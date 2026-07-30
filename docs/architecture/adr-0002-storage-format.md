# ADR-0002: Storage Format — Save Blob, Catalog Data, Level Geometry

## Status
Accepted

**Gate**: ADR-0001 Accepted (depends-on cleared) 2026-07-22. No @abstract dependency — all FileAccess/JSON/RefCounted patterns use stable 4.7.1 APIs.

## Date
2026-07-21

## Engine Compatibility

| Field | Value |
|-------|-------|
| **Engine** | Godot 4.7.1 |
| **Domain** | Core / Scripting (serialization, file I/O) |
| **Knowledge Risk** | HIGH — version is 4 releases beyond LLM training cutoff |
| **References Consulted** | `docs/engine-reference/godot/VERSION.md`, `docs/engine-reference/godot/breaking-changes.md`, `docs/engine-reference/godot/deprecated-apis.md`, `docs/engine-reference/godot/current-best-practices.md` |
| **Post-Cutoff APIs Used** | `FileAccess.store_*` return `bool` (4.4+ — was `void` before 4.4), `ResourceLoader.load()` (stable, no post-cutoff changes), `JSON.stringify()` / `JSON.parse_string()` (stable, no post-cutoff changes) |
| **Verification Required** | `FileAccess.store_string()` return value must be checked (was void, now bool in 4.4+) — verify that failing to check the return value produces a GDScript warning in 4.7.1; verify `JSON.stringify()` float precision is sufficient for RNG stream state (SplitMix64 uses 64-bit integers — JSON number may truncate) |

## ADR Dependencies

| Field | Value |
|-------|-------|
| **Depends On** | ADR-0001 (DI Container & Scene Bootstrap — uses `init()` signatures defined there) |
| **Enables** | ADR-0003 (GridStateReader Contract — needs serialization format for `get_placed_instances()` data), ADR for Save/Load UI |
| **Blocks** | SaveLoad (#14) implementation, EquipmentCatalog (#2) implementation, all systems that expose `serialize()`/`deserialize()` methods |
| **Ordering Note** | Must be Accepted before any `serialize()`/`deserialize()` method is implemented on a simulation system |

## Context

### Problem Statement

Three distinct data categories need persistent storage, each with different requirements:

1. **Save blob** — runtime simulation state (7 systems' serialized output + version + seed).
   Must be bit-exact reproducible after reload. Written and read by SaveLoad coordinator.
   Size: ~10-50 KB for a typical session.
2. **Equipment catalog** — authored game data (~20-50 equipment definitions, each ~15 fields).
   Immutable at runtime. Authored by designers (hand-edited or tool-generated). Must be
   validated on load with configurable `strict_mode`.
3. **Level geometry** — `buildable` mask (PackedByteArray, one byte per cell) and
   entrance/exit positions. Single fixed level at MVP. Must be available before
   GridSystem deserialization.

These three categories share infrastructure needs: a version field, error handling
strategy, and a file I/O path. But forcing one format onto all three would compromise
each category's primary use case.

### Constraints

- Godot 4.7.1 `FileAccess.store_*` methods return `bool` (changed from `void` in 4.4) —
  all write calls must check the return value
- Godot's `JSON` class handles `int` and `float` but has **no native 64-bit integer
  support** — `master_seed` (int64) and RNG stream states (64-bit) risk precision loss
  if stored as JSON numbers
- Catalog data must be human-readable and VCS-diffable (designers edit it)
- Save blob must survive across game versions (MVP: exact-match version check; future:
  migration support)
- Level geometry is a large binary blob (width × height bytes) — storing as
  pretty-printed JSON would be wasteful and slow
- EquipmentCatalog's `strict_mode: bool` parameter (injected, per coding standards)
  must be honored regardless of storage format
- Per ADR-0001: all systems are RefCounted, `init()` receives typed dependencies
- No networking — single-player, local filesystem only

### Requirements

- Save blob must be loadable on the same game version (exact version match), producing
  a bit-exact reproduction of the saved simulation state (determinism contract from
  SaveLoad Core Rule 5)
- Catalog must support hand-authoring by designers in a text editor, with validation
  errors that point to the offending line/field
- Level geometry must load before GridSystem deserialization (SaveLoad Core Rule 3,
  step 2's `buildable_snapshot`)
- All formats must embed a version field at the top level
- Corrupt or truncated files must fail with a clear error, never silently partial-load
- Headless CI (GUT test runner) must be able to load all three categories without
  editor coupling

## Decision

### 1. Format Strategy — Per-Category, Not One-Size-Fits-All

Rather than force one format onto all three categories, each category uses the
format best suited to its primary use case:

| Category | Format | Rationale |
|----------|--------|-----------|
| **Save blob** | JSON (`.sav.json`) | Debuggable, diffable, human-readable for QA. Size (~10-50 KB) is negligible for a local save file. JSON enables save-file introspection during development without custom tooling. |
| **Equipment catalog** | JSON (`.catalog.json`) | Hand-authored by designers. JSON is the lowest-friction text format — no custom parser to maintain, trivial VCS diff, any text editor works. Validation errors include JSON path context. |
| **Level geometry** | Custom binary (`.level.bin`) | PackedByteArray (`buildable`) + `Vector2i` (entrance/exit/dimensions). Binary is compact, fast to parse, and the data has no human-editing use case (level editor tooling is VS-stage). |

This is a deliberately pragmatic split — not "one format to rule them all." The
shared infrastructure (version field, error envelope, file path convention) is
defined below; the per-category format choice lives with the category.

### 2. Version Envelope (All Formats)

Every persisted file, regardless of category, wraps its payload in a version envelope:

```json
// Save blob and catalog (JSON)
{
  "format_version": 1,
  "payload": { ... }
}
```

```gdscript
# Level geometry (binary) — fixed header
# Bytes 0-3:    format_version (int32, little-endian)
# Bytes 4-7:    width (int32)
# Bytes 8-11:   height (int32)
# Bytes 12-15:  entrance_x (int32)
# Bytes 16-19:  entrance_y (int32)
# Bytes 20-23:  exit_x (int32)
# Bytes 24-27:  exit_y (int32)
# Bytes 28+:    buildable mask (width * height bytes, row-major, 1 = buildable)
```

**Version policy**: Monotonic integer (`format_version: 1, 2, 3, ...`).
Not semver — save formats don't have "minor" compatibility. Each version increment
means "this format is different from the previous one." MVP is **exact match only**
(SaveLoad Core Rule 6): a mismatch is rejected with a user-facing "incompatible
save" message, no auto-migration. Migration support (version N → N+1 transforms)
is a VS-stage feature, not MVP.

The version integer is stored **outside** the system-level `serialize()` output —
SaveLoad owns the version envelope; individual systems do not embed their own version.

### 3. Save Blob Structure

```json
{
  "format_version": 1,
  "payload": {
    "master_seed": "<int64 as hex string>",
    "time_system": { ... TimeSystem.serialize() output ... },
    "grid_system": { ... GridSystem.serialize() output ... },
    "member_sim": { ... MemberSim.serialize() output ... },
    "congestion": { ... Congestion.serialize() output ... },
    "satisfaction": { ... Satisfaction.serialize() output ... },
    "economy": { ... Economy.serialize() output ... }
  }
}
```

**64-bit integer encoding**: `master_seed` (signed int64) and RNG stream states
(SplitMix64, unsigned uint64) are stored in JSON. JSON has no native 64-bit integer
type — JavaScript's `Number` is IEEE 754 double (53-bit mantissa). To avoid silent
truncation, all 64-bit values are serialized as **hex strings** in the JSON blob.

GDScript's `int` is signed 64-bit. The conversion method depends on whether the
value is semantically signed or unsigned:

| Value type | Serialize | Deserialize | Notes |
|------------|-----------|-------------|-------|
| signed `int64` (`master_seed`) | `String.num_int64(v, 16)` | `"hex".hex_to_int()` | Signed round-trip is exact |
| unsigned `uint64` (SplitMix64 state) | `String.num_uint64(v, 16)` | `"hex".hex_to_int()` | Bits preserved; values ≥ 2^63 display as negative `int` but the bit pattern is correct for SplitMix64 |

**Critical**: `String.num_uint64()` must be used for SplitMix64 state, NOT
`num_int64()`. Using `num_int64()` on a value ≥ 2^63 would produce a string
with a leading `-` (e.g., `"-7fffffffffffffff"` instead of `"8000000000000000"`),
which `hex_to_int()` would not parse correctly.

Each system's `serialize()`/`deserialize()` is responsible for the hex ↔ int
conversion using the correct function pair. This is a **mandatory rule** — no
64-bit value may appear as a JSON number literal in a save blob.

A GUT test must verify round-trip for signed and unsigned boundary values:
- Signed: `0`, `1`, `-1`, `2^62`, `-(2^62)`, `2^63-1`, `-(2^63)`
- Unsigned: `0`, `1`, `2^53`, `2^63`, `2^64-1` (bits preserved even though `int` displays negative)

### 4. Equipment Catalog Format

```json
{
  "format_version": 1,
  "payload": {
    "equipment": [
      {
        "id": "treadmill_basic",
        "display_name": "Basic Treadmill",
        "zone_membership": "cardio",
        "footprint_cells": [[0, 0], [1, 0]],
        "access_cells": [[0, 1]],
        "cost": 100,
        "unlock_requirement": null,
        "effects": [
          {"tag": "comfort", "magnitude": 0.1}
        ],
        "use_duration_mean_ticks": 200,
        "use_duration_stddev_ticks": 30,
        "use_duration_min_ticks": 100,
        "use_duration_max_ticks": 300
      }
    ]
  }
}
```

**Catalog loading** follows EquipmentCatalog GDD Core Rule 2 (immutable after load)
and Core Rule 6 (validation contract). The loader:

1. Parses the JSON file
2. Validates the `format_version` envelope
3. For each entry in `payload.equipment[]`:
   - Normalizes coordinates per Core Rule 5 (shift to `min == (0,0)`)
   - Runs the validation checklist from Core Rule 6 (a-d) and Core Rule 7 (e-h)
   - On failure: if `strict_mode == true` → aborts entire load; if `false` →
     skips the offending entry and logs a warning
4. Constructs `EquipmentDef` records from valid entries
5. Freezes the catalog — no further mutation

The `strict_mode` parameter is injected at construction time per ADR-0001:
```gdscript
var catalog := EquipmentCatalog.new()
catalog.init(strict_mode, data_path)
```

### 5. Level Geometry Format

Binary header + body as described in the version envelope section. The loader:

1. Opens the `.level.bin` file
2. Reads the 28-byte header (7 × int32)
3. Validates `format_version`
4. Reads `width * height` bytes of buildable mask
5. Constructs a `Dictionary` with `{width, height, entrance, exit, buildable}`
6. Returns this dictionary — the caller (scene bootstrap or SaveLoad) passes it
   as `buildable_snapshot` to GridSystem

No JSON wrapping for level data — the binary format is self-describing via its
28-byte header, and the data has no human authoring use case at MVP.

### 6. File I/O — Godot FileAccess with Error Checking

All file operations use Godot's `FileAccess` class (not `ResourceSaver`/`ResourceLoader`
for runtime save data, which would couple to the editor's resource cache).

**Godot 4.4+ breaking change**: `FileAccess.store_string()` and all `store_*()`
methods return `bool` (was `void` before 4.4). Every write call must check the
return value:

```gdscript
func _write_save(path: String, data: Dictionary) -> bool:
    var f := FileAccess.open(path, FileAccess.WRITE)
    if f == null:
        push_error("SaveLoad: cannot open %s for writing: %d" % [path, FileAccess.get_open_error()])
        return false

    var json_str := JSON.stringify(data, "\t")  # pretty-print for debuggability
    if not f.store_string(json_str):
        push_error("SaveLoad: write failed for %s" % path)
        return false

    f.flush()   # force OS-level write before close (Godot docs recommendation for crash safety)
    f.close()
    return true
```

**JSON parsing — two paths for two use cases**: Godot 4.7 provides two JSON
parsing APIs with different error-reporting capabilities:

| Method | Use Case | Error Detail |
|--------|----------|--------------|
| `JSON.parse_string(json_string)` | **SaveLoad round-trip** (load saved blob) | Returns `null` on parse failure. No line number, no error message — sufficient for "corrupt or truncated save → `LoadError(category="parse_error")`" |
| `JSON.new(); json.parse(json_string)` | **Catalog loader** (designer-authored data) | Returns `Error` enum; `json.get_error_line()` and `json.get_error_message()` provide line-number context for validation errors |

Catalog loading with `strict_mode=true` uses the instance-based `JSON.parse()`
path so validation errors can report the offending line:

```gdscript
var json := JSON.new()
var parse_err := json.parse(catalog_text)
if parse_err != OK:
    return _load_error("parse_error",
        "Catalog JSON parse failed at line %d: %s" % [json.get_error_line(), json.get_error_message()])
var data := json.get_data()  # Dictionary, safe to access after parse_err == OK
```

SaveLoad uses `JSON.parse_string()` — the round-trip path is "JSON we wrote
ourselves," so parse failures indicate I/O corruption, not authoring errors.
A `null` return is sufficient to trigger all-or-nothing abort.

**Headless CI compatibility**: `FileAccess` works identically in headless and
editor modes — no `.tres` or `.res` files are used for runtime data, so GUT
tests can verify save/load round-trips without the Godot editor.

### 7. Error Envelope

All load errors produce a structured error rather than a bare string:

```gdscript
class_name LoadError extends RefCounted
var category: String    # "version_mismatch", "parse_error", "validation_failed", "io_error"
var message: String     # human-readable, safe to show in UI
var detail: String      # developer-facing (file path, line number, field name)
```

This allows the UI layer (future Save/Load menu) to distinguish "incompatible
version" (show version numbers) from "corrupt file" (suggest deleting save) from
"IO error" (suggest checking disk permissions).

### Architecture Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                      STORAGE LAYER                           │
│                                                              │
│  ┌──────────────────┐  ┌──────────────┐  ┌───────────────┐ │
│  │   Save Blob       │  │   Catalog     │  │  Level Geom   │ │
│  │   (.sav.json)     │  │ (.catalog.json)│  │  (.level.bin) │ │
│  │                    │  │               │  │               │ │
│  │  JSON envelope     │  │  JSON array   │  │  28-byte hdr  │ │
│  │  + 7 sys payloads  │  │  of defs      │  │  + mask bytes │ │
│  │  + hex-encoded i64 │  │  + validation │  │               │ │
│  └────────┬───────────┘  └──────┬────────┘  └───────┬───────┘ │
│           │                     │                    │         │
│  ┌────────┴─────────────────────┴────────────────────┴───────┐ │
│  │                   Shared Infrastructure                    │ │
│  │  • format_version (monotonic int, envelope)                │ │
│  │  • FileAccess with bool-return checking (Godot 4.4+)       │ │
│  │  • LoadError structured error type                         │ │
│  │  • Headless-compatible (no .tres/.res for runtime data)    │ │
│  └────────────────────────────────────────────────────────────┘ │
└─────────────────────────────────────────────────────────────┘
```

### Key Interfaces

#### SaveLoad serialization contract (per system)

Every coordinated system exposes:

```gdscript
## Returns a Dictionary of this system's serializable state.
## Must be pure — no side effects, no RNG calls.
func serialize() -> Dictionary:
    pass

## Validates (mode == "validate") or applies (mode == "commit") serialized state.
## In validate mode: returns {valid: bool, error: String} without mutating state.
## In commit mode: applies the data and returns {success: bool, error: String}.
func deserialize(data: Dictionary, mode: String) -> Dictionary:
    pass
```

`mode` is `"validate"` (Phase A, zero mutation) or `"commit"` (Phase B, full
application). Systems that don't hold serializable state (ZoneRules, Navigation,
PlacementSystem, SelectionSystem) omit these methods — their state is either
pure-function or derived from GridSystem on load.

#### EquipmentCatalog loading contract

```gdscript
## Loads and validates equipment definitions from a JSON file.
## strict_mode=true: any validation failure aborts the entire load.
## strict_mode=false: invalid entries are skipped with a warning.
func load_catalog(data_path: String, strict_mode: bool) -> CatalogLoadResult:
    pass

class_name CatalogLoadResult extends RefCounted
var definitions: Array[EquipmentDef]   # successfully loaded
var errors: Array[LoadError]            # validation failures (empty if strict_mode)
var ok: bool                            # false if catastrophic failure (IO error, parse error)
```

`CatalogLoadResult` is not a `LoadError` — it's a batch result that may contain
both successful definitions and per-entry errors. This supports `strict_mode=false`
(debug/edit workflows) while keeping the success path clean for `strict_mode=true`
(release/test builds).

## Alternatives Considered

### Alternative 1: Godot Resources (.tres / .res)

- **Description**: Store save data, catalog, and level geometry as Godot `Resource`
  subclasses. Save via `ResourceSaver.save()`, load via `ResourceLoader.load()`.
  Edit catalog in the Godot editor inspector.
- **Pros**: Godot-native; editor integration for catalog editing; built-in
  serialization of Vector2i, Dictionary, Array; ResourceLoader handles caching
- **Cons**: `.tres`/`.res` format is Godot-proprietary and not VCS-diffable
  (`.res` is binary); `ResourceLoader` is coupled to the editor's resource cache
  and may not be available or behave identically in headless CI; `ResourceSaver`
  can introduce editor-only dependencies; designers cannot edit `.tres` in a plain
  text editor without understanding Godot's resource syntax
- **Rejection Reason**: Three deal-breakers: (1) Headless CI incompatibility —
  GUT tests must be able to load catalog data without the Godot editor running,
  and `ResourceLoader` behavior in headless mode is inconsistent across Godot
  4.x versions. (2) VCS-diff — catalog changes must be reviewable in git diffs;
  `.tres` produces noisy diffs with resource IDs and internal metadata. (3)
  Save files should not be Godot-proprietary — a player's save should be
  inspectable with any text editor.

### Alternative 2: Custom Binary for Everything

- **Description**: Define a compact binary format for all three categories. Save
  blob, catalog, and level geometry all use the same binary framing with a
  shared header and per-section length prefixes.
- **Pros**: Smallest file size; fastest parse; no JSON overhead; consistent
  tooling for all three categories
- **Cons**: Binary is opaque — debugging a save file requires a hex editor;
  catalog cannot be hand-authored by designers without a dedicated editor tool;
  format changes require maintaining a binary parser; VCS diffs are meaningless
  (binary blobs)
- **Rejection Reason**: The primary use case for catalog data is **designer
  authoring** — forcing designers to use a custom binary editor is premature
  infrastructure for a solo/indie project. Binary saves are useful for AAA
  games with 100+ MB save files; this game's save blob is ~10-50 KB. JSON's
  debuggability and zero-tooling requirement outweigh its size overhead by a
  large margin for this project's scale.

### Alternative 3: SQLite

- **Description**: Use an embedded SQLite database (via GDExtension or engine
  module) for save data and catalog queries.
- **Pros**: Queryable; supports migrations via SQL; well-understood format
- **Cons**: Requires a GDExtension or custom engine build (Godot has no built-in
  SQLite support); adds a native dependency to the build pipeline; overkill for
  ~20 catalog entries and a single save slot
- **Rejection Reason**: Infrastructure cost vastly exceeds benefit. This is a
  single-player management sim with one save slot — SQLite would add a native
  build dependency and ~500 KB of binary size for a problem solved by a 50-line
  JSON parser.

## Consequences

### Positive

- Save files are human-readable JSON — debugging a "my save broke" bug report
  is as simple as opening the file in a text editor
- Catalog data is hand-authorable in any text editor, VCS-diffable, and trivially
  validated in CI (validate the JSON against the EquipmentCatalog contract)
- Binary level geometry is fast to load and compact — no JSON overhead for a
  potentially large grid (100×100 = 10,000 cells = 10 KB binary vs ~60 KB JSON)
- 64-bit integer encoding (hex strings) prevents silent precision loss — a class
  of bugs that would be nearly impossible to diagnose from symptoms alone
- `FileAccess` works identically in headless and editor modes — GUT tests can
  verify round-trip save/load deterministically
- Per-category format choice means each category optimizes for its primary user
  (player for saves, designer for catalog, engine for level geometry)

### Negative

- Three formats means three parsers to maintain — though each is small
  (JSON parser is Godot's built-in `JSON` class; binary level parser is ~30
  lines of `FileAccess.get_8()`/`get_32()` calls)
- Hex-encoded 64-bit integers add ~18 characters per value in the JSON blob
  (acceptable: ~10 such values in a typical save)
- JSON pretty-printing adds whitespace overhead (~2× size vs compact JSON) —
  but ~10-50 KB is negligible for a local save file
- `JSON.stringify()` with `"\t"` indent is not available in all Godot versions
  (confirmed in 4.7.1 — verify; fallback: `JSON.stringify(data)` without indent)

### Risks

- **JSON float precision for RNG state**: IEEE 754 double has 53 bits of mantissa.
  SplitMix64 uses 64-bit state. This is why we encode as hex strings — but a
  future developer might add a float field to `serialize()` without realizing the
  precision constraint. Mitigation: the serialization contract section of this ADR
  explicitly requires 64-bit integers to use hex encoding; a GUT test verifies
  round-trip for boundary values.
- **Float precision in `JSON.stringify()`**: Godot 4.7's `JSON.stringify()` has a
  `full_precision` parameter (default `false`). Systems that serialize `float`
  values (Satisfaction, Economy) may lose the last bit of IEEE 754 round-trip
  precision when `full_precision` is left at default. For deterministic save/load,
  call `JSON.stringify(data, "\t", false, true)` to enable full-precision float
  encoding. This does not affect integer values < 2^53, and does not affect
  hex-encoded 64-bit integers (stored as strings).
- **`JSON.stringify()` key ordering**: Godot 4.7's `JSON.stringify()` sorts
  dictionary keys alphabetically by default (`sort_keys=true`, the third parameter).
  This produces stable diffs between saves — a benefit for VCS and debugging.
  Developers writing `serialize()` methods should know that Dictionary key insertion
  order will not be preserved in JSON output. Non-issue for correctness.
- **`JSON.stringify()` indent parameter**: Confirmed available in Godot 4.7.1 with
  `"\t"` indent — official docs include this exact usage. More reliable than the
  Risks section of the ADR-0002 first draft assumed.
- **`FileAccess.flush()` for crash safety**: The `_write_save()` example now includes
  `f.flush()` before `f.close()`. Per Godot 4.7 docs, the OS-level file close is not
  guaranteed if the process is killed (editor F8 stop, crash). `f.flush()` reduces
  the window for data loss.
- **Binary `store_32()` return checking**: The binary level format writer must also
  check `store_32()` return values — all `store_*()` methods return `bool` since
  Godot 4.4. The ADR's JSON example covers the pattern; the binary writer must
  follow the same `if not f.store_32(value):` discipline.
- **`FileAccess.get_open_error()` returns `Error` enum**: The example code formats it
  with `%d` which works (prints the numeric value), but `error_string(FileAccess.get_open_error())`
  is more readable in logs. Minor — adjust during implementation.
- **Binary format endianness**: The level geometry header uses little-endian int32
  (Godot's native byte order on all supported platforms — macOS, Windows, Linux
  are all little-endian). If a big-endian platform is ever targeted, the binary
  reader must swap. Mitigation: document the endianness assumption; a future
  platform port would need to update the level loader. This is a non-issue for
  MVP (macOS/Windows only).
- **Save file size growth**: As more systems are added or equipment instances
  accumulate, the JSON save blob could grow. At 200 placed instances with full
  state each, the save blob is estimated at ~200 KB — still well within
  acceptable range for a local file. If this becomes a problem, the mitigation
  is to add optional gzip compression to the save pipeline (`.sav.json.gz`)
  without changing the format inside.

## GDD Requirements Addressed

| GDD System | Requirement | How This ADR Addresses It |
|------------|-------------|--------------------------|
| save-load.md | Core Rule 2: save composition — one ordered blob with version, master_seed, and 6 system payloads | Defines the JSON save blob structure with `format_version` envelope and per-system `serialize()` output fields |
| save-load.md | Core Rule 3: load order enforced programmatically with Phase A (validate) / Phase B (commit) | Defines the `deserialize(data, mode)` contract — mode is `"validate"` (Phase A) or `"commit"` (Phase B) |
| save-load.md | Core Rule 4: all-or-nothing integrity — stage-then-commit | `deserialize(mode="validate")` returns `{valid: bool, error: String}` without mutation; only after all systems pass does Phase B commit |
| save-load.md | Core Rule 5: determinism contract — RNG stream states must be restored exactly | 64-bit integers encoded as hex strings to avoid IEEE 754 truncation; GUT test for round-trip boundary values |
| save-load.md | Core Rule 6: versioning — MVP exact-match only, no auto-migration | `format_version` monotonic int; mismatch → `LoadError(category="version_mismatch")` |
| save-load.md | Core Rule 7: resume paused, always | TimeSystem.deserialize() forces paused=true — this is TimeSystem's contract, not the storage format, but the save blob preserves `speed_multiplier` for introspection |
| equipment-catalog.md | Core Rule 1: EquipmentDef data fields — 15 typed fields per definition | JSON structure maps 1:1 to EquipmentDef fields; `footprint_cells`/`access_cells` as `[[x,y],...]` arrays |
| equipment-catalog.md | Core Rule 2: immutable after load, read-only interface | Catalog loader constructs EquipmentDefs, then freezes the catalog — no setter/mutator in the runtime interface |
| equipment-catalog.md | Core Rule 6: load-time validation contract (a-d) + Rule 7 (e-h) | Validation runs during JSON parse; `strict_mode` parameter controls debug-abort vs release-skip behavior |
| equipment-catalog.md | Core Rule 6 (testability): `strict_mode` injected, not hardcoded via `OS.is_debug_build()` | `EquipmentCatalog.init(strict_mode, data_path)` — test fixtures pass `true`/`false` explicitly |
| equipment-catalog.md | Core Rule 5: coordinate normalization | Normalization runs during catalog load, before EquipmentDef construction — the stored JSON may have non-normalized coordinates; the loader fixes them |

## Performance Implications
- **CPU**: JSON parse for ~50 KB save blob — < 1ms. Binary level parse for 100×100
  grid — < 0.1ms. Catalog JSON parse for ~50 definitions — < 1ms. Total load time
  for all three categories: < 5ms.
- **Memory**: Save blob deserialized into Dictionaries — ~50-100 KB transient until
  each system extracts its fields. Catalog EquipmentDefs — ~20-50 KB permanent
  (immutable, shared by all systems). Level buildable mask — `width × height` bytes
  (10 KB for 100×100).
- **Load Time**: All file I/O is synchronous at load time (before the first frame).
  No async loading needed — total file reads < 100 KB.
- **Network**: N/A — single-player, local filesystem only.

## Migration Plan
N/A — greenfield project. The format version starts at 1. When format version
2 is needed (VS-stage), the migration strategy (transform functions or auto-reject)
will be an ADR of its own.

## Validation Criteria
1. GUT test: save a fresh simulation state, load it, run 100 ticks, save again,
   load again — the second load must produce bit-exact state identical to the
   post-100-ticks state (determinism round-trip)
2. GUT test: `int64 → hex_string → int64` for boundary values `0`, `1`,
   `2^53`, `2^63-1`, `2^64-1` — all round-trip exactly
3. GUT test: intentionally corrupt a save blob (truncate JSON, remove a required
   field, mismatch `format_version`) — each case produces the correct `LoadError`
   category and no simulation state is mutated
4. GUT test: load catalog with `strict_mode=true` and a deliberately invalid
   entry (negative cost, `access_cells` overlapping `footprint_cells`) — load
   aborts with validation error
5. GUT test: load catalog with `strict_mode=false` and the same invalid entry —
   load succeeds with the invalid entry skipped and a warning logged
6. Manual: open a saved `.sav.json` in a text editor — the structure is
   self-explanatory (readable field names, pretty-printed JSON)

## Related Decisions
- ADR-0001: DI Container & Scene Bootstrap — defines the `init()` signatures
  that `EquipmentCatalog.init(strict_mode, data_path)` follows
- ADR-0003: GridStateReader Contract — will use the `serialize()`/`deserialize()`
  contract defined here for GridSystem's persistence interface
- `design/gdd/save-load.md` — defines the coordination protocol; this ADR
  defines the data format that protocol operates on
- `design/gdd/equipment-catalog.md` — defines the validation rules; this ADR
  defines the file format and loading contract
- `docs/architecture/architecture.md` — Data Flow section, Save/Load sequence
