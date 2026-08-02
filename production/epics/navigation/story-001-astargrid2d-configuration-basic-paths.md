# Story 001: AStarGrid2D Configuration and Basic Paths

> **Epic**: navigation
> **Status**: Ready
> **Layer**: Core
> **Type**: Logic
> **Estimate**: M — 2 sessions (≤4h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-02

## Context

**GDD**: `design/gdd/navigation.md`
**Requirements**: `TR-NAV-001`, `TR-NAV-002`, `TR-NAV-007`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0007: AStarGrid2D Cross-Rebuild Determinism
**ADR Decision Summary**: One `AStarGrid2D` instance, configured once at init: `region` = GridSystem's bounding box cell-for-cell, `diagonal_mode = DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES`, `default_compute_heuristic = default_estimate_heuristic = HEURISTIC_OCTILE`, `jumping_enabled = false`. Navigation exposes and consumes grid cells (`Vector2i`) backed exclusively by `AStarGrid2D.get_id_path()`; `get_point_path()` (world-space) is forbidden. Step cost: 1.0 orthogonal, √2 diagonal; octile heuristic is the only heuristic consistent with diagonal cost.

**Engine**: Godot 4.7.1 | **Risk**: MEDIUM
**Engine Notes**: `AStarGrid2D` is the 4.x API: `setup()` → `update()`, `find_path()` → `get_id_path()` (returns `Array[Vector2i]`), `diagonals_allowed` → `diagonal_mode`. `class_name` is NOT globally registered under headless project load — reference cross-script classes via `preload` const aliases. `var x := VariantReturningCall()` fails inference — give critical locals explicit `: Type`.

**Control Manifest Rules (Core layer)**:
- Required: `AStarGrid2D` configuration: `DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES`, `HEURISTIC_OCTILE`, matching `cell_size` and `region` to grid dimensions
- Forbidden: Never serialise `AStarGrid2D` internal state — rebuild from grid occupancy on load
- Guardrail: `get_placed_instances()` full scan < 0.1ms for 200 instances on a 10,000-cell grid (adjacent perf baseline; Navigation rebuild is ~130 set_point_solid + 1 update ≈ <1ms)

---

## Acceptance Criteria

*From GDD `design/gdd/navigation.md`, scoped to this story:*

- [ ] AC1 GIVEN an empty grid, WHEN `get_path((2,2),(2,5))` is called, THEN it returns exactly `[(2,2),(2,3),(2,4),(2,5)]`
- [ ] AC2 GIVEN an empty grid, WHEN `get_path((0,0),(3,3))` is called, THEN the returned path has 4 elements (diagonals used), not 7
- [ ] AC15 GIVEN a displacement of dx=3, dy=2 with no obstacles, WHEN the returned path's step costs are summed, THEN total = `2·√2 + 1·1.0` within float tolerance (validates `path_step_cost`)

---

## Implementation Notes

*Derived from ADR-0007 Implementation Guidelines:*

**Init configuration (Core Rule 1):**
- One `AStarGrid2D` instance, configured exactly once:
  - `region = Rect2i` matching GridSystem's bounding box, origin-aligned to GridSystem's `(0,0)`
  - `diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES`
  - `default_compute_heuristic = default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE`
  - `jumping_enabled = false` (no JPS at 130 cells)
- Seed all cells' solidity from `GridSystem.is_solid()` at init, then `update()`

**Cell-space only (Core Rule 2):**
- `get_path(from: Vector2i, to: Vector2i) -> Array[Vector2i]` backed by `AStarGrid2D.get_id_path(from, to)`
- `get_point_path()` is forbidden anywhere in Navigation's surface — this makes Navigation provably independent of `cell_size`
- No caching — every call recomputes (A* over 130 cells is sub-millisecond)

**Step cost (Formula — path_step_cost):**
- `step_cost(a, b) = 1.0` orthogonal, `√2 ≈ 1.41421356` diagonal
- Octile heuristic `h(n) = (dx + dy) + (√2 - 2) · min(dx, dy)` — admissible and consistent, so A* returns provably shortest paths

**Forbidden:**
- Never call `get_point_path()`; never use Manhattan/Euclidean heuristic with diagonal costs (breaks optimality)
- Never serialise the AStarGrid2D instance

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 002]: diagonal flank matrix / corner-clipping rules (DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES semantics)
- [Story 003]: path query edge cases (enclosed target, from==to, out-of-bounds)
- [Story 004]: solidity sync via `grid_changed` (incremental updates + `update()`)
- [Story 005]: determinism gate test and congestion blindness
- [Story 006]: rebuild-on-load and cell_size independence

---

## QA Test Cases

*Written by qa-lead at story creation. The developer implements against these — do not invent new test cases during implementation.*

- **AC1**: 空网格直线路径
  - Given: empty grid (all cells walkable)
  - When: get_path((2,2),(2,5))
  - Then: returns exactly [(2,2),(2,3),(2,4),(2,5)]
  - Edge cases: path length 1 (adjacent cells); reversed direction (from (2,5) to (2,2))

- **AC2**: 对角线使用
  - Given: empty grid
  - When: get_path((0,0),(3,3))
  - Then: path has 4 elements (diagonals used), not 7 (orthogonal-only)
  - Edge cases: verify path cost equals 3·√2 ≈ 4.2426, not 6.0

- **AC15**: 步长成本
  - Given: dx=3, dy=2 displacement, no obstacles
  - When: returned path's step costs summed
  - Then: total = 2·√2 + 1·1.0 within float tolerance
  - Edge cases: pure diagonal (dx=dy) → n·√2; pure orthogonal → n·1.0

---

## Test Evidence

**Story Type**: Logic
**Required evidence**:
- `tests/unit/navigation/config_basic_paths_test.gd` — must exist and pass

**Status**: [ ] Not yet created

---

## Dependencies

- Depends on: grid-system epic (story-002 — `is_solid`; story-006 — `GridStateReader`/dimensions)
- Unlocks: Story 002 (diagonal semantics), Story 003 (edge cases), Story 004 (sync)
