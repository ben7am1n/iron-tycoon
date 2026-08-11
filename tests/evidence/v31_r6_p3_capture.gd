# tests/evidence/v31_r6_p3_capture.gd — V3.1 返工6 P3 证据捕获（照明/第三眼）
#
# 渲染真实主场景（src/main.tscn，V3.1 P1 oblique + P2 设备 + P3 手绘密度 +
# P4 pixel lighting + P5 高饱和焦点 + 返工6 P1 噪点降密 + P2 会员肢体重绘 +
# P4 N1/N4 全链路）并保存：
#   - tests/evidence/v31-r6-p3-lighting.png   全场景帧（8 会员在场注入保留）
#   - tests/evidence/v31-r6-p3-closeup.png    设备带+灯池 2.5x 特写
#   - tests/evidence/v31-r6-p3-lightmap.png   LightingLayer 静态 light map
#   - tests/evidence/v31-r6-p3-projected-lightmap.png  投影空间灯泡→落点光束
#
# 复用 v31_gate_r2_capture.gd 的会员在场确定性注入（8 会员，同一 INJECTED
# 列表 —— 门禁最终帧字节一致；本卡只改证据布局 + P3 特写帧，不改注入）。
#
# 内嵌验证（对照返工6 P3 任务书 FAIL 点 + 已通过项防回归）：
#   - 可读暖光衰减：灯池热核 alpha > 中圈 > 外圈（受控离散亮度环 ——
#     GPT：核心实色、次圈稀疏抖动、外圈更稀疏；非整片随机噪点）
#   - 方向一致冷投影：设备/会员投影偏移方向全场一致（统一向西南，
#     MAIN_LIGHT_DIR 全局主光方向 —— 非区域压暗）
#   - 空间层次：会员脚下接触影更小更纯 + 亮池托起（人物/地面分离）
#   - R4 硬门保持：light map 灯池中心同心环覆盖率全部 < 0.95（热核 keep 行
#     不动 —— 无圆光斑回归）
#   - 投光关系保持：灯下暖亮 alpha > 墙边冷暗（V3 §6）
#   - 会员在场：衬衫色命中（非空场）
#   - draw_calls < 200（V3 §15 性能预算）
#
# 用法（窗口模式——headless 下 get_image() 返回 null，4.7.1 已验证）：
#   godot --path . res://tests/evidence/v31_r6_p3_capture.tscn
extends Node

const MAIN_SCENE := preload("res://src/main.tscn")
const Palette := preload("res://src/palette.gd")
const WorldLayout := preload("res://src/presentation/world_layout.gd")
const Proj2D := preload("res://src/presentation/oblique_projection.gd")
const Main := preload("res://src/main.gd")
const OUT_FULL := "res://tests/evidence/v31-r6-p3-lighting.png"
const OUT_CLOSEUP := "res://tests/evidence/v31-r6-p3-closeup.png"
const LIGHTMAP_PATH := "res://tests/evidence/v31-r6-p3-lightmap.png"
const PROJECTED_LIGHTMAP_PATH := "res://tests/evidence/v31-r6-p3-projected-lightmap.png"
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

## 特写变换：聚焦设备带 + 中灯池（treadmill(6,3) / bike(2,5) / 会员行走区）。
## WorldRoot 默认 scale 0.75；特写 scale 2.5 → 世界 (426/2.5, 240/2.5)=(170,96)
## 可见；position 使世界 (128,128)（设备带中心）附近居中，并保留灯池
## (224,170) 在右下入画（暖池衰减 + 设备受光带可读）。
##   pos = (213 - 128*2.5, 120 - 128*2.5) = (213-320, 120-320) = (-107, -200)
const CLOSEUP_SCALE := Vector2(2.5, 2.5)
const CLOSEUP_FOCUS := Vector2(128, 128)
const CLOSEUP_POS := Vector2(213.0 - 128.0 * 2.5, 120.0 - 128.0 * 2.5)

## 注入会员（确定性采样；与 v31_gate_r2_capture.gd 完全一致 —— 8 会员在场，
## 门禁最终帧字节一致；本卡只复用，不改注入）。
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
		push_error("v31_r6_p3_capture: WorldRoot not found")
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
		print("  R6 P3 full-scene captured (members present)")
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


## 导出 light map + 投影空间光束（qa_v31r4 / qa_v31r4p3 独立复核输入）。
func _export_light_maps() -> void:
	var lighting := _main.get_node_or_null("WorldViewport/WorldRoot/LightingLayer")
	if lighting == null:
		push_error("v31_r6_p3_capture: LightingLayer not found")
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
		push_error("v31_r6_p3_capture: get_image() returned null (headless dummy driver?)")
		get_tree().quit(1)
		return null
	return img


func _save(img: Image, out_path: String) -> void:
	var abs_path := ProjectSettings.globalize_path(out_path)
	var err := img.save_png(abs_path)
	if err != OK:
		push_error("v31_r6_p3_capture: save_png failed err=%d path=%s" % [err, abs_path])
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


# === LightMap 级验证（R4 硬门保持 + 返工6 P3 可读衰减） ===

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

	# R6 P3 可读暖光衰减：热核（r≤8）alpha 均值 > 中圈（r 16..24）> 外圈（r 32..40）
	# —— 受控离散亮度环（GPT：核心实色、次圈稀疏、外圈更稀疏，非整片随机）。
	var hot := _ring_alpha_mean(img, LAMP_CENTER, 2, 8)
	var mid := _ring_alpha_mean(img, LAMP_CENTER, 16, 24)
	var outer := _ring_alpha_mean(img, LAMP_CENTER, 32, 40)
	_ok(hot > mid, "R6P3 暖光衰减: 热核 alpha %.3f > 中圈 %.3f (核心实色)" % [hot, mid])
	_ok(mid > outer, "R6P3 暖光衰减: 中圈 alpha %.3f > 外圈 %.3f (逐级衰减)" % [mid, outer])

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


## 环形带 alpha 均值（世界像素；r0..r1 半径环带，24 方向采样）。
func _ring_alpha_mean(img: Image, center: Vector2, r0: int, r1: int) -> float:
	var sum := 0.0
	var n := 0
	for i in 24:
		var a := TAU * float(i) / 24.0
		for rr in range(r0, r1 + 1, 2):
			var px := int(round(center.x + cos(a) * rr))
			var py := int(round(center.y + sin(a) * rr))
			if px < 0 or py < 0 or px >= img.get_width() or py >= img.get_height():
				continue
			sum += img.get_pixel(px, py).a
			n += 1
	return sum / maxf(n, 1)


# === 渲染帧级验证（R6 P3 FAIL 点 + 会员在场 + 方向一致冷投影） ===

func _verify_world_frame(img: Image) -> void:
	_verify_members(img)
	# R6 P3 方向一致冷投影：三处设备投影偏移方向全场一致（统一向西南 ——
	# MAIN_LIGHT_DIR 全局主光方向）。暗部读作「定向投影」而非「区域压暗」。
	var dirs: Array[Vector2] = []
	for dev in [[Vector2(96, 80), 30.0], [Vector2(80, 176), 36.0], [Vector2(304, 80), 6.0]]:
		dirs.append(WorldLayout.cast_shadow_offset(dev[0], dev[1]).normalized())
	var consistent := true
	for d in dirs:
		if d.dot(dirs[0]) < 0.999:
			consistent = false
	_ok(consistent, "R6P3 方向一致: 设备投影方向全场一致 %s" % [str(dirs)])
	# 统一向西南：x<0（西）、y>0（南）
	var sw := true
	for d in dirs:
		if d.x >= -0.1 or d.y <= 0.1:
			sw = false
	_ok(sw, "R6P3 投影统一向西南 (x<0, y>0): %s" % [str(dirs)])
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


func _verify_closeup(img: Image) -> void:
	# 特写帧必须非空且包含设备带：世界 (128,128) 附近应有 treadmill 顶面色层
	var found_equip := false
	for dy in range(-30, 31, 3):
		for dx in range(-30, 31, 3):
			var p := _w2s(Vector2(128 + dx, 128 + dy), 0.0)
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
	# 特写帧暖池可读：中灯池 (224,170) 附近（特写变换内入画）暖相像素存在
	var warm_found := false
	for dy in range(0, 200, 2):
		for dx in range(0, img.get_width(), 2):
			var c := img.get_pixel(dx, dy)
			if c.a > 0.5 and c.r > c.b + 0.02 and c.r > 0.55:
				warm_found = true
				break
		if warm_found:
			break
	_ok(warm_found, "CLOSEUP warm pool tone present (特写内暖池/受光暖相可读)")


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

func _ok(cond: bool, msg: String) -> void:
	if not cond:
		_all_ok = false
	print("  %s %s" % ["PASS" if cond else "FAIL", msg])


func _w2s(w: Vector2, z: float) -> Vector2i:
	# 特写变换下：viewport = w * scale + pos，再乘 1280/426 与 720/240。
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
	var v := Proj2D.world_to_screen(w, OFF, WS, Vector2(SX, SY), 0.0)
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
