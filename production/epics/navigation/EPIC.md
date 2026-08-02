# Epic: Navigation

> **Layer**: Core
> **GDD**: design/gdd/navigation.md
> **Architecture Module**: Navigation — owns AStarGrid2D instance (rebuilt on occupancy change)
> **Status**: Complete
> **Stories**: 6 stories created — see below

## Stories

| # | Story | Type | Status | ADR |
|---|-------|------|--------|-----|
| 001 | AStarGrid2D Configuration and Basic Paths | Logic | Complete | ADR-0007 |
| 002 | Diagonal Mode and Corner Clipping Rules | Logic | Complete | ADR-0007 |
| 003 | Path Query Edge Cases | Logic | Complete | ADR-0007 |
| 004 | Solidity Sync via grid_changed | Logic | Complete | ADR-0005, ADR-0007 |
| 005 | Determinism Gate and Congestion Blindness | Integration | Complete | ADR-0007 |
| 006 | Rebuild-on-Load and cell_size Independence | Integration | Complete | ADR-0002, ADR-0007 |

## Overview

Navigation is the deterministic grid pathfinder every simulated member uses to move through the gym. It wraps a single `AStarGrid2D` instance whose solidity mirrors GridSystem's occupancy: given a start cell and a goal cell, it returns the geometric shortest path as an ordered list of grid cells (`Array[Vector2i]`), or an empty array when no path exists. It is deliberately **congestion-blind** — it pathfinds over static occupancy (walls, pillars, placed equipment footprints) only; dynamic member density never enters a path's cost, and choosing *which* equipment to walk toward is MemberSim's job. Navigation owns no serialized game state: the `AStarGrid2D` is rebuilt from GridSystem occupancy on load, so the save file never carries a path or a baked graph.

The AStarGrid2D is configured once at init: `DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES` (diagonal movement only when both flanking orthogonal cells are open — never clipping a solid corner), `HEURISTIC_OCTILE` (the only heuristic consistent with √2 diagonal step cost), `jumping_enabled = false` (no JPS at 130 cells). Solidity sync is event-driven: Navigation subscribes to GridSystem's `grid_changed` (S1) and, for every changed cell, re-pushes `set_point_solid(cell, is_solid(cell))` followed by `AStarGrid2D.update()` — the 4.7.1-corrected ordering, since `set_point_solid` has no immediate effect until `update()` is called. Cross-process determinism was proven by the ADR-0007 gate (10/10 independent headless processes bit-identical, 2026-07-21); the gate test stays in CI and re-runs on every Godot version bump.

## Governing ADRs

| ADR | Decision Summary | Engine Risk |
|-----|-----------------|-------------|
| ADR-0001: DI Container & Scene Bootstrap | Navigation is a `RefCounted` system injected via `SimulationOrchestrator`, extends `SimSystem` with the manual `_init()` guard. No scene-tree presence, no Autoload. | LOW |
| ADR-0002: Storage Format | Navigation contributes NOTHING to the save file — systems that don't hold serializable state omit `serialize()`/`deserialize()`. AStarGrid2D is rebuilt from occupancy on load. | LOW |
| ADR-0003: GridStateReader Contract | `GridSystem.is_solid()` is the truth source Navigation reads during rebuild and incremental sync. Access cells resolve to non-solid automatically via `is_solid`. | LOW |
| ADR-0005: Signal Bus & Event Routing | `grid_changed(footprint_cells_changed, access_cells_changed)` (S1) drives incremental solidity sync during live play. Handler must call `set_point_solid()` for each changed cell, then `update()`. | LOW |
| ADR-0007: AStarGrid2D Cross-Rebuild Determinism | Physical gate test (10 headless processes, bit-identical `get_id_path()`) **PASSED 2026-07-21** — rebuild-on-load proven correct. Gate test stays in CI; lexicographic fallback `_lexicographic_stabilize()` defined but not active. | MEDIUM |

## GDD Requirements

| TR-ID | Requirement | ADR Coverage |
|-------|-------------|--------------|
| TR-NAV-001 | Single AStarGrid2D instance; diagonal_mode = DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES; HEURISTIC_OCTILE | ADR-0007 ✅ |
| TR-NAV-002 | Cell-space only: get_id_path returns Array[Vector2i]; get_point_path forbidden | ADR-0007 ✅ |
| TR-NAV-003 | Solidity sync: subscribe grid_changed, call set_point_solid + update() after push (corrected for 4.7.1) | ADR-0005, ADR-0007 ✅ |
| TR-NAV-004 | Congestion-blind: Congestion(t-1) NEVER enters path cost; influences target selection only | ADR-0007 ✅ |
| TR-NAV-005 | Navigation contributes NOTHING to save file; AStarGrid2D rebuilt from GridSystem occupancy on load | ADR-0002, ADR-0007 ✅ |
| TR-NAV-006 | HARD GATE: AStarGrid2D cross-process tie-break stability unverified — must pass before save-load trustable | ADR-0007 ✅ (PASSED 2026-07-21) |
| TR-NAV-007 | Path step cost: 1.0 orthogonal, sqrt(2) diagonal; octile heuristic admissible and consistent | ADR-0007 ✅ |
| TR-NAV-008 | cell_size independence by construction (only cell indices, no world coords) | ADR-0007 ✅ |

## Definition of Done

This epic is complete when:
- All stories are implemented, reviewed, and closed via `/story-done`
- All acceptance criteria from `design/gdd/navigation.md` are verified
- All Logic and Integration stories have passing test files in `tests/`
- AC7 verified in Godot 4.7.1 headless: `grid_changed` handler calls `set_point_solid()` + `update()`, and only then do paths reflect the change
- AC11 cross-process determinism gate passes (10/10 processes bit-identical) — the ADR-0007 gate test exists in `tests/unit/navigation/` and runs in CI
- AC9 white-box solidity hook exists (per-cell solidity accessor) for the access-cell-never-solid assertion
- All Visual/Feel and UI stories have evidence docs with sign-off in `production/qa/evidence/`

## Next Step

Run `/create-stories navigation` to break this epic into implementable stories.
