# tests/evidence/v31_r3_p4_capture.gd — V3.1 返工3 P4（UI 去程序感）证据捕获
#
# 渲染真实主场景（src/main.tscn，V3.1 P1 oblique + P2 设备 + P3 手绘密度 +
# P4 pixel lighting + P5 高饱和焦点全链路）并保存视口快照，像素级验证
# V3.1 返工3 P4 门禁（第三轮 GPT 视觉 FAIL 修复 —— HUD 去「条+卡片」语言）：
#
#   1. 顶部状态栏 → 三块独立手绘木牌（金钱/满意度/时间），牌间露出墙面 ——
#      不再是全宽 CSS 横条（门禁 FAIL：顶部状态栏=CSS 仪表盘）
#   2. 右上倍速控制 → 场景内时钟（时间牌上的圆钟 + 手写标签）—— 不再是按钮
#   3. 底部商品栏 → 薄木展示架（前台货架/价目板）+ tile 手绘价签 —— 不再是
#      全宽深色条带 + 卡片边界
#   4. 无大量完美直线 / 规则矩形 / 等宽边框（挂牌撕裂轮廓 + 手绘阴影）
#   5. UI 不主导第一眼（暖木色 + 低 alpha 半融入背景，挂牌尺寸收敛）
#
# 输出：
#   tests/evidence/v31-r3-p4-ui.png          —— 渲染帧（主场景视口 1280×720，
#                                               会员在场：8 会员确定性注入）
#   tests/evidence/v31-r3-p4-ui-hud-zoom.png —— HUD 特写（顶栏挂牌 + 底部
#                                               展示架，2× NEAREST 放大）
#
# 用法（窗口模式——headless 用 dummy 渲染驱动，get_image() 返回 null，
# 4.7.1 已验证；窗口捕获是项目既有证据方法）：
#   godot --path . res://tests/evidence/v31_r3_p4_capture.tscn
#
# 会员注入复用 v31_gate_r2_capture.gd 的确定性采样（8 会员：walk/queue/leave/
# using 活动姿态；member_id 决定外观变体 → 差异化 silhouette）。
extends Node

const MAIN_SCENE := preload("res://src/main.tscn")
const Palette := preload("res://src/palette.gd")
const WorldLayout := preload("res://src/presentation/world_layout.gd")
const Proj2D := preload("res://src/presentation/oblique_projection.gd")
const Main := preload("res://src/main.gd")
const OUT_PATH := "res://tests/evidence/v31-r3-p4-ui.png"
const ZOOM_PATH := "res://tests/evidence/v31-r3-p4-ui-hud-zoom.png"
const REDRAW_FRAME := 6      # 抓帧前强制世界画布重绘（SubViewport 纹理滞后 ≥1 帧）
const INJECT_FRAME := 8      # 注入会员 + 强制重绘（抓全场景帧前完成注入）
const CAPTURE_FRAME := 18    # 面板淡入（0.18s ≈ 11 帧）+ 布局稳定后再抓帧
const CELL_SIZE := 32

## 管线常量（来自 main.gd —— 证据复算与实现同源）。
const SX := Main.SCREEN_PER_VIEWPORT_X
const SY := Main.SCREEN_PER_VIEWPORT_Y
const OFF := Main.WORLD_VIEWPORT_OFFSET
const WS := Main.WORLD_SCALE

## 注入会员（与 v31_gate_r2_capture.gd 同源 —— 8 会员必须在场）。
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

## HUD 采样坐标（屏幕空间 1280×720，与视口像素一一对应）。
## 顶栏三块挂牌的预期位置（HBox 布局：MoneyGroup 左 / SatGroup 中 / TimeGroup 右）。
const MONEY_PLAQUE_X0 := 12
const MONEY_PLAQUE_X1 := 180
const SAT_PLAQUE_X0 := 430
const SAT_PLAQUE_X1 := 640
const TIME_PLAQUE_X0 := 940
const TIME_PLAQUE_X1 := 1268
const TOP_BAND_Y0 := 0
const TOP_BAND_Y1 := 52
## 挂牌间墙面色（WALL_BASE 系 —— 露出墙面 = 非全宽条带）。
const WALL_TOL := 0.22
## 底部展示架（palette strip y = 720-88 = 632..720；架条 = 底部 16px）。
const SHELF_Y0 := 700
const SHELF_Y1 := 718

var _frame := 0
var _captured := false
var _injected := false
var _main: Node = null
var _sim = null
var _world_root: Node2D = null
var _all_ok := true


func _ready() -> void:
	_main = MAIN_SCENE.instantiate()
	add_child(_main)
	_sim = _main.get("_member")
	var orch = _main.get("_orch")
	if orch != null and orch.time_system != null:
		orch.time_system.pause()  # 模拟暂停 —— 采样点稳定
	# 预置设备（同 v31_gate_r2_capture：保证 P2 设备带 + P5 焦点在场）
	_place_preset_equipment()
	_world_root = _main.get_node_or_null("WorldViewport/WorldRoot")
	if _world_root == null:
		push_error("v31_r3_p4_capture: WorldRoot not found")
		get_tree().quit(1)


## 显式放置 V3.1 预置设备（同 v31_gate_r2_capture）。
func _place_preset_equipment() -> void:
	var orch = _main.get("_orch")
	if orch == null or orch.placement_system == null:
		return
	var placement = orch.placement_system
	var grid = orch.grid_system
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
		_capture_and_report()


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


## 冻结 + 注入规范会员（同 v31_gate_r2_capture —— 8 会员确定性注入）。
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
		push_error("v31_r3_p4_capture: get_image() returned null (headless dummy driver?)")
		get_tree().quit(1)
		return null
	return img


func _capture_and_report() -> void:
	var img := _grab()
	if img == null:
		return
	_save_and_report(img)


func _save_and_report(img: Image) -> void:
	var abs_path := ProjectSettings.globalize_path(OUT_PATH)
	var err := img.save_png(abs_path)
	if err != OK:
		push_error("v31_r3_p4_capture: save_png failed err=%d path=%s" % [err, abs_path])
		get_tree().quit(1)
		return
	print("CAPTURE saved=%s size=%dx%d" % [OUT_PATH, img.get_width(), img.get_height()])
	_save_hud_zoom(img)
	_verify_hud(img)
	_verify_members(img)
	_verify_perf()
	print("RESULT: %s" % ("PASS" if _all_ok else "CHECK"))
	get_tree().quit(0 if _all_ok else 1)


## HUD 特写：顶栏（y 0..64）+ 底部建造条（y 600..720）拼成一张 2× NEAREST
## 放大图，供人工核对「场景内挂牌语言，非网页仪表盘」。
func _save_hud_zoom(img: Image) -> void:
	var zoom := Image.create(1280 * 2, 184 * 2, false, Image.FORMAT_RGBA8)
	for y in 64:
		for x in 1280:
			var c: Color = img.get_pixel(x, y)
			for dy in 2:
				for dx in 2:
					zoom.set_pixel(x * 2 + dx, y * 2 + dy, c)
	for y in 120:
		for x in 1280:
			var c: Color = img.get_pixel(x, 600 + y)
			for dy in 2:
				for dx in 2:
					zoom.set_pixel(x * 2 + dx, (64 + y) * 2 + dy, c)
	var zerr := zoom.save_png(ProjectSettings.globalize_path(ZOOM_PATH))
	_ok(zerr == OK, "ZOOM saved %s" % ZOOM_PATH)


# === HUD 像素级验证（V3.1 返工3 P4 门禁） ===

## 1) 顶栏不再是全宽横条：三块挂牌之间的区域露出墙面（挂牌间墙色命中）
## 2) 挂牌 = 撕裂轮廓（挂牌带边缘存在「非木色」缺口 —— 手绘撕裂，非完美矩形）
## 3) 无大量完美直线 / 等宽边框：挂牌顶缘非连续直线（jitter）
## 4) 底部展示架：架条薄（~16px），架上方露出墙面/地板 —— 非全宽深色条带
## 5) 速度控制 → 场景内时钟：时间牌区域存在圆钟（Butter 弧/刻度）
func _verify_hud(img: Image) -> void:
	# 1) 挂牌间露出墙面（Money 与 Sat 之间、Sat 与 Time 之间的中部区域）
	var wall_between := 0
	var wall_samples := 0
	for y in range(TOP_BAND_Y0 + 12, TOP_BAND_Y1 - 4, 4):
		for x in [340, 360, 700, 720, 740]:
			wall_samples += 1
			var c: Color = img.get_pixel(x, y)
			# 墙色系（WALL_BASE 暖灰/远景暗墙）—— 与挂牌暖木色区分
			if _is_wall_tone(c):
				wall_between += 1
	_ok(wall_samples > 0 and wall_between >= wall_samples * 0.4,
		"P4 top bar is NOT a full-width strip (wall shows between plaques %d/%d)" % [wall_between, wall_samples])

	# 2) 挂牌撕裂轮廓：三块挂牌各自顶缘存在非木色缺口（透明/墙色穿出）
	var torn_gaps := 0
	for x in range(MONEY_PLAQUE_X0 + 2, MONEY_PLAQUE_X1 - 2, 4):
		var c: Color = img.get_pixel(x, TOP_BAND_Y0 + 4)
		if not _is_wood_tone(c):
			torn_gaps += 1
	_ok(torn_gaps >= 3, "P4 money plaque edge has torn gaps (%d >= 3, 非完美矩形)" % torn_gaps)

	# 3) 无等宽边框：挂牌顶缘 Butter 覆盖率低（无实心亮色描边）
	var butter_top := 0
	var butter_total := 0
	for x in range(MONEY_PLAQUE_X0, MONEY_PLAQUE_X1 + 200, 2):
		for y in [TOP_BAND_Y0 + 2, TOP_BAND_Y0 + 3]:
			butter_total += 1
			if _near(img.get_pixel(x, y), Color("f5d97b"), 0.16):
				butter_top += 1
	_ok(butter_total > 0 and float(butter_top) / float(butter_total) < 0.12,
		"P4 no equal-width Butter border on plaques (coverage %.3f)" % (float(butter_top) / float(butter_total)))

	# 4) 底部展示架薄 + 架上方露出场景（非全宽深色条带）
	var floor_above := 0
	var floor_samples := 0
	for y in range(644, 692, 4):
		for x in [200, 400, 640, 900, 1100]:
			floor_samples += 1
			var c: Color = img.get_pixel(x, y)
			if not _is_dark_panel(c):
				floor_above += 1
	_ok(floor_samples > 0 and floor_above >= floor_samples * 0.5,
		"P4 bottom is NOT a full-width dark strip (scene shows above shelf %d/%d)" % [floor_above, floor_samples])
	# 架条存在：底部 16px 带内木色命中
	var shelf_hits := 0
	for y in range(SHELF_Y0, SHELF_Y1, 2):
		for x in [100, 300, 500, 700, 900, 1100]:
			if _is_shelf_wood(img.get_pixel(x, y)):
				shelf_hits += 1
	_ok(shelf_hits >= 4, "P4 bottom shelf plank present (%d hits, 前台货架语言)" % shelf_hits)


## 会员在场：衬衫色命中（活动姿态可见 —— 非空场）。
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
		_ok(found, "MEMBER %-12s shirt visible @(%3d,%3d)" % [entry["state"], p.x, p.y])


func _member_shirt_screen(cell: Vector2i) -> Vector2i:
	var feet := Vector2(cell.x * CELL_SIZE + CELL_SIZE * 0.5,
		cell.y * CELL_SIZE + CELL_SIZE)
	var anchor := Proj2D.proj(feet.x, feet.y, 0.0) - Vector2(24, 48)
	var v := ((anchor + Vector2(24, 19)) * WS + OFF) * Vector2(SX, SY)
	return Vector2i(roundi(v.x), roundi(v.y))


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


func _verify_perf() -> void:
	var draw_calls := Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	var fps := Performance.get_monitor(Performance.TIME_FPS)
	var perf_ok := draw_calls < 200
	_ok(perf_ok, "PERF draw_calls=%d fps=%.1f budget_ok=%s" % [draw_calls, fps, str(perf_ok)])


# === helpers ===

## 墙色系：WALL_BASE (#9D8B7C 暖灰) / WALL_BASE_FAR (#747272 远景暗墙)。
func _is_wall_tone(c: Color) -> bool:
	return _near(c, Color("9D8B7C"), 0.20) or _near(c, Color("747272"), 0.20) \
		or _near(c, Color("9D8B7C").darkened(0.12), 0.16) \
		or _near(c, Color("9D8B7C").lightened(0.10), 0.16)

## 木色系（挂牌/价签/架条）：DESK_WOOD (#A87E4F) 加深/提亮族。用通道区间
## 判定（r 110-155 / g 78-118 / b 42-95）—— 与墙面（WALL_BASE 暖灰 r>140
## g>120 b>105）和深色面板严格区分，避免距离容差误判墙为木。
func _is_wood_tone(c: Color) -> bool:
	var r8 := int(c.r * 255.0)
	var g8 := int(c.g * 255.0)
	var b8 := int(c.b * 255.0)
	if r8 < 108 or r8 > 160 or g8 < 74 or g8 > 122:
		return false
	if b8 < 40 or b8 > 100:
		return false
	return r8 > g8 and g8 > b8

## 架条木色系（展示架 = DESK_WOOD.lightened(0.10)，比挂牌浅）：r 150-195 /
## g 110-150 / b 70-115，r>g>b。与挂牌木色（更暗）区分。
func _is_shelf_wood(c: Color) -> bool:
	var r8 := int(c.r * 255.0)
	var g8 := int(c.g * 255.0)
	var b8 := int(c.b * 255.0)
	if r8 < 148 or r8 > 200 or g8 < 108 or g8 > 155:
		return false
	if b8 < 68 or b8 > 120:
		return false
	return r8 > g8 and g8 > b8

## 深色面板：旧 CSS 条带的近黑 charcoal 系 —— 不应在架上方大量出现。
func _is_dark_panel(c: Color) -> bool:
	return c.r < 0.28 and c.g < 0.28 and c.b < 0.30

func _ok(cond: bool, msg: String) -> void:
	if not cond:
		_all_ok = false
	print("  %s %s" % ["PASS" if cond else "FAIL", msg])


func _near(a: Color, b: Color, tol: float) -> bool:
	var dr := a.r - b.r
	var dg := a.g - b.g
	var db := a.b - b.b
	return sqrt(dr * dr + dg * dg + db * db) <= tol
