# tests/integration/grid_system/grid_navigation_solidity_test.gd
# Story 008: Signals, Integration, and Performance
# Covers AC-X.1 (Navigation consumes solidity, ignores access):
#   GIVEN equipment A's access cell (2,2) has no footprint on it,
#   WHEN Navigation reads that cell via get_solidity_snapshot(),
#   THEN returns non-solid (0).
# Plus the optional AStarGrid2D fixture: a path can traverse the access
# cell — proving solidity truth drives pathfinding while access cells stay
# walkable (TR-GS-016, AC-D3.1).
#
# This is the GridSystem-side integration test: it exercises the read
# surface Navigation depends on (is_solid() + get_solidity_snapshot()) and
# a minimal AStarGrid2D bake driven from that surface. The full Navigation
# system (its grid_changed subscription handler) lives in the navigation
# epic's own stories — this test pins the contract GridSystem hands over.
# Run standalone: godot --headless --script tests/integration/grid_system/grid_navigation_solidity_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

# Rotation values mirror GridSystem.Rotation (degree-valued).
const R0 := 0

var _pass := 0
var _fail := 0


## 被 tests/headless_runner.gd 托管时立即返回 —— 用例由 runner 调用的 run_all() 驱动。
## 否则 script.new() 触发的 _init() 与随后的 run_all() 会让每个用例跑两遍。
func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	var result := run_all()
	quit(1 if int(result["fail"]) > 0 else 0)


## 返回 {"pass": int, "fail": int} —— 见 tests/headless_runner.gd 的测试文件契约
func run_all() -> Dictionary:
	print("=".repeat(48))
	print("  INTEGRATION TEST: GridSystem — Navigation Solidity (Story 008)")
	print("=".repeat(48))

	_test_ac_x_1_get_solidity_snapshot()
	_test_ac_x_1_snapshot_matches_is_solid_per_cell()
	_test_ac_x_1_astar_traverses_access_cell()
	_test_ac_x_1_astar_blocked_by_footprint()
	_test_ac_x_1_multiple_access_cells()

	print("\n=== GRID NAVIGATION SOLIDITY TEST: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


# === Helpers ===

func _make_grid(width: int, height: int) -> RefCounted:
	var GS: Script = load("res://src/systems/grid_system.gd") as Script
	var gs: RefCounted = GS.new()
	gs.call("init", width, height)
	return gs


## Makes every cell buildable.
func _make_open_grid(width: int, height: int) -> RefCounted:
	var gs := _make_grid(width, height)
	for y in height:
		for x in width:
			gs.call("set_buildable", Vector2i(x, y), true)
	gs.call("freeze_buildable")
	return gs


func _commit(gs: RefCounted, id: int, fp: Array[Vector2i], ac: Array[Vector2i], rot: int) -> void:
	gs.call("commit", id, fp, ac, rot)


## Builds an AStarGrid2D over the full grid, baking solidity from
## get_solidity_snapshot() — the exact integration point the GDD defines
## for Navigation ("is_solid(cell) / get_solidity_snapshot()" read surface,
## line 315/739). Uses DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES so diagonal moves
## cannot cut through solid corners (GDD C.4 engine note).
##
## 4.7.1 API DEVIATION from ADR-0005's illustrative sketch (documented,
## not silent): the ADR shows `_astar.set_point_solid(cell.x, cell.y,
## solid)` — three int args. The real 4.7.1 signature is
## `set_point_solid(position: Vector2i, solid: bool)` (verified empirically
## by probe). Also, the grid must be initialized with update() BEFORE any
## set_point_solid() call — calling it before update() raises "Grid is not
## initialized" (probed). Once initialized, set_point_solid() takes effect
## immediately with no second update() needed (GDD C.4 engine note
## confirmed — paths are identical with and without a trailing update()).
func _bake_astar_from_grid(gs: RefCounted) -> AStarGrid2D:
	var dims: Vector2i = gs.call("get_dimensions")
	var astar := AStarGrid2D.new()
	astar.region = Rect2i(0, 0, dims.x, dims.y)
	astar.cell_size = Vector2.ONE
	astar.diagonal_mode = AStarGrid2D.DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES
	astar.update()  # MUST precede set_point_solid — grid init (4.7.1 probed)
	var solidity: PackedByteArray = gs.call("get_solidity_snapshot")
	for y in dims.y:
		for x in dims.x:
			var idx := y * dims.x + x
			astar.set_point_solid(Vector2i(x, y), solidity[idx] != 0)
	return astar


# === AC-X.1: Navigation 消费 solidity，无视 access ===

func _test_ac_x_1_get_solidity_snapshot() -> void:
	print("\n[AC-X.1] get_solidity_snapshot() — access cell (2,2) with no footprint reads 0 (non-solid)")

	var gs := _make_open_grid(13, 10)
	# AC fixture: the access cell (2,2) must have NO footprint on it.
	# Footprint at (2,1), access cell (2,2) directly below.
	var fp: Array[Vector2i] = [Vector2i(2, 1)]
	var ac: Array[Vector2i] = [Vector2i(2, 2)]
	_commit(gs, 1, fp, ac, R0)

	var dims: Vector2i = gs.call("get_dimensions")
	var solidity: PackedByteArray = gs.call("get_solidity_snapshot")
	_check(
		solidity.size() == dims.x * dims.y,
		"get_solidity_snapshot() returns one byte per cell (size %d == %dx%d)" % [solidity.size(), dims.x, dims.y]
	)
	# flat_index(cell) = cell.y * width + cell.x (row-major) — index for
	# (x,y) is y * dims.x + x.
	var idx_access := 2 * dims.x + 2  # cell (2,2)
	var idx_footprint := 1 * dims.x + 2  # cell (2,1)
	_check(
		solidity[idx_access] == 0,
		"access cell (2,2) reads 0 (non-solid) — footprint is at (2,1), access is walkable"
	)
	_check(
		solidity[idx_footprint] == 1,
		"footprint cell (2,1) reads 1 (solid)"
	)
	# Cross-check against the per-cell query — both surfaces must agree.
	_check(
		(solidity[idx_access] != 0) == bool(gs.call("is_solid", Vector2i(2, 2))),
		"snapshot and is_solid agree on the access cell"
	)


func _test_ac_x_1_snapshot_matches_is_solid_per_cell() -> void:
	print("\n[AC-X.1 edge] get_solidity_snapshot() agrees with is_solid() on EVERY cell")

	var gs := _make_open_grid(13, 10)
	_commit(gs, 1, [Vector2i(2, 1), Vector2i(2, 2)], [Vector2i(2, 3)], R0)
	_commit(gs, 2, [Vector2i(5, 5), Vector2i(6, 5)], [Vector2i(5, 6), Vector2i(2, 3)], R0)
	_commit(gs, 3, [Vector2i(9, 2)], [], R0)

	var dims: Vector2i = gs.call("get_dimensions")
	var solidity: PackedByteArray = gs.call("get_solidity_snapshot")
	var mismatches := 0
	for y in dims.y:
		for x in dims.x:
			var idx := y * dims.x + x
			var from_snapshot: bool = solidity[idx] != 0
			var from_query: bool = gs.call("is_solid", Vector2i(x, y))
			if from_snapshot != from_query:
				mismatches += 1
	_check(
		mismatches == 0,
		"get_solidity_snapshot() == is_solid() on all %d cells (mismatches=%d)" % [dims.x * dims.y, mismatches]
	)


func _test_ac_x_1_astar_traverses_access_cell() -> void:
	print("\n[AC-X.1 optional] AStarGrid2D path traverses the access cell (2,2) — walkable by design")

	var gs := _make_open_grid(13, 10)
	# Corridor fixture: walls (single-cell footprints) on rows 1 and 3,
	# columns 0..4, force the horizontal path along row 2 from (0,2) to
	# (4,2). Equipment A's footprint occupies (2,1) — the middle cell of
	# the TOP wall; its access cell (2,2) sits inside the corridor. The
	# ONLY path from (0,2) to (4,2) passes through (2,2) — if access cells
	# were solid, the corridor would be blocked and no path would exist.
	for c in range(5):
		if c != 2:
			_commit(gs, 100 + c, [Vector2i(c, 1)], [], R0)
		_commit(gs, 200 + c, [Vector2i(c, 3)], [], R0)
	var fp: Array[Vector2i] = [Vector2i(2, 1)]
	var ac: Array[Vector2i] = [Vector2i(2, 2)]
	_commit(gs, 1, fp, ac, R0)

	var astar := _bake_astar_from_grid(gs)
	var path: Array[Vector2i] = astar.get_id_path(Vector2i(0, 2), Vector2i(4, 2))

	_check(
		not path.is_empty(),
		"AStarGrid2D found a path from (0,2) to (4,2) — got %s" % [path]
	)
	_check(
		path.has(Vector2i(2, 2)),
		"the corridor path traverses the access cell (2,2) — access cells stay walkable (TR-GS-016)"
	)
	# The footprint (2,1) sits above the corridor (a wall cell); the
	# corridor row must never use it.
	_check(
		not path.has(Vector2i(2, 1)),
		"path does NOT traverse the footprint cell (2,1) — solidity respected"
	)


func _test_ac_x_1_astar_blocked_by_footprint() -> void:
	print("\n[AC-X.1 edge] AStarGrid2D is blocked by a footprint — solidity truth drives pathfinding")

	var gs := _make_open_grid(13, 10)
	# A solid wall of footprints at row 5, columns 3..7 (single-cell pieces).
	for x in range(3, 8):
		_commit(gs, 100 + x, [Vector2i(x, 5)], [], R0)

	var astar := _bake_astar_from_grid(gs)
	# Straight vertical path (5,2) → (5,6) is fully blocked by the wall.
	var path: Array[Vector2i] = astar.get_id_path(Vector2i(5, 2), Vector2i(5, 6))

	_check(not path.is_empty(), "a path exists around the wall (got %s)" % [path])
	# The wall cells themselves must never be traversed.
	var hits_wall := false
	for cell in path:
		if cell.y == 5 and cell.x >= 3 and cell.x <= 7:
			hits_wall = true
	_check(
		not hits_wall,
		"path avoids every footprint cell in the wall (hits_wall=%s)" % hits_wall
	)
	# Reaching the goal proves the detour completed.
	_check(path[path.size() - 1] == Vector2i(5, 6), "path terminates at the goal (5,6)")


func _test_ac_x_1_multiple_access_cells() -> void:
	print("\n[AC-X.1 edge] multiple overlapping access cells stay non-solid in the snapshot")

	var gs := _make_open_grid(13, 10)
	# Three pieces share access cell (7,7); two also have separate access cells.
	_commit(gs, 1, [Vector2i(7, 6)], [Vector2i(7, 7)], R0)
	_commit(gs, 2, [Vector2i(8, 8)], [Vector2i(7, 7)], R0)
	_commit(gs, 3, [Vector2i(9, 9)], [Vector2i(7, 7), Vector2i(10, 8)], R0)

	var dims: Vector2i = gs.call("get_dimensions")
	var solidity: PackedByteArray = gs.call("get_solidity_snapshot")
	# flat_index = y * width + x (row-major).
	var idx_shared := 7 * dims.x + 7   # cell (7,7)
	var idx_extra := 8 * dims.x + 10   # cell (10,8)
	_check(solidity[idx_shared] == 0, "shared access cell (7,7) reads 0 — contention does not make it solid")
	_check(solidity[idx_extra] == 0, "second access cell (10,8) reads 0")
	_check(
		(gs.call("get_access_ids", Vector2i(7, 7)) as Array).size() == 3,
		"3 ids registered on the shared access cell (get_access_ids sanity)"
	)
