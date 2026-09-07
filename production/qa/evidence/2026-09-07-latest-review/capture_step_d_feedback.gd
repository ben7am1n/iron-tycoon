extends Node

const Main := preload("res://src/main.gd")
const Proj2D := preload("res://src/presentation/oblique_projection.gd")

var _main: Main = null
var _step := 0
var _img_clapping: Image = null
var _img_nodding: Image = null

func _ready() -> void:
	_main = Main.new()
	_main.set_community_mode(true)
	_main._save_name = "test-step-d-capture"
	add_child(_main)
	_main._save_name = "test-step-d-capture"

func _process(_delta: float) -> void:
	_step += 1
	if _step == 5:
		_main._on_community_action("depart", {})
	elif _step == 10:
		_main._on_community_action("return_to_gym", {})
	elif _step == 15:
		for i in 1200:
			_main._orch.time_system.process(0.1)
		# Enable shallow oblique profile
		Proj2D.enable_shallow_profile(true)
		if _main._world_root != null:
			_main._world_root.position = Proj2D.viewport_offset(Vector2(Main.WORLD_VIEWPORT_W, Main.WORLD_VIEWPORT_H), Main.WORLD_SCALE)

		# Trigger feedback sequence: Phase 1 (0.5s - Clapping & Panting)
		if _main._day_cycle != null:
			_main._day_cycle.trigger_feedback_sequence(0, "singer_aluo", 100)
			_main._day_cycle._state.feedback_sequence.elapsed = 0.5
		if _main._coach_layer != null:
			_main._coach_layer.update_state()
			_main._coach_layer.queue_redraw()
		if _main._world_canvas != null:
			_main._world_canvas.queue_redraw()
		if _main._community_hud != null:
			_main._community_hud._refresh()

	elif _step == 20:
		# Capture Phase 1: Coach clapping + Aluo panting + Coach guidance toast
		_img_clapping = get_viewport().get_texture().get_image()
		if _img_clapping != null:
			_img_clapping.save_png("production/qa/evidence/2026-09-07-latest-review/feedback-phase-clapping-panting.png")
			print("SAVED feedback-phase-clapping-panting.png")

		# Switch to Phase 2 (1.6s - Thumbs Up & Relieved Smile + Lao Qiu nod)
		if _main._day_cycle != null:
			_main._day_cycle._state.feedback_sequence.elapsed = 1.6
		if _main._coach_layer != null:
			_main._coach_layer.update_state()
			_main._coach_layer.queue_redraw()
		if _main._world_canvas != null:
			_main._world_canvas.queue_redraw()
		if _main._community_hud != null:
			_main._community_hud._refresh()

	elif _step == 25:
		# Capture Phase 2: Coach thumbs up + Aluo smile + Lao Qiu nod
		_img_nodding = get_viewport().get_texture().get_image()
		if _img_nodding != null:
			_img_nodding.save_png("production/qa/evidence/2026-09-07-latest-review/feedback-phase-nod-smile.png")
			print("SAVED feedback-phase-nod-smile.png")

		# Create split/composite comparison image
		if _img_clapping != null and _img_nodding != null:
			var w: int = _img_clapping.get_width()
			var h: int = _img_clapping.get_height()
			var comp := Image.create(w, h, false, Image.FORMAT_RGBA8)
			var half_w: int = w / 2

			# Left half: Phase 1 (clapping / panting)
			for y in range(h):
				for x in range(half_w):
					comp.set_pixel(x, y, _img_clapping.get_pixel(x, y))

			# Right half: Phase 2 (thumbs up / smiling / Lao Qiu nod)
			for y in range(h):
				for x in range(half_w, w):
					comp.set_pixel(x, y, _img_nodding.get_pixel(x, y))

			# Gold divider line
			for y in range(h):
				comp.set_pixel(half_w, y, Color("F5D97B"))

			comp.save_png("production/qa/evidence/2026-09-07-latest-review/feedback-sequence-composite.png")
			print("SAVED feedback-sequence-composite.png!")

		# Cleanup
		Proj2D.enable_shallow_profile(false)
		var save_p := OS.get_user_data_dir().path_join("saves/test-step-d-capture.sav.json")
		if FileAccess.file_exists(save_p):
			DirAccess.remove_absolute(save_p)
		get_tree().quit(0)
