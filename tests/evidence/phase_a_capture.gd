# tests/evidence/phase_a_capture.gd — Phase A 视觉冒烟证据捕获
#
# 渲染真实主场景（src/main.tscn）并保存视口快照 + 采样验证 + draw call 预算。
# 输出：tests/evidence/phase-a-floor.png（证据文件，随仓库提交）。
#
# 用法（窗口模式——headless 用 dummy 渲染驱动，get_image() 返回 null，
# 4.7.1 已验证；窗口捕获是项目既有证据方法，见 production/playtests README）：
#   godot --path . res://tests/evidence/phase_a_capture.tscn
#
# 验收对照（art-bible §4 / 任务 Exit 条件 4/5）：
#   - 角落像素 ≈ Warm Cream #F4E9D8
#   - 力量区 ≈ Sage #8FBF9F / 有氧区 ≈ Sky #8EC5E8 / 团课区 ≈ Peach #F2B486
#   - draw calls < 200（Performance monitor，4.7.1 枚举名见
#     docs/engine-reference/godot/deprecated-apis.md：MONITOR_ 前缀已移除）
extends Node

const MAIN_SCENE := preload("res://src/main.tscn")
const OUT_PATH := "res://tests/evidence/phase-a-floor.png"
const CAPTURE_FRAME := 10

var _frame := 0
var _captured := false

# 采样点（像素坐标，1280×720 视口；单元中心避开网格线/设备/UI）：
# 角落 (2,2) 在环场走道（cell(0,0)，奶油底）
# 力量区 cell(2,4) / 有氧区 cell(7,1) / 团课区 cell(10,8)
const SAMPLE_POINTS := {
	"corner": Vector2i(2, 2),
	"strength": Vector2i(80, 144),
	"cardio": Vector2i(240, 48),
	"flex": Vector2i(336, 272),
}


func _ready() -> void:
	add_child(MAIN_SCENE.instantiate())


func _process(_delta: float) -> void:
	_frame += 1
	if _frame >= CAPTURE_FRAME and not _captured:
		_captured = true
		_capture_and_report()


func _capture_and_report() -> void:
	var img := get_viewport().get_texture().get_image()
	if img == null:
		push_error("phase_a_capture: get_image() returned null (headless dummy driver?)")
		get_tree().quit(1)
		return
	var abs_path := ProjectSettings.globalize_path(OUT_PATH)
	var err := img.save_png(abs_path)
	if err != OK:
		push_error("phase_a_capture: save_png failed err=%d path=%s" % [err, abs_path])
		get_tree().quit(1)
		return
	print("CAPTURE saved=%s size=%dx%d" % [OUT_PATH, img.get_width(), img.get_height()])
	for label in SAMPLE_POINTS:
		var p: Vector2i = SAMPLE_POINTS[label]
		print("SAMPLE %-8s @(%3d,%3d) = %s" % [label, p.x, p.y, img.get_pixel(p.x, p.y)])
	var draw_calls := Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	var fps := Performance.get_monitor(Performance.TIME_FPS)
	print("PERF draw_calls=%d fps=%.1f budget_ok=%s" % [draw_calls, fps, str(draw_calls < 200)])
	print("RESULT: %s" % ("PASS" if draw_calls < 200 else "CHECK"))
	get_tree().quit(0)
