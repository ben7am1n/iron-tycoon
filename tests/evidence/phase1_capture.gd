# tests/evidence/phase1_capture.gd — V3 Phase 1 低分辨率世界管线证据捕获
#
# 渲染真实主场景（src/main.tscn，含 V3 §2 SubViewport 低分辨率管线）并保存
# 视口快照 + 像素级验证 + 结构验证 + draw call 预算。
# 输出：tests/evidence/phase1-lowres-pipeline.png（证据文件，随仓库提交）。
#
# 用法（窗口模式——headless 用 dummy 渲染驱动，get_image() 返回 null，
# 4.7.1 已验证；窗口捕获是项目既有证据方法，见 phase_b_capture 同款注释）：
#   godot --path . res://tests/evidence/phase1_capture.tscn
#
# 验收对照（V3 §2 低分辨率世界渲染 + §14 可读性 + 任务 Exit 条件）：
#   - 世界内容（设备语义色 / 描边 / access Butter / 阴影）经低分辨率管线
#     仍可采样命中（世界 → 0.75 → 426×240 → nearest 3x → 1280×720）
#   - 像素 stair-step 真实：同一 viewport 像素的屏幕 ~3px 块内逐像素 IDENTICAL，
#     边缘硬切（无抗锯齿渐变）—— 最近邻放大证据
#   - V3 §14：正常经营模式 grid 完全隐藏；placement mode（拖拽中）grid 显示
#     （采样窗口 305..325 @row450 —— 覆盖网格线栅格化的 ±2 viewport px 偏移）
#   - WORLD/UI 分辨率分离：WorldViewport 426×240 + TextureRect NEAREST +
#     UICanvas CanvasLayer 结构存在；UI 面板（palette 条带）高分辨率绘制
#   - draw calls < 200（Performance monitor，4.7.1 枚举名 RENDER_TOTAL_...）
#
# 采样策略：模拟暂停（非 --smoke 默认），会员不生成 → 采样点稳定不被遮挡。
# 世界→屏幕换算用 main.gd 的管线常量（SCREEN_PER_VIEWPORT_X/Y、
# WORLD_VIEWPORT_OFFSET、WORLD_SCALE）独立复算 —— 同时验证常量本身。
extends Node

const MAIN_SCENE := preload("res://src/main.tscn")
const Main := preload("res://src/main.gd")  # V3 §2 管线常量（单一来源）
const OUT_PATH := "res://tests/evidence/phase1-lowres-pipeline.png"
const CAPTURE_NORMAL_FRAME := 10
const DRAG_START_FRAME := 11
const CAPTURE_PLACEMENT_FRAME := 12

## 管线常量（来自 main.gd —— 证据复算与实现同源）。
const Proj2D := preload("res://src/presentation/oblique_projection.gd")
const SX := Main.SCREEN_PER_VIEWPORT_X
const SY := Main.SCREEN_PER_VIEWPORT_Y
const OFF := Main.WORLD_VIEWPORT_OFFSET
const WS := Main.WORLD_SCALE

var _frame := 0
var _captured := false
var _main: Node = null
var _placement: Object = null
var _normal_img: Image = null
var _all_ok := true


## 世界坐标 → 屏幕坐标（V3 §2 管线换算，独立于 main.gd 实现复算）。
## [w] 扁平世界坐标；[z] 高度（世界 px，0=地面；设备顶面/挤出面用设备高度）。
func world_to_screen(w: Vector2, z: float = 0.0) -> Vector2i:
	# V3.1 P1：世界→屏幕走 oblique 投影（main.gd 同源换算，证据独立复算）。
	# V3.1 P2：设备/结构有体积（顶面 z=height 挤出）—— 采样 z>0 顶面/挤出面
	# 必须带高度（bench_press z=26、yoga_mat z=6；P1 审查：z=0 采样到挤出
	# 前脸阴影，期望色在 z=15/30 顶面）。
	var v := Proj2D.world_to_screen(w, OFF, WS, Vector2(SX, SY), z)
	return Vector2i(roundi(v.x), roundi(v.y))


func _ready() -> void:
	_main = MAIN_SCENE.instantiate()
	add_child(_main)
	_place_preset_equipment()
	_placement = _main.get("_orch").placement_system


## 显式放置 V3.1 预置设备（treadmill(2,2)(6,3) / bike(2,5) / bench_press(1,7)
## / yoga_mat(9,2)）—— 证据采样依赖这些设备的场景语义（bench sage / yoga
## peach / treadmill 跑带 stair-step / console cyan）。main.gd 的初始布局是
## 经济默认（B2 后改为空房开局），证据脚本不依赖它 —— 已放置则跳过，
## 未放置则走 PlacementSystem 完整拖放链补齐（同 main.gd _drag_drop）。
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
	if _frame == CAPTURE_NORMAL_FRAME:
		_capture_normal_and_verify()
		return
	if _frame == DRAG_START_FRAME:
		# placement mode：拖 treadmill 到 (10,8)（合法格）→ 网格 + 合法幽灵同框。
		_placement.begin_drag("treadmill")
		_placement.on_mouse_moved(Vector2i(10, 8))
		return
	if _frame == CAPTURE_PLACEMENT_FRAME:
		_captured = true
		_capture_placement_and_report()


func _grab() -> Image:
	var img := get_viewport().get_texture().get_image()
	if img == null:
		push_error("phase1_capture: get_image() returned null (headless dummy driver?)")
		get_tree().quit(1)
		return null
	return img


## 第 1 帧验证（正常经营模式，V3 §14 grid 隐藏）：
##   结构（WORLD/UI 分离） + 世界内容 + stair-step + grid 隐藏 + UI 高分辨率。
func _capture_normal_and_verify() -> void:
	_normal_img = _grab()
	if _normal_img == null:
		return
	_verify_structure()
	_verify_world_content(_normal_img)
	_verify_stair_step(_normal_img)
	_verify_grid_hidden(_normal_img)
	_verify_ui_layer(_normal_img)


func _capture_placement_and_report() -> void:
	var img := _grab()
	if img == null:
		return
	var abs_path := ProjectSettings.globalize_path(OUT_PATH)
	var err := img.save_png(abs_path)
	if err != OK:
		push_error("phase1_capture: save_png failed err=%d path=%s" % [err, abs_path])
		get_tree().quit(1)
		return
	print("CAPTURE saved=%s size=%dx%d" % [OUT_PATH, img.get_width(), img.get_height()])
	_verify_grid_visible(img)
	_verify_perf()
	print("RESULT: %s" % ("PASS" if _all_ok else "CHECK"))
	get_tree().quit(0 if _all_ok else 1)


# === 结构验证（WORLD/UI 分辨率分离可验证，Exit 条件 2） ===

func _verify_structure() -> void:
	var vp := _main.get_node_or_null("WorldViewport")
	_ok(vp != null, "STRUCT WorldViewport node exists")
	if vp != null:
		_ok(vp.size == Vector2i(426, 240), "STRUCT WorldViewport size == 426x240 (got %s)" % str(vp.size))
	_ok(_main.get_node_or_null("WorldViewport/WorldRoot") != null, "STRUCT WorldRoot exists (world pixel space)")
	_ok(_main.get_node_or_null("WorldViewport/WorldRoot/WorldCanvas") != null, "STRUCT WorldCanvas exists (world draw node)")
	var display := _main.get_node_or_null("WorldDisplay")
	_ok(display != null, "STRUCT WorldDisplay TextureRect exists")
	if display != null:
		_ok(display.texture_filter == CanvasItem.TEXTURE_FILTER_NEAREST,
			"STRUCT WorldDisplay filter == NEAREST (got %d)" % display.texture_filter)
		_ok(display.texture != null, "STRUCT WorldDisplay texture bound")
		_ok(display.mouse_filter == Control.MOUSE_FILTER_IGNORE, "STRUCT WorldDisplay input-ignore")
	var ui := _main.get_node_or_null("UICanvas")
	_ok(ui != null, "STRUCT UICanvas CanvasLayer exists")
	if ui != null:
		_ok(ui is CanvasLayer, "STRUCT UICanvas is CanvasLayer")
		_ok(ui.get_child_count() > 0, "STRUCT UICanvas has UI children (got %d)" % ui.get_child_count())
	_ok(_main.get_node_or_null("WorldViewport/WorldRoot/HeatmapLayer") != null
		or _main.get_node_or_null("WorldViewport/WorldRoot") != null,
		"STRUCT world presentation layers inside WorldRoot")


# === 世界内容验证（低分辨率管线内语义色仍可命中） ===

## 采样点（世界坐标 → 屏幕换算；V3 Phase 3 设备场景物件语义色）：
##   - treadmill(2,2) 机身中调 EQUIP_BODY #5D6673（机器灰阶，非 Sky 图标色）；
##     轮廓 EQUIP_OUTLINE #3B4552（§11 机器深蓝灰轮廓，左缘 art col2）；access(2,3)
##     Butter 菱形
##   - bench_press(1,7) pad Sage（16×16 art 下 pad 居 world x 60..70，取 64）
##     —— V3.1 P2：设备有体积，sage pad 在顶面 z=26（EQUIP_HEIGHTS bench_press
##     26.0）。z=0 采样会落到挤出前脸阴影（#424B57）—— P1 审查确认期望色
##     #8FBF9F 在 z=26 顶面。
##   - yoga_mat(9,2) 垫面 Peach —— 同理顶面 z=6（EQUIP_HEIGHTS yoga_mat 6.0）
##   - 阴影对比：treadmill footprint 下方 vs 同区域地板
func _verify_world_content(img: Image) -> void:
	var checks := [
		["deck_body", Vector2(96, 80), Color("5D6673"), 0.16, 0.0],
		["outline_equip", Vector2(68, 66), Color("3B4552"), 0.20, 0.0],
		["bench_sage", Vector2(64, 268), Color("8FBF9F"), 0.16, 26.0],
		["yoga_peach", Vector2(310, 74), Color("F2B486"), 0.16, 6.0],
	]
	for entry in checks:
		var p := world_to_screen(entry[1], entry[4])
		var got := img.get_pixel(p.x, p.y)
		var expect: Color = entry[2]
		var ok := _near(got, expect, entry[3])
		_ok(ok, "WORLD %-16s world%s z=%s -> screen(%3d,%3d) = %s expect=%s %s" % [
			entry[0], str(entry[1]), str(entry[4]), p.x, p.y, got.to_html(false), expect.to_html(false),
			"OK" if ok else "MISMATCH"
		])
	# V3 §14 可读性（P0-2 修复）：access cell 星形标记仅 placement mode / hover
	# 出现 —— 正常经营模式静态帧不再常驻黄框（门禁 FAIL：选择/任务标记有调试感）。
	# 断言：treadmill(2,2) 的 access cell (2,3) 中心（世界 (80,112)）在正常帧
	# 不出现 BUTTER 标记；拖拽中的 placement 帧由 _verify_placement_butter 断言
	# 标记出现。
	var acc_p := world_to_screen(Vector2(80, 112))
	var acc_col := img.get_pixel(acc_p.x, acc_p.y)
	_ok(not _near(acc_col, Color("F5D97B"), 0.20),
		"WORLD access_marker_hidden world(80,112) -> screen(%3d,%3d) = %s（V3 §14：正常经营帧无常驻黄框）" % [
			acc_p.x, acc_p.y, acc_col.to_html(false)
		])
	var sh_p := world_to_screen(Vector2(130, 80))
	var fl_p := world_to_screen(Vector2(138, 80))
	var shadow_col := img.get_pixel(sh_p.x, sh_p.y)
	var floor_col := img.get_pixel(fl_p.x, fl_p.y)
	var shadow_ok := _luminance(shadow_col) < _luminance(floor_col) - 0.04
	_ok(shadow_ok, "WORLD shadow(%d,%d)=%s darker than floor(%d,%d)=%s %s" % [
		sh_p.x, sh_p.y, shadow_col.to_html(false), fl_p.x, fl_p.y, floor_col.to_html(false),
		"OK" if shadow_ok else "WEAK"
	])


## 像素 stair-step（Exit 条件 1）：treadmill(2,2) 跑带左缘 —— V3.1 P2 设备顶面
## z=30（EQUIP_HEIGHTS treadmill 30.0），跑带行 world(64,80) → 屏幕 (251,293)。
## 左块 261..263 = EQUIP_BODY_LIGHT #8E99A6（142,153,166）逐像素 IDENTICAL；
## 右块 264..266 = 接触影深色 #3A444F（58,68,81）逐像素 IDENTICAL；两组之间
## 硬切（无抗锯齿中间色）—— 最近邻放大证据（P1 审查：旧 322..327@y=180 是
## 轴对齐投影位置，oblique 下 treadmill 左缘移到 x=261..266@y=293）。
func _verify_stair_step(img: Image) -> void:
	var y := 293
	var a: Array = [img.get_pixel(261, y), img.get_pixel(262, y), img.get_pixel(263, y)]
	var b: Array = [img.get_pixel(264, y), img.get_pixel(265, y), img.get_pixel(266, y)]
	_ok(_identical(a), "STAIR left block (261..263) identical nearest-run: %s" % a[0].to_html(false))
	_ok(_identical(b), "STAIR right block (264..266) identical nearest-run: %s" % b[0].to_html(false))
	_ok(not _near(a[0], b[0], 0.10), "STAIR hard edge 263/264 (no bilinear blend): %s vs %s" % [
		a[0].to_html(false), b[0].to_html(false)
	])


## V3 §14：正常经营模式 grid 完全隐藏 —— world (394,224)（walkway 列 12 瓷砖面
## 上的水平网格线位置）处无 Charcoal 线。采样窗口 x 1112..1132 @ y 544..550
## （world y=224 → screen ≈547，±2 viewport px 栅格化容差；窗口落在亮瓷砖面
## 内，无结构/设备遮挡）。V3.1 P1 迁移：旧窗口 1044..1066@357..360 是轴对齐
## 投影下的世界 (390,160)；oblique 下该屏幕位置落在东墙（暗），改用新投影
## 下 walkway 亮瓷砖 + 网格线交点 (394,224)→(1122,547)。
func _verify_grid_hidden(img: Image) -> void:
	var min_lum := 1.0
	var max_lum := 0.0
	for x in range(1112, 1133):
		for y in range(544, 551):
			var c := img.get_pixel(x, y)
			min_lum = minf(min_lum, _luminance(c))
			max_lum = maxf(max_lum, _luminance(c))
	# 网格线（Charcoal）未画 → 窗口内全部是亮瓷砖面（高亮度、平坦）。
	# 主断言是 min_lum（无暗线）；spread 为次级平坦检查 —— 瓷砖面 + 砖缝行
	# 本身有 ~0.1 亮度差（材质地板，非旧纯色 Sage），Phase 5 地板砖缝 + 光照
	# 叠加 ~0.16，放宽至 0.20（仅作平坦性参考，不承载 grid 隐藏判定）。
	_ok(min_lum > 0.55, "GRID hidden: no charcoal in window 1112..1132 @544..550 (min lum %.3f)" % min_lum)
	_ok(max_lum - min_lum < 0.20, "GRID hidden: flat tile window (spread %.3f)" % (max_lum - min_lum))


## UI 高分辨率层（Exit 条件 3）：palette 条带（底部 96px 深色面板）在
## 1280×720 画布上渲染 —— 非低分辨率世界内容。
func _verify_ui_layer(img: Image) -> void:
	_ok(img.get_width() == 1280 and img.get_height() == 720,
		"UI canvas 1280x720 (got %dx%d)" % [img.get_width(), img.get_height()])
	var c := img.get_pixel(640, 660)
	_ok(_luminance(c) < 0.45, "UI palette strip panel dark at (640,660): %s (lum %.3f)" % [
		c.to_html(false), _luminance(c)
	])


## placement mode（拖拽中）：网格线出现 —— world (394,224) 亮瓷砖窗口内出现
## Charcoal 暗线（水平网格线 world y=224 → screen ≈547；相对瓷砖面显著更暗）。
## V3 §14（P0-2 修复）：拖拽中 grid 可见 → 所有已放置实例的 access cell 星形
## 标记也出现（正常经营帧隐藏，见 _verify_world_content）。断言 treadmill(2,2)
## 的 access cell (2,3) 中心（世界 (80,112)，z=0 贴地）出现 BUTTER 标记。
func _verify_grid_visible(img: Image) -> void:
	var min_lum := 1.0
	for x in range(1112, 1133):
		for y in range(544, 551):
			var c := img.get_pixel(x, y)
			min_lum = minf(min_lum, _luminance(c))
	_ok(min_lum < 0.45, "GRID visible: charcoal line in window 1112..1132 @544..550 during drag (min lum %.3f)" % min_lum)
	var acc_p := world_to_screen(Vector2(80, 112))
	var acc_col := img.get_pixel(acc_p.x, acc_p.y)
	var acc_ok := _near(acc_col, Color("F5D97B"), 0.25)
	if not acc_ok:
		acc_ok = _scan_near(img, acc_p, Color("F5D97B"), 4) > 0
	_ok(acc_ok, "GRID access_marker_visible world(80,112) -> screen(%3d,%3d) = %s（V3 §14：拖拽中 access 星形标记出现）" % [
		acc_p.x, acc_p.y, acc_col.to_html(false)
	])


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


## 中心点 ±radius 窗口内搜索 target 颜色（NEAREST 光栅化 ±1..2px 落位容差，
## 与 phase4 的 _scan_near 同款；V3 §2 管线已知现象）。
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


func _identical(cs: Array) -> bool:
	for i in range(1, cs.size()):
		if not _near(cs[0], cs[i], 0.001):
			return false
	return true


func _near(a: Color, b: Color, tol: float) -> bool:
	var dr := a.r - b.r
	var dg := a.g - b.g
	var db := a.b - b.b
	return sqrt(dr * dr + dg * dg + db * db) <= tol


func _luminance(c: Color) -> float:
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
