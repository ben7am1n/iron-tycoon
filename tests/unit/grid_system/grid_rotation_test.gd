# tests/unit/grid_system/grid_rotation_test.gd
# Story 003: Rotation Transform and Declared Bounds
# Covers AC-C4.1, AC-C4.2, AC-C4.3, AC-D1.1, AC-D5.1, AC-D5.2, AC-D5.3
# Run standalone: godot --headless --script tests/unit/grid_system/grid_rotation_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"
const PROBE_SCRIPT_PATH := "res://tests/unit/grid_system/grid_rotation_assert_probe.gd"
## The probe's safety-net exit code. NOT used for assert detection (see
## _run_probe) — assert() does not halt in Godot 4.7.1, so this code never
## fires in practice. Kept documented so the probe's contract stays legible.
const PROBE_QUIT_CODE_TIMEOUT := 66  # keep in sync with grid_rotation_assert_probe.gd

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
	print("  UNIT TEST: GridSystem — Rotation Transform (Story 003)")
	print("=".repeat(48))

	_test_ac_c4_1_treadmill_all_rotations()
	_test_ac_c4_2_squat_rack_cross_validation()
	_test_ac_c4_3_union_bbox_negative_coordinate_regression()
	_test_ac_d1_1_illegal_rotation_asserts()
	_test_ac_d5_1_declared_bounds()
	_test_ac_d5_2_anchor_convention_assert()
	_test_ac_d5_3_empty_footprint_assert()

	print("\n=== GRID ROTATION TEST: %d passed, %d failed ===" % [_pass, _fail])
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


## Runs tests/unit/grid_system/grid_rotation_assert_probe.gd in an ISOLATED
## subprocess so a firing assert() can be observed by its OUTPUT without any
## risk to this test process — see grid_rotation_assert_probe.gd's own
## header comment and get_transformed_cells()'s guard comment in
## grid_system.gd for the full, corrected understanding of Godot 4.7.1's
## assert() semantics (it aborts the rest of the CURRENT FUNCTION FRAME, not
## the process — a distinction the first version of this helper got wrong).
##
## Returns {"asserted": bool, "output": String, "exit_code": int}.
##
## "asserted" is true iff the child's output — stdout and stderr COMBINED
## into one stream, per OS.execute()'s read_stderr=true argument, not stderr
## alone — contains Godot's own "Assertion failed" text.
##
## IMPORTANT — why the exit code is NOT the signal: since assert() does not
## terminate the child PROCESS, a probe whose assert fires still runs to
## completion and exits 0 (its aborted function frame simply returns a
## default/null value, which this probe's callers ignore by not using the
## return value — see grid_rotation_assert_probe.gd's declared_bounds_*
## modes). The safety-net exit code exists only for a genuinely hung child
## (e.g. an infinite loop, not an assert) and is not expected to fire for
## any scenario this probe currently exercises.
func _run_probe(mode: String, extra_args: Array[String] = []) -> Dictionary:
	var exe := OS.get_executable_path()
	var project_root := ProjectSettings.globalize_path("res://")
	var probe_path := ProjectSettings.globalize_path(PROBE_SCRIPT_PATH)

	var args: Array[String] = ["--headless", "--path", project_root, "--script", probe_path, "--", mode]
	args.append_array(extra_args)

	var output: Array = []
	var exit_code := OS.execute(exe, args, output, true)
	var output_text: String = "".join(output)

	var asserted := output_text.find("Assertion failed") != -1

	return {"asserted": asserted, "output": output_text, "exit_code": exit_code}


# === AC-C4.1: 1x2 跑步机 4 朝向穷举（非方形 footprint，最高危 fixture） ===

func _test_ac_c4_1_treadmill_all_rotations() -> void:
	print("\n[AC-C4.1] 1x2 treadmill — all 4 rotations, exact cell match")

	var gs := _make_grid(10, 10)
	var footprint: Array[Vector2i] = [Vector2i(0, 0), Vector2i(0, 1)]
	var access: Array[Vector2i] = [Vector2i(0, 2)]
	var anchor := Vector2i(0, 0)

	var cases := [
		{"rot": 0, "fp": [Vector2i(0, 0), Vector2i(0, 1)], "ac": [Vector2i(0, 2)], "size": Vector2i(1, 3)},
		{"rot": 90, "fp": [Vector2i(2, 0), Vector2i(1, 0)], "ac": [Vector2i(0, 0)], "size": Vector2i(3, 1)},
		{"rot": 180, "fp": [Vector2i(0, 2), Vector2i(0, 1)], "ac": [Vector2i(0, 0)], "size": Vector2i(1, 3)},
		{"rot": 270, "fp": [Vector2i(0, 0), Vector2i(1, 0)], "ac": [Vector2i(2, 0)], "size": Vector2i(3, 1)},
	]

	for c in cases:
		var result = gs.call("get_transformed_cells", footprint, access, anchor, c["rot"])
		_check(
			result.footprint_cells == c["fp"],
			"rotation=%d: footprint_cells == %s (got %s)" % [c["rot"], c["fp"], result.footprint_cells]
		)
		_check(
			result.access_cells == c["ac"],
			"rotation=%d: access_cells == %s (got %s)" % [c["rot"], c["ac"], result.access_cells]
		)
		_check(
			result.new_size == c["size"],
			"rotation=%d: new_size == %s (got %s)" % [c["rot"], c["size"], result.new_size]
		)


# === AC-C4.2: 1x1 深蹲架 4 朝向交叉验证（独立 fixture，第二个形状） ===

func _test_ac_c4_2_squat_rack_cross_validation() -> void:
	print("\n[AC-C4.2] 1x1 squat rack — independent fixture, cross-validates AC-C4.1")

	var gs := _make_grid(10, 10)
	var footprint: Array[Vector2i] = [Vector2i(0, 0)]
	var access: Array[Vector2i] = [Vector2i(0, 1)]
	var anchor := Vector2i(0, 0)

	var cases := [
		{"rot": 0, "fp": Vector2i(0, 0), "ac": Vector2i(0, 1), "size": Vector2i(1, 2)},
		{"rot": 90, "fp": Vector2i(1, 0), "ac": Vector2i(0, 0), "size": Vector2i(2, 1)},
		{"rot": 180, "fp": Vector2i(0, 1), "ac": Vector2i(0, 0), "size": Vector2i(1, 2)},
		{"rot": 270, "fp": Vector2i(0, 0), "ac": Vector2i(1, 0), "size": Vector2i(2, 1)},
	]

	for c in cases:
		var result = gs.call("get_transformed_cells", footprint, access, anchor, c["rot"])
		_check(
			result.footprint_cells.size() == 1 and result.footprint_cells[0] == c["fp"],
			"rotation=%d: footprint_cells[0] == %s (got %s)" % [c["rot"], c["fp"], result.footprint_cells]
		)
		_check(
			result.access_cells.size() == 1 and result.access_cells[0] == c["ac"],
			"rotation=%d: access_cells[0] == %s (got %s) — matches GDD D.1 worked example" % [c["rot"], c["ac"], result.access_cells]
		)
		_check(
			result.new_size == c["size"],
			"rotation=%d: new_size == %s (got %s)" % [c["rot"], c["size"], result.new_size]
		)


# === AC-C4.3: 负向回归 —— 若误用 footprint-only 局部包围盒会在 90/270 度产出负坐标 ===

func _test_ac_c4_3_union_bbox_negative_coordinate_regression() -> void:
	print("\n[AC-C4.3] NEGATIVE regression — access cell components must stay >= 0 at 90/270 (union bbox, not footprint-only bbox)")

	var gs := _make_grid(10, 10)
	# Reuses the AC-C4.1 treadmill fixture: the footprint's OWN local bbox is
	# (W=1,H=2), but the UNION bbox (footprint + access) is (W=1,H=3). Using
	# the wrong (local) bbox for the access transform at 90 degrees would
	# compute (-1, 0) here — see GDD Core Rule 4's worked example.
	var footprint: Array[Vector2i] = [Vector2i(0, 0), Vector2i(0, 1)]
	var access: Array[Vector2i] = [Vector2i(0, 2)]
	var anchor := Vector2i(0, 0)

	var result_90 = gs.call("get_transformed_cells", footprint, access, anchor, 90)
	_check(result_90.access_cells.size() == 1, "90 degrees: access_cells has exactly 1 cell")
	var ac_90: Vector2i = result_90.access_cells[0]
	_check(
		ac_90.x >= 0 and ac_90.y >= 0,
		"90 degrees: access cell %s has both components >= 0 (got x=%d, y=%d)" % [ac_90, ac_90.x, ac_90.y]
	)
	_check(ac_90 == Vector2i(0, 0), "90 degrees: access cell == (0,0), NOT (-1,0) (the footprint-only-bbox regression value)")

	var result_270 = gs.call("get_transformed_cells", footprint, access, anchor, 270)
	_check(result_270.access_cells.size() == 1, "270 degrees: access_cells has exactly 1 cell")
	var ac_270: Vector2i = result_270.access_cells[0]
	_check(
		ac_270.x >= 0 and ac_270.y >= 0,
		"270 degrees: access cell %s has both components >= 0 (got x=%d, y=%d)" % [ac_270, ac_270.x, ac_270.y]
	)
	_check(ac_270 == Vector2i(2, 0), "270 degrees: access cell == (2,0)")


# === AC-D1.1: 非法 rotation 必须 assert(false)，不静默回退到 0 度 ===

func _test_ac_d1_1_illegal_rotation_asserts() -> void:
	print("\n[AC-D1.1] illegal rotation values never silently fall back to 0 degrees")

	# NOTE on this test's history: an earlier version drove this scenario
	# through the subprocess probe expecting get_transformed_cells() itself
	# to trigger an observable assert(false). That is no longer correct by
	# design: assert(false) aborts the rest of its OWN function frame when it
	# fires (see grid_system.gd's get_transformed_cells() guard comment for
	# the full empirical finding) — an Object-typed return path calling
	# assert() then attempting `return result` would return null instead,
	# which crashed THIS test the first time it was run for real (caught by
	# /code-review, not by the original author, who never ran the suite).
	#
	# get_transformed_cells() therefore rejects illegal rotations via
	# push_error() only (never assert()) and always returns a valid, empty,
	# non-null TransformedFootprint. That is directly and simply verifiable
	# in-process — no subprocess needed for this AC. The literal
	# assert(false) fallback required by TR-GS-029 still exists in
	# _transform_cell()'s `_:` branch, but is unreachable via this public
	# entrypoint by construction (a stronger guarantee than an assert that
	# fires-but-continues would have given), so it is not re-tested here —
	# reaching it would require calling the private _transform_cell()
	# directly, which this suite deliberately does not do (see qa-tester
	# review: test hooks must stay on the public surface).
	var gs := _make_grid(10, 10)
	var footprint: Array[Vector2i] = [Vector2i(0, 0)]
	var access: Array[Vector2i] = [Vector2i(0, 1)]

	for illegal in [45, -90, 360]:
		var result = gs.call("get_transformed_cells", footprint, access, Vector2i(3, 3), illegal)
		_check(
			result != null,
			"rotation=%d: returns a valid (non-null) TransformedFootprint, not Nil" % illegal
		)
		_check(
			result.footprint_cells.is_empty() and result.access_cells.is_empty(),
			"rotation=%d: returns EMPTY footprint+access — no silent (0,0)-collapsed garbage" % illegal
		)

	# Sanity: the same fixture at a legal rotation DOES produce cells, at a
	# non-zero anchor, so the emptiness above is caused by the rejection, not
	# by a broken fixture or an anchor of (0,0) masking real cells.
	var valid = gs.call("get_transformed_cells", footprint, access, Vector2i(3, 3), 0)
	_check(
		not valid.footprint_cells.is_empty(),
		"control: rotation=0 with the same fixture returns non-empty cells"
	)
	_check(
		valid.footprint_cells[0] == Vector2i(3, 3),
		"control: non-zero anchor (3,3) is correctly applied to the returned cells"
	)


# === AC-D5.1: declared_bounds 计算 ===

func _test_ac_d5_1_declared_bounds() -> void:
	print("\n[AC-D5.1] declared_bounds — 2x2 footprint + 1 access cell")

	var gs := _make_grid(10, 10)

	var footprint: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]
	var access: Array[Vector2i] = [Vector2i(0, 2)]
	var wh: Vector2i = gs.call("declared_bounds", footprint, access)
	_check(wh == Vector2i(2, 3), "declared_bounds(2x2 footprint, access=(0,2)) == (2,3) (got %s)" % wh)

	# Edge case: access cell inside footprint, at the origin — bounds are
	# still driven by the footprint's own max, unaffected by this access cell.
	var access_inside: Array[Vector2i] = [Vector2i(0, 0)]
	var wh_inside: Vector2i = gs.call("declared_bounds", footprint, access_inside)
	_check(wh_inside == Vector2i(2, 2), "declared_bounds(2x2 footprint, access=(0,0) inside footprint) == (2,2) (got %s)" % wh_inside)


# === AC-D5.2: debug assert —— 锚点约定违规 ===

func _test_ac_d5_2_anchor_convention_assert() -> void:
	print("\n[AC-D5.2] declared_bounds — debug assert on anchor-convention violation")
	print("  (subprocess-isolated — see grid_rotation_assert_probe.gd header for why)")

	var violated := _run_probe("declared_bounds_violation")
	_check(
		violated["asserted"],
		"un-normalized cells (min_offset=(1,1), not (0,0)) -> assert(false) fires (exit_code=%d)" % violated["exit_code"]
	)

	var ok := _run_probe("declared_bounds_ok")
	_check(
		not ok["asserted"] and ok["exit_code"] == 0,
		"normalized cells (min_offset=(0,0)) -> no assert, completes normally (exit_code=%d)" % ok["exit_code"]
	)


# === AC-D5.3: debug assert —— 空 footprint ===

func _test_ac_d5_3_empty_footprint_assert() -> void:
	print("\n[AC-D5.3] declared_bounds — debug assert on empty footprint_cells")
	print("  (subprocess-isolated — see grid_rotation_assert_probe.gd header for why)")

	var probe := _run_probe("declared_bounds_empty")
	_check(
		probe["asserted"],
		"footprint_cells=[] -> assert(false) fires (exit_code=%d)" % probe["exit_code"]
	)
