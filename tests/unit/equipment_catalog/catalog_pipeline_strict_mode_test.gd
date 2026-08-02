# tests/unit/equipment_catalog/catalog_pipeline_strict_mode_test.gd
# Story 004: Validation Pipeline, strict_mode, and Duplicate ID Detection
# Covers the 4 BLOCKING ACs: AC-E.1, AC-PIPELINE.1, AC-PIPELINE.2, AC-PIPELINE.3
# (GDD design/gdd/equipment-catalog.md, Story 004 QA test cases).
# Run standalone: godot --headless --script tests/unit/equipment_catalog/catalog_pipeline_strict_mode_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"
const FIXTURES_DIR := "res://tests/unit/equipment_catalog/fixtures/"
const PROBE_SCRIPT_PATH := "res://tests/unit/equipment_catalog/catalog_pipeline_strict_mode_probe.gd"

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
	print("  UNIT TEST: EquipmentCatalog — Validation Pipeline & strict_mode (Story 004)")
	print("=".repeat(48))

	_test_ac_e1_duplicate_first_kept()
	_test_ac_e1_three_duplicates_only_first_kept()
	_test_ac_e1_strict_aborts_on_duplicate()
	_test_ac_e1_non_strict_push_error_first_kept()
	_test_ac_pipeline1_one_valid_one_invalid()
	_test_ac_pipeline1_all_valid_zero_errors()
	_test_ac_pipeline1_all_invalid_empty_catalog()
	_test_ac_pipeline2_strict_aborts_never_freezes()
	_test_ac_pipeline3_multiple_failures_deterministic_order()

	print("\n=== PIPELINE/STRICT-MODE TEST: %d passed, %d failed ===" % [_pass, _fail])
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


## Runs catalog_pipeline_strict_mode_probe.gd in an ISOLATED subprocess so a
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


# === AC-E.1: 重复 id → 首次保留，后续为失败 ===

func _test_ac_e1_duplicate_first_kept() -> void:
	print("\n[AC-E.1] two definitions sharing id 'treadmill' -> first occurrence kept, second is DUPLICATE_ID")

	var result: RefCounted = _load_result("duplicate_id.catalog.json", false)
	_check(result.get("ok") == true, "ok=true (A loaded, only the duplicate failed)")

	var catalog: RefCounted = result.get("catalog")
	_check(catalog.call("get_all_ids") == ["treadmill"], "catalog holds exactly one id")

	# A (first occurrence) must be the definition under "treadmill": cost 200,
	# display "Original Treadmill". B (cost 999) must NOT be there.
	var kept = catalog.call("get_definition", "treadmill")
	_check(kept.get("cost") == 200, "kept definition is A's (cost 200, not B's 999)")
	_check(kept.get("display_name") == "Original Treadmill", "kept definition is A's display name")

	var errors: Array = result.get("errors")
	_check(errors.size() == 1, "exactly one error recorded")
	var err = errors[0]
	_check(err.get("category") == "DUPLICATE_ID", "category is DUPLICATE_ID")
	_check(err.get("equipment_id") == "treadmill", "error names the duplicate id")
	_check(
		err.get("message").find("first occurrence kept") != -1,
		"message explains the first-occurrence-kept rule"
	)


# === AC-E.1 边界: 3 个重复 → 仅首次保留 ===

func _test_ac_e1_three_duplicates_only_first_kept() -> void:
	print("\n[AC-E.1 edge] three definitions sharing id 'treadmill' -> only first kept, 2 DUPLICATE_ID errors")

	var result: RefCounted = _load_result("duplicate_id_three.catalog.json", false)
	_check(result.get("ok") == true, "ok=true (A loaded)")

	var catalog: RefCounted = result.get("catalog")
	_check(catalog.call("get_all_ids") == ["treadmill"], "catalog holds exactly one id")

	var kept = catalog.call("get_definition", "treadmill")
	_check(kept.get("cost") == 200, "kept definition is A's (cost 200)")

	var errors: Array = result.get("errors")
	_check(errors.size() == 2, "exactly two DUPLICATE_ID errors")
	_check(errors[0].get("category") == "DUPLICATE_ID", "first error category DUPLICATE_ID")
	_check(errors[1].get("category") == "DUPLICATE_ID", "second error category DUPLICATE_ID")
	_check(errors[0].get("equipment_id") == "treadmill", "first error names the id")
	_check(errors[1].get("equipment_id") == "treadmill", "second error names the id")


# === AC-E.1 边界: strict_mode=true → 在重复 id 处 assert 中止 ===

func _test_ac_e1_strict_aborts_on_duplicate() -> void:
	print("\n[AC-E.1 edge] duplicate id with strict_mode=true -> assert() aborts on the second occurrence")

	var res := _run_probe("strict_duplicate_id")
	_check(res["exit_code"] == 0, "probe exits 0 (assert aborts the frame, not the process)")
	_check(res["output"].find("Assertion failed") != -1, "assert fired")
	_check(
		res["output"].find("Duplicate equipment id 'treadmill'") != -1,
		"assert message names the duplicate id"
	)
	_check(
		res["output"].find("PROBE_OPERATION_COMPLETED") != -1,
		"probe completes after the firing assert (freeze never reached)"
	)


# === AC-E.1 边界: strict_mode=false → push_error + 首次保留 ===

func _test_ac_e1_non_strict_push_error_first_kept() -> void:
	print("\n[AC-E.1 edge] duplicate id with strict_mode=false -> push_error fires, first occurrence kept")

	var res := _run_probe("nons_duplicate_keeps_first")
	_check(res["exit_code"] == 0, "non-strict probe exits 0")
	_check(res["output"].find("ERROR:") != -1, "push_error fired (Godot prints 'ERROR:')")
	_check(
		res["output"].find("excluding duplicate entry 'treadmill'") != -1,
		"push_error message names the excluded duplicate id"
	)
	_check(
		res["output"].find("CATALOG_IDS=[\"treadmill\"]") != -1,
		"probe confirms the catalog holds only the kept id"
	)
	_check(
		res["output"].find("KEPT_COST=200") != -1,
		"probe confirms the KEPT definition is A's (cost 200, not B's 999)"
	)


# === AC-PIPELINE.1: 1 合法 + 1 非法 → partial load (strict_mode=false) ===

func _test_ac_pipeline1_one_valid_one_invalid() -> void:
	print("\n[AC-PIPELINE.1] 1 valid + 1 invalid -> ok=true, catalog has 1 definition, errors has 1 entry")

	var result: RefCounted = _load_result("pipeline_one_valid_one_invalid.catalog.json", false)
	_check(result.get("ok") == true, "ok=true (usable catalog despite the bad entry)")

	var catalog: RefCounted = result.get("catalog")
	_check(catalog.call("get_all_ids") == ["valid_treadmill"], "catalog holds ONLY the valid entry")

	var errors: Array = result.get("errors")
	_check(errors.size() == 1, "errors array has exactly 1 entry")
	var err = errors[0]
	_check(err.get("category") == "VALIDATION_FAILED", "category is VALIDATION_FAILED")
	_check(err.get("equipment_id") == "l_shape_rack", "error names the invalid entry id")
	_check(
		err.get("message").find("FOOTPRINT_NOT_RECTANGULAR") != -1,
		"error carries the footprint rule code"
	)


# === AC-PIPELINE.1 边界: 全合法 → 0 错误 ===

func _test_ac_pipeline1_all_valid_zero_errors() -> void:
	print("\n[AC-PIPELINE.1 edge] all entries valid -> 0 errors, ok=true")

	var result: RefCounted = _load_result("three_valid.catalog.json", false)
	_check(result.get("ok") == true, "ok=true")
	_check((result.get("errors") as Array).is_empty(), "errors array is empty")
	_check((result.get("catalog") as RefCounted).call("get_all_ids").size() == 3, "catalog holds all 3 entries")


# === AC-PIPELINE.1 边界: 全非法 → ok=false, 空 catalog ===

func _test_ac_pipeline1_all_invalid_empty_catalog() -> void:
	print("\n[AC-PIPELINE.1 edge] all entries invalid -> ok=false, empty catalog")

	var result: RefCounted = _load_result("all_invalid.catalog.json", false)
	_check(result.get("ok") == false, "ok=false (no usable entries)")
	var catalog: RefCounted = result.get("catalog")
	_check((catalog.call("get_all_ids") as Array).is_empty(), "catalog is empty (frozen, queryable)")


# === AC-PIPELINE.2: 1 合法 + 1 非法 → strict_mode=true assert 中止 ===

func _test_ac_pipeline2_strict_aborts_never_freezes() -> void:
	print("\n[AC-PIPELINE.2] 1 valid + 1 invalid with strict_mode=true -> assert() aborts on the invalid entry")

	var res := _run_probe("strict_invalid_entry")
	_check(res["exit_code"] == 0, "probe exits 0 (assert aborts the frame, not the process)")
	_check(res["output"].find("Assertion failed") != -1, "assert fired")
	_check(
		res["output"].find("failed to load 'l_shape_rack'") != -1,
		"assert message names the invalid entry id"
	)
	_check(
		res["output"].find("FOOTPRINT_NOT_RECTANGULAR") != -1,
		"assert message carries the rule code"
	)
	_check(
		res["output"].find("PROBE_OPERATION_COMPLETED") != -1,
		"probe completes after the firing assert — _freeze() (textually after the loop) never ran"
	)


# === AC-PIPELINE.3: 多重校验失败 → 全部报告，顺序确定 ===

func _test_ac_pipeline3_multiple_failures_deterministic_order() -> void:
	print("\n[AC-PIPELINE.3] entry with empty footprint AND 2 access cells AND cost=-1 -> ALL 3 failures reported, deterministic order")

	# Direct validator-level: _validate_all returns every sub-validator's first
	# failure in fixed order (footprint shape → access cells → use-duration →
	# cost). Cost validation (COST_NEGATIVE) joined via EC-007's validate_cost —
	# the story QA case documents the full 3-error order (FOOTPRINT_EMPTY,
	# ACCESS_COUNT, COST_NEGATIVE). Use-duration values are VALID (200/35/100/300)
	# so they do not add a failure — the test isolates the documented QA order.
	var loader: Script = _loader()
	var empty_footprint: Array[Vector2i] = []
	var two_access: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0)]
	var failures: Array = loader._validate_all(empty_footprint, two_access, 200, 35, 100, 300, -1)
	_check(failures.size() == 3, "_validate_all returns 3 failures (FOOTPRINT_EMPTY, ACCESS_COUNT, COST_NEGATIVE)")
	_check(failures[0].get("code") == "FOOTPRINT_EMPTY", "first failure is FOOTPRINT_EMPTY (footprint checked first)")
	_check(failures[1].get("code") == "ACCESS_COUNT", "second failure is ACCESS_COUNT")
	_check(failures[2].get("code") == "COST_NEGATIVE", "third failure is COST_NEGATIVE (cost validated last)")

	# Deterministic error ordering: same input -> same error order every run.
	var failures_again: Array = loader._validate_all(empty_footprint, two_access, 200, 35, 100, 300, -1)
	var order_a: Array = [failures[0].get("code"), failures[1].get("code"), failures[2].get("code")]
	var order_b: Array = [failures_again[0].get("code"), failures_again[1].get("code"), failures_again[2].get("code")]
	_check(order_a == order_b, "error order is deterministic across runs")

	# Loader path: multi-failure entry excluded, valid control loads, ALL THREE
	# failures recorded in deterministic order (cost=-1 in the fixture now
	# contributes COST_NEGATIVE — Story 007 wired validate_cost into the
	# pipeline; the fixture was designed for this in Story 004).
	var result: RefCounted = _load_result("pipeline_multi_failure.catalog.json", false)
	_check(result.get("ok") == true, "ok=true (valid control entry loaded)")
	var catalog: RefCounted = result.get("catalog")
	_check(catalog.call("get_all_ids") == ["valid_dumbbell"], "valid control loaded, multi-failure entry excluded")

	var errors: Array = result.get("errors")
	_check(errors.size() == 3, "all three failures recorded for the multi-failure entry")
	_check(errors[0].get("equipment_id") == "multi_failure_rack", "first error names the entry")
	_check(errors[0].get("message").find("FOOTPRINT_EMPTY") != -1, "first error is FOOTPRINT_EMPTY")
	_check(errors[1].get("equipment_id") == "multi_failure_rack", "second error names the entry")
	_check(errors[1].get("message").find("ACCESS_COUNT") != -1, "second error is ACCESS_COUNT")
	_check(errors[2].get("equipment_id") == "multi_failure_rack", "third error names the entry")
	_check(errors[2].get("message").find("COST_NEGATIVE") != -1, "third error is COST_NEGATIVE")
