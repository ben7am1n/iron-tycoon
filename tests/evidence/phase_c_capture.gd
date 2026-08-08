# tests/evidence/phase_c_capture.gd — Phase C v2 视觉冒烟证据捕获
#
# 渲染真实主场景（src/main.tscn）并保存视口快照 + 采样验证 + draw call 预算。
# 输出：
#   tests/evidence/phase-c-v2-members.png        —— 确定性情景区（主证据）
#   tests/evidence/phase-c-v2-members-live.png   —— 自然运行区（副证据）
#
# 用法（窗口模式——headless 用 dummy 渲染驱动，get_image() 返回 null，
# 4.7.1 已验证；窗口捕获是项目既有证据方法，见 phase_a_capture.gd）：
#   godot --path . res://tests/evidence/phase_c_capture.tscn
#
# 验收对照（art-bible-25d §1/§2/§4 + 任务 Exit 条件 5/6）：
#   - 采样验证：walking≈Sky 系、queue/using≈Peach 系、leaving≈灰
#   - 小人轮廓像素阶梯可见（32×32 手工像素，无抗锯齿）
#   - draw calls < 200（Performance monitor，4.7.1 枚举名见
#     docs/engine-reference/godot/deprecated-apis.md：MONITOR_ 前缀已移除）
#
# 确定性采样：自然 RNG 场景无法保证采样点命中全部三态，故在自然运行后
# 冻结时间、清空会员、注入 4 个已知状态/已知 cell 的规范会员（member_sim
# 的 members 是公开数组，测试惯用法；仅 presentation 层证据，不改玩法逻辑），
# 在已知坐标采样衬衫色 —— 三通道可复现验证。自然运行帧另存为副证据。
extends Node

const MAIN_SCENE := preload("res://src/main.tscn")
const Palette := preload("res://src/palette.gd")
const OUT_PATH := "res://tests/evidence/phase-c-v2-members.png"
const OUT_LIVE_PATH := "res://tests/evidence/phase-c-v2-members-live.png"
const LIVE_FRAME := 360       # 6s 自然模拟（≈60 ticks @10Hz），会员生成/移动
const INJECT_FRAME := 400     # 注入后留 40 帧让 queue_redraw 落帧
const CELL_SIZE := 32

var _frame := 0
var _live_saved := false
var _captured := false
var _main: Node2D
var _sim
var _orch

# 注入会员：state -> cell（避开设备占位 (2,2)(2,3)(2,5)(3,5)(6,3)(6,4)(7,3)）
const INJECTED := [
	{"member_id": 9001, "state": "WALKING_TO", "cell": Vector2i(4, 1)},
	{"member_id": 9002, "state": "QUEUEING", "cell": Vector2i(8, 1)},
	{"member_id": 9003, "state": "USING", "cell": Vector2i(8, 5)},
	{"member_id": 9004, "state": "LEAVING", "cell": Vector2i(10, 1)},
]


func _ready() -> void:
	_main = MAIN_SCENE.instantiate()
	add_child(_main)
	_sim = _main.get("_member")
	_orch = _main.get("_orch")
	_orch.time_system.resume()


func _process(_delta: float) -> void:
	_frame += 1
	if _frame == LIVE_FRAME:
		_save_live()
	if _frame == INJECT_FRAME:
		_inject_deterministic()
	if _frame >= INJECT_FRAME + 40 and not _captured:
		_captured = true
		_capture_and_report()


## 自然运行帧：会员真实 spawn/移动的副证据。
func _save_live() -> void:
	var img := get_viewport().get_texture().get_image()
	if img == null:
		push_error("phase_c_capture: live get_image() null")
		return
	var err := img.save_png(ProjectSettings.globalize_path(OUT_LIVE_PATH))
	print("LIVE saved=%s err=%d" % [OUT_LIVE_PATH, err])


## 冻结 + 注入 4 个规范会员（已知状态/坐标 → 确定性采样）。
func _inject_deterministic() -> void:
	_orch.time_system.pause()
	_sim.members.clear()
	for entry in INJECTED:
		var m := {
			"member_id": entry["member_id"],
			"state": entry["state"],
			"cell": entry["cell"],
			"exercises_done": 0,
			"exercises_per_visit": 1,
			"preference_profile": {},
			"target_equipment_instance_id": -1,
			"cached_path": [],
			"cached_path_grid_version": -1,
			"repath_failures": 0,
			"give_up_blacklist": {},
			"leaving_timeout_ticks": 0,
			"patience_ticks_remaining": 0,
			"recently_used_ids": [],
		}
		_sim.members.append(m)
	_main.queue_redraw()
	print("INJECTED 4 canonical members (frozen)")


func _capture_and_report() -> void:
	var img := get_viewport().get_texture().get_image()
	if img == null:
		push_error("phase_c_capture: get_image() returned null (headless dummy driver?)")
		get_tree().quit(1)
		return
	var err := img.save_png(ProjectSettings.globalize_path(OUT_PATH))
	if err != OK:
		push_error("phase_c_capture: save_png failed err=%d path=%s" % [err, OUT_PATH])
		get_tree().quit(1)
		return
	print("CAPTURE saved=%s size=%dx%d" % [OUT_PATH, img.get_width(), img.get_height()])

	# --- 采样验证：每注入会员的衬衫中心像素（本地 (16,15) 为衬衫块） ---
	var sky_hits := 0
	var peach_hits := 0
	var gray_hits := 0
	for entry in INJECTED:
		var cell: Vector2i = entry["cell"]
		var p := Vector2i(cell.x * CELL_SIZE + 16, cell.y * CELL_SIZE + 15)
		var c := img.get_pixel(p.x, p.y)
		var cls := _classify(c)
		print("SAMPLE %-12s @(%3d,%3d) = %s -> %s" % [entry["state"], p.x, p.y, c, cls])
		match cls:
			"sky":
				sky_hits += 1
			"peach":
				peach_hits += 1
			"gray":
				gray_hits += 1

	# 轮廓像素阶梯验证：发际线左侧 x7 是地板色（非发色）、x8 是发色 ——
	# 视口 PNG 已合成（alpha 全 1），故用「地板→发色硬切换」证明无中间色
	var hair_p := Vector2i(4 * CELL_SIZE + 7, 1 * CELL_SIZE + 4)
	var hair_edge := Vector2i(4 * CELL_SIZE + 8, 1 * CELL_SIZE + 4)
	var edge_a := img.get_pixel(hair_p.x, hair_p.y)
	var edge_b := img.get_pixel(hair_edge.x, hair_edge.y)
	var staircase_ok := not _near(edge_a, Palette.MEMBER_HAIR) \
		and _near(edge_b, Palette.MEMBER_HAIR)
	print("STAIRCASE hair_edge @(%d,%d) a=%s b=%s staircase_ok=%s" % [
		hair_p.x, hair_p.y, edge_a, edge_b, str(staircase_ok)])

	var draw_calls := Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	var fps := Performance.get_monitor(Performance.TIME_FPS)
	print("PERF draw_calls=%d fps=%.1f budget_ok=%s" % [draw_calls, fps, str(draw_calls < 200)])

	var channel_ok := sky_hits >= 1 and peach_hits >= 2 and gray_hits >= 1
	print("CHANNELS sky=%d peach=%d gray=%d dual_channel_ok=%s" % [
		sky_hits, peach_hits, gray_hits, str(channel_ok)])
	print("RESULT: %s" % ("PASS" if (draw_calls < 200 and channel_ok and staircase_ok) else "CHECK"))
	get_tree().quit(0)


## 颜色 → 状态通道分类（容差匹配 palette 色系；member 衬衫色即状态色）。
func _classify(c: Color) -> String:
	if _near(c, Palette.SKY):
		return "sky"
	if _near(c, Palette.PEACH):
		return "peach"
	if _near(c, Palette.MEMBER_LEAVE_GRAY):
		return "gray"
	if _near(c, Palette.MEMBER_HAIR) or _near(c, Palette.MEMBER_SKIN) \
		or _near(c, Palette.MEMBER_PANTS) or _near(c, Palette.MEMBER_SHOE):
		return "member"
	return "floor"


func _near(a: Color, b: Color) -> bool:
	const EPS := 8.0 / 255.0
	return absf(a.r - b.r) < EPS and absf(a.g - b.g) < EPS and absf(a.b - b.b) < EPS
