# VERTICAL SLICE - NOT FOR PRODUCTION
# Validation Question: core loop buildable at quality — PlacementSystem (drag-snap + rotate + re-layout)
# Date: 2026-07-19
#
# Faithful to placement-system.md:
#  - Anchor snap: viewport cursor -> grid cell via floor (anchor = top-left local (0,0))
#  - Rotation: cycles 0->90->180->270->0, resolved through UNION-bbox rotation (GridSystem)
#  - Validity: GridSystem.can_place / get_speculative_snapshot (no real state, no signal)
#  - Re-layout: GridSystem.move() wraps clear+commit as ONE grid_changed
#  - Determinism: same (def, cursor, rotation) -> same snapped anchor (pure floor, no RNG)
# Cross-script class_name annotations omitted (GDScript dynamic) for headless parse.

class_name PlacementSystem
extends RefCounted

const ROT_STEP := 90

var _grid
var _catalog

func _init(grid, catalog) -> void:
	_grid = grid
	_catalog = catalog

# Pure: viewport cursor cell -> snapped anchor (top-left local (0,0)).
# Determinism: floor only, no RNG, no state.
func snap_anchor(cursor_cell: Vector2i) -> Vector2i:
	return Vector2i(floor(cursor_cell.x), floor(cursor_cell.y))

func rotate(rotation: int) -> int:
	return (rotation + ROT_STEP) % 360

# Live preview during drag: read-only validity + resolved cells. Never mutates grid.
func preview(def_id: String, cursor_cell: Vector2i, rotation: int) -> Dictionary:
	var def: Dictionary = _catalog.get_definition(def_id)
	var anchor: Vector2i = snap_anchor(cursor_cell)
	return _grid.get_speculative_snapshot(def["footprint_local"], def["access_local"], anchor, rotation)

# Commit a NEW placement (initial build).
func place_new(instance_id: int, def_id: String, cursor_cell: Vector2i, rotation: int) -> bool:
	var def: Dictionary = _catalog.get_definition(def_id)
	var anchor: Vector2i = snap_anchor(cursor_cell)
	return _grid.commit(instance_id, def["footprint_local"], def["access_local"], anchor, rotation)

# Re-layout an EXISTING instance (the core "drag to rearrange" fun action).
# Returns false (and leaves state intact) if the new spot is invalid.
func move_existing(instance_id: int, def_id: String, cursor_cell: Vector2i, rotation: int) -> bool:
	var def: Dictionary = _catalog.get_definition(def_id)
	var anchor: Vector2i = snap_anchor(cursor_cell)
	return _grid.move(instance_id, def["footprint_local"], def["access_local"], anchor, rotation)
