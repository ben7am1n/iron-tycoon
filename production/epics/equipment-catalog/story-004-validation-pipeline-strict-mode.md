# Story 004: Validation Pipeline, strict_mode, and Duplicate ID Detection

> **Epic**: equipment-catalog
> **Status**: Complete
> **Layer**: Foundation
> **Type**: Logic
> **Estimate**: [hours or t-shirt size — fill before sprint planning]
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-02

## Context

**GDD**: `design/gdd/equipment-catalog.md`
**Requirements**: `TR-EC-004`, `TR-EC-005`, `TR-EC-006`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0001: DI Container & Scene Bootstrap, ADR-0002: Storage Format
**ADR Decision Summary**: strict_mode injectable boolean controls debug-abort vs release-skip-and-push_error behavior. Duplicate id detection: first occurrence kept, subsequent occurrences treated as validation failures. Catalog loads entirely or with individual exclusions — never a partial-catalog half-loaded state. strict_mode parameter injected (not OS.is_debug_build() check) so GUT tests can deterministically cover both branches.

**Engine**: Godot 4.7.1 | **Risk**: LOW
**Engine Notes**: assert() is compile-time removed in release builds — strict_mode=true paths must use assert() which is zero-cost in production. strict_mode=false paths use push_error() + skip, which has negligible cost at startup.

**Control Manifest Rules (Foundation layer)**:
- Required: strict_mode injected as constructor parameter, not read from OS/ProjectSettings; all validation errors produce LoadError objects with id + rule reference
- Forbidden: Never use OS.is_debug_build() to control validation behavior; never produce a half-loaded Catalog state
- Guardrail: LoadResult must contain both the catalog (with valid entries) AND the list of errors (for logging/diagnostics)

---

## Acceptance Criteria

*From GDD `design/gdd/equipment-catalog.md`, scoped to this story:*

- [x] AC-E.1 [BLOCKING][Logic] GIVEN two equipment definitions sharing the same id (test fixture guarantees load order: A before B), WHEN Catalog loads, THEN final Catalog has A's definition under that id, B is treated as validation failure
- [x] AC-PIPELINE.1 [BLOCKING][Logic] GIVEN a catalog JSON with 1 valid entry + 1 invalid entry, WHEN loaded with strict_mode=false, THEN LoadResult.ok == true, catalog contains 1 definition, errors array has 1 entry
- [x] AC-PIPELINE.2 [BLOCKING][Logic] GIVEN same JSON, WHEN loaded with strict_mode=true, THEN assert() aborts on the invalid entry (never reaches freeze)
- [x] AC-PIPELINE.3 [BLOCKING][Integration] GIVEN a definition with multiple validation failures (e.g. empty footprint AND 2 access cells), WHEN validated, THEN all failures are reported in deterministic order (footprint → access → …), NOT just the first — see Decisions note #1 for the AC-text/QA resolution

---

## Implementation Notes

*Derived from ADR-0001 + ADR-0002 + GDD Core Rule 6 + Edge Cases:*

**Validation pipeline with strict_mode branching:**
```gdscript
static func load_from_file(path: String, strict_mode: bool) -> LoadResult:
    # ... JSON parse, schema check (from Story 002) ...
    
    var catalog := EquipmentCatalog.new()
    var errors: Array[LoadError] = []
    var seen_ids: Dictionary = {}  # id -> bool, for duplicate detection
    
    for entry in data.equipment:
        var entry_id: String = entry.get("id", "")
        
        # Step 0: Duplicate id check
        if seen_ids.has(entry_id):
            var err := LoadError.new("DUPLICATE_ID",
                "Duplicate equipment id '%s'; first occurrence kept" % entry_id)
            errors.append(err)
            if strict_mode:
                assert(false, "EquipmentCatalog: %s" % err.message)
            continue  # skip this entry
        
        seen_ids[entry_id] = true
        
        # Step 1: Normalize (Story 002)
        var norm := normalize_anchor(_cells_from_json(entry.footprint_cells),
                                     _cells_from_json(entry.access_cells))
        # Replace with normalized cells for subsequent steps
        entry["footprint_cells"] = norm["footprint"]
        entry["access_cells"] = norm["access"]
        
        # Step 2-4: Validate (Story 003 + Story 005)
        var errors_for_this := _validate_all(entry)
        
        if errors_for_this.is_empty():
            # All validations passed
            catalog._add_definition(_build_equipment_def(entry))
        else:
            errors.append_array(errors_for_this)
            if strict_mode:
                var msg := "EquipmentCatalog: failed to load '%s':" % entry_id
                for e in errors_for_this:
                    msg += "\n  %s: %s" % [e.category, e.message]
                assert(false, msg)
            else:
                push_error("EquipmentCatalog: skipping '%s' — %d validation error(s)" %
                    [entry_id, errors_for_this.size()])
    
    catalog._freeze()
    return LoadResult.new(catalog, errors)

static func _validate_all(entry: Dictionary) -> Array[LoadError]:
    # Returns empty array if all pass, or array of errors
    # Checks in deterministic order — first failure reported per sub-validator
    var errors: Array[LoadError] = []
    var entry_id: String = entry["id"]
    
    # Footprint shape
    var r := validate_footprint_shape(entry["footprint_cells"])
    if not r.ok:
        errors.append(LoadError.new(entry_id, r.category, r.message))
    
    # Access cells
    r = validate_access_cells(entry["access_cells"], entry["footprint_cells"])
    if not r.ok:
        errors.append(LoadError.new(entry_id, r.category, r.message))
    
    # Use-duration fields (Story 005)
    r = validate_use_duration(entry)
    if not r.ok:
        errors.append(LoadError.new(entry_id, r.category, r.message))
    
    # Cost
    r = validate_cost(entry.get("cost", -1))
    if not r.ok:
        errors.append(LoadError.new(entry_id, r.category, r.message))
    
    return errors

# strict_mode is a parameter of load_from_file(), NOT derived from OS/ProjectSettings:
# ✅ correct: load_from_file(path, strict_mode)  — caller controls
# ❌ wrong:   if OS.is_debug_build(): ...        — test can't control
```

**LoadResult DTO:**
```gdscript
class LoadResult extends RefCounted:
    var ok: bool  # true if catalog has at least one entry
    var catalog: EquipmentCatalog
    var errors: Array[LoadError]
    
    static func fail(category: String, message: String) -> LoadResult:
        var r := LoadResult.new()
        r.ok = false
        r.catalog = EquipmentCatalog.new()  # empty catalog
        r.catalog._freeze()
        r.errors = [LoadError.new("", category, message)]
        return r
    
    static func new_loaded(catalog: EquipmentCatalog, errors: Array[LoadError]) -> LoadResult:
        var r := LoadResult.new()
        r.ok = catalog.get_all_ids().size() > 0
        r.catalog = catalog
        r.errors = errors
        return r
```

**LoadError DTO:**
```gdscript
class LoadError extends RefCounted:
    var equipment_id: String
    var category: String
    var message: String
    
    func _init(p_id: String, p_category: String, p_message: String) -> void:
        equipment_id = p_id
        category = p_category
        message = p_message
```

**Key design decisions:**
- Duplicate id detection is the FIRST check (before normalization) — prevents wasted work
- _validate_all collects ALL errors per entry, not first-only (unlike individual validators which early-exit)
- strict_mode controls whether a single bad entry aborts: true = assert(false) on first bad entry; false = skip + push_error + continue
- LoadResult.ok is true if catalog has ≥1 entry — empty catalog for FILE_NOT_FOUND / all-entries-failed
- The `seen_ids` dict is a design choice: duplicate id is not a "validation error" per se, but the consequence (second occurrence treated as failure) matches the validation failure path

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 002]: JSON parsing and file reading — this story receives parsed data
- [Story 003]: Individual validators (footprint shape, access cells) — this story orchestrates them
- [Story 005]: use-duration validator implementation — consumed by _validate_all but defined separately
- [Story 006]: Cost validator implementation
- [Story 007]: Edge case — empty catalog (all entries fail), unlock_requirement handling

---

## QA Test Cases

- **AC-E.1**: 重复 id → 首次保留，后续失败
  - Given: two entries both with id="treadmill" (fixture guarantees A first, B second)
  - When: load with strict_mode=false
  - Then: Catalog contains A's definition under "treadmill"; errors array has DUPLICATE_ID for B
  - Edge cases: test with strict_mode=true (should abort on B); test with 3 duplicates (only first kept)

- **AC-PIPELINE.1**: 1 合法 + 1 非法 → partial load (strict_mode=false)
  - Given: entry A (valid) + entry B (invalid footprint), strict_mode=false
  - When: load_from_file()
  - Then: LoadResult.ok == true, catalog has A only, errors array has 1 error for B
  - Edge cases: test with all valid entries → 0 errors; test with all invalid → ok=false, empty catalog

- **AC-PIPELINE.2**: 1 合法 + 1 非法 → abort (strict_mode=true)
  - Given: same JSON as AC-PIPELINE.1, strict_mode=true
  - When: load_from_file()
  - Then: assert() aborts — never reaches _freeze()
  - Edge cases: verify assert message contains the failing entry id

- **AC-PIPELINE.3**: 多重校验失败 → 都报告
  - Given: entry with empty footprint AND 2 access cells AND negative cost
  - When: _validate_all()
  - Then: returns 3 errors (FOOTPRINT_EMPTY, ACCESS_COUNT, COST_NEGATIVE) — NOT just the first
  - Edge cases: verify error order is deterministic (same input → same error order every run)

---

## Test Evidence

**Story Type**: Logic
**Required evidence**:
- `tests/unit/equipment_catalog/catalog_pipeline_strict_mode_test.gd` — must exist and pass

**Status**: [x] Created and passing (2026-08-02)

**Test Evidence**: Full suite 878/878 (was 824). New files:
- `tests/unit/equipment_catalog/catalog_pipeline_strict_mode_test.gd` — 52 assertions, 0 failures. AC-E.1 (duplicate id: first kept, second DUPLICATE_ID; 3-duplicate edge keeps only first; strict probe asserts on duplicate; non-strict probe push_error + KEPT_COST proves A won), AC-PIPELINE.1 (1 valid + 1 invalid → ok=true, 1 def, 1 error; all-valid → 0 errors; all-invalid → ok=false empty catalog), AC-PIPELINE.2 (strict probe: assert fires, message names `l_shape_rack` + FOOTPRINT_NOT_RECTANGULAR, probe completes after the aborted frame — freeze never reached), AC-PIPELINE.3 (empty footprint + 2 access → `_validate_all` returns both failures FOOTPRINT_EMPTY + ACCESS_COUNT, deterministic order across runs; loader path records both).
- `tests/unit/equipment_catalog/catalog_pipeline_strict_mode_probe.gd` — subprocess probe (not a _test.gd): `strict_duplicate_id` + `strict_invalid_entry` + `nons_duplicate_keeps_first` modes, same pattern as the Story 003 probe (9th use of the subprocess-isolation pattern).
- `tests/unit/equipment_catalog/fixtures/*.catalog.json` — 4 new committed fixtures (duplicate_id, duplicate_id_three, pipeline_one_valid_one_invalid, pipeline_multi_failure).

**Decisions recorded at close**:
1. **AC-PIPELINE.3 interpretation — all failures reported, deterministic order.** The AC text says "only the FIRST failure is reported", but the story's own QA Test Cases section says "returns 3 errors (FOOTPRINT_EMPTY, ACCESS_COUNT, COST_NEGATIVE) — NOT just the first" and the implementation-notes Key design decisions say "_validate_all collects ALL errors per entry, not first-only". Resolved toward the detailed spec (3:1 evidence): `_validate_all` runs every sub-validator in fixed order (footprint shape → access → use-duration → cost) and collects ONE error per FAILING sub-validator — each sub-validator still early-exits at its own first failure. This also satisfies the AC's "(deterministic error ordering)" requirement, which would be meaningless with a single error. Recorded in docs/tech-debt-register.md.
2. **Duplicate id check runs BEFORE structural parsing** (Step 0, story sketch) — `_raw_entry_id()` extracts the raw String id without parsing the entry; a duplicate is skipped entirely (no wasted normalization). Empty ids are deliberately NOT tracked (missing id is a structural INVALID_ENTRY error, not a duplicate).
3. **Non-strict duplicate exclusion fires push_error()** — the GDD Edge Cases say duplicates "走上一条的失败处理路径" (take the same failure path as validation failures), which per AC-C.2/EC-003 decision includes push_error in non-strict mode.
4. **`_validate_all` wired into `_load_single_definition`** replacing the Story 003 first-fail `_validate_definition` call — consequence: the empty_footprint fixture now reports TWO errors (FOOTPRINT_EMPTY + ACCESS_NOT_ADJACENT); the EC-003 test assertion was updated accordingly (67→69 assertions).
5. **Cost / use-duration validators NOT implemented here** — they are out of scope (Story 005/006/007) and remain as documented extension points inside `_validate_all`; the multi_failure fixture's negative cost does NOT yet produce COST_NEGATIVE (that joins in Story 007).

---

## Dependencies

- Depends on: Story 001 (Catalog container), Story 002 (JSON loading + normalization), Story 003 (footprint/access validators), Story 005 (use-duration validator), Story 006 (cost validator)
- Unlocks: Story 007 (edge cases — empty catalog, unlock_requirement)
