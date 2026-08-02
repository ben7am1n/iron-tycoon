## Navigation — deterministic grid pathfinder wrapping a single AStarGrid2D.
##
## Stories: navigation / story-001-astargrid2d-configuration-basic-paths.md
##          navigation / story-006-rebuild-on-load-cell-size-independence.md
## Req:   TR-NAV-001 (single AStarGrid2D; DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES;
##                  HEURISTIC_OCTILE), TR-NAV-002 (cell-space only:
##                  get_id_path returns Array[Vector2i]; get_point_path
##                  forbidden), TR-NAV-005 (Navigation contributes NOTHING to
##                  the save file; AStarGrid2D rebuilt from GridSystem
##                  occupancy on load), TR-NAV-007 (step cost 1.0 orth /
##                  sqrt(2) diag; octile heuristic admissible and consistent),
##                  TR-NAV-008 (cell_size independence by construction — only
##                  cell indices, no world coords)
## ADR:   ADR-0002 (Storage Format — Navigation serializes nothing, so there
##                  is no serialize()/deserialize() override on this class),
##                  ADR-0007 (AStarGrid2D Cross-Rebuild Determinism — gate
##                  PASSED 2026-07-21: 10/10 processes bit-identical;
##                  rebuild-on-load proven correct)
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
## - REBUILD (Story 006, verified 4.7.1): changing AStarGrid2D.region clears
##   ALL solid flags — a region change requires a full re-init, not an
##   incremental push. rebuild() therefore constructs a FRESH AStarGrid2D and
##   re-seeds every cell (the load path is a full rebuild by design; live
##   play uses the incremental grid_changed path, Story 004).
## - REBUILD AND cell_size (Story 006, verified 4.7.1): get_id_path operates
##   on cell indices only — the probe confirmed two AStarGrid2D instances
##   with identical solidity but cell_size 16 vs 32 return element-for-element
##   identical paths for identical cell queries. AC6 is the black-box proof.
class_name Navigation extends SimSystem

## The single AStarGrid2D instance. NEVER serialized (TR-NAV-005) — rebuilt
## from occupancy via rebuild() on load (SaveLoad load sequence step 4).
## Replaced wholesale by rebuild() (region change clears solid flags).
var _astar: AStarGrid2D

## Grid bounding box, origin-aligned to GridSystem's (0,0). Cell-space only:
## Navigation exposes and consumes grid cells (Vector2i), never world space
## (TR-NAV-002, TR-NAV-008).
var _region: Rect2i

## Per-instance cell_size (TR-NAV-008). Only ever assigned to
## AStarGrid2D.cell_size at construction — no Navigation logic reads it, so
## the value is provably irrelevant to path output (AC6 black-box proof).
var _cell_size: Vector2 = Vector2.ONE


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
## [cell_size] is configurable per instance (Story 006 / TR-NAV-008): the
## value is pinned later at /create-architecture; Navigation's logic never
## reads it, so any value yields identical get_path() results (AC6). Default
## Vector2.ONE keeps Story 001's call sites (`init(grid)`) unchanged.
##
## Rejects non-positive grid dimensions without marking the system
## initialized (caller may retry with a valid grid) — mirrors GridSystem.init.
func init(grid: GridStateReader, cell_size: Vector2 = Vector2.ONE) -> void:
	var dims: Vector2i = grid.get_dimensions()
	if dims.x <= 0 or dims.y <= 0:
		push_error("Navigation: init() requires a grid with positive dimensions, got %s." % dims)
		return
	if not _mark_initialized():
		return
	_cell_size = cell_size
	_configure_astar(grid)


func system_name() -> String:
	return "Navigation"


## Full rebuild of the AStarGrid2D from [grid]'s occupancy (TR-NAV-005).
##
## Called by SaveLoad during load sequence step 4 — after
## GridSystem.deserialize(), before MemberSim — with the restored grid. It
## performs a FULL re-init, never an incremental push: a fresh AStarGrid2D is
## constructed, region re-read from the grid's current dimensions, every
## cell's solidity re-seeded from GridStateReader.is_solid(), then update().
##
## Why a full rebuild: changing AStarGrid2D.region clears all solid flags
## (verified 4.7.1 — see class ENGINE NOTES), so there is no safe incremental
## path across a load; and the load path must produce a bit-identical graph
## to the pre-save one, which ADR-0007's gate proved for fresh rebuilds
## (10/10 processes bit-identical). Navigation serializes nothing — this
## rebuild is the ONLY state restoration it needs.
##
## The instance's configured cell_size is preserved (cell_size is fixed at
## init; rebuild refreshes occupancy only — TR-NAV-008).
func rebuild(grid: GridStateReader) -> void:
	if not _assert_initialized():
		return
	_configure_astar(grid)


## Shared construction for init() and rebuild(): reads [grid]'s dimensions,
## builds a fresh AStarGrid2D with the fixed configuration, seeds every cell
## from is_solid(), then update().
func _configure_astar(grid: GridStateReader) -> void:
	var dims: Vector2i = grid.get_dimensions()
	_region = Rect2i(0, 0, dims.x, dims.y)
	_astar = AStarGrid2D.new()
	_astar.region = _region
	_astar.cell_size = _cell_size  # cell-space only; get_point_path forbidden (TR-NAV-002)
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
## The result is identical after rebuild() from identical occupancy (AC13).
func get_path(from: Vector2i, to: Vector2i) -> Array[Vector2i]:
	if not _assert_initialized():
		return []
	if not _region.has_point(from) or not _region.has_point(to):
		return []
	return _astar.get_id_path(from, to)
