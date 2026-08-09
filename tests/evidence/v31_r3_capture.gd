# tests/evidence/v31_r3_capture.gd — V3.1 R3 密度/环境叙事/活跃度 + 墙地交界抖动证据
#
# 渲染真实主场景（src/main.tscn，含 V3 §2 SubViewport 低分辨率管线）并保存：
#   1. tests/evidence/v31-r3-density.png —— 密度帧（叙事道具 + 墙地交界抖动；
#      空场版本 —— 证据聚焦环境：水瓶/毛巾/杠铃架/暖色灯/植物等 §12 叙事
#      道具 + 墙帽/踢脚线多色 cluster 抖动，无 200px+ 直线）
#   2. tests/evidence/v31-r3-populated.png —— populated 变体（确定性注入 8 个
#      会员：walk/queue/leave/using 活动姿态；会员在场景中可见 —— 与
#      density 帧字节不同，证明会员真实渲染进场景，非静态空场）
#
# 验收对照（V3.1 P3-density + V3 §12 storytelling + 附录 P3 手绘感）：
#   - 每区至少 2-3 件叙事道具（跑步机旁水瓶/毛巾、力量区杠铃架/配重/粉笔盒、
#     瑜伽区植物/音箱/卷垫/暖色灯、自行车区风扇/水杯架/墙上计时器）
#   - 道具打破规则化摆放：非 4px 对齐 + 前后交错遮挡（towel 搭瓶、plate 半压）
#   - 墙地交界无 200px+ 连续水平直线（墙帽/踢脚线多色 cluster 起伏）
#   - 会员在场景中有可见活动姿态（站/走/使用器械），非空场
#
# 用法（窗口模式——headless dummy 驱动下 get_image() 返回 null，项目既有
# 证据方法，见 v31_r2_capture.gd 同款注释）：
#   godot --path . res://tests/evidence/v31_r3_capture.tscn
extends Node

const MAIN_SCENE := preload("res://src/main.tscn")
const Main := preload("res://src/main.gd")
const Proj2D := preload("res://src/presentation/oblique_projection.gd")
const DENSITY_OUT := "res://tests/evidence/v31-r3-density.png"
const POPULATED_OUT := "res://tests/evidence/v31-r3-populated.png"
const REDRAW_FRAME := 6      # 抓帧前强制世界画布重绘（SubViewport 纹理滞后 ≥1 帧）
const DENSITY_FRAME := 40
const INJECT_FRAME := 60     # 注入会员 + 强制重绘（后续帧纹理更新）
const POPULATED_FRAME := 64  # 注入后抓帧（4 帧余量 —— 纹理滞后 ≥1 帧）
const CELL_SIZE := 32

## 管线常量（来自 main.gd —— 证据复算与实现同源）。
const SX := Main.SCREEN_PER_VIEWPORT_X
const SY := Main.SCREEN_PER_VIEWPORT_Y
const OFF := Main.WORLD_VIEWPORT_OFFSET
const WS := Main.WORLD_SCALE

## 注入会员（确定性采样；member_id 决定外观变体 → 差异化 silhouette）。
## 避开初始布局设备占位与互不遮挡。member_id 0..3 → 变体 0..3。
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

## 叙事道具采样锚点（世界坐标，§12 清单）：prop -> 世界采样点 + 期望色。
## 采样点取精灵语义色（与 phase5/v31_p5 同源：锚点 + art px × ART_SCALE）。
## water_bottle(132,70)+art(2,2)*4 / barbell_rack(96,200)+art(4,2)*4 /
## warm_lamp(296,200)+art(3,3)*4 / mat_rolled(349,267)+art(3,2)*4 /
## plant_bright_f1(352,176)+art(2,1)*4。
const PROPS := [
	{"name": "water_bottle", "pos": Vector2(140, 78), "color": Color("F2C94C")},   # ACCENT_YELLOW 瓶身
	{"name": "barbell_rack", "pos": Vector2(112, 208), "color": Color("B7D4EC")}, # METAL_HIGHLIGHT 横杆
	{"name": "warm_lamp", "pos": Vector2(308, 212), "color": Color("E07A3F")},    # ACCENT_ORANGE 暖橙灯罩
	{"name": "mat_rolled", "pos": Vector2(361, 275), "color": Color("C98E6E")},   # TOWEL 暖橙卷垫
	{"name": "plant", "pos": Vector2(360, 180), "color": Color("4E8A5A")},        # PLANT_GREEN 亮叶
]

var _frame := 0
var _density_saved := false
var _injected := false
var _done := false
var _main: Node = null
var _sim = null
var _orch = null
var _all_ok := true


## 世界坐标（可带高度 z）→ 屏幕坐标（V3.1 P1 oblique 投影，独立复算）。
func world_to_screen(w: Vector2, z: float = 0.0) -> Vector2i:
	var v := Proj2D.world_to_screen(w, OFF, WS, Vector2(SX, SY), z)
	return Vector2i(roundi(v.x), roundi(v.y))


func _ready() -> void:
	_main = MAIN_SCENE.instantiate()
	add_child(_main)
	_sim = _main.get("_member")
	_orch = _main.get("_orch")
	_orch.time_system.pause()  # 模拟暂停 —— 采样点稳定


func _process(_delta: float) -> void:
	if _done:
		return
	_frame += 1
	if _frame == REDRAW_FRAME:
		_force_redraw()
		return
	if _frame == DENSITY_FRAME:
		_grab_and_save(DENSITY_OUT, false)
		return
	if _frame == INJECT_FRAME and not _injected:
		_inject_deterministic()
		_force_redraw()
		return
	if _frame == POPULATED_FRAME:
		_grab_and_save(POPULATED_OUT, true)
		_done = true
		print("RESULT: %s" % ("PASS" if _all_ok else "CHECK"))
		get_tree().quit(0 if _all_ok else 1)


func _force_redraw() -> void:
	var canvas := _main.get_node_or_null("WorldViewport/WorldRoot/WorldCanvas")
	if canvas != null:
		canvas.queue_redraw()


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


## 初始布局设备 instance_id 解析（与 phase4_capture 同源）。
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


func _grab_and_save(out_path: String, populated: bool) -> void:
	var img := get_viewport().get_texture().get_image()
	if img == null:
		push_error("v31_r3_capture: get_image() returned null (headless dummy driver?)")
		get_tree().quit(1)
		return
	var abs_path := ProjectSettings.globalize_path(out_path)
	var err := img.save_png(abs_path)
	if err != OK:
		push_error("v31_r3_capture: save_png failed err=%d path=%s" % [err, abs_path])
		get_tree().quit(1)
		return
	print("%s saved=%s size=%dx%d" % ["POPULATED" if populated else "DENSITY",
		out_path, img.get_width(), img.get_height()])
	if populated:
		_verify_populated(img)
	else:
		_verify_density(img)


## 密度帧验证：叙事道具可见（语义色命中）+ 墙地交界无长直线（粗查；
## 严格量化在 v31_r3_pil_sample.py）。
func _verify_density(img: Image) -> void:
	for entry in PROPS:
		var p := world_to_screen(entry["pos"])
		var found := _scan_tone(img, p, 7, entry["color"], 0.20)
		_ok(found, "DENSITY prop %-14s @(%3d,%3d) tone present" % [
			entry["name"], p.x, p.y])
	# 墙地交界直线粗查：北墙墙帽行（屏幕 y≈72..80）与踢脚线（y≈255..266）
	# 不应存在 ≥200px 单色连续行（严格量化见 PIL 脚本）。
	var worst := 0
	for y in [72, 73, 74, 78, 79, 80, 255, 256, 257, 260, 261, 262, 264, 265, 266]:
		var run := _max_same_run(img, y, 12)
		worst = maxi(worst, run)
	_ok(worst < 200, "DENSITY wall-floor junction no 200px+ straight line (max run %d px)" % worst)


## populated 帧验证：会员衬衫色命中（活动姿态可见 —— 非空场）。
func _verify_populated(img: Image) -> void:
	var checks := [
		{"state": "WALKING_TO", "cell": Vector2i(5, 2), "expect": Color("8EC5E8")},
		{"state": "WALKING_TO", "cell": Vector2i(11, 2), "expect": Color("8EC5E8")},
		{"state": "QUEUEING", "cell": Vector2i(3, 6), "expect": Color("F2B486")},
		{"state": "LEAVING", "cell": Vector2i(10, 6), "expect": Color("9A948C")},
	]
	for entry in checks:
		var p := _member_shirt_screen(entry["cell"])
		var found := _scan_tone(img, p, 5, entry["expect"], 0.22)
		_ok(found, "POPULATED %-12s member shirt visible @(%3d,%3d)" % [
			entry["state"], p.x, p.y])


## 会员衬衫采样点（与 v31_r2_capture 同源：画布锚点 + 纹理局部 (24,19)）。
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


## 一行内同色（容差 tol）连续段的最大长度。
func _max_same_run(img: Image, y: int, tol: int) -> int:
	var cur := img.get_pixel(0, y)
	var rs := 0
	var best := 0
	for x in range(1, img.get_width()):
		var c := img.get_pixel(x, y)
		if _ch_dist(c, cur) <= tol:
			continue
		best = maxi(best, x - rs)
		cur = c
		rs = x
	best = maxi(best, img.get_width() - rs)
	return best


func _ch_dist(a: Color, b: Color) -> int:
	return int(absf(a.r - b.r) * 255 + absf(a.g - b.g) * 255 + absf(a.b - b.b) * 255)


func _near(a: Color, b: Color, tol: float) -> bool:
	return absf(a.r - b.r) < tol and absf(a.g - b.g) < tol and absf(a.b - b.b) < tol


func _ok(cond: bool, msg: String) -> void:
	if not cond:
		_all_ok = false
	print("  %s %s" % ["PASS" if cond else "FAIL", msg])
