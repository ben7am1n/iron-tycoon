# tests/unit/grid_system/grid_core_cell_data_test.gd
# Story 001: Grid Core — Cell Data Model
# Covers AC-C1.1 through AC-D2.1
# Run standalone: godot --headless --script tests/unit/grid_system/grid_core_cell_data_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

var _pass := 0
var _fail := 0


## 被 tests/headless_runner.gd 托管时立即返回 —— 用例由 runner 调用的 run_all() 驱动。
## 否则 script.new() 触发的 _init() 与随后的 run_all() 会让每个用例跑两遍。
func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	var result := run_all()
	quit(1 if int(result["fail"]) > 0 else 0)


## 返回 {"pass": int, "fail": int} —— 见 tests/headless_runner.gd 的测试文件契约
func run_all() -> Dictionary:
	print("=".repeat(48))
	print("  UNIT TEST: GridSystem — Cell Data Model (Story 001)")
	print("=".repeat(48))

	_test_buildable_does_not_affect_occupancy_read()
	_test_set_buildable_rejected_after_freeze()
	_test_occupant_id_mutually_exclusive_per_cell()
	_test_occupant_id_zero_is_legal_first_piece()
	_test_access_ids_non_exclusive_multiple_per_cell()
	_test_get_transformed_cells_zero_rotation()
	_test_get_transformed_cells_nonzero_rotation_errors()
	_test_flat_index_no_cross_row_leak()
	_test_double_init_rejected()
	_test_method_before_init_rejected()
	_test_mutator_methods_before_init_rejected()
	_test_get_transformed_cells_before_init_returns_empty()
	_test_commit_occupant_rejects_sentinel_value()
	_test_init_rejects_non_positive_dimensions()
	_test_sim_system_base_class_not_directly_instantiable()

	print("\n=== GRID CORE CELL DATA TEST: %d passed, %d failed ===" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


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


# === occupant_id = 0 regression — NEVER truthy-check (Story 001/002 documented trap) ===

func _test_occupant_id_zero_is_legal_first_piece() -> void:
	print("\n[REGRESSION] occupant_id=0 is legal — never truthy-check")

	var gs := _make_grid(3, 3)

	# Commit occupant_id=0 (first piece placed — MUST succeed)
	var ok: bool = gs.call("commit_occupant", Vector2i(1, 1), 0)
	_check(ok, "commit_occupant id=0 succeeds — 0 is a legal occupant_id")
	_check(
		gs.call("get_occupant_id", Vector2i(1, 1)) == 0,
		"get_occupant_id returns 0 (not -1) — explicit comparison, not truthy"
	)

	# Mutually-exclusive: second commit to same cell must fail
	var ok2: bool = gs.call("commit_occupant", Vector2i(1, 1), 1)
	_check(not ok2, "commit_occupant id=1 rejected — id=0 already occupies the cell")
	_check(
		gs.call("get_occupant_id", Vector2i(1, 1)) == 0,
		"occupant_id still 0 after rejected commit — no overwrite"
	)

	# Clear and re-commit — id=0 must be clearable
	gs.call("clear_occupant", Vector2i(1, 1))
	_check(
		gs.call("get_occupant_id", Vector2i(1, 1)) == -1,
		"occupant_id back to -1 after clearing id=0"
	)

	# After clear, re-commit id=0 again — must work
	var ok3: bool = gs.call("commit_occupant", Vector2i(1, 1), 0)
	_check(ok3, "re-commit occupant_id=0 succeeds after clear")


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


# === get_transformed_cells non-zero rotation error path ===

func _test_get_transformed_cells_nonzero_rotation_errors() -> void:
	print("\n[GUARD] get_transformed_cells rejects non-zero rotation in Story 001")

	var gs := _make_grid(5, 5)

	var fp: Array[Vector2i] = [Vector2i(0, 0)]
	var ac: Array[Vector2i] = [Vector2i(0, 1)]

	for rot in [90, 180, 270]:
		var result: Dictionary = gs.call("get_transformed_cells", fp, ac, Vector2i(0, 0), rot)
		var fp_world: Array = result["footprint"] as Array
		var ac_world: Array = result["access"] as Array
		_check(
			fp_world.is_empty() and ac_world.is_empty(),
			"rotation=%d: returns empty footprint and access arrays" % rot
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


# === Double init() guard ===

func _test_double_init_rejected() -> void:
	print("\n[GUARD] double init() is rejected")

	var GS: Script = load("res://src/systems/grid_system.gd") as Script
	var gs: RefCounted = GS.new()
	gs.call("init", 4, 4)

	# Write a known value to verify state is unchanged after rejected double-init
	gs.call("commit_occupant", Vector2i(0, 0), 7)
	_check(
		gs.call("get_occupant_id", Vector2i(0, 0)) == 7,
		"id=7 at (0,0) before double-init attempt"
	)

	# Second init — must push_error and no-op (state preserved)
	gs.call("init", 99, 99)
	_check(
		gs.call("get_occupant_id", Vector2i(0, 0)) == 7,
		"id=7 at (0,0) still 7 after rejected double-init"
	)
	_check(
		gs.call("get_dimensions") == Vector2i(4, 4),
		"dimensions still (4,4) after rejected double-init — not overwritten to (99,99)"
	)


# === Method-before-init guard ===

func _test_method_before_init_rejected() -> void:
	print("\n[GUARD] public methods reject calls before init()")

	var GS: Script = load("res://src/systems/grid_system.gd") as Script
	var gs: RefCounted = GS.new()
	# Deliberately skip init()

	# Call a public method on an uninitialized grid — each must not crash
	var id: int = gs.call("get_occupant_id", Vector2i(0, 0))
	_check(id == -1, "get_occupant_id returns -1 before init (safe default)")

	var b: bool = gs.call("get_buildable", Vector2i(0, 0))
	_check(b == false, "get_buildable returns false before init (safe default)")

	var ids: Array = gs.call("get_access_ids", Vector2i(0, 0))
	_check(ids.is_empty(), "get_access_ids returns empty before init (safe default)")

	var dims: Vector2i = gs.call("get_dimensions")
	_check(dims == Vector2i(0, 0), "get_dimensions returns (0,0) before init (safe default)")

	var in_bounds: bool = gs.call("is_in_bounds", Vector2i(0, 0))
	_check(not in_bounds, "is_in_bounds returns false before init (0x0 grid)")

	var idx: int = gs.call("flat_index", Vector2i(0, 0))
	_check(idx == -1, "flat_index returns -1 before init (never a valid index)")


# === Mutator methods before init — regression for BUG-GS-001 ===
# _assert_initialized() only logs; it does not halt execution on its own.
# Every mutator must explicitly check its return value and bail out —
# this test proves state stays untouched for the 7 mutators that
# _test_method_before_init_rejected() above does not exercise (that test
# only covers the 5 read-only accessors).

func _test_mutator_methods_before_init_rejected() -> void:
	print("\n[GUARD] mutator methods reject calls before init() — no state mutation")

	var GS: Script = load("res://src/systems/grid_system.gd") as Script
	var gs: RefCounted = GS.new()
	# Deliberately skip init() — grid stays at width=0, height=0

	# set_buildable / set_buildable_bulk / freeze_buildable must no-op.
	# There's no state to observe directly (arrays are empty pre-init), so
	# these assertions confirm the calls don't crash and the grid remains
	# uninitialized (dimensions still (0,0), matching the double-init test's
	# pattern of observing state through get_dimensions()).
	gs.call("set_buildable", Vector2i(0, 0), true)
	gs.call("set_buildable_bulk", [Vector2i(0, 0)], true)
	gs.call("freeze_buildable")
	_check(
		gs.call("get_dimensions") == Vector2i(0, 0),
		"set_buildable/set_buildable_bulk/freeze_buildable before init leave grid uninitialized"
	)

	# commit_occupant before init must return false (not silently succeed)
	var committed: bool = gs.call("commit_occupant", Vector2i(0, 0), 1)
	_check(not committed, "commit_occupant before init returns false")
	_check(
		gs.call("get_occupant_id", Vector2i(0, 0)) == -1,
		"get_occupant_id still -1 after rejected pre-init commit_occupant"
	)

	# clear_occupant before init must not crash
	gs.call("clear_occupant", Vector2i(0, 0))

	# commit_access / clear_access before init must not crash and must not
	# register anything
	gs.call("commit_access", Vector2i(0, 0), 1)
	var access_ids: Array = gs.call("get_access_ids", Vector2i(0, 0))
	_check(
		access_ids.is_empty(),
		"commit_access before init does not register — get_access_ids still empty"
	)
	gs.call("clear_access", Vector2i(0, 0), 1)

	# Grid must still be usable after a valid init() call following these
	# rejected pre-init calls — proves no corrupted partial state leaked
	# through.
	gs.call("init", 3, 3)
	_check(
		gs.call("get_dimensions") == Vector2i(3, 3),
		"grid initializes normally after rejected pre-init mutator calls"
	)
	_check(
		gs.call("get_occupant_id", Vector2i(0, 0)) == -1,
		"post-init state is clean — no leaked pre-init mutation"
	)


# === get_transformed_cells before init — regression for BUG-GS-001 ===
# This method never reads _width/_height, so the guard was previously a
# complete no-op for it: calling it before init() silently returned a
# fully-computed, valid-looking transform instead of the documented empty
# result.

func _test_get_transformed_cells_before_init_returns_empty() -> void:
	print("\n[GUARD] get_transformed_cells before init returns empty (not a computed result)")

	var GS: Script = load("res://src/systems/grid_system.gd") as Script
	var gs: RefCounted = GS.new()
	# Deliberately skip init()

	var fp: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0)]
	var ac: Array[Vector2i] = [Vector2i(0, 1)]
	var result: Dictionary = gs.call("get_transformed_cells", fp, ac, Vector2i(5, 5), 0)
	var fp_world: Array = result["footprint"] as Array
	var ac_world: Array = result["access"] as Array

	_check(
		fp_world.is_empty() and ac_world.is_empty(),
		"get_transformed_cells before init returns empty footprint/access, not a computed transform"
	)


# === commit_occupant(-1) sentinel rejection — regression ===
# occupant_id=-1 is the reserved empty sentinel. Committing it would make
# an occupied cell indistinguishable from an empty one.

func _test_commit_occupant_rejects_sentinel_value() -> void:
	print("\n[REGRESSION] commit_occupant(-1) is rejected — reserved empty sentinel")

	var gs := _make_grid(3, 3)

	var ok: bool = gs.call("commit_occupant", Vector2i(1, 1), -1)
	_check(not ok, "commit_occupant(cell, -1) returns false")
	_check(
		gs.call("get_occupant_id", Vector2i(1, 1)) == -1,
		"cell remains empty (-1) — not corrupted by the rejected commit"
	)

	# The cell must still be genuinely empty and available for a real commit
	var ok2: bool = gs.call("commit_occupant", Vector2i(1, 1), 5)
	_check(ok2, "cell still accepts a legitimate commit after rejected -1 attempt")


# === init() dimension validation — regression ===
# Non-positive width/height must be rejected without marking the system
# initialized, so a caller can retry with valid values.

func _test_init_rejects_non_positive_dimensions() -> void:
	print("\n[GUARD] init() rejects non-positive width/height")

	var GS: Script = load("res://src/systems/grid_system.gd") as Script

	var gs_zero: RefCounted = GS.new()
	gs_zero.call("init", 0, 5)
	_check(
		gs_zero.call("get_dimensions") == Vector2i(0, 0),
		"init(0, 5) rejected — dimensions remain (0,0), not marked initialized"
	)

	var gs_neg: RefCounted = GS.new()
	gs_neg.call("init", 5, -2)
	_check(
		gs_neg.call("get_dimensions") == Vector2i(0, 0),
		"init(5, -2) rejected — dimensions remain (0,0), not marked initialized"
	)

	# A rejected invalid init() must not block a subsequent valid init() —
	# the system was never marked initialized, so this is a fresh attempt,
	# not a double-init.
	gs_zero.call("init", 4, 4)
	_check(
		gs_zero.call("get_dimensions") == Vector2i(4, 4),
		"valid init() succeeds after a rejected non-positive attempt"
	)


# === SimSystem abstract-instantiation guard (ADR-0001 Validation Criterion #1) ===
# This harness has no push_error-capture utility (SceneTree + hand-rolled
# _check(), not GUT), so this test cannot assert the guard's push_error
# fired — only that direct SimSystem construction doesn't crash (the guard
# logs, it does not halt) and that GridSystem, a concrete subclass, remains
# fully usable (proving the guard's get_script() == SimSystem check does
# not fire for subclasses).

func _test_sim_system_base_class_not_directly_instantiable() -> void:
	print("\n[GUARD] SimSystem base class guard does not crash on direct instantiation")

	var Base: Script = load("res://src/systems/sim_system.gd") as Script
	var base_instance: RefCounted = Base.new()
	_check(
		base_instance != null,
		"SimSystem.new() does not crash (guard logs via push_error, does not halt)"
	)

	# A concrete subclass must remain fully usable — proves the guard's
	# get_script() == SimSystem check correctly does not fire for GridSystem.
	var gs := _make_grid(2, 2)
	_check(
		gs.call("system_name") == "GridSystem",
		"GridSystem.system_name() returns 'GridSystem' — subclass unaffected by base guard"
	)
	_check(
		gs.call("get_dimensions") == Vector2i(2, 2),
		"GridSystem remains fully functional after the base-class guard check"
	)
