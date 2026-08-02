# tests/integration/equipment_catalog/catalog_edge_cases_test.gd
# Story 007: Edge Cases — Empty Catalog, Unlock Requirements, Cost Boundary
# Covers the 3 BLOCKING ACs (AC-E.2, AC-E.5, AC-E.6) plus the ADVISORY AC-E.3
# (GDD design/gdd/equipment-catalog.md §Edge Cases, Story 007 QA test cases).
#
# Story Type: Integration — exercises the FULL loader path (fixture .catalog.json
# → EquipmentCatalogLoader.load_from_file → frozen EquipmentCatalog), not just
# the individual validators (those are covered by the unit tests).
#
# Run standalone: godot --headless --script tests/integration/equipment_catalog/catalog_edge_cases_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"
const FIXTURES_DIR := "res://tests/integration/equipment_catalog/fixtures/"
const PROBE_SCRIPT_PATH := "res://tests/integration/equipment_catalog/catalog_edge_cases_probe.gd"

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
	print("  INTEGRATION TEST: EquipmentCatalog — Edge Cases (Story 007)")
	print("=".repeat(48))

	_test_ac_e2_cost_negative_fails()
	_test_ac_e2_cost_zero_loads()
	_test_ac_e2_cost_max_int_loads()
	_test_ac_e2_cost_omitted_uses_formula()
	_test_ac_e3_unlock_opaque_loads_no_error()
	_test_ac_e3_unlock_null_missing_default_empty()
	_test_ac_e5_all_invalid_strict_aborts()
	_test_ac_e5_all_invalid_non_strict_empty_catalog()
	_test_ac_e5_empty_data_source_no_crash()
	_test_ac_e6_empty_catalog_safe_queries()

	print("\n=== CATALOG EDGE CASES TEST: %d passed, %d failed ===" % [_pass, _fail])
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


## Runs catalog_edge_cases_probe.gd in an ISOLATED subprocess so a firing
## assert()/push_error() can be observed by its OUTPUT without any risk to
## this test process (established subprocess-isolation pattern, Story 002+).
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


# === AC-E.2: cost 边界 (BLOCKING) ===

func _test_ac_e2_cost_negative_fails() -> void:
	print("\n[AC-E.2] cost = -1 -> validation fails (COST_NEGATIVE)")

	var result: RefCounted = _load_result("cost_negative.catalog.json", false)
	_check(result.get("ok") == false, "ok=false (entry rejected)")

	var catalog: RefCounted = result.get("catalog")
	_check((catalog.call("get_all_ids") as Array).is_empty(), "catalog has 0 entries")

	var errors: Array = result.get("errors")
	_check(errors.size() == 1, "exactly one error recorded")
	var err = errors[0]
	_check(err.get("category") == "VALIDATION_FAILED", "category is VALIDATION_FAILED")
	_check(err.get("equipment_id") == "negative_cost_mat", "error names the offending entry")
	_check(err.get("message").find("COST_NEGATIVE") != -1, "error carries COST_NEGATIVE rule code")
	_check(err.get("message").find("-1") != -1, "error message reports the offending value")

	# Direct validator-level check (unit-style, cheap determinism proof).
	var loader: Script = _loader()
	var neg: RefCounted = loader.validate_cost(-1)
	_check(neg.get("ok") == false, "validate_cost(-1) fails")
	_check(neg.get("code") == "COST_NEGATIVE", "validate_cost(-1) code is COST_NEGATIVE")


func _test_ac_e2_cost_zero_loads() -> void:
	print("\n[AC-E.2] cost = 0 -> loads successfully (free starter equipment)")

	var result: RefCounted = _load_result("cost_zero.catalog.json", false)
	_check(result.get("ok") == true, "ok=true (cost=0 entry loads)")
	_check((result.get("errors") as Array).is_empty(), "no errors")

	var catalog: RefCounted = result.get("catalog")
	var def: RefCounted = catalog.call("get_definition", "free_starter_mat")
	_check(def != null, "free_starter_mat present in catalog")
	_check(def.get("cost") == 0, "cost round-trips as 0")

	var loader: Script = _loader()
	var zero: RefCounted = loader.validate_cost(0)
	_check(zero.get("ok") == true, "validate_cost(0) passes")


func _test_ac_e2_cost_max_int_loads() -> void:
	print("\n[AC-E.2 edge] very large positive cost (MAX_INT) -> loads successfully")

	var result: RefCounted = _load_result("cost_max_int.catalog.json", false)
	_check(result.get("ok") == true, "ok=true (MAX_INT cost loads)")
	_check((result.get("errors") as Array).is_empty(), "no errors")

	var catalog: RefCounted = result.get("catalog")
	var def: RefCounted = catalog.call("get_definition", "max_cost_treadmill")
	_check(def != null, "max_cost_treadmill present")
	_check(def.get("cost") == 2147483647, "cost round-trips as MAX_INT")

	var loader: Script = _loader()
	var maxv: RefCounted = loader.validate_cost(2147483647)
	_check(maxv.get("ok") == true, "validate_cost(MAX_INT) passes — no upper bound")


func _test_ac_e2_cost_omitted_uses_formula() -> void:
	print("\n[AC-E.2 edge] cost omitted from JSON -> provisional formula applies")

	# Fixture: 1x1 mat with NO "cost" key -> formula: base 200 + 150*(1-1) = 200.
	var result: RefCounted = _load_result("cost_omitted.catalog.json", false)
	_check(result.get("ok") == true, "ok=true (omitted-cost entry loads)")
	_check((result.get("errors") as Array).is_empty(), "no errors")

	var catalog: RefCounted = result.get("catalog")
	var def: RefCounted = catalog.call("get_definition", "omitted_cost_mat")
	_check(def != null, "omitted_cost_mat present")
	_check(def.get("cost") == 200, "cost = 200 (formula output for 1x1), NOT a hardcoded JSON value")


# === AC-E.3: unlock_requirement 不校验 (ADVISORY) ===

func _test_ac_e3_unlock_opaque_loads_no_error() -> void:
	print("\n[AC-E.3] unlock_requirement references non-existent milestone -> loads, no error, no warning")

	var result: RefCounted = _load_result("unlock_opaque.catalog.json", false)
	_check(result.get("ok") == true, "ok=true (opaque unlock loads)")
	_check((result.get("errors") as Array).is_empty(), "no errors in LoadResult")

	var catalog: RefCounted = result.get("catalog")
	var def: RefCounted = catalog.call("get_definition", "opaque_unlock_rack")
	_check(def != null, "opaque_unlock_rack present")
	_check(
		def.get("unlock_requirement") == "milestone_not_yet_designed",
		"unlock_requirement stored AS-IS (opaque string round-trips)"
	)

	# "no error, no warning" verified in the subprocess: the loader path must
	# not print ERROR: (push_error) or WARNING: (push_warning) for this load.
	var res := _run_probe("unlock_opaque")
	_check(res["exit_code"] == 0, "probe exits 0")
	_check(res["output"].find("ERROR:") == -1, "no push_error fired (no ERROR: in output)")
	_check(res["output"].find("WARNING:") == -1, "no push_warning fired (no WARNING: in output)")
	_check(
		res["output"].find("UNLOCK_VALUE=milestone_not_yet_designed") != -1,
		"probe confirms opaque unlock string round-trips"
	)
	_check(res["output"].find("ERRORS_SIZE=0") != -1, "probe confirms zero LoadResult errors")


func _test_ac_e3_unlock_null_missing_default_empty() -> void:
	print("\n[AC-E.3 edge] unlock_requirement null / missing -> defaults to \"\"")

	var result: RefCounted = _load_result("unlock_null_missing.catalog.json", false)
	_check(result.get("ok") == true, "ok=true (both entries load)")
	_check((result.get("errors") as Array).is_empty(), "no errors")

	var catalog: RefCounted = result.get("catalog")
	var null_def: RefCounted = catalog.call("get_definition", "null_unlock_mat")
	_check(null_def.get("unlock_requirement") == "", "null unlock_requirement -> empty string")

	var missing_def: RefCounted = catalog.call("get_definition", "missing_unlock_mat")
	_check(missing_def.get("unlock_requirement") == "", "missing unlock_requirement field -> empty string")


# === AC-E.5: 全部失败 → 空 Catalog (BLOCKING) ===

func _test_ac_e5_all_invalid_strict_aborts() -> void:
	print("\n[AC-E.5] all entries invalid with strict_mode=true -> assert() aborts on the FIRST failing entry")

	var res := _run_probe("strict_all_invalid")
	_check(res["exit_code"] == 0, "probe exits 0 (assert aborts the frame, not the process)")
	_check(res["output"].find("Assertion failed") != -1, "assert fired")
	_check(
		res["output"].find("failed to load 'neg_one'") != -1,
		"assert fires on the FIRST invalid entry (neg_one)"
	)
	_check(
		res["output"].find("COST_NEGATIVE") != -1,
		"assert message carries the COST_NEGATIVE rule code"
	)
	_check(
		res["output"].find("PROBE_OPERATION_COMPLETED") != -1,
		"probe completes after the firing assert"
	)


func _test_ac_e5_all_invalid_non_strict_empty_catalog() -> void:
	print("\n[AC-E.5] all entries invalid with strict_mode=false -> no crash, push_error() x3, catalog has 0 entries")

	var res := _run_probe("nons_all_invalid")
	_check(res["exit_code"] == 0, "probe exits 0 (no crash)")
	# Each of the 3 excluded entries fires one push_error (ERROR: line).
	var error_count := 0
	for line in res["output"].split("\n"):
		if line.find("ERROR:") != -1:
			error_count += 1
	_check(error_count == 3, "push_error() fired exactly 3 times (one per excluded entry, got %d)" % error_count)
	_check(
		res["output"].find("CATALOG_IDS=[]") != -1,
		"final catalog has 0 entries (get_all_ids() == [])"
	)
	_check(res["output"].find("RESULT_OK=false") != -1, "LoadResult.ok is false (no usable entries)")

	# In-process path: same result without the push_error observability.
	var result: RefCounted = _load_result("all_cost_negative.catalog.json", false)
	_check(result.get("ok") == false, "in-process: ok=false")
	var catalog: RefCounted = result.get("catalog")
	_check((catalog.call("get_all_ids") as Array).is_empty(), "in-process: catalog has 0 entries")
	_check((result.get("errors") as Array).size() == 3, "in-process: 3 errors recorded")


func _test_ac_e5_empty_data_source_no_crash() -> void:
	print("\n[AC-E.5] empty data source ({\"equipment\": []}) -> no crash, empty frozen catalog")

	var result: RefCounted = _load_result("empty_equipment.catalog.json", false)
	_check(result.get("ok") == false, "ok=false (no usable entries)")
	_check((result.get("errors") as Array).is_empty(), "no errors (nothing to validate)")
	var catalog: RefCounted = result.get("catalog")
	_check((catalog.call("get_all_ids") as Array).is_empty(), "catalog is empty but frozen + queryable")

	# strict_mode=true on an EMPTY source is a no-op (no entries to fail) — no
	# crash, empty catalog returned. The AC's strict abort applies to the
	# all-entries-invalid case, not the empty-source case.
	var strict_result: RefCounted = _load_result("empty_equipment.catalog.json", true)
	_check(strict_result.get("ok") == false, "strict + empty source: ok=false (no assert, no entries)")


# === AC-E.6: 空 Catalog 安全查询 (BLOCKING) ===

func _test_ac_e6_empty_catalog_safe_queries() -> void:
	print("\n[AC-E.6] empty catalog (0 entries) after freeze() -> safe queries, no crash")

	# Build the empty catalog through the real loader (empty fixture) so the
	# "0 entries after freeze()" state is the production one.
	var result: RefCounted = _load_result("empty_equipment.catalog.json", false)
	var catalog: RefCounted = result.get("catalog")

	# get_all_ids() -> [] (NOT null)
	var ids: Variant = catalog.call("get_all_ids")
	_check(ids != null, "get_all_ids() returns non-null")
	_check(ids is Array and (ids as Array).is_empty(), "get_all_ids() returns [] on empty catalog")

	# has_definition(any) -> false (no crash)
	_check(catalog.call("has_definition", "any") == false, "has_definition(any) == false")

	# get_definition(any) -> null + push_error (verified in subprocess — the
	# push_error is the observable part of AC-E.6's guardrail).
	var res := _run_probe("empty_queries")
	_check(res["exit_code"] == 0, "probe exits 0 (no crash on any query)")
	_check(res["output"].find("ERROR:") != -1, "get_definition(any) fires push_error (ERROR line)")
	_check(
		res["output"].find("no definition for id 'any'") != -1,
		"push_error message names the unknown id"
	)
	_check(res["output"].find("EMPTY_IDS=[]") != -1, "probe confirms get_all_ids() == []")
	_check(res["output"].find("HAS_ANY=false") != -1, "probe confirms has_definition(any) == false")
	_check(res["output"].find("GET_DEF_NULL=true") != -1, "probe confirms get_definition(any) == null")
