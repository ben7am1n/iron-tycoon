# tests/evidence/v31_r1_layer_capture.gd — V3.1 R1 空间层级/物体-背景分离证据捕获
#
# 渲染真实主场景（src/main.tscn）并保存视口快照，验证 R1 核心目标：
# 「设备作为前景物体从深色地面分离」（3D diorama 空间层级）。量化信号
# （本脚本只导出 PNG + 少量内联检查；完整量化在 v31_r1_layer_pil_sample.py）：
#   - 设备贴地 contact shadow：设备底边比远处地板更暗（物体「坐」在地面上，
#     不漂浮）—— 空间层级证据
#   - 设备顶面与地面分离：顶面（区域语义色/机身亮部）与所在区域地板在
#     亮度或饱和度上有可测差异（silhouette 从背景托起）
#   - 设备脚下暖色亮池（HIGHLIGHT_WARM）：设备周边地面比远处同区地面更暖
#     （R1 新增：暖白光把深色设备轮廓从深灰橡胶地面托起）
#
# 输出：
#   tests/evidence/v31-r1-layer.png  —— 渲染帧（主场景视口）
#
# 用法（窗口模式——headless dummy 驱动下 get_image() 返回 null，项目既有
# 证据方法，见 v31_p1..p5_capture.gd）：
#   godot --path . res://tests/evidence/v31_r1_layer_capture.tscn
#
# 采样换算：world_to_screen 走 src/presentation/oblique_projection.gd
# （与 main.gd 同源 —— 证据独立复算）。
extends Node

const MAIN_SCENE := preload("res://src/main.tscn")
const Main := preload("res://src/main.gd")
const Proj2D := preload("res://src/presentation/oblique_projection.gd")
const OUT_PATH := "res://tests/evidence/v31-r1-layer.png"
const REDRAW_FRAME := 6      # 抓帧前强制世界画布重绘（SubViewport 纹理滞后 ≥1 帧）
const CAPTURE_FRAME := 12

## 管线常量（来自 main.gd —— 证据复算与实现同源）。
const SX := Main.SCREEN_PER_VIEWPORT_X
const SY := Main.SCREEN_PER_VIEWPORT_Y
const OFF := Main.WORLD_VIEWPORT_OFFSET
const WS := Main.WORLD_SCALE

## 初始布局设备（footprint 世界 px + 顶面高度，与 main.gd _initial_layout 同源）。
## V3.1 R1：yoga_mat(9,2) 西半已正确落在 column_2 前景立柱的屏幕柱影后
## （diorama 深度：前景柱遮挡背景物）—— 顶面采样取东半可见部分。
const EQUIP := [
	{"name": "treadmill_a", "fp": Rect2i(64, 64, 64, 32), "h": 30.0},
	{"name": "bike",        "fp": Rect2i(64, 160, 32, 32), "h": 36.0},
	{"name": "treadmill_b", "fp": Rect2i(192, 96, 64, 32), "h": 30.0},
	{"name": "bench",       "fp": Rect2i(32, 224, 64, 64), "h": 26.0},
	{"name": "yoga_mat",    "fp": Rect2i(312, 64, 16, 32), "h": 6.0},
]

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
		push_error("v31_r1_layer_capture: get_image() returned null (headless dummy driver?)")
		get_tree().quit(1)
		return null
	return img


func _save_and_report(img: Image) -> void:
	var abs_path := ProjectSettings.globalize_path(OUT_PATH)
	var err := img.save_png(abs_path)
	if err != OK:
		push_error("v31_r1_layer_capture: save_png failed err=%d path=%s" % [err, abs_path])
		get_tree().quit(1)
		return
	print("CAPTURE saved=%s size=%dx%d" % [OUT_PATH, img.get_width(), img.get_height()])
	_verify_world_frame(img)
	print("RESULT: %s" % ("PASS" if _all_ok else "CHECK"))
	get_tree().quit(0 if _all_ok else 1)


func _capture_and_report() -> void:
	var img := _grab()
	if img == null:
		return
	_save_and_report(img)


# === 渲染帧级验证（R1 空间层级内联检查；完整量化在 PIL 脚本） ===

## 内联检查（主场景帧）：
##   - 每台设备顶面中心存在（亮度 > 0.25：顶面不是空白）
##   - 每台设备贴地 contact shadow 存在（底边南侧 2..5px 比远处地板暗）
func _verify_world_frame(img: Image) -> void:
	for eq in EQUIP:
		var name: String = eq["name"]
		var fp: Rect2i = eq["fp"]
		var h: float = eq["h"]
		# 顶面中心存在（采样中心 8×8 窗口，取最大亮度）
		var cx := fp.position.x + fp.size.x / 2.0
		var cy := fp.position.y + fp.size.y / 2.0
		var top_seen := false
		for dy in range(-4, 5, 2):
			for dx in range(-4, 5, 2):
				var p := world_to_screen(Vector2(cx + dx, cy + dy), h)
				if not _in_bounds(img, p):
					continue
				if img.get_pixel(p.x, p.y).get_luminance() > 0.25:
					top_seen = true
		_ok(top_seen, "WORLD %s top face present (设备顶面可见)" % name)
		# contact shadow：footprint 南侧 2..5px 平均亮度 < 远处同 x 地板平均亮度
		var shadow_lum := 0.0
		var shadow_n := 0
		for dx in range(4, fp.size.x - 4, 4):
			for dy in range(2, 6, 2):
				var p := world_to_screen(Vector2(fp.position.x + dx, fp.position.y + fp.size.y + dy), 0.0)
				if not _in_bounds(img, p):
					continue
				shadow_lum += img.get_pixel(p.x, p.y).get_luminance()
				shadow_n += 1
		shadow_lum /= maxi(shadow_n, 1)
		var far_y := fp.position.y + fp.size.y + fp.size.y * 0.62 + 18.0
		var far_lum := 0.0
		var far_n := 0
		for dx in range(4, fp.size.x - 4, 4):
			for dy in range(0, 8, 4):
				var p := world_to_screen(Vector2(fp.position.x + dx, far_y + dy), 0.0)
				if not _in_bounds(img, p):
					continue
				far_lum += img.get_pixel(p.x, p.y).get_luminance()
				far_n += 1
		far_lum /= maxi(far_n, 1)
		var grounded := shadow_lum < far_lum
		_ok(grounded, "WORLD %s contact shadow grounds floor (shadow %.3f < far %.3f)"
			% [name, shadow_lum, far_lum])


# === helpers ===

func _ok(cond: bool, msg: String) -> void:
	if not cond:
		_all_ok = false
	print("  %s %s" % ["PASS" if cond else "FAIL", msg])


func _in_bounds(img: Image, p: Vector2i) -> bool:
	return p.x >= 0 and p.y >= 0 and p.x < img.get_width() and p.y < img.get_height()
