# tests/unit/equipment_upgrade/equipment_upgrade_system_test.gd
# A2: Equipment Upgrade System
#
# Covers the blocking A2 acceptance criteria:
#   - exponential upgrade-cost formula and max-level boundary
#   - attractiveness and revenue multipliers
#   - atomic spend + level mutation
#   - GridSystem serialize/deserialize keeps upgraded levels and accepts
#     legacy records without a level as level 1
#   - MemberSim target-selection weight applies the attraction multiplier
#   - Economy applies the completed visit's snapshotted equipment level
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"
const R0 := 0


class CompletedVisitMemberStub:
	extends RefCounted

	var completed_level: int = 1

	func get_completed_visit_equipment_level(_member_id: int) -> int:
		return completed_level


var _pass := 0
var _fail := 0
var _nodes_to_free: Array[Node] = []


func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	var result := run_all()
	quit(1 if int(result["fail"]) > 0 else 0)


func run_all() -> Dictionary:
	print("=".repeat(56))
	print("  UNIT TEST: A2 Equipment Upgrade System")
	print("=".repeat(56))

	_test_cost_formula_and_max_level()
	_test_effect_multipliers()
	_test_upgrade_spends_atomically()
	_test_grid_roundtrip_preserves_level()
	_test_legacy_grid_record_defaults_to_level_one()
	_test_target_weight_applies_attraction_multiplier()
	_test_economy_applies_upgraded_revenue()

	_free_nodes()
	print("\n=== EQUIPMENT UPGRADE TEST: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(condition: bool, message: String) -> void:
	if condition:
		_pass += 1
		print("  PASS: " + message)
	else:
		_fail += 1
		print("  FAIL: " + message)


func _make_grid() -> RefCounted:
	var grid: RefCounted = (load("res://src/systems/grid_system.gd") as Script).new()
	grid.call("init", 5, 5)
	for y in 5:
		for x in 5:
			grid.call("set_buildable", Vector2i(x, y), true)
	grid.call("freeze_buildable")
	return grid


func _open_snapshot() -> PackedByteArray:
	var snapshot := PackedByteArray()
	snapshot.resize(25)
	snapshot.fill(1)
	return snapshot


func _commit_one(grid: RefCounted, instance_id: int = 7) -> void:
	var footprint: Array[Vector2i] = [Vector2i(1, 1)]
	var access: Array[Vector2i] = [Vector2i(2, 1)]
	grid.call("commit", instance_id, footprint, access, R0)


func _make_orchestrator() -> Node:
	var orch: Node = (load("res://src/systems/simulation_orchestrator.gd") as Script).new()
	root.add_child(orch)
	orch.call("_ready")
	_nodes_to_free.append(orch)
	return orch


func _make_economy() -> Dictionary:
	var orch := _make_orchestrator()
	var seeded_rng: RefCounted = (load("res://src/systems/seeded_rng.gd") as Script).new()
	seeded_rng.call("init", 0xA2E001)
	var economy: RefCounted = (load("res://src/systems/economy.gd") as Script).new()
	economy.call("init", orch, seeded_rng)
	orch.set("economy", economy)
	return {"orchestrator": orch, "seeded_rng": seeded_rng, "economy": economy}


func _make_upgrade(grid: RefCounted) -> RefCounted:
	var upgrade: RefCounted = (load("res://src/systems/equipment_upgrade_system.gd") as Script).new()
	upgrade.call("init", grid, {
		"max_level": 5,
		"base_cost_ratio": 0.5,
		"cost_growth": 2.0,
		"attraction_per_level": 0.15,
		"revenue_per_level": 0.10,
	})
	return upgrade


func _test_cost_formula_and_max_level() -> void:
	print("\n[cost] base × 0.5 × 2^(level-1)")
	var grid := _make_grid()
	_commit_one(grid)
	var upgrade := _make_upgrade(grid)
	_check(int(upgrade.call("upgrade_cost_for_level", 200, 1)) == 100, "L1→L2 costs 50% of purchase price")
	_check(int(upgrade.call("upgrade_cost_for_level", 200, 2)) == 200, "L2→L3 doubles to 200")
	_check(int(upgrade.call("upgrade_cost_for_level", 200, 3)) == 400, "L3→L4 doubles to 400")
	_check(int(upgrade.call("upgrade_cost_for_level", 200, 4)) == 800, "L4→L5 doubles to 800")
	_check(int(upgrade.call("upgrade_cost_for_level", 200, 5)) == 0, "max level has no further upgrade cost")


func _test_effect_multipliers() -> void:
	print("\n[effects] attraction +15%/level, revenue +10%/level")
	var grid := _make_grid()
	_commit_one(grid)
	var upgrade := _make_upgrade(grid)
	_check(is_equal_approx(float(upgrade.call("attraction_multiplier_for_level", 1)), 1.0), "L1 attraction is neutral")
	_check(is_equal_approx(float(upgrade.call("attraction_multiplier_for_level", 3)), 1.30), "L3 attraction multiplier is 1.30")
	_check(is_equal_approx(float(upgrade.call("revenue_multiplier_for_level", 4)), 1.30), "L4 revenue multiplier is 1.30")
	_check(int(upgrade.call("revenue_for_visit", 12, 2)) == 13, "$12 visit at L2 rounds to $13")
	_check(int(upgrade.call("revenue_for_visit", 12, 5)) == 17, "$12 visit at L5 rounds to $17")


func _test_upgrade_spends_atomically() -> void:
	print("\n[transaction] spend succeeds once and raises only that instance")
	var grid := _make_grid()
	_commit_one(grid)
	var upgrade := _make_upgrade(grid)
	var economy_rig := _make_economy()
	var economy: RefCounted = economy_rig["economy"]
	var ok: bool = bool(upgrade.call("try_upgrade", 7, 200, economy))
	_check(ok, "affordable L1→L2 upgrade succeeds")
	_check(int(grid.call("get_equipment_level", 7)) == 2, "instance level becomes 2")
	_check(int(economy.get("balance")) == 400, "exact $100 upgrade cost deducted")
	var before_level := int(grid.call("get_equipment_level", 7))
	var before_balance := int(economy.get("balance"))
	var failed: bool = bool(upgrade.call("try_upgrade", 999, 200, economy))
	_check(not failed, "unknown instance upgrade is rejected")
	_check(int(grid.call("get_equipment_level", 7)) == before_level, "rejected transaction does not mutate another level")
	_check(int(economy.get("balance")) == before_balance, "rejected transaction does not spend money")


func _test_grid_roundtrip_preserves_level() -> void:
	print("\n[save] upgraded level survives GridSystem round-trip")
	var source := _make_grid()
	_commit_one(source)
	_check(bool(source.call("set_equipment_level", 7, 4)), "fixture level set to 4")
	var blob: Dictionary = source.call("serialize")
	_check(int(blob["records"][0].get("level", 0)) == 4, "serialized record contains level 4")

	var restored := _make_grid()
	var validate_result: RefCounted = restored.call("deserialize", blob, _open_snapshot(), "validate")
	_check(bool(validate_result.get("success")), "upgraded record validates")
	var commit_result: RefCounted = restored.call("deserialize", blob, _open_snapshot(), "commit")
	_check(bool(commit_result.get("success")), "upgraded record deserializes")
	_check(int(restored.call("get_equipment_level", 7)) == 4, "deserialized instance remains level 4")
	_check(restored.call("serialize") == blob, "save→load→save is byte-identical with level")


func _test_legacy_grid_record_defaults_to_level_one() -> void:
	print("\n[save compatibility] missing level defaults to L1")
	var grid := _make_grid()
	var legacy := {
		"schema_version": 1,
		"width": 5,
		"height": 5,
		"records": [{
			"instance_id": 7,
			"footprint_cells": [[1, 1]],
			"access_cells": [[2, 1]],
			"rotation": 0,
		}],
	}
	var result: RefCounted = grid.call("deserialize", legacy, _open_snapshot(), "commit")
	_check(bool(result.get("success")), "legacy record without level still loads")
	_check(int(grid.call("get_equipment_level", 7)) == 1, "legacy instance defaults to level 1")
	_check(not (grid.call("serialize") as Dictionary)["records"][0].has("level"), "implicit L1 stays omitted for byte-compatible saves")


func _test_target_weight_applies_attraction_multiplier() -> void:
	print("\n[targeting] upgraded attraction changes selection weight")
	var member_sim: RefCounted = (load("res://src/systems/member_sim.gd") as Script).new()
	var neutral := float(member_sim.call("target_selection_weight", 0.2, 3, 1.0, 1.0, 1.0, 1.0))
	var upgraded := float(member_sim.call("target_selection_weight", 0.2, 3, 1.0, 1.0, 1.0, 1.30))
	_check(upgraded > neutral, "L3 attraction produces strictly higher target weight")
	_check(is_equal_approx(upgraded / neutral, 1.30), "target weight changes by the exact 1.30 multiplier")


func _test_economy_applies_upgraded_revenue() -> void:
	print("\n[revenue] completed visit applies snapshotted equipment level")
	var grid := _make_grid()
	_commit_one(grid)
	var upgrade := _make_upgrade(grid)
	var rig := _make_economy()
	var orch: Node = rig["orchestrator"]
	var economy: RefCounted = rig["economy"]
	var member_stub := CompletedVisitMemberStub.new()
	member_stub.completed_level = 3
	orch.set("member_sim", member_stub)
	economy.set("_upgrade_reader", upgrade)
	economy.call("on_member_completed_visit", 42)
	_check(int(economy.get("balance")) == 514, "L3 completed visit earns round($12×1.2) = $14")


func _free_nodes() -> void:
	for node in _nodes_to_free:
		if is_instance_valid(node):
			node.free()
	_nodes_to_free.clear()
