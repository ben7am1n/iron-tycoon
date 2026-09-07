extends Node

const Main := preload("res://src/main.gd")
const Proj2D := preload("res://src/presentation/oblique_projection.gd")

var _main: Main = null
var _step := 0
var _saved_images: Dictionary = {}

func _ready() -> void:
	_main = Main.new()
	_main.set_community_mode(true)
	_main._save_name = "test-park-remaster-capture"
	add_child(_main)

func _process(_delta: float) -> void:
	_step += 1

	if _step == 3:
		Proj2D.enable_shallow_profile(true)
		if _main._world_root != null:
			_main._world_root.position = Proj2D.viewport_offset(Vector2(Main.WORLD_VIEWPORT_W, Main.WORLD_VIEWPORT_H), Main.WORLD_SCALE)
		_main._on_community_action("depart", {})

	elif _step == 6:
		# 1. Capture Start of Park (Coach at 0m, Idle/Walk)
		if _main._park_view != null:
			_main._park_view.queue_redraw()
		var img_start := get_viewport().get_texture().get_image()
		if img_start != null:
			img_start.save_png("production/qa/evidence/2026-09-07-latest-review/park-remaster-start.png")
			_saved_images["start"] = img_start
			print("SAVED park-remaster-start.png")

		# Advance coach to 36m near Aluo, pace = jog
		if _main._day_cycle != null:
			_main._day_cycle._state.outing.progress_m = 36.0
			_main._day_cycle._state.outing.pace = "jog"
			_main._day_cycle._state.outing.active = true
			_main._day_cycle._state.outing.stamina = 85.0

	elif _step == 10:
		# 2. Capture Near Aluo (36m, Jogging, Aluo with prompt)
		if _main._park_view != null:
			_main._park_view.queue_redraw()
		var img_aluo := get_viewport().get_texture().get_image()
		if img_aluo != null:
			img_aluo.save_png("production/qa/evidence/2026-09-07-latest-review/park-remaster-aluo.png")
			_saved_images["aluo"] = img_aluo
			print("SAVED park-remaster-aluo.png")

		# Advance coach to 120m, pace = sprint
		if _main._day_cycle != null:
			_main._day_cycle._state.outing.progress_m = 120.0
			_main._day_cycle._state.outing.pace = "sprint"
			_main._day_cycle._state.outing.active = true
			_main._day_cycle._state.outing.stamina = 55.0

	elif _step == 14:
		# 3. Capture Sprinting (120m, Sprinting with speed streaks)
		if _main._park_view != null:
			_main._park_view.queue_redraw()
		var img_sprint := get_viewport().get_texture().get_image()
		if img_sprint != null:
			img_sprint.save_png("production/qa/evidence/2026-09-07-latest-review/park-remaster-sprint.png")
			_saved_images["sprint"] = img_sprint
			print("SAVED park-remaster-sprint.png")

		# Also update phase-outing-dusk.png with the new high-quality capture
		if _saved_images.has("aluo"):
			_saved_images["aluo"].save_png("production/qa/evidence/2026-09-07-latest-review/phase-outing-dusk.png")
			print("UPDATED phase-outing-dusk.png")

		get_tree().quit(0)
