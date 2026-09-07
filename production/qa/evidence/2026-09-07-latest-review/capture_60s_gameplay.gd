extends Node

const Main := preload("res://src/main.gd")
const Proj2D := preload("res://src/presentation/oblique_projection.gd")

const FRAMES_DIR := "/Users/bmac/.gemini/antigravity-cli/brain/4b8c88fd-6ced-4874-8574-e65f45eaadb9/scratch/frames"
const TOTAL_FRAMES := 600 # 60.0s @ 10 FPS

var _main: Main = null
var _frame_count := 0
var _boot_step := 0

func _ready() -> void:
	_main = Main.new()
	_main.set_community_mode(true)
	_main._save_name = "test-step-e-capture"
	add_child(_main)

func _process(_delta: float) -> void:
	if _boot_step < 20:
		_boot_step += 1
		if _boot_step == 5:
			_main._on_community_action("depart", {})
		elif _boot_step == 10:
			_main._on_community_action("return_to_gym", {})
		elif _boot_step == 15:
			for i in 1200:
				_main._orch.time_system.process(0.1)
			Proj2D.enable_shallow_profile(true)
			if _main._world_root != null:
				_main._world_root.position = Proj2D.viewport_offset(Vector2(Main.WORLD_VIEWPORT_W, Main.WORLD_VIEWPORT_H), Main.WORLD_SCALE)
			# Mark gym_renovated
			if _main._day_cycle != null and not _main._day_cycle._state.events.has("gym_renovated"):
				_main._day_cycle._state.events.append("gym_renovated")
		return

	if _frame_count >= TOTAL_FRAMES:
		Proj2D.enable_shallow_profile(false)
		var save_p := OS.get_user_data_dir().path_join("saves/test-step-e-capture.sav.json")
		if FileAccess.file_exists(save_p):
			DirAccess.remove_absolute(save_p)
		print("COMPLETED 60s CAPTURE: %d frames saved!" % _frame_count)
		get_tree().quit(0)
		return

	# Scripted 60-second choreographic events:
	var sec: float = float(_frame_count) * 0.1

	# 0.0s - 6.0s: Coach Cheng walking across floor demonstrating 4-way walk
	if sec < 2.0:
		_main._on_community_action("move", {"x": 1.0, "y": 0.0})
	elif sec < 4.0:
		_main._on_community_action("move", {"x": 0.0, "y": 1.0})
	elif sec < 6.0:
		_main._on_community_action("move", {"x": -1.0, "y": 0.0})
	else:
		_main._on_community_action("move", {"x": 0.0, "y": 0.0})

	# 6.0s - 30.0s: Normal gym simulation running
	_main._orch.time_system.process(0.1)

	# 30.0s - 42.0s: Guidance phase on treadmill
	if sec >= 30.0 and sec < 35.0:
		if _main._day_cycle != null:
			_main._day_cycle._state.request = {
				"member_id": 0, "state": "USING", "status": "waiting",
				"seconds": 0.5, "timing_seconds": 0.0, "correct_choice": "maintain", "correct": false
			}
	elif sec >= 35.0 and sec < 42.0:
		if _main._day_cycle != null:
			_main._day_cycle._state.request.status = "timing"
			_main._day_cycle._state.request.timing_seconds = snappedf(fmod(sec * 1.5, 3.0), 0.01)

	# 42.0s - 52.0s: Expressive feedback sequence
	elif sec >= 42.0 and sec < 42.1:
		if _main._day_cycle != null:
			_main._day_cycle.trigger_feedback_sequence(0, "singer_aluo", 100)
	elif sec >= 42.1 and sec < 52.0:
		if _main._day_cycle != null and _main._day_cycle._state.get("feedback_sequence", {}).get("active", false):
			var fb_el: float = (sec - 42.0) * 0.25
			_main._day_cycle._state.feedback_sequence.elapsed = fb_el
			if fb_el >= 2.5:
				_main._day_cycle._state.feedback_sequence.active = false

	# 52.0s - 60.0s: Sequence completes, members finish stage
	elif sec >= 52.0:
		if _main._day_cycle != null:
			_main._day_cycle._state.feedback_sequence = {"active": false}

	# Refresh visuals
	if _main._coach_layer != null:
		_main._coach_layer.update_state()
		_main._coach_layer.queue_redraw()
	if _main._world_canvas != null:
		_main._world_canvas.queue_redraw()
	if _main._lighting != null:
		_main._lighting.queue_redraw()
	if _main._community_hud != null:
		_main._community_hud._refresh()

	# Capture current viewport frame
	var img := get_viewport().get_texture().get_image()
	if img != null:
		var frame_path := "%s/frame_%04d.png" % [FRAMES_DIR, _frame_count]
		img.save_png(frame_path)

	_frame_count += 1
	if _frame_count % 60 == 0:
		print("Captured %d / %d frames (%.1f sec)..." % [_frame_count, TOTAL_FRAMES, sec])
