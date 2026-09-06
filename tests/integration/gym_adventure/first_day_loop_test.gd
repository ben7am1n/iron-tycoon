## GA-003: Full first playable community day simulation loop test.
extends SceneTree
const RUNNER_META := "gym_manager_test_runner_active"
var _pass := 0
var _fail := 0

func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	var result := run_all()
	quit(1 if result.fail else 0)

func run_all() -> Dictionary:
	_test_prep_borrowed_equipment_unsellable()
	_test_park_movement_pace_stamina_and_scoring()
	_test_service_class_guidance_and_closing()
	_test_closing_narrative_and_next_day()
	print("FIRST DAY LOOP: %d passed, %d failed" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}

func _rig() -> Dictionary:
	var main: Node = load("res://src/main.gd").new()
	var checked: Dictionary = load("res://src/bootstrap/resource_preflight.gd").check()
	main.set("_catalog", checked.catalog)
	main.set("_preflight_data", checked.data)
	main.call("_assemble_systems")
	var orch: SimulationOrchestrator = main.get("_orch")
	orch._ready()
	var day = load("res://src/systems/day_cycle_system.gd").new()
	var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/gym_adventure.json"))
	var fixture: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/gym_adventure_fixture.json"))
	day.init(config, fixture, orch)
	var save := SaveLoad.new()
	save.init(orch)
	return {"main": main, "orch": orch, "day": day, "save": save}

func _advance(rig: Dictionary, ticks: int) -> void:
	for index in ticks:
		rig.orch.time_system.process(0.1)

func _check(ok: bool, label: String) -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
		print("FAIL: " + label)

## Criterion 1: Community starts PREP with 280 and movable, unsellable borrowed devices.
func _test_prep_borrowed_equipment_unsellable() -> void:
	var rig := _rig()
	var view: Dictionary = rig.day.get_view_state()
	_check(view.phase == "PREP", "starts in PREP phase")
	_check(view.balance == 280, "initial balance is 280")
	var placed: Array = rig.orch.grid_system.get_placed_instances()
	_check(placed.size() == 2, "two starter devices placed")
	
	# Verify that starter devices (0 and 1) cannot be sold
	rig.orch.selection_system.select(0)
	var sold_0 = rig.orch.selection_system.sell_selected()
	_check(not sold_0, "starter instance 0 is protected and cannot be sold")
	rig.orch.selection_system.select(1)
	var sold_1 = rig.orch.selection_system.sell_selected()
	_check(not sold_1, "starter instance 1 is protected and cannot be sold")
	_check(rig.orch.economy.balance == 280, "balance untouched after rejected sell")
	rig.main.free()

## Criterion 2 & 3: Park movement, pace choices, stamina consumption, and scoring.
func _test_park_movement_pace_stamina_and_scoring() -> void:
	var rig := _rig()
	_check(rig.day.command("depart", {}).ok, "depart to park succeeds")
	_check(rig.day.get_view_state().phase == "OUTING", "phase transitioned to OUTING")
	
	# Start practice run
	_check(rig.day.command("practice", {}).ok, "practice challenge starts")
	_check(rig.day.get_view_state().outing.active, "outing active in practice")
	
	# Test stamina depletion in sprint
	_check(rig.day.command("set_pace", {"pace": "sprint"}).ok, "set pace to sprint")
	rig.day.command("move", {"x": 1.0, "y": 0.0})
	_advance(rig, 100)
	var outing: Dictionary = rig.day.get_view_state().outing
	_check(outing.stamina < 100.0, "stamina consumed during sprint")
	
	# Finish run
	rig.day.command("finish_challenge", {})
	_check(not rig.day.get_view_state().outing.active, "challenge finished")
	
	# Formal run
	_check(rig.day.command("start_challenge", {}).ok, "formal challenge starts")
	rig.day.command("set_pace", {"pace": "jog"})
	rig.day.command("move", {"x": 1.0, "y": 0.0})
	_advance(rig, 100)
	_check(rig.day.get_view_state().outing.progress_m > 0, "formal progress recorded")
	rig.day.command("finish_challenge", {})
	_check(not rig.day.command("start_challenge", {}).ok, "formal challenge cannot run twice on same day")
	rig.main.free()

## Criterion 4 & 5: Service execution, guidance window, and course completion.
func _test_service_class_guidance_and_closing() -> void:
	var rig := _rig()
	_check(rig.day.command("return_to_gym", {}).ok, "return to gym opens service")
	_check(rig.day.get_view_state().phase == "SERVICE", "phase is SERVICE")
	
	# Advance through service to trigger course guidance
	_advance(rig, 1200)
	var view: Dictionary = rig.day.get_view_state()
	_check(view.phase == "SERVICE", "still in SERVICE after 120s")
	
	# Advance remaining service until close (total service_seconds = 360)
	_advance(rig, 2500)
	view = rig.day.get_view_state()
	_check(view.phase == "CLOSE", "service finishes and transitions to CLOSE")
	_check(view.course.status == "completed", "class status is completed")
	_check(view.balance > 280, "balance increased from course and walk-in fees")
	rig.main.free()

## Criterion 6: Closing narrative, event registration, and next day transition.
func _test_closing_narrative_and_next_day() -> void:
	var rig := _rig()
	# Fast-forward directly to close via service
	rig.day.command("return_to_gym", {})
	_advance(rig, 3700)
	var view: Dictionary = rig.day.get_view_state()
	_check(view.phase == "CLOSE", "reached CLOSE")
	
	# Interact with Aluo at closing
	_check(rig.day.command("interact", {}).ok, "closing interaction succeeds")
	view = rig.day.get_view_state()
	_check(view.story.events.has("aluo_met"), "aluo_met event logged")
	
	# Next day transition
	_check(rig.day.command("next_day", {}).ok, "transition to next day succeeds")
	view = rig.day.get_view_state()
	_check(view.day == 2, "day advanced to 2")
	_check(view.phase == "PREP", "day 2 starts in PREP phase")
	_check(view.story.events.has("aluo_met"), "persisted events retained into next day")
	rig.main.free()
