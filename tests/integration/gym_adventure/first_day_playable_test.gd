## GA-004 first playable integration test exercising full community day controls,
## HUD signals, scene visibility, building toggle, park pacing, class guidance,
## and isolated save/load roundtripping.
extends SceneTree

const Main := preload("res://src/main.gd")
const RUNNER_META := "gym_manager_test_runner_active"
const SCREENSHOT_DIR := "production/qa/evidence"

var _pass := 0
var _fail := 0
var _main: Main


func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	create_timer(30.0).timeout.connect(func() -> void: quit(1))
	_run_all.call_deferred()


func _check(ok: bool, label: String) -> void:
	if ok:
		_pass += 1
	else:
		_fail += 1
		print("FAIL: " + label)


func _advance(ticks: int) -> void:
	for index in ticks:
		_main._orch.time_system.process(0.1)


func _run_all() -> void:
	await _execute_test()
	print("FIRST DAY PLAYABLE: %d passed, %d failed" % [_pass, _fail])
	quit(0 if _fail == 0 else 1)


func _tree_root() -> Window:
	if root != null:
		return root
	var loop = Engine.get_main_loop()
	if loop is SceneTree:
		return loop.root
	return null


func run_all() -> Dictionary:
	var output: Array = []
	var path := ProjectSettings.globalize_path("res://")
	var status := OS.execute(OS.get_executable_path(), ["--headless", "--path", path, "--script", "res://tests/integration/gym_adventure/first_day_playable_test.gd"], output, true)
	var out_str := str(output)
	var regex := RegEx.create_from_string("FIRST DAY PLAYABLE: (\\d+) passed, (\\d+) failed")
	var m := regex.search(out_str)
	if m != null:
		var p := int(m.get_string(1))
		var f := int(m.get_string(2))
		if status == 0 and f == 0:
			_pass = p
			_fail = 0
		else:
			_pass = p
			_fail = f if f > 0 else 1
			print(out_str)
	else:
		_fail += 1
		print("FAIL: first_day_playable process execution error: status=%d\n%s" % [status, out_str])
	return {"pass": _pass, "fail": _fail}


func _test_headless_contract() -> void:
	_main = Main.new()
	_main.set_community_mode(true)
	_main._save_name = "ga004-test-save"
	var win := _tree_root()
	if win != null:
		win.add_child(_main)
	_main._save_name = "ga004-test-save"

	# 1. 验证启动与社区模式装配
	_check(_main._community_mode, "community mode enabled on main")
	_check(_main._day_cycle != null, "day_cycle initialized")
	_check(_main._community_hud != null and _main._community_hud.visible, "community HUD visible")
	_check(_main._hud != null and not _main._hud.visible, "standard HUD hidden in community mode")
	_check(_main._goal_tracker != null and not _main._goal_tracker.visible, "goal tracker hidden in community mode")
	_check(_main._palette != null and not _main._palette.visible, "palette hidden initially until building toggled")
	_check(_main._save_entry != null and _main._save_name == "ga004-test-save", "save entry configured with community slot")
	_check(_main._grid.get_placed_instances().size() == 2, "two starter loan fixtures present")

	var vs: Dictionary = _main._day_cycle.get_view_state()
	_check(vs.phase == "PREP" and vs.balance == 280, "initial PREP state and 280 starting cash")

	# 2. 验证 PREP 移动与布置切换
	var coach_init: Array = vs.coach.position.duplicate()
	_main._orch.time_system.resume()
	_main._on_community_action("move", {"x": 1.0, "y": 0.0})
	_main._orch.time_system.process(0.1)
	var coach_moved: Array = _main._day_cycle.get_view_state().coach.position
	_check(coach_moved[0] > coach_init[0], "coach moves right on player input in PREP")
	_main._on_community_action("move", {"x": 0.0, "y": 0.0})
	_main._orch.time_system.pause()

	_main._on_community_action("toggle_build", {})
	_check(_main._is_building and _main._palette.visible, "toggle_build reveals palette in PREP")
	_main._palette.on_tile_mouse_down("bike")
	_main._orch.placement_system.on_mouse_moved(Vector2i(3, 7))
	_main._orch.placement_system.on_drop()
	_check(_main._grid.get_placed_instances().size() == 3, "additional fixture purchased and placed in PREP")
	_check(_main._econ.balance == 60, "economy charged 220 for bike (280 - 220 = 60)")

	# 保护测试：借用设备 0 和 1 不能出售
	_main._orch.selection_system.select(0)
	_main._orch.selection_system.sell_selected()
	_check(_main._grid.get_placed_instances().size() == 3, "borrowed fixture 0 cannot be sold")

	# 恢复基础布局：购买设备放入收纳，借用设备保留
	_main._on_community_action("restore_layout", {})
	_check(_main._grid.get_placed_instances().size() == 2, "layout restored to 2 loan fixtures")
	_check(_main._day_cycle.get_view_state().stored_count == 1, "purchased bike placed in stored inventory")

	_main._on_community_action("toggle_build", {})
	_check(not _main._is_building and not _main._palette.visible, "toggle_build closes palette")

	# 3. 验证进入 OUTING 阶段与公园视图
	_main._on_community_action("depart", {})
	vs = _main._day_cycle.get_view_state()
	_check(vs.phase == "OUTING", "depart command transitions to OUTING")
	_check(_main._park_view != null and _main._park_view.visible, "park view visible during OUTING")
	_check(_main._world_canvas != null and not _main._world_canvas.visible, "world canvas hidden during OUTING")
	_check(_main._coach_layer != null and not _main._coach_layer.visible, "gym coach layer hidden during OUTING")

	# 外出期间布置被禁用
	_main._on_community_action("toggle_build", {})
	_check(not _main._is_building, "building unavailable during OUTING")

	# 与阿洛交谈
	_main._on_community_action("interact", {})
	vs = _main._day_cycle.get_view_state()
	_check(vs.story.events.has("aluo_met"), "interacting in park records aluo_met event")

	# 开始正式挑战与配速控制
	_main._on_community_action("start_challenge", {})
	vs = _main._day_cycle.get_view_state()
	_check(vs.outing.active, "challenge active after start_challenge")

	_main._on_community_action("set_pace", {"pace": "jog"})
	_check(_main._day_cycle.get_view_state().outing.pace == "jog", "set_pace changes pace to jog")
	_main._on_community_action("set_pace", {"pace": "sprint"})
	_check(_main._day_cycle.get_view_state().outing.pace == "sprint", "set_pace changes pace to sprint")

	# 沿公园路径前进
	_main._on_community_action("move", {"x": 1.0, "y": 0.0})
	_advance(30)
	_main._on_community_action("move", {"x": 0.0, "y": 0.0})
	vs = _main._day_cycle.get_view_state()
	_check(vs.outing.progress_m > 0, "coach advances along park route")

	# 结束挑战并返回健身房
	_main._on_community_action("finish_challenge", {})
	_check(not _main._day_cycle.get_view_state().outing.active, "challenge finished")
	_main._on_community_action("return_to_gym", {})
	vs = _main._day_cycle.get_view_state()
	_check(vs.phase == "SERVICE", "return_to_gym enters SERVICE phase")
	_check(_main._park_view != null and not _main._park_view.visible, "park view hidden in SERVICE")
	_check(_main._world_canvas != null and _main._world_canvas.visible, "world canvas visible in SERVICE")
	_check(_main._coach_layer != null and _main._coach_layer.visible, "coach layer visible in SERVICE")

	# 4. 验证 SERVICE 阶段课程、指导与营业结束
	_main._on_community_action("toggle_build", {})
	_check(not _main._is_building, "building unavailable during SERVICE")

	# 推进时间至会员到馆 (150s = 1500 ticks) 与开班 (180s = 1800 ticks)
	_advance(1850)
	vs = _main._day_cycle.get_view_state()
	_check(vs.course.status == "running", "course running on real equipment")
	_check(vs.course.members.size() == 4, "four members participating in course")

	# 指导选择与节奏确认
	_main._on_community_action("choose_guidance", {"choice": "maintain"})
	_main._on_community_action("confirm_timing", {})

	# 推进至打烊 (360s = 3600 ticks)
	_advance(1800)
	vs = _main._day_cycle.get_view_state()
	_check(vs.phase == "CLOSE", "service completes and transitions to CLOSE")
	_check(vs.course.status == "completed", "course completed successfully")

	# 5. 验证 CLOSE 结算对话与存读档独立性
	_main._on_community_action("interact", {})
	vs = _main._day_cycle.get_view_state()
	_check(not vs.story.closing_text.is_empty(), "closing dialogue retrieved")

	# 保存到社区故事专属存档
	var saved: bool = _main.save_game()
	_check(saved, "synchronous save in community mode succeeds")

	var balance_before: int = _main._econ.balance
	_main._econ.credit(99, "test_drift")
	var loaded: bool = _main.load_game()
	_check(loaded, "synchronous load in community mode succeeds")
	_check(_main._orch.time_system.is_paused(), "restored game is paused")
	_check(_main._econ.balance == balance_before, "restored economy balance matches save point")
	_check(_main._day_cycle.get_view_state().phase == "CLOSE", "restored phase matches save point")

	# 跨模式隔离测试：用沙盒加载器加载社区存档应被拒绝
	var sandbox_save := SaveLoad.new()
	sandbox_save.init(_main._orch)
	sandbox_save.set("_day_cycle", null)
	var snapshot := PackedByteArray()
	snapshot.resize(130)
	snapshot.fill(1)
	var reject_result: Variant = sandbox_save.load_save("ga004-test-save", snapshot)
	_check(not reject_result.ok, "sandbox mode cleanly rejects community save blob")

	# 进入第二天
	_main._on_community_action("next_day", {})
	vs = _main._day_cycle.get_view_state()
	_check(vs.phase == "PREP" and vs.day == 2, "next_day advances to Day 2 PREP")

	# 清理测试存档与节点
	_clean_test_saves()
	if win != null and _main.get_parent() == win:
		win.remove_child(_main)
	_main.free()


func _clean_test_saves() -> void:
	var saves_dir := OS.get_user_data_dir().path_join("saves")
	for fname in ["ga004-test-save.sav.json", "gym-adventure.sav.json"]:
		var p := saves_dir.path_join(fname)
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)


func _execute_test() -> void:
	_test_headless_contract()
	# Scene tree frame integration & screenshot capture
	_main = Main.new()
	_main.set_community_mode(true)
	_main._save_name = "ga004-test-save"
	root.add_child(_main)
	_main._save_name = "ga004-test-save"
	await process_frame
	await process_frame

	DirAccess.make_dir_recursive_absolute(SCREENSHOT_DIR)
	_capture_viewport(SCREENSHOT_DIR.path_join("gym-adventure-prep.png"))

	_main._on_community_action("depart", {})
	await process_frame
	_capture_viewport(SCREENSHOT_DIR.path_join("gym-adventure-park.png"))

	_main._on_community_action("return_to_gym", {})
	_advance(1900)
	await process_frame
	_capture_viewport(SCREENSHOT_DIR.path_join("gym-adventure-service.png"))

	_advance(1800)
	await process_frame
	_capture_viewport(SCREENSHOT_DIR.path_join("gym-adventure-close.png"))

	if root != null and _main.get_parent() == root:
		root.remove_child(_main)
	_main.free()
	_clean_test_saves()
	await process_frame


func _capture_viewport(filepath: String) -> void:
	if DisplayServer.get_name() == "headless":
		return
	var viewport := root.get_viewport()
	if viewport == null:
		return
	var tex := viewport.get_texture()
	if tex == null:
		return
	var img := tex.get_image()
	if img != null and not img.is_empty():
		img.save_png(filepath)
