# tests/unit/placement_system/drag_state_getters_test.gd
# Phase B v2 — PlacementSystem 拖拽状态只读观测 getter 单元测试
#
# 验证 Phase B 幽灵渲染所需的观测面（与 is_dragging 同属纯读状态查询，
# TR-PS-010 同一 standing）：
#   - IDLE：equipment_id="" / anchor=ZERO / rotation=R0 / has_previewed=false /
#     preview_valid=false（安全默认，不崩溃）
#   - begin_drag 后：equipment_id 正确；未移动时 has_previewed=false
#   - on_mouse_moved 后：anchor 更新、has_previewed=true、preview_valid 与
#     can_place 结果一致（合法格 true / 占位格 false）
#   - on_rotate_pressed 后：rotation 推进
#   - on_drop 成功后：全部回到 IDLE 安全默认
#   - begin_relocate：equipment_id 来自被移动设备的 def
#
# Run standalone: godot --headless --script tests/unit/placement_system/drag_state_getters_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const GridSystemScript := preload("res://src/systems/grid_system.gd")
const EquipmentCatalogScript := preload("res://src/systems/equipment_catalog.gd")
const EquipmentDefScript := preload("res://src/systems/equipment_def.gd")
const PlacementSystemScript := preload("res://src/systems/placement_system.gd")

var _pass := 0
var _fail := 0


func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	var result := run_all()
	quit(1 if int(result["fail"]) > 0 else 0)


func run_all() -> Dictionary:
	print("=".repeat(48))
	print("  UNIT TEST: PlacementSystem drag-state observation getters (Phase B v2)")
	print("=".repeat(48))

	_test_idle_safe_defaults()
	_test_begin_drag_sets_equipment_id()
	_test_mouse_move_updates_anchor_and_valid()
	_test_rotate_advances_rotation()
	_test_drop_resets_to_idle()
	_test_relocate_exposes_equipment_id()

	print("\n=== DRAG STATE GETTERS TEST: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


# === 构造辅助 ===

func _make_grid() -> GridSystemScript:
	var grid = GridSystemScript.new()
	grid.init(6, 6)
	for y in 6:
		for x in 6:
			grid.set_buildable(Vector2i(x, y), true)
	grid.freeze_buildable()
	return grid


func _make_catalog() -> EquipmentCatalogScript:
	var cat = EquipmentCatalogScript.new()
	cat.call("_add_definition", EquipmentDefScript.new(
		"treadmill", "Treadmill", ["cardio"],
		[Vector2i(0, 0), Vector2i(1, 0)], [Vector2i(0, 1)],
		200, "", [{"tag": "cardio", "magnitude": 1.0}], 200, 35, 100, 300
	))
	cat.call("_freeze")
	return cat


func _make_placement() -> PlacementSystemScript:
	var p = PlacementSystemScript.new()
	p.init(_make_grid(), _make_catalog())
	return p


# === 用例 ===

func _test_idle_safe_defaults() -> void:
	var p := _make_placement()
	_check(p.get_drag_equipment_id() == "", "IDLE equipment_id == ''")
	_check(p.get_drag_anchor() == Vector2i.ZERO, "IDLE anchor == ZERO")
	_check(p.get_drag_rotation() == 0, "IDLE rotation == R0")
	_check(not p.get_drag_has_previewed(), "IDLE has_previewed == false")
	_check(not p.get_drag_preview_valid(), "IDLE preview_valid == false")


func _test_begin_drag_sets_equipment_id() -> void:
	var p := _make_placement()
	p.begin_drag("treadmill")
	_check(p.is_dragging(), "drag started")
	_check(p.get_drag_equipment_id() == "treadmill", "drag equipment_id == 'treadmill'")
	_check(not p.get_drag_has_previewed(), "no preview yet after begin_drag")
	_check(not p.get_drag_preview_valid(), "preview_valid false before any move")


func _test_mouse_move_updates_anchor_and_valid() -> void:
	var grid := _make_grid()
	var p := PlacementSystemScript.new()
	p.init(grid, _make_catalog())
	p.begin_drag("treadmill")
	p.on_mouse_moved(Vector2i(1, 1))
	_check(p.get_drag_has_previewed(), "has_previewed true after move")
	_check(p.get_drag_anchor() == Vector2i(1, 1), "anchor updated to (1,1)")
	_check(p.get_drag_preview_valid(), "preview_valid true on empty cell")
	# 先放一台到 (2,2)，再拖到其 footprint 上 → invalid
	var p2 := PlacementSystemScript.new()
	p2.init(grid, _make_catalog())
	p2.begin_drag("treadmill")
	p2.on_mouse_moved(Vector2i(2, 2))
	p2.on_drop()
	p.begin_drag("treadmill")
	p.on_mouse_moved(Vector2i(2, 2))
	_check(not p.get_drag_preview_valid(), "preview_valid false on occupied cell")


func _test_rotate_advances_rotation() -> void:
	var p := _make_placement()
	p.begin_drag("treadmill")
	p.on_mouse_moved(Vector2i(1, 1))
	p.on_rotate_pressed()
	_check(p.get_drag_rotation() == 90, "rotation advances to R90")
	p.on_rotate_pressed()
	_check(p.get_drag_rotation() == 180, "rotation advances to R180")


func _test_drop_resets_to_idle() -> void:
	var p := _make_placement()
	p.begin_drag("treadmill")
	p.on_mouse_moved(Vector2i(1, 1))
	p.on_drop()
	_check(not p.is_dragging(), "drop ends drag")
	_check(p.get_drag_equipment_id() == "", "equipment_id reset after drop")
	_check(p.get_drag_anchor() == Vector2i.ZERO, "anchor reset after drop")
	_check(not p.get_drag_has_previewed(), "has_previewed reset after drop")
	_check(not p.get_drag_preview_valid(), "preview_valid reset after drop")


func _test_relocate_exposes_equipment_id() -> void:
	var p := _make_placement()
	p.begin_drag("treadmill")
	p.on_mouse_moved(Vector2i(1, 1))
	p.on_drop()  # instance 0 placed at (1,1)
	_check(not p.is_dragging(), "placed, idle again")
	p.begin_relocate(0)
	_check(p.is_dragging(), "relocate started")
	_check(p.get_drag_equipment_id() == "treadmill", "relocate exposes equipment_id")
	_check(p.get_drag_anchor() == Vector2i.ZERO, "relocate anchor ZERO until move")
	_check(not p.get_drag_has_previewed(), "relocate no preview until move")
