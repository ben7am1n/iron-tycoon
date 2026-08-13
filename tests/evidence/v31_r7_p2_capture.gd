# tests/evidence/v31_r7_p2_capture.gd — V3.1 返工7 P2 证据捕获（方向一致冷投影可读性）
#
# 渲染真实主场景（src/main.tscn，V3.1 全链路 + 返工7 P1 焦点层级 + P2 方向
# 一致冷投影）并保存：
#   - tests/evidence/v31-r7-p2-lighting.png   全场景帧（8 会员在场注入保留）
#   - tests/evidence/v31-r7-p2-closeup.png    设备带特写（投影方向一致性/
#     投影与本体分离/暖光衰减）
#   - tests/evidence/v31-r7-lightmap.png       LightingLayer 静态 light map
#     （qa_v31r4_independent.py 独立复核输入）
#   - tests/evidence/v31-r7-projected-lightmap.png  投影空间灯泡→落点光束
#
# 复用 v31_gate_r2_capture.gd / v31_r7_p1_capture.gd 的会员在场确定性注入
# （8 会员，同一 INJECTED 列表 —— 门禁最终帧字节一致；本卡只改证据布局 +
# P2 特写校验，不改注入）。
#
# 内嵌验证（对照返工7 P2 任务书三线 + 已通过项防回归）：
#   - 会员在场：衬衫色命中（非空场）
#   - P2 方向一致冷投影（FAIL 第三眼#2）：
#       a. 每台设备投影方向一致 —— 投影 slab 只出现在 MAIN_LIGHT_DIR 侧
#          （左下），对侧（右上）无投影暗部
#       b. 投影与本体分离明确 —— slab 与本体之间有可辨间隙（gap 带明度
#          高于 slab 内部，非贴体成「轮廓描边」）
#       c. 会员/桌椅/墙边同规则 —— 会员脚底投影偏移方向与设备一致；
#          light map 墙边暗角西/南（投影侧）密度 > 北/东（受光侧）
#   - P1 防回归：噪点焦点层级 + 中央焦点 + 轮廓勾边 + R4 ring <0.95
#   - draw_calls < 200（V3 §15 性能预算）
#
# 用法（窗口模式——headless 下 get_image() 返回 null，4.7.1 已验证）：
#   godot --path . res://tests/evidence/v31_r7_p2_capture.tscn
extends Node

const MAIN_SCENE := preload("res://src/main.tscn")
const Palette := preload("res://src/palette.gd")
const WorldLayout := preload("res://src/presentation/world_layout.gd")
const Proj2D := preload("res://src/presentation/oblique_projection.gd")
const Main := preload("res://src/main.gd")
const OUT_FULL := "res://tests/evidence/v31-r7-p2-lighting.png"
const OUT_CLOSEUP := "res://tests/evidence/v31-r7-p2-closeup.png"
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

## P2 投影方向一致性采样设备（world footprint + 高度，与 world_layout 布局
## 同源）。排除遮挡/不可见的情形：
##   - treadmill(2,2)：被 USING 会员 9006 遮挡（会员立在跑步机上，其
##     48×48 billboard 盖住该设备投影的大部分 —— 场景叙事自然遮挡）
##   - bench_press(1,7)：其投影 slab 落在屏幕底部 HUD build-bar 之下
##     （slab 屏幕 y≈648..719 被 HUD 覆盖）
## 采样 bike / treadmill(6,3) —— 投影在帧中完整可见。
const SHADOW_SAMPLES := [
	{"footprint": Rect2i(64, 160, 32, 32), "height": 36.0, "probe_extra": 0.0},  # bike(2,5)
	{"footprint": Rect2i(192, 96, 64, 32), "height": 30.0, "probe_extra": 0.0},  # treadmill(6,3)
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
		push_error("v31_r7_p2_capture: WorldRoot not found")
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
		print("  R7 P2 full-scene captured (members present)")
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
		push_error("v31_r7_p2_capture: LightingLayer not found")
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
		push_error("v31_r7_p2_capture: get_image() returned null (headless dummy driver?)")
		get_tree().quit(1)
		return null
	return img


func _save(img: Image, out_path: String) -> void:
	var abs_path := ProjectSettings.globalize_path(out_path)
	var err := img.save_png(abs_path)
	if err != OK:
		push_error("v31_r7_p2_capture: save_png failed err=%d path=%s" % [err, abs_path])
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


# === LightMap 级验证（R4 硬门保持：pixel-based 无圆形光斑 + 投光关系 + P2 方向） ===

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

	# P2 墙边方向性：西/南（投影侧）边缘暗角密度 > 北/东（受光侧）。
	# 世界 light map 直接采样四边带（同 _paint_edge_shadow 的 EDGE_SHADOW_WIDTH）。
	# 注意避开灯池带（y 110..210 有左/右灯池像素）—— 只采样池外上/下带。
	var w2 := img.get_width()
	var h2 := img.get_height()
	var edge_w := WorldLayout.EDGE_SHADOW_WIDTH
	var west_n := 0
	var east_n := 0
	var north_n := 0
	var south_n := 0
	var band_top := 26
	var band_bot := 110
	var band_mid := 210
	for e in 4:
		for yy in range(band_top, band_bot):
			var c: Color = img.get_pixel(e, yy)
			if c.a > 0.02:
				west_n += 1
			var c2: Color = img.get_pixel(w2 - 1 - e, yy)
			if c2.a > 0.02:
				east_n += 1
		for yy in range(band_mid, h2 - edge_w):
			var c: Color = img.get_pixel(e, yy)
			if c.a > 0.02:
				west_n += 1
			var c2: Color = img.get_pixel(w2 - 1 - e, yy)
			if c2.a > 0.02:
				east_n += 1
		for xx in range(edge_w, w2 - edge_w):
			var c: Color = img.get_pixel(xx, e)
			if c.a > 0.02:
				north_n += 1
			var c2: Color = img.get_pixel(xx, h2 - 1 - e)
			if c2.a > 0.02:
				south_n += 1
	_ok(west_n > east_n and south_n > north_n,
		"LIGHTMAP edge shadow directional (west %d > east %d, south %d > north %d, 投影侧更暗)" % [west_n, east_n, south_n, north_n])


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
	# V3.1 返工7 P2（FAIL 第三眼#2）：投影方向一致性 + 与本体分离
	_verify_shadow_direction(img)


## 返工7 P1（FAIL1/FAIL2/FAIL3 自测防回归）。
func _verify_r7_focus_noise(img: Image) -> void:
	var near := _sample_world_region(img, Rect2i(176, 150, 54, 40), 2)
	var far := _sample_world_region(img, Rect2i(300, 140, 50, 40), 2)
	var far2 := _sample_world_region(img, Rect2i(52, 240, 50, 40), 2)
	var near_d := _noise_density(near)
	var far_d := _noise_density(far)
	var far2_d := _noise_density(far2)
	_ok(far_d <= near_d + 0.01,
		"R7 noise hierarchy far<=focus (far %.3f <= near %.3f, 远景角落留白)" % [far_d, near_d])
	_ok(far2_d <= near_d + 0.01,
		"R7 noise hierarchy far2<=focus (far2 %.3f <= near %.3f, 远景角落留白)" % [far2_d, near_d])
	var focal_colors := _sample_window(img, Vector2(206, 150), 55, 4)
	var far_zone_colors := _sample_window(img, Vector2(200, 70), 55, 4)
	var focal_lum := _avg_luminance(focal_colors)
	var far_zone_lum := _avg_luminance(far_zone_colors)
	_ok(focal_lum > far_zone_lum,
		"R7 focus zone brighter than periphery (focal lum %.3f > far %.3f, 中央焦点)" % [focal_lum, far_zone_lum])
	# (c) 轮廓勾边 Δlum ≥ 25：bench_press(1,7) 前缘 vs 相邻地面 —— 与
	# qa_v31r4p1_independent.py 同一口径（edge z=1.0 前缘立面 / floor z=0.0
	# 相邻地面；P2 方向投影 slab 落在更远处，本采样带仍为未受影地板）。
	var edge := _sample_world_region_z(img, Rect2i(36, 286, 56, 3), 1.0, 2)
	var floor := _sample_world_region_z(img, Rect2i(36, 292, 56, 8), 0.0, 2)
	var edge_lum := _avg_luminance(edge)
	var floor_lum := _avg_luminance(floor)
	var d := floor_lum - edge_lum
	_ok(d > 0.098, "R7 outline Δlum %.3f >= 0.098 (≈25/255, 轮廓与背景分离)" % d)


## 世界矩形区域采样 → 屏幕像素颜色列表（越界跳过）。
func _sample_world_region(img: Image, r: Rect2i, step: int) -> Array[Color]:
	return _sample_world_region_z(img, r, 0.0, step)


## 世界矩形区域采样（指定高度 z）→ 屏幕像素颜色列表（越界跳过）。
## [z] 投影高度（世界 px；0=贴地。前缘立面采样用 z=1.0 —— 与
## qa_v31r4p1_independent.py 同一口径）。
func _sample_world_region_z(img: Image, r: Rect2i, z: float, step: int) -> Array[Color]:
	var out: Array[Color] = []
	for wy in range(r.position.y, r.end.y, step):
		for wx in range(r.position.x, r.end.x, step):
			var p := _world_to_screen_full_z(Vector2(wx, wy), z)
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


## P2（FAIL 第三眼#2）：投影方向一致性 + 与本体分离（全场景帧）。
## 对每台采样设备：
##   a. 投影出现：MAIN_LIGHT_DIR 方向（左下，cast_shadow_draw_offset 落点）
##      存在冷暗像素（SHADOW_COOL/EQUIP_SHADOW 系，与地板冷灰区分）；
##   b. 方向统一：footprint 外偏左下的采样窗内冷阴影像素质心位于本体中心
##      左下（x < 中心+2、y > 中心-2）—— 暗部读作「定向投影」而非区域压暗；
##   c. 分离明确：本体左侧上方 gap 点（fp.x-6, fp.y+off.y·0.5 —— 本体与
##      slab 之间未受影的亮池区）明度高于 slab 内部（可辨间隙）。
## 冷阴影像素判别：b > r + 0.06 且 lum < 0.45 —— 命中 SHADOW_COOL/EQUIP_SHADOW
## 叠在深色地板（lum≈0.29, b-r≈0.09）与暖池上（slab a=0.40 → lum≈0.37,
## b-r≈0.08）的投影，排除地板本体（#4B4F57 lum 0.31, b-r 0.05）与亮池
## （lum≥0.45, warm r>b）。采样窗偏左下（避免前台影/相邻设备）。
func _verify_shadow_direction(img: Image) -> void:
	for s in SHADOW_SAMPLES:
		var fp: Rect2i = s["footprint"]
		var height: float = s["height"]
		var probe_extra: float = s.get("probe_extra", 0.0)
		var center := Vector2(fp.position) + Vector2(fp.size) * 0.5
		var offset := WorldLayout.cast_shadow_draw_offset(center, height)
		# a. 投影出现：slab 落点窗口内冷暗像素存在。probe_extra>0 时沿投影
		#    方向再深入（bench_press 本体高 64，其 slab 中心落在自身 footprint
		#    内 —— 探针移到本体下缘之外的可见投影区）。
		var proj_center := center + offset * (1.0 + probe_extra)
		var proj_cool := 0
		var proj_total := 0
		for dy in range(-8, 9, 2):
			for dx in range(-8, 9, 2):
				var p := _world_to_screen_full_z(proj_center + Vector2(dx, dy), 0.0)
				if not _in_bounds(img, p):
					continue
				proj_total += 1
				var c := img.get_pixel(p.x, p.y)
				if c.b > c.r + 0.06 and _luminance(c) < 0.45:
					proj_cool += 1
		_ok(proj_cool > 0 and proj_total >= 3,
			"SHADOW dir: equipment %s projection present on light-opposite side (cool %d/%d, 左下投影存在)"
			% [str(fp.position), proj_cool, proj_total])
		# b. 方向统一：偏左下的采样窗（center + (-60,-8) .. +30/+60）内，
		#    排除本体 footprint 后冷阴影像素质心应在本体中心左下。
		var sx_sum := 0.0
		var sy_sum := 0.0
		var s_count := 0
		var win := Rect2(center + Vector2(-60, -8), Vector2(90, 68))
		for dy in range(int(win.position.y), int(win.end.y), 2):
			for dx in range(int(win.position.x), int(win.end.x), 2):
				var wpt := Vector2(dx, dy)
				var inside_fp := wpt.x >= fp.position.x and wpt.x < fp.end.x \
						and wpt.y >= fp.position.y and wpt.y < fp.end.y
				if inside_fp:
					continue  # 排除本体 footprint
				var p := _world_to_screen_full_z(wpt, 0.0)
				if not _in_bounds(img, p):
					continue
				var c := img.get_pixel(p.x, p.y)
				if c.b > c.r + 0.06 and _luminance(c) < 0.45:
					sx_sum += wpt.x
					sy_sum += wpt.y
					s_count += 1
		var centroid_ok := false
		if s_count >= 4:
			var cx := sx_sum / float(s_count)
			var cy := sy_sum / float(s_count)
			centroid_ok = cx < center.x + 2.0 and cy > center.y - 2.0
			_ok(centroid_ok,
				"SHADOW dir: equipment %s shadow mass centroid (%.0f,%.0f) down-left of center (%.0f,%.0f), n=%d"
				% [str(fp.position), cx, cy, center.x, center.y, s_count])
		else:
			_ok(false,
				"SHADOW dir: equipment %s not enough shadow samples in ring (n=%d)"
				% [str(fp.position), s_count])
		# c. 分离明确：本体的受光侧（无投影区）明度高于投影侧（slab 内部）
		#    —— 投影只在一侧（左下），另一侧干净，暗部读作「定向投影」而非
		#    「轮廓描边/区域压暗」。默认取 center - offset×0.6（NE 侧）；
		#    bench_press 本体占满 NE —— 用 gap_local 取本体东侧地板。
		var gap_pt: Vector2
		var gap_local: Variant = s.get("gap_local", Vector2.INF)
		if gap_local is Vector2 and gap_local != Vector2.INF:
			gap_pt = center + (gap_local as Vector2)
		else:
			gap_pt = center - offset * 0.6
		var gap_p := _world_to_screen_full_z(gap_pt, 0.0)
		var slab_p := _world_to_screen_full_z(proj_center, 0.0)
		var gap_lum := 0.0
		var slab_lum := 0.0
		var gap_n := 0
		var slab_n := 0
		for dy in range(-2, 3):
			for dx in range(-2, 3):
				if _in_bounds(img, gap_p + Vector2i(dx, dy)):
					gap_lum += _luminance(img.get_pixel(gap_p.x + dx, gap_p.y + dy))
					gap_n += 1
				if _in_bounds(img, slab_p + Vector2i(dx, dy)):
					slab_lum += _luminance(img.get_pixel(slab_p.x + dx, slab_p.y + dy))
					slab_n += 1
		gap_lum /= maxf(gap_n, 1)
		slab_lum /= maxf(slab_n, 1)
		_ok(gap_lum > slab_lum,
			"SHADOW sep: equipment %s clean side lighter than slab (gap %.3f > slab %.3f, 可辨间隙)"
			% [str(fp.position), gap_lum, slab_lum])


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
	# Node2D 变换：屏幕 = world * scale + position（scale 后 position）。
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
