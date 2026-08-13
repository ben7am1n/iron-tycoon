# tests/evidence/v31_r7_p4_capture.gd — V3.1 返工7 P4（HUD/UI 矩形破形：
# 顶部状态栏/底部商品栏/目标框等宽描边与完美矩形轮廓 → 手绘抖动/缺口/
# 错落/像素化硬边）证据捕获
#
# 渲染真实主场景（src/main.tscn，8 会员注入保留 —— 与 v31_gate_r2_capture.gd
# 同一 INJECTED 列表，门禁判定帧字节一致），并保存：
#   - tests/evidence/v31-r7-p4-space.png   全场景帧（会员在场）
#   - tests/evidence/v31-r7-p4-hud-top.png 顶部状态栏特写（y 0..90）
#     （挂牌撕裂 + 顶缘 cornice —— 无全宽平墙带/无等宽描边）
#   - tests/evidence/v31-r7-p4-goal.png    目标框特写（x 880..1280, y 50..190）
#     （撕裂强度 2.6 —— 大面板轮廓参差，绝不读作规则矩形）
#   - tests/evidence/v31-r7-p4-bottom.png  底部商品栏特写（y 560..720）
#     （展示架段错落 ±5px + 架条上方交界破形带延伸 —— 无笔直横栏）
#
# 内嵌验证（对照本卡 FAIL 清单 + 已通过项防回归）：
#   - 会员在场：衬衫色命中（非空场）
#   - N1 防回归：世界区无 200px+ 完美直线（水平+垂直）
#   - 顶缘破形：顶部 y0..16 无长墙色 run（< 120px —— 全宽平墙带已打散）
#   - 底部破形：y 700..718 无长墙色 run（< 120px —— 架条上方平墙带已打散）
#   - draw_calls < 200（V3 §15 性能预算）
#
# 用法（窗口模式——headless 下 get_image() 返回 null，4.7.1 已验证）：
#   godot --path . res://tests/evidence/v31_r7_p4_capture.tscn
extends Node

const MAIN_SCENE := preload("res://src/main.tscn")
const Palette := preload("res://src/palette.gd")
const WorldLayout := preload("res://src/presentation/world_layout.gd")
const Proj2D := preload("res://src/presentation/oblique_projection.gd")
const Main := preload("res://src/main.gd")
const OUT_SPACE := "res://tests/evidence/v31-r7-p4-space.png"
const OUT_HUD_TOP := "res://tests/evidence/v31-r7-p4-hud-top.png"
const OUT_GOAL := "res://tests/evidence/v31-r7-p4-goal.png"
const OUT_BOTTOM := "res://tests/evidence/v31-r7-p4-bottom.png"
const REDRAW_FRAME := 6       # 全场景抓帧前强制世界画布重绘（纹理滞后 ≥1 帧）
const INJECT_FRAME := 8       # 注入会员 + 强制重绘
const CAPTURE_FRAME := 12
const CELL_SIZE := 32

## 管线常量（来自 main.gd —— 证据复算与实现同源）。
const SX := Main.SCREEN_PER_VIEWPORT_X
const SY := Main.SCREEN_PER_VIEWPORT_Y
const OFF := Main.WORLD_VIEWPORT_OFFSET
const WS := Main.WORLD_SCALE

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
		push_error("v31_r7_p4_capture: WorldRoot not found")
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
		_full_img = _grab()
		_save(_full_img, OUT_SPACE)
		# 调试（返工7 P4 第二轮 QA E 回归）：打印 palette 实际尺寸/位置 ——
		# tile 内容栈高度是否撑破 88px（HBox 增高 → 架条/trim 锚定回退）。
		var pal := _main.get_node_or_null("UICanvas/BuildShopPalette")
		if pal != null:
			print("[r7-p4] palette size=", pal.size, " pos=", pal.position)
		_save_region(_full_img, OUT_HUD_TOP, Rect2i(0, 0, 1280, 90))
		_save_region(_full_img, OUT_GOAL, Rect2i(880, 50, 400, 140))
		_save_region(_full_img, OUT_BOTTOM, Rect2i(0, 560, 1280, 160))
		_verify_world_frame(_full_img)
		_verify_top_band(_full_img)
		_verify_bottom_band(_full_img)
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
		push_error("v31_r7_p4_capture: get_image() returned null (headless dummy driver?)")
		get_tree().quit(1)
		return null
	return img


func _save(img: Image, out_path: String) -> void:
	var abs_path := ProjectSettings.globalize_path(out_path)
	var err := img.save_png(abs_path)
	if err != OK:
		push_error("v31_r7_p4_capture: save_png failed err=%d path=%s" % [err, abs_path])
		get_tree().quit(1)
		return
	print("CAPTURE saved=%s size=%dx%d" % [out_path, img.get_width(), img.get_height()])


## 保存视口帧的局部裁剪（HUD 特写 —— HUD 是屏幕空间 UI，直接裁剪全帧）。
func _save_region(img: Image, out_path: String, region: Rect2i) -> void:
	var crop := img.get_region(region)
	_save(crop, out_path)


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


# === 渲染帧级验证 ===

func _verify_world_frame(img: Image) -> void:
	_verify_members(img)
	var longest_h := _longest_horizontal_run(img, 80, 600)
	_ok(longest_h < 200, "N1 no 200px+ perfect horizontal line (longest %dpx < 200)" % longest_h)
	var longest_v := _longest_vertical_run(img)
	_ok(longest_v < 200, "N1 no 200px+ perfect vertical line (longest %dpx < 200)" % longest_v)


## 顶缘破形（本卡 FAIL：顶部状态栏上方全宽平墙带）：y0..16 最长同色 run
## < 120px（旧帧 1132px 全宽平墙带 —— cornice 短段错落后应远小于 120）。
func _verify_top_band(img: Image) -> void:
	var longest := 0
	for y in range(0, mini(16, img.get_height())):
		var run := 1
		for x in range(1, img.get_width()):
			if _near(img.get_pixel(x, y), img.get_pixel(x - 1, y), 6.0 / 255.0):
				run += 1
			else:
				longest = maxi(longest, run)
				run = 1
		longest = maxi(longest, run)
	_ok(longest < 120, "P4 top band de-formed (longest run %dpx < 120 in y0..16)" % longest)


## 底部破形（本卡 FAIL：架条上方全宽平墙带）：y700..718 最长同色 run
## < 120px（旧帧 1280px 全宽平墙带 —— 交界破形带延伸后应远小于 120）。
func _verify_bottom_band(img: Image) -> void:
	var longest := 0
	for y in range(700, mini(718, img.get_height())):
		var run := 1
		for x in range(1, img.get_width()):
			if _near(img.get_pixel(x, y), img.get_pixel(x - 1, y), 6.0 / 255.0):
				run += 1
			else:
				longest = maxi(longest, run)
				run = 1
		longest = maxi(longest, run)
	_ok(longest < 120, "P4 bottom band de-formed (longest run %dpx < 120 in y700..718)" % longest)


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


func _verify_perf() -> void:
	var draw_calls := Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	var fps := Performance.get_monitor(Performance.TIME_FPS)
	var perf_ok := draw_calls < 200
	_ok(perf_ok, "PERF draw_calls=%d fps=%.1f budget_ok=%s" % [draw_calls, fps, str(perf_ok)])


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
