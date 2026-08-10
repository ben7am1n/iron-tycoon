# tests/unit/goals/goal_system_test.gd
# A4: deterministic goal/task progression, claiming, rewards, and persistence.
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"


class GridStub:
	extends RefCounted

	var instance_ids: Array = []

	func get_placed_instances() -> Array:
		var out: Array = []
		for instance_id in instance_ids:
			out.append({"instance_id": instance_id})
		return out


class SatisfactionStub:
	extends RefCounted

	var global_satisfaction: float = 0.0


class EconomyStub:
	extends RefCounted

	signal balance_changed(new_balance: int, delta: int)

	var balance: int = 500
	var credit_calls: Array[Dictionary] = []

	func credit(amount: int, reason: String) -> bool:
		if amount <= 0:
			return false
		balance += amount
		credit_calls.append({"amount": amount, "reason": reason})
		balance_changed.emit(balance, amount)
		return true

	func earn(amount: int) -> void:
		balance += amount
		balance_changed.emit(balance, amount)


class ExpansionStub:
	extends RefCounted

	signal region_unlocked(region_id: String, cost: int, new_dimensions: Vector2i)

	var unlocked: Array[String] = []

	func get_unlocked_count() -> int:
		return unlocked.size()

	func is_unlocked(region_id: String) -> bool:
		return unlocked.has(region_id)

	func grant_unlock(region_id: String) -> bool:
		if is_unlocked(region_id):
			return true
		if region_id != "group_class_room" or not unlocked.is_empty():
			return false
		unlocked.append(region_id)
		region_unlocked.emit(region_id, 0, Vector2i(18, 10))
		return true


var _pass := 0
var _fail := 0


func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	var result := run_all()
	quit(1 if int(result["fail"]) > 0 else 0)


func run_all() -> Dictionary:
	print("=".repeat(56))
	print("  UNIT TEST: A4 Goal / Task System")
	print("=".repeat(56))

	_test_progress_and_completion()
	_test_claim_rewards_once_and_unlock_link()
	_test_round_trip_and_optional_empty_payload()
	_test_production_catalog_loads()
	_test_same_inputs_are_deterministic()

	print("\n=== GOAL SYSTEM TEST: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(condition: bool, message: String) -> void:
	if condition:
		_pass += 1
		print("  PASS: " + message)
	else:
		_fail += 1
		print("  FAIL: " + message)


func _config() -> Dictionary:
	return {
		"schema_version": 1,
		"goals": [
			{
				"id": "place_first_strength",
				"title": "放置第 1 台力量设备",
				"type": "GUIDE",
				"metric": "EQUIPMENT_COUNT",
				"target": 1,
				"equipment_ids": ["bench_press"],
				"reward": {"money": 100},
			},
			{
				"id": "satisfaction_70",
				"title": "满意度达到 70%",
				"type": "MILESTONE",
				"metric": "SATISFACTION",
				"target": 0.7,
				"reward": {"money": 200, "unlock_region": "group_class_room"},
			},
			{
				"id": "earn_50",
				"title": "累计收入 $50",
				"type": "BUSINESS",
				"metric": "CUMULATIVE_INCOME",
				"target": 50,
				"reward": {"money": 75},
			},
			{
				"id": "unlock_region",
				"title": "解锁新区域",
				"type": "EXPANSION",
				"metric": "EXPANSION_COUNT",
				"target": 1,
				"reward": {"money": 125},
			},
		],
	}


func _make_rig() -> Dictionary:
	var grid := GridStub.new()
	var satisfaction := SatisfactionStub.new()
	var economy := EconomyStub.new()
	var expansion := ExpansionStub.new()
	var equipment_ids := {1: "treadmill", 2: "bench_press"}
	var resolver := func(instance_id: int) -> String:
		return str(equipment_ids.get(instance_id, ""))
	var goals: RefCounted = (load("res://src/systems/goal_system.gd") as Script).new()
	goals.call("init", _config(), grid, satisfaction, economy, expansion, resolver)
	goals.call("_post_init")
	return {
		"grid": grid,
		"satisfaction": satisfaction,
		"economy": economy,
		"expansion": expansion,
		"goals": goals,
	}


func _goal(goals: RefCounted, id: String) -> Dictionary:
	return goals.call("get_goal", id) as Dictionary


func _test_progress_and_completion() -> void:
	print("\n[progress] polling and signals update four deterministic metrics")
	var rig := _make_rig()
	var goals: RefCounted = rig["goals"]

	goals.call("on_tick", 0)
	_check(str(_goal(goals, "place_first_strength")["status"]) == "ACTIVE", "guide goal starts ACTIVE")
	_check(float(_goal(goals, "place_first_strength")["progress"]) == 0.0, "non-strength equipment count starts at zero")

	rig["grid"].instance_ids = [1]
	goals.call("on_tick", 1)
	_check(float(_goal(goals, "place_first_strength")["progress"]) == 0.0, "cardio placement does not advance strength-specific guide")

	rig["grid"].instance_ids = [1, 2]
	goals.call("on_tick", 2)
	_check(str(_goal(goals, "place_first_strength")["status"]) == "COMPLETED", "placing bench press completes guide goal")
	_check(float(_goal(goals, "place_first_strength")["progress"]) == 1.0, "equipment progress reaches target exactly")

	rig["satisfaction"].global_satisfaction = 0.69
	goals.call("on_tick", 3)
	_check(str(_goal(goals, "satisfaction_70")["status"]) == "ACTIVE", "satisfaction below 0.70 remains ACTIVE")
	rig["satisfaction"].global_satisfaction = 0.7
	goals.call("on_tick", 4)
	_check(str(_goal(goals, "satisfaction_70")["status"]) == "COMPLETED", "satisfaction boundary 0.70 completes milestone")

	rig["economy"].earn(49)
	_check(float(_goal(goals, "earn_50")["progress"]) == 49.0, "positive economy delta updates cumulative income immediately")
	_check(str(_goal(goals, "earn_50")["status"]) == "ACTIVE", "$49 / $50 remains ACTIVE")
	rig["economy"].earn(1)
	_check(str(_goal(goals, "earn_50")["status"]) == "COMPLETED", "$50 cumulative income completes business goal")

	rig["expansion"].grant_unlock("group_class_room")
	_check(str(_goal(goals, "unlock_region")["status"]) == "COMPLETED", "region_unlocked signal completes expansion goal immediately")


func _test_claim_rewards_once_and_unlock_link() -> void:
	print("\n[rewards] claiming pays through Economy and unlocks through ExpansionSystem once")
	var rig := _make_rig()
	var goals: RefCounted = rig["goals"]
	rig["satisfaction"].global_satisfaction = 0.7
	goals.call("on_tick", 0)
	var before := int(rig["economy"].balance)

	_check(bool(goals.call("claim_goal", "satisfaction_70")), "completed milestone can be claimed")
	_check(int(rig["economy"].balance) == before + 200, "money reward credits exact $200 through Economy")
	_check(rig["economy"].credit_calls.size() == 1, "Economy.credit called exactly once")
	_check(bool(rig["expansion"].is_unlocked("group_class_room")), "unlock reward grants configured region through ExpansionSystem")
	_check(str(_goal(goals, "satisfaction_70")["status"]) == "CLAIMED", "successful reward changes status to CLAIMED")
	_check(float(_goal(goals, "earn_50")["progress"]) == 0.0, "goal reward money is excluded from cumulative-income progress")
	_check(not bool(goals.call("claim_goal", "satisfaction_70")), "claimed goal rejects duplicate claim")
	_check(int(rig["economy"].balance) == before + 200 and rig["economy"].credit_calls.size() == 1, "duplicate claim cannot duplicate money")
	_check(str(_goal(goals, "unlock_region")["status"]) == "COMPLETED", "unlock reward also advances the linked expansion goal")


func _test_round_trip_and_optional_empty_payload() -> void:
	print("\n[save] JSON round-trip preserves status/progress/income; empty payload resets")
	var source := _make_rig()
	source["grid"].instance_ids = [2]
	source["economy"].earn(50)
	source["goals"].call("on_tick", 0)
	source["goals"].call("claim_goal", "place_first_strength")
	var payload: Dictionary = source["goals"].call("serialize")
	var parsed: Variant = JSON.parse_string(JSON.stringify(payload))
	_check(parsed is Dictionary, "goal payload survives JSON encoding")
	parsed = (load("res://src/systems/save_load.gd") as Script).call("_normalize_types", parsed)

	var restored := _make_rig()
	var validation: RefCounted = restored["goals"].call("deserialize", parsed, true)
	_check(bool(validation.get("ok")), "validate-only accepts normalized JSON payload")
	_check(str(_goal(restored["goals"], "place_first_strength")["status"]) == "ACTIVE", "validate-only does not mutate live goal state")
	var committed: RefCounted = restored["goals"].call("deserialize", parsed, false)
	_check(bool(committed.get("ok")), "goal payload commit succeeds")
	_check(str(_goal(restored["goals"], "place_first_strength")["status"]) == "CLAIMED", "CLAIMED state survives round-trip")
	_check(str(_goal(restored["goals"], "earn_50")["status"]) == "COMPLETED", "COMPLETED state survives round-trip")
	_check(float(restored["goals"].call("get_cumulative_income")) == 50.0, "cumulative income survives round-trip")

	var reset_result: RefCounted = restored["goals"].call("deserialize", {}, false)
	_check(bool(reset_result.get("ok")), "empty optional payload is accepted for pre-A4 saves")
	_check(str(_goal(restored["goals"], "place_first_strength")["status"]) == "ACTIVE", "empty optional payload resets definitions to ACTIVE")
	_check(float(restored["goals"].call("get_cumulative_income")) == 0.0, "empty optional payload resets cumulative income")

	var corrupt := payload.duplicate(true)
	(corrupt["goals"] as Array)[0]["id"] = "removed_goal"
	var rejected: RefCounted = restored["goals"].call("deserialize", corrupt, true)
	_check(not bool(rejected.get("ok")), "unknown saved goal id is rejected as corrupt data")
	_check(str(_goal(restored["goals"], "place_first_strength")["status"]) == "ACTIVE", "rejected validation leaves live state untouched")


func _test_production_catalog_loads() -> void:
	print("\n[data] production goals.json is valid and ordered")
	var script := load("res://src/systems/goal_system.gd") as Script
	var config: Dictionary = script.call("config_from_file", "res://data/goals.json")
	var rig := _make_rig()
	var production_goals: RefCounted = script.new()
	production_goals.call("init", config, rig["grid"], rig["satisfaction"], rig["economy"], rig["expansion"])
	var definitions: Array = production_goals.call("get_goals")
	_check(definitions.size() == 4, "production catalog loads four A4 goals")
	_check(str(definitions[0]["id"]) == "place_first_strength" and str(definitions[3]["id"]) == "unlock_first_region", "production goal order preserves short-to-medium arc")


func _run_deterministic_sequence() -> Dictionary:
	var rig := _make_rig()
	rig["grid"].instance_ids = [2]
	rig["satisfaction"].global_satisfaction = 0.7
	rig["economy"].earn(50)
	rig["goals"].call("on_tick", 42)
	rig["goals"].call("claim_goal", "satisfaction_70")
	return {
		"goals": rig["goals"].call("serialize"),
		"balance": rig["economy"].balance,
		"unlocked": rig["expansion"].unlocked.duplicate(),
	}


func _test_same_inputs_are_deterministic() -> void:
	print("\n[determinism] same state transitions produce byte-equivalent output")
	var run_a := _run_deterministic_sequence()
	var run_b := _run_deterministic_sequence()
	_check(run_a == run_b, "same input sequence yields identical goal, balance, and unlock state")
