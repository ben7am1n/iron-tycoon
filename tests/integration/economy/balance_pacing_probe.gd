# B3 deterministic economy regression probe.
#
# This is both a headless_runner test and a standalone data probe. It exercises
# the playable composition root with Main's pinned seed and real system wiring.
#
# Gates:
#   - representative opening earns $150-$240 by minute 10 and remains inside
#     the 30-minute pacing envelope;
#   - forced G=0/0.5/1.0 completion rates are monotonic;
#   - mixed and all-Yoga layouts remain within a 20% net-value gap;
#   - a multi-use visit settles from the mean snapshotted multiplier, not its
#     final equipment level.
#
# Run standalone:
#   godot --headless --script tests/integration/economy/balance_pacing_probe.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"
const MASTER_SEED := 20260807
const TICKS_PER_MINUTE := 600
const TICKS_10_MIN := 10 * TICKS_PER_MINUTE
const TICKS_30_MIN := 30 * TICKS_PER_MINUTE

const TEN_MIN_INCOME_MIN := 150
const TEN_MIN_INCOME_MAX := 240
# B1's $24-$48/min steady-state target, with the first ten-minute ramp already
# bounded above, yields a deliberately broad cumulative 30-minute guardrail.
const THIRTY_MIN_INCOME_MIN := 600
const THIRTY_MIN_INCOME_MAX := 1200
const LAYOUT_GAP_MAX := 0.20

const OPENING_LAYOUT := [
	{"id": "treadmill", "cell": Vector2i(2, 2)},
	{"id": "bike", "cell": Vector2i(2, 5)},
]
const MIXED_LAYOUT := [
	{"id": "treadmill", "cell": Vector2i(2, 2)},
	{"id": "bike", "cell": Vector2i(6, 2)},
	{"id": "bench_press", "cell": Vector2i(2, 6)},
	{"id": "yoga_mat", "cell": Vector2i(7, 6)},
]
const ALL_MAT_LAYOUT := [
	{"id": "yoga_mat", "cell": Vector2i(2, 2)},
	{"id": "yoga_mat", "cell": Vector2i(6, 2)},
	{"id": "yoga_mat", "cell": Vector2i(2, 6)},
	{"id": "yoga_mat", "cell": Vector2i(7, 6)},
]
const G_LAYER_LAYOUT := [
	{"id": "yoga_mat", "cell": Vector2i(2, 1)},
	{"id": "yoga_mat", "cell": Vector2i(5, 1)},
	{"id": "yoga_mat", "cell": Vector2i(8, 1)},
	{"id": "yoga_mat", "cell": Vector2i(2, 4)},
	{"id": "yoga_mat", "cell": Vector2i(5, 4)},
	{"id": "yoga_mat", "cell": Vector2i(8, 4)},
	{"id": "yoga_mat", "cell": Vector2i(2, 7)},
	{"id": "yoga_mat", "cell": Vector2i(5, 7)},
	{"id": "yoga_mat", "cell": Vector2i(8, 7)},
]

var _pass := 0
var _fail := 0


func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	var result := run_all()
	quit(1 if int(result["fail"]) > 0 else 0)


func run_all() -> Dictionary:
	print("=".repeat(64))
	print("  INTEGRATION TEST: B3 Economy Balance Regression")
	print("=".repeat(64))

	_test_average_revenue_settlement()
	_test_fixed_seed_pacing()
	_test_g_layer_monotonicity()
	_test_mixed_vs_all_mat()

	print("\n=== B3 ECONOMY REGRESSION: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(condition: bool, message: String) -> void:
	if condition:
		_pass += 1
		print("  PASS: " + message)
	else:
		_fail += 1
		print("  FAIL: " + message)


## Builds the exact gameplay composition without presentation. Main owns the
## authoritative seed/config and the same system dependency graph as the game.
func _make_main() -> Node:
	var main: Node = load("res://src/main.gd").new()
	var preflight: Dictionary = load("res://src/bootstrap/resource_preflight.gd").check()
	main.set("_preflight_data", preflight.data)
	main.set("_catalog", preflight.catalog)
	main.call("_assemble_systems")
	var orchestrator: Node = main.get("_orch")
	# Main is intentionally not added to the SceneTree in this synchronous
	# probe, so drive the child's ready hook exactly once ourselves.
	orchestrator.call("_ready")
	main.call("_initial_layout")
	return main


## Places a layout through the real PlacementSystem drag/drop flow. When
## charge=true, purchases are paid from Economy first, matching the playable
## opening; capacity/layout comparison fixtures are uncharged on purpose.
func _place_layout(main: Node, layout: Array, charge: bool) -> Dictionary:
	var orchestrator: Node = main.get("_orch")
	var placement: RefCounted = orchestrator.get("placement_system")
	var economy: RefCounted = main.get("_econ")
	var catalog: RefCounted = main.get("_catalog")
	var grid: RefCounted = main.get("_grid")
	var spent := 0
	var layout_cost := 0
	var ok := true
	for item in layout:
		var equipment_id := str(item["id"])
		var cost := int(catalog.call("get_definition", equipment_id).get("cost"))
		layout_cost += cost
		if charge:
			if not bool(economy.call("spend", cost)):
				ok = false
				break
			spent += cost
		var before := (grid.call("get_placed_instances") as Array).size()
		main.call("_drag_drop", placement, equipment_id, item["cell"])
		if (grid.call("get_placed_instances") as Array).size() != before + 1:
			ok = false
			break
	return {"ok": ok, "spent": spent, "layout_cost": layout_cost}


## Runs one deterministic scenario. A negative forced_g leaves the real
## Satisfaction loop untouched. Otherwise G is pinned immediately before each
## tick boundary so MemberSim consumes exactly that stratum's two modifiers.
func _run_scenario(layout: Array, ticks: int, forced_g: float = -1.0, charge: bool = false) -> Dictionary:
	var main := _make_main()
	var orchestrator: Node = main.get("_orch")
	var economy: RefCounted = main.get("_econ")
	var satisfaction: RefCounted = main.get("_sat")
	var member_sim: RefCounted = main.get("_member")
	var seeded_rng: RefCounted = main.get("_srg")
	var placement_result := _place_layout(main, layout, charge)
	var stats := {"completed": 0}
	member_sim.member_completed_visit.connect(
		func(_member_id: int) -> void: stats["completed"] = int(stats["completed"]) + 1)

	var balance_after_purchase := int(economy.get("balance"))
	var income_10 := -1
	for tick in ticks:
		if forced_g >= 0.0:
			satisfaction.set("global_satisfaction", forced_g)
		orchestrator.call("_advance_tick")
		if tick + 1 == TICKS_10_MIN:
			income_10 = int(economy.get("balance")) - balance_after_purchase

	var result := {
		"placement_ok": bool(placement_result["ok"]),
		"seed": int(seeded_rng.get("master_seed")),
		"spent": int(placement_result["spent"]),
		"layout_cost": int(placement_result["layout_cost"]),
		"income_10": income_10,
		"income_total": int(economy.get("balance")) - balance_after_purchase,
		"completed": int(stats["completed"]),
		"final_g": float(satisfaction.get("global_satisfaction")),
	}
	main.free()
	return result


## B3-1 end-to-end: MemberSim snapshots L1 then L5 multipliers on completion,
## persists the accumulator, and Economy settles the mean when S5 fires.
func _test_average_revenue_settlement() -> void:
	print("\n[B3-1] multi-use visit settles mean snapshotted revenue multiplier")
	var main := _make_main()
	var placed := _place_layout(main, [
		{"id": "yoga_mat", "cell": Vector2i(2, 2)},
	], false)
	_check(bool(placed["ok"]), "average-settlement fixture placed one equipment")

	var grid: RefCounted = main.get("_grid")
	var member_sim: RefCounted = main.get("_member")
	var economy: RefCounted = main.get("_econ")
	var records: Array = grid.call("get_placed_instances")
	var instance_id := int(records[0].instance_id)
	var member := {
		"member_id": 7001,
		"state": "USING",
		"cell": Vector2i(3, 2),
		"exercises_done": 0,
		"exercises_per_visit": 2,
		"target_equipment_instance_id": instance_id,
		"cached_path": [],
		"cached_path_grid_version": -1,
		"repath_failures": 0,
		"give_up_blacklist": {},
		"leaving_timeout_ticks": 0,
		"patience_ticks_remaining": 0,
		"use_ticks_remaining": 1,
		"recently_used_ids": [],
		"last_completed_equipment_level": 1,
		"visit_revenue_multiplier_sum": 0.0,
		"visit_revenue_multiplier_count": 0,
	}
	(member_sim.get("members") as Array).append(member)

	# First completed use snapshots L1. Upgrade before the second completion;
	# this deliberately makes the last-device rule pay $20 instead of $16.
	member_sim.call("_on_using", member)
	_check(bool(grid.call("set_equipment_level", instance_id, 5)), "fixture upgrades equipment to L5 between completed uses")
	member["state"] = "USING"
	member["target_equipment_instance_id"] = instance_id
	member["use_ticks_remaining"] = 1
	member_sim.call("_on_using", member)

	var average := float(member_sim.call(
		"get_completed_visit_revenue_multiplier", int(member["member_id"])))
	_check(absf(average - 1.3334) < 0.000001,
		"MemberSim averages completed L1/L5 multipliers to 1.3334 (got %.6f)" % average)
	var saved_members: Array = (member_sim.call("serialize") as Dictionary)["members"]
	var saved: Dictionary = saved_members[0]
	_check(int(saved["visit_revenue_multiplier_count"]) == 2 \
		and absf(float(saved["visit_revenue_multiplier_sum"]) - 2.6668) < 0.000001,
		"visit multiplier sum/count are serialized mid-departure")

	var balance_before := int(economy.get("balance"))
	member_sim.call("_mark_gone", member, [])
	var revenue := int(economy.get("balance")) - balance_before
	_check(revenue == 16,
		"Economy pays round($12 × mean)= $16, not final-L5 $20 (got $%d)" % revenue)
	main.free()


func _test_fixed_seed_pacing() -> void:
	print("\n[B3-2 pacing] fixed-seed representative opening at 10/30 minutes")
	var result := _run_scenario(OPENING_LAYOUT, TICKS_30_MIN, -1.0, true)
	var income_10 := int(result["income_10"])
	var income_30 := int(result["income_total"])
	print("B3_PACING seed=%d opening=Treadmill+Bike spent=%d income_10=%d income_30=%d completed_30=%d final_G=%.6f" % [
		int(result["seed"]), int(result["spent"]), income_10, income_30,
		int(result["completed"]), float(result["final_g"])])
	_check(bool(result["placement_ok"]), "representative opening places Treadmill + Bike")
	_check(int(result["seed"]) == MASTER_SEED, "probe uses pinned seed %d" % MASTER_SEED)
	_check(income_10 >= TEN_MIN_INCOME_MIN and income_10 <= TEN_MIN_INCOME_MAX,
		"10-minute income is $%d within $%d-$%d" % [income_10, TEN_MIN_INCOME_MIN, TEN_MIN_INCOME_MAX])
	_check(income_30 >= THIRTY_MIN_INCOME_MIN and income_30 <= THIRTY_MIN_INCOME_MAX,
		"30-minute income is $%d within $%d-$%d" % [income_30, THIRTY_MIN_INCOME_MIN, THIRTY_MIN_INCOME_MAX])


func _test_g_layer_monotonicity() -> void:
	print("\n[B3-2 G layers] fixed G completion rate must be monotonic")
	var strata: Array[Dictionary] = []
	for g in [0.0, 0.5, 1.0]:
		var result := _run_scenario(G_LAYER_LAYOUT, TICKS_30_MIN, g, false)
		strata.append(result)
		print("B3_G_LAYER G=%.1f completed_30=%d rate_per_min=%.3f income=%d" % [
			g, int(result["completed"]), float(result["completed"]) / 30.0,
			int(result["income_total"])])
		_check(bool(result["placement_ok"]), "G=%.1f capacity fixture places all equipment" % g)
	var c0 := int(strata[0]["completed"])
	var c05 := int(strata[1]["completed"])
	var c1 := int(strata[2]["completed"])
	_check(c0 <= c05 and c05 <= c1,
		"completion counts are monotonic: %d <= %d <= %d" % [c0, c05, c1])


func _test_mixed_vs_all_mat() -> void:
	print("\n[B3-2 layout] mixed layout vs all Yoga Mat")
	var mixed := _run_scenario(MIXED_LAYOUT, TICKS_30_MIN)
	var mats := _run_scenario(ALL_MAT_LAYOUT, TICKS_30_MIN)
	var mixed_income := int(mixed["income_total"])
	var mat_income := int(mats["income_total"])
	var mixed_net := mixed_income - int(mixed["layout_cost"])
	var mat_net := mat_income - int(mats["layout_cost"])
	var denominator := float(maxi(abs(mixed_net), abs(mat_net)))
	var gap := 0.0 if denominator <= 0.0 \
		else absf(float(mixed_net - mat_net)) / denominator
	print("B3_LAYOUT_COMPARE minutes=30 mixed_income=%d mixed_net=%d all_mat_income=%d all_mat_net=%d gap=%.2f%%" % [
		mixed_income, mixed_net, mat_income, mat_net, gap * 100.0])
	_check(bool(mixed["placement_ok"]) and bool(mats["placement_ok"]),
		"mixed and all-Mat comparison fixtures place all equipment")
	_check(gap <= LAYOUT_GAP_MAX,
		"absolute net advantage gap %.2f%% <= %.0f%% (mixed=$%d, all-Mat=$%d)" % [
			gap * 100.0, LAYOUT_GAP_MAX * 100.0, mixed_net, mat_net])
