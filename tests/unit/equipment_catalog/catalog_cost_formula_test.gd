# tests/unit/equipment_catalog/catalog_cost_formula_test.gd
# Story 006: Provisional Cost Formula
# Covers the BLOCKING ACs AC-D.3, AC-PROV.1, AC-PROV.2 plus the ADVISORY
# AC-D.4 marker (as a static source check) — GDD design/gdd/equipment-catalog.md
# §Formulas → provisional_equipment_cost.
#
# The formula is a dedicated static utility (EquipmentCostFormula) rather than
# a method on EquipmentCatalog or EquipmentDef:
#   - EquipmentCatalog's public API is pinned by Story 001's AC-C.8 static
#     check to exactly the 3 read-only queries — a public static method would
#     appear in get_script_method_list() and break that check.
#   - EquipmentDef is a logic-free DTO.
# The JSON loader (Story 002) calls compute_provisional_cost() at EquipmentDef
# construction time when a JSON entry omits "cost"; this test simulates that
# construction path exactly (cost := formula output → EquipmentDef → catalog).
#
# Run standalone: godot --headless --script tests/unit/equipment_catalog/catalog_cost_formula_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"
const FORMULA_PATH := "res://src/systems/equipment_cost_formula.gd"

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
	print("  UNIT TEST: EquipmentCatalog — Provisional Cost Formula (Story 006)")
	print("=".repeat(48))

	_test_ac_d3_default_outputs()
	_test_ac_d3_only_three_outputs_for_mvp()
	_test_ac_prov_1_catalog_returns_formula_cost()
	_test_ac_prov_1_no_hardcoded_cost_table()
	_test_ac_prov_2_parameterized_outputs()
	_test_ac_d4_provisional_marker_static_check()

	print("\n=== CATALOG COST FORMULA TEST: %d passed, %d failed ===" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


# === Helpers ===

func _F() -> Script:
	return load(FORMULA_PATH) as Script


func _ED() -> Script:
	return load("res://src/systems/equipment_def.gd") as Script


func _EC() -> Script:
	return load("res://src/systems/equipment_catalog.gd") as Script


## The three locked canonical footprints (GDD Core Rule 3): 1×1, 1×2, 2×2.
## Area (cell count) is the ONLY input the formula consumes.
func _footprint_area_1() -> Array[Vector2i]:
	return [Vector2i(0, 0)]


func _footprint_area_2() -> Array[Vector2i]:
	return [Vector2i(0, 0), Vector2i(1, 0)]


func _footprint_area_4() -> Array[Vector2i]:
	return [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)]


## Builds an EquipmentDef the way Story 002's loader will: cost is DERIVED
## from the formula (the loader never hardcodes a per-equipment price). The
## remaining fields are the standard valid fixture (1×2 footprint + 1 access).
func _make_def_with_formula_cost(ED: Script, id: String, footprint: Array[Vector2i], formula: RefCounted) -> RefCounted:
	var zone: Array = ["cardio"]
	var access: Array[Vector2i] = [Vector2i(0, 1)]
	var effects: Array[Dictionary] = [{"tag": "comfort", "magnitude": 0.1}]
	var cost: int = formula.compute_provisional_cost(footprint)
	var def: RefCounted = ED.new(
		id,
		"Test %s" % id,
		zone,
		footprint,
		access,
		cost,
		"",
		effects,
		200,
		30,
		100,
		300,
	)
	return def


## Loads a frozen catalog holding the given defs (internal loader API, exactly
## how Story 002's JSON loader will populate then freeze it).
func _make_catalog(defs: Array) -> RefCounted:
	var cat: RefCounted = _EC().new()
	for d in defs:
		cat.call("_add_definition", d)
	cat.call("_freeze")
	return cat


# === AC-D.3: 默认参数输出 200/350/650 ===

func _test_ac_d3_default_outputs() -> void:
	print("\n[AC-D.3] default params (base=200, tier=150): area 1/2/4 → 200/350/650")

	var formula: RefCounted = _F().new()

	_check(
		formula.compute_provisional_cost(_footprint_area_1()) == 200,
		"area 1 (1×1) → 200"
	)
	_check(
		formula.compute_provisional_cost(_footprint_area_2()) == 350,
		"area 2 (1×2) → 350"
	)
	_check(
		formula.compute_provisional_cost(_footprint_area_4()) == 650,
		"area 4 (2×2) → 650"
	)

	# Explicitly named defaults must exist as PROVISIONAL constants and equal
	# the documented MVP values (AC-PROV.2's "constants, not magic numbers").
	_check(
		formula.PROVISIONAL_BASE_COST == 200,
		"PROVISIONAL_BASE_COST constant == 200"
	)
	_check(
		formula.PROVISIONAL_TIER_STEP == 150,
		"PROVISIONAL_TIER_STEP constant == 150"
	)


func _test_ac_d3_only_three_outputs_for_mvp() -> void:
	print("\n[AC-D.3 edge] only the 3 MVP output values are possible with defaults")

	var formula: RefCounted = _F().new()
	var outputs: Dictionary = {}
	for footprint in [_footprint_area_1(), _footprint_area_2(), _footprint_area_4()]:
		outputs[formula.compute_provisional_cost(footprint)] = true

	_check(outputs.size() == 3, "exactly 3 distinct outputs for the 3 locked shapes")
	_check(outputs.has(200) and outputs.has(350) and outputs.has(650),
		"output set is exactly {200, 350, 650}")


# === AC-PROV.1: get_definition(id).cost 来自公式 ===

func _test_ac_prov_1_catalog_returns_formula_cost() -> void:
	print("\n[AC-PROV.1] catalog get_definition(id).cost matches formula output (350 for 1×2)")

	var formula: RefCounted = _F().new()
	var footprint: Array[Vector2i] = _footprint_area_2()
	var def: RefCounted = _make_def_with_formula_cost(_ED(), "treadmill", footprint, formula)
	var cat: RefCounted = _make_catalog([def])

	var queried: RefCounted = cat.call("get_definition", "treadmill")
	_check(queried != null, "definition loads and queries")

	# The cost the catalog returns must equal the formula output for this
	# footprint (350 with MVP defaults) — the formula is the source of truth.
	_check(
		queried.get("cost") == 350,
		"get_definition('treadmill').cost == 350 for a 1×2 footprint"
	)
	_check(
		queried.get("cost") == formula.compute_provisional_cost(footprint),
		"get_definition(id).cost == compute_provisional_cost(same footprint) — cost is formula-derived"
	)

	# Same construction path for the other two locked shapes: 1×1 → 200, 2×2 → 650.
	for pair in [
		["mat", _footprint_area_1(), 200],
		["rack", _footprint_area_4(), 650],
	]:
		var d: RefCounted = _make_def_with_formula_cost(_ED(), pair[0], pair[1], formula)
		var c: RefCounted = _make_catalog([d])
		var q: RefCounted = c.call("get_definition", pair[0])
		_check(
			q.get("cost") == pair[2],
			"get_definition('%s').cost == %d for area %d footprint" % [pair[0], pair[2], (pair[1] as Array).size()]
		)


func _test_ac_prov_1_no_hardcoded_cost_table() -> void:
	print("\n[AC-PROV.1 edge] formula has no hardcoded per-equipment or per-area price table")

	var formula: RefCounted = _F().new()

	# The formula must not consult any id→cost or area→cost lookup: the same
	# footprint area must be able to produce different costs under different
	# parameters (proven by AC-PROV.2 below), and the function's own body must
	# contain no data table. Static check: read the source.
	var source: String = FileAccess.get_file_as_string(FORMULA_PATH)
	_check(source != "", "can read formula source for static check")

	# No JSON-style dictionary/array of prices anywhere in the source.
	_check(
		source.find("200, 350, 650") == -1 and source.find("200/350/650") == -1,
		"source contains no embedded price table literal"
	)
	_check(
		source.find("compute_provisional_cost") != -1,
		"compute_provisional_cost exists in source"
	)

	# The return expression must be the formula itself (parameterized), not a
	# lookup — verify the formula body lines.
	_check(
		source.find("base_cost + tier_step * (area - 1)") != -1,
		"formula body is the parameterized expression base_cost + tier_step * (area - 1)"
	)


# === AC-PROV.2: 参数化可调 ===

func _test_ac_prov_2_parameterized_outputs() -> void:
	print("\n[AC-PROV.2] parameterized base=100, tier=50: area 1/2/4 → 100/150/250")

	var formula: RefCounted = _F().new()

	_check(
		formula.compute_provisional_cost(_footprint_area_1(), 100, 50) == 100,
		"area 1 with base=100/tier=50 → 100"
	)
	_check(
		formula.compute_provisional_cost(_footprint_area_2(), 100, 50) == 150,
		"area 2 with base=100/tier=50 → 150"
	)
	_check(
		formula.compute_provisional_cost(_footprint_area_4(), 100, 50) == 250,
		"area 4 with base=100/tier=50 → 250"
	)

	# Parameters flow through to the catalog's stored cost — the loader passes
	# the tuned values at construction, so the whole pipeline respects them.
	var def: RefCounted = _make_def_with_formula_cost(_ED(), "bench", _footprint_area_2(), formula)
	def.cost = formula.compute_provisional_cost(_footprint_area_2(), 100, 50)
	var cat: RefCounted = _make_catalog([def])
	var q: RefCounted = cat.call("get_definition", "bench")
	_check(
		q.get("cost") == 150,
		"get_definition('bench').cost == 150 under tuned base=100/tier=50 — no recompilation needed"
	)


# === AC-D.4 (ADVISORY): PROVISIONAL 标记 ===

func _test_ac_d4_provisional_marker_static_check() -> void:
	print("\n[AC-D.4 advisory] PROVISIONAL marker traceable in code (static source check)")

	var source: String = FileAccess.get_file_as_string(FORMULA_PATH)

	# Constants must be named with the PROVISIONAL_ prefix.
	_check(
		source.find("const PROVISIONAL_BASE_COST := 200") != -1,
		"PROVISIONAL_BASE_COST constant declared with PROVISIONAL_ prefix"
	)
	_check(
		source.find("const PROVISIONAL_TIER_STEP := 150") != -1,
		"PROVISIONAL_TIER_STEP constant declared with PROVISIONAL_ prefix"
	)

	# The file must carry the ⚠️ PROVISIONAL marker in its header comment.
	_check(
		source.find("PROVISIONAL") != -1,
		"source contains PROVISIONAL marker"
	)
	_check(
		source.find("will be replaced when Economy/Shop GDD") != -1,
		"source names the deprecation trigger (Economy/Shop GDD)"
	)
	_check(
		source.find("AC-D.4") != -1,
		"source references the mandatory re-evaluation checkpoint AC-D.4"
	)
