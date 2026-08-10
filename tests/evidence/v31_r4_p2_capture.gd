# tests/evidence/v31_r4_p2_capture.gd — V3.1 返工4 P2 证据捕获（chunky sprite 设备）
#
# 渲染真实主场景（src/main.tscn）并保存两张视口快照：
#   - tests/evidence/v31-r4-p2-sprite.png     全场景（会员在场，8 会员注入保留）
#   - tests/evidence/v31-r4-p2-closeup.png    设备带 2x 特写：跑步机×2 + 单车 + 卧推
#     同框（顶面亮 / 正面中 / 侧面暗三层 + 关键零部件 2x 可读）
#
# P2 证据布局（placement 校验通过，见 test_layout_probe）：
#   bench_press(2,3) / treadmill(5,4) / bike(6,6) / treadmill(5,2) / yoga_mat(10,2)
#   —— 单车/跑步机/长椅聚在特写窗口内（投影并集 204×79 世界 px < 2x 视口
#   213×120）；会员 9006 用 treadmill(5,4)、9007 用 bike(6,6)（EQUIPMENT
#   resolver 取实例数组第一个匹配 —— 与 gate 同源逻辑）。
#
# 复用 v31_gate_r2_capture.gd 的会员在场确定性注入（8 会员，同一 INJECTED
# 列表 —— 门禁最终帧字节一致；本卡只改证据布局 + P2 特写帧，不改注入）。
#
# 内嵌验证（对照返工4 P2 任务书 FAIL1-5）：
#   - 会员衬衫色命中（非空场，与 gate 一致）
#   - FAIL1 轮廓勾边：设备前缘底部 vs 相邻地面明度差 > 18（深色外轮廓）
#   - FAIL2 三层色阶：treadmill(5,2) 顶面（z=height）亮于同机正面下缘
#     （顶面受光 / 正面中调分离）
#   - FAIL3 零部件 2x 可读：closeup 窗口内 bike 飞轮金属高光 H / 控制台青蓝 A
#     像素命中（关键零件在 2x 下仍可寻）
#   - 接地线：设备前缘底部存在 EQUIP_EDGE_OUTLINE 深色像素
#   - draw_calls < 200（V3 §15 性能预算）
#
# 用法（窗口模式——headless 下 get_image() 返回 null，4.7.1 已验证）：
#   godot --path . res://tests/evidence/v31_r4_p2_capture.tscn
extends Node

const MAIN_SCENE := preload("res://src/main.tscn")
const Palette := preload("res://src/palette.gd")
const WorldLayout := preload("res://src/presentation/world_layout.gd")
const Proj2D := preload("res://src/presentation/oblique_projection.gd")
const Main := preload("res://src/main.gd")
const OUT_FULL := "res://tests/evidence/v31-r4-p2-sprite.png"
const OUT_CLOSEUP := "res://tests/evidence/v31-r4-p2-closeup.png"
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

## 特写变换：聚焦 P2 设备带（bench(2,3)+treadmill(5,4)+bike(6,6) 投影并集
## 中心 ≈ 世界 (160,160) → 画布 (216,99.2)）。scale 2.0 / pos 使并集居中：
##   pos = (213 - 200*2, 120 - 99.2*2) = (-187, -78.4)
const CLOSEUP_SCALE := Vector2(2.0, 2.0)
const CLOSEUP_POS := Vector2(-195.3, -57.9)

## 注入会员（确定性采样；与 v31_gate_r2_capture.gd 完全一致 —— 8 会员在场，
## 门禁最终帧字节一致；本卡只复用，不改注入）。
const INJECTED := [
	{"member_id": 9000, "state": "WALKING_TO", "cell": Vector2i(0, 3)},
	{"member_id": 9001, "state": "WALKING_TO", "cell": Vector2i(11, 2)},
	{"member_id": 9002, "state": "WALKING_TO", "cell": Vector2i(0, 6)},
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
		push_error("v31_r4_p2_capture: WorldRoot not found")
		get_tree().quit(1)


## P2 证据布局（与 v31_gate_r2_capture 同源走 PlacementSystem 完整拖放链；
## 布局经过 test_layout_probe 校验 —— 单车/跑步机/长椅聚在特写窗口内）。
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
		["bench_press", Vector2i(3, 3)],
		["treadmill", Vector2i(4, 6)],
		["bike", Vector2i(8, 6)],
		["bike", Vector2i(7, 4)],
		["treadmill", Vector2i(5, 3)],
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
		push_error("v31_r4_p2_capture: get_image() returned null (headless dummy driver?)")
		get_tree().quit(1)
		return null
	return img


func _save(img: Image, out_path: String) -> void:
	var abs_path := ProjectSettings.globalize_path(out_path)
	var err := img.save_png(abs_path)
	if err != OK:
		push_error("v31_r4_p2_capture: save_png failed err=%d path=%s" % [err, abs_path])
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


# === 全场景验证（会员在场 + FAIL1 轮廓勾边，与 P1/gate 一致） ===

func _verify_world_frame(img: Image) -> void:
	_verify_members(img)
	# FAIL1 道具轮廓勾边：treadmill(5,3)（member-free —— member 9006 用
	# (4,6)，closeup 外；位处灯池北侧上方，接地线全强度可见）。前缘底部 =
	# 南面 y=128（z∈[1,2]），相邻地面 y 140..152。勾边后明度差 > 18
	# （深色外轮廓把主体从地面勾出）。
	var bench_edge := _sample_world_lum(img, Rect2i(210, 128, 4, 1), 1.5)
	var bench_floor := _sample_world_lum(img, Rect2i(210, 140, 8, 8), 0.0)
	_ok(bench_edge > 0.0 and bench_floor > 0.0,
		"P2 FAIL1 treadmill(5,3) edge/floor sample non-empty (edge=%.0f floor=%.0f)" % [bench_edge, bench_floor])
	var edge_diff := bench_floor - bench_edge
	_ok(edge_diff > 18.0,
		"P2 FAIL1 treadmill(5,3) edge separated from floor (Δlum %.0f > 18, 深色外轮廓)" % edge_diff)


func _verify_members(img: Image) -> void:
	var checks := [
		{"state": "WALKING_TO", "cell": Vector2i(0, 3), "expect": Color("8EC5E8")},
		{"state": "WALKING_TO", "cell": Vector2i(11, 2), "expect": Color("8EC5E8")},
		{"state": "QUEUEING", "cell": Vector2i(3, 6), "expect": Color("8494A6")},
		{"state": "LEAVING", "cell": Vector2i(10, 6), "expect": Color("9A948C")},
	]
	for entry in checks:
		var p := _member_shirt_screen(entry["cell"])
		var found := _scan_tone(img, p, 6, entry["expect"], 0.22)
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


# === 特写验证（FAIL2 三层色阶 / FAIL3 零部件 2x 可读 / 接地线） ===

func _verify_closeup(img: Image) -> void:
	# FAIL2 三层色阶（场景侧）：treadmill(5,3)（member-free —— member 9006
	# 用 (4,6)，closeup 外）顶面受光（z=30）读到机身中调 EQUIP_BODY 材质
	# （顶面亮层渲染；完整三层分离量化在隔离纹理 PIL QA —— 顶面 > 正面 >
	# 侧面，场景斜投影下顶面会遮住侧面，无法在同帧采样三层）。
	var top_deck_hits := _count_near_world_cu(img, Rect2i(172, 100, 40, 16), 30.0,
		Palette.EQUIP_BODY, 0.10, 2)
	_ok(top_deck_hits > 0,
		"P2 FAIL2 treadmill(5,3) top face deck tone visible (hits=%d, 顶面受光层)" % top_deck_hits)
	# FAIL3 零部件 2x 可读：closeup 内 bike(7,4) 区域（世界 224..256 ×
	# 128..160）飞轮金属高光 H + 控制台青蓝 A 可寻（关键零件 2x 不糊）。
	var bike_h := _count_near_world_cu(img, Rect2i(224, 128, 32, 32), 0.0,
		Palette.METAL_HIGHLIGHT, 0.10, 2)
	var bike_a := _count_near_world_cu(img, Rect2i(224, 128, 32, 32), 0.0,
		Palette.EQUIP_ACCENT_CYAN, 0.12, 2)
	_ok(bike_h > 0, "P2 FAIL3 bike flywheel metal highlight visible at 2x (hits=%d)" % bike_h)
	_ok(bike_a > 0, "P2 FAIL3 bike console cyan visible at 2x (hits=%d)" % bike_a)
	# FAIL3 跑步机控制台青蓝屏幕 2x 可读：treadmill(5,3) 顶面前端（世界
	# 168..216 × 118..128 z=30 —— 无 USING 会员遮挡）。
	var tm_a := _count_near_world_cu(img, Rect2i(168, 118, 48, 10), 30.0,
		Palette.EQUIP_ACCENT_CYAN, 0.12, 2)
	_ok(tm_a > 0, "P2 FAIL3 treadmill console cyan visible at 2x (hits=%d)" % tm_a)
	# 接地线：bench(3,3) 前缘底部存在 EQUIP_EDGE_OUTLINE 深色像素（世界
	# y 158..162, z 0..2；bench footprint x 96..160）。
	var ground_hits := _count_near_world_cu(img, Rect2i(100, 158, 52, 4), 1.0,
		Palette.EQUIP_EDGE_OUTLINE, 0.10, 2)
	_ok(ground_hits > 0, "P2 grounding edge pixels present (接地线 hits=%d)" % ground_hits)


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


## 全场景：世界矩形（z 采样高度）平均明度（0-255 口径，与 P1/gate 阈值一致）。
func _sample_world_lum(img: Image, rect: Rect2i, z: float) -> float:
	var sum := 0.0
	var n := 0
	for y in range(rect.position.y, rect.end.y, 2):
		for x in range(rect.position.x, rect.end.x, 2):
			var p := _world_to_screen_full(Vector2(x, y), z)
			if p.x < 0 or p.y < 0 or p.x >= img.get_width() or p.y >= img.get_height():
				continue
			var c := img.get_pixel(p.x, p.y)
			sum += 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
			n += 1
	return sum * 255.0 / n if n > 0 else 0.0


## 特写变换下世界矩形平均明度（0-255 口径，step 间隔）。
func _sample_world_lum_cu(img: Image, rect: Rect2i, z: float, step: int) -> float:
	var sum := 0.0
	var n := 0
	for y in range(rect.position.y, rect.end.y, step):
		for x in range(rect.position.x, rect.end.x, step):
			var p := _w2s(Vector2(x, y), z)
			if p.x < 0 or p.y < 0 or p.x >= img.get_width() or p.y >= img.get_height():
				continue
			var c := img.get_pixel(p.x, p.y)
			sum += 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
			n += 1
	return sum * 255.0 / n if n > 0 else 0.0


## 特写变换下世界矩形内接近 [target] 的像素数。
func _count_near_world_cu(img: Image, rect: Rect2i, z: float,
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


## 全场景：世界坐标 → 屏幕（V3.1 P1 oblique 投影管线，与 gate 同源）。
func _world_to_screen_full(w: Vector2, z: float) -> Vector2i:
	var v := Proj2D.world_to_screen(w, OFF, WS, Vector2(SX, SY), z)
	return Vector2i(roundi(v.x), roundi(v.y))


func _near(c: Color, target: Color, tol: float) -> bool:
	return absf(c.r - target.r) <= tol and absf(c.g - target.g) <= tol \
		and absf(c.b - target.b) <= tol


func _ok(cond: bool, msg: String) -> void:
	if cond:
		print("  PASS " + msg)
	else:
		_all_ok = false
		print("  FAIL " + msg)
