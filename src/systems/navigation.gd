## Navigation — deterministic grid pathfinder wrapping a single AStarGrid2D.
##
## Story: navigation / story-001-astargrid2d-configuration-basic-paths.md
##        navigation / story-003-path-query-edge-cases.md
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
##
## STORY 003 EDGE-CASE CONTRACT (empty-array contract, Core Rule 4):
## - get_path NEVER returns null under any condition; always a typed
##   Array[Vector2i]. The engine's get_id_path() may return different array
##   shapes across versions, so the wrapper converts + normalizes explicitly
##   (story 003 engine note).
## - No path exists (target enclosed by solids, from/to solid, from/to
##   outside region) → [] (AC4/AC14).
## - from == to → [from] for any OPEN cell (AC5). A SOLID from==to cell has
##   no path → [] (empty-array contract applies to solid endpoints).
## - Out-of-bounds from/to → [] WITHOUT an engine error (region guard).
## - Debug-only log (not crash): if the destination `to` is in-bounds and
##   solid, that signals an upstream invariant violation (access cells are
##   never solid per GridSystem contract) — push_warning, still return [].
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
## Story 003 edge cases (see class doc):
## - from == to → [from] (AC5; MemberSim treats as "already arrived")
## - solid from/to, enclosed target, out-of-bounds → [] (AC4/AC14)
## - never null, always typed Array[Vector2i]
func get_path(from: Vector2i, to: Vector2i) -> Array[Vector2i]:
	var empty_path: Array[Vector2i] = []
	if not _assert_initialized():
		return empty_path
	if not _region.has_point(from) or not _region.has_point(to):
		return empty_path
	# AC5: from == to → [from] for an OPEN cell. A solid from==to cell has
	# no path (empty-array contract covers solid endpoints) → [].
	if from == to:
		if _astar.is_point_solid(from):
			# Debug-only log: a solid destination/start cell signals an
			# upstream invariant violation (access cells are never solid
			# per GridSystem contract). Log, don't crash.
			push_warning("Navigation: get_path(%s, %s) — cell is solid; access cells are never solid (upstream invariant violation). Returning []." % [from, to])
			return empty_path
		var single: Array[Vector2i] = [from]
		return single
	# Empty-array contract: solid endpoints → no path → [].
	if _astar.is_point_solid(from) or _astar.is_point_solid(to):
		if _astar.is_point_solid(to):
			# Debug-only log (don't crash): the destination `to` being solid
			# means MemberSim targeted a solid access cell — upstream
			# invariant violation per GridSystem contract.
			push_warning("Navigation: get_path(%s, %s) — destination %s is solid; access cells are never solid (upstream invariant violation). Returning []." % [from, to, to])
		return empty_path
	# Normalize the engine result: get_id_path returns a typed
	# Array[Vector2i] in 4.7.1, but the story contract requires the wrapper
	# to convert + normalize explicitly (never null, always typed) so the
	# behavior is independent of engine return-shape changes.
	var raw: Array = _astar.get_id_path(from, to)
	if raw.is_empty():
		return empty_path
	var out: Array[Vector2i] = []
	for v in raw:
		out.append(Vector2i(v.x, v.y))
	return out
