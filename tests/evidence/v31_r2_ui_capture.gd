# tests/evidence/v31_r2_ui_capture.gd — V3.1 返工 2 UI（HUD 负面约束第二轮）证据捕获
#
# 注意：本文件是「返工 2 UI 卡」证据（命名 v31_r2_ui_* 与既有 R2 sprite 卡
# v31_r2_capture.gd 区分 —— 后者是 P2 人物/器械 sprite 证据，勿混用）。
#
# 渲染真实主场景（src/main.tscn）并保存视口快照，像素级验证 V3.1 返工 2
# 门禁（第二轮 GPT 视觉 FAIL 修复）：
#   1. 无规整矩形分区/无等宽描边 —— 顶栏条带边缘 2-3 texel 锯齿 + 缺口 +
#      边角色相微差（_edge_tone_jitter），非完美直线/非等宽边框
#   2. 无重复黄黑像素虚线纹理 —— Butter accent 改为少量散点墨迹（覆盖率
#      < 20%，且任意行无 > 60px 连续 Butter 段）—— 绝非 warning stripe
#   3. 无纯色大块 —— 条带/tile/按钮底色逐 texel 噪声，量化色数充足
#   4. 按钮 = 手绘像素小板（StyleBoxTexture + PixelPanel 金属平板），
#      非 StyleBoxFlat 规整矩形芯片
#   5. 速度/金额/状态文字可读（pixel-bold 粗体保留，不做像素级断言，
#      由结构性文字检查 + 人类核对 zoom 图）
#
# 输出：
#   tests/evidence/v31-r2-ui.png          —— 渲染帧（主场景视口 1280×720）
#   tests/evidence/v31-r2-ui-hud-zoom.png —— HUD 特写（顶栏 + 底部建造条，
#                                            2× NEAREST 放大，供人工核对）
#
# 用法（窗口模式——headless 用 dummy 渲染驱动，get_image() 返回 null，
# 4.7.1 已验证；窗口捕获是项目既有证据方法）：
#   godot --path . res://tests/evidence/v31_r2_ui_capture.tscn
#
# 采样坐标全部为屏幕空间（HUD 挂 UICanvas 1280×720，与视口像素一一对应）。
extends Node

const MAIN_SCENE := preload("res://src/main.tscn")
const OUT_PATH := "res://tests/evidence/v31-r2-ui.png"
const ZOOM_PATH := "res://tests/evidence/v31-r2-ui-hud-zoom.png"
const REDRAW_FRAME := 6      # 抓帧前强制世界画布重绘（SubViewport 纹理滞后 ≥1 帧）
const CAPTURE_FRAME := 14    # 面板淡入（0.18s ≈ 11 帧）后再抓帧

## HUD 顶栏条带（hud.gd _draw）：strip_rect = (12, 2, 1256, 48)。
## 纹理 texel 4px：texel 行 0 → 屏幕 y 2..5（锯齿边缘），texel 行 1..3 →
## 屏幕 y 6..17（Butter 散点墨迹带）。
const STRIP_TOP := 2
const STRIP_ACCENT_Y := 6
const STRIP_ACCENT_H := 4
const STRIP_X0 := 16
const STRIP_X1 := 1264
## 顶缘「无实心 Butter 边框」检查的 x 范围：排除右上角 transport 按钮
## （活动按钮的 Butter 像素轮廓是 V3 §14 合法反馈，非面板边框）。
const STRIP_EDGE_X1 := 1000
const BUTTER_TOL_ALPHA := 0.25
const BUTTER_TOL_FULL := 0.12

## 底部建造条（main.gd PALETTE_STRIP_H=88）：条带 y = 720-88 = 632..720。
const TILE0_X0 := 0
const TILE0_Y0 := 632
const TILE0_W := 88
const TILE0_H := 88

## 散点墨迹覆盖率上限：整条 accent 带内 Butter 采样占比 < 20%
## （旧全宽虚线 = 60%+；warning stripe 观感）。
const ACCENT_COVERAGE_MAX := 0.20
## 任意单行 Butter 连续段长度上限（px）：> 60px 读作虚线带/描边。
const MAX_BUTTER_RUN_PX := 60
## 纯色大块检查：条带内部区域量化颜色数下限（逐 texel 噪声 → 充足）。
const MIN_STRIP_COLORS := 24
const MIN_TILE_COLORS := 10

var _frame := 0
var _captured := false
var _main: Node = null
var _all_ok := true


func _ready() -> void:
	_main = MAIN_SCENE.instantiate()
	add_child(_main)


func _process(_delta: float) -> void:
	_frame += 1
	if _captured:
		return
	if _frame == REDRAW_FRAME:
		var canvas := _main.get_node_or_null("WorldViewport/WorldRoot/WorldCanvas")
		if canvas != null:
			canvas.queue_redraw()
		var lighting := _main.get_node_or_null("WorldViewport/WorldRoot/LightingLayer")
		if lighting != null:
			lighting.queue_redraw()
		return
	if _frame == CAPTURE_FRAME:
		_capture_and_report()


func _grab() -> Image:
	var img := get_viewport().get_texture().get_image()
	if img == null:
		push_error("v31_r2_ui_capture: get_image() returned null (headless dummy driver?)")
		get_tree().quit(1)
		return null
	return img


func _save_and_report(img: Image) -> void:
	var abs_path := ProjectSettings.globalize_path(OUT_PATH)
	var err := img.save_png(abs_path)
	if err != OK:
		push_error("v31_r2_ui_capture: save_png failed err=%d path=%s" % [err, abs_path])
		get_tree().quit(1)
		return
	print("CAPTURE saved=%s size=%dx%d" % [OUT_PATH, img.get_width(), img.get_height()])
	_save_hud_zoom(img)
	_verify_hud(img)
	_verify_perf()
	print("RESULT: %s" % ("PASS" if _all_ok else "CHECK"))
	get_tree().quit(0 if _all_ok else 1)


func _capture_and_report() -> void:
	var img := _grab()
	if img == null:
		return
	_save_and_report(img)


## HUD 特写：顶栏（y 0..64）+ 底部建造条（y 600..720）拼成一张 2× NEAREST
## 放大图，供人工核对「像素游戏 HUD，非网页仪表盘」。
func _save_hud_zoom(img: Image) -> void:
	var zoom := Image.create(1280 * 2, 184 * 2, false, Image.FORMAT_RGBA8)
	for y in 64:
		for x in 1280:
			var c: Color = img.get_pixel(x, y)
			for dy in 2:
				for dx in 2:
					zoom.set_pixel(x * 2 + dx, y * 2 + dy, c)
	for y in 120:
		for x in 1280:
			var c: Color = img.get_pixel(x, 600 + y)
			for dy in 2:
				for dx in 2:
					zoom.set_pixel(x * 2 + dx, (64 + y) * 2 + dy, c)
	var zerr := zoom.save_png(ProjectSettings.globalize_path(ZOOM_PATH))
	_ok(zerr == OK, "ZOOM saved %s" % ZOOM_PATH)


# === HUD 像素级验证（V3.1 返工 2 门禁） ===

## 1) 顶缘锯齿缺口（世界透出）—— 非完美直线
## 2) 顶缘无实心 Butter 描边
## 3) Butter accent 散点：存在但覆盖率 < 20%（非全宽虚线带）
## 4) 任意行无长 Butter 连续段（< 60px）—— 无 warning stripe
## 5) 条带内部多色 cluster（无纯色大块）
## 6) tile 内部多色 cluster + 外缘无 CSS 卡片边框
func _verify_hud(img: Image) -> void:
	# 1) 锯齿边缘：y=2 行存在「非面板色」像素（透明缺口露出世界）
	var gaps := 0
	var butter_top := 0
	for x in range(STRIP_X0, STRIP_EDGE_X1, 2):
		var c: Color = img.get_pixel(x, STRIP_TOP)
		if c.r > 0.32 and c.g > 0.30:  # 世界亮色（墙/地板），非深色面板
			gaps += 1
		if _near(c, Color("f5d97b"), BUTTER_TOL_FULL):
			butter_top += 1
	_ok(gaps > 2, "R2 HUD top edge has jagged gaps (world shows through, %d px) — 非完美直线" % gaps)
	_ok(butter_top < 8, "R2 HUD top edge has no solid Butter border (%d px) — 无等宽描边" % butter_top)

	# 3) Butter accent 散点存在 + 覆盖率 < 20%（散点墨迹，非全宽虚线带）
	var accent_total := 0
	var accent_found := 0
	for x in range(STRIP_X0, STRIP_X1, 2):
		var row_best := 0
		for dy in STRIP_ACCENT_H:
			if _near(img.get_pixel(x, STRIP_ACCENT_Y + dy), Color("f5d97b"), BUTTER_TOL_ALPHA):
				row_best = 1
				break
		accent_total += 1
		accent_found += row_best
	_ok(accent_found >= 4, "R2 HUD Butter accent flecks present (%d/%d sampled) — 手绘散点存在" % [accent_found, accent_total])
	var accent_ratio := float(accent_found) / float(maxi(1, accent_total))
	_ok(accent_ratio < ACCENT_COVERAGE_MAX,
		"R2 HUD Butter accent is sparse flecks (coverage %.2f < %.2f) — 非全宽虚线带" % [accent_ratio, ACCENT_COVERAGE_MAX])

	# 4) 任意行无长 Butter 连续段（顶栏 y 2..50 全宽扫描）
	var max_run := 0
	var max_run_y := -1
	for y in range(STRIP_TOP, 50):
		var run := 0
		for x in range(0, 1280):
			if _near(img.get_pixel(x, y), Color("f5d97b"), BUTTER_TOL_ALPHA):
				run += 1
				if run > max_run:
					max_run = run
					max_run_y = y
			else:
				run = 0
	_ok(max_run < MAX_BUTTER_RUN_PX,
		"R2 no long Butter run in top bar (max %dpx < %dpx) — 无 warning stripe/等宽描边" % [max_run, MAX_BUTTER_RUN_PX])

	# 5) 条带内部多色 cluster（无纯色大块）：条带中部 y 14..44 采样
	var strip_colors := {}
	for y in range(14, 44, 2):
		for x in range(40, 900, 2):
			var c: Color = img.get_pixel(x, y)
			if c.a < 0.1:
				continue
			var key := "%d-%d-%d" % [int(c.r * 16.0), int(c.g * 16.0), int(c.b * 16.0)]
			strip_colors[key] = true
	_ok(strip_colors.size() >= MIN_STRIP_COLORS,
		"R2 strip interior multi-color cluster (%d quantized colors >= %d) — 无纯色大块" % [strip_colors.size(), MIN_STRIP_COLORS])

	# 6) tile 内部多色 cluster + 外缘无 CSS 卡片边框
	var tile_colors := {}
	for y in range(TILE0_Y0 + 6, TILE0_Y0 + 40, 2):
		for x in range(TILE0_X0 + 6, TILE0_X0 + 40, 2):
			var c: Color = img.get_pixel(x, y)
			if c.a < 0.1:
				continue
			var key := "%d-%d-%d" % [int(c.r * 16.0), int(c.g * 16.0), int(c.b * 16.0)]
			tile_colors[key] = true
	_ok(tile_colors.size() >= MIN_TILE_COLORS,
		"R2 tile plate multi-color cluster (%d quantized colors >= %d) — 非纯色填充" % [tile_colors.size(), MIN_TILE_COLORS])
	var edge_butter := 0
	var edge_total := 0
	for y in 2:
		for x in range(TILE0_X0 + 2, TILE0_X0 + TILE0_W - 2, 2):
			edge_total += 1
			if _near(img.get_pixel(x, TILE0_Y0 + y), Color("f5d97b"), 0.12):
				edge_butter += 1
	var edge_ratio := float(edge_butter) / float(maxi(1, edge_total))
	_ok(edge_ratio < 0.30, "R2 tile outer edge has no CSS card border (Butter coverage %.2f < 0.30)" % edge_ratio)


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


func _near(a: Color, b: Color, tol: float) -> bool:
	var dr := a.r - b.r
	var dg := a.g - b.g
	var db := a.b - b.b
	return sqrt(dr * dr + dg * dg + db * db) <= tol
