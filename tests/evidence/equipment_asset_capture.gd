# tests/evidence/equipment_asset_capture.gd — 方案 C 精绘设备游戏内渲染证据
#
# 渲染真实 main.tscn / 426×240 SubViewport 管线，补齐四类预置设备后保存全帧。
# 用法：godot --path . res://tests/evidence/equipment_asset_capture.tscn
extends Node

const MAIN_SCENE := preload("res://src/main.tscn")
const OUT_PATH := "res://tests/evidence/equipment-asset-game.png"
const CAPTURE_FRAME := 20

var _frame := 0
var _main: Node = null


func _ready() -> void:
	_main = MAIN_SCENE.instantiate()
	add_child(_main)
	_place_preset_equipment()


func _place_preset_equipment() -> void:
	var orch = _main.get("_orch")
	if orch == null or orch.placement_system == null or orch.grid_system == null:
		push_error("equipment_asset_capture: gameplay systems unavailable")
		get_tree().quit(1)
		return
	var placement = orch.placement_system
	var grid = orch.grid_system
	var layout := [
		["treadmill", Vector2i(2, 2)],
		["bike", Vector2i(2, 5)],
		["treadmill", Vector2i(6, 3)],
		["bench_press", Vector2i(1, 7)],
		["yoga_mat", Vector2i(9, 2)],
	]
	var occupied := {}
	for inst in grid.get_placed_instances():
		for cell in inst.footprint_cells:
			occupied[cell] = true
	for entry in layout:
		if occupied.has(entry[1]):
			continue
		placement.begin_drag(entry[0])
		placement.on_mouse_moved(entry[1])
		placement.on_drop()


func _process(_delta: float) -> void:
	_frame += 1
	if _frame != CAPTURE_FRAME:
		return
	var equip_art = _main.get("_equip_art")
	for eq_id in ["treadmill", "bike", "bench_press", "yoga_mat"]:
		if equip_art == null or not equip_art.is_using_asset(eq_id):
			push_error("equipment_asset_capture: '%s' is not using PNG asset" % eq_id)
			get_tree().quit(1)
			return
	var img := get_viewport().get_texture().get_image()
	if img == null:
		push_error("equipment_asset_capture: viewport image unavailable")
		get_tree().quit(1)
		return
	var err := img.save_png(ProjectSettings.globalize_path(OUT_PATH))
	if err != OK:
		push_error("equipment_asset_capture: save failed (%d)" % err)
		get_tree().quit(1)
		return
	var draw_calls := Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	print("CAPTURE saved=%s size=%dx%d" % [OUT_PATH, img.get_width(), img.get_height()])
	print("PERF draw_calls=%d budget_ok=%s" % [draw_calls, str(draw_calls < 200)])
	get_tree().quit(0 if draw_calls < 200 else 1)
