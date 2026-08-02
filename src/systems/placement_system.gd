## PlacementSystem — single interactive surface for placing equipment (GDD
## placement-system.md, EPIC placement-system, Stories 001–007).
##
## Turns a mouse drag into a live preview (via GridSystem.can_place against
## real grid state — never mutating), a rotate keypress into a normalized
## 0/90/180/270 orientation, and a drop into one atomic, GridSystem-validated
## commit that either succeeds with a fresh instance_id or fails with a
## specific reason. It is the SOLE allocator of instance_id for every placed
## piece — GridSystem consumes that id but never generates it.
##
## STORY 003 SCOPE (this file's first landing slice): the drop resolution
## contains the full three-way branch required by GDD Core Rule 6 —
##   - rejected drop (mouse-up over the grid, can_place returns one of
##     GridSystem's 5 FailCode values): emits placement_rejected(eq_id,
##     anchor, rotation, fail_code) EXACTLY once, allocates no instance_id,
##     calls no commit(), fires no grid_changed (TR-PS-004, AC7/AC22)
##   - silent cancel (mouse-up outside grid bounds, Escape, or focus loss):
##     ends the drag with NO signal at all — neither placement_committed nor
##     placement_rejected (TR-PS-005, AC8/AC9/AC17/AC23)
##   - successful commit (can_place VALID): allocate id, GridSystem.commit()
##     (GridSystem fires grid_changed), emit placement_committed (Story 002's
##     success path; present here so the decision point is complete)
##
## The drag-lifecycle entry points (begin_drag / on_mouse_moved /
## on_rotate_pressed) and the instance_id counter are Story 001/002/004
## surface; they are implemented to the same contract so the three-way drop
## resolution is testable. Parallel story branches (PL-001/002/004/005/006/
## 007) extend this file; the sprint gate reconciles the union.
##
## Architecture (ADR-0001/0003/0005): extends SimSystem (two-phase
## init()/_post_init(), manual _init() guard on the base). RefCounted — no
## scene-tree presence; input arrives through the presentation-layer bridge
## Node (Story 007) as parsed method calls with grid cells, never pixels.
## placement_committed/placement_rejected are this system's own signals
## (ADR-0005 S3/S4); grid_changed belongs to GridSystem and is only ever
## triggered here indirectly via commit().
class_name PlacementSystem extends SimSystem

## Drag state machine (GDD States and Transitions).
enum DragState { IDLE = 0, DRAGGING = 1 }

## S3 (ADR-0005): emitted exactly once after a successful GridSystem.commit()
## — never on rejected drops, never on silent cancels. 3 args, arity must
## match exactly at every .emit() call site (engine note: GDScript does not
## check arity at parse time; a mismatch crashes at runtime).
signal placement_committed(instance_id: int, equipment_id: String, footprint_cells: Array[Vector2i])

## S4 (ADR-0005): emitted exactly once per REJECTED drop — mouse released
## over the grid and can_place() returned one of GridSystem's 5 FailCode
## values. fail_code is passed through raw, unmodified. 4 args. Silent
## cancels (out-of-bounds drop / Escape / focus loss) emit NOTHING.
signal placement_rejected(equipment_id: String, anchor: Vector2i, rotation: int, fail_code: int)

## GridSystem reference — the ONLY writer PlacementSystem calls (can_place,
## commit, get_transformed_cells, is_in_bounds). Injected via init(), never
## an Autoload (ADR-0001).
var _grid: GridSystem

## EquipmentCatalog reference — get_definition() queried exactly once per
## drag at begin_drag() (GDD Core Rule 2). Injected via init().
var _catalog: EquipmentCatalog

var _state: int = DragState.IDLE
var _equipment_id: String = ""
var _def: EquipmentDef = null
var _anchor: Vector2i = Vector2i.ZERO
## Degree-valued rotation (0/90/180/270), stored as int per the repo-wide
## convention (PlacementRecord.rotation / PlacedInstance.rotation); cast to
## the GridSystem.Rotation enum only at the GridSystem call boundary.
var _rotation: int = 0
## Last cell reported by on_mouse_moved() — the drop resolution point. May be
## out-of-bounds (the OOB drop → silent cancel case, AC8).
var _current_cell: Vector2i = Vector2i.ZERO
## Sole instance_id allocator (GDD Core Rule 7). Incremented ONLY on a
## successful new-placement commit — never at drag-start, never for a
## canceled or failed drag, never for a relocate re-commit. Resume after load
## is Story 004's re-derivation; here it starts at 0 (empty grid).
var _next_instance_id: int = 0


## Two-phase init (ADR-0001): stores typed dependencies. Must be called
## exactly once before any public method. Does not trigger side effects.
func init(grid: GridSystem, catalog: EquipmentCatalog) -> void:
	if not _mark_initialized():
		return
	_grid = grid
	_catalog = catalog


func _post_init() -> void:
	# PlacementSystem emits its own signals and subscribes to nothing
	# (ADR-0005: it triggers grid_changed indirectly via GridSystem.commit()).
	pass


func system_name() -> String:
	return "PlacementSystem"


# === Drag lifecycle (Story 001 surface — minimal contract for the drop
# === resolution; parallel story branches extend the details) ===

## Starts a new-placement drag for [equipment_id] (GDD Core Rule 2, Story
## 001). Queries the catalog exactly once and holds the definition for the
## whole drag. Unknown ids fail loudly and stay IDLE (AC15). A second
## mouse-down while already DRAGGING is a silent no-op (Core Rule 11).
## Each new drag starts at R0 (AC19 — rotation is drag-scoped state).
func begin_drag(equipment_id: String) -> void:
	if not _assert_initialized():
		return
	if _state == DragState.DRAGGING:
		return
	var def: EquipmentDef = _catalog.get_definition(equipment_id)
	if def == null:
		push_error("PlacementSystem: begin_drag() — unknown equipment_id '%s'; staying IDLE." % equipment_id)
		return
	_state = DragState.DRAGGING
	_equipment_id = equipment_id
	_def = def
	_rotation = GridSystem.Rotation.R0
	_anchor = Vector2i.ZERO
	_current_cell = Vector2i.ZERO


## Records the hovered grid cell during a drag (bridge forwards every mouse
## move as a cell — including out-of-bounds cells, which the drop resolution
## needs for the AC8 silent-cancel branch). No grid mutation, no signal.
func on_mouse_moved(cell: Vector2i) -> void:
	if not _assert_initialized():
		return
	if _state != DragState.DRAGGING:
		return
	_current_cell = cell
	_anchor = cell


## Rotate action (GDD rotation_increment_formula, Story 001 AC3/AC5).
## Precondition guard (runtime, not debug-only): corrupt rotation values are
## rejected with push_error() BEFORE any write — never silently laundered to
## a legal value (AC4). The formula itself: rotation' = (rotation + 90) % 360.
func on_rotate_pressed() -> void:
	if not _assert_initialized():
		return
	if _state != DragState.DRAGGING:
		return
	if _rotation not in [GridSystem.Rotation.R0, GridSystem.Rotation.R90, GridSystem.Rotation.R180, GridSystem.Rotation.R270]:
		push_error("PlacementSystem: on_rotate_pressed() — corrupt rotation %d; refusing to launder." % _rotation)
		return
	_rotation = ((_rotation + 90) % 360) as GridSystem.Rotation


# === Drop resolution — the three-way decision (GDD Core Rule 6) ===

## Mouse-up ends the drag. Resolves against the last hovered cell:
##   - cell outside grid bounds        → SILENT CANCEL (no signal, AC8/AC23)
##   - can_place returns a FailCode    → REJECTED: emit placement_rejected
##                                       exactly once, no id, no commit, no
##                                       grid_changed (AC7/AC22)
##   - can_place VALID                 → COMMIT: allocate id, GridSystem.commit()
##                                       (fires grid_changed), emit
##                                       placement_committed (Story 002 path)
## Nothing is written to GridSystem until the VALID branch — safe by
## construction (a canceled/failed drag leaves the grid byte-identical).
func on_drop() -> void:
	if not _assert_initialized():
		return
	if _state != DragState.DRAGGING:
		return

	var cell := _current_cell

	# AC8: drop outside grid bounds → silent cancel. No signal at all.
	if not _grid.is_in_bounds(cell):
		_clear_drag()
		return

	var result: PlacementCheckResult = _grid.can_place(
		_def.footprint_cells, _def.access_cells, cell, _rotation as GridSystem.Rotation
	)

	if not result.valid:
		# AC7/AC22: rejected drop — no instance_id, no commit, no grid_changed;
		# emit placement_rejected exactly once with the RAW fail_code.
		var eq_id := _equipment_id
		var anchor := cell
		var rot := _rotation
		var fail_code := result.fail_code
		_clear_drag()
		placement_rejected.emit(eq_id, anchor, rot, fail_code)
		return

	# Success path (GDD Core Rule 5 / Story 002): allocate id, commit, emit.
	var transformed: TransformedFootprint = _grid.get_transformed_cells(
		_def.footprint_cells, _def.access_cells, cell, _rotation as GridSystem.Rotation
	)
	var instance_id := _next_instance_id
	_next_instance_id += 1
	_grid.commit(instance_id, transformed.footprint_cells, transformed.access_cells, _rotation as GridSystem.Rotation)
	var committed_id := instance_id
	var committed_eq := _equipment_id
	var committed_fp: Array[Vector2i] = transformed.footprint_cells.duplicate()
	_clear_drag()
	placement_committed.emit(committed_id, committed_eq, committed_fp)


# === Cancel paths (silent cancel, TR-PS-005) ===

## Escape pressed (bridge forwards on_cancel from _unhandled_key_input).
## Ends the drag with NO signal at all — regardless of current cell validity
## (AC9). No instance_id, no commit(), no grid_changed.
func on_cancel() -> void:
	if not _assert_initialized():
		return
	_cancel_drag()


## Focus loss mid-drag (window deactivate, alt-tab, minimized). Routed to the
## SAME cancel path as Escape (AC17) — the bridge forwards an explicit cancel
## event; this system treats it identically.
func on_focus_lost() -> void:
	if not _assert_initialized():
		return
	_cancel_drag()


## Shared silent-cancel implementation: clears drag state, emits nothing.
func _cancel_drag() -> void:
	if _state != DragState.DRAGGING:
		return
	_clear_drag()


## Resets all drag-scoped state back to IDLE. No signals, no grid writes.
func _clear_drag() -> void:
	_state = DragState.IDLE
	_equipment_id = ""
	_def = null
	_anchor = Vector2i.ZERO
	_rotation = GridSystem.Rotation.R0
	_current_cell = Vector2i.ZERO
