## Independent first-day contract checks using the real main simulation assembly.
extends SceneTree
const RUNNER_META := "gym_manager_test_runner_active"
var _pass := 0
var _fail := 0

func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	var result := run_all()
	quit(1 if result.fail else 0)

## Exercises public commands, actual course progression and coordinated restoration.
func run_all() -> Dictionary:
	_test_no_purchase_course_and_pause()
	_test_park_and_invalid_restore()
	print("DAY CONTRACT: %d passed, %d failed" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}

func _rig() -> Dictionary:
	var main: Node = load("res://src/main.gd").new()
	var checked: Dictionary = load("res://src/bootstrap/resource_preflight.gd").check()
	main.set("_catalog", checked.catalog)
	main.set("_preflight_data", checked.data)
	main.call("_assemble_systems")
	var orch = main.get("_orch")
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

func _test_no_purchase_course_and_pause() -> void:
	var rig := _rig()
	var view: Dictionary = rig.day.get_view_state()
	_check(view.phase == "PREP" and view.balance == 280, "community initialization is scoped")
	_check(rig.orch.grid_system.get_placed_instances().size() == 2, "two borrowed devices exist in real grid")
	_check(not rig.day.command("next_day", {}).ok, "cannot skip directly to next day")
	_check(rig.day.command("return_to_gym", {}).ok, "skip park still opens actual service")
	_advance(rig, 1600)
	rig.orch.time_system.pause()
	var paused: Dictionary = rig.day.serialize()
	_advance(rig, 100)
	_check(rig.day.serialize() == paused, "global pause freezes all course/day timers")
	rig.orch.time_system.resume()
	_advance(rig, 2000)
	view = rig.day.get_view_state()
	_check(view.phase == "CLOSE", "exact service duration reaches closing")
	_check(view.course.status == "completed", "real zero-purchase AUTO course completes")
	_check(float(view.course.start_seconds) <= 220, "baseline opens before latest start")
	_check(view.course.training_seconds.size() == 4, "four actual class members retained for report")
	for trained in view.course.training_seconds:
		_check(float(trained) >= 30 and float(trained) <= 40, "actual member training meets fee threshold without exceeding plan")
	_check(view.balance >= 376 and view.balance <= 472, "four course fees and at most eight ordinary fees, no extra reward")
	_check(view.story.events.has("aluo_met"), "skip-park path still introduces Aluo at closing")
	var money: int = view.balance
	rig.day.command("interact", {})
	rig.day.command("interact", {})
	_check(rig.day.get_view_state().balance == money, "reopening closing dialogue never pays again")
	_check(rig.day.command("next_day", {}).ok and rig.day.get_view_state().day == 2, "closing can continue to day two prep")
	rig.main.free()

func _test_park_and_invalid_restore() -> void:
	var rig := _rig()
	_check(rig.day.command("depart", {}).ok, "depart enters park")
	_check(rig.day.command("start_challenge", {}).ok, "formal attempt begins")
	rig.day.command("move", {"x": 0.0, "y": 0.0})
	_advance(rig, 30)
	var view: Dictionary = rig.day.get_view_state()
	_check(view.outing.progress_m == 0 and view.outing.seconds > 0, "standing consumes time without scoring distance")
	rig.day.command("move", {"x": 1.0, "y": 0.0})
	_advance(rig, 20)
	_check(rig.day.get_view_state().outing.progress_m > 0, "player input moves along actual park route")
	var bad: Dictionary = rig.day.serialize().duplicate(true)
	bad["phase"] = "INVALID_PHASE"
	var before: Dictionary = rig.day.serialize()
	var rejected = rig.day.deserialize(bad, true)
	_check(not rejected.ok and rig.day.serialize() == before, "malformed phase rejected without mutation")
	rig.day.command("move", {"x": 0.0, "y": 0.0})
	var blob: Dictionary = SaveLoad._normalize_types(JSON.parse_string(JSON.stringify(rig.save._perform_save(), "", true, true)))
	var cold := _rig()
	var mask := PackedByteArray()
	mask.resize(130)
	mask.fill(1)
	var restored = cold.save.load(blob, mask)
	_check(restored.ok, "whole session restores into a new composition")
	_check(cold.orch.time_system.is_paused(), "cold restoration is paused")
	_check(cold.day.get_view_state().outing == rig.day.get_view_state().outing, "ongoing challenge checkpoint/stamina/timers preserved")
	rig.day.command("finish_challenge", {})
	_check(rig.day.get_view_state().phase == "OUTING", "finishing challenge returns to park, not auto service")
	_check(not rig.day.command("start_challenge", {}).ok, "formal result cannot be submitted twice")
	rig.main.free()
	cold.main.free()
