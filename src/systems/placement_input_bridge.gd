## PlacementInputBridge — the thin input-forwarding Node for PlacementSystem.
##
## Story: placement-system / story-007-input-bridge-event-forwarding.md (PL-007)
## Req:   TR-PS-011 (bridge owned by composition root, forwards parsed method
##        calls — cells not pixels), TR-PS-012 (mouse-move preview via
##        InputEventMouseMotion, never _process() polling)
## ADR:   ADR-0001 §3 (Presentation Bridge Pattern — thin Node owned by the
##        composition root, zero logic, pure forwarding), ADR-0005 §5 (Input
##        Bridge Pattern — _unhandled_input() for mouse, _unhandled_key_input()
##        for keyboard, screen→cell conversion BEFORE any system call)
##
## PlacementSystem is RefCounted and cannot receive Godot input callbacks
## (_input/_unhandled_input/_process are Node-only). This bridge is the
## presentation-layer bridge Node: it converts engine input events into the
## system's parsed method calls and forwards them.
##
## OWNERSHIP (pinned): the bridge is created and attached by
## SimulationOrchestrator (the composition root, ADR-0001 §4) as a child Node —
## NOT a separate scene, NOT owned by the presentation layer. The orchestrator
## holds PlacementSystem as a RefCounted field; this bridge holds a reference
## too, but MUST NEVER be the sole strong reference: if a scene transition
## destroys this Node, PlacementSystem must survive with DRAGGING state intact
## (AC bridge — freed-object detection).
##
## CONTRACT — 6 forwarded methods (ADR-0005 §5 / story-007):
##   on_drag_start(equipment_id)  → PlacementSystem.begin_drag(equipment_id)
##   on_mouse_moved(cell)         → PlacementSystem.on_mouse_moved(cell)
##   on_rotate_pressed()          → PlacementSystem.on_rotate_pressed()
##   on_drop()                    → PlacementSystem.on_drop()
##   on_cancel()                  → PlacementSystem.on_cancel()
##   on_focus_lost()              → PlacementSystem.on_focus_lost()
##
## EVENT ROUTING (Godot 4.6 dual-focus, ADR-0005 §5):
##   - Mouse: _unhandled_input() filtering InputEventMouseButton /
##     InputEventMouseMotion. Screen position → grid cell via
##     GridSystem.world_to_grid() BEFORE any system call — the RefCounted
##     system never sees raw screen pixels (AC bridge).
##   - Keyboard (Esc/R): _unhandled_key_input() — focus-independent.
##   - Focus loss: NOTIFICATION_WM_WINDOW_FOCUS_OUT → on_focus_lost().
##
## TR-PS-012 (no _process polling): mouse-move preview is driven ONLY by
## InputEventMouseMotion events. can_place()/world_to_grid() fire only when
## the hovered cell actually changes — same-cell motion is a silent no-op
## (deduplicated here AND inside PlacementSystem.on_mouse_moved; the States
## table event is "mouse moves to a NEW cell"). There is deliberately NO
## _process() override in this class.
class_name PlacementInputBridge extends Node


## The RefCounted system this bridge forwards to. Injected by the
## composition root. Never null after init(); a null guard keeps the bridge
## safe during scene teardown ordering.
var _system: PlacementSystem

## The GridSystem used for screen→cell conversion (ADR-0005 §5: the bridge
## converts, the system never sees pixels). Injected by the composition root
## alongside the system.
var _grid: GridSystem

## Presentation cell size for world_to_grid() — the project's final value is
## not yet decided (GDD D.4 handoff note: 16 or 32px). The bridge receives it
## from the composition root so GridSystem keeps its "never hardcoded"
## contract; tests may inject any value.
var _cell_size: int = 32

## Last hovered cell forwarded to the system — TR-PS-012 dedupe state.
## Mouse motion within the SAME cell is a silent no-op (no world_to_grid
## result change, no system call). Vector2i.ZERO is the pre-first-move
## sentinel; _has_hovered disambiguates a real hover at (0,0).
var _last_hovered_cell: Vector2i = Vector2i.ZERO
var _has_hovered: bool = false


## Composition-root injection (ADR-0001 §3 init pattern). Stores the system
## and grid references and the presentation cell size. Called once by
## SimulationOrchestrator right after add_child(). A second call re-injects —
## the bridge is stateless besides the dedupe cache, so this is safe (and
## matches how scene-transition rebuilds re-wire the bridge).
func init(system: PlacementSystem, grid: GridSystem, cell_size: int) -> void:
	_system = system
	_grid = grid
	_cell_size = cell_size


# === 6 forwarded calls (ADR-0005 §5 contract) ===

## Drag start — forwarded from the shop palette UI: mouse-down on a palette
## item becomes on_drag_start(equipment_id). The bridge itself does NOT
## derive equipment_id from mouse position (palette → equipment_id mapping is
## the presentation layer's job, out of scope here); it only forwards.
func on_drag_start(equipment_id: String) -> void:
	if _system == null:
		return
	_system.begin_drag(equipment_id)


## Mouse moved to a grid cell — the ONLY cell-typed input the system accepts.
## Callers (this bridge's _unhandled_input) MUST convert screen position to
## cell via world_to_grid() BEFORE calling — the system never sees pixels.
func on_mouse_moved(cell: Vector2i) -> void:
	if _system == null:
		return
	_system.on_mouse_moved(cell)


## Rotate action (R key) during a drag.
func on_rotate_pressed() -> void:
	if _system == null:
		return
	_system.on_rotate_pressed()


## Mouse-up over the grid — commits or rejects/cancels per PlacementSystem
## semantics (success / rejected / silent-cancel by position validity).
func on_drop() -> void:
	if _system == null:
		return
	_system.on_drop()


## Escape key — silent cancel (AC9).
func on_cancel() -> void:
	if _system == null:
		return
	_system.on_cancel()


## Window focus lost mid-drag (alt-tab / deactivate / minimize) — silent
## cancel (AC17).
func on_focus_lost() -> void:
	if _system == null:
		return
	_system.on_focus_lost()


# === Engine event handlers ===

## Mouse routing (ADR-0005 §5): _unhandled_input() filters
## InputEventMouseButton / InputEventMouseMotion. Every position-carrying
## event is converted screen→cell via GridSystem.world_to_grid() BEFORE any
## system call — the RefCounted system never sees raw screen pixels.
##
## Event → action mapping:
##   left button pressed   → treat as hover at the pressed cell (seeds the
##                           first preview cell so a press-then-release drag
##                           previews even without motion)
##   left button released  → on_drop()
##   mouse motion          → hover at the new cell (deduped, TR-PS-012)
func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_forward_hover(mb.position)
			else:
				on_drop()
	elif event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		_forward_hover(mm.position)


## Keyboard routing (Godot 4.6 dual-focus, ADR-0005 §5): Esc and R arrive via
## _unhandled_key_input() — focus-independent, so they work while a UI
## Control has focus. Echo repeats are ignored (a held key must not cancel
## repeatedly).
func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey:
		var key := event as InputEventKey
		if not key.pressed or key.echo:
			return
		if key.keycode == KEY_ESCAPE:
			on_cancel()
		elif key.keycode == KEY_R:
			on_rotate_pressed()


## Focus loss → silent cancel. NOTIFICATION_WM_WINDOW_FOCUS_OUT fires on
## alt-tab / deactivate / minimize even while the window is not focused —
## the drag must not silently continue past a focus change (AC17).
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
		on_focus_lost()


## Screen→cell conversion + TR-PS-012 dedupe. Converts the screen position
## via GridSystem.world_to_grid() and forwards on_mouse_moved(cell) ONLY if
## the hovered cell actually changed — never per-frame, never per-motion
## within the same cell. Out-of-bounds positions yield the raw floor-division
## cell (world_to_grid's documented no-clamp contract); the system's own
## is_in_bounds() drop handling decides cancel vs reject.
func _forward_hover(screen_pos: Vector2) -> void:
	if _system == null or _grid == null:
		return
	var cell: Vector2i = _grid.world_to_grid(screen_pos, _cell_size)
	if _has_hovered and cell == _last_hovered_cell:
		return  # same cell — no re-preview, no system call (TR-PS-012)
	_has_hovered = true
	_last_hovered_cell = cell
	on_mouse_moved(cell)
