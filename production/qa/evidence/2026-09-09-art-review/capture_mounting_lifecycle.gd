extends SceneTree

const Main := preload("res://src/main.gd")
const EVIDENCE_DIR := "/Users/bmac/CodeBase/gym_manager/production/qa/evidence/2026-09-09-art-review"
const FRAMES_DIR := "/Users/bmac/CodeBase/gym_manager/production/qa/evidence/2026-09-09-art-review/lifecycle_frames"

var _main: Main = null
var _frame_count := 0
var _save_name := "mounting-lifecycle-20260910"

func _initialize() -> void:
	create_timer(300.0).timeout.connect(func():
		print("TIMEOUT in capture_mounting_lifecycle")
		quit(1)
	)
	_run.call_deferred()

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

func _record_frame() -> void:
	if _frame_count < 900:
		_flush_render()
		await process_frame
		await RenderingServer.frame_post_draw
		var img := root.get_texture().get_image()
		if img != null:
			var frame_path := "%s/frame_%04d.png" % [FRAMES_DIR, _frame_count]
			img.save_png(frame_path)
		_frame_count += 1
		if _frame_count % 90 == 0:
			print("Recorded frame %d / 900 (%.1fs @ 30 FPS)..." % [_frame_count, float(_frame_count) / 30.0])

func _capture_milestone(target_path: String) -> void:
	_flush_render()
	await process_frame
	await RenderingServer.frame_post_draw
	var img := root.get_texture().get_image()
	if img != null:
		img.save_png(target_path)
		print(">>> Milestone captured: ", target_path)

func _run() -> void:
	DirAccess.make_dir_recursive_absolute(FRAMES_DIR)

	_main = Main.new()
	_main.set_community_mode(true)
	_main._save_name = _save_name
	root.add_child(_main)
	await process_frame
	await RenderingServer.frame_post_draw

	var hud = _main._community_hud
	var dc = _main._day_cycle
	var orch = _main._orch
	var sim = orch.member_sim
	var canvas = _main._world_canvas

	print(">>> 1. Starting Segment 1: Ordinary Member Lifecycle (Walk -> Mount -> Workout -> Pause -> Resume -> Dismount -> Second Mount)...")

	# Open gym service
	hud._buttons["open_service"].pressed.emit()
	_flush_render()
	await process_frame

	while sim.members.is_empty():
		orch.time_system.process(0.1)

	var mem0 = sim.members[0]
	var mem0_id: int = int(mem0.member_id)
	mem0["exercises_per_visit"] = 2

	# Phase 1: Walk to Treadmill
	print("Recording walk approach...")
	await _capture_milestone(EVIDENCE_DIR.path_join("lifecycle-01-walk-approach.png"))
	while sim.visit_snapshot(mem0_id).get("state") != "USING":
		await _record_frame()
		if _frame_count % 3 == 0:
			orch.time_system.process(0.1)

	print("Member %d arrived at Treadmill! State=USING at sim tick %d." % [mem0_id, orch.get_tick_count()])
	_flush_render()
	await process_frame

	# Phase 2: 12-Frame Mounting Interpolation (0.4s @ 30 FPS)
	var trk0 = canvas.get_member_using_tracker(mem0_id)
	print("Treadmill initial tracker: ", trk0)
	assert(trk0.get("ticks_in_use", 0) <= 1)

	for f in 12:
		await _record_frame()
		if (f + 1) % 3 == 0:
			orch.time_system.process(0.1)
		if f == 6:
			await _capture_milestone(EVIDENCE_DIR.path_join("lifecycle-02-mount-interpolating.png"))

	var trk_mounted = canvas.get_member_using_tracker(mem0_id)
	assert(trk_mounted.get("ticks_in_use") >= 4)
	print("Treadmill mount completed! Tracker: ", trk_mounted)

	# Phase 3: Active Workout on Treadmill (90 frames, 3.0s)
	print("Recording active workout on treadmill...")
	await _capture_milestone(EVIDENCE_DIR.path_join("lifecycle-03-treadmill-active.png"))
	for f in 90:
		await _record_frame()
		if _frame_count % 3 == 0:
			orch.time_system.process(0.1)

	# Phase 4: Pause Freeze (30 frames, 1.0s)
	print("Dispatching toggle_pause to PAUSE...")
	_main._on_community_action("toggle_pause", {})
	assert(orch.time_system.is_paused())
	await _capture_milestone(EVIDENCE_DIR.path_join("lifecycle-04-pause-frozen.png"))

	var pause_tick = orch.get_tick_count()
	var pause_trk = canvas.get_member_using_tracker(mem0_id).duplicate()

	for f in 30:
		var cur_trk = canvas.get_member_using_tracker(mem0_id)
		assert(cur_trk.get("ticks_in_use") == pause_trk.get("ticks_in_use"))
		await _record_frame()

	print("Pause freeze verified: 30 frames at tick %d with ticks_in_use=%s!" % [pause_tick, pause_trk.get("ticks_in_use")])

	# Phase 5: Resume Workout (60 frames, 2.0s)
	print("Dispatching toggle_pause to RESUME...")
	_main._on_community_action("toggle_pause", {})
	assert(not orch.time_system.is_paused())

	for f in 60:
		await _record_frame()
		if _frame_count % 3 == 0:
			orch.time_system.process(0.1)

	# Phase 6: Dismount Interpolation (12 frames, 0.4s)
	mem0["use_ticks_remaining"] = 4
	print("Recording dismount interpolation...")
	await _capture_milestone(EVIDENCE_DIR.path_join("lifecycle-05-dismount-lerp.png"))
	for f in 12:
		await _record_frame()
		if (f + 1) % 3 == 0:
			orch.time_system.process(0.1)

	# Step until member leaves treadmill
	while sim.visit_snapshot(mem0_id).get("state") == "USING":
		orch.time_system.process(0.1)

	# Phase 7: Walk to Secondary Station (Yoga Mat)
	print("Ordinary member walking to secondary station (Yoga Mat, Dev 1)...")
	while sim.visit_snapshot(mem0_id).get("state") != "USING":
		await _record_frame()
		if _frame_count % 3 == 0:
			orch.time_system.process(0.1)

	# Phase 8: Secondary Station Mount (12 frames, 0.4s @ 30 FPS)
	_flush_render()
	await process_frame
	var sec_init_trk = canvas.get_member_using_tracker(mem0_id)
	print("Secondary mount initial tracker: ", sec_init_trk)
	assert(sec_init_trk.get("device_id") == 1)
	assert(sec_init_trk.get("ticks_in_use", 0) <= 1)
	await _capture_milestone(EVIDENCE_DIR.path_join("lifecycle-06-second-station-mount.png"))

	for f in 12:
		await _record_frame()
		if (f + 1) % 3 == 0:
			orch.time_system.process(0.1)

	var sec_trk_done = canvas.get_member_using_tracker(mem0_id)
	assert(sec_trk_done.get("ticks_in_use") >= 4)
	print("Secondary mount completed successfully to Yoga Mat anchor!")

	# Phase 9: Secondary Workout (60 frames, 2.0s)
	for f in 60:
		await _record_frame()
		if _frame_count % 3 == 0:
			orch.time_system.process(0.1)

	# =========================================================================
	# SEGMENT 2: Course Member Lifecycle
	# =========================================================================
	print(">>> 2. Starting Segment 2: Course Member Lifecycle...")

	# Advance game time to tick 1750 (course gathering)
	while orch.get_tick_count() < 1750:
		orch.time_system.process(0.1)

	var cmems = dc.get_view_state().course.members
	assert(cmems.size() == 4)
	var c_lead: int = int(cmems[0])
	print("Course lead member: %d. Waiting gathering..." % c_lead)

	# Phase 10: Course Waiting Gathering (30 frames)
	for f in 30:
		await _record_frame()
		if _frame_count % 3 == 0:
			orch.time_system.process(0.1)

	# Advance to tick 1800 (Course starts!)
	while orch.get_tick_count() < 1800:
		orch.time_system.process(0.1)

	# Phase 11: Course Member Walk to Station 1
	print("Course started! Lead member walking to Station 1...")
	while sim.visit_snapshot(c_lead).get("state") != "USING":
		await _record_frame()
		if _frame_count % 3 == 0:
			orch.time_system.process(0.1)

	# Phase 12: Station 1 Mount (12 frames, 0.4s @ 30 FPS)
	_flush_render()
	await process_frame
	var c_mount1_trk = canvas.get_member_using_tracker(c_lead)
	assert(c_mount1_trk.get("ticks_in_use", 0) <= 1)

	for f in 12:
		await _record_frame()
		if (f + 1) % 3 == 0:
			orch.time_system.process(0.1)

	# Phase 13: Station 1 Workout (60 frames, 2.0s)
	for f in 60:
		await _record_frame()
		if _frame_count % 3 == 0:
			orch.time_system.process(0.1)

	# Phase 14: Station Switch Walk (advance to tick 2400)
	print("Advancing to Block 2 station switch (tick 2400)...")
	while orch.get_tick_count() < 2400:
		orch.time_system.process(0.1)

	print("Course lead walking to Station 2 with trained_ticks=%s..." % sim.visit_snapshot(c_lead).get("trained_ticks"))
	while sim.visit_snapshot(c_lead).get("state") != "USING":
		await _record_frame()
		if _frame_count % 3 == 0:
			orch.time_system.process(0.1)

	# Phase 15: Station 2 Secondary Mount (12 frames, 0.4s @ 30 FPS)
	_flush_render()
	await process_frame
	var c_sec_init = canvas.get_member_using_tracker(c_lead)
	print("Course Station 2 initial tracker: ", c_sec_init)
	assert(c_sec_init.get("device_id") == 1)
	assert(c_sec_init.get("ticks_in_use", 0) <= 1)
	await _capture_milestone(EVIDENCE_DIR.path_join("lifecycle-07-course-switch-mount.png"))

	for f in 12:
		await _record_frame()
		if (f + 1) % 3 == 0:
			orch.time_system.process(0.1)

	var c_sec_done = canvas.get_member_using_tracker(c_lead)
	assert(c_sec_done.get("ticks_in_use") >= 4)
	print("Course Station 2 mount completed smoothly to anchor!")

	# Phase 16: Station 2 Workout & Wrap-up (remaining frames up to 900)
	await _capture_milestone(EVIDENCE_DIR.path_join("lifecycle-08-course-active.png"))
	while _frame_count < 900:
		await _record_frame()
		if _frame_count % 3 == 0:
			orch.time_system.process(0.1)

	print(">>> ALL 900 FRAMES (30.0s @ 30 FPS) AND 8 MILESTONES CAPTURED SUCCESSFULLY! <<<")

	_main.free()
	var save_p := OS.get_user_data_dir().path_join("saves/" + _save_name + ".sav.json")
	if FileAccess.file_exists(save_p):
		DirAccess.remove_absolute(save_p)

	quit(0)
