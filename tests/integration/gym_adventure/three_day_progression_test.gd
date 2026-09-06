## GA-006: Comprehensive three-day content progression, course selection, renovation, and band event test.
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
	_test_day_1_flow_and_aluo_first_class()
	_test_day_2_course_selection_and_renovation()
	_test_day_3_band_event_and_slice_completion()
	_test_events_idempotency_and_save_load()
	print("THREE DAY PROGRESSION: %d passed, %d failed" % [_pass, _fail])
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

## Test 1: Full Day 1 loop leading to aluo_first_class and no premature band invitation.
func _test_day_1_flow_and_aluo_first_class() -> void:
	var rig := _rig()
	var day = rig.day
	_check(day.get_view_state().day == 1, "starts on Day 1")
	_check(day.get_view_state().phase == "PREP", "starts in PREP")

	# Park outing
	_check(day.command("depart", {}).ok, "depart to park")
	_check(day.command("interact", {}).ok, "interact with Aluo in park")
	var view: Dictionary = day.get_view_state()
	_check(view.story.events.has("aluo_met"), "aluo_met committed on Day 1 park meeting")

	# Return to gym and run service
	_check(day.command("return_to_gym", {}).ok, "open service")
	_advance(rig, 3700) # 370s exceeds service duration 360s
	view = day.get_view_state()
	_check(view.phase == "CLOSE", "transitions to CLOSE after service")
	_check(view.course.status == "completed", "Day 1 course completed")
	_check(view.story.events.has("aluo_first_class"), "aluo_first_class committed after meeting training quota")
	_check(not view.story.events.has("band_invitation"), "band_invitation is NOT triggered on Day 1")

	# Transition to Day 2
	_check(day.command("next_day", {}).ok, "transition to Day 2")
	view = day.get_view_state()
	_check(view.day == 2, "day advanced to 2")
	_check(view.phase == "PREP", "Day 2 in PREP phase")
	rig.main.free()

## Test 2: Day 2 course selection (strength course) and renovation command.
func _test_day_2_course_selection_and_renovation() -> void:
	var rig := _rig()
	var day = rig.day
	# Advance through Day 1 quickly
	day.command("return_to_gym", {})
	_advance(rig, 3700)
	day.command("next_day", {})
	_check(day.get_view_state().day == 2, "now on Day 2")

	# Check course selection without required equipment
	var res: Dictionary = day.command("select_course", {"course_id": "course_strength_intro"})
	_check(not res.ok, "cannot select strength course without bench_press placed")

	# Place bench_press on grid (anchor 5,3, footprint 1x2, access 5,2)
	var foot: Array[Vector2i] = [Vector2i(5, 3), Vector2i(5, 4)]
	var access: Array[Vector2i] = [Vector2i(5, 2)]
	rig.orch.grid_system.commit(2, foot, access, 0, "bench_press")
	rig.orch.selection_system.rebuild_mapping()

	# Select strength course
	res = day.command("select_course", {"course_id": "course_strength_intro"})
	_check(res.ok, "selecting strength course succeeds with bench_press placed")
	var view: Dictionary = day.get_view_state()
	_check(view.selected_course_id == "course_strength_intro", "selected course is course_strength_intro")
	_check(view.course.devices == [2, 1], "devices bound to bench_press (2) and yoga_mat (1)")

	# Park interaction Day 2
	day.command("depart", {})
	day.command("interact", {})
	view = day.get_view_state()
	_check(view.story.feedback.back().begins_with("阿洛：今天我换了段慢歌"), "Day 2 Aluo dialogue reflects slower rhythm")

	# Service and close on Day 2
	day.command("return_to_gym", {})
	_advance(rig, 3700)
	view = day.get_view_state()
	_check(view.phase == "CLOSE", "reached Day 2 CLOSE")
	_check(view.story.events.has("band_invitation"), "band_invitation committed at Day 2 CLOSE after first class")

	# Renovation testing
	var cash_before: int = view.balance
	res = day.command("renovate_gym", {})
	_check(res.ok, "renovate_gym succeeds with sufficient funds")
	view = day.get_view_state()
	_check(view.balance == cash_before - 120, "120 cash deducted for renovation")
	_check(view.gym_renovated == true, "gym_renovated flag true in view")
	_check(view.story.events.has("gym_renovated"), "gym_renovated recorded in permanent events")

	# Duplicate renovation rejected
	res = day.command("renovate_gym", {})
	_check(not res.ok, "duplicate renovation rejected")
	rig.main.free()

## Test 3: Day 3 band concert, attended event, completion, and final dialogue.
func _test_day_3_band_event_and_slice_completion() -> void:
	var rig := _rig()
	var day = rig.day
	# Fast-forward Day 1
	day.command("return_to_gym", {})
	_advance(rig, 3700)
	day.command("next_day", {})

	# Fast-forward Day 2
	day.command("return_to_gym", {})
	_advance(rig, 3700)
	day.command("next_day", {})

	# Now on Day 3
	var view: Dictionary = day.get_view_state()
	_check(view.day == 3, "advanced to Day 3")
	_check(view.is_band_event == true, "Day 3 course is flagged as band event")
	_check(view.objective.contains("乐队"), "Day 3 PREP objective mentions band event")

	# Day 3 Outing
	day.command("depart", {})
	day.command("interact", {})
	view = day.get_view_state()
	_check(view.story.feedback.back().contains("包场"), "Day 3 Aluo dialogue mentions band event booking")

	# Day 3 Service: band members arrive and train
	day.command("return_to_gym", {})
	_advance(rig, 1700) # Arrival at 150s (1500 ticks), check roster
	_check(day.get_view_state().course.members.size() == 4, "4 band course members spawned")

	# Verify roster persistent NPC IDs
	var members: Array = day.get_view_state().course.members
	var npcs := []
	for mid in members:
		var snap = rig.orch.member_sim.visit_snapshot(int(mid))
		npcs.append(snap.get("persistent_npc_id", ""))
	_check(npcs[0] == "singer_aluo", "seat 0 is singer_aluo")
	_check(npcs[1] == "band_bass_aming", "seat 1 is band_bass_aming")
	_check(npcs[2] == "band_guitar_dawei", "seat 2 is band_guitar_dawei")
	_check(npcs[3] == "band_drum_xiaokai", "seat 3 is band_drum_xiaokai")

	# Run until class start and check band_event_attended
	_advance(rig, 200) # Reaches 190s (past 180s class start)
	view = day.get_view_state()
	_check(view.story.events.has("band_event_attended"), "band_event_attended committed at class start")

	# Complete service and check band_event_complete
	_advance(rig, 1800) # Total 370s, closing service
	view = day.get_view_state()
	_check(view.phase == "CLOSE", "Day 3 in CLOSE phase")
	_check(view.story.events.has("band_event_complete"), "band_event_complete committed after all 4 band members train")
	_check(view.story.closing_text.contains("吉他手"), "Day 3 closing dialogue features the ending band conversation")
	rig.main.free()

## Test 4: Idempotency of permanent events and save/load integrity across multi-day states.
func _test_events_idempotency_and_save_load() -> void:
	var rig := _rig()
	var day = rig.day
	# Day 1 -> Day 2
	day.command("return_to_gym", {})
	_advance(rig, 3700)
	day.command("next_day", {})

	# Renovate on Day 2
	day.command("renovate_gym", {})
	day.command("return_to_gym", {})
	_advance(rig, 3700)

	# Serialize state at Day 2 CLOSE
	var serialized: Dictionary = day.serialize()
	_check(serialized.has("events"), "serialized payload contains events")
	_check(serialized.has("selected_course_id"), "serialized payload contains selected_course_id")
	_check(serialized.has("last_course_arrivals"), "serialized payload contains last_course_arrivals")

	# Deserialize into fresh DayCycleSystem
	var fresh_day = load("res://src/systems/day_cycle_system.gd").new()
	var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/gym_adventure.json"))
	var fixture: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/gym_adventure_fixture.json"))
	fresh_day.init(config, fixture, rig.orch)
	var dres = fresh_day.deserialize(serialized)
	_check(dres.ok, "deserialization of multi-day payload succeeds")
	var fresh_view = fresh_day.get_view_state()
	_check(fresh_view.day == 2, "restored day is 2")
	_check(fresh_view.phase == "CLOSE", "restored phase is CLOSE")
	_check(fresh_view.gym_renovated == true, "restored gym_renovated is true")
	_check(fresh_view.story.events.has("band_invitation"), "restored band_invitation event present")

	# Verify event array has no duplicates
	var events: Array = fresh_view.story.events
	var unique_events := {}
	for ev in events:
		_check(not unique_events.has(ev), "event %s appears only once" % str(ev))
		unique_events[ev] = true

	rig.main.free()
