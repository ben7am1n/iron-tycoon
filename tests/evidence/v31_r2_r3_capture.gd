# tests/evidence/v31_r2_r3_capture.gd — V3.1 返工2 R3 灯光/第三眼证据捕获
#
# 渲染真实主场景（src/main.tscn，V3 §2 SubViewport 低分辨率管线）并保存：
#   1. tests/evidence/v31-r2-r3-lighting.png —— 第三眼全场景帧
#      （暖光照明系统：光源→受光面→扩散连续；方向一致冷投影；三层景深）
#   2. tests/evidence/v31-r2-r3-closeup.png —— 灯光路径/投影特写
#      （吊灯→光束→灯下地面/设备受光带 + 设备/会员方向投影）
#
# 验收对照（返工2 R3 任务书 FAIL 点）：
#   - FAIL1 暖光照明：灯下地面/设备表面有连续暖色提亮（受光面），沿光源
#     方向衰减到环境冷色 —— 光不是孤立色块，而是让物体「被照亮」
#   - FAIL2 方向一致冷投影：物体在光源另一侧投出有方向的冷色投影（遮挡
#     投影而非区域底色）；投影随物体形状与光源位置变化，方向全场一致
#   - FAIL3 三层景深：前景物体明度高/对比强，中景器械中等，背景墙面明度
#     低或偏冷 —— 通过明度（非仅饱和度）拉开三层
#   - P4 负约束：无圆形 gradient 光斑；局部辉光（屏幕/灯罩）小范围亮色
#
# 用法（窗口模式——headless dummy 驱动下 get_image() 返回 null，项目既有
# 证据方法，见 v31_r2_r2_capture.gd 同款注释）：
#   godot --path . res://tests/evidence/v31_r2_r3_capture.tscn
extends Node

const MAIN_SCENE := preload("res://src/main.tscn")
const Main := preload("res://src/main.gd")
const Proj2D := preload("res://src/presentation/oblique_projection.gd")
const Palette := preload("res://src/palette.gd")
const WorldLayout := preload("res://src/presentation/world_layout.gd")
const OUT_FULL := "res://tests/evidence/v31-r2-r3-lighting.png"
const OUT_CLOSEUP := "res://tests/evidence/v31-r2-r3-closeup.png"
const REDRAW_FRAME := 6
const INJECT_FRAME := 10       # 注入规范会员（冻结模拟）
const CAPTURE_FRAME := 18      # 全场景抓帧（注入后纹理更新）
const CLOSEUP_APPLY_FRAME := 24
const CLOSEUP_REDRAW_FRAME := 26
const CLOSEUP_CAPTURE_FRAME := 32
const CELL_SIZE := 32
const CLOSEUP_SCALE := Vector2(2.0, 2.0)
const CLOSEUP_POS := Vector2(213.0 - 128.0 * 2.0, 120.0 - 128.0 * 2.0)

## 管线常量（来自 main.gd —— 证据复算与实现同源）。
const SX := Main.SCREEN_PER_VIEWPORT_X
const SY := Main.SCREEN_PER_VIEWPORT_Y
const OFF := Main.WORLD_VIEWPORT_OFFSET
const WS := Main.WORLD_SCALE

## 注入会员（确定性；覆盖走道/排队/离场 + 设备使用接触点）。
const INJECTED := [
	{"member_id": 9300, "state": "WALKING_TO", "cell": Vector2i(5, 2)},
	{"member_id": 9301, "state": "WALKING_TO", "cell": Vector2i(11, 2)},
	{"member_id": 9302, "state": "QUEUEING", "cell": Vector2i(3, 6)},
	{"member_id": 9303, "state": "LEAVING", "cell": Vector2i(10, 6), "leaving_reason": "quota_met"},
	{"member_id": 9304, "state": "USING", "cell": Vector2i(3, 3), "target_equipment": "treadmill"},
	{"member_id": 9305, "state": "USING", "cell": Vector2i(2, 6), "target_equipment": "bike"},
]

var _frame := 0
var _injected := false
var _main: Node = null
var _sim = null
var _orch = null
var _world_root: Node2D = null
var _all_ok := true
var _full_img: Image = null


func _ready() -> void:
	_main = MAIN_SCENE.instantiate()
	add_child(_main)
	_sim = _main.get("_member")
	_orch = _main.get("_orch")
	if _orch != null and _orch.time_system != null:
		_orch.time_system.pause()
	_place_preset_equipment()
	_world_root = _main.get_node_or_null("WorldViewport/WorldRoot")
	if _world_root == null:
		push_error("v31_r2_r3_capture: WorldRoot not found")
		get_tree().quit(1)


## 显式放置预置设备（与 v31_r2_r2_capture 同源）。
func _place_preset_equipment() -> void:
	if _orch == null or _orch.placement_system == null:
		return
	var placement = _orch.placement_system
	var grid = _orch.grid_system
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
	if _frame == REDRAW_FRAME:
		_canvas_redraw()
		return
	if _frame == INJECT_FRAME and not _injected:
		_injected = true
		_inject_deterministic()
		# 注入后必须显式重绘 WorldCanvas/LightingLayer（_main.queue_redraw()
		# 不会传导到子 CanvasItem）—— 否则 CAPTURE_FRAME 全场景帧仍是注入前
		# 的空场（会员影子/受光带断言会打到错误锚点）。
		_canvas_redraw()
		return
	if _frame == CAPTURE_FRAME:
		_capture_full()
		return
	if _frame == CLOSEUP_APPLY_FRAME:
		_world_root.scale = CLOSEUP_SCALE
		_world_root.position = CLOSEUP_POS
		_canvas_redraw()
		return
	if _frame == CLOSEUP_REDRAW_FRAME:
		_canvas_redraw()
		return
	if _frame == CLOSEUP_CAPTURE_FRAME:
		_capture_closeup()
		return


func _canvas_redraw() -> void:
	var canvas := _main.get_node_or_null("WorldViewport/WorldRoot/WorldCanvas")
	if canvas != null:
		canvas.queue_redraw()
	var lighting := _main.get_node_or_null("WorldViewport/WorldRoot/LightingLayer")
	if lighting != null:
		lighting.queue_redraw()


## 冻结 + 注入规范会员（已知状态/坐标/设备 → 确定性采样）。
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
		push_error("v31_r2_r3_capture: get_image() returned null (headless dummy driver?)")
		get_tree().quit(1)
	return img


func _save(img: Image, path: String) -> void:
	var err := img.save_png(ProjectSettings.globalize_path(path))
	if err != OK:
		push_error("v31_r2_r3_capture: save_png failed err=%d path=%s" % [err, path])
		get_tree().quit(1)
	print("CAPTURE saved=%s size=%dx%d" % [path, img.get_width(), img.get_height()])


func _capture_full() -> void:
	var img := _grab()
	_full_img = img
	_save(img, OUT_FULL)
	_verify_warm_lighting(img)
	_verify_directional_shadows(img)
	_verify_three_layer_depth(img)
	_verify_no_circle_blob(img)
	_verify_perf()
	print("RESULT: %s" % ("PASS" if _all_ok else "CHECK"))


## FAIL1 暖光照明：灯下地面暖亮（受光面）+ 设备顶面有暖色受光带 + 远离
## 光源回落冷色。采样锚点：吊灯落点灯池、treadmill(6,3) 顶面（西侧受光带，
## 无会员占用 —— treadmill(2,2) 顶面被 USING 会员 sprite 覆盖，不再采样）、
## 力量区远端。
func _verify_warm_lighting(img: Image) -> void:
	# 灯池中心（LIGHT_POOLS[0] 力量区）暖亮
	var pool := WorldLayout.LIGHT_POOLS[0]
	var pool_screen := _world_to_screen_v(pool)
	var pool_warm := _window_warm_count(img, pool_screen, 10)
	_ok(pool_warm >= 8, "FAIL1 灯下地面暖亮像素存在（受光面, warm=%d）" % pool_warm)
	# 设备顶面受光带：treadmill(6,3) footprint (192,96,64,32) 顶面 z=30 西侧
	# （受光带朝向最近吊灯落点 —— band 覆盖西半顶面，暖像素充足）
	var tm_screen := _world_to_screen_v(Vector2(200, 112), 30.0)
	var tm_warm := _window_warm_count(img, tm_screen, 16)
	_ok(tm_warm >= 4, "FAIL1 设备顶面暖色受光带存在（被照亮, warm=%d）" % tm_warm)
	# 扩散衰减：灯池暖度 > 力量区远端（远离光源回落冷色）
	var far_screen := _world_to_screen_v(Vector2(60, 90))
	var pool_w = _window_avg_warm(img, pool_screen, 8)
	var far_w = _window_avg_warm(img, far_screen, 8)
	_ok(pool_w > far_w + 0.004, "FAIL1 灯池暖度 %.3f > 远端 %.3f（沿光源方向衰减）" % [pool_w, far_w])


## FAIL2 方向一致冷投影：设备/会员脚下在光源另一侧有冷色投影（遮挡投影）。
## 采样：bike(2,5) footprint (64,160,32,32) 南侧（远离灯方向）应有冷暗像素；
## 墙边暗角仍存在（冷色环境）。方向一致性：两处投影的偏移方向（朝南）一致。
func _verify_directional_shadows(img: Image) -> void:
	# bike 方向投影：footprint 中心朝南偏移（cast_shadow_offset 背向最近灯）
	var bike_center := Vector2(80, 176)
	var bike_offset := WorldLayout.cast_shadow_offset(bike_center, 36.0)
	var shadow_world := bike_center + bike_offset
	var shadow_screen := _world_to_screen_v(shadow_world)
	var cool_count := _window_cool_count(img, shadow_screen, 10)
	_ok(cool_count >= 2, "FAIL2 bike 方向投影冷色像素存在（遮挡投影, cool=%d @%s）" \
		% [cool_count, str(shadow_screen)])
	# 方向一致性：两台设备投影偏移方向（y 增量）都朝南（远离北墙吊灯）
	var tm_center := Vector2(96, 80)
	var tm_offset := WorldLayout.cast_shadow_offset(tm_center, 30.0)
	var bench_center := Vector2(64, 240)
	var bench_offset := WorldLayout.cast_shadow_offset(bench_center, 26.0)
	_ok(tm_offset.y > 4.0 and bench_offset.y > 4.0 and bike_offset.y > 4.0,
		"FAIL2 投影方向全场一致（均远离北墙吊灯向南: tm=%.0f bike=%.0f bench=%.0f）" \
		% [tm_offset.y, bike_offset.y, bench_offset.y])
	# 会员方向投影：QUEUEING(3,6) 脚底南侧冷暗
	var member_world := Vector2(3 * CELL_SIZE + 16, 6 * CELL_SIZE + 32)
	var m_offset := WorldLayout.cast_shadow_offset(member_world, 20.0)
	var m_screen := _world_to_screen_v(member_world + m_offset)
	var m_cool := _window_cool_count(img, m_screen, 8)
	_ok(m_cool >= 1, "FAIL2 会员方向投影冷色像素存在（cool=%d）" % m_cool)


## FAIL3 三层景深：背景墙面明度低/偏冷，中景器械中等，前景物体明度高。
## 采样：北墙面（背景，选两灯之间的纯墙段避开光束）、treadmill(6,3) 顶面
## 受光带（中景 —— 无会员占用；treadmill(2,2) 顶面被 USING 会员 sprite
## 覆盖，不采样）、前景暖光带（前景）。
func _verify_three_layer_depth(img: Image) -> void:
	var wall_screen := _wall_screen(60, 12)   # 北墙中段，入口门洞以东纯墙（避光束/窗/墙饰）
	var wall_lum := _window_avg_lum(img, wall_screen, 10)
	var tm_screen := _world_to_screen_v(Vector2(200, 112), 30.0)
	var tm_lum := _window_avg_lum(img, tm_screen, 12)
	var fore_screen := _world_to_screen_v(Vector2(230, 265))
	var fore_lum := _window_avg_lum(img, fore_screen, 12)
	_ok(wall_lum <= tm_lum + 0.01, "FAIL3 背景墙面明度 %.3f ≤ 中景器械 %.3f（背景偏暗/偏冷）" \
		% [wall_lum, tm_lum])
	_ok(fore_lum >= wall_lum - 0.01, "FAIL3 前景明度 %.3f ≥ 背景 %.3f（前景可读）" \
		% [fore_lum, wall_lum])


## P4 负约束：灯池区域无圆形 gradient 光斑（hash 散射 cluster —— 同心环
## alpha 覆盖率 < 0.95 且非均匀）。
func _verify_no_circle_blob(img: Image) -> void:
	var pool := WorldLayout.LIGHT_POOLS[0]
	var pool_screen := _world_to_screen_v(pool)
	var coverage_total := 0.0
	var rings := 0
	for ring_r in [8.0, 14.0, 20.0]:
		var hits := 0
		var sampled := 0
		for i in 24:
			var a := TAU * float(i) / 24.0
			var p := pool_screen + Vector2i(roundi(cos(a) * ring_r), roundi(sin(a) * ring_r))
			var c := img.get_pixel(p.x, p.y)
			sampled += 1
			if c.r > c.b + 0.02 and c.r > 0.4:
				hits += 1
		coverage_total += float(hits) / maxi(sampled, 1)
		rings += 1
	var avg_coverage := coverage_total / maxi(rings, 1)
	_ok(avg_coverage < 0.95, "P4 灯池无圆形实心光斑（环覆盖率 %.2f < 0.95）" % avg_coverage)


func _verify_perf() -> void:
	var draw_calls := Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	var fps := Performance.get_monitor(Performance.TIME_FPS)
	_ok(draw_calls < 200, "PERF draw_calls=%d (<200)" % draw_calls)
	print("  PERF draw_calls=%d fps=%.1f" % [draw_calls, fps])


## 特写：灯光路径/投影（吊灯→光束→灯下地面/设备受光带 + 设备方向投影）。
func _capture_closeup() -> void:
	var img := _grab()
	_save(img, OUT_CLOSEUP)
	# 特写帧冷投影 + 暖受光带验证（放大 2×，锚点从全场景换算）
	var bike_center := Vector2i(376, 480)
	var bike_crop := _crop_around(img, bike_center, 170)
	if bike_crop != null:
		_verify_closeup_lit(bike_crop, "BIKE")
	var tm_center := Vector2i(337, 346)
	var tm_crop := _crop_around(img, tm_center, 170)
	if tm_crop != null:
		_verify_closeup_lit(tm_crop, "TREAD")
	print("RESULT: %s" % ("PASS" if _all_ok else "CHECK"))
	get_tree().quit(0 if _all_ok else 1)


## 特写帧：暖受光带（r>b）与冷投影（b>r）并存 —— 设备被照亮 + 投出方向影。
func _verify_closeup_lit(img: Image, tag: String) -> void:
	var warm := 0
	var cool := 0
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			if c.r > c.b + 0.04:
				warm += 1
			elif c.b > c.r + 0.04:
				cool += 1
	_ok(warm > 30, "%s 特写暖受光像素存在（warm=%d）" % [tag, warm])
	_ok(cool > 30, "%s 特写冷投影像素存在（cool=%d）" % [tag, cool])


## 世界坐标 → 屏幕（与 main.gd 同源复算）。
func _world_to_screen_v(w: Vector2, z: float = 0.0) -> Vector2i:
	var v := Proj2D.world_to_screen(w, OFF, WS, Vector2(SX, SY), z)
	return Vector2i(roundi(v.x), roundi(v.y))


## 北墙本地坐标 → 屏幕（_north_wall_transform 同源复算：fy=24→z=0，
## fy=0→z=WALL_HEIGHT）。
func _wall_screen(fx: float, fy: float) -> Vector2i:
	var kex := Proj2D.WALL_HEIGHT * Proj2D.EXTRUDE_X / 24.0
	var khe := Proj2D.WALL_HEIGHT * Proj2D.HEIGHT_SCALE / 24.0
	var ox := 24.0 * Proj2D.SHEAR - 24.0 * kex
	var oy := 24.0 * Proj2D.FLOOR_SCALE - 24.0 * khe
	var px := fx + fy * kex + ox
	var py := fy * khe + oy
	var v := Vector2(px * WS + OFF.x, py * WS + OFF.y) * Vector2(SX, SY)
	return Vector2i(roundi(v.x), roundi(v.y))


## 以 [center] 为中心裁剪 [radius]×2 方形区域（越界自动 clamp）。
func _crop_around(img: Image, center: Vector2i, radius: int) -> Image:
	var w := img.get_width()
	var h := img.get_height()
	var x0 := clampi(center.x - radius, 0, w - 1)
	var y0 := clampi(center.y - radius, 0, h - 1)
	var x1 := clampi(center.x + radius, 0, w - 1)
	var y1 := clampi(center.y + radius, 0, h - 1)
	if x1 - x0 <= 0 or y1 - y0 <= 0:
		return null
	var src := img
	if img.get_format() != Image.FORMAT_RGBA8:
		src = img.duplicate()
		src.convert(Image.FORMAT_RGBA8)
	var out := Image.create(x1 - x0, y1 - y0, false, Image.FORMAT_RGBA8)
	out.blit_rect(src, Rect2i(x0, y0, x1 - x0, y1 - y0), Vector2i.ZERO)
	return out


func _window_warm_count(img: Image, center: Vector2i, radius: int) -> int:
	var n := 0
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var p := center + Vector2i(dx, dy)
			if p.x < 0 or p.y < 0 or p.x >= img.get_width() or p.y >= img.get_height():
				continue
			var c := img.get_pixel(p.x, p.y)
			if c.r > c.b + 0.03 and c.r > 0.35:
				n += 1
	return n


func _window_cool_count(img: Image, center: Vector2i, radius: int) -> int:
	var n := 0
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var p := center + Vector2i(dx, dy)
			if p.x < 0 or p.y < 0 or p.x >= img.get_width() or p.y >= img.get_height():
				continue
			var c := img.get_pixel(p.x, p.y)
			if c.b > c.r + 0.02 and c.r < 0.5:
				n += 1
	return n


func _window_avg_warm(img: Image, center: Vector2i, radius: int) -> float:
	var total := 0.0
	var n := 0
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var p := center + Vector2i(dx, dy)
			if p.x < 0 or p.y < 0 or p.x >= img.get_width() or p.y >= img.get_height():
				continue
			var c := img.get_pixel(p.x, p.y)
			total += c.r - c.b
			n += 1
	return total / maxi(n, 1)


func _window_avg_lum(img: Image, center: Vector2i, radius: int) -> float:
	var total := 0.0
	var n := 0
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var p := center + Vector2i(dx, dy)
			if p.x < 0 or p.y < 0 or p.x >= img.get_width() or p.y >= img.get_height():
				continue
			var c := img.get_pixel(p.x, p.y)
			total += 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
			n += 1
	return total / maxi(n, 1)


func _ok(cond: bool, msg: String) -> void:
	if not cond:
		_all_ok = false
	print("  %s %s" % ["PASS" if cond else "FAIL", msg])
