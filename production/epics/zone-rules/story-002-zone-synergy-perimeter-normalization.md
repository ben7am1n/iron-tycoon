# Story 002: zone_synergy with Perimeter Normalization

> **Epic**: zone-rules
> **Status**: Ready
> **Layer**: Feature
> **Type**: Logic
> **Estimate**: M — 2 sessions (≤4h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-02

## Context

**GDD**: `design/gdd/zone-rules.md`
**Requirement**: `TR-ZR-004`, `TR-ZR-006`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0003 (GridStateReader Contract)
**ADR Decision Summary**: Adjacency is orthogonal edge-sharing only (no diagonal) — consistent with the Navigation no-corner-cut rule, so synergy geometry matches walkability geometry. `zone_synergy_i = S_max × (1 − e^(−k × r_i))` with `r_i = n_same_i / N_max_i` (perimeter-normalized) — all footprint sizes earn the same synergy for the same proportion of zone-cohesive neighbors.

**Engine**: Godot 4.7.1 | **Risk**: LOW
**Engine Notes**: Determinism — fixed iteration order (ascending instance_id); formulas are order-independent sums but the fixed order is mandated.

**Control Manifest Rules (Feature layer)**:
- Required: stateless pure function; all effects non-negative
- Forbidden: no RNG; no member data
- Guardrail: diminishing returns — synergy never reaches S_max strictly

---

## Acceptance Criteria

*From GDD `design/gdd/zone-rules.md`, scoped to this story:*

- [ ] AC3 GIVEN two same-zone instances touching only diagonally (no shared edge), WHEN `evaluate()` runs, THEN neither counts the other in `n_same_i` (zone_synergy unaffected)
- [ ] AC4 GIVEN a 1×1 instance (N_max=4) with `n_same_i` = 0, 1, 3, WHEN zone_synergy is computed, THEN `r_i` = 0, 0.25, 0.75 and synergy values are 0.0, ≈0.451, ≈0.835 (tol 1e-4); AND for `r_i` = 1.0 (fully surrounded), `zone_synergy_i < 1.0` strictly (never reaches `S_max`)
- [ ] AC4b GIVEN a 2×2 instance (N_max=8) with `n_same_i` = 2 and a 1×1 instance (N_max=4) with `n_same_i` = 1, WHEN zone_synergy is computed, THEN both have `r_i` = 0.25 and produce **identical** synergy values (tol 1e-4). *(Validates perimeter normalization — footprint size does not advantage synergy.)*
- [ ] AC5 [WB] GIVEN a 2×2 instance A and a neighbor B sharing 2 separate edges with A, WHEN `n_same` for A is computed, THEN A excludes its own cells AND counts B exactly once (not per shared edge); AND `N_max_A` = 8 (the 2×2's perimeter cell count)
- [ ] AC9 GIVEN A=`[Strength,Cardio]` adjacent to B=`[Cardio,Social]`, WHEN `evaluate()` runs, THEN A and B count each other (share Cardio — OR-match)
- [ ] AC10 GIVEN A=`[Strength]` adjacent to B=`[Social]` with no shared zone, WHEN `evaluate()` runs, THEN neither counts the other; the pair contributes 0, never negative

---

## Implementation Notes

*Derived from ADR-0003 Implementation Guidelines:*

**Core Rule 5 — zones:**
- Three MVP zones: 力量区 Strength (Sage), 有氧区 Cardio (Sky), 团课/社交区 Social (Peach)
- Equipment with empty `zone_membership` never earns zone_synergy
- `zone_membership` may be an Array; two instances same-zone iff they share ≥ 1 zone (OR-match — AC9)

**Core Rule 6 — adjacency + perimeter normalization:**
- Adjacent iff any footprint cell of one shares an **orthogonal edge** with any footprint cell of the other
- Diagonal (corner-only) touching is NOT adjacency (AC3)
- `n_same_i` counts **distinct neighboring instances** (not shared edges — AC5)
- `N_max_i` = number of distinct in-bounds cells orthogonally adjacent to footprint_cells, excluding own cells. 1×1 → 4, 2×2 → 8
- `r_i = n_same_i / N_max_i`

**Formula (TR-ZR-004):**
- `zone_synergy_i = S_max × (1 − e^(−k × r_i))`, `S_max = 1.0` (0.5–1.5), `k = 2.4`
- Output [0, S_max) — asymptotic, never reaches S_max (AC4: r=1.0 → 0.909 < 1.0)
- Diminishing returns — clustering beyond ~75% perimeter coverage adds almost nothing

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 001]: evaluate() entry point, effect vocabulary, output shape
- [Story 003]: spaciousness formula (adjacent-cell open-space ratio)
- [Story 004]: preview==commit equivalence, invalid-equipment handling

---

## QA Test Cases

*Written by qa-lead at story creation. The developer implements against these — do not invent new test cases during implementation.*

- **AC3**: 对角不邻接
  - Given: two same-zone instances touching only diagonally
  - When: evaluate() runs
  - Then: neither counts the other in n_same_i; zone_synergy unaffected
  - Edge cases: diagonal at corner of 2×2 instance

- **AC4**: 1×1 协同值
  - Given: 1×1 instance (N_max=4), n_same_i = 0, 1, 3
  - When: zone_synergy computed
  - Then: r_i = 0, 0.25, 0.75; synergy = 0.0, ≈0.451, ≈0.835 (tol 1e-4); r=1.0 → < 1.0 strictly
  - Edge cases: fully surrounded (4/4) → 0.909 < 1.0; partial (2/4) → r=0.5

- **AC4b**: 周长归一化
  - Given: 2×2 instance (N_max=8) with n_same=2; 1×1 instance (N_max=4) with n_same=1
  - When: zone_synergy computed
  - Then: both r_i = 0.25; identical synergy values (tol 1e-4)
  - Edge cases: 2×2 with 4/8 vs 1×1 with 2/4 — same r, same synergy

- **AC5**: 邻居去重
  - Given: 2×2 instance A, neighbor B sharing 2 separate edges with A
  - When: n_same for A computed
  - Then: A excludes own cells; counts B exactly once (not per shared edge); N_max_A = 8
  - Edge cases: two separate neighbors each sharing multiple edges

- **AC9**: 多区 OR 匹配
  - Given: A=[Strength,Cardio] adjacent to B=[Cardio,Social]
  - When: evaluate() runs
  - Then: A and B count each other (share Cardio)
  - Edge cases: A=[Strength,Cardio], B=[Cardio] — count; A=[Strength], B=[Cardio,Social] — no count

- **AC10**: 跨区中性
  - Given: A=[Strength] adjacent to B=[Social], no shared zone
  - When: evaluate() runs
  - Then: neither counts the other; pair contributes 0, never negative
  - Edge cases: many cross-zone pairs — all neutral

---

## Test Evidence

**Story Type**: Logic
**Required evidence**:
- `tests/unit/zone_rules/zone_synergy_test.gd` — must exist and pass (AC3, AC4, AC4b, AC5, AC9, AC10)

**Status**: [ ] Not yet created

---

## Dependencies

- Depends on: Story 001 (evaluate entry + effect vocabulary), equipment-catalog epic (`zone_membership` field)
- Unlocks: Story 004 (preview equivalence uses full formula set)
