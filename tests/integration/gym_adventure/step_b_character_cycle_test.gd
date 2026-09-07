# tests/integration/gym_adventure/step_b_character_cycle_test.gd
# Validates Step B character & equipment dynamic loop:
# Member mount -> treadmill workout -> coach guidance -> yoga mat stretch -> success reaction -> dismount.
extends SceneTree

const Main := preload("res://src/main.gd")
const CoachLayer := preload("res://src/presentation/coach_layer.gd")
const RUNNER_META := "gym_manager_test_runner_active"

var _pass := 0
var _fail := 0
var _main: Main = null

func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	create_timer(30.0).timeout.connect(func() -> void: quit(1))
	_run_all.call_deferred()

func _check(ok: bool, label: String) -> void:
	if ok:
		_pass += 1
		print("  PASS: " + label)
	else:
		_fail += 1
		print("  FAIL: " + label)

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
	var status := OS.execute(OS.get_executable_path(), ["--headless", "--path", path, "--script", "res://tests/integration/gym_adventure/step_b_character_cycle_test.gd"], output, true)
	var out_str := str(output)
	var regex := RegEx.create_from_string("STEP B LIFECYCLE: (\\d+) passed, (\\d+) failed")
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
		print("FAIL: step_b process execution error: status=%d\n%s" % [status, out_str])
	return {"pass": _pass, "fail": _fail}

func _run_all() -> void:
	await _execute_test()
	print("STEP B LIFECYCLE: %d passed, %d failed" % [_pass, _fail])
	quit(0 if _fail == 0 else 1)

func _execute_test() -> void:
	_main = Main.new()
	_main.set_community_mode(true)
	_main._save_name = "test-step-b-lifecycle"
	var win := _tree_root()
	if win != null:
		win.add_child(_main)
	_main._save_name = "test-step-b-lifecycle"

	# 1. Verify community character art system loaded on world canvas & coach
	_check(_main._world_canvas != null, "WorldCanvas initialized")
	_check(_main._coach_layer != null, "CoachLayer initialized")
	_check(_main._coach_layer._char_art != null, "CoachLayer has CommunityCharacterArt bound")
	_check(_main._world_canvas._community_char_art != null, "WorldCanvas has CommunityCharacterArt bound")

	# 2. Advance to SERVICE phase
	_main._on_community_action("depart", {})
	_main._on_community_action("return_to_gym", {})
	_check(_main._day_cycle.phase == "SERVICE", "Entered SERVICE phase")

	# 3. Simulate Member Entry and Mount on Treadmill
	var member_id: int = _main._orch.member_sim.spawn_visit("v1", "drop_in", "singer_aluo")
	_check(member_id >= 0 and _main._orch.member_sim.members.size() > 0, "Member spawned in gym (id=%d)" % member_id)
	
	var m: Dictionary = _main._orch.member_sim.members.back()
	m["persistent_npc_id"] = "singer_aluo"
	m["target_equipment_instance_id"] = 1
	m["state"] = "USING"
	m["use_ticks_remaining"] = 50


	# 4. Check Coach Cheng guidance & success states
	_main._coach_layer.update_state()
	_check(_main._coach_layer.get_current_pose() in ["idle", "walk", "guidance"], "Coach has valid active pose: %s" % _main._coach_layer.get_current_pose())

	# Trigger guidance
	_main._day_cycle._state.request = {"status": "waiting", "equipment_id": "treadmill"}
	_main._coach_layer.update_state()
	_check(_main._coach_layer.get_current_pose() == "guidance", "Coach transitions to 'guidance' clapping pose during member request")

	# Trigger success
	_main._day_cycle._state.request = {"status": "success", "equipment_id": "treadmill"}
	_main._coach_layer.update_state()
	_check(_main._coach_layer.get_current_pose() == "success", "Coach transitions to 'success' thumbs-up pose upon workout success")

	# 5. Member transitions to yoga mat
	var placed_insts: Array = _main._grid.get_placed_instances()
	_check(placed_insts.size() > 0, "Grid has placed equipment instances")
	var target_inst_id: int = int(placed_insts[0].instance_id)
	m["state"] = "USING"
	m["target_equipment_instance_id"] = target_inst_id
	var ctx: Dictionary = _main._world_canvas._member_ctx(m, "USING")
	_check(str(ctx.get("persistent_npc_id", "")) == "singer_aluo", "Aluo persistent_npc_id traced into drawing context")
	_check(str(ctx.get("equipment_id", "")) != "", "Equipment type correctly resolved in context (%s)" % str(ctx.get("equipment_id", "")))

	# 6. Member completion & leaving
	m["state"] = "LEAVING"
	m["leaving_reason"] = "quota_met"
	var leave_ctx: Dictionary = _main._world_canvas._member_ctx(m, "LEAVING")
	_check(str(leave_ctx.get("leaving_reason", "")) == "quota_met", "Leaving reason preserved for satisfied smile")

	# Clean up save file
	var save_p := OS.get_user_data_dir().path_join("saves/test-step-b-lifecycle.sav.json")
	if FileAccess.file_exists(save_p):
		DirAccess.remove_absolute(save_p)
