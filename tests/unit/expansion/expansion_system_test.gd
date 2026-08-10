# tests/unit/expansion/expansion_system_test.gd
# A3: Region Expansion System
#
# Covers the player-visible unlock gates and transaction, GridSystem growth
# invariants, grid_resized/region_unlocked signals, expansion-state
# serialization, and deterministic replay with the same master seed/input.
# Run standalone: godot --headless --script tests/unit/expansion/expansion_system_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"
const R0 := 0
const BASE_DIMENSIONS := Vector2i(4, 3)
const MASTER_SEED := 0xA3E001


class SatisfactionStub:
	extends RefCounted

	var global_satisfaction: float = 0.0


class EconomyStub:
	extends RefCounted

	var balance: int
	var spend_calls: int = 0
	var credited: int = 0

	func _init(starting_balance: int) -> void:
		balance = starting_balance

	func can_afford(amount: int) -> bool:
		return amount > 0 and balance >= amount

	func spend(amount: int) -> bool:
		spend_calls += 1
		if amount <= 0 or amount > balance:
			return false
		balance -= amount
		return true

	func credit(amount: int, _reason: String) -> bool:
		if amount <= 0:
			return false
		balance += amount
		credited += amount
		return true


var _pass := 0
var _fail := 0
var _nodes_to_free: Array[Node] = []

var _resize_count := 0
var _last_new_dimensions := Vector2i.ZERO
var _last_old_dimensions := Vector2i.ZERO
var _unlock_count := 0
var _last_region_id := ""
var _last_unlock_cost := 0
var _last_unlock_dimensions := Vector2i.ZERO


func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	var result := run_all()
	quit(1 if int(result["fail"]) > 0 else 0)


func run_all() -> Dictionary:
	print("=".repeat(56))
	print("  UNIT TEST: A3 Region Expansion System")
	print("=".repeat(56))

	_test_satisfaction_gate()
	_test_funds_gate_and_paid_unlock()
	_test_all_regions_unlocked_status()
	_test_grid_resize_preserves_data_and_opens_new_cells()
	_test_grid_resized_signal()
	_test_reward_grant_unlock()
	_test_serialize_deserialize_round_trip()
	_test_same_seed_same_input_is_deterministic()

	_free_nodes()
	print("\n=== EXPANSION SYSTEM TEST: %d passed, %d failed ===\n" % [_pass, _fail])
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
		"satisfaction_threshold": 0.6,
		"regions": [
			{
				"id": "group_class_room",
				"display_name": "团课室",
				"cost": 600,
				"add_width": 2,
				"add_height": 0,
				"satisfaction_threshold": 0.6,
			},
			{
				"id": "protein_bar",
				"display_name": "蛋白吧",
				"cost": 900,
				"add_width": 0,
				"add_height": 1,
				"satisfaction_threshold": 0.7,
			},
		],
	}


func _make_open_grid(dimensions: Vector2i = BASE_DIMENSIONS) -> RefCounted:
	var grid: RefCounted = (load("res://src/systems/grid_system.gd") as Script).new()
	grid.call("init", dimensions.x, dimensions.y)
	for y in dimensions.y:
		for x in dimensions.x:
			grid.call("set_buildable", Vector2i(x, y), true)
	grid.call("freeze_buildable")
	return grid


func _make_rig(starting_balance: int, satisfaction_value: float) -> Dictionary:
	var grid := _make_open_grid()
	var satisfaction := SatisfactionStub.new()
	satisfaction.global_satisfaction = satisfaction_value
	var economy := EconomyStub.new(starting_balance)
	var expansion: RefCounted = (load("res://src/systems/expansion_system.gd") as Script).new()
	expansion.call("init", grid, _config(), satisfaction)
	return {
		"grid": grid,
		"satisfaction": satisfaction,
		"economy": economy,
		"expansion": expansion,
	}


func _make_orchestrator() -> Node:
	var orchestrator: Node = (load("res://src/systems/simulation_orchestrator.gd") as Script).new()
	root.add_child(orchestrator)
	_nodes_to_free.append(orchestrator)
	return orchestrator


func _free_nodes() -> void:
	for node in _nodes_to_free:
		if is_instance_valid(node):
			node.queue_free()
	_nodes_to_free.clear()


func _connect_expansion_signals(rig: Dictionary) -> void:
	_resize_count = 0
	_last_new_dimensions = Vector2i.ZERO
	_last_old_dimensions = Vector2i.ZERO
	_unlock_count = 0
	_last_region_id = ""
	_last_unlock_cost = 0
	_last_unlock_dimensions = Vector2i.ZERO
	rig["grid"].connect("grid_resized", Callable(self, "_on_grid_resized"))
	rig["expansion"].connect("region_unlocked", Callable(self, "_on_region_unlocked"))


func _on_grid_resized(new_dimensions: Vector2i, old_dimensions: Vector2i) -> void:
	_resize_count += 1
	_last_new_dimensions = new_dimensions
	_last_old_dimensions = old_dimensions


func _on_region_unlocked(region_id: String, cost: int, new_dimensions: Vector2i) -> void:
	_unlock_count += 1
	_last_region_id = region_id
	_last_unlock_cost = cost
	_last_unlock_dimensions = new_dimensions


func _test_satisfaction_gate() -> void:
	print("\n[satisfaction] below threshold blocks; boundary value unlocks")
	var rig := _make_rig(600, 0.59)
	var expansion: RefCounted = rig["expansion"]
	var economy: EconomyStub = rig["economy"]
	var status: Dictionary = expansion.call("unlock_status", economy)

	_check(str(status["status"]) == "SATISFACTION_TOO_LOW", "satisfaction 0.59 < 0.60 returns STATUS_SATISFACTION_TOO_LOW")
	_check(not bool(status["available"]), "below-threshold verdict is unavailable")
	_check(not bool(expansion.call("try_unlock", economy)), "below-threshold try_unlock is rejected")
	_check(economy.balance == 600 and economy.spend_calls == 0, "rejected satisfaction gate neither spends nor changes balance")

	rig["satisfaction"].global_satisfaction = 0.6
	status = expansion.call("unlock_status", economy)
	_check(str(status["status"]) == "OK" and bool(status["available"]), "satisfaction exactly at threshold returns STATUS_OK")


func _test_funds_gate_and_paid_unlock() -> void:
	print("\n[funds] insufficient funds block; sufficient funds deduct exactly once")
	var rig := _make_rig(599, 0.8)
	var expansion: RefCounted = rig["expansion"]
	var economy: EconomyStub = rig["economy"]
	var status: Dictionary = expansion.call("unlock_status", economy)

	_check(str(status["status"]) == "INSUFFICIENT_FUNDS", "$599 < $600 returns STATUS_INSUFFICIENT_FUNDS")
	_check(not bool(expansion.call("try_unlock", economy)), "insufficient-funds try_unlock is rejected")
	_check(economy.balance == 599 and economy.spend_calls == 0, "funds rejection does not call spend or mutate balance")

	economy.balance = 600
	status = expansion.call("unlock_status", economy)
	_check(str(status["status"]) == "OK" and bool(status["available"]), "$600 is sufficient for the $600 region")
	_check(bool(expansion.call("try_unlock", economy)), "affordable region unlock succeeds")
	_check(economy.balance == 0 and economy.spend_calls == 1, "successful unlock deducts exactly $600 once")
	_check(bool(expansion.call("is_unlocked", "group_class_room")), "paid region is recorded as unlocked")


func _test_all_regions_unlocked_status() -> void:
	print("\n[terminal] all configured regions produce STATUS_ALL_UNLOCKED")
	var rig := _make_rig(1500, 0.8)
	var expansion: RefCounted = rig["expansion"]
	var economy: EconomyStub = rig["economy"]

	_check(bool(expansion.call("try_unlock", economy)), "first configured region unlocks")
	_check(bool(expansion.call("try_unlock", economy)), "second configured region unlocks")
	var status: Dictionary = expansion.call("unlock_status", economy)
	_check(str(status["status"]) == "ALL_REGIONS_UNLOCKED", "after final region unlock_status returns STATUS_ALL_UNLOCKED")
	_check(not bool(status["available"]) and str(status["region_id"]).is_empty(), "terminal verdict exposes no purchasable region")
	_check(not bool(expansion.call("try_unlock", economy)) and economy.balance == 0, "extra unlock attempt is a no-op")


func _test_grid_resize_preserves_data_and_opens_new_cells() -> void:
	print("\n[grid] resize preserves placements and makes new cells placeable")
	var rig := _make_rig(600, 0.8)
	var grid: RefCounted = rig["grid"]
	var footprint: Array[Vector2i] = [Vector2i(2, 1)]
	var access: Array[Vector2i] = [Vector2i(3, 1)]
	grid.call("commit", 7, footprint, access, R0)

	_check(bool(rig["expansion"].call("try_unlock", rig["economy"])), "unlock grows the live GridSystem")
	_check(grid.call("get_dimensions") == Vector2i(6, 3), "grid dimensions grow from 4x3 to 6x3")
	_check(int(grid.call("get_occupant_id", Vector2i(2, 1))) == 7, "existing footprint occupant survives row-stride relayout")
	_check((grid.call("get_access_ids", Vector2i(3, 1)) as Array) == [7], "existing access-cell data survives relayout")
	_check(bool(grid.call("get_buildable", Vector2i(4, 1))) and int(grid.call("get_occupant_id", Vector2i(4, 1))) == -1, "new expansion cell is buildable and empty")

	var local_footprint: Array[Vector2i] = [Vector2i.ZERO]
	var local_access: Array[Vector2i] = [Vector2i(1, 0)]
	var placement: Variant = grid.call("can_place", local_footprint, local_access, Vector2i(4, 1), R0)
	_check(bool(placement.get("valid")), "equipment footprint + access can be placed wholly inside new columns")
	var new_footprint: Array[Vector2i] = [Vector2i(4, 1)]
	var new_access: Array[Vector2i] = [Vector2i(5, 1)]
	grid.call("commit", 8, new_footprint, new_access, R0)
	_check(int(grid.call("get_occupant_id", Vector2i(4, 1))) == 8, "commit succeeds on newly unlocked cell")


func _test_grid_resized_signal() -> void:
	print("\n[signals] successful unlock emits resize and region payloads once")
	var rig := _make_rig(600, 0.8)
	_connect_expansion_signals(rig)

	_check(bool(rig["expansion"].call("try_unlock", rig["economy"])), "signal fixture unlock succeeds")
	_check(_resize_count == 1, "grid_resized emitted exactly once")
	_check(_last_old_dimensions == Vector2i(4, 3) and _last_new_dimensions == Vector2i(6, 3), "grid_resized payload is old=4x3, new=6x3")
	_check(_unlock_count == 1, "region_unlocked emitted exactly once")
	_check(_last_region_id == "group_class_room" and _last_unlock_cost == 600 and _last_unlock_dimensions == Vector2i(6, 3), "region_unlocked payload carries id, cost, and resized dimensions")


func _test_reward_grant_unlock() -> void:
	print("\n[reward] GoalSystem grant bypasses purchase gates but preserves prefix order")
	var rig := _make_rig(0, 0.0)
	_connect_expansion_signals(rig)
	_check(not bool(rig["expansion"].call("grant_unlock", "protein_bar")), "out-of-order reward region is rejected")
	_check(bool(rig["expansion"].call("grant_unlock", "group_class_room")), "next configured region can be reward-granted")
	_check(rig["economy"].balance == 0 and rig["economy"].spend_calls == 0, "reward unlock neither requires nor spends money")
	_check(_unlock_count == 1 and _last_unlock_cost == 0, "reward emits region_unlocked once with zero cost")
	_check(bool(rig["expansion"].call("grant_unlock", "group_class_room")), "already granted region is idempotently successful")
	_check(_unlock_count == 1, "idempotent reward grant emits no duplicate unlock signal")


func _test_serialize_deserialize_round_trip() -> void:
	print("\n[round-trip] serialize -> deserialize preserves unlocked prefix")
	var source := _make_rig(600, 0.8)
	_check(bool(source["expansion"].call("try_unlock", source["economy"])), "round-trip source unlocks first region")
	var payload: Dictionary = source["expansion"].call("serialize")

	var restored_grid := _make_open_grid()
	var restored_satisfaction := SatisfactionStub.new()
	restored_satisfaction.global_satisfaction = 0.8
	var restored: RefCounted = (load("res://src/systems/expansion_system.gd") as Script).new()
	restored.call("init", restored_grid, _config(), restored_satisfaction)
	var result: Variant = restored.call("deserialize", payload, false)

	_check(bool(result.get("ok")), "serialized expansion payload deserializes successfully")
	_check((restored.call("get_unlocked_ids") as Array) == ["group_class_room"], "restored unlocked IDs equal source prefix")
	_check(int(restored.call("get_unlocked_count")) == 1 and bool(restored.call("is_unlocked", "group_class_room")), "restored read surface reports one unlocked region")
	_check(restored.call("serialize") == payload, "serialize -> deserialize -> serialize is exact")
	_check(restored.call("dimensions_for_data", payload) == Vector2i(6, 3), "round-trip payload resolves to the saved expansion dimensions")


func _run_seeded_scenario(master_seed: int) -> Dictionary:
	var orchestrator := _make_orchestrator()
	var seeded_rng: RefCounted = (load("res://src/systems/seeded_rng.gd") as Script).new()
	seeded_rng.call("init", master_seed)
	var economy: RefCounted = (load("res://src/systems/economy.gd") as Script).new()
	economy.call("init", orchestrator, seeded_rng, {"starting_capital": 1500})

	var grid := _make_open_grid()
	var satisfaction := SatisfactionStub.new()
	satisfaction.global_satisfaction = 0.8
	var expansion: RefCounted = (load("res://src/systems/expansion_system.gd") as Script).new()
	expansion.call("init", grid, _config(), satisfaction)

	var statuses: Array[String] = []
	statuses.append(str((expansion.call("unlock_status", economy) as Dictionary)["status"]))
	var first: bool = bool(expansion.call("try_unlock", economy))
	statuses.append(str((expansion.call("unlock_status", economy) as Dictionary)["status"]))
	var second: bool = bool(expansion.call("try_unlock", economy))
	statuses.append(str((expansion.call("unlock_status", economy) as Dictionary)["status"]))

	return {
		"statuses": statuses,
		"unlock_results": [first, second],
		"balance": int(economy.get("balance")),
		"dimensions": grid.call("get_dimensions"),
		"expansion": expansion.call("serialize"),
		"grid": grid.call("serialize"),
	}


func _test_same_seed_same_input_is_deterministic() -> void:
	print("\n[determinism] same master seed + same inputs produce identical results")
	var run_a := _run_seeded_scenario(MASTER_SEED)
	var run_b := _run_seeded_scenario(MASTER_SEED)

	_check(run_a == run_b, "same seed/input yields byte-equivalent status, balance, grid, and expansion state")
	_check(run_a["statuses"] == ["OK", "OK", "ALL_REGIONS_UNLOCKED"], "deterministic status sequence is OK -> OK -> ALL_REGIONS_UNLOCKED")
	_check(run_a["unlock_results"] == [true, true], "both deterministic unlock transactions succeed")
	_check(int(run_a["balance"]) == 0 and run_a["dimensions"] == Vector2i(6, 4), "deterministic terminal state is balance $0 and grid 6x4")
