# Story 007: Edge Cases — Empty Catalog, Unlock Requirements, and Cost Boundary

> **Epic**: equipment-catalog
> **Status**: Complete
> **Layer**: Foundation
> **Type**: Integration
> **Estimate**: [hours or t-shirt size — fill before sprint planning]
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-02 (EC-007)

## Context

**GDD**: `design/gdd/equipment-catalog.md`
**Requirements**: `TR-EC-001`, `TR-EC-005`, `TR-EC-010`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0001: DI Container & Scene Bootstrap
**ADR Decision Summary**: EquipmentCatalog loaded once at startup via DI injection. No Autoload. Empty catalog is a valid (if degenerate) state — downstream systems must handle it gracefully (e.g. Shop shows "no equipment available"). unlock_requirement stored as opaque string — EquipmentCatalog does NOT validate existence of referenced milestones. Cost=0 allowed (free starter equipment). Catalog frozen after load — no runtime writes.

**Engine**: Godot 4.7.1 | **Risk**: LOW
**Engine Notes**: Empty catalog is not a crash condition — it's a data state. Downstream consumer (Shop/Purchase) is responsible for graceful empty-state presentation. This story verifies the catalog itself handles the edge without crashing.

**Control Manifest Rules (Foundation layer)**:
- Required: Empty catalog must not crash — downstream systems handle empty presentation; DI injection only — no Autoload
- Forbidden: Never validate unlock_requirement references at load time (belongs to /consistency-check)
- Guardrail: Catalog must be usable even with 0 entries — no null-deref on get_all_ids() or get_definition()

---

## Acceptance Criteria

*From GDD `design/gdd/equipment-catalog.md` §Edge Cases:*

- [x] AC-E.2 [BLOCKING][Logic] GIVEN cost = -1, WHEN loaded, THEN validation fails; GIVEN cost = 0, WHEN loaded, THEN loads successfully
- [x] AC-E.3 [ADVISORY][Logic] GIVEN a definition whose unlock_requirement references a non-existent milestone id, WHEN Catalog loads, THEN the definition loads successfully, no error — Catalog does NOT parse this string's semantics (existence check belongs to future /consistency-check)
- [x] AC-E.5 [BLOCKING][Logic] GIVEN all entries fail validation (or data source is empty), WHEN Catalog loads with strict_mode=true, THEN assert() aborts; WHEN loads with strict_mode=false, THEN no crash, push_error() logs, final Catalog has 0 entries
- [x] AC-E.6 [BLOCKING][Integration] GIVEN empty Catalog (0 entries) after freeze(), WHEN get_all_ids() is called, THEN returns empty Array (not null); WHEN get_definition(any_id) is called, THEN push_error() + returns null

---

## Implementation Notes

*Derived from ADR-0001 + GDD Edge Cases + States and Transitions:*

**Cost boundary validation:**
```gdscript
static func validate_cost(cost: int) -> ValidationResult:
    if cost < 0:
        return ValidationResult.fail("COST_NEGATIVE",
            "equipment cost must be >= 0; got %d" % cost)
    # cost >= 0 is valid — 0 = free equipment
    return ValidationResult.ok()
```

**Empty catalog handling:**
```gdscript
# In LoadResult:
static func new_loaded(catalog: EquipmentCatalog, errors: Array[LoadError]) -> LoadResult:
    var r := LoadResult.new()
    # ok = true if at least one definition made it through
    r.ok = catalog.get_all_ids().size() > 0
    r.catalog = catalog
    r.errors = errors
    return r

# In EquipmentCatalog:
func get_all_ids() -> Array[String]:
    if not _is_frozen:
        push_error("EquipmentCatalog: get_all_ids() called before freeze()")
        return []
    return _definitions.keys()  # empty array if no definitions — never null

func get_definition(equipment_id: String) -> EquipmentDef:
    if not _is_frozen:
        push_error("EquipmentCatalog: get_definition() called before freeze()")
        return null
    if not _definitions.has(equipment_id):
        push_error("EquipmentCatalog: no definition for id '%s'" % equipment_id)
        return null
    return _definitions[equipment_id]

func has_definition(equipment_id: String) -> bool:
    return _definitions.has(equipment_id)

func get_definition_count() -> int:
    return _definitions.size()
```

**unlock_requirement handling:**
```gdscript
# unlock_requirement is stored AS-IS from JSON — no parsing, no validation
# Empty string = "always available" (no unlock required)
# Non-empty string = opaque milestone id (validated by Progression/Unlocks GDD #19)

# In loader:
var unlock_req: String = entry.get("unlock_requirement", "")
# Stored directly — no existence check performed
```

**DI injection pattern:**
```gdscript
# In SimulationOrchestrator:
var equipment_catalog: EquipmentCatalog

func _init() -> void:
    equipment_catalog = EquipmentCatalog.new()

func load_catalog(path: String, strict_mode: bool) -> void:
    var result := EquipmentCatalogLoader.load_from_file(path, strict_mode)
    equipment_catalog = result.catalog
    if not result.ok:
        push_warning("SimulationOrchestrator: Catalog loaded with 0 valid entries")
    # Inject into downstream systems
    placement_system.set_catalog(equipment_catalog)
    shop_system.set_catalog(equipment_catalog)
```

**Key design decisions:**
- unlock_requirement is intentionally opaque — Catalog is a data holder, not a validator of cross-system references
- Empty catalog is valid (get_all_ids() returns [], get_definition() returns null) — downstream consumers decide how to present
- cost < 0 is a load-time validation failure; cost = 0 is explicitly allowed (free equipment design space)
- Catalog never loads "partially" in the sense of having a broken internal state — either validates+adds, or skips entirely

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 001–006]: All individual validators — this story handles the composition of failure modes
- [Shop/Purchase]: Empty catalog UI presentation — Catalog only provides data; Shop decides how to say "no equipment available"
- [Progression/Unlocks #19]: unlock_requirement reference validation — handled by /consistency-check in that GDD

---

## QA Test Cases

- **AC-E.2**: cost 边界
  - Given: cost=-1 entry
  - When: load
  - Then: validation fails (COST_NEGATIVE)
  - Given: cost=0 entry
  - When: load
  - Then: loads successfully
  - Edge cases: test with very large positive cost (MAX_INT); test with cost explicitly omitted from JSON (should use formula)

- **AC-E.3**: unlock_requirement 不校验
  - Given: entry with unlock_requirement = "milestone_not_yet_designed"
  - When: load
  - Then: entry loads successfully, no error, no warning
  - Edge cases: test with empty string (should load); test with null/missing field (should default to "")

- **AC-E.5**: 全部失败 → 空 Catalog
  - Given: JSON with 3 entries, all invalid (strict_mode=false)
  - When: load
  - Then: no crash, push_error() fires 3 times, catalog has 0 entries, get_all_ids() = []
  - Given: same JSON with strict_mode=true
  - When: load
  - Then: assert() aborts on first invalid entry

- **AC-E.6**: 空 Catalog 安全查询
  - Given: catalog with 0 entries after freeze()
  - When: get_all_ids(), get_definition("any"), has_definition("any"), get_definition_count()
  - Then: get_all_ids() = [] (not null), get_definition() = null + push_error(), has_definition() = false, get_definition_count() = 0
  - Edge cases: verify no crash on any query; verify push_error messages are informative

---

## Test Evidence

**Story Type**: Integration
**Required evidence**:
- `tests/integration/equipment_catalog/catalog_edge_cases_test.gd` — must exist and pass

**Status**: [x] Implemented — 2026-08-02 (EC-007)

**Test evidence** (full suite 967/967, was 878 after EC-004 + 25 from EC-006):

- `tests/integration/equipment_catalog/catalog_edge_cases_test.gd` — **61 assertions, 0 failures** (integration test through the FULL loader path, not just individual validators):
  - **AC-E.2** (cost boundary): `cost_negative.catalog.json` → ok=false, 1 error, COST_NEGATIVE code + value in message, catalog 0 entries; `cost_zero.catalog.json` → ok=true, cost=0 round-trips; `cost_max_int.catalog.json` → ok=true, MAX_INT (2147483647) accepted — no upper bound; `cost_omitted.catalog.json` → ok=true, cost=200 = formula output for 1×1 (EC-006 contract: missing cost → `EquipmentCostFormula.compute_provisional_cost(normalized footprint)`). Direct `validate_cost(-1/0/MAX_INT)` unit-level checks.
  - **AC-E.3** (advisory, unlock opaque): `unlock_opaque.catalog.json` → loads ok, unlock_requirement `"milestone_not_yet_designed"` stored AS-IS; subprocess probe proves NO `push_error` (no ERROR:) and NO warning (no WARNING:) fired; `unlock_null_missing.catalog.json` → null and missing field both default to `""`.
  - **AC-E.5** (all-fail → empty catalog): `all_cost_negative.catalog.json` (3 entries, costs -1/-5/-10) with strict_mode=true → assert fires on FIRST invalid entry `neg_one` (subprocess probe, `COST_NEGATIVE` in message); strict_mode=false → NO crash, `push_error()` fires exactly 3 times (one per excluded entry), final catalog has 0 entries, ok=false. Empty data source `empty_equipment.catalog.json` (`{"equipment": []}`) → ok=false, no errors, empty-but-frozen queryable catalog; strict=true on empty source is a no-op (no entries to fail).
  - **AC-E.6** (empty catalog safe queries): get_all_ids() → non-null `[]`, has_definition(any) → false, get_definition(any) → null + push_error naming the unknown id (subprocess probe), no crash on any query.
  - **Deviation (reviewer note)**: the story sketch's `get_definition_count()` is NOT implemented — it conflicts with Story 001's AC-C.8 test, which pins the public API to EXACTLY 3 read-only queries via `get_script_method_list()`; the BLOCKING AC-E.6 text only requires `get_all_ids()`/`get_definition()`, both covered. See docs/tech-debt-register.md.
- Updated `tests/unit/equipment_catalog/catalog_pipeline_strict_mode_test.gd` (52 → 55 assertions): the `pipeline_multi_failure.catalog.json` fixture's cost=-1 now contributes a THIRD error (COST_NEGATIVE) — the fixed pipeline order FOOTPRINT_EMPTY → ACCESS_COUNT → COST_NEGATIVE matches this story's QA case exactly. This is the observable EC-004 explicitly deferred to EC-007 ("pipeline_multi_failure fixture 的负数 cost 暂不产生 COST_NEGATIVE（Story 007 加入）").

---

## Dependencies

- Depends on: Story 001 (Catalog container), Story 002 (loading), Story 003–006 (all validators), Story 004 (pipeline with strict_mode)
- Unlocks: Shop/Purchase implementation (consumes Catalog safely even when empty), Progression/Unlocks design
