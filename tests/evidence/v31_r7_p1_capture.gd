# tests/evidence/v31_r7_p1_capture.gd — V3.1 返工7 P1 证据捕获（手绘质感聚焦）
#
# 渲染真实主场景（src/main.tscn，V3.1 全链路 + 返工7 P1 噪点焦点层级：
# 散射光焦点权重 + 周边暗角让位 + 地板 cluster 稀疏 + 设备体零噪点 + 通道
# 留白）并保存：
#   - tests/evidence/v31-r7-p1-space.png   全场景帧（8 会员在场注入保留）
#   - tests/evidence/v31-r7-p1-closeup.png  设备带特写（轮廓/色阶/噪点退让/焦点区）
#   - tests/evidence/v31-r7-lightmap.png      LightingLayer 静态 light map
#     （qa_v31r4_independent.py / qa_v31r4p1_independent.py 独立复核输入）
#   - tests/evidence/v31-r7-projected-lightmap.png  投影空间灯泡→落点光束
#
# 复用 v31_gate_r2_capture.gd 的会员在场确定性注入（8 会员，同一 INJECTED
# 列表 —— 门禁最终帧字节一致；本卡只改证据布局 + R7 特写帧，不改注入）。
#
# 内嵌验证（对照返工7 P1 任务书四线 + 已通过项防回归）：
#   - 会员在场：衬衫色命中（非空场）
#   - 焦点层级（FAIL1）：远处地板（离焦点带最远）噪点密度 ≤ 焦点带附近
#   - 中央焦点（FAIL2）：设备带/暖池焦点区明度 > 周边同材质远处
#   - 轮廓/色阶（FAIL3）：设备前缘与地面明度分离 Δlum ≥ 25（bench 采样
#     同 r4p1 口径）、closeup 设备带多色阶
#   - R4 硬门保持：light map 灯池中心同心环覆盖率全部 < 0.95（keep 行不动）
#   - 投光关系保持：灯下暖亮 alpha > 墙边冷暗
#   - draw_calls < 200（V3 §15 性能预算）
#
# 用法（窗口模式——headless 下 get_image() 返回 null，4.7.1 已验证）：
#   godot --path . res://tests/evidence/v31_r7_p1_capture.tscn
extends Node

const MAIN_SCENE := preload("res://src/main.tscn")
const Palette := preload("res://src/palette.gd")
const WorldLayout := preload("res://src/presentation/world_layout.gd")
const Proj2D := preload("res://src/presentation/oblique_projection.gd")
const Main := preload("res://src/main.gd")
const OUT_FULL := "res://tests/evidence/v31-r7-p1-space.png"
const OUT_CLOSEUP := "res://tests/evidence/v31-r7-p1-closeup.png"
const LIGHTMAP_PATH := "res://tests/evidence/v31-r7-lightmap.png"
const PROJECTED_LIGHTMAP_PATH := "res://tests/evidence/v31-r7-projected-lightmap.png"
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

## 特写变换：聚焦世界设备带（treadmill(2,2)(6,3) / bike(2,5) 区域）。
## WorldRoot 默认 scale 0.75；特写 scale 2.0 → 世界 (426/2, 240/2)=(213,120)
## 可见；position 使 (128,128) 居中。
const CLOSEUP_SCALE := Vector2(2.0, 2.0)
const CLOSEUP_FOCUS := Vector2(128, 128)   # 世界坐标焦点
const CLOSEUP_POS := Vector2(213.0 - 128.0 * 2.0, 120.0 - 128.0 * 2.0)  # = (-43, -136)

## 注入会员（确定性采样；member_id 决定外观变体 → 差异化 silhouette）。
## 与 v31_gate_r2_capture.gd 完全一致 —— 8 会员在场，门禁最终帧字节一致。
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

## 灯池中心（WorldLayout.LIGHT_POOLS[0] = 力量区吊灯 1 落点）。
const LAMP_CENTER := Vector2(86, 170)
## 墙边暗角带内采样（左侧墙 x=10，strength zone 边缘 y=170）。
const WALL_EDGE_SAMPLE := Vector2(10, 170)

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
		push_error("v31_r7_p1_capture: WorldRoot not found")
		get_tree().quit(1)


## 显式放置 V3.1 预置设备（同 v31_gate_r2_capture.gd —— 门禁帧视觉元素全套）。
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
		_export_light_maps()
		_full_img = _grab()
		_save(_full_img, OUT_FULL)
		_verify_world_frame(_full_img)
		print("  R7 P1 full-scene captured (members present)")
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


## 导出 light map + 投影空间光束（qa_v31r4 / qa_v31r4p1 独立复核输入）。
func _export_light_maps() -> void:
	var lighting := _main.get_node_or_null("WorldViewport/WorldRoot/LightingLayer")
	if lighting == null:
		push_error("v31_r7_p1_capture: LightingLayer not found")
		return
	var img: Image = lighting.call("light_map_image")
	if img != null:
		_ok(img.save_png(ProjectSettings.globalize_path(LIGHTMAP_PATH)) == OK,
			"LIGHTMAP exported %s" % LIGHTMAP_PATH)
	var projected: Image = lighting.call("projected_light_map_image")
	if projected != null:
		_ok(projected.save_png(ProjectSettings.globalize_path(PROJECTED_LIGHTMAP_PATH)) == OK,
			"PROJECTED exported %s" % PROJECTED_LIGHTMAP_PATH)
	_verify_light_map(img)


func _grab() -> Image:
	var img := get_viewport().get_texture().get_image()
	if img == null:
		push_error("v31_r7_p1_capture: get_image() returned null (headless dummy driver?)")
		get_tree().quit(1)
		return null
	return img


func _save(img: Image, out_path: String) -> void:
	var abs_path := ProjectSettings.globalize_path(out_path)
	var err := img.save_png(abs_path)
	if err != OK:
		push_error("v31_r7_p1_capture: save_png failed err=%d path=%s" % [err, abs_path])
		get_tree().quit(1)
		return
	print("CAPTURE saved=%s size=%dx%d" % [out_path, img.get_width(), img.get_height()])


## 冻结 + 注入规范会员（与 v31_gate_r2_capture.gd 完全一致）。
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
	print("EQUIPMENT instances: %s" % [str(out)])
	return out


# === LightMap 级验证（R4 硬门保持：pixel-based 无圆形光斑 + 投光关系） ===

func _verify_light_map(img: Image) -> void:
	if img == null:
		_ok(false, "LIGHTMAP available")
		return
	# 灯下暖亮像素存在（热核 + 光晕）：灯池中心 12×12 窗口
	var lamp_warm := 0
	var lamp_alpha_sum := 0.0
	for dy in range(-6, 7):
		for dx in range(-6, 7):
			var p := Vector2i(int(LAMP_CENTER.x) + dx, int(LAMP_CENTER.y) + dy)
			var c: Color = img.get_pixel(p.x, p.y)
			if c.a > 0.03 and c.r > c.b:
				lamp_warm += 1
			lamp_alpha_sum += c.a
	var lamp_avg_a := lamp_alpha_sum / 169.0
	_ok(lamp_warm > 0, "LIGHTMAP under-lamp warm pixels exist (灯下稍亮, warm %d)" % lamp_warm)

	# 墙边冷暗（冷色阴影）：左墙边带冷蓝灰像素
	var edge_cool := 0
	var edge_sum := 0.0
	var edge_n := 0
	for dy in range(-6, 7):
		for dx in range(0, 8):
			var p := Vector2i(int(WALL_EDGE_SAMPLE.x) + dx, int(WALL_EDGE_SAMPLE.y) + dy)
			if p.x < 0 or p.y < 0 or p.x >= img.get_width() or p.y >= img.get_height():
				continue
			var c: Color = img.get_pixel(p.x, p.y)
			if c.a > 0.03 and c.b > c.r:
				edge_cool += 1
			edge_sum += c.a
			edge_n += 1
	var edge_avg_a := edge_sum / maxf(edge_n, 1)
	_ok(edge_cool > 0, "LIGHTMAP wall-edge cool-dark pixels exist (近墙冷色阴影, cool %d)" % edge_cool)
	_ok(lamp_avg_a > edge_avg_a,
		"LIGHTMAP lamp avg alpha %.3f > wall-edge avg alpha %.3f (灯下亮于墙边)" % [lamp_avg_a, edge_avg_a])

	# R4 硬门：同心环覆盖率全部 < 0.95（热核 keep 行不动 —— 无圆光斑）
	var ring_ratios: Array[float] = []
	for ring_r in [10, 22, 34, 44]:
		var covered := 0
		var total := 0
		var alphas: Array[float] = []
		for i in 48:
			var a := TAU * float(i) / 48.0
			var px := int(round(LAMP_CENTER.x + cos(a) * ring_r))
			var py := int(round(LAMP_CENTER.y + sin(a) * ring_r))
			if px < 0 or py < 0 or px >= img.get_width() or py >= img.get_height():
				continue
			total += 1
			var c: Color = img.get_pixel(px, py)
			alphas.append(c.a)
			if c.a > 0.02:
				covered += 1
		if total > 0:
			ring_ratios.append(float(covered) / float(total))
			var mean := 0.0
			for a2 in alphas:
				mean += a2
			mean /= float(alphas.size())
			var variance := 0.0
			for a2 in alphas:
				variance += (a2 - mean) * (a2 - mean)
			variance /= float(alphas.size())
			_ok(sqrt(variance) > 0.01,
				"LIGHTMAP ring r=%d alpha non-uniform (std %.3f > 0.01, scattered cluster)" % [ring_r, sqrt(variance)])
	_ok(ring_ratios.size() >= 3, "LIGHTMAP sampled >=3 concentric rings")
	for rr in ring_ratios:
		_ok(rr < 0.95, "LIGHTMAP ring coverage %.2f < 0.95 (not solid translucent circle)" % rr)


# === 渲染帧级验证（返工7 P1 四线 + 会员在场 + 投光关系保持） ===

func _verify_world_frame(img: Image) -> void:
	_verify_members(img)
	# 投光关系：灯下 vs 同材质远离灯（亮度 + 暖度对比）—— P3 语言保持
	var lamp_colors := _sample_window(img, LAMP_CENTER, 10, 3)
	var lamp_lum := _avg_luminance(lamp_colors)
	var lamp_warmness := _avg_warmness(lamp_colors)
	var far_min_lum := 1e9
	var far_min_warmness := 0.0
	for far in [Vector2(120, 90), Vector2(60, 130), Vector2(130, 140), Vector2(60, 200)]:
		var far_colors := _sample_window(img, far, 10, 3)
		far_min_lum = minf(far_min_lum, _avg_luminance(far_colors))
		far_min_warmness = minf(far_min_warmness, _avg_warmness(far_colors))
	_ok(lamp_lum > far_min_lum + 0.005,
		"WORLD lamp area brighter than far same-zone floor (lum %.3f > %.3f)" % [lamp_lum, far_min_lum])
	_ok(lamp_warmness > far_min_warmness + 0.002,
		"WORLD lamp area warmer than far same-zone floor (warm %.3f > %.3f, V3 §7 受光变暖)" % [lamp_warmness, far_min_warmness])
	# V3.1 返工7 P1 内嵌验证（非正式验收；gate PIL 为准）：
	_verify_r7_focus_noise(img)


## 返工7 P1（FAIL1/FAIL2/FAIL3 自测）：
##   a. 噪点焦点层级：远离焦点带的地板（flex 东侧 / strength 远角）噪点
##      密度应 ≤ 焦点带附近（散射光焦点权重 + 地板 cluster 稀疏生效）。
##      noise_density = 4-bit 桶数 / 采样像素数（r4p1 同口径）。
##   b. 中央焦点：设备带/暖池焦点区明度 > 周边同材质远处（r4p1 口径）。
##   c. 轮廓勾边：bench_press 前缘 vs 相邻地面 Δlum ≥ 25（r4p1 口径）。
func _verify_r7_focus_noise(img: Image) -> void:
	# (a) 噪点焦点层级：近带 = 中央设备带（treadmill(6,3) 附近地板），
	# 远带 = 远离焦点带的地板（flex 东侧 + strength 西侧远角）。
	# 任务口径：焦点区「细节密度显著高于周边」—— 焦点地板保留手绘
	# cluster 局部点缀；远景角落「近乎无噪点」（稀疏留白）。因此
	# 断言 far 角噪点密度 ≤ 焦点带（远处更干净），且近/远都有手绘
	# 存在（r4p1 的 near<far 是「设备邻域 vs 远处地板」另一口径，
	# 由独立脚本验证，本处只验证焦点层级方向）。
	var near := _sample_world_region(img, Rect2i(176, 150, 54, 40), 2)
	var far := _sample_world_region(img, Rect2i(300, 140, 50, 40), 2)
	var far2 := _sample_world_region(img, Rect2i(52, 240, 50, 40), 2)
	var near_d := _noise_density(near)
	var far_d := _noise_density(far)
	var far2_d := _noise_density(far2)
	# 返工7 目标：远景角落噪点密度 ≤ 焦点带（焦点保留局部点缀、远角留白）
	_ok(far_d <= near_d + 0.01,
		"R7 noise hierarchy far<=focus (far %.3f <= near %.3f, 远景角落留白)" % [far_d, near_d])
	_ok(far2_d <= near_d + 0.01,
		"R7 noise hierarchy far2<=focus (far2 %.3f <= near %.3f, 远景角落留白)" % [far2_d, near_d])
	# (b) 中央焦点：焦点区明度 > 周边（r4p1 口径）
	var focal_colors := _sample_window(img, Vector2(206, 150), 55, 4)
	var far_zone_colors := _sample_window(img, Vector2(200, 70), 55, 4)
	var focal_lum := _avg_luminance(focal_colors)
	var far_zone_lum := _avg_luminance(far_zone_colors)
	_ok(focal_lum > far_zone_lum,
		"R7 focus zone brighter than periphery (focal lum %.3f > far %.3f, 中央焦点)" % [focal_lum, far_zone_lum])
	# (c) 轮廓勾边 Δlum ≥ 25：bench_press(1,7) 前缘 vs 相邻地面（r4p1 同口径）
	var edge := _sample_world_region(img, Rect2i(36, 286, 56, 3), 2)
	var floor := _sample_world_region(img, Rect2i(36, 292, 56, 8), 2)
	var edge_lum := _avg_luminance(edge)
	var floor_lum := _avg_luminance(floor)
	var d := floor_lum - edge_lum
	_ok(d > 0.098, "R7 outline Δlum %.3f >= 0.098 (≈25/255, 轮廓与背景分离)" % d)


## 世界矩形区域采样 → 屏幕像素颜色列表（越界跳过）。
func _sample_world_region(img: Image, r: Rect2i, step: int) -> Array[Color]:
	var out: Array[Color] = []
	for wy in range(r.position.y, r.end.y, step):
		for wx in range(r.position.x, r.end.x, step):
			var p := _world_to_screen_full(Vector2(wx, wy))
			if _in_bounds(img, p):
				out.append(img.get_pixel(p.x, p.y))
	return out


## 噪点密度代理（r4p1 同口径）：4-bit 色桶数 / 采样像素数。
func _noise_density(colors: Array[Color]) -> float:
	if colors.is_empty():
		return 1.0
	var buckets := {}
	for c in colors:
		buckets[Vector2i(c.r8 >> 4, c.g8 >> 4 | ((c.b8 >> 4) << 4))] = true
	return float(buckets.size()) / float(colors.size())


func _verify_closeup(img: Image) -> void:
	# 特写聚焦设备带 —— 验证轮廓/色阶/噪点退让：
	#   a. 设备带内容非空（treadmill/bike 顶面、地面色层存在）
	#   b. 设备前缘轮廓（EQUIP_EDGE_OUTLINE 深蓝灰）与地面分离可辨
	#   c. 多色阶（受光面/主体/暗面）多样性 —— 独立 5-bit 桶数
	var found_equip := false
	var buckets := {}
	for dy in range(0, img.get_height(), 2):
		for dx in range(0, img.get_width(), 2):
			var c := img.get_pixel(dx, dy)
			var lum := 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
			if lum > 0.25 and lum < 0.95 and (c.s > 0.08 or lum < 0.45):
				found_equip = true
			buckets[Vector2i(c.r8 >> 3, c.g8 >> 3 | ((c.b8 >> 3) << 5))] = true
	_ok(found_equip, "CLOSEUP equipment belt content present (特写设备带非空)")
	_ok(buckets.size() >= 60, "CLOSEUP color variety %d buckets >= 60 (色阶分层, N4 手绘语言)" % buckets.size())
	# 轮廓勾边：设备带内应存在深色轮廓（EQUIP_EDGE_OUTLINE 2C333D 系）
	var outline_found := false
	for dy in range(0, img.get_height(), 2):
		for dx in range(0, img.get_width(), 2):
			var c := img.get_pixel(dx, dy)
			if absf(c.r - 0.173) < 0.10 and absf(c.g - 0.20) < 0.10 and absf(c.b - 0.24) < 0.10:
				outline_found = true
				break
		if outline_found:
			break
	_ok(outline_found, "CLOSEUP equipment outline tone present (设备外轮廓勾边可辨)")


func _verify_members(img: Image) -> void:
	var checks := [
		{"state": "WALKING_TO", "cell": Vector2i(5, 2), "expect": Color("8EC5E8")},
		{"state": "QUEUEING", "cell": Vector2i(3, 6), "expect": Color("8494A6")},
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

func _w2s(w: Vector2, z: float) -> Vector2i:
	var v := w * CLOSEUP_SCALE + CLOSEUP_POS
	v.x *= 1280.0 / 426.0
	v.y *= 720.0 / 240.0
	return Vector2i(roundi(v.x), roundi(v.y))


func _sample_window(img: Image, world_center: Vector2, world_r: int, step: int) -> Array[Color]:
	var out: Array[Color] = []
	for dy in range(-world_r, world_r + 1, step):
		for dx in range(-world_r, world_r + 1, step):
			var p := _world_to_screen_full(world_center + Vector2(dx, dy))
			if _in_bounds(img, p):
				out.append(img.get_pixel(p.x, p.y))
	return out


func _world_to_screen_full(w: Vector2) -> Vector2i:
	return _world_to_screen_full_z(w, 0.0)


func _world_to_screen_full_z(w: Vector2, z: float) -> Vector2i:
	var v := Proj2D.world_to_screen(w, OFF, WS, Vector2(SX, SY), z)
	return Vector2i(roundi(v.x), roundi(v.y))


func _avg_luminance(colors: Array[Color]) -> float:
	if colors.is_empty():
		return 0.0
	var sum := 0.0
	for c in colors:
		sum += _luminance(c)
	return sum / float(colors.size())


func _luminance(c: Color) -> float:
	return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b


func _avg_warmness(colors: Array[Color]) -> float:
	if colors.is_empty():
		return 0.0
	var sum := 0.0
	for c in colors:
		sum += c.r - c.b
	return sum / float(colors.size())


func _in_bounds(img: Image, p: Vector2i) -> bool:
	return p.x >= 0 and p.y >= 0 and p.x < img.get_width() and p.y < img.get_height()


func _near(a: Color, b: Color, tol: float) -> bool:
	var dr := a.r - b.r
	var dg := a.g - b.g
	var db := a.b - b.b
	return sqrt(dr * dr + dg * dg + db * db) <= tol


func _ok(cond: bool, msg: String) -> void:
	if not cond:
		_all_ok = false
	print("  %s %s" % ["PASS" if cond else "FAIL", msg])
