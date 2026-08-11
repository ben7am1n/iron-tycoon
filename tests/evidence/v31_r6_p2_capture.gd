# tests/evidence/v31_r6_p2_capture.gd — V3.1 返工6 P2 证据捕获（会员肢体/落地 + 单车体块）
#
# 渲染真实主场景（src/main.tscn，V3.1 P1 oblique + P2 设备 + P3 手绘密度 +
# P4 pixel lighting + P5 高饱和焦点全链路 + 返工6 P1 噪点分层），保存：
#   - tests/evidence/v31-r6-p2-space.png     全场景帧（8 会员在场注入保留）
#   - tests/evidence/v31-r6-p2-closeup.png   设备带 2.5x 特写（bike(2,5) 三面体块 +
#     treadmill(6,3) 层次 + 会员肢体）
#
# 复用 v31_gate_r2_capture.gd 的会员在场确定性注入（8 会员，同一 INJECTED
# 列表 —— 门禁最终帧字节一致；本卡只改证据布局 + 返工6 P2 特写帧）。
# 管线结构复用 v31_r6_p1_capture.gd（_process 帧循环 + _force_redraw）。
#
# 内嵌验证（对照返工6 P2 任务书 FAIL 点 + 已通过项防回归）：
#   - R6 P2 FAIL1 会员肢体完整：member(11,2) 行走会员 3 条色带（头/躯干/腿）
#     + CHARCOAL 外轮廓 + 双脚分开（两脚列分离）
#   - R6 P2 FAIL2 双脚落地：member(11,2) 鞋色在接触行成 2 段（两脚分开），
#     鞋下接触影（MEMBER_SHADOW 半透明）紧贴脚底
#   - R6 P2 FAIL3 单车体块：bike(2,5) 顶面 H 金属高光（飞轮）+ Z 毂 +
#     W 把手暖端头在 2x 可辨（三面体块色阶稳定）
#   - R6 P2 FAIL4 跑步机层次不回归：treadmill(6,3) 控制台 A 青蓝 + 跑带 M/S
#     纹理在 2x 可辨
#   - 会员在场：衬衫色命中（非空场）
#   - draw_calls < 200（V3 §15 性能预算）
#
# 用法（窗口模式——headless 下 get_image() 返回 null，4.7.1 已验证）：
#   godot --path . res://tests/evidence/v31_r6_p2_capture.tscn
extends Node

const MAIN_SCENE := preload("res://src/main.tscn")
const Palette := preload("res://src/palette.gd")
const Proj2D := preload("res://src/presentation/oblique_projection.gd")
const Main := preload("res://src/main.gd")
const OUT_FULL := "res://tests/evidence/v31-r6-p2-space.png"
const OUT_CLOSEUP := "res://tests/evidence/v31-r6-p2-closeup.png"

const REDRAW_FRAME := 6
const INJECT_FRAME := 8
const CAPTURE_FRAME := 12
const CLOSEUP_APPLY_FRAME := 18
const CLOSEUP_REDRAW_FRAME := 20
const CLOSEUP_CAPTURE_FRAME := 26
const CELL_SIZE := 32

const SX := Main.SCREEN_PER_VIEWPORT_X
const SY := Main.SCREEN_PER_VIEWPORT_Y
const OFF := Main.WORLD_VIEWPORT_OFFSET
const WS := Main.WORLD_SCALE

## 特写变换：聚焦设备带中段。用投影空间（Proj2D.proj 输出）计算焦点：
##   bike(2,5) 顶面中心 proj≈(110.8, 110.6)、treadmill(6,3) 控制台
##   proj≈(230, 72)；2.5x 视野 = 426/2.5=170 × 240/2.5=96 投影单位。
##   两机 x 跨 110..230（<170 ✓）、y 跨 72..111（<96 ✓）→ 焦点取中点
##   (170, 91)，两机都完整在画面内（R6 P2 证据：FAIL3 bike + FAIL4 treadmill）。
const CLOSEUP_SCALE := Vector2(2.5, 2.5)
const CLOSEUP_FOCUS := Vector2(170, 91)
const CLOSEUP_POS := Vector2(213.0 - 170.0 * 2.5, 120.0 - 91.0 * 2.5)

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
		orch.time_system.pause()
	_place_preset_equipment()
	_world_root = _main.get_node_or_null("WorldViewport/WorldRoot")
	if _world_root == null:
		push_error("v31_r6_p2_capture: WorldRoot not found")
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
		_full_img = _grab()
		_save(_full_img, OUT_FULL)
		_verify_world_frame(_full_img)
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
		print("RESULT: %s" % ("PASS" if _all_ok else "FAIL"))
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
		push_error("v31_r6_p2_capture: get_image() returned null (headless dummy driver?)")
		get_tree().quit(1)
		return null
	return img


func _save(img: Image, out_path: String) -> void:
	var abs_path := ProjectSettings.globalize_path(out_path)
	var err := img.save_png(abs_path)
	if err != OK:
		push_error("v31_r6_p2_capture: save_png failed err=%d path=%s" % [err, abs_path])
		get_tree().quit(1)
		return
	print("CAPTURE saved=%s size=%dx%d" % [out_path, img.get_width(), img.get_height()])


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


func _ok(cond: bool, label: String) -> void:
	_all_ok = _all_ok and cond
	print("  %s %s" % ["PASS" if cond else "FAIL", label])


func _push_error(msg: String) -> void:
	_all_ok = false
	print("ERROR: " + msg)


func _near(c: Color, ref: Color, tol: float) -> bool:
	return absf(c.r - ref.r) <= tol and absf(c.g - ref.g) <= tol and absf(c.b - ref.b) <= tol


func _color_distance(a: Color, b: Color) -> float:
	var dr := a.r - b.r
	var dg := a.g - b.g
	var db := a.b - b.b
	return sqrt(dr * dr + dg * dg + db * db)


## 世界坐标 → 屏幕（主场景常量，与 main.gd 同源）。
func _proj_screen(wx: float, wy: float, wz: float = 0.0) -> Vector2:
	var p := Proj2D.proj(wx, wy, wz)
	return Vector2((p.x * WS + OFF.x) * SX, (p.y * WS + OFF.y) * SY)


## 特写坐标 → 屏幕（WorldRoot 应用 CLOSEUP_POS/SCALE 后）：
## 世界投影坐标 → 直接乘 CLOSEUP_SCALE + CLOSEUP_POS（WorldRoot 变换
## 替换默认 WS/OFF）→ 最后乘 SX/SY（426×240 → 1280×720）。
## 与 R6 P1 的 WorldRoot 特写变换一致：
##   world_root.scale = CLOSEUP_SCALE; world_root.position = CLOSEUP_POS
func _proj_closeup(wx: float, wy: float, wz: float = 0.0) -> Vector2:
	var p := Proj2D.proj(wx, wy, wz)
	var zoomed := Vector2(p.x * CLOSEUP_SCALE.x + CLOSEUP_POS.x,
		p.y * CLOSEUP_SCALE.y + CLOSEUP_POS.y)
	return Vector2(zoomed.x * SX, zoomed.y * SY)


func _count_near_region(img: Image, center: Vector2, half: int, ref: Color, tol: float,
		every: int = 2) -> int:
	var hits := 0
	for y in range(int(center.y) - half, int(center.y) + half, every):
		for x in range(int(center.x) - half, int(center.x) + half, every):
			if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
				continue
			var c := img.get_pixel(x, y)
			if c.a > 0.5 and _color_distance(c, ref) <= tol:
				hits += 1
	return hits


func _verify_world_frame(img: Image) -> void:
	if img == null:
		return
	# 会员在场：衬衫色命中（非空场）
	var m9000_shirt := _proj_screen(5 * CELL_SIZE + 16, 2 * CELL_SIZE + 16)
	var shirt_hits := _count_near_region(img, m9000_shirt, 40, Palette.SKY, 0.25)
	_ok(shirt_hits > 0, "MEMBER WALKING_TO shirt visible (in-scene, non-empty)")
	# R6 P2 FAIL1/FAIL2：member(11,2) 行走会员 —— 3 条色带 + 双色腿 + 两脚分开
	_verify_member_limbs(img)


func _verify_member_limbs(img: Image) -> void:
	# member(11,2)：脚底 cell 底部中心 → 投影 z=0（行走中景 billboard）
	var cell := Vector2i(11, 2)
	var foot := _proj_screen(cell.x * CELL_SIZE + 16, cell.y * CELL_SIZE + CELL_SIZE, 0.0)
	var cx := int(foot.x)
	var top := int(foot.y) - 100
	var bottom := int(foot.y) + 10
	# 色带：从头（MEMBER_SKIN）→ 躯干（SKY 衬衫）→ 腿（MEMBER_PANTS）
	var head_found := false
	var torso_found := false
	var pants_found := false
	for y in range(top, bottom):
		for x in range(cx - 30, cx + 30):
			var c := img.get_pixel(x, y)
			if c.a <= 0.5:
				continue
			if _color_distance(c, Palette.MEMBER_SKIN) <= 0.20 \
					or _color_distance(c, Palette.MEMBER_SKIN_ALT1) <= 0.20:
				head_found = true
			if _color_distance(c, Palette.SKY) <= 0.18 \
					or _color_distance(c, Palette.PEACH) <= 0.18 \
					or _color_distance(c, Palette.SKY.darkened(0.15)) <= 0.18:
				torso_found = true
			if _color_distance(c, Palette.MEMBER_PANTS) <= 0.18 \
					or _color_distance(c, Palette.FOCAL_GYM_ORANGE) <= 0.18 \
					or _color_distance(c, Palette.MEMBER_PANTS_ALT2) <= 0.18:
				pants_found = true
	var bands := int(head_found) + int(torso_found) + int(pants_found)
	_ok(bands >= 3, "R6P2 FAIL1 member(11,2) 3 color bands (head/torso/legs) — 肢体完整可辨")
	# 深色外轮廓
	var outline_hits := 0
	for y in range(top, bottom):
		for x in range(cx - 30, cx + 30):
			var c := img.get_pixel(x, y)
			if c.a > 0.5 and _color_distance(c, Palette.CHARCOAL) <= 0.18:
				outline_hits += 1
	_ok(outline_hits > 20, "R6P2 FAIL1 member(11,2) CHARCOAL outline hits %d > 20 (深色外轮廓)" % outline_hits)
	# 双脚分开：鞋色（MEMBER_SHOE）在接触行成 ≥2 段
	var shoe_segs := _shoe_segments(img, cx, top, bottom)
	_ok(shoe_segs >= 2, "R6P2 FAIL2 member(11,2) separate feet columns %d >= 2 (两脚分开落地)" % shoe_segs)
	# 接触影：鞋行下方地面亮度低于两侧（阴影压暗地面；alpha 混叠后不再
	# 是纯 MEMBER_SHADOW 色 —— 用局部亮度对比检测，鲁棒）
	var shadow_ok := _contact_shadow_dark(img, cx, top, bottom)
	_ok(shadow_ok, "R6P2 FAIL2 member(11,2) contact shadow darkens ground below feet (脚下接触影)")


func _shoe_segments(img: Image, cx: int, top: int, bottom: int) -> int:
	var best_count := 0
	var best_y := bottom - 1
	for y in range(bottom - 30, bottom):
		var cnt := 0
		for x in range(cx - 30, cx + 30):
			var c := img.get_pixel(x, y)
			if c.a > 0.5 and (_color_distance(c, Palette.MEMBER_SHOE) <= 0.20 \
					or _color_distance(c, Palette.MEMBER_SHOE_ALT1) <= 0.20):
				cnt += 1
		if cnt > best_count:
			best_count = cnt
			best_y = y
	if best_count <= 0:
		return 0
	var segs := 0
	var in_seg := false
	for x in range(cx - 30, cx + 30):
		var c := img.get_pixel(x, best_y)
		var is_shoe := c.a > 0.5 and (_color_distance(c, Palette.MEMBER_SHOE) <= 0.20 \
				or _color_distance(c, Palette.MEMBER_SHOE_ALT1) <= 0.20)
		if is_shoe and not in_seg:
			segs += 1
			in_seg = true
		elif not is_shoe:
			in_seg = false
	return segs


## 接触影检测：找鞋行下方 2-10px 地面带，统计亮度显著低于该带两侧
## 20px 外地面均值的列（阴影压暗地面；alpha 混叠后不再是纯阴影色）。
## 至少 6 列明显更暗 → 判定脚下有接触影。
func _contact_shadow_dark(img: Image, cx: int, top: int, bottom: int) -> bool:
	# 先定位鞋行（复用 _shoe_segments 的行查找逻辑）
	var best_count := 0
	var best_y := bottom - 1
	for y in range(bottom - 30, bottom):
		var cnt := 0
		for x in range(cx - 30, cx + 30):
			var c := img.get_pixel(x, y)
			if c.a > 0.5 and (_color_distance(c, Palette.MEMBER_SHOE) <= 0.20 \
					or _color_distance(c, Palette.MEMBER_SHOE_ALT1) <= 0.20):
				cnt += 1
		if cnt > best_count:
			best_count = cnt
			best_y = y
	if best_count <= 0:
		return false
	var shadow_y := best_y + 4
	if shadow_y >= img.get_height():
		return false
	# 两侧参考带（鞋行水平范围外 25..45px）
	var side_ref := 0.0
	var side_n := 0
	for x in range(cx - 45, cx - 25):
		if x < 0 or x >= img.get_width():
			continue
		var c := img.get_pixel(x, shadow_y)
		if c.a > 0.5:
			side_ref += 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
			side_n += 1
	for x in range(cx + 25, cx + 45):
		if x < 0 or x >= img.get_width():
			continue
		var c := img.get_pixel(x, shadow_y)
		if c.a > 0.5:
			side_ref += 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
			side_n += 1
	if side_n < 4:
		return false
	side_ref /= float(side_n)
	# 鞋行下方带的暗列数
	var dark_cols := 0
	for x in range(cx - 22, cx + 22):
		if x < 0 or x >= img.get_width():
			continue
		var c := img.get_pixel(x, shadow_y)
		if c.a <= 0.5:
			continue
		var lum := 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
		if side_ref - lum > 0.05:
			dark_cols += 1
	return dark_cols >= 6


func _verify_closeup(img: Image) -> void:
	# bike(2,5) 顶面（z=36 顶面受光面）：飞轮 H / 毂 Z 在 2x 可辨。
	# 把手 W 不在顶面采样 —— 会员 9007 USING 骑在车上，身体自然遮挡
	# 顶面南缘把手（正确构图）；把手暖端头由隔离 QA（qa_v31r4p2 C 项
	# 16px）验证。这里改用 bike 正面控制台 W（朝相机，不被骑手遮挡）。
	var bike_top := _proj_closeup(2 * CELL_SIZE + 16, 5 * CELL_SIZE + 16, 36.0)
	var h_hits := _count_near_region(img, bike_top, 60, Palette.METAL_HIGHLIGHT, 0.14)
	_ok(h_hits > 4, "R6P2 FAIL3 bike(2,5) flywheel H metal highlight at 2x (hits=%d)" % h_hits)
	var z_hits := _count_near_region(img, bike_top, 50, Palette.ZONE_COLORS["cardio"], 0.16)
	_ok(z_hits > 4, "R6P2 FAIL3 bike(2,5) flywheel hub Z zone at 2x (hits=%d)" % z_hits)
	# bike 正面（z≈0.8h 控制台带）：W 暖端头朝相机
	var bike_front := _proj_closeup(2 * CELL_SIZE + 16, 5 * CELL_SIZE + 32, 29.0)
	var w_hits := _count_near_region(img, bike_front, 60, Palette.EQUIP_HIGHLIGHT, 0.14)
	_ok(w_hits > 3, "R6P2 FAIL3 bike(2,5) front console W warm ends at 2x (hits=%d)" % w_hits)
	# treadmill(6,3) 顶面（z=30）：控制台 A 青蓝
	var tread_top := _proj_closeup(6 * CELL_SIZE + 16, 3 * CELL_SIZE + 16, 30.0)
	var a_hits := _count_near_region(img, tread_top, 80, Palette.EQUIP_ACCENT_CYAN, 0.15)
	_ok(a_hits > 8, "R6P2 FAIL4 treadmill(6,3) console cyan at 2x (hits=%d)" % a_hits)
	# 设备带非空
	var belt_hits := 0
	for y in range(150, 500, 3):
		for x in range(100, 1100, 4):
			var c := img.get_pixel(x, y)
			if c.a > 0.5:
				belt_hits += 1
	_ok(belt_hits > 2000, "CLOSEUP equipment belt content present (belt_hits=%d)" % belt_hits)


func _verify_perf() -> void:
	var perf = _main.get("_perf_stats")
	if perf != null:
		var dc: int = int(perf.get("draw_calls", 9999))
		_ok(dc < 200, "PERF draw_calls=%d < 200 budget_ok" % dc)
