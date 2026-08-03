# Story 003: spaciousness Formula

> **Epic**: zone-rules
> **Status**: Complete — 2026-08-03 (QA 终审 PASS, t_aa618b98)
> **Layer**: Feature
> **Type**: Logic
> **Estimate**: S — 1 session (≤2h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-03

## Context

**GDD**: `design/gdd/zone-rules.md`
**Requirement**: `TR-ZR-005`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0003 (GridStateReader Contract)
**ADR Decision Summary**: `spaciousness_i = C_max × (open_adj_i / total_adj_i)`. Reads only static solidity (walls + placed footprints) — zero overlap with Congestion's dynamic member-density field. `total_adj_i == 0` → `spaciousness_i = 0`, never divide-by-zero.

**Engine**: Godot 4.7.1 | **Risk**: LOW
**Engine Notes**: Out-of-bounds cells excluded from `total_adj_i` (not counted as solid or open). `is_solid` from GridStateReader.

**Control Manifest Rules (Feature layer)**:
- Required: stateless pure function; all effects non-negative
- Forbidden: no member data reads (static solidity only)
- Guardrail: no divide-by-zero on total_adj == 0

---

## Acceptance Criteria

*From GDD `design/gdd/zone-rules.md`, scoped to this story:*

- [x] AC6 GIVEN an instance with `total_adj_i = 4, open_adj_i = 2`, WHEN spaciousness is computed, THEN `spaciousness_i == 0.25` exactly (`0.5 × 2/4`)
- [x] AC7 GIVEN an instance whose `footprint ∪ access` yields `total_adj_i == 0`, WHEN spaciousness is computed, THEN `spaciousness_i == 0.0`, no exception
- [x] AC17 GIVEN an instance adjacent to the grid boundary (fewer in-bounds neighbors), WHEN `total_adj_i` is computed, THEN out-of-bounds cells are excluded from `total_adj_i` (not counted as solid or open)

---

## Implementation Notes

*Derived from ADR-0003 Implementation Guidelines:*

**Formula (TR-ZR-005):**
```
spaciousness_i = C_max × (open_adj_i / total_adj_i)
```
- `total_adj_i`: in-bounds cells orthogonally adjacent to i's `footprint_cells ∪ access_cells`, excluding i's own cells (AC17 — out-of-bounds dropped)
- `open_adj_i`: subset where `is_solid == false` (static: walls + placed footprints, NO member data)
- `C_max = 0.5` (0.3–0.8)
- Output [0, C_max]; `total_adj_i == 0` → 0 (guard, AC7)

**Example:** 6 adjacent cells, 4 open → `0.5 × (4/6) = 0.333`

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 001]: evaluate() entry point, effect vocabulary
- [Story 002]: zone_synergy formula
- [Story 004]: preview==commit equivalence, invalid-equipment handling

---

## QA Test Cases

*Written by qa-lead at story creation. The developer implements against these — do not invent new test cases during implementation.*

- **AC6**: 精确值
  - Given: total_adj_i = 4, open_adj_i = 2
  - When: spaciousness computed
  - Then: spaciousness_i == 0.25 exactly (0.5 × 2/4)
  - Edge cases: open_adj = 0 → 0.0; open_adj = total_adj → C_max
  - **QA 回填 (2026-08-03)**: PASS — 1×1 于 10×10 中央、4 邻中 2 邻 solid → spaciousness == 0.25 精确相等（非 approx）；edge1 4 邻全 solid → 0.0；edge2 无 solid → 0.5 == C_max

- **AC7**: 零邻接守卫
  - Given: footprint ∪ access yields total_adj_i == 0
  - When: spaciousness computed
  - Then: spaciousness_i == 0.0, no exception
  - Edge cases: fully walled-in instance (shouldn't occur under placement rules, but must not crash)
  - **QA 回填 (2026-08-03)**: PASS — 1×1 于 1×1 网格（4 邻全部越界）→ total_adj==0 → 0.0 且 evaluate() 正常返回无异常；edge 完全封墙实例（footprint(5,5)+access(5,6) 的全部界内邻格 solid）→ 0.0 无崩溃

- **AC17**: 边界排除
  - Given: instance adjacent to grid boundary
  - When: total_adj_i computed
  - Then: out-of-bounds cells excluded from total_adj_i (not counted solid or open)
  - Edge cases: instance at corner (fewer in-bounds neighbors); edge-aligned access cells
  - **QA 回填 (2026-08-03)**: PASS — 角位 1×1 (0,0) 于 5×5：界内邻仅 (1,0),(0,1) → total_adj==2（OOB 2 格整体剔除）→ 0.5；edge 边缘对齐 access（footprint(0,0)+access(0,1)）→ total_adj==3 → 0.5。若把 OOB 当 solid 计会得 0.25，数值上钉死排除

---

## Test Evidence

**Story Type**: Logic
**Required evidence**:
- `tests/unit/zone_rules/spaciousness_test.gd` — must exist and pass (AC6, AC7, AC17)

**Status**: [x] Complete — 2026-08-03

`tests/unit/zone_rules/spaciousness_test.gd` exists and passes: 18/18
assertions standalone (exit 0), covering AC6 (total_adj=4/open_adj=2 →
0.25 exactly; open_adj=0 → 0.0; open_adj=total_adj → 0.5 == C_max), AC7
(1×1 on 1×1 grid → total_adj==0 → 0.0, no exception; fully walled-in edge
→ 0.0 no crash), AC17 (corner instance total_adj==2 with OOB excluded →
0.5; edge-aligned access total_adj==3 → 0.5), plus dedupe (shared neighbor
cell counted once → 0.5×5/6), static solidity (placed footprint counts
solid for neighbor → 0.375), static-only AC13 re-scan (zero forbidden
member-data / single-cell occupancy tokens), output range [0, C_max] with
non-negative totals, and the inherited ZR-001 entry shape (exact 4 keys,
ascending instance_id order, total == sum).
Registered in `tests/headless_runner.gd` TEST_FILES. Full headless suite
run twice independently by QA on a merge worktree (impl commit c25fad5
merged onto main e61e826): 2760 passed / 0 failed both rounds, RESULT
PASSED, exit 0, 0 SCRIPT ERROR, per-file results identical (53 files;
spaciousness 18/0 both; zone_synergy 39/0 both — ZR-002 unbroken;
evaluate_purity 21/0 both — ZR-001 evaluate entry unbroken). AC13 static
scan re-verified: only get_placed_instances/get_definition/is_solid/
get_dimensions — zero forbidden dynamic-state tokens. Real reader contract
confirmed: GridSystem and GridSnapshot both override is_solid/get_dimensions.

---

## Dependencies

- Depends on: Story 001 (evaluate entry + effect vocabulary), grid-system epic (`is_solid`, `get_dimensions`)
- Unlocks: Story 004 (preview equivalence uses full formula set)
