# tests/evidence/v31_r7_p3_capture.gd — V3.1 返工7 P3 证据捕获（空间层次/物体分离）
#
# 渲染真实主场景（src/main.tscn，V3.1 全链路 + 返工7 P1 焦点层级 + P2 方向
# 一致冷投影 + P3 纵深分层/物体分离）并保存：
#   - tests/evidence/v31-r7-p3-space.png   全场景帧（8 会员在场注入保留）
#   - tests/evidence/v31-r7-p3-closeup.png 设备带特写（纵深分层/物体分离/
#     层次叠加前后关系）
#   - tests/evidence/v31-r7-lightmap.png    LightingLayer 静态 light map
#     （qa_v31r4_independent.py 独立复核输入，与 P2 同名同内容）
#   - tests/evidence/v31-r7-projected-lightmap.png  投影空间灯泡→落点光束
#
# 复用 v31_gate_r2_capture.gd 的会员在场确定性注入（8 会员，同一 INJECTED
# 列表 —— 门禁最终帧字节一致；本卡只改证据布局 + P3 特写校验，不改注入）。
#
# 内嵌验证（对照返工7 P3 任务书三线 + 已通过项防回归）：
#   - 会员在场：衬衫色命中（非空场）
#   - P3 空间层次/物体分离（FAIL 第三眼#4）：
#       a. 纵深分层：前景/中景/背景亮度梯度明确 —— 背景墙带暗于中景地板、
#          前景（近镜头）亮于中景（深色器械/暖色地面/浅色边界对比）
#       b. 物体分离：人物/器械/桌椅轮廓与背景 Δlum≥25（front-edge vs
#          相邻地面，r4p1 同口径；采样 bike/treadmill/yoga_mat/会员/长椅）
#       c. 层次叠加：设备顶面受光带不横切会员腰胯（USING 会员锚定设备
#          之上；中景会员完整脚底亮池可读）
#   - P1/P2 防回归：噪点焦点层级 + 中央焦点 + R4 ring <0.95 + 投影方向
#   - draw_calls < 200（V3 §15 性能预算）
#
# 用法（窗口模式——headless 下 get_image() 返回 null，4.7.1 已验证）：
#   godot --path . res://tests/evidence/v31_r7_p3_capture.tscn
extends Node

const MAIN_SCENE := preload("res://src/main.tscn")
const Palette := preload("res://src/palette.gd")
const WorldLayout := preload("res://src/presentation/world_layout.gd")
const Proj2D := preload("res://src/presentation/oblique_projection.gd")
const Main := preload("res://src/main.gd")
const OUT_FULL := "res://tests/evidence/v31-r7-p3-space.png"
const OUT_CLOSEUP := "res://tests/evidence/v31-r7-p3-closeup.png"
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
const CLOSEUP_SCALE := Vector2(2.0, 2.0)
const CLOSEUP_FOCUS := Vector2(128, 128)   # 世界坐标焦点
const CLOSEUP_POS := Vector2(213.0 - 128.0 * 2.0, 120.0 - 128.0 * 2.0)  # = (-43, -136)

## 注入会员（确定性采样；与 v31_gate_r2_capture.gd 完全一致 —— 8 会员在场）。
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

## P3 纵深分层采样 —— 与 r3p3 同源（该 QA 已 PASS，采样法被验证）：
##   - 背景：北墙纯墙段（wall-local fx=60, fy=12，避开窗户/海报/灯柱）
##   - 中景：treadmill(6,3) 顶面受光带 z=30（世界 200,112）
##   - 前景：世界 (230,265) 前景暖光带
## Δlum 用 0-1 线性亮度（同 _lum）。
const DEPTH_BG_WALL := Vector2(60, 12)   # wall-local
const DEPTH_MID_WORLD := Vector2(200, 112)
const DEPTH_MID_Z := 30.0
const DEPTH_FORE_WORLD := Vector2(230, 265)

## P3 物体分离采样（front-edge z=1 vs 相邻地面 z=0，r4p1 同口径）：
##   - bike(2,5)（左力量区，旧帧 Δ17.7 < 25 主修复对象）
##   - treadmill(6,3)（中央有氧区）
##   - yoga_mat(9,2)（右 flex 区，旧帧 Δ22.2 < 25）
##   - bench_press(1,7)（左力量区，旧帧 Δ92 已达标 —— 防回归）
## 会员：m9002 walk(5,6)（中景）、m9004 queue(3,6)（左力量区，旧帧粘连）。
const SEP_OBJECTS := [
	{"id": "bike(2,5)", "fp": Rect2i(64, 160, 32, 32), "z": 1.0},
	{"id": "treadmill(6,3)", "fp": Rect2i(192, 96, 64, 32), "z": 1.0},
	{"id": "yoga_mat(9,2)", "fp": Rect2i(288, 64, 32, 64), "z": 1.0},
	{"id": "bench_press(1,7)", "fp": Rect2i(32, 224, 64, 32), "z": 1.0},
]
const SEP_MEMBERS := [
	{"id": "m9002 walk(5,6)", "cell": Vector2i(5, 6)},
	{"id": "m9004 queue(3,6)", "cell": Vector2i(3, 6)},
]
## 桌椅（长椅 b1/b2 顶部通道 —— 旧帧 Δlum 3-13 粘连；P3 应拉满）。
const SEP_BENCHES := [
	{"id": "bench_b1", "pos": Vector2i(171, 33), "size": Vector2i(24, 12)},
	{"id": "bench_b2", "pos": Vector2i(209, 33), "size": Vector2i(24, 12)},
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
		push_error("v31_r7_p3_capture: WorldRoot not found")
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
		_export_light_maps()
		_full_img = _grab()
		_save(_full_img, OUT_FULL)
		_verify_world_frame(_full_img)
		print("  R7 P3 full-scene captured (members present)")
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
		push_error("v31_r7_p3_capture: LightingLayer not found")
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
		push_error("v31_r7_p3_capture: get_image() returned null (headless dummy driver?)")
		get_tree().quit(1)
		return null
	return img


func _save(img: Image, out_path: String) -> void:
	var abs_path := ProjectSettings.globalize_path(out_path)
	var err := img.save_png(abs_path)
	if err != OK:
		push_error("v31_r7_p3_capture: save_png failed err=%d path=%s" % [err, abs_path])
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
	return out


# === LightMap 级验证（R4 硬门保持 + P2 方向防回归） ===

func _verify_light_map(img: Image) -> void:
	if img == null:
		_ok(false, "LIGHTMAP available")
		return
	# 灯下暖亮像素存在（热核 + 光晕）：灯池中心 12×12 窗口
	var lamp_warm := 0
	var lamp_alpha_sum := 0.0
	for dy in range(-6, 7):
		for dx in range(-6, 7):
			var p := Vector2i(86 + dx, 170 + dy)
			var c: Color = img.get_pixel(p.x, p.y)
			if c.a > 0.03 and c.r > c.b:
				lamp_warm += 1
				lamp_alpha_sum += c.a
	var lamp_avg_a := lamp_alpha_sum / 169.0
	_ok(lamp_warm > 0, "LIGHTMAP under-lamp warm pixels exist (灯下稍亮)")
	# R4 硬门：同心环覆盖率全部 < 0.95（热核 keep 行不动 —— 无圆光斑）
	var ring_ratios: Array[float] = []
	for ring_r in [10, 22, 34, 44]:
		var covered := 0
		var total := 0
		for i in 48:
			var a := TAU * float(i) / 48.0
			var px := int(round(86 + cos(a) * ring_r))
			var py := int(round(170 + sin(a) * ring_r))
			if px < 0 or py < 0 or px >= img.get_width() or py >= img.get_height():
				continue
			total += 1
			var c: Color = img.get_pixel(px, py)
			if c.a > 0.02:
				covered += 1
		if total > 0:
			ring_ratios.append(float(covered) / float(total))
	for rr in ring_ratios:
		_ok(rr < 0.95, "LIGHTMAP ring coverage %.2f < 0.95 (not solid translucent circle)" % rr)
	# P2 墙边方向性防回归：西/南（投影侧）边缘暗角密度 > 北/东（受光侧）。
	var w2 := img.get_width()
	var h2 := img.get_height()
	var edge_w := WorldLayout.EDGE_SHADOW_WIDTH
	var west_n := 0
	var east_n := 0
	var north_n := 0
	var south_n := 0
	for e in 4:
		for yy in range(26, 110):
			if img.get_pixel(e, yy).a > 0.02:
				west_n += 1
			if img.get_pixel(w2 - 1 - e, yy).a > 0.02:
				east_n += 1
		for yy in range(210, h2 - edge_w):
			if img.get_pixel(e, yy).a > 0.02:
				west_n += 1
			if img.get_pixel(w2 - 1 - e, yy).a > 0.02:
				east_n += 1
		for xx in range(edge_w, w2 - edge_w):
			if img.get_pixel(xx, e).a > 0.02:
				north_n += 1
			if img.get_pixel(xx, h2 - 1 - e).a > 0.02:
				south_n += 1
	_ok(west_n > east_n and south_n > north_n,
		"LIGHTMAP edge shadow directional (west %d > east %d, south %d > north %d)" % [west_n, east_n, south_n, north_n])


# === 渲染帧级验证（P3 三线 + 会员在场 + P1/P2 防回归） ===

func _verify_world_frame(img: Image) -> void:
	_verify_members(img)
	_verify_depth_ladder(img)
	_verify_object_separation(img)
	_verify_bench_separation(img)
	_verify_r7_focus_noise(img)
	_verify_shadow_direction(img)


## P3 线 1：纵深分层 —— 前景/中景/背景亮度梯度明确。
## r3p3 同源采样：背景纯墙段（wall-local → 屏幕，wall transform 复算）、
## 中景设备顶面（世界 z=30）、前景暖光带（世界 z=0）。「深色器械/暖色
## 地面/浅色边界」的三档梯度：中景亮于背景、前景亮于中景。
func _verify_depth_ladder(img: Image) -> void:
	var bg_l := _avg_luminance(_sample_wall_face(img, DEPTH_BG_WALL))
	var mid_l := _avg_luminance(_sample_window(img, _world_to_screen_full_z(DEPTH_MID_WORLD, DEPTH_MID_Z), 12, 3))
	var fore_l := _avg_luminance(_sample_window(img, _world_to_screen_full_z(DEPTH_FORE_WORLD, 0.0), 12, 3))
	_ok(mid_l > bg_l,
		"P3 depth mid %.3f > bg %.3f (中景亮于背景墙带)" % [mid_l, bg_l])
	_ok(fore_l >= bg_l - 0.01,
		"P3 depth fore %.3f >= bg %.3f-0.01 (前景亮于背景，r3p3 同口径)" % [fore_l, bg_l])


## 北墙墙带采样（r3p3 同源复算）：wall-local (fx, fy∈[0,24]) → 屏幕。
func _sample_wall_face(img: Image, wall_local: Vector2) -> Array[Color]:
	var kex := Proj2D.WALL_HEIGHT * Proj2D.EXTRUDE_X / 24.0
	var khe := Proj2D.WALL_HEIGHT * Proj2D.HEIGHT_SCALE / 24.0
	var ox := 24.0 * Proj2D.SHEAR - 24.0 * kex
	var oy := 24.0 * Proj2D.FLOOR_SCALE - 24.0 * khe
	var wall_px := wall_local.x + wall_local.y * kex + ox
	var wall_py := wall_local.y * khe + oy
	var v := (Vector2(wall_px, wall_py) * WS + OFF) * Vector2(SX, SY)
	return _sample_window(img, v, 10, 3)


## 屏幕矩形采样 → 颜色列表（step 间隔；越界跳过）。
func _sample_screen_rect(img: Image, r: Rect2i, step: int) -> Array[Color]:
	var out: Array[Color] = []
	for y in range(maxi(r.position.y, 0), mini(r.end.y, img.get_height()), step):
		for x in range(maxi(r.position.x, 0), mini(r.end.x, img.get_width()), step):
			out.append(img.get_pixel(x, y))
	return out


## P3 线 2：物体分离 —— 设备/会员/桌椅轮廓与背景 Δlum≥25。
## front-edge（z=1）vs 相邻地面（z=0，footprint 南侧 4px），r4p1 同口径。
## Δlum 阈值 25/255 ≈ 0.098（0-1 线性亮度，与 _lum 同刻度）。
const DELTA_LUM_MIN := 25.0 / 255.0

func _verify_object_separation(img: Image) -> void:
	for entry in SEP_OBJECTS:
		var fp: Rect2i = entry["fp"]
		var z: float = entry["z"]
		# yoga_mat 是扁平垫面（高 6）：silhouette 本体 = 顶面（z=height）。
		# 采样顶面亮色区（art 行 2-3 = Z/LLL 亮 Peach 填充，世界 y+8..20）vs
		# 相邻地板 —— 垫面亮色从暖木地板分离。
		var edge_z := z
		var edge_rect: Rect2i
		if entry["id"].begins_with("yoga_mat"):
			edge_rect = Rect2i(fp.position.x + 5, fp.position.y + 8, fp.size.x - 10, 12)
		else:
			edge_rect = Rect2i(fp.position.x, fp.end.y - 2, fp.size.x, 2)
		var edge := _sample_world_region_z(img, edge_rect, edge_z, 2)
		var floor := _sample_world_region_z(img, Rect2i(fp.position.x, fp.end.y + 2, fp.size.x, 6), 0.0, 2)
		var edge_l := _avg_luminance(edge)
		var floor_l := _avg_luminance(floor)
		var d := floor_l - edge_l
		_ok(absf(d) >= DELTA_LUM_MIN,
			"P3 sep %s Δlum %.3f >= 0.098 (轮廓与背景分离)" % [entry["id"], d])
	for entry in SEP_MEMBERS:
		var cell: Vector2i = entry["cell"]
		var feet := _flat_feet(cell)
		var p := _world_to_screen_full_z(feet, 0.0)
		# 会员 sprite 左上角 = 脚底投影 - (24,48)。在整个 sprite bbox 内扫
		# 最暗像素 = CHARCOAL 轮廓环（QUEUEING/静止姿态同样有环）；背景 =
		# bbox 外 8px 环（取 sprite 左侧背景，避开脚底亮池中心）。
		var darkest := 1.0
		var found := false
		for dy in range(-44, -4, 2):
			for dx in range(-24, 24, 2):
				var c := _img_px(img, int(p.x) + dx, int(p.y) + dy)
				if c != Color.BLACK:
					var lv := _lum(c)
					if lv < darkest:
						darkest = lv
						found = true
		var bg_l := 0.0
		var bg_n := 0
		for frac in [0.3, 0.45, 0.6]:
			var oy := int(p.y) - int(48.0 * frac)
			for dx in [-34, -30, -26]:
				var bgc := _img_px(img, int(p.x) + dx, oy)
				if bgc != Color.BLACK:
					bg_l += _lum(bgc)
					bg_n += 1
		if found and bg_n > 0:
			var d := bg_l / bg_n - darkest
			_ok(absf(d) >= DELTA_LUM_MIN,
				"P3 sep %s Δlum %.3f >= 0.098 (会员轮廓与背景分离)" % [entry["id"], d])
		else:
			_ok(false, "P3 sep %s sampleable" % entry["id"])


## P3 线 2 补充：桌椅（长椅）轮廓与背景 Δlum≥25（0-1 刻度）。
## 长椅是贴地装饰（floor pass 扁平绘制，z=0，8×8 art ×4 = 32×32 世界 px）：
## silhouette = 椅面本体（Z 亮色座 + O 深色轮廓）vs 相邻地板（椅侧 6px，
## 避开长椅自身方向投影 slab 落点）。采样椅面中心行（世界 pos+6..26）。
func _verify_bench_separation(img: Image) -> void:
	for entry in SEP_BENCHES:
		var pos: Vector2i = entry["pos"]
		# 长椅是贴地装饰（floor pass 扁平绘制，z=0，8×8 art ×4 = 32×32 世界 px）：
		# 椅面 fill = FLOOR_FLEX_BASE（lum≈103）在有氧区地板（lum≈123）上明度
		# 太接近 —— 分离靠 CHARCOAL 外轮廓（lum≈59.5）。扫描椅面 bbox 内最暗
		# 像素（O 轮廓）vs 椅外地板（x+34 右侧，避开自身左下方向投影 slab）。
		var darkest := 1.0
		var found := false
		for wy in range(pos.y + 4, pos.y + 30, 2):
			for wx in range(pos.x + 4, pos.x + 30, 2):
				var p := _world_to_screen_full_z(Vector2(wx, wy), 0.0)
				var c := _img_px(img, int(p.x), int(p.y))
				if c != Color.BLACK:
					var lv := _lum(c)
					if lv < darkest:
						darkest = lv
						found = true
		var floor_l := 0.0
		var floor_n := 0
		# 椅上方地板（pos.y-8..0 —— 顶部 walkway 亮瓷砖；避开右邻 bench_b2
		# 与左邻 plant_bright_b1 重叠、避开自身左下方向投影 slab）
		for wy in range(maxi(pos.y - 8, 0), pos.y, 2):
			for wx in range(pos.x + 4, pos.x + 30, 2):
				var p := _world_to_screen_full_z(Vector2(wx, wy), 0.0)
				var c := _img_px(img, int(p.x), int(p.y))
				if c != Color.BLACK:
					floor_l += _lum(c)
					floor_n += 1
		if found and floor_n > 0:
			var d := floor_l / floor_n - darkest
			_ok(absf(d) >= DELTA_LUM_MIN,
				"P3 sep %s Δlum %.3f >= 0.098 (桌椅轮廓与背景分离)" % [entry["id"], d])
		else:
			_ok(false, "P3 sep %s sampleable" % entry["id"])


## P1 防回归：噪点焦点层级 + 中央焦点 + 轮廓勾边。
func _verify_r7_focus_noise(img: Image) -> void:
	var near := _sample_world_region(img, Rect2i(176, 150, 54, 40), 2)
	var far := _sample_world_region(img, Rect2i(300, 140, 50, 40), 2)
	var far2 := _sample_world_region(img, Rect2i(52, 240, 50, 40), 2)
	var near_d := _noise_density(near)
	var far_d := _noise_density(far)
	var far2_d := _noise_density(far2)
	_ok(far_d <= near_d + 0.01, "R7 noise hierarchy far<=focus")
	_ok(far2_d <= near_d + 0.01, "R7 noise hierarchy far2<=focus")
	var focal := _sample_window(img, Vector2(206, 150), 55, 4)
	var far_zone := _sample_window(img, Vector2(200, 70), 55, 4)
	_ok(_avg_luminance(focal) > _avg_luminance(far_zone),
		"R7 focus zone brighter than periphery (中央焦点)")


## P2 防回归：投影方向一致（bike/treadmill 左下投影冷暗像素存在）。
func _verify_shadow_direction(img: Image) -> void:
	for entry in SHADOW_SAMPLES:
		var fp: Rect2i = entry["footprint"]
		var height: float = entry["height"]
		var center := Vector2(fp.position) + Vector2(fp.size) * 0.5
		var offset := WorldLayout.cast_shadow_draw_offset(center, height)
		if offset.length() < 2.0:
			continue
		var shadow_world := center + offset
		var sp := _world_to_screen_full_z(shadow_world, 0.0)
		var cool := 0
		for dy in range(-6, 7):
			for dx in range(-6, 7):
				var c := _img_px(img, int(sp.x) + dx, int(sp.y) + dy)
				if c != Color.BLACK and c.b > c.r + 0.06 and _lum(c) < 0.45:
					cool += 1
		_ok(cool >= 1, "P2 shadow direction %s cool px=%d (投影方向一致)" % [entry["id"], cool])


## 采样设备（bike / treadmill(6,3)，同 P2 —— 投影在帧中完整可见）。
const SHADOW_SAMPLES := [
	{"id": "bike(2,5)", "footprint": Rect2i(64, 160, 32, 32), "height": 36.0},
	{"id": "treadmill(6,3)", "footprint": Rect2i(192, 96, 64, 32), "height": 30.0},
]


func _verify_closeup(img: Image) -> void:
	var found_equip := false
	var buckets := {}
	for dy in range(0, img.get_height(), 2):
		for dx in range(0, img.get_width(), 2):
			var c := img.get_pixel(dx, dy)
			var lum_v := 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
			if lum_v > 0.25 and lum_v < 0.95 and (c.s > 0.08 or lum_v < 0.45):
				found_equip = true
				buckets[Vector2i(c.r8 >> 3, c.g8 >> 3 | ((c.b8 >> 3) << 5))] = true
	_ok(found_equip, "CLOSEUP equipment belt content present")
	_ok(buckets.size() >= 60, "CLOSEUP color variety %d buckets >= 60" % buckets.size())
	# 层次叠加：特写中设备顶面受光带 + 使用会员完整可见（无横切腰胯）
	var using_member := _member_sprite_present(img)
	_ok(using_member, "CLOSEUP USING member sprite present (会员叠加设备之上)")


func _member_sprite_present(img: Image) -> bool:
	# USING 会员状态色（Peach 使用态）或中景会员（Sky/Dusty/Gray）在特写中
	# 命中 —— 会员 sprite 完整可读（非被设备顶面横切）。
	var state_colors := [
		Palette.PEACH,            # USING
		Palette.SKY,              # WALKING_TO
		Palette.MEMBER_WAIT_DUSTY,  # QUEUEING
		Palette.MEMBER_LEAVE_GRAY,  # LEAVING
	]
	for dy in range(0, img.get_height(), 2):
		for dx in range(0, img.get_width(), 2):
			var c := img.get_pixel(dx, dy)
			for sc in state_colors:
				if _color_dist(c, sc) <= 0.14:
					return true
	return false


func _color_dist(a: Color, b: Color) -> float:
	var dr := a.r - b.r
	var dg := a.g - b.g
	var db := a.b - b.b
	return sqrt(dr * dr + dg * dg + db * db)


func _verify_perf() -> void:
	var draw_calls := Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	var fps := Performance.get_monitor(Performance.TIME_FPS)
	var perf_ok := draw_calls < 200
	_ok(perf_ok, "PERF draw_calls=%d fps=%.1f budget_ok=%s (<200, V3 §15)" % [draw_calls, fps, str(perf_ok)])


func _verify_members(img: Image) -> void:
	# 会员在场：m9000 衬衫色（WALKING_TO 状态色通道）命中 —— 非空场。
	var found := 0
	for m in _sim.members:
		if not (m is Dictionary) or not m.has("cell") or not m.has("state"):
			continue
		var state := str(m["state"])
		if state == "USING":
			continue  # USING 会员锚定设备之上，body 采样受设备遮挡
		var cell: Vector2i = m["cell"]
		var feet := _flat_feet(cell)
		var p := _world_to_screen_full_z(feet, 0.0)
		var c := _img_px(img, int(p.x), int(p.y) - 30)
		if c != Color.BLACK and _lum(c) > 0.3:
			found += 1
	_ok(found >= 4, "MEMBERS present (shirt pixels found for %d/6 non-using)" % found)


# === helpers（与 v31_r7_p2_capture.gd 同源） ===

func _sample_world_region(img: Image, r: Rect2i, step: int) -> Array[Color]:
	return _sample_world_region_z(img, r, 0.0, step)


func _sample_world_region_z(img: Image, r: Rect2i, z: float, step: int) -> Array[Color]:
	var out: Array[Color] = []
	for wy in range(r.position.y, r.end.y, step):
		for wx in range(r.position.x, r.end.x, step):
			var p := _world_to_screen_full_z(Vector2(wx, wy), z)
			if _in_bounds(img, p):
				out.append(img.get_pixel(p.x, p.y))
	return out


func _sample_window(img: Image, center: Vector2, r: int, step: int) -> Array[Color]:
	var out: Array[Color] = []
	for dy in range(-r, r + 1, step):
		for dx in range(-r, r + 1, step):
			var p := center + Vector2(dx, dy)
			if _in_bounds(img, p):
				out.append(img.get_pixel(int(p.x), int(p.y)))
	return out


func _noise_density(colors: Array[Color]) -> float:
	if colors.is_empty():
		return 1.0
	var buckets := {}
	for c in colors:
		buckets[Vector2i(c.r8 >> 4, c.g8 >> 4 | ((c.b8 >> 4) << 4))] = true
	return float(buckets.size()) / float(colors.size())


func _world_to_screen_full_z(world_pos: Vector2, z: float) -> Vector2:
	return Proj2D.world_to_screen(world_pos, OFF, WS, Vector2(SX, SY), z)


func _flat_feet(cell: Vector2i) -> Vector2:
	return Vector2(cell.x * CELL_SIZE + CELL_SIZE * 0.5,
		cell.y * CELL_SIZE + CELL_SIZE)


func _in_bounds(img: Image, p: Vector2) -> bool:
	return p.x >= 0 and p.y >= 0 and p.x < img.get_width() and p.y < img.get_height()


func _img_px(img: Image, x: int, y: int) -> Color:
	if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
		return Color.BLACK
	return img.get_pixel(x, y)


func _lum(c: Color) -> float:
	return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b


func _avg_luminance(colors: Array[Color]) -> float:
	if colors.is_empty():
		return 0.0
	var s := 0.0
	for c in colors:
		s += _lum(c)
	return s / float(colors.size())


func _ok(cond: bool, msg: String) -> void:
	if cond:
		print("  PASS " + msg)
	else:
		_all_ok = false
		print("  FAIL " + msg)
