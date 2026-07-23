# tests/unit/grid_system/grid_core_cell_data_test.gd
# Story 001: Grid Core — Cell Data Model
# Covers AC-C1.1 through AC-D2.1
# Run standalone: godot --headless --script tests/unit/grid_system/grid_core_cell_data_test.gd
extends SceneTree

var _pass := 0
var _fail := 0


func _init() -> void:
	print("=".repeat(48))
	print("  UNIT TEST: GridSystem — Cell Data Model (Story 001)")
	print("=".repeat(48))

	_test_buildable_does_not_affect_occupancy_read()
	_test_set_buildable_rejected_after_freeze()
	_test_occupant_id_mutually_exclusive_per_cell()
	_test_access_ids_non_exclusive_multiple_per_cell()
	_test_get_transformed_cells_zero_rotation()
	_test_flat_index_no_cross_row_leak()

	print("\n=== GRID CORE CELL DATA TEST: %d passed, %d failed ===" % [_pass, _fail])
	quit(_fail > 0)


func run_all() -> bool:
	_init()
	return _fail == 0


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


# === Helper ===

func _make_grid(width: int, height: int) -> RefCounted:
	var GS: Script = load("res://src/systems/grid_system.gd") as Script
	var gs: RefCounted = GS.new()
	gs.call("init", width, height)
	return gs


# === AC-C1.1: buildable 与 occupancy 读取互不干扰 ===

func _test_buildable_does_not_affect_occupancy_read() -> void:
	print("\n[AC-C1.1] buildable state does not affect occupancy read")

	var gs := _make_grid(5, 5)

	# Set buildable=false on (2,2)
	gs.call("set_buildable", Vector2i(2, 2), false)
	gs.call("freeze_buildable")

	# Occupancy should still be -1 (empty), unaffected by buildable
	_check(
		gs.call("get_occupant_id", Vector2i(2, 2)) == -1,
		"get_occupant_id((2,2)) returns -1 when buildable=false"
	)

	# Also verify buildable state is unchanged after occupant_id writes
	gs.call("commit_occupant", Vector2i(0, 0), 1)
	_check(
		gs.call("get_buildable", Vector2i(0, 0)) == false,
		"buildable state unchanged after occupant_id write"
	)

	# Verify get_buildable returns the correct value
	_check(
		gs.call("get_buildable", Vector2i(2, 2)) == false,
		"get_buildable((2,2)) returns false as set"
	)


# === AC-C1.2: set_buildable 运行时不可调用 ===

func _test_set_buildable_rejected_after_freeze() -> void:
	print("\n[AC-C1.2] set_buildable rejected after freeze")

	var gs := _make_grid(5, 5)

	# Set some buildable cells during level load
	gs.call("set_buildable", Vector2i(0, 0), true)
	gs.call("set_buildable", Vector2i(1, 1), false)

	_check(
		gs.call("get_buildable", Vector2i(0, 0)) == true,
		"buildable(0,0) = true before freeze"
	)
	_check(
		gs.call("get_buildable", Vector2i(1, 1)) == false,
		"buildable(1,1) = false before freeze"
	)

	# Freeze — simulates level load complete
	gs.call("freeze_buildable")

	# Attempt to mutate — should be rejected (no-op + push_error)
	gs.call("set_buildable", Vector2i(0, 0), false)
	gs.call("set_buildable", Vector2i(1, 1), true)

	# Buildable state must be UNCHANGED
	_check(
		gs.call("get_buildable", Vector2i(0, 0)) == true,
		"buildable(0,0) still true after rejected set_buildable"
	)
	_check(
		gs.call("get_buildable", Vector2i(1, 1)) == false,
		"buildable(1,1) still false after rejected set_buildable"
	)

	# Test both false→true and true→false attempts after freeze
	gs.call("set_buildable", Vector2i(2, 2), true)
	_check(
		gs.call("get_buildable", Vector2i(2, 2)) == false,
		"buildable(2,2) unchanged after rejected false→true set"
	)

	# set_buildable_bulk also rejected after freeze
	gs.call("set_buildable_bulk", [Vector2i(0, 0), Vector2i(4, 4)], true)
	_check(
		gs.call("get_buildable", Vector2i(0, 0)) == true,
		"buildable(0,0) unchanged after frozen set_buildable_bulk"
	)


# === AC-C2.1: occupant_id 互斥单值 ===

func _test_occupant_id_mutually_exclusive_per_cell() -> void:
	print("\n[AC-C2.1] occupant_id mutually exclusive per cell")

	var gs := _make_grid(5, 5)

	# First commit succeeds
	var ok1: bool = gs.call("commit_occupant", Vector2i(2, 2), 1)
	_check(ok1, "commit_occupant id=1 to (2,2) succeeds")
	_check(
		gs.call("get_occupant_id", Vector2i(2, 2)) == 1,
		"occupant_id at (2,2) is 1"
	)

	# Second commit to same cell without clearing — must fail
	var ok2: bool = gs.call("commit_occupant", Vector2i(2, 2), 2)
	_check(not ok2, "commit_occupant id=2 to (2,2) without clear is rejected")
	_check(
		gs.call("get_occupant_id", Vector2i(2, 2)) == 1,
		"occupant_id at (2,2) still 1 after rejected commit"
	)

	# After clearing, re-commit succeeds
	gs.call("clear_occupant", Vector2i(2, 2))
	_check(
		gs.call("get_occupant_id", Vector2i(2, 2)) == -1,
		"occupant_id at (2,2) is -1 after clear"
	)
	var ok3: bool = gs.call("commit_occupant", Vector2i(2, 2), 2)
	_check(ok3, "commit_occupant id=2 succeeds after clear")
	_check(
		gs.call("get_occupant_id", Vector2i(2, 2)) == 2,
		"occupant_id at (2,2) is 2 after re-commit"
	)


# === AC-C2.2: access_ids 非互斥多值 ===

func _test_access_ids_non_exclusive_multiple_per_cell() -> void:
	print("\n[AC-C2.2] access_ids non-exclusive — multiple per cell")

	var gs := _make_grid(5, 5)

	# Commit access for two different occupant_ids to the same cell
	gs.call("commit_access", Vector2i(2, 2), 1)
	gs.call("commit_access", Vector2i(2, 2), 2)

	var ids: Array = gs.call("get_access_ids", Vector2i(2, 2))
	_check(
		ids.has(1) and ids.has(2),
		"access_ids at (2,2) contains both [1, 2]"
	)

	# Verify no interference with occupant_id
	_check(
		gs.call("get_occupant_id", Vector2i(2, 2)) == -1,
		"occupant_id at (2,2) still -1 — access_ids don't affect occupancy"
	)

	# Edge case: order stability
	var gs2 := _make_grid(5, 5)
	gs2.call("commit_access", Vector2i(0, 0), 10)
	gs2.call("commit_access", Vector2i(0, 0), 5)
	var ids2: Array = gs2.call("get_access_ids", Vector2i(0, 0))
	_check(
		ids2.has(5) and ids2.has(10),
		"access_ids order-independent: both ids present regardless of commit order"
	)

	# Clear one id and verify the other remains
	gs.call("clear_access", Vector2i(2, 2), 1)
	var ids_after_clear: Array = gs.call("get_access_ids", Vector2i(2, 2))
	_check(
		ids_after_clear.has(2) and not ids_after_clear.has(1),
		"after clearing id=1, access_ids = [2] only"
	)

	# Clear last id and verify entry is removed
	gs.call("clear_access", Vector2i(2, 2), 2)
	var ids_final: Array = gs.call("get_access_ids", Vector2i(2, 2))
	_check(
		ids_final.is_empty(),
		"after clearing id=2, access_ids is empty"
	)


# === AC-C3.1: 锚点约定 + 0° 变换 ===

func _test_get_transformed_cells_zero_rotation() -> void:
	print("\n[AC-C3.1] anchor convention + 0° transform")

	var gs := _make_grid(13, 10)

	# 2x2 footprint + 1 access cell
	var fp: Array[Vector2i] = [
		Vector2i(0, 0), Vector2i(1, 0),
		Vector2i(0, 1), Vector2i(1, 1),
	]
	var ac: Array[Vector2i] = [
		Vector2i(0, 2),
	]
	var anchor := Vector2i(5, 5)

	var result: Dictionary = gs.call("get_transformed_cells", fp, ac, anchor, 0)
	var fp_world: Array = result["footprint"] as Array
	var ac_world: Array = result["access"] as Array

	_check(
		fp_world.has(Vector2i(5, 5)) and
		fp_world.has(Vector2i(6, 5)) and
		fp_world.has(Vector2i(5, 6)) and
		fp_world.has(Vector2i(6, 6)),
		"footprint world cells = {(5,5),(6,5),(5,6),(6,6)}"
	)
	_check(
		fp_world.size() == 4,
		"footprint has exactly 4 cells"
	)
	_check(
		ac_world.has(Vector2i(5, 7)),
		"access world cell = (5,7)"
	)
	_check(
		ac_world.size() == 1,
		"access has exactly 1 cell"
	)
	# Verify anchor is top-left of footprint
	_check(
		fp_world.has(anchor),
		"anchor (5,5) is in the footprint world cells (top-left of union bbox)"
	)


# === AC-D2.1: 扁平索引无跨行泄漏 ===

func _test_flat_index_no_cross_row_leak() -> void:
	print("\n[AC-D2.1] flat_index — no cross-row leakage")

	var gs := _make_grid(13, 10)

	# Write known values to specific cells
	# (6,3): flat_index = 3*13 + 6 = 45
	# (5,3): flat_index = 3*13 + 5 = 44 — adjacent in flat space!
	var c1: bool = gs.call("commit_occupant", Vector2i(6, 3), 99)
	var c2: bool = gs.call("commit_occupant", Vector2i(5, 3), 42)
	_check(c1 and c2, "both cells initially writable")

	_check(
		gs.call("get_occupant_id", Vector2i(6, 3)) == 99,
		"(6,3) retains id=99 after writing adjacent cell (5,3) — no cross-row leak"
	)
	_check(
		gs.call("get_occupant_id", Vector2i(5, 3)) == 42,
		"(5,3) correctly has id=42"
	)

	# Edge case: row boundary test
	# (12,0): flat_index = 0*13 + 12 = 12, (0,1): flat_index = 1*13 + 0 = 13 — adjacent!
	var gs2 := _make_grid(13, 10)
	gs2.call("commit_occupant", Vector2i(12, 0), 77)
	gs2.call("commit_occupant", Vector2i(0, 1), 88)
	_check(
		gs2.call("get_occupant_id", Vector2i(12, 0)) == 77,
		"row boundary: (12,0) retains id=77 after writing (0,1)"
	)
	_check(
		gs2.call("get_occupant_id", Vector2i(0, 1)) == 88,
		"row boundary: (0,1) correctly has id=88"
	)
