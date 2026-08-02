# tests/unit/navigation/path_query_edge_cases_test.gd
# Story 003: Path Query Edge Cases
# Covers AC4, AC5, AC14 (with the QA edge cases from the story):
#   AC4  — target fully enclosed by solid cells → empty Array[Vector2i]
#          (size 0), never null. Edge: diagonal-gap-only enclosure
#          (impassable under ONLY_IF_NO_OBSTACLES); from-cell itself
#          enclosed; from/to solid endpoints.
#   AC5  — get_path(C, C) → [C] (single element). Edge: C at grid corner;
#          C adjacent to solid cells.
#   AC14 — from/to outside the 13×10 bbox ((-1,0),(13,0),(0,10) family)
#          → empty array without throwing; is_solid(out_of_bounds)
#          independently returns true. Edge: both from and to OOB; from
#          in-bounds to OOB and vice versa.
# Plus the story-003 empty-array contract: every result is a typed
# Array[Vector2i], never null.
#
# Run standalone: godot --headless --script tests/unit/navigation/path_query_edge_cases_test.gd
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
	print("  UNIT TEST: Navigation — Path Query Edge Cases (Story 003)")
	print("=".repeat(48))

	_test_ac4_fully_enclosed_target()
	_test_ac4_diagonal_gap_only()
	_test_ac4_from_cell_enclosed()
	_test_ac4_solid_endpoints()
	_test_ac5_self_path()
	_test_ac5_corner_cell()
	_test_ac5_adjacent_to_solids()
	_test_ac14_out_of_bounds()
	_test_ac14_both_oob()
	_test_ac14_one_side_oob()
	_test_ac14_is_solid_oob()

	print("\n=== NAVIGATION PATH QUERY EDGE CASES TEST: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


# === Helpers ===

## Makes an all-buildable (empty = fully walkable) grid and returns it as a
## dynamically-dispatched RefCounted. class_name is not globally registered
## under headless load — load by path + call(), per the project test contract.
func _make_open_grid(width: int, height: int) -> RefCounted:
	var GS: Script = load("res://src/systems/grid_system.gd") as Script
	var gs: RefCounted = GS.new()
	gs.call("init", width, height)
	for y in height:
		for x in width:
			gs.call("set_buildable", Vector2i(x, y), true)
	gs.call("freeze_buildable")
	return gs


## Builds a Navigation instance over [grid] (dynamic dispatch; see above).
func _make_navigation(grid: RefCounted) -> RefCounted:
	var NS: Script = load("res://src/systems/navigation.gd") as Script
	var nav: RefCounted = NS.new()
	nav.call("init", grid)
	return nav


func _commit(gs: RefCounted, id: int, fp: Array[Vector2i], ac: Array[Vector2i], rot: int) -> void:
	gs.call("commit", id, fp, ac, rot)


## Asserts the story-003 empty-array contract on a get_path result that is
## expected to be EMPTY: typed Array[Vector2i] (builtin TYPE_VECTOR2I),
## never null, size 0.
func _check_empty_typed_array(path: Variant, label: String) -> void:
	_check(path != null, "%s — result is not null" % label)
	_check(typeof(path) == TYPE_ARRAY, "%s — result is an Array (got %s)" % [label, type_string(typeof(path))])
	_check(
		(path as Array).get_typed_builtin() == TYPE_VECTOR2I,
		"%s — result is typed Array[Vector2i] (builtin=%d)" % [label, (path as Array).get_typed_builtin()]
	)
	_check((path as Array).size() == 0, "%s — result has size 0 (got %d)" % [label, (path as Array).size()])


## Asserts the result is a non-empty typed Array[Vector2i] (used by AC5).
func _check_typed_array(path: Variant, label: String) -> void:
	_check(path != null, "%s — result is not null" % label)
	_check(typeof(path) == TYPE_ARRAY, "%s — result is an Array (got %s)" % [label, type_string(typeof(path))])
	_check(
		(path as Array).get_typed_builtin() == TYPE_VECTOR2I,
		"%s — result is typed Array[Vector2i] (builtin=%d)" % [label, (path as Array).get_typed_builtin()]
	)


# === AC4: 全封闭目标 ===

## Builds the AC4 fixture on an open 13×10 grid: target access cell (5,5)
## fully enclosed by an 8-cell ring of single-cell footprints (4 orthogonal
## + 4 diagonal flanks, matching the QA "walls on all 4 orthogonal sides +
## diagonal flanks"). The target equipment T sits at (8,8) with its ONLY
## access cell at (5,5) — unreachable from outside.
func _build_enclosed_target_fixture() -> RefCounted:
	var gs := _make_open_grid(13, 10)
	var ring: Array[Vector2i] = [
		Vector2i(4, 4), Vector2i(5, 4), Vector2i(6, 4),
		Vector2i(4, 5), Vector2i(6, 5),
		Vector2i(4, 6), Vector2i(5, 6), Vector2i(6, 6),
	]
	for i in ring.size():
		var ring_fp: Array[Vector2i] = [ring[i]]
		var ring_ac: Array[Vector2i] = []
		_commit(gs, 100 + i, ring_fp, ring_ac, R0)
	# Target T: footprint (8,8), access cell (5,5) — fully enclosed.
	var t_fp: Array[Vector2i] = [Vector2i(8, 8)]
	var t_ac: Array[Vector2i] = [Vector2i(5, 5)]
	_commit(gs, 7, t_fp, t_ac, R0)
	return gs


func _test_ac4_fully_enclosed_target() -> void:
	print("\n[AC4] target fully enclosed by solid cells → get_path((0,0),(5,5)) returns empty Array[Vector2i], never null")

	var nav := _make_navigation(_build_enclosed_target_fixture())
	var path: Variant = nav.call("get_path", Vector2i(0, 0), Vector2i(5, 5))

	_check_empty_typed_array(path, "AC4 enclosed target")
	# The enclosed access cell itself is NOT solid (GridSystem contract —
	# access cells are never solid) — it is only unreachable.
	var grid := _build_enclosed_target_fixture()
	_check(
		grid.call("is_solid", Vector2i(5, 5)) == false,
		"AC4 fixture sanity — enclosed access cell (5,5) itself is open (only surrounded)"
	)


func _test_ac4_diagonal_gap_only() -> void:
	print("\n[AC4 edge] diagonal-gap-only enclosure — impassable under DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES")

	# Fixture: only the 4 ORTHOGONAL neighbors of (5,5) are solid; the 4
	# diagonal cells stay open. Under ONLY_IF_NO_OBSTACLES, a diagonal step
	# into (5,5) requires BOTH flanking orthogonals open — they are solid,
	# so the diagonal gap is structurally impassable (GDD Diagonal Squeeze
	# edge case) → still empty.
	var gs := _make_open_grid(13, 10)
	var ortho: Array[Vector2i] = [
		Vector2i(4, 5), Vector2i(6, 5), Vector2i(5, 4), Vector2i(5, 6),
	]
	for i in ortho.size():
		var fp: Array[Vector2i] = [ortho[i]]
		var ac: Array[Vector2i] = []
		_commit(gs, 200 + i, fp, ac, R0)

	var nav := _make_navigation(gs)
	var path: Variant = nav.call("get_path", Vector2i(0, 0), Vector2i(5, 5))

	_check_empty_typed_array(path, "AC4 diagonal-gap-only enclosure")
	# Sanity: (4,5) solid, diagonal (4,4) open — the squeeze is diagonal-only.
	_check(gs.call("is_solid", Vector2i(4, 5)) == true, "AC4 fixture sanity — orthogonal (4,5) is solid")
	_check(gs.call("is_solid", Vector2i(4, 4)) == false, "AC4 fixture sanity — diagonal (4,4) is open")


func _test_ac4_from_cell_enclosed() -> void:
	print("\n[AC4 edge] from-cell itself enclosed → get_path((5,5),(0,0)) returns empty (cannot leave)")

	var nav := _make_navigation(_build_enclosed_target_fixture())
	var path: Variant = nav.call("get_path", Vector2i(5, 5), Vector2i(0, 0))

	_check_empty_typed_array(path, "AC4 from-cell enclosed")


func _test_ac4_solid_endpoints() -> void:
	print("\n[AC4 edge] from/to solid endpoints → empty array (empty-array contract covers solid endpoints)")

	var gs := _make_open_grid(13, 10)
	var fp: Array[Vector2i] = [Vector2i(3, 3)]
	var ac: Array[Vector2i] = []
	_commit(gs, 1, fp, ac, R0)

	var nav := _make_navigation(gs)

	var from_solid: Variant = nav.call("get_path", Vector2i(3, 3), Vector2i(0, 0))
	_check_empty_typed_array(from_solid, "AC4 solid from (3,3)")
	_check(gs.call("is_solid", Vector2i(3, 3)) == true, "AC4 fixture sanity — (3,3) is solid")

	var to_solid: Variant = nav.call("get_path", Vector2i(0, 0), Vector2i(3, 3))
	_check_empty_typed_array(to_solid, "AC4 solid to (3,3)")

	var both_solid: Variant = nav.call("get_path", Vector2i(3, 3), Vector2i(3, 3))
	_check_empty_typed_array(both_solid, "AC4 solid from==to (3,3)")


# === AC5: 起点等于终点 ===

func _test_ac5_self_path() -> void:
	print("\n[AC5] open cell C=(2,2) — get_path(C,C) returns [C] (single element)")

	var nav := _make_navigation(_make_open_grid(13, 10))
	var path: Variant = nav.call("get_path", Vector2i(2, 2), Vector2i(2, 2))

	_check_typed_array(path, "AC5 self-path")
	_check((path as Array).size() == 1, "AC5 path has exactly 1 element (got %d)" % (path as Array).size())
	_check((path as Array)[0] == Vector2i(2, 2), "AC5 path[0] == (2,2) (got %s)" % [(path as Array)[0]])


func _test_ac5_corner_cell() -> void:
	print("\n[AC5 edge] C at grid corner (0,0) — get_path(C,C) returns [C]")

	var nav := _make_navigation(_make_open_grid(13, 10))
	var path: Variant = nav.call("get_path", Vector2i(0, 0), Vector2i(0, 0))

	_check_typed_array(path, "AC5 corner self-path")
	_check((path as Array).size() == 1, "AC5 corner path has 1 element")
	_check((path as Array)[0] == Vector2i(0, 0), "AC5 corner path[0] == (0,0)")


func _test_ac5_adjacent_to_solids() -> void:
	print("\n[AC5 edge] open C=(2,2) adjacent to solid cells — get_path(C,C) still returns [C]")

	var gs := _make_open_grid(13, 10)
	# Solids at (3,2) and (2,3) — C=(2,2) stays open, adjacent to both.
	var fp1: Array[Vector2i] = [Vector2i(3, 2)]
	var ac1: Array[Vector2i] = []
	_commit(gs, 1, fp1, ac1, R0)
	var fp2: Array[Vector2i] = [Vector2i(2, 3)]
	var ac2: Array[Vector2i] = []
	_commit(gs, 2, fp2, ac2, R0)

	var nav := _make_navigation(gs)
	var path: Variant = nav.call("get_path", Vector2i(2, 2), Vector2i(2, 2))

	_check_typed_array(path, "AC5 adjacent-to-solids self-path")
	_check((path as Array).size() == 1, "AC5 adjacent path has 1 element")
	_check((path as Array)[0] == Vector2i(2, 2), "AC5 adjacent path[0] == (2,2)")
	_check(gs.call("is_solid", Vector2i(2, 2)) == false, "AC5 fixture sanity — C=(2,2) is open")


# === AC14: 越界查询 ===

func _test_ac14_out_of_bounds() -> void:
	print("\n[AC14] from/to outside 13×10 bbox → empty array without throwing: (-1,0), (13,0), (0,10)")

	var nav := _make_navigation(_make_open_grid(13, 10))

	var p1: Variant = nav.call("get_path", Vector2i(-1, 0), Vector2i(0, 0))
	_check_empty_typed_array(p1, "AC14 from=(-1,0)")

	var p2: Variant = nav.call("get_path", Vector2i(13, 0), Vector2i(0, 0))
	_check_empty_typed_array(p2, "AC14 from=(13,0)")

	var p3: Variant = nav.call("get_path", Vector2i(0, 0), Vector2i(0, 10))
	_check_empty_typed_array(p3, "AC14 to=(0,10)")


func _test_ac14_both_oob() -> void:
	print("\n[AC14 edge] both from and to out of bounds → empty array")

	var nav := _make_navigation(_make_open_grid(13, 10))

	var p1: Variant = nav.call("get_path", Vector2i(-1, 0), Vector2i(13, 10))
	_check_empty_typed_array(p1, "AC14 both OOB (-1,0)→(13,10)")

	var p2: Variant = nav.call("get_path", Vector2i(13, 0), Vector2i(0, 10))
	_check_empty_typed_array(p2, "AC14 both OOB (13,0)→(0,10)")


func _test_ac14_one_side_oob() -> void:
	print("\n[AC14 edge] from in-bounds to OOB and vice versa → empty array")

	var nav := _make_navigation(_make_open_grid(13, 10))

	var p1: Variant = nav.call("get_path", Vector2i(0, 0), Vector2i(-1, 5))
	_check_empty_typed_array(p1, "AC14 from in-bounds → to=(-1,5) OOB")

	var p2: Variant = nav.call("get_path", Vector2i(13, 5), Vector2i(0, 0))
	_check_empty_typed_array(p2, "AC14 from=(13,5) OOB → to in-bounds")

	# Boundary cells are NOT OOB: (12,9) is the last in-bounds cell.
	var p3: Variant = nav.call("get_path", Vector2i(12, 9), Vector2i(0, 0))
	_check(p3 != null and (p3 as Array).size() > 0, "AC14 sanity — in-bounds (12,9)→(0,0) yields a real path")


func _test_ac14_is_solid_oob() -> void:
	print("\n[AC14] is_solid(out_of_bounds) independently returns true (GridSystem contract)")

	var gs := _make_open_grid(13, 10)

	_check(gs.call("is_solid", Vector2i(-1, 0)) == true, "AC14 is_solid((-1,0)) == true")
	_check(gs.call("is_solid", Vector2i(13, 0)) == true, "AC14 is_solid((13,0)) == true")
	_check(gs.call("is_solid", Vector2i(0, 10)) == true, "AC14 is_solid((0,10)) == true")
	_check(gs.call("is_solid", Vector2i(13, 10)) == true, "AC14 is_solid((13,10)) == true")
	# In-bounds open cell must still be non-solid — the OOB default is
	# specifically about being outside the bbox, not about the mask.
	_check(gs.call("is_solid", Vector2i(5, 5)) == false, "AC14 sanity — is_solid((5,5)) == false (open, in-bounds)")
