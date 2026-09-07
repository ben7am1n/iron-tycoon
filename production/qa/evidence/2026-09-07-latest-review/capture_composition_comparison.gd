extends Node

const Main := preload("res://src/main.gd")
const Proj2D := preload("res://src/presentation/oblique_projection.gd")

var _main: Main = null
var _step := 0

func _ready() -> void:
	_main = Main.new()
	_main.set_community_mode(true)
	_main._save_name = "test-comp-capture"
	add_child(_main)
	_main._save_name = "test-comp-capture"

func _process(_delta: float) -> void:
	_step += 1
	if _step == 5:
		_main._on_community_action("depart", {})
	elif _step == 10:
		_main._on_community_action("return_to_gym", {})
	elif _step == 15:
		for i in 1900:
			_main._orch.time_system.process(0.1)
	elif _step == 20:
		# Capture View A: Current 50 deg steep oblique
		var img_a := get_viewport().get_texture().get_image()
		if img_a != null:
			img_a.save_png("production/qa/evidence/2026-09-07-latest-review/comp-current-50deg.png")
			print("SAVED comp-current-50deg.png!")
		
		# Now switch to Shallow Oblique Profile
		Proj2D.enable_shallow_profile(true)
		if _main._world_root != null:
			_main._world_root.position = Proj2D.viewport_offset(Vector2(Main.WORLD_VIEWPORT_W, Main.WORLD_VIEWPORT_H), Main.WORLD_SCALE)
		_main._world_canvas.queue_redraw()
		if _main._lighting != null:
			_main._lighting.queue_redraw()
		if _main._coach_layer != null:
			_main._coach_layer.queue_redraw()
	elif _step == 25:
		# Capture View B: Shallow 32 deg oblique (emphasizing upright character and tight diorama)
		var img_b := get_viewport().get_texture().get_image()
		if img_b != null:
			img_b.save_png("production/qa/evidence/2026-09-07-latest-review/comp-shallow-32deg.png")
			print("SAVED comp-shallow-32deg.png!")
		
		# Generate side-by-side composite
		_generate_side_by_side()

		# Reset profile back to standard
		Proj2D.enable_shallow_profile(false)

		var save_p := OS.get_user_data_dir().path_join("saves/test-comp-capture.sav.json")
		if FileAccess.file_exists(save_p):
			DirAccess.remove_absolute(save_p)
		get_tree().quit(0)

func _generate_side_by_side() -> void:
	var path_a := "production/qa/evidence/2026-09-07-latest-review/comp-current-50deg.png"
	var path_b := "production/qa/evidence/2026-09-07-latest-review/comp-shallow-32deg.png"
	var img_a := Image.new()
	var img_b := Image.new()
	if img_a.load(path_a) == OK and img_b.load(path_b) == OK:
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
		comp.save_png("production/qa/evidence/2026-09-07-latest-review/comp-side-by-side.png")
		print("SAVED comp-side-by-side.png!")
