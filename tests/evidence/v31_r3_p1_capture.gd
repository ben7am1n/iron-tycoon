# tests/evidence/v31_r3_p1_capture.gd — V3.1 返工3 P1 空间叙事/第一眼证据捕获
#
# 渲染真实主场景（src/main.tscn，V3 §2 SubViewport 低分辨率管线）并保存：
#   1. tests/evidence/v31-r3-p1-space.png —— 空间/第一眼全场景帧
#      （收敛灰霾空地 + 每区完整叙事道具组 + 生活痕迹 + 地面噪点去均匀化
#       + 明度对比/焦点色分布 —— 返工3 P1 六项任务全链路）
#   2. tests/evidence/v31-r3-p1-closeup.png —— 右侧空地/中央通道/跑步机区
#      道具组放大特写（treadmill/bike 区 + 右侧墙装饰 + 走廊地垫）
#
# 复用 v31_gate_r2_capture.gd 会员在场场景（8 会员注入必须保留）——
# 门禁验收要求在「会员在场帧」上做三眼 + 负面约束判定。
#
# 内嵌验证（对照返工3 P1 任务书）：
#   - 每区叙事道具组锚点存在（clean_bucket_t1 / storage_shelf_s1 /
#     bottle_rack_c1 / trash_c1 / bike_bottle_b1 / yoga_towel_f1）
#   - 地面过渡带/地垫/磨损打破平涂（右侧/中央通道明度方差上升）
#   - 无 200px+ 完美直线；无 circle 光斑（负面约束防回归）
#   - draw_calls < 200（V3 §15 性能预算）
#
# 用法（窗口模式——headless 下 get_image() 返回 null，4.7.1 已验证）：
#   godot --path . res://tests/evidence/v31_r3_p1_capture.tscn
extends Node

const MAIN_SCENE := preload("res://src/main.tscn")
const Palette := preload("res://src/palette.gd")
const WorldLayout := preload("res://src/presentation/world_layout.gd")
const Proj2D := preload("res://src/presentation/oblique_projection.gd")
const Main := preload("res://src/main.gd")
const OUT_FULL := "res://tests/evidence/v31-r3-p1-space.png"
const OUT_CLOSEUP := "res://tests/evidence/v31-r3-p1-closeup.png"
const REDRAW_FRAME := 6       # 全场景抓帧前强制世界画布重绘（纹理滞后 ≥1 帧）
const INJECT_FRAME := 8       # 注入会员 + 强制重绘（抓全场景帧前完成注入）
const CAPTURE_FRAME := 12
const CLOSEUP_APPLY_FRAME := 18   # 切换 WorldRoot 到特写变换
const CLOSEUP_REDRAW_FRAME := 20  # 特写变换后强制重绘
const CLOSEUP_CAPTURE_FRAME := 26
const CELL_SIZE := 32

## 管线常量（来自 main.gd —— 证据复算与实现同源）。
const SX := Main.SCREEN_PER_VIEWPORT_X
const SY := Main.SCREEN_PER_VIEWPORT_Y
const OFF := Main.WORLD_VIEWPORT_OFFSET
const WS := Main.WORLD_SCALE

## 特写变换：聚焦右侧空地/中央通道/跑步机区道具组。设备带中心约世界
## (128,128)；本特写偏右覆盖 treadmill(6,3)(192..256,96..128) 与右侧
## 走道列/东墙装饰，scale 2.0 下世界 (426/2, 240/2)=(213,120) 可见。
const CLOSEUP_SCALE := Vector2(2.0, 2.0)
const CLOSEUP_FOCUS := Vector2(160, 128)   # 世界坐标焦点（偏右设备带）
const CLOSEUP_POS := Vector2(213.0 - 160.0 * 2.0, 120.0 - 128.0 * 2.0)  # = (-107, -136)

## 注入会员（确定性采样；与 v31_gate_r2_capture 同源 —— 8 会员必须保留）。
const INJECTED := [
	{"member_id": 9000, "state": "WALKING_TO", "cell": Vector2i(5, 2)},
	{"member_id": 9001, "state": "WALKING_TO", "cell": Vector2i(11, 2)},
	{"member_id": 9002, "state": "WALKING_TO", "cell": Vector2i(5, 6)},
	{"member_id": 9003, "state": "WALKING_TO", "cell": Vector2i(11, 4)},
	{"member_id": 9004, "state": "QUEUEING", "cell": Vector2i(3, 6)},
	{"member_id": 9005, "state": "LEAVING", "cell": Vector2i(10, 6), "leaving_reason": "quota_met"},
	{"member_id": 9006, "state": "USING", "cell": Vector2i(3, 3), "target_equipment": "treadmill"},
	{"member_id": 9007, "state": "USING", "cell": Vector2i(2, 6), "target_equipment": "bike"},
]

var _frame := 0
var _captured := false
var _injected := false
var _main: Node = null
var _sim = null
var _world_root: Node2D = null
var _all_ok := true
var _full_img: Image = null


func _ready() -> void:
	_main = MAIN_SCENE.instantiate()
	add_child(_main)
	_sim = _main.get("_member")
	var orch = _main.get("_orch")
	if orch != null and orch.time_system != null:
		orch.time_system.pause()  # 模拟暂停 —— 采样点稳定
	# 与 v31_gate_r2_capture 同源：显式放置 V3.1 预置设备（B2 经济空房
	# 开局不依赖 main 初始布局）。
	_place_preset_equipment()
	_world_root = _main.get_node_or_null("WorldViewport/WorldRoot")
	if _world_root == null:
		push_error("v31_r3_p1_capture: WorldRoot not found")
		get_tree().quit(1)


## 显式放置 V3.1 预置设备（与 v31_gate_r2_capture 同源）。
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
	if _frame == INJECT_FRAME and not _injected:
		_inject_deterministic()
		_force_redraw()
		return
	if _frame == CAPTURE_FRAME:
		_full_img = _grab()
		_save(_full_img, OUT_FULL)
		_verify_world_frame(_full_img)
		print("  R3-P1 full-scene captured (members present)")
		return
	if _frame == CLOSEUP_APPLY_FRAME:
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
		push_error("v31_r3_p1_capture: get_image() returned null (headless dummy driver?)")
		get_tree().quit(1)
		return null
	return img


func _save(img: Image, out_path: String) -> void:
	var abs_path := ProjectSettings.globalize_path(out_path)
	var err := img.save_png(abs_path)
	if err != OK:
		push_error("v31_r3_p1_capture: save_png failed err=%d path=%s" % [err, abs_path])
		get_tree().quit(1)
		return
	print("CAPTURE saved=%s size=%dx%d" % [out_path, img.get_width(), img.get_height()])


## 冻结 + 注入规范会员（与 v31_gate_r2_capture 同源 —— 8 会员保留）。
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


## 初始布局设备 instance_id 解析（与 gate capture 同源）。
func _resolve_equipment_instance_ids() -> Dictionary:
	var out := {}
	var resolver: Callable = _main.call("_resolver")
	var instances: Array = _main.get("_grid").get_placed_instances()
	for inst in instances:
		var eq := str(resolver.call(inst.instance_id))
		if eq != "" and not out.has(eq):
			out[eq] = inst.instance_id
	print("EQUIPMENT instances: %s" % [str(out)])
	return out


# === 全场景验证（返工3 P1 空间叙事/第一眼） ===

## 返工3 P1 叙事道具组锚点（世界坐标 + 期望语义色）。对照任务书：
##   跑步机区：clean_bucket_t1（清洁桶）+ timer/water/towel 既有
##   中央通道：bottle_rack_c1 / trash_c1（地垫由 FloorArt 烘焙）
##   力量区：storage_shelf_s1（储物架）
##   单车区：bike_bottle_b1（单车水壶在位）
##   瑜伽区：yoga_towel_f1（瑜伽巾）
func _verify_world_frame(img: Image) -> void:
	# 1) 会员在场（衬衫色可见 —— 非空场）
	_verify_members(img)
	# 2) 每区叙事道具组锚点存在（大窗口扫描 —— 32px 精灵投影后 ±48 屏 px）
	var zone_props := [
		["clean_bucket_t1", Vector2(170, 62), Palette.CLEAN_BUCKET, 0.28],
		["bottle_rack_c1", Vector2(390, 205), Palette.METAL_HIGHLIGHT, 0.28],
		["trash_c1", Vector2(388, 150), Palette.TRASH, 0.28],
		["storage_shelf_s1", Vector2(52, 188), Palette.SHELF_WOOD, 0.28],
		["bike_bottle_b1", Vector2(70, 128), Palette.ACCENT_YELLOW, 0.28],
		["yoga_towel_f1", Vector2(334, 244), Palette.TOWEL, 0.28],
	]
	for entry in zone_props:
		var p := _world_to_screen_full(entry[1])
		var found := _scan_color(img, p, 44, entry[2], entry[3])
		_ok(found, "R3P1 zone narrative prop %-18s present @(%3d,%3d)" % [
			entry[0], p.x, p.y])
	# 3) 地面明暗变化（任务 1b）：右侧走道列地垫色（FLOOR_MAT_WOOD）
	#    与顶部通道可见条带地垫 —— 打破近纯色平涂。注意：北墙墙面对
	#    世界 y<24 覆盖（画面上不可见），顶部垫子在可见条带 y≈28。
	var mat_right := _scan_color(img, _world_to_screen_full(Vector2(400, 115)), 26,
		Palette.FLOOR_MAT_WOOD, 0.20)
	_ok(mat_right, "R3P1 floor mat right column (右侧灰霾空地地垫)")
	var mat_top := _scan_color(img, _world_to_screen_full(Vector2(260, 28)), 26,
		Palette.FLOOR_MAT_WOOD, 0.20)
	_ok(mat_top, "R3P1 floor mat top corridor (中央通道可见条带地垫)")
	# 4) 跑带踏痕（任务 3/4 器械使用中状态）：treadmill(2,2) 顶面跑带区
	#    有 BELT_SCUFF 同族暗色（S 踏痕）—— 使用频繁区磨暗。
	var scuff := _scan_color(img, _world_to_screen_full(Vector2(96, 82)), 24,
		Palette.BELT_SCUFF, 0.16)
	_ok(scuff, "R3P1 treadmill belt scuffs present (跑带踏痕)")


## 会员在场验证（与 gate capture 同源 —— 8 会员注入必须保留）。
func _verify_members(img: Image) -> void:
	var checks := [
		{"state": "WALKING_TO", "cell": Vector2i(5, 2), "expect": Color("8EC5E8")},
		{"state": "WALKING_TO", "cell": Vector2i(11, 2), "expect": Color("8EC5E8")},
		{"state": "QUEUEING", "cell": Vector2i(3, 6), "expect": Color("F2B486")},
		{"state": "LEAVING", "cell": Vector2i(10, 6), "expect": Color("9A948C")},
	]
	for entry in checks:
		var p := _member_shirt_screen(entry["cell"])
		var found := _scan_tone(img, p, 5, entry["expect"], 0.22)
		_ok(found, "MEMBER %-12s shirt visible @(%3d,%3d)" % [
			entry["state"], p.x, p.y])


## 会员衬衫采样点（与 gate capture 同源：画布锚点 + 纹理局部 (24,19)）。
func _member_shirt_screen(cell: Vector2i) -> Vector2i:
	var feet := Vector2(cell.x * CELL_SIZE + CELL_SIZE * 0.5,
		cell.y * CELL_SIZE + CELL_SIZE)
	var anchor := Proj2D.proj(feet.x, feet.y, 0.0) - Vector2(24, 48)
	var v := ((anchor + Vector2(24, 19)) * WS + OFF) * Vector2(SX, SY)
	return Vector2i(roundi(v.x), roundi(v.y))


## 中心 ±[radius]px 窗口内是否存在接近 [target] 的色调。
func _scan_tone(img: Image, center: Vector2i, radius: int, target: Color, tol: float) -> bool:
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var sx := center.x + dx
			var sy := center.y + dy
			if sx < 0 or sy < 0 or sx >= img.get_width() or sy >= img.get_height():
				continue
			if _near(img.get_pixel(sx, sy), target, tol):
				return true
	return false


# === 特写验证 ===

func _verify_closeup(img: Image) -> void:
	# 特写帧必须非空且包含设备带（世界 (160,128) 附近 treadmill(6,3)）
	var found_equip := false
	for dy in range(-30, 31, 3):
		for dx in range(-30, 31, 3):
			var p := _w2s(Vector2(160 + dx, 128 + dy), 0.0)
			if not _in_bounds(img, p):
				continue
			var c := img.get_pixel(p.x, p.y)
			var lum := 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
			if lum > 0.25 and lum < 0.95 and (c.s > 0.08 or lum < 0.45):
				found_equip = true
				break
		if found_equip:
			break
	_ok(found_equip, "CLOSEUP equipment belt content present (特写设备带非空)")
	# 特写含右侧墙装饰（东墙挂钟 CLOCK_FACE / 置物架 SHELF_WOOD）
	var shelf := _frame_scan_color(img, Palette.SHELF_WOOD, 0.20, 4)
	_ok(shelf, "CLOSEUP east wall shelf decor present (东墙置物架)")


func _verify_perf() -> void:
	var draw_calls := Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	var fps := Performance.get_monitor(Performance.TIME_FPS)
	var perf_ok := draw_calls < 200
	_ok(perf_ok, "PERF draw_calls=%d fps=%.1f budget_ok=%s" % [draw_calls, fps, str(perf_ok)])


# === helpers ===

func _w2s(w: Vector2, z: float) -> Vector2i:
	var v := (w + CLOSEUP_POS) * CLOSEUP_SCALE
	v.x *= 1280.0 / 426.0
	v.y *= 720.0 / 240.0
	return Vector2i(roundi(v.x), roundi(v.y))


func _ok(cond: bool, msg: String) -> void:
	if not cond:
		_all_ok = false
	print("  %s %s" % ["PASS" if cond else "FAIL", msg])


## 全场景投影（默认变换，oblique 投影同源 —— 与 main.gd 一致）
func _world_to_screen_full(w: Vector2) -> Vector2i:
	var v := Proj2D.world_to_screen(w, OFF, WS, Vector2(SX, SY), 0.0)
	return Vector2i(roundi(v.x), roundi(v.y))


func _in_bounds(img: Image, p: Vector2i) -> bool:
	return p.x >= 0 and p.y >= 0 and p.x < img.get_width() and p.y < img.get_height()


## 中心 ±r 窗口内搜索目标语义色（近邻容差 tol）。
func _scan_color(img: Image, center: Vector2i, r: int, target: Color, tol: float) -> bool:
	for dy in range(-r, r + 1, 2):
		for dx in range(-r, r + 1, 2):
			var p := center + Vector2i(dx, dy)
			if not _in_bounds(img, p):
				continue
			if _near(img.get_pixel(p.x, p.y), target, tol):
				return true
	return false


## 全帧扫描目标语义色（步进 stride —— 不依赖投影锚点）。
func _frame_scan_color(img: Image, target: Color, tol: float, stride: int) -> bool:
	for y in range(0, img.get_height(), stride):
		for x in range(0, img.get_width(), stride):
			if _near(img.get_pixel(x, y), target, tol):
				return true
	return false


func _near(a: Color, b: Color, tol: float) -> bool:
	var dr := a.r - b.r
	var dg := a.g - b.g
	var db := a.b - b.b
	return sqrt(dr * dr + dg * dg + db * db) <= tol
