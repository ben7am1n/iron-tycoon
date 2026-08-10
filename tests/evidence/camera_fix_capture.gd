# tests/evidence/camera_fix_capture.gd
# 玩家视角修复证据：真实 main 场景 + V3 §2 低分辨率世界管线。
# 输出：camera-fix-full.png / camera-fix-center.png。
extends Node

const MAIN_SCENE := preload("res://src/main.tscn")
const Main := preload("res://src/main.gd")
const Proj2D := preload("res://src/presentation/oblique_projection.gd")

const OUT_FULL := "res://tests/evidence/camera-fix-full.png"
const OUT_CENTER := "res://tests/evidence/camera-fix-center.png"
const CENTER_CROP := Rect2i(160, 100, 960, 540)
const CAPTURE_FRAME := 48

var _main: Node = null
var _frame := 0
var _all_ok := true


func _ready() -> void:
	_main = MAIN_SCENE.instantiate()
	add_child(_main)
	var orch = _main.get("_orch")
	if orch != null and orch.time_system != null:
		orch.time_system.pause()
	_place_readability_layout(orch)
	_queue_world_redraw()


func _process(_delta: float) -> void:
	_frame += 1
	if _frame == 12 or _frame == 30:
		_queue_world_redraw()
	if _frame < CAPTURE_FRAME:
		return
	set_process(false)
	_capture_and_verify()


func _place_readability_layout(orch) -> void:
	if orch == null or orch.placement_system == null or orch.grid_system == null:
		return
	var occupied := {}
	for inst in orch.grid_system.get_placed_instances():
		for cell in inst.footprint_cells:
			occupied[cell] = true
	var layout := [
		["treadmill", Vector2i(2, 2)],
		["bike", Vector2i(2, 5)],
		["treadmill", Vector2i(6, 3)],
		["bench_press", Vector2i(1, 7)],
		["yoga_mat", Vector2i(9, 2)],
	]
	for entry in layout:
		if occupied.has(entry[1]):
			continue
		orch.placement_system.begin_drag(entry[0])
		orch.placement_system.on_mouse_moved(entry[1])
		orch.placement_system.on_drop()


func _queue_world_redraw() -> void:
	for path in [
		"WorldViewport/WorldRoot/WorldCanvas",
		"WorldViewport/WorldRoot/LightingLayer",
		"WorldViewport/WorldRoot/AmbientFx",
	]:
		var item := _main.get_node_or_null(path)
		if item != null:
			item.queue_redraw()
	_main.queue_redraw()


func _capture_and_verify() -> void:
	var image := get_viewport().get_texture().get_image()
	if image == null:
		push_error("camera_fix_capture: viewport image is null")
		get_tree().quit(1)
		return
	_save(image, OUT_FULL)
	var crop := CENTER_CROP.intersection(Rect2i(Vector2i.ZERO, image.get_size()))
	_save(image.get_region(crop), OUT_CENTER)
	_verify_projection_contract()
	_verify_frame_readability(image)
	print("RESULT: %s" % ("PASS" if _all_ok else "CHECK"))
	get_tree().quit(0 if _all_ok else 1)


func _save(image: Image, path: String) -> void:
	var err := image.save_png(ProjectSettings.globalize_path(path))
	_ok(err == OK, "saved %s (%dx%d)" % [path, image.get_width(), image.get_height()])


func _verify_projection_contract() -> void:
	var floor_depth := Proj2D.WORLD_H * Proj2D.FLOOR_SCALE
	var wall_height := Proj2D.WALL_HEIGHT * Proj2D.HEIGHT_SCALE
	_ok(Proj2D.TILT_DEG >= 48.0 and Proj2D.FLOOR_SCALE >= 0.75,
		"center uses readability-first top-down projection")
	_ok(wall_height / floor_depth < 0.20,
		"wall occupies less than 20% of projected floor depth")
	_ok(Proj2D.EXTRUDE_X > 0.0 and Proj2D.HEIGHT_SCALE > 0.0,
		"edge/equipment 2.5D extrusion remains enabled")
	var expected := Proj2D.viewport_offset(
		Vector2(Main.WORLD_VIEWPORT_W, Main.WORLD_VIEWPORT_H), Main.WORLD_SCALE)
	_ok(expected.distance_to(Main.WORLD_VIEWPORT_OFFSET) < 0.001,
		"main viewport offset matches projection bounds")


func _verify_frame_readability(image: Image) -> void:
	var center := _world_to_screen(Vector2(208, 160))
	var edge_projected := Proj2D.PROJECTED_MIN + Vector2(12, 12)
	var edge := _projected_to_screen(edge_projected)
	_ok(_in_bounds(image, center) and _in_bounds(image, edge),
		"center floor and ceiling edge samples are visible")
	if not (_in_bounds(image, center) and _in_bounds(image, edge)):
		return
	var center_color := image.get_pixel(center.x, center.y)
	var edge_color := image.get_pixel(edge.x, edge.y)
	_ok(_color_distance(center_color, edge_color) > 0.08,
		"central floor is visually separated from edge ceiling (%s vs %s)" % [
			center_color.to_html(false), edge_color.to_html(false)])
	# 中央裁区必须有足够明暗变化，防止天花板/单色层意外盖住设备和地板。
	var min_lum := 1.0
	var max_lum := 0.0
	for y in range(180, 620, 20):
		for x in range(260, 1040, 20):
			var c := image.get_pixel(x, y)
			var lum := c.get_luminance()
			min_lum = minf(min_lum, lum)
			max_lum = maxf(max_lum, lum)
	_ok(max_lum - min_lum > 0.30,
		"center crop retains readable floor/equipment contrast (range %.3f)" % (
			max_lum - min_lum))


func _world_to_screen(world: Vector2, height: float = 0.0) -> Vector2i:
	var p := Proj2D.world_to_screen(world, Main.WORLD_VIEWPORT_OFFSET,
		Main.WORLD_SCALE, Vector2(Main.SCREEN_PER_VIEWPORT_X,
			Main.SCREEN_PER_VIEWPORT_Y), height)
	return Vector2i(roundi(p.x), roundi(p.y))


func _projected_to_screen(projected: Vector2) -> Vector2i:
	var viewport := projected * Main.WORLD_SCALE + Main.WORLD_VIEWPORT_OFFSET
	return Vector2i(roundi(viewport.x * Main.SCREEN_PER_VIEWPORT_X),
		roundi(viewport.y * Main.SCREEN_PER_VIEWPORT_Y))


func _in_bounds(image: Image, point: Vector2i) -> bool:
	return point.x >= 0 and point.y >= 0 \
		and point.x < image.get_width() and point.y < image.get_height()


func _color_distance(a: Color, b: Color) -> float:
	return sqrt(pow(a.r - b.r, 2) + pow(a.g - b.g, 2) + pow(a.b - b.b, 2))


func _ok(condition: bool, message: String) -> void:
	if condition:
		print("  PASS: " + message)
	else:
		_all_ok = false
		push_error("  FAIL: " + message)
