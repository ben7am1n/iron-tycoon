extends Node

const Main := preload("res://src/main.gd")
const Proj2D := preload("res://src/presentation/oblique_projection.gd")

var _main: Main = null
var _step := 0
var _saved_images: Dictionary = {}

func _ready() -> void:
	_main = Main.new()
	_main.set_community_mode(true)
	_main._save_name = "test-step-c-capture"
	add_child(_main)
	_main._save_name = "test-step-c-capture"

func _process(_delta: float) -> void:
	_step += 1
	
	if _step == 3:
		# Set shallow oblique profile
		Proj2D.enable_shallow_profile(true)
		if _main._world_root != null:
			_main._world_root.position = Proj2D.viewport_offset(Vector2(Main.WORLD_VIEWPORT_W, Main.WORLD_VIEWPORT_H), Main.WORLD_SCALE)

	elif _step == 5:
		# 1. Capture PREP (Daylight)
		var img_prep := get_viewport().get_texture().get_image()
		if img_prep != null:
			img_prep.save_png("production/qa/evidence/2026-09-07-latest-review/phase-prep-daylight.png")
			_saved_images["prep"] = img_prep
			print("SAVED phase-prep-daylight.png")
		
		# Transition to OUTING (Dusk)
		_main._on_community_action("depart", {})

	elif _step == 10:
		# 2. Capture OUTING (Dusk)
		var img_dusk := get_viewport().get_texture().get_image()
		if img_dusk != null:
			img_dusk.save_png("production/qa/evidence/2026-09-07-latest-review/phase-outing-dusk.png")
			_saved_images["dusk"] = img_dusk
			print("SAVED phase-outing-dusk.png")

		# Transition to SERVICE (Night)
		_main._on_community_action("return_to_gym", {})

	elif _step == 15:
		# Advance slightly into SERVICE
		for i in 800:
			_main._orch.time_system.process(0.1)
		_main._world_canvas.queue_redraw()
		if _main._lighting != null:
			_main._lighting.queue_redraw()

	elif _step == 20:
		# 3. Capture SERVICE (Night) before renovation
		var img_service := get_viewport().get_texture().get_image()
		if img_service != null:
			img_service.save_png("production/qa/evidence/2026-09-07-latest-review/phase-service-night.png")
			img_service.save_png("production/qa/evidence/2026-09-07-latest-review/renovate-before.png")
			_saved_images["service"] = img_service
			print("SAVED phase-service-night.png & renovate-before.png")

		# Advance to CLOSE
		if _main._day_cycle != null:
			_main._day_cycle._change_phase("CLOSE")
		_main._world_canvas.queue_redraw()
		if _main._lighting != null:
			_main._lighting.queue_redraw()

	elif _step == 25:
		# 4. Capture CLOSE (打烊)
		var img_close := get_viewport().get_texture().get_image()
		if img_close != null:
			img_close.save_png("production/qa/evidence/2026-09-07-latest-review/phase-close-night.png")
			_saved_images["close"] = img_close
			print("SAVED phase-close-night.png")

		# Now test Renovation (Day 2+ with gym_renovated event)
		if _main._day_cycle != null:
			if not _main._day_cycle._state.events.has("gym_renovated"):
				_main._day_cycle._state.events.append("gym_renovated")
			_main._day_cycle.phase = "SERVICE"
		_main._world_canvas.queue_redraw()
		if _main._lighting != null:
			_main._lighting.queue_redraw()

	elif _step == 30:
		# 5. Capture After Renovation (Neon sign, tablet, plaque, brass trim)
		var img_renovated := get_viewport().get_texture().get_image()
		if img_renovated != null:
			img_renovated.save_png("production/qa/evidence/2026-09-07-latest-review/renovate-after.png")
			print("SAVED renovate-after.png")

		# 6. Capture Unlit Assets (hide LightingLayer)
		if _main._lighting != null:
			_main._lighting.visible = false
		_main._world_canvas.queue_redraw()

	elif _step == 35:
		var img_unlit := get_viewport().get_texture().get_image()
		if img_unlit != null:
			img_unlit.save_png("production/qa/evidence/2026-09-07-latest-review/unlit-asset-composite.png")
			print("SAVED unlit-asset-composite.png")

		# Generate side-by-side renovation compare
		_generate_renovation_compare()

		# Reset profile
		Proj2D.enable_shallow_profile(false)
		var save_p := OS.get_user_data_dir().path_join("saves/test-step-c-capture.sav.json")
		if FileAccess.file_exists(save_p):
			DirAccess.remove_absolute(save_p)
		get_tree().quit(0)

func _generate_renovation_compare() -> void:
	var path_before := "production/qa/evidence/2026-09-07-latest-review/renovate-before.png"
	var path_after := "production/qa/evidence/2026-09-07-latest-review/renovate-after.png"
	var img_a := Image.new()
	var img_b := Image.new()
	if img_a.load(path_before) == OK and img_b.load(path_after) == OK:
		img_a.convert(Image.FORMAT_RGBA8)
		img_b.convert(Image.FORMAT_RGBA8)
		var w := img_a.get_width()
		var h := img_a.get_height()
		var comp := Image.create(w, h, false, Image.FORMAT_RGBA8)
		var half_w := w / 2
		comp.blit_rect(img_a, Rect2i(0, 0, half_w, h), Vector2i(0, 0))
		comp.blit_rect(img_b, Rect2i(half_w, 0, half_w, h), Vector2i(half_w, 0))
		for y in h:
			comp.set_pixel(half_w - 1, y, Color(0.86, 0.66, 0.24, 1.0))
			comp.set_pixel(half_w, y, Color(0.86, 0.66, 0.24, 1.0))
		comp.save_png("production/qa/evidence/2026-09-07-latest-review/renovation-before-after.png")
		print("SAVED renovation-before-after.png!")
