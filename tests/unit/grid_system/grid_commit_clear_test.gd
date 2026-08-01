# tests/unit/grid_system/grid_commit_clear_test.gd
# Story 005: Commit, Clear, and Reverse Index
# Covers AC-C7.1, AC-C7.2, AC-C7.3, AC-C7.7 (blocking), AC-C7.8
# (advisory/documentation), the instance_id=0 legal pitfall, guard paths
# (before-init), and the grid_changed once-per-commit/clear signal contract.
# The literal "push_error() fires" clause of AC-C7.2/C7.3/C7.7 is verified
# via the subprocess probe grid_commit_clear_error_probe.gd (see the
# _test_push_error_firing_probe method) — GDScript has no in-process
# push_error capture, so the same subprocess-isolation pattern Story 003
# established for assert() is used (see docs/tech-debt-register.md, Story
# 002/003 entries for the project-wide limitation).
# Run standalone: godot --headless --script tests/unit/grid_system/grid_commit_clear_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

# Rotation values mirror GridSystem.Rotation (degree-valued).
const R0 := 0
const R90 := 90
const R180 := 180
const R270 := 270

# Subprocess probe path — keep in sync with grid_commit_clear_error_probe.gd.
const PROBE_SCRIPT_PATH := "res://tests/unit/grid_system/grid_commit_clear_error_probe.gd"

var _pass := 0
var _fail := 0

# grid_changed observation state — reset per _connect_signal().
var _signal_count := 0
var _last_footprint: Array = []
var _last_access: Array = []


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
	print("  UNIT TEST: GridSystem — Commit / Clear / Reverse Index (Story 005)")
	print("=".repeat(48))

	_test_ac_c7_1_commit_clear_round_trip()
	_test_ac_c7_1_clear_2x2_footprint()
	_test_ac_c7_1_clear_zero_access_cells()
	_test_ac_c7_2_duplicate_commit_rejected()
	_test_ac_c7_3_clear_unknown_id()
	_test_ac_c7_7_negative_instance_id_rejected()
	_test_ac_c7_8_id_reuse_accepted()
	_test_pitfall_instance_id_zero_legal()
	_test_guard_commit_clear_before_init()
	_test_signal_contract_commit()
	_test_signal_contract_clear()
	_test_push_error_firing_probe()

	print("\n=== GRID COMMIT/CLEAR TEST: %d passed, %d failed ===\n" % [_pass, _fail])
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


## Makes every cell buildable — commit/clear tests care about occupancy /
## access, not room geometry, so start from an all-open room.
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


## Runs clear() through call().
func _clear(gs: RefCounted, id: int) -> void:
	gs.call("clear", id)


## Full-grid snapshot via the PUBLIC read API only — occupant_id, buildable,
## and access_ids for every cell. get_snapshot() itself is Story 006; this
## stand-in is the same one Story 004 used to satisfy "full-grid snapshot
## before and after is exactly equal" with the read surface available today.
func _full_snapshot(gs: RefCounted) -> Dictionary:
	var dims: Vector2i = gs.call("get_dimensions")
	var occ := {}
	var bld := {}
	var acc := {}
	for y in dims.y:
		for x in dims.x:
			var cell := Vector2i(x, y)
			occ[cell] = gs.call("get_occupant_id", cell)
			bld[cell] = gs.call("get_buildable", cell)
			acc[cell] = gs.call("get_access_ids", cell)
	return {"occupant": occ, "buildable": bld, "access": acc}


## Reverse-index observation. The index is deliberately NOT public API
## (Control Manifest: Forbidden), but tests must prove the record contents
## survive a rejected duplicate commit (AC-C7.2) and that clear() removes
## the entry — Object.get() reads private state without adding API surface.
func _reverse_index(gs: RefCounted) -> Dictionary:
	return gs.get("_reverse_index")


## Connects grid_changed and resets observation counters. Each test creates
## its own grid, so counters are reset per connect.
func _connect_signal(gs: RefCounted) -> void:
	_signal_count = 0
	_last_footprint = []
	_last_access = []
	gs.connect("grid_changed", Callable(self, "_on_grid_changed"))


func _on_grid_changed(footprint_changed: Array, access_changed: Array) -> void:
	_signal_count += 1
	_last_footprint = footprint_changed
	_last_access = access_changed


## Runs grid_commit_clear_error_probe.gd in an ISOLATED subprocess so the
## child's push_error() output ("ERROR: GridSystem: ...") can be asserted
## on directly — GDScript provides no in-process push_error capture.
## Pattern copied from grid_rotation_test.gd's _run_probe (Story 003's
## subprocess-isolation resolution for assert()-style ACs).
##
## Returns {"errored": bool, "output": String, "exit_code": int}.
## "errored" is true iff the merged stdout+stderr contains "ERROR:"
## (push_error's format; OS.execute(read_stderr=true) merges both streams).
func _run_probe(mode: String) -> Dictionary:
	var exe := OS.get_executable_path()
	var project_root := ProjectSettings.globalize_path("res://")
	var probe_path := ProjectSettings.globalize_path(PROBE_SCRIPT_PATH)

	var args: Array[String] = ["--headless", "--path", project_root, "--script", probe_path, "--", mode]

	var output: Array = []
	var exit_code := OS.execute(exe, args, output, true)
	var output_text: String = "".join(output)

	return {"errored": output_text.find("ERROR:") != -1, "output": output_text, "exit_code": exit_code}


# === AC-C7.1: commit→clear 往返 —— 反向索引被正确使用 ===

func _test_ac_c7_1_commit_clear_round_trip() -> void:
	print("\n[AC-C7.1] commit(id=9, fp=[(1,1)], ac=[(1,2)]) then clear(9) — round trip")

	var gs := _make_open_grid(10, 10)
	_connect_signal(gs)

	var fp: Array[Vector2i] = [Vector2i(1, 1)]
	var ac: Array[Vector2i] = [Vector2i(1, 2)]
	_commit(gs, 9, fp, ac, R0)

	# Post-commit state.
	_check(
		gs.call("get_occupant_id", Vector2i(1, 1)) == 9,
		"after commit: (1,1) occupant_id == 9"
	)
	_check(
		(gs.call("get_access_ids", Vector2i(1, 2)) as Array) == [9],
		"after commit: (1,2) access_ids == [9]"
	)
	_check(
		_reverse_index(gs).has(9),
		"after commit: reverse index contains instance_id 9"
	)
	_check(
		_signal_count == 1,
		"after commit: grid_changed emitted exactly once (count=%d)" % _signal_count
	)

	# Immediately clear.
	_clear(gs, 9)

	_check(
		gs.call("get_occupant_id", Vector2i(1, 1)) == -1,
		"after clear: (1,1) occupant_id back to -1"
	)
	_check(
		(gs.call("get_access_ids", Vector2i(1, 2)) as Array).is_empty(),
		"after clear: (1,2) access_ids no longer contains 9"
	)
	_check(
		not _reverse_index(gs).has(9),
		"after clear: reverse index no longer contains instance_id 9 — clear resolved cells via the index"
	)
	_check(
		_signal_count == 2,
		"after clear: grid_changed emitted exactly once more (count=%d) — one per clear, not per cell" % _signal_count
	)

	# Cell-level regression: the cleared cell is reusable for a new commit.
	_commit(gs, 10, fp, ac, R0)
	_check(
		gs.call("get_occupant_id", Vector2i(1, 1)) == 10,
		"after clear + re-commit: (1,1) reusable, occupant_id == 10"
	)


# === AC-C7.1 QA edge: 2×2 footprint ===

func _test_ac_c7_1_clear_2x2_footprint() -> void:
	print("\n[AC-C7.1 edge] clear() of a 2x2 footprint equipment")

	var gs := _make_open_grid(10, 10)
	var fp: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]
	var ac: Array[Vector2i] = [Vector2i(0, 2), Vector2i(1, 2)]
	_commit(gs, 9, fp, ac, R0)

	# All 4 footprint cells occupied.
	var all_occupied := true
	for c in fp:
		if gs.call("get_occupant_id", c) != 9:
			all_occupied = false
	_check(all_occupied, "2x2 commit: all 4 footprint cells occupied by 9")

	_clear(gs, 9)

	var all_cleared := true
	for c in fp:
		if gs.call("get_occupant_id", c) != -1:
			all_cleared = false
	_check(all_cleared, "2x2 clear: all 4 footprint cells back to -1")
	for c in ac:
		_check(
			(gs.call("get_access_ids", c) as Array).is_empty(),
			"2x2 clear: access cell %s has no access_ids left" % c
		)


# === AC-C7.1 QA edge: 0 access cells（装饰物/储物柜） ===

func _test_ac_c7_1_clear_zero_access_cells() -> void:
	print("\n[AC-C7.1 edge] clear() of equipment with access_cells=[]")

	var gs := _make_open_grid(5, 5)
	var fp: Array[Vector2i] = [Vector2i(2, 2)]
	var ac_empty: Array[Vector2i] = []
	_commit(gs, 11, fp, ac_empty, R0)

	_check(
		gs.call("get_occupant_id", Vector2i(2, 2)) == 11,
		"zero-access commit: (2,2) occupied by 11"
	)

	_clear(gs, 11)

	_check(
		gs.call("get_occupant_id", Vector2i(2, 2)) == -1,
		"zero-access clear: (2,2) back to -1"
	)
	_check(
		not _reverse_index(gs).has(11),
		"zero-access clear: reverse index entry removed"
	)


# === AC-C7.2: 重复 id commit 被拒 —— 拒绝发生在任何 cell 写入之前 ===

func _test_ac_c7_2_duplicate_commit_rejected() -> void:
	print("\n[AC-C7.2] duplicate commit(9, different cells) rejected — old record NOT overwritten")

	var gs := _make_open_grid(10, 10)
	_connect_signal(gs)

	var fp_old: Array[Vector2i] = [Vector2i(1, 1)]
	var ac_old: Array[Vector2i] = [Vector2i(1, 2)]
	_commit(gs, 9, fp_old, ac_old, R0)

	var before := _full_snapshot(gs)
	var count_before := _signal_count

	# Second commit with DIFFERENT cells (and a different rotation) — must be rejected.
	var fp_new: Array[Vector2i] = [Vector2i(3, 3)]
	var ac_new: Array[Vector2i] = [Vector2i(3, 4)]
	_commit(gs, 9, fp_new, ac_new, R90)

	_check(
		before == _full_snapshot(gs),
		"duplicate commit rejected: full-grid snapshot unchanged (atomic — no cell writes)"
	)
	var record: Dictionary = _reverse_index(gs)
	var old_record = record[9]
	_check(
		old_record.footprint_cells == fp_old,
		"duplicate commit rejected: old record NOT overwritten — footprint_cells still %s (got %s)" % [fp_old, old_record.footprint_cells]
	)
	_check(
		old_record.access_cells == ac_old,
		"duplicate commit rejected: old record access_cells still %s (got %s)" % [ac_old, old_record.access_cells]
	)
	_check(
		old_record.rotation == R0,
		"duplicate commit rejected: old record rotation still R0 (got %d)" % old_record.rotation
	)
	_check(
		gs.call("get_occupant_id", Vector2i(1, 1)) == 9,
		"duplicate commit rejected: old cell (1,1) still occupied by 9"
	)
	_check(
		gs.call("get_occupant_id", Vector2i(3, 3)) == -1,
		"duplicate commit rejected: NEW cell (3,3) NOT written (reject precedes writes)"
	)
	_check(
		(gs.call("get_access_ids", Vector2i(3, 4)) as Array).is_empty(),
		"duplicate commit rejected: NEW access cell (3,4) has no ids (reject precedes writes)"
	)
	_check(
		_signal_count == count_before,
		"duplicate commit rejected: no grid_changed emitted for the rejected call (count=%d)" % _signal_count
	)


# === AC-C7.3: 清除不存在的 id —— 无变更、无信号 ===

func _test_ac_c7_3_clear_unknown_id() -> void:
	print("\n[AC-C7.3] clear(99) where 99 was never committed — no mutation, no signal")

	var gs := _make_open_grid(10, 10)
	_connect_signal(gs)
	# Give the grid real state so "no mutation" is a meaningful comparison.
	_commit(gs, 1, [Vector2i(1, 1)], [Vector2i(1, 2)], R0)
	_commit(gs, 2, [Vector2i(4, 4), Vector2i(4, 5)], [], R0)
	var count_before := _signal_count

	var before := _full_snapshot(gs)
	var index_before: Dictionary = _reverse_index(gs).duplicate()

	_clear(gs, 99)

	_check(
		before == _full_snapshot(gs),
		"clear(99): full-grid snapshot before == after — no mutation"
	)
	_check(
		index_before == _reverse_index(gs),
		"clear(99): reverse index unchanged (no 99 entry added/removed)"
	)
	_check(
		_signal_count == count_before,
		"clear(99): grid_changed NOT emitted (count=%d)" % _signal_count
	)

	# QA edge: clear(-1) — never committed, hits the same unknown-id path.
	var count_edge := _signal_count
	var before_edge := _full_snapshot(gs)
	_clear(gs, -1)
	_check(
		before_edge == _full_snapshot(gs),
		"clear(-1): snapshot unchanged (unknown-id path, not a clear-semantics error)"
	)
	_check(
		_signal_count == count_edge,
		"clear(-1): grid_changed NOT emitted"
	)


# === AC-C7.7: 负 instance_id 拒绝 ===

func _test_ac_c7_7_negative_instance_id_rejected() -> void:
	print("\n[AC-C7.7] commit(-1) and commit(-5) rejected — no writes, no signal")

	var gs := _make_open_grid(10, 10)
	_connect_signal(gs)

	var before := _full_snapshot(gs)

	_commit(gs, -1, [Vector2i(1, 1)], [Vector2i(1, 2)], R0)
	_commit(gs, -5, [Vector2i(2, 2)], [], R180)
	# QA edge: a very large negative (near -MAX_INT) must be rejected the
	# same way — the guard is `< 0`, not a specific value check.
	var neg_max := -(1 << 62)
	_commit(gs, neg_max, [Vector2i(3, 3)], [Vector2i(3, 4)], R90)

	_check(
		before == _full_snapshot(gs),
		"negative ids (-1, -5, %d): full-grid snapshot before == after — no writes" % neg_max
	)
	_check(
		_reverse_index(gs).is_empty(),
		"negative ids: reverse index stays empty — all commits rejected"
	)
	_check(
		gs.call("get_occupant_id", Vector2i(1, 1)) == -1 and gs.call("get_occupant_id", Vector2i(2, 2)) == -1 and gs.call("get_occupant_id", Vector2i(3, 3)) == -1,
		"negative ids: none of the would-be footprint cells are occupied"
	)
	_check(
		_signal_count == 0,
		"negative ids: grid_changed NOT emitted (count=0)"
	)

	# Control: the same cells with a legal id commit fine — the rejection
	# was about the id, not the geometry.
	_commit(gs, 0, [Vector2i(1, 1)], [Vector2i(1, 2)], R0)
	_check(
		gs.call("get_occupant_id", Vector2i(1, 1)) == 0,
		"control: same fixture with legal id 0 commits fine"
	)


# === AC-C7.8 (ADVISORY): id 复用不可检测 —— 文档性验收 ===

func _test_ac_c7_8_id_reuse_accepted() -> void:
	print("\n[AC-C7.8 ADVISORY] commit(5) → clear(5) → commit(5) for DIFFERENT equipment — accepted (documented allocator contract)")

	var gs := _make_open_grid(10, 10)
	_connect_signal(gs)

	_commit(gs, 5, [Vector2i(0, 0)], [Vector2i(0, 1)], R0)
	_clear(gs, 5)

	# Reuse id 5 for a DIFFERENT equipment (different cells + rotation).
	_commit(gs, 5, [Vector2i(2, 2)], [Vector2i(2, 3)], R270)

	_check(
		gs.call("get_occupant_id", Vector2i(2, 2)) == 5,
		"reused id 5 commits normally — new footprint cell (2,2) occupied by 5"
	)
	_check(
		gs.call("get_occupant_id", Vector2i(0, 0)) == -1,
		"reused id 5: OLD footprint cell (0,0) is empty (not orphaned)"
	)
	var record = _reverse_index(gs)[5]
	_check(
		record.footprint_cells == [Vector2i(2, 2)] and record.rotation == R270,
		"reused id 5: reverse index holds the NEW record (footprint (2,2), rotation 270)"
	)
	_check(
		_signal_count == 3,
		"reused id 5: three emissions total — commit, clear, commit (count=%d)" % _signal_count
	)
	print("  (AC-C7.8 is ADVISORY/Code Review — GridSystem CANNOT detect id reuse; the never-reuse contract is PlacementSystem's)")


# === Pitfall: instance_id = 0 合法（Story 005 显式点名） ===

func _test_pitfall_instance_id_zero_legal() -> void:
	print("\n[PITFALL] instance_id = 0 is LEGAL — never truthy-check ids")

	var gs := _make_open_grid(10, 10)
	_connect_signal(gs)

	_commit(gs, 0, [Vector2i(1, 1)], [Vector2i(1, 2)], R0)

	_check(
		gs.call("get_occupant_id", Vector2i(1, 1)) == 0,
		"commit(id=0): (1,1) occupant_id == 0 — NOT treated as empty"
	)
	_check(
		_reverse_index(gs).has(0),
		"commit(id=0): reverse index contains key 0 (Dictionary.has, not truthiness)"
	)
	_check(
		gs.call("is_solid", Vector2i(1, 1)) == true,
		"commit(id=0): (1,1) is solid — id 0 occupies, explicit != -1 check"
	)

	# Duplicate rejection must also work for id 0.
	var before := _full_snapshot(gs)
	var count_before := _signal_count
	_commit(gs, 0, [Vector2i(9, 9)], [], R0)
	_check(
		before == _full_snapshot(gs) and _signal_count == count_before,
		"commit(id=0) duplicate rejected — snapshot unchanged, no signal"
	)

	# clear(0) must work.
	_clear(gs, 0)
	_check(
		gs.call("get_occupant_id", Vector2i(1, 1)) == -1,
		"clear(id=0): (1,1) back to -1"
	)
	_check(
		not _reverse_index(gs).has(0),
		"clear(id=0): reverse index key 0 removed"
	)


# === Guard: use-before-init（Control Manifest Foundation 层强制） ===

func _test_guard_commit_clear_before_init() -> void:
	print("\n[GUARD] commit()/clear() before init() are no-ops (guard logs, state untouched)")

	var GS: Script = load("res://src/systems/grid_system.gd") as Script
	var gs: RefCounted = GS.new()
	# Deliberately skip init().

	_commit(gs, 0, [Vector2i(1, 1)], [Vector2i(1, 2)], R0)
	_clear(gs, 0)

	_check(
		_reverse_index(gs).is_empty(),
		"before-init commit/clear: reverse index stays empty — no crash, no write"
	)
	# _assert_initialized() also guards the read surface; get_occupant_id
	# returns its -1 safe default without touching state.
	_check(
		gs.call("get_occupant_id", Vector2i(1, 1)) == -1,
		"before-init: read surface still returns safe defaults"
	)


# === Signal contract: commit 恰好发一次，payload == 提交的 cells ===

func _test_signal_contract_commit() -> void:
	print("\n[SIGNAL] commit emits grid_changed exactly once with the committed cells")

	var gs := _make_open_grid(10, 10)
	_connect_signal(gs)

	var fp: Array[Vector2i] = [Vector2i(2, 2), Vector2i(3, 2)]
	var ac: Array[Vector2i] = [Vector2i(2, 3)]
	_commit(gs, 7, fp, ac, R0)

	_check(_signal_count == 1, "commit emits exactly once (count=%d)" % _signal_count)
	_check(
		_last_footprint == fp,
		"commit payload footprint_cells_changed == committed footprint (got %s)" % [_last_footprint]
	)
	_check(
		_last_access == ac,
		"commit payload access_cells_changed == committed access (got %s)" % [_last_access]
	)

	# Two independent commits on one grid: two emissions, payload matches each.
	_commit(gs, 8, [Vector2i(6, 6)], [], R0)
	_check(_signal_count == 2, "second commit emits once more (count=%d)" % _signal_count)
	_check(
		_last_footprint == [Vector2i(6, 6)] and _last_access == [],
		"second commit payload is the second equipment's cells — not accumulated"
	)


# === Signal contract: clear 恰好发一次，payload == 被清 cells ===

func _test_signal_contract_clear() -> void:
	print("\n[SIGNAL] clear emits grid_changed exactly once with the cleared cells")

	var gs := _make_open_grid(10, 10)
	_connect_signal(gs)

	var fp: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0)]
	var ac: Array[Vector2i] = [Vector2i(0, 1)]
	_commit(gs, 7, fp, ac, R0)
	_check(_signal_count == 1, "fixture: commit emitted once (count=%d)" % _signal_count)

	_clear(gs, 7)

	_check(_signal_count == 2, "clear emits exactly once (count=%d)" % _signal_count)
	_check(
		_last_footprint == fp,
		"clear payload footprint_cells_changed == the record's footprint (got %s)" % [_last_footprint]
	)
	_check(
		_last_access == ac,
		"clear payload access_cells_changed == the record's access (got %s)" % [_last_access]
	)


# === push_error() 字面触发验证（子进程探针，AC-C7.2 / C7.3 / C7.7） ===

func _test_push_error_firing_probe() -> void:
	print("\n[PROBE] push_error() literally fires on AC-C7.2/C7.3/C7.7 rejection paths (subprocess-isolated)")

	var cases := [
		{
			"mode": "commit_negative",
			"expect_error": true,
			"label": "commit(-1)/commit(-5) -> push_error (AC-C7.7)",
		},
		{
			"mode": "commit_duplicate",
			"expect_error": true,
			"label": "duplicate commit(9) -> push_error (AC-C7.2)",
		},
		{
			"mode": "clear_unknown",
			"expect_error": true,
			"label": "clear(99)/clear(-1) unknown -> push_error (AC-C7.3)",
		},
		{
			"mode": "commit_clear_ok",
			"expect_error": false,
			"label": "control: commit(0)+clear(0) -> NO push_error",
		},
	]
	for c in cases:
		var r := _run_probe(c["mode"])
		# exit_code == 0 proves the probe itself ran to completion (quit(0)
		# reached) — "errored" alone would also match a SCRIPT ERROR crash
		# in the probe, which must not count as the AC's push_error firing.
		_check(
			r["errored"] == c["expect_error"] and r["exit_code"] == 0,
			"%s — probe %s with clean exit 0 (got errored=%s, exit=%d)" % [c["label"], "errored" if c["expect_error"] else "clean", r["errored"], r["exit_code"]]
		)
		if r["errored"] != c["expect_error"] or r["exit_code"] != 0:
			print("      probe output: %s" % r["output"])
