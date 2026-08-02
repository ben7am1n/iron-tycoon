## Navigation — deterministic grid pathfinder wrapping a single AStarGrid2D.
##
## Story: navigation / story-001-astargrid2d-configuration-basic-paths.md
## Req:   TR-NAV-001 (single AStarGrid2D; DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES;
##                  HEURISTIC_OCTILE), TR-NAV-002 (cell-space only:
##                  get_id_path returns Array[Vector2i]; get_point_path
##                  forbidden), TR-NAV-007 (step cost 1.0 orth / sqrt(2)
##                  diag; octile heuristic admissible and consistent)
## ADR:   ADR-0007 (AStarGrid2D Cross-Rebuild Determinism — gate PASSED
##                  2026-07-21: 10/10 processes bit-identical; rebuild-on-load
##                  proven correct)
##
## Wraps Godot's AStarGrid2D, whose solidity mirrors GridSystem's occupancy:
## given a start cell and a goal cell it returns the geometric shortest path
## as an ordered list of grid cells, or an empty array when no path exists.
## Navigation is deliberately congestion-blind (TR-NAV-004 — target selection
## lives in MemberSim, never in path cost) and owns NO serialized state: the
## AStarGrid2D is rebuilt from GridSystem occupancy on load (TR-NAV-005).
##
## CLASS HIERARCHY — DEVIATION FROM STORY SKETCH (documented, not silent):
## The Story 001 sketch shows `class_name Navigation extends RefCounted`, but
## ADR-0001 (the governing implementation ADR) mandates the SimSystem
## two-phase init pattern (_mark_initialized/_assert_initialized/system_name)
## for every one of the 12 simulation systems — same precedent already
## documented in TimeSystem's header (Story 002) and GridStateReader's
## (Story 006). So Navigation extends SimSystem.
##
## ENGINE NOTES (Godot 4.7.1, verified by probe 2026-08-02):
## - class_name is NOT globally registered under headless project load —
##   tests reference systems via load("res://...") + .call(), never by name.
## - AStarGrid2D.update() MUST precede set_point_solid (grid init); calling
##   set_point_solid before it raises "Grid is not initialized".
## - After grid init, set_point_solid takes effect immediately; the trailing
##   update() after the solidity seed is kept per the story's "seed all, then
##   update()" wording and is harmless (paths identical with/without it).
## - jumping_enabled=false is LOAD-BEARING: with JPS on, get_id_path returns
##   jump points (e.g. [(0,0),(5,0)]), NOT the full cell path. The
##   cell-path contract (TR-NAV-002) requires it off.
## - get_id_path pushes an engine ERROR for out-of-bounds points; get_path()
##   guards with region.has_point() and returns [] instead (GDD AC14).
class_name Navigation extends SimSystem

## The single AStarGrid2D instance, configured exactly once in init()
## (TR-NAV-001). Never serialized (TR-NAV-005) — rebuilt from occupancy.
var _astar: AStarGrid2D

## Grid bounding box, origin-aligned to GridSystem's (0,0). Cell-space only:
## Navigation exposes and consumes grid cells (Vector2i), never world space
## (TR-NAV-002, TR-NAV-008).
var _region: Rect2i


## Configures the AStarGrid2D exactly once from the grid's read surface.
##
## region = GridSystem's bounding box cell-for-cell, origin-aligned to (0,0);
## diagonal_mode = DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES (no corner clipping
## past solids); default_compute_heuristic = default_estimate_heuristic =
## HEURISTIC_OCTILE (the only heuristic consistent with the sqrt(2) diagonal
## step cost); jumping_enabled = false (no JPS at ~130 cells — and JPS would
## break the full-cell-path contract). Seeds every cell's solidity from
## GridStateReader.is_solid(), then update().
##
## Rejects non-positive grid dimensions without marking the system
## initialized (caller may retry with a valid grid) — mirrors GridSystem.init.
func init(grid: GridStateReader) -> void:
	var dims: Vector2i = grid.get_dimensions()
	if dims.x <= 0 or dims.y <= 0:
		push_error("Navigation: init() requires a grid with positive dimensions, got %s." % dims)
		return
	if not _mark_initialized():
		return
	_region = Rect2i(0, 0, dims.x, dims.y)
	_astar = AStarGrid2D.new()
	_astar.region = _region
	_astar.cell_size = Vector2.ONE  # cell-space only; get_point_path forbidden (TR-NAV-002)
	_astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	_astar.default_compute_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	_astar.default_estimate_heuristic = AStarGrid2D.HEURISTIC_OCTILE
	_astar.jumping_enabled = false
	_astar.update()  # MUST precede set_point_solid — grid init (4.7.1 probed)
	for y in dims.y:
		for x in dims.x:
			var cell := Vector2i(x, y)
			_astar.set_point_solid(cell, grid.is_solid(cell))
	_astar.update()  # flush solidity seed (story: seed all, then update)


func system_name() -> String:
	return "Navigation"


## Returns the shortest cell path from [from] to [to], inclusive of both
## endpoints, or an empty array when no path exists (never null).
##
## Backed exclusively by AStarGrid2D.get_id_path() (TR-NAV-002);
## get_point_path() is forbidden anywhere in Navigation's surface — this
## makes Navigation provably independent of cell_size (TR-NAV-008).
## No caching — every call recomputes (A* over ~130 cells is sub-ms).
##
## Out-of-bounds from/to return [] WITHOUT an engine error (guarded by
## region.has_point — GDD AC14). from == to returns [from] (GDD AC5, natively
## handled by get_id_path). Solid endpoints return [] (no path exists).
func get_path(from: Vector2i, to: Vector2i) -> Array[Vector2i]:
	if not _assert_initialized():
		return []
	if not _region.has_point(from) or not _region.has_point(to):
		return []
	return _astar.get_id_path(from, to)
