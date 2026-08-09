# tests/evidence/v31_r2_r2_capture.gd — V3.1 返工2 R2 第二眼证据捕获
#
# 渲染真实主场景（src/main.tscn，V3 §2 SubViewport 低分辨率管线）并保存：
#   1. tests/evidence/v31-r2-r2-sprite.png —— 全场景帧（注入 4 变体会员 +
#      设备上使用会员；V3 §15 第二眼：人物/器械是精心制作的 pixel sprite，
#      非棋子/非贴图）
#   2. tests/evidence/v31-r2-r2-member.png —— 会员带特写（2× 放大，walk
#      摆臂迈步 / queue 擦汗弯腰 / 设备上使用会员 —— 头身比修正、手脚
#      姿态明确、与器械接触点可信）
#   3. tests/evidence/v31-r2-r2-bike.png —— 单车三面体块特写（顶面座垫/
#      飞轮/车把 + 正面车架/链条/飞轮 + 侧面曲柄/踏板，30-45° 斜俯视自洽）
#   4. tests/evidence/v31-r2-r2-treadmill.png —— 跑步机特写（控制台屏幕带
#      内容/发光 + 金属立柱高光 + 跑带纹理 + 急停开关/扶手）
#
# 验收对照（返工2 R2 任务书）：
#   - 人物非「大头+矩形躯干」棋子感：头身比（头 14/48 行 ≈29%）、V 字躯干、
#     手脚姿态明确（摆臂/握杠/踩踏/坐姿）
#   - 单车三面体块稳定：顶面（座垫/车把俯视）+ 正面（车架/链条/飞轮）+
#     侧面（曲柄/踏板）投影遮挡一致
#   - 跑步机控制台屏幕带内容/发光；金属立柱高光；跑带纹理；材质分层
#   - 无「人物像棋子」观感；无「设备像嵌地装饰图」观感
#
# 用法（窗口模式——headless dummy 驱动下 get_image() 返回 null，项目既有
# 证据方法，见 v31_r2_r1_capture.gd 同款注释）：
#   godot --path . res://tests/evidence/v31_r2_r2_capture.tscn
extends Node

const MAIN_SCENE := preload("res://src/main.tscn")
const Main := preload("res://src/main.gd")
const Proj2D := preload("res://src/presentation/oblique_projection.gd")
const Palette := preload("res://src/palette.gd")
const OUT_FULL := "res://tests/evidence/v31-r2-r2-sprite.png"
const OUT_MEMBER := "res://tests/evidence/v31-r2-r2-member.png"
const OUT_BIKE := "res://tests/evidence/v31-r2-r2-bike.png"
const OUT_TREAD := "res://tests/evidence/v31-r2-r2-treadmill.png"
const REDRAW_FRAME := 6
const INJECT_FRAME := 10       # 注入规范会员（冻结模拟）
const CAPTURE_FRAME := 18      # 全场景抓帧（注入后纹理更新）
const CLOSEUP_APPLY_FRAME := 24
const CLOSEUP_REDRAW_FRAME := 26
const CLOSEUP_CAPTURE_FRAME := 32
const CELL_SIZE := 32
const CLOSEUP_SCALE := Vector2(2.0, 2.0)
const CLOSEUP_POS := Vector2(213.0 - 128.0 * 2.0, 120.0 - 128.0 * 2.0)

## 管线常量（来自 main.gd —— 证据复算与实现同源）。
const SX := Main.SCREEN_PER_VIEWPORT_X
const SY := Main.SCREEN_PER_VIEWPORT_Y
const OFF := Main.WORLD_VIEWPORT_OFFSET
const WS := Main.WORLD_SCALE

## 注入会员（确定性；覆盖 4 变体 + 设备使用接触点）。
const INJECTED := [
	{"member_id": 9200, "state": "WALKING_TO", "cell": Vector2i(5, 2)},
	{"member_id": 9201, "state": "WALKING_TO", "cell": Vector2i(11, 2)},
	{"member_id": 9202, "state": "QUEUEING", "cell": Vector2i(3, 6)},
	{"member_id": 9203, "state": "LEAVING", "cell": Vector2i(10, 6), "leaving_reason": "quota_met"},
	{"member_id": 9204, "state": "USING", "cell": Vector2i(3, 3), "target_equipment": "treadmill"},
	{"member_id": 9205, "state": "USING", "cell": Vector2i(2, 6), "target_equipment": "bike"},
]

var _frame := 0
var _injected := false
var _main: Node = null
var _sim = null
var _orch = null
var _world_root: Node2D = null
var _all_ok := true
var _full_img: Image = null


func _ready() -> void:
	_main = MAIN_SCENE.instantiate()
	add_child(_main)
	_sim = _main.get("_member")
	_orch = _main.get("_orch")
	if _orch != null and _orch.time_system != null:
		_orch.time_system.pause()
	_place_preset_equipment()
	_world_root = _main.get_node_or_null("WorldViewport/WorldRoot")
	if _world_root == null:
		push_error("v31_r2_r2_capture: WorldRoot not found")
		get_tree().quit(1)


## 显式放置预置设备（与 v31_r2_r1_capture 同源 —— B2 经济空房开局下保证
## 证据帧包含设备带；treadmill(2,2) / bike(2,5) / treadmill(6,3) /
## bench_press(1,7) / yoga_mat(9,2)）。
func _place_preset_equipment() -> void:
	if _orch == null or _orch.placement_system == null:
		return
	var placement = _orch.placement_system
	var grid = _orch.grid_system
	if grid == null:
		return
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
	if _frame == REDRAW_FRAME:
		_canvas_redraw()
		return
	if _frame == INJECT_FRAME and not _injected:
		_injected = true
		_inject_deterministic()
		return
	if _frame == CAPTURE_FRAME:
		_capture_full()
		return
	if _frame == CLOSEUP_APPLY_FRAME:
		_world_root.scale = CLOSEUP_SCALE
		_world_root.position = CLOSEUP_POS
		_canvas_redraw()
		return
	if _frame == CLOSEUP_REDRAW_FRAME:
		_canvas_redraw()
		return
	if _frame == CLOSEUP_CAPTURE_FRAME:
		_capture_closeup()
		return


func _canvas_redraw() -> void:
	var canvas := _main.get_node_or_null("WorldViewport/WorldRoot/WorldCanvas")
	if canvas != null:
		canvas.queue_redraw()


## 冻结 + 注入规范会员（已知状态/坐标/设备 → 确定性采样）。
func _inject_deterministic() -> void:
	_sim.members.clear()
	var target_ids := _resolve_equipment_instance_ids()
	for entry in INJECTED:
		var m := {
			"member_id": entry["member_id"],
			"state": entry["state"],
			"cell": entry["cell"],
			"exercises_done": 0,
			"exercises_per_visit": 1,
			"preference_profile": {},
			"target_equipment_instance_id": int(target_ids.get(entry.get("target_equipment", ""), -1)),
			"cached_path": [],
			"cached_path_grid_version": -1,
			"repath_failures": 0,
			"give_up_blacklist": {},
			"leaving_timeout_ticks": 0,
			"patience_ticks_remaining": 0,
			"recently_used_ids": [],
			"leaving_reason": entry.get("leaving_reason", ""),
			"use_ticks_remaining": 60,
		}
		_sim.members.append(m)
	_main.queue_redraw()
	print("INJECTED %d canonical members (frozen, tick=0)" % INJECTED.size())


## 初始布局设备 instance_id 解析（与 phase4_capture 同源）。
func _resolve_equipment_instance_ids() -> Dictionary:
	var out := {}
	var resolver: Callable = _main.call("_resolver")
	var instances: Array = _main.get("_grid").get_placed_instances()
	for inst in instances:
		var eq := str(resolver.call(inst.instance_id))
		if eq != "" and not out.has(eq):
			out[eq] = inst.instance_id
	return out


func _grab() -> Image:
	var img := get_viewport().get_texture().get_image()
	if img == null:
		push_error("v31_r2_r2_capture: get_image() returned null (headless dummy driver?)")
		get_tree().quit(1)
	return img


func _save(img: Image, path: String) -> void:
	var err := img.save_png(ProjectSettings.globalize_path(path))
	if err != OK:
		push_error("v31_r2_r2_capture: save_png failed err=%d path=%s" % [err, path])
		get_tree().quit(1)
	print("CAPTURE saved=%s size=%dx%d" % [path, img.get_width(), img.get_height()])


func _capture_full() -> void:
	var img := _grab()
	_full_img = img
	_save(img, OUT_FULL)
	_verify_members_rendered(img)
	_verify_equipment_visible(img)
	print("RESULT: %s" % ("PASS" if _all_ok else "CHECK"))


## 特写：会员带（2× 放大帧）+ 单车/跑步机（从全场景帧裁剪，绕开特写
## 相机的世界偏移 —— 特写帧只聚焦会员带，设备部件在近景裁剪里更清晰）。
func _capture_closeup() -> void:
	var img := _grab()
	_save(img, OUT_MEMBER)
	# 特写 2：单车区 —— 全场景帧中 bike 顶面投影位置（_verify_equipment_visible
	# 已验证 @(376,480) 附近；放大 2× 裁剪更清晰）
	if _full_img != null:
		# 单车 footprint 是 1×1（32 世界 px），屏幕投影约 60-70px —— 用
		# 更大的裁剪半径（160）确保顶面座垫/飞轮/车把 + 正侧面都在框内
		var bike_center := Vector2i(376, 480)
		var bike_crop := _crop_around(_full_img, bike_center, 160)
		if bike_crop != null:
			_save(bike_crop, OUT_BIKE)
			_verify_bike_closeup(bike_crop)
		# 特写 3：跑步机区 —— 全场景帧中 treadmill 顶面投影位置 @(337,346)
		var tm_center := Vector2i(337, 346)
		var tm_crop := _crop_around(_full_img, tm_center, 160)
		if tm_crop != null:
			_save(tm_crop, OUT_TREAD)
			_verify_treadmill_closeup(tm_crop)
	print("RESULT: %s" % ("PASS" if _all_ok else "CHECK"))
	get_tree().quit(0 if _all_ok else 1)


## 特写变换：世界坐标（footprint 平面，z 忽略 —— WorldRoot 直接缩放平移，
## 与 R1 _w2s 同源）→ 特写帧屏幕。
func _w2s(w: Vector2, _z: float = 0.0) -> Vector2i:
	var v := (w + CLOSEUP_POS) * CLOSEUP_SCALE
	v.x *= SX
	v.y *= SY
	return Vector2i(roundi(v.x), roundi(v.y))


## 世界坐标 → 屏幕（与 main.gd 同源复算）。
func _world_to_screen_v(w: Vector2) -> Vector2i:
	var v := Proj2D.world_to_screen(w, OFF, WS, Vector2(SX, SY), 0.0)
	return Vector2i(roundi(v.x), roundi(v.y))


## 以 [center] 为中心裁剪 [radius]×2 方形区域（越界自动 clamp）。
## 注意：全场景帧格式可能是 RGBX/RGB8 —— 统一转 RGBA8 再 blit（4.7.1
## blit_rect 要求同 format，否则返回 FAILED 并留下透明图）。
func _crop_around(img: Image, center: Vector2i, radius: int) -> Image:
	var w := img.get_width()
	var h := img.get_height()
	var x0 := clampi(center.x - radius, 0, w - 1)
	var y0 := clampi(center.y - radius, 0, h - 1)
	var x1 := clampi(center.x + radius, 0, w - 1)
	var y1 := clampi(center.y + radius, 0, h - 1)
	if x1 - x0 <= 0 or y1 - y0 <= 0:
		return null
	var src := img
	if img.get_format() != Image.FORMAT_RGBA8:
		# 4.7.1 Image.convert 是 in-place（void）—— 先拷贝再转格式
		src = img.duplicate()
		src.convert(Image.FORMAT_RGBA8)
	var out := Image.create(x1 - x0, y1 - y0, false, Image.FORMAT_RGBA8)
	out.blit_rect(src, Rect2i(x0, y0, x1 - x0, y1 - y0), Vector2i.ZERO)
	return out


## 全场景帧：注入会员都渲染成功（衬衫色通道；扫描窗口吸收投影偏差）。
func _verify_members_rendered(img: Image) -> void:
	for entry in INJECTED:
		var state: String = entry["state"]
		if state == "USING":
			continue
		var cell: Vector2i = entry["cell"]
		var expect := _channel_of(state)
		var found := false
		for oy in [-40, -16, 8, 32]:
			for ox in [-24, -8, 8, 24]:
				var p := _world_to_screen_v(Vector2(
					cell.x * CELL_SIZE + CELL_SIZE * 0.5 + ox,
					cell.y * CELL_SIZE + CELL_SIZE * 0.5 + oy))
				if p.x < 0 or p.y < 0 or p.x >= img.get_width() or p.y >= img.get_height():
					continue
				var c := img.get_pixel(p.x, p.y)
				if _near(c, expect, 0.20) or _scan_near(img, p, expect, 10) > 0:
					found = true
					break
			if found:
				break
		_ok(found, "STATE %-12s rendered @cell(%d,%d) shirt≈%s" % [
			state, cell.x, cell.y, expect.to_html(false)])


## 全场景帧：设备带可见（顶面主体色命中）。
func _verify_equipment_visible(img: Image) -> void:
	var eqs := [
		["treadmill", Vector2(96, 80), 30.0],
		["bike", Vector2(80, 176), 36.0],
	]
	for entry in eqs:
		var p := _world_to_screen_v(entry[1])
		var found := _scan_equip_tone(img, p, 3)
		_ok(found, "EQ %-10s top @(%3d,%3d) 可见（设备顶面主体色）" % [entry[0], p.x, p.y])


## 单车特写：飞轮金属高光（H / METAL_HIGHLIGHT）+ 座垫区域色（Z）+ 车把
## 显示（青蓝 A）在特写帧内存在 —— 三面体块部件可辨。
## 注意：渲染管线会压暗设备面，青蓝像素与 palette 原色有偏差 —— 显示灯
## 用「青蓝主导」谓词（g>r 且 b>r 且足够亮），与 PIL 采样同义。
func _verify_bike_closeup(img: Image) -> void:
	var has_metal := _image_contains(img, Palette.METAL_HIGHLIGHT, 0.10)
	var has_zone := _image_contains(img, Palette.ZONE_COLORS["cardio"], 0.10)
	var has_cyan := _image_has_cyan(img)
	_ok(has_metal, "BIKE closeup 飞轮金属高光存在（H/METAL_HIGHLIGHT）")
	_ok(has_zone, "BIKE closeup 座垫区域色存在（Z/cardio zone）")
	_ok(has_cyan, "BIKE closeup 车把显示青蓝存在（A 青蓝主导像素）")


## 青蓝主导像素（显示灯）：g > r + 40 且 b > r + 20 且 g > 120。
func _image_has_cyan(img: Image) -> bool:
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			if c.g > c.r + 0.16 and c.b > c.r + 0.08 and c.g > 0.47:
				return true
	return false


## 跑步机特写：控制台屏幕亮色（青蓝 A + 暖高光 W）+ 跑带纹理（METAL_DARK
## M 与 BODY 交替）+ 金属立柱（METAL_HIGHLIGHT H）。
func _verify_treadmill_closeup(img: Image) -> void:
	var has_cyan := _image_contains(img, Palette.EQUIP_ACCENT_CYAN, 0.08)
	var has_warm := _image_contains(img, Palette.EQUIP_HIGHLIGHT, 0.08)
	var has_metal := _image_contains(img, Palette.METAL_DARK, 0.08)
	var has_h := _image_contains(img, Palette.METAL_HIGHLIGHT, 0.08)
	_ok(has_cyan, "TREAD closeup 控制台屏幕青蓝存在（A）")
	_ok(has_warm, "TREAD closeup 屏幕/面板暖高光存在（W）")
	_ok(has_metal, "TREAD closeup 跑带金属暗纹存在（M 纹理）")
	_ok(has_h, "TREAD closeup 金属立柱高光存在（H）")


## ±[radius]px 窗口内是否有设备主体色调。
func _scan_equip_tone(img: Image, center: Vector2i, radius: int) -> bool:
	var tones := [
		Color("5D6673"), Color("49525F"), Color("8E99A6"),
		Color("5B6470"), Color("3A4350"), Color("3B4552"),
		Color("8FBF9F"), Color("8EC5E8"),
	]
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var sx := center.x + dx
			var sy := center.y + dy
			if sx < 0 or sy < 0 or sx >= img.get_width() or sy >= img.get_height():
				continue
			for t in tones:
				if _near(img.get_pixel(sx, sy), t, 0.09):
					return true
	return false


func _channel_of(state: String) -> Color:
	match state:
		"QUEUEING", "USING":
			return Color("F2B486")
		"LEAVING":
			return Color("9A948C")
		_:
			return Color("8EC5E8")


func _near(a: Color, b: Color, tol: float) -> bool:
	return absf(a.r - b.r) < tol and absf(a.g - b.g) < tol and absf(a.b - b.b) < tol


func _scan_near(img: Image, center: Vector2i, target: Color, radius: int) -> int:
	var hits := 0
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var sx := center.x + dx
			var sy := center.y + dy
			if sx < 0 or sy < 0 or sx >= img.get_width() or sy >= img.get_height():
				continue
			if _near(img.get_pixel(sx, sy), target, 0.20):
				hits += 1
	return hits


func _image_contains(img: Image, target: Color, tol: float) -> bool:
	for y in img.get_height():
		for x in img.get_width():
			if _near(img.get_pixel(x, y), target, tol):
				return true
	return false


func _ok(cond: bool, msg: String) -> void:
	if not cond:
		_all_ok = false
	print("  %s %s" % ["PASS" if cond else "FAIL", msg])
