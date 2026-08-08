# tests/unit/world_canvas/world_canvas_hover_test.gd
# V3 Phase 3 — 设备 hover 状态（V3 §14 可读性）单元测试
#
# 验证 src/presentation/world_canvas.gd 的 hover 机制：
#   - hover provider 轮询维护 _hovered_instance_id（O(1) 状态读，边沿重绘）
#   - set_hover_provider / set_hovered_instance_id / get_hovered_instance_id
#   - 无 provider 时轮询是 no-op（默认 -1）
#   - hover 上移常量契约（HOVER_LIFT_PX > 0，V3 §14 轻微上移）
#   - 黄色 hover 轮廓色 = Palette.EQUIP_HOVER_OUTLINE（§14/§10 契约）
#
# Headless 断言 STATE（query surface），不碰像素 —— 与 grid_visibility_test
# 同一模式。
#
# Run standalone: godot --headless --script tests/unit/world_canvas/world_canvas_hover_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const WorldCanvasScript := preload("res://src/presentation/world_canvas.gd")
const PaletteScript := preload("res://src/palette.gd")

const GRID_W := 13
const GRID_H := 10
const CELL_SIZE := 32

var _pass := 0
var _fail := 0
var _nodes_to_free: Array = []


func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	var result := run_all()
	quit(1 if int(result["fail"]) > 0 else 0)


func run_all() -> Dictionary:
	print("=".repeat(48))
	print("  UNIT TEST: WorldCanvas — V3 §14 equipment hover state")
	print("=".repeat(48))

	_test_default_no_hover()
	_test_provider_poll_updates()
	_test_provider_poll_idempotent()
	_test_setter_direct()
	_test_no_provider_noop()
	_test_hover_lift_constant()
	_test_hover_outline_color()

	_free_test_nodes()

	print("\n=== WORLD CANVAS HOVER: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


# === helpers ===

func _make_grid():
	var grid = _GRID().new()
	grid.init(GRID_W, GRID_H)
	for y in GRID_H:
		for x in GRID_W:
			grid.set_buildable(Vector2i(x, y), true)
	grid.freeze_buildable()
	return grid


func _GRID() -> Script:
	return preload("res://src/systems/grid_system.gd") as Script


func _make_canvas(grid, placement = null) -> Node2D:
	var canvas: Node2D = WorldCanvasScript.new()
	canvas.init(
		grid,
		null,      # catalog
		null,      # member
		null,      # member_sprites
		null,      # equip_art
		placement,
		null,      # arbitration
		Callable(),  # resolver
		Callable(),  # tick_provider
		CELL_SIZE
	)
	_nodes_to_free.append(canvas)
	return canvas


func _free_test_nodes() -> void:
	for n in _nodes_to_free:
		if is_instance_valid(n):
			n.queue_free()
	_nodes_to_free.clear()


# === tests ===

func _test_default_no_hover() -> void:
	var grid = _make_grid()
	var canvas := _make_canvas(grid)
	_check(canvas.get_hovered_instance_id() == -1, "default hovered instance == -1 (no hover)")


func _test_provider_poll_updates() -> void:
	var grid = _make_grid()
	var canvas := _make_canvas(grid)
	# GDScript lambda 按值捕获局部变量 —— 用可变的 holder 字典承载状态。
	var state := {"id": 42}
	canvas.set_hover_provider(func() -> int: return int(state["id"]))
	canvas.call("_poll_hover")
	_check(canvas.get_hovered_instance_id() == 42, "provider poll picks up instance 42")
	state["id"] = 7
	canvas.call("_poll_hover")
	_check(canvas.get_hovered_instance_id() == 7, "provider poll updates to instance 7")
	state["id"] = -1
	canvas.call("_poll_hover")
	_check(canvas.get_hovered_instance_id() == -1, "provider poll clears on -1")


func _test_provider_poll_idempotent() -> void:
	var grid = _make_grid()
	var canvas := _make_canvas(grid)
	var state := {"id": 3}
	canvas.set_hover_provider(func() -> int: return int(state["id"]))
	canvas.call("_poll_hover")
	_check(canvas.get_hovered_instance_id() == 3, "precondition: polled once")
	# 状态未变时重复轮询不翻转（幂等，零开销约定）。
	canvas.call("_poll_hover")
	_check(canvas.get_hovered_instance_id() == 3, "repeated poll stays (idempotent)")


func _test_setter_direct() -> void:
	var grid = _make_grid()
	var canvas := _make_canvas(grid)
	canvas.set_hovered_instance_id(5)
	_check(canvas.get_hovered_instance_id() == 5, "set_hovered_instance_id(5) sticks")
	canvas.set_hovered_instance_id(5)
	_check(canvas.get_hovered_instance_id() == 5, "same-value set is a no-op (idempotent)")
	canvas.set_hovered_instance_id(-1)
	_check(canvas.get_hovered_instance_id() == -1, "set_hovered_instance_id(-1) clears")


func _test_no_provider_noop() -> void:
	var grid = _make_grid()
	var canvas := _make_canvas(grid)
	# 无 provider（Callable 无效）→ 轮询不崩溃、不改状态。
	canvas.call("_poll_hover")
	_check(canvas.get_hovered_instance_id() == -1, "no provider → poll is a no-op")


func _test_hover_lift_constant() -> void:
	_check(WorldCanvasScript.HOVER_LIFT_PX > 0.0, "HOVER_LIFT_PX > 0 (V3 §14 轻微上移)")
	_check(WorldCanvasScript.HOVER_LIFT_PX <= 4.0, "HOVER_LIFT_PX <= 4 (subtle lift, not a jump)")


func _test_hover_outline_color() -> void:
	# V3 §14 hover 黄色像素轮廓；§10 购买栏 Hover 黄色像素描边。
	# 单一来源：palette.EQUIP_HOVER_OUTLINE（Butter 暖黄）。
	_check(PaletteScript.EQUIP_HOVER_OUTLINE == PaletteScript.BUTTER,
		"hover outline == Butter (yellow pixel outline, V3 §14)")
