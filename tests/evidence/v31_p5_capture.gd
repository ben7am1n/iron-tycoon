# tests/evidence/v31_p5_capture.gd — V3.1 P5 高饱和视觉焦点证据捕获
#
# 渲染真实主场景（src/main.tscn，含 V3.1 P1 oblique 投影 + P3 手绘材质 +
# P4 pixel-based lighting + P5 高饱和焦点）并保存视口快照，像素级验证：
#   - 高饱和焦点存在且数量达标（PIL 独立复算：画面中高饱和像素簇数量
#     10-15 个，分布合理 —— 本脚本只负责导出 PNG，聚类统计在
#     v31_p5_pil_sample.py 做）
#   - 渲染帧包含 P5 焦点元素：红广告牌（FOCAL_RED）/黄水杯（ACCENT_YELLOW）
#     /设备屏幕（EQUIP_ACCENT_CYAN）/植物亮叶（PLANT_GREEN_LIGHT）
#     /彩色瑜伽用品（FOCAL_PINK/PURPLE/TEAL）
#   - draw calls < 200（性能预算，V3 §15）
#
# 输出：
#   tests/evidence/v31-p5-color.png  —— 渲染帧（主场景视口）
#
# 用法（窗口模式——headless 用 dummy 渲染驱动，get_image() 返回 null，
# 4.7.1 已验证；窗口捕获是项目既有证据方法）：
#   godot --path . res://tests/evidence/v31_p5_capture.tscn
#
# 采样换算：world_to_screen 走 src/presentation/oblique_projection.gd
# （与 main.gd 同源 —— 证据独立复算）。
extends Node

const MAIN_SCENE := preload("res://src/main.tscn")
const Main := preload("res://src/main.gd")
const Proj2D := preload("res://src/presentation/oblique_projection.gd")
const Palette := preload("res://src/palette.gd")
const WorldLayout := preload("res://src/presentation/world_layout.gd")
const OUT_PATH := "res://tests/evidence/v31-p5-color.png"
const REDRAW_FRAME := 6      # 抓帧前强制世界画布重绘（SubViewport 纹理滞后 ≥1 帧）
const CAPTURE_FRAME := 12

## 管线常量（来自 main.gd —— 证据复算与实现同源）。
const SX := Main.SCREEN_PER_VIEWPORT_X
const SY := Main.SCREEN_PER_VIEWPORT_Y
const OFF := Main.WORLD_VIEWPORT_OFFSET
const WS := Main.WORLD_SCALE

## 世界采样锚点（世界像素空间）。
## 红广告牌：WALL_DECOR.ad_red = (192,1) 挂墙，墙条坐标 fy=1 → 墙面 z≈105
## （V3.1 R1 修正投影后 HEIGHT_SCALE 0.79：墙更高，广告牌必须按墙面高度采样，
## 不能再按墙基 z=0 近似 —— 旧近似在新投影下窗口偏移出广告牌区域）。
## 采样 z 用 AD_ANCHOR_Z（墙面高度，世界 px）。
const AD_ANCHOR := Vector2(192, 24)
const AD_ANCHOR_Z := 105.0
## 黄水杯：DECOR.cup_yellow_f1 = (88,108)。
const CUP_ANCHOR := Vector2(88, 108)
## 彩色瑜伽球：DECOR.yoga_ball_f1 = (320,136)。
## V3.1 R1（投影修正）：原 (288,96) 落入 column_2 前景立柱屏幕柱影
## （x 284..308），东移到 flex 区中段可见木地板。
const YOGA_BALL_ANCHOR := Vector2(320, 136)
## treadmill(2,2) footprint = (64,64,64,32)；顶面 z=30。
const TM_RECT := Rect2i(64, 64, 64, 32)
const TM_HEIGHT := 30.0

var _frame := 0
var _captured := false
var _main: Node = null
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
		push_error("v31_p5_capture: get_image() returned null (headless dummy driver?)")
		get_tree().quit(1)
		return null
	return img


func _save_and_report(img: Image) -> void:
	var abs_path := ProjectSettings.globalize_path(OUT_PATH)
	var err := img.save_png(abs_path)
	if err != OK:
		push_error("v31_p5_capture: save_png failed err=%d path=%s" % [err, abs_path])
		get_tree().quit(1)
		return
	print("CAPTURE saved=%s size=%dx%d" % [OUT_PATH, img.get_width(), img.get_height()])
	_verify_world_frame(img)
	_verify_perf()
	print("RESULT: %s" % ("PASS" if _all_ok else "CHECK"))
	get_tree().quit(0 if _all_ok else 1)


func _capture_and_report() -> void:
	var img := _grab()
	if img == null:
		return
	_save_and_report(img)


# === 渲染帧级验证（P5 焦点元素局部存在） ===

## 渲染帧验证：
##   - 红广告牌区域存在 FOCAL_RED 高饱和红像素（渲染帧小窗口内）
##   - 黄水杯区域存在 ACCENT_YELLOW 高饱和黄像素
##   - 彩色瑜伽球区域存在 FOCAL_PINK/PURPLE 像素
##   - treadmill 控制台存在青蓝屏幕像素（EQUIP_ACCENT_CYAN/EMISSIVE_CYAN）
##   - 植物亮叶（PLANT_GREEN_LIGHT）在植物锚点附近存在（绿色焦点）
func _verify_world_frame(img: Image) -> void:
	# 红广告牌：渲染帧窗口内找 FOCAL_RED 族（含光照压暗/提亮 → 宽容差 0.22）
	# V3.1 R1：广告牌挂墙 z≈105，按墙面高度采样（旧 z=0 近似在新投影下偏移）。
	var ad_found := _window_contains(img, AD_ANCHOR, 22, Palette.FOCAL_RED, 0.22, AD_ANCHOR_Z)
	_ok(ad_found, "WORLD red ad board focal red pixels present (红广告牌焦点)")
	# 黄水杯
	var cup_found := _window_contains(img, CUP_ANCHOR, 20, Palette.ACCENT_YELLOW, 0.22)
	_ok(cup_found, "WORLD yellow cup focal yellow pixels present (黄色水杯焦点)")
	# 彩色瑜伽球（粉/紫）
	var ball_found := _window_contains(img, YOGA_BALL_ANCHOR, 22, Palette.FOCAL_PINK, 0.22) \
		or _window_contains(img, YOGA_BALL_ANCHOR, 22, Palette.FOCAL_PURPLE, 0.22)
	_ok(ball_found, "WORLD colorful yoga ball pixels present (彩色瑜伽用品焦点)")
	# treadmill 控制台青蓝屏幕
	var screen_found := false
	for dy in range(-3, 4):
		for dx in range(-3, 4):
			var p := world_to_screen(Vector2(TM_RECT.position.x + 16 + dx, TM_RECT.position.y + 28 + dy), TM_HEIGHT)
			if not _in_bounds(img, p):
				continue
			var c := img.get_pixel(p.x, p.y)
			if _near(c, Palette.EQUIP_ACCENT_CYAN, 0.16) or _near(c, Palette.EMISSIVE_CYAN, 0.16):
				screen_found = true
				break
		if screen_found:
			break
	_ok(screen_found, "WORLD treadmill console cyan screen pixels present (设备屏幕焦点)")
	# 植物亮叶（PLANT_GREEN_LIGHT —— 绿色焦点）：扫描所有 plant 装饰锚点
	var plant_found := false
	for prop_id: String in WorldLayout.DECOR:
		if not prop_id.begins_with("plant"):
			continue
		var pos: Vector2i = WorldLayout.DECOR[prop_id]
		if _window_contains(img, Vector2(pos), 26, Palette.PLANT_GREEN_LIGHT, 0.22) \
				or _window_contains(img, Vector2(pos), 26, Palette.PLANT_GREEN, 0.18):
			plant_found = true
			break
	_ok(plant_found, "WORLD plant bright-leaf green pixels present (绿色植物焦点)")


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


## 世界锚点周围窗口内是否存在接近 [color] 的像素（投影后 + 容差窗口）。
## [height_z] 采样高度（世界 px，z=0 贴地；挂墙元素按墙面高度采样）。
func _window_contains(img: Image, world_anchor: Vector2, r: int, color: Color, tol: float, height_z: float = 0.0) -> bool:
	for dy in range(-r, r + 1, 2):
		for dx in range(-r, r + 1, 2):
			var p := world_to_screen(world_anchor + Vector2(dx, dy), height_z)
			if not _in_bounds(img, p):
				continue
			var c := img.get_pixel(p.x, p.y)
			if _near(c, color, tol):
				return true
	return false


func _in_bounds(img: Image, p: Vector2i) -> bool:
	return p.x >= 0 and p.y >= 0 and p.x < img.get_width() and p.y < img.get_height()


func _near(a: Color, b: Color, tol: float) -> bool:
	var dr := a.r - b.r
	var dg := a.g - b.g
	var db := a.b - b.b
	return sqrt(dr * dr + dg * dg + db * db) <= tol
