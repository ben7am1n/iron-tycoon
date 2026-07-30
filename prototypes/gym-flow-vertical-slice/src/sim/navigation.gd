# VERTICAL SLICE - NOT FOR PRODUCTION
# Validation Question: core loop buildable at quality — Navigation (AStarGrid2D wrapper)
# Date: 2026-07-19
#
# Faithful to navigation.md:
#  - solidity sync via GridSystem.is_solid() on every grid_changed cell (re-query, never assume)
#  - NO corner cutting (default AStarGrid2D behavior; we use per-cell set_point_solid)
#  - Navigation does NOT read Congestion (congestion-blind pathfinding)
#  - get_path returns [] when no route exists (caller handles)
# Verified 4.7.1 behavior: set_point_solid() takes effect immediately, no update()/dirty needed.
# NOTE: cross-script class_name type annotations are omitted (GDScript dynamic) to keep
# headless project parse independent of global class_name registration order.

class_name Navigation
extends RefCounted

var _grid
var _astar: AStarGrid2D

func _init(grid) -> void:
	_grid = grid
	_astar = AStarGrid2D.new()
	var r: Rect2i = grid.get_dimensions()
	_astar.region = r
	_astar.cell_size = Vector2i(1, 1)
	_astar.offset = Vector2i(0, 0)
	_astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER   # no corner cutting
	_astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_MANHATTAN
	_astar.default_estimate_heuristic = AStarGrid2D.HEURISTIC_MANHATTAN
	_astar.update()
	for x in range(r.position.x, r.end.x):
		for y in range(r.position.y, r.end.y):
			var c := Vector2i(x, y)
			_astar.set_point_solid(c, _grid.is_solid(c))

func on_grid_changed(footprint_changed: Array, access_changed: Array) -> void:
	for c in footprint_changed + access_changed:
		_astar.set_point_solid(c, _grid.is_solid(c))
	_astar.update()

func get_path(from: Vector2i, to: Vector2i) -> Array:
	if _grid.is_solid(from) or _grid.is_solid(to):
		return []
	var p: Array = _astar.get_id_path(from, to)
	if p.is_empty():
		return []
	var out := []
	for v in p:
		out.append(Vector2i(v.x, v.y))
	return out
