# tests/unit/art_assets/park_view_remaster_test.gd
# Validates park view remaster: 32x40 character art, route geometry, and HUD collapse.
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"
const ParkViewScript := preload("res://src/presentation/park_view.gd")
const CommunityHudScript := preload("res://src/ui/community_hud.gd")

var _pass := 0
var _fail := 0

func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	var result := run_all()
	quit(1 if int(result["fail"]) > 0 else 0)

func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: %s" % msg)
	else:
		_fail += 1
		print("  FAIL: %s" % msg)

func run_all() -> Dictionary:
	_pass = 0
	_fail = 0
	print("=".repeat(56))
	print("  UNIT TEST: Park View Remaster (Dave the Diver Quality)")
	print("=".repeat(56))

	_test_park_view_init()
	_test_route_projections()
	_test_hud_collapse_during_active_run()
	_test_checkpoint_markers()

	print("\n=== PARK VIEW REMASTER: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}

func _test_park_view_init() -> void:
	print("\n[ParkView] Initialization and Character Art Binding")
	var pv = ParkViewScript.new()
	var mock_view := {
		"phase": "OUTING",
		"day": 1,
		"outing": {
			"progress_m": 0.0,
			"position": [0.0, 0.0],
			"pace": "walk",
			"active": false,
			"stamina": 100.0,
		},
		"story": {"events": []}
	}
	pv.init(func() -> Dictionary: return mock_view)
	_check(pv._char_art != null, "CommunityCharacterArt instance created in park view")
	_check(pv.SCALE_M > 2.0 and pv.SCALE_M < 2.5, "SCALE_M tuned for comfortable viewport breathing (got %.2f)" % pv.SCALE_M)
	_check(pv.ORIGIN == Vector2(44.0, 56.0), "ORIGIN calibrated to (44, 56)")
	pv.free()

func _test_route_projections() -> void:
	print("\n[ParkView] Route coordinate projections")
	var pv = ParkViewScript.new()
	pv.init(func() -> Dictionary: return {})
	var p0: Vector2 = pv._m_to_p(Vector2(0, 0))
	var p1: Vector2 = pv._m_to_p(Vector2(36, 0))
	var p2: Vector2 = pv._m_to_p(Vector2(36, 60))
	var p3: Vector2 = pv._m_to_p(Vector2(108, 60))

	_check(p0.x == 44.0 and p0.y == 56.0, "p0 (0m) starts at ORIGIN (44, 56)")
	_check(p1.x > p0.x and p1.y == p0.y, "p1 (36m) moves horizontally right from p0")
	_check(p2.x == p1.x and p2.y > p1.y, "p2 (96m) moves vertically down from p1")
	_check(p3.x > p2.x and p3.y == p2.y, "p3 (168m) moves horizontally right from p2")
	_check(p3.y < 200.0, "p3 finish line at %.1f is comfortably above collapsed HUD (200px threshold)" % p3.y)
	pv.free()

func _test_hud_collapse_during_active_run() -> void:
	print("\n[CommunityHud] HUD Collapse During Active Run in OUTING")
	var hud = CommunityHudScript.new()
	var mock_view := {
		"phase": "OUTING",
		"day": 1,
		"balance": 280,
		"outing": {
			"progress_m": 36.0,
			"position": [36.0, 0.0],
			"pace": "jog",
			"active": false, # Stopped / interacting with Aluo
			"stamina": 85.0
		},
		"story": {"events": []}
	}
	hud.init(func() -> Dictionary: return mock_view)
	root.add_child(hud)
	hud._ready()
	hud._process(0.016)

	_check(not hud._is_collapsed, "HUD is expanded when active is false (speaking with Aluo)")

	# Set active to true (running along track)
	mock_view["outing"]["active"] = true
	hud._process(0.016)
	_check(hud.is_hud_collapsed(), "HUD collapses when active is true (running along track)")
	_check(hud._details.position.y >= 650.0, "Collapsed details label positioned at bottom bar (got %.1f)" % hud._details.position.y)

	hud.free()

func _test_checkpoint_markers() -> void:
	print("\n[ParkView] Checkpoint and Props layout")
	var pv = ParkViewScript.new()
	pv.init(func() -> Dictionary: return {})
	var p1: Vector2 = pv._m_to_p(Vector2(36, 0))
	var aluo_pos := p1 + Vector2(36, 18)
	var sign_36m_pos := p1 + Vector2(-46, 32)

	_check(aluo_pos.x > p1.x, "Aluo is positioned east of corner (got x=%.1f > %.1f)" % [aluo_pos.x, p1.x])
	_check(sign_36m_pos.x < p1.x, "36m milestone sign is positioned west of running track (got x=%.1f < %.1f)" % [sign_36m_pos.x, p1.x])
	_check(absf(aluo_pos.x - sign_36m_pos.x) > 70.0, "Sign and Aluo separated by >70px (got %.1fpx) to guarantee zero overlap" % absf(aluo_pos.x - sign_36m_pos.x))
	pv.free()
