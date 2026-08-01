# tests/unit/grid_system/grid_can_place_test.gd
# Story 004: Placement Validation — can_place
# Covers AC-C6.1..C6.5, AC-C5.2..C5.5 (blocking ACs), plus guard paths
# (before-init, empty footprint, illegal rotation).
# Run standalone: godot --headless --script tests/unit/grid_system/grid_can_place_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

# FailCode mirror — MUST stay in sync with GridSystem.FailCode (TR-GS-015).
# Local consts instead of GridSystem.FailCode.X references to match the
# existing test style (grid_rotation_test.gd uses literal rotation ints too);
# the numeric equality is asserted explicitly, which is what AC-C6.4's
# "assertion on the enum value itself" requires.
const VALID := 0
const OUT_OF_BOUNDS := 1
const BLOCKED_BY_ROOM_GEOMETRY := 2
const OVERLAPS_EXISTING_EQUIPMENT := 3
const ACCESS_OUT_OF_BOUNDS := 4
const ACCESS_BLOCKED_BY_ROOM_GEOMETRY := 5

# Rotation values mirror GridSystem.Rotation (degree-valued).
const R0 := 0
const R90 := 90
const R180 := 180
const R270 := 270

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
	print("  UNIT TEST: GridSystem — Placement Validation (Story 004)")
	print("=".repeat(48))

	_test_ac_c6_1_footprint_out_of_bounds()
	_test_ac_c6_2_footprint_blocked_by_room_geometry()
	_test_ac_c6_3_footprint_overlaps_existing_equipment()
	_test_ac_c6_4_access_out_of_bounds_distinct_code()
	_test_ac_c6_5_can_place_is_pure_no_side_effects()
	_test_ac_c5_2_access_overlap_allowed()
	_test_ac_c5_3_access_blocked_by_room_geometry()
	_test_ac_c5_4_access_on_footprint_allowed()
	_test_ac_c5_5_zero_access_cells_legal()
	_test_guard_can_place_before_init()
	_test_guard_empty_footprint_rejected()
	_test_guard_illegal_rotation_rejected()

	print("\n=== GRID CAN_PLACE TEST: %d passed, %d failed ===" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


# === Helpers ===

func _make_grid(width: int, height: int) -> RefCounted:
	var GS: Script = load("res://src/systems/grid_system.gd") as Script
	var gs: RefCounted = GS.new()
	gs.call("init", width, height)
	return gs


## Makes every cell buildable — most can_place tests care about occupancy /
## access, not room geometry, so start from an all-open room.
func _make_open_grid(width: int, height: int) -> RefCounted:
	var gs := _make_grid(width, height)
	for y in height:
		for x in width:
			gs.call("set_buildable", Vector2i(x, y), true)
	gs.call("freeze_buildable")
	return gs


## Runs can_place() and returns the PlacementCheckResult object.
## All call sites go through this helper so a signature change breaks one
## place instead of every test body.
func _can_place(
	gs: RefCounted,
	fp: Array[Vector2i],
	ac: Array[Vector2i],
	anchor: Vector2i,
	rot: int
) -> RefCounted:
	return gs.call("can_place", fp, ac, anchor, rot)


## Builds a full-grid snapshot via the PUBLIC read API only — occupant_id,
## buildable, and access_ids for every cell. get_snapshot() itself is Story
## 006 (GridSnapshot, out of scope); this stand-in satisfies AC-C6.5's
## "full-grid snapshot before and after is exactly equal" with the read
## surface available today.
func _full_snapshot(gs: RefCounted) -> Dictionary:
	var dims: Vector2i = gs.call("get_dimensions")
	var occ := {}
	var bld := {}
	var acc := {}
	for y in dims.y:
		for x in dims.x:
			var cell := Vector2i(x, y)
			occ[cell] = gs.call("get_occupant_id", cell)
			bld[cell] = gs.call("get_buildable", cell)
			acc[cell] = gs.call("get_access_ids", cell)
	return {"occupant": occ, "buildable": bld, "access": acc}


# === AC-C6.1: footprint 越界 → OUT_OF_BOUNDS（必须先于其他检查触发） ===

func _test_ac_c6_1_footprint_out_of_bounds() -> void:
	print("\n[AC-C6.1] footprint out of bounds -> OUT_OF_BOUNDS (fires before other checks)")

	var gs := _make_open_grid(10, 10)
	var fp: Array[Vector2i] = [Vector2i(0, 0)]
	var ac: Array[Vector2i] = [Vector2i(0, 1)]

	# All 4 edges independently (QA edge case list).
	var edges := [
		{"anchor": Vector2i(-1, 3), "cell": Vector2i(-1, 3), "label": "left edge (-1,3)"},
		{"anchor": Vector2i(10, 3), "cell": Vector2i(10, 3), "label": "right edge (10,3)"},
		{"anchor": Vector2i(3, -1), "cell": Vector2i(3, -1), "label": "top edge (3,-1)"},
		{"anchor": Vector2i(3, 10), "cell": Vector2i(3, 10), "label": "bottom edge (3,10)"},
	]
	for e in edges:
		var r = _can_place(gs, fp, ac, e["anchor"], R0)
		_check(
			r.valid == false and r.fail_code == OUT_OF_BOUNDS,
			"%s: FAIL OUT_OF_BOUNDS (valid=%s, code=%d)" % [e["label"], r.valid, r.fail_code]
		)
		_check(
			r.fail_cell == e["cell"],
			"%s: fail_cell == %s (got %s)" % [e["label"], e["cell"], r.fail_cell]
		)

	# Corner placement that is PARTIALLY OOB: 1x2 treadmill at (9,9) →
	# footprint cells (9,9) + (9,10); (9,10) is OOB on a 10x10 grid.
	var gs2 := _make_open_grid(10, 10)
	var fp2: Array[Vector2i] = [Vector2i(0, 0), Vector2i(0, 1)]
	var ac2: Array[Vector2i] = [Vector2i(0, 2)]
	var r2 = _can_place(gs2, fp2, ac2, Vector2i(9, 9), R0)
	_check(
		r2.valid == false and r2.fail_code == OUT_OF_BOUNDS,
		"partially-OOB corner: FAIL OUT_OF_BOUNDS (valid=%s, code=%d)" % [r2.valid, r2.fail_code]
	)
	_check(
		r2.fail_cell == Vector2i(9, 10),
		"partially-OOB corner: fail_cell == first OOB cell (9,10) (got %s)" % r2.fail_cell
	)

	# OOB must fire BEFORE the overlap check: the first transformed footprint
	# cell is OOB, the second would overlap an existing occupant. Array order
	# is preserved by get_transformed_cells at R0, so the OOB cell is hit
	# first and OUT_OF_BOUNDS must win over OVERLAPS_EXISTING_EQUIPMENT.
	var gs3 := _make_open_grid(5, 5)
	gs3.call("commit_occupant", Vector2i(4, 4), 1)
	var fp3: Array[Vector2i] = [Vector2i(0, 1), Vector2i(0, 0)]
	var ac3: Array[Vector2i] = [Vector2i(0, 2)]
	var r3 = _can_place(gs3, fp3, ac3, Vector2i(4, 4), R0)
	_check(
		r3.valid == false and r3.fail_code == OUT_OF_BOUNDS,
		"OOB-before-overlap: cell (4,5) OOB checked before (4,4) overlap -> OUT_OF_BOUNDS (code=%d)" % r3.fail_code
	)
	_check(
		r3.fail_cell == Vector2i(4, 5),
		"OOB-before-overlap: fail_cell == (4,5) (got %s)" % r3.fail_cell
	)

	# Control: same fixture fully in bounds is VALID.
	var r_ctrl = _can_place(gs3, fp3, ac3, Vector2i(0, 0), R0)
	_check(
		r_ctrl.valid == true and r_ctrl.fail_code == VALID,
		"control: same footprint anchored at (0,0) is VALID"
	)


# === AC-C6.2: footprint 在 buildable=false 格上 → BLOCKED_BY_ROOM_GEOMETRY ===

func _test_ac_c6_2_footprint_blocked_by_room_geometry() -> void:
	print("\n[AC-C6.2] footprint on buildable=false cell -> BLOCKED_BY_ROOM_GEOMETRY")

	var gs := _make_grid(5, 5)
	for y in 5:
		for x in 5:
			gs.call("set_buildable", Vector2i(x, y), true)
	gs.call("set_buildable", Vector2i(2, 2), false)
	gs.call("set_buildable", Vector2i(3, 3), false)
	gs.call("freeze_buildable")

	var fp: Array[Vector2i] = [Vector2i(0, 0)]
	var ac: Array[Vector2i] = [Vector2i(0, 1)]

	var r = _can_place(gs, fp, ac, Vector2i(2, 2), R0)
	_check(
		r.valid == false and r.fail_code == BLOCKED_BY_ROOM_GEOMETRY,
		"footprint on (2,2) buildable=false -> BLOCKED_BY_ROOM_GEOMETRY (code=%d)" % r.fail_code
	)
	_check(
		r.fail_cell == Vector2i(2, 2),
		"fail_cell == the wall cell (2,2) (got %s)" % r.fail_cell
	)

	# QA edge: verify after buildable is set false on a PREVIOUSLY-DISTINCT
	# cell — (3,3) was true before freeze, now false, placement must fail.
	var r2 = _can_place(gs, fp, ac, Vector2i(3, 3), R0)
	_check(
		r2.valid == false and r2.fail_code == BLOCKED_BY_ROOM_GEOMETRY,
		"footprint on (3,3) (true-then-false) -> BLOCKED_BY_ROOM_GEOMETRY"
	)

	# Control: open cell is VALID on the same grid.
	var r_ctrl = _can_place(gs, fp, ac, Vector2i(0, 0), R0)
	_check(
		r_ctrl.valid == true,
		"control: footprint on open (0,0) is VALID on the same grid"
	)


# === AC-C6.3: footprint 重叠 → OVERLAPS_EXISTING_EQUIPMENT ===

func _test_ac_c6_3_footprint_overlaps_existing_equipment() -> void:
	print("\n[AC-C6.3] footprint overlapping an existing occupant -> OVERLAPS_EXISTING_EQUIPMENT")

	var gs := _make_open_grid(5, 5)
	gs.call("commit_occupant", Vector2i(4, 4), 1)

	var fp: Array[Vector2i] = [Vector2i(0, 0)]
	var ac: Array[Vector2i] = [Vector2i(0, 1)]

	# Exactly overlapping: same single cell (4,4).
	var r_exact = _can_place(gs, fp, ac, Vector2i(4, 4), R0)
	_check(
		r_exact.valid == false and r_exact.fail_code == OVERLAPS_EXISTING_EQUIPMENT,
		"exactly-overlapping placement -> OVERLAPS_EXISTING_EQUIPMENT (code=%d)" % r_exact.fail_code
	)
	_check(
		r_exact.fail_cell == Vector2i(4, 4),
		"exact overlap: fail_cell == (4,4) (got %s)" % r_exact.fail_cell
	)

	# Partially overlapping: HORIZONTAL 1x2 at (3,4) → (3,4)+(4,4); (4,4) occupied.
	var fp2: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0)]
	var ac2: Array[Vector2i] = [Vector2i(0, 2)]
	var r_partial = _can_place(gs, fp2, ac2, Vector2i(3, 4), R0)
	_check(
		r_partial.valid == false and r_partial.fail_code == OVERLAPS_EXISTING_EQUIPMENT,
		"partially-overlapping placement -> OVERLAPS_EXISTING_EQUIPMENT"
	)
	_check(
		r_partial.fail_cell == Vector2i(4, 4),
		"partial overlap: fail_cell == the shared occupied cell (4,4) (got %s)" % r_partial.fail_cell
	)

	# occupant_id=0 regression — never a truthy check (Story 001/002 trap).
	var gs2 := _make_open_grid(3, 3)
	gs2.call("commit_occupant", Vector2i(2, 2), 0)
	var r_zero = _can_place(gs2, fp, ac, Vector2i(2, 2), R0)
	_check(
		r_zero.valid == false and r_zero.fail_code == OVERLAPS_EXISTING_EQUIPMENT,
		"occupant_id=0 still blocks placement (explicit != -1, not truthy)"
	)

	# Control: free cell is VALID.
	var r_ctrl = _can_place(gs, fp, ac, Vector2i(0, 0), R0)
	_check(
		r_ctrl.valid == true,
		"control: free cell placement is VALID"
	)


# === AC-C6.4: access 越界 → ACCESS_OUT_OF_BOUNDS（与 footprint-OOB 不同错误码） ===

func _test_ac_c6_4_access_out_of_bounds_distinct_code() -> void:
	print("\n[AC-C6.4] access cell out of bounds -> ACCESS_OUT_OF_BOUNDS (code != footprint-OOB code)")

	var gs := _make_open_grid(10, 10)
	var fp: Array[Vector2i] = [Vector2i(0, 0)]
	var ac: Array[Vector2i] = [Vector2i(0, 1)]

	# Footprint (9,9) is in bounds; access (9,10) is OOB.
	var r = _can_place(gs, fp, ac, Vector2i(9, 9), R0)
	_check(
		r.valid == false and r.fail_code == ACCESS_OUT_OF_BOUNDS,
		"access OOB -> ACCESS_OUT_OF_BOUNDS (code=%d)" % r.fail_code
	)
	_check(
		r.fail_cell == Vector2i(9, 10),
		"access OOB: fail_cell == the OOB access cell (9,10) (got %s)" % r.fail_cell
	)
	# The whole point of the distinct code: assert the enum VALUE differs
	# from footprint-OOB's value (4 != 1).
	_check(
		r.fail_code != OUT_OF_BOUNDS,
		"access-OOB code %d is DIFFERENT from footprint-OOB code %d (assertion on the enum value itself)" % [r.fail_code, OUT_OF_BOUNDS]
	)

	# Also distinct from BLOCKED_BY_ROOM_GEOMETRY — the code must be the
	# ACCESS_* variant, not the footprint variant, for the same failure mode.
	_check(
		r.fail_code != BLOCKED_BY_ROOM_GEOMETRY,
		"access-OOB is not confused with the footprint geometry code"
	)

	# Control: access moved in-bounds makes it VALID.
	var r_ctrl = _can_place(gs, fp, ac, Vector2i(8, 8), R0)
	_check(
		r_ctrl.valid == true,
		"control: same fixture anchored at (8,8) with access in bounds is VALID"
	)


# === AC-C6.5: can_place 纯函数 —— 调用前后全量快照必须完全相等 ===

func _test_ac_c6_5_can_place_is_pure_no_side_effects() -> void:
	print("\n[AC-C6.5] can_place is pure — full-grid snapshot equal before/after, for valid AND invalid calls")

	var gs := _make_open_grid(5, 5)
	# Varied state: an occupant, an access registration, and nothing else.
	gs.call("commit_occupant", Vector2i(2, 2), 1)
	gs.call("commit_access", Vector2i(0, 3), 1)

	var fp: Array[Vector2i] = [Vector2i(0, 0)]
	var ac: Array[Vector2i] = [Vector2i(0, 1)]

	# --- Invalid call: overlaps the existing occupant ---
	var before_invalid := _full_snapshot(gs)
	var r_invalid = _can_place(gs, fp, ac, Vector2i(2, 2), R0)
	_check(r_invalid.valid == false, "fixture: overlap call is invalid (as expected)")
	var after_invalid := _full_snapshot(gs)
	_check(
		before_invalid == after_invalid,
		"snapshot unchanged after an INVALID can_place (overlap)"
	)

	# --- Invalid call: out of bounds ---
	var before_oob := _full_snapshot(gs)
	var r_oob = _can_place(gs, fp, ac, Vector2i(99, 99), R0)
	_check(r_oob.valid == false, "fixture: OOB call is invalid (as expected)")
	_check(
		before_oob == _full_snapshot(gs),
		"snapshot unchanged after an INVALID can_place (OOB)"
	)

	# --- VALID call: success must also be side-effect free ---
	# Anchor (3,3): footprint (3,3) is free; access (3,4) is in bounds and
	# free on the 5x5 grid (the occupied cell is (2,2), access (0,3)).
	var before_valid := _full_snapshot(gs)
	var r_valid = _can_place(gs, fp, ac, Vector2i(3, 3), R0)
	_check(r_valid.valid == true, "fixture: valid call is valid (as expected)")
	_check(
		before_valid == _full_snapshot(gs),
		"snapshot unchanged after a VALID can_place — success writes nothing"
	)
	# Explicit: the would-be footprint cell is still empty after a valid check.
	_check(
		gs.call("get_occupant_id", Vector2i(3, 3)) == -1,
		"would-be footprint cell (3,3) still empty after valid can_place — no write"
	)
	_check(
		gs.call("get_access_ids", Vector2i(3, 4)).is_empty(),
		"would-be access cell (3,4) has no access_ids after valid can_place — no write"
	)


# === AC-C5.2: access 重叠允许 —— 同一 access 格被多台器械共享 ===

func _test_ac_c5_2_access_overlap_allowed() -> void:
	print("\n[AC-C5.2] access overlap allowed — identical access cell, different footprints, all succeed")

	var gs := _make_open_grid(10, 10)
	# A occupies footprint (0,0) with access (0,1) — simulated via the raw
	# write primitives (commit() itself is Story 005, out of scope).
	gs.call("commit_occupant", Vector2i(0, 0), 1)
	gs.call("commit_access", Vector2i(0, 1), 1)

	var ac_shared: Array[Vector2i] = [Vector2i(0, 1)]

	# B: same access cell, different footprint (1,0).
	var fp_b: Array[Vector2i] = [Vector2i(1, 0)]
	var r_b = _can_place(gs, fp_b, ac_shared, Vector2i(0, 0), R0)
	_check(
		r_b.valid == true and r_b.fail_code == VALID,
		"B with same access cell (0,1) as A -> VALID (no access-overlap failure)"
	)

	# Edge: 3+ equipments sharing the same access cell.
	var fp_c: Array[Vector2i] = [Vector2i(2, 0)]
	var r_c = _can_place(gs, fp_c, ac_shared, Vector2i(0, 0), R0)
	var fp_d: Array[Vector2i] = [Vector2i(3, 0)]
	var r_d = _can_place(gs, fp_d, ac_shared, Vector2i(0, 0), R0)
	_check(
		r_c.valid == true and r_d.valid == true,
		"C and D (3rd/4th sharers of access (0,1)) are both VALID — no cap, no conflict"
	)

	# Edge: after A is cleared, the access cell still accepts new sharers.
	gs.call("clear_occupant", Vector2i(0, 0))
	gs.call("clear_access", Vector2i(0, 1), 1)
	var r_after = _can_place(gs, fp_b, ac_shared, Vector2i(0, 0), R0)
	_check(
		r_after.valid == true,
		"after A cleared, B still VALID on shared access (0,1)"
	)


# === AC-C5.3: access 压在 buildable=false 格上 → ACCESS_BLOCKED_BY_ROOM_GEOMETRY ===

func _test_ac_c5_3_access_blocked_by_room_geometry() -> void:
	print("\n[AC-C5.3] access on buildable=false cell -> ACCESS_BLOCKED_BY_ROOM_GEOMETRY, no writes")

	var gs := _make_grid(5, 5)
	for y in 5:
		for x in 5:
			gs.call("set_buildable", Vector2i(x, y), true)
	gs.call("set_buildable", Vector2i(3, 3), false)
	gs.call("freeze_buildable")

	var fp: Array[Vector2i] = [Vector2i(0, 0)]
	var ac: Array[Vector2i] = [Vector2i(3, 3)]  # access lands on the wall

	var before := _full_snapshot(gs)
	var r = _can_place(gs, fp, ac, Vector2i(0, 0), R0)
	_check(
		r.valid == false and r.fail_code == ACCESS_BLOCKED_BY_ROOM_GEOMETRY,
		"access (3,3) on buildable=false -> ACCESS_BLOCKED_BY_ROOM_GEOMETRY (code=%d)" % r.fail_code
	)
	_check(
		r.fail_cell == Vector2i(3, 3),
		"fail_cell == the wall access cell (3,3) (got %s)" % r.fail_cell
	)
	_check(
		before == _full_snapshot(gs),
		"no grid writes occur — snapshot unchanged"
	)

	# Edge: mixed access — one valid access + one wall access. The wall cell
	# must still fail the placement; the valid access doesn't rescue it.
	var ac_mixed: Array[Vector2i] = [Vector2i(0, 1), Vector2i(3, 3)]
	var r_mixed = _can_place(gs, fp, ac_mixed, Vector2i(0, 0), R0)
	_check(
		r_mixed.valid == false and r_mixed.fail_code == ACCESS_BLOCKED_BY_ROOM_GEOMETRY,
		"mixed access (valid (0,1) + wall (3,3)) -> ACCESS_BLOCKED_BY_ROOM_GEOMETRY"
	)
	_check(
		r_mixed.fail_cell == Vector2i(3, 3),
		"mixed access: fail_cell == the wall cell (3,3) (got %s)" % r_mixed.fail_cell
	)

	# Control: footprint-only access (no access cells) avoids the wall check.
	var ac_empty: Array[Vector2i] = []
	var r_ctrl = _can_place(gs, fp, ac_empty, Vector2i(0, 0), R0)
	_check(
		r_ctrl.valid == true,
		"control: no access cells -> VALID (wall is only in the access set)"
	)


# === AC-C5.4: access 压在别的 footprint 上允许 ===

func _test_ac_c5_4_access_on_footprint_allowed() -> void:
	print("\n[AC-C5.4] access on another equipment's footprint is allowed")

	var gs := _make_open_grid(5, 5)
	# Equipment A's footprint occupies (4,4).
	gs.call("commit_occupant", Vector2i(4, 4), 1)

	# B's access set contains (4,4) — A's footprint cell.
	var fp_b: Array[Vector2i] = [Vector2i(0, 0)]
	var ac_b: Array[Vector2i] = [Vector2i(4, 4)]
	var r = _can_place(gs, fp_b, ac_b, Vector2i(0, 0), R0)
	_check(
		r.valid == true and r.fail_code == VALID,
		"B access-on-A-footprint -> VALID (no occupancy check on access cells)"
	)

	# Simulated commit of B (real commit() is Story 005): the AC's post-state
	# must hold — (4,4) occupant_id still A, access_ids now contains B.
	gs.call("commit_occupant", Vector2i(0, 0), 2)
	gs.call("commit_access", Vector2i(4, 4), 2)
	_check(
		gs.call("get_occupant_id", Vector2i(4, 4)) == 1,
		"after B placed: (4,4) occupant_id is STILL A (1) — access did not steal the cell"
	)
	_check(
		(gs.call("get_access_ids", Vector2i(4, 4)) as Array).has(2),
		"after B placed: (4,4) access_ids contains B (2)"
	)

	# QA edge: after clearing BOTH, the cell returns to a clean state.
	gs.call("clear_occupant", Vector2i(0, 0))
	gs.call("clear_access", Vector2i(4, 4), 2)
	gs.call("clear_occupant", Vector2i(4, 4))
	gs.call("clear_access", Vector2i(4, 4), 1)
	_check(
		gs.call("get_occupant_id", Vector2i(4, 4)) == -1,
		"after clearing both: (4,4) occupant_id back to -1 (clean)"
	)
	_check(
		(gs.call("get_access_ids", Vector2i(4, 4)) as Array).is_empty(),
		"after clearing both: (4,4) access_ids empty (clean)"
	)


# === AC-C5.5: 0 个 access cells 合法（装饰物/储物柜） ===

func _test_ac_c5_5_zero_access_cells_legal() -> void:
	print("\n[AC-C5.5] equipment with access_cells=[] is legal")

	var gs := _make_open_grid(5, 5)
	var fp: Array[Vector2i] = [Vector2i(0, 0)]
	var ac_empty: Array[Vector2i] = []

	var r = _can_place(gs, fp, ac_empty, Vector2i(0, 0), R0)
	_check(
		r.valid == true and r.fail_code == VALID,
		"access_cells=[] -> VALID (access loop skipped, not crashed)"
	)

	# Simulated commit: placement succeeds, and no access is registered.
	gs.call("commit_occupant", Vector2i(0, 0), 7)
	_check(
		gs.call("get_occupant_id", Vector2i(0, 0)) == 7,
		"commit succeeds for the zero-access equipment"
	)
	_check(
		(gs.call("get_access_ids", Vector2i(0, 0)) as Array).is_empty(),
		"no access_ids registered anywhere for this id — get_access_ids((0,0)) is []"
	)
	# NOTE: AC-C5.5's get_access_cells(id) == [] and grid_changed's
	# access_cells_changed == [] (not null) are GridStateReader (Story 006)
	# and grid_changed (Story 008) contracts — out of scope here, verified
	# at the cell level with the API available today.


# === Guard: use-before-init（Control Manifest Foundation 层强制） ===

func _test_guard_can_place_before_init() -> void:
	print("\n[GUARD] can_place before init() returns invalid, does not crash")

	var GS: Script = load("res://src/systems/grid_system.gd") as Script
	var gs: RefCounted = GS.new()
	# Deliberately skip init().

	var fp: Array[Vector2i] = [Vector2i(0, 0)]
	var ac: Array[Vector2i] = [Vector2i(0, 1)]
	var r = _can_place(gs, fp, ac, Vector2i(0, 0), R0)
	_check(
		r != null and r.valid == false,
		"can_place before init returns a non-null invalid result (valid=%s)" % (r.valid if r != null else "null")
	)
	_check(
		r.fail_code == OUT_OF_BOUNDS,
		"before-init safe default fail_code == OUT_OF_BOUNDS (0x0 grid contains nothing) (got %d)" % r.fail_code
	)


# === Guard: 空 footprint 是编程错误（AC-D5.3 的 can_place 侧拦截） ===

func _test_guard_empty_footprint_rejected() -> void:
	print("\n[GUARD] empty footprint_cells is rejected with the safe default")

	var gs := _make_open_grid(5, 5)
	var fp_empty: Array[Vector2i] = []
	var ac: Array[Vector2i] = [Vector2i(0, 1)]

	var r = _can_place(gs, fp_empty, ac, Vector2i(0, 0), R0)
	_check(
		r.valid == false,
		"empty footprint -> invalid (valid=%s)" % r.valid
	)
	_check(
		not (gs.call("get_occupant_id", Vector2i(0, 0)) != -1),
		"empty-footprint rejection writes nothing"
	)


# === Guard: 非法 rotation 不能静默通过（否则空 transform 会虚过 footprint 循环） ===

func _test_guard_illegal_rotation_rejected() -> void:
	print("\n[GUARD] illegal rotation values are rejected, never vacuously VALID")

	var gs := _make_open_grid(5, 5)
	var fp: Array[Vector2i] = [Vector2i(0, 0)]
	var ac: Array[Vector2i] = [Vector2i(0, 1)]

	for illegal in [45, -90, 360]:
		var r = _can_place(gs, fp, ac, Vector2i(0, 0), illegal)
		_check(
			r.valid == false,
			"rotation=%d -> invalid (never silently VALID via empty transform)" % illegal
		)
		_check(
			r.fail_code == OUT_OF_BOUNDS,
			"rotation=%d -> safe default OUT_OF_BOUNDS (got %d)" % [illegal, r.fail_code]
		)

	# Control: legal rotations still place fine.
	var r0 = _can_place(gs, fp, ac, Vector2i(0, 0), R0)
	var r90 = _can_place(gs, fp, ac, Vector2i(0, 0), R90)
	_check(
		r0.valid == true and r90.valid == true,
		"control: legal rotations R0/R90 still VALID"
	)
