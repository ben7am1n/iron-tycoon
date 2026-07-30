# Story 007: Edge Cases — Empty Catalog, Unlock Requirements, and Cost Boundary

> **Epic**: equipment-catalog
> **Status**: Ready
> **Layer**: Foundation
> **Type**: Integration
> **Estimate**: [hours or t-shirt size — fill before sprint planning]
> **Manifest Version**: 2026-07-23
> **Last Updated**: [set by /dev-story when implementation begins]

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

- [ ] AC-E.2 [BLOCKING][Logic] GIVEN cost = -1, WHEN loaded, THEN validation fails; GIVEN cost = 0, WHEN loaded, THEN loads successfully
- [ ] AC-E.3 [ADVISORY][Logic] GIVEN a definition whose unlock_requirement references a non-existent milestone id, WHEN Catalog loads, THEN the definition loads successfully, no error — Catalog does NOT parse this string's semantics (existence check belongs to future /consistency-check)
- [ ] AC-E.5 [BLOCKING][Logic] GIVEN all entries fail validation (or data source is empty), WHEN Catalog loads with strict_mode=true, THEN assert() aborts; WHEN loads with strict_mode=false, THEN no crash, push_error() logs, final Catalog has 0 entries
- [ ] AC-E.6 [BLOCKING][Integration] GIVEN empty Catalog (0 entries) after freeze(), WHEN get_all_ids() is called, THEN returns empty Array (not null); WHEN get_definition(any_id) is called, THEN push_error() + returns null

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

**Status**: [ ] Not yet created

---

## Dependencies

- Depends on: Story 001 (Catalog container), Story 002 (loading), Story 003–006 (all validators), Story 004 (pipeline with strict_mode)
- Unlocks: Shop/Purchase implementation (consumes Catalog safely even when empty), Progression/Unlocks design
