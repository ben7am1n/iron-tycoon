# tests/evidence/v31_r2_capture.gd — V3.1 R2 人物/器械 sprite 辨识度证据捕获
#
# 渲染真实主场景（src/main.tscn，含 V3 §2 SubViewport 低分辨率管线）并保存：
#   1. tests/evidence/v31-r2-sprite.png —— 渲染帧（注入 4 个不同 silhouette
#      变体会员 + 设备上使用会员；V3 §15 第二眼：人物/器械是精心制作的
#      pixel sprite）
#   2. tests/evidence/v31-r2-members.png —— 会员变体矩阵（4 变体 × 3 姿态，
#      2× 放大独立导出；PIL 采样剪影分层色数/肩宽差异 —— 非复制色块）
#
# 验收对照（V3.1 P2-sprite + V3 §15 第二眼标准）：
#   - 人物可辨认为精心制作的 pixel sprite：头/身/四肢比例、运动服配色、
#     站立姿态有体积感（V3 §8）
#   - 不同会员类型有差异化 silhouette：变体 0 标准 / 1 壮硕（无袖背心 +
#     橙色短裤）/ 2 纤细（马尾）/ 3 敦实（平头）—— 非复制色块
#   - 设备部件可辨：treadmill 跑带（S2S2 高对比履带纹）+ 扶手 + 控制台；
#     bench 长凳（Z 垫 + D 分隔段）+ 杠铃片 + 架子；bike 飞轮 + 座椅 +
#     把手（V3.1 P2 最低要求：3 方向面 + 5 色层 + contact shadow）
#   - contact shadow 明确：会员脚底椭圆收拢影（非 36px 全宽平带）
#
# 用法（窗口模式——headless dummy 驱动下 get_image() 返回 null，项目既有
# 证据方法，见 v31_r1_layer_capture.gd 同款注释）：
#   godot --path . res://tests/evidence/v31_r2_capture.tscn
#
# 采样换算：world_to_screen 走 src/presentation/oblique_projection.gd
# （与 main.gd 同源 —— 证据独立复算）。
extends Node

const MAIN_SCENE := preload("res://src/main.tscn")
const Main := preload("res://src/main.gd")
const Proj2D := preload("res://src/presentation/oblique_projection.gd")
const MemberSpriteScript := preload("res://src/presentation/member_sprite.gd")
const OUT_PATH := "res://tests/evidence/v31-r2-sprite.png"
const MEMBERS_OUT := "res://tests/evidence/v31-r2-members.png"
const REDRAW_FRAME := 6      # 抓帧前强制世界画布重绘（SubViewport 纹理滞后 ≥1 帧）
const CAPTURE_FRAME := 40
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

var _frame := 0
var _captured := false
var _main: Node = null
var _sim = null
var _orch = null
var _all_ok := true


## 世界坐标（可带高度 z）→ 屏幕坐标（V3.1 P1 oblique 投影，独立复算）。
func world_to_screen(w: Vector2, z: float = 0.0) -> Vector2i:
	var v := Proj2D.world_to_screen(w, OFF, WS, Vector2(SX, SY), z)
	return Vector2i(roundi(v.x), roundi(v.y))


## 会员是 billboard：纹理画在「投影后锚点 + 纹理局部偏移」（world_canvas
## _cell_anchor 同源），不是扁平世界点再投影。canvas_pos 已是投影后画布
## 坐标 —— 直接经 WS/OFF/SPV 放大到屏幕（不再次 proj）。
func canvas_to_screen(c: Vector2) -> Vector2i:
	var v := (c * WS + OFF) * Vector2(SX, SY)
	return Vector2i(roundi(v.x), roundi(v.y))


## 会员 sprite 左上角（投影后画布坐标）：脚底（cell 底部中心）投影后 -
## (sprite_w/2, sprite_w)。与 world_canvas._cell_anchor 同源复算。
func _member_canvas_anchor(cell: Vector2i) -> Vector2:
	var feet := Vector2(cell.x * CELL_SIZE + CELL_SIZE * 0.5,
		cell.y * CELL_SIZE + CELL_SIZE)
	return Proj2D.proj(feet.x, feet.y, 0.0) - Vector2(24, 48)


func _ready() -> void:
	_main = MAIN_SCENE.instantiate()
	add_child(_main)
	_sim = _main.get("_member")
	_orch = _main.get("_orch")
	_orch.time_system.pause()  # 模拟暂停 —— 采样点稳定
	_inject_deterministic()
	_export_member_matrix()


func _process(_delta: float) -> void:
	_frame += 1
	if _captured:
		return
	if _frame == REDRAW_FRAME:
		var canvas := _main.get_node_or_null("WorldViewport/WorldRoot/WorldCanvas")
		if canvas != null:
			canvas.queue_redraw()
		return
	if _frame == CAPTURE_FRAME:
		_captured = true
		_capture_and_report()


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


## 会员变体矩阵（独立导出，避开场景光照/遮挡 —— PIL 精确采样剪影）：
## 4 变体 × 3 姿态（walk/tired/satisfied），2× 放大，白底。
func _export_member_matrix() -> void:
	var sprites = _main.get("_member_sprites")
	var poses := [
		{"state": "WALKING_TO", "ctx": {}},
		{"state": "QUEUEING", "ctx": {}},
		{"state": "LEAVING", "ctx": {"leaving_reason": "quota_met"}},
	]
	var cell_w := 48 * 2
	var img := Image.create(cell_w * 4, cell_w * 3, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.92, 0.90, 0.86, 1))  # 暖白底（区分于透明）
	for vi in 4:
		for pi in 3:
			var pose: Dictionary = poses[pi]
			var ctx: Dictionary = pose["ctx"].duplicate()
			ctx["member_id"] = 9000 + vi
			var tex: ImageTexture = sprites.texture_for(pose["state"], 0, false, ctx)
			var s_img: Image = tex.get_image()
			var ox := vi * cell_w
			var oy := pi * cell_w
			for y in 48:
				for x in 48:
					var c: Color = s_img.get_pixel(x, y)
					if c.a <= 0.02:
						continue
					for dy in 2:
						for dx in 2:
							img.set_pixel(ox + x * 2 + dx, oy + y * 2 + dy, c)
	var abs_path := ProjectSettings.globalize_path(MEMBERS_OUT)
	var err := img.save_png(abs_path)
	if err != OK:
		push_error("v31_r2_capture: member matrix save_png failed err=%d" % err)
		get_tree().quit(1)
		return
	print("MEMBERS saved=%s size=%dx%d" % [MEMBERS_OUT, img.get_width(), img.get_height()])


func _capture_and_report() -> void:
	var img := get_viewport().get_texture().get_image()
	if img == null:
		push_error("v31_r2_capture: get_image() returned null (headless dummy driver?)")
		get_tree().quit(1)
		return
	var abs_path := ProjectSettings.globalize_path(OUT_PATH)
	var err := img.save_png(abs_path)
	if err != OK:
		push_error("v31_r2_capture: save_png failed err=%d path=%s" % [err, abs_path])
		get_tree().quit(1)
		return
	print("CAPTURE saved=%s size=%dx%d" % [OUT_PATH, img.get_width(), img.get_height()])
	_verify_members_rendered(img)
	_verify_equipment_visible(img)
	print("RESULT: %s" % ("PASS" if _all_ok else "CHECK"))
	get_tree().quit(0 if _all_ok else 1)


# === 渲染帧验证（内联检查；完整量化在 v31_r2_pil_sample.py） ===

## 4 个不同变体的 walking 会员都渲染成功：在各自 cell 底部中心上方采样到
## 衬衫色（Sky 通道）。变体差异（肩宽/发型）由 PIL 脚本对成员矩阵量化。
func _verify_members_rendered(img: Image) -> void:
	for entry in INJECTED:
		var state: String = entry["state"]
		if state == "USING":
			continue  # 设备上会员在 _verify_equipment_visible 覆盖
		var cell: Vector2i = entry["cell"]
		# 纹理局部坐标：站立姿态躯干行 (24,19) —— 画布锚点 + 局部偏移。
		var p := canvas_to_screen(_member_canvas_anchor(cell) + Vector2(24, 19))
		if p.x < 0 or p.y < 0 or p.x >= img.get_width() or p.y >= img.get_height():
			_ok(false, "STATE %-12s sample out of screen (%d,%d)" % [state, p.x, p.y])
			continue
		var c := img.get_pixel(p.x, p.y)
		var expect := _channel_of(state)
		var found := _near(c, expect, 0.20)
		if not found:
			found = _scan_near(img, p, expect, 5) > 0
		_ok(found, "STATE %-12s @(%3d,%3d) shirt=%s expect=%s" % [
			state, p.x, p.y, c.to_html(false), expect.to_html(false)])


## 设备可见（V3.1 P2 真物体）：footprint 中心采样到设备主体色（非地板）。
## 部件细节（跑带/垫段/飞轮）由 PIL 脚本对设备纹理量化。
func _verify_equipment_visible(img: Image) -> void:
	var eqs := [
		["treadmill", Vector2(96, 80), 30.0, Vector2(96, 91)],   # 顶面中心 + 控制台区
		["bike", Vector2(80, 176), 36.0, Vector2(80, 187)],      # 顶面中心 + 把手/显示区
	]
	for entry in eqs:
		var p := world_to_screen(entry[1], float(entry[2]))
		# 设备主体色在 ±3px 窗口内命中（belt S2S2 的 S 与深色地板接近，
		# 用设备色调检查而非「非地板」）；USING 会员锚定在设备中心 ——
		# 中心被会员衬衫盖住时改扫南端部件区（把手/控制台，会员脚下方）。
		var found := _scan_equip_tone(img, p, 3)
		if not found:
			var p2 := world_to_screen(entry[3], float(entry[2]) * 0.4)
			found = _scan_equip_tone(img, p2, 3)
		var c := img.get_pixel(p.x, p.y)
		_ok(found, "EQ %-10s top @(%3d,%3d) = %s（设备顶面可见）" % [
			entry[0], p.x, p.y, c.to_html(false)])


## ±[radius]px 窗口内是否有设备主体色调（EQUIP_BODY 系 / METAL / SHADOW /
## 区域语义色）—— 窗口吸收 belt S2S2 暗色采样点落在 S 上的情况。
func _scan_equip_tone(img: Image, center: Vector2i, radius: int) -> bool:
	var tones := [
		Color("5D6673"),  # EQUIP_BODY
		Color("49525F"),  # EQUIP_BODY_DARK
		Color("8E99A6"),  # EQUIP_BODY_LIGHT
		Color("5B6470"),  # METAL_DARK
		Color("3A4350"),  # EQUIP_SHADOW_TONE
		Color("3B4552"),  # EQUIP_OUTLINE
		Color("8FBF9F"),  # SAGE (zone)
		Color("8EC5E8"),  # SKY (zone)
	]
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var sx := center.x + dx
			var sy := center.y + dy
			if sx < 0 or sy < 0 or sx >= img.get_width() or sy >= img.get_height():
				continue
			var c := img.get_pixel(sx, sy)
			for t in tones:
				if _near(c, t, 0.09):
					return true
	return false


# === helpers ===

func _channel_of(state: String) -> Color:
	match state:
		"QUEUEING", "USING":
			return Color("F2B486")  # PEACH
		"LEAVING":
			return Color("9A948C")  # MEMBER_LEAVE_GRAY
		_:
			return Color("8EC5E8")  # SKY


func _is_floor_like(c: Color) -> bool:
	for floor_col in [Color("F4E9D8"), Color("4B4F57"), Color("7C8288"),
			Color("A9744C"), Color("D3CBB9")]:
		if _near(c, floor_col, 0.10):
			return true
	return false


func _near(a: Color, b: Color, tol: float) -> bool:
	return absf(a.r - b.r) < tol and absf(a.g - b.g) < tol and absf(a.b - b.b) < tol


func _scan_near(img: Image, center: Vector2i, target: Color, radius: int) -> int:
	var hits := 0
	for dy in range(-radius, radius + 1):
		for dx in range(-radius, radius + 1):
			var sx := center.x + dx
			var sy := center.y + dy
			if sx < 0 or sy < 0 or sx >= img.get_width() or sy >= img.get_height():
				continue
			if _near(img.get_pixel(sx, sy), target, 0.20):
				hits += 1
	return hits


func _ok(cond: bool, msg: String) -> void:
	if not cond:
		_all_ok = false
	print("  %s %s" % ["PASS" if cond else "FAIL", msg])
