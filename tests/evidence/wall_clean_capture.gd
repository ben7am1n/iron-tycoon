# tests/evidence/wall_clean_capture.gd
#
# Wall-tone and decor-density visual evidence. Captures one deterministic
# populated gym frame before/after the wall cleanup and writes a close-up plus
# a left-before/right-after comparison after the final capture.
#
# Run:
#   godot --path . res://tests/evidence/wall_clean_capture.tscn -- before
extends Node

const MAIN_SCENE := preload("res://src/main.tscn")
const CAPTURE_FRAME := 48
const WALL_CROP := Rect2i(96, 48, 960, 192)

var _frame := 0
var _captured := false
var _main: Node = null
var _label := "after"


func _ready() -> void:
	var args := OS.get_cmdline_user_args()
	if not args.is_empty() and str(args[0]) in ["before", "after"]:
		_label = str(args[0])
	_main = MAIN_SCENE.instantiate()
	add_child(_main)
	var orch = _main.get("_orch")
	if orch != null and orch.time_system != null:
		orch.time_system.pause()
	_place_preset_equipment(orch)
	_force_redraw()


func _process(_delta: float) -> void:
	_frame += 1
	if _captured:
		return
	if _frame == 12 or _frame == 30:
		_force_redraw()
	if _frame < CAPTURE_FRAME:
		return
	_captured = true
	var image := get_viewport().get_texture().get_image()
	if image == null:
		push_error("wall clean capture: viewport image is null")
		get_tree().quit(1)
		return
	var path := "res://tests/evidence/wall-clean-%s.png" % _label
	var err := image.save_png(ProjectSettings.globalize_path(path))
	if err == OK:
		_save_wall_crop(image, _label)
		if _label == "after":
			_save_comparison(image)
	else:
		push_error("wall clean capture: failed to save %s" % path)
	get_tree().quit(0 if err == OK else 1)


func _save_wall_crop(image: Image, label: String) -> void:
	var crop_rect := WALL_CROP.intersection(Rect2i(Vector2i.ZERO, image.get_size()))
	var crop := image.get_region(crop_rect)
	var output := "res://tests/evidence/wall-clean-%s-closeup.png" % label
	if crop.save_png(ProjectSettings.globalize_path(output)) != OK:
		push_warning("wall clean capture: failed to save close-up")


func _save_comparison(after: Image) -> void:
	var before := Image.new()
	if before.load("res://tests/evidence/wall-clean-before.png") != OK:
		push_warning("wall clean capture: before frame missing; comparison skipped")
		return
	if before.get_size() != after.get_size():
		push_warning("wall clean capture: frame sizes differ; comparison skipped")
		return
	before.convert(Image.FORMAT_RGBA8)
	after.convert(Image.FORMAT_RGBA8)
	var before_crop := before.get_region(WALL_CROP)
	var after_crop := after.get_region(WALL_CROP)
	var compare := Image.create(WALL_CROP.size.x * 2, WALL_CROP.size.y, false,
		Image.FORMAT_RGBA8)
	compare.blit_rect(before_crop, Rect2i(Vector2i.ZERO, WALL_CROP.size), Vector2i.ZERO)
	compare.blit_rect(after_crop, Rect2i(Vector2i.ZERO, WALL_CROP.size),
		Vector2i(WALL_CROP.size.x, 0))
	var output := "res://tests/evidence/wall-clean-compare.png"
	if compare.save_png(ProjectSettings.globalize_path(output)) != OK:
		push_warning("wall clean capture: failed to save comparison")


func _place_preset_equipment(orch) -> void:
	if orch == null or orch.placement_system == null or orch.grid_system == null:
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


func _force_redraw() -> void:
	for path in [
		"WorldViewport/WorldRoot/WorldCanvas",
		"WorldViewport/WorldRoot/LightingLayer",
		"WorldViewport/WorldRoot/AmbientFx",
	]:
		var item := _main.get_node_or_null(path)
		if item != null:
			item.queue_redraw()
	_main.queue_redraw()
