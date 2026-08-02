# tests/unit/equipment_catalog/catalog_json_loading_test.gd
# Story 002: JSON Loading and Anchor Normalization
# Covers the 5 BLOCKING ACs: AC-C.7, AC-D.1, AC-D.2, AC-JSON.1, AC-JSON.2
# (GDD design/gdd/equipment-catalog.md, Story 002 QA test cases).
# Run standalone: godot --headless --script tests/unit/equipment_catalog/catalog_json_loading_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"
const FIXTURES_DIR := "res://tests/unit/equipment_catalog/fixtures/"
const PROBE_SCRIPT_PATH := "res://tests/unit/equipment_catalog/equipment_catalog_loader_error_probe.gd"

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
	print("  UNIT TEST: EquipmentCatalog — JSON Loading & Anchor Normalization (Story 002)")
	print("=".repeat(48))

	_test_ac_c7_normalization_written_into_def()
	_test_ac_d1_idempotent()
	_test_ac_d2_range_0_2()
	_test_ac_json1_loads_n_defs()
	_test_ac_json2_parse_error_with_line()
	_test_ac_json2_schema_errors()
	_test_strict_mode_false_skips_invalid_entry()
	_test_strict_mode_true_asserts()

	print("\n=== CATALOG JSON LOADING TEST: %d passed, %d failed ===" % [_pass, _fail])
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


## Field-by-field value equality for two EquipmentDef instances (identity
## deliberately NOT compared — get_definition returns copies, AC-IMMUTABLE.1).
func _defs_value_equal(a: RefCounted, b: RefCounted) -> bool:
	return (
		a.get("id") == b.get("id")
		and a.get("display_name") == b.get("display_name")
		and a.get("zone_membership") == b.get("zone_membership")
		and a.get("footprint_cells") == b.get("footprint_cells")
		and a.get("access_cells") == b.get("access_cells")
		and a.get("cost") == b.get("cost")
		and a.get("unlock_requirement") == b.get("unlock_requirement")
		and a.get("effects") == b.get("effects")
		and a.get("use_duration_mean_ticks") == b.get("use_duration_mean_ticks")
		and a.get("use_duration_stddev_ticks") == b.get("use_duration_stddev_ticks")
		and a.get("use_duration_min_ticks") == b.get("use_duration_min_ticks")
		and a.get("use_duration_max_ticks") == b.get("use_duration_max_ticks")
	)


## Component-wise min of footprint ∪ access — the anchor_normalization
## post-condition (AC-C.7: union min must be (0,0)).
func _union_min(def: RefCounted) -> Vector2i:
	var all: Array = []
	all.append_array(def.get("footprint_cells"))
	all.append_array(def.get("access_cells"))
	var min_x := (all[0] as Vector2i).x
	var min_y := (all[0] as Vector2i).y
	for cell in all:
		min_x = min(min_x, (cell as Vector2i).x)
		min_y = min(min_y, (cell as Vector2i).y)
	return Vector2i(min_x, min_y)


## AC-D.2 range assertion: every coordinate component of every cell in the
## given Array[Vector2i] (passed as Variant) falls in [0, 2].
func _all_in_range(cells: Variant) -> bool:
	for cell in cells:
		if (cell as Vector2i).x < 0 or (cell as Vector2i).x > 2:
			return false
		if (cell as Vector2i).y < 0 or (cell as Vector2i).y > 2:
			return false
	return true


## Runs equipment_catalog_loader_error_probe.gd in an ISOLATED subprocess so
## a firing assert() can be observed by its OUTPUT without any risk to this
## test process (pattern established by equipment_catalog_error_probe.gd,
## Story 001). Returns {"output": String, "exit_code": int} — output is
## stdout+stderr COMBINED (OS.execute read_stderr=true).
func _run_probe(mode: String) -> Dictionary:
	var exe := OS.get_executable_path()
	var project_root := ProjectSettings.globalize_path("res://")
	var probe_path := ProjectSettings.globalize_path(PROBE_SCRIPT_PATH)

	var args: Array[String] = ["--headless", "--path", project_root, "--script", probe_path, "--", mode]

	var output: Array = []
	var exit_code := OS.execute(exe, args, output, true)
	var output_text: String = "".join(output)

	return {"output": output_text, "exit_code": exit_code}


# === AC-C.7: 未归一化输入 → 归一化输出（写入最终 EquipmentDef） ===

func _test_ac_c7_normalization_written_into_def() -> void:
	print("\n[AC-C.7] un-normalized input -> normalized coords written into the final EquipmentDef (union min == (0,0))")

	var result: RefCounted = _load_result("unnormalized.catalog.json", false)
	_check(result.get("ok") == true, "load of unnormalized fixture succeeds (ok=true)")
	var catalog: RefCounted = result.get("catalog")
	_check(catalog.call("get_all_ids").size() == 2, "catalog holds both definitions")

	# QA case: footprint={(1,1),(2,1)}, access={(3,1)} -> min=(1,1)
	var offset = catalog.call("get_definition", "offset_treadmill")
	_check(offset != null, "offset_treadmill loaded")
	_check(
		offset.get("footprint_cells") == [Vector2i(0, 0), Vector2i(1, 0)],
		"footprint (1,1),(2,1) normalized to (0,0),(1,0)"
	)
	_check(
		offset.get("access_cells") == [Vector2i(2, 0)],
		"access (3,1) normalized to (2,0)"
	)
	_check(_union_min(offset) == Vector2i(0, 0), "post-normalization union min == (0,0)")

	# QA edge: negative coordinates — access at (-1,0), footprint at (0,0)
	var neg = catalog.call("get_definition", "negative_access_mat")
	_check(neg != null, "negative_access_mat loaded")
	_check(
		neg.get("access_cells") == [Vector2i(0, 0)],
		"access (-1,0) normalized to (0,0)"
	)
	_check(
		neg.get("footprint_cells") == [Vector2i(1, 0), Vector2i(2, 0)],
		"footprint (0,0),(1,0) shifted to (1,0),(2,0)"
	)
	_check(_union_min(neg) == Vector2i(0, 0), "post-normalization union min == (0,0)")


# === AC-D.1: 已归一化输入不变（幂等） ===

func _test_ac_d1_idempotent() -> void:
	print("\n[AC-D.1] already-normalized input unchanged (idempotent)")

	var loader: Script = _loader()

	# QA case: footprint={(1,0),(2,0)}, access={(0,0)} — min already (0,0)
	var fp: Array[Vector2i] = [Vector2i(1, 0), Vector2i(2, 0)]
	var ac: Array[Vector2i] = [Vector2i(0, 0)]
	var out: Dictionary = loader.normalize_anchor(fp, ac)
	_check(out["footprint"] == fp, "footprint {(1,0),(2,0)} unchanged")
	_check(out["access"] == ac, "access {(0,0)} unchanged")

	# QA edge: footprint already at origin — single cell
	var fp2: Array[Vector2i] = [Vector2i(0, 0)]
	var ac2: Array[Vector2i] = [Vector2i(1, 0)]
	var out2: Dictionary = loader.normalize_anchor(fp2, ac2)
	_check(out2["footprint"] == [Vector2i(0, 0)], "single-cell footprint at origin unchanged")
	_check(out2["access"] == [Vector2i(1, 0)], "adjacent access unchanged")

	# 2x2 footprint already at origin
	var fp3: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]
	var ac3: Array[Vector2i] = [Vector2i(1, 2)]
	var out3: Dictionary = loader.normalize_anchor(fp3, ac3)
	_check(out3["footprint"] == fp3, "2x2 footprint unchanged")
	_check(out3["access"] == ac3, "2x2 access unchanged")

	# No-aliasing posture: returned arrays are copies, not the caller's arrays
	# (behavioral check — GDScript Array has no identity method; mutating the
	# return must leave the input untouched).
	(out3["footprint"] as Array).append(Vector2i(9, 9))
	_check(fp3.size() == 4, "returned footprint is a copy — mutating it does not touch the input")
	(out3["access"] as Array).append(Vector2i(9, 9))
	_check(ac3.size() == 1, "returned access is a copy — mutating it does not touch the input")


# === AC-D.2: 输出坐标每轴 ∈ [0, 2]（包围盒保证） ===

func _test_ac_d2_range_0_2() -> void:
	print("\n[AC-D.2] every output coordinate component in [0, 2] (bounding-box guarantee)")

	var loader: Script = _loader()

	# QA edge: access on the left side (x negative before normalization)
	var fp: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0)]
	var ac: Array[Vector2i] = [Vector2i(-1, 0)]
	var out: Dictionary = loader.normalize_anchor(fp, ac)
	_check(_all_in_range(out["footprint"]), "left-access normalized footprint coords in [0,2]")
	_check(_all_in_range(out["access"]), "left-access normalized access coords in [0,2]")
	_check(out["access"] == [Vector2i(0, 0)], "left access becomes origin after normalization")

	# QA edge: 2x2 footprint (union up to 3x3 -> coords up to 2)
	var fp2: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]
	var ac2: Array[Vector2i] = [Vector2i(1, 2)]
	var out2: Dictionary = loader.normalize_anchor(fp2, ac2)
	_check(_all_in_range(out2["footprint"]), "2x2 footprint coords in [0,2]")
	_check(_all_in_range(out2["access"]), "2x2 access coords in [0,2]")

	# Fully shifted valid def (offset (2,1) -> normalized back into range)
	var fp3: Array[Vector2i] = [Vector2i(2, 1), Vector2i(3, 1)]
	var ac3: Array[Vector2i] = [Vector2i(1, 1)]
	var out3: Dictionary = loader.normalize_anchor(fp3, ac3)
	_check(_all_in_range(out3["footprint"]), "shifted footprint coords in [0,2]")
	_check(_all_in_range(out3["access"]), "shifted access coords in [0,2]")

	# Through the FULL loader: every def in the valid fixture stays in range
	var result: RefCounted = _load_result("three_valid.catalog.json", false)
	var catalog: RefCounted = result.get("catalog")
	for id in catalog.call("get_all_ids"):
		var def = catalog.call("get_definition", id)
		_check(_all_in_range(def.get("footprint_cells")), "%s: loaded footprint coords in [0,2]" % id)
		_check(_all_in_range(def.get("access_cells")), "%s: loaded access coords in [0,2]" % id)


# === AC-JSON.1: 合法 JSON → N 个 EquipmentDef ===

func _test_ac_json1_loads_n_defs() -> void:
	print("\n[AC-JSON.1] valid .catalog.json with N=3 -> 3 EquipmentDefs, all fields match JSON source")

	var result: RefCounted = _load_result("three_valid.catalog.json", false)
	_check(result.get("ok") == true, "LoadResult.ok is true")
	var errors: Array = result.get("errors")
	_check(errors.is_empty(), "no load errors on the valid fixture")
	var catalog: RefCounted = result.get("catalog")
	_check(catalog.call("get_all_ids").size() == 3, "catalog contains 3 definitions")
	_check(
		catalog.call("get_all_ids") == ["treadmill_basic", "yoga_mat", "bench_press"],
		"get_all_ids returns file order (deterministic insertion order)"
	)

	# treadmill_basic — every one of the 12 fields matches the JSON source.
	var treadmill = catalog.call("get_definition", "treadmill_basic")
	_check(treadmill.get("id") == "treadmill_basic", "treadmill id round-trips")
	_check(treadmill.get("display_name") == "Basic Treadmill", "display_name round-trips")
	_check(treadmill.get("zone_membership") == ["cardio"], "zone_membership round-trips")
	_check(
		treadmill.get("footprint_cells") == [Vector2i(0, 0), Vector2i(1, 0)],
		"footprint_cells round-trips"
	)
	_check(treadmill.get("access_cells") == [Vector2i(0, 1)], "access_cells round-trips")
	_check(treadmill.get("cost") == 200, "cost round-trips")
	_check(treadmill.get("unlock_requirement") == "", "unlock_requirement empty string round-trips")
	_check(
		treadmill.get("effects") == [{"tag": "cardio", "magnitude": 1.0}],
		"effects round-trip with magnitude normalized to float"
	)
	_check(treadmill.get("use_duration_mean_ticks") == 200, "use_duration_mean_ticks round-trips")
	_check(treadmill.get("use_duration_stddev_ticks") == 35, "use_duration_stddev_ticks round-trips")
	_check(treadmill.get("use_duration_min_ticks") == 100, "use_duration_min_ticks round-trips")
	_check(treadmill.get("use_duration_max_ticks") == 300, "use_duration_max_ticks round-trips")

	# QA edges: empty effects array; non-empty unlock_requirement.
	var yoga = catalog.call("get_definition", "yoga_mat")
	_check((yoga.get("effects") as Array).is_empty(), "empty effects array loads as []")
	_check(yoga.get("unlock_requirement") == "milestone_a", "non-empty unlock_requirement round-trips")

	# Multi-zone membership + 2x2 footprint.
	var bench = catalog.call("get_definition", "bench_press")
	_check(
		bench.get("zone_membership") == ["strength", "free_weights"],
		"multi-zone membership round-trips"
	)
	_check((bench.get("footprint_cells") as Array).size() == 4, "2x2 footprint has 4 cells")

	# Frozen catalog is queryable; repeated queries value-equal (AC-C.8 posture).
	_check(catalog.call("has_definition", "yoga_mat") == true, "has_definition works on the loaded catalog")
	var again = catalog.call("get_definition", "treadmill_basic")
	_check(_defs_value_equal(treadmill, again), "repeated get_definition returns value-equal copies")


# === AC-JSON.2: JSON 语法错误 → 带行号 LoadError ===

func _test_ac_json2_parse_error_with_line() -> void:
	print("\n[AC-JSON.2] malformed JSON -> LoadError with JSON.parse() line number")

	# NOTE: Godot 4.7.1's JSON parser LENIENTLY ACCEPTS trailing commas
	# (empirically verified: err=0) — so the QA "trailing comma" case cannot
	# produce a parse error. A missing comma between array elements is used
	# instead; both fixtures report the error on line 3 (verified empirically).
	var result: RefCounted = _load_result("syntax_missing_comma.catalog.json", false)
	_check(result.get("ok") == false, "missing comma -> ok=false")
	var errors: Array = result.get("errors")
	_check(errors.size() == 1, "exactly one LoadError")
	var err = errors[0]
	_check(err.get("category") == "JSON_PARSE_ERROR", "category is JSON_PARSE_ERROR")
	_check(err.get("message").begins_with("Line "), "message carries line info: '%s'" % err.get("message"))
	_check(
		err.get("message").find("Line 3") != -1,
		"missing comma reported with the exact line number from JSON.parse() (Line 3)"
	)

	var result2: RefCounted = _load_result("missing_brace.catalog.json", false)
	_check(result2.get("ok") == false, "missing brace -> ok=false")
	var err2 = result2.get("errors")[0]
	_check(err2.get("category") == "JSON_PARSE_ERROR", "missing brace category is JSON_PARSE_ERROR")
	_check(
		err2.get("message").find("Line 3") != -1,
		"missing brace reported with the exact line number from JSON.parse() (Line 3)"
	)


# === AC-JSON.2 边界: 合法 JSON 但结构非法 ===

func _test_ac_json2_schema_errors() -> void:
	print("\n[AC-JSON.2 edge] valid JSON but wrong shape -> INVALID_SCHEMA / FILE_NOT_FOUND")

	# QA edge: valid JSON but missing the "equipment" key.
	var result: RefCounted = _load_result("missing_equipment.catalog.json", false)
	_check(result.get("ok") == false, "missing 'equipment' key -> ok=false")
	var err = result.get("errors")[0]
	_check(err.get("category") == "INVALID_SCHEMA", "missing equipment -> INVALID_SCHEMA")
	_check(err.get("message").find("equipment") != -1, "message names the 'equipment' array")

	# QA edge: equipment present but a string instead of an array.
	var result2: RefCounted = _load_result("equipment_not_array.catalog.json", false)
	_check(result2.get("ok") == false, "equipment as string -> ok=false")
	var err2 = result2.get("errors")[0]
	_check(err2.get("category") == "INVALID_SCHEMA", "equipment as string -> INVALID_SCHEMA")

	# Missing file on disk.
	var loader: Script = _loader()
	var result3: RefCounted = loader.load_from_file(FIXTURES_DIR + "does_not_exist.catalog.json", false)
	_check(result3.get("ok") == false, "missing file -> ok=false")
	_check(result3.get("errors")[0].get("category") == "FILE_NOT_FOUND", "missing file -> FILE_NOT_FOUND")
	_check(result3.get("catalog") != null, "fail() still returns a queryable (empty, frozen) catalog")


# === strict_mode=false: 剔除坏记录，其余正常加载 ===

func _test_strict_mode_false_skips_invalid_entry() -> void:
	print("\n[strict_mode=false] invalid entry skipped, valid entries still load, error recorded")

	var result: RefCounted = _load_result("one_invalid_entry.catalog.json", false)
	_check(result.get("ok") == true, "ok=true despite one bad entry")
	var catalog: RefCounted = result.get("catalog")
	_check(catalog.call("get_all_ids") == ["good_treadmill"], "only the valid entry loaded")
	var errors: Array = result.get("errors")
	_check(errors.size() == 1, "exactly one error recorded")
	var err = errors[0]
	_check(err.get("category") == "INVALID_ENTRY", "category is INVALID_ENTRY")
	_check(err.get("equipment_id") == "bad_cost", "error names the offending entry id")
	_check(err.get("message").find("cost") != -1, "error message names the offending field ('cost')")

	# All entries invalid -> frozen EMPTY catalog, ok=false, one error per entry.
	var result2: RefCounted = _load_result("all_invalid.catalog.json", false)
	_check(result2.get("ok") == false, "all entries invalid -> ok=false (no usable catalog)")
	var catalog2: RefCounted = result2.get("catalog")
	_check((catalog2.call("get_all_ids") as Array).is_empty(), "frozen catalog is empty")
	_check(result2.get("errors").size() == 2, "one LoadError per invalid entry")


# === strict_mode=true: assert 中止（子进程探针） ===

func _test_strict_mode_true_asserts() -> void:
	print("\n[strict_mode=true] failing entry fires assert (isolated subprocess probe)")

	var res := _run_probe("strict_assert")
	_check(res["exit_code"] == 0, "probe exits 0 (assert aborts the frame, not the process)")
	_check(res["output"].find("Assertion failed") != -1, "assert fired")
	_check(
		res["output"].find("failed to load 'bad_cost'") != -1,
		"assert message names the offending entry id ('bad_cost')"
	)
	_check(
		res["output"].find("PROBE_OPERATION_COMPLETED") != -1,
		"probe completes after the firing assert"
	)
