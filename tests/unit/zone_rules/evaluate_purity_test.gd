# tests/unit/zone_rules/evaluate_purity_test.gd
# Story 001: Pure evaluate() and Effect Vocabulary
# Covers the 7 BLOCKING ACs scoped to this story: AC1 (bit-identical purity),
# AC8 (non-negativity), AC11 (empty layout), AC12 (single instance),
# AC13 (static read-only source scan), AC14 (output shape), AC16 (ascending
# instance_id iteration). Uses fake GridStateReader / frozen EquipmentCatalog
# stubs per the story requirement — constructing a real grid+placement stack
# is too heavy for a pure-function unit test.
# Run standalone: godot --headless --script tests/unit/zone_rules/evaluate_purity_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

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
	print("  UNIT TEST: ZoneRules — Pure evaluate() and Effect Vocabulary (Story 001)")
	print("=".repeat(48))

	_test_ac1_pure_function_100_calls_bit_identical()
	_test_ac1_interleaved_calls_no_hidden_state()
	_test_ac8_all_values_non_negative_worst_case_clutter()
	_test_ac11_empty_layout_returns_empty_dictionary()
	_test_ac12_single_instance_zone_synergy_zero()
	_test_ac13_static_read_only_source_scan()
	_test_ac14_output_shape_exact_keys()
	_test_ac16_non_contiguous_ids_ascending_order()

	print("\n=== EVALUATE PURITY TEST: %d passed, %d failed ===" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


# === Helpers ===

func _ED() -> Script:
	return load("res://src/systems/equipment_def.gd") as Script


func _EC() -> Script:
	return load("res://src/systems/equipment_catalog.gd") as Script


func _PI() -> Script:
	return load("res://src/systems/placed_instance.gd") as Script


func _ZR() -> Script:
	return load("res://src/systems/zone_rules.gd") as Script


## Builds a valid canonical-0° fixture def with the given zone membership and
## effects container. TYPED arrays are required — Godot's typed-array
## parameter boundary rejects untyped literals through Object.call()
## (tech-debt register, Story 005); direct .new() with typed locals is safe.
func _make_def(id: String, zones: Array, effects: Array[Dictionary]) -> RefCounted:
	var footprint: Array[Vector2i] = [Vector2i(0, 0)]
	var access: Array[Vector2i] = [Vector2i(0, 1)]
	var def: RefCounted = _ED().new(
		id,
		"Test %s" % id,
		zones,
		footprint,
		access,
		100,
		"",
		effects,
		200,
		30,
		100,
		300,
	)
	return def


## Loads a frozen catalog holding the given defs (via the internal loader API
## the way Story 002's JSON loader will — _add_definition()..._freeze()).
func _make_catalog(defs: Array) -> RefCounted:
	var cat: RefCounted = _EC().new()
	for d in defs:
		cat.call("_add_definition", d)
	cat.call("_freeze")
	return cat


## Builds a PlacedInstance DTO (Story 006 / ADR-0003 shape: instance_id,
## equipment_id, anchor, rotation, transformed footprint + access cells).
func _make_instance(id: int, equipment_id: String, footprint: Array[Vector2i], access: Array[Vector2i]) -> RefCounted:
	return _PI().new(id, equipment_id, Vector2i(0, 0), 0, footprint, access)


## Builds a fake GridStateReader stub returning the given placed instances.
func _make_reader(instances: Array[PlacedInstance]) -> RefCounted:
	var reader: RefCounted = (load("res://tests/unit/zone_rules/fake_grid_state_reader.gd") as Script).new()
	reader.placed_instances = instances
	return reader


## Convenience: a fresh ZoneRules instance evaluating [reader] against
## [catalog]. Story-001 scope: zone_synergy and spaciousness are 0.0
## placeholders (Stories 002/003 own their formulas).
func _evaluate(reader: RefCounted, catalog: RefCounted) -> Dictionary:
	var zr: RefCounted = _ZR().new()
	return zr.call("evaluate", reader, catalog)


# === AC1: 纯函数确定性 ===

func _test_ac1_pure_function_100_calls_bit_identical() -> void:
	print("\n[AC1] evaluate(S) called 100 times returns bit-identical Dictionary values")

	var catalog := _make_catalog([
		_make_def("treadmill", ["cardio"], [{"tag": "comfort", "magnitude": 0.4}]),
		_make_def("barbell", ["strength"], [{"tag": "comfort", "magnitude": 0.85}]),
		_make_def("bench", ["strength"], [{"tag": "comfort", "magnitude": 1.0}]),
	])
	var reader := _make_reader([
		_make_instance(2, "treadmill", [Vector2i(0, 0), Vector2i(1, 0)], [Vector2i(0, 1)]),
		_make_instance(7, "barbell", [Vector2i(0, 0)], [Vector2i(0, 1)]),
		_make_instance(40, "bench", [Vector2i(0, 0), Vector2i(1, 0), Vector2i(0, 1), Vector2i(1, 1)], [Vector2i(2, 0)]),
	])

	var zr: RefCounted = _ZR().new()
	var first: Dictionary = zr.call("evaluate", reader, catalog)
	var identical := true
	for i in 99:
		var next: Dictionary = zr.call("evaluate", reader, catalog)
		if not (next == first):
			identical = false
			break

	_check(identical, "all 100 sequential evaluate(S) calls return bit-identical Dictionary values (no variance, no time/order dependence, no RNG)")
	_check(first.size() == 3, "result has exactly one row per placed instance (3 instances -> 3 rows)")
	_check(first[2]["comfort"] == 0.4 and first[7]["comfort"] == 0.85 and first[40]["comfort"] == 1.0, "authored comfort values pass through unchanged (0.4 / 0.85 / 1.0)")


func _test_ac1_interleaved_calls_no_hidden_state() -> void:
	print("\n[AC1 edge] repeated calls between OTHER evaluations — no hidden state")

	var catalog := _make_catalog([
		_make_def("lone", ["strength"], [{"tag": "comfort", "magnitude": 0.5}]),
	])
	var reader_a := _make_reader([
		_make_instance(1, "lone", [Vector2i(0, 0)], [Vector2i(0, 1)]),
	])
	var reader_b := _make_reader([
		_make_instance(2, "lone", [Vector2i(0, 0)], [Vector2i(0, 1)]),
		_make_instance(3, "lone", [Vector2i(1, 0)], [Vector2i(1, 1)]),
	])

	var zr: RefCounted = _ZR().new()
	var baseline: Dictionary = zr.call("evaluate", reader_a, catalog)
	# Interleave evaluations on a DIFFERENT snapshot, then re-evaluate S.
	zr.call("evaluate", reader_b, catalog)
	zr.call("evaluate", reader_b, catalog)
	var after: Dictionary = zr.call("evaluate", reader_a, catalog)

	_check(after == baseline, "evaluate(S) after interleaved calls on other snapshots is bit-identical — no hidden state on the instance")


# === AC8: 非负性 ===

func _test_ac8_all_values_non_negative_worst_case_clutter() -> void:
	print("\n[AC8] comfort / zone_synergy / spaciousness / total never negative (worst-case cross-zone clutter)")

	# Worst-case clutter: four different zones cross-adjacent, a piece with NO
	# comfort tag, and a multi-zone piece. (Unknown equipment_id handling is
	# Story 004's scope — the strict_mode reporting channel lives there; a
	# valid snapshot never contains a stale id.)
	var catalog := _make_catalog([
		_make_def("strength_machine", ["strength"], [{"tag": "comfort", "magnitude": 0.7}]),
		_make_def("cardio_machine", ["cardio"], [{"tag": "comfort", "magnitude": 0.9}]),
		_make_def("social_piece", ["social"], [{"tag": "comfort", "magnitude": 0.3}]),
		_make_def("no_comfort_piece", ["strength"], []),
		_make_def("combo_piece", ["strength", "cardio"], [{"tag": "comfort", "magnitude": 0.5}]),
	])
	var reader := _make_reader([
		_make_instance(1, "strength_machine", [Vector2i(0, 0)], [Vector2i(0, 1)]),
		_make_instance(2, "cardio_machine", [Vector2i(1, 0)], [Vector2i(1, 1)]),
		_make_instance(3, "social_piece", [Vector2i(2, 0)], [Vector2i(2, 1)]),
		_make_instance(4, "no_comfort_piece", [Vector2i(3, 0)], [Vector2i(3, 1)]),
		_make_instance(5, "combo_piece", [Vector2i(4, 0)], [Vector2i(4, 1)]),
	])

	var result := _evaluate(reader, catalog)
	var all_non_negative := true
	for row in result.values():
		var d: Dictionary = row
		for key in ["comfort", "zone_synergy", "spaciousness", "total"]:
			if float(d[key]) < 0.0:
				all_non_negative = false
	_check(all_non_negative, "every instance row: comfort, zone_synergy, spaciousness, total >= 0 (never negative)")

	_check(result[4]["comfort"] == 0.0, "def with no comfort tag earns comfort 0.0 (missing tag is 0, never negative)")
	_check(result[5]["total"] == result[5]["comfort"], "combo piece total equals its comfort (synergy/spaciousness placeholders are 0)")


# === AC11: 空布局 ===

func _test_ac11_empty_layout_returns_empty_dictionary() -> void:
	print("\n[AC11] get_placed_instances() returns [] -> evaluate() returns empty Dictionary")

	var catalog := _make_catalog([
		_make_def("treadmill", ["cardio"], [{"tag": "comfort", "magnitude": 0.5}]),
	])
	var reader := _make_reader([])

	var result := _evaluate(reader, catalog)
	_check(result is Dictionary, "evaluate() returns a Dictionary (no error on empty layout)")
	_check(result.is_empty(), "empty layout returns an EMPTY Dictionary")
	_check(result.size() == 0, "result has zero rows")


# === AC12: 单实例 ===

func _test_ac12_single_instance_zone_synergy_zero() -> void:
	print("\n[AC12] exactly 1 placed instance, no neighbors -> zone_synergy == 0.0, total == comfort + spaciousness")

	var catalog := _make_catalog([
		_make_def("lone_machine", ["strength"], [{"tag": "comfort", "magnitude": 0.6}]),
	])
	var reader := _make_reader([
		_make_instance(5, "lone_machine", [Vector2i(0, 0)], [Vector2i(0, 1)]),
	])

	var result := _evaluate(reader, catalog)
	var row: Dictionary = result[5]
	_check(row["zone_synergy"] == 0.0, "single instance with no neighbors: zone_synergy_i == 0.0 exactly")
	_check(row["total"] == row["comfort"] + row["spaciousness"], "total_i == comfort_i + spaciousness_i (single instance, no synergy)")
	_check(row["comfort"] == 0.6, "comfort passes through from the catalog-authored effects")


# === AC13: 静态只读 ===

func _test_ac13_static_read_only_source_scan() -> void:
	print("\n[AC13] zone_rules.gd source references ONLY the documented read contract (static scan)")

	var source: String = FileAccess.get_file_as_string("res://src/systems/zone_rules.gd")
	_check(source.length() > 0, "zone_rules.gd source is readable and non-empty (no stub)")

	# Must use the two read methods Story 001 needs...
	_check(source.contains("get_placed_instances"), "source calls GridStateReader.get_placed_instances()")
	_check(source.contains("get_definition"), "source calls EquipmentCatalog.get_definition()")

	# ...and must NOT reference any other grid-read / dynamic-state API —
	# AC13 edge case: no references to the crowding/member-sim classes or any
	# live data accessor anywhere in the file.
	var forbidden := [
		"get_occupant_id",        # single-cell occupancy lookup — not in the documented set
		"get_access_cells",       # single-cell access lookup — not in the documented set
		"get_member_position",    # live member-position accessor
		"get_queue_length",       # queue-length accessor
		"get_position",           # any live position accessor
		"Congestion",             # dynamic crowding system — must not be referenced
		"MemberSim",              # dynamic member system — must not be referenced
	]
	var clean := true
	for token in forbidden:
		if source.contains(token):
			clean = false
			print("    found forbidden token: %s" % token)
	_check(clean, "source contains none of the forbidden dynamic-state / non-documented API tokens")


# === AC14: 输出形状 ===

func _test_ac14_output_shape_exact_keys() -> void:
	print("\n[AC14] every value Dictionary contains exactly {comfort, zone_synergy, spaciousness, total}")

	var catalog := _make_catalog([
		_make_def("treadmill", ["cardio"], [{"tag": "comfort", "magnitude": 0.4}]),
		_make_def("barbell", ["strength"], [{"tag": "comfort", "magnitude": 0.85}]),
	])
	var reader := _make_reader([
		_make_instance(2, "treadmill", [Vector2i(0, 0), Vector2i(1, 0)], [Vector2i(0, 1)]),
		_make_instance(7, "barbell", [Vector2i(0, 0)], [Vector2i(0, 1)]),
		_make_instance(9, "barbell", [Vector2i(1, 0)], [Vector2i(1, 1)]),
	])

	var result := _evaluate(reader, catalog)
	var shape_ok := true
	for row in result.values():
		var d: Dictionary = row
		if d.size() != 4:
			shape_ok = false
		for key in ["comfort", "zone_synergy", "spaciousness", "total"]:
			if not d.has(key):
				shape_ok = false
	_check(shape_ok, "every value Dictionary has EXACTLY the 4 keys {comfort, zone_synergy, spaciousness, total} — no missing, no extra")
	_check(result.size() == 3, "one row per placed instance (3 instances -> 3 rows)")


# === AC16: 非连续 id 排序 ===

func _test_ac16_non_contiguous_ids_ascending_order() -> void:
	print("\n[AC16] non-contiguous instance_ids (2, 7, 40) iterated in ascending order")

	var catalog := _make_catalog([
		_make_def("treadmill", ["cardio"], [{"tag": "comfort", "magnitude": 0.4}]),
		_make_def("barbell", ["strength"], [{"tag": "comfort", "magnitude": 0.85}]),
		_make_def("bench", ["strength"], [{"tag": "comfort", "magnitude": 1.0}]),
	])
	# Dictionary preserves insertion order but does NOT auto-sort — feed the
	# snapshot SHUFFLED (insertion order differs from id order) and require
	# the implementation to sort before emitting rows.
	var reader := _make_reader([
		_make_instance(7, "barbell", [Vector2i(0, 0)], [Vector2i(0, 1)]),
		_make_instance(40, "bench", [Vector2i(0, 0)], [Vector2i(0, 1)]),
		_make_instance(2, "treadmill", [Vector2i(0, 0)], [Vector2i(0, 1)]),
	])

	var result := _evaluate(reader, catalog)
	_check(result.keys() == [2, 7, 40], "result Dictionary keys are in ascending instance_id order (2, 7, 40) despite shuffled input order")
