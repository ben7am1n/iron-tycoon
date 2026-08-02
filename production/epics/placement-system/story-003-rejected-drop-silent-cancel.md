# Story 003: Rejected Drop and Silent Cancel

> **Epic**: placement-system
> **Status**: Ready
> **Layer**: Core
> **Type**: Logic
> **Estimate**: M — 2 sessions (≤4h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-02

## Context

**GDD**: `design/gdd/placement-system.md`
**Requirements**: `TR-PS-004`, `TR-PS-005`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0003: GridStateReader Contract; ADR-0005: Signal Bus & Event Routing
**ADR Decision Summary**: A rejected drop (mouse-up over the grid with `can_place` = FAIL) allocates no `instance_id`, calls no `commit()`, fires no `grid_changed`, and emits `placement_rejected(equipment_id, anchor, rotation, fail_code)` carrying one of GridSystem's 5 FAIL codes. A silent cancel (drop outside grid bounds, Escape, or focus loss) ends the drag with **no signal at all**. In both cases nothing was written, so there is nothing to undo — the equipment conceptually returns to the shop.

**Engine**: Godot 4.7.1 | **Risk**: LOW
**Engine Notes**: `placement_rejected` takes 4 args (equipment_id, anchor, rotation, fail_code) — arity must match exactly at every `.emit()` call site. Lambda closures do NOT write back to outer-scope locals — use a `RefCounted` counter class when asserting "neither signal emitted" (AC23).

**Control Manifest Rules (Core layer)**:
- Required: `grid_changed` (S1) never fires during drag preview or on rejected/cancelled drops
- Required: Bridges use `_unhandled_input()` for mouse events, `_unhandled_key_input()` for keyboard shortcuts (Esc)
- Forbidden: Never emit a signal with mismatched arity — GDScript does not check arity at parse time; a mismatch crashes at runtime

---

## Acceptance Criteria

*From GDD `design/gdd/placement-system.md`, scoped to this story:*

- [ ] AC7 GIVEN `can_place`=false for the current cell, WHEN mouse-up, THEN the drag ends with no `instance_id` allocated, no `commit()` call, no `grid_changed`
- [ ] AC8 GIVEN DRAGGING, WHEN mouse-up occurs outside grid bounds, THEN the same no-op outcome as AC7
- [ ] AC9 GIVEN DRAGGING, WHEN Escape is pressed, THEN the same no-op outcome as AC7, regardless of current cell validity
- [ ] AC17 GIVEN a drag is interrupted by a focus-loss/alt-tab event mid-drag, WHEN focus is lost, THEN the drag cancels identically to Escape (no `instance_id`, no `commit()`, no `grid_changed`)
- [ ] AC22 GIVEN a drop over the grid where `can_place()` returns `FAIL(OVERLAPS_EXISTING_EQUIPMENT)`, WHEN the drop resolves, THEN `placement_rejected(equipment_id, anchor, rotation, OVERLAPS_EXISTING_EQUIPMENT)` is emitted exactly once and no `placement_committed` fires
- [ ] AC23 GIVEN a drag that ends via Escape, focus-loss, or a drop outside grid bounds, WHEN it resolves, THEN neither `placement_committed` nor `placement_rejected` is emitted (silent cancel)

---

## Implementation Notes

*Derived from ADR-0003 + ADR-0005 Implementation Guidelines:*

**Rejected drop (Core Rule 6 — sub-case 1):**
- Mouse releases over the grid, `can_place()` returns one of the 5 `PlacementFailCode` values
- Emit `placement_rejected(equipment_id, anchor, rotation, fail_code)` — exactly once, 4 args
- No `instance_id` allocated, no `commit()` call, no `grid_changed` — nothing was written

**Silent cancel (Core Rule 6 — sub-case 2):**
- Triggered by: mouse-up outside grid bounds, Escape, or focus loss (window loses focus, alt-tab, minimized)
- End the drag with no signal at all — neither `placement_committed` nor `placement_rejected`
- Focus-loss must be routed to the same cancel path as Escape (bridge forwards an explicit cancel event)
- Safe by construction: nothing is written to GridSystem until a successful commit

**Fail-code passthrough:**
- `placement_rejected` carries GridSystem's raw `fail_code` (OUT_OF_BOUNDS / BLOCKED_BY_ROOM_GEOMETRY / OVERLAPS_EXISTING_EQUIPMENT / ACCESS_OUT_OF_BOUNDS / ACCESS_BLOCKED_BY_ROOM_GEOMETRY)
- Visual treatment of each code is Presentation layer territory (Congestion/Overlay #8) — out of scope here

**Testing note (Godot 4.7.1):** Use a `RefCounted` counter class spy for both signals when asserting emission counts; lambda closures cannot write back outer locals.

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 001]: drag start, live preview, rotation (feeds the commit decision)
- [Story 002]: successful commit path (the counterpart to the reject path)
- [Story 005]: rejected *relocate* drop — that path is a silent restore to the original anchor, NOT a `placement_rejected` emission
- [Story 007]: bridge Node wiring for the actual input events that trigger cancel

---

## QA Test Cases

*Written by qa-lead at story creation. The developer implements against these — do not invent new test cases during implementation.*

- **AC7**: can_place=false 的拒绝提交
  - Given: DRAGGING, can_place returns false at current cell (e.g. OVERLAPS_EXISTING_EQUIPMENT)
  - When: mouse-up
  - Then: no instance_id allocated; no commit() call; no grid_changed; drag state cleared
  - Edge cases: each of the 5 FAIL codes produces the same no-write outcome

- **AC8**: 网格外释放
  - Given: DRAGGING
  - When: mouse-up at a position outside grid bounds
  - Then: no id, no commit, no grid_changed; no signal
  - Edge cases: drop exactly at the boundary cell (in-bounds side commits or rejects normally)

- **AC9**: Escape 取消
  - Given: DRAGGING (current cell valid or invalid)
  - When: Escape pressed
  - Then: no id, no commit, no grid_changed; no signal; drag cleared
  - Edge cases: Escape while over a valid cell (still silent cancel, not commit)

- **AC17**: 失焦中断
  - Given: DRAGGING mid-drag
  - When: focus-loss event
  - Then: identical to Escape — no id, no commit, no grid_changed; no signal
  - Edge cases: alt-tab vs minimize vs window-deactivate all route to the same path

- **AC22**: placement_rejected 携带 fail_code
  - Given: DRAGGING, can_place returns OVERLAPS_EXISTING_EQUIPMENT
  - When: mouse-up over grid
  - Then: placement_rejected(eq_id, anchor, rotation, OVERLAPS_EXISTING_EQUIPMENT) emitted exactly once; placement_committed never fires
  - Edge cases: verify argument order and that the raw fail_code is passed through unmodified

- **AC23**: 静默取消无信号
  - Given: drag ends via Escape, focus-loss, or out-of-bounds drop
  - When: drag resolves
  - Then: neither placement_committed nor placement_rejected emitted (counter spies both == 0)
  - Edge cases: each cancel trigger tested separately

---

## Test Evidence

**Story Type**: Logic
**Required evidence**:
- `tests/unit/placement_system/reject_cancel_test.gd` — must exist and pass

**Status**: [ ] Not yet created

---

## Dependencies

- Depends on: Story 002 (commit decision point — reject is the FAIL branch)
- Unlocks: Story 005 (relocate cancel/restore shares the no-write discipline)
