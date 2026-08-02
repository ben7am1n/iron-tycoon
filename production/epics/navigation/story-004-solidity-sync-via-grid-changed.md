# Story 004: Solidity Sync via grid_changed

> **Epic**: navigation
> **Status**: Complete
> **Layer**: Core
> **Type**: Logic
> **Estimate**: M — 2 sessions (≤4h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-02

## Context

**GDD**: `design/gdd/navigation.md`
**Requirements**: `TR-NAV-003`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0005: Signal Bus & Event Routing; ADR-0007: AStarGrid2D Cross-Rebuild Determinism
**ADR Decision Summary**: Navigation subscribes to GridSystem's `grid_changed(footprint_cells_changed, access_cells_changed)` (S1) during `_post_init()`. On each emission, for every cell in **both** arrays it calls `set_point_solid(cell, GridSystem.is_solid(cell))` — always re-querying `is_solid`, never assuming true/false (the same signal fires for placement and removal). Because `set_point_solid()` does **not** take effect until `update()` is called (corrected for 4.7.1), the handler MUST call `AStarGrid2D.update()` after pushing all solidity changes. Access cells resolve to non-solid automatically via `is_solid` — no access-cell special-casing needed.

**Engine**: Godot 4.7.1 | **Risk**: MEDIUM
**Engine Notes**: **Verified during vertical slice**: `set_point_solid(c, solid)` has NO immediate effect in 4.7.1 — you MUST call `AStarGrid2D.update()` after pushing solidity changes, or paths won't reflect edits. Signal emit arity must match exactly — `grid_changed.emit(fp_cells, ac_cells)` with both args, never `emit(fp_cells + ac_cells)` as one array. Lambda closures do NOT write back to outer-scope locals — use a `RefCounted` counter class for signal-count assertions.

**Control Manifest Rules (Core layer)**:
- Required: `grid_changed` (S1) fires exactly once per `commit()`/`clear()`, never during drag preview; both parameters are `Array[Vector2i]`
- Required: Navigation rebuilds `AStarGrid2D` from `GridSystem.is_solid()` occupancy — incremental sync during live play via `grid_changed` subscription
- Forbidden: Never serialise `AStarGrid2D` internal state

---

## Acceptance Criteria

*From GDD `design/gdd/navigation.md`, scoped to this story:*

- [ ] AC7 GIVEN an open path exists, WHEN `grid_changed` marks a path cell solid and the handler calls `update()` after the solidity push, THEN the new solid cell is excluded on the next `get_path()` query (the handler MUST call `update()` — Navigation does NOT copy Congestion's t-1 lag pattern)
- [ ] AC8 GIVEN `grid_changed` fires for a cell whose solidity did not actually change (same value re-pushed), WHEN it is handled, THEN subsequent `get_path` results are unchanged and no state is corrupted (idempotent no-op)
- [ ] AC9 GIVEN an access cell adjacent to an occupied footprint, WHEN its solidity is checked via the exposed `is_solid` accessor, THEN it is never solid. *(Not pure black-box — requires a test hook exposing per-cell solidity.)*

---

## Implementation Notes

*Derived from ADR-0005 + ADR-0007 Implementation Guidelines:*

**Subscription (ADR-0005):**
- In `_post_init()`: `_grid_system.grid_changed.connect(_on_grid_changed)` — systems live for the session lifetime, so no disconnect needed

**Handler (Core Rule 3 — 4.7.1-corrected):**
```gdscript
func _on_grid_changed(footprint_cells: Array, access_cells: Array) -> void:
    for cell in footprint_cells + access_cells:
        _astar.set_point_solid(cell, _grid_system.is_solid(cell))
    _astar.update()  # MANDATORY — set_point_solid has no effect until update()
```
- Always re-query `GridSystem.is_solid(cell)` — never assume true/false from the signal alone
- Access cells resolve to non-solid automatically via `is_solid` — no special-casing
- Incremental sync only — full rebuild is Story 006 (load path)

**Idempotency (AC8):**
- Re-pushing the same solidity value is a no-op at the AStarGrid2D level; the handler must not corrupt state on redundant emissions
- `grid_changed` can fire for cells whose solidity didn't change (same signal for placement and removal); the handler treats it uniformly

**White-box hook (AC9):**
- Expose per-cell solidity access (e.g. `is_solid(cell) -> bool` delegating to `_astar.is_point_solid`) so tests can assert access cells are never solid — documented as a test hook, not a public API for gameplay consumers

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 001]: init configuration and full-grid solidity seeding
- [Story 006]: full rebuild from occupancy on load (load sequence step 4 — bypasses the signal)
- [Congestion epic]: t-1 lag pattern — Navigation does NOT copy it (explicitly noted in AC7)

---

## QA Test Cases

*Written by qa-lead at story creation. The developer implements against these — do not invent new test cases during implementation.*

- **AC7**: update() 后路径生效
  - Given: open path exists, e.g. get_path((2,2),(2,5)) returns full path
  - When: grid_changed marks (2,4) solid; handler pushes solidity and calls update()
  - Then: next get_path((2,2),(2,5)) excludes (2,4) — reroutes or returns empty if fully blocked
  - Edge cases: WITHOUT calling update(), the new solid cell is still traversable (negative control proving the 4.7.1 behavior)

- **AC8**: 幂等重复推送
  - Given: grid_changed fires for cell X whose solidity is already correct
  - When: handler processes it
  - Then: subsequent get_path results unchanged; no corruption; no exception
  - Edge cases: repeated redundant emissions (10× same cell) produce identical results

- **AC9**: access 单元永不 solid
  - Given: footprint occupied at cells, access cell adjacent (e.g. access at (2,0) next to footprint (0,0),(1,0))
  - When: is_solid accessor called on the access cell
  - Then: returns false (access cells are never solid)
  - Edge cases: access cell adjacent to a wall (still non-solid); multiple equipment sharing access cell

---

## Test Evidence

**Story Type**: Logic
**Required evidence**:
- `tests/unit/navigation/solidity_sync_test.gd` — must exist and pass

**Status**: [x] Created and passing — tests/unit/navigation/solidity_sync_test.gd — 27 assertions, 0 failures; full suite 2394/0, exit 0 (2026-08-02)

---

## Dependencies

- Depends on: Story 001 (AStarGrid2D instance + is_solid access), grid-system epic (grid_changed signal)
- Unlocks: Story 006 (load-path rebuild reuses solidity model)
