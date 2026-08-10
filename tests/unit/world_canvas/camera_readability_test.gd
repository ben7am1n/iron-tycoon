# tests/unit/world_canvas/camera_readability_test.gd
# Camera fix 回归：中央俯视可读性优先，边缘仍保留 2.5D 体积与天花板氛围。
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"
const Proj2D := preload("res://src/presentation/oblique_projection.gd")
const WorldCanvas := preload("res://src/presentation/world_canvas.gd")
const VIEWPORT_SIZE := Vector2(426, 240)
const WORLD_SCALE := 0.75

var _pass := 0
var _fail := 0


func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	var result := run_all()
	quit(1 if int(result["fail"]) > 0 else 0)


func run_all() -> Dictionary:
	print("=".repeat(48))
	print("  UNIT TEST: Camera readability — top-down center / 2.5D edge")
	print("=".repeat(48))

	_test_projection_readability()
	_test_edge_volume_preserved()
	_test_bounds_and_input_roundtrip()
	_test_ceiling_edge_contract()

	print("\n=== CAMERA READABILITY TEST: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(condition: bool, message: String) -> void:
	if condition:
		_pass += 1
		print("  PASS: " + message)
	else:
		_fail += 1
		print("  FAIL: " + message)


func _test_projection_readability() -> void:
	_check(Proj2D.TILT_DEG >= 48.0,
		"tilt >= 48deg keeps the operation area predominantly top-down")
	_check(Proj2D.FLOOR_SCALE >= 0.75,
		"floor depth scale >= 0.75 keeps equipment footprints readable")
	_check(Proj2D.SHEAR <= 0.24,
		"floor shear <= 0.24 prevents the center reading as a strong diagonal box")
	var floor_depth := Proj2D.WORLD_H * Proj2D.FLOOR_SCALE
	var wall_height := Proj2D.WALL_HEIGHT * Proj2D.HEIGHT_SCALE
	_check(wall_height / floor_depth < 0.20,
		"projected wall height stays below 20% of projected floor depth")
	_check(Proj2D.WALL_HEIGHT >= 60.0 and Proj2D.WALL_HEIGHT <= 70.0,
		"wall height remains in the 60-70px edge-atmosphere band")


func _test_edge_volume_preserved() -> void:
	_check(Proj2D.HEIGHT_SCALE >= 0.60,
		"height projection remains visible for equipment front faces")
	_check(Proj2D.EXTRUDE_X >= 0.14,
		"horizontal extrusion remains visible for equipment side faces")
	_check(Proj2D.SHEAR > 0.0,
		"non-zero floor shear preserves 2.5D direction at room edges")


func _test_bounds_and_input_roundtrip() -> void:
	var scaled := Proj2D.PROJECTED_SIZE * WORLD_SCALE
	_check(scaled.x <= VIEWPORT_SIZE.x and scaled.y <= VIEWPORT_SIZE.y,
		"projected room fits the 426x240 low-resolution viewport")
	var offset := Proj2D.viewport_offset(VIEWPORT_SIZE, WORLD_SCALE)
	var screen_scale := Vector2(1280.0 / 426.0, 720.0 / 240.0)
	var world := Vector2(208.0, 160.0)
	var screen := Proj2D.world_to_screen(world, offset, WORLD_SCALE, screen_scale)
	var restored := Proj2D.screen_to_world(screen, offset, WORLD_SCALE, screen_scale)
	_check(restored.distance_to(world) < 0.001,
		"world/screen input bridge round-trips after camera recentering")


func _test_ceiling_edge_contract() -> void:
	_check(WorldCanvas.CEILING_CENTER_ALPHA <= 0.16,
		"ceiling texture is weak in the center")
	_check(WorldCanvas.CEILING_EDGE_BAND >= 24.0,
		"ceiling keeps a visible atmosphere band around room edges")
	_check(WorldCanvas.CEILING_OUTER_BAND < WorldCanvas.CEILING_EDGE_BAND,
		"nested ceiling bands form an edge-weighted pixel gradient")
