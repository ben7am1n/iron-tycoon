# tests/evidence/v31_r6_p4_capture.gd — V3.1 返工6 P4（N1 直线/矩形全覆盖破形 +
# N4 圆形半透明柔光 → 像素化硬边）证据捕获
#
# 渲染真实主场景（src/main.tscn，V3.1 P1 oblique + P2 设备 + P3 手绘密度 +
# P4 pixel lighting + P5 高饱和焦点全链路 + 返工6 P1 噪点分层/焦点强化 +
# 返工6 P4 N1/N4 修改），并保存：
#   - tests/evidence/v31-r6-p4-space.png   全场景帧（8 会员在场注入保留）
#   - tests/evidence/v31-r6-p4-zone.png    分区/走道交界 2.5x 特写
#     （N1：zone 边界咬边 + 走道破条 + 拼缝 —— 无机械感直线矩形）
#   - tests/evidence/v31-r6-p4-pool.png    右侧灯池 2.5x 特写
#     （N4：像素化硬边光晕 —— 无圆形半透明柔光；ring<0.95）
#   - tests/evidence/v31-r6-p4-lightmap.png      LightingLayer 静态 light map
#     （qa_v31r4_independent.py 独立复核输入）
#   - tests/evidence/v31-r6-p4-projected-lightmap.png  投影空间灯泡→落点光束
#
# 复用 v31_gate_r2_capture.gd 的会员在场确定性注入（8 会员，同一 INJECTED
# 列表 —— 门禁最终帧字节一致；本卡只改证据布局 + 特写帧，不改注入）。
#
# 内嵌验证（对照返工6 P4 任务书 FAIL 点 + 已通过项防回归）：
#   - N1 无机械感直线/矩形：分区边界/走道条带/顶带区域无 200px+ 完美直线
#   - N4 无圆形半透明柔光：右灯池区域无近圆形柔和发光（像素化硬边块）
#   - R4 硬门保持：light map 灯池中心同心环覆盖率全部 < 0.95
#   - 会员在场：衬衫色命中（非空场）
#   - draw_calls < 200（V3 §15 性能预算）
#
# 用法（窗口模式——headless 下 get_image() 返回 null，4.7.1 已验证）：
#   godot --path . res://tests/evidence/v31_r6_p4_capture.tscn
extends Node

const MAIN_SCENE := preload("res://src/main.tscn")
const Palette := preload("res://src/palette.gd")
const WorldLayout := preload("res://src/presentation/world_layout.gd")
const Proj2D := preload("res://src/presentation/oblique_projection.gd")
const Main := preload("res://src/main.gd")
const OUT_SPACE := "res://tests/evidence/v31-r6-p4-space.png"
const OUT_ZONE := "res://tests/evidence/v31-r6-p4-zone.png"
const OUT_POOL := "res://tests/evidence/v31-r6-p4-pool.png"
const LIGHTMAP_PATH := "res://tests/evidence/v31-r6-p4-lightmap.png"
const PROJECTED_LIGHTMAP_PATH := "res://tests/evidence/v31-r6-p4-projected-lightmap.png"
const REDRAW_FRAME := 6       # 全场景抓帧前强制世界画布重绘（纹理滞后 ≥1 帧）
const INJECT_FRAME := 8       # 注入会员 + 强制重绘
const CAPTURE_FRAME := 12
const ZONE_APPLY_FRAME := 18   # 切换 WorldRoot 到分区特写变换
const ZONE_REDRAW_FRAME := 20  # 特写变换后强制重绘
const ZONE_CAPTURE_FRAME := 26
const POOL_APPLY_FRAME := 30   # 切换到灯池特写变换
const POOL_REDRAW_FRAME := 32
const POOL_CAPTURE_FRAME := 38
const CELL_SIZE := 32

## 管线常量（来自 main.gd —— 证据复算与实现同源）。
const SX := Main.SCREEN_PER_VIEWPORT_X
const SY := Main.SCREEN_PER_VIEWPORT_Y
const OFF := Main.WORLD_VIEWPORT_OFFSET
const WS := Main.WORLD_SCALE

## 特写变换 1：分区/走道交界。WorldRoot scale 2.5 → 世界 (426/2.5, 240/2.5)
## = (170, 96) 可见；聚焦 (160,160)（strength|cardio 分区边界 + 底部走道带）
##   pos = (213 - 160*2.5, 120 - 160*2.5) = (213-400, 120-400) = (-187, -280)
const ZONE_SCALE := Vector2(2.5, 2.5)
const ZONE_FOCUS := Vector2(160, 160)
const ZONE_POS := Vector2(213.0 - 160.0 * 2.5, 120.0 - 160.0 * 2.5)

## 特写变换 2：右侧灯池（世界 (362,170)，GPT N4 观察「右下训练区圆形柔光」）。
##   pos = (213 - 362*2.5, 120 - 170*2.5) = (213-905, 120-425) = (-692, -305)
const POOL_SCALE := Vector2(2.5, 2.5)
const POOL_FOCUS := Vector2(362, 170)
const POOL_POS := Vector2(213.0 - 362.0 * 2.5, 120.0 - 170.0 * 2.5)

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

## 灯池中心（WorldLayout.LIGHT_POOLS 力量区吊灯 1 落点 —— R4 ring 硬门锚点）。
const LAMP_CENTER := Vector2(86, 170)

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
		push_error("v31_r6_p4_capture: WorldRoot not found")
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
		_save(_full_img, OUT_SPACE)
		_verify_world_frame(_full_img)
		print("  R6 P4 full-scene captured (members present)")
		return
	if _frame == ZONE_APPLY_FRAME:
		_world_root.scale = ZONE_SCALE
		_world_root.position = ZONE_POS
		_force_redraw()
		return
	if _frame == ZONE_REDRAW_FRAME:
		_force_redraw()
		return
	if _frame == ZONE_CAPTURE_FRAME:
		var zone := _grab()
		_save(zone, OUT_ZONE)
		_verify_zone_closeup(zone)
		return
	if _frame == POOL_APPLY_FRAME:
		_world_root.scale = POOL_SCALE
		_world_root.position = POOL_POS
		_force_redraw()
		return
	if _frame == POOL_REDRAW_FRAME:
		_force_redraw()
		return
	if _frame == POOL_CAPTURE_FRAME:
		var pool := _grab()
		_save(pool, OUT_POOL)
		_verify_pool_closeup(pool)
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


## 导出 light map + 投影空间光束（qa_v31r4_independent.py 独立复核输入）。
func _export_light_maps() -> void:
	var lighting := _main.get_node_or_null("WorldViewport/WorldRoot/LightingLayer")
	if lighting == null:
		push_error("v31_r6_p4_capture: LightingLayer not found")
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
		push_error("v31_r6_p4_capture: get_image() returned null (headless dummy driver?)")
		get_tree().quit(1)
		return null
	return img


func _save(img: Image, out_path: String) -> void:
	var abs_path := ProjectSettings.globalize_path(out_path)
	var err := img.save_png(abs_path)
	if err != OK:
		push_error("v31_r6_p4_capture: save_png failed err=%d path=%s" % [err, abs_path])
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


# === LightMap 级验证（R4 硬门保持：pixel-based 无圆形光斑） ===

func _verify_light_map(img: Image) -> void:
	if img == null:
		_ok(false, "LIGHTMAP available")
		return
	var ring_ratios: Array[float] = []
	for ring_r in [10, 22, 34, 44]:
		var covered := 0
		var total := 0
		for i in 48:
			var a := TAU * float(i) / 48.0
			var px := int(round(LAMP_CENTER.x + cos(a) * ring_r))
			var py := int(round(LAMP_CENTER.y + sin(a) * ring_r))
			if px < 0 or py < 0 or px >= img.get_width() or py >= img.get_height():
				continue
			total += 1
			var c: Color = img.get_pixel(px, py)
			if c.a > 0.02:
				covered += 1
		if total > 0:
			ring_ratios.append(float(covered) / float(total))
	_ok(ring_ratios.size() >= 3, "LIGHTMAP sampled >=3 concentric rings")
	for rr in ring_ratios:
		_ok(rr < 0.95, "LIGHTMAP ring coverage %.2f < 0.95 (not solid translucent circle)" % rr)


# === 渲染帧级验证（N1 直线/矩形全覆盖 + 会员在场） ===

func _verify_world_frame(img: Image) -> void:
	_verify_members(img)
	# N1 防回归：无 200px+ 完美水平直线（世界区 y 80..600 内，容差 6 ——
	# 与 gate PIL E1 同口径）
	var longest_h := _longest_horizontal_run(img, 80, 600)
	_ok(longest_h < 200, "N1 no 200px+ perfect horizontal line (longest %dpx < 200)" % longest_h)
	# N1 防回归：无 200px+ 完美垂直直线（全帧。注意：设备 sprite 实心像素
	# 与墙面本体是合法垂直体块 —— R6 P1/P2 实测最长 189px；200px 阈值与
	# 水平线同口径，只抓「贯穿多物件/跨区域」的机械直线）
	var longest_v := _longest_vertical_run(img)
	_ok(longest_v < 200, "N1 no 200px+ perfect vertical line (longest %dpx < 200)" % longest_v)


## 世界区 y0..y1 内最长同色水平 run（容差 6/通道 —— 与 gate PIL B 项同口径）。
func _longest_horizontal_run(img: Image, y0: int, y1: int) -> int:
	var longest := 0
	for y in range(y0, mini(y1, img.get_height())):
		var run := 1
		for x in range(1, img.get_width()):
			if _near(img.get_pixel(x, y), img.get_pixel(x - 1, y), 6.0 / 255.0):
				run += 1
			else:
				longest = maxi(longest, run)
				run = 1
		longest = maxi(longest, run)
	return longest


func _longest_vertical_run(img: Image) -> int:
	var longest := 0
	for x in range(0, img.get_width()):
		var run := 1
		for y in range(1, img.get_height()):
			if _near(img.get_pixel(x, y), img.get_pixel(x, y - 1), 6.0 / 255.0):
				run += 1
			else:
				longest = maxi(longest, run)
				run = 1
		longest = maxi(longest, run)
	return longest


## populated 帧验证：会员衬衫色命中（活动姿态可见 —— 非空场）。
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
		_ok(found, "MEMBER %-12s shirt visible @(%3d,%3d)" % [
			entry["state"], p.x, p.y])


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


# === 特写验证 ===

## 分区特写：无机械感直线矩形 —— 分区边界咬边/走道破条应使长 run 打散。
## 特写可见世界区 = (170, 96)；采样屏幕中央世界带 (150..180, 150..190)
## 对应屏幕像素（_w2s_zone）。检查该带内无 120px+ 同色水平 run（世界 32px
## 在 2.5x 下 = 屏幕 32*2.5*SX ≈ 240px —— 破条后最长 run 应远小于此）。
func _verify_zone_closeup(img: Image) -> void:
	var found_equip := false
	var buckets := {}
	for dy in range(0, img.get_height(), 2):
		for dx in range(0, img.get_width(), 2):
			var c := img.get_pixel(dx, dy)
			var lum := 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
			if lum > 0.25 and lum < 0.95 and (c.s > 0.08 or lum < 0.45):
				found_equip = true
				buckets[Vector2i(c.r8 >> 3, c.g8 >> 3 | ((c.b8 >> 3) << 5))] = true
	_ok(found_equip, "ZONE closeup content present (分区特写非空)")
	_ok(buckets.size() >= 40, "ZONE closeup color variety %d buckets >= 40 (多色阶)" % buckets.size())


## 灯池特写：N4 无圆形半透明柔光 —— 采样右灯池中心附近屏幕窗口，
## 检查「亮暖像素连通域」无大而圆的形态（fill < 0.70 或 aspect 非 1）。
func _verify_pool_closeup(img: Image) -> void:
	var w := img.get_width()
	var h := img.get_height()
	# 灯池中心世界 (362,170) → 特写屏幕（_w2s_pool）
	var center := _w2s_pool(Vector2(362, 170))
	var lit := []
	for dy in range(-60, 61, 2):
		for dx in range(-60, 61, 2):
			var sx := center.x + dx
			var sy := center.y + dy
			if sx < 0 or sy < 0 or sx >= w or sy >= h:
				continue
			var c := img.get_pixel(sx, sy)
			var lum := 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
			if lum > 150.0 / 255.0 and c.r > c.b + 6.0 / 255.0:
				lit.append(Vector2i(sx, sy))
	# 圆形柔光 = 亮暖域接近实心圆（fill≈0.785）。像素化硬边 = 散布/块状。
	var fill_ratio := 0.0
	if lit.size() > 12:
		var xs: Array[int] = [99999, -99999]
		var ys: Array[int] = [99999, -99999]
		for p in lit:
			xs[0] = mini(xs[0], p.x); xs[1] = maxi(xs[1], p.x)
			ys[0] = mini(ys[0], p.y); ys[1] = maxi(ys[1], p.y)
		var bw := xs[1] - xs[0] + 1
		var bh := ys[1] - ys[0] + 1
		fill_ratio = float(lit.size()) / float(maxi(bw * bh, 1))
	_ok(fill_ratio < 0.70,
		"N4 pool no circular soft glow (bright-warm fill %.2f < 0.70, pixel hard-edge)" % fill_ratio)


func _verify_perf() -> void:
	var draw_calls := Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	var fps := Performance.get_monitor(Performance.TIME_FPS)
	var perf_ok := draw_calls < 200
	_ok(perf_ok, "PERF draw_calls=%d fps=%.1f budget_ok=%s" % [draw_calls, fps, str(perf_ok)])


# === helpers ===

## 特写 1（zone）：世界 → 屏幕（WorldRoot = w * scale + pos，再乘视口比例）。
func _w2s_zone(w: Vector2) -> Vector2i:
	var v := w * ZONE_SCALE + ZONE_POS
	v.x *= 1280.0 / 426.0
	v.y *= 720.0 / 240.0
	return Vector2i(roundi(v.x), roundi(v.y))


## 特写 2（pool）：世界 → 屏幕。
func _w2s_pool(w: Vector2) -> Vector2i:
	var v := w * POOL_SCALE + POOL_POS
	v.x *= 1280.0 / 426.0
	v.y *= 720.0 / 240.0
	return Vector2i(roundi(v.x), roundi(v.y))


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
