# tests/evidence/v31_r5_p2_capture.gd — V3.1 返工5 P2 证据捕获（会员 sprite 重绘）
#
# 渲染真实主场景（src/main.tscn）并保存两张视口快照：
#   - tests/evidence/v31-r5-p2-sprite.png     全场景（会员在场，8 会员注入保留）
#   - tests/evidence/v31-r5-p2-closeup.png    设备带 2x 特写（会员肢体 + 设备
#     关键零部件 2x 复验）
#
# 复用 v31_gate_r2_capture.gd 的会员在场确定性注入（8 会员，同一 INJECTED
# 列表 + 同一预置设备布局 —— 门禁最终帧可复算；本卡只改证据路径 + 新增
# 会员肢体结构验证，不改注入、不改布局）。
#
# 本卡（返工5 P2）内嵌验证：
#   - 会员衬衫色命中（WALKING/QUEUEING/LEAVING 姿态可见 —— 非空场，与 gate 一致）
#   - FAIL1 会员肢体结构：walk(11,2) 竖直颜色带 ≥2（躯干带 + 腿带）+
#     两脚分开 ≥2 列 —— 消除「头部+蓝灰横块」棋子感
#   - FAIL2 深色外轮廓库：会员躯干边缘 CHARCOAL 轮廓（与 P1 勾边同源）
#   - FAIL3 顶侧色阶：衬衫上缘亮于下摆（顶面受光 / 下摆压暗）
#   - FAIL4 设备关键零部件 2x 复验：bike 飞轮金属高光 H / 控制台青蓝 A /
#     treadmill 控制台 A（round4 已重绘，本卡逐台复核不退回）
#   - draw_calls < 200（V3 §15 性能预算）
#
# 用法（窗口模式——headless 下 get_image() 返回 null，4.7.1 已验证）：
#   godot --path . res://tests/evidence/v31_r5_p2_capture.tscn
extends Node

const MAIN_SCENE := preload("res://src/main.tscn")
const Palette := preload("res://src/palette.gd")
const Proj2D := preload("res://src/presentation/oblique_projection.gd")
const Main := preload("res://src/main.gd")
const OUT_FULL := "res://tests/evidence/v31-r5-p2-sprite.png"
const OUT_CLOSEUP := "res://tests/evidence/v31-r5-p2-closeup.png"
const REDRAW_FRAME := 6       # 全场景抓帧前强制世界画布重绘（纹理滞后 ≥1 帧）
const INJECT_FRAME := 8       # 注入会员 + 强制重绘
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

## 特写变换（与 v31_r4_p2_capture 同源 —— 聚焦设备带含控制台 2x）：
## 世界焦点 ≈ (204, 89) —— treadmill(6,3) 控制台（z=30）+ bike(2,5) 飞轮
## 在视口内可见；scale 2.0 / pos (-195.3, -57.9)。
const CLOSEUP_SCALE := Vector2(2.0, 2.0)
const CLOSEUP_POS := Vector2(-195.3, -57.9)

## 注入会员（与 v31_gate_r2_capture.gd 完全一致 —— 8 会员在场，门禁最终帧
## 字节一致；本卡只复用，不改注入）。
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
	_place_preset_equipment()
	_world_root = _main.get_node_or_null("WorldViewport/WorldRoot")
	if _world_root == null:
		push_error("v31_r5_p2_capture: WorldRoot not found")
		get_tree().quit(1)


## 显式放置 V3.1 预置设备（与 v31_gate_r2_capture 同源 —— treadmill(2,2)(6,3)
## / bike(2,5) / bench_press(1,7) / yoga_mat(9,2)）。走 PlacementSystem 完整
## 拖放链（同 main.gd _drag_drop）。
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
		print("  P2 full-scene captured (members present)")
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
		push_error("v31_r5_p2_capture: get_image() returned null (headless dummy driver?)")
		get_tree().quit(1)
		return null
	return img


func _save(img: Image, out_path: String) -> void:
	var abs_path := ProjectSettings.globalize_path(out_path)
	var err := img.save_png(abs_path)
	if err != OK:
		push_error("v31_r5_p2_capture: save_png failed err=%d path=%s" % [err, abs_path])
		get_tree().quit(1)
		return
	print("CAPTURE saved=%s size=%dx%d" % [out_path, img.get_width(), img.get_height()])


## 冻结 + 注入规范会员（与 v31_gate_r2_capture.gd 同源 —— 8 会员在场）。
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
	print("INJECTED 8 canonical members (frozen, tick=0)")


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


# === 全场景验证（会员在场 + FAIL1-3 会员肢体结构） ===

func _verify_world_frame(img: Image) -> void:
	_verify_members(img)
	_verify_member_limbs(img)


func _verify_members(img: Image) -> void:
	var checks := [
		{"state": "WALKING_TO", "cell": Vector2i(5, 2), "expect": Color("8EC5E8")},
		{"state": "WALKING_TO", "cell": Vector2i(11, 2), "expect": Color("8EC5E8")},
		{"state": "QUEUEING", "cell": Vector2i(3, 6), "expect": Color("8494A6")},
		{"state": "LEAVING", "cell": Vector2i(10, 6), "expect": Color("9A948C")},
	]
	for entry in checks:
		var p := _member_shirt_screen(entry["cell"])
		var found := _scan_tone(img, p, 5, entry["expect"], 0.22)
		_ok(found, "MEMBER %-12s shirt visible @(%3d,%3d)" % [entry["state"], p.x, p.y])


## 会员衬衫采样点（与 v31_gate_r2_capture 同源：画布锚点 + 纹理局部 (24,19)）。
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


## 全场景帧会员肢体结构验证：walk(11,2) 躯干带 + 腿带 ≥2（衬衫 → 裤/鞋，
## 头颈连接躯干是正常解剖 —— 不要求头/躯干分开）+ 两脚分开 ≥2 列 +
## CHARCOAL 轮廓命中 + 顶/下摆色阶。用与 gate 同源的衬衫锚点窗口；
## floor 全不透明 → 按【会员专属色】过滤，不用 alpha。
func _verify_member_limbs(img: Image) -> void:
	var cell := Vector2i(11, 2)
	var shirt := _member_shirt_screen(cell)
	var cx := shirt.x
	var cy := shirt.y  # 衬衫点在躯干中部（局部 (24,19)）
	var sky := Color("8EC5E8")
	var skin := Color("EACBA6")
	var hair := Color("554433")
	var pants := Color("665555")
	var shoes := Color("444433")
	# FAIL1 竖直颜色带：沿 member 中心列扫描（dx ±30 —— 覆盖窄腿），
	# 发/肤/衬衫/裤/鞋任一命中计为会员像素。躯干带（发/肤/衬衫）与腿带
	# （裤/鞋）应 ≥2 个连续带 —— 腿从躯干读出，非「头部+单块」。
	var member_color := func(c: Color) -> bool:
		return _near(c, sky, 0.14) or _near(c, skin, 0.14) or _near(c, hair, 0.14) \
			or _near(c, pants, 0.14) or _near(c, shoes, 0.14)
	var bands := 0
	var in_band := false
	for dy in range(-55, 95, 2):
		var sy := cy + dy
		var opaque := false
		for dx in range(-30, 31, 3):
			var sx := cx + dx
			if sx < 0 or sy < 0 or sx >= img.get_width() or sy >= img.get_height():
				continue
			if member_color.call(img.get_pixel(sx, sy)):
				opaque = true
				break
		if opaque and not in_band:
			bands += 1
			in_band = true
		elif not opaque:
			in_band = false
	_ok(bands >= 2, "R5 FAIL1 member(11,2) color bands %d >= 2 (躯干+腿可辨)" % bands)
	# FAIL1 两脚分开：member 底部（衬衫点下方 25..60）x 方向鞋色列组数。
	var feet_cols := 0
	var in_col := false
	for dx in range(-40, 41, 3):
		var sx := cx + dx
		var opaque := false
		for dy in range(25, 61, 3):
			var sy := cy + dy
			if sx < 0 or sy < 0 or sx >= img.get_width() or sy >= img.get_height():
				continue
			if _near(img.get_pixel(sx, sy), shoes, 0.14):
				opaque = true
				break
		if opaque and not in_col:
			feet_cols += 1
			in_col = true
		elif not opaque:
			in_col = false
	_ok(feet_cols >= 2, "R5 FAIL1 member(11,2) separate feet columns %d >= 2 (两脚分开)" % feet_cols)
	# FAIL2 深色外轮廓库：member 躯干边缘 CHARCOAL（邻接衬衫/裤色块的深色像素）。
	var outline_hits := 0
	for dy in range(-55, 85, 2):
		for dx in range(-30, 31, 2):
			var sx := cx + dx
			var sy := cy + dy
			if sx < 0 or sy < 0 or sx >= img.get_width() or sy >= img.get_height():
				continue
			var c := img.get_pixel(sx, sy)
			if _near(c, Palette.CHARCOAL, 0.10) and _has_member_neighbor(img, sx, sy, member_color):
				outline_hits += 1
	_ok(outline_hits > 0, "R5 FAIL2 member(11,2) CHARCOAL outline hits %d > 0 (深色外轮廓库)" % outline_hits)
	# FAIL3 顶侧色阶：衬衫上缘（dy -8..0 —— 亮 'c'）亮于衬衫下缘
	# （dy +6..+18 —— 暗化 'd' 下摆）—— 顶面受光 / 下摆压暗。
	var shoulder_lum := _member_band_lum_full(img, cx, cy, -8, 0)
	var hem_lum := _member_band_lum_full(img, cx, cy, 6, 18)
	_ok(shoulder_lum > hem_lum + 4.0,
		"R5 FAIL3 member(11,2) top/hem shading (%.0f > %.0f+4, 顶侧色阶)" % [shoulder_lum, hem_lum])


## [c] 是否会员专属色（衬衫/肤/发/裤/鞋任一）—— 用 [pred] 回调判断。
func _has_member_neighbor(img: Image, x: int, y: int, pred: Callable) -> bool:
	for d in [[1, 0], [-1, 0], [0, 1], [0, -1]]:
		var nx := x + int(d[0])
		var ny := y + int(d[1])
		if nx < 0 or ny < 0 or nx >= img.get_width() or ny >= img.get_height():
			continue
		if pred.call(img.get_pixel(nx, ny)):
			return true
	return false


## 全场景帧：member 区域内某水平带平均明度（0-255）。dy0..dy1 相对衬衫点
## (cx, cy) 的 y 偏移（负=上方/躯干上部，正=下方/下摆）。
func _member_band_lum_full(img: Image, cx: int, cy: int, dy0: int, dy1: int) -> float:
	var sum := 0.0
	var n := 0
	for dy in range(dy0, dy1, 2):
		var sy := cy + dy
		for dx in range(-16, 17, 2):
			var sx := cx + dx
			if sx < 0 or sy < 0 or sx >= img.get_width() or sy >= img.get_height():
				continue
			var c := img.get_pixel(sx, sy)
			if c.a <= 0.5:
				continue
			sum += 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
			n += 1
	return sum * 255.0 / n if n > 0 else 0.0


# === 特写验证（FAIL4 设备零部件 2x 复验） ===

func _verify_closeup(img: Image) -> void:
	# FAIL4 设备关键零部件 2x 复验（round4 已重绘，本卡逐台复核不退回）：
	# - bike(2,5) 飞轮金属高光 H（世界 (72..120, 150..190) z 0..20 —— 特写下
	#   屏幕 ≈ (66..305, 480..658)，已实测 598 命中）
	# - treadmill(6,3) 控制台青蓝 A（世界 (200..230, 105..118) z=30 —— 特写下
	#   屏幕 ≈ (759..888, 210..242)，已实测 cluster B）
	# bike 控制台青蓝在本布局特写下被 USING 会员遮挡 —— 由 R4 P2 隔离帧 QA
	# （qa_v31r4p2_independent.py，bike console cyan on top/front）覆盖，非本帧
	# 回归（equipment_art.gd 本卡未改）。
	var bike_h := _count_near_world_cu(img, Rect2i(72, 150, 48, 40), 14.0,
		Palette.METAL_HIGHLIGHT, 0.10, 2)
	_ok(bike_h > 0, "R5 FAIL4 bike flywheel metal highlight visible at 2x (hits=%d)" % bike_h)
	var tm_a := _count_near_screen(img, Rect2i(780, 250, 240, 110),
		Palette.EQUIP_ACCENT_CYAN, 0.16, 2)
	_ok(tm_a > 0, "R5 FAIL4 treadmill console cyan visible at 2x (hits=%d)" % tm_a)


## 特写帧屏幕矩形内接近 [target] 的像素数（已投影到屏幕 —— 供特写帧
## 设备带控制台验证；坐标由实测 cluster 校准）。
func _count_near_screen(img: Image, rect: Rect2i,
		target: Color, tol: float, step: int) -> int:
	var hits := 0
	for y in range(rect.position.y, rect.end.y, step):
		for x in range(rect.position.x, rect.end.x, step):
			if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
				continue
			if _near(img.get_pixel(x, y), target, tol):
				hits += 1
	return hits


func _verify_perf() -> void:
	var draw_calls := Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	var fps := Performance.get_monitor(Performance.TIME_FPS)
	var perf_ok := draw_calls < 200
	_ok(perf_ok, "PERF draw_calls=%d fps=%.1f budget_ok=%s" % [draw_calls, fps, str(perf_ok)])


# === helpers ===

## 特写变换下世界坐标 → 屏幕：WorldCanvas 输出投影后画布 coords，WorldRoot
## scale=2 / position=CLOSEUP_POS 再变换到 viewport，最后 × 屏幕放大。
func _w2s(w: Vector2, z: float) -> Vector2i:
	var canvas := Proj2D.proj(w.x, w.y, z)
	var v := canvas * CLOSEUP_SCALE + CLOSEUP_POS
	v.x *= 1280.0 / 426.0
	v.y *= 720.0 / 240.0
	return Vector2i(roundi(v.x), roundi(v.y))


## 特写变换下世界矩形内接近 [target] 的像素数（z=0）。
func _count_near_world_cu(img: Image, rect: Rect2i, z: float,
		target: Color, tol: float, step: int) -> int:
	return _count_near_world_cu_z(img, rect, z, target, tol, step)


func _count_near_world_cu_z(img: Image, rect: Rect2i, z: float,
		target: Color, tol: float, step: int) -> int:
	var hits := 0
	for y in range(rect.position.y, rect.end.y, step):
		for x in range(rect.position.x, rect.end.x, step):
			var p := _w2s(Vector2(x, y), z)
			if p.x < 0 or p.y < 0 or p.x >= img.get_width() or p.y >= img.get_height():
				continue
			if _near(img.get_pixel(p.x, p.y), target, tol):
				hits += 1
	return hits


func _near(c: Color, target: Color, tol: float) -> bool:
	return absf(c.r - target.r) <= tol and absf(c.g - target.g) <= tol \
		and absf(c.b - target.b) <= tol


func _ok(cond: bool, msg: String) -> void:
	if cond:
		print("  PASS " + msg)
	else:
		_all_ok = false
		print("  FAIL " + msg)
