# tests/unit/art_assets/feedback_sequence_test.gd
# Validates 2-3s key expressive success feedback sequence:
# Coach Cheng clapping rhythm -> Aluo panting to smile -> Lao Qiu nod of approval.
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"
const DayCycleScript := preload("res://src/systems/day_cycle_system.gd")
const CoachLayerScript := preload("res://src/presentation/coach_layer.gd")
const CommunityCharacterArtScript := preload("res://src/presentation/community_character_art.gd")
const CommunityHudScript := preload("res://src/ui/community_hud.gd")

var _pass := 0
var _fail := 0

func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	var result := run_all()
	quit(1 if int(result["fail"]) > 0 else 0)

func run_all() -> Dictionary:
	print("=".repeat(56))
	print("  UNIT TEST: Feedback Sequence & Expressive Performance")
	print("=".repeat(56))
	_test_lao_qiu_nod_portrait()
	_test_day_cycle_feedback_sequence()
	_test_coach_layer_feedback_poses()
	_test_community_character_art_feedback_textures()
	_test_community_hud_feedback_expansion()
	print("\n=== FEEDBACK SEQUENCE TEST: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}

func _check(condition: bool, message: String) -> void:
	if condition:
		_pass += 1
		print("  PASS: %s" % message)
	else:
		_fail += 1
		print("  FAIL: %s" % message)

func _test_lao_qiu_nod_portrait() -> void:
	print("\n[Lao Qiu Nod Portrait] existence and specs")
	var path := "res://assets/sprites/portraits/portrait_qiu_nod.png"
	_check(FileAccess.file_exists(path), "portrait_qiu_nod.png exists on disk")
	var img := Image.new()
	var err := img.load(path)
	_check(err == OK, "portrait_qiu_nod.png loads successfully")
	_check(img.get_width() == 48 and img.get_height() == 48, "portrait_qiu_nod.png is 48x48 (got %dx%d)" % [img.get_width(), img.get_height()])

func _test_day_cycle_feedback_sequence() -> void:
	print("\n[DayCycleSystem] feedback sequence state and lifecycle")
	var main: Node = load("res://src/main.gd").new()
	var checked: Dictionary = load("res://src/bootstrap/resource_preflight.gd").check()
	main.set("_catalog", checked.catalog)
	main.set("_preflight_data", checked.data)
	main.call("_assemble_systems")
	var orch = main.get("_orch")
	orch._ready()
	var day = DayCycleScript.new()
	var config: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/gym_adventure.json"))
	var fixture: Dictionary = JSON.parse_string(FileAccess.get_file_as_string("res://data/gym_adventure_fixture.json"))
	day.init(config, fixture, orch)

	var vs: Dictionary = day.get_view_state()
	_check(vs.has("feedback_sequence"), "view_state contains feedback_sequence key")
	_check(not bool(vs.feedback_sequence.get("active", false)), "feedback_sequence is initially inactive")

	# Test triggering sequence
	var signal_fired := [false]
	day.feedback_sequence_started.connect(func(_seq: Dictionary) -> void: signal_fired[0] = true)
	day.trigger_feedback_sequence(0, "singer_aluo", 100)
	_check(signal_fired[0], "feedback_sequence_started signal emitted on trigger")

	vs = day.get_view_state()
	_check(bool(vs.feedback_sequence.get("active", false)), "feedback_sequence becomes active")
	_check(float(vs.feedback_sequence.get("duration", 0.0)) == 2.5, "feedback_sequence duration is 2.5s")
	_check(int(vs.feedback_sequence.get("score", 0)) == 100, "feedback_sequence score is 100")

	# Test elapsed time advance in tick_end
	day.tick_end()
	vs = day.get_view_state()
	_check(float(vs.feedback_sequence.get("elapsed", 0.0)) > 0.0, "elapsed time advances in tick_end")

	# Advance 30 ticks (3.0s > 2.5s) to complete sequence
	for i in 30:
		day.tick_end()
	vs = day.get_view_state()
	_check(not bool(vs.feedback_sequence.get("active", false)), "feedback_sequence deactivates after 2.5s")

	# Test skip_feedback command
	day.trigger_feedback_sequence(0, "singer_aluo", 85)
	_check(bool(day.get_view_state().feedback_sequence.get("active", false)), "sequence active again")
	day.command("skip_feedback", {})
	_check(not bool(day.get_view_state().feedback_sequence.get("active", false)), "skip_feedback deactivates sequence immediately")

func _test_coach_layer_feedback_poses() -> void:
	print("\n[CoachLayer] choreography poses during feedback sequence")
	var coach_layer = CoachLayerScript.new()
	var mock_view: Dictionary = {
		"phase": "SERVICE",
		"coach": {"position": [5.0, 5.0], "direction": [0.0, 0.0]},
		"feedback_sequence": {"active": true, "elapsed": 0.4, "duration": 2.5}
	}
	coach_layer.init(func() -> Dictionary: return mock_view, 32, func() -> int: return 0)

	coach_layer.update_state()
	_check(coach_layer.get_current_pose() == CoachLayerScript.POSE_GUIDANCE, "Coach in POSE_GUIDANCE (clapping) during first half (<1.0s)")

	# Second half (>1.0s): thumbs up success
	mock_view.feedback_sequence.elapsed = 1.6
	coach_layer.update_state()
	_check(coach_layer.get_current_pose() == CoachLayerScript.POSE_SUCCESS, "Coach in POSE_SUCCESS (thumbs up) during second half (>=1.0s)")

	# Inactive: idle
	mock_view.feedback_sequence.active = false
	coach_layer.update_state()
	_check(coach_layer.get_current_pose() == CoachLayerScript.POSE_IDLE, "Coach returns to POSE_IDLE when sequence completes")

func _test_community_character_art_feedback_textures() -> void:
	print("\n[CommunityCharacterArt] Aluo panting and smile textures")
	var art = CommunityCharacterArtScript.new()
	var tex_panting := art.get_member_texture("singer_aluo", "USING", 0, false, {
		"feedback_sequence_active": true,
		"feedback_sequence_elapsed": 0.5
	})
	_check(tex_panting != null, "Aluo panting texture retrieved during first half")

	var tex_smiling := art.get_member_texture("singer_aluo", "USING", 0, false, {
		"feedback_sequence_active": true,
		"feedback_sequence_elapsed": 1.6
	})
	_check(tex_smiling != null, "Aluo smiling texture retrieved during second half")
	_check(tex_panting != tex_smiling, "Panting and smiling are distinct subtextures")

func _test_community_hud_feedback_expansion() -> void:
	print("\n[CommunityHUD] expanded dialogue card and speaker progression")
	var hud = CommunityHudScript.new()
	hud._ready()

	var mock_view: Dictionary = {
		"phase": "SERVICE",
		"day": 1,
		"service_seconds": 60.0,
		"balance": 300,
		"course": {"label": "初级耐力训练", "status": "running"},
		"feedback_sequence": {"active": true, "elapsed": 0.4, "duration": 2.5}
	}
	hud.init(func() -> Dictionary: return mock_view)
	hud._refresh()

	_check(hud.is_portrait_visible(), "Portrait visible and HUD expanded during feedback sequence (<1.0s)")
	_check(hud.get_active_portrait_character() == "coach", "Speaker is Coach Cheng during first half")
	_check(hud.is_button_visible("skip_feedback"), "Skip feedback button is visible")

	# Second half (>1.0s): Lao Qiu nod
	mock_view.feedback_sequence.elapsed = 1.5
	hud._refresh()
	_check(hud.is_portrait_visible(), "Portrait visible during second half")
	_check(hud.get_active_portrait_character() == "qiu_nod", "Speaker switches to Lao Qiu nod portrait during second half")

	# After completion in SERVICE: docks to collapsed HUD
	mock_view.feedback_sequence.active = false
	hud._refresh()
	_check(not hud.is_portrait_visible(), "HUD cleanly docks to collapsed bar after sequence finishes")
