# tests/evidence/lamp_fix_capture.gd
# 吊灯悬吊空间感修复证据：真实 main 场景 + 真实 2.5D/低分辨率渲染管线。
# 输出：lamp-fix-full.png / lamp-fix-closeup.png。
extends Node

const MAIN_SCENE := preload("res://src/main.tscn")
const Main := preload("res://src/main.gd")
const Proj2D := preload("res://src/presentation/oblique_projection.gd")
const WorldLayout := preload("res://src/presentation/world_layout.gd")

const OUT_FULL := "res://tests/evidence/lamp-fix-full.png"
const OUT_CLOSEUP := "res://tests/evidence/lamp-fix-closeup.png"
const CLOSEUP_RECT := Rect2i(110, 24, 1060, 230)
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
	_queue_world_redraw()


func _process(_delta: float) -> void:
	_frame += 1
	if _frame == 12 or _frame == 30:
		_queue_world_redraw()
	if _frame < CAPTURE_FRAME:
		return
	set_process(false)
	_capture_and_verify()


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
		push_error("lamp_fix_capture: viewport image is null")
		get_tree().quit(1)
		return
	_save(image, OUT_FULL)
	var crop := CLOSEUP_RECT.intersection(Rect2i(Vector2i.ZERO, image.get_size()))
	_save(image.get_region(crop), OUT_CLOSEUP)
	_verify_layout()
	_verify_fixture_visibility(image)
	print("RESULT: %s" % ("PASS" if _all_ok else "CHECK"))
	get_tree().quit(0 if _all_ok else 1)


func _save(image: Image, path: String) -> void:
	var err := image.save_png(ProjectSettings.globalize_path(path))
	_ok(err == OK, "saved %s (%dx%d)" % [path, image.get_width(), image.get_height()])


func _verify_layout() -> void:
	var centers: Array[float] = []
	for light: Dictionary in WorldLayout.HANGING_LIGHTS:
		var rect: Rect2i = light.get("rect", Rect2i())
		centers.append(float(rect.position.x) + float(rect.size.x) * 0.5)
		_ok(rect.position.y >= 18,
			"%s fixture is forward of north-wall plane" % str(light.get("id", "")))
	_ok(is_equal_approx(centers[1] - centers[0], centers[2] - centers[1]),
		"lamp spacing is uniform (%.0f / %.0f world px)" % [
			centers[1] - centers[0], centers[2] - centers[1]])


func _verify_fixture_visibility(image: Image) -> void:
	for i in WorldLayout.HANGING_LIGHTS.size():
		var light: Dictionary = WorldLayout.HANGING_LIGHTS[i]
		var rect: Rect2i = light.get("rect", Rect2i())
		var top_canvas := Proj2D.proj(rect.position.x, rect.position.y,
			float(light.get("height", 0.0)))
		var top_screen := _canvas_to_screen(top_canvas + Vector2(14, 1))
		var bulb_screen := _canvas_to_screen(top_canvas
			+ (light.get("bulb_local", Vector2.ZERO) as Vector2))
		_ok(_dark_pixels_near(image, top_screen, 11) >= 8,
			"lamp %d suspension/mount visible" % (i + 1))
		_ok(_warm_pixels_near(image, bulb_screen, 16) >= 12,
			"lamp %d warm shade/core glow visible" % (i + 1))


func _canvas_to_screen(canvas: Vector2) -> Vector2i:
	var viewport := canvas * Main.WORLD_SCALE + Main.WORLD_VIEWPORT_OFFSET
	return Vector2i(roundi(viewport.x * Main.SCREEN_PER_VIEWPORT_X),
		roundi(viewport.y * Main.SCREEN_PER_VIEWPORT_Y))


func _dark_pixels_near(image: Image, center: Vector2i, radius: int) -> int:
	var count := 0
	for y in range(maxi(center.y - radius, 0), mini(center.y + radius + 1, image.get_height())):
		for x in range(maxi(center.x - radius, 0), mini(center.x + radius + 1, image.get_width())):
			var c := image.get_pixel(x, y)
			if c.get_luminance() < 0.34 and absf(c.r - c.b) < 0.18:
				count += 1
	return count


func _warm_pixels_near(image: Image, center: Vector2i, radius: int) -> int:
	var count := 0
	for y in range(maxi(center.y - radius, 0), mini(center.y + radius + 1, image.get_height())):
		for x in range(maxi(center.x - radius, 0), mini(center.x + radius + 1, image.get_width())):
			var c := image.get_pixel(x, y)
			if c.r > c.b + 0.08 and c.r > c.g and c.get_luminance() > 0.48:
				count += 1
	return count


func _ok(condition: bool, message: String) -> void:
	if condition:
		print("  PASS: " + message)
	else:
		_all_ok = false
		push_error("  FAIL: " + message)
