# A1: Member preference profiles — type distribution, category-weighted target
# selection, deterministic sequences, and Core Rule 7 save/load fidelity.
#
# Run standalone: godot --headless --script tests/unit/member_sim/preference_profile_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"
const ENTRANCE := Vector2i(0, 0)
const EXIT := Vector2i(7, 5)

var _pass := 0
var _fail := 0


func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	var result := run_all()
	quit(1 if int(result["fail"]) > 0 else 0)


func run_all() -> Dictionary:
	print("=".repeat(48))
	print("  UNIT TEST: MemberSim — A1 Preference Profiles")
	print("=".repeat(48))

	_test_roll_distribution_and_resolved_shape()
	_test_all_type_weights_take_effect()
	_test_strength_candidate_weight_is_higher()
	_test_balanced_preserves_old_weighting()
	_test_same_seed_same_profile_sequence()
	_test_serialize_deserialize_preserves_resolved_profile()

	print("\n=== A1 PREFERENCE PROFILE TEST: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(condition: bool, message: String) -> void:
	if condition:
		_pass += 1
		print("  PASS: " + message)
	else:
		_fail += 1
		print("  FAIL: " + message)


func _make_orchestrator() -> Node:
	var orch: Node = load("res://src/systems/simulation_orchestrator.gd").new()
	root.add_child(orch)
	orch.call("_ready")
	return orch


func _make_grid() -> RefCounted:
	var grid: RefCounted = load("res://src/systems/grid_system.gd").new()
	grid.call("init", 8, 6)
	for y in 6:
		for x in 8:
			grid.call("set_buildable", Vector2i(x, y), true)
	grid.call("freeze_buildable")
	return grid


func _make_catalog() -> RefCounted:
	var catalog: RefCounted = load("res://src/systems/equipment_catalog.gd").new()
	var equipment_def := load("res://src/systems/equipment_def.gd") as Script
	var footprint: Array[Vector2i] = [Vector2i(0, 0)]
	var access: Array[Vector2i] = [Vector2i(1, 0)]
	var effects: Array[Dictionary] = []
	for entry in [
		["bench_press", "Bench Press", "strength"],
		["treadmill", "Treadmill", "cardio"],
		["yoga_mat", "Yoga Mat", "flex"],
	]:
		var def = equipment_def.new(
			entry[0], entry[1], [entry[2]], footprint, access, 100, "", effects,
			100, 0, 100, 100
		)
		catalog.call("_add_definition", def)
	catalog.call("_freeze")
	return catalog


func _make_rig(seed: int, with_equipment: bool = false) -> Dictionary:
	var orch := _make_orchestrator()
	var seeded_rng: RefCounted = load("res://src/systems/seeded_rng.gd").new()
	seeded_rng.call("init", seed)
	var grid := _make_grid()
	var navigation: RefCounted = load("res://src/systems/navigation.gd").new()
	navigation.call("init", grid)
	navigation.call("_post_init")
	var catalog := _make_catalog()
	var equipment_ids := {
		1: "bench_press",
		2: "treadmill",
		3: "yoga_mat",
	}
	if with_equipment:
		# All access cells have Chebyshev distance 3 from ENTRANCE, isolating
		# preference category as the only weight difference.
		for entry in [
			[1, Vector2i(2, 1), Vector2i(3, 1)],
			[2, Vector2i(2, 2), Vector2i(3, 2)],
			[3, Vector2i(2, 3), Vector2i(3, 3)],
		]:
			var fp: Array[Vector2i] = [entry[1]]
			var ac: Array[Vector2i] = [entry[2]]
			grid.call("commit", entry[0], fp, ac, 0)
	var resolver := func(instance_id: int) -> String:
		return str(equipment_ids.get(instance_id, ""))
	var member_sim: RefCounted = load("res://src/systems/member_sim.gd").new()
	member_sim.call(
		"init", orch, seeded_rng, grid, navigation, catalog, ENTRANCE, EXIT,
		{"base_arrival_rate_per_min": 0.0, "max_concurrent_members": 5000},
		null, resolver
	)
	orch.set("member_sim", member_sim)
	return {
		"member_sim": member_sim,
		"seeded_rng": seeded_rng,
	}


func _profile(preference_type: String) -> Dictionary:
	var weights := {
		"STRENGTH": {"strength": 1.5, "cardio": 0.8, "flex": 0.8},
		"CARDIO": {"strength": 0.8, "cardio": 1.5, "flex": 0.8},
		"FLEX": {"strength": 0.8, "cardio": 0.8, "flex": 1.5},
		"BALANCED": {"strength": 1.0, "cardio": 1.0, "flex": 1.0},
	}
	return {
		"type": preference_type,
		"category_weights": (weights[preference_type] as Dictionary).duplicate(true),
		"preference_noise": 1.0,
	}


func _member(preference_type: String) -> Dictionary:
	return {
		"member_id": 100,
		"state": "SELECTING_TARGET",
		"cell": ENTRANCE,
		"exercises_done": 0,
		"exercises_per_visit": 3,
		"preference_profile": _profile(preference_type),
		"target_equipment_instance_id": -1,
		"cached_path": [],
		"recently_used_ids": [],
	}


func _candidates(rig: Dictionary, preference_type: String) -> Array:
	return rig["member_sim"].call("_build_weighted_candidates", _member(preference_type)) as Array


func _test_roll_distribution_and_resolved_shape() -> void:
	print("\n[A1 distribution] 4,000 rolls include all four approximately uniform types and resolved weights")
	var rig := _make_rig(0xA10001)
	var counts := {"STRENGTH": 0, "CARDIO": 0, "FLEX": 0, "BALANCED": 0}
	var shapes_valid := true
	for _i in 4000:
		var profile: Dictionary = rig["member_sim"].call("_roll_preference_profile")
		var preference_type := str(profile.get("type", ""))
		if not counts.has(preference_type):
			shapes_valid = false
			continue
		counts[preference_type] += 1
		var noise := float(profile.get("preference_noise", 0.0))
		var weights: Variant = profile.get("category_weights", null)
		if noise < 0.85 or noise > 1.15 or not (weights is Dictionary) or (weights as Dictionary).size() != 3:
			shapes_valid = false
	_check(shapes_valid, "every roll stores {type, category_weights, preference_noise} with valid bounds")
	var approximately_uniform := true
	for preference_type in counts:
		if int(counts[preference_type]) < 800 or int(counts[preference_type]) > 1200:
			approximately_uniform = false
	_check(approximately_uniform, "all four equal-probability types land in [20%%,30%%] (counts=%s)" % str(counts))


func _test_all_type_weights_take_effect() -> void:
	print("\n[A1 weights] each specialist favors its zone; BALANCED stays neutral")
	var rig := _make_rig(0xA10002, true)
	var expected := {
		"STRENGTH": [1.5, 0.8, 0.8],
		"CARDIO": [0.8, 1.5, 0.8],
		"FLEX": [0.8, 0.8, 1.5],
		"BALANCED": [1.0, 1.0, 1.0],
	}
	for preference_type in expected:
		var entries := _candidates(rig, preference_type)
		var actual: Array = []
		for entry in entries:
			actual.append(float(entry["preference_weight"]))
		_check(actual == expected[preference_type], "%s category multipliers resolve from EquipmentDef zones: %s" % [preference_type, str(actual)])


func _test_strength_candidate_weight_is_higher() -> void:
	print("\n[A1 integration] STRENGTH member weights strength above equidistant cardio/flex")
	var entries := _candidates(_make_rig(0xA10003, true), "STRENGTH")
	var strength_weight := float(entries[0]["weight"])
	var cardio_weight := float(entries[1]["weight"])
	var flex_weight := float(entries[2]["weight"])
	_check(strength_weight > cardio_weight and strength_weight > flex_weight,
		"strength weight %.6f > cardio %.6f and flex %.6f" % [strength_weight, cardio_weight, flex_weight])
	_check(absf(strength_weight / cardio_weight - 1.875) < 1e-9,
		"preference multiplier composes multiplicatively with the existing formula (ratio=%.3f)" % (strength_weight / cardio_weight))


func _test_balanced_preserves_old_weighting() -> void:
	print("\n[A1 compatibility] BALANCED produces the pre-A1 neutral category weighting")
	var entries := _candidates(_make_rig(0xA10004, true), "BALANCED")
	var equal := entries.size() == 3
	for entry in entries:
		equal = equal and absf(float(entry["weight"]) - float(entries[0]["weight"])) < 1e-12
	_check(equal, "equidistant BALANCED candidates retain equal weights")


func _profile_sequence(rig: Dictionary, count: int) -> Array[String]:
	var sequence: Array[String] = []
	for _i in count:
		var profile: Dictionary = rig["member_sim"].call("_roll_preference_profile")
		sequence.append("%s|%.12f|%s" % [profile["type"], profile["preference_noise"], str(profile["category_weights"])])
	return sequence


func _test_same_seed_same_profile_sequence() -> void:
	print("\n[A1 determinism] identical master seed produces identical profile sequence")
	var a := _profile_sequence(_make_rig(0xA10005), 128)
	var b := _profile_sequence(_make_rig(0xA10005), 128)
	_check(a == b, "same seed reproduces all types, resolved weights, and noise values")


func _test_serialize_deserialize_preserves_resolved_profile() -> void:
	print("\n[A1 Core Rule 7] save/load restores the resolved profile without re-roll")
	var source := _make_rig(0xA10006)
	source["member_sim"].call("_spawn_member")
	var source_member: Dictionary = (source["member_sim"].get("members") as Array)[0]
	var expected: Dictionary = (source_member["preference_profile"] as Dictionary).duplicate(true)
	var payload: Dictionary = source["member_sim"].call("serialize")

	var restored := _make_rig(0xDEADBEEF)
	var result: RefCounted = restored["member_sim"].call("deserialize", payload, false, [])
	var restored_member: Dictionary = (restored["member_sim"].get("members") as Array)[0]
	_check(bool(result.get("ok")), "deserialize accepts the A1 resolved profile")
	_check(restored_member["preference_profile"] == expected,
		"type, category weights, and noise are restored verbatim (%s)" % str(expected))

	# Matching next draw proves deserialize restored RNG state and did not spend
	# any draw re-rolling the profile during load.
	var next_source: Dictionary = source["member_sim"].call("_roll_preference_profile")
	var next_restored: Dictionary = restored["member_sim"].call("_roll_preference_profile")
	_check(next_source == next_restored, "load performs no profile re-roll (next RNG result still matches)")
