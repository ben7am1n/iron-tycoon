# Epic: PlacementSystem

> **Layer**: Core
> **GDD**: design/gdd/placement-system.md
> **Architecture Module**: PlacementSystem — owns `next_instance_id` counter, drag state (DRAGGING/IDLE), current drag def/anchor/rotation
> **Status**: Ready
> **Stories**: 7 stories created — see below

## Stories

| # | Story | Type | Status | ADR |
|---|-------|------|--------|-----|
| 001 | Drag Lifecycle — Start, Preview, Rotation | Logic | Ready | ADR-0001, ADR-0003 |
| 002 | Commit-on-Drop — Success Path | Logic | Ready | ADR-0001, ADR-0003, ADR-0005 |
| 003 | Rejected Drop and Silent Cancel | Logic | Ready | ADR-0003, ADR-0005 |
| 004 | instance_id Resume After Load | Logic | Ready | ADR-0001, ADR-0002 |
| 005 | Relocate Flow | Logic | Ready | ADR-0001, ADR-0003, ADR-0005 |
| 006 | is_dragging Query and Cost Scope | Logic | Ready | ADR-0001 |
| 007 | Input Bridge and Event Forwarding | Integration | Ready | ADR-0001, ADR-0005 |

## Overview

PlacementSystem is the single interactive surface through which the player builds their gym: it turns a mouse drag into a live preview (via GridSystem's `can_place` against real grid state — never mutating), a rotate key-press into a normalized 0/90/180/270 orientation, and a drop into one atomic, GridSystem-validated commit that either succeeds with a fresh `instance_id` or fails with a specific reason. It is the sole allocator of `instance_id` for every placed piece — GridSystem consumes that id but never generates it — and the sole caller that must normalize rotation before GridSystem ever sees it. Architecturally it is a leaf writer: it owns none of the spatial truth it manipulates (GridSystem owns occupancy) and reads none of the equipment data it places (EquipmentCatalog owns definitions). Its entire job is orchestrating the moment-to-moment drag/rotate/drop interaction against those two systems' already-locked contracts.

Relocation is owned here too: `begin_relocate(instance_id)` clears the piece's occupancy at drag-start (so mid-drag `can_place` previews don't collide with the piece's own old position), re-commits under the **same** `instance_id` on a valid drop, and silently restores the original anchor/rotation on cancel or rejected drop — never destructive to the grid (Pillar 2). PlacementSystem emits `placement_committed` / `placement_rejected` signals for the presentation layer and exposes the synchronous `is_dragging()` query required by Shop/Purchase. It contributes nothing to the save file — its `instance_id` counter is fully re-derived from GridSystem occupancy after load. Input arrives through a thin presentation-layer bridge Node (RefCounted systems cannot receive Godot input callbacks), which converts screen coordinates to grid cells before forwarding parsed method calls.

## Governing ADRs

| ADR | Decision Summary | Engine Risk |
|-----|-----------------|-------------|
| ADR-0001: DI Container & Scene Bootstrap | `SimSystem` base class extends `RefCounted` with manual `_init()` guard (not `@abstract` — non-functional on `RefCounted` in 4.7.1). Two-phase `init()`/`_post_init()`. Input-requiring systems receive input through thin bridge Nodes owned by the composition root. `instance_id` allocated by PlacementSystem, never reused within session. | LOW |
| ADR-0003: GridStateReader Contract | `GridSystem.can_place()` / `commit()` / `clear()` are write methods present only on `GridSystem`, not on `GridStateReader`. PlacementSystem is an authorized writer; it reads occupancy via the granted read surface (`get_occupant_id()`, `get_dimensions()`) for the id-resume scan. `get_speculative_snapshot()` is NOT granted to PlacementSystem for MVP. | LOW |
| ADR-0005: Signal Bus & Event Routing | `placement_committed(instance_id, equipment_id, footprint_cells)` (S3) emitted exactly once after successful commit; `placement_rejected(equipment_id, anchor, rotation, fail_code)` (S4) emitted once per rejected drop; silent cancels emit neither. Signal arity must match exactly at every `.emit()`. Bridge Node uses `_unhandled_input()` for mouse, `_unhandled_key_input()` for keyboard. | LOW |

## GDD Requirements

| TR-ID | Requirement | ADR Coverage |
|-------|-------------|--------------|
| TR-PS-001 | Single interactive surface for BOTH new placement and relocation (begin_relocate) | ADR-0001 ✅ |
| TR-PS-002 | Live preview via GridSystem.can_place against REAL grid state each frame (no mutation) | ADR-0003 ✅ |
| TR-PS-003 | Commit-on-drop: can_place check, allocate instance_id, GridSystem.commit, emit placement_committed | ADR-0001, ADR-0003, ADR-0005 ✅ |
| TR-PS-004 | Rejected drop: no instance_id, no commit, no grid_changed; emit placement_rejected(fail_code) | ADR-0003, ADR-0005 ✅ |
| TR-PS-005 | Silent cancel (Esc/out-of-bounds/focus-loss): no signal at all | ADR-0005 ✅ |
| TR-PS-006 | instance_id allocation: single monotonically-increasing counter; next_instance_id = max(all occupant_ids) + 1 on load | ADR-0001 ✅ |
| TR-PS-007 | PlacementSystem stores NO data in save file; instance_id counter fully reconstructible from GridSystem | ADR-0002 ✅ |
| TR-PS-008 | Relocate: begin_relocate clears occupancy at drag-START, re-commits same id on valid drop, restores on cancel | ADR-0001, ADR-0003, ADR-0005 ✅ |
| TR-PS-009 | Cost/affordability out of scope; PlacementSystem assumes drag is pre-cleared by Shop | ADR-0006 ✅ |
| TR-PS-010 | is_dragging() -> bool public query required by Shop/Purchase | ADR-0001 ✅ |
| TR-PS-011 | PlacementSystem extends RefCounted; bridge Node forwards input events (owned by composition root) | ADR-0001, ADR-0005 ✅ |
| TR-PS-012 | Mouse-move preview forwarding must use InputEventMouseMotion, not _process polling | ADR-0005 ✅ |

## Definition of Done

This epic is complete when:
- All stories are implemented, reviewed, and closed via `/story-done`
- All acceptance criteria from `design/gdd/placement-system.md` are verified
- All Logic and Integration stories have passing test files in `tests/`
- Signal emit arity verified for `placement_committed` (3 args) and `placement_rejected` (4 args) via GUT spy tests (AC21–23)
- White-box seam `_test_set_rotation_unchecked()` exists and is reachable only from `tests/unit/placement_system/` (AC4 prerequisite)
- `instance_id` resume verified against GridSystem post-load state (AC11–13), including the `occupant_id = 0` non-falsy case
- Relocate flow verified cell-for-cell restore on cancel and same-id re-commit on valid drop (AC24–26)
- All Visual/Feel and UI stories have evidence docs with sign-off in `production/qa/evidence/`

## Next Step

Run `/create-stories placement-system` to break this epic into implementable stories.
