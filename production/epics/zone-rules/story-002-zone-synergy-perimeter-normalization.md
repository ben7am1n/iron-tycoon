# Story 002: zone_synergy with Perimeter Normalization

> **Epic**: zone-rules
> **Status**: Complete — 2026-08-03 (QA 终审 PASS, t_3c527da5)
> **Layer**: Feature
> **Type**: Logic
> **Estimate**: M — 2 sessions (≤4h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-03

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

- [x] AC3 GIVEN two same-zone instances touching only diagonally (no shared edge), WHEN `evaluate()` runs, THEN neither counts the other in `n_same_i` (zone_synergy unaffected)
- [x] AC4 GIVEN a 1×1 instance (N_max=4) with `n_same_i` = 0, 1, 3, WHEN zone_synergy is computed, THEN `r_i` = 0, 0.25, 0.75 and synergy values are 0.0, ≈0.451, ≈0.835 (tol 1e-4); AND for `r_i` = 1.0 (fully surrounded), `zone_synergy_i < 1.0` strictly (never reaches `S_max`)
- [x] AC4b GIVEN a 2×2 instance (N_max=8) with `n_same_i` = 2 and a 1×1 instance (N_max=4) with `n_same_i` = 1, WHEN zone_synergy is computed, THEN both have `r_i` = 0.25 and produce **identical** synergy values (tol 1e-4). *(Validates perimeter normalization — footprint size does not advantage synergy.)*
- [x] AC5 [WB] GIVEN a 2×2 instance A and a neighbor B sharing 2 separate edges with A, WHEN `n_same` for A is computed, THEN A excludes its own cells AND counts B exactly once (not per shared edge); AND `N_max_A` = 8 (the 2×2's perimeter cell count)
- [x] AC9 GIVEN A=`[Strength,Cardio]` adjacent to B=`[Cardio,Social]`, WHEN `evaluate()` runs, THEN A and B count each other (share Cardio — OR-match)
- [x] AC10 GIVEN A=`[Strength]` adjacent to B=`[Social]` with no shared zone, WHEN `evaluate()` runs, THEN neither counts the other; the pair contributes 0, never negative

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
  - **QA 回填 (2026-08-03)**: PASS — 1×1 对角对 (1,1)/(2,2) 双方 synergy==0.0；2×2 与角对角 1×1 双方 0.0；阳性对照（同 2×2 + 正交共边 1×1）双方 > 0，证明排除非「全 0 假象」

- **AC4**: 1×1 协同值
  - Given: 1×1 instance (N_max=4), n_same_i = 0, 1, 3
  - When: zone_synergy computed
  - Then: r_i = 0, 0.25, 0.75; synergy = 0.0, ≈0.451, ≈0.835 (tol 1e-4); r=1.0 → < 1.0 strictly
  - Edge cases: fully surrounded (4/4) → 0.909 < 1.0; partial (2/4) → r=0.5
  - **QA 回填 (2026-08-03)**: PASS — r=0 (0/4) → 0.0 精确；r=0.25 (1/4) → 0.451188；r=0.5 (2/4, QA edge) → 0.698806；r=0.75 (3/4) → 0.834701；r=1.0 (4/4) → 0.909282，严格 < S_max=1.0。全部 tol 1e-4

- **AC4b**: 周长归一化
  - Given: 2×2 instance (N_max=8) with n_same=2; 1×1 instance (N_max=4) with n_same=1
  - When: zone_synergy computed
  - Then: both r_i = 0.25; identical synergy values (tol 1e-4)
  - Edge cases: 2×2 with 4/8 vs 1×1 with 2/4 — same r, same synergy
  - **QA 回填 (2026-08-03)**: PASS — 2×2(2/8) 与 1×1(1/4) 均 0.451188，差值 < 1e-4；QA edge 2×2(4/8) 与 1×1(2/4) 均 0.698806 一致。footprint 大小不带来协同优势

- **AC5**: 邻居去重
  - Given: 2×2 instance A, neighbor B sharing 2 separate edges with A
  - When: n_same for A computed
  - Then: A excludes own cells; counts B exactly once (not per shared edge); N_max_A = 8
  - Edge cases: two separate neighbors each sharing multiple edges
  - **QA 回填 (2026-08-03)**: PASS — 1×2 B 与 2×2 A 共享 2 边 → 计一次，r=1/8 → 0.259182（按边计会是 2/8=0.25 → 0.451，数值钉死去重）；独立公式对照 `1−e^(−2.4×1/8)` 精确 1e-9 钉死 N_max_A=8；QA edge 两个 1×2 各共享 2 边 → 各计一次，r=2/8=0.25 → 0.451188

- **AC9**: 多区 OR 匹配
  - Given: A=[Strength,Cardio] adjacent to B=[Cardio,Social]
  - When: evaluate() runs
  - Then: A and B count each other (share Cardio)
  - Edge cases: A=[Strength,Cardio], B=[Cardio] — count; A=[Strength], B=[Cardio,Social] — no count
  - **QA 回填 (2026-08-03)**: PASS — A/B 共享 cardio 互计 0.451188 双方；QA edge1 A=[S,C] vs B=[C] 互计 > 0；QA edge2 A=[Strength] vs B=[Cardio,Social] 双方 0.0

- **AC10**: 跨区中性
  - Given: A=[Strength] adjacent to B=[Social], no shared zone
  - When: evaluate() runs
  - Then: neither counts the other; pair contributes 0, never negative
  - Edge cases: many cross-zone pairs — all neutral
  - **QA 回填 (2026-08-03)**: PASS — A/B 双方 synergy==0.0 且 >= 0 非负；QA edge 三区连排（Strength/Cardio/Social 全跨区邻接）全部 0.0，混合区域从不惩罚

---

## Test Evidence

**Story Type**: Logic
**Required evidence**:
- `tests/unit/zone_rules/zone_synergy_test.gd` — must exist and pass (AC3, AC4, AC4b, AC5, AC9, AC10)

**Status**: [x] Complete — 2026-08-03

`tests/unit/zone_rules/zone_synergy_test.gd` exists and passes: 39/39
assertions standalone (exit 0), covering AC3 (diagonal not adjacent, incl.
2×2 corner-diagonal edge + positive control), AC4 (r=0/0.25/0.5/0.75/1.0 →
0.0/0.451188/0.698806/0.834701/0.909282, all tol 1e-4, r=1.0 strictly
< S_max), AC4b (2×2(2/8) vs 1×1(1/4) identical 0.451188; 4/8 vs 2/4 edge
identical 0.698806), AC5 (1×2 sharing 2 edges counted once → r=1/8;
N_max_A=8 pinned via `1−e^(−2.4×1/8)` at 1e-9; two-neighbor edge), AC9
(multi-zone OR-match both directions + 2 edges), AC10 (cross-zone neutral
0, never negative, incl. 3-zone line), plus Core Rule 5 (empty
zone_membership never earns) and the S_max/k config override seam.
Registered in `tests/headless_runner.gd` TEST_FILES. Full headless suite
run twice independently by QA: 2742 passed / 0 failed both rounds, RESULT
PASSED, exit 0, 0 SCRIPT ERROR, per-file results identical (51 files,
zone_synergy 39/0 both; evaluate_purity 21/0 both — ZR-001 evaluate entry
unbroken). AC13 static scan re-grepped independently by QA: only
get_placed_instances/get_definition, zero forbidden dynamic-state tokens.

---

## Dependencies

- Depends on: Story 001 (evaluate entry + effect vocabulary), equipment-catalog epic (`zone_membership` field)
- Unlocks: Story 004 (preview equivalence uses full formula set)
