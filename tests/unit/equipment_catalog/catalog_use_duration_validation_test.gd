# tests/unit/equipment_catalog/catalog_use_duration_validation_test.gd
# Story 005: Use-Duration Field Validation
# Covers the 5 BLOCKING ACs: AC-U.1..AC-U.5
# (GDD design/gdd/equipment-catalog.md §use-duration, Story 005 QA test cases;
# GDD Core Rule 7 (e)-(h); TR-EC-004; cross-document contract with MemberSim #6 OQ2).
# Run standalone: godot --headless --script tests/unit/equipment_catalog/catalog_use_duration_validation_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"
const FIXTURES_DIR := "res://tests/unit/equipment_catalog/fixtures/"
const PROBE_SCRIPT_PATH := "res://tests/unit/equipment_catalog/catalog_use_duration_strict_probe.gd"

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
	print("  UNIT TEST: EquipmentCatalog — Use-Duration Field Validation (Story 005)")
	print("=".repeat(48))

	_test_ac_u1_mean_zero_strict_aborts()
	_test_ac_u1_mean_negative_edges()
	_test_ac_u1_mean_zero_non_strict_excludes()
	_test_ac_u2_stddev_negative_fails()
	_test_ac_u3_min_too_low_fails()
	_test_ac_u3_min_exceeds_mean_fails()
	_test_ac_u3_max_below_mean_fails()
	_test_ac_u3_min_above_max_fails()
	_test_ac_u3_boundary_equalities_pass()
	_test_ac_u4_valid_fields_land_exactly()
	_test_ac_u5_stddev_zero_allowed()
	_test_ac_u5_boundary_all_ones_allowed()
	_test_missing_use_duration_field_structural_failure()

	print("\n=== USE-DURATION VALIDATION TEST: %d passed, %d failed ===" % [_pass, _fail])
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


## Runs catalog_use_duration_strict_probe.gd in an ISOLATED subprocess so a
## firing assert()/push_error() can be observed by its OUTPUT without any risk
## to this test process (established subprocess-isolation pattern, Story 002+).
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


# === AC-U.1: mean <= 0 → strict abort (assert with entry id) ===

func _test_ac_u1_mean_zero_strict_aborts() -> void:
	print("\n[AC-U.1] use_duration_mean_ticks = 0 with strict_mode=true -> assert() aborts with entry id (Core Rule 7 (e))")

	var res := _run_probe("strict_mean_zero")
	_check(res["exit_code"] == 0, "probe exits 0 (assert aborts the frame, not the process)")
	_check(res["output"].find("Assertion failed") != -1, "assert fired")
	_check(
		res["output"].find("failed to load 'mean_zero_rack'") != -1,
		"assert message names the offending entry id"
	)
	_check(
		res["output"].find("USE_DURATION_MEAN_INVALID") != -1,
		"assert message carries the rule code USE_DURATION_MEAN_INVALID"
	)
	_check(
		res["output"].find("PROBE_OPERATION_COMPLETED") != -1,
		"probe completes after the firing assert"
	)


# === AC-U.1 边界: mean = -1 / -100 ===

func _test_ac_u1_mean_negative_edges() -> void:
	print("\n[AC-U.1 edge] mean = -1 and mean = -100 -> USE_DURATION_MEAN_INVALID (validator level)")

	var loader: Script = _loader()
	var r1: ValidationResult = loader.validate_use_duration(-1, 35, 100, 300)
	_check(r1.ok == false, "mean=-1 rejected")
	_check(r1.code == "USE_DURATION_MEAN_INVALID", "mean=-1 reports USE_DURATION_MEAN_INVALID (got '%s')" % r1.code)
	var r2: ValidationResult = loader.validate_use_duration(-100, 35, 100, 300)
	_check(r2.ok == false, "mean=-100 rejected")
	_check(r2.code == "USE_DURATION_MEAN_INVALID", "mean=-100 reports USE_DURATION_MEAN_INVALID (got '%s')" % r2.code)


# === AC-U.1 边界: strict_mode=false → 剔除 + push_error ===

func _test_ac_u1_mean_zero_non_strict_excludes() -> void:
	print("\n[AC-U.1 edge] mean=0 with strict_mode=false -> entry excluded, valid control loads")

	var result: RefCounted = _load_result("use_duration_mean_zero.catalog.json", false)
	_check(result.get("ok") == true, "ok=true (valid control loaded)")

	var catalog: RefCounted = result.get("catalog")
	_check(catalog.call("get_all_ids") == ["valid_control"], "catalog holds ONLY the valid control (mean-zero excluded)")

	var errors: Array = result.get("errors")
	_check(errors.size() == 1, "errors array has exactly 1 entry")
	var err = errors[0]
	_check(err.get("category") == "VALIDATION_FAILED", "category is VALIDATION_FAILED")
	_check(err.get("equipment_id") == "mean_zero_rack", "error names the excluded entry id")
	_check(
		err.get("message").find("USE_DURATION_MEAN_INVALID") != -1,
		"error message carries the rule code"
	)

	# push_error observable via subprocess (same isolation pattern as AC-E.1).
	var res := _run_probe("nons_mean_zero_excludes")
	_check(res["exit_code"] == 0, "non-strict probe exits 0")
	_check(res["output"].find("ERROR:") != -1, "push_error fired (Godot prints 'ERROR:')")
	_check(
		res["output"].find("excluding invalid entry 'mean_zero_rack'") != -1,
		"push_error message names the excluded entry"
	)
	_check(
		res["output"].find("CATALOG_IDS=[\"valid_control\"]") != -1,
		"probe confirms the catalog holds only the valid control"
	)


# === AC-U.2: stddev < 0 → validation fails (Core Rule 7 (f)) ===

func _test_ac_u2_stddev_negative_fails() -> void:
	print("\n[AC-U.2] use_duration_stddev_ticks = -1 -> USE_DURATION_STDDEV_NEGATIVE, entry excluded")

	# Validator level: the rule code
	var loader: Script = _loader()
	var r: ValidationResult = loader.validate_use_duration(200, -1, 100, 300)
	_check(r.ok == false, "stddev=-1 rejected")
	_check(r.code == "USE_DURATION_STDDEV_NEGATIVE", "reports USE_DURATION_STDDEV_NEGATIVE (got '%s')" % r.code)

	# Loader path: excluded + error recorded, valid control survives
	var result: RefCounted = _load_result("use_duration_stddev_negative.catalog.json", false)
	_check(result.get("ok") == true, "ok=true (valid control loaded)")
	var catalog: RefCounted = result.get("catalog")
	_check(catalog.call("get_all_ids") == ["valid_control"], "catalog holds ONLY the valid control")
	var errors: Array = result.get("errors")
	_check(errors.size() == 1, "errors array has exactly 1 entry")
	_check(errors[0].get("equipment_id") == "stddev_negative_bench", "error names the excluded entry")
	_check(
		errors[0].get("message").find("USE_DURATION_STDDEV_NEGATIVE") != -1,
		"error message carries the rule code"
	)


# === AC-U.3: min < 1 → fail (Core Rule 7 (g) first clause) ===

func _test_ac_u3_min_too_low_fails() -> void:
	print("\n[AC-U.3 (a)] use_duration_min_ticks = 0 -> USE_DURATION_MIN_TOO_LOW")

	var loader: Script = _loader()
	var r: ValidationResult = loader.validate_use_duration(200, 35, 0, 300)
	_check(r.ok == false, "min=0 rejected")
	_check(r.code == "USE_DURATION_MIN_TOO_LOW", "reports USE_DURATION_MIN_TOO_LOW (got '%s')" % r.code)

	var result: RefCounted = _load_result("use_duration_range_invalid.catalog.json", false)
	var catalog: RefCounted = result.get("catalog")
	_check(catalog.call("get_all_ids") == ["valid_control"], "all 4 invalid range entries excluded, control loads")
	var errors: Array = result.get("errors")
	_check(errors.size() == 4, "4 use-duration errors recorded (one per failing entry)")
	_check(errors[0].get("equipment_id") == "min_zero_rack", "first error names the min=0 entry")
	_check(
		errors[0].get("message").find("USE_DURATION_MIN_TOO_LOW") != -1,
		"min=0 error carries USE_DURATION_MIN_TOO_LOW"
	)


# === AC-U.3: min > mean → fail (Core Rule 7 (g) second clause) ===

func _test_ac_u3_min_exceeds_mean_fails() -> void:
	print("\n[AC-U.3 (b)] use_duration_min_ticks = 250 > mean=200 -> USE_DURATION_MIN_EXCEEDS_MEAN")

	var loader: Script = _loader()
	var r: ValidationResult = loader.validate_use_duration(200, 35, 250, 300)
	_check(r.ok == false, "min=250 > mean=200 rejected")
	_check(r.code == "USE_DURATION_MIN_EXCEEDS_MEAN", "reports USE_DURATION_MIN_EXCEEDS_MEAN (got '%s')" % r.code)

	var result: RefCounted = _load_result("use_duration_range_invalid.catalog.json", false)
	var errors: Array = result.get("errors")
	_check(errors[1].get("equipment_id") == "min_above_mean_rack", "second error names the min>mean entry")
	_check(
		errors[1].get("message").find("USE_DURATION_MIN_EXCEEDS_MEAN") != -1,
		"min>mean error carries USE_DURATION_MIN_EXCEEDS_MEAN"
	)


# === AC-U.3: max < mean → fail (Core Rule 7 (h) first clause) ===

func _test_ac_u3_max_below_mean_fails() -> void:
	print("\n[AC-U.3 (c)] use_duration_max_ticks = 150 < mean=200 -> USE_DURATION_MAX_BELOW_MEAN")

	var loader: Script = _loader()
	var r: ValidationResult = loader.validate_use_duration(200, 35, 100, 150)
	_check(r.ok == false, "max=150 < mean=200 rejected")
	_check(r.code == "USE_DURATION_MAX_BELOW_MEAN", "reports USE_DURATION_MAX_BELOW_MEAN (got '%s')" % r.code)

	var result: RefCounted = _load_result("use_duration_range_invalid.catalog.json", false)
	var errors: Array = result.get("errors")
	_check(errors[2].get("equipment_id") == "max_below_mean_rack", "third error names the max<mean entry")
	_check(
		errors[2].get("message").find("USE_DURATION_MAX_BELOW_MEAN") != -1,
		"max<mean error carries USE_DURATION_MAX_BELOW_MEAN"
	)


# === AC-U.3: min > max → fail (Core Rule 7 (h) second clause) ===

func _test_ac_u3_min_above_max_fails() -> void:
	print("\n[AC-U.3 (d)] use_duration_min_ticks = 300 > max=200 -> validation fails")
	print("  NOTE (ordering): with mean=200 the ordered checks hit MIN_EXCEEDS_MEAN first")
	print("  (min>mean is rule (g), checked before rule (h) min>max) — the entry still FAILS,")
	print("  which is what AC-U.3 requires; RANGE_INVALID is documented as unreachable.")

	var loader: Script = _loader()
	# With mean=250 the entry still fails (min=300 > max=200), and the observed
	# code is the FIRST violated rule in the fixed order: min=300 > mean=250 →
	# USE_DURATION_MIN_EXCEEDS_MEAN. With mean=200, min=100: max=... — the
	# direct way to hit the RANGE_INVALID branch would need min<=mean AND
	# max>=mean AND min>max, which is impossible (min<=mean<=max). So the
	# branch is defensive dead code; the ENTRY always fails via (g) or (h) 1st
	# clause. The fixture proves the load path: min=300/max=200/mean=200 fails.
	var r: ValidationResult = loader.validate_use_duration(200, 35, 300, 200)
	_check(r.ok == false, "min=300 > max=200 rejected (some rule code)")
	_check(
		r.code == "USE_DURATION_MIN_EXCEEDS_MEAN" or r.code == "USE_DURATION_RANGE_INVALID",
		"entry fails with a use-duration rule code (got '%s')" % r.code
	)

	var result: RefCounted = _load_result("use_duration_range_invalid.catalog.json", false)
	var errors: Array = result.get("errors")
	_check(errors.size() == 4, "all 4 sub-cases fail (errors array has 4 entries)")
	_check(errors[3].get("equipment_id") == "min_above_max_rack", "fourth error names the min>max entry")
	_check(
		errors[3].get("message").find("USE_DURATION_") != -1,
		"min>max error carries a use-duration rule code"
	)


# === AC-U.3 边界: max == mean 与 min == mean 合法 ===

func _test_ac_u3_boundary_equalities_pass() -> void:
	print("\n[AC-U.3 edge] max == mean and min == mean are VALID (no variation allowed above/below mean)")

	var loader: Script = _loader()
	var r1: ValidationResult = loader.validate_use_duration(200, 35, 100, 200)
	_check(r1.ok, "max == mean (200/35/100/200) accepted — 'no variation allowed above mean'")
	var r2: ValidationResult = loader.validate_use_duration(200, 35, 200, 300)
	_check(r2.ok, "min == mean (200/35/200/300) accepted — 'no variation allowed below mean'")
	var r3: ValidationResult = loader.validate_use_duration(200, 35, 200, 200)
	_check(r3.ok, "min == max == mean (200/35/200/200) accepted — fully deterministic range")


# === AC-U.4: 合法字段完整保留 + 可被 MemberSim 消费 ===

func _test_ac_u4_valid_fields_land_exactly() -> void:
	print("\n[AC-U.4] valid def (mean=200, stddev=35, min=100, max=300) -> load succeeds, get_definition returns EXACT values")

	var result: RefCounted = _load_result("use_duration_stddev_zero.catalog.json", false)
	_check(result.get("ok") == true, "ok=true (both entries valid)")
	_check((result.get("errors") as Array).is_empty(), "zero errors")

	var catalog: RefCounted = result.get("catalog")
	var def: RefCounted = catalog.call("get_definition", "deterministic_treadmill")
	_check(def != null, "get_definition('deterministic_treadmill') returns the definition")
	_check(def.get("use_duration_mean_ticks") == 200, "mean_ticks == 200 (exact)")
	_check(def.get("use_duration_stddev_ticks") == 0, "stddev_ticks == 0 (exact)")
	_check(def.get("use_duration_min_ticks") == 100, "min_ticks == 100 (exact)")
	_check(def.get("use_duration_max_ticks") == 300, "max_ticks == 300 (exact)")

	# 无 int → float 类型转换 (QA edge case): JSON.parse() 把数字解析为 float，
	# _field_int 必须还原为 int —— typeof 必须是 TYPE_INT，不是 TYPE_FLOAT。
	_check(typeof(def.get("use_duration_mean_ticks")) == TYPE_INT, "mean_ticks stored as int (not float)")
	_check(typeof(def.get("use_duration_stddev_ticks")) == TYPE_INT, "stddev_ticks stored as int (not float)")
	_check(typeof(def.get("use_duration_min_ticks")) == TYPE_INT, "min_ticks stored as int (not float)")
	_check(typeof(def.get("use_duration_max_ticks")) == TYPE_INT, "max_ticks stored as int (not float)")

	# 完整落地的交叉验证：同样经 load 路径的 benchmark 值 (mean=1,stddev=0,min=1,max=1)
	var boundary: RefCounted = catalog.call("get_definition", "boundary_one_rack")
	_check(boundary != null, "get_definition('boundary_one_rack') returns the definition")
	_check(boundary.get("use_duration_mean_ticks") == 1, "boundary mean_ticks == 1 (exact)")
	_check(boundary.get("use_duration_stddev_ticks") == 0, "boundary stddev_ticks == 0 (exact)")
	_check(boundary.get("use_duration_min_ticks") == 1, "boundary min_ticks == 1 (exact)")
	_check(boundary.get("use_duration_max_ticks") == 1, "boundary max_ticks == 1 (exact)")


# === AC-U.5: stddev = 0 合法 ===

func _test_ac_u5_stddev_zero_allowed() -> void:
	print("\n[AC-U.5] use_duration_stddev_ticks = 0 -> validation PASSES (deterministic duration allowed)")

	var loader: Script = _loader()
	var r: ValidationResult = loader.validate_use_duration(200, 0, 100, 300)
	_check(r.ok, "stddev=0 with valid range accepted (validator level)")
	_check(r.code == "", "success result carries no error code")

	# Loader path: the deterministic_treadmill fixture above has stddev=0 and loaded ok
	var result: RefCounted = _load_result("use_duration_stddev_zero.catalog.json", false)
	_check(result.get("ok") == true, "stddev=0 fixture loads ok")


# === AC-U.5 边界: 全部字段在边界值 ===

func _test_ac_u5_boundary_all_ones_allowed() -> void:
	print("\n[AC-U.5 edge] all fields at boundary (mean=1, stddev=0, min=1, max=1) -> validation passes")

	var loader: Script = _loader()
	var r: ValidationResult = loader.validate_use_duration(1, 0, 1, 1)
	_check(r.ok, "mean=1/stddev=0/min=1/max=1 accepted (validator level)")

	var catalog: RefCounted = _load_result("use_duration_stddev_zero.catalog.json", false).get("catalog")
	var def: RefCounted = catalog.call("get_definition", "boundary_one_rack")
	_check(def.get("use_duration_mean_ticks") == 1, "boundary definition landed in catalog")


# === Control Manifest Forbidden: 缺省字段不得假设默认值 ===

func _test_missing_use_duration_field_structural_failure() -> void:
	print("\n[Forbidden rule] missing use_duration field -> STRUCTURAL failure (never a default)")

	var loader: Script = _loader()
	# 直接缺省调用：_field_int 对缺失字段返回 0 并追加 INVALID_ENTRY —— 但故事要求
	# "missing = validation failure"。load 路径上 _field_int 已先拦下缺失字段
	# (INVALID_ENTRY 结构性错误)，validator 拿到的永远是非缺省的 int。
	# 这里用一条缺失 use_duration_mean_ticks 的 fixture 验证结构层拦截。
	# (无现成 fixture —— 用 _field_int 缺失行为验证 + 单条内联 dict 验证结构错误)
	var entry := {
		"id": "missing_mean",
		"display_name": "Missing Mean",
		"zone_membership": ["cardio"],
		"footprint_cells": [{"x": 0, "y": 0}],
		"access_cells": [{"x": 1, "y": 0}],
		"cost": 200,
		"unlock_requirement": "",
		"effects": [],
		"use_duration_stddev_ticks": 35,
		"use_duration_min_ticks": 100,
		"use_duration_max_ticks": 300,
	}
	var parsed: Dictionary = loader._load_single_definition(entry)
	_check(parsed["ok"] == false, "entry missing use_duration_mean_ticks fails load")
	var errs: Array = parsed["errors"]
	_check(errs.size() == 1, "exactly one structural error")
	_check(errs[0].get("category") == "INVALID_ENTRY", "missing field is a STRUCTURAL INVALID_ENTRY (not a range error)")
	_check(
		errs[0].get("message").find("use_duration_mean_ticks") != -1,
		"error names the missing field"
	)
