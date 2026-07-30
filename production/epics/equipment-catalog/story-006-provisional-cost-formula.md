# Story 006: Provisional Cost Formula

> **Epic**: equipment-catalog
> **Status**: Ready
> **Layer**: Foundation
> **Type**: Logic
> **Estimate**: [hours or t-shirt size — fill before sprint planning]
> **Manifest Version**: 2026-07-23
> **Last Updated**: [set by /dev-story when implementation begins]

## Context

**GDD**: `design/gdd/equipment-catalog.md`
**Requirements**: `TR-EC-008`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0002: Storage Format
**ADR Decision Summary**: provisional_equipment_cost = base_cost + tier_step × (footprint_area − 1). MVP values: base_cost=200, tier_step=150 → 1×1=200, 1×2=350, 2×2=650. This is a TEMPORARY anchor — NOT a final economy balance decision. Marked as provisional in the code; when Economy/Shop GDD (#11/#12) lands, this formula must be deprecated in favor of the official economy system. AC-D.4 is the mandatory re-evaluation checkpoint.

**Engine**: Godot 4.7.1 | **Risk**: LOW
**Engine Notes**: Pure integer arithmetic — no engine API risks. The formula is computed at load time (cost written into EquipmentDef) or at query time (stateless pure function). MVP chooses load-time for simplicity.

**Control Manifest Rules (Foundation layer)**:
- Required: Cost formula must be explicitly marked as PROVISIONAL in comments; no hardcoded per-equipment cost values in JSON (formula-derived)
- Forbidden: Never make cost dependent on anything other than footprint_area in MVP
- Guardrail: cost >= 0 always (cost=0 allowed — free equipment); cost < 0 rejected in validation

---

## Acceptance Criteria

*From GDD `design/gdd/equipment-catalog.md` §Formulas:*

- [ ] AC-D.3 [BLOCKING][Logic] GIVEN footprint_area ∈ {1, 2, 4} AND base_cost=200, tier_step=150, WHEN provisional_equipment_cost computed, THEN outputs 200/350/650 respectively
- [ ] AC-D.4 [ADVISORY][Code Review] GIVEN provisional_equipment_cost formula is still marked as PROVISIONAL, WHEN Economy/Shop GDD (#11/#12) lands, THEN this formula's status must be re-evaluated — must not silently persist as final
- [ ] AC-PROV.1 [BLOCKING][Logic] GIVEN a definition with footprint_area=2, WHEN get_definition(id).cost is queried, THEN the returned cost matches the formula output (350 with MVP defaults), not a hardcoded value from JSON
- [ ] AC-PROV.2 [BLOCKING][Logic] GIVEN base_cost and tier_step are parameterized (not hardcoded), WHEN base_cost=100, tier_step=50, THEN formula outputs 100/150/250 for footprint_area 1/2/4

---

## Implementation Notes

*Derived from ADR-0002 + GDD Formula provisional_equipment_cost:*

```gdscript
# ⚠️ PROVISIONAL — will be replaced when Economy/Shop GDD (#11/#12) lands
# See AC-D.4 in design/gdd/equipment-catalog.md
# See Open Question #2

const PROVISIONAL_BASE_COST := 200
const PROVISIONAL_TIER_STEP := 150

static func compute_provisional_cost(footprint_cells: Array[Vector2i],
                                     base_cost: int = PROVISIONAL_BASE_COST,
                                     tier_step: int = PROVISIONAL_TIER_STEP) -> int:
    var area := footprint_cells.size()
    # area ∈ {1, 2, 4} — guaranteed by footprint shape validation (Story 003)
    return base_cost + tier_step * (area - 1)

# Usage in loader:
# If JSON entry does NOT specify "cost", derive from footprint:
#   cost = compute_provisional_cost(normalized_footprint)
# If JSON entry DOES specify "cost", validate it:
#   validate_cost(cost_value, computed_cost)
```

**Cost validation (from Story 004 pipeline):**
```gdscript
static func validate_cost(cost: int, expected_from_formula: int = -1) -> ValidationResult:
    # cost < 0 → fail
    if cost < 0:
        return ValidationResult.fail("COST_NEGATIVE",
            "equipment cost must be >= 0; got %d" % cost)
    # cost = 0 → allowed (free equipment space)
    return ValidationResult.ok()
```

**When the Economy GDD lands:**
- Replace the `PROVISIONAL_BASE_COST` / `PROVISIONAL_TIER_STEP` constants with Economy system call
- Remove the "⚠️ PROVISIONAL" comment
- AC-D.4 ensures this does not silently persist — it's a mandatory checkpoint

**Key design decisions:**
- Cost is computed at load time and stored in EquipmentDef.cost (not re-computed at query time)
- base_cost and tier_step are parameterized (not hardcoded in the formula body) — AC-PROV.2 verifies this
- The formula intentionally ignores effects/zone_membership — cost is based purely on footprint area in MVP
- cost=0 is VALID (free starter equipment) — validation only rejects negative costs

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 001]: EquipmentDef.cost field — this story computes the value that gets stored there
- [Story 003]: Footprint shape validation — guarantees area ∈ {1,2,4} before this formula runs
- [Not yet designed]: Economy system final pricing model — this is provisional only

---

## QA Test Cases

- **AC-D.3**: 公式输出对应 footprint 面积
  - Given: footprint_area 1 (1×1), 2 (1×2), 4 (2×2) with defaults base=200, tier=150
  - When: compute_provisional_cost()
  - Then: returns 200, 350, 650 respectively
  - Edge cases: verify only 3 possible output values for MVP

- **AC-D.4**: 临时值标记可追溯
  - Given: the formula implementation
  - When: code review
  - Then: function/method has PROVISIONAL marker in comment/doc; constants named with PROVISIONAL_ prefix
  - Edge cases: this is ADVISORY/Code Review — no runtime assertion; the checkpoint is in the Economy GDD landing process

- **AC-PROV.1**: Catalog 返回公式计算的价格
  - Given: loaded definition with 1×2 footprint, no explicit cost in JSON
  - When: get_definition(id).cost
  - Then: returns 350 (formula output), not a hardcoded value
  - Edge cases: verify with explicit cost in JSON (should use explicit value if provided, otherwise formula)

- **AC-PROV.2**: 参数化可调
  - Given: base_cost=100, tier_step=50
  - When: compute_provisional_cost with area 1/2/4
  - Then: returns 100/150/250
  - Edge cases: verify that changing parameters does not require recompilation (constants, not magic numbers)

---

## Test Evidence

**Story Type**: Logic
**Required evidence**:
- `tests/unit/equipment_catalog/catalog_cost_formula_test.gd` — must exist and pass

**Status**: [ ] Not yet created

---

## Dependencies

- Depends on: Story 001 (EquipmentDef class), Story 003 (footprint area guaranteed by validation)
- Unlocks: Shop/Purchase implementation, Economy GDD landing (replaces this formula)
