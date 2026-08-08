# tests/evidence/phase_b_capture.gd — Phase B v2 视觉冒烟证据捕获
#
# 渲染真实主场景（src/main.tscn）并保存视口快照 + 采样验证 + draw call 预算。
# 输出：tests/evidence/phase-b-v2-equipment.png（证据文件，随仓库提交）。
#
# 用法（窗口模式——headless 用 dummy 渲染驱动，get_image() 返回 null，
# 4.7.1 已验证；窗口捕获是项目既有证据方法，见 Phase A capture 同款注释）：
#   godot --path . res://tests/evidence/phase_b_capture.tscn
#
# 验收对照（V3 Phase 3 §5/§6/§11 + 任务 Exit 条件）：
#   - 设备主色 = 机器灰阶（treadmill/bike 机身 EQUIP_BODY #5D6673；区域色只做
#     accent），bench_press 长凳垫 Sage #8FBF9F、yoga_mat 垫面 Peach #F2B486
#   - 机器轮廓 ≈ EQUIP_OUTLINE #3B4552（§11 深蓝灰轮廓，非纯黑）
#   - access cell ≈ Butter #F5D97B 高亮
#   - 非法放置预览 ≈ Dusty Rose #E0A0A0（柔和警示，绝不刺眼红）
#   - 设备脚下 contact shadow 存在（阴影采样显著暗于同区域地板，§6）
#   - draw calls < 200（Performance monitor，4.7.1 枚举名 RENDER_TOTAL_...）
#
# 采样策略：模拟暂停（非 --smoke 默认），会员不生成 → 采样点稳定不被遮挡。
# 非法预览通过直接驱动 PlacementSystem 产生：begin_drag("treadmill") 后
# on_mouse_moved(占用格 (6,3)) → preview invalid → 幽灵 Dusty Rose。
# 世界→屏幕换算用 main.gd 的管线常量独立复算（与 phase1/phase3 同款）。
extends Node

const MAIN_SCENE := preload("res://src/main.tscn")
const Main := preload("res://src/main.gd")  # V3 §2 管线常量（单一来源）
const OUT_PATH := "res://tests/evidence/phase-b-v2-equipment.png"
const CAPTURE_FRAME := 10

## 管线常量（来自 main.gd —— 证据复算与实现同源；Phase 1 起世界在
## 426×240 SubViewport 内 0.75 缩放，采样必须先做 world→screen 换算）。
const SX := Main.SCREEN_PER_VIEWPORT_X
const SY := Main.SCREEN_PER_VIEWPORT_Y
const OFF := Main.WORLD_VIEWPORT_OFFSET
const WS := Main.WORLD_SCALE

var _frame := 0
var _captured := false
var _main: Node = null
var _placement: Object = null


## 世界坐标 → 屏幕坐标（V3 §2 管线换算，独立于 main.gd 实现复算）。
func world_to_screen(w: Vector2) -> Vector2i:
	var v := (w * WS + OFF) * Vector2(SX, SY)
	return Vector2i(roundi(v.x), roundi(v.y))


## 采样点（世界坐标 → 屏幕换算；取自初始布局的已放置设备，V3 Phase 3）：
##   - treadmill(2,2) fp (2,2),(3,2)：机身中调 world(96,80)（机器灰阶
##     #5D6673，belt 区）、左端轮廓 world(68,66)（EQUIP_OUTLINE #3B4552，
##     art col2 左缘）
##   - access (2,3)：Butter 菱形中心 world(80,112)
##   - bench_press(1,7) fp 2×2：bench pad 主色 world(64,268)（Sage #8FBF9F，
##     16×16 art 下 pad 居 world x 60..70，取 64）
##   - yoga_mat(9,2)：垫面主色 world(304,80)（Peach #F2B486）
##   - 阴影：treadmill footprint 右下 world(130,80) vs 同区域地板 world(138,80)
##   - 非法幽灵：占用格 (6,3) 边框 world(200,96)（拖 treadmill 到已有
##     treadmill 上；rect 顶边 y=96，ROSE 0.9-over-Charcoal ≈ #D19899）
const SAMPLE_POINTS := {
	"treadmill_main": {"pos": Vector2(96, 80), "expect": Color("5D6673"), "tol": 0.15},
	"outline": {"pos": Vector2(68, 66), "expect": Color("3B4552"), "tol": 0.15},
	"access_butter": {"pos": Vector2(80, 112), "expect": Color("F5D97B"), "tol": 0.20},
	"bench_main": {"pos": Vector2(64, 268), "expect": Color("8FBF9F"), "tol": 0.15},
	"yoga_main": {"pos": Vector2(304, 80), "expect": Color("F2B486"), "tol": 0.15},
	"shadow_px": {"pos": Vector2(130, 80), "expect": null, "tol": 0.0},
	"floor_px": {"pos": Vector2(138, 80), "expect": null, "tol": 0.0},
	# 非法幽灵描边：rect 顶边 y=96（Godot 2px stroke 以边界为中心，95..97）。
	# Phase 5 光照层会在幽灵 console 处叠加 emissive 辉光（采样点若落在屏幕
	# 位置会被污染），改采左上角内侧 stroke (193,97) ≈ ROSE 0.9-over-Charcoal
	# #D69A9B，距 #E0A0A0 约 0.05。
	"illegal_ghost": {"pos": Vector2(193, 97), "expect": Color("E0A0A0"), "tol": 0.18},
}


func _ready() -> void:
	_main = MAIN_SCENE.instantiate()
	add_child(_main)
	# 驱动非法拖拽幽灵：拖 treadmill 到已有 treadmill 的占用格 (6,3) →
	# preview invalid。模拟已暂停（非 --smoke），无会员生成，幽灵是当前帧
	# 唯一动态元素。
	_placement = _main.get("_orch").placement_system


func _process(_delta: float) -> void:
	_frame += 1
	if _captured:
		return
	if _frame == CAPTURE_FRAME:
		# 第 CAPTURE_FRAME 帧开始拖拽，让幽灵在下一帧渲染。
		# 拖到已有 treadmill(6,3) 上 → preview invalid → 非法幽灵；
		# bike(2,5) 保持可见，证据图里 4 种设备剪影 + 非法预览同框。
		_placement.begin_drag("treadmill")
		_placement.on_mouse_moved(Vector2i(6, 3))
		return
	if _frame == CAPTURE_FRAME + 1:
		_captured = true
		_capture_and_report()


func _capture_and_report() -> void:
	var img := get_viewport().get_texture().get_image()
	if img == null:
		push_error("phase_b_capture: get_image() returned null (headless dummy driver?)")
		get_tree().quit(1)
		return
	var abs_path := ProjectSettings.globalize_path(OUT_PATH)
	var err := img.save_png(abs_path)
	if err != OK:
		push_error("phase_b_capture: save_png failed err=%d path=%s" % [err, abs_path])
		get_tree().quit(1)
		return
	print("CAPTURE saved=%s size=%dx%d" % [OUT_PATH, img.get_width(), img.get_height()])
	var all_ok := true
	for label in SAMPLE_POINTS:
		var entry: Dictionary = SAMPLE_POINTS[label]
		var w: Vector2 = entry["pos"]
		var p: Vector2i = world_to_screen(w)
		var got := img.get_pixel(p.x, p.y)
		# Variant get：null = 纯参考采样点（阴影/地板对比用），无期望色。
		var expect_v: Variant = entry.get("expect")
		if expect_v == null:
			print("SAMPLE %-14s world%s -> screen(%3d,%3d) = %s (reference)" % [label, str(w), p.x, p.y, got.to_html(false)])
			continue
		var expect := expect_v as Color
		var tol: float = entry["tol"]
		var ok := _near(got, expect, tol)
		if not ok:
			all_ok = false
		print("SAMPLE %-14s world%s -> screen(%3d,%3d) = %s expect=%s tol=%.2f %s" % [
			label, str(w), p.x, p.y, got.to_html(false), expect.to_html(false), tol,
			"OK" if ok else "MISMATCH"
		])
	# 阴影验证：shadow_px 显著暗于 floor_px（同区域地板，shadow 为半透明深色块）
	var shadow_p := world_to_screen(SAMPLE_POINTS["shadow_px"]["pos"])
	var floor_p := world_to_screen(SAMPLE_POINTS["floor_px"]["pos"])
	var shadow_col := img.get_pixel(shadow_p.x, shadow_p.y)
	var floor_col := img.get_pixel(floor_p.x, floor_p.y)
	var shadow_ok := _luminance(shadow_col) < _luminance(floor_col) - 0.04
	if not shadow_ok:
		all_ok = false
	print("SHADOW  shadow=%s floor=%s lum(%.3f < %.3f) %s" % [
		shadow_col.to_html(false), floor_col.to_html(false),
		_luminance(shadow_col), _luminance(floor_col),
		"OK" if shadow_ok else "WEAK"
	])
	var draw_calls := Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	var fps := Performance.get_monitor(Performance.TIME_FPS)
	var perf_ok := draw_calls < 200
	if not perf_ok:
		all_ok = false
	print("PERF draw_calls=%d fps=%.1f budget_ok=%s" % [draw_calls, fps, str(perf_ok)])
	print("RESULT: %s" % ("PASS" if all_ok else "CHECK"))
	get_tree().quit(0 if all_ok else 1)


func _near(a: Color, b: Color, tol: float) -> bool:
	var dr := a.r - b.r
	var dg := a.g - b.g
	var db := a.b - b.b
	return sqrt(dr * dr + dg * dg + db * db) <= tol


func _luminance(c: Color) -> float:
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
