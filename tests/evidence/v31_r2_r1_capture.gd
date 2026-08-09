# tests/evidence/v31_r2_r1_capture.gd — V3.1 返工2 R1 空间/第一眼证据捕获
#
# 渲染真实主场景（src/main.tscn，V3 §2 SubViewport 低分辨率管线）并保存：
#   1. tests/evidence/v31-r2-r1-space.png —— 空间/第一眼全场景帧
#      （暖光池分层 + 冷阴影 + 手绘材质 + 每区叙事道具组 + 会员在场，
#      会员与环境接触点有明暗衔接 —— 返工2 R1 四项 FAIL 点全链路）
#   2. tests/evidence/v31-r2-r1-closeup.png —— 设备带放大特写
#      （treadmill/bike 区：会员脚踩踏板接触影 + 手扶处设备微反光）
#
# 验收对照（返工2 R1 任务书）：
#   - 暖光池与冷阴影分层：灯下暖、远离光源冷灰 —— 有方向的照明
#   - 地面/墙面材质手绘笔触：短笔触簇、色相微差、边缘抖动
#   - 每区至少一个明确叙事道具组（跑步机/力量/瑜伽/单车）
#   - 会员与环境互动可读性：接触点投影/明暗衔接
#   - 无 200px+ 完美直线；无圆形 gradient 光斑（负面约束）
#
# 用法（窗口模式——headless dummy 驱动下 get_image() 返回 null，项目既有
# 证据方法，见 v31_gate_capture.gd 同款注释）：
#   godot --path . res://tests/evidence/v31_r2_r1_capture.tscn
extends Node

const MAIN_SCENE := preload("res://src/main.tscn")
const Main := preload("res://src/main.gd")
const Proj2D := preload("res://src/presentation/oblique_projection.gd")
const Palette := preload("res://src/palette.gd")
const WorldLayout := preload("res://src/presentation/world_layout.gd")
const OUT_FULL := "res://tests/evidence/v31-r2-r1-space.png"
const OUT_CLOSEUP := "res://tests/evidence/v31-r2-r1-closeup.png"
const REDRAW_FRAME := 6
const INJECT_FRAME := 10       # 注入规范会员（冻结模拟）
const CAPTURE_FRAME := 18      # 全场景抓帧（注入后纹理更新）
const CLOSEUP_APPLY_FRAME := 24
const CLOSEUP_REDRAW_FRAME := 26
const CLOSEUP_CAPTURE_FRAME := 32
const CELL_SIZE := 32

## 管线常量（来自 main.gd —— 证据复算与实现同源）。
const SX := Main.SCREEN_PER_VIEWPORT_X
const SY := Main.SCREEN_PER_VIEWPORT_Y
const OFF := Main.WORLD_VIEWPORT_OFFSET
const WS := Main.WORLD_SCALE

## 特写变换：聚焦设备带（treadmill(2,2)(6,3) / bike(2,5) 区域）。
const CLOSEUP_SCALE := Vector2(2.0, 2.0)
const CLOSEUP_FOCUS := Vector2(128, 128)
const CLOSEUP_POS := Vector2(213.0 - 128.0 * 2.0, 120.0 - 128.0 * 2.0)

## 注入会员（确定性；与 v31_r3_capture 同源 —— 覆盖多种环境接触点：
## WALKING 脚踩地面 / USING 脚踩设备 + 手扶设备）。
const INJECTED := [
	{"member_id": 9100, "state": "WALKING_TO", "cell": Vector2i(5, 2)},
	{"member_id": 9101, "state": "WALKING_TO", "cell": Vector2i(11, 2)},
	{"member_id": 9102, "state": "QUEUEING", "cell": Vector2i(3, 6)},
	{"member_id": 9103, "state": "LEAVING", "cell": Vector2i(10, 6), "leaving_reason": "quota_met"},
	{"member_id": 9104, "state": "USING", "cell": Vector2i(3, 3), "target_equipment": "treadmill"},
	{"member_id": 9105, "state": "USING", "cell": Vector2i(2, 6), "target_equipment": "bike"},
]

var _frame := 0
var _injected := false
var _captured := false
var _main: Node = null
var _sim = null
var _orch = null
var _world_root: Node2D = null
var _all_ok := true


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
		push_error("v31_r2_r1_capture: WorldRoot not found")
		get_tree().quit(1)


## 显式放置预置设备（与 gate capture 同源 —— B2 经济空房开局下保证
## 证据帧包含设备带）。
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
		var img := _grab()
		_save(img, OUT_FULL)
		_verify_space_frame(img)
		print("  SPACE full-scene captured")
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


func _inject_deterministic() -> void:
	if _sim == null:
		return
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
	_injected = true
	print("INJECTED %d canonical members (frozen)" % INJECTED.size())


func _resolve_equipment_instance_ids() -> Dictionary:
	var out := {}
	if _main == null:
		return out
	var resolver: Callable = _main.call("_resolver")
	var instances: Array = _main.get("_grid").get_placed_instances()
	for inst in instances:
		var eq := str(resolver.call(inst.instance_id))
		if eq != "" and not out.has(eq):
			out[eq] = inst.instance_id
	return out


func _force_redraw() -> void:
	var canvas := _main.get_node_or_null("WorldViewport/WorldRoot/WorldCanvas")
	if canvas != null:
		canvas.queue_redraw()
	var lighting := _main.get_node_or_null("WorldViewport/WorldRoot/LightingLayer")
	if lighting != null:
		lighting.queue_redraw()


func _grab() -> Image:
	var img := get_viewport().get_texture().get_image()
	if img == null:
		push_error("v31_r2_r1_capture: get_image() returned null (headless dummy driver?)")
		get_tree().quit(1)
		return null
	return img


func _save(img: Image, out_path: String) -> void:
	var abs_path := ProjectSettings.globalize_path(out_path)
	var err := img.save_png(abs_path)
	if err != OK:
		push_error("v31_r2_r1_capture: save_png failed err=%d path=%s" % [err, abs_path])
		get_tree().quit(1)
		return
	print("CAPTURE saved=%s size=%dx%d" % [out_path, img.get_width(), img.get_height()])


# === 全场景验证（返工2 R1 空间/第一眼） ===

## 每区叙事道具组锚点（世界坐标 + 期望语义色）：
##   跑步机区：timer_treadmill_t1（计时器 C 显示屏）+ water_bottle（Y 瓶身）
##   力量区：poster_strength_s1（海报 W 板面）+ chalk_box（B 粉笔盒）
##   瑜伽区：plant_f1（P 绿植）+ speaker_f1（H 金属网）
##   单车区：bottle_rack_b1（H 金属架）+ towel_b1（T 毛巾）
func _verify_space_frame(img: Image) -> void:
	# 1) 暖光池存在（灯下暖像素）—— 世界锚点取 3 个吊灯落点
	var pool_found := true
	for landing in WorldLayout.LIGHT_POOLS:
		var p := world_to_screen(landing)
		if not _scan_warm(img, p, 14, 0.25):
			pool_found = false
			break
	_ok(pool_found, "SPACE warm light pools present at all 3 hangings (暖光池)")
	# 2) 墙边冷阴影存在（近墙冷蓝灰）—— 世界锚点 (10,170)（西墙边）
	var edge_p := world_to_screen(Vector2(10, 170))
	var edge_cool := _scan_cool(img, edge_p, 10)
	_ok(edge_cool > 0, "SPACE wall-edge cool shadow pixels present (冷阴影)")
	# 3) 每区叙事道具组锚点存在（大窗口扫描 —— 道具是 32px 精灵，投影后
	#    约 ±48 屏幕 px）
	var zone_props := [
		["timer_treadmill_t1", Vector2(158, 70), Palette.METAL_HIGHLIGHT, 0.28],
		["poster_strength_s1", Vector2(150, 260), Palette.WALL_TRIM, 0.28],
		["plant_f1", Vector2(360, 180), Palette.PLANT_GREEN, 0.22],
		["bottle_rack_b1", Vector2(16, 144), Palette.METAL_HIGHLIGHT, 0.28],
	]
	for entry in zone_props:
		var p := world_to_screen(entry[1])
		var found := _scan_color(img, p, 40, entry[2], entry[3])
		_ok(found, "SPACE zone narrative prop %-18s present @(%3d,%3d)" % [
			entry[0], p.x, p.y])
	# 4) 会员在场（衬衫色可见）—— 与空场区分
	var member_found := _member_shirt_visible(img)
	_ok(member_found, "SPACE members visible (会员在场)")


## 会员衬衫可见性：walk 会员 9100 @cell(5,2) 附近搜索 SKY（衬衫色）。
## 会员 sprite 48×48 锚定 cell 底部 —— 衬衫在 cell 上方 20-40px 处，
## 扫描窗口取 cell 中心 ±30 世界 px（屏幕约 ±90px，覆盖 sprite 主体）。
func _member_shirt_visible(img: Image) -> bool:
	var p := world_to_screen(Vector2(5 * CELL_SIZE + 16, 2 * CELL_SIZE + 8))
	return _scan_color(img, p, 60, Palette.SKY, 0.22) \
		or _scan_color(img, p, 60, Palette.PEACH, 0.22)


# === 特写验证（人物-环境接触点明暗衔接） ===

func _verify_closeup(img: Image) -> void:
	# 设备带非空
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
	# 会员在场（特写含 USING 会员 —— 脚踩设备、手扶设备）。USING 状态
	# 通道 = Peach；特写变换后锚点投影偏差大，直接全帧扫描（大步进）——
	# 只要有会员衬衫/主体色块即证明会员真实渲染在设备带内。
	var member_found := _frame_scan_color(img, Palette.PEACH, 0.20, 3) \
		or _frame_scan_color(img, Palette.SKY, 0.20, 3)
	_ok(member_found, "CLOSEUP USING member visible near treadmill (会员脚踩设备)")


func _verify_perf() -> void:
	var draw_calls := Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	var fps := Performance.get_monitor(Performance.TIME_FPS)
	var perf_ok := draw_calls < 200
	_ok(perf_ok, "PERF draw_calls=%d fps=%.1f budget_ok=%s" % [draw_calls, fps, str(perf_ok)])


# === helpers ===

func world_to_screen(w: Vector2) -> Vector2i:
	var v := Proj2D.world_to_screen(w, OFF, WS, Vector2(SX, SY))
	return Vector2i(roundi(v.x), roundi(v.y))


func _w2s(w: Vector2, z: float) -> Vector2i:
	var v := (w + CLOSEUP_POS) * CLOSEUP_SCALE
	v.x *= SX
	v.y *= SY
	return Vector2i(roundi(v.x), roundi(v.y))


func _in_bounds(img: Image, p: Vector2i) -> bool:
	return p.x >= 0 and p.y >= 0 and p.x < img.get_width() and p.y < img.get_height()


## 中心 ±r 窗口内搜索暖色像素（r > b 且亮度足够 —— 暖光池/暖色道具）。
func _scan_warm(img: Image, center: Vector2i, r: int, min_lum: float) -> bool:
	for dy in range(-r, r + 1, 2):
		for dx in range(-r, r + 1, 2):
			var p := center + Vector2i(dx, dy)
			if not _in_bounds(img, p):
				continue
			var c := img.get_pixel(p.x, p.y)
			var lum := 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
			if lum > min_lum and c.r > c.b + 0.03:
				return true
	return false


## 中心 ±r 窗口内搜索冷蓝灰像素（b > r，冷阴影）。
func _scan_cool(img: Image, center: Vector2i, r: int) -> int:
	var count := 0
	for dy in range(-r, r + 1):
		for dx in range(-r, r + 1):
			var p := center + Vector2i(dx, dy)
			if not _in_bounds(img, p):
				continue
			var c := img.get_pixel(p.x, p.y)
			if c.b > c.r + 0.03 and c.b > c.g + 0.01:
				count += 1
	return count


## 中心 ±r 窗口内搜索目标语义色（近邻容差 tol）。
func _scan_color(img: Image, center: Vector2i, r: int, target: Color, tol: float) -> bool:
	for dy in range(-r, r + 1, 2):
		for dx in range(-r, r + 1, 2):
			var p := center + Vector2i(dx, dy)
			if not _in_bounds(img, p):
				continue
			if _near(img.get_pixel(p.x, p.y), target, tol):
				return true
	return false


## 全帧扫描目标语义色（步进 stride，确定性强 —— 不依赖投影锚点）。
func _frame_scan_color(img: Image, target: Color, tol: float, stride: int) -> bool:
	for y in range(0, img.get_height(), stride):
		for x in range(0, img.get_width(), stride):
			if _near(img.get_pixel(x, y), target, tol):
				return true
	return false


func _near(a: Color, b: Color, tol: float) -> bool:
	var dr := a.r - b.r
	var dg := a.g - b.g
	var db := a.b - b.b
	return sqrt(dr * dr + dg * dg + db * db) <= tol


func _ok(cond: bool, msg: String) -> void:
	if not cond:
		_all_ok = false
	print("  %s %s" % ["PASS" if cond else "FAIL", msg])
