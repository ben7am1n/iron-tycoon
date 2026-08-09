# tests/evidence/v31_gate_populated_capture.gd — V3.1 门禁最终渲染帧捕获
# （populated 变体：与 v31_gate_capture.gd 同构，仅输出文件名不同 —— B2 后
# main 空房开局、模拟默认暂停，populated 语义由预置设备填充场景实现）
#
# 渲染真实主场景（src/main.tscn，V3.1 P1 oblique + P2 设备 + P3 手绘密度 +
# P4 pixel lighting + P5 高饱和焦点全链路）并保存两张视口快照：
#   - tests/evidence/v31-gate-populated.png    全场景（根 viewport 1280×720）
#   - tests/evidence/v31-gate-closeup-populated.png  设备带放大特写（WorldRoot scale 2x 聚焦
#     treadmill/bike 区，WorldCanvas+Lighting 重绘后抓帧）
#
# 内嵌验证：
#   - P5 焦点元素在渲染帧中可寻（红广告牌/黄水杯/瑜伽球/设备屏幕/植物亮叶）
#   - 特写帧设备带存在设备色层（非空）
#   - draw_calls < 200（V3 §15 性能预算）
#
# 用法（窗口模式——headless 下 get_image() 返回 null，4.7.1 已验证）：
#   godot --path . res://tests/evidence/v31_gate_populated_capture.tscn
extends Node

const MAIN_SCENE := preload("res://src/main.tscn")
const Palette := preload("res://src/palette.gd")
const WorldLayout := preload("res://src/presentation/world_layout.gd")
const OUT_FULL := "res://tests/evidence/v31-gate-populated.png"
const OUT_CLOSEUP := "res://tests/evidence/v31-gate-closeup-populated.png"
const REDRAW_FRAME := 6       # 全场景抓帧前强制世界画布重绘（纹理滞后 ≥1 帧）
const CAPTURE_FRAME := 12
const CLOSEUP_APPLY_FRAME := 18   # 切换 WorldRoot 到特写变换
const CLOSEUP_REDRAW_FRAME := 20  # 特写变换后强制重绘
const CLOSEUP_CAPTURE_FRAME := 26

## 特写变换：聚焦世界设备带（treadmill(2,2)(6,3) / bike(2,5) 区域）。
## WorldRoot 默认 scale 0.75、position (19.05, 51.975)；设备带中心约世界 (128,128)。
## scale 2.0 → 世界 (426/2, 240/2)=(213,120) 可见；position 使 (128,128) 居中。
const CLOSEUP_SCALE := Vector2(2.0, 2.0)
const CLOSEUP_FOCUS := Vector2(128, 128)   # 世界坐标焦点
const CLOSEUP_POS := Vector2(213.0 - 128.0 * 2.0, 120.0 - 128.0 * 2.0)  # = (-43, -136)

var _frame := 0
var _captured := false
var _main: Node = null
var _world_root: Node2D = null
var _all_ok := true
var _full_img: Image = null


func _ready() -> void:
	_main = MAIN_SCENE.instantiate()
	add_child(_main)
	# 确保 V3.1 证据场景包含预置设备 —— 不依赖 main.tscn 的初始布局经济默认
	# （B2 经济重平衡把 main 改成空房开局，撤掉预置设备；门禁证据需要
	# treadmill(2,2) 控制台/瑜伽球/卧推等 V3.1 P2-P5 焦点，必须在捕获前显式
	# 放置，否则 treadmill console / CLOSEUP 设备带断言 MISS）。
	_place_preset_equipment()
	# WorldRoot 在主场景 _ready 后构建；帧 1 后即可查询
	_world_root = _main.get_node_or_null("WorldViewport/WorldRoot")
	if _world_root == null:
		push_error("v31_gate_capture: WorldRoot not found")
		get_tree().quit(1)


## 显式放置 V3.1 预置设备（treadmill(2,2)(6,3) / bike(2,5) / bench_press(1,7)
## / yoga_mat(9,2)）—— 与 e682da3 时代 main.gd _initial_layout 一致，保证
## 门禁帧包含 V3.1 全套视觉元素（P2 设备带 + P5 焦点），不受经济系统初始
## 布局（B2 空房）影响。走 PlacementSystem 完整拖放链（同 main.gd
## _drag_drop：begin_drag → on_mouse_moved → on_drop）。
func _place_preset_equipment() -> void:
	var orch = _main.get("_orch")
	if orch == null or orch.placement_system == null:
		return
	var placement = orch.placement_system
	var grid = orch.grid_system
	if grid == null:
		return
	if placement.placement_committed.is_connected(_on_placed) == false:
		placement.placement_committed.connect(_on_placed)
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


func _on_placed(instance_id: int, equipment_id: String, _footprint_cells: Array) -> void:
	pass


func _process(_delta: float) -> void:
	_frame += 1
	if _captured:
		return
	if _frame == REDRAW_FRAME:
		_force_redraw()
		return
	if _frame == CAPTURE_FRAME:
		_full_img = _grab()
		_save(_full_img, OUT_FULL)
		_verify_world_frame(_full_img)
		print("  GATE full-scene captured")
		return
	if _frame == CLOSEUP_APPLY_FRAME:
		# 切换到特写变换：缩放 + 平移 WorldRoot（世界层统一变换，像素语义不变）
		_world_root.scale = CLOSEUP_SCALE
		_world_root.position = CLOSEUP_POS
		_force_redraw()
		return
	if _frame == CLOSEUP_REDRAW_FRAME:
		_force_redraw()
		return
	if _frame == CLOSEUP_CAPTURE_FRAME:
		var closeup := _grab()
		_save(closeup, OUT_CLOSEUP)
		_verify_closeup(closeup)
		_verify_perf()
		print("RESULT: %s" % ("PASS" if _all_ok else "CHECK"))
		get_tree().quit(0 if _all_ok else 1)


func _force_redraw() -> void:
	var canvas := _main.get_node_or_null("WorldViewport/WorldRoot/WorldCanvas")
	if canvas != null:
		canvas.queue_redraw()
	var lighting := _main.get_node_or_null("WorldViewport/WorldRoot/LightingLayer")
	if lighting != null:
		lighting.queue_redraw()
	var fx := _main.get_node_or_null("WorldViewport/WorldRoot/AmbientFx")
	if fx != null:
		fx.queue_redraw()


func _grab() -> Image:
	var img := get_viewport().get_texture().get_image()
	if img == null:
		push_error("v31_gate_capture: get_image() returned null (headless dummy driver?)")
		get_tree().quit(1)
		return null
	return img


func _save(img: Image, out_path: String) -> void:
	var abs_path := ProjectSettings.globalize_path(out_path)
	var err := img.save_png(abs_path)
	if err != OK:
		push_error("v31_gate_capture: save_png failed err=%d path=%s" % [err, abs_path])
		get_tree().quit(1)
		return
	print("CAPTURE saved=%s size=%dx%d" % [out_path, img.get_width(), img.get_height()])


# === 全场景验证（V3.1 P5 焦点元素在渲染帧中可寻） ===

func _verify_world_frame(img: Image) -> void:
	# 红广告牌（WALL_DECOR.ad_red）—— V3.1 P1 迁移：广告牌是北墙墙面装饰，
	# 绘制在墙本地空间（wall-local (164,1) 经 _north_wall_transform 投影），
	# 不再是旧轴对齐贴地坐标 (192,20)。墙本地 → 屏幕 ≈ (398,81)，窗口覆盖
	# 整条横幅（实测 bbox 406..602 x 82..208）。
	var ad_found := _window_contains(img, Vector2(164, 1), 26, Palette.FOCAL_RED, 0.22, true)
	_ok(ad_found, "WORLD red ad board focal red pixels present (红广告牌焦点)")
	# 黄水杯（DECOR cup_yellow_f1 @(88,108) 贴地）
	var cup_found := _window_contains(img, Vector2(88, 108), 20, Palette.ACCENT_YELLOW, 0.22, false)
	_ok(cup_found, "WORLD yellow cup focal yellow pixels present (黄色水杯焦点)")
	# 彩色瑜伽球（DECOR yoga_ball_f1 @(320,136) 贴地；FOCAL_PINK/FOCAL_PURPLE）
	var ball_found := _window_contains(img, Vector2(320, 136), 26, Palette.FOCAL_PINK, 0.22, false) \
		or _window_contains(img, Vector2(320, 136), 26, Palette.FOCAL_PURPLE, 0.22, false)
	_ok(ball_found, "WORLD colorful yoga ball pixels present (彩色瑜伽用品焦点)")
	# treadmill 控制台青蓝屏幕
	var screen_found := _screen_present(img)
	_ok(screen_found, "WORLD treadmill console cyan screen pixels present (设备屏幕焦点)")
	# 植物亮叶
	var plant_found := false
	for prop_id: String in WorldLayout.DECOR:
		if not prop_id.begins_with("plant"):
			continue
		var pos: Vector2i = WorldLayout.DECOR[prop_id]
		if _window_contains(img, Vector2(pos), 26, Palette.PLANT_GREEN_LIGHT, 0.22, false) \
				or _window_contains(img, Vector2(pos), 26, Palette.PLANT_GREEN, 0.18, false):
			plant_found = true
			break
	_ok(plant_found, "WORLD plant bright-leaf green pixels present (绿色植物焦点)")


func _screen_present(img: Image) -> bool:
	# treadmill(2,2) footprint=(64,64,64,32) 顶面 z=30 控制台区域
	# 注意：全场景抓帧时 WorldRoot 未切换特写变换 —— 用 oblique 投影（同 main.gd）
	# V3.1 P1/P2 迁移：控制台在顶面 z=30，A 像素列 9-11 / 16-20（世界 x≈82..86 /
	# 96..104，y≈90..91）—— 采样点与 phase5 证据同源（世界 (84,90)/(86,90)/
	# (98,90)/(100,90)/(84,91) 均在渲染帧命中青蓝）。旧窗口 world (80,92)±3 在
	# oblique 下落在控制台左缘外（暖光叠加区），间歇性 MISS。
	const TM_HEIGHT := 30.0
	for p in [Vector2(84, 90), Vector2(86, 90), Vector2(98, 90), Vector2(100, 90), Vector2(84, 91)]:
		for dy in range(-2, 3):
			for dx in range(-2, 3):
				var sp := _world_to_screen_full_z(p + Vector2(dx, dy), TM_HEIGHT)
				if not _in_bounds(img, sp):
					continue
				var c := img.get_pixel(sp.x, sp.y)
				if _near(c, Palette.EQUIP_ACCENT_CYAN, 0.16) or _near(c, Palette.EMISSIVE_CYAN, 0.16):
					return true
	return false


# === 特写验证 ===

func _verify_closeup(img: Image) -> void:
	# 特写帧必须非空且包含设备带：世界 (128,128) 附近应有 treadmill 顶面色层
	# （设备带放大后中央区域不应是纯地板/空）
	var found_equip := false
	for dy in range(-30, 31, 3):
		for dx in range(-30, 31, 3):
			var p := _w2s(Vector2(128 + dx, 128 + dy), 0.0)
			if not _in_bounds(img, p):
				continue
			var c := img.get_pixel(p.x, p.y)
			# treadmill 带材（深灰蓝系）或控制台青 —— 取饱和度略高/亮度变化
			var lum := 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
			if lum > 0.25 and lum < 0.95 and (c.s > 0.08 or lum < 0.45):
				found_equip = true
				break
		if found_equip:
			break
	_ok(found_equip, "CLOSEUP equipment belt content present (特写设备带非空)")


func _verify_perf() -> void:
	var draw_calls := Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	var fps := Performance.get_monitor(Performance.TIME_FPS)
	var perf_ok := draw_calls < 200
	_ok(perf_ok, "PERF draw_calls=%d fps=%.1f budget_ok=%s" % [draw_calls, fps, str(perf_ok)])


# === helpers ===

func _w2s(w: Vector2, z: float) -> Vector2i:
	# 特写变换下：屏幕 = (w + position) * scale，再乘 1280/426 与 720/240
	var v := (w + CLOSEUP_POS) * CLOSEUP_SCALE
	v.x *= 1280.0 / 426.0
	v.y *= 720.0 / 240.0
	return Vector2i(roundi(v.x), roundi(v.y))


func _ok(cond: bool, msg: String) -> void:
	if not cond:
		_all_ok = false
	print("  %s %s" % ["PASS" if cond else "FAIL", msg])


## [on_wall] true=本地坐标是北墙墙条坐标（经 _north_wall_transform 投影），
## false=世界坐标（oblique proj z=0）。V3.1 P1：墙饰/贴墙焦点（ad_red）在墙
## 本地空间绘制，采样必须走墙变换。
func _window_contains(img: Image, anchor: Vector2, r: int, color: Color, tol: float, on_wall: bool) -> bool:
	for dy in range(-r, r + 1, 2):
		for dx in range(-r, r + 1, 2):
			var p: Vector2i
			if on_wall:
				p = _wall_to_screen_full(anchor + Vector2(dx, dy))
			else:
				p = _world_to_screen_full(anchor + Vector2(dx, dy))
			if not _in_bounds(img, p):
				continue
			var c := img.get_pixel(p.x, p.y)
			if _near(c, color, tol):
				return true
	return false


## 北墙墙条坐标 → 屏幕（与 world_canvas._north_wall_transform 同源复算）。
func _wall_to_screen_full(w: Vector2) -> Vector2i:
	const Proj2D := preload("res://src/presentation/oblique_projection.gd")
	const Main := preload("res://src/main.gd")
	var kex := Proj2D.WALL_HEIGHT * Proj2D.EXTRUDE_X / 24.0
	var khe := Proj2D.WALL_HEIGHT * Proj2D.HEIGHT_SCALE / 24.0
	var c := Vector2(
		w.x + w.y * kex + 24.0 * Proj2D.SHEAR - 24.0 * kex,
		w.y * khe + 24.0 * Proj2D.FLOOR_SCALE - 24.0 * khe)
	var v := c * Main.WORLD_SCALE + Main.WORLD_VIEWPORT_OFFSET
	return Vector2i(roundi(v.x * Main.SCREEN_PER_VIEWPORT_X), roundi(v.y * Main.SCREEN_PER_VIEWPORT_Y))


## 全场景投影（默认变换，oblique 投影同源 —— 与 main.gd 一致）
func _world_to_screen_full(w: Vector2) -> Vector2i:
	return _world_to_screen_full_z(w, 0.0)


func _world_to_screen_full_z(w: Vector2, z: float) -> Vector2i:
	const Proj2D := preload("res://src/presentation/oblique_projection.gd")
	const Main := preload("res://src/main.gd")
	var v := Proj2D.world_to_screen(w, Main.WORLD_VIEWPORT_OFFSET, Main.WORLD_SCALE,
		Vector2(Main.SCREEN_PER_VIEWPORT_X, Main.SCREEN_PER_VIEWPORT_Y), z)
	return Vector2i(roundi(v.x), roundi(v.y))


func _in_bounds(img: Image, p: Vector2i) -> bool:
	return p.x >= 0 and p.y >= 0 and p.x < img.get_width() and p.y < img.get_height()


func _near(a: Color, b: Color, tol: float) -> bool:
	var dr := a.r - b.r
	var dg := a.g - b.g
	var db := a.b - b.b
	return sqrt(dr * dr + dg * dg + db * db) <= tol
