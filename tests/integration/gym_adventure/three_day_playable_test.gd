## GA-007: Three-day end-to-end playable integration, UX validation,
## lighting presentation change, and resource lifecycle stability test.
extends SceneTree

const Main := preload("res://src/main.gd")
const RUNNER_META := "gym_manager_test_runner_active"
const SCREENSHOT_DIR := "production/qa/evidence"

var _pass := 0
var _fail := 0
var _main: Main


func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	create_timer(35.0).timeout.connect(func() -> void: quit(1))
	_run_all.call_deferred()


func _check(ok: bool, label: String) -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
		print("FAIL: " + label)


func _advance(ticks: int) -> void:
	for index in ticks:
		_main._orch.time_system.process(0.1)


func _tree_root() -> Window:
	if root != null:
		return root
	var loop = Engine.get_main_loop()
	if loop is SceneTree:
		return loop.root
	return null


func run_all() -> Dictionary:
	var output: Array = []
	var path := ProjectSettings.globalize_path("res://")
	var status := OS.execute(OS.get_executable_path(), ["--headless", "--path", path, "--script", "res://tests/integration/gym_adventure/three_day_playable_test.gd"], output, true)
	var out_str := str(output)
	var regex := RegEx.create_from_string("THREE DAY PLAYABLE: (\\d+) passed, (\\d+) failed")
	var m := regex.search(out_str)
	if m != null:
		var p := int(m.get_string(1))
		var f := int(m.get_string(2))
		if status == 0 and f == 0:
			_pass = p
			_fail = 0
		else:
			_pass = p
			_fail = f if f > 0 else 1
			print(out_str)
	else:
		_fail += 1
		print("FAIL: three_day_playable process execution error: status=%d\n%s" % [status, out_str])
	return {"pass": _pass, "fail": _fail}


func _run_all() -> void:
	await _execute_test()
	_test_session_lifecycle_stability()
	print("THREE DAY PLAYABLE: %d passed, %d failed" % [_pass, _fail])
	quit(0 if _fail == 0 else 1)


func _execute_test() -> void:
	_main = Main.new()
	_main.set_community_mode(true)
	_main._save_name = "ga007-playable-test"
	var win := _tree_root()
	if win != null:
		win.add_child(_main)
	_main._save_name = "ga007-playable-test"
	await process_frame
	await process_frame

	# === Day 1 ===
	_check(_main._day_cycle.get_view_state().day == 1, "Day 1 starts in Main scene")
	_check(_main._day_cycle.get_view_state().phase == "PREP", "Day 1 starts in PREP")

	# Park outing & Aluo meeting
	_main._on_community_action("depart", {})
	await process_frame
	_check(_main._park_view.visible, "park view visible during OUTING")
	_main._on_community_action("interact", {})
	_check(_main._day_cycle.get_view_state().story.events.has("aluo_met"), "aluo_met event logged")

	# Return to gym and run Day 1 service
	_main._on_community_action("return_to_gym", {})
	await process_frame
	_advance(3700)
	await process_frame
	_check(_main._day_cycle.get_view_state().phase == "CLOSE", "Day 1 service finishes and enters CLOSE")
	_check(_main._day_cycle.get_view_state().story.events.has("aluo_first_class"), "aluo_first_class achieved on Day 1")

	# Transition to Day 2
	_main._on_community_action("next_day", {})
	await process_frame
	_check(_main._day_cycle.get_view_state().day == 2, "advanced to Day 2 in real Main scene")

	# === Day 2 ===
	# Buy and place bench_press via Build Palette
	_main._on_community_action("toggle_build", {})
	_check(_main._is_building and _main._palette.visible, "build palette opened in Day 2 PREP")
	_main._palette.on_tile_mouse_down("bench_press")
	_main._orch.placement_system.on_mouse_moved(Vector2i(5, 4))
	_main._orch.placement_system.on_drop()
	_main._on_community_action("toggle_build", {})
	_check(_main._grid.get_placed_instances().size() == 3, "bench_press placed on grid")

	# Select strength course
	var sel_res: Dictionary = _main._day_cycle.command("select_course", {"course_id": "course_strength_intro"})
	_check(sel_res.ok, "strength course selected with bench_press placed")
	_check(_main._day_cycle.get_view_state().selected_course_id == "course_strength_intro", "view reflects strength course")

	# Outing on Day 2
	_main._on_community_action("depart", {})
	_main._on_community_action("interact", {})
	_check(_main._day_cycle.get_view_state().story.feedback.back().contains("慢歌"), "Day 2 Aluo slow rhythm dialogue received")

	# Run Day 2 service on strength equipment
	_main._on_community_action("return_to_gym", {})
	_advance(3700)
	await process_frame
	_check(_main._day_cycle.get_view_state().phase == "CLOSE", "Day 2 reaches CLOSE")
	_check(_main._day_cycle.get_view_state().story.events.has("band_invitation"), "band_invitation committed at Day 2 CLOSE")

	# Renovation testing
	var cash_before: int = _main._econ.balance
	var reno_res: Dictionary = _main._day_cycle.command("renovate_gym", {})
	_check(reno_res.ok, "renovate_gym succeeds")
	_check(_main._econ.balance == cash_before - 120, "120 cash deducted for renovation")
	_check(_main._day_cycle.get_view_state().gym_renovated, "gym_renovated true in view")
	_check(_main._lighting.is_renovated(), "LightingLayer receives live renovated status")

	# Capture Day 2 renovated screenshot
	DirAccess.make_dir_recursive_absolute(SCREENSHOT_DIR)
	_capture_viewport(SCREENSHOT_DIR.path_join("gym-adventure-day2-renovated.png"))

	# Transition to Day 3
	_main._on_community_action("next_day", {})
	await process_frame
	_check(_main._day_cycle.get_view_state().day == 3, "advanced to Day 3")
	_check(_main._day_cycle.get_view_state().is_band_event, "Day 3 is flagged as band event")

	# === Day 3 ===
	# Outing on Day 3
	_main._on_community_action("depart", {})
	_main._on_community_action("interact", {})
	_check(_main._day_cycle.get_view_state().story.feedback.back().contains("包场"), "Day 3 Aluo concert warm-up dialogue")

	# Run Day 3 service: band members train
	_main._on_community_action("return_to_gym", {})
	_advance(1600) # Roster spawned and arrived
	var course_view: Dictionary = _main._day_cycle.get_view_state().course
	_check(course_view.members.size() == 4, "4 band course members present")

	# Class starts
	_advance(300) # Past 180s
	_check(_main._day_cycle.get_view_state().story.events.has("band_event_attended"), "band_event_attended committed at class start")
	await process_frame
	_capture_viewport(SCREENSHOT_DIR.path_join("gym-adventure-day3-band.png"))

	# Complete service
	_advance(1800)
	await process_frame
	_check(_main._day_cycle.get_view_state().phase == "CLOSE", "Day 3 reaches CLOSE")
	_check(_main._day_cycle.get_view_state().story.events.has("band_event_complete"), "band_event_complete committed after all members train")
	_check(_main._day_cycle.get_view_state().story.closing_text.contains("吉他手"), "Day 3 closing conversation displayed")
	_capture_viewport(SCREENSHOT_DIR.path_join("gym-adventure-day3-close.png"))

	# Teardown
	if win != null and _main.get_parent() == win:
		win.remove_child(_main)
	_main.free()
	_clean_test_saves()
	await process_frame


## Evaluates memory stability across 20 consecutive session create/destroy cycles (as required in implementation.md).
func _test_session_lifecycle_stability() -> void:
	var checked: Dictionary = load("res://src/bootstrap/resource_preflight.gd").check()
	var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/gym_adventure.json"))
	var fixture: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/gym_adventure_fixture.json"))
	
	var initial_mem := OS.get_static_memory_usage()
	for i in 20:
		var main_inst: Node = load("res://src/main.gd").new()
		main_inst.set("_catalog", checked.catalog)
		main_inst.set("_preflight_data", checked.data)
		main_inst.call("_assemble_systems")
		var orch: SimulationOrchestrator = main_inst.get("_orch")
		orch._ready()
		var dsys = load("res://src/systems/day_cycle_system.gd").new()
		dsys.init(config, fixture, orch)
		# Step one tick
		orch.time_system.process(0.1)
		main_inst.free()

	var final_mem := OS.get_static_memory_usage()
	var mem_growth_kb := (final_mem - initial_mem) / 1024
	# Growth after 20 cycles should be negligible (< 4096 KB)
	_check(mem_growth_kb < 4096, "20 session cycles maintain bounded memory (growth: %d KB)" % mem_growth_kb)


func _capture_viewport(filepath: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	var win := _tree_root()
	if win == null:
		return
	var viewport := win.get_viewport()
	if viewport == null:
		return
	var tex := viewport.get_texture()
	if tex == null:
		return
	var img := tex.get_image()
	if img != null and not img.is_empty():
		img.save_png(filepath)


func _clean_test_saves() -> void:
	var dir := DirAccess.open("user://saves")
	if dir != null:
		for file in dir.get_files():
			if file.begins_with("ga007-"):
				dir.remove(file)
