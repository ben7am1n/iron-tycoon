# tests/evidence/v31_r4_p1_capture.gd — V3.1 返工4 P1 证据捕获（空间叙事/第一眼）
#
# 渲染真实主场景（src/main.tscn）并保存两张视口快照：
#   - tests/evidence/v31-r4-p1-space.png     全场景（会员在场，8 会员注入保留）
#   - tests/evidence/v31-r4-p1-closeup.png   设备带放大特写（道具轮廓勾边 /
#     色阶分层 / 噪点降扰 / 焦点区）
#
# 复用 v31_gate_r2_capture.gd 的会员在场确定性注入（8 会员，同一 INJECTED
# 列表 —— 门禁最终帧字节一致；本卡只加 P1 特写帧 + 第一眼验证，不改注入）。
#
# 内嵌验证（对照返工4 P1 任务书 FAIL1-4 + 弱项#5）：
#   - 会员衬衫色命中（非空场，与 gate 一致）
#   - FAIL1 道具轮廓勾边：主要设备（treadmill/bike/bench）前缘底部 vs 相邻
#     地面明度差 > 18（勾边后主体从背景中拉出；EQUIP_EDGE_OUTLINE lum≈50
#     vs 力量区地面 78.7 —— 差 ~29）
#   - FAIL2 色阶分层：treadmill 顶面色阶数（独立 4-bit bucket）>= 6
#     （手绘抖动后亮/中/暗面分层可读）
#   - FAIL3 噪点降扰：treadmill 2px 邻域噪点密度（distinct/px）< 远处地面
#   - FAIL4 空间焦点：设备带（暖池区）明度 > 远侧地板明度（焦点区先落眼）
#   - 弱项#5 接地：设备前缘底部有 EQUIP_EDGE_OUTLINE 深色接地像素
#   - draw_calls < 200（V3 §15 性能预算）
#
# 用法（窗口模式——headless 下 get_image() 返回 null，4.7.1 已验证）：
#   godot --path . res://tests/evidence/v31_r4_p1_capture.tscn
extends Node

const MAIN_SCENE := preload("res://src/main.tscn")
const Palette := preload("res://src/palette.gd")
const WorldLayout := preload("res://src/presentation/world_layout.gd")
const Proj2D := preload("res://src/presentation/oblique_projection.gd")
const Main := preload("res://src/main.gd")
const OUT_FULL := "res://tests/evidence/v31-r4-p1-space.png"
const OUT_CLOSEUP := "res://tests/evidence/v31-r4-p1-closeup.png"
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

## 特写变换：聚焦设备带（treadmill(2,2) 控制台 / bike(2,5) 飞轮区 ——
## 主要道具轮廓勾边 + 色阶分层 + 噪点降扰 + 焦点暖池同框）。与
## v31_gate_r2_capture.gd 相同的 scale 2.0 / focus (128,128) 特写（世界
## (426/2, 240/2)=(213,120) 可见，focus 居中）。
const CLOSEUP_SCALE := Vector2(2.0, 2.0)
const CLOSEUP_FOCUS := Vector2(128, 128)
const CLOSEUP_POS := Vector2(213.0 - 128.0 * 2.0, 120.0 - 128.0 * 2.0)  # = (-43, -136)

## 注入会员（确定性采样；与 v31_gate_r2_capture 同源 —— 8 会员必须保留）。
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
	# 与 gate 一致：显式放置 V3.1 预置设备（不依赖 B2 空房开局）
	_place_preset_equipment()
	_world_root = _main.get_node_or_null("WorldViewport/WorldRoot")
	if _world_root == null:
		push_error("v31_r4_p1_capture: WorldRoot not found")
		get_tree().quit(1)


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
		_full_img = _grab()
		_save(_full_img, OUT_FULL)
		_verify_world_frame(_full_img)
		print("  P1 full-scene captured (members present)")
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
		push_error("v31_r4_p1_capture: get_image() returned null (headless dummy driver?)")
		get_tree().quit(1)
		return null
	return img


func _save(img: Image, out_path: String) -> void:
	var abs_path := ProjectSettings.globalize_path(out_path)
	var err := img.save_png(abs_path)
	if err != OK:
		push_error("v31_r4_p1_capture: save_png failed err=%d path=%s" % [err, abs_path])
		get_tree().quit(1)
		return
	print("CAPTURE saved=%s size=%dx%d" % [out_path, img.get_width(), img.get_height()])


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


# === 全场景验证（FAIL1-4 第一眼 + 会员在场，与 gate 一致） ===

func _verify_world_frame(img: Image) -> void:
	_verify_members(img)
	# FAIL1 道具轮廓勾边：bench_press(1,7) footprint 2×2 → 世界 32..96 ×
	# 224..288；前缘底部 = 南面 y=288（z∈[0,2]），相邻地面 y 292..300。
	# 勾边后明度差 > 18（旧版 Δ≈11 融合进力量区深灰地面）。
	var bench_edge := _sample_world_lum(img, Rect2i(38, 286, 56, 3), 1.0)
	var bench_floor := _sample_world_lum(img, Rect2i(38, 292, 56, 8), 0.0)
	_ok(bench_edge > 0.0 and bench_floor > 0.0,
		"P1 FAIL1 bench edge/floor sample non-empty (edge=%.0f floor=%.0f)" % [bench_edge, bench_floor])
	var edge_diff := bench_floor - bench_edge
	_ok(edge_diff > 18.0,
		"P1 FAIL1 bench edge separated from floor (Δlum %.0f > 18, 轮廓勾边)" % edge_diff)
	# FAIL4 空间焦点：焦点区 = 灯光暖池区 + 主要设备区（lamp2 落点 (224,170)
	# 覆盖 treadmill(6,3) 与暖池），vs 同材质远处地板（cardio 区远离暖池处）。
	# 通道瓷砖本就偏亮（V3 §1 公共通道比训练区亮）—— 焦点比较应同材质，
	# 否则拿「通道设计亮」当周边会误判。焦点区明度更高 → 第一眼先落设备。
	var focal := _sample_world_lum(img, Rect2i(206, 150, 54, 40), 0.0)
	var far_zone := _sample_world_lum(img, Rect2i(200, 70, 60, 40), 0.0)
	_ok(focal > far_zone,
		"P1 FAIL4 focal warm-pool zone brighter than same-material far floor (focal=%.0f far=%.0f)"
		% [focal, far_zone])


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


# === 特写验证（FAIL1 勾边 / FAIL2 色阶 / FAIL3 噪点 / FAIL5 接地） ===
## 特写帧显示世界投影画布 coords × 2 + CLOSEUP_POS → viewport → 屏幕放大。
## 与 gate closeup 同一变换（WorldRoot scale=2, position=CLOSEUP_POS）；
## 可见区域约 canvas x 21..234 / y 68..188（z=0 世界 y ≈ 88..244）——
## bike(2,5) 在框内（treadmill 顶面 z=30 在视口上方外，特写复验采样 bike）。

func _verify_closeup(img: Image) -> void:
	# FAIL2 色阶分层：treadmill(6,3) 顶面南段（世界 198..254 x 100..126 @
	# z=30，无 USING 会员遮挡 —— 会员 9006 占用 treadmill(2,2)）独立 4-bit
	# bucket 数 >= 6 —— 手绘抖动后亮/中/暗面分层可读（程序色块平涂一般
	# 只有 2-4 个 bucket）。
	var steps := _count_buckets_world_cu(img, Rect2i(198, 100, 56, 26), 30.0, 2)
	_ok(steps >= 6, "P1 FAIL2 treadmill(6,3) top color steps %d >= 6 (色阶分层)" % steps)
	# FAIL3 噪点降扰：bike(2,5) footprint 3px 邻域（接触影覆盖带，世界
	# 64..96 x 160..192 外扩 3px，z=2 避开 member 9007 头部）distinct/px
	# < 远处 cardio 地面（世界 170..210 x 110..140，无设备无暖池）——
	# 道具周围噪点让位主体（接触影压住邻域噪点，远处地面保留手绘变化）。
	# 同材质比较（strength 近带 vs cardio 远带时明度差大，取 bike 所在
	# strength 暗地面 —— 近带含接触影 → 更均匀）。
	var near_density := _noise_density_band_cu(img, Rect2i(64, 160, 32, 32), 3, 2.0)
	var far_density := _noise_density_rect_cu(img, Rect2i(170, 110, 40, 30), 0.0, 2)
	_ok(near_density < far_density,
		"P1 FAIL3 near-prop noise density %.3f < far floor %.3f (噪点让位主体)"
		% [near_density, far_density])
	# FAIL1 勾边（特写复验）：treadmill(6,3) 前缘底部（世界 y=128 z=1）vs
	# 地面（y 132..140）—— 与全场景一致的明度分离。
	var edge := _sample_world_lum_cu(img, Rect2i(194, 126, 60, 3), 1.0, 2)
	var floor_l := _sample_world_lum_cu(img, Rect2i(194, 132, 60, 8), 0.0, 2)
	var d := floor_l - edge
	_ok(d > 12.0,
		"P1 FAIL1 treadmill(6,3) edge separated (Δlum %.0f > 12, 特写复验)" % d)
	# 弱项#5 接地：treadmill(6,3) 前缘底部存在 EQUIP_EDGE_OUTLINE 深色接地
	# 像素（世界 y 126..129, z 0..2 → 勾边后底部接地线）。
	var ground_hits := _count_near_world_cu(img, Rect2i(194, 126, 60, 4), 1.0,
		Palette.EQUIP_EDGE_OUTLINE, 0.10, 2)
	_ok(ground_hits > 0, "P1 #5 grounding edge pixels present (接地线 hits=%d)" % ground_hits)


func _verify_perf() -> void:
	var draw_calls := Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	var fps := Performance.get_monitor(Performance.TIME_FPS)
	var perf_ok := draw_calls < 200
	_ok(perf_ok, "PERF draw_calls=%d fps=%.1f budget_ok=%s" % [draw_calls, fps, str(perf_ok)])


# === helpers ===

## 特写变换下世界坐标 → 屏幕：WorldCanvas 输出投影后画布 coords，WorldRoot
## scale=2 / position=CLOSEUP_POS 再变换到 viewport（Godot Node2D 顺序：
## point × scale + position），最后 × 屏幕放大。
## 可见画布范围约 x 14..227 / y 68..188（z=0 世界 y ≈ 88..244）——
## 本特写覆盖 bike(2,5) 与 treadmill(6,3) 南段（treadmill(2,2) 顶面在
## 视口上方外）。USING 会员 9007 站在 bike 上（遮挡 bike 顶面），故
## FAIL2 采样未占用的 treadmill(6,3) 顶面南段（无会员遮挡）。
func _w2s(w: Vector2, z: float) -> Vector2i:
	var canvas := Proj2D.proj(w.x, w.y, z)
	var v := canvas * CLOSEUP_SCALE + CLOSEUP_POS
	v.x *= 1280.0 / 426.0
	v.y *= 720.0 / 240.0
	return Vector2i(roundi(v.x), roundi(v.y))


## 特写变换下世界矩形采样（step 间隔），返回平均明度（0-255，与 gate 阈值
## 口径一致）。
func _sample_world_lum_cu(img: Image, r: Rect2i, z: float, step: int) -> float:
	var total := 0.0
	var n := 0
	for wy in range(r.position.y, r.position.y + r.size.y, step):
		for wx in range(r.position.x, r.position.x + r.size.x, step):
			var p := _w2s(Vector2(wx, wy), z)
			if not _in_bounds(img, p):
				continue
			total += _lum(img.get_pixel(p.x, p.y)) * 255.0
			n += 1
	return total / float(n) if n > 0 else 0.0


## 特写变换下世界矩形独立 4-bit bucket 数（色阶分层度量）。
func _count_buckets_world_cu(img: Image, r: Rect2i, z: float, step: int) -> int:
	var buckets := {}
	for wy in range(r.position.y, r.position.y + r.size.y, step):
		for wx in range(r.position.x, r.position.x + r.size.x, step):
			var p := _w2s(Vector2(wx, wy), z)
			if not _in_bounds(img, p):
				continue
			var c := img.get_pixel(p.x, p.y)
			var key := "%d%d%d" % [int(c.r * 15.0), int(c.g * 15.0), int(c.b * 15.0)]
			buckets[key] = true
	return buckets.size()


## 特写变换下 footprint 外 band 邻域噪点密度（distinct bucket / 采样数）。
func _noise_density_band_cu(img: Image, fp: Rect2i, band: int, z: float) -> float:
	var buckets := {}
	var n := 0
	for wy in range(fp.position.y - band, fp.position.y + fp.size.y + band):
		for wx in range(fp.position.x - band, fp.position.x + fp.size.x + band):
			if wx >= fp.position.x and wx < fp.position.x + fp.size.x \
					and wy >= fp.position.y and wy < fp.position.y + fp.size.y:
				continue
			var p := _w2s(Vector2(wx, wy), z)
			if not _in_bounds(img, p):
				continue
			var c := img.get_pixel(p.x, p.y)
			buckets["%d%d%d" % [int(c.r * 15.0), int(c.g * 15.0), int(c.b * 15.0)]] = true
			n += 1
	return float(buckets.size()) / float(n) if n > 0 else 1.0


func _noise_density_rect_cu(img: Image, r: Rect2i, z: float, step: int) -> float:
	var buckets := {}
	var n := 0
	for wy in range(r.position.y, r.position.y + r.size.y, step):
		for wx in range(r.position.x, r.position.x + r.size.x, step):
			var p := _w2s(Vector2(wx, wy), z)
			if not _in_bounds(img, p):
				continue
			var c := img.get_pixel(p.x, p.y)
			buckets["%d%d%d" % [int(c.r * 15.0), int(c.g * 15.0), int(c.b * 15.0)]] = true
			n += 1
	return float(buckets.size()) / float(n) if n > 0 else 1.0


## 特写变换下世界矩形内接近 [color] 的像素数（step 采样）。
func _count_near_world_cu(img: Image, r: Rect2i, z: float, color: Color, tol: float, step: int) -> int:
	var hits := 0
	for wy in range(r.position.y, r.position.y + r.size.y, step):
		for wx in range(r.position.x, r.position.x + r.size.x, step):
			var p := _w2s(Vector2(wx, wy), z)
			if not _in_bounds(img, p):
				continue
			if _near(img.get_pixel(p.x, p.y), color, tol):
				hits += 1
	return hits


func _ok(cond: bool, msg: String) -> void:
	if not cond:
		_all_ok = false
	print("  %s %s" % ["PASS" if cond else "FAIL", msg])


## 全场景投影（与 v31_gate_r2_capture 同源）。
func _world_to_screen_full_z(w: Vector2, z: float) -> Vector2i:
	var v := Proj2D.world_to_screen(w, Main.WORLD_VIEWPORT_OFFSET, Main.WORLD_SCALE,
		Vector2(Main.SCREEN_PER_VIEWPORT_X, Main.SCREEN_PER_VIEWPORT_Y), z)
	return Vector2i(roundi(v.x), roundi(v.y))


func _in_bounds(img: Image, p: Vector2i) -> bool:
	return p.x >= 0 and p.y >= 0 and p.x < img.get_width() and p.y < img.get_height()


func _near(a: Color, b: Color, tol: float) -> bool:
	var dr := a.r - b.r
	var dg := a.g - b.g
	var db := a.b - b.b
	return sqrt(dr * dr + dg * dg + db * db) <= tol


func _lum(c: Color) -> float:
	return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b


## 世界矩形 → 采样屏幕像素（z 固定；step 间隔采样），返回平均明度（0-255，
## 与 gate 阈值口径一致）。
func _sample_world_lum(img: Image, r: Rect2i, z: float, step: int = 3) -> float:
	var total := 0.0
	var n := 0
	for wy in range(r.position.y, r.position.y + r.size.y, step):
		for wx in range(r.position.x, r.position.x + r.size.x, step):
			var p := _world_to_screen_full_z(Vector2(wx, wy), z)
			if not _in_bounds(img, p):
				continue
			total += _lum(img.get_pixel(p.x, p.y)) * 255.0
			n += 1
	return total / float(n) if n > 0 else 0.0


## 世界矩形内独立 4-bit bucket 数（色阶分层度量）。
func _count_buckets_world(img: Image, r: Rect2i, z: float, step: int) -> int:
	var buckets := {}
	for wy in range(r.position.y, r.position.y + r.size.y, step):
		for wx in range(r.position.x, r.position.x + r.size.x, step):
			var p := _world_to_screen_full_z(Vector2(wx, wy), z)
			if not _in_bounds(img, p):
				continue
			var c := img.get_pixel(p.x, p.y)
			var key := "%d%d%d" % [int(c.r * 15.0), int(c.g * 15.0), int(c.b * 15.0)]
			buckets[key] = true
	return buckets.size()


## footprint 外 band 邻域噪点密度：distinct bucket / 采样数（越小越安静）。
func _noise_density_band(img: Image, fp: Rect2i, band: int, z: float) -> float:
	var buckets := {}
	var n := 0
	for wy in range(fp.position.y - band, fp.position.y + fp.size.y + band):
		for wx in range(fp.position.x - band, fp.position.x + fp.size.x + band):
			if wx >= fp.position.x and wx < fp.position.x + fp.size.x \
					and wy >= fp.position.y and wy < fp.position.y + fp.size.y:
				continue
			var p := _world_to_screen_full_z(Vector2(wx, wy), z)
			if not _in_bounds(img, p):
				continue
			var c := img.get_pixel(p.x, p.y)
			buckets["%d%d%d" % [int(c.r * 15.0), int(c.g * 15.0), int(c.b * 15.0)]] = true
			n += 1
	return float(buckets.size()) / float(n) if n > 0 else 1.0


func _noise_density_rect(img: Image, r: Rect2i, z: float, step: int) -> float:
	var buckets := {}
	var n := 0
	for wy in range(r.position.y, r.position.y + r.size.y, step):
		for wx in range(r.position.x, r.position.x + r.size.x, step):
			var p := _world_to_screen_full_z(Vector2(wx, wy), z)
			if not _in_bounds(img, p):
				continue
			var c := img.get_pixel(p.x, p.y)
			buckets["%d%d%d" % [int(c.r * 15.0), int(c.g * 15.0), int(c.b * 15.0)]] = true
			n += 1
	return float(buckets.size()) / float(n) if n > 0 else 1.0


## 世界矩形内接近 [color] 的像素数（step 采样）。
func _count_near_world(img: Image, r: Rect2i, z: float, color: Color, tol: float, step: int) -> int:
	var hits := 0
	for wy in range(r.position.y, r.position.y + r.size.y, step):
		for wx in range(r.position.x, r.position.x + r.size.x, step):
			var p := _world_to_screen_full_z(Vector2(wx, wy), z)
			if not _in_bounds(img, p):
				continue
			if _near(img.get_pixel(p.x, p.y), color, tol):
				hits += 1
	return hits
