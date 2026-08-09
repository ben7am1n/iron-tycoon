# B2 deterministic economy pacing probe.
#
# Runs the playable composition root's real simulation wiring for 6000 ticks
# (10 simulated minutes) after a representative player opening: buy and place
# one Treadmill + one Bike from the new empty-room $500 start. The probe prints
# earned income separately from the remaining post-purchase cash.
#
# Run:
#   godot --headless --log-file /tmp/gym-b2-probe.log \
#     --script tests/integration/economy/balance_pacing_probe.gd
extends SceneTree

const TICKS := 6000
const STARTING_CAPITAL := 500


func _init() -> void:
	var main: Node = load("res://src/main.gd").new()
	# _assemble_systems normally runs from Main._ready(). A --script probe has
	# no ready notification before _init completes, so drive the same methods
	# synchronously, matching the project's headless test convention.
	main.call("_assemble_systems")
	var orch: Node = main.get("_orch")
	orch.call("_ready")
	main.call("_initial_layout")

	var economy: RefCounted = main.get("_econ")
	var catalog: RefCounted = main.get("_catalog")
	var placement: RefCounted = orch.get("placement_system")
	var purchases := [
		["treadmill", Vector2i(2, 2)],
		["bike", Vector2i(2, 5)],
	]
	var spent := 0
	for purchase in purchases:
		var equipment_id := str(purchase[0])
		var cost := int(catalog.call("get_definition", equipment_id).get("cost"))
		if not bool(economy.call("spend", cost)):
			printerr("B2_PROBE purchase failed: %s cost=%d" % [equipment_id, cost])
			quit(2)
			return
		spent += cost
		main.call("_drag_drop", placement, equipment_id, purchase[1])

	for _tick in TICKS:
		orch.call("_advance_tick")

	var final_balance := int(economy.get("balance"))
	var post_purchase_balance := STARTING_CAPITAL - spent
	var earned_income := final_balance - post_purchase_balance
	var satisfaction: RefCounted = main.get("_sat")
	print("B2_ECONOMY_PROBE seed=20260807 ticks=%d minutes=10" % TICKS)
	print("B2_ECONOMY_PROBE opening=Treadmill+Bike spent=%d post_purchase=%d" % [
		spent, post_purchase_balance])
	print("B2_ECONOMY_PROBE earned_income=%d final_balance=%d completed_visits=%d G=%.6f" % [
		earned_income, final_balance, earned_income / 12,
		float(satisfaction.get("global_satisfaction"))])
	main.free()
	quit(0)
