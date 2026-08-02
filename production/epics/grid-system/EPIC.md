# Epic: GridSystem

> **Layer**: Foundation
> **GDD**: design/gdd/grid-system.md
> **Architecture Module**: GridSystem — owns `occupant_id` array, `buildable` array, `access_ids` dict, `declared_bounds` per-equipment
> **Status**: Complete
> **Stories**: 8 stories completed — see below

## Stories

| # | Story | Type | Status | ADR |
|---|-------|------|--------|-----|
| 001 | Grid Core Cell Data | Logic | Complete | ADR-0002 |
| 002 | Grid Solidity and Coordinates | Logic | Complete | ADR-0003 |
| 003 | Rotation Transform and Declared Bounds | Logic | Complete | ADR-0003 |
| 004 | Placement Validation — can_place | Logic | Complete | ADR-0003 |
| 005 | Commit, Clear, and Reverse Index | Logic | Complete | ADR-0003 |
| 006 | GridStateReader and GridSnapshot | Logic | Complete | ADR-0003 |
| 007 | Serialization and Deserialization | Integration | Complete | ADR-0002 |
| 008 | Signals, Integration, and Performance | Integration | Complete | ADR-0005 |

## Completion Timeline

| Date | Milestone |
|------|-----------|
| 2026-07-25 | Story 001 complete — Grid Core Cell Data |
| 2026-07-31 | Story 002 complete — Grid Solidity and Coordinates |
| 2026-08-01 | Story 003 complete — Rotation Transform and Declared Bounds |
| 2026-08-02 | Stories 004–008 complete — can_place, commit/clear, GridStateReader/Snapshot, serialization, signals/integration/perf |
| 2026-08-02 | Epic closed — QA sign-off (1040/1040 automated assertions, incl. GRID-008 perf smoke 11.15ms < 50ms) |

## Overview

GridSystem is the single source of spatial truth for the gym floor. It owns cell occupancy (`occupant_id` per cell), multi-cell equipment footprints with rotation mapping, and the `access_ids` set for equipment use positions. Every spatial system depends on GridSystem rather than on each other: PlacementSystem writes to it, Navigation reads solidity to drive AStarGrid2D, ZoneRules reads snapshots to evaluate adjacency, and SelectionSystem resolves "what's at this cell." The system exposes a read-only `GridStateReader` interface shared by both the real grid and speculative `GridSnapshot` views used during placement previews. Without a single arbitrator of "what's where," every consumer would need its own copy of spatial truth — centralizing it here is what makes deterministic saves, correct pathfinding, and consistent zone rules possible.

GridSystem stores only integer `occupant_id` (never equipment type or zone membership) and exposes a typed `GridStateReader` contract that prevents consumers from depending on internal storage details. The write surface (`commit()`, `clear()`, `can_place()`) exists only on `GridSystem`, not on `GridStateReader`, so the type system enforces the read/write split. Rotation transforms use a single union bounding box `(W,H)` shared by both footprint and access cells — a critical safety rule enforced by the `TransformedFootprint` return type.

## Governing ADRs

| ADR | Decision Summary | Engine Risk |
|-----|-----------------|-------------|
| ADR-0001: DI Container & Scene Bootstrap | `SimSystem` base class extends `RefCounted` with manual `_init()` guard (not `@abstract` — non-functional on `RefCounted` in 4.7.1). Two-phase `init()`/`_post_init()`. Injected via `SimulationOrchestrator`. | MEDIUM |
| ADR-0002: Storage Format | Level geometry as custom binary (`.level.bin`). `buildable` array NOT in save file — injected separately by level loader before `deserialize`. `FileAccess.store_*()` returns `bool` since 4.4. | LOW |
| ADR-0003: GridStateReader Contract | `GridStateReader` defines the read-only contract: `is_solid()`, `get_occupant_id()`, `get_access_cells()`, `get_dimensions()`, `get_placed_instances()`. `GridSystem` subclasses it. `PlacedInstance` is a typed `RefCounted` DTO with immutable fields. `GridSnapshot` provides speculative views via delta dictionaries. | LOW |
| ADR-0005: Signal Bus & Event Routing | `grid_changed(footprint_cells_changed: Array[Vector2i], access_cells_changed: Array[Vector2i])` signal (S1) — emitted once per `commit()`/`clear()`, never during drag preview. Subscribers: Navigation, Overlay, SelectionSystem, ZoneRules. | LOW |

## GDD Requirements

| TR-ID | Requirement | ADR Coverage |
|-------|-------------|--------------|
| TR-GS-001 | Origin (0,0) at room bounding-box top-left, col right-positive, row down-positive | ADR-0001 ✅ |
| TR-GS-002 | Orthogonal square grid (CELL_SHAPE_SQUARE); isometric appearance is art-only | ADR-0001 ✅ |
| TR-GS-003 | Two orthogonal dimensions per cell: buildable (bool, static) and occupant_id (int, dynamic) | ADR-0002 ✅ |
| TR-GS-004 | occupant_id stored as PackedInt32Array indexed by flat_index (y*width+x); -1 sentinel for empty | ADR-0002 ✅ |
| TR-GS-005 | buildable stored as PackedByteArray (static, loaded once, read-only during gameplay) | ADR-0002 ✅ |
| TR-GS-006 | access_ids stored as sparse Dictionary (most cells empty, dense array would waste memory) | ADR-0002 ✅ |
| TR-GS-007 | occupant_id and access_ids are two independent fields, must not be merged | ADR-0003 ✅ |
| TR-GS-008 | occupant_id is single-value (mutually exclusive per cell) | ADR-0003 ✅ |
| TR-GS-009 | access_ids is multi-value (non-mutually-exclusive per cell, multiple equipment can share access cell) | ADR-0003 ✅ |
| TR-GS-010 | GridSystem only stores integer occupant_id, never equipment type or zone membership | ADR-0003 ✅ |
| TR-GS-011 | Anchor convention: (0,0) = declared bounding box top-left of canonical(0°) footprint+access union | ADR-0003 ✅ |
| TR-GS-012 | Rotation transform: 4-branch formula using union bounding box (W,H), called once with same (W,H) for footprint AND access | ADR-0003 ✅ |
| TR-GS-013 | footprint and access MUST share same declared bounding box for rotation — using footprint-only bbox causes negative coordinates at 90/270 | ADR-0003 ✅ |
| TR-GS-014 | get_transformed_cells() returns TransformedFootprint composite, never accepts bare cell set | ADR-0003 ✅ |
| TR-GS-015 | can_place() returns one of 5 FAIL codes: OUT_OF_BOUNDS, BLOCKED_BY_ROOM_GEOMETRY, OVERLAPS_EXISTING_EQUIPMENT, ACCESS_OUT_OF_BOUNDS, ACCESS_BLOCKED_BY_ROOM_GEOMETRY | ADR-0003 ✅ |
| TR-GS-016 | access cells NOT included in is_solid; occupancy of access cell by footprint is allowed (access_blocked scenario) | ADR-0003 ✅ |
| TR-GS-017 | commit()/clear() with reverse index; reverse index is mandatory, not optional | ADR-0003 ✅ |
| TR-GS-018 | instance_id >= 0 monotonic integer, never reused within session; PlacementSystem allocates, GridSystem consumes | ADR-0001 ✅ |
| TR-GS-019 | serialize() stores reverse index; deserialize() is two-stage validate-then-commit, all-or-nothing | ADR-0002 ✅ |
| TR-GS-020 | buildable NOT in save file — injected separately by level loader before deserialize | ADR-0002 ✅ |
| TR-GS-021 | grid_changed(footprint_cells_changed, access_cells_changed) emitted once per commit/clear, never on drag preview | ADR-0005 ✅ |
| TR-GS-022 | is_solid(cell) = NOT buildable(cell) OR occupant_id(cell) != -1; access_ids explicitly excluded | ADR-0003 ✅ |
| TR-GS-023 | GridSystem extends RefCounted, NOT Node/Autoload/singleton; injected via SimulationOrchestrator | ADR-0001 ✅ |
| TR-GS-024 | GridStateReader abstract base class shared by GridSystem and GridSnapshot; @abstract methods for read surface | ADR-0003 ✅ |
| TR-GS-025 | ZoneRules.evaluate(snapshot: GridStateReader) typed to abstract base, cannot distinguish real vs speculative | ADR-0003 ✅ |
| TR-GS-026 | Commit-to-grid must succeed at 130 cells MVP; get_snapshot() < 100µs expected | ADR-0003 ✅ |
| TR-GS-027 | Drag smoke test: 300 consecutive get_speculative_snapshot calls must total < 50ms, single max < 5ms | ADR-0003 ✅ |
| TR-GS-028 | Footprint shapes: 1x1, 1x2, 2x2 rectangular AABB only; L-shapes permanently excluded | ADR-0003 ✅ |
| TR-GS-029 | rotation typed as enum Rotation; exhaust 4 branches + assert(false) fallback, never silent fallthrough | ADR-0003 ✅ |
| TR-GS-030 | occupant_id = 0 is legal (first piece placed); truthy check is a bug | ADR-0003 ✅ |

## Definition of Done

This epic is complete when:
- All stories are implemented, reviewed, and closed via `/story-done`
- All acceptance criteria from `design/gdd/grid-system.md` are verified
- All Logic and Integration stories have passing test files in `tests/`
- GridSnapshot performance budgets verified (AC-D5.1–D5.4)
- GridSystem rotation transform correctness verified for all 4 rotation branches
- `PackedInt32Array.duplicate()` performance verified in Godot 4.7.1 headless
- All Visual/Feel and UI stories have evidence docs with sign-off in `production/qa/evidence/`

## Next Step

This epic is **Complete** (all 8 stories closed, 2026-08-02). Next recommended action: `/create-epics layer: core` — unlock PlacementSystem + Navigation (Sprint 3 dependency, gate-check 首批事项 #1).
