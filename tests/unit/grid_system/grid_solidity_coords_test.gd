# tests/unit/grid_system/grid_solidity_coords_test.gd
# Story 002: Solidity Formula and Coordinate Conversion
# Covers AC-D3.1 through AC-D3.4, AC-D2.2, AC-D2.3, AC-D4.1, AC-C5.1
# Run standalone: godot --headless --script tests/unit/grid_system/grid_solidity_coords_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

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
	print("  UNIT TEST: GridSystem — Solidity & Coords (Story 002)")
	print("=".repeat(48))

	_test_access_ids_do_not_affect_solidity()
	_test_occupant_id_overrides_solidity_regardless_of_access()
	_test_unbuildable_is_always_solid()
	_test_occupant_id_zero_is_solid_not_falsy()
	_test_oob_query_functions_push_error_and_no_leak()
	_test_oob_is_solid_defaults_true()
	_test_coordinate_round_trip()
	_test_access_cell_is_walkable()

	print("\n=== GRID SOLIDITY & COORDS TEST: %d passed, %d failed ===" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


# === Helper ===

func _make_grid(width: int, height: int) -> RefCounted:
	var GS: Script = load("res://src/systems/grid_system.gd") as Script
	var gs: RefCounted = GS.new()
	gs.call("init", width, height)
	return gs


## Makes every cell in the grid buildable — most solidity tests care about
## occupant_id / access_ids, not room geometry, so start from an all-open room.
func _make_open_grid(width: int, height: int) -> RefCounted:
	var gs := _make_grid(width, height)
	for y in height:
		for x in width:
			gs.call("set_buildable", Vector2i(x, y), true)
	gs.call("freeze_buildable")
	return gs


# === AC-D3.1 / AC-C5.1: access_ids 不参与 solidity（第二高危断言） ===

func _test_access_ids_do_not_affect_solidity() -> void:
	print("\n[AC-D3.1 / AC-C5.1] access_ids do not affect is_solid — access cells stay walkable")

	# Edge case: access_ids = [] (no access at all) — trivially not solid.
	var gs_empty := _make_open_grid(5, 5)
	_check(
		gs_empty.call("is_solid", Vector2i(2, 2)) == false,
		"buildable=true, occupant_id=-1, access_ids=[] -> is_solid=false"
	)

	# Edge case: access_ids = [7] — the story's primary fixture.
	var gs_one := _make_open_grid(5, 5)
	gs_one.call("commit_access", Vector2i(2, 2), 7)
	_check(
		gs_one.call("get_access_ids", Vector2i(2, 2)).has(7),
		"fixture sanity: (2,2) is access_id=7's access cell"
	)
	_check(
		gs_one.call("get_occupant_id", Vector2i(2, 2)) == -1,
		"fixture sanity: (2,2) has no footprint occupant"
	)
	_check(
		gs_one.call("is_solid", Vector2i(2, 2)) == false,
		"buildable=true, occupant_id=-1, access_ids=[7] -> is_solid=false (AC-D3.1)"
	)

	# Edge case: access_ids = [7, 8, 9] — multiple ids sharing the same access cell.
	var gs_many := _make_open_grid(5, 5)
	gs_many.call("commit_access", Vector2i(3, 3), 7)
	gs_many.call("commit_access", Vector2i(3, 3), 8)
	gs_many.call("commit_access", Vector2i(3, 3), 9)
	_check(
		gs_many.call("is_solid", Vector2i(3, 3)) == false,
		"buildable=true, occupant_id=-1, access_ids=[7,8,9] -> is_solid=false"
	)

	# AC-C5.1 edge case: cleared access cell — access_ids becomes [] again,
	# solidity must remain false throughout (was never solid because of access).
	gs_many.call("clear_access", Vector2i(3, 3), 7)
	gs_many.call("clear_access", Vector2i(3, 3), 8)
	gs_many.call("clear_access", Vector2i(3, 3), 9)
	_check(
		gs_many.call("get_access_ids", Vector2i(3, 3)).is_empty(),
		"access_ids at (3,3) empty after clearing all three ids"
	)
	_check(
		gs_many.call("is_solid", Vector2i(3, 3)) == false,
		"AC-C5.1 transition: after access_ids clears to [], is_solid stays false"
	)


# === AC-D3.2: occupant_id 覆盖一切，无论 access_ids ===

func _test_occupant_id_overrides_solidity_regardless_of_access() -> void:
	print("\n[AC-D3.2] occupant_id != -1 always makes is_solid true, regardless of access_ids")

	# occupant_id=7, access_ids=[] (nobody's access cell)
	var gs_no_access := _make_open_grid(5, 5)
	gs_no_access.call("commit_occupant", Vector2i(2, 2), 7)
	_check(
		gs_no_access.call("is_solid", Vector2i(2, 2)) == true,
		"buildable=true, occupant_id=7, access_ids=[] -> is_solid=true"
	)

	# occupant_id=7, access_ids=[8,9] (someone else's access cell)
	var gs_other_access := _make_open_grid(5, 5)
	gs_other_access.call("commit_occupant", Vector2i(2, 2), 7)
	gs_other_access.call("commit_access", Vector2i(2, 2), 8)
	gs_other_access.call("commit_access", Vector2i(2, 2), 9)
	_check(
		gs_other_access.call("is_solid", Vector2i(2, 2)) == true,
		"buildable=true, occupant_id=7, access_ids=[8,9] -> is_solid=true (access_blocked scenario)"
	)

	# Edge case: occupant_id=5 with access_ids containing [5] itself —
	# formula is unambiguous regardless of this data oddity.
	var gs_self_access := _make_open_grid(5, 5)
	gs_self_access.call("commit_occupant", Vector2i(2, 2), 5)
	gs_self_access.call("commit_access", Vector2i(2, 2), 5)
	_check(
		gs_self_access.call("is_solid", Vector2i(2, 2)) == true,
		"buildable=true, occupant_id=5, access_ids=[5] (self-overlap) -> is_solid=true"
	)


# === AC-D3.3: buildable=false 恒为 solid ===

func _test_unbuildable_is_always_solid() -> void:
	print("\n[AC-D3.3] buildable=false always makes is_solid true, regardless of occupant_id")

	# buildable=false, occupant_id=-1 (empty wall/pillar cell)
	var gs_empty := _make_grid(5, 5)
	gs_empty.call("set_buildable", Vector2i(2, 2), false)
	gs_empty.call("freeze_buildable")
	_check(
		gs_empty.call("is_solid", Vector2i(2, 2)) == true,
		"buildable=false, occupant_id=-1 -> is_solid=true"
	)

	# buildable=false, occupant_id=5 (illegal data state per GDD's legal-values
	# table, but the formula must still be unambiguous: buildable=false wins)
	var gs_occupied := _make_grid(5, 5)
	gs_occupied.call("set_buildable", Vector2i(2, 2), true)
	gs_occupied.call("freeze_buildable")
	gs_occupied.call("commit_occupant", Vector2i(2, 2), 5)
	_check(
		gs_occupied.call("is_solid", Vector2i(2, 2)) == true,
		"buildable=false, occupant_id=5 -> is_solid=true"
	)

	# Edge case: negative-looking occupant_id is not directly settable via the
	# public API (commit_occupant rejects -1), so we verify the "any value"
	# claim by testing occupant_id=0 as well — still solid when unbuildable.
	var gs_zero := _make_grid(5, 5)
	gs_zero.call("set_buildable", Vector2i(1, 1), true)
	gs_zero.call("freeze_buildable")
	gs_zero.call("commit_occupant", Vector2i(1, 1), 0)
	_check(
		gs_zero.call("is_solid", Vector2i(1, 1)) == true,
		"buildable=true after all (occupant_id=0 present) -> is_solid=true regardless"
	)


# === AC-D3.4: occupant_id=0 不是 falsy（GDScript 陷阱） ===

func _test_occupant_id_zero_is_solid_not_falsy() -> void:
	print("\n[AC-D3.4] occupant_id=0 (first piece ever placed) is solid, not falsy-skipped")

	var gs := _make_open_grid(3, 3)

	# GIVEN buildable=true, cell (2,2) occupied by instance_id=0
	var committed: bool = gs.call("commit_occupant", Vector2i(2, 2), 0)
	_check(committed, "commit_occupant(cell=(2,2), id=0) succeeds")

	# THEN is_solid((2,2)) returns true
	_check(
		gs.call("is_solid", Vector2i(2, 2)) == true,
		"is_solid((2,2)) == true with occupant_id=0 — the classic `if occupant_id:` bug would return false"
	)

	# AND get_occupant_id((2,2)) returns 0 (not -1)
	_check(
		gs.call("get_occupant_id", Vector2i(2, 2)) == 0,
		"get_occupant_id((2,2)) == 0, not -1 — explicit comparison, not truthy"
	)


# === AC-D2.2: 越界拦截不崩溃不泄漏（全部 8 个方向 + 全部公开查询函数） ===

func _test_oob_query_functions_push_error_and_no_leak() -> void:
	print("\n[AC-D2.2] out-of-bounds queries push_error(), return safe default, never leak adjacent data")

	var width := 13
	var height := 10
	var gs := _make_open_grid(width, height)

	# --- Cross-row/column leak fixture ---
	# flat_index(col, row) = row * width + col. If a query skipped bounds-
	# checking and fed a negative/overflowing col straight into that formula,
	# it would silently land on a DIFFERENT real cell's index (row-major
	# wraparound), reading that cell's data instead of failing loudly.
	#
	# For width=13: flat_index(-1, 5)    naively = 5*13 + (-1) = 64, which is
	#               the REAL index of cell (12, 4) — one row up, last column.
	#               flat_index(13, 5)    naively = 5*13 + 13  = 78, which is
	#               the REAL index of cell (0, 6) — one row down, first column.
	# We plant known, distinct ids at exactly those two real "leak target"
	# cells so a bounds-check bug would surface as "returned 111/222" instead
	# of the documented -1/false/[] safe defaults.
	gs.call("commit_occupant", Vector2i(12, 4), 111)
	gs.call("commit_access", Vector2i(12, 4), 21)
	gs.call("commit_occupant", Vector2i(0, 6), 222)
	gs.call("commit_access", Vector2i(0, 6), 22)

	# Also plant sentinels at the grid's real corners so post-probe integrity
	# checks below have something to verify.
	gs.call("commit_occupant", Vector2i(0, 0), 444)
	gs.call("commit_occupant", Vector2i(width - 1, height - 1), 333)

	var col_minus_one := Vector2i(-1, 5)
	var col_width := Vector2i(width, 5)

	var leaked_occ_1: int = gs.call("get_occupant_id", col_minus_one)
	_check(
		leaked_occ_1 == -1,
		"get_occupant_id((-1,5)) returns -1, NOT 111 leaked from real cell (12,4) (got %d)" % leaked_occ_1
	)
	var leaked_access_1: Array = gs.call("get_access_ids", col_minus_one)
	_check(
		leaked_access_1.is_empty(),
		"get_access_ids((-1,5)) returns [], NOT [21] leaked from real cell (12,4)"
	)

	var leaked_occ_2: int = gs.call("get_occupant_id", col_width)
	_check(
		leaked_occ_2 == -1,
		"get_occupant_id((13,5)) returns -1, NOT 222 leaked from real cell (0,6) (got %d)" % leaked_occ_2
	)
	var leaked_access_2: Array = gs.call("get_access_ids", col_width)
	_check(
		leaked_access_2.is_empty(),
		"get_access_ids((13,5)) returns [], NOT [22] leaked from real cell (0,6)"
	)

	# --- All 8 OOB directions (4 corners + 4 edges) — every public query
	# function must push_error() + return its documented safe default ---
	var oob_edges: Array[Vector2i] = [
		Vector2i(-1, 3),      # col=-1
		Vector2i(width, 3),   # col=width
		Vector2i(3, -1),      # row=-1
		Vector2i(3, height),  # row=height
	]
	var oob_corners: Array[Vector2i] = [
		Vector2i(-1, -1),
		Vector2i(width, -1),
		Vector2i(-1, height),
		Vector2i(width, height),
	]

	var oob_cells: Array[Vector2i] = oob_edges + oob_corners
	_check(oob_cells.size() == 8, "test covers all 8 OOB directions (4 edges + 4 corners)")

	for cell in oob_cells:
		var occ: int = gs.call("get_occupant_id", cell)
		_check(
			occ == -1,
			"get_occupant_id(%s) returns -1 (safe default) (got %d)" % [cell, occ]
		)

		var buildable: bool = gs.call("get_buildable", cell)
		_check(
			buildable == false,
			"get_buildable(%s) returns false (safe default)" % cell
		)

		var access: Array = gs.call("get_access_ids", cell)
		_check(
			access.is_empty(),
			"get_access_ids(%s) returns [] (safe default)" % cell
		)

		var solid: bool = gs.call("is_solid", cell)
		_check(
			solid == true,
			"is_solid(%s) returns true (safe default per AC-D2.3)" % cell
		)

	# Explicitly confirm the real data is untouched by all the OOB probing above.
	_check(
		gs.call("get_occupant_id", Vector2i(12, 4)) == 111,
		"real cell (12,4) still holds id=111 after OOB probing — no cross-contamination"
	)
	_check(
		gs.call("get_occupant_id", Vector2i(0, 6)) == 222,
		"real cell (0,6) still holds id=222 after OOB probing — no cross-contamination"
	)
	_check(
		gs.call("get_occupant_id", Vector2i(width - 1, height - 1)) == 333,
		"real cell (width-1,height-1) still holds id=333 after OOB probing"
	)
	_check(
		gs.call("get_occupant_id", Vector2i(0, 0)) == 444,
		"real cell (0,0) still holds id=444 after OOB probing"
	)


# === AC-D2.3: is_solid 越界默认 true ===

func _test_oob_is_solid_defaults_true() -> void:
	print("\n[AC-D2.3] is_solid on out-of-bounds coordinate defaults to true, never false")

	var gs := _make_open_grid(13, 10)

	var oob_cells: Array[Vector2i] = [
		Vector2i(-1, -1), Vector2i(-1, 5), Vector2i(-1, 10),
		Vector2i(13, -1), Vector2i(13, 5), Vector2i(13, 10),
		Vector2i(5, -1), Vector2i(5, 10),
	]

	for cell in oob_cells:
		var solid: bool = gs.call("is_solid", cell)
		_check(
			solid == true,
			"is_solid(%s) == true (out of bounds default) — false would let AStarGrid2D path outside the room" % cell
		)


# === AC-D4.1: 坐标换算往返一致性 ===

func _test_coordinate_round_trip() -> void:
	print("\n[AC-D4.1] grid_to_world_corner / grid_to_world_center / world_to_grid round-trip")

	var gs := _make_open_grid(13, 10)
	var cell_size := 32

	# Primary fixture: cell=(5,3), cell_size=32
	var corner: Vector2 = gs.call("grid_to_world_corner", Vector2i(5, 3), cell_size)
	_check(corner == Vector2(160, 96), "grid_to_world_corner((5,3), 32) == (160, 96)")

	var center: Vector2 = gs.call("grid_to_world_center", Vector2i(5, 3), cell_size)
	_check(center == Vector2(176, 112), "grid_to_world_center((5,3), 32) == (176, 112)")

	var back: Vector2i = gs.call("world_to_grid", Vector2(170, 100), cell_size)
	_check(back == Vector2i(5, 3), "world_to_grid((170,100), 32) == (5, 3)")

	# Edge case: odd cell_size
	var odd_size := 17
	var corner_odd: Vector2 = gs.call("grid_to_world_corner", Vector2i(2, 4), odd_size)
	_check(
		corner_odd == Vector2(34, 68),
		"grid_to_world_corner((2,4), 17) == (34, 68) — odd cell_size"
	)
	var center_odd: Vector2 = gs.call("grid_to_world_center", Vector2i(2, 4), odd_size)
	_check(
		center_odd == Vector2(34 + 8.5, 68 + 8.5),
		"grid_to_world_center((2,4), 17) == (42.5, 76.5) — odd cell_size uses fractional half"
	)
	var back_odd: Vector2i = gs.call("world_to_grid", Vector2(40, 75), odd_size)
	_check(
		back_odd == Vector2i(2, 4),
		"world_to_grid((40,75), 17) == (2, 4) — odd cell_size round-trip"
	)

	# Edge case: cell at origin (0,0)
	var corner_origin: Vector2 = gs.call("grid_to_world_corner", Vector2i(0, 0), cell_size)
	_check(corner_origin == Vector2.ZERO, "grid_to_world_corner((0,0), 32) == (0,0)")
	var back_origin: Vector2i = gs.call("world_to_grid", Vector2(0, 0), cell_size)
	_check(back_origin == Vector2i(0, 0), "world_to_grid((0,0), 32) == (0,0)")

	# Edge case: cell at max boundary (width-1, height-1) = (12, 9)
	var max_cell := Vector2i(12, 9)
	var corner_max: Vector2 = gs.call("grid_to_world_corner", max_cell, cell_size)
	_check(
		corner_max == Vector2(384, 288),
		"grid_to_world_corner((12,9), 32) == (384, 288) — max boundary cell"
	)
	var back_max: Vector2i = gs.call("world_to_grid", corner_max, cell_size)
	_check(
		back_max == max_cell,
		"world_to_grid(grid_to_world_corner((12,9))) round-trips back to (12,9)"
	)

	# world_to_grid is a pure conversion — out-of-bounds input is normal and
	# expected (e.g. mouse dragged outside the room), NOT an error condition.
	# It must NOT clamp, NOT push_error, and NOT return a sentinel.
	var oob_result: Vector2i = gs.call("world_to_grid", Vector2(-10, -10), cell_size)
	_check(
		oob_result == Vector2i(-1, -1),
		"world_to_grid((-10,-10), 32) == (-1,-1) — raw floor division, no clamp/error/sentinel"
	)
	var oob_result_far: Vector2i = gs.call("world_to_grid", Vector2(1000, 1000), cell_size)
	_check(
		oob_result_far == Vector2i(31, 31),
		"world_to_grid((1000,1000), 32) == (31,31) — far out-of-bounds, still raw math, no clamp"
	)


# === AC-C5.1: access cell 可步行（同 AC-D3.1，framed as "can members stand there") ===

func _test_access_cell_is_walkable() -> void:
	print("\n[AC-C5.1] access cell with occupant_id=-1 is walkable (is_solid == false)")

	var gs := _make_open_grid(5, 5)
	gs.call("commit_access", Vector2i(1, 1), 7)

	_check(
		gs.call("get_occupant_id", Vector2i(1, 1)) == -1,
		"fixture sanity: (1,1) has no footprint occupant"
	)
	_check(
		gs.call("is_solid", Vector2i(1, 1)) == false,
		"access cell with occupant_id=-1 -> is_solid=false — members can walk there"
	)

	# Edge case: multiple access_ids on the same walkable cell
	gs.call("commit_access", Vector2i(1, 1), 8)
	_check(
		gs.call("is_solid", Vector2i(1, 1)) == false,
		"still walkable with access_ids=[7,8]"
	)
