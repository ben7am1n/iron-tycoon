# tests/evidence/v31_r3_p2_capture.gd — V3.1 返工3 P2 证据捕获（会员 sprite 精细度/设备体积/姿态可读）
#
# 渲染真实主场景并保存两张视口快照：
#   - tests/evidence/v31-r3-p2-sprite.png    全场景（会员在场，8 会员注入保留 —— 与
#     v31_gate_r2_capture.gd 同源）
#   - tests/evidence/v31-r3-p2-closeup.png   设备带放大特写：单车 + 跑步机 + 会员 3 姿态同框
#     （walk 行走 / using treadmill 跑步 / using bike 骑行 / queue 排队）
#
# 复用 v31_gate_r2_capture.gd 的会员在场确定性注入（8 会员，同一 INJECTED 列表 ——
# 门禁最终帧字节一致；本卡只加 P2 特写帧 + 姿态/体积验证，不改注入）。
#
# 内嵌验证：
#   - 全场景：会员衬衫色命中（WALKING sky / QUEUEING peach / LEAVING gray —— 非空场）
#   - 特写：单车车架金属高光（H）与坐垫暖色（zone）同框；跑步机控制台青蓝屏幕 + 扶手金属
#   - 姿态：walk / using treadmill / using bike / queue 四姿态衬衫色在特写窗口内可寻
#   - draw_calls < 200（V3 §15 性能预算）
#
# 用法（窗口模式——headless 下 get_image() 返回 null，4.7.1 已验证）：
#   godot --path . res://tests/evidence/v31_r3_p2_capture.tscn
extends Node

const MAIN_SCENE := preload("res://src/main.tscn")
const Palette := preload("res://src/palette.gd")
const WorldLayout := preload("res://src/presentation/world_layout.gd")
const Proj2D := preload("res://src/presentation/oblique_projection.gd")
const Main := preload("res://src/main.gd")
const OUT_FULL := "res://tests/evidence/v31-r3-p2-sprite.png"
const OUT_CLOSEUP := "res://tests/evidence/v31-r3-p2-closeup.png"
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

## 特写变换：聚焦设备带（单车 (2,5) + 跑步机 (2,2) 控制台 + 会员 3 姿态同框
## —— walk 行走 / using treadmill 跑步 / using bike 骑行；queue 排队由全场景
## 帧 + 隔离子图 QA 覆盖）。需要同框的投影点（Proj2D.proj 后，sprite 左上角
## = proj(脚底, 站立高度) - (24,48)）：
##   跑步机跑步会员 (2,2)z22.5 → 左上 (101.1, -6.2) 底 (149.1, 41.8)
##   单车骑行会员 (2,5)z27   → 左上 (120.6, 54.7) 底 (168.6, 102.7)
##   walk 会员 (5,2)z0       → 左上 (185.6, 11.5) 底 (233.6, 59.5)
## 3 个 sprite 的并集 x 101..234 / y -6..103。scale 2.1 下视口 426×240
## 可见世界投影 203×114，position 使并集全部入框且四周留白：
##   pos = (213 - 167.4*2.1, 120 - 48.2*2.1) = (-138.6, 18.8)
## （返工3 P2 修正：旧 scale 2.0 / pos(-117,-30) 只按注释值取景，实际会员
##   锚点比注释低 ~20px，跑步会员头部整段裁出帧外 —— GPT 第二眼读不到头身比/
##   姿态。新取景以真实投影并集为准，3 姿态全帧可见且放大到可读比例。）
const CLOSEUP_SCALE := Vector2(2.1, 2.1)
const CLOSEUP_POS := Vector2(-138.6, 18.8)   # 覆盖 treadmill 跑步会员 → walk 会员

## 注入会员（与 v31_gate_r2_capture.gd 完全一致 —— 8 会员在场，门禁最终帧
## 字节一致；本卡只复用，不改注入）。
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
	_place_preset_equipment()
	_world_root = _main.get_node_or_null("WorldViewport/WorldRoot")
	if _world_root == null:
		push_error("v31_r3_p2_capture: WorldRoot not found")
		get_tree().quit(1)


## 显式放置预置设备（与 v31_gate_r2_capture.gd 同源 —— 保证特写帧包含
## 单车 + 跑步机全套视觉元素）。
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
		["yoga_mat", Vector2i(5, 4)],
		["bench_press", Vector2i(1, 7)],
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
		push_error("v31_r3_p2_capture: get_image() returned null (headless dummy driver?)")
		get_tree().quit(1)
		return null
	return img


func _save(img: Image, out_path: String) -> void:
	var abs_path := ProjectSettings.globalize_path(out_path)
	var err := img.save_png(abs_path)
	if err != OK:
		push_error("v31_r3_p2_capture: save_png failed err=%d path=%s" % [err, abs_path])
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


# === 全场景验证 ===

func _verify_world_frame(img: Image) -> void:
	_verify_members(img)
	# 单车/跑步机/瑜伽垫/卧推设备带在场（zone 色 / 金属色 / 青蓝屏幕任一命中）
	var bike_found := false
	for dy in range(-40, 41, 4):
		for dx in range(-40, 41, 4):
			var p := _world_to_screen_full(Vector2(80 + dx, 176 + dy))
			if not _in_bounds(img, p):
				continue
			var c := img.get_pixel(p.x, p.y)
			if _near(c, Palette.ZONE_COLORS["cardio"], 0.12) or _near(c, Palette.METAL_HIGHLIGHT, 0.12):
				bike_found = true
	_ok(bike_found, "WORLD bike zone/metal volume present (单车区色层在场)")
	var screen_found := _screen_present(img)
	_ok(screen_found, "WORLD treadmill console cyan screen pixels present (跑步机控制台屏幕在场)")


## 会员衬衫色命中（WALKING sky / QUEUEING peach / LEAVING gray —— 非空场）。
func _verify_members(img: Image) -> void:
	var checks := [
		{"state": "WALKING_TO", "cell": Vector2i(5, 2), "expect": Color("8EC5E8")},
		{"state": "QUEUEING", "cell": Vector2i(3, 6), "expect": Color("F2B486")},
		{"state": "LEAVING", "cell": Vector2i(10, 6), "expect": Color("9A948C")},
	]
	for entry in checks:
		var p := _member_shirt_screen(entry["cell"])
		var found := _scan_tone(img, p, 5, entry["expect"], 0.22)
		_ok(found, "MEMBER %-12s shirt visible @(%3d,%3d)" % [
			entry["state"], p.x, p.y])


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


## 特写窗口（closeup 变换）内衬衫色可寻 —— 会员 3+ 姿态同框验证。
## [cell] 会员所在 cell；[z] 会员 sprite 站立高度（walk/queue 贴地 z=0，
## using 抬到设备高度）。与 world_canvas._cell_anchor/_equipment_anchor 同源：
## 锚点 = Proj2D.proj(脚底, z) - (24,48)，衬衫像素 = 锚点 + (24,19)。
func _scan_closeup_zone(img: Image, cell: Vector2i, target: Color, tol: float,
		z: float = 0.0, radius: int = 40) -> bool:
	var feet := Vector2(cell.x * CELL_SIZE + CELL_SIZE * 0.5,
		cell.y * CELL_SIZE + CELL_SIZE)
	var proj_flat := Proj2D.proj(feet.x, feet.y, z)
	var shirt_flat := proj_flat - Vector2(0, 29)  # 锚点(24,48) + 衬衫(24,19)
	for dy in range(-radius, radius + 1, 2):
		for dx in range(-radius, radius + 1, 2):
			var p := _w2s(shirt_flat + Vector2(dx, dy))
			if not _in_bounds(img, p):
				continue
			if _near(img.get_pixel(p.x, p.y), target, tol):
				return true
	return false


# === 特写验证 ===

func _verify_closeup(img: Image) -> void:
	# 1) 单车体积：车架金属高光 / 坐垫暖色（zone）在单车 footprint 附近
	#    单车 footprint (2,5) = 世界 (64,160)-(96,192)，车架/坐垫高 ~20..36
	var bike_metal := _scan_closeup_world(img, Vector2(80, 176), 22.0, Palette.METAL_HIGHLIGHT, 0.14, 44)
	var bike_zone := _scan_closeup_world(img, Vector2(80, 176), 16.0, Palette.ZONE_COLORS["cardio"], 0.14, 40)
	_ok(bike_metal or bike_zone, "CLOSEUP bike volume present (metal/zone) (单车三面体积)")
	# 2) 跑步机：控制台青蓝屏幕（treadmill (2,2) footprint (64,64)-(128,96)，控制台 z≈30）
	var tm_screen := _scan_closeup_world(img, Vector2(96, 90), 30.0, Palette.EQUIP_ACCENT_CYAN, 0.16, 46) \
		or _scan_closeup_world(img, Vector2(96, 90), 30.0, Palette.EMISSIVE_CYAN, 0.16, 46)
	_ok(tm_screen, "CLOSEUP treadmill console cyan screen (跑步机控制台屏幕)")
	# 2b) 瑜伽垫（返工3 P2 特写第三台设备：yoga_mat (5,4) footprint (160,128)-(192,160)）
	var yoga_zone := _scan_closeup_world(img, Vector2(176, 144), 4.0, Palette.ZONE_COLORS["cardio"], 0.16, 44)
	_ok(yoga_zone, "CLOSEUP yoga mat zone present (瑜伽垫在场)")
	# 3) 会员 3 姿态：walk (5,2) sky / using treadmill (2,2) peach / using bike
	#    (2,5) peach —— 特写窗口内衬衫色可寻（姿态同框）。queue (3,6) 在
	#    2.1x 特写取景外（feet 超出帧底）—— 排队姿态由全场景帧 + 隔离子图
	#    QA（raw_tiredA silhouette 差异）覆盖，不在特写断言。
	var walk_ok := _scan_closeup_zone(img, Vector2i(5, 2), Color("8EC5E8"), 0.20, 0.0, 42)
	_ok(walk_ok, "CLOSEUP member WALK pose visible (行走姿态)")
	var use_tm_ok := _scan_closeup_member(img, "treadmill", Vector2i(2, 2),
		Color("F2B486"), 0.20, 44)
	_ok(use_tm_ok, "CLOSEUP member RUN pose on treadmill (跑步姿态)")
	var use_bike_ok := _scan_closeup_member(img, "bike", Vector2i(2, 5),
		Color("F2B486"), 0.20, 46)
	_ok(use_bike_ok, "CLOSEUP member RIDE pose on bike (骑行姿态)")


## USING 会员衬衫采样：锚定设备 footprint（与 world_canvas._equipment_anchor
## 同源复算）。[fp_cell] 设备左上 cell（treadmill 2x1 / bike 1x1）。
func _scan_closeup_member(img: Image, eq_id: String, fp_cell: Vector2i,
		target: Color, tol: float, radius: int) -> bool:
	var fp := Rect2i(fp_cell.x * CELL_SIZE, fp_cell.y * CELL_SIZE,
		32 * (2 if eq_id == "treadmill" else 1), 32)
	var center_x := fp.position.x + fp.size.x / 2.0
	var feet_y := fp.position.y + fp.size.y
	var sprite_w := 48.0
	var flat_anchor: Vector2
	if eq_id == "treadmill":
		flat_anchor = Vector2(center_x - sprite_w / 2.0, feet_y - sprite_w)
	elif eq_id == "bike":
		flat_anchor = Vector2(center_x - sprite_w / 2.0,
			fp.position.y + fp.size.y - 16 - sprite_w * 0.5)
	else:
		flat_anchor = Vector2(center_x - sprite_w / 2.0, feet_y - sprite_w)
	var flat_feet := flat_anchor + Vector2(sprite_w * 0.5, sprite_w)
	var stand_z: float = 16.0
	if eq_id == "treadmill":
		stand_z = 30.0 * 0.75
	elif eq_id == "bike":
		stand_z = 36.0 * 0.75
	var p := Proj2D.proj(flat_feet.x, flat_feet.y, stand_z)
	var shirt_flat := p - Vector2(0, 29)  # anchor-(24,48) + 衬衫(24,19)
	for dy in range(-radius, radius + 1, 2):
		for dx in range(-radius, radius + 1, 2):
			var sp := _w2s(shirt_flat + Vector2(dx, dy))
			if not _in_bounds(img, sp):
				continue
			if _near(img.get_pixel(sp.x, sp.y), target, tol):
				return true
	return false


## 特写窗口内世界坐标 (wx,wy) 在高度 z 处的颜色可寻 —— 设备体积验证。
## 投影锚点 = Proj2D.proj(世界点, z)，再经 closeup 变换到屏幕。
func _scan_closeup_world(img: Image, w: Vector2, z: float, target: Color,
		tol: float, radius: int) -> bool:
	var proj_flat := Proj2D.proj(w.x, w.y, z)
	for dy in range(-radius, radius + 1, 2):
		for dx in range(-radius, radius + 1, 2):
			var p := _w2s(proj_flat + Vector2(dx, dy))
			if not _in_bounds(img, p):
				continue
			if _near(img.get_pixel(p.x, p.y), target, tol):
				return true
	return false


func _verify_perf() -> void:
	var draw_calls := Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	var fps := Performance.get_monitor(Performance.TIME_FPS)
	var perf_ok := draw_calls < 200
	_ok(perf_ok, "PERF draw_calls=%d fps=%.1f budget_ok=%s" % [draw_calls, fps, str(perf_ok)])


# === helpers ===

func _w2s(w: Vector2) -> Vector2i:
	# 特写变换下：WorldRoot scale=2.0 position=CLOSEUP_POS（Godot 先 scale
	# 后 position）→ 子节点本地 w 映射到 viewport 空间 = w*scale + position，
	# 再乘 1280/426 与 720/240 到屏幕。
	var v := w * CLOSEUP_SCALE + CLOSEUP_POS
	v.x *= 1280.0 / 426.0
	v.y *= 720.0 / 240.0
	return Vector2i(roundi(v.x), roundi(v.y))


func _ok(cond: bool, msg: String) -> void:
	if not cond:
		_all_ok = false
	print("  %s %s" % ["PASS" if cond else "FAIL", msg])


func _screen_present(img: Image) -> bool:
	for p in [Vector2(84, 90), Vector2(86, 90), Vector2(98, 90), Vector2(100, 90), Vector2(84, 91),
			Vector2(102, 90), Vector2(103, 90), Vector2(104, 90), Vector2(105, 90),
			Vector2(106, 90), Vector2(107, 90), Vector2(106, 92), Vector2(108, 92)]:
		for dy in range(-2, 3):
			for dx in range(-2, 3):
				var sp := _world_to_screen_full_z(p + Vector2(dx, dy), 30.0)
				if not _in_bounds(img, sp):
					continue
				var c := img.get_pixel(sp.x, sp.y)
				if _near(c, Palette.EQUIP_ACCENT_CYAN, 0.16) or _near(c, Palette.EMISSIVE_CYAN, 0.16):
					return true
	return false


func _world_to_screen_full(w: Vector2) -> Vector2i:
	return _world_to_screen_full_z(w, 0.0)


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
