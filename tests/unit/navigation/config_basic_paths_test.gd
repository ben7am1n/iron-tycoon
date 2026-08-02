# tests/unit/navigation/config_basic_paths_test.gd
# Story 001: AStarGrid2D Configuration and Basic Paths
# Covers AC1, AC2, AC15 (with the QA edge cases from the story):
#   AC1  — empty grid get_path((2,2),(2,5)) == [(2,2),(2,3),(2,4),(2,5)]
#          edge: adjacent cells (path length 1); reversed direction
#   AC2  — get_path((0,0),(3,3)) has 4 elements (diagonals used), not 7;
#          edge: path cost == 3*sqrt(2) ~= 4.2426, not 6.0
#   AC15 — dx=3, dy=2, no obstacles: summed step costs == 2*sqrt(2) + 1.0
#          within float tolerance; edge: pure diagonal n*sqrt(2);
#          edge: pure orthogonal n*1.0
# Plus TR-NAV-001 black-box config proof: jumping_enabled=false honored
# (a long straight run returns EVERY intermediate cell, never jump points).
# Run standalone: godot --headless --script tests/unit/navigation/config_basic_paths_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

## sqrt(2) step cost (TR-NAV-007 / path_step_cost). Literal, not sqrt(2.0),
## so the expected value is pinned and immune to const-folding edge cases.
const SQRT2 := 1.4142135623730951

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
	print("  UNIT TEST: Navigation — AStarGrid2D Config & Basic Paths (Story 001)")
	print("=".repeat(48))

	_test_ac1_straight_line()
	_test_ac1_adjacent_cells()
	_test_ac1_reversed_direction()
	_test_ac2_diagonal_used()
	_test_ac2_diagonal_cost()
	_test_ac15_mixed_step_cost()
	_test_ac15_pure_diagonal()
	_test_ac15_pure_orthogonal()
	_test_jumping_disabled_full_cell_path()

	print("\n=== NAVIGATION CONFIG & BASIC PATHS TEST: %d passed, %d failed ===\n" % [_pass, _fail])
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


## Sums the path_step_cost over consecutive cells of a returned path
## (TR-NAV-007): 1.0 orthogonal, sqrt(2) diagonal. Called with the ACTUAL
## path array — never an assumed one — so the assertion validates the path
## Navigation actually returned.
func _sum_step_costs(path: Array) -> float:
	var total := 0.0
	for i in range(1, path.size()):
		var a: Vector2i = path[i - 1]
		var b: Vector2i = path[i]
		var dx := absi(b.x - a.x)
		var dy := absi(b.y - a.y)
		if dx == 1 and dy == 1:
			total += SQRT2
		elif dx + dy == 1:
			total += 1.0
		else:
			# Non-adjacent step would mean the path jumped cells — flag it
			# loudly inside the sum so the cost assertion fails visibly.
			total += 999.0
	return total


# === AC1: 空网格直线路径 ===

func _test_ac1_straight_line() -> void:
	print("\n[AC1] empty grid — get_path((2,2),(2,5)) returns exactly [(2,2),(2,3),(2,4),(2,5)]")

	var nav := _make_navigation(_make_open_grid(13, 10))
	var path: Array = nav.call("get_path", Vector2i(2, 2), Vector2i(2, 5))

	var expected: Array = [
		Vector2i(2, 2), Vector2i(2, 3), Vector2i(2, 4), Vector2i(2, 5),
	]
	_check(
		path.size() == 4,
		"path has 4 cells (got %d)" % path.size()
	)
	_check(
		path == expected,
		"path is exactly [(2,2),(2,3),(2,4),(2,5)] (got %s)" % [path]
	)


func _test_ac1_adjacent_cells() -> void:
	print("\n[AC1 edge] adjacent cells — path length 1: get_path((2,2),(2,3))")

	var nav := _make_navigation(_make_open_grid(13, 10))
	var path: Array = nav.call("get_path", Vector2i(2, 2), Vector2i(2, 3))

	var expected: Array = [Vector2i(2, 2), Vector2i(2, 3)]
	_check(
		path == expected,
		"adjacent cells yield exactly [(2,2),(2,3)] (got %s)" % [path]
	)


func _test_ac1_reversed_direction() -> void:
	print("\n[AC1 edge] reversed direction — get_path((2,5),(2,2))")

	var nav := _make_navigation(_make_open_grid(13, 10))
	var path: Array = nav.call("get_path", Vector2i(2, 5), Vector2i(2, 2))

	var expected: Array = [
		Vector2i(2, 5), Vector2i(2, 4), Vector2i(2, 3), Vector2i(2, 2),
	]
	_check(
		path == expected,
		"reversed query returns [(2,5),(2,4),(2,3),(2,2)] (got %s)" % [path]
	)


# === AC2: 对角线使用 ===

func _test_ac2_diagonal_used() -> void:
	print("\n[AC2] empty grid — get_path((0,0),(3,3)) has 4 elements (diagonals used), not 7")

	var nav := _make_navigation(_make_open_grid(13, 10))
	var path: Array = nav.call("get_path", Vector2i(0, 0), Vector2i(3, 3))

	_check(
		path.size() == 4,
		"path has 4 elements, not 7 (got %d) — diagonals are used" % path.size()
	)
	_check(
		path[0] == Vector2i(0, 0) and path[path.size() - 1] == Vector2i(3, 3),
		"path starts at (0,0) and ends at (3,3) (got %s)" % [path]
	)


func _test_ac2_diagonal_cost() -> void:
	print("\n[AC2 edge] (0,0)->(3,3) cost == 3*sqrt(2) ~= 4.2426, not 6.0 (orthogonal-only)")

	var nav := _make_navigation(_make_open_grid(13, 10))
	var path: Array = nav.call("get_path", Vector2i(0, 0), Vector2i(3, 3))

	var cost := _sum_step_costs(path)
	_check(
		absf(cost - 3.0 * SQRT2) < 0.0001,
		"summed step cost == 3*sqrt(2) (got %.6f, expected %.6f)" % [cost, 3.0 * SQRT2]
	)
	_check(
		absf(cost - 6.0) > 0.0001,
		"cost is NOT the orthogonal-only 6.0 (got %.6f)" % cost
	)


# === AC15: 步长成本 ===

func _test_ac15_mixed_step_cost() -> void:
	print("\n[AC15] dx=3, dy=2, no obstacles — summed step costs == 2*sqrt(2) + 1*1.0")

	var nav := _make_navigation(_make_open_grid(13, 10))
	# Displacement (3,2): shortest octile path = 2 diagonals + 1 orthogonal.
	var path: Array = nav.call("get_path", Vector2i(0, 0), Vector2i(3, 2))

	var expected := 2.0 * SQRT2 + 1.0
	var cost := _sum_step_costs(path)
	_check(
		absf(cost - expected) < 0.0001,
		"summed step cost == 2*sqrt(2) + 1.0 (got %.6f, expected %.6f)" % [cost, expected]
	)
	_check(
		path.size() == 4,
		"3-step path has 4 cells (got %d)" % path.size()
	)


func _test_ac15_pure_diagonal() -> void:
	print("\n[AC15 edge] pure diagonal dx=dy=4 — summed step costs == 4*sqrt(2)")

	var nav := _make_navigation(_make_open_grid(13, 10))
	var path: Array = nav.call("get_path", Vector2i(0, 0), Vector2i(4, 4))

	var expected := 4.0 * SQRT2
	var cost := _sum_step_costs(path)
	_check(
		absf(cost - expected) < 0.0001,
		"pure diagonal cost == 4*sqrt(2) (got %.6f, expected %.6f)" % [cost, expected]
	)
	_check(
		path.size() == 5,
		"pure diagonal path has 5 cells (got %d)" % path.size()
	)


func _test_ac15_pure_orthogonal() -> void:
	print("\n[AC15 edge] pure orthogonal dx=4, dy=0 — summed step costs == 4*1.0")

	var nav := _make_navigation(_make_open_grid(13, 10))
	var path: Array = nav.call("get_path", Vector2i(0, 0), Vector2i(4, 0))

	var expected := 4.0
	var cost := _sum_step_costs(path)
	_check(
		absf(cost - expected) < 0.0001,
		"pure orthogonal cost == 4.0 (got %.6f, expected %.6f)" % [cost, expected]
	)


# === TR-NAV-001 black-box config proof: jumping_enabled=false ===

func _test_jumping_disabled_full_cell_path() -> void:
	print("\n[TR-NAV-001] jumping_enabled=false — long straight run returns every cell, never jump points")

	var nav := _make_navigation(_make_open_grid(13, 10))
	# With JPS enabled, get_id_path((0,0),(5,0)) collapses to [(0,0),(5,0)]
	# (probed 4.7.1). With jumping disabled it must return all 6 cells.
	var path: Array = nav.call("get_path", Vector2i(0, 0), Vector2i(5, 0))

	var expected: Array = [
		Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0),
		Vector2i(3, 0), Vector2i(4, 0), Vector2i(5, 0),
	]
	_check(
		path == expected,
		"full 6-cell path returned (got %s) — jumping is disabled" % [path]
	)
