# tests/evidence/phase4_capture.gd — V3 Phase 4 会员重绘证据捕获
#
# 渲染真实主场景（src/main.tscn，含 V3 §2 SubViewport 低分辨率管线）并保存
# 视口快照 + 采样验证 + 结构验证 + draw call 预算。
# 输出：tests/evidence/phase4-members.png（证据文件，随仓库提交）。
#
# 用法（窗口模式——headless 用 dummy 渲染驱动，get_image() 返回 null，
# 4.7.1 已验证；窗口捕获是项目既有证据方法，见 phase1_capture 同款注释）：
#   godot --path . res://tests/evidence/phase4_capture.tscn
#
# 验收对照（V3 §8 人物重新设计 + §9 微型动态 + §11 轮廓 + 任务 Exit 条件）：
#   - 会员 sprite 明显增大：48×48 > cell 32（视觉主体，非微型符号）
#   - 动作有表现力：多人同屏 + 至少两种动作状态（walk 跑步 / tired 擦汗 /
#     satisfied 满意 / use 设备互动 —— 通过注入规范会员确定性呈现）
#   - 状态双通道保留：walking→Sky 衬衫 / queue·using→Peach / leaving→灰
#   - 设备互动姿态（V3 §8）：treadmill 跑带 / bench_press 卧推（杠铃+坐起）/
#     bike 骑行 / yoga_mat 瑜伽 —— USING 会员锚定在设备 footprint 上
#   - 深色轮廓（V3 §11）：剪影边缘出现 CHARCOAL（人物轮廓明显）
#   - 微型动态（V3 §9）：tired 头顶 BUTTER 汗滴 / satisfied BUTTER 闪光
#   - draw calls < 200（Performance monitor，4.7.1 枚举名 RENDER_TOTAL_...）
#
# 采样策略：模拟暂停（非 --smoke 默认），注入 6 个已知状态/已知 cell 的
# 规范会员（member_sim 的 members 是公开数组，测试惯用法；仅 presentation
# 层证据，不改玩法逻辑），在已知坐标采样。USING 会员经
# target_equipment_instance_id 锚定到初始布局的设备 footprint。
extends Node

const MAIN_SCENE := preload("res://src/main.tscn")
const Main := preload("res://src/main.gd")  # V3 §2 管线常量（单一来源）
const Palette := preload("res://src/palette.gd")
const OUT_PATH := "res://tests/evidence/phase4-members.png"
const CAPTURE_FRAME := 60      # 注入后留帧让 queue_redraw 落帧
const CELL_SIZE := 32

## 管线常量（来自 main.gd —— 证据复算与实现同源）。
const Proj2D := preload("res://src/presentation/oblique_projection.gd")
const SX := Main.SCREEN_PER_VIEWPORT_X
const SY := Main.SCREEN_PER_VIEWPORT_Y
const OFF := Main.WORLD_VIEWPORT_OFFSET
const WS := Main.WORLD_SCALE

var _frame := 0
var _captured := false
var _main: Node = null
var _sim = null
var _orch = null
var _all_ok := true

## 注入会员：state -> cell / 设备 target。cell 避开初始布局设备占位
## （(2,2)(3,2)(2,5)(3,5)(6,3)(7,3)(1,7)(2,7)(1,8)(2,8)(9,2)）与互不遮挡。
## V3.1 P1 迁移：QUEUEING 从 (8,4) 移到 (9,4) —— 旧 cell 的 sprite 头/躯干被
## FOREGROUND 立柱 (276,16,8,288) 盖住（oblique 下立柱正面投影覆盖右侧）。
## (9,4) 全精灵无遮挡（sweat/head/shirt/legs 均 CLEAR，避让 treadmill(6,3)
## 与立柱）。非 USING 会员放 row≥2：sprite 脚底锚定 cell 底部、头部向上越出
## cell 16px —— row 1 的头部会探进顶部走道，被 HUD 顶栏面板（screen y≈2..54）
## 遮挡，汗滴/闪光等微元素会被盖住。row 2+ 头部完全露出（screen y≈108+）。
const INJECTED := [
	{"member_id": 9001, "state": "WALKING_TO", "cell": Vector2i(5, 2)},
	{"member_id": 9002, "state": "QUEUEING", "cell": Vector2i(9, 4)},
	{"member_id": 9003, "state": "LEAVING", "cell": Vector2i(11, 2), "leaving_reason": "quota_met"},
	{"member_id": 9004, "state": "SELECTING_TARGET", "cell": Vector2i(5, 6)},
	{"member_id": 9005, "state": "USING", "cell": Vector2i(3, 3), "target_equipment": "treadmill"},
	{"member_id": 9006, "state": "USING", "cell": Vector2i(8, 4), "target_equipment": "bench_press"},
	{"member_id": 9007, "state": "USING", "cell": Vector2i(2, 6), "target_equipment": "bike"},
	{"member_id": 9008, "state": "USING", "cell": Vector2i(9, 3), "target_equipment": "yoga_mat"},
]


func _ready() -> void:
	_main = MAIN_SCENE.instantiate()
	add_child(_main)
	_sim = _main.get("_member")
	_orch = _main.get("_orch")
	_orch.time_system.pause()  # 模拟暂停 —— 采样点稳定
	_inject_deterministic()


func _process(_delta: float) -> void:
	_frame += 1
	if _captured:
		return
	if _frame >= CAPTURE_FRAME:
		_captured = true
		_capture_and_report()


## 冻结 + 注入规范会员（已知状态/坐标/设备 → 确定性采样）。
## USING 会员的 target_equipment_instance_id 经 resolver 解析为初始布局
## 里对应 equipment_id 的 instance（evidence 数据源与 main.gd 同源）。
func _inject_deterministic() -> void:
	_sim.members.clear()
	var target_ids := _resolve_equipment_instance_ids()
	print("TARGET_IDS %s" % [str(target_ids)])
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


## 初始布局设备 instance_id 解析：遍历 placed instances，用 main.gd 的
## resolver（_instance_defs）把 equipment_id 映射回 instance_id。
func _resolve_equipment_instance_ids() -> Dictionary:
	var out := {}
	var resolver: Callable = _main.call("_resolver")
	var instances: Array = _main.get("_grid").get_placed_instances()
	for inst in instances:
		var eq := str(resolver.call(inst.instance_id))
		var cells: Array = inst.footprint_cells
		var min_c := Vector2i(cells[0])
		var max_c := Vector2i(cells[0])
		for c in cells:
			min_c.x = mini(min_c.x, c.x)
			min_c.y = mini(min_c.y, c.y)
			max_c.x = maxi(max_c.x, c.x)
			max_c.y = maxi(max_c.y, c.y)
		var rect := Rect2i(min_c * CELL_SIZE, (max_c - min_c + Vector2i.ONE) * CELL_SIZE)
		print("INST inst=%d eq=%s rect=%s anchor=%s" % [inst.instance_id, eq, rect, _equipment_anchor(eq, rect)])
		if eq != "" and not out.has(eq):
			out[eq] = inst.instance_id
	print("EQUIPMENT instances: %s" % [str(out)])
	return out


func _capture_and_report() -> void:
	var img := get_viewport().get_texture().get_image()
	if img == null:
		push_error("phase4_capture: get_image() returned null (headless dummy driver?)")
		get_tree().quit(1)
		return
	var abs_path := ProjectSettings.globalize_path(OUT_PATH)
	var err := img.save_png(abs_path)
	if err != OK:
		push_error("phase4_capture: save_png failed err=%d path=%s" % [err, abs_path])
		get_tree().quit(1)
		return
	print("CAPTURE saved=%s size=%dx%d" % [OUT_PATH, img.get_width(), img.get_height()])
	print("LIVE tick=%d（tick 奇偶决定帧位 —— 微元素采样点按实际帧位解析）" % _live_tick())
	_verify_sprite_size()
	_verify_action_states(img)
	_verify_channels(img)
	_verify_equipment_interaction(img)
	_verify_outline(img)
	_verify_micro_elements(img)
	_verify_perf()
	print("RESULT: %s" % ("PASS" if _all_ok else "CHECK"))
	get_tree().quit(0 if _all_ok else 1)


# === 结构验证 ===

## V3 §8 sprite 明显增大：member_sprite.SIZE == 48（> cell 32）。
func _verify_sprite_size() -> void:
	var size: int = _main.get("_member_sprites").SIZE
	_ok(size > CELL_SIZE, "STRUCT member sprite %d×%d > cell %d（画面视觉主体）" % [size, size, CELL_SIZE])


# === 内容验证 ===

## 动作状态（V3 §8 表现力）：注入 6 种状态的成员都渲染成功（采样到衬衫色
## 或轮廓/主体像素）。walk 跑步/tired/satisfied/use×4 —— 多人同屏 + 多动作。
func _verify_action_states(img: Image) -> void:
	for entry in INJECTED:
		var state: String = entry["state"]
		var cell: Vector2i = entry["cell"]
		# 非 USING 成员：脚底锚定 cell 底部；USING 成员：锚定设备 footprint。
		var anchor := _member_anchor(state, entry, cell)
		var shirt_px := _shirt_local(state, entry)
		var p := canvas_to_full(anchor + shirt_px)
		if p.x < 0 or p.y < 0 or p.x >= img.get_width() or p.y >= img.get_height():
			_ok(false, "STATE %-18s sample out of screen (%d,%d)" % [state, p.x, p.y])
			continue
		var c := img.get_pixel(p.x, p.y)
		var channel := _channel_of(_main, state)
		var ok := _near(c, channel, 0.20)
		# 卧推是横躺构图，锚点经 footprint+类型偏移推算存在 ±2px 精度抖动；
		# 单点未命中时在 ±4px 窗口内搜索衬衫色（成员主体必然着色）——
		# 逐像素正确性由 unit 测试锁定，这里验证渲染/叠加真实发生。
		if not ok:
			var found := _scan_near(img, p, channel, 4)
			ok = found
			if found:
				print("  note: STATE %-18s 单点未命中，±4px 窗口内命中 %d 像素" % [state, found])
		_ok(ok, "STATE %-18s @(%3d,%3d) = %s expect=%s %s" % [
			state, p.x, p.y, c.to_html(false), channel.to_html(false),
			"OK" if ok else "MISS"
		])


## 在 [center] 的 ±[radius]px 窗口内搜索颜色 [target]，命中返回窗口内
## 实际命中像素数（>0 即命中），否则 0。窗口用于吸收卧推横躺锚点抖动。
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


## 状态双通道：walking→Sky / queue·using→Peach / leaving→灰（在 sprite 上
## 采样衬衫色 —— 颜色通道保留）。
func _verify_channels(img: Image) -> void:
	# WALKING_TO (9001) 衬衫 Sky
	var walk_p := canvas_to_full(_cell_anchor(Vector2i(5, 2)) + _shirt_local("WALKING_TO", INJECTED[0]))
	_ok(_near(img.get_pixel(walk_p.x, walk_p.y), Palette.SKY, 0.20),
		"CHANNEL walking 衬衫 Sky @%s" % str(walk_p))
	# QUEUEING (9002) 衬衫 Peach（tired 姿态，颜色通道不变）
	var queue_p := canvas_to_full(_cell_anchor(INJECTED[1]["cell"]) + _shirt_local("QUEUEING", INJECTED[1]))
	_ok(_near(img.get_pixel(queue_p.x, queue_p.y), Palette.PEACH, 0.20),
		"CHANNEL queue 衬衫 Peach @%s" % str(queue_p))
	# LEAVING+quota_met (9003) 衬衫 灰
	var leave_p := canvas_to_full(_cell_anchor(Vector2i(11, 2)) + _shirt_local("LEAVING", INJECTED[2]))
	_ok(_near(img.get_pixel(leave_p.x, leave_p.y), Palette.MEMBER_LEAVE_GRAY, 0.20),
		"CHANNEL leaving 衬衫 MEMBER_LEAVE_GRAY @%s" % str(leave_p))


## 设备互动（V3 §8）：USING 会员锚定在设备 footprint，脚底投影到设备高度
## （stand_z = 高度×0.75）—— 在设备上采样成员主体像素（衬衫 Peach 或轮廓/
## 皮肤 —— 至少不是纯地板）。V3.1 P1：锚点走 _member_anchor（画布坐标），
## 采样走 canvas_to_full（billboard 不再贴地）。
func _verify_equipment_interaction(img: Image) -> void:
	# USING 注入条目（9005 treadmill / 9006 bench_press / 9007 bike / 9008 yoga_mat）
	for entry in INJECTED:
		if entry["state"] != "USING":
			continue
		var eq: String = entry["target_equipment"]
		var anchor := _member_anchor("USING", entry, entry["cell"])
		var shirt_px := _shirt_local("USING", entry)
		var p := canvas_to_full(anchor + shirt_px)
		if p.x < 0 or p.y < 0 or p.x >= img.get_width() or p.y >= img.get_height():
			_ok(false, "EQ %s sample out of screen" % eq)
			continue
		var c := img.get_pixel(p.x, p.y)
		# 成员主体/轮廓：不是纯地板色（Warm Cream 系）即为叠加成功
		var is_floor := _near(c, Color("F4E9D8"), 0.10) or _near(c, Palette.SAGE, 0.10) \
			or _near(c, Palette.SKY, 0.10) or _near(c, Palette.PEACH, 0.10)
		_ok(not is_floor or _near(c, Palette.PEACH, 0.20),
			"EQ %-12s @(%3d,%3d) = %s（设备上有人/轮廓叠加）" % [eq, p.x, p.y, c.to_html(false)])


## V3 §11 深色轮廓：在 walk 成员头左侧边缘采样 CHARCOAL（发际线外 1px）。
## 采样点不硬编码 —— 从实际纹理解析：发际线左外侧必存在 CHARCOAL 轮廓
## 像素（_apply_outline 后处理环），取头部左上区域（x8..20, y2..10）内
## 最左的 CHARCOAL 像素投影到屏幕。变体无关（fringe/tuft 发型都成立）。
func _verify_outline(img: Image) -> void:
	var sprites = _main.get("_member_sprites")
	var tex_img: Image = sprites.texture_for("WALKING_TO", 0, false, {"member_id": 9001}).get_image()
	var local := Vector2i(-1, -1)
	for y in range(2, 11):
		for x in range(8, 21):
			var c := tex_img.get_pixel(x, y)
			if c.a > 0.5 and _near(c, Palette.CHARCOAL, 0.10):
				local = Vector2i(x, y)
				break
		if local != Vector2i(-1, -1):
			break
	_ok(local != Vector2i(-1, -1), "OUTLINE 纹理存在 CHARCOAL 轮廓像素（发际线外）")
	if local == Vector2i(-1, -1):
		return
	# 9001 WALKING_TO @cell(5,2)：billboard 画布锚点（_cell_anchor 已投影）
	var p := canvas_to_full(_cell_anchor(Vector2i(5, 2)) + Vector2(local))
	var c := img.get_pixel(p.x, p.y)
	var ok := _near(c, Palette.CHARCOAL, 0.20)
	if not ok:
		# NEAREST 光栅化偏移：与 MICRO 同款容差扫描（world 0.75 缩放下 1px 轮廓
		# 在屏上 ±1..2px 落位，V3 §2 管线已知现象；d67887b 迁移 phase1 同理）。
		var found := _scan_near(img, p, Palette.CHARCOAL, 4)
		ok = found > 0
	_ok(ok,
		"OUTLINE 发际线外 1px CHARCOAL @%s = %s（V3 §11 人物深色轮廓，纹理@%s）%s" % [str(p), c.to_html(false), str(local), "" if ok else " MISS"])


## V3 §9 微型动态：tired 头顶 BUTTER 汗滴（9002 @cell(8,4)）、satisfied BUTTER
## 闪光（9003 @cell(11,2)）。采样点不硬编码 —— 从实际纹理按当前帧位解析
## （tick 奇偶决定 A/B 帧；汗滴/闪光在 A/B 帧位置不同）。在世界坐标中找到
## 该 BUTTER 微元素的左上角后经 canvas_to_full 采样，避免帧位漂移。
func _verify_micro_elements(img: Image) -> void:
	var sprites = _main.get("_member_sprites")
	var tick := _live_tick()
	# tired 汗滴：QUEUEING 纹理在当前帧位的 BUTTER 像素（行 0..1 内）。
	var tired_tex: ImageTexture = sprites.texture_for("QUEUEING", tick, false, {"member_id": 9002})
	var tired_local := _find_butter_top(tired_tex.get_image(), 2)
	_ok(tired_local != Vector2i(-1, -1),
		"MICRO tired 纹理存在 BUTTER 汗滴像素（帧位 tick=%d）" % tick)
	if tired_local != Vector2i(-1, -1):
		var tired_p := canvas_to_full(_cell_anchor(INJECTED[1]["cell"]) + Vector2(tired_local))
		var c1 := img.get_pixel(tired_p.x, tired_p.y)
		var ok1 := _near(c1, Palette.BUTTER, 0.20)
		if not ok1:
			var found1 := _scan_near(img, tired_p, Palette.BUTTER, 4)
			ok1 = found1 > 0
		_ok(ok1,
			"MICRO tired 汗滴 BUTTER @%s = %s（V3 §9 角色汗滴，纹理@%s）%s" % [str(tired_p), c1.to_html(false), str(tired_local), "" if ok1 else " MISS"])
	# satisfied 闪光：LEAVING+quota_met 纹理在当前帧位的 BUTTER 像素。
	var sat_tex: ImageTexture = sprites.texture_for("LEAVING", tick, false,
		{"leaving_reason": "quota_met", "member_id": 9003})
	var sat_local := _find_butter_top(sat_tex.get_image(), 2)
	_ok(sat_local != Vector2i(-1, -1),
		"MICRO satisfied 纹理存在 BUTTER 闪光像素（帧位 tick=%d）" % tick)
	if sat_local != Vector2i(-1, -1):
		var sat_p := canvas_to_full(_cell_anchor(Vector2i(11, 2)) + Vector2(sat_local))
		var c2 := img.get_pixel(sat_p.x, sat_p.y)
		var ok2 := _near(c2, Palette.BUTTER, 0.20)
		if not ok2:
			var found2 := _scan_near(img, sat_p, Palette.BUTTER, 4)
			ok2 = found2 > 0
		_ok(ok2,
			"MICRO satisfied 闪光 BUTTER @%s = %s（V3 §9 小闪光，纹理@%s）%s" % [str(sat_p), c2.to_html(false), str(sat_local), "" if ok2 else " MISS"])


## 在纹理顶部 [max_rows] 行内找第一个 BUTTER 像素（汗滴/闪光微元素）。
## 返回本地坐标；找不到返回 (-1,-1)。
func _find_butter_top(tex_img: Image, max_rows: int) -> Vector2i:
	for y in max_rows:
		for x in tex_img.get_width():
			var c := tex_img.get_pixel(x, y)
			if c.a > 0.5 and _near(c, Palette.BUTTER, 0.10):
				return Vector2i(x, y)
	return Vector2i(-1, -1)


func _verify_perf() -> void:
	var draw_calls := Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	var fps := Performance.get_monitor(Performance.TIME_FPS)
	var perf_ok := draw_calls < 200
	_ok(perf_ok, "PERF draw_calls=%d fps=%.1f budget_ok=%s" % [draw_calls, fps, str(perf_ok)])


# === helpers ===

## 当前动画 tick（与 world_canvas 的 tick_provider 同源 —— 采样帧位一致）。
func _live_tick() -> int:
	if _orch != null and _orch.time_system != null:
		return _orch.get_tick_count()
	return 0


## 画布坐标 → SubViewport 像素（vp = canvas × WS + OFF；与 main.gd WorldDisplay 同源）。
func canvas_to_vp(c: Vector2) -> Vector2i:
	return Vector2i(roundi(c.x * WS + OFF.x), roundi(c.y * WS + OFF.y))

## 画布坐标 → 全屏像素（×3 放大）。
func canvas_to_full(c: Vector2) -> Vector2i:
	var v := canvas_to_vp(c)
	return Vector2i(roundi(v.x * SX), roundi(v.y * SY))


## 普通会员的 sprite 锚点（投影后画布坐标，sprite 左上角）：脚底
## （cell 底部中心）投影后 - (sprite_w/2, sprite_w) —— 与 world_canvas._cell_anchor
## 同源（V3.1 P1：billboard 站立，头部向上越出 cell）。
func _cell_anchor(cell: Vector2i) -> Vector2:
	var w := float(_main.get("_member_sprites").SIZE)
	var feet := Vector2(cell.x * CELL_SIZE + CELL_SIZE * 0.5,
		cell.y * CELL_SIZE + CELL_SIZE)
	var p := Proj2D.proj(feet.x, feet.y, 0.0)
	return p - Vector2(w * 0.5, w)


## 衬衫采样局部坐标（纹理内）：站立/跑步姿态躯干行 (24,19)；卧推是横躺
## 构图 —— 衬衫躯干在 (8,23)（头左、躯干向右，行 18..33 身体区）。由
## _member_anchor 给出的锚点 + 此处局部坐标共同定位（状态感知）。
func _shirt_local(state: String, entry: Dictionary) -> Vector2:
	if state == "USING" and entry.get("target_equipment", "") == "bench_press":
		return Vector2(8, 23)
	return Vector2(24, 19)


## 状态 → 期望衬衫通道色（world_canvas 语义，证据复算同源）。
func _channel_of(main_node, state: String) -> Color:
	match state:
		"WALKING_TO", "ENTERING", "SELECTING_TARGET":
			return Palette.SKY
		"QUEUEING", "USING":
			return Palette.PEACH
		"LEAVING":
			return Palette.MEMBER_LEAVE_GRAY
		_:
			return Color(0, 0, 0, 0)


## 注入条目 → 绘制锚点（投影后画布坐标；非 USING：cell；USING：设备
## footprint 中心附近，脚底投影到设备高度 stand_z = 高度×0.75 —— 与
## world_canvas._equipment_anchor 同源）。证据脚本独立复算。
func _member_anchor(state: String, entry: Dictionary, cell: Vector2i) -> Vector2:
	if state != "USING":
		return _cell_anchor(cell)
	var eq: String = entry.get("target_equipment", "")
	var w := float(_main.get("_member_sprites").SIZE)
	var rect := _equipment_rect(eq)
	var flat_anchor: Vector2
	match eq:
		"treadmill":
			flat_anchor = Vector2(rect.position.x + rect.size.x / 2.0 - w * 0.5,
				rect.position.y + rect.size.y - w)
		"bench_press":
			flat_anchor = Vector2(rect.position.x + 2, rect.position.y + 26)
		"bike":
			flat_anchor = Vector2(rect.position.x + rect.size.x / 2.0 - w * 0.5,
				rect.position.y + rect.size.y - 16 - w * 0.5)
		"yoga_mat":
			flat_anchor = Vector2(rect.position.x + rect.size.x / 2.0 - w * 0.5,
				rect.position.y + rect.size.y - w * 0.62)
		_:
			flat_anchor = Vector2(rect.position.x + rect.size.x / 2.0 - w * 0.5,
				rect.position.y + rect.size.y - w)
	var flat_feet := flat_anchor + Vector2(w * 0.5, w)
	var stand_z: float = 16.0
	if _main.get("_equip_art") != null:
		stand_z = _main.get("_equip_art").height_for(eq) * 0.75
	var p := Proj2D.proj(flat_feet.x, flat_feet.y, stand_z)
	return p - Vector2(w * 0.5, w)


## 设备 footprint（世界坐标；与 main.gd 初始布局同源 —— 证据复算用）。
func _equipment_rect(eq: String) -> Rect2i:
	match eq:
		"treadmill": return Rect2i(64, 64, 64, 32)
		"bench_press": return Rect2i(32, 224, 64, 64)
		"bike": return Rect2i(64, 160, 32, 32)
		"yoga_mat": return Rect2i(288, 64, 32, 32)
		_: return Rect2i(0, 0, 32, 32)


## 设备使用锚点（与 world_canvas._equipment_anchor 同源复算；供 INST 调试打印）。
func _equipment_anchor(eq_id: String, rect: Rect2i) -> Vector2:
	var center_x := rect.position.x + rect.size.x / 2.0
	var feet_y := rect.position.y + rect.size.y
	var sprite_w := 48.0
	var flat_anchor: Vector2
	match eq_id:
		"treadmill":
			flat_anchor = Vector2(center_x - sprite_w / 2.0, feet_y - sprite_w)
		"bench_press":
			flat_anchor = Vector2(rect.position.x + 2, rect.position.y + 26)
		"bike":
			flat_anchor = Vector2(center_x - sprite_w / 2.0, rect.position.y + rect.size.y - 16 - sprite_w * 0.5)
		"yoga_mat":
			flat_anchor = Vector2(center_x - sprite_w / 2.0, feet_y - sprite_w * 0.62)
		_:
			flat_anchor = Vector2(center_x - sprite_w / 2.0, feet_y - sprite_w)
	var flat_feet := flat_anchor + Vector2(sprite_w * 0.5, sprite_w)
	var stand_z: float = 16.0
	if _main.get("_equip_art") != null:
		stand_z = _main.get("_equip_art").height_for(eq_id) * 0.75
	var p := Proj2D.proj(flat_feet.x, flat_feet.y, stand_z)
	return p - Vector2(sprite_w * 0.5, sprite_w)


func _ok(cond: bool, msg: String) -> void:
	if not cond:
		_all_ok = false
	print("  %s %s" % ["PASS" if cond else "FAIL", msg])


func _near(a: Color, b: Color, tol: float) -> bool:
	var dr := a.r - b.r
	var dg := a.g - b.g
	var db := a.b - b.b
	return sqrt(dr * dr + dg * dg + db * db) <= tol
