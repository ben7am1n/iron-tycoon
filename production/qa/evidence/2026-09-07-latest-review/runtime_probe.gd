extends SceneTree
func _initialize() -> void:
	_run.call_deferred()
func _run() -> void:
	var main = load("res://src/main.gd").new()
	var checked = load("res://src/bootstrap/resource_preflight.gd").check()
	main._catalog = checked.catalog
	main._preflight_data = checked.data
	main._assemble_systems()
	main._orch._ready()
	var day = load("res://src/systems/day_cycle_system.gd").new()
	day.init(checked.data["gym_adventure.json"], checked.data["gym_adventure_fixture.json"], main._orch)
	main._day_cycle = day
	main._community_mode = true
	var audio = load("res://src/audio/audio_manager.gd").new()
	audio.connect_day_cycle(day)
	day.phase_changed.emit("CLOSE")
	print("REVIEW_AUDIO_CLOSE_CHIME_COUNT=", audio.get_play_count("satisfaction_chime"))
	var bad: Dictionary = day.serialize()
	bad.course.erase("devices")
	print("REVIEW_SAVE_WITHOUT_COURSE_DEVICES_ACCEPTED=", day.deserialize(bad, true).ok)
	bad = day.serialize()
	bad.request = {"status": "timing"}
	print("REVIEW_SAVE_INCOMPLETE_REQUEST_ACCEPTED=", day.deserialize(bad, true).ok)
	var hud = load("res://src/ui/community_hud.gd").new()
	var view: Dictionary = day.get_view_state()
	view.phase = "OUTING"
	view.outing.progress_m = 42.0
	view.outing.seconds = 60.0
	hud.init(func(): return view)
	root.add_child(hud)
	hud._refresh()
	print("REVIEW_HUD_PARK_TEXT=", hud._details.text)
	view.phase = "SERVICE"
	view.course.guidance = {"state": "呼吸急促", "answer": "slow", "seconds_left": 10.0, "index": 0}
	hud._refresh()
	print("REVIEW_GUIDANCE_BUTTON_VISIBLE=", hud._buttons.slow.visible)
	var late: Dictionary = day.serialize()
	late.day = 3
	late.phase = "SERVICE"
	late.service_tick = 3599
	late.events = ["aluo_met", "aluo_first_class"]
	day.deserialize(late, false)
	day.tick_end()
	print("REVIEW_DAY3_FIRST_CLASS_INVITATION=", day.get_view_state().story.events.has("band_invitation"))
	day._place_record(2, "bench_press", Vector2i(5, 4), 0, 1)
	day._restore_layout()
	print("REVIEW_STORED_BEFORE=", day.get_view_state().stored_count)
	day._restore_stored()
	print("REVIEW_STORED_AFTER=", day.get_view_state().stored_count)
	main.switch_mode(false)
	print("REVIEW_SANDBOX_MEMBER_COMMUNITY_MODE=", main._member.community_mode, " ECONOMY_COMMUNITY_MODE=", main._econ.community_mode, " BALANCE=", main._econ.balance)
	main.switch_mode(true)
	print("REVIEW_RETURN_COMMUNITY_ORCHESTRATOR_ATTACHED=", main._orch.day_cycle != null)
	hud.free()
	audio.free()
	main.free()
	quit()
