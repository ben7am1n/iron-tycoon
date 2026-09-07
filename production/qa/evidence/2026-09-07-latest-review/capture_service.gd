extends Node

const Main := preload("res://src/main.gd")
var _main: Main = null
var _frame := 0

func _ready() -> void:
	_main = Main.new()
	_main.set_community_mode(true)
	_main._save_name = "test-service-capture"
	add_child(_main)
	_main._save_name = "test-service-capture"

func _process(_delta: float) -> void:
	_frame += 1
	if _frame == 5:
		_main._on_community_action("depart", {})
	elif _frame == 10:
		_main._on_community_action("return_to_gym", {})
	elif _frame == 15:
		# Advance to mid-service
		for i in 1900:
			_main._orch.time_system.process(0.1)
	elif _frame == 20:
		var img := get_viewport().get_texture().get_image()
		if img != null:
			img.save_png("production/qa/evidence/2026-09-07-latest-review/test-service.png")
			print("SAVED test-service.png!")
		var save_p := OS.get_user_data_dir().path_join("saves/test-service-capture.sav.json")
		if FileAccess.file_exists(save_p):
			DirAccess.remove_absolute(save_p)
		get_tree().quit(0)
