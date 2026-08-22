# tests/evidence/tile_clean_capture.gd
#
# Floor/wall tile assetization visual evidence. Captures the same deterministic
# populated gym before and after the pipeline change. Pass `before` or `after`
# after Godot's `--` separator to select the output name.
#
# Run:
#   godot --path . res://tests/evidence/tile_clean_capture.tscn -- before
extends Node

const MAIN_SCENE := preload("res://src/main.tscn")
const CAPTURE_FRAME := 48

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
	if _frame >= CAPTURE_FRAME:
		_captured = true
		var image := get_viewport().get_texture().get_image()
		if image == null:
			push_error("tile clean capture: viewport image is null")
			get_tree().quit(1)
			return
		var path := "res://tests/evidence/tile-clean-%s.png" % _label
		var err := image.save_png(ProjectSettings.globalize_path(path))
		if err != OK:
			push_error("tile clean capture: failed to save %s" % path)
		elif _label == "after":
			_save_comparison(image)
		get_tree().quit(0 if err == OK else 1)


## Left = before, right = after. Kept label-free so the captured pixels remain
## untouched; ordering is documented here and in the final evidence report.
func _save_comparison(after: Image) -> void:
	var before := Image.new()
	if before.load("res://tests/evidence/tile-clean-before.png") != OK:
		push_warning("tile clean capture: before frame missing; comparison skipped")
		return
	if before.get_size() != after.get_size():
		push_warning("tile clean capture: frame sizes differ; comparison skipped")
		return
	before.convert(Image.FORMAT_RGBA8)
	after.convert(Image.FORMAT_RGBA8)
	var compare := Image.create(after.get_width() * 2, after.get_height(), false,
		Image.FORMAT_RGBA8)
	compare.blit_rect(before, Rect2i(Vector2i.ZERO, before.get_size()), Vector2i.ZERO)
	compare.blit_rect(after, Rect2i(Vector2i.ZERO, after.get_size()),
		Vector2i(after.get_width(), 0))
	var output := "res://tests/evidence/tile-clean-compare.png"
	if compare.save_png(ProjectSettings.globalize_path(output)) != OK:
		push_warning("tile clean capture: failed to save comparison")


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
