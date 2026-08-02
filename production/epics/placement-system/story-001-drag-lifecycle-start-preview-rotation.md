# Story 001: Drag Lifecycle — Start, Preview, Rotation

> **Epic**: placement-system
> **Status**: Complete
> **Layer**: Core
> **Type**: Logic
> **Estimate**: M — 2 sessions (≤4h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-02

## Context

**GDD**: `design/gdd/placement-system.md`
**Requirements**: `TR-PS-001`, `TR-PS-002`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0001: DI Container & Scene Bootstrap; ADR-0003: GridStateReader Contract
**ADR Decision Summary**: PlacementSystem is a `RefCounted` `SimSystem` with two-phase `init()`/`_post_init()` and a manual `_init()` guard. It receives input through a thin bridge Node as parsed method calls (cells, not pixels). Live preview calls `GridSystem.can_place(def, anchor, rotation)` against real grid state with no mutation; rotation is normalized by PlacementSystem via `rotation = ((rotation + 90) % 360) as Rotation` because GridSystem does not.

**Engine**: Godot 4.7.1 | **Risk**: LOW
**Engine Notes**: `rotation` is typed as a `Rotation` enum (`R0=0, R90=90, R180=180, R270=270`); enum arithmetic promotes to `int` in GDScript 4.x, so the result **must** be cast back: `((rotation + 90) % 360) as Rotation`. The `as Rotation` cast pattern is NOT yet engine-verified in this project's own code — spike it before `/dev-story` implements the formula. `var x := get_*()` inference fails on Variant returns — use explicit `: Type`.

**Control Manifest Rules (Core layer)**:
- Required: Every public method on a SimSystem subclass must guard against use-before-init; `init()` must only be called once per system instance
- Required: Bridges convert screen coordinates to grid cells before calling system methods; GridSystem.world_to_grid() is the conversion
- Forbidden: Never use duck-typing for the grid read surface — consume the typed `GridStateReader`
- Forbidden: Never call `init()` twice on the same system

---

## Acceptance Criteria

*From GDD `design/gdd/placement-system.md`, scoped to this story:*

- [ ] AC1 GIVEN `equipment_id="treadmill_01"` exists in EquipmentCatalog and system is IDLE, WHEN mouse-down on that palette item, THEN `get_definition("treadmill_01")` is called exactly once and no further calls occur for the rest of that drag
- [ ] AC2 GIVEN DRAGGING with a held def, WHEN the mouse enters a new cell, THEN `can_place(def, anchor, rotation)` is called, GridSystem's occupancy is unchanged afterward, and the valid/invalid signal matches the returned bool
- [ ] AC3 GIVEN DRAGGING at R90, WHEN rotate fires, THEN rotation becomes R180 and `get_transformed_cells(def, anchor, R180)` supplies the preview cells (no local transform logic)
- [ ] AC4 GIVEN rotation is corrupted to an out-of-enum value — injected via `_test_set_rotation_unchecked(value: int)` — WHEN rotate fires, THEN the precondition guard's `push_error()` fires *before* any write; rotation is never silently laundered to a valid value
- [ ] AC5 GIVEN rotation=R270, WHEN rotate fires, THEN rotation becomes R0 (wrap-around case)
- [ ] AC15 GIVEN `"nonexistent_id"` is absent from EquipmentCatalog, WHEN mouse-down occurs on a palette item bound to it, THEN `push_error()` fires and state remains IDLE, never entering DRAGGING
- [ ] AC16 GIVEN DRAGGING is already active for drag A, WHEN a second mouse-down occurs on any palette item, THEN it is ignored — no second drag state, drag A's def/rotation/anchor unchanged
- [ ] AC18 GIVEN `speed_multiplier=0` (paused) throughout a drag, WHEN the full lifecycle (start→preview→rotate→commit) executes, THEN PlacementSystem makes zero calls to any TimeSystem API, and the outcome is identical to an unpaused drag
- [ ] AC19 GIVEN a prior drag committed or was cancelled at some non-R0 rotation, WHEN a new drag begins (same or different equipment_id), THEN the new drag's rotation starts at R0, not inherited from the previous drag

---

## Implementation Notes

*Derived from ADR-0001 + ADR-0003 Implementation Guidelines:*

**Drag start (Core Rule 2):**
- `begin_drag(equipment_id: String)` → call `EquipmentCatalog.get_definition(equipment_id)` exactly once; hold the returned def for the whole drag (catalog is immutable by contract)
- Unknown id: `push_error()` and stay IDLE — never enter DRAGGING silently
- Second mouse-down while DRAGGING (Core Rule 11): no-op — no state change, no signal, in-flight drag untouched

**Live preview (Core Rule 3):**
- On each mouse move to a new cell: convert world→cell via `GridSystem.world_to_grid()`, then call `GridSystem.can_place(def, anchor, rotation)` against **real** grid state — never write during preview
- AC2 asserts occupancy is unchanged after the call

**Rotation (Core Rule 4 + Formula):**
- `rotation = ((rotation + 90) % 360) as Rotation` — the `as Rotation` cast is mandatory under strict typing
- **Runtime precondition guard (not debug-only):** validate `rotation in [R0, R90, R180, R270]` before applying the formula. If invalid: `push_error("PlacementSystem: corrupt rotation %d" % rotation)` + early return. `assert()` alone is stripped in exports — the `push_error()` + bail is load-bearing
- Preview cells come exclusively from `GridSystem.get_transformed_cells(def, anchor, rotation)` — never reimplement rotation math or derive `(W, H)` locally
- Each new drag starts at R0 (drag-scoped state, never carried across placements)

**White-box seam (AC4 prerequisite):**
- Expose `_test_set_rotation_unchecked(value: int) -> void` — documented as test-only, must NOT be reachable from any production call site, only from `tests/unit/placement_system/`
- This seam must exist before AC4 is implementable

**Pause independence (AC18):**
- PlacementSystem is purely input-driven; it never reads tick state. No TimeSystem dependency in `init()` signature — the test asserts zero TimeSystem calls structurally

**Testing note (Godot 4.7.1):** Lambda closures do NOT write back to outer-scope locals — use a `RefCounted` counter class with a method callback when asserting "called exactly once" (AC1, AC2).

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 002]: commit-on-drop success path — `instance_id` allocation, `GridSystem.commit()`, `placement_committed` emission
- [Story 003]: rejected drop (`placement_rejected`) and silent cancel paths
- [Story 004]: `instance_id` resume after load (`next_instance_id = max(S) + 1`)
- [Story 005]: relocate flow (`begin_relocate`, same-id re-commit, cancel restore)
- [Story 006]: `is_dragging()` query and cost-scope guarantees
- [Story 007]: bridge Node input forwarding, `InputEventMouseMotion` wiring

---

## QA Test Cases

*Written by qa-lead at story creation. The developer implements against these — do not invent new test cases during implementation.*

- **AC1**: get_definition 恰好调用一次
  - Given: IDLE state, catalog has "treadmill_01"
  - When: begin_drag("treadmill_01") then moving mouse across 3 cells
  - Then: get_definition called exactly 1 time total; a RefCounted counter class (not lambda) asserts count == 1
  - Edge cases: drag with 0 mouse moves still calls it once at start

- **AC2**: 预览不改变占用状态
  - Given: DRAGGING with held def at anchor (3,3)
  - When: mouse enters cell (4,3), can_place returns true
  - Then: can_place(def, anchor, rotation) was called; grid occupancy snapshot identical before/after
  - Edge cases: can_place false path (occupancy still unchanged); move to same cell twice (no double call)

- **AC3**: 旋转使用 GridSystem 变换
  - Given: DRAGGING at R90
  - When: rotate fires
  - Then: rotation == R180; get_transformed_cells(def, anchor, R180) called with the new rotation; no local transform math exists in PlacementSystem
  - Edge cases: rotation change does not re-query catalog

- **AC4**: 损坏 rotation 被守卫拦截
  - Given: `_test_set_rotation_unchecked(1080)` sets a corrupt rotation
  - When: rotate fires
  - Then: push_error() fires; rotation stays 1080 (never laundered to 0); no state write occurred
  - Edge cases: values 45, -90, 1080 — all rejected; valid R0/R90/R180/R270 pass through

- **AC5**: 旋转回绕
  - Given: DRAGGING at R270
  - When: rotate fires
  - Then: rotation == R0
  - Edge cases: 4th press wraps; 8th press wraps again

- **AC15**: 未知 equipment_id
  - Given: IDLE, catalog has no "nonexistent_id"
  - When: begin_drag("nonexistent_id")
  - Then: push_error() fires; state remains IDLE; no preview, no signal
  - Edge cases: subsequent valid begin_drag still works normally

- **AC16**: 拖拽中第二次 mouse-down 被忽略
  - Given: DRAGGING drag A (treadmill_01 at R90)
  - When: begin_drag("bench_01") fires mid-drag
  - Then: no second drag state; drag A's def/rotation/anchor unchanged; no signal emitted
  - Edge cases: second drag with same equipment_id also ignored

- **AC18**: 暂停不影响拖拽
  - Given: speed_multiplier=0 for the entire drag
  - When: full lifecycle (start→preview→rotate→commit) executes
  - Then: zero calls to TimeSystem API (verify with injected spy); outcome identical to unpaused drag
  - Edge cases: pause toggled mid-drag (start unpaused, pause, commit)

- **AC19**: 新拖拽从 R0 开始
  - Given: prior drag ended at R180 (committed)
  - When: new begin_drag starts
  - Then: internal rotation == R0
  - Edge cases: prior drag cancelled at R270 — new drag still R0

---

## Test Evidence

**Story Type**: Logic
**Required evidence**:
- `tests/unit/placement_system/drag_lifecycle_test.gd` — must exist and pass

**Status**: [x] Created and passing — tests/unit/placement_system/drag_lifecycle_test.gd — 91 assertions, 0 failures; full suite 2394/0, exit 0 (2026-08-02)

---

## Dependencies

- Depends on: grid-system epic (stories 001–006 — `can_place`, `commit`, `get_transformed_cells`, `world_to_grid`), equipment-catalog epic (story 001 — `get_definition`)
- Unlocks: Story 002 (commit path), Story 003 (reject/cancel paths)
