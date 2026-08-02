# tests/integration/navigation/rebuild_load_cell_size_test.gd
# Story 006: Rebuild-on-Load and cell_size Independence
# (production/epics/navigation/story-006-rebuild-on-load-cell-size-independence.md)
#
# Covers the BLOCKING ACs:
#   - AC6  two Navigation instances with identical solidity but different
#         cell_size (16 vs 32) → identical cell-coordinate queries return
#         element-for-element identical outputs (black-box proof that
#         get_point_path() is not used internally — TR-NAV-008)
#   - AC13 solidity state pre-save → save (Navigation serializes nothing) →
#         reload → Navigation.rebuild(occupancy from persisted grid) →
#         get_path(from, to) returns the pre-save result (TR-NAV-005,
#         ADR-0007 rebuild-on-load)
#
# QA edge cases covered:
#   AC6 — multi-cell paths with diagonals; empty-path cases; different region
#         sizes with the same solidity pattern
#   AC13 — equal-cost path pair (tie-break stability, in-process; the
#         cross-process gate is ADR-0007 / Story 005's test); empty path
#         pre-save stays empty post-load
#
# FIXTURE NOTE (AC13): the story's test evidence allows "a save-load
# round-trip harness OR a minimal grid serialize/deserialize fixture". This
# test uses the MINIMAL fixture: GridSystem.serialize()/deserialize() (grid
# story-007, already landed and unit-tested) stands in for the full SaveLoad
# pipeline — the save payload IS grid_system's serialized data, and the
# reload IS a fresh grid deserialize(..., "commit") followed by
# Navigation.rebuild(). This exercises the exact load-sequence step 4
# contract (GridSystem.deserialize → Navigation.rebuild) without the 6-system
# orchestration rig.
#
# Run standalone: godot --headless --script tests/integration/navigation/rebuild_load_cell_size_test.gd
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
	print("  INTEGRATION TEST: Navigation — Rebuild-on-Load & cell_size Independence (Story 006)")
	print("=".repeat(48))

	# AC6 — cell_size independence
	_test_ac6_same_grid_different_cell_size()
	_test_ac6_diagonal_path_identical()
	_test_ac6_empty_path_identical()
	_test_ac6_different_region_same_solidity()

	# AC13 — save → reload → rebuild round-trip
	_test_ac13_serializes_nothing()
	_test_ac13_roundtrip_returns_presave_path()
	_test_ac13_equal_cost_tiebreak_stable()
	_test_ac13_empty_path_stays_empty()

	print("\n=== REBUILD/LOAD & CELL_SIZE TEST: %d passed, %d failed ===\n" % [_pass, _fail])
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


## Makes every cell buildable — these tests care about occupancy, not room
## geometry. Returns the grid (buildable frozen).
func _make_open_grid(width: int, height: int) -> RefCounted:
	var gs := _make_grid(width, height)
	for y in height:
		for x in width:
			gs.call("set_buildable", Vector2i(x, y), true)
	gs.call("freeze_buildable")
	return gs


## The buildable_snapshot (PackedByteArray) matching an all-open grid.
func _open_snapshot(width: int, height: int) -> PackedByteArray:
	var snap := PackedByteArray()
	snap.resize(width * height)
	snap.fill(1)
	return snap


func _commit(gs: RefCounted, id: int, fp: Array[Vector2i], ac: Array[Vector2i], rot: int) -> void:
	gs.call("commit", id, fp, ac, rot)


## Builds a Navigation instance over [grid] with [cell_size] (defaults to
## the Story 001 value, Vector2.ONE). Dynamic dispatch — class_name is not
## globally registered under headless load.
func _make_navigation(grid: RefCounted, cell_size: Vector2 = Vector2.ONE) -> RefCounted:
	var NS: Script = load("res://src/systems/navigation.gd") as Script
	var nav: RefCounted = NS.new()
	nav.call("init", grid, cell_size)
	return nav


## Element-for-element equality of two path arrays (the AC6/AC13 comparison
## contract — "outputs are element-for-element identical").
func _paths_equal(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		if a[i] != b[i]:
			return false
	return true


# === AC6: cell_size 独立性 ===

## Core AC6: same grid (identical solidity), two Navigation instances with
## cell_size 16 vs 32 — identical cell-coordinate queries must return
## element-for-element identical paths. Uses an obstacle field so the path
## is multi-cell with detours (not a degenerate straight run).
func _test_ac6_same_grid_different_cell_size() -> void:
	print("\n[AC6] same solidity, cell_size 16 vs 32 — get_path((2,2),(8,7)) element-for-element identical")

	var gs := _make_open_grid(13, 10)
	# Obstacle field forcing a detour: a vertical wall at column 5, rows 0..8,
	# with a 1-cell gap at (5,4) — from (2,2) to (8,7) the path must route
	# through the gap (multi-cell, diagonal-capable).
	for y in range(9):
		if y != 4:
			_commit(gs, 100 + y, [Vector2i(5, y)], [], R0)

	var nav16 := _make_navigation(gs, Vector2(16, 16))
	var nav32 := _make_navigation(gs, Vector2(32, 32))

	var p16: Array = nav16.call("get_path", Vector2i(2, 2), Vector2i(8, 7))
	var p32: Array = nav32.call("get_path", Vector2i(2, 2), Vector2i(8, 7))

	_check(not p16.is_empty(), "AC6 path exists for (2,2)->(8,7) — got %s" % [p16])
	_check(_paths_equal(p16, p32), "AC6 cell_size 16 and 32 return element-for-element identical paths")
	_check(p16.size() >= 7, "AC6 path is multi-cell (size %d — detour through gap)" % p16.size())
	# The wall cell (5,2) must never be traversed.
	var hits_wall := false
	for cell in p16:
		if cell == Vector2i(5, 2):
			hits_wall = true
	_check(not hits_wall, "AC6 path avoids the solid wall cell (5,2)")

	# Reversed query — same property, other direction.
	var r16: Array = nav16.call("get_path", Vector2i(8, 7), Vector2i(2, 2))
	var r32: Array = nav32.call("get_path", Vector2i(8, 7), Vector2i(2, 2))
	_check(_paths_equal(r16, r32), "AC6 reversed query (8,7)->(2,2) also element-for-element identical")


## QA edge: multi-cell paths with diagonals. Open grid, dx=6 dy=5 — the
## shortest path uses 5 diagonals + 1 orthogonal step = 7 cells (not 12
## orthogonal-only). Both cell_sizes must agree on the exact diagonal path.
func _test_ac6_diagonal_path_identical() -> void:
	print("\n[AC6 edge] diagonal multi-cell path — open grid (2,2)->(8,7), 7 cells (diagonals used)")

	var gs := _make_open_grid(13, 10)
	var nav16 := _make_navigation(gs, Vector2(16, 16))
	var nav32 := _make_navigation(gs, Vector2(32, 32))

	var p16: Array = nav16.call("get_path", Vector2i(2, 2), Vector2i(8, 7))
	var p32: Array = nav32.call("get_path", Vector2i(2, 2), Vector2i(8, 7))

	_check(p16.size() == 7, "AC6 diagonal path has 7 cells (5 diag + 1 orth), got %d — %s" % [p16.size(), p16])
	_check(_paths_equal(p16, p32), "AC6 diagonal path element-for-element identical across cell_size")
	_check(p16[0] == Vector2i(2, 2) and p16[p16.size() - 1] == Vector2i(8, 7), "AC6 path endpoints correct")


## QA edge: empty-path cases. Fully walled-off from/to — both instances must
## return the SAME empty array (not null, not a divergent non-empty path).
func _test_ac6_empty_path_identical() -> void:
	print("\n[AC6 edge] empty path — full-width wall separates from/to; both instances return []")

	var gs := _make_open_grid(13, 10)
	# Full-width wall at row 5: nothing can cross from rows 0-4 to rows 6-9.
	var wall: Array[Vector2i] = []
	for x in range(13):
		wall.append(Vector2i(x, 5))
	_commit(gs, 1, wall, [], R0)

	var nav16 := _make_navigation(gs, Vector2(16, 16))
	var nav32 := _make_navigation(gs, Vector2(32, 32))

	var p16: Array = nav16.call("get_path", Vector2i(0, 0), Vector2i(12, 9))
	var p32: Array = nav32.call("get_path", Vector2i(0, 0), Vector2i(12, 9))

	_check(p16.is_empty(), "AC6 empty path returns [] (cell_size 16)")
	_check(p32.is_empty(), "AC6 empty path returns [] (cell_size 32)")
	_check(_paths_equal(p16, p32), "AC6 empty-path outputs identical (both [])")

	# Control: a path entirely on the same side of the wall still exists.
	var ok16: Array = nav16.call("get_path", Vector2i(0, 0), Vector2i(4, 4))
	_check(not ok16.is_empty(), "AC6 control — path within one side of the wall still exists")


## QA edge: different region sizes with the same solidity pattern. Two grids
## (13x10 and 8x8) share an identical wall pattern in the queried region; the
## forced route is identical in both, so all four instances (16/32 × A/B)
## must agree element-for-element.
func _test_ac6_different_region_same_solidity() -> void:
	print("\n[AC6 edge] different region sizes, same solidity pattern — all four instances identical")

	var ga := _make_open_grid(13, 10)
	var gb := _make_open_grid(8, 8)
	# Wall at row 5 spanning x=0..4 in BOTH grids (identical pattern in the
	# shared region). From (2,1) to (2,7) the ONLY crossing is right of x=4
	# (x=5), which exists in both grids → forced, identical route.
	for x in range(5):
		_commit(ga, 100 + x, [Vector2i(x, 5)], [], R0)
		_commit(gb, 100 + x, [Vector2i(x, 5)], [], R0)

	var a16 := _make_navigation(ga, Vector2(16, 16))
	var a32 := _make_navigation(ga, Vector2(32, 32))
	var b16 := _make_navigation(gb, Vector2(16, 16))
	var b32 := _make_navigation(gb, Vector2(32, 32))

	var pa16: Array = a16.call("get_path", Vector2i(2, 1), Vector2i(2, 7))
	var pa32: Array = a32.call("get_path", Vector2i(2, 1), Vector2i(2, 7))
	var pb16: Array = b16.call("get_path", Vector2i(2, 1), Vector2i(2, 7))
	var pb32: Array = b32.call("get_path", Vector2i(2, 1), Vector2i(2, 7))

	_check(not pa16.is_empty(), "AC6 region-diff path exists in 13x10 grid — %s" % [pa16])
	_check(not pb16.is_empty(), "AC6 region-diff path exists in 8x8 grid — %s" % [pb16])
	_check(_paths_equal(pa16, pa32), "AC6 13x10 grid: cell_size 16 == 32")
	_check(_paths_equal(pb16, pb32), "AC6 8x8 grid: cell_size 16 == 32")
	_check(_paths_equal(pa16, pb16), "AC6 same solidity pattern → same path across different region sizes")


# === AC13: 存档 → 重载 → 重建往返 ===

## Structural proof: Navigation has NO serialize()/deserialize() methods —
## it contributes nothing to the save file (TR-NAV-005). The absence is the
## contract; there is nothing to call.
func _test_ac13_serializes_nothing() -> void:
	print("\n[AC13] Navigation serializes nothing — no serialize()/deserialize() on the class")

	var gs := _make_open_grid(13, 10)
	var nav := _make_navigation(gs)
	_check(not nav.has_method("serialize"), "AC13 Navigation exposes no serialize() method")
	_check(not nav.has_method("deserialize"), "AC13 Navigation exposes no deserialize() method")


## Core AC13: solidity state pre-save → save (Navigation serializes nothing)
## → reload (fresh grid deserialize from the serialized payload) →
## Navigation.rebuild(occupancy) → get_path(from, to) returns the pre-save
## result, element-for-element.
func _test_ac13_roundtrip_returns_presave_path() -> void:
	print("\n[AC13] save -> reload -> rebuild — get_path returns the pre-save result")

	var gs := _make_open_grid(13, 10)
	# Solidity pattern: vertical wall at column 5 with a 1-cell gap at (5,4),
	# plus two isolated blocks — a detour-rich occupancy.
	for y in range(9):
		if y != 4:
			_commit(gs, 100 + y, [Vector2i(5, y)], [], R0)
	_commit(gs, 200, [Vector2i(2, 8), Vector2i(3, 8)], [Vector2i(2, 9)], R0)
	_commit(gs, 201, [Vector2i(9, 1)], [], R0)

	var nav := _make_navigation(gs, Vector2(16, 16))
	var from := Vector2i(2, 2)
	var to := Vector2i(8, 7)
	var pre_save: Array = nav.call("get_path", from, to)
	_check(not pre_save.is_empty(), "AC13 pre-save path exists — %s" % [pre_save])

	# "Save": the grid's serialized payload (Navigation contributes nothing —
	# asserted separately). Stands in for the save blob's grid_system key.
	var save_data: Dictionary = gs.call("serialize")

	# "Reload": fresh grid, deserialize with commit — restores occupancy.
	var restored := _make_open_grid(13, 10)
	var result: RefCounted = restored.call("deserialize", save_data, _open_snapshot(13, 10), "commit")
	_check(result.get("success") == true, "AC13 deserialize of saved grid succeeds")

	# Load-sequence step 4: rebuild Navigation from the restored occupancy.
	nav.call("rebuild", restored)
	var post_load: Array = nav.call("get_path", from, to)

	_check(_paths_equal(pre_save, post_load), "AC13 get_path after rebuild == pre-save result (element-for-element)")
	_check(not post_load.is_empty(), "AC13 post-load path is non-empty — %s" % [post_load])


## QA edge: equal-cost path pair — tie-break stability across rebuild. A
## symmetric wall creates two equal-length routes (over and under); the
## rebuild must choose the same one (in-process stability; the cross-process
## gate is ADR-0007 / Story 005's test, already PASSED).
func _test_ac13_equal_cost_tiebreak_stable() -> void:
	print("\n[AC13 edge] equal-cost path pair — tie-break stable across rebuild")

	var gs := _make_open_grid(13, 10)
	# Symmetric wall at column 6, rows 3..5: from (0,4) to (12,4) the two
	# routes (over row 2 or under row 6) are exactly equal length.
	for y in range(3, 6):
		_commit(gs, 100 + y, [Vector2i(6, y)], [], R0)

	var nav := _make_navigation(gs, Vector2(16, 16))
	var from := Vector2i(0, 4)
	var to := Vector2i(12, 4)
	var pre_save: Array = nav.call("get_path", from, to)
	_check(not pre_save.is_empty(), "AC13 equal-cost path exists pre-save — %s" % [pre_save])

	var save_data: Dictionary = gs.call("serialize")
	var restored := _make_open_grid(13, 10)
	var result: RefCounted = restored.call("deserialize", save_data, _open_snapshot(13, 10), "commit")
	_check(result.get("success") == true, "AC13 tie-break fixture deserialize succeeds")

	nav.call("rebuild", restored)
	var post_load: Array = nav.call("get_path", from, to)

	_check(_paths_equal(pre_save, post_load), "AC13 equal-cost tie-break identical across rebuild (pre-save %s, post-load %s)" % [pre_save, post_load])


## QA edge: empty path pre-save stays empty post-load. The full-width wall
## blocks the crossing both before save and after rebuild.
func _test_ac13_empty_path_stays_empty() -> void:
	print("\n[AC13 edge] empty path pre-save stays empty post-load")

	var gs := _make_open_grid(13, 10)
	var wall: Array[Vector2i] = []
	for x in range(13):
		wall.append(Vector2i(x, 5))
	_commit(gs, 1, wall, [], R0)

	var nav := _make_navigation(gs, Vector2(16, 16))
	var from := Vector2i(0, 0)
	var to := Vector2i(12, 9)
	var pre_save: Array = nav.call("get_path", from, to)
	_check(pre_save.is_empty(), "AC13 empty path pre-save returns []")

	var save_data: Dictionary = gs.call("serialize")
	var restored := _make_open_grid(13, 10)
	var result: RefCounted = restored.call("deserialize", save_data, _open_snapshot(13, 10), "commit")
	_check(result.get("success") == true, "AC13 empty-path fixture deserialize succeeds")

	nav.call("rebuild", restored)
	var post_load: Array = nav.call("get_path", from, to)
	_check(post_load.is_empty(), "AC13 empty path stays empty after rebuild — got %s" % [post_load])
