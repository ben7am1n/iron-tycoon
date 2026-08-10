# tests/evidence/v31_r3_p3_capture.gd — V3.1 返工3 P3 证据捕获（灯光链可读/冷色投影/三层景深）
#
# 渲染真实主场景并保存两张视口快照：
#   - tests/evidence/v31-r3-p3-lighting.png    全场景（会员在场，8 会员注入保留 —— 与
#     v31_gate_r2_capture.gd 同源）
#   - tests/evidence/v31-r3-p3-closeup.png     吊灯下受光面放大特写：灯罩发光 → 灯下暖池 →
#     向南衰减 → 远处冷灰（FAIL1 受光链）+ 设备顶面受光/侧面暗 + 冷色投影 + 前景遮挡
#
# 复用 v31_gate_r2_capture.gd 的会员在场确定性注入（8 会员，同一 INJECTED 列表 ——
# 门禁最终帧字节一致；本卡只加 P3 灯光特写帧 + 灯光链验证，不改注入）。
#
# 内嵌验证：
#   - 全场景：会员衬衫色命中（非空场，与 gate 一致）
#   - 特写：吊灯灯罩暖橙金（LAMP_SHADE_LIT）可见；灯下暖池像素（r>b）存在；
#     设备顶面受光带暖色像素存在（受光面明暗朝向）；冷色投影（b>r）存在；
#     近景暖带（foreground warm）存在
#   - draw_calls < 200（V3 §15 性能预算）
#
# 用法（窗口模式——headless 下 get_image() 返回 null，4.7.1 已验证）：
#   godot --path . res://tests/evidence/v31_r3_p3_capture.tscn
extends Node

const MAIN_SCENE := preload("res://src/main.tscn")
const Palette := preload("res://src/palette.gd")
const WorldLayout := preload("res://src/presentation/world_layout.gd")
const Proj2D := preload("res://src/presentation/oblique_projection.gd")
const Main := preload("res://src/main.gd")
const OUT_FULL := "res://tests/evidence/v31-r3-p3-lighting.png"
const OUT_CLOSEUP := "res://tests/evidence/v31-r3-p3-closeup.png"
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

## 特写变换：聚焦力量区吊灯 hanging_lamp_1（世界 rect(72,18,28,36) height 78，
## 落点 (86,170)）。需要同框的投影点（Proj2D.proj 后，canvas 坐标）：
##   灯罩顶部 proj(72,18,78)          ≈ (63.5, -36.1)
##   灯下暖池中心 proj(86,170,0)       ≈ (123.4, 130.9)
##   暖池北缘 proj(86,158,0)           ≈ (120.8, 121.7)
##   暖池南段 proj(86,196,0)           ≈ (129.1, 150.9)（衰减段）
##   北墙饰带（后景）proj(120,60,0)    ≈ (133.2, 46.2)（雾化墙带/远处冷灰）
##   设备顶面 proj(96,80,30)           ≈ (108.8, 42.4)
##   设备侧面 proj(128,96,16)          ≈ (146.6, 63.7)
##   冷色投影 proj(96,105,0)           ≈ (119.1, 80.9)
##   前景暖带 proj(200,270,0)          ≈ (259.4, 207.9)（底部）
## 覆盖 x 63..260 / y -36..208。scale 0.9 下视口 426×240 可见世界投影
## 473×266；position (60,34) 使灯罩顶（y≈1.5）到前景带（y≈221）全部入框：
##   pos = (60, 34)。
const CLOSEUP_SCALE := Vector2(0.9, 0.9)
const CLOSEUP_POS := Vector2(60.0, 34.0)

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
var _closeup := false
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
		push_error("v31_r3_p3_capture: WorldRoot not found")
		get_tree().quit(1)


## 显式放置 V3.1 预置设备（与 v31_gate_r2_capture.gd 同源 —— 门禁帧含
## V3.1 全套视觉元素，不受 B2 经济空房开局影响）。
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
		var eq_id := str(entry[0])
		var cell: Vector2i = entry[1]
		if occupied.has(cell):
			continue
		if _drag_place(placement, eq_id, cell):
			for c in grid.get_placed_instances():
				if str(c.equipment_id) == eq_id:
					for fc in c.footprint_cells:
						occupied[fc] = true
					break


## 经 PlacementSystem 拖放链放置（同 gate capture）。
func _drag_place(placement, eq_id: String, cell: Vector2i) -> bool:
	if not placement.has_method("begin_drag") or not placement.has_method("on_drop"):
		return false
	var pid: Variant = placement.begin_drag(eq_id)
	if pid == null or int(pid) < 0:
		return false
	placement.on_mouse_moved(cell)
	return placement.on_drop()


func _on_placed(instance_id: int, equipment_id: String, _cells: Array) -> void:
	print("EQUIPMENT placed: %s id=%d" % [equipment_id, instance_id])


func _process(_delta: float) -> void:
	_frame += 1
	if _captured:
		return
	if _frame == REDRAW_FRAME:
		_world_root.queue_redraw()
		return
	if _frame == INJECT_FRAME:
		_inject_members()
		_world_root.queue_redraw()
		return
	if _frame == CAPTURE_FRAME:
		_capture_full()
		return
	if _frame == CLOSEUP_APPLY_FRAME:
		_apply_closeup_transform()
		_world_root.queue_redraw()
		return
	if _frame == CLOSEUP_REDRAW_FRAME:
		_world_root.queue_redraw()
		return
	if _frame == CLOSEUP_CAPTURE_FRAME:
		_capture_closeup()
		_finish()


## 注入 8 个确定性会员（与 gate capture 相同）。
func _inject_members() -> void:
	if _injected:
		return
	_injected = true
	if _sim == null:
		return
	_sim.members.clear()
	for m in INJECTED:
		var entry := {
			"member_id": int(m.get("member_id", 0)),
			"state": str(m.get("state", "WALKING_TO")),
			"cell": m.get("cell", Vector2i(5, 2)),
			"exercises_done": 0,
			"exercises_per_visit": 1,
			"preference_profile": {},
			"target_equipment_instance_id": -1,
			"cached_path": [],
			"cached_path_grid_version": -1,
			"repath_failures": 0,
			"give_up_blacklist": {},
			"leaving_timeout_ticks": 0,
			"patience_ticks_remaining": 0,
			"recently_used_ids": [],
			"leaving_reason": str(m.get("leaving_reason", "")),
			"use_ticks_remaining": 60,
		}
		if entry["state"] == "USING":
			entry["target_equipment"] = str(m.get("target_equipment", "treadmill"))
		_sim.members.append(entry)
	print("INJECTED 8 canonical members (frozen, tick=0)")


func _grab() -> Image:
	var img := get_viewport().get_texture().get_image()
	if img == null:
		push_error("v31_r3_p3_capture: get_image() returned null (headless dummy driver?)")
		get_tree().quit(1)
		return null
	return img


func _capture_full() -> void:
	var img := _grab()
	var abs_path := ProjectSettings.globalize_path(OUT_FULL)
	var err := img.save_png(abs_path)
	if err != OK:
		push_error("v31_r3_p3_capture: save_png failed err=%d path=%s" % [err, abs_path])
		get_tree().quit(1)
		return
	_full_img = img
	print("CAPTURE saved=%s size=%dx%d" % [OUT_FULL, img.get_width(), img.get_height()])
	_verify_full_frame(img)


func _capture_closeup() -> void:
	var img := _grab()
	var abs_path := ProjectSettings.globalize_path(OUT_CLOSEUP)
	var err := img.save_png(abs_path)
	if err != OK:
		push_error("v31_r3_p3_capture: closeup save_png failed err=%d path=%s" % [err, abs_path])
		get_tree().quit(1)
		return
	print("CAPTURE saved=%s size=%dx%d" % [OUT_CLOSEUP, img.get_width(), img.get_height()])
	_verify_closeup(img)
	_verify_perf()


func _apply_closeup_transform() -> void:
	if _world_root == null:
		return
	_closeup = true
	_world_root.scale = CLOSEUP_SCALE
	_world_root.position = CLOSEUP_POS


func _finish() -> void:
	print("RESULT: %s" % ("PASS" if _all_ok else "CHECK"))
	get_tree().quit(0 if _all_ok else 1)


func _ok(cond: bool, msg: String) -> void:
	if not cond:
		_all_ok = false
	print("  %s %s" % ["PASS" if cond else "FAIL", msg])


# === 全场景验证（会员在场 + 灯光链粗查） ===

func _verify_full_frame(img: Image) -> void:
	# 会员衬衫色命中（WALKING sky / QUEUEING peach / LEAVING gray —— 非空场）
	var member_found := false
	for y in range(0, img.get_height(), 4):
		for x in range(0, img.get_width(), 4):
			var c := img.get_pixel(x, y)
			if _luminance(c) > 0.2 and (c.r - c.b > 0.15 or c.b - c.r > 0.15):
				member_found = true
				break
		if member_found:
			break
	_ok(member_found, "FULL member color present (非空场)")


# === 特写验证（灯罩发光 → 灯下暖池 → 衰减 → 冷灰 + 设备受光 + 冷投影 + 前景带） ===

func _verify_closeup(img: Image) -> void:
	# 1. 灯罩暖橙金（LAMP_SHADE_LIT）在特写内可见（光源物件可辨识）
	# 灯罩纹理 28×36 从 proj(72,18,78) 起，暖橙灯罩像素集中在灯泡局部点
	# bulb_local(14,29) 附近 —— 以灯泡点为中心扫 30px 窗口。
	var lamp_pos := canvas_to_screen(Proj2D.proj(72.0, 18.0, 78.0) + Vector2(14, 29))
	var shade_found := false
	for dy in range(-15, 16):
		for dx in range(-15, 16):
			var sx := lamp_pos.x + dx
			var sy := lamp_pos.y + dy
			if sx < 0 or sy < 0 or sx >= img.get_width() or sy >= img.get_height():
				continue
			if _near(img.get_pixel(sx, sy), Palette.LAMP_SHADE_LIT, 0.24):
				shade_found = true
				break
		if shade_found:
			break
	_ok(shade_found, "CLOSEUP lamp shade warm-lit visible @screen(%d,%d) (灯罩发光)" % [lamp_pos.x, lamp_pos.y])

	# 2. 灯下暖池（受光面）：落点中心窗口暖色像素 r>b
	var pool_pos := canvas_to_screen(Proj2D.project_world(Vector2(86, 170)))
	var pool_warm := 0
	for dy in range(-6, 7):
		for dx in range(-6, 7):
			var sx := pool_pos.x + dx
			var sy := pool_pos.y + dy
			if sx < 0 or sy < 0 or sx >= img.get_width() or sy >= img.get_height():
				continue
			var c := img.get_pixel(sx, sy)
			if c.r > c.b + 0.02 and _luminance(c) > 0.24:
				pool_warm += 1
	_ok(pool_warm > 0, "CLOSEUP under-lamp warm pool visible @screen(%d,%d) (灯下受光面, warm %d)" % [pool_pos.x, pool_pos.y, pool_warm])

	# 3. 南向衰减：落点北侧暖 > 南侧远段（亮→衰减方向可读）
	# 南侧采样点取 (86,214)：避开 treadmill(2,2) 脚下暖色地面亮池
	# （footprint y 96 + 亮池 ~y 100-105 → 屏幕 y≈470-500；(86,196) 投影
	# 后恰落在该亮池窗口内，warm 计数被设备受光污染 —— 改到亮池以南）。
	var north_pos := canvas_to_screen(Proj2D.project_world(Vector2(86, 158)))
	var south_pos := canvas_to_screen(Proj2D.project_world(Vector2(86, 214)))
	var north_warm := _count_warm(img, north_pos, 5)
	var south_warm := _count_warm(img, south_pos, 5)
	_ok(north_warm > 0 and south_warm < north_warm,
		"CLOSEUP north-warm %d > south-warm %d (灯下亮→向南衰减)" % [north_warm, south_warm])

	# 4. 远处冷灰（链尾）：远离灯池的远段存在冷像素 b>r
	var far_pos := canvas_to_screen(Proj2D.project_world(Vector2(120, 60)))
	var far_cool := 0
	for dy in range(-6, 7):
		for dx in range(-6, 7):
			var sx := far_pos.x + dx
			var sy := far_pos.y + dy
			if sx < 0 or sy < 0 or sx >= img.get_width() or sy >= img.get_height():
				continue
			var c := img.get_pixel(sx, sy)
			if c.b > c.r + 0.02 and _luminance(c) > 0.10:
				far_cool += 1
	_ok(far_cool > 0, "CLOSEUP far cool-gray pixels present @screen(%d,%d) (远处冷灰链尾, cool %d)" % [far_pos.x, far_pos.y, far_cool])

	# 5. 设备顶面受光带 + 侧面暗（受光面明暗朝向）：treadmill(2,2) 顶面暖 vs 侧面冷
	# 顶面受光带画在朝灯侧（北缘）—— 采样点取顶面北半 (96,74)，避开顶面
	# 中段 hash 缺口；侧面取东缘 (128,96)。
	var equip_top := canvas_to_screen(Proj2D.proj(96.0, 74.0, 30.0))
	var equip_side := canvas_to_screen(Proj2D.proj(128.0, 96.0, 16.0))
	var top_warm := _count_warm(img, equip_top, 6)
	var side_warm := _count_warm(img, equip_side, 6)
	_ok(top_warm > 0 and side_warm < top_warm,
		"CLOSEUP equipment top warm %d > side warm %d (受光面顶亮侧暗)" % [top_warm, side_warm])

	# 6. 冷色投影（b>r 低明度）：设备南侧投影带
	var shadow_pos := canvas_to_screen(Proj2D.project_world(Vector2(96, 105)))
	var shadow_cool := 0
	for dy in range(-6, 7):
		for dx in range(-6, 7):
			var sx := shadow_pos.x + dx
			var sy := shadow_pos.y + dy
			if sx < 0 or sy < 0 or sx >= img.get_width() or sy >= img.get_height():
				continue
			var c := img.get_pixel(sx, sy)
			if c.b > c.r + 0.01 and _luminance(c) < 0.5:
				shadow_cool += 1
	_ok(shadow_cool > 0, "CLOSEUP cool cast shadow pixels present @screen(%d,%d) (冷色投影, cool %d)" % [shadow_pos.x, shadow_pos.y, shadow_cool])

	# 7. 前景暖带（三层景深：近景受光）
	var fore_pos := canvas_to_screen(Proj2D.project_world(Vector2(200, 270)))
	var fore_warm := _count_warm(img, fore_pos, 6)
	_ok(fore_warm > 0, "CLOSEUP foreground warm band present @screen(%d,%d) (前景受光, warm %d)" % [fore_pos.x, fore_pos.y, fore_warm])


func _verify_perf() -> void:
	var draw_calls := Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	var fps := Performance.get_monitor(Performance.TIME_FPS)
	_ok(draw_calls < 200, "PERF draw_calls=%d (<200) fps=%.1f budget_ok=%s" % [draw_calls, fps, str(draw_calls < 200)])


# === helpers ===

## 投影后 canvas 坐标 → 最终屏幕坐标（billboard 灯泡局部点不能用 world_to_screen）。
## 特写模式：WorldRoot scale=CLOSEUP_SCALE / position=CLOSEUP_POS，画布点经
## 该变换进 viewport，再经非等比放大到 1280×720。全场景模式用默认 WS/OFF。
func canvas_to_screen(p: Vector2) -> Vector2i:
	var v: Vector2
	if _closeup:
		v = (p * CLOSEUP_SCALE + CLOSEUP_POS) * Vector2(SX, SY)
	else:
		v = (p * WS + OFF) * Vector2(SX, SY)
	return Vector2i(roundi(v.x), roundi(v.y))


func _luminance(c: Color) -> float:
	return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b


func _near(a: Color, b: Color, tol: float) -> bool:
	var dr := a.r - b.r
	var dg := a.g - b.g
	var db := a.b - b.b
	return sqrt(dr * dr + dg * dg + db * db) <= tol


func _count_warm(img: Image, p: Vector2i, radius: int) -> int:
	var found := 0
	for y in range(maxi(p.y - radius, 0), mini(p.y + radius + 1, img.get_height())):
		for x in range(maxi(p.x - radius, 0), mini(p.x + radius + 1, img.get_width())):
			var c := img.get_pixel(x, y)
			if c.r > c.b + 0.02 and _luminance(c) > 0.24:
				found += 1
	return found
