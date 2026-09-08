extends SceneTree
func _initialize() -> void:
	create_timer(30.0).timeout.connect(func(): quit(1))
	_run.call_deferred()
func _run() -> void:
	var main = load("res://src/main.gd").new()
	main.set_community_mode(true)
	main._save_name = "review-20260907-capture"
	root.add_child(main)
	main._save_name = "review-20260907-capture"
	await process_frame
	main._on_community_action("open_service", {})
	for i in 1950:
		main._orch.time_system.process(0.1)
	await process_frame
	await process_frame
	await RenderingServer.frame_post_draw
	root.get_texture().get_image().save_png("/tmp/gym-sep8-training.png")
	print("REVIEW_COURSE=", main._day_cycle.get_view_state().course)
	main.free()
	DirAccess.remove_absolute("user://saves/review-20260907-capture.sav.json")
	quit()
