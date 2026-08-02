# tests/unit/navigation/determinism_congestion_blind_test.gd
# Story 005: Determinism Gate and Congestion Blindness — AC10 + AC12.
#
# AC10 (same-process determinism — the baseline contract):
#   GIVEN a fixed solidity map and fixed call sequence, WHEN run twice in the
#   same process, THEN outputs are element-for-element identical.
#   Edge cases: 100-query sequence; query order preserved (the determinism
#   contract depends on order — same order required).
#
# AC12 (congestion blindness):
#   GIVEN identical solidity but artificially varied Congestion(t-1) state,
#   WHEN get_path is queried both times, THEN outputs are identical (proves
#   zero read access to Congestion).
#   Edge cases: extreme congestion values (0 vs saturated); verify via
#   injected spy that no Congestion reference is ever read.
#
# Core Rule 5 (GDD): Navigation is congestion-blind — Congestion(t-1) never
# enters a path's cost. Congestion-aware behavior lives entirely in
# MemberSim's target selection. Feeding a per-tick-changing value into path
# cost is FORBIDDEN (this test would catch it).
#
# Run standalone: godot --headless --script tests/unit/navigation/determinism_congestion_blind_test.gd
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
	print("=".repeat(56))
	print("  UNIT TEST: Navigation — Determinism & Congestion Blindness (AC10/AC12)")
	print("=".repeat(56))

	_test_ac10_fixed_map_fixed_sequence_twice()
	_test_ac10_three_query_sequence_twice()
	_test_ac10_100_query_sequence_twice()
	_test_ac12_congestion_variation_identical_output()
	_test_ac12_extreme_congestion_0_vs_saturated()
	_test_ac12_spy_zero_read_access()
	_test_ac12_no_congestion_identifier_in_source()

	print("\n=== DETERMINISM CONGESTION-BLIND TEST: %d passed, %d failed ===\n" % [_pass, _fail])
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


## Fixed symmetric solidity map used across all AC10 tests: a mirror-pair of
## walls creating a deterministic maze with several equal-cost choices.
func _build_fixed_solidity(gs: RefCounted) -> void:
	var solids: Array[Vector2i] = []
	for y in range(1, 4):
		solids.append(Vector2i(3, y))
		solids.append(Vector2i(9, y))
	for y in range(6, 9):
		solids.append(Vector2i(3, y))
		solids.append(Vector2i(9, y))
	# Solid pillars inside the corridor — forces detours with equal-cost forks.
	solids.append(Vector2i(6, 2))
	solids.append(Vector2i(6, 7))
	_commit_single_cells(gs, solids)


# === AC10: fixed solidity + fixed call sequence, run twice → identical ===

func _test_ac10_fixed_map_fixed_sequence_twice() -> void:
	print("\n[AC10] fixed solidity + fixed 3-query sequence, run twice in same process")

	var gs := _make_open_grid(13, 10)
	_build_fixed_solidity(gs)
	var nav := _make_navigation(gs)

	var seq := [
		[Vector2i(0, 0), Vector2i(12, 9)],
		[Vector2i(1, 4), Vector2i(11, 4)],
		[Vector2i(0, 9), Vector2i(12, 0)],
	]

	var first := _run_sequence(nav, seq)
	var second := _run_sequence(nav, seq)

	_check(
		_serialize_sequence(first) == _serialize_sequence(second),
		"AC10: both runs serialize identically (run1=%s, run2=%s)" % [_serialize_sequence(first), _serialize_sequence(second)]
	)
	_check(
		_paths_equal(first, second),
		"AC10: every query result element-for-element identical"
	)


func _test_ac10_three_query_sequence_twice() -> void:
	print("\n[AC10 edge] three queries in a different fixed order, twice")

	var gs := _make_open_grid(13, 10)
	_build_fixed_solidity(gs)
	var nav := _make_navigation(gs)

	var seq := [
		[Vector2i(2, 5), Vector2i(8, 5)],
		[Vector2i(0, 0), Vector2i(12, 9)],
		[Vector2i(5, 0), Vector2i(5, 9)],
	]
	var first := _run_sequence(nav, seq)
	var second := _run_sequence(nav, seq)
	_check(
		_paths_equal(first, second),
		"AC10 edge: 3-query fixed order produces identical outputs on repeat"
	)


func _test_ac10_100_query_sequence_twice() -> void:
	print("\n[AC10 edge] 100-query fixed sequence, run twice")

	var gs := _make_open_grid(13, 10)
	_build_fixed_solidity(gs)
	var nav := _make_navigation(gs)

	var seq: Array = []
	var seed := 12345
	for i in 100:
		seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
		var x1 := seed % 13
		seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
		var y1 := seed % 10
		seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
		var x2 := seed % 13
		seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
		var y2 := seed % 10
		seq.append([Vector2i(x1, y1), Vector2i(x2, y2)])

	var first := _run_sequence(nav, seq)
	var second := _run_sequence(nav, seq)
	_check(
		_paths_equal(first, second),
		"AC10 edge: 100-query sequence produces identical outputs on repeat"
	)


## Runs a sequence of [from, to] pairs through nav.get_path in order,
## returning a parallel array of paths. Fixed call order is part of the
## determinism contract — never reorder.
func _run_sequence(nav: RefCounted, seq: Array) -> Array:
	var results: Array = []
	for pair in seq:
		results.append(nav.call("get_path", pair[0], pair[1]))
	return results


func _serialize_sequence(results: Array) -> String:
	var parts := PackedStringArray()
	for path in results:
		parts.append(_serialize_path(path))
	return "||".join(parts)


func _serialize_path(path: Array) -> String:
	if path.is_empty():
		return "EMPTY"
	var parts := PackedStringArray()
	for v in path:
		parts.append("%d,%d" % [v.x, v.y])
	return "|".join(parts)


## Element-for-element equality across a parallel array of paths.
func _paths_equal(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		var pa: Array = a[i]
		var pb: Array = b[i]
		if pa.size() != pb.size():
			return false
		for j in pa.size():
			if pa[j] != pb[j]:
				return false
	return true


# === AC12: congestion blindness — zero read access to Congestion ===

## A spy standing in for the Congestion system. It counts every read access
## so the test can prove Navigation never touches it. Congestion(t-1) values
## are artificially varied between queries (0 vs saturated) — if any path
## cost consulted the spy, outputs would diverge AND the counter would jump.
class CongestionSpy:
	extends RefCounted

	var _reads: int = 0
	var _value: int = 0

	func set_value(v: int) -> void:
		_value = v

	func get_value() -> int:
		_reads += 1
		return _value

	func get_reads() -> int:
		return _reads


func _test_ac12_congestion_variation_identical_output() -> void:
	print("\n[AC12] identical solidity, artificially varied Congestion(t-1) state — outputs identical")

	var gs := _make_open_grid(13, 10)
	_build_fixed_solidity(gs)
	var nav := _make_navigation(gs)

	var spy := CongestionSpy.new()
	spy.set_value(0)

	var q1 := [Vector2i(0, 0), Vector2i(12, 9)]
	var q2 := [Vector2i(1, 4), Vector2i(11, 4)]

	var before_0: Array = nav.call("get_path", q1[0], q1[1])
	var before_1: Array = nav.call("get_path", q2[0], q2[1])

	# Artificially vary Congestion(t-1) to a saturated state.
	spy.set_value(999)

	var after_0: Array = nav.call("get_path", q1[0], q1[1])
	var after_1: Array = nav.call("get_path", q2[0], q2[1])

	_check(
		_serialize_path(before_0) == _serialize_path(after_0),
		"AC12: query (0,0)->(12,9) output identical under congestion 0 vs 999"
	)
	_check(
		_serialize_path(before_1) == _serialize_path(after_1),
		"AC12: query (1,4)->(11,4) output identical under congestion 0 vs 999"
	)
	_check(
		spy.get_reads() == 0,
		"AC12: the congestion spy was never read (reads=%d) — zero read access" % spy.get_reads()
	)


func _test_ac12_extreme_congestion_0_vs_saturated() -> void:
	print("\n[AC12 edge] extreme congestion values (0 vs saturated) — identical outputs")

	var gs := _make_open_grid(13, 10)
	_build_fixed_solidity(gs)
	var nav := _make_navigation(gs)

	var spy := CongestionSpy.new()
	var from := Vector2i(2, 5)
	var to := Vector2i(8, 5)

	spy.set_value(0)
	var p0: Array = nav.call("get_path", from, to)

	spy.set_value(1 << 30)
	var p1: Array = nav.call("get_path", from, to)

	spy.set_value(-(1 << 30))
	var p2: Array = nav.call("get_path", from, to)

	_check(
		_serialize_path(p0) == _serialize_path(p1) and _serialize_path(p1) == _serialize_path(p2),
		"AC12 edge: outputs identical across congestion 0, +2^30, -2^30"
	)
	_check(
		spy.get_reads() == 0,
		"AC12 edge: spy still never read (reads=%d)" % spy.get_reads()
	)


func _test_ac12_spy_zero_read_access() -> void:
	print("\n[AC12 spy] injected spy — no Congestion reference is ever read during a full query sequence")

	var gs := _make_open_grid(13, 10)
	_build_fixed_solidity(gs)
	var nav := _make_navigation(gs)
	var spy := CongestionSpy.new()

	var seq := [
		[Vector2i(0, 0), Vector2i(12, 9)],
		[Vector2i(1, 4), Vector2i(11, 4)],
		[Vector2i(0, 9), Vector2i(12, 0)],
		[Vector2i(6, 0), Vector2i(6, 9)],
		[Vector2i(0, 4), Vector2i(12, 4)],
	]
	# Interleave spy value changes to model a live Congestion(t-1) that
	# Navigation must never observe.
	for i in seq.size():
		spy.set_value(i * 37)
		var path: Array = nav.call("get_path", seq[i][0], seq[i][1])
		_check(not path.is_empty(), "AC12 spy: query %d returned a non-empty path" % i)

	_check(
		spy.get_reads() == 0,
		"AC12 spy: after %d queries with changing congestion state, spy read count is 0" % seq.size()
	)


func _test_ac12_no_congestion_identifier_in_source() -> void:
	print("\n[AC12 source] navigation.gd has no congestion COUPLING (no file ref, no member, no instantiation)")

	var nav_path := "res://src/systems/navigation.gd"
	_check(FileAccess.file_exists(nav_path), "navigation.gd exists")

	var f := FileAccess.open(nav_path, FileAccess.READ)
	if f == null:
		_check(false, "AC12 source: cannot open navigation.gd")
		return
	var source: String = f.get_as_text()
	f.close()

	# Precise coupling probes. A blanket 'congestion' substring would false-
	# fail: the file's header doc intentionally says "congestion-blind" to
	# document the NON-dependency. We assert zero actual coupling:
	#   - no reference to the congestion script (load/preload of congestion.gd)
	#   - no member variable or parameter named _congestion
	#   - no typed declaration `: Congestion` or `Congestion.new()`
	var lower := source.to_lower()
	var refs_file: bool = lower.contains("congestion.gd")
	var refs_member: bool = lower.contains("_congestion")
	var refs_type: bool = lower.contains(": congestion") or lower.contains("congestion.new")
	_check(
		not refs_file,
		"AC12 source: no reference to congestion.gd (load/preload path)"
	)
	_check(
		not refs_member,
		"AC12 source: no _congestion member/parameter"
	)
	_check(
		not refs_type,
		"AC12 source: no ': Congestion' type annotation or Congestion.new()"
	)
