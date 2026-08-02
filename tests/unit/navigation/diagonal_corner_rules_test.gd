# tests/unit/navigation/diagonal_corner_rules_test.gd
# Story 002: Diagonal Mode and Corner Clipping Rules
# Covers GDD AC3 (a)-(d) — the full 4-permutation flank matrix around
# target (1,1) from (0,0), under DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES:
#   (a) (1,0) solid / (0,1) open  → no direct diagonal; route around via (0,1); length ≥ 3
#   (b) (0,1) solid / (1,0) open  → mirror; route around via (1,0); length ≥ 3
#   (c) both flanks solid         → empty (no route)
#   (d) both flanks open          → direct diagonal allowed; length 2
# Plus the QA edge case: longer diagonal runs (e.g. (0,0)→(5,5)) use
# diagonals throughout (length 6).
#
# The behavior under test is PROVIDED BY the AStarGrid2D mode itself
# (DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES) — Navigation adds no special handling.
# This test pins the mode's semantics to the GDD (Pillar 3: members never
# clip through solid corners). It is deliberately written as a black-box
# Navigation test: grid built through GridSystem.commit() (the production
# solidity source), paths queried through Navigation.get_path().
#
# Run standalone: godot --headless --script tests/unit/navigation/diagonal_corner_rules_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const NAV_SCRIPT := preload("res://src/systems/navigation.gd")

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
	print("  UNIT TEST: Navigation — Diagonal Mode & Corner Clipping (Story 002)")
	print("=".repeat(48))

	_test_ac3a_right_flank_solid()
	_test_ac3b_down_flank_solid()
	_test_ac3c_both_flanks_solid()
	_test_ac3d_both_flanks_open()
	_test_ac3d_edge_longer_diagonal_run()

	print("\n=== DIAGONAL CORNER RULES TEST: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


# === Helpers ===

func _make_open_grid(width: int, height: int) -> RefCounted:
	var GS: Script = load("res://src/systems/grid_system.gd") as Script
	var gs: RefCounted = GS.new()
	gs.call("init", width, height)
	for y in height:
		for x in width:
			gs.call("set_buildable", Vector2i(x, y), true)
	gs.call("freeze_buildable")
	return gs


## Commits single-cell footprints (making those cells solid) — the
## production solidity source Navigation reads at init.
## NOTE: commit() takes typed Array[Vector2i]; bare [] literals passed via
## .call() fail the typed-array check (4.7.1 pitfall) — always build typed.
func _commit_single_cells(gs: RefCounted, cells: Array[Vector2i]) -> void:
	var id := 0
	for c in cells:
		var fp: Array[Vector2i] = [c]
		var ac: Array[Vector2i] = []
		gs.call("commit", id, fp, ac, 0)
		id += 1


## Builds Navigation over the given grid (production wiring: init reads
## GridSystem.is_solid() for every cell and calls update()).
func _make_navigation(gs: RefCounted) -> RefCounted:
	var nav: RefCounted = NAV_SCRIPT.new()
	nav.call("init", gs)
	return nav


## Asserts the path never contains a direct (0,0)→(1,1) diagonal step.
## Under ONLY_IF_NO_OBSTACLES the direct diagonal is the 2-element path;
## any path of length ≥ 3 trivially avoids it, but the check is explicit
## so the assertion survives a future engine change that reorders steps.
func _assert_no_direct_diagonal(path: Array[Vector2i], label: String) -> void:
	_check(
		not (path.size() == 2 and path[0] == Vector2i(0, 0) and path[1] == Vector2i(1, 1)),
		"%s: path never steps directly (0,0)->(1,1)" % label
	)


# === AC3(a): (1,0) solid / (0,1) open → route around via (0,1) ===

func _test_ac3a_right_flank_solid() -> void:
	print("\n[AC3(a)] right flank (1,0) solid, down flank (0,1) open — route around via (0,1)")

	var gs := _make_open_grid(13, 10)
	_commit_single_cells(gs, [Vector2i(1, 0)])

	var nav := _make_navigation(gs)
	var path: Array[Vector2i] = nav.call("get_path", Vector2i(0, 0), Vector2i(1, 1))

	_check(not path.is_empty(), "AC3(a): a route exists (got %s)" % [path])
	_check(
		path.size() >= 3,
		"AC3(a): path length >= 3 (routes around, got %d: %s)" % [path.size(), path]
	)
	_assert_no_direct_diagonal(path, "AC3(a)")
	_check(
		path.has(Vector2i(0, 1)),
		"AC3(a): route passes through the open flank (0,1) (got %s)" % [path]
	)
	# The solid flank must never be traversed.
	_check(
		not path.has(Vector2i(1, 0)),
		"AC3(a): solid flank (1,0) never traversed"
	)
	# Sanity: start/end correct.
	_check(path[0] == Vector2i(0, 0) and path[path.size() - 1] == Vector2i(1, 1), "AC3(a): path starts at (0,0) and ends at (1,1)")


# === AC3(b): (0,1) solid / (1,0) open → route around via (1,0) (mirror) ===

func _test_ac3b_down_flank_solid() -> void:
	print("\n[AC3(b)] down flank (0,1) solid, right flank (1,0) open — route around via (1,0)")

	var gs := _make_open_grid(13, 10)
	_commit_single_cells(gs, [Vector2i(0, 1)])

	var nav := _make_navigation(gs)
	var path: Array[Vector2i] = nav.call("get_path", Vector2i(0, 0), Vector2i(1, 1))

	_check(not path.is_empty(), "AC3(b): a route exists (got %s)" % [path])
	_check(
		path.size() >= 3,
		"AC3(b): path length >= 3 (routes around, got %d: %s)" % [path.size(), path]
	)
	_assert_no_direct_diagonal(path, "AC3(b)")
	_check(
		path.has(Vector2i(1, 0)),
		"AC3(b): route passes through the open flank (1,0) (got %s)" % [path]
	)
	_check(
		not path.has(Vector2i(0, 1)),
		"AC3(b): solid flank (0,1) never traversed"
	)
	_check(path[0] == Vector2i(0, 0) and path[path.size() - 1] == Vector2i(1, 1), "AC3(b): path starts at (0,0) and ends at (1,1)")


# === AC3(c): both flanks solid → empty (no route) ===

func _test_ac3c_both_flanks_solid() -> void:
	print("\n[AC3(c)] both flanks solid — target unreachable, empty path")

	var gs := _make_open_grid(13, 10)
	_commit_single_cells(gs, [Vector2i(1, 0), Vector2i(0, 1)])

	var nav := _make_navigation(gs)
	var path: Array[Vector2i] = nav.call("get_path", Vector2i(0, 0), Vector2i(1, 1))

	_check(
		path.is_empty(),
		"AC3(c): returns empty array (no route) — got %s" % [path]
	)
	_check(
		path.size() == 0,
		"AC3(c): path size is exactly 0 (got %d)" % path.size()
	)


# === AC3(d): both flanks open → direct diagonal allowed, length 2 ===

func _test_ac3d_both_flanks_open() -> void:
	print("\n[AC3(d)] both flanks open — direct diagonal allowed")

	var gs := _make_open_grid(13, 10)
	# No solid cells at all — pure open grid.

	var nav := _make_navigation(gs)
	var path: Array[Vector2i] = nav.call("get_path", Vector2i(0, 0), Vector2i(1, 1))

	_check(
		path == [Vector2i(0, 0), Vector2i(1, 1)],
		"AC3(d): direct diagonal (0,0)->(1,1) allowed, path length 2 (got %s)" % [path]
	)


# === AC3(d) QA edge: longer diagonal runs use diagonals throughout ===

func _test_ac3d_edge_longer_diagonal_run() -> void:
	print("\n[AC3(d) edge] longer diagonal run (0,0)->(5,5) uses diagonals throughout")

	var gs := _make_open_grid(13, 10)
	var nav := _make_navigation(gs)
	var path: Array[Vector2i] = nav.call("get_path", Vector2i(0, 0), Vector2i(5, 5))

	_check(
		path.size() == 6,
		"AC3(d) edge: (0,0)->(5,5) has 6 elements (5 diagonal steps), got %d: %s" % [path.size(), path]
	)
	_check(
		path[0] == Vector2i(0, 0) and path[path.size() - 1] == Vector2i(5, 5),
		"AC3(d) edge: starts at (0,0) and ends at (5,5)"
	)
