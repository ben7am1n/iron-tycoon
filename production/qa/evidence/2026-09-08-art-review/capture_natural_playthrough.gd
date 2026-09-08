extends SceneTree

const Main := preload("res://src/main.gd")
const FRAMES_DIR := "/Users/bmac/CodeBase/gym_manager/production/qa/evidence/2026-09-08-art-review/frames"
const EVIDENCE_DIR := "/Users/bmac/CodeBase/gym_manager/production/qa/evidence/2026-09-08-art-review"

var _main: Main = null
var _frame_count := 0
var _save_name := "natural-playthrough-capture"

func _initialize() -> void:
	create_timer(180.0).timeout.connect(func():
		print("TIMEOUT in capture_natural_playthrough")
		quit(1)
	)
	_run.call_deferred()

func _capture_frame(target_path: String) -> void:
	if _main._coach_layer != null:
		_main._coach_layer.update_state()
		_main._coach_layer.queue_redraw()
	if _main._world_canvas != null:
		_main._world_canvas.queue_redraw()
	if _main._lighting != null:
		_main._lighting.queue_redraw()
	if _main._community_hud != null:
		_main._community_hud._refresh()
	
	var img := root.get_texture().get_image()
	if img != null:
		img.save_png(target_path)

func _record_video_frame() -> void:
	if _frame_count < 600:
		var frame_path := "%s/frame_%04d.png" % [FRAMES_DIR, _frame_count]
		_capture_frame(frame_path)
		_frame_count += 1
		if _frame_count % 60 == 0:
			print("Recorded frame %d / 600 (%.1fs)..." % [_frame_count, float(_frame_count) * 0.1])

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(FRAMES_DIR)
	
	_main = Main.new()
	_main.set_community_mode(true)
	_main._save_name = _save_name
	root.add_child(_main)
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw

	# =========================================================================
	# MILESTONE 1: PREP Phase Default Start (0s)
	# =========================================================================
	print(">>> Capturing Milestone 1: PREP phase default...")
	_capture_frame(EVIDENCE_DIR.path_join("natural-01-prep.png"))
	
	# Record first 100 frames (0.0s - 10.0s): Coach walking gently around gym center
	for f in 100:
		if f < 25:
			_main._on_community_action("move", {"x": -0.5, "y": 0.0})
		elif f < 50:
			_main._on_community_action("move", {"x": 0.5, "y": 0.0})
		elif f < 75:
			_main._on_community_action("move", {"x": 0.0, "y": -0.5})
		else:
			_main._on_community_action("move", {"x": 0.0, "y": 0.5})
		_main._orch.time_system.process(0.1)
		await process_frame
		await RenderingServer.frame_post_draw
		_record_video_frame()

	# =========================================================================
	# Transition: Open Gym Service
	# =========================================================================
	print(">>> Opening Gym Service...")
	_main._on_community_action("move", {"x": 0.0, "y": 0.0})
	_main._on_community_action("open_service", {})
	await process_frame
	await RenderingServer.frame_post_draw

	# Advance 350 ticks (35.0s in SERVICE)
	for i in 350:
		_main._orch.time_system.process(0.1)
	await process_frame
	await RenderingServer.frame_post_draw

	# =========================================================================
	# MILESTONE 2: Ordinary Workout (35s)
	# =========================================================================
	print(">>> Capturing Milestone 2: Ordinary member workout at 35s...")
	_capture_frame(EVIDENCE_DIR.path_join("natural-02-ordinary-workout.png"))

	# Advance 101 ticks to tick 451: Natural coaching request triggers for member on treadmill!
	for i in 101:
		_main._orch.time_system.process(0.1)
	await process_frame
	await RenderingServer.frame_post_draw

	var dc = _main._day_cycle
	var req = dc.get_view_state().request
	print("TICK 451 NATURAL REQUEST=", req)

	var snap = _main._orch.member_sim.visit_snapshot(int(req.member_id))
	var mcell = snap.get("cell")
	var mx: float = float(mcell[0]) if mcell is Array else float(mcell.x)
	var my: float = float(mcell[1]) if mcell is Array else float(mcell.y)

	# Record video frames 100 - 250 (10.0s - 25.0s in video):
	# Coach dynamically walks towards member at (mx, my), gives guidance, confirms timing, triggers celebration!
	var interact_done := false
	var interact_frame := -1
	var choose_done := false
	var choose_frame := -1
	var confirm_done := false

	for f in 150:
		var cpos = dc.get_view_state().coach.position
		var to_mem := Vector2(mx - float(cpos[0]), my + 0.8 - float(cpos[1]))
		
		if not interact_done:
			if to_mem.length() > 0.8:
				var move_dir := to_mem.normalized()
				_main._on_community_action("move", {"x": move_dir.x, "y": move_dir.y})
			else:
				_main._on_community_action("move", {"x": 0.0, "y": 0.0})
				var r_int = dc.command("interact", {})
				print("REAL INTERACT: ", r_int)
				interact_done = true
				interact_frame = f
		elif interact_done and not choose_done:
			if f >= interact_frame + 5:
				var r_cho = dc.command("choose_guidance", {"choice": "rest"})
				print("REAL CHOOSE: ", r_cho)
				choose_done = true
				choose_frame = f
		elif choose_done and not confirm_done:
			if f >= choose_frame + 10:
				var r_conf = dc.command("confirm_timing", {})
				print("REAL CONFIRM: ", r_conf)
				print("FEEDBACK TRIGGERED: ", dc.get_view_state().feedback_sequence)
				confirm_done = true
				_capture_frame(EVIDENCE_DIR.path_join("natural-03-coaching-celebration.png"))
		elif confirm_done:
			if f > choose_frame + 40 and f < choose_frame + 70:
				# Walk back towards center floor
				var to_center := Vector2(5.0 - float(cpos[0]), 5.0 - float(cpos[1]))
				if to_center.length() > 0.3:
					var mdir := to_center.normalized()
					_main._on_community_action("move", {"x": mdir.x, "y": mdir.y})
				else:
					_main._on_community_action("move", {"x": 0.0, "y": 0.0})
			elif f >= choose_frame + 70:
				_main._on_community_action("move", {"x": 0.0, "y": 0.0})
		
		_main._orch.time_system.process(0.1)
		await process_frame
		await RenderingServer.frame_post_draw
		_record_video_frame()

	print(">>> Milestone 3: Coaching celebration completed...")

	# Fast forward to tick 1500 (150s): 4 course members spawn and walk to waiting area
	var current_tick = int(dc._state.service_tick)
	for i in (1500 - current_tick):
		_main._orch.time_system.process(0.1)
	await process_frame
	await RenderingServer.frame_post_draw

	# Record video frames 250 - 400 (25.0s - 40.0s):
	# Course members walking in and sitting down in waiting area
	for f in 150:
		_main._orch.time_system.process(0.1)
		if f == 50:
			# At 155s: Milestone 4: Course waiting
			print(">>> Capturing Milestone 4: Course waiting at 155s...")
			_capture_frame(EVIDENCE_DIR.path_join("natural-04-course-waiting.png"))
		await process_frame
		await RenderingServer.frame_post_draw
		_record_video_frame()

	# Tick 1800 (180s): Course begins! Members walk up and mount Treadmill & Bike
	# Record video frames 400 - 550 (40.0s - 55.0s):
	# Smooth mounting interpolation (4 ticks) and ongoing workout
	for f in 150:
		_main._orch.time_system.process(0.1)
		if f == 50:
			# At 185s: Milestone 5: Course mounted and running
			print(">>> Capturing Milestone 5: Course mounted at 185s...")
			_capture_frame(EVIDENCE_DIR.path_join("natural-05-course-mounted.png"))
		await process_frame
		await RenderingServer.frame_post_draw
		_record_video_frame()

	# Fast forward to tick 3600 (360s): Service finishes, gym transitions to CLOSE phase!
	current_tick = int(dc._state.service_tick)
	for i in (3600 - current_tick):
		_main._orch.time_system.process(0.1)
	await process_frame
	await RenderingServer.frame_post_draw

	# Record video frames 550 - 600 (55.0s - 60.0s):
	# CLOSE phase, night lighting, cool window contrast
	var r_close_int = dc.command("interact", {})
	print("CLOSE INTERACT: ", r_close_int)
	print("CLOSE TEXT: ", dc.get_view_state().story.closing_text)
	
	for f in 50:
		_main._orch.time_system.process(0.1)
		if f == 10:
			print(">>> Capturing Milestone 6: Daily close settlement...")
			_capture_frame(EVIDENCE_DIR.path_join("natural-06-close-settlement.png"))
		await process_frame
		await RenderingServer.frame_post_draw
		_record_video_frame()

	print(">>> ALL 600 FRAMES AND 6 MILESTONES CAPTURED SUCCESSFULLY!")

	# Cleanup save
	_main.free()
	var save_p := OS.get_user_data_dir().path_join("saves/" + _save_name + ".sav.json")
	if FileAccess.file_exists(save_p):
		DirAccess.remove_absolute(save_p)
	
	quit(0)
