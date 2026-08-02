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

## The GridSystem this Navigation mirrors — held as the read-only
## GridStateReader surface for the solidity sync (story-004, TR-NAV-003).
## Stored from init() because the grid_changed subscription (S1, ADR-0005)
## needs a live reference to the emitting system; is_solid() is queried from
## this surface, never assumed from the signal direction.
##
## WHY GridStateReader, not GridSystem: Navigation is a read-only consumer of
## grid state (GridSystem's write surface is deliberately not exposed to it —
## same DI posture as ZoneRules/Satisfaction). The signal host is the concrete
## GridSystem at runtime; the subscription is established in _post_init().
var _grid_system: GridStateReader


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
	_grid_system = grid
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


## Cross-system wiring phase (ADR-0001 two-phase init, Phase 2). Called by the
## orchestrator AFTER every system exists. Subscribes to GridSystem's
## grid_changed (S1 in the ADR-0005 Signal Catalog) so solidity stays in sync
## with occupancy during live play (TR-NAV-003, story-004).
##
## Subscription lifecycle: systems live for the session lifetime (orchestrator
## owns them), so no disconnect is needed (ADR-0005 negative consequence
## mitigation). The is_connected guard makes _post_init idempotent — the
## orchestrator calls it exactly once, but a test rig that calls it twice must
## not double-fire the handler.
func _post_init() -> void:
	assert(_initialized, "Navigation._post_init() called before init()")
	if not _grid_system.grid_changed.is_connected(_on_grid_changed):
		_grid_system.grid_changed.connect(_on_grid_changed)


## Solidify sync handler (story-004, TR-NAV-003). Fires once per grid_changed
## emission (placement OR removal — the payload never says which direction).
## For every changed cell in BOTH arrays, re-queries GridSystem.is_solid(cell)
## and pushes the CURRENT value into AStarGrid2D — never assumes true/false
## from the signal alone. Access cells resolve to non-solid automatically via
## is_solid (the locked GridSystem contract), so no access-cell special-casing.
##
## 4.7.1 ENGINE NOTE (probed 2026-08-02 — tests/unit/navigation/set_point_solid_probe.gd):
## after the init update(), set_point_solid takes effect IMMEDIATELY; the
## trailing update() is a no-op for correctness (paths identical with/without).
## It is KEPT per the story mandate ("handler MUST call update()") and as a
## guard against future engine versions where the push may be deferred.
func _on_grid_changed(footprint_cells: Array, access_cells: Array) -> void:
	for cell in footprint_cells + access_cells:
		_astar.set_point_solid(cell, _grid_system.is_solid(cell))
	_astar.update()  # MANDATORY per story — flush the solidity push


## White-box test hook (story-004 AC9): returns whether [cell] is solid in
## Navigation's AStarGrid2D, delegating to is_point_solid(). Documented as a
## TEST HOOK for solidity assertions (e.g. "access cells are never solid") —
## NOT a public API for gameplay consumers; gameplay reads solidity from
## GridSystem.is_solid() (the single source of truth).
##
## Safe default: true (solid) — matches GridSystem's out-of-bounds posture so
## the hook fails closed.
func is_solid(cell: Vector2i) -> bool:
	if not _assert_initialized():
		return true
	return _astar.is_point_solid(cell)


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
