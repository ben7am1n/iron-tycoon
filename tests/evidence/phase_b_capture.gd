# tests/evidence/phase_b_capture.gd — Phase B v2 视觉冒烟证据捕获
#
# 渲染真实主场景（src/main.tscn）并保存视口快照 + 采样验证 + draw call 预算。
# 输出：tests/evidence/phase-b-v2-equipment.png（证据文件，随仓库提交）。
#
# 用法（窗口模式——headless 用 dummy 渲染驱动，get_image() 返回 null，
# 4.7.1 已验证；窗口捕获是项目既有证据方法，见 Phase A capture 同款注释）：
#   godot --path . res://tests/evidence/phase_b_capture.tscn
#
# 验收对照（art-bible-25d-style §1/§2/§4 + 任务 Exit 条件 5）：
#   - 设备主色 ≈ 对应区域语义色（treadmill/bike cardio→Sky #8EC5E8、
#     bench_press strength→Sage #8FBF9F、yoga_mat flex→Peach #F2B486）
#   - 描边 ≈ Soft Charcoal #3C3A42（非纯黑）
#   - access cell ≈ Butter #F5D97B 高亮
#   - 非法放置预览 ≈ Dusty Rose #E0A0A0（柔和警示，绝不刺眼红）
#   - 设备脚下大暗面存在（阴影采样显著暗于同区域地板）
#   - draw calls < 200（Performance monitor，4.7.1 枚举名 RENDER_TOTAL_...）
#
# 采样策略：模拟暂停（非 --smoke 默认），会员不生成 → 采样点稳定不被遮挡。
# 非法预览通过直接驱动 PlacementSystem 产生：begin_drag("treadmill") 后
# on_mouse_moved(占用格 (2,5)) → preview invalid → 幽灵 Dusty Rose。
extends Node

const MAIN_SCENE := preload("res://src/main.tscn")
const OUT_PATH := "res://tests/evidence/phase-b-v2-equipment.png"
const CAPTURE_FRAME := 10

var _frame := 0
var _captured := false
var _main: Node = null
var _placement: Object = null


## 采样点（像素坐标，1280×720 视口；取自初始布局的已放置设备）：
##   - treadmill(2,2) fp (2,2),(3,2)：deck 主色 (96,80)（art row4 col8 = Z，
##     避免误采 row3 的描边）、左端描边 (66,66)
##   - access (2,3)：Butter 菱形中心 (80,112)
##   - bench_press(1,7) fp 2×2：bench pad 主色 (52,268)
##   - yoga_mat(9,2)：垫面主色 (304,80)
##   - 阴影：treadmill footprint 下方 (130,80) vs 同区域地板 (138,80)
##   - 非法幽灵：占用格 (6,3) 边框 (200,96)（拖 treadmill 到已有 treadmill 上）
const SAMPLE_POINTS := {
	"treadmill_main": {"pos": Vector2i(96, 80), "expect": Color("8EC5E8"), "tol": 0.15},
	"outline": {"pos": Vector2i(66, 66), "expect": Color("3C3A42"), "tol": 0.15},
	"access_butter": {"pos": Vector2i(80, 112), "expect": Color("F5D97B"), "tol": 0.20},
	"bench_main": {"pos": Vector2i(52, 268), "expect": Color("8FBF9F"), "tol": 0.15},
	"yoga_main": {"pos": Vector2i(304, 80), "expect": Color("F2B486"), "tol": 0.15},
	"shadow_px": {"pos": Vector2i(130, 80), "expect": null, "tol": 0.0},
	"floor_px": {"pos": Vector2i(138, 80), "expect": null, "tol": 0.0},
	# 非法幽灵描边：rect 顶边 y=96（Godot 2px stroke 以边界为中心，95..97），
	# 采样 y=96 命中 ROSE 0.9-over-Charcoal ≈ #D09696，距 #E0A0A0 约 0.085。
	"illegal_ghost": {"pos": Vector2i(200, 96), "expect": Color("E0A0A0"), "tol": 0.18},
}


func _ready() -> void:
	_main = MAIN_SCENE.instantiate()
	add_child(_main)
	# 驱动非法拖拽幽灵：拖 treadmill 到 bike 的占用格 (2,5) → preview invalid。
	# 模拟已暂停（非 --smoke），无会员生成，幽灵是当前帧唯一动态元素。
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
		var p: Vector2i = entry["pos"]
		var got := img.get_pixel(p.x, p.y)
		# Variant get：null = 纯参考采样点（阴影/地板对比用），无期望色。
		var expect_v: Variant = entry.get("expect")
		if expect_v == null:
			print("SAMPLE %-14s @(%3d,%3d) = %s (reference)" % [label, p.x, p.y, got.to_html(false)])
			continue
		var expect := expect_v as Color
		var tol: float = entry["tol"]
		var ok := _near(got, expect, tol)
		if not ok:
			all_ok = false
		print("SAMPLE %-14s @(%3d,%3d) = %s expect=%s tol=%.2f %s" % [
			label, p.x, p.y, got.to_html(false), expect.to_html(false), tol,
			"OK" if ok else "MISMATCH"
		])
	# 阴影验证：shadow_px 显著暗于 floor_px（同区域地板，shadow 为半透明深色块）
	var shadow_col := img.get_pixel(130, 80)
	var floor_col := img.get_pixel(138, 80)
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
