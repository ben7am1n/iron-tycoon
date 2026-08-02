# tests/unit/equipment_catalog/catalog_footprint_access_validation_test.gd
# Story 003: Footprint Shape and Access Cell Validation
# Covers the 6 BLOCKING ACs: AC-C.1 .. AC-C.6
# (GDD design/gdd/equipment-catalog.md, Story 003 QA test cases).
# Run standalone: godot --headless --script tests/unit/equipment_catalog/catalog_footprint_access_validation_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"
const FIXTURES_DIR := "res://tests/unit/equipment_catalog/fixtures/"
const PROBE_SCRIPT_PATH := "res://tests/unit/equipment_catalog/equipment_shape_validation_error_probe.gd"

var _pass := 0
var _fail := 0


## 被 tests/headless_runner.gd 托管时立即返回 —— 用例由 runner 调用的 run_all() 驱动。
func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	var result := run_all()
	quit(1 if int(result["fail"]) > 0 else 0)


## 返回 {"pass": int, "fail": int} —— 见 tests/headless_runner.gd 的测试文件契约
func run_all() -> Dictionary:
	print("=".repeat(48))
	print("  UNIT TEST: EquipmentCatalog — Footprint Shape & Access Cell Validation (Story 003)")
	print("=".repeat(48))

	_test_ac_c1_strict_abort_with_id()
	_test_ac_c2_non_strict_excludes_rest_load()
	_test_ac_c3_l_shape_rejected()
	_test_ac_c4_two_plus_access_rejected()
	_test_ac_c5_diagonal_only_rejected()
	_test_ac_c6_access_overlaps_footprint_rejected()
	_test_valid_shapes_accepted()
	_test_ordered_pipeline_first_failure()

	print("\n=== FOOTPRINT/ACCESS VALIDATION TEST: %d passed, %d failed ===" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


# === Helpers ===

func _loader() -> Script:
	return load("res://src/systems/equipment_catalog_loader.gd") as Script


## Loads a committed fixture through EquipmentCatalogLoader.load_from_file().
func _load_result(fixture_name: String, strict_mode: bool) -> RefCounted:
	var loader: Script = _loader()
	return loader.load_from_file(FIXTURES_DIR + fixture_name, strict_mode)


## Runs equipment_shape_validation_error_probe.gd in an ISOLATED subprocess so
## a firing assert()/push_error() can be observed by its OUTPUT without any
## risk to this test process (pattern established by the Story 001/002 probes).
## Returns {"output": String, "exit_code": int} — output is stdout+stderr
## COMBINED (OS.execute read_stderr=true).
func _run_probe(mode: String) -> Dictionary:
	var exe := OS.get_executable_path()
	var project_root := ProjectSettings.globalize_path("res://")
	var probe_path := ProjectSettings.globalize_path(PROBE_SCRIPT_PATH)

	var args: Array[String] = ["--headless", "--path", project_root, "--script", probe_path, "--", mode]

	var output: Array = []
	var exit_code := OS.execute(exe, args, output, true)
	var output_text: String = "".join(output)

	return {"output": output_text, "exit_code": exit_code}


# === AC-C.1: 空 footprint → strict_mode=true assert 中止（含 id） ===

func _test_ac_c1_strict_abort_with_id() -> void:
	print("\n[AC-C.1] empty footprint -> strict_mode=true assert aborts, message contains the entry id")

	var res := _run_probe("strict_empty_footprint")
	_check(res["exit_code"] == 0, "probe exits 0 (assert aborts the frame, not the process)")
	_check(res["output"].find("Assertion failed") != -1, "assert fired")
	_check(
		res["output"].find("failed to load 'empty_footprint_bench'") != -1,
		"assert message names the offending entry id ('empty_footprint_bench')"
	)
	_check(
		res["output"].find("FOOTPRINT_EMPTY") != -1,
		"assert message carries the rule code (FOOTPRINT_EMPTY)"
	)
	_check(
		res["output"].find("PROBE_OPERATION_COMPLETED") != -1,
		"probe completes after the firing assert"
	)


# === AC-C.2: 空 footprint → strict_mode=false 剔除 + push_error + 其余照常 ===

func _test_ac_c2_non_strict_excludes_rest_load() -> void:
	print("\n[AC-C.2] empty footprint -> strict_mode=false excludes entry, push_error fires, valid entries load")

	var result: RefCounted = _load_result("empty_footprint.catalog.json", false)
	_check(result.get("ok") == true, "ok=true despite the bad entry (usable catalog)")
	var catalog: RefCounted = result.get("catalog")
	_check(
		catalog.call("get_all_ids") == ["valid_treadmill", "valid_yoga_mat"],
		"catalog holds ONLY the 2 valid entries (empty-footprint entry excluded)"
	)
	var errors: Array = result.get("errors")
	_check(errors.size() == 1, "exactly one error recorded")
	var err = errors[0]
	_check(err.get("category") == "VALIDATION_FAILED", "category is VALIDATION_FAILED")
	_check(err.get("equipment_id") == "empty_footprint_bench", "error names the offending entry id")
	_check(err.get("message").find("FOOTPRINT_EMPTY") != -1, "error message carries the rule code")

	# push_error() must fire in the non-strict path (subprocess probe —
	# GDScript has no in-process push_error capture).
	var res := _run_probe("nons strict_excludes")
	_check(res["exit_code"] == 0, "non-strict probe exits 0")
	_check(res["output"].find("ERROR:") != -1, "push_error fired (Godot prints 'ERROR:')")
	_check(
		res["output"].find("excluding invalid entry 'empty_footprint_bench'") != -1,
		"push_error message names the excluded entry id"
	)
	_check(
		res["output"].find("CATALOG_IDS=[\"valid_treadmill\", \"valid_yoga_mat\"]") != -1,
		"probe confirms the 2 valid entries still loaded"
	)


# === AC-C.3: 非矩形 footprint（L 形）拒绝 ===

func _test_ac_c3_l_shape_rejected() -> void:
	print("\n[AC-C.3] non-rectangular footprint (L-shape) -> validation fails")

	var loader: Script = _loader()

	# QA case: 3-cell L-shape, bbox 2x2 but 3 != 4 -> FOOTPRINT_NOT_RECTANGULAR
	var l_shape: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0), Vector2i(1, 1)]
	var r: ValidationResult = loader.validate_footprint_shape(l_shape)
	_check(r.ok == false, "L-shape rejected")
	_check(r.code == "FOOTPRINT_NOT_RECTANGULAR", "L-shape -> FOOTPRINT_NOT_RECTANGULAR (got '%s')" % r.code)

	# QA edge: T-shape [(0,0),(1,0),(2,0),(1,1)] — 4 cells in 3x2 bbox -> 4 != 6
	var t_shape: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(1, 1)]
	var r2: ValidationResult = loader.validate_footprint_shape(t_shape)
	_check(r2.ok == false and r2.code == "FOOTPRINT_NOT_RECTANGULAR", "T-shape -> FOOTPRINT_NOT_RECTANGULAR")

	# QA edge: diagonal-only [(0,0),(1,1)] — bbox 2x2, 2 cells -> 2 != 4
	var diagonal: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 1)]
	var r3: ValidationResult = loader.validate_footprint_shape(diagonal)
	_check(r3.ok == false and r3.code == "FOOTPRINT_NOT_RECTANGULAR", "diagonal-only pair -> FOOTPRINT_NOT_RECTANGULAR")

	# QA edge: 1x3 straight (3 cells, bbox 3x1) — rectangular but NOT a locked
	# shape -> FOOTPRINT_INVALID_SHAPE (shape dimension check).
	var straight3: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0)]
	var r4: ValidationResult = loader.validate_footprint_shape(straight3)
	_check(r4.ok == false and r4.code == "FOOTPRINT_INVALID_SHAPE", "1x3 straight -> FOOTPRINT_INVALID_SHAPE (got '%s')" % r4.code)

	# Hole: 3x3 with center missing — 8 cells in 3x3 bbox -> 8 != 9
	var hole: Array[Vector2i] = [
		Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0),
		Vector2i(0, 1), Vector2i(2, 1),
		Vector2i(0, 2), Vector2i(1, 2), Vector2i(2, 2),
	]
	var r5: ValidationResult = loader.validate_footprint_shape(hole)
	_check(r5.ok == false and r5.code == "FOOTPRINT_NOT_RECTANGULAR", "holed 3x3 -> FOOTPRINT_NOT_RECTANGULAR")

	# Full loader path: L-shape fixture -> entry excluded, valid entry loads.
	var result: RefCounted = _load_result("l_shape_footprint.catalog.json", false)
	_check(result.get("ok") == true, "L-shape fixture ok=true (valid control entry loaded)")
	var catalog: RefCounted = result.get("catalog")
	_check(catalog.call("get_all_ids") == ["valid_dumbbell"], "L-shape entry excluded, valid control loaded")
	var err = result.get("errors")[0]
	_check(err.get("equipment_id") == "l_shape_rack", "L-shape error names the entry id")
	_check(err.get("category") == "VALIDATION_FAILED", "L-shape error category VALIDATION_FAILED")
	_check(err.get("message").find("FOOTPRINT_NOT_RECTANGULAR") != -1, "L-shape error carries rule code")


# === AC-C.4: 2+ access cells 拒绝 ===

func _test_ac_c4_two_plus_access_rejected() -> void:
	print("\n[AC-C.4] access_cells with 2+ entries -> validation fails")

	var loader: Script = _loader()
	var footprint: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0)]

	# QA case: 2 access cells -> ACCESS_COUNT
	var two_access: Array[Vector2i] = [Vector2i(1, 0), Vector2i(2, 0)]
	var r: ValidationResult = loader.validate_access_cells(two_access, footprint)
	_check(r.ok == false, "2 access cells rejected")
	_check(r.code == "ACCESS_COUNT", "2 access -> ACCESS_COUNT (got '%s')" % r.code)

	# QA edge: 0 access cells -> ACCESS_COUNT
	var zero_access: Array[Vector2i] = []
	var r2: ValidationResult = loader.validate_access_cells(zero_access, footprint)
	_check(r2.ok == false and r2.code == "ACCESS_COUNT", "0 access -> ACCESS_COUNT")

	# QA edge: 3+ access cells -> ACCESS_COUNT
	var three_access: Array[Vector2i] = [Vector2i(0, 1), Vector2i(1, 1), Vector2i(2, 1)]
	var r3: ValidationResult = loader.validate_access_cells(three_access, footprint)
	_check(r3.ok == false and r3.code == "ACCESS_COUNT", "3 access -> ACCESS_COUNT")

	# Full loader path: 2-access fixture -> entry excluded, valid control loads.
	var result: RefCounted = _load_result("two_access_cells.catalog.json", false)
	_check(result.get("ok") == true, "2-access fixture ok=true (valid control entry loaded)")
	var catalog: RefCounted = result.get("catalog")
	_check(catalog.call("get_all_ids") == ["valid_dumbbell"], "2-access entry excluded, valid control loaded")
	var err = result.get("errors")[0]
	_check(err.get("equipment_id") == "two_access_treadmill", "2-access error names the entry id")
	_check(err.get("message").find("ACCESS_COUNT") != -1, "2-access error carries rule code")


# === AC-C.5: 仅对角相邻拒绝 ===

func _test_ac_c5_diagonal_only_rejected() -> void:
	print("\n[AC-C.5] access only diagonally adjacent to footprint -> validation fails")

	var loader: Script = _loader()

	# QA case: footprint=(0,0), access=(1,1) — diagonal only (dx=1,dy=1)
	var footprint: Array[Vector2i] = [Vector2i(0, 0)]
	var diagonal: Array[Vector2i] = [Vector2i(1, 1)]
	var r: ValidationResult = loader.validate_access_cells(diagonal, footprint)
	_check(r.ok == false, "diagonal-only access rejected")
	_check(r.code == "ACCESS_NOT_ADJACENT", "diagonal-only -> ACCESS_NOT_ADJACENT (got '%s')" % r.code)

	# QA edge: access at (5,5) — far away
	var far: Array[Vector2i] = [Vector2i(5, 5)]
	var r2: ValidationResult = loader.validate_access_cells(far, footprint)
	_check(r2.ok == false and r2.code == "ACCESS_NOT_ADJACENT", "far access (5,5) -> ACCESS_NOT_ADJACENT")

	# QA edge: access at (2,0) with footprint at (0,0) — Manhattan distance 2,
	# no shared edge -> not adjacent
	var distance2: Array[Vector2i] = [Vector2i(2, 0)]
	var r3: ValidationResult = loader.validate_access_cells(distance2, footprint)
	_check(r3.ok == false and r3.code == "ACCESS_NOT_ADJACENT", "access (2,0) vs footprint (0,0) -> ACCESS_NOT_ADJACENT")

	# Full loader path: diagonal fixture -> entry excluded, valid control loads.
	var result: RefCounted = _load_result("diagonal_access.catalog.json", false)
	_check(result.get("ok") == true, "diagonal fixture ok=true (valid control entry loaded)")
	var catalog: RefCounted = result.get("catalog")
	_check(catalog.call("get_all_ids") == ["valid_dumbbell"], "diagonal entry excluded, valid control loaded")
	var err = result.get("errors")[0]
	_check(err.get("equipment_id") == "diagonal_access_mat", "diagonal error names the entry id")
	_check(err.get("message").find("ACCESS_NOT_ADJACENT") != -1, "diagonal error carries rule code")


# === AC-C.6: access 与 footprint 重叠拒绝 ===

func _test_ac_c6_access_overlaps_footprint_rejected() -> void:
	print("\n[AC-C.6] access_cells overlapping footprint_cells -> validation fails")

	var loader: Script = _loader()

	# QA case: footprint=(0,0), access=(0,0) — same cell
	var footprint: Array[Vector2i] = [Vector2i(0, 0)]
	var overlap: Array[Vector2i] = [Vector2i(0, 0)]
	var r: ValidationResult = loader.validate_access_cells(overlap, footprint)
	_check(r.ok == false, "overlapping access rejected")
	_check(r.code == "ACCESS_OVERLAPS_FOOTPRINT", "overlap -> ACCESS_OVERLAPS_FOOTPRINT (got '%s')" % r.code)

	# QA edge: 2x2 footprint, access at one of its cells
	var footprint2x2: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]
	var overlap_inside: Array[Vector2i] = [Vector2i(1, 1)]
	var r2: ValidationResult = loader.validate_access_cells(overlap_inside, footprint2x2)
	_check(
		r2.ok == false and r2.code == "ACCESS_OVERLAPS_FOOTPRINT",
		"2x2 footprint with access inside -> ACCESS_OVERLAPS_FOOTPRINT"
	)

	# Full loader path: overlap fixture -> entry excluded, valid control loads.
	var result: RefCounted = _load_result("access_overlap.catalog.json", false)
	_check(result.get("ok") == true, "overlap fixture ok=true (valid control entry loaded)")
	var catalog: RefCounted = result.get("catalog")
	_check(catalog.call("get_all_ids") == ["valid_dumbbell"], "overlap entry excluded, valid control loaded")
	var err = result.get("errors")[0]
	_check(err.get("equipment_id") == "overlap_bench", "overlap error names the entry id")
	_check(err.get("message").find("ACCESS_OVERLAPS_FOOTPRINT") != -1, "overlap error carries rule code")


# === 合法形状全部通过 ===

func _test_valid_shapes_accepted() -> void:
	print("\n[valid] 1x1 / 1x2 (both orientations) / 2x2 footprints pass; orthogonal access passes")

	var loader: Script = _loader()

	# 1x1
	var shape_1x1: Array[Vector2i] = [Vector2i(0, 0)]
	var r1: ValidationResult = loader.validate_footprint_shape(shape_1x1)
	_check(r1.ok, "1x1 footprint accepted")

	# 1x2 horizontal (w=2,h=1)
	var shape_1x2_h: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0)]
	var r2: ValidationResult = loader.validate_footprint_shape(shape_1x2_h)
	_check(r2.ok, "1x2 horizontal accepted")

	# 1x2 vertical (w=1,h=2)
	var shape_1x2_v: Array[Vector2i] = [Vector2i(0, 0), Vector2i(0, 1)]
	var r3: ValidationResult = loader.validate_footprint_shape(shape_1x2_v)
	_check(r3.ok, "1x2 vertical accepted")

	# 2x2
	var shape_2x2: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]
	var r4: ValidationResult = loader.validate_footprint_shape(shape_2x2)
	_check(r4.ok, "2x2 footprint accepted")

	# Orthogonal access on all 4 sides of a single-cell footprint (each side
	# declared as an explicitly typed Array[Vector2i] — Godot 4.7.1 rejects
	# assigning an untyped loop var to a typed array, tech-debt register).
	var footprint: Array[Vector2i] = [Vector2i(0, 0)]
	var acc_right: Array[Vector2i] = [Vector2i(1, 0)]
	var acc_left: Array[Vector2i] = [Vector2i(-1, 0)]
	var acc_down: Array[Vector2i] = [Vector2i(0, 1)]
	var acc_up: Array[Vector2i] = [Vector2i(0, -1)]
	for access in [acc_right, acc_left, acc_down, acc_up]:
		var r: ValidationResult = loader.validate_access_cells(access, footprint)
		_check(r.ok, "orthogonal neighbor %s accepted" % access[0])

	# Access beside a 1x2 footprint (edge-adjacent to either end)
	var fp_1x2: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0)]
	var ac_beside: Array[Vector2i] = [Vector2i(2, 0)]
	var r5: ValidationResult = loader.validate_access_cells(ac_beside, fp_1x2)
	_check(r5.ok, "access at (2,0) beside 1x2 footprint accepted")

	# Access beside a 2x2 footprint
	var ac_2x2: Array[Vector2i] = [Vector2i(1, 2)]
	var r6: ValidationResult = loader.validate_access_cells(ac_2x2, shape_2x2)
	_check(r6.ok, "access at (1,2) beside 2x2 footprint accepted")

	# Existing Story 002 fixtures still pass the NEW validation gate — full
	# regression: three_valid + unnormalized load without VALIDATION_FAILED.
	for fixture in ["three_valid.catalog.json", "unnormalized.catalog.json"]:
		var result: RefCounted = _load_result(fixture, false)
		_check(result.get("ok") == true, "%s still loads ok (regression)" % fixture)
		var errs: Array = result.get("errors")
		var has_validation_err := false
		for e in errs:
			if e.get("category") == "VALIDATION_FAILED":
				has_validation_err = true
		_check(not has_validation_err, "%s: no VALIDATION_FAILED errors (regression)" % fixture)


# === 校验顺序: footprint 形状先于 access 校验 ===

func _test_ordered_pipeline_first_failure() -> void:
	print("\n[order] footprint shape failure reported before access checks (deterministic first failure)")

	var loader: Script = _loader()

	# L-shape footprint + 2 access cells: shape failure must win (ACCESS_COUNT
	# is only reachable after footprint passes).
	var l_shape: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0), Vector2i(1, 1)]
	var two_access: Array[Vector2i] = [Vector2i(1, 0), Vector2i(2, 0)]
	var r: ValidationResult = loader._validate_definition(l_shape, two_access)
	_check(r.ok == false, "L-shape + 2 access rejected")
	_check(r.code == "FOOTPRINT_NOT_RECTANGULAR", "footprint failure wins (got '%s')" % r.code)

	# Empty footprint + overlapping access: FOOTPRINT_EMPTY wins
	var empty_fp: Array[Vector2i] = []
	var overlap: Array[Vector2i] = [Vector2i(0, 0)]
	var r2: ValidationResult = loader._validate_definition(empty_fp, overlap)
	_check(r2.code == "FOOTPRINT_EMPTY", "empty footprint wins over access overlap (got '%s')" % r2.code)

	# Valid footprint + 2 access cells: ACCESS_COUNT is the next failure
	var fp_1x1: Array[Vector2i] = [Vector2i(0, 0)]
	var r3: ValidationResult = loader._validate_definition(fp_1x1, two_access)
	_check(r3.code == "ACCESS_COUNT", "valid shape + 2 access -> ACCESS_COUNT (got '%s')" % r3.code)
