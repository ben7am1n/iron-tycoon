## GA-005 visual sample integration and verification test:
## Coach Cheng identity, broad shoulders, silver hair streak, pose changes (idle/walk/guidance),
## 4-way direction without 2D screen rotation, treadmill/yoga mat contact anchors,
## daylight/dusk/night phase lighting triptych, and viewport capture.
extends SceneTree

const Main := preload("res://src/main.gd")
const CoachLayer := preload("res://src/presentation/coach_layer.gd")
const LightingLayer := preload("res://src/presentation/lighting_layer.gd")
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
	var status := OS.execute(OS.get_executable_path(), ["--headless", "--path", path, "--script", "res://tests/integration/gym_adventure/visual_sample_test.gd"], output, true)
	var out_str := str(output)
	var regex := RegEx.create_from_string("VISUAL SAMPLE: (\\d+) passed, (\\d+) failed")
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
		print("FAIL: visual_sample process execution error: status=%d\n%s" % [status, out_str])
	return {"pass": _pass, "fail": _fail}


func _run_all() -> void:
	await _execute_test()
	print("VISUAL SAMPLE: %d passed, %d failed" % [_pass, _fail])
	quit(0 if _fail == 0 else 1)


func _clean_test_saves() -> void:
	var saves_dir := OS.get_user_data_dir().path_join("saves")
	for fname in ["ga005-visual-test.sav.json", "gym-adventure.sav.json"]:
		var p := saves_dir.path_join(fname)
		if FileAccess.file_exists(p):
			DirAccess.remove_absolute(p)


func _test_visual_contract() -> void:
	_main = Main.new()
	_main.set_community_mode(true)
	_main._save_name = "ga005-visual-test"
	var win := _tree_root()
	if win != null:
		win.add_child(_main)
	_main._save_name = "ga005-visual-test"

	# 1. 验证程教练美术身份特征（宽肩、银白挑染发、青绿夹克、脚底贴地无屏幕旋转）
	var coach_layer: CoachLayer = _main._coach_layer
	_check(coach_layer != null, "coach layer mounted on main")
	_check(coach_layer.get_shoulder_width() == 14.0, "coach has broad shoulders (14px vs 10px members)")
	_check(coach_layer.has_silver_streak(), "coach has distinctive silver hair streak")
	_check(not coach_layer.is_screen_rotated(), "coach direction does not use 2D screen space rotation")

	# 2. 验证姿态切换：待机 (idle) -> 行走 (walk) -> 指导 (guidance)
	coach_layer.update_state()
	_check(coach_layer.get_current_pose() == "idle", "initial stationary pose is idle")
	_check(coach_layer.get_current_direction() == "down", "initial direction is down")

	# 移动输入触发 walk 姿态并更新方向
	_main._orch.time_system.resume()
	_main._on_community_action("move", {"x": 1.0, "y": 0.0})
	_main._orch.time_system.process(0.1)
	coach_layer.update_state()
	_check(coach_layer.get_current_pose() == "walk", "moving coach transitions to walk pose")
	_check(coach_layer.get_current_direction() == "right", "moving right updates direction to right")

	_main._on_community_action("move", {"x": 0.0, "y": -1.0})
	_main._orch.time_system.process(0.1)
	coach_layer.update_state()
	_check(coach_layer.get_current_direction() == "up", "moving up updates direction to up")

	_main._on_community_action("move", {"x": -1.0, "y": 0.0})
	_main._orch.time_system.process(0.1)
	coach_layer.update_state()
	_check(coach_layer.get_current_direction() == "left", "moving left updates direction to left")

	_main._on_community_action("move", {"x": 0.0, "y": 0.0})
	_main._orch.time_system.process(0.1)
	coach_layer.update_state()
	_check(coach_layer.get_current_pose() == "idle", "stopping movement returns to idle pose")

	# 3. 验证两器械接触锚点 (Treadmill 与 Yoga Mat) 及全四类器械社区专用锚点
	var canvas = _main._world_canvas
	_check(canvas != null, "world canvas initialized")
	var dummy_rect := Rect2i(64, 64, 32, 64)
	var tm_anchor: Vector2 = canvas._equipment_anchor("treadmill", dummy_rect)
	var ym_anchor: Vector2 = canvas._equipment_anchor("yoga_mat", dummy_rect)
	_check(tm_anchor != Vector2.ZERO and tm_anchor.is_finite(), "treadmill contact anchor computed")
	_check(ym_anchor != Vector2.ZERO and ym_anchor.is_finite(), "yoga mat contact anchor computed")
	_check(tm_anchor != ym_anchor, "distinct contact anchor offsets per equipment geometry")

	# 3b. 验证社区 32×40 四类器械全朝向接触锚点
	for eq in ["treadmill", "bike", "bench_press", "yoga_mat"]:
		for r in [0, 90, 180, 270]:
			var c_anchor: Vector2 = canvas._community_equipment_anchor(eq, dummy_rect, r)
			_check(c_anchor.is_finite() and c_anchor != Vector2.ZERO, "community anchor finite for %s R%d" % [eq, r])

	# 3c. 验证亚格连续脚底坐标计算 (Sub-tile float coordinates)
	var m_discrete := {"cell": Vector2i(3, 4)}
	var feet_discrete: Vector2 = canvas._get_member_feet(m_discrete, Vector2i(3, 4))
	var m_continuous := {"cell": Vector2i(3, 4), "position_xy": [3.45, 4.2]}
	var feet_continuous: Vector2 = canvas._get_member_feet(m_continuous, Vector2i(3, 4))
	_check(feet_discrete != feet_continuous, "sub-tile position produces smooth continuous feet coordinates")
	_check(absf(feet_continuous.x - (3.45 * 32.0 + 16.0)) < 0.001, "feet x maps accurately from position_xy")
	_check(absf(feet_continuous.y - (4.2 * 32.0 + 32.0)) < 0.001, "feet y maps accurately from position_xy")

	# 3d. 验证连续位移朝向推断
	var f_right: bool = canvas._update_facing_continuous(999, 5.2, Vector2i(5, 5))
	var f_left: bool = canvas._update_facing_continuous(999, 5.1, Vector2i(5, 5))
	_check(!f_right, "moving right faces right (facing_left=false)")
	_check(f_left, "moving left within same cell immediately faces left (facing_left=true)")

	# 3e. 验证表现层独立上机过渡跟踪器（散客首次上机、二次换站、暂停冻结、跳tick、同设备再入场与读档恢复）
	canvas.clear_member_using_tracker()
	var test_mid := 888
	var dummy_member := {
		"member_id": test_mid,
		"state": "USING",
		"cell": Vector2i(3, 4),
		"target_equipment_instance_id": 0,
		"use_ticks_remaining": 200
	}
	_main._orch.member_sim.members.append(dummy_member)
	
	# 1) 散客首次上机：初始 ticks_in_use 必须为 0 开始平滑过渡
	var trk0: Dictionary = canvas._update_member_using_mount(test_mid, 0, dummy_member, 100)
	_check(trk0.has("ticks_in_use") and trk0.ticks_in_use == 0, "first-time using starts ticks_in_use at 0")

	# 2) 暂停冻结：相同 tick 下多次渲染，ticks_in_use 严格保持不变，不漂移
	var trk_pause: Dictionary = canvas._update_member_using_mount(test_mid, 0, dummy_member, 100)
	_check(trk_pause.ticks_in_use == 0, "ticks_in_use remains frozen during pause/same tick")

	# 3) 下一 tick：自然推进 1 tick (100 -> 101)
	var trk_next: Dictionary = canvas._update_member_using_mount(test_mid, 0, dummy_member, 101)
	_check(trk_next.ticks_in_use == 1, "advancing tick increments ticks_in_use")

	# 4) 计时器观察频率无关性：tick 从 101 跳至 104（低帧率或合帧），按差值 +3，达到 4（过渡完成）
	var trk_jump: Dictionary = canvas._update_member_using_mount(test_mid, 0, dummy_member, 104)
	_check(trk_jump.ticks_in_use == 4, "tick jump 101->104 advances ticks_in_use by dt to 4 (frequency independent)")

	# 5) 真实生命周期状态机切换（USING -> WALKING_TO -> USING 二次换站）：
	# 成员结束设备 0 训练，进入 WALKING_TO 前往设备 1，表现层清除 tracker 缓存
	canvas.erase_member_using_tracker(test_mid)
	_check(canvas.get_member_using_tracker(test_mid).is_empty(), "exiting USING clears tracker from canvas")

	# 到达设备 1，即使课程已累计训练 trained_ticks = 240，二次上机初始 ticks_in_use 仍必须为 0！
	dummy_member["target_equipment_instance_id"] = 1
	dummy_member["trained_ticks"] = 240
	var trk_switch_walk: Dictionary = canvas._update_member_using_mount(test_mid, 1, dummy_member, 108)
	_check(trk_switch_walk.device_id == 1 and trk_switch_walk.ticks_in_use == 0, "second station mount after walk resets to 0 regardless of trained_ticks")

	# 6) 同设备再入场生命周期（USING -> RESTING -> USING）：
	# 散客练完休息后再次使用同一设备 1，清空后再次进入，ticks_in_use 必须同样重置为 0
	canvas.erase_member_using_tracker(test_mid)
	var trk_reenter: Dictionary = canvas._update_member_using_mount(test_mid, 1, dummy_member, 120)
	_check(trk_reenter.device_id == 1 and trk_reenter.ticks_in_use == 0, "re-entering same device resets ticks_in_use to 0")

	# 7) 读档回退 tick 重建：模拟时钟从 120 回退到 90（读更早存档）
	var trk_rollback: Dictionary = canvas._update_member_using_mount(test_mid, 1, dummy_member, 90)
	_check(trk_rollback.last_sim_tick == 90 and trk_rollback.ticks_in_use == 999, "tick rollback 120->90 cleanly reconstructs tracker to 999")

	# 8) 真实 notify_game_loaded() 恢复即贴合：
	# 存档恢复时正在 USING 的成员被预设为 ticks_in_use = 999（恢复即贴合，避免跳变）
	var mid_restored := 889
	var dummy_restored := {
		"member_id": mid_restored,
		"state": "USING",
		"target_equipment_instance_id": 2,
		"trained_ticks": 50,
		"use_ticks_remaining": 20
	}
	_main._orch.member_sim.members.append(dummy_restored)
	canvas.notify_game_loaded()
	var trk_loaded: Dictionary = canvas.get_member_using_tracker(mid_restored)
	_check(trk_loaded.get("ticks_in_use", 0) >= 999 and trk_loaded.get("is_restored", false), "notify_game_loaded sets mid-use member to 999 restored")

	# 随后该读档成员在下次换站时走完整 WALKING_TO -> USING，新站点仍能以 0 平滑过渡
	canvas.erase_member_using_tracker(mid_restored)
	dummy_restored["target_equipment_instance_id"] = 0
	var trk_restored_next: Dictionary = canvas._update_member_using_mount(mid_restored, 0, dummy_restored, 130)
	_check(trk_restored_next.ticks_in_use == 0, "restored member next station mount starts at 0")

	# 移除测试 dummy members
	_main._orch.member_sim.members.erase(dummy_member)
	_main._orch.member_sim.members.erase(dummy_restored)
	canvas.clear_member_using_tracker()

	# 3f. 验证社区 HUD 文案本地化，绝无 scheduled/running 等程序英文
	var comm_hud = _main._community_hud
	_check(comm_hud != null, "community hud exists")
	var hud_text: String = comm_hud._details.text
	_check(!hud_text.contains("scheduled") and !hud_text.contains("running"), "hud avoids raw programmer strings")

	# 4. 验证昼 / 暮 / 夜 / 烊四时段光照切换 (Daylight / Dusk / Night / Close)
	var lighting: LightingLayer = _main._lighting
	_check(lighting != null, "lighting layer mounted on main")
	_check(lighting._phase_provider.is_valid(), "lighting layer connected to phase provider")

	# PREP: 白昼 (Daylight)
	_check(_main._day_cycle.phase == "PREP", "day starts in PREP phase (daylight)")
	_check(str(lighting._phase_provider.call()) == "PREP", "phase provider returns PREP")

	# OUTING: 傍晚 (Dusk)
	_main._on_community_action("depart", {})
	_check(_main._day_cycle.phase == "OUTING", "depart command enters OUTING phase (dusk)")
	_check(str(lighting._phase_provider.call()) == "OUTING", "phase provider returns OUTING")

	# SERVICE: 营业/夜间 (Night) 与课中指导姿态 (Guidance)
	_main._on_community_action("return_to_gym", {})
	_advance(1850)
	_check(_main._day_cycle.phase == "SERVICE", "SERVICE phase reached (night overhead lighting)")
	_check(str(lighting._phase_provider.call()) == "SERVICE", "phase provider returns SERVICE")

	# 课中出现指导请求时触发指导姿态
	var vs: Dictionary = _main._day_cycle.get_view_state()
	if not vs.get("request", {}).is_empty():
		coach_layer.update_state()
		_check(coach_layer.get_current_pose() == "guidance", "coach adopts guidance pose during member request")

	# CLOSE: 打烊 (Close)
	_advance(1800)
	_check(_main._day_cycle.phase == "CLOSE", "service completed, entered CLOSE phase")
	_check(str(lighting._phase_provider.call()) == "CLOSE", "phase provider returns CLOSE")

	# 清理
	_clean_test_saves()
	if win != null and _main.get_parent() == win:
		win.remove_child(_main)
	_main.free()


func _execute_test() -> void:
	_test_visual_contract()

	# 窗口模式下捕获昼/暮/夜三联画与教练姿态
	_main = Main.new()
	_main.set_community_mode(true)
	_main._save_name = "ga005-visual-test"
	root.add_child(_main)
	_main._save_name = "ga005-visual-test"
	await process_frame
	await process_frame

	DirAccess.make_dir_recursive_absolute(SCREENSHOT_DIR)
	# 1. 白昼准备阶段 (Daylight PREP)
	_capture_viewport(SCREENSHOT_DIR.path_join("gym-visual-daylight.png"))

	# 2. 傍晚外出阶段 (Dusk OUTING)
	_main._on_community_action("depart", {})
	await process_frame
	_capture_viewport(SCREENSHOT_DIR.path_join("gym-visual-dusk.png"))

	# 3. 夜间营业阶段 (Night SERVICE)
	_main._on_community_action("return_to_gym", {})
	_advance(1850)
	await process_frame
	_capture_viewport(SCREENSHOT_DIR.path_join("gym-visual-night.png"))

	# 4. 打烊阶段 (Close)
	_advance(1800)
	await process_frame
	_capture_viewport(SCREENSHOT_DIR.path_join("gym-visual-close.png"))

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
