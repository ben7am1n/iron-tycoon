# tests/unit/grid_system/grid_system_signals_test.gd
# Story 008: Signals, Integration, and Performance
# Covers AC-C7.4 (commit emits grid_changed exactly once with the exact
# footprint/access cell arrays), AC-C7.5 (clear-side symmetry — same arrays,
# post-signal is_solid re-query contract), AC-C7.6 (drag preview emits ZERO
# signals — frequency isolation), plus the signal arity contract (two
# Array[Vector2i] arguments, per ADR-0005 S1).
#
# The signal emission sites themselves were implemented in Story 005
# (commit/clear) and Story 007 (deserialize); this file is the dedicated
# contract test the GDD H.15/H.17 test-organization map assigns to
# grid_system_signals_test.gd (AC-C7.4~7.6).
# Run standalone: godot --headless --script tests/unit/grid_system/grid_system_signals_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

# Rotation values mirror GridSystem.Rotation (degree-valued).
const R0 := 0
const R90 := 90

var _pass := 0
var _fail := 0

# grid_changed observation state — reset per _connect_signal().
var _signal_count := 0
var _last_footprint: Array = []
var _last_access: Array = []
var _last_footprint_is_typed := false
var _last_access_is_typed := false


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
	print("  UNIT TEST: GridSystem — Signals Contract (Story 008)")
	print("=".repeat(48))

	_test_ac_c7_4_commit_exact_payload()
	_test_ac_c7_4_multiple_sequential_commits()
	_test_ac_c7_5_clear_symmetry()
	_test_ac_c7_5_clear_2x2_footprint()
	_test_ac_c7_5_clear_rotation_90()
	_test_ac_c7_6_preview_emits_nothing()
	_test_ac_c7_6_get_snapshot_no_signal()
	_test_ac_c7_6_speculative_removal_no_signal()
	_test_signal_arity_two_typed_arrays()
	_test_rejected_paths_emit_nothing()

	print("\n=== GRID SYSTEM SIGNALS TEST: %d passed, %d failed ===\n" % [_pass, _fail])
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


## Makes every cell buildable — signal tests care about occupancy/access
## payloads, not room geometry.
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


## Connects grid_changed and resets observation counters. The handler
## captures payload contents AND type info (are the arguments typed
## Array[Vector2i], per the signal declaration / ADR-0005 arity contract).
func _connect_signal(gs: RefCounted) -> void:
	_signal_count = 0
	_last_footprint = []
	_last_access = []
	_last_footprint_is_typed = false
	_last_access_is_typed = false
	gs.connect("grid_changed", Callable(self, "_on_grid_changed"))


func _on_grid_changed(footprint_changed: Array[Vector2i], access_changed: Array[Vector2i]) -> void:
	_signal_count += 1
	_last_footprint = footprint_changed.duplicate()
	_last_access = access_changed.duplicate()
	_last_footprint_is_typed = footprint_changed is Array[Vector2i]
	_last_access_is_typed = access_changed is Array[Vector2i]


## Asserts the payload arrays match [fp]/[ac] exactly — same length, same
## elements, same order, no extras, no missing.
func _check_payload_exact(fp_expected: Array[Vector2i], ac_expected: Array[Vector2i]) -> void:
	_check(
		_last_footprint == fp_expected,
		"footprint_cells_changed == %s exactly (got %s)" % [fp_expected, _last_footprint]
	)
	_check(
		_last_access == ac_expected,
		"access_cells_changed == %s exactly (got %s)" % [ac_expected, _last_access]
	)
	_check(
		(_last_footprint as Array).size() == (fp_expected as Array).size(),
		"footprint payload has no extra cells (size %d == %d)" % [(_last_footprint as Array).size(), (fp_expected as Array).size()]
	)
	_check(
		(_last_access as Array).size() == (ac_expected as Array).size(),
		"access payload has no extra cells (size %d == %d)" % [(_last_access as Array).size(), (ac_expected as Array).size()]
	)


# === AC-C7.4: commit 触发恰好一次，payload 精确 ===

func _test_ac_c7_4_commit_exact_payload() -> void:
	print("\n[AC-C7.4] commit emits grid_changed exactly once, payload == exact committed cells")
	print("  fixture: footprint=[(1,1),(1,2)], access=[(1,3)]")

	var gs := _make_open_grid(10, 10)
	_connect_signal(gs)

	var fp: Array[Vector2i] = [Vector2i(1, 1), Vector2i(1, 2)]
	var ac: Array[Vector2i] = [Vector2i(1, 3)]
	_commit(gs, 1, fp, ac, R0)

	_check(
		_signal_count == 1,
		"grid_changed emitted exactly once (count=%d)" % _signal_count
	)
	_check_payload_exact(fp, ac)


func _test_ac_c7_4_multiple_sequential_commits() -> void:
	print("\n[AC-C7.4 edge] multiple sequential commits — exactly 1 signal per commit, payload per-commit")

	var gs := _make_open_grid(10, 10)
	_connect_signal(gs)

	var fp_a: Array[Vector2i] = [Vector2i(2, 2)]
	var ac_a: Array[Vector2i] = [Vector2i(2, 3)]
	_commit(gs, 1, fp_a, ac_a, R0)
	_check(_signal_count == 1, "first commit: 1 emission (count=%d)" % _signal_count)
	_check_payload_exact(fp_a, ac_a)

	var fp_b: Array[Vector2i] = [Vector2i(4, 4), Vector2i(5, 4)]
	var ac_b: Array[Vector2i] = []
	_commit(gs, 2, fp_b, ac_b, R0)
	_check(_signal_count == 2, "second commit: exactly 1 more emission (count=%d)" % _signal_count)
	_check_payload_exact(fp_b, ac_b)

	var fp_c: Array[Vector2i] = [Vector2i(7, 7)]
	var ac_c: Array[Vector2i] = [Vector2i(7, 8), Vector2i(8, 8)]
	_commit(gs, 3, fp_c, ac_c, R0)
	_check(_signal_count == 3, "third commit: exactly 1 more emission (count=%d)" % _signal_count)
	_check_payload_exact(fp_c, ac_c)


# === AC-C7.5: clear 侧对称 —— 数组与 commit 侧相同，字段名不带方向语义 ===

func _test_ac_c7_5_clear_symmetry() -> void:
	print("\n[AC-C7.5] clear emits exactly once, arrays identical to commit side; post-signal is_solid re-query")
	print("  fixture: commit fp=[(1,1),(1,2)] ac=[(1,3)], then clear")

	var gs := _make_open_grid(10, 10)
	_connect_signal(gs)

	var fp: Array[Vector2i] = [Vector2i(1, 1), Vector2i(1, 2)]
	var ac: Array[Vector2i] = [Vector2i(1, 3)]
	_commit(gs, 1, fp, ac, R0)
	_check(_signal_count == 1, "fixture: commit emitted once (count=%d)" % _signal_count)
	_check_payload_exact(fp, ac)

	_clear(gs, 1)

	_check(
		_signal_count == 2,
		"clear emits exactly once (count=%d)" % _signal_count
	)
	# The critical symmetry: clear-side payload is IDENTICAL to commit-side.
	# Field names carry no direction semantics — "changed, re-query".
	_check_payload_exact(fp, ac)
	# Re-query contract: after the signal, the subscriber must NOT guess
	# direction from field names; it re-reads current state.
	_check(
		gs.call("is_solid", Vector2i(1, 1)) == false,
		"post-signal is_solid((1,1)) == false — re-query proves the change, not the field name"
	)


func _test_ac_c7_5_clear_2x2_footprint() -> void:
	print("\n[AC-C7.5 edge] clear symmetry with 2x2 footprint")

	var gs := _make_open_grid(10, 10)
	_connect_signal(gs)

	var fp: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]
	var ac: Array[Vector2i] = [Vector2i(0, 2), Vector2i(1, 2)]
	_commit(gs, 7, fp, ac, R0)
	_check(_signal_count == 1, "fixture: commit emitted once (count=%d)" % _signal_count)

	_clear(gs, 7)
	_check(_signal_count == 2, "clear emits exactly once (count=%d)" % _signal_count)
	_check_payload_exact(fp, ac)
	_check(
		gs.call("is_solid", Vector2i(0, 0)) == false and gs.call("is_solid", Vector2i(1, 1)) == false,
		"post-signal: 2x2 footprint cells no longer solid"
	)


func _test_ac_c7_5_clear_rotation_90() -> void:
	print("\n[AC-C7.5 edge] clear symmetry with rotation=90 (transformed cells committed)")

	var gs := _make_open_grid(10, 10)
	_connect_signal(gs)

	# The caller passes TRANSFORMED cells to commit() (canonical cells
	# rotated by get_transformed_cells beforehand) — rotation only affects
	# what the caller passes, not the signal payload contract.
	var fp: Array[Vector2i] = [Vector2i(3, 5), Vector2i(4, 5)]
	var ac: Array[Vector2i] = [Vector2i(5, 5)]
	_commit(gs, 7, fp, ac, R90)
	_check(_signal_count == 1, "fixture: commit emitted once (count=%d)" % _signal_count)

	_clear(gs, 7)
	_check(_signal_count == 2, "clear emits exactly once (count=%d)" % _signal_count)
	_check_payload_exact(fp, ac)
	_check(
		gs.call("is_solid", Vector2i(3, 5)) == false and gs.call("is_solid", Vector2i(4, 5)) == false,
		"post-signal: rotation-90 footprint cells no longer solid"
	)


# === AC-C7.6: 拖拽预览不发射信号（频率隔离） ===

func _test_ac_c7_6_preview_emits_nothing() -> void:
	print("\n[AC-C7.6] drag preview — N speculative snapshots emit 0 signals; commit emits exactly 1")

	var gs := _make_open_grid(13, 10)
	_connect_signal(gs)
	# Real equipment already placed so preview deltas are meaningful.
	_commit(gs, 1, [Vector2i(2, 2)], [Vector2i(2, 3)], R0)
	var count_after_fixture := _signal_count

	# Simulated drag: 5 speculative snapshots with a moving anchor.
	var fp: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0)]
	var ac: Array[Vector2i] = [Vector2i(0, 1)]
	for i in 5:
		var anchor := Vector2i(4 + i, 3)
		var tfp: Array[Vector2i] = []
		var tac: Array[Vector2i] = []
		for c in fp:
			tfp.append(anchor + c)
		for c in ac:
			tac.append(anchor + c)
		var delta := PlacementDelta.new(false, 99 + i, tfp, tac)
		var deltas: Array[PlacementDelta] = [delta]
		var snap: RefCounted = gs.call("get_speculative_snapshot", deltas)
		_check(
			snap != null and snap.call("is_solid", anchor + Vector2i(0, 0)) == true,
			"preview %d: speculative snapshot reflects the delta" % i
		)

	_check(
		_signal_count == count_after_fixture,
		"after 5 preview snapshots: grid_changed emission count UNCHANGED (count=%d, fixture left it at %d)" % [_signal_count, count_after_fixture]
	)

	# Actual commit fires exactly once.
	var real_fp: Array[Vector2i] = [Vector2i(6, 6)]
	var real_ac: Array[Vector2i] = [Vector2i(6, 7)]
	_commit(gs, 50, real_fp, real_ac, R0)
	_check(
		_signal_count == count_after_fixture + 1,
		"after commit: grid_changed emitted exactly once more (count=%d)" % _signal_count
	)


func _test_ac_c7_6_get_snapshot_no_signal() -> void:
	print("\n[AC-C7.6 edge] get_snapshot() is a pure read — no grid_changed")

	var gs := _make_open_grid(10, 10)
	_connect_signal(gs)
	_commit(gs, 1, [Vector2i(1, 1)], [Vector2i(1, 2)], R0)
	var count_before := _signal_count

	var snap: RefCounted = gs.call("get_snapshot")
	_check(snap != null, "get_snapshot() returns a snapshot")
	_check(
		_signal_count == count_before,
		"get_snapshot() emitted NO grid_changed (count=%d)" % _signal_count
	)


func _test_ac_c7_6_speculative_removal_no_signal() -> void:
	print("\n[AC-C7.6 edge] speculative snapshot with REMOVAL deltas — still no signal")

	var gs := _make_open_grid(10, 10)
	_connect_signal(gs)
	_commit(gs, 1, [Vector2i(1, 1)], [Vector2i(1, 2)], R0)
	var count_before := _signal_count

	var empty_cells: Array[Vector2i] = []
	var rem := PlacementDelta.new(true, 1, empty_cells, empty_cells)
	var deltas: Array[PlacementDelta] = [rem]
	var snap: RefCounted = gs.call("get_speculative_snapshot", deltas)
	_check(
		snap.call("get_occupant_id", Vector2i(1, 1)) == -1,
		"speculative removal: snapshot shows the cell cleared"
	)
	_check(
		_signal_count == count_before,
		"speculative removal emitted NO grid_changed (count=%d)" % _signal_count
	)
	_check(
		gs.call("get_occupant_id", Vector2i(1, 1)) == 1,
		"real grid untouched by speculative removal"
	)


# === ADR-0005 arity: signal carries exactly two typed Array[Vector2i] ===

func _test_signal_arity_two_typed_arrays() -> void:
	print("\n[SIGNAL ARITY] grid_changed emits exactly 2 arguments, both typed Array[Vector2i] (ADR-0005 S1)")

	var gs := _make_open_grid(10, 10)
	_connect_signal(gs)

	var fp: Array[Vector2i] = [Vector2i(1, 1)]
	var ac: Array[Vector2i] = [Vector2i(1, 2)]
	_commit(gs, 1, fp, ac, R0)

	_check(_signal_count == 1, "signal fired once")
	# The handler signature `_on_grid_changed(Array[Vector2i], Array[Vector2i])`
	# is itself the arity check — a 0/1/3-arg emit would error at connection.
	# These assert the runtime type of what arrived.
	_check(
		_last_footprint_is_typed,
		"footprint_cells_changed arrived as typed Array[Vector2i]"
	)
	_check(
		_last_access_is_typed,
		"access_cells_changed arrived as typed Array[Vector2i]"
	)
	_check(
		(_last_footprint as Array).size() == 1 and (_last_access as Array).size() == 1,
		"each payload holds exactly the committed cells"
	)


# === Rejected paths must stay silent (commit/clear atomicity + signals) ===

func _test_rejected_paths_emit_nothing() -> void:
	print("\n[REJECT] rejected commit/clear emit NO grid_changed (Story 005 atomicity holds from the signal side)")

	var gs := _make_open_grid(10, 10)
	_connect_signal(gs)
	_commit(gs, 1, [Vector2i(1, 1)], [Vector2i(1, 2)], R0)
	var count_before := _signal_count

	# Duplicate commit rejected.
	_commit(gs, 1, [Vector2i(9, 9)], [], R0)
	_check(
		_signal_count == count_before,
		"rejected duplicate commit: no grid_changed (count=%d)" % _signal_count
	)

	# Negative id rejected.
	_commit(gs, -5, [Vector2i(2, 2)], [], R0)
	_check(
		_signal_count == count_before,
		"rejected negative-id commit: no grid_changed (count=%d)" % _signal_count
	)

	# Clear of unknown id rejected.
	_clear(gs, 999)
	_check(
		_signal_count == count_before,
		"rejected clear(unknown): no grid_changed (count=%d)" % _signal_count
	)
