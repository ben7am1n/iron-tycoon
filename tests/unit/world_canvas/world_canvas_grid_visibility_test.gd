# tests/unit/world_canvas/world_canvas_grid_visibility_test.gd
# V3 Phase 1 — 低分辨率世界画布（WorldCanvas）网格可见性单元测试
#
# 验证 src/presentation/world_canvas.gd（V3 §14 可读性）：
#   - 默认（正常经营模式）网格完全隐藏（is_grid_visible() == false）
#   - placement mode（PlacementSystem.is_dragging() == true）→ 网格可见
#   - 拖拽结束（is_dragging() == false）→ 网格隐藏
#   - _poll_placement_mode() 幂等（状态未变时零开销、无状态翻转）
#   - set_grid_visible() 显式开关（测试/调试入口）
#   - 双 init 防护（push_error 不崩溃）
#   - 信号接线：grid_changed → _on_world_changed 不崩溃
#
# 不做像素断言（与 SelectionCue / SnapPulse 同一约定：测试断言状态，不测
# 像素）。placement 是鸭子类型（is_dragging()），与项目 presentation 层
# seam 一致。
#
# Run standalone: godot --headless --script tests/unit/world_canvas/world_canvas_grid_visibility_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const WorldCanvasScript := preload("res://src/presentation/world_canvas.gd")
const GridSystemScript := preload("res://src/systems/grid_system.gd")

const GRID_W := 13
const GRID_H := 10
const CELL_SIZE := 32

var _pass := 0
var _fail := 0
var _nodes_to_free: Array = []


## 鸭子类型 placement（is_dragging() 表面）—— 与 WorldCanvas 的注入 seam
## 一致（presentation 层 duck-typing 约定，同 CongestionOverlayController）。
class FakePlacement extends RefCounted:
	var dragging: bool = false

	func is_dragging() -> bool:
		return dragging


## 被 tests/headless_runner.gd 托管时立即返回 —— 用例由 runner 调用的 run_all() 驱动。
func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	var result := run_all()
	quit(1 if int(result["fail"]) > 0 else 0)


## 返回 {"pass": int, "fail": int} —— 见 tests/headless_runner.gd 的测试文件契约
func run_all() -> Dictionary:
	print("=".repeat(48))
	print("  UNIT TEST: WorldCanvas — V3 §14 grid visibility gating")
	print("=".repeat(48))

	_test_default_hidden()
	_test_drag_shows_grid()
	_test_drop_hides_grid()
	_test_poll_idempotent()
	_test_explicit_set_grid_visible()
	_test_double_init_guard()
	_test_grid_changed_signal_noop()
	_test_init_with_null_placement_safe()

	_free_test_nodes()

	print("\n=== WORLD CANVAS TEST: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


## 真实 GridSystem（typed GridStateReader 表面：grid_changed 信号 +
## get_dimensions / get_placed_instances / get_transformed_cells）。
func _make_grid():
	var grid = GridSystemScript.new()
	grid.init(GRID_W, GRID_H)
	for y in GRID_H:
		for x in GRID_W:
			grid.set_buildable(Vector2i(x, y), true)
	grid.freeze_buildable()
	return grid


## 构造 WorldCanvas（挂在树外，headless 状态断言直接驱动方法）。
func _make_canvas(grid, placement) -> Node2D:
	var canvas: Node2D = WorldCanvasScript.new()
	canvas.init(
		grid,
		null,      # catalog（绘制路径才需要；本测试只断言状态）
		null,      # member
		null,      # member_sprites
		null,      # equip_art
		placement,
		null,      # arbitration
		Callable(),  # resolver（未注入 → 绘制兜底为空）
		Callable(),  # tick_provider
		CELL_SIZE
	)
	_nodes_to_free.append(canvas)
	return canvas


func _test_default_hidden() -> void:
	var grid = _make_grid()
	var placement = FakePlacement.new()
	var canvas := _make_canvas(grid, placement)
	_check(not canvas.is_grid_visible(), "V3 §14: grid hidden by default (normal mode)")
	# 默认值常量契约：与 V3 §14 的「完全隐藏」一致。
	_check(canvas.is_grid_visible() == WorldCanvasScript.DEFAULT_GRID_VISIBLE,
		"default matches DEFAULT_GRID_VISIBLE")


func _test_drag_shows_grid() -> void:
	var grid = _make_grid()
	var placement = FakePlacement.new()
	var canvas := _make_canvas(grid, placement)
	placement.dragging = true
	canvas.call("_poll_placement_mode")
	_check(canvas.is_grid_visible(), "placement mode (drag active) → grid visible")


func _test_drop_hides_grid() -> void:
	var grid = _make_grid()
	var placement = FakePlacement.new()
	var canvas := _make_canvas(grid, placement)
	placement.dragging = true
	canvas.call("_poll_placement_mode")
	_check(canvas.is_grid_visible(), "precondition: drag active → grid visible")
	placement.dragging = false
	canvas.call("_poll_placement_mode")
	_check(not canvas.is_grid_visible(), "drag end → grid hidden again (V3 §14)")


func _test_poll_idempotent() -> void:
	var grid = _make_grid()
	var placement = FakePlacement.new()
	var canvas := _make_canvas(grid, placement)
	# 状态未变时重复轮询不翻转状态（幂等，零开销约定）。
	canvas.call("_poll_placement_mode")
	canvas.call("_poll_placement_mode")
	_check(not canvas.is_grid_visible(), "no-drag repeated poll stays hidden")
	placement.dragging = true
	canvas.call("_poll_placement_mode")
	canvas.call("_poll_placement_mode")
	_check(canvas.is_grid_visible(), "drag repeated poll stays visible")


func _test_explicit_set_grid_visible() -> void:
	var grid = _make_grid()
	var placement = FakePlacement.new()
	var canvas := _make_canvas(grid, placement)
	canvas.set_grid_visible(true)
	_check(canvas.is_grid_visible(), "set_grid_visible(true) shows grid")
	canvas.set_grid_visible(false)
	_check(not canvas.is_grid_visible(), "set_grid_visible(false) hides grid")
	# 幂等：重复设置同值不报错。
	canvas.set_grid_visible(false)
	_check(not canvas.is_grid_visible(), "repeated set same value is a no-op")


func _test_double_init_guard() -> void:
	var grid = _make_grid()
	var placement = FakePlacement.new()
	var canvas := _make_canvas(grid, placement)
	# 第二次 init 是 push_error + no-op（不崩溃、不重置状态）。
	canvas.call("init", grid, null, null, null, null, placement, null, Callable(), Callable(), CELL_SIZE)
	_check(not canvas.is_grid_visible(), "double-init leaves state intact")


func _test_grid_changed_signal_noop() -> void:
	var grid = _make_grid()
	var placement = FakePlacement.new()
	var canvas := _make_canvas(grid, placement)
	# init 接线：grid_changed → _on_world_changed（队列重绘，headless 无害）。
	grid.grid_changed.emit([], [])
	_check(true, "grid_changed emission reaches canvas without crash")
	canvas.call("_on_world_changed")
	_check(true, "_on_world_changed direct call safe")


func _test_init_with_null_placement_safe() -> void:
	var grid = _make_grid()
	var canvas := _make_canvas(grid, null)
	_check(not canvas.is_grid_visible(), "null placement → grid stays hidden")
	canvas.call("_poll_placement_mode")
	_check(not canvas.is_grid_visible(), "null placement poll is a safe no-op")


func _free_test_nodes() -> void:
	for n in _nodes_to_free:
		if is_instance_valid(n):
			n.free()
	_nodes_to_free.clear()
