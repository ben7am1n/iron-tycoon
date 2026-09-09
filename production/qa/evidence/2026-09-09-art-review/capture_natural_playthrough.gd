extends SceneTree

const Main := preload("res://src/main.gd")
const EVIDENCE_DIR := "/Users/bmac/CodeBase/gym_manager/production/qa/evidence/2026-09-09-art-review"
const FRAMES_DIR := "/Users/bmac/CodeBase/gym_manager/production/qa/evidence/2026-09-09-art-review/frames"

var _main: Main = null
var _frame_count := 0
var _save_name := "natural-playthrough-20260909"

func _initialize() -> void:
	create_timer(300.0).timeout.connect(func():
		print("TIMEOUT in capture_natural_playthrough")
		quit(1)
	)
	_run.call_deferred()

func _send_key_down(hud: Node, k: Key) -> void:
	var ev := InputEventKey.new()
	ev.pressed = true
	ev.keycode = k
	ev.physical_keycode = k
	hud._unhandled_key_input(ev)

func _send_key_up(hud: Node, k: Key) -> void:
	var ev := InputEventKey.new()
	ev.pressed = false
	ev.keycode = k
	ev.physical_keycode = k
	hud._input(ev)

func _tap_key(hud: Node, k: Key) -> void:
	_send_key_down(hud, k)
	_send_key_up(hud, k)

func _flush_render() -> void:
	if _main._coach_layer != null:
		_main._coach_layer.update_state()
		_main._coach_layer.queue_redraw()
	if _main._world_canvas != null:
		_main._world_canvas.queue_redraw()
	if _main._lighting != null:
		_main._lighting.queue_redraw()
	if _main._community_hud != null:
		_main._community_hud._refresh()

func _capture_milestone(target_path: String) -> void:
	_flush_render()
	await process_frame
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	if img != null:
		img.save_png(target_path)
		print(">>> Milestone captured: ", target_path)

func _record_frame() -> void:
	if _frame_count < 1800:
		_flush_render()
		await process_frame
		await RenderingServer.frame_post_draw
		var img := root.get_texture().get_image()
		if img != null:
			var frame_path := "%s/frame_%04d.png" % [FRAMES_DIR, _frame_count]
			img.save_png(frame_path)
		_frame_count += 1
		if _frame_count % 150 == 0:
			print("Recorded frame %d / 1800 (%.1fs @ 30 FPS)..." % [_frame_count, float(_frame_count) / 30.0])

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(FRAMES_DIR)

	_main = Main.new()
	_main.set_community_mode(true)
	_main._save_name = _save_name
	root.add_child(_main)
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw

	var hud = _main._community_hud
	var dc = _main._day_cycle
	assert(hud != null and dc != null)

	# =========================================================================
	# MILESTONE 1: PREP Phase Default Start (0.0s)
	# =========================================================================
	print(">>> Capturing Milestone 1: PREP phase default (0.0s)...")
	var vs1 = dc.get_view_state()
	assert(vs1.phase == "PREP")
	await _capture_milestone(EVIDENCE_DIR.path_join("natural-01-prep.png"))

	# Segment 1: Video Frames 0 to 299 (0.0s - 10.0s @ 30 FPS)
	# Coach walks around with WASD keys, examining equipment and layout
	print(">>> Recording Segment 1: PREP walking with WASD (Frames 0 - 299)...")
	for f in 300:
		if f == 0: _send_key_down(hud, KEY_A)
		elif f == 60:
			_send_key_up(hud, KEY_A)
			_send_key_down(hud, KEY_D)
		elif f == 120:
			_send_key_up(hud, KEY_D)
			_send_key_down(hud, KEY_W)
		elif f == 180:
			_send_key_up(hud, KEY_W)
			_send_key_down(hud, KEY_S)
		elif f == 240:
			_send_key_up(hud, KEY_S)
			_send_key_down(hud, KEY_D)
		elif f == 285:
			_send_key_up(hud, KEY_D)

		_main._orch.time_system.process(0.1 / 3.0)
		await _record_frame()

	_send_key_up(hud, KEY_A)
	_send_key_up(hud, KEY_D)
	_send_key_up(hud, KEY_W)
	_send_key_up(hud, KEY_S)

	# Open gym service via HUD action button
	print(">>> Opening Gym Service via UI action...")
	hud._buttons["open_service"].pressed.emit()
	await process_frame
	await RenderingServer.frame_post_draw

	var vs_open = dc.get_view_state()
	print("SERVICE OPENED: Phase=", vs_open.phase)
	assert(vs_open.phase == "SERVICE")

	# =========================================================================
	# Segment 2: Video Frames 300 to 749 (10.0s - 25.0s @ 30 FPS)
	# Ordinary workout, fatigue request, coaching & celebration
	# =========================================================================
	print(">>> Recording Segment 2: Ordinary Workout & Coaching (Frames 300 - 749)...")

	# Advance to 35.0s game time (tick 350)
	while dc.get_view_state().service_seconds < 35.0:
		_main._orch.time_system.process(0.1)

	# Milestone 2: Ordinary Workout at 35.0s
	var vs2 = dc.get_view_state()
	var mems = _main._orch.member_sim.members
	print(">>> Milestone 2 Check: service_seconds=%.1f, members=%d" % [vs2.service_seconds, mems.size()])
	assert(vs2.service_seconds >= 35.0 and mems.size() > 0)
	await _capture_milestone(EVIDENCE_DIR.path_join("natural-02-ordinary-workout.png"))

	# Advance to natural coaching request (tick 451, 45.1s)
	while dc.get_view_state().request.is_empty():
		_main._orch.time_system.process(0.1)

	var req = dc.get_view_state().request
	print("Natural request triggered: ", req)
	assert(not req.is_empty())

	var snap = _main._orch.member_sim.visit_snapshot(int(req.member_id))
	var mcell = snap.get("cell")
	var mx: float = float(mcell[0]) if mcell is Array else float(mcell.x)
	var my: float = float(mcell[1]) if mcell is Array else float(mcell.y)

	var interact_done := false
	var choose_done := false
	var confirm_done := false
	var action_f := 0

	# Record frames 300 to 749 (450 frames)
	while _frame_count < 750:
		action_f += 1
		var cpos = dc.get_view_state().coach.position
		var to_mem := Vector2(mx - float(cpos[0]), my + 0.8 - float(cpos[1]))

		if not interact_done:
			if to_mem.length() > 0.8:
				if to_mem.x < -0.1: _send_key_down(hud, KEY_A)
				elif to_mem.x > 0.1: _send_key_down(hud, KEY_D)
				else:
					_send_key_up(hud, KEY_A)
					_send_key_up(hud, KEY_D)
				if to_mem.y < -0.1: _send_key_down(hud, KEY_W)
				elif to_mem.y > 0.1: _send_key_down(hud, KEY_S)
				else:
					_send_key_up(hud, KEY_W)
					_send_key_up(hud, KEY_S)
			else:
				_send_key_up(hud, KEY_A)
				_send_key_up(hud, KEY_D)
				_send_key_up(hud, KEY_W)
				_send_key_up(hud, KEY_S)
				_tap_key(hud, KEY_E)
				print("KEY_E Interact dispatched, req status=", dc.get_view_state().request.get("status"))
				interact_done = true
		elif interact_done and not choose_done:
			if action_f >= 40:
				_tap_key(hud, KEY_3)
				print("KEY_3 Choose guidance (rest) dispatched, req status=", dc.get_view_state().request.get("status"))
				choose_done = true
		elif choose_done and not confirm_done:
			if action_f >= 70:
				_tap_key(hud, KEY_E)
				print("KEY_E Confirm timing dispatched, feedback=", dc.get_view_state().feedback_sequence)
				confirm_done = true
				assert(dc.get_view_state().feedback_sequence.get("active") == true)
				await _capture_milestone(EVIDENCE_DIR.path_join("natural-03-coaching-celebration.png"))
		elif confirm_done:
			if action_f > 120 and action_f < 180:
				var to_center := Vector2(5.0 - float(cpos[0]), 5.0 - float(cpos[1]))
				if to_center.length() > 0.3:
					if to_center.x < -0.1: _send_key_down(hud, KEY_A)
					elif to_center.x > 0.1: _send_key_down(hud, KEY_D)
					if to_center.y < -0.1: _send_key_down(hud, KEY_W)
					elif to_center.y > 0.1: _send_key_down(hud, KEY_S)
				else:
					_send_key_up(hud, KEY_A)
					_send_key_up(hud, KEY_D)
					_send_key_up(hud, KEY_W)
					_send_key_up(hud, KEY_S)
			elif action_f >= 180:
				_send_key_up(hud, KEY_A)
				_send_key_up(hud, KEY_D)
				_send_key_up(hud, KEY_W)
				_send_key_up(hud, KEY_S)

		_main._orch.time_system.process(0.1 / 3.0)
		await _record_frame()

	# =========================================================================
	# Segment 3: Video Frames 750 to 1199 (25.0s - 40.0s @ 30 FPS)
	# Course arrival & waiting area gathering
	# =========================================================================
	print(">>> Recording Segment 3: Course Arrival & Waiting (Frames 750 - 1199)...")

	# Advance game time to tick 1500 (150.0s) where 4 course members spawn & gather
	while dc.get_view_state().service_seconds < 155.0:
		_main._orch.time_system.process(0.1)

	var vs4 = dc.get_view_state()
	print(">>> Milestone 4 Check: service_seconds=%.1f, status=%s, course_members=%d" % [
		vs4.service_seconds, vs4.course.status, vs4.course.members.size()
	])
	assert(vs4.service_seconds >= 150.0 and vs4.course.status == "scheduled")
	assert(vs4.course.members.size() == 4)
	await _capture_milestone(EVIDENCE_DIR.path_join("natural-04-course-waiting.png"))

	# Record frames 750 to 1199 showing seated members in waiting area
	while _frame_count < 1200:
		_main._orch.time_system.process(0.1 / 3.0)
		await _record_frame()

	# =========================================================================
	# Segment 4: Video Frames 1200 to 1649 (40.0s - 55.0s @ 30 FPS)
	# Course starts at tick 1800, smooth 12-frame mounting, active workout!
	# =========================================================================
	print(">>> Recording Segment 4: Course Mounted & Active Workout (Frames 1200 - 1649)...")

	# Advance game time past 1800 ticks (180.0s) to 195.0s (15.0s into course)
	while dc.get_view_state().service_seconds < 195.0:
		_main._orch.time_system.process(0.1)

	var vs5 = dc.get_view_state()
	print(">>> Milestone 5 Check: service_seconds=%.1f, status=%s, training_seconds=%s" % [
		vs5.service_seconds, vs5.course.status, str(vs5.course.training_seconds)
	])
	# Strict verification required by 2026-09-09 action plan:
	assert(vs5.course.status == "running")
	assert(vs5.course.training_seconds[0] >= 3.0)
	await _capture_milestone(EVIDENCE_DIR.path_join("natural-05-course-mounted.png"))

	# Record frames 1200 to 1649 showing ongoing workout animations with anchors & facing
	while _frame_count < 1650:
		_main._orch.time_system.process(0.1 / 3.0)
		await _record_frame()

	# =========================================================================
	# Segment 5: Video Frames 1650 to 1799 (55.0s - 60.0s @ 30 FPS)
	# Gym close, evening settlement & closing dialogue
	# =========================================================================
	print(">>> Recording Segment 5: Gym Close & Settlement (Frames 1650 - 1799)...")

	# Advance to 360.0s (tick 3600, CLOSE phase)
	while dc.get_view_state().phase != "CLOSE":
		_main._orch.time_system.process(0.1)

	var vs6 = dc.get_view_state()
	print(">>> Milestone 6 Check: phase=%s, closing_text=%s" % [vs6.phase, vs6.story.closing_text])
	assert(vs6.phase == "CLOSE")

	# Tap KEY_E for settlement dialogue interaction
	_tap_key(hud, KEY_E)
	print("KEY_E Interact dispatched in CLOSE, feedback=", dc.get_view_state().story.feedback)
	await _capture_milestone(EVIDENCE_DIR.path_join("natural-06-close-settlement.png"))

	# Record remaining frames to complete 1800 frames
	while _frame_count < 1800:
		_main._orch.time_system.process(0.1 / 3.0)
		await _record_frame()

	print(">>> ALL 1800 FRAMES (60.0s @ 30 FPS) AND 6 MILESTONES CAPTURED SUCCESSFULLY! <<<")

	# Cleanup
	_main.free()
	var save_p := OS.get_user_data_dir().path_join("saves/" + _save_name + ".sav.json")
	if FileAccess.file_exists(save_p):
		DirAccess.remove_absolute(save_p)

	quit(0)
