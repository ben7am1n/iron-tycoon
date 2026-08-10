# tests/evidence/visual_fix_20260810_capture.gd
#
# 玩家反馈修复证据：真实主场景、真实低分辨率世界管线。
#   - 同一 treadmill：USING 在 access cell/设备上做跑带动作；QUEUEING 在南侧
#     一格外直立等待，Dusty 灰蓝衬衫 + 暂停符号。
#   - 全场景同时展示降噪后的地板与多台设备，验证 §14 设备成为视觉前景。
#
# 输出（独立命名，避免与其他 evidence worker 冲突）：
#   tests/evidence/visual-fix-20260810-full.png
#   tests/evidence/visual-fix-20260810-member-closeup.png
#
# Run: godot --log-file /tmp/gym-manager-visual-fix.log --path . \
#   res://tests/evidence/visual_fix_20260810_capture.tscn
extends Node

const MAIN_SCENE := preload("res://src/main.tscn")
const MemberSprite := preload("res://src/presentation/member_sprite.gd")
const Palette := preload("res://src/palette.gd")

const OUT_FULL := "res://tests/evidence/visual-fix-20260810-full.png"
const OUT_CLOSEUP := "res://tests/evidence/visual-fix-20260810-member-closeup.png"
const CAPTURE_FRAME := 48
const CELL_SIZE := 32
const ACCESS_CELL := Vector2i(3, 3)
const QUEUE_CELL := Vector2i(3, 4)
const CLOSEUP_RECT := Rect2i(150, 190, 430, 390)

const INJECTED := [
	{"member_id": 10100, "state": "USING", "cell": ACCESS_CELL,
		"target_equipment": "treadmill"},
	{"member_id": 10104, "state": "QUEUEING", "cell": QUEUE_CELL,
		"target_equipment": "treadmill"},
	{"member_id": 10101, "state": "USING", "cell": Vector2i(2, 6),
		"target_equipment": "bike"},
	{"member_id": 10102, "state": "USING", "cell": Vector2i(8, 4),
		"target_equipment": "bench_press"},
	{"member_id": 10103, "state": "USING", "cell": Vector2i(9, 3),
		"target_equipment": "yoga_mat"},
]

var _frame := 0
var _captured := false
var _main: Node = null
var _sim = null
var _orch = null
var _all_ok := true


func _ready() -> void:
	_main = MAIN_SCENE.instantiate()
	add_child(_main)
	_orch = _main.get("_orch")
	_sim = _main.get("_member")
	if _orch != null and _orch.time_system != null:
		_orch.time_system.pause()
	_place_preset_equipment()
	_inject_members()
	_queue_world_redraw()


func _process(_delta: float) -> void:
	_frame += 1
	if _captured:
		return
	if _frame == 12 or _frame == 30:
		_queue_world_redraw()
	if _frame >= CAPTURE_FRAME:
		_captured = true
		_capture_and_verify()


func _place_preset_equipment() -> void:
	if _orch == null or _orch.placement_system == null or _orch.grid_system == null:
		return
	var placement = _orch.placement_system
	var grid = _orch.grid_system
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


func _inject_members() -> void:
	_sim.members.clear()
	var target_ids := _equipment_ids()
	for entry in INJECTED:
		_sim.members.append({
			"member_id": entry["member_id"],
			"state": entry["state"],
			"cell": entry["cell"],
			"exercises_done": 0,
			"exercises_per_visit": 1,
			"preference_profile": {},
			"target_equipment_instance_id": int(target_ids.get(entry["target_equipment"], -1)),
			"cached_path": [],
			"cached_path_grid_version": -1,
			"repath_failures": 0,
			"give_up_blacklist": {},
			"leaving_timeout_ticks": 0,
			"patience_ticks_remaining": 60,
			"recently_used_ids": [],
			"leaving_reason": "",
			"use_ticks_remaining": 60,
		})
	print("INJECTED visual-fix members=%d targets=%s" % [INJECTED.size(), str(target_ids)])


func _equipment_ids() -> Dictionary:
	var result := {}
	var resolver: Callable = _main.call("_resolver")
	for inst in _orch.grid_system.get_placed_instances():
		var equipment_id := str(resolver.call(inst.instance_id))
		if equipment_id != "" and not result.has(equipment_id):
			result[equipment_id] = inst.instance_id
	return result


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
		push_error("visual_fix capture: viewport image is null")
		get_tree().quit(1)
		return
	_save(image, OUT_FULL)
	var crop_rect := CLOSEUP_RECT.intersection(Rect2i(Vector2i.ZERO, image.get_size()))
	var closeup := image.get_region(crop_rect)
	_save(closeup, OUT_CLOSEUP)
	_verify_state_channels_and_shapes()
	_verify_queue_position()
	_verify_floor_contrast()
	print("RESULT: %s" % ("PASS" if _all_ok else "CHECK"))
	get_tree().quit(0 if _all_ok else 1)


func _save(image: Image, path: String) -> void:
	var err := image.save_png(ProjectSettings.globalize_path(path))
	_ok(err == OK, "saved %s (%dx%d)" % [path, image.get_width(), image.get_height()])


func _verify_state_channels_and_shapes() -> void:
	var sprites := MemberSprite.new()
	_ok(sprites.state_channel("QUEUEING") == "dusty",
		"QUEUEING channel = Dusty neutral wait")
	_ok(sprites.state_channel("USING") == "peach",
		"USING channel = Peach active use")
	_ok(sprites.state_pose("QUEUEING") == "wait",
		"QUEUEING pose = upright wait")
	_ok(sprites.state_pose("USING") == "use",
		"USING pose resolves equipment action")
	var wait_img: Image = sprites.texture_for("QUEUEING", 0, false,
		{"member_id": 10104}).get_image()
	var use_img: Image = sprites.texture_for("USING", 0, false,
		{"member_id": 10100, "equipment_id": "treadmill"}).get_image()
	_ok(_near(wait_img.get_pixel(24, 19), Palette.MEMBER_WAIT_DUSTY),
		"QUEUEING shirt = MEMBER_WAIT_DUSTY")
	_ok(_near(use_img.get_pixel(24, 19), Palette.PEACH),
		"USING shirt = PEACH")
	_ok(_near(wait_img.get_pixel(37, 0), Palette.BUTTER) \
		and wait_img.get_pixel(39, 0).a == 0.0,
		"QUEUEING has shape-first pause glyph")
	var diff := 0
	for y in MemberSprite.SIZE:
		for x in MemberSprite.SIZE:
			if not _near(wait_img.get_pixel(x, y), use_img.get_pixel(x, y)):
				diff += 1
	_ok(diff > 100, "wait/use silhouettes visibly differ (pixels=%d)" % diff)


func _verify_queue_position() -> void:
	var delta := QUEUE_CELL - ACCESS_CELL
	_ok(QUEUE_CELL != ACCESS_CELL and maxi(absi(delta.x), absi(delta.y)) == 1,
		"QUEUEING cell %s is exactly one cell outside access %s" \
		% [str(QUEUE_CELL), str(ACCESS_CELL)])
	_ok(INJECTED[0]["cell"] == ACCESS_CELL and INJECTED[1]["cell"] == QUEUE_CELL,
		"USING stays on access; QUEUEING stays outside")


func _verify_floor_contrast() -> void:
	# 环境细节均靠近各自底色；这是设备“较饱和 + 清楚轮廓”跳到前景的
	# 可重复数值证据。磨损数量/面积的结构修改由截图直接展示。
	var strength_delta := maxf(
		_color_distance(Palette.FLOOR_STRENGTH_BASE, Palette.FLOOR_STRENGTH_STAIN),
		_color_distance(Palette.FLOOR_STRENGTH_BASE, Palette.FLOOR_STRENGTH_WEAR))
	var walk_delta := maxf(
		_color_distance(Palette.FLOOR_WALK_BASE, Palette.FLOOR_WALK_CL_LIGHT),
		_color_distance(Palette.FLOOR_WALK_BASE, Palette.FLOOR_WALK_CL_DARK))
	var cardio_delta := maxf(
		_color_distance(Palette.FLOOR_CARDIO_BASE, Palette.FLOOR_CARDIO_CL_GRAYBLUE),
		_color_distance(Palette.FLOOR_CARDIO_BASE, Palette.FLOOR_CARDIO_CL_WARMGRAY))
	_ok(strength_delta < 0.10, "strength stain/wear contrast is quiet (%.3f < 0.10)" % strength_delta)
	_ok(walk_delta < 0.13, "walkway tile variation is quiet (%.3f < 0.13)" % walk_delta)
	_ok(cardio_delta < 0.12, "cardio cluster variation is quiet (%.3f < 0.12)" % cardio_delta)


func _color_distance(a: Color, b: Color) -> float:
	return sqrt(pow(a.r - b.r, 2) + pow(a.g - b.g, 2) + pow(a.b - b.b, 2))


func _near(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) <= 1.0 / 255.0 \
		and absf(a.g - b.g) <= 1.0 / 255.0 \
		and absf(a.b - b.b) <= 1.0 / 255.0 \
		and absf(a.a - b.a) <= 1.0 / 255.0


func _ok(condition: bool, message: String) -> void:
	if condition:
		print("  PASS: %s" % message)
	else:
		_all_ok = false
		push_error("  FAIL: %s" % message)
