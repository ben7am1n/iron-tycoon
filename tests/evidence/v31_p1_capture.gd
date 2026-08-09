# tests/evidence/v31_p1_capture.gd — V3.1 P1 2.5D 斜俯视相机证据捕获
#
# 渲染真实主场景（src/main.tscn，含 V3.1 P1 oblique 投影管线）并保存视口
# 快照 + 像素级验证 + 结构验证 + draw call 预算。
# 输出：tests/evidence/v31-p1-camera.png（证据文件，随仓库提交）。
#
# 用法（窗口模式——headless 用 dummy 渲染驱动，get_image() 返回 null，
# 4.7.1 已验证；窗口捕获是项目既有证据方法，见 phase1_capture 同款注释）：
#   godot --path . res://tests/evidence/v31_p1_capture.tscn
#
# 验收对照（附录 V3.1 P1）：
#   - 画面非俯瞰地图：北墙/侧墙面（WALL_BASE）立起 + 墙帽（WALL_TRIM）
#     可见 —— diorama 房间盒而非平面棋盘
#   - 设备有体积：顶面（原 art 提升）+ 正面（南边条带变暗）+ 侧面（东边
#     条带变暗）三面同时可见且颜色分层（V3.1 P1 证据：多层高度色）
#   - 人物不是棋盘棋子：会员 billboard 站立（脚底贴地、身体立起），采样
#     命中衬衫色（SKY/PEACH 通道）
#   - 地板仍是低分辨率像素管线（nearest stair-step；结构断言 FloorArt）
#   - draw calls < 200（性能预算，V3 §15）
#
# 采样换算：world_to_screen 走 src/presentation/oblique_projection.gd
# （与 main.gd 同源 —— 证据独立复算）。
extends Node

const MAIN_SCENE := preload("res://src/main.tscn")
const Main := preload("res://src/main.gd")
const Proj2D := preload("res://src/presentation/oblique_projection.gd")
const Palette := preload("res://src/palette.gd")
const OUT_PATH := "res://tests/evidence/v31-p1-camera.png"
const REDRAW_FRAME := 6      # 抓帧前强制世界画布重绘（SubViewport 纹理滞后 ≥1 帧）
const CAPTURE_FRAME := 30
const RESUME_FRAME := 31     # 第 1 帧采样后恢复模拟 —— 会员开始生成
const SECOND_FRAME := 170    # 约 2.8s 后会员应已出现（到达率 60/min）

## 管线常量（来自 main.gd —— 证据复算与实现同源）。
const SX := Main.SCREEN_PER_VIEWPORT_X
const SY := Main.SCREEN_PER_VIEWPORT_Y
const OFF := Main.WORLD_VIEWPORT_OFFSET
const WS := Main.WORLD_SCALE

var _frame := 0
var _captured := false
var _main: Node = null
var _img_first: Image = null
var _img_second: Image = null
var _all_ok := true


## 世界坐标（可带高度 z）→ 屏幕坐标（V3.1 P1 oblique 投影，独立复算）。
func world_to_screen(w: Vector2, z: float = 0.0) -> Vector2i:
	var v := Proj2D.world_to_screen(w, OFF, WS, Vector2(SX, SY), z)
	return Vector2i(roundi(v.x), roundi(v.y))


func _ready() -> void:
	_main = MAIN_SCENE.instantiate()
	add_child(_main)


func _process(_delta: float) -> void:
	_frame += 1
	if _captured:
		return
	if _frame == REDRAW_FRAME:
		# SubViewport 纹理可能滞后：抓帧前强制世界画布重绘（queue_redraw
		# 幂等，1-2 帧内生效 —— 避免证据采到陈旧帧，见 _debug_iso 排查）。
		var canvas := _main.get_node_or_null("WorldViewport/WorldRoot/WorldCanvas")
		if canvas != null:
			canvas.queue_redraw()
		return
	if _frame == CAPTURE_FRAME:
		_img_first = _grab()
		if _img_first == null:
			return
		_verify_structure()
		_verify_2_5d_walls(_img_first)
		_verify_equipment_volume(_img_first)
		return
	if _frame == RESUME_FRAME:
		var orch = _main.get("_orch")
		if orch != null and orch.time_system != null:
			orch.time_system.resume()
		return
	if _frame == SECOND_FRAME:
		_img_second = _grab()
		if _img_second == null:
			return
		_verify_member_volume(_img_second)
		_save_and_report(_img_second)


func _grab() -> Image:
	var img := get_viewport().get_texture().get_image()
	if img == null:
		push_error("v31_p1_capture: get_image() returned null (headless dummy driver?)")
		get_tree().quit(1)
		return null
	return img


## 保存 PNG + draw call 预算 + 结果。
func _save_and_report(img: Image) -> void:
	var abs_path := ProjectSettings.globalize_path(OUT_PATH)
	var err := img.save_png(abs_path)
	if err != OK:
		push_error("v31_p1_capture: save_png failed err=%d path=%s" % [err, abs_path])
		get_tree().quit(1)
		return
	print("CAPTURE saved=%s size=%dx%d" % [OUT_PATH, img.get_width(), img.get_height()])
	_verify_perf()
	print("RESULT: %s" % ("PASS" if _all_ok else "CHECK"))
	get_tree().quit(0 if _all_ok else 1)


# === 结构验证（V3.1 P1 投影管线存在性） ===

func _verify_structure() -> void:
	_ok(_main.get_node_or_null("WorldViewport/WorldRoot/WorldCanvas") != null,
		"STRUCT WorldCanvas exists (world draw node)")
	var canvas := _main.get_node_or_null("WorldViewport/WorldRoot/WorldCanvas")
	if canvas != null:
		_ok(canvas.get("_floor_art") != null, "STRUCT WorldCanvas has FloorArt (V3 §1 low-res pipeline)")
		_ok(canvas.get("_equip_art") != null, "STRUCT WorldCanvas has EquipmentArt (V3 Phase 3)")
	# 投影常量契约（V3.1 P1/P1-R1）：30-45° 俯角 → FLOOR_SCALE=sin(θ)∈[0.50,0.71]、
	# HEIGHT_SCALE=cos(θ)∈[0.71,0.87]（R1 修正：此前 0.78/0.62 相当于 52° 俯角，
	# 超出区间读作俯视布局图 —— 修正为 sin38°≈0.62 / cos38°≈0.79）。
	_ok(Proj2D.FLOOR_SCALE > 0.50 and Proj2D.FLOOR_SCALE < 0.71,
		"STRUCT FLOOR_SCALE %.2f in 30-45deg band (sin)" % Proj2D.FLOOR_SCALE)
	_ok(Proj2D.HEIGHT_SCALE > 0.71 and Proj2D.HEIGHT_SCALE < 0.87,
		"STRUCT HEIGHT_SCALE %.2f in 30-45deg band (cos)" % Proj2D.HEIGHT_SCALE)
	# 世界锚定 UI 投影注入（selection cue/toolbar 拿 world_to_screen）。
	var cue := _main.get_node_or_null("UICanvas/SelectionCue")
	if cue != null:
		_ok(cue.get("_world_to_screen").is_valid() if cue.get("_world_to_screen") != null else false,
			"STRUCT SelectionCue has world_to_screen projection (V3.1 P1 anchoring)")
	var toolbar := _main.get_node_or_null("UICanvas/SelectionToolbar")
	if toolbar != null:
		_ok(toolbar.get("_world_to_screen").is_valid() if toolbar.get("_world_to_screen") != null else false,
			"STRUCT SelectionToolbar has world_to_screen projection (V3.1 P1 anchoring)")


# === 2.5D 墙验证（V3.1 P1：墙壁有体积 —— 正面/顶面/侧面） ===

## 北墙面（WALL_BASE）：z=30 与 z=100 两处采样 —— 证明墙面连续立起
## （有高度，非贴地色块）。踢脚线（WALL_DARK，z≈2）。采样点 x=90 避开
## 墙上装饰（窗 x 96+/喷淋 x 80..84/挂钟 x 200/空调 x 244/通风口 x 156）。
## 注：墙帽顶面（z 106..110）在屏幕 y 44.6..50.7 —— 恰在 HUD 顶栏面板
## （y 2..50）之下被 UI 遮挡（旧扁平视图同样被顶栏盖住顶部墙条）—— 顶面
## 证据改由设备顶面承担（_verify_equipment_volume），墙证据聚焦墙身立面。
func _verify_2_5d_walls(img: Image) -> void:
	# 北墙面（x=90 在喷淋与窗之间，z=55 中段）
	var face_p := world_to_screen(Vector2(90, 24), 55.0)
	var face_c := img.get_pixel(face_p.x, face_p.y)
	_ok(_near(face_c, Palette.WALL_BASE, 0.25),
		"WALL north face = WALL_BASE (%s vs %s) @%s" % [face_c.to_html(false), Palette.WALL_BASE.to_html(false), face_p])
	# 墙身上段（z=100 —— 低于 HUD 面板，可见；证明墙面连续立起）
	var top_p := world_to_screen(Vector2(90, 24), 100.0)
	var top_c := img.get_pixel(top_p.x, top_p.y)
	_ok(_near(top_c, Palette.WALL_BASE, 0.25),
		"WALL north face near-top = WALL_BASE (%s vs %s) @%s" % [top_c.to_html(false), Palette.WALL_BASE.to_html(false), top_p])
	# 踢脚线（z=2 —— WALL_DARK 墙基压条；x=200 避开前台 x 56..160）
	var base_p := world_to_screen(Vector2(200, 24), 2.0)
	var base_c := img.get_pixel(base_p.x, base_p.y)
	_ok(_near(base_c, Palette.WALL_DARK, 0.22),
		"WALL north baseboard = WALL_DARK (%s vs %s) @%s" % [base_c.to_html(false), Palette.WALL_DARK.to_html(false), base_p])
	# 墙面 ≠ 地板（墙是有高度的立面，不是贴地色）
	var floor_p := world_to_screen(Vector2(90, 200))
	var floor_c := img.get_pixel(floor_p.x, floor_p.y)
	_ok(not _near(face_c, floor_c, 0.08),
		"WALL face color differs from floor color (volume, not flat decal): %s vs %s" % [
			face_c.to_html(false), floor_c.to_html(false)])


# === 设备体积验证（V3.1 P1：顶面 + 正面 + 侧面三面分层） ===

## 初始布局 treadmill(2,2)（footprint 64..128 × 64..96，h=30）：
##   - 顶面：proj(80, 80, 30)（原 art 提升）
##   - 正面：proj(80, 96, 15)（南边条带变暗）
##   - 侧面：proj(128, 80, 15)（东边条带变暗）
## 三面颜色必须互不相同（多层高度色 —— 非单色平面块）。
func _verify_equipment_volume(img: Image) -> void:
	var top_p := world_to_screen(Vector2(80, 80), 30.0)
	var front_p := world_to_screen(Vector2(80, 96), 15.0)
	var side_p := world_to_screen(Vector2(128, 80), 15.0)
	var top_c := img.get_pixel(top_p.x, top_p.y)
	var front_c := img.get_pixel(front_p.x, front_p.y)
	var side_c := img.get_pixel(side_p.x, side_p.y)
	_ok(not _near(top_c, front_c, 0.05),
		"VOLUME treadmill top #%s != front #%s (multi-layer height colors)" % [
			top_c.to_html(false), front_c.to_html(false)])
	_ok(not _near(top_c, side_c, 0.05),
		"VOLUME treadmill top #%s != side #%s (multi-layer height colors)" % [
			top_c.to_html(false), side_c.to_html(false)])
	_ok(not _near(front_c, side_c, 0.05),
		"VOLUME treadmill front #%s != side #%s (multi-layer height colors)" % [
			front_c.to_html(false), side_c.to_html(false)])
	# 顶面是设备 art（机器灰阶/暖高光 —— 非地板色）
	_ok(_lum(top_c) < 0.9,
		"VOLUME treadmill top face rendered (lum %.2f, equipment art present)" % _lum(top_c))


# === 会员体积验证（V3.1 P1：人物不是棋盘棋子 —— billboard 站立） ===

## 会员生成后（frame 150，到达率 60/min → 应有会员在走动/排队）：
## 取第一个非 USING 会员，采样其 sprite 衬衫区（脚底上方 ~20-34px），
## 命中 SKY（walking）/ PEACH（queueing）通道色 —— 人物立起有身体。
## V3.1 R1（投影修正）：sprite 是 screen-space billboard（脚底投影点上方
## 48px sprite，不随 FLOOR_SCALE 压缩）—— 采样改为「投影脚底 + 屏幕空间
## 偏移」，不再用世界坐标向上偏移（旧方式在 FLOOR_SCALE 0.78→0.62 后
## 与 sprite 错位）。
func _verify_member_volume(img: Image) -> void:
	var member = _find_visible_member()
	if member == null:
		_ok(false, "MEMBER a visible member exists at frame %d (sim spawned)" % _frame)
		return
	var cell: Vector2i = member["cell"]
	var state := str(member["state"])
	var expected := Palette.SKY if _is_walking_state(state) else Palette.PEACH
	var feet := Vector2(cell.x * 32 + 16, cell.y * 32 + 32)
	var feet_p := world_to_screen(feet)
	# 衬衫区：屏幕空间脚底上方 48..66px（48px sprite 中段 shirt 行 20-34 ×
	# 0.75×3 屏幕放大 ≈ 45..76px；实测 shirt 蓝灰在 50-66px —— 取中段
	# 48/54/60/66），水平扫 5 列。
	var found := false
	for dy in [48, 54, 60, 66]:
		for dx in [-10, -5, 0, 5, 10]:
			var p := Vector2i(feet_p.x + dx, feet_p.y - dy)
			if not _in_bounds(img, p):
				continue
			var c := img.get_pixel(p.x, p.y)
			if _near(c, expected, 0.28) or _near(c, Palette.MEMBER_SKIN, 0.25):
				found = true
				break
		if found:
			break
	_ok(found,
		"MEMBER %s at cell %s has body pixels (shirt/skin, not a chess pawn)" % [state, cell])
	# 会员 sprite 高于地面（脚底贴地，身体立起 —— 与地板不同色）
	var ground_p := world_to_screen(feet)
	var ground_c := img.get_pixel(ground_p.x, ground_p.y)
	var body_p := Vector2i(feet_p.x, feet_p.y - 54)
	var body_c := img.get_pixel(body_p.x, body_p.y)
	_ok(not _near(ground_c, body_c, 0.06),
		"MEMBER body pixels differ from ground (standing, has height): %s vs %s" % [
			body_c.to_html(false), ground_c.to_html(false)])


func _find_visible_member() -> Dictionary:
	var member = _main.get("_member")
	if member == null:
		return {}
	for m in member.members:
		if not (m is Dictionary) or not m.has("cell") or not m.has("state"):
			continue
		var state := str(m["state"])
		if state == "GONE":
			continue
		var cell: Vector2i = m["cell"]
		if cell.x < 0 or cell.y < 0 or cell.x > 12 or cell.y > 9:
			continue
		if state == "USING":
			continue  # USING 会员在设备上 —— 采样可能被设备盖住，优先走动/排队
		return m
	return {}


func _is_walking_state(state: String) -> bool:
	return state == "ENTERING" or state == "WALKING_TO" or state == "SELECTING_TARGET"


func _verify_perf() -> void:
	var draw_calls := Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	var fps := Performance.get_monitor(Performance.TIME_FPS)
	var perf_ok := draw_calls < 200
	_ok(perf_ok, "PERF draw_calls=%d fps=%.1f budget_ok=%s" % [draw_calls, fps, str(perf_ok)])


# === helpers ===

func _ok(cond: bool, msg: String) -> void:
	if not cond:
		_all_ok = false
	print("  %s %s" % ["PASS" if cond else "FAIL", msg])


func _in_bounds(img: Image, p: Vector2i) -> bool:
	return p.x >= 0 and p.y >= 0 and p.x < img.get_width() and p.y < img.get_height()


func _near(a: Color, b: Color, tol: float) -> bool:
	return _color_distance(a, b) <= tol


func _color_distance(a: Color, b: Color) -> float:
	var dr := a.r - b.r
	var dg := a.g - b.g
	var db := a.b - b.b
	return sqrt(dr * dr + dg * dg + db * db)


func _lum(c: Color) -> float:
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
