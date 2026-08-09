# tests/evidence/v31_r1_capture.gd — V3.1 返工 UI（HUD 去 CSS 仪表盘化）证据捕获
#
# 渲染真实主场景（src/main.tscn，含 V3.1 P1-P5 世界管线）并保存视口快照，
# 像素级验证 V3.1 返工 UI 门禁：
#   - HUD 顶栏 = 手绘像素面板：顶部边缘有锯齿缺口（非完美直线/非等宽
#     边框 —— V3 §15 / 附录 V3.1 负面约束），Butter accent 为断续线
#     （非整条实心描边）
#   - 底部建造条 tile = 像素平板：tile 角落区域多色 cluster（非纯色填充），
#     外缘 Butter 覆盖率低（无 CSS 卡片式等宽描边矩形）
#   - draw calls < 200（性能预算，V3 §15）
#
# 输出：
#   tests/evidence/v31-r1-ui.png          —— 渲染帧（主场景视口 1280×720）
#   tests/evidence/v31-r1-ui-hud-zoom.png —— HUD 特写（顶栏 + 底部建造条，
#                                            2× NEAREST 放大，供人工核对）
#
# 用法（窗口模式——headless 用 dummy 渲染驱动，get_image() 返回 null，
# 4.7.1 已验证；窗口捕获是项目既有证据方法）：
#   godot --path . res://tests/evidence/v31_r1_capture.tscn
#
# 采样坐标全部为屏幕空间（HUD 挂 UICanvas 1280×720，与视口像素一一对应）。
extends Node

const MAIN_SCENE := preload("res://src/main.tscn")
const OUT_PATH := "res://tests/evidence/v31-r1-ui.png"
const ZOOM_PATH := "res://tests/evidence/v31-r1-ui-hud-zoom.png"
const REDRAW_FRAME := 6      # 抓帧前强制世界画布重绘（SubViewport 纹理滞后 ≥1 帧）
const CAPTURE_FRAME := 14    # 面板淡入（0.18s ≈ 11 帧）后再抓帧

## HUD 顶栏条带（hud.gd _draw）：strip_rect = (12, 2, 1256, 48)。
## 纹理 texel 4px：texel 行 0 → 屏幕 y 2..5（锯齿边缘），texel 行 1..2 →
## 屏幕 y 6..13（Butter 断续 accent 线）。
## 注意：条带 alpha 由面板淡入调制到 PANEL_ALPHA(0.82)，屏上 Butter ≈
## Butter×0.82 叠加世界底色 → 采样容差用 0.25（vs tile 全 alpha 用 0.12）。
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
## 第一个 tile 屏幕区 x 0..88（tile 高 88 → y 632..720）。
const TILE0_X0 := 0
const TILE0_Y0 := 632
const TILE0_W := 88
const TILE0_H := 88
## tile 角落采样区（左上角 20×20 —— 平板材质 + 铆钉/磨损高光，避开图标）。
const CLUSTER_X0 := 3
const CLUSTER_Y0 := 3
const CLUSTER_W := 18
const CLUSTER_H := 18
## tile 外缘 Butter 覆盖率检查：顶缘 2px 条带（旧 CSS 卡片 = 3px 实心
## Butter 描边；新平板 = 深色 base + 锯齿缺口，无实心描边）。
const EDGE_CHECK_H := 2

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
		push_error("v31_r1_capture: get_image() returned null (headless dummy driver?)")
		get_tree().quit(1)
		return null
	return img


func _save_and_report(img: Image) -> void:
	var abs_path := ProjectSettings.globalize_path(OUT_PATH)
	var err := img.save_png(abs_path)
	if err != OK:
		push_error("v31_r1_capture: save_png failed err=%d path=%s" % [err, abs_path])
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
	# 顶栏 0..64
	for y in 64:
		for x in 1280:
			var c: Color = img.get_pixel(x, y)
			for dy in 2:
				for dx in 2:
					zoom.set_pixel(x * 2 + dx, y * 2 + dy, c)
	# 底部建造条 600..720（贴到 zoom 的 y 64..184）
	for y in 120:
		for x in 1280:
			var c: Color = img.get_pixel(x, 600 + y)
			for dy in 2:
				for dx in 2:
					zoom.set_pixel(x * 2 + dx, (64 + y) * 2 + dy, c)
	var zerr := zoom.save_png(ProjectSettings.globalize_path(ZOOM_PATH))
	_ok(zerr == OK, "ZOOM saved %s" % ZOOM_PATH)


# === HUD 像素级验证（V3.1 返工 UI 门禁） ===

## 顶栏 = 手绘像素面板：
##   - 顶部边缘（y=2..5）存在透明缺口 —— 缺口处是后面世界的亮色像素
##     （旧 StyleBoxFlat 等宽边框：整行实心，无缺口）
##   - Butter accent 线（y=6..9）存在但断续 —— 覆盖率 < 90%（非整条实线）
##   - 顶缘无实心 Butter 描边（旧 3px 边框：y=2 行 Butter 全覆盖）
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
	_ok(gaps > 2, "HUD top edge has jagged gaps (world shows through, %d px) — 非完美直线" % gaps)
	_ok(butter_top < 8, "HUD top edge has no solid Butter border (%d px) — 无等宽描边" % butter_top)

	# 2) Butter accent 断续线（y=6..9 行带，alpha 调制 → 容差 0.25）
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
	_ok(accent_found >= 20, "HUD Butter accent pixels present (%d/%d sampled) — 手绘描边存在" % [accent_found, accent_total])
	var accent_ratio := float(accent_found) / float(maxi(1, accent_total))
	_ok(accent_ratio < 0.9, "HUD Butter accent is broken/dashed (coverage %.2f < 0.90) — 非整条实线" % accent_ratio)

	# 3) 底部 tile 平板：左上角区域多色 cluster（≥3 种量化色 —— 非纯色填充）
	var colors := {}
	for y in range(CLUSTER_Y0, CLUSTER_Y0 + CLUSTER_H, 2):
		for x in range(CLUSTER_X0, CLUSTER_X0 + CLUSTER_W, 2):
			var c: Color = img.get_pixel(TILE0_X0 + x, TILE0_Y0 + y)
			if c.a < 0.1:
				continue
			var key := "%d-%d-%d" % [
				int(c.r * 16.0), int(c.g * 16.0), int(c.b * 16.0)
			]
			colors[key] = true
	_ok(colors.size() >= 3, "tile plate multi-color cluster present (%d quantized colors) — 非纯色填充" % colors.size())

	# 4) tile 外缘无实心 Butter 描边：顶缘 2px 行带 Butter 覆盖率 < 30%
	#    （旧 CSS 卡片 = 3px 实心 Butter 边框 → 覆盖率 ≈ 100%）
	var edge_butter := 0
	var edge_total := 0
	for y in EDGE_CHECK_H:
		for x in range(TILE0_X0 + 2, TILE0_X0 + TILE0_W - 2, 2):
			edge_total += 1
			if _near(img.get_pixel(x, TILE0_Y0 + y), Color("f5d97b"), 0.12):
				edge_butter += 1
	var edge_ratio := float(edge_butter) / float(maxi(1, edge_total))
	_ok(edge_ratio < 0.30, "tile outer edge has no CSS card border (Butter coverage %.2f < 0.30)" % edge_ratio)


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
