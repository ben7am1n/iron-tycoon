extends Node

const Main := preload("res://src/main.gd")
const Proj2D := preload("res://src/presentation/oblique_projection.gd")

var _main: Main = null
var _step := 0

func _ready() -> void:
	_main = Main.new()
	_main.set_community_mode(true)
	_main._save_name = "test-step-b-capture"
	add_child(_main)
	_main._save_name = "test-step-b-capture"

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
		# Set coach guidance pose
		if _main._day_cycle != null:
			_main._day_cycle._state.request = {"status": "waiting", "equipment_id": "treadmill", "member_id": 0}
		if _main._coach_layer != null:
			_main._coach_layer.update_state()
			_main._coach_layer.queue_redraw()
		if _main._world_canvas != null:
			_main._world_canvas.queue_redraw()
	elif _step == 20:
		var img := get_viewport().get_texture().get_image()
		if img != null:
			img.save_png("production/qa/evidence/2026-09-07-latest-review/test-step-b-characters.png")
			print("SAVED test-step-b-characters.png!")
		
		# Reset profile
		Proj2D.enable_shallow_profile(false)
		var save_p := OS.get_user_data_dir().path_join("saves/test-step-b-capture.sav.json")
		if FileAccess.file_exists(save_p):
			DirAccess.remove_absolute(save_p)
		get_tree().quit(0)
