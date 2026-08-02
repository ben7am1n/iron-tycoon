# Story 006: Rebuild-on-Load and cell_size Independence

> **Epic**: navigation
> **Status**: Ready
> **Layer**: Core
> **Type**: Integration
> **Estimate**: M — 2 sessions (≤4h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-02

## Context

**GDD**: `design/gdd/navigation.md`
**Requirements**: `TR-NAV-005`, `TR-NAV-008`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0002: Storage Format; ADR-0007: AStarGrid2D Cross-Rebuild Determinism
**ADR Decision Summary**: Navigation contributes **nothing** to the save file — `AStarGrid2D` is a `RefCounted` object rebuilt from GridSystem occupancy on load (load sequence step 4, per save-load.md). Rebuild-on-load is proven correct by the ADR-0007 gate (PASSED 2026-07-21). Navigation is cell-space only by construction: it consumes/exposes grid cells (`Vector2i`) and never touches world coordinates, making it provably independent of `cell_size` (whose value is pinned later at `/create-architecture`).

**Engine**: Godot 4.7.1 | **Risk**: MEDIUM
**Engine Notes**: Room reshape clears all AStarGrid2D solid flags (verified 4.7.1) → requires a full re-init, not incremental push. MVP room is fixed-size, so this is documentation-only; flagged for the future `grid_resized` event. `get_point_path()` (world-space) is forbidden — the cell_size independence test is the black-box proof.

**Control Manifest Rules (Core layer)**:
- Required: Navigation rebuilds `AStarGrid2D` from `GridSystem.is_solid()` occupancy on load; full rebuild during load sequence step 4; incremental sync during live play via `grid_changed` (S1)
- Required: Systems that don't hold serializable state omit `serialize()`/`deserialize()` — Navigation contributes nothing to the save file
- Forbidden: Never serialise `AStarGrid2D` internal state — rebuild from grid occupancy instead

---

## Acceptance Criteria

*From GDD `design/gdd/navigation.md`, scoped to this story:*

- [ ] AC6 GIVEN two Navigation instances with identical solidity but different `cell_size`, WHEN both are queried with the same cell coordinates, THEN outputs are element-for-element identical (black-box proof that `get_point_path()` is not used internally)
- [ ] AC13 GIVEN a solidity state pre-save, WHEN the game saves (Navigation serializes nothing), reloads, and rebuilds `AStarGrid2D` from persisted occupancy, THEN `get_path` for the same from/to returns the pre-save result

---

## Implementation Notes

*Derived from ADR-0002 + ADR-0007 Implementation Guidelines:*

**Rebuild-on-load (Core Rule 6 / ADR-0007):**
- `rebuild(grid: GridStateReader) -> void` — rebuilds `AStarGrid2D` from GridSystem occupancy: configure region, seed all cells' solidity from `is_solid`, then `update()`
- Called by SaveLoad during load sequence step 4 (after GridSystem.deserialize, before MemberSim)
- Navigation serializes nothing — no `serialize()`/`deserialize()` override
- Full rebuild on load; incremental sync via `grid_changed` during live play (Story 004)
- Proven correct by the ADR-0007 gate — this story's AC13 is the round-trip integration test

**cell_size independence (Core Rule 2 / AC6):**
- Navigation's logic consumes only cell indices — never world coordinates
- `get_point_path()` forbidden — the black-box test (two instances, different cell_size, identical outputs) proves it
- `cell_size` may be configured differently per instance; only `region` must match grid dimensions

**Room reshape (documentation-only for MVP):**
- Changing `AStarGrid2D.region` clears all solid flags (verified 4.7.1) — needs full re-init, not incremental push
- MVP room is fixed-size; flagged for future `grid_resized` event (GridSystem/SaveLoad territory)

**Forbidden:**
- Never serialize the AStarGrid2D instance or its internal state
- Never use `get_point_path()` in Navigation's surface

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 005]: the cross-process determinism gate (this story's round-trip depends on it)
- [grid-system story-007]: GridSystem's own serialize/deserialize (the occupancy source)
- [save-load epic]: load orchestration sequence (step 4 ordering), tick-boundary saves

---

## QA Test Cases

*Written by qa-lead at story creation. The developer implements against these — do not invent new test cases during implementation.*

- **AC6**: cell_size 独立性
  - Given: two Navigation instances, identical solidity, different cell_size (e.g. 16 and 32)
  - When: both queried with identical cell coordinates (e.g. get_path((2,2),(8,7)))
  - Then: outputs element-for-element identical
  - Edge cases: multi-cell paths with diagonals; empty-path cases; different region sizes with same solidity pattern

- **AC13**: 存档→重载→重建往返
  - Given: solidity state pre-save, get_path(from, to) returns path P
  - When: save (Navigation serializes nothing) → reload → Navigation.rebuild(occupancy from persisted grid)
  - Then: get_path(from, to) returns P (pre-save result)
  - Edge cases: equal-cost path pair in the occupancy (tie-break must be stable — depends on Story 005 gate); empty path pre-save stays empty post-load

---

## Test Evidence

**Story Type**: Integration
**Required evidence**:
- `tests/integration/navigation/rebuild_load_cell_size_test.gd` — must exist and pass (AC6, AC13)
- Depends on: save-load round-trip harness (or a minimal grid serialize/deserialize fixture)

**Status**: [ ] Not yet created

---

## Dependencies

- Depends on: Story 005 (determinism gate — AC13 assumes tie-break stability), grid-system epic (story-007 — serialize/deserialize)
- Unlocks: SaveLoad implementation (navigation rebuild at load step 4), MemberSim path caching (cached paths valid after load)
