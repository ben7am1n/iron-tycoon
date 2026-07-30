# tests/unit/grid_system/grid_core_cell_data_test.gd
# Story 001: Grid Core — Cell Data Model
# Covers AC-C1.1 through AC-D2.1
# Run via: tests/headless_runner.gd (registered in TEST_FILES)
extends SceneTree

const GridSystemClass := preload("res://src/systems/grid_system.gd")

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

func _make_grid(width: int, height: int) -> GridSystem:
	var gs := GridSystemClass.new()
	gs.init(width, height)
	return gs


# === AC-C1.1: buildable 与 occupancy 读取互不干扰 ===
# GIVEN a 5×5 grid, cell (2,2) has buildable=false,
# WHEN querying get_occupant_id((2,2)),
# THEN returns -1 — buildable and occupancy don't interfere.

func _test_buildable_does_not_affect_occupancy_read() -> void:
	print("\n[AC-C1.1] buildable state does not affect occupancy read")

	var gs := _make_grid(5, 5)

	# Set buildable=false on (2,2)
	gs.set_buildable(Vector2i(2, 2), false)
	gs.freeze_buildable()

	# Occupancy should still be -1 (empty), unaffected by buildable
	_check(
		gs.get_occupant_id(Vector2i(2, 2)) == -1,
		"get_occupant_id((2,2)) returns -1 when buildable=false"
	)

	# Also verify buildable state is unchanged after occupant_id writes
	gs.commit_occupant(Vector2i(0, 0), 1)
	_check(
		gs.get_buildable(Vector2i(0, 0)) == false,
		"buildable state unchanged after occupant_id write (cell was default 0)"
	)

	# Verify get_buildable returns the correct value
	_check(
		gs.get_buildable(Vector2i(2, 2)) == false,
		"get_buildable((2,2)) returns false as set"
	)


# === AC-C1.2: set_buildable 运行时不可调用 ===
# GIVEN an initialized GridSystem instance (MVP mode),
# WHEN set_buildable() is called after level load completes,
# THEN the call is rejected with push_error(), grid buildable state unchanged.

func _test_set_buildable_rejected_after_freeze() -> void:
	print("\n[AC-C1.2] set_buildable rejected after freeze")

	var gs := _make_grid(5, 5)

	# Set some buildable cells during level load
	gs.set_buildable(Vector2i(0, 0), true)
	gs.set_buildable(Vector2i(1, 1), false)

	_check(
		gs.get_buildable(Vector2i(0, 0)) == true,
		"buildable(0,0) = true before freeze"
	)
	_check(
		gs.get_buildable(Vector2i(1, 1)) == false,
		"buildable(1,1) = false before freeze"
	)

	# Freeze — simulates level load complete
	gs.freeze_buildable()

	# Attempt to mutate — should be rejected silently (no-op, push_error)
	gs.set_buildable(Vector2i(0, 0), false)
	gs.set_buildable(Vector2i(1, 1), true)

	# Buildable state must be UNCHANGED
	_check(
		gs.get_buildable(Vector2i(0, 0)) == true,
		"buildable(0,0) still true after rejected set_buildable"
	)
	_check(
		gs.get_buildable(Vector2i(1, 1)) == false,
		"buildable(1,1) still false after rejected set_buildable"
	)

	# Test on multiple cell positions
	gs.set_buildable(Vector2i(2, 2), true)
	_check(
		gs.get_buildable(Vector2i(2, 2)) == false,
		"buildable(2,2) unchanged (was default 0) after rejected set to true"
	)


# === AC-C2.1: occupant_id 互斥单值 ===
# GIVEN empty grid,
# WHEN committing id=1 to a cell then committing id=2 to the same cell
#      without clearing first,
# THEN second commit rejected, occupant_id still 1.

func _test_occupant_id_mutually_exclusive_per_cell() -> void:
	print("\n[AC-C2.1] occupant_id mutually exclusive per cell")

	var gs := _make_grid(5, 5)

	# First commit succeeds
	var ok1 := gs.commit_occupant(Vector2i(2, 2), 1)
	_check(ok1, "commit_occupant id=1 to (2,2) succeeds")
	_check(
		gs.get_occupant_id(Vector2i(2, 2)) == 1,
		"occupant_id at (2,2) is 1"
	)

	# Second commit to same cell without clearing — must fail
	var ok2 := gs.commit_occupant(Vector2i(2, 2), 2)
	_check(not ok2, "commit_occupant id=2 to (2,2) without clear is rejected")
	_check(
		gs.get_occupant_id(Vector2i(2, 2)) == 1,
		"occupant_id at (2,2) still 1 after rejected commit"
	)

	# Edge case: commit to overlapping but not identical footprint sets
	var ok3 := gs.commit_occupant(Vector2i(3, 0), 3)
	_check(ok3, "commit_occupant id=3 to (3,0) succeeds (different cell)")
	var ok4 := gs.commit_occupant(Vector2i(3, 0), 4)
	_check(not ok4, "commit_occupant id=4 to (3,0) rejected (already occupied)")


# === AC-C2.2: access_ids 非互斥多值 ===
# GIVEN empty grid,
# WHEN commit(id=1, access=[cell]) then commit(id=2, access=[same cell])
#      with different footprints,
# THEN both succeed, access_ids returns [1, 2].

func _test_access_ids_non_exclusive_multiple_per_cell() -> void:
	print("\n[AC-C2.2] access_ids non-exclusive — multiple per cell")

	var gs := _make_grid(5, 5)

	# Commit access for two different occupant_ids to the same cell
	gs.commit_access(Vector2i(2, 2), 1)
	gs.commit_access(Vector2i(2, 2), 2)

	var ids := gs.get_access_ids(Vector2i(2, 2))
	_check(
		ids.has(1) and ids.has(2),
		"access_ids at (2,2) contains both [1, 2]"
	)

	# Verify no interference with occupant_id
	_check(
		gs.get_occupant_id(Vector2i(2, 2)) == -1,
		"occupant_id at (2,2) still -1 — access_ids don't affect occupancy"
	)

	# Edge case: order stability — same result regardless of commit order
	var gs2 := _make_grid(5, 5)
	gs2.commit_access(Vector2i(0, 0), 10)
	gs2.commit_access(Vector2i(0, 0), 5)
	var ids2 := gs2.get_access_ids(Vector2i(0, 0))
	_check(
		ids2.has(5) and ids2.has(10),
		"access_ids order-independent: both ids present regardless of commit order"
	)

	# Clear one id and verify the other remains
	gs.clear_access(Vector2i(2, 2), 1)
	var ids_after_clear := gs.get_access_ids(Vector2i(2, 2))
	_check(
		ids_after_clear.has(2) and not ids_after_clear.has(1),
		"after clearing id=1, access_ids = [2] only"
	)

	# Clear last id and verify entry is removed
	gs.clear_access(Vector2i(2, 2), 2)
	_check(
		gs.get_access_ids(Vector2i(2, 2)).is_empty(),
		"after clearing id=2, access_ids is empty"
	)


# === AC-C3.1: 锚点约定 + 0° 变换 ===
# GIVEN anchor_cell=(5,5), rotation=0°,
# WHEN get_transformed_cells,
# THEN footprint world cells exactly {(5,5),(6,5),(5,6),(6,6)},
#      access = {(5,7)}.

func _test_get_transformed_cells_zero_rotation() -> void:
	print("\n[AC-C3.1] anchor convention + 0° transform")

	var gs := _make_grid(13, 10)

	# 2x2 footprint + 1 access cell
	var footprint: Array[Vector2i] = [
		Vector2i(0, 0), Vector2i(1, 0),
		Vector2i(0, 1), Vector2i(1, 1),
	]
	var access: Array[Vector2i] = [
		Vector2i(0, 2),
	]
	var anchor := Vector2i(5, 5)

	var result := gs.get_transformed_cells(footprint, access, anchor, 0)
	var fp_world := result["footprint"] as Array
	var ac_world := result["access"] as Array

	# Expected: anchor (5,5) + canonical cell
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


# === AC-D2.1: 扁平索引无跨行泄漏 ===
# GIVEN width=13,height=10, cell (6,3) has known value,
# WHEN writing (5,3) then reading (6,3),
# THEN (6,3) value unchanged — proves flat_index doesn't miscompute
#      causing cross-row writes.

func _test_flat_index_no_cross_row_leak() -> void:
	print("\n[AC-D2.1] flat_index — no cross-row leakage")

	var gs := _make_grid(13, 10)

	# Write known values to specific cells
	# (6,3): flat_index = 3*13 + 6 = 45
	# (5,3): flat_index = 3*13 + 5 = 44 — adjacent in flat space!
	_check(
		gs.commit_occupant(Vector2i(6, 3), 99),
		"commit_occupant id=99 to (6,3) succeeds"
	)
	_check(
		gs.commit_occupant(Vector2i(5, 3), 42),
		"commit_occupant id=42 to (5,3) succeeds"
	)

	# Verify no cross-contamination — (6,3) should still be 99
	_check(
		gs.get_occupant_id(Vector2i(6, 3)) == 99,
		"(6,3) retains id=99 after writing adjacent cell (5,3) — no cross-row leak"
	)
	_check(
		gs.get_occupant_id(Vector2i(5, 3)) == 42,
		"(5,3) correctly has id=42"
	)

	# Edge case: row boundary test
	# last cell of row 0 (12,0) vs first cell of row 1 (0,1)
	# flat_index(12,0) = 0*13 + 12 = 12
	# flat_index(0,1)  = 1*13 + 0  = 13 — adjacent!
	var gs2 := _make_grid(13, 10)
	gs2.commit_occupant(Vector2i(12, 0), 77)
	gs2.commit_occupant(Vector2i(0, 1), 88)
	_check(
		gs2.get_occupant_id(Vector2i(12, 0)) == 77,
		"row boundary: (12,0) retains id=77 after writing (0,1)"
	)
	_check(
		gs2.get_occupant_id(Vector2i(0, 1)) == 88,
		"row boundary: (0,1) correctly has id=88"
	)
