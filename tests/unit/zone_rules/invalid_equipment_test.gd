# tests/unit/zone_rules/invalid_equipment_test.gd
# Story 004: Invalid Equipment (AC15a / AC15b)
#
# An instance whose equipment_id has no EquipmentCatalog definition is an
# upstream invariant violation (PlacementSystem committed a type not in the
# Catalog), NOT a ZoneRules bug. The GDD mandates an INJECTED, capturable
# channel — strict_mode + on_invalid_equipment — never a bare assert() (a
# bare assert is a no-op in release and cannot be tested in headless CI).
#
# AC15a (strict_mode=false): evaluate() returns normally; the offending
#   instance's row is {comfort=0, zone_synergy=0, spaciousness=<computed>,
#   total=spaciousness}; it is EXCLUDED from neighbors' n_same; the injected
#   on_invalid_equipment callback fires exactly once per offender with
#   (instance_id, equipment_id).
# AC15b (strict_mode=true): evaluate() does NOT return a normal result — it
#   returns the structured error {"error": {kind, offenders}} (a
#   return-type variant, OQ4-sanctioned), deterministically observable by a
#   test harness without stderr capture, exit code, or assert().
#
# Static guarantees also asserted here: zone_rules.gd contains no bare
# assert() for invalid-equipment handling, and (TR-ZR-007) contributes no
# serialization surface (no serialize/deserialize methods).
# Run standalone: godot --headless --script tests/unit/zone_rules/invalid_equipment_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const TOL := 1e-6

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
	print("  UNIT TEST: ZoneRules — Invalid Equipment Channel (Story 004)")
	print("=".repeat(48))

	_test_ac15a_single_invalid_lenient_zeroed_row()
	_test_ac15a_excluded_from_neighbors_n_same()
	_test_ac15a_multiple_invalid_callback_per_instance()
	_test_ac15a_spaciousness_still_computed_geometrically()
	_test_ac15b_strict_returns_structured_error()
	_test_ac15b_strict_multiple_offenders_in_error()
	_test_ac15b_no_normal_result_key_shape()
	_test_static_no_bare_assert()
	_test_static_no_serialization_surface()

	print("\n=== INVALID EQUIPMENT TEST: %d passed, %d failed ===" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


func _almost_eq(a: float, b: float, tol: float) -> bool:
	return abs(a - b) <= tol


# === Helpers ===

func _ED() -> Script:
	return load("res://src/systems/equipment_def.gd") as Script


func _EC() -> Script:
	return load("res://src/systems/equipment_catalog.gd") as Script


func _PI() -> Script:
	return load("res://src/systems/placed_instance.gd") as Script


func _ZR() -> Script:
	return load("res://src/systems/zone_rules.gd") as Script


## Builds a valid canonical-0° fixture def. TYPED arrays are required —
## Godot's typed-array parameter boundary rejects untyped literals through
## Object.call() (tech-debt register, Story 005).
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


## Loads a frozen catalog holding the given defs.
func _make_catalog(defs: Array) -> RefCounted:
	var cat: RefCounted = _EC().new()
	for d in defs:
		cat.call("_add_definition", d)
	cat.call("_freeze")
	return cat


## Builds a PlacedInstance DTO (instance_id, equipment_id, anchor, rotation,
## transformed footprint + access cells).
func _make_instance(id: int, equipment_id: String, footprint: Array[Vector2i], access: Array[Vector2i]) -> RefCounted:
	return _PI().new(id, equipment_id, Vector2i(0, 0), 0, footprint, access)


## Builds a fake GridStateReader with the given placed instances, grid size
## and solid cells (static solidity: walls + placed footprints).
func _make_reader(instances: Array[PlacedInstance], dims: Vector2i, solid: Array[Vector2i]) -> RefCounted:
	var reader: RefCounted = (load("res://tests/unit/zone_rules/fake_grid_state_reader.gd") as Script).new()
	reader.placed_instances = instances
	reader.grid_dimensions = dims
	var solid_dict: Dictionary = {}
	for c in solid:
		solid_dict[c] = true
	reader.solid_cells = solid_dict
	return reader


## Convenience: a fresh ZoneRules instance evaluating [reader] against
## [catalog] with an explicit [config] (strict_mode / on_invalid_equipment
## keys ride the same Dictionary as the Story 002 tuning seam).
func _evaluate_with_config(reader: RefCounted, catalog: RefCounted, config: Dictionary) -> Dictionary:
	var zr: RefCounted = _ZR().new()
	return zr.call("evaluate", reader, catalog, config)


## A recording callback: appends each (instance_id, equipment_id) call.
func _make_recorder() -> Array:
	var calls: Array = []
	return calls


# === AC15a: 宽容模式 (strict_mode=false) ===

func _test_ac15a_single_invalid_lenient_zeroed_row() -> void:
	print("\n[AC15a] single invalid equipment_id, strict_mode=false — returns normally with zeroed row")

	var catalog := _make_catalog([
		_make_def("barbell", ["strength"], [{"tag": "comfort", "magnitude": 0.85}]),
	])
	var dims := Vector2i(10, 10)
	var instances: Array[PlacedInstance] = [
		_make_instance(1, "barbell", [Vector2i(5, 5)], [Vector2i(5, 6)]) as PlacedInstance,
		# instance 2's equipment_id has NO catalog definition (stale/corrupt type id)
		_make_instance(2, "ghost_machine", [Vector2i(6, 5)], [Vector2i(6, 6)]) as PlacedInstance,
	]
	var reader := _make_reader(instances, dims, [Vector2i(5, 5), Vector2i(6, 5)])

	var calls: Array = _make_recorder()
	var config := {
		"on_invalid_equipment": func(instance_id: int, equipment_id: String) -> void:
			calls.append([instance_id, equipment_id]),
	}
	var result := _evaluate_with_config(reader, catalog, config)

	# Returns NORMALLY: a normal per-instance result for every instance.
	_check(result.has(1) and result.has(2), "evaluate() returns normally — both instance rows present")
	_check(not result.has("error"), "no 'error' key in lenient mode (normal result shape)")

	# The offending instance's row: comfort=0, zone_synergy=0, spaciousness
	# computed geometrically, total = spaciousness.
	var row: Dictionary = result[2]
	_check(row["comfort"] == 0.0, "invalid instance comfort == 0.0")
	_check(row["zone_synergy"] == 0.0, "invalid instance zone_synergy == 0.0")
	_check(row["spaciousness"] > 0.0, "invalid instance spaciousness computed geometrically (> 0): %.4f" % row["spaciousness"])
	_check(
		_almost_eq(row["total"], row["spaciousness"], 0.0),
		"invalid instance total == spaciousness (%.9f == %.9f)" % [row["total"], row["spaciousness"]]
	)

	# Callback fired exactly once with the offending instance_id + equipment_id.
	_check(calls.size() == 1, "on_invalid_equipment called exactly once (got %d calls)" % calls.size())
	_check(
		calls.size() == 1 and calls[0] == [2, "ghost_machine"],
		"callback received (instance_id=2, equipment_id='ghost_machine')"
	)


func _test_ac15a_excluded_from_neighbors_n_same() -> void:
	print("\n[AC15a] invalid instance EXCLUDED from neighbors' n_same")

	var catalog := _make_catalog([
		_make_def("barbell", ["strength"], [{"tag": "comfort", "magnitude": 0.85}]),
	])
	var dims := Vector2i(10, 10)

	# A valid strength barbell at (5,5); the invalid ghost at (6,5) is
	# orthogonally ADJACENT but must NOT count toward the barbell's n_same.
	var instances: Array[PlacedInstance] = [
		_make_instance(1, "barbell", [Vector2i(5, 5)], [Vector2i(5, 6)]) as PlacedInstance,
		_make_instance(2, "ghost_machine", [Vector2i(6, 5)], [Vector2i(6, 6)]) as PlacedInstance,
	]
	var reader := _make_reader(instances, dims, [Vector2i(5, 5), Vector2i(6, 5)])
	var calls: Array = _make_recorder()
	var result := _evaluate_with_config(reader, catalog, {
		"on_invalid_equipment": func(instance_id: int, equipment_id: String) -> void:
			calls.append([instance_id, equipment_id]),
	})

	# n_same for barbell = 0 → zone_synergy == 0.0 exactly, even though the
	# ghost is adjacent. If the ghost were (wrongly) counted, r=0.25 →
	# synergy ≈ 0.451.
	_check(result[1]["zone_synergy"] == 0.0, "neighbor barbell zone_synergy == 0.0 (invalid adjacent instance excluded from n_same)")

	# Control: with a VALID same-zone neighbor at the same spot, synergy > 0
	# — proving the exclusion is about the invalid id, not the adjacency.
	var control_instances: Array[PlacedInstance] = [
		_make_instance(1, "barbell", [Vector2i(5, 5)], [Vector2i(5, 6)]) as PlacedInstance,
		_make_instance(2, "barbell", [Vector2i(6, 5)], [Vector2i(6, 6)]) as PlacedInstance,
	]
	var control_reader := _make_reader(control_instances, dims, [Vector2i(5, 5), Vector2i(6, 5)])
	var control := _evaluate_with_config(control_reader, catalog, {})
	_check(control[1]["zone_synergy"] > 0.0, "control: valid same-zone neighbor DOES count (synergy > 0: %.4f)" % control[1]["zone_synergy"])


func _test_ac15a_multiple_invalid_callback_per_instance() -> void:
	print("\n[AC15a] multiple invalid instances — callback fires once PER offender")

	var catalog := _make_catalog([
		_make_def("barbell", ["strength"], [{"tag": "comfort", "magnitude": 0.85}]),
	])
	var dims := Vector2i(10, 10)
	var instances: Array[PlacedInstance] = [
		_make_instance(1, "barbell", [Vector2i(5, 5)], [Vector2i(5, 6)]) as PlacedInstance,
		_make_instance(2, "ghost_a", [Vector2i(6, 5)], [Vector2i(6, 6)]) as PlacedInstance,
		_make_instance(3, "ghost_b", [Vector2i(8, 8)], [Vector2i(8, 9)]) as PlacedInstance,
	]
	var reader := _make_reader(instances, dims, [Vector2i(5, 5), Vector2i(6, 5), Vector2i(8, 8)])
	var calls: Array = _make_recorder()
	var result := _evaluate_with_config(reader, catalog, {
		"on_invalid_equipment": func(instance_id: int, equipment_id: String) -> void:
			calls.append([instance_id, equipment_id]),
	})

	_check(calls.size() == 2, "callback called once per invalid instance (2 calls, got %d)" % calls.size())
	var found_a := false
	var found_b := false
	for call in calls:
		if call == [2, "ghost_a"]:
			found_a = true
		if call == [3, "ghost_b"]:
			found_b = true
	_check(found_a and found_b, "callback invoked with each offender's (instance_id, equipment_id)")
	_check(result.has(1) and result.has(2) and result.has(3), "all three rows still returned normally")


func _test_ac15a_spaciousness_still_computed_geometrically() -> void:
	print("\n[AC15a] invalid instance's spaciousness is GEOMETRIC (same as a valid twin)")

	var catalog := _make_catalog([
		_make_def("barbell", ["strength"], [{"tag": "comfort", "magnitude": 0.85}]),
	])
	var dims := Vector2i(10, 10)

	# Identical geometry: one valid, one invalid — spaciousness must match
	# (it reads static solidity only, never the catalog).
	var invalid_instances: Array[PlacedInstance] = [
		_make_instance(1, "barbell", [Vector2i(5, 5)], [Vector2i(5, 6)]) as PlacedInstance,
		_make_instance(2, "ghost_machine", [Vector2i(6, 5)], [Vector2i(6, 6)]) as PlacedInstance,
	]
	var valid_instances: Array[PlacedInstance] = [
		_make_instance(1, "barbell", [Vector2i(5, 5)], [Vector2i(5, 6)]) as PlacedInstance,
		_make_instance(2, "barbell", [Vector2i(6, 5)], [Vector2i(6, 6)]) as PlacedInstance,
	]
	var solid: Array[Vector2i] = [Vector2i(5, 5), Vector2i(6, 5)]
	var invalid_reader := _make_reader(invalid_instances, dims, solid)
	var valid_reader := _make_reader(valid_instances, dims, solid)
	var invalid_result := _evaluate_with_config(invalid_reader, catalog, {})
	var valid_result := _evaluate_with_config(valid_reader, catalog, {})

	_check(
		_almost_eq(invalid_result[2]["spaciousness"], valid_result[2]["spaciousness"], TOL),
		"invalid instance spaciousness == valid twin's (%.6f == %.6f)" % [invalid_result[2]["spaciousness"], valid_result[2]["spaciousness"]]
	)
	_check(invalid_result[2]["spaciousness"] > 0.0, "invalid instance spaciousness computed from geometry (> 0)")


# === AC15b: 严格模式 (strict_mode=true) ===

func _test_ac15b_strict_returns_structured_error() -> void:
	print("\n[AC15b] strict_mode=true — does NOT return a normal result; structured error via injected channel")

	var catalog := _make_catalog([
		_make_def("barbell", ["strength"], [{"tag": "comfort", "magnitude": 0.85}]),
	])
	var dims := Vector2i(10, 10)
	var instances: Array[PlacedInstance] = [
		_make_instance(1, "barbell", [Vector2i(5, 5)], [Vector2i(5, 6)]) as PlacedInstance,
		_make_instance(2, "ghost_machine", [Vector2i(6, 5)], [Vector2i(6, 6)]) as PlacedInstance,
	]
	var reader := _make_reader(instances, dims, [Vector2i(5, 5), Vector2i(6, 5)])
	var calls: Array = _make_recorder()
	var result := _evaluate_with_config(reader, catalog, {
		"strict_mode": true,
		"on_invalid_equipment": func(instance_id: int, equipment_id: String) -> void:
			calls.append([instance_id, equipment_id]),
	})

	# Deterministically observable WITHOUT stderr / exit-code / assert:
	# the return-type variant carries the structured error.
	_check(result.has("error"), "result is the structured-error variant (has 'error' key)")
	_check(result["error"]["kind"] == "invalid_equipment", "error.kind == 'invalid_equipment'")
	var offenders: Array = result["error"]["offenders"]
	_check(offenders.size() == 1, "error.offenders holds exactly the 1 offender (got %d)" % offenders.size())
	_check(
		offenders.size() == 1 and offenders[0] == {"instance_id": 2, "equipment_id": "ghost_machine"},
		"offender entry = {instance_id: 2, equipment_id: 'ghost_machine'}"
	)
	# The injected callback is still the observable per-offender channel.
	_check(calls.size() == 1 and calls[0] == [2, "ghost_machine"], "callback still fired once per offender in strict mode")


func _test_ac15b_strict_multiple_offenders_in_error() -> void:
	print("\n[AC15b] strict_mode=true with multiple offenders — all captured in the structured error")

	var catalog := _make_catalog([
		_make_def("barbell", ["strength"], [{"tag": "comfort", "magnitude": 0.85}]),
	])
	var dims := Vector2i(10, 10)
	var instances: Array[PlacedInstance] = [
		_make_instance(1, "barbell", [Vector2i(5, 5)], [Vector2i(5, 6)]) as PlacedInstance,
		_make_instance(2, "ghost_a", [Vector2i(6, 5)], [Vector2i(6, 6)]) as PlacedInstance,
		_make_instance(3, "ghost_b", [Vector2i(8, 8)], [Vector2i(8, 9)]) as PlacedInstance,
	]
	var reader := _make_reader(instances, dims, [Vector2i(5, 5), Vector2i(6, 5), Vector2i(8, 8)])
	var calls: Array = _make_recorder()
	var result := _evaluate_with_config(reader, catalog, {
		"strict_mode": true,
		"on_invalid_equipment": func(instance_id: int, equipment_id: String) -> void:
			calls.append([instance_id, equipment_id]),
	})

	var offenders: Array = result["error"]["offenders"]
	_check(offenders.size() == 2, "error.offenders holds both offenders (got %d)" % offenders.size())
	var found_a := false
	var found_b := false
	for entry in offenders:
		if entry == {"instance_id": 2, "equipment_id": "ghost_a"}:
			found_a = true
		if entry == {"instance_id": 3, "equipment_id": "ghost_b"}:
			found_b = true
	_check(found_a and found_b, "both offender entries present in structured error")
	_check(calls.size() == 2, "callback fired per offender in strict mode (2 calls)")


func _test_ac15b_no_normal_result_key_shape() -> void:
	print("\n[AC15b] strict error is NOT a normal result (no per-instance score rows)")

	var catalog := _make_catalog([
		_make_def("barbell", ["strength"], [{"tag": "comfort", "magnitude": 0.85}]),
	])
	var dims := Vector2i(10, 10)
	var instances: Array[PlacedInstance] = [
		_make_instance(1, "barbell", [Vector2i(5, 5)], [Vector2i(5, 6)]) as PlacedInstance,
		_make_instance(2, "ghost_machine", [Vector2i(6, 5)], [Vector2i(6, 6)]) as PlacedInstance,
	]
	var reader := _make_reader(instances, dims, [Vector2i(5, 5), Vector2i(6, 5)])
	var result := _evaluate_with_config(reader, catalog, {"strict_mode": true})

	_check(not result.has(1) and not result.has(2), "strict error contains NO per-instance rows (not a normal result)")
	_check(result.size() == 1, "error variant has exactly the 'error' key (size == 1)")
	# Sanity: lenient mode on the same fixture returns the normal 2-row shape.
	var lenient := _evaluate_with_config(reader, catalog, {})
	_check(lenient.size() == 2 and lenient.has(1) and lenient.has(2), "lenient control returns the normal 2-row shape")


# === 静态保障 ===

func _test_static_no_bare_assert() -> void:
	print("\n[STATIC] zone_rules.gd contains NO bare assert() for invalid-equipment handling")

	var source: String = FileAccess.get_file_as_string("res://src/systems/zone_rules.gd")
	# Only CODE lines count — `##` doc comments may legitimately mention the
	# forbidden pattern ("a bare assert() is a no-op in release"). A code
	# line begins with a tab (function body) or is a statement outside a
	# comment block. Scan for an actual call token: assert( preceded by
	# whitespace, i.e. a real statement — not prose inside a comment.
	var code_lines: Array[String] = []
	for line in source.split("\n"):
		var trimmed := line.strip_edges()
		if trimmed.begins_with("#"):
			continue
		code_lines.append(line)
	var code := "\n".join(code_lines)
	_check(not code.contains("assert("), "code lines contain no assert( token (bare assert forbidden — injected channel instead)")


func _test_static_no_serialization_surface() -> void:
	print("\n[STATIC] ZoneRules contributes no serialization surface (TR-ZR-007)")

	var source: String = FileAccess.get_file_as_string("res://src/systems/zone_rules.gd")
	_check(not source.contains("func serialize"), "source declares no serialize() method")
	_check(not source.contains("func deserialize"), "source declares no deserialize() method")
	_check(not source.contains("class_name ZoneRules extends SimSystem"), "ZoneRules stays RefCounted (no SimSystem init machinery)")
