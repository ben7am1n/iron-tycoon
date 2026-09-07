# tests/integration/gym_adventure/step_e_sixty_second_showcase_test.gd
# Validates 60-second full gameplay loop and evidence deliverables for Step E:
# waiting, walking, using equipment, guidance interaction, and celebration feedback.
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"
const Main := preload("res://src/main.gd")

var _pass := 0
var _fail := 0
var _main: Main = null

func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	create_timer(30.0).timeout.connect(func() -> void: quit(1))
	_run_all.call_deferred()

func _check(condition: bool, message: String) -> void:
	if condition:
		_pass += 1
		print("  PASS: %s" % message)
	else:
		_fail += 1
		print("  FAIL: %s" % message)

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
	var status := OS.execute(OS.get_executable_path(), ["--headless", "--path", path, "--script", "res://tests/integration/gym_adventure/step_e_sixty_second_showcase_test.gd"], output, true)
	var out_str := str(output)
	var regex := RegEx.create_from_string("STEP E SHOWCASE: (\\d+) passed, (\\d+) failed")
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
		print("FAIL: step_e process execution error: status=%d\n%s" % [status, out_str])
	return {"pass": _pass, "fail": _fail}

func _run_all() -> void:
	await _execute_test()
	print("STEP E SHOWCASE: %d passed, %d failed" % [_pass, _fail])
	quit(0 if _fail == 0 else 1)

func _execute_test() -> void:
	# 1. Deliverables existence and validation
	var video_path := "production/qa/evidence/2026-09-07-latest-review/gameplay-60s-showcase.mp4"
	_check(FileAccess.file_exists(video_path), "gameplay-60s-showcase.mp4 exists on disk")
	if FileAccess.file_exists(video_path):
		var fa := FileAccess.open(video_path, FileAccess.READ)
		var sz := fa.get_length()
		fa.close()
		_check(sz > 100_000, "gameplay-60s-showcase.mp4 is valid video size (>100KB, got %d bytes)" % sz)

	var board_path := "production/qa/evidence/2026-09-07-latest-review/gameplay-60s-storyboard.png"
	_check(FileAccess.file_exists(board_path), "gameplay-60s-storyboard.png exists on disk")
	if FileAccess.file_exists(board_path):
		var img := Image.new()
		var err := img.load(board_path)
		_check(err == OK, "gameplay-60s-storyboard.png loads cleanly")
		_check(img.get_width() > 1000 and img.get_height() > 500, "gameplay-60s-storyboard.png dimensions valid (%dx%d)" % [img.get_width(), img.get_height()])

	# 2. Simulation Loop execution in real window
	_main = Main.new()
	_main.set_community_mode(true)
	_main._save_name = "test-step-e-run"
	var win := _tree_root()
	if win != null:
		win.add_child(_main)
	_main._save_name = "test-step-e-run"

	# Open gym & start service
	_main._on_community_action("depart", {})
	_main._on_community_action("return_to_gym", {})
	_check(_main._day_cycle != null and _main._day_cycle.phase == "SERVICE", "entered SERVICE phase")

	# Simulate 60 seconds (600 ticks @ 0.1s dt)
	var initial_coach_pos: Array = _main._day_cycle.get_view_state().coach.position.duplicate()
	_main._on_community_action("move", {"x": 1.0, "y": 0.0})
	for i in 20:
		_main._orch.time_system.process(0.1)

	var moved_coach_pos: Array = _main._day_cycle.get_view_state().coach.position
	_check(moved_coach_pos[0] > initial_coach_pos[0], "Coach moves horizontally with move input")

	# Run until course is running
	for i in 200:
		_main._orch.time_system.process(0.1)
	var vs: Dictionary = _main._day_cycle.get_view_state()
	_check(vs.course.status in ["scheduled", "running"], "course in scheduled or running state (status=%s)" % str(vs.course.status))

	# Trigger guidance and timing
	_main._day_cycle._state.request = {
		"member_id": 0, "state": "USING", "status": "timing",
		"seconds": 1.0, "timing_seconds": 1.0, "correct_choice": "maintain", "correct": true
	}
	_main._on_community_action("confirm_timing", {})
	vs = _main._day_cycle.get_view_state()
	_check(bool(vs.feedback_sequence.get("active", false)), "feedback sequence triggered by confirm_timing")

	# Advance 25 ticks to finish feedback sequence
	for i in 26:
		_main._orch.time_system.process(0.1)
	vs = _main._day_cycle.get_view_state()
	_check(not bool(vs.feedback_sequence.get("active", false)), "feedback sequence completes after 2.5s")

	# Advance remainder of 60s
	for i in 400:
		_main._orch.time_system.process(0.1)

	_check(_main._orch.get_tick_count() >= 600, "60s+ of gameplay ticks successfully simulated without error (ticks=%d)" % _main._orch.get_tick_count())
	var save_p := OS.get_user_data_dir().path_join("saves/test-step-e-run.sav.json")
	if FileAccess.file_exists(save_p):
		DirAccess.remove_absolute(save_p)
