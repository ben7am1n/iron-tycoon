# tests/unit/navigation/solidity_sync_test.gd
# Story 004: Solidity Sync via grid_changed
# Covers AC7 (grid_changed marks a path cell solid + handler pushes solidity
# and calls update() → next get_path() excludes the new solid cell),
# AC8 (same-value re-push is an idempotent no-op — get_path unchanged, no
# state corruption), and AC9 (an access cell adjacent to an occupied
# footprint is NEVER solid via the exposed is_solid accessor — white-box
# hook delegating to _astar.is_point_solid).
#
# The Navigation system under test lives in src/systems/navigation.gd
# (Story 001, parent story NV-001). This file exercises the Story 004
# increment on top of it: _post_init() subscribes to GridSystem.grid_changed,
# the handler re-queries is_solid for every changed cell and pushes it into
# AStarGrid2D, and is_solid(cell) exposes per-cell solidity for tests.
#
# ENGINE NOTE — documented deviation from the QA text (4.7.1 empirical):
# The QA negative control for AC7 says "WITHOUT calling update(), the new
# solid cell is still traversable". This is NOT reproducible in Godot 4.7.1:
# after the init update(), set_point_solid() takes effect IMMEDIATELY for
# get_id_path() (verified by probe tests/unit/navigation/set_point_solid_probe.gd —
# is_dirty stays false, path excludes the cell without any second update()).
# The vertical slice note ("set_point_solid() takes effect immediately, no
# update()/dirty needed") and the passing Story 008 integration test
# (grid_navigation_solidity_test.gd) agree. So the negative-control assertion
# below pins the ACTUAL 4.7.1 behavior (immediate effect), and the handler
# keeps its update() call per the story mandate — it is a harmless no-op
# (paths identical with/without it, probed).
#
# Run standalone: godot --headless --script tests/unit/navigation/solidity_sync_test.gd
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
	print("  UNIT TEST: Navigation — Solidity Sync via grid_changed (Story 004)")
	print("=".repeat(48))

	_test_ac7_path_cell_solid_excluded_after_handler()
	_test_ac7_single_solid_reroutes()
	_test_ac7_fully_blocked_returns_empty()
	_test_ac7_negative_control_immediate_effect_471()
	_test_ac7_clear_restores_walkability()
	_test_ac8_same_value_repush_noop()
	_test_ac8_ten_redundant_emissions_identical()
	_test_ac9_access_cell_never_solid()
	_test_ac9_access_adjacent_to_wall_still_open()
	_test_ac9_multiple_equipment_shared_access_cell()

	print("\n=== SOLIDITY SYNC TEST: %d passed, %d failed ===\n" % [_pass, _fail])
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


## Runs commit() through call() so a signature change breaks one place.
func _commit(gs: RefCounted, id: int, fp: Array[Vector2i], ac: Array[Vector2i], rot: int) -> void:
	gs.call("commit", id, fp, ac, rot)


func _clear(gs: RefCounted, id: int) -> void:
	gs.call("clear", id)


## Builds the Navigation system under test (Story 001 base + Story 004
## increment): init(grid) configures AStarGrid2D and seeds solidity;
## _post_init() subscribes to GridSystem.grid_changed (the Story 004 hook).
func _make_navigation(gs: RefCounted) -> RefCounted:
	var NAV: Script = load("res://src/systems/navigation.gd") as Script
	var nav: RefCounted = NAV.new()
	nav.call("init", gs)
	nav.call("_post_init")
	return nav


# === AC7: grid_changed marks path cell solid + handler + update() → excluded ===

func _test_ac7_path_cell_solid_excluded_after_handler() -> void:
	print("\n[AC7] open path (2,2)->(2,5); grid_changed marks (2,4) solid → next get_path excludes it")
	var gs := _make_open_grid(13, 10)
	var nav := _make_navigation(gs)

	var before: Array[Vector2i] = nav.call("get_path", Vector2i(2, 2), Vector2i(2, 5))
	_check(
		before == [Vector2i(2, 2), Vector2i(2, 3), Vector2i(2, 4), Vector2i(2, 5)],
		"baseline open path is the full column — got %s" % [before]
	)

	# grid_changed fires exactly once per commit() (S1 contract); the handler
	# re-queries is_solid((2,4)) == true and pushes it.
	_commit(gs, 1, [Vector2i(2, 4)], [], R0)

	var after: Array[Vector2i] = nav.call("get_path", Vector2i(2, 2), Vector2i(2, 5))
	_check(
		not after.has(Vector2i(2, 4)),
		"new solid cell (2,4) is excluded on the next get_path — got %s" % [after]
	)
	_check(
		after.size() >= 1 and after[after.size() - 1] == Vector2i(2, 5),
		"rerouted path still reaches the goal (2,5) — got %s" % [after]
	)
	_check(
		after != before,
		"path CHANGED after the solidity push (handler took effect, no t-1 lag)"
	)


func _test_ac7_single_solid_reroutes() -> void:
	print("\n[AC7 edge] single solid cell on a long corridor reroutes around it")
	var gs := _make_open_grid(13, 10)
	var nav := _make_navigation(gs)

	var before: Array[Vector2i] = nav.call("get_path", Vector2i(0, 5), Vector2i(12, 5))
	_check(before.size() == 13, "baseline horizontal corridor has 13 cells — got %s" % [before])

	_commit(gs, 1, [Vector2i(6, 5)], [], R0)
	var after: Array[Vector2i] = nav.call("get_path", Vector2i(0, 5), Vector2i(12, 5))
	_check(
		not after.has(Vector2i(6, 5)),
		"blocked mid-corridor cell (6,5) excluded — got %s" % [after]
	)
	_check(
		after.size() >= 1 and after[after.size() - 1] == Vector2i(12, 5),
		"reroute reaches the goal — got %s" % [after]
	)


func _test_ac7_fully_blocked_returns_empty() -> void:
	print("\n[AC7 edge] full wall across the grid → get_path returns empty (never null)")
	var gs := _make_open_grid(13, 10)
	var nav := _make_navigation(gs)

	# Wall across row 3, columns 0..12 (single-cell pieces).
	for x in range(13):
		_commit(gs, 100 + x, [Vector2i(x, 3)], [], R0)

	var path: Array[Vector2i] = nav.call("get_path", Vector2i(2, 2), Vector2i(2, 5))
	_check(
		path.is_empty(),
		"no path through a full wall — empty array, not null — got %s" % [path]
	)


func _test_ac7_negative_control_immediate_effect_471() -> void:
	print("\n[AC7 negative control] 4.7.1 empirical: set_point_solid is immediate after init")
	# The QA text negative control ("WITHOUT update() the cell is still
	# traversable") is NOT reproducible in 4.7.1 — see header ENGINE NOTE.
	# Pin the ACTUAL behavior instead: the push excludes the cell even before
	# any trailing update(). This is what makes Navigation's handler correct
	# with or without its update() call (paths identical, probed).
	var gs := _make_open_grid(13, 10)
	var nav := _make_navigation(gs)

	var before: Array[Vector2i] = nav.call("get_path", Vector2i(2, 2), Vector2i(2, 5))
	_check(before == [Vector2i(2, 2), Vector2i(2, 3), Vector2i(2, 4), Vector2i(2, 5)], "baseline open")

	# Drive the raw AStarGrid2D directly, bypassing the handler, to isolate
	# the engine primitive (mirrors probe). No update() after the push.
	var astar: AStarGrid2D = nav.get("_astar")
	astar.set_point_solid(Vector2i(2, 4), true)
	var no_update: Array[Vector2i] = astar.get_id_path(Vector2i(2, 2), Vector2i(2, 5))
	_check(
		not no_update.has(Vector2i(2, 4)),
		"4.7.1: set_point_solid alone (no trailing update) already excludes the cell — %s" % [no_update]
	)
	# A trailing update() is a no-op for correctness (idempotent).
	astar.update()
	var with_update: Array[Vector2i] = astar.get_id_path(Vector2i(2, 2), Vector2i(2, 5))
	_check(
		no_update == with_update,
		"4.7.1: path with and without trailing update() is identical (update is a harmless no-op)"
	)


func _test_ac7_clear_restores_walkability() -> void:
	print("\n[AC7 reverse] clear() emits grid_changed; handler re-queries is_solid == false → cell walkable again")
	var gs := _make_open_grid(13, 10)
	var nav := _make_navigation(gs)

	_commit(gs, 1, [Vector2i(2, 4)], [], R0)
	var blocked: Array[Vector2i] = nav.call("get_path", Vector2i(2, 2), Vector2i(2, 5))
	_check(not blocked.has(Vector2i(2, 4)), "cell solid after commit — got %s" % [blocked])

	_clear(gs, 1)
	var restored: Array[Vector2i] = nav.call("get_path", Vector2i(2, 2), Vector2i(2, 5))
	_check(
		restored == [Vector2i(2, 2), Vector2i(2, 3), Vector2i(2, 4), Vector2i(2, 5)],
		"cell walkable again after clear (handler re-queried is_solid=false) — got %s" % [restored]
	)


# === AC8: same-value re-push is an idempotent no-op ===

func _test_ac8_same_value_repush_noop() -> void:
	print("\n[AC8] grid_changed fires for a cell whose solidity did NOT change → get_path unchanged, no corruption")
	var gs := _make_open_grid(13, 10)
	var nav := _make_navigation(gs)

	# Commit A: footprint (2,4) → solid.
	_commit(gs, 1, [Vector2i(2, 4)], [], R0)
	var after_a: Array[Vector2i] = nav.call("get_path", Vector2i(2, 2), Vector2i(2, 5))
	_check(not after_a.has(Vector2i(2, 4)), "solid after commit A — got %s" % [after_a])

	# Commit B: footprint elsewhere, access cell (2,4) — the grid_changed
	# payload includes (2,4) as an ACCESS cell; the handler re-queries
	# is_solid((2,4)) == true (still occupied) and re-pushes the SAME value.
	_commit(gs, 2, [Vector2i(5, 5)], [Vector2i(2, 4)], R0)

	var after_b: Array[Vector2i] = nav.call("get_path", Vector2i(2, 2), Vector2i(2, 5))
	_check(
		after_b == after_a,
		"same-value re-push leaves get_path identical — got %s" % [after_b]
	)
	# No corruption: the still-occupied cell stays solid.
	_check(not after_b.has(Vector2i(2, 4)), "cell remains solid after re-push")


func _test_ac8_ten_redundant_emissions_identical() -> void:
	print("\n[AC8 edge] 10x redundant emissions on the same cell → identical results every time")
	var gs := _make_open_grid(13, 10)
	var nav := _make_navigation(gs)

	_commit(gs, 1, [Vector2i(2, 4)], [], R0)
	var reference: Array[Vector2i] = nav.call("get_path", Vector2i(2, 2), Vector2i(2, 5))
	_check(not reference.has(Vector2i(2, 4)), "reference path excludes (2,4) — got %s" % [reference])

	# 10 redundant re-pushes of the SAME solidity (via access-cell commits on
	# distinct pieces — each fires grid_changed with (2,4) in the payload).
	# Footprints stay in bounds: rows 0..9 on the 13x10 grid.
	var all_identical := true
	var last: Array[Vector2i] = reference
	for i in range(10):
		var piece_id := 100 + i
		_commit(gs, piece_id, [Vector2i(8, i)], [Vector2i(2, 4)], R0)
		var current: Array[Vector2i] = nav.call("get_path", Vector2i(2, 2), Vector2i(2, 5))
		if current != last:
			all_identical = false
			print("    divergence at emission #%d: %s" % [i, current])
		last = current

	_check(all_identical, "10x redundant emissions produce identical get_path results (idempotent no-op)")


# === AC9: access cells are never solid (white-box is_solid hook) ===

func _test_ac9_access_cell_never_solid() -> void:
	print("\n[AC9] access cell (2,0) adjacent to occupied footprint (0,0),(1,0) is never solid")
	var gs := _make_open_grid(13, 10)
	var nav := _make_navigation(gs)

	_commit(gs, 1, [Vector2i(0, 0), Vector2i(1, 0)], [Vector2i(2, 0)], R0)

	_check(
		bool(nav.call("is_solid", Vector2i(2, 0))) == false,
		"access cell (2,0) reads non-solid via the exposed is_solid accessor"
	)
	_check(
		bool(nav.call("is_solid", Vector2i(0, 0))) == true,
		"footprint cell (0,0) reads solid (hook agrees with occupancy)"
	)
	_check(
		bool(nav.call("is_solid", Vector2i(1, 0))) == true,
		"footprint cell (1,0) reads solid"
	)
	# The hook must reflect the grid_changed push — verify via pathfinding too.
	var path: Array[Vector2i] = nav.call("get_path", Vector2i(2, 0), Vector2i(5, 0))
	_check(
		not path.is_empty(),
		"a path can START on the access cell (it is walkable) — got %s" % [path]
	)


func _test_ac9_access_adjacent_to_wall_still_open() -> void:
	print("\n[AC9 edge] access cell adjacent to a wall (footprint) stays non-solid")
	var gs := _make_open_grid(13, 10)
	var nav := _make_navigation(gs)

	# Wall footprint at (2,1); access cell (2,0) directly below it.
	_commit(gs, 1, [Vector2i(2, 1)], [Vector2i(2, 0)], R0)

	_check(
		bool(nav.call("is_solid", Vector2i(2, 0))) == false,
		"access cell (2,0) next to wall footprint (2,1) reads non-solid"
	)
	_check(
		bool(nav.call("is_solid", Vector2i(2, 1))) == true,
		"the wall footprint (2,1) itself reads solid"
	)


func _test_ac9_multiple_equipment_shared_access_cell() -> void:
	print("\n[AC9 edge] multiple equipment sharing one access cell → still non-solid")
	var gs := _make_open_grid(13, 10)
	var nav := _make_navigation(gs)

	_commit(gs, 1, [Vector2i(7, 6)], [Vector2i(7, 7)], R0)
	_commit(gs, 2, [Vector2i(8, 8)], [Vector2i(7, 7)], R0)
	_commit(gs, 3, [Vector2i(9, 9)], [Vector2i(7, 7), Vector2i(10, 8)], R0)

	_check(
		bool(nav.call("is_solid", Vector2i(7, 7))) == false,
		"shared access cell (7,7) reads non-solid after 3 pieces registered it"
	)
	_check(
		bool(nav.call("is_solid", Vector2i(10, 8))) == false,
		"second access cell (10,8) reads non-solid"
	)
	_check(
		bool(nav.call("is_solid", Vector2i(7, 6))) == true,
		"footprint (7,6) reads solid (access contention does not affect it)"
	)
