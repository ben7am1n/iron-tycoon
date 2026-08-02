# tests/unit/navigation/tiebreak_cross_rebuild_test.gd
# ADR-0007 Decision §1 — the CROSS-PROCESS determinism gate (GDD AC11).
#
# Protocol (verbatim from ADR-0007):
#   1. deterministic occupancy with known symmetry → at least one pair of
#      equal-cost paths from a fixed start to a fixed goal
#   2. configure AStarGrid2D identically to production
#      (DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES, HEURISTIC_OCTILE, cell_size,
#      region)
#   3. populate solidity from the deterministic occupancy map
#   4. update()
#   5. record get_id_path(from, to) as the GOLDEN VECTOR (exact
#      Array[Vector2i])
#   6. spawn ≥10 independent headless Godot processes via OS.execute() that
#      repeat steps 1–5 and serialize the result to a file
#   7. diff each result against the golden vector
#   8. all bit-identical → PASS; any divergence → FAIL
#
# Why a separate process: within one process AStarGrid2D reuses the same
# heap allocator state, which can create the ILLUSION of determinism when the
# actual tie-break depends on heap addresses. A fresh process forces a
# different heap layout. 10 independent launches rule out coincidence.
#
# This is the physical gate for SaveLoad: rebuild-on-load is proven correct
# only if this test passes. It stays in CI and re-runs on every Godot
# version bump (a 4.7.1 pass does not guarantee 4.7.2).
#
# Run standalone: godot --headless --script tests/unit/navigation/tiebreak_cross_rebuild_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const CHILD_SCRIPT := preload("res://tests/unit/navigation/tiebreak_child.gd")

# Minimum independent process launches required by ADR-0007 (≥10).
const MIN_RUNS := 10
# We run a few extra to harden the gate against coincidence.
const TOTAL_RUNS := 12

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
	print("  UNIT TEST: Navigation — Cross-Process Determinism Gate (AC11 / ADR-0007)")
	print("=".repeat(56))

	_test_gate_same_process_has_symmetric_fork()
	_test_gate_golden_vector_stable_in_process()
	_test_gate_cross_process_bit_identical()

	print("\n=== TIEBREAK CROSS-REBUILD TEST: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


# === Helpers ===

## Golden-vector builder — IN-PROCESS execution of ADR steps 1–5. Shares the
## exact code path with the child (same static funcs on tiebreak_child.gd),
## so any divergence between in-process and cross-process results is
## attributable to process state, not to divergent test logic.
func _build_golden(perturb_seed: int) -> Array[Vector2i]:
	return CHILD_SCRIPT.build_path(perturb_seed)


## Serializes a path the same way the child does.
func _serialize(path: Array) -> String:
	return CHILD_SCRIPT.serialize(path)


## Resolves the Godot executable used to spawn children. Prefers the current
## process's executable (guaranteed version match — the headless binary MUST
## match the project version per the story), falling back to "godot" on PATH.
func _godot_executable() -> String:
	var exe := OS.get_executable_path()
	if exe != "" and FileAccess.file_exists(exe):
		return exe
	return "godot"


# === AC11 scenario sanity: the symmetric fork actually exists ===

func _test_gate_same_process_has_symmetric_fork() -> void:
	print("\n[AC11 setup] symmetric occupancy produces an equal-cost fork (2,4)->(10,4) around solid (6,4)")

	var path: Array[Vector2i] = _build_golden(0)

	_check(not path.is_empty(), "gate scenario: a path exists (got %s)" % [path])
	_check(
		not path.has(Vector2i(6, 4)),
		"gate scenario: path avoids the solid cell (6,4)"
	)
	_check(
		path.size() == 9,
		"gate scenario: path length is 9 (8 steps) — equal-cost fork above/below both length 9 (got %d)" % path.size()
	)
	_check(
		path[0] == Vector2i(2, 4) and path[path.size() - 1] == Vector2i(10, 4),
		"gate scenario: path starts at (2,4) and ends at (10,4)"
	)
	# The fork must be REAL: both the above (y=3) and below (y=5) routes must
	# be open and equal length. If only one route existed there would be no
	# tie to test — the gate would be vacuous.
	var above_open := true
	var below_open := true
	for x in range(4, 8):
		if CHILD_SCRIPT._is_solid(Vector2i(x, 3)):
			above_open = false
		if CHILD_SCRIPT._is_solid(Vector2i(x, 5)):
			below_open = false
	_check(above_open and below_open, "gate scenario: both fork routes (y=3 and y=5) are open — tie is real")
	_check(
		path.size() >= 9,
		"gate scenario: path did not clip the corner (minimum detour length 9 enforced)"
	)


# === AC10 baseline: same-process determinism is the contract ===

func _test_gate_golden_vector_stable_in_process() -> void:
	print("\n[AC10 baseline] golden vector is element-for-element stable across repeated in-process builds")

	var first: Array[Vector2i] = _build_golden(0)
	var second: Array[Vector2i] = _build_golden(1)
	_check(
		_serialize(first) == _serialize(second),
		"AC10: two in-process builds (heap-perturbed differently) serialize identically"
	)
	_check(
		first == second,
		"AC10: arrays are element-for-element equal (PackedString compare already proved it; direct compare too)"
	)


# === AC11: the cross-process physical gate ===

func _test_gate_cross_process_bit_identical() -> void:
	print("\n[AC11] cross-process gate — %d independent headless processes rebuild from identical occupancy" % TOTAL_RUNS)

	var golden: Array[Vector2i] = _build_golden(0)
	var golden_s: String = _serialize(golden)
	var exe := _godot_executable()
	var proj: String = ProjectSettings.globalize_path("res://")
	var child_path: String = ProjectSettings.globalize_path("res://tests/unit/navigation/tiebreak_child.gd")

	_check(FileAccess.file_exists(child_path), "child script exists on disk: %s" % child_path)

	var mismatches: Array[String] = []
	var launched := 0
	var finished := 0
	for run in TOTAL_RUNS:
		var out_file := _temp_out_file(run)
		var args := PackedStringArray([
			"--headless", "--path", proj, "--script", child_path,
			"--", str(run + 1), out_file,
		])
		var output: Array = []
		var code := OS.execute(exe, args, output, true)
		launched += 1
		if code != 0:
			mismatches.append("run %d: child exited %d (stderr: %s)" % [run, code, str(output)])
			continue
		if not FileAccess.file_exists(out_file):
			mismatches.append("run %d: child produced no output file" % run)
			continue
		var got := ""
		var f := FileAccess.open(out_file, FileAccess.READ)
		if f:
			got = f.get_as_text().strip_edges()
			f.close()
		finished += 1
		if got != golden_s:
			mismatches.append("run %d: DIVERGED\n    golden: %s\n    child:  %s" % [run, golden_s, got])
		DirAccess.remove_absolute(out_file)

	_check(launched == TOTAL_RUNS, "AC11: all %d child processes launched (launched=%d)" % [TOTAL_RUNS, launched])
	_check(finished == TOTAL_RUNS, "AC11: all %d child processes completed and produced output (finished=%d)" % [TOTAL_RUNS, finished])
	var detail := ""
	if not mismatches.is_empty():
		detail = "\n    " + "\n    ".join(mismatches)
	_check(
		mismatches.is_empty(),
		"AC11: %d/%d cross-process results bit-identical to golden vector%s" % [finished, launched, detail]
	)

	# The gate must be re-run with a different launch ORDER to rule out
	# launch-order-dependent state (ADR QA edge case).
	print("  [AC11 edge] re-run with reversed seed order")
	var rev_mismatches := 0
	for i in TOTAL_RUNS:
		var run := TOTAL_RUNS - 1 - i
		var out_file := _temp_out_file(100 + run)
		var args := PackedStringArray([
			"--headless", "--path", proj, "--script", child_path,
			"--", str(run + 1), out_file,
		])
		var output: Array = []
		var code := OS.execute(exe, args, output, true)
		if code != 0:
			rev_mismatches += 1
			continue
		var got := ""
		var f := FileAccess.open(out_file, FileAccess.READ)
		if f:
			got = f.get_as_text().strip_edges()
			f.close()
		if got != golden_s:
			rev_mismatches += 1
		DirAccess.remove_absolute(out_file)
	_check(
		rev_mismatches == 0,
		"AC11 edge: reversed launch order — %d/%d bit-identical (mismatches=%d)" % [TOTAL_RUNS - rev_mismatches, TOTAL_RUNS, rev_mismatches]
	)


## Temp file path unique per run so concurrent children never collide.
func _temp_out_file(run: int) -> String:
	return "%s/nv005_tiebreak_%d_%d.txt" % [OS.get_temp_dir(), OS.get_process_id(), run]
