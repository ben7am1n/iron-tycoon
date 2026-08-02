# Story 007: Input Bridge and Event Forwarding

> **Epic**: placement-system
> **Status**: Ready
> **Layer**: Core
> **Type**: Integration
> **Estimate**: M — 2 sessions (≤4h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-02

## Context

**GDD**: `design/gdd/placement-system.md`
**Requirements**: `TR-PS-011`, `TR-PS-012`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0001: DI Container & Scene Bootstrap; ADR-0005: Signal Bus & Event Routing
**ADR Decision Summary**: PlacementSystem is `RefCounted` and cannot receive Godot input callbacks (`_input()`/`_unhandled_input()`/`_process()` are Node-only). A thin presentation-layer bridge Node — owned by the composition root (`SimulationOrchestrator`), not the presentation layer — forwards mouse/keyboard events as parsed method calls: `on_drag_start(equipment_id)`, `on_mouse_moved(cell)`, `on_rotate_pressed()`, `on_drop()`, `on_cancel()`, `on_focus_lost()`. The bridge converts screen coordinates to grid cells via `GridSystem.world_to_grid()` — the RefCounted system never sees screen pixels. Mouse-move preview forwarding MUST use `InputEventMouseMotion` events, not `_process()` polling. Bridges use `_unhandled_input()` for mouse, `_unhandled_key_input()` for keyboard shortcuts.

**Engine**: Godot 4.7.1 | **Risk**: LOW
**Engine Notes**: Bridge ownership must be pinned to the composition root — if the presentation-layer bridge Node held the sole strong reference to PlacementSystem, destroying/recreating that Node mid-drag would silently free the RefCounted system and lose DRAGGING state with no warning. Godot 4.6 dual-focus: keyboard shortcuts via `_unhandled_key_input()` (focus-independent), mouse via `_unhandled_input()`.

**Control Manifest Rules (Core layer)**:
- Required: Bridges convert screen coordinates to grid cells before calling system methods; conversion uses `GridSystem.world_to_grid()`
- Required: Bridges use `_unhandled_input()` for mouse events, `_unhandled_key_input()` for keyboard shortcuts (Godot 4.6 dual-focus)
- Required: `SimulationOrchestrator` is the single composition root Node — it owns all systems as RefCounted fields and all bridge Nodes as children

---

## Acceptance Criteria

*From GDD `design/gdd/placement-system.md` + ADR-0005 §5, scoped to this story:*

- [ ] TR-PS-011 GIVEN the composition root scene, WHEN the game boots, THEN `PlacementInputBridge` exists as a child Node of `SimulationOrchestrator` (not the presentation layer) and forwards input events as parsed method calls (grid cells, not screen pixels)
- [ ] TR-PS-012 GIVEN a drag in progress, WHEN the mouse moves, THEN preview forwarding uses `InputEventMouseMotion` handling — `can_place()`/`world_to_grid()` fire only when the hovered cell actually changes, never every frame via `_process()` polling
- [ ] AC (bridge) GIVEN a mouse event at screen position P over the grid, WHEN the bridge receives it, THEN PlacementSystem receives a call with the grid cell `GridSystem.world_to_grid(P)`, never raw screen coordinates
- [ ] AC (bridge) GIVEN the bridge Node is destroyed/recreated (scene transition), WHEN the event arrives, THEN PlacementSystem is NOT silently freed — the composition root retains the strong reference and DRAGGING state survives

---

## Implementation Notes

*Derived from ADR-0001 + ADR-0005 Implementation Guidelines:*

**Bridge contract (ADR-0005 §5):**
- `PlacementInputBridge` extends `Node` (likely `Control` or `Node2D` in the UI layer), created and attached by `SimulationOrchestrator._ready()` — not a separate scene
- Forwards: `on_drag_start(equipment_id)`, `on_mouse_moved(cell)`, `on_rotate_pressed()`, `on_drop()`, `on_cancel()`, `on_focus_lost()`
- Mouse events via `_unhandled_input()` filtering `InputEventMouseButton` / `InputEventMouseMotion`
- Keyboard shortcuts (Esc, R) via `_unhandled_key_input()` — focus-independent per Godot 4.6 dual-focus
- Screen→cell conversion via `GridSystem.world_to_grid()` before any system call

**Mouse-move forwarding (TR-PS-012):**
- Wire preview through `InputEventMouseMotion` handlers, NOT `_process()` polling
- `can_place()`/`world_to_grid()` must fire only when the hovered cell actually changes — matching the States table's "moves to a new cell" granularity (AC2's semantics)
- The bridge may also provide `SceneTree` access for tween creation (`create_tween()` requires a Node context)

**Ownership (pinned):**
- `SimulationOrchestrator` owns PlacementSystem as a RefCounted field AND the bridge Node as a child
- The bridge must NOT be the sole strong reference to PlacementSystem — a scene transition destroying the bridge must not free the system
- Systems live for the session lifetime; no dynamic create/destroy after init

**Testing note:** All PlacementSystem ACs test via direct method calls — the bridge is tested separately with synthetic input events in an integration test (headless SceneTree with a simulated event).

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 001–006]: PlacementSystem logic — the bridge only forwards parsed calls
- [SelectionSystem epic]: SelectionInputBridge (same pattern, different system)
- [Build/Shop UI epic]: palette rendering and affordability gate — the drag *initiation* source
- [Presentation layer]: ghost/preview visuals, placement feedback rendering

---

## QA Test Cases

*Written by qa-lead at story creation. The developer implements against these — do not invent new test cases during implementation.*

- **TR-PS-011**: 桥接节点归属与转发
  - Given: composition root scene booted
  - When: inspected
  - Then: PlacementInputBridge is a child of SimulationOrchestrator; input events arrive as parsed method calls (cells, not pixels)
  - Edge cases: verify no presentation-layer scene owns the bridge; verify all 6 forwarded calls exist

- **TR-PS-012**: MouseMotion 而非 _process 轮询
  - Given: drag in progress
  - When: mouse moves to a new cell
  - Then: can_place/world_to_grid fire once for the cell change; no per-frame polling occurs
  - Edge cases: mouse moves within the same cell (no re-fire); verify via spy counter that _process is not the forwarding path

- **AC (bridge)**: 屏幕坐标转网格单元
  - Given: synthetic InputEventMouseButton at screen position P over the grid
  - When: bridge receives it
  - Then: PlacementSystem receives grid cell world_to_grid(P); raw P never reaches the system
  - Edge cases: P at grid boundary; P outside grid (system receives out-of-bounds cell or cancel as designed)

- **AC (bridge)**: 组合根持有强引用
  - Given: bridge Node destroyed mid-drag (scene transition)
  - When: subsequent event arrives
  - Then: PlacementSystem not freed; DRAGGING state survives; no silent state loss
  - Edge cases: verify via freed-object detection that the system remains alive after bridge free

---

## Test Evidence

**Story Type**: Integration
**Required evidence**:
- `tests/integration/placement_system/input_bridge_test.gd` — must exist and pass (headless SceneTree + synthetic events)

**Status**: [ ] Not yet created

---

## Dependencies

- Depends on: Story 001–006 (the system the bridge forwards to), grid-system (world_to_grid)
- Unlocks: Build/Shop UI drag initiation, SelectionSystem Move handoff (begin_relocate via UI)
