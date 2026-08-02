# Story 004: File I/O, JSON Encoding, and Version Checking

> **Epic**: save-load
> **Status**: Ready
> **Layer**: Foundation
> **Type**: Integration
> **Estimate**: [hours or t-shirt size — fill before sprint planning]
> **Manifest Version**: 2026-07-23
> **Last Updated**: [set by /dev-story when implementation begins]

## Context

**GDD**: `design/gdd/save-load.md`
**Requirements**: `TR-SL-007`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADRs Governing Implementation**: ADR-0002: Storage Format
**ADR Decision Summary**: Save files stored as JSON (`.sav.json`) using Godot's `FileAccess` API. `JSON.stringify()` with `full_precision=true` and `sort_keys=true` for deterministic output. `JSON.parse_string()` for reading (self-written JSON — no authoring errors to guard against with parse-with-line-numbers). `FileAccess.store_*()` returns `bool` since Godot 4.4 — every write call must check the return value. `FileAccess.flush()` called before `f.close()` for durability (OS-level write buffer flushed). Versioning: exact-match only for MVP (`SAVE_FORMAT_VERSION == blob.version`); mismatch rejected gracefully with user-facing error message. No auto-migration, no downgrade support.

**Engine**: Godot 4.7.1 | **Risk**: MEDIUM
**Engine Notes**: `FileAccess.store_string()` and `FileAccess.store_buffer()` return `bool` since Godot 4.4 — must check return values; a false return means the write failed silently in older versions, now it's explicit. `FileAccess.flush()` is separate from `close()` — call flush first, check its return, then close. Save directory: `OS.get_user_data_dir()` for the Godot project (platform-appropriate location). `DirAccess.make_dir_recursive()` for creating the save directory if it doesn't exist. `JSON.parse_string()` returns `null` on parse failure (not an error object like `JSON.new(); json.parse()`) — but since we only read our own JSON, parse failure = corruption. `full_precision=true` in `JSON.stringify()` is essential: without it, int64 values (RNG states, seeds) exceeding 2^53 will be silently truncated.

**Control Manifest Rules (Foundation layer)**:
- Required: `FileAccess.store_*()` return value checked everywhere (missing check = test failure); `FileAccess.flush()` before `close()`; `full_precision=true` on every `JSON.stringify()` call; version exact-match check BEFORE any system is touched
- Forbidden: Never write to user-controlled paths (path traversal); never proceed with load if version mismatches (even for "minor" version bumps); never call `JSON.stringify()` without `sort_keys=true` (ordering differences break hash-based comparison)
- Guardrail: Save file size estimate: < 50 KB for MVP grid (130 cells, ~20 equipment, ~10 members) — log a warning if > 1 MB

---

## Acceptance Criteria

*From GDD `design/gdd/save-load.md`, scoped to this story:*

- [ ] AC6 [BLOCKING][Logic] GIVEN a save file whose `version != SAVE_FORMAT_VERSION` (higher or lower), WHEN `load_from_file()` reads it, THEN the load is rejected gracefully: result.ok == false, result.errors contains a version-mismatch message mentioning both versions, and no system is touched (no Phase A even starts)
- [ ] AC-FILE-1 [BLOCKING][Logic] GIVEN a valid save blob, WHEN `save_to_file(path)` writes it, THEN every `FileAccess.store_*()` return value is checked — a mocked `store_string()` returning `false` must cause `save_to_file()` to return an error, not silently succeed
- [ ] AC-FILE-2 [BLOCKING][Logic] GIVEN `save_to_file()` writes successfully, WHEN the file is inspected, THEN `flush()` was called before `close()` — verified by mock or by reading the file's content immediately after `save_to_file()` returns (flush guarantees the OS has written it)
- [ ] AC-FILE-3 [BLOCKING][Logic] GIVEN a save file with JSON syntax error (truncated file), WHEN `load_from_file()` reads it, THEN the load fails with "save file corrupted or truncated" error — no crash, no partial parse, no mutation
- [ ] AC-FILE-4 [BLOCKING][Logic] GIVEN `save_to_file("my_save")`, WHEN the save completes, THEN the file exists at `user_data_dir/saves/my_save.sav.json` and contains valid parseable JSON

---

## Implementation Notes

*Derived from ADR-0002 + GDD Core Rule 6:*

**File I/O methods on SaveLoad:**
```gdscript
const SAVE_DIR := "saves"
const SAVE_EXTENSION := ".sav.json"

# Write save blob to disk. Returns error string if failed, empty string on success.
func save_to_file(save_name: String) -> String:
    assert(_initialized, "SaveLoad: not initialized")
    
    # Produce the blob (delegates to save-blob composition from Story 001)
    var blob := _perform_save()
    
    # JSON encode with deterministic options
    var json_string := JSON.stringify(blob, "  ", false, true)
    #                                   indent, sort_keys, full_precision
    # indent="  " for human-readability; sort_keys=true for deterministic output;
    # full_precision=true for int64 safety
    
    # Resolve save path
    var user_dir := OS.get_user_data_dir()
    var save_dir := user_dir.path_join(SAVE_DIR)
    
    # Ensure directory exists
    var dir := DirAccess.open("user://")
    if not dir.dir_exists(save_dir):
        var mkdir_result := dir.make_dir_recursive(save_dir)
        if mkdir_result != OK:
            return "SaveLoad: failed to create save directory '%s' (error %d)" % [save_dir, mkdir_result]
    
    var file_path := save_dir.path_join(save_name + SAVE_EXTENSION)
    
    # Write to file
    var f := FileAccess.open(file_path, FileAccess.WRITE)
    if f == null:
        var open_error := FileAccess.get_open_error()
        return "SaveLoad: failed to open '%s' for writing (error %d)" % [file_path, open_error]
    
    # Every store_* call's return value MUST be checked.
    if not f.store_string(json_string):
        f.close()
        return "SaveLoad: failed to write save data to '%s'" % file_path
    
    # flush() before close() — ensures OS-level write buffers are committed.
    # If flush fails, the file on disk may be incomplete.
    f.flush()
    
    var close_error := f.get_open_error()  # FileAccess.get_open_error() after close
    f.close()
    
    if close_error != OK:
        return "SaveLoad: error closing save file '%s' (error %d)" % [file_path, close_error]
    
    return ""  # success

# Read save blob from disk. Returns [blob: Dictionary, error: String].
# error is empty on success.
func load_from_file(save_name: String) -> Array:  # [Dictionary, String]
    assert(_initialized, "SaveLoad: not initialized")
    
    var file_path := OS.get_user_data_dir().path_join(SAVE_DIR).path_join(save_name + SAVE_EXTENSION)
    
    if not FileAccess.file_exists(file_path):
        return [{}, "Save file '%s' not found" % file_path]
    
    var f := FileAccess.open(file_path, FileAccess.READ)
    if f == null:
        return [{}, "Failed to open save file '%s'" % file_path]
    
    var json_string := f.get_as_text()
    f.close()
    
    if json_string.is_empty():
        return [{}, "Save file '%s' is empty" % file_path]
    
    # Parse JSON
    var json := JSON.new()
    var parse_error := json.parse(json_string)
    if parse_error != OK:
        return [{}, "Save file '%s' is corrupted or truncated (JSON parse error at line %d: %s)" % 
            [file_path, json.get_error_line(), json.get_error_message()]]
    
    var blob = json.get_data()
    if not blob is Dictionary:
        return [{}, "Save file '%s' has unexpected structure (not a JSON object)" % file_path]
    
    # Version check — BEFORE any system is touched
    if not blob.has("version"):
        return [{}, "Save file '%s' is missing version field — possibly from an older format" % file_path]
    
    if blob["version"] != SAVE_FORMAT_VERSION:
        return [{}, "Save file '%s' version mismatch: file is v%d, game expects v%d" % 
            [file_path, blob["version"], SAVE_FORMAT_VERSION]]
    
    return [blob, ""]
```

**Full save/load public API:**
```gdscript
# Public: save to disk using save_name as the slot identifier.
# The caller (UI) is responsible for the save_name — e.g., "autosave", "slot_1", etc.
# Returns error string (empty on success).
func save(save_name: String) -> String:
    # request_save() defers to tick boundary (Story 001)
    # For file I/O, the save is synchronous at the boundary.
    # The caller should call this from within the tick_completed handler.
    return save_to_file(save_name)

# Public: load from disk. The caller must provide buildable_snapshot.
# Calls the load() method from Story 002 internally.
# Returns LoadResult (from Story 002).
func load_save(save_name: String, buildable_snapshot: PackedByteArray) -> LoadResult:
    var arr := load_from_file(save_name)
    var blob: Dictionary = arr[0]
    var error: String = arr[1]
    
    var result := LoadResult.new()
    if not error.is_empty():
        result.errors.append(error)
        return result
    
    return load(blob, buildable_snapshot)  # from Story 002
```

**Key design decisions:**
- Version check happens in `load_from_file()` before any Dictionary is passed to `load()` — the version gates the entire pipeline (AC6)
- `JSON.parse_string()` is NOT used — `JSON.new(); json.parse()` is preferred because it provides line numbers in error messages (self-written JSON may become corrupted via disk error)
- `flush()` is called before `close()` — if the process crashes between `close()` and the OS flush, data is already committed
- `full_precision=true` on every `stringify()` call — never omit it, even for debug output; the habit prevents silent truncation bugs
- Save files are `.sav.json` — human-readable and VCS-friendly for debugging; can be inspected with any text editor
- User data directory is `OS.get_user_data_dir()` — platform-appropriate (e.g., `~/Library/Application Support/` on macOS, `%APPDATA%` on Windows)

---

## Out of Scope

*Handled by neighbouring stories or future work:*

- [Story 001-003]: All in-memory save/load logic — this story adds the disk layer only
- [Future]: Save slot UI (new game, load game, save game menus) — this story provides `save(name)` and `load_save(name)`, but the UI that calls them is a separate UI story
- [Future]: Save migration (version bump handling beyond exact-match reject) — MVP rejects mismatch; migration is post-MVP
- [Future]: Autosave cadence (periodic save every N minutes) — game-designer/producer decision; this story provides the `save()` primitive

---

## QA Test Cases

*Sourced from `production/qa/qa-plan-sprint-2-2026-08-02.md` — Automated Tests Required (SL-004). Authoritative test file: `tests/integration/save_load/file_io_version_test.gd` (~30 assertions).*

**What to test**:
- AC-FILE-1: 每个 FileAccess.store_*() 返回值检查 — mock store_string() 返回 false → save_to_file() 报错
- AC-FILE-2: flush() 先于 close()（写后立即读文件内容验证）
- AC-FILE-3: 截断/损坏 JSON → "save file corrupted or truncated" 错误，无崩溃/部分解析
- AC-FILE-4: save_to_file("my_save") → `user_data_dir/saves/my_save.sav.json` 存在且 JSON 可解析
- 版本 exact-match：不匹配 → 用户可见"不兼容存档"消息，无迁移

**Edge cases**: 文件已存在覆盖、目录不存在、版本字段缺失

**Estimated assertions**: ~30

- **AC6**: 版本不匹配 → 优雅拒绝
  - Given: save file with version=99, current SAVE_FORMAT_VERSION=1
  - When: load_from_file("test_save")
  - Then: result.error includes "version mismatch"; error message mentions both versions (99 and 1); no Phase A or B ran — no system touched
  - Edge cases: test with version=0 (lower than current); test with version=-1 (corrupt/malicious); test with version as string "1" instead of int 1 (wrong type — should fail at JSON parse or type check); test with missing version field entirely

- **AC-FILE-1**: store_string 返回值检查
  - Given: mock FileAccess where store_string() returns false (simulated disk full)
  - When: save_to_file("test")
  - Then: returns non-empty error string; error mentions write failure; file not left in corrupt state on disk
  - Edge cases: test store_string success (returns true → no error); test flush failure; test open failure (permission denied)

- **AC-FILE-2**: flush → close 顺序
  - Given: mock FileAccess tracking call order
  - When: save_to_file("test")
  - Then: flush() called before close(); flush() called exactly once; close() called exactly once after flush()
  - Edge cases: test that flush failure still results in close() being called (cleanup is not skipped on flush error)

- **AC-FILE-3**: 损坏文件处理
  - Given: save file containing `{this is not valid JSON`
  - When: load_from_file("corrupt_save")
  - Then: result.error includes "corrupted or truncated"; parse error line number is reported; no system mutated
  - Edge cases: test empty file; test file with valid JSON but wrong structure (array instead of object); test file with valid JSON object but wrong keys

- **AC-FILE-4**: 保存文件写入正确位置
  - Given: save_name="autosave"
  - When: save_to_file("autosave") succeeds
  - Then: file exists at `<user_data_dir>/saves/autosave.sav.json`; file content is valid JSON; parsed content matches the blob
  - Edge cases: test with special characters in save_name (should be sanitized or rejected); test saving twice to same name (overwrites); test save_dir doesn't exist yet (create it)

---

## Test Evidence

**Story Type**: Integration (FileAccess I/O + JSON encoding + SaveLoad coordination)
**Required evidence**:
- `tests/integration/save_load/file_io_version_test.gd` — must exist and pass (AC6, AC-FILE-1, AC-FILE-2, AC-FILE-3, AC-FILE-4)

**Status**: [ ] Not yet created

---

## Dependencies

- Depends on: Story 001 (save blob composition), Story 002 (load pipeline), Story 003 (round-trip determinism verified). File I/O is the final layer — it only works if the in-memory pipeline is correct.
- Unlocks: Save/load UI integration (UI can call save()/load_save()), autosave scheduling, save migration (post-MVP)
