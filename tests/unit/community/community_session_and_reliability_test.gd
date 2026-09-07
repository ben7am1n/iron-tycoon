class_name CommunitySessionAndReliabilityTest
extends SceneTree

## CommunitySessionAndReliabilityTest
## Validates Batch 1 & 2 fixes:
## - Mode switching isolation (member/economy flags & orchestrator day_cycle attachment)
## - Stored equipment retrieval via can_place(definition_cells, ...)
## - Band invitation day >= 2 condition on day close
## - Strict deserialization rejection of missing course devices and incomplete request
## - HUD park text contract and guidance button visibility
## - AudioManager uppercase phase event matching

const RUNNER_META := "gym_manager_test_runner_active"
const DayCycleScript := preload("res://src/systems/day_cycle_system.gd")
const AudioManagerScript := preload("res://src/audio/audio_manager.gd")
const CommunityHudScript := preload("res://src/ui/community_hud.gd")
const MainScript := preload("res://src/main.gd")
const ResourcePreflightScript := preload("res://src/bootstrap/resource_preflight.gd")

var _pass := 0
var _fail := 0

func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	print("\n── Running CommunitySessionAndReliabilityTest ──")
	var res := run_all()
	print("CommunitySessionAndReliabilityTest: %d passed, %d failed" % [res.pass, res.fail])
	quit(1 if res.fail > 0 else 0)

func run_all() -> Dictionary:
	_pass = 0
	_fail = 0
	_test_audio_phase_matching()
	_test_deserialization_strict_validation()
	_test_hud_data_contracts()
	_test_band_invitation_day_condition()
	_test_stored_equipment_restoration()
	_test_mode_switching_isolation()
	return {"pass": _pass, "fail": _fail}

func _assert_true(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		printerr("FAIL: %s" % msg)

func _assert_false(cond: bool, msg: String) -> void:
	_assert_true(not cond, msg)

func _assert_eq(actual: Variant, expected: Variant, msg: String) -> void:
	if actual == expected:
		_pass += 1
	else:
		_fail += 1
		printerr("FAIL: %s (expected %s, got %s)" % [msg, str(expected), str(actual)])

func _test_audio_phase_matching() -> void:
	var audio = AudioManagerScript.new()
	var day = DayCycleScript.new()
	audio.connect_day_cycle(day)
	
	_assert_eq(audio.get_play_count("satisfaction_chime"), 0, "Initial close chime count is 0")
	day.phase_changed.emit("CLOSE")
	_assert_eq(audio.get_play_count("satisfaction_chime"), 1, "CLOSE phase triggers satisfaction_chime")
	
	day.phase_changed.emit("SERVICE")
	_assert_true(audio.is_ambient_playing(), "SERVICE phase starts ambient sound")
	_assert_true(audio.is_bgm_playing(), "SERVICE phase starts BGM")

	day.phase_changed.emit("OUTING")
	_assert_false(audio.is_ambient_playing(), "OUTING stops gym ambient")

	audio.free()

func _test_deserialization_strict_validation() -> void:
	var preflight := ResourcePreflightScript.check()
	var main = MainScript.new()
	main._catalog = preflight.catalog
	main._preflight_data = preflight.data
	main._assemble_systems()
	main._orch._ready()
	
	var day = DayCycleScript.new()
	day.init(preflight.data["gym_adventure.json"], preflight.data["gym_adventure_fixture.json"], main._orch)

	var valid_data: Dictionary = day.serialize()
	_assert_true(day.deserialize(valid_data, true).ok, "Valid serialized data passes validation")

	var bad_course: Dictionary = valid_data.duplicate(true)
	bad_course.course.erase("devices")
	_assert_false(day.deserialize(bad_course, true).ok, "Save missing course devices is strictly rejected")

	var bad_request: Dictionary = valid_data.duplicate(true)
	bad_request.request = {"status": "timing"}
	_assert_false(day.deserialize(bad_request, true).ok, "Incomplete request is strictly rejected")

	main.free()

func _test_hud_data_contracts() -> void:
	var hud = CommunityHudScript.new()
	var park_view: Dictionary = {
		"phase": "OUTING",
		"day": 1,
		"balance": 200,
		"objective": "测试公园",
		"outing": {
			"progress_m": 55.0,
			"seconds": 45.0,
			"stamina": 90.0,
			"active": false,
		},
		"course": {},
		"request": {},
		"stored_count": 0,
	}
	hud.init(func(): return park_view)
	root.add_child(hud)
	hud._ready()
	hud._refresh()

	_assert_true(hud._details.text.contains("55.0 米"), "HUD park details contains progress_m")
	_assert_true(hud._details.text.contains("135 秒"), "HUD park details correctly computes remaining seconds (180 - 45)")

	# Test guidance buttons visible in SERVICE
	park_view.phase = "SERVICE"
	park_view.course = {
		"guidance": {"state": "呼吸急促", "answer": "slow", "seconds_left": 10.0, "index": 0}
	}
	hud._refresh()
	_assert_true(hud._buttons.slow.visible, "Guidance slow button is visible when course.guidance exists")
	_assert_true(hud._buttons.maintain.visible, "Guidance maintain button is visible when course.guidance exists")
	_assert_true(hud._buttons.rest.visible, "Guidance rest button is visible when course.guidance exists")

	# Test PREP phase with stored count shows restore_stored button
	park_view.phase = "PREP"
	park_view.course = {}
	park_view.stored_count = 2
	hud._refresh()
	_assert_true(hud._buttons.restore_stored.visible, "restore_stored button visible when stored_count > 0")
	_assert_true(hud._buttons.restore_stored.text.contains("取回库存(2)"), "restore_stored button label contains stored count")

	root.remove_child(hud)
	hud.free()

func _test_band_invitation_day_condition() -> void:
	var preflight := ResourcePreflightScript.check()
	var main = MainScript.new()
	main._catalog = preflight.catalog
	main._preflight_data = preflight.data
	main._assemble_systems()
	main._orch._ready()
	
	var day = DayCycleScript.new()
	day.init(preflight.data["gym_adventure.json"], preflight.data["gym_adventure_fixture.json"], main._orch)

	# Simulate completing first class on Day 3
	var day3_state: Dictionary = day.serialize()
	day3_state.day = 3
	day3_state.phase = "SERVICE"
	day3_state.service_tick = day._ticks(preflight.data["gym_adventure.json"].day.service_seconds) - 1
	day3_state.events = ["aluo_met", "aluo_first_class"]
	day.deserialize(day3_state, false)
	day.tick_end()

	var view: Dictionary = day.get_view_state()
	_assert_true(view.story.events.has("band_invitation"), "First class achieved on Day 3 successfully triggers band_invitation")

	main.free()

func _test_stored_equipment_restoration() -> void:
	var preflight := ResourcePreflightScript.check()
	var main = MainScript.new()
	main._catalog = preflight.catalog
	main._preflight_data = preflight.data
	main._assemble_systems()
	main._orch._ready()
	
	var day = DayCycleScript.new()
	day.init(preflight.data["gym_adventure.json"], preflight.data["gym_adventure_fixture.json"], main._orch)

	# Add an extra equipment, store layout, and restore stored
	day._place_record(5, "bench_press", Vector2i(5, 4), 0, 1)
	day._restore_layout()
	_assert_eq(day.get_view_state().stored_count, 1, "Non-fixture equipment placed in gym stored during restore_layout")

	# Test _restore_stored runs without assertion or error and places equipment back
	day._restore_stored()
	_assert_eq(day.get_view_state().stored_count, 0, "Stored equipment successfully restored to grid")

	main.free()

func _test_mode_switching_isolation() -> void:
	var preflight := ResourcePreflightScript.check()
	var main = MainScript.new()
	main._catalog = preflight.catalog
	main._preflight_data = preflight.data
	main._assemble_systems()
	main._orch._ready()
	
	var day = DayCycleScript.new()
	day.init(preflight.data["gym_adventure.json"], preflight.data["gym_adventure_fixture.json"], main._orch)
	main._day_cycle = day

	# Switch to community mode
	main.switch_mode(true)
	_assert_true(main._community_mode, "Mode is community")
	_assert_true(main._member.community_mode, "MemberSim is in community mode")
	_assert_true(main._econ.community_mode, "Economy is in community mode")
	_assert_true(main._orch.day_cycle != null, "Orchestrator has day_cycle attached in community mode")

	# Switch to sandbox mode
	main.switch_mode(false)
	_assert_false(main._community_mode, "Mode is sandbox")
	_assert_false(main._member.community_mode, "MemberSim community mode is disabled in sandbox")
	_assert_false(main._econ.community_mode, "Economy community mode is disabled in sandbox")
	_assert_true(main._orch.day_cycle == null, "Orchestrator day_cycle detached in sandbox mode")

	# Switch back to community mode
	main.switch_mode(true)
	_assert_true(main._community_mode, "Mode returned to community")
	_assert_true(main._member.community_mode, "MemberSim community mode re-enabled")
	_assert_true(main._econ.community_mode, "Economy community mode re-enabled")
	_assert_true(main._orch.day_cycle != null, "Orchestrator day_cycle re-attached")

	main.free()
