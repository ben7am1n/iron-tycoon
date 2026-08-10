# tests/evidence/v31_r4_p4_capture.gd — V3.1 返工4 P4（HUD 条带像素级破形 +
# 世界/HUD 交界线打散）证据捕获
#
# 渲染真实主场景（src/main.tscn，V3.1 P1 oblique + P2 设备 + P3 手绘密度 +
# P4 pixel lighting + P5 高饱和焦点全链路）并保存视口快照，像素级验证
# V3.1 返工4 P4 门禁（第四轮 GPT 视觉 FAIL 修复）：
#
#   1. 顶部/底部 HUD 条带外轮廓像素级不规则（边缘 2-3px 锯齿/破损，四角
#      不齐 —— 条带读作轻微不规则多边形而非完美矩形）
#   2. 场地中央笔直分区边缘（世界层与 HUD 交界 / 挂牌下平齐墙色带）打散：
#      短线段错落 / 材质过渡 —— 不再一条完整直线贯穿
#   3. 挂牌撕裂轮廓强度提升（GPT 可辨）
#   4. 底部展示架每段垂直错落（非等高校直线）
#
# 输出：
#   tests/evidence/v31-r4-p4-ui.png          —— 渲染帧（主场景视口 1280×720，
#                                               会员在场：8 会员确定性注入）
#   tests/evidence/v31-r4-p4-ui-hud-zoom.png —— HUD 特写（顶栏挂牌 + 底部
#                                               展示架，2× NEAREST 放大）
#
# 用法（窗口模式——headless 用 dummy 渲染驱动，get_image() 返回 null，
# 4.7.1 已验证；窗口捕获是项目既有证据方法）：
#   godot --path . res://tests/evidence/v31_r4_p4_capture.tscn
#
# 会员注入复用 v31_gate_r2_capture.gd 的确定性采样（8 会员：walk/queue/leave/
# using 活动姿态；member_id 决定外观变体 → 差异化 silhouette）。
extends Node

const MAIN_SCENE := preload("res://src/main.tscn")
const Palette := preload("res://src/palette.gd")
const WorldLayout := preload("res://src/presentation/world_layout.gd")
const Proj2D := preload("res://src/presentation/oblique_projection.gd")
const Main := preload("res://src/main.gd")
const OUT_PATH := "res://tests/evidence/v31-r4-p4-ui.png"
const ZOOM_PATH := "res://tests/evidence/v31-r4-p4-ui-hud-zoom.png"
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

	# 5) V3.1 返工4 P4 FAIL#1：顶带外轮廓锯齿 —— 顶缘非水平直线（2-3px+ 抖动）。
	# 逐列找 HUD 材质（木/板面）最上缘；统计「相邻列 1-2px 台阶」数量。
	# 撕裂轮廓（4px texel 步进）在同一 texel 内 4 列同高 → 台阶为 0 或 ≥4px；
	# pixel-break（1-3px 咬口）制造 1-2px 相邻列台阶 —— 该计数专门检测
	# 像素级破形（GPT 可辨的 2-3px 抖动），排除元素自然高度差。
	var edge_jagged := 0
	var edge_cols := 0
	var prev_edge := -1
	for x in range(0, 1280, 1):
		var found := -1
		for y in range(0, 16):
			if _is_hud_mat(img.get_pixel(x, y)):
				found = y
				break
		if found >= 0:
			edge_cols += 1
			if prev_edge >= 0 and absi(found - prev_edge) >= 1 and absi(found - prev_edge) <= 2:
				edge_jagged += 1
			prev_edge = found
		else:
			prev_edge = -1
	_ok(edge_cols > 100 and edge_jagged >= 20,
		"R4 P4 top-strip edge sawtooth (1-2px steps %d >= 20 of %d cols, 2-3px+ 抖动)" % [edge_jagged, edge_cols])

	# 6) V3.1 返工4 P4 FAIL#1：四角不齐 —— 顶带内容包围盒四角不应是完整
	# 直角矩形。pixel-break 角部咬口（3-5px）+ 撕裂轮廓（3-4 texel 角咬）
	# → 四个角覆盖应显著低于完整 8×8（64）。若任一角覆盖 < 48（缺 ≥25%）
	# 即证明无规则直角（R3 撕裂已咬角，本检查是防回归：不得恢复完整矩形）。
	var bbox := _hud_mat_bbox(img, 60)
	if bbox.size == Vector2i.ZERO:
		_ok(false, "R4 P4 top-strip bbox empty (cannot check corners)")
	else:
		var corners: Array[int] = [
			_hud_count(img, Rect2i(bbox.position, Vector2i(8, 8))),
			_hud_count(img, Rect2i(Vector2i(bbox.end.x - 8, bbox.position.y), Vector2i(8, 8))),
			_hud_count(img, Rect2i(Vector2i(bbox.position.x, bbox.end.y - 8), Vector2i(8, 8))),
			_hud_count(img, Rect2i(Vector2i(bbox.end.x - 8, bbox.end.y - 8), Vector2i(8, 8))),
		]
		var cmin := 9999
		for c in corners:
			cmin = mini(cmin, c)
		_ok(cmin < 48,
			"R4 P4 top-strip corners bitten (min corner coverage %d < 48, 四角不齐)" % cmin)

	# 7) V3.1 返工4 P4 FAIL#2：顶部世界/HUD 交界线打散 —— 挂牌下方墙色带
	# 任意扫描行最长墙色 run < 200px（旧帧 316px @ y=52..64）。交界破形带
	# （错落短段）把平齐直线切成短线段。
	var top_junction_max := _max_wall_run(img, 46, 78)
	_ok(top_junction_max < 200,
		"R4 P4 top junction line broken (max wall run %dpx < 200, 短线段错落)" % top_junction_max)

	# 8) V3.1 返工4 P4 FAIL#2：底部世界/HUD 交界线打散 —— 架条上方墙色带
	# （世界地板底缘与架条之间）任意行最长墙色 run < 200px（旧帧 739px）。
	var bottom_junction_max := _max_wall_run(img, 684, 702)
	_ok(bottom_junction_max < 200,
		"R4 P4 bottom junction line broken (max wall run %dpx < 200)" % bottom_junction_max)


## 会员在场：衬衫色命中（活动姿态可见 —— 非空场）。
## 注意：QUEUEING → state_channel → CH_DUSTY（MEMBER_WAIT_DUSTY 8494A6），
## 不是 PEACH —— 旧 R3 P4 脚本期望 F2B486 是历史笔误（P3 lighting 合并后
## 该检查实际一直失败；此处按 state_channel 修正）。
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


## V3.1 返工4 P4：HUD 材质判定（顶带锯齿/四角检查用）—— 挂牌暖木 +
## 公告板软木 + 黑板板面（slate）+ 钟面 Butter。与墙面（WALL 系）和
## 背景 cream（F4E9D8 —— 顶带外背景色，绝不能当作 HUD 材质）严格区分。
func _is_hud_mat(c: Color) -> bool:
	if _is_wood_tone(c):
		return true
	if _near(c, Color("C8A97C"), 0.14):
		return true  # 软木板面
	if _near(c, Color("4A5450"), 0.14):
		return true  # 黑板板面
	if _near(c, Color("F5D97B"), 0.16):
		return true  # Butter（钟面/粉笔痕）
	return false


## V3.1 返工4 P4：顶带 HUD 材质包围盒（限 [0..max_y) 行 —— 排除底部交界
## 破形带误入）。逐像素扫描，返回内容包围盒（可能为空）。
func _hud_mat_bbox(img: Image, max_y: int) -> Rect2i:
	var w := img.get_width()
	var h := mini(img.get_height(), max_y)
	var min_x := 9999
	var min_y := 9999
	var max_x := -1
	var max_y_found := -1
	for y in h:
		for x in w:
			if _is_hud_mat(img.get_pixel(x, y)):
				min_x = mini(min_x, x)
				min_y = mini(min_y, y)
				max_x = maxi(max_x, x)
				max_y_found = maxi(max_y_found, y)
	if max_x < 0:
		return Rect2i()
	return Rect2i(min_x, min_y, max_x - min_x + 1, max_y_found - min_y + 1)


## V3.1 返工4 P4：矩形区域内 HUD 材质像素计数。
func _hud_count(img: Image, r: Rect2i) -> int:
	var count := 0
	for y in range(maxi(0, r.position.y), mini(img.get_height(), r.end.y)):
		for x in range(maxi(0, r.position.x), mini(img.get_width(), r.end.x)):
			if _is_hud_mat(img.get_pixel(x, y)):
				count += 1
	return count


## V3.1 返工4 P4：扫描 [y0..y1) 各行，返回最长「墙色带」连续 run（px）。
## 墙色带 = WALL_BASE 加深族（世界层与 HUD 交界的平齐墙色带 —— 旧帧
## 316px@y52..64 / 739px@y684..700）。破形后任意行 run 应 < 200px。
func _max_wall_run(img: Image, y0: int, y1: int) -> int:
	var w := img.get_width()
	var max_run := 0
	for y in range(y0, mini(y1, img.get_height())):
		var run := 0
		for x in w:
			if _is_junction_wall_tone(img.get_pixel(x, y)):
				run += 1
				max_run = maxi(max_run, run)
			else:
				run = 0
	return max_run


## 交界墙色带：WALL_BASE 加深 0.35-0.45 族（含吊顶/墙根阴影）—— 与挂牌
## 暖木 / 深色面板 / 奶油背景严格区分。实测交界带 (105..113, 93..100,
## 83..89)；加深 0.38 → (97,86,77)，lightened 至 (110..113, 97..100,
## 87..89) 均属此带（天花板纹理 +0.14 alpha 提亮）。
func _is_junction_wall_tone(c: Color) -> bool:
	var r8 := int(c.r * 255.0)
	var g8 := int(c.g * 255.0)
	var b8 := int(c.b * 255.0)
	# WALL_BASE (157,139,124) 加深 0.32-0.46 → (85..107, 75..95, 67..84)，
	# 含天花板纹理提亮 ~+8 → r8 ≤ 115
	if r8 < 84 or r8 > 118 or g8 < 74 or g8 > 104 or b8 < 66 or b8 > 94:
		return false
	return r8 > g8 and g8 > b8

func _ok(cond: bool, msg: String) -> void:
	if not cond:
		_all_ok = false
	print("  %s %s" % ["PASS" if cond else "FAIL", msg])


func _near(a: Color, b: Color, tol: float) -> bool:
	var dr := a.r - b.r
	var dg := a.g - b.g
	var db := a.b - b.b
	return sqrt(dr * dr + dg * dg + db * db) <= tol
