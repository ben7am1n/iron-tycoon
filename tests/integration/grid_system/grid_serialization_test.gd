# tests/integration/grid_system/grid_serialization_test.gd
# Story 007: Serialization and Deserialization
# Covers AC-C8.1 (round-trip equality), AC-C8.2 (rotation preserved),
# AC-C8.3 (deterministic output), AC-C8.3b (output stable across round-trip),
# AC-C8.4..C8.6 (LEVEL_GEOMETRY_MISMATCH), AC-C8.7
# (CORRUPTED_SAVE_OUT_OF_BOUNDS before writes), AC-C8.8
# (CORRUPTED_SAVE_OVERLAP, access overlap allowed), AC-C8.9 (no partial
# recovery), AC-C8.10 (single grid_changed emission), plus the validate-mode
# zero-mutation contract, JSON stringify/parse round-trip (float coercion),
# and the structural strengtheners (schema_version, negative/duplicate ids,
# illegal rotation, empty footprint, malformed cells, snapshot size).
#
# Run standalone: godot --headless --script tests/integration/grid_system/grid_serialization_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

# Rotation values mirror GridSystem.Rotation (degree-valued).
const R0 := 0
const R90 := 90
const R180 := 180
const R270 := 270

# Error categories — mirror GridSystem ERR_* constants.
const ERR_GEOMETRY := "LEVEL_GEOMETRY_MISMATCH"
const ERR_OOB := "CORRUPTED_SAVE_OUT_OF_BOUNDS"
const ERR_OVERLAP := "CORRUPTED_SAVE_OVERLAP"
const ERR_CORRUPT := "CORRUPTED_SAVE"
const ERR_INTERNAL := "INTERNAL_ERROR"

var _pass := 0
var _fail := 0

# grid_changed observation state — reset per _connect_signal().
var _signal_count := 0
var _signal_fp: Array = []
var _signal_ac: Array = []


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
	print("  INTEGRATION TEST: GridSystem — Serialization (Story 007)")
	print("=".repeat(48))

	_test_ac_c8_1_round_trip_equality()
	_test_ac_c8_2_rotation_preserved()
	_test_ac_c8_2_all_four_rotations_round_trip()
	_test_ac_c8_3_deterministic_output()
	_test_ac_c8_3b_output_stable_across_round_trip()
	_test_ac_c8_4_footprint_on_wall()
	_test_ac_c8_5_access_on_wall()
	_test_ac_c8_6_dimension_mismatch()
	_test_ac_c8_7_out_of_bounds_before_write()
	_test_ac_c8_8_footprint_overlap_access_ok()
	_test_ac_c8_9_no_partial_recovery()
	_test_ac_c8_10_single_signal_emission()
	_test_validate_mode_zero_mutation()
	_test_commit_mode_replaces_state()
	_test_json_round_trip_float_coercion()
	_test_unknown_mode_internal_error()
	_test_schema_version_mismatch()
	_test_structural_strengtheners()
	_test_failed_deserialize_no_signal()
	_test_empty_save_no_signal()

	print("\n=== GRID SERIALIZATION TEST: %d passed, %d failed ===\n" % [_pass, _fail])
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


## Makes every cell buildable — these tests care about occupancy/access and
## serialization semantics, not room geometry. Returns the grid AND its
## matching buildable_snapshot.
func _make_open_grid(width: int, height: int) -> RefCounted:
	var gs := _make_grid(width, height)
	for y in height:
		for x in width:
			gs.call("set_buildable", Vector2i(x, y), true)
	gs.call("freeze_buildable")
	return gs


## The buildable_snapshot (PackedByteArray) matching an all-open grid.
func _open_snapshot(width: int, height: int) -> PackedByteArray:
	var snap := PackedByteArray()
	snap.resize(width * height)
	snap.fill(1)
	return snap


## Snapshot with [walls] (Array of Vector2i) set to buildable=0.
func _snapshot_with_walls(width: int, height: int, walls: Array) -> PackedByteArray:
	var snap := _open_snapshot(width, height)
	for cell in walls:
		snap[cell.y * width + cell.x] = 0
	return snap


## Runs commit() through call() so a signature change breaks one place.
func _commit(gs: RefCounted, id: int, fp: Array[Vector2i], ac: Array[Vector2i], rot: int) -> void:
	gs.call("commit", id, fp, ac, rot)


func _clear(gs: RefCounted, id: int) -> void:
	gs.call("clear", id)


func _serialize(gs: RefCounted) -> Dictionary:
	return gs.call("serialize")


func _deserialize(gs: RefCounted, data: Dictionary, snap: PackedByteArray, mode: String) -> RefCounted:
	return gs.call("deserialize", data, snap, mode)


func _result_success(r: RefCounted) -> bool:
	return r.get("success")


func _result_category(r: RefCounted, index: int = 0) -> String:
	var errors: Array = r.get("errors")
	if index >= errors.size():
		return ""
	return errors[index]["category"]


## Full-grid state capture via the PUBLIC read API — occupant_id + access_ids
## per cell. access_ids is a multi-value SET: both sides are sorted so the
## comparison is order-insensitive (A commits in player order, deserialize
## replays in ascending instance_id order — GDD C.5 multi-value semantics).
func _full_state(gs: RefCounted) -> Dictionary:
	var dims: Vector2i = gs.call("get_dimensions")
	var occ := {}
	var acc := {}
	for y in dims.y:
		for x in dims.x:
			var cell := Vector2i(x, y)
			occ[cell] = gs.call("get_occupant_id", cell)
			var ids: Array = gs.call("get_access_ids", cell)
			ids.sort()
			acc[cell] = ids
	return {"dims": dims, "occupant": occ, "access": acc}


func _states_equal(a: Dictionary, b: Dictionary) -> bool:
	if a["dims"] != b["dims"]:
		return false
	if a["occupant"].size() != b["occupant"].size() or a["access"].size() != b["access"].size():
		return false
	for cell in a["occupant"]:
		if a["occupant"][cell] != b["occupant"][cell]:
			return false
	for cell in a["access"]:
		if a["access"][cell] != b["access"][cell]:
			return false
	return true


## Per-instance access cells, sorted by (y,x) — set comparison for AC-C8.1(b)
## (deserialize replays records in ascending id order, so cell order within a
## record may differ from the original commit order; membership is the
## round-trip invariant, per GDD line "格归属").
func _access_cells_sorted(gs: RefCounted, instance_id: int) -> Array:
	var cells: Array = gs.call("get_access_cells", instance_id)
	cells.sort_custom(func(a: Vector2i, b: Vector2i): return a.y < b.y or (a.y == b.y and a.x < b.x))
	return cells


func _connect_signal(gs: RefCounted) -> void:
	_signal_count = 0
	_signal_fp = []
	_signal_ac = []
	var cb := Callable(self, "_on_grid_changed")
	if gs.is_connected("grid_changed", cb):
		gs.disconnect("grid_changed", cb)
	gs.connect("grid_changed", cb)


func _on_grid_changed(fp: Array, ac: Array) -> void:
	_signal_count += 1
	_signal_fp.append_array(fp)
	_signal_ac.append_array(ac)


# === AC-C8.1: round-trip consistency ===

func _test_ac_c8_1_round_trip_equality() -> void:
	print("\n[AC-C8.1] round-trip — commit/clear sequence w/ rotation, 0-access piece, shared access")

	var A := _make_open_grid(13, 10)
	var snap := _open_snapshot(13, 10)

	# Operation sequence: multiple commits + one clear, rotations ≠ 0°,
	# one 0-access-cell piece (id 12, never cleared), one shared access cell
	# (id 9 and id 11 both use (7,1)).
	_commit(A, 5, [Vector2i(0, 0), Vector2i(1, 0)], [Vector2i(0, 1)], R90)
	_commit(A, 2, [Vector2i(3, 0)], [], R0)
	_commit(A, 7, [Vector2i(5, 0), Vector2i(5, 1)], [Vector2i(5, 2)], R270)
	_clear(A, 2)
	_commit(A, 9, [Vector2i(7, 0)], [Vector2i(7, 1)], R180)
	_commit(A, 11, [Vector2i(9, 0)], [Vector2i(7, 1)], R0)  # shared access w/ 9
	_commit(A, 12, [Vector2i(11, 0)], [], R0)  # 0-access-cell piece, survives

	var state_a := _full_state(A)
	var save_a := _serialize(A)

	var B := _make_open_grid(13, 10)
	var result := _deserialize(B, save_a, snap, "commit")

	_check(_result_success(result), "AC-C8.1 deserialize result.success == true")
	_check(_states_equal(state_a, _full_state(B)), "AC-C8.1(a) per-cell occupant_id + access_ids equal for EVERY cell")

	# (b) per-instance_id get_access_cells equal for every committed id.
	var all_ok := true
	for id in [5, 7, 9, 11, 12]:
		if _access_cells_sorted(A, id) != _access_cells_sorted(B, id):
			all_ok = false
			print("    id %d access mismatch: A=%s B=%s" % [id, _access_cells_sorted(A, id), _access_cells_sorted(B, id)])
	_check(all_ok, "AC-C8.1(b) per-instance_id get_access_cells equal for every committed id")

	# And the 0-access piece survived as a record with empty access cells.
	var placed: Array = B.call("get_placed_instances")
	var found_zero_access := false
	for pi in placed:
		if pi.get("access_cells").is_empty():
			found_zero_access = true
	_check(found_zero_access, "AC-C8.1 edge — 0-access-cell piece survives round-trip")


# === AC-C8.2: rotation preserved ===

func _test_ac_c8_2_rotation_preserved() -> void:
	print("\n[AC-C8.2] rotation preserved — commit rotation=90, serialize, deserialize")

	var A := _make_open_grid(13, 10)
	_commit(A, 1, [Vector2i(0, 0)], [Vector2i(0, 1)], R90)
	var save_a := _serialize(A)

	var B := _make_open_grid(13, 10)
	var result := _deserialize(B, save_a, _open_snapshot(13, 10), "commit")
	_check(_result_success(result), "AC-C8.2 deserialize success")

	# Rotation only lives in the reverse index — reading it back through
	# serialize() output (which dumps the reverse index) proves it survived.
	var records: Array = _serialize(B)["records"]
	var found := false
	for rec in records:
		if rec["instance_id"] == 1 and rec["rotation"] == R90:
			found = true
	_check(found, "AC-C8.2 reverse index PlacementRecord.rotation == 90 after round-trip")

	# Cross-check through the public read surface (PlacedInstance.rotation).
	var placed: Array = B.call("get_placed_instances")
	var rot_ok := false
	for pi in placed:
		if pi.get("instance_id") == 1 and pi.get("rotation") == R90:
			rot_ok = true
	_check(rot_ok, "AC-C8.2 cross-check — get_placed_instances().rotation == 90")


func _test_ac_c8_2_all_four_rotations_round_trip() -> void:
	print("\n[AC-C8.2 edge] all 4 rotation values round-trip, twice (save → load → save)")

	var A := _make_open_grid(13, 10)
	_commit(A, 1, [Vector2i(0, 0)], [Vector2i(0, 1)], R0)
	_commit(A, 2, [Vector2i(2, 0)], [Vector2i(2, 1)], R90)
	_commit(A, 3, [Vector2i(4, 0)], [Vector2i(4, 1)], R180)
	_commit(A, 4, [Vector2i(6, 0)], [Vector2i(6, 1)], R270)
	var save_a := _serialize(A)

	var B := _make_open_grid(13, 10)
	_deserialize(B, save_a, _open_snapshot(13, 10), "commit")
	var save_b := _serialize(B)

	# Second round-trip: C loaded from B's output (rotation restored from a
	# prior save — QA edge case).
	var C := _make_open_grid(13, 10)
	_deserialize(C, save_b, _open_snapshot(13, 10), "commit")

	var expected := {1: R0, 2: R90, 3: R180, 4: R270}
	var ok := true
	for rec in _serialize(C)["records"]:
		if expected.has(rec["instance_id"]) and rec["rotation"] != expected[rec["instance_id"]]:
			ok = false
			print("    id %d rotation %d != expected %d" % [rec["instance_id"], rec["rotation"], expected[rec["instance_id"]]])
	_check(ok, "AC-C8.2 all 4 rotations preserved through save→load→save→load")


# === AC-C8.3: deterministic output ===

func _test_ac_c8_3_deterministic_output() -> void:
	print("\n[AC-C8.3] deterministic output — out-of-order ids, two identical instances")

	var build := func(gs: RefCounted) -> void:
		_commit(gs, 5, [Vector2i(1, 0), Vector2i(0, 0)], [Vector2i(0, 1)], R90)
		_commit(gs, 2, [Vector2i(3, 1), Vector2i(3, 0)], [Vector2i(4, 0)], R0)

	var A := _make_open_grid(13, 10)
	build.call(A)
	var B := _make_open_grid(13, 10)
	build.call(B)

	var sa := _serialize(A)
	var sb := _serialize(B)

	_check(sa == sb, "AC-C8.3 A.serialize() == B.serialize() — full deep Dictionary equality")

	# Records sorted by instance_id ascending.
	var records: Array = sa["records"]
	var ids: Array = []
	for rec in records:
		ids.append(rec["instance_id"])
	_check(ids == [2, 5], "AC-C8.3 records sorted by instance_id ascending (commit order was 5, 2)")

	# Cells within each record sorted by (y,x) lexicographic.
	var cells_sorted := true
	for rec in records:
		var fp: Array = rec["footprint_cells"]
		for i in range(1, fp.size()):
			if fp[i - 1][1] > fp[i][1] or (fp[i - 1][1] == fp[i][1] and fp[i - 1][0] > fp[i][0]):
				cells_sorted = false
		var ac: Array = rec["access_cells"]
		for i in range(1, ac.size()):
			if ac[i - 1][1] > ac[i][1] or (ac[i - 1][1] == ac[i][1] and ac[i - 1][0] > ac[i][0]):
				cells_sorted = false
	_check(cells_sorted, "AC-C8.3 within each record, footprint_cells/access_cells sorted by (y,x) lexicographic")

	# JSON projection byte-determinism (control manifest: stringify w/ sort_keys).
	var jsa := JSON.stringify(sa, "", true, true)
	var jsb := JSON.stringify(sb, "", true, true)
	_check(jsa == jsb, "AC-C8.3 JSON.stringify(sort_keys=true, full_precision=true) byte-identical")


# === AC-C8.3b: output stable across round-trip ===

func _test_ac_c8_3b_output_stable_across_round_trip() -> void:
	print("\n[AC-C8.3b] S_A == S_B — serialize output stable after save→load→save")

	var A := _make_open_grid(13, 10)
	_commit(A, 5, [Vector2i(0, 0), Vector2i(0, 1)], [Vector2i(1, 0)], R90)
	_commit(A, 2, [Vector2i(3, 0)], [], R0)
	_commit(A, 9, [Vector2i(5, 0)], [Vector2i(5, 1)], R270)
	var save_a := _serialize(A)

	var B := _make_open_grid(13, 10)
	var result := _deserialize(B, save_a, _open_snapshot(13, 10), "commit")
	var save_b := _serialize(B)

	_check(_result_success(result), "AC-C8.3b deserialize success")
	_check(save_a == save_b, "AC-C8.3b S_A == S_B — full deep Dictionary equality")
	_check(JSON.stringify(save_a, "", true, true) == JSON.stringify(save_b, "", true, true), "AC-C8.3b byte-identical JSON projection")


# === AC-C8.4 / C8.5: LEVEL_GEOMETRY_MISMATCH ===

func _test_ac_c8_4_footprint_on_wall() -> void:
	print("\n[AC-C8.4] LEVEL_GEOMETRY_MISMATCH — footprint cell buildable=false")

	var A := _make_open_grid(13, 10)
	_commit(A, 1, [Vector2i(0, 0)], [Vector2i(1, 0)], R0)
	var save_a := _serialize(A)

	var B := _make_open_grid(13, 10)
	var state_before := _full_state(B)
	var snap := _snapshot_with_walls(13, 10, [Vector2i(0, 0)])
	var result := _deserialize(B, save_a, snap, "commit")

	_check(not _result_success(result), "AC-C8.4 success == false")
	_check(_result_category(result) == ERR_GEOMETRY, "AC-C8.4 errors[0].category == LEVEL_GEOMETRY_MISMATCH")
	_check(_states_equal(state_before, _full_state(B)), "AC-C8.4 grid has no writes")
	_check(B.call("get_placed_instances").is_empty(), "AC-C8.4 no records committed")


func _test_ac_c8_5_access_on_wall() -> void:
	print("\n[AC-C8.5] LEVEL_GEOMETRY_MISMATCH — access cell buildable=false")

	var A := _make_open_grid(13, 10)
	_commit(A, 1, [Vector2i(0, 0)], [Vector2i(1, 0)], R0)
	var save_a := _serialize(A)

	var B := _make_open_grid(13, 10)
	var state_before := _full_state(B)
	var snap := _snapshot_with_walls(13, 10, [Vector2i(1, 0)])
	var result := _deserialize(B, save_a, snap, "commit")

	_check(not _result_success(result), "AC-C8.5 success == false")
	_check(_result_category(result) == ERR_GEOMETRY, "AC-C8.5 errors[0].category == LEVEL_GEOMETRY_MISMATCH (same as footprint — both geometry)")
	_check(_states_equal(state_before, _full_state(B)), "AC-C8.5 grid has no writes")


# === AC-C8.6: dimension mismatch ===

func _test_ac_c8_6_dimension_mismatch() -> void:
	print("\n[AC-C8.6] LEVEL_GEOMETRY_MISMATCH — data.width/height differ from grid")

	# Width mismatch: save from 10-wide grid, load into 13-wide.
	var src := _make_open_grid(10, 10)
	_commit(src, 1, [Vector2i(0, 0)], [Vector2i(0, 1)], R0)
	var save_10 := _serialize(src)

	var B := _make_open_grid(13, 10)
	var state_before := _full_state(B)
	var result := _deserialize(B, save_10, _open_snapshot(13, 10), "commit")
	_check(not _result_success(result), "AC-C8.6 width mismatch → success == false")
	_check(_result_category(result) == ERR_GEOMETRY, "AC-C8.6 width mismatch → LEVEL_GEOMETRY_MISMATCH")
	_check(_states_equal(state_before, _full_state(B)), "AC-C8.6 no records processed, grid unchanged")

	# Height mismatch.
	var src2 := _make_open_grid(13, 9)
	_commit(src2, 1, [Vector2i(0, 0)], [Vector2i(0, 1)], R0)
	var save_h := _serialize(src2)
	var C := _make_open_grid(13, 10)
	var result_h := _deserialize(C, save_h, _open_snapshot(13, 10), "commit")
	_check(_result_category(result_h) == ERR_GEOMETRY, "AC-C8.6 height mismatch → LEVEL_GEOMETRY_MISMATCH")

	# Both mismatch.
	var src3 := _make_open_grid(12, 9)
	_commit(src3, 1, [Vector2i(0, 0)], [Vector2i(0, 1)], R0)
	var save_both := _serialize(src3)
	var D := _make_open_grid(13, 10)
	var result_both := _deserialize(D, save_both, _open_snapshot(13, 10), "commit")
	_check(_result_category(result_both) == ERR_GEOMETRY, "AC-C8.6 both mismatch → LEVEL_GEOMETRY_MISMATCH")


# === AC-C8.7: CORRUPTED_SAVE_OUT_OF_BOUNDS ===

func _test_ac_c8_7_out_of_bounds_before_write() -> void:
	print("\n[AC-C8.7] CORRUPTED_SAVE_OUT_OF_BOUNDS — intercepted before write phase")

	var B := _make_open_grid(13, 10)
	var snap := _open_snapshot(13, 10)

	# col=20 beyond width=13.
	var data_oob := {
		"schema_version": 1, "width": 13, "height": 10,
		"records": [{"instance_id": 1, "footprint_cells": [[20, 0]], "access_cells": [], "rotation": 0}],
	}
	var state_before := _full_state(B)
	var r1 := _deserialize(B, data_oob, snap, "commit")
	_check(not _result_success(r1), "AC-C8.7 col=20 → success == false")
	_check(_result_category(r1) == ERR_OOB, "AC-C8.7 col=20 → CORRUPTED_SAVE_OUT_OF_BOUNDS")
	_check(_states_equal(state_before, _full_state(B)), "AC-C8.7 no PackedArray writes occurred (grid unchanged)")

	# Negative coordinate.
	var data_neg := {
		"schema_version": 1, "width": 13, "height": 10,
		"records": [{"instance_id": 1, "footprint_cells": [[-1, 0]], "access_cells": [], "rotation": 0}],
	}
	var r2 := _deserialize(B, data_neg, snap, "commit")
	_check(_result_category(r2) == ERR_OOB, "AC-C8.7 negative coordinate → CORRUPTED_SAVE_OUT_OF_BOUNDS")

	# Exactly at width (off-by-one): x == 13 is out of bounds.
	var data_edge := {
		"schema_version": 1, "width": 13, "height": 10,
		"records": [{"instance_id": 1, "footprint_cells": [[13, 0]], "access_cells": [], "rotation": 0}],
	}
	var r3 := _deserialize(B, data_edge, snap, "commit")
	_check(_result_category(r3) == ERR_OOB, "AC-C8.7 coordinate at exactly width → CORRUPTED_SAVE_OUT_OF_BOUNDS (off-by-one)")

	# Access cell OOB also intercepted.
	var data_ac_oob := {
		"schema_version": 1, "width": 13, "height": 10,
		"records": [{"instance_id": 1, "footprint_cells": [[0, 0]], "access_cells": [[0, 10]], "rotation": 0}],
	}
	var r4 := _deserialize(B, data_ac_oob, snap, "commit")
	_check(_result_category(r4) == ERR_OOB, "AC-C8.7 access cell y=10 (== height) → CORRUPTED_SAVE_OUT_OF_BOUNDS")
	_check(_states_equal(state_before, _full_state(B)), "AC-C8.7 still zero writes after all OOB attempts")


# === AC-C8.8: CORRUPTED_SAVE_OVERLAP ===

func _test_ac_c8_8_footprint_overlap_access_ok() -> void:
	print("\n[AC-C8.8] CORRUPTED_SAVE_OVERLAP — footprint overlap fails, access overlap OK")

	var B := _make_open_grid(13, 10)
	var snap := _open_snapshot(13, 10)

	# Two records share footprint cell (0,0).
	var data_fp_overlap := {
		"schema_version": 1, "width": 13, "height": 10,
		"records": [
			{"instance_id": 1, "footprint_cells": [[0, 0]], "access_cells": [], "rotation": 0},
			{"instance_id": 2, "footprint_cells": [[0, 0], [1, 0]], "access_cells": [], "rotation": 0},
		],
	}
	var state_before := _full_state(B)
	var r1 := _deserialize(B, data_fp_overlap, snap, "commit")
	_check(not _result_success(r1), "AC-C8.8 footprint overlap → success == false")
	_check(_result_category(r1) == ERR_OVERLAP, "AC-C8.8 footprint overlap → CORRUPTED_SAVE_OVERLAP")
	_check(_states_equal(state_before, _full_state(B)), "AC-C8.8 no writes on overlap failure")

	# Access-cell overlap is LEGAL — two records sharing an access cell load fine.
	var data_ac_shared := {
		"schema_version": 1, "width": 13, "height": 10,
		"records": [
			{"instance_id": 1, "footprint_cells": [[0, 0]], "access_cells": [[2, 0]], "rotation": 0},
			{"instance_id": 2, "footprint_cells": [[1, 0]], "access_cells": [[2, 0]], "rotation": 0},
		],
	}
	var r2 := _deserialize(B, data_ac_shared, snap, "commit")
	_check(_result_success(r2), "AC-C8.8 access-cell overlap does NOT error — load succeeds")
	var acc_at_2_0: Array = B.call("get_access_ids", Vector2i(2, 0))
	acc_at_2_0.sort()
	_check(acc_at_2_0 == [1, 2], "AC-C8.8 shared access cell registered for both ids")

	# Partial overlap also fails.
	var data_partial := {
		"schema_version": 1, "width": 13, "height": 10,
		"records": [
			{"instance_id": 1, "footprint_cells": [[0, 0], [1, 0]], "access_cells": [], "rotation": 0},
			{"instance_id": 2, "footprint_cells": [[1, 0], [2, 0]], "access_cells": [], "rotation": 0},
		],
	}
	var r3 := _deserialize(B, data_partial, snap, "commit")
	_check(_result_category(r3) == ERR_OVERLAP, "AC-C8.8 partial footprint overlap → CORRUPTED_SAVE_OVERLAP")


# === AC-C8.9: no partial recovery ===

func _test_ac_c8_9_no_partial_recovery() -> void:
	print("\n[AC-C8.9] no partial recovery — 5 valid records + 1 overlapping → grid stays empty")

	var B := _make_open_grid(13, 10)
	var snap := _open_snapshot(13, 10)

	var records: Array = []
	for i in range(5):
		records.append({"instance_id": i, "footprint_cells": [[i * 2, 0]], "access_cells": [], "rotation": 0})
	# 6th record overlaps record 0's footprint.
	records.append({"instance_id": 5, "footprint_cells": [[0, 0]], "access_cells": [], "rotation": 0})

	var data := {"schema_version": 1, "width": 13, "height": 10, "records": records}
	var result := _deserialize(B, data, snap, "commit")

	_check(not _result_success(result), "AC-C8.9 success == false (CORRUPTED_SAVE_OVERLAP)")
	_check(_result_category(result) == ERR_OVERLAP, "AC-C8.9 category == CORRUPTED_SAVE_OVERLAP")

	# get_snapshot() shows the initial empty state — NOT "5 committed, 6th failed".
	var snapshot = B.call("get_snapshot")
	_check(snapshot.call("get_placed_instances").is_empty(), "AC-C8.9 get_snapshot().get_placed_instances() empty")
	var occupant_zero: int = snapshot.call("get_occupant_id", Vector2i(0, 0))
	_check(occupant_zero == -1, "AC-C8.9 cell (0,0) still empty — first 5 records did NOT take effect")
	var occupant_two: int = snapshot.call("get_occupant_id", Vector2i(4, 0))
	_check(occupant_two == -1, "AC-C8.9 cell (4,0) (record 2) still empty")


# === AC-C8.10: single signal emission ===

func _test_ac_c8_10_single_signal_emission() -> void:
	print("\n[AC-C8.10] single grid_changed emission — 3 records, payload = union")

	var B := _make_open_grid(13, 10)
	var snap := _open_snapshot(13, 10)

	var records: Array = [
		{"instance_id": 1, "footprint_cells": [[0, 0], [1, 0]], "access_cells": [[0, 1]], "rotation": 0},
		{"instance_id": 2, "footprint_cells": [[3, 0]], "access_cells": [[3, 1], [4, 1]], "rotation": 90},
		{"instance_id": 3, "footprint_cells": [[5, 0], [5, 1]], "access_cells": [], "rotation": 270},
	]
	var data := {"schema_version": 1, "width": 13, "height": 10, "records": records}

	_connect_signal(B)
	var result := _deserialize(B, data, snap, "commit")

	_check(_result_success(result), "AC-C8.10 load succeeds")
	_check(_signal_count == 1, "AC-C8.10 grid_changed fired exactly 1 time (not 3)")

	# Payload covers the union of all 3 records' cell sets.
	var expected_fp := [Vector2i(0, 0), Vector2i(1, 0), Vector2i(3, 0), Vector2i(5, 0), Vector2i(5, 1)]
	var expected_ac := [Vector2i(0, 1), Vector2i(3, 1), Vector2i(4, 1)]
	var covers := true
	for cell in expected_fp:
		if not _signal_fp.has(cell):
			covers = false
	for cell in expected_ac:
		if not _signal_ac.has(cell):
			covers = false
	_check(covers, "AC-C8.10 payload covers union of all 3 records' footprint + access cells")


# === validate mode: zero mutation ===

func _test_validate_mode_zero_mutation() -> void:
	print("\n[validate mode] Phase A only — zero mutation, no signal")

	var A := _make_open_grid(13, 10)
	_commit(A, 1, [Vector2i(0, 0)], [Vector2i(0, 1)], R90)
	var save_a := _serialize(A)

	var B := _make_open_grid(13, 10)
	var state_before := _full_state(B)
	_connect_signal(B)
	var result := _deserialize(B, save_a, _open_snapshot(13, 10), "validate")

	_check(_result_success(result), "validate mode: valid data → success == true")
	_check(_states_equal(state_before, _full_state(B)), "validate mode: zero mutation (grid unchanged)")
	_check(_signal_count == 0, "validate mode: no grid_changed emitted")
	_check(B.call("get_placed_instances").is_empty(), "validate mode: no records committed")

	# Invalid data in validate mode → fail with zero mutation too.
	var snap := _snapshot_with_walls(13, 10, [Vector2i(0, 0)])
	var result2 := _deserialize(B, save_a, snap, "validate")
	_check(not _result_success(result2), "validate mode: invalid data → success == false")
	_check(_result_category(result2) == ERR_GEOMETRY, "validate mode: invalid data → LEVEL_GEOMETRY_MISMATCH")
	_check(_states_equal(state_before, _full_state(B)), "validate mode: invalid data still zero mutation")


# === commit mode replaces existing state ===

func _test_commit_mode_replaces_state() -> void:
	print("\n[commit mode] deserialize replaces pre-existing placements")

	var B := _make_open_grid(13, 10)
	_commit(B, 99, [Vector2i(8, 8)], [Vector2i(8, 9)], R0)  # pre-existing piece

	var data := {
		"schema_version": 1, "width": 13, "height": 10,
		"records": [{"instance_id": 7, "footprint_cells": [[2, 2]], "access_cells": [[2, 3]], "rotation": 0}],
	}
	var result := _deserialize(B, data, _open_snapshot(13, 10), "commit")

	_check(_result_success(result), "commit mode replaces state — success")
	_check(B.call("get_occupant_id", Vector2i(8, 8)) == -1, "pre-existing piece (id 99) cleared")
	_check(B.call("get_occupant_id", Vector2i(2, 2)) == 7, "loaded piece (id 7) present")
	var placed: Array = B.call("get_placed_instances")
	_check(placed.size() == 1 and placed[0].get("instance_id") == 7, "exactly 1 instance after replace")


# === JSON round-trip ===

func _test_json_round_trip_float_coercion() -> void:
	print("\n[JSON] full blob round-trip — stringify(full_precision, sort_keys) → parse → deserialize")

	var A := _make_open_grid(13, 10)
	_commit(A, 5, [Vector2i(0, 0), Vector2i(0, 1)], [Vector2i(1, 0)], R90)
	_commit(A, 2, [Vector2i(3, 0)], [], R0)
	var save_a := _serialize(A)

	# Simulate the SaveLoad blob write: JSON.stringify with the control
	# manifest parameters, then JSON.parse_string (returns floats for all
	# numbers — probed in 4.7.1).
	var json_text := JSON.stringify(save_a, "", true, true)
	var parsed: Variant = JSON.parse_string(json_text)
	_check(parsed is Dictionary, "JSON blob parses back to Dictionary")

	var B := _make_open_grid(13, 10)
	var result := _deserialize(B, parsed as Dictionary, _open_snapshot(13, 10), "commit")
	_check(_result_success(result), "deserialize of JSON-parsed data (floats) succeeds")
	_check(_states_equal(_full_state(A), _full_state(B)), "JSON round-trip state equality")
	var records: Array = _serialize(B)["records"]
	_check(records[0]["instance_id"] == 2 and records[1]["instance_id"] == 5, "JSON round-trip preserves sorted ids")

	# Float coercion: deserialize a record whose id/rotation arrive as floats.
	var float_data := {
		"schema_version": 1.0, "width": 13.0, "height": 10.0,
		"records": [{"instance_id": 5.0, "footprint_cells": [[1.0, 0.0]], "access_cells": [], "rotation": 90.0}],
	}
	var C := _make_open_grid(13, 10)
	var result2 := _deserialize(C, float_data, _open_snapshot(13, 10), "commit")
	_check(_result_success(result2), "float-typed ids/rotations/cells coerce cleanly")


# === unknown mode ===

func _test_unknown_mode_internal_error() -> void:
	print("\n[unknown mode] INTERNAL_ERROR")

	var A := _make_open_grid(13, 10)
	_commit(A, 1, [Vector2i(0, 0)], [Vector2i(0, 1)], R0)
	var save_a := _serialize(A)

	var B := _make_open_grid(13, 10)
	var result := _deserialize(B, save_a, _open_snapshot(13, 10), "bogus")
	_check(not _result_success(result), "unknown mode → success == false")
	_check(_result_category(result) == ERR_INTERNAL, "unknown mode → INTERNAL_ERROR")


# === schema_version ===

func _test_schema_version_mismatch() -> void:
	print("\n[schema] schema_version exact-match")

	var A := _make_open_grid(13, 10)
	_commit(A, 1, [Vector2i(0, 0)], [Vector2i(0, 1)], R0)
	var save_a := _serialize(A)
	save_a["schema_version"] = 2

	var B := _make_open_grid(13, 10)
	var state_before := _full_state(B)
	var result := _deserialize(B, save_a, _open_snapshot(13, 10), "commit")
	_check(not _result_success(result), "schema_version=2 → rejected (MVP exact-match)")
	_check(_result_category(result) == ERR_CORRUPT, "schema_version mismatch → CORRUPTED_SAVE")
	_check(_states_equal(state_before, _full_state(B)), "schema mismatch → zero writes")

	var result2 := _deserialize(B, {"width": 13, "height": 10, "records": []}, _open_snapshot(13, 10), "commit")
	_check(not _result_success(result2), "missing schema_version → rejected")


# === structural strengtheners ===

func _test_structural_strengtheners() -> void:
	print("\n[structural] negative id, duplicate id, illegal rotation, empty footprint, malformed cell, bad snapshot")

	var B := _make_open_grid(13, 10)
	var snap := _open_snapshot(13, 10)
	var state_before := _full_state(B)

	# Negative instance_id.
	var data_neg_id := {
		"schema_version": 1, "width": 13, "height": 10,
		"records": [{"instance_id": -1, "footprint_cells": [[0, 0]], "access_cells": [], "rotation": 0}],
	}
	var r1 := _deserialize(B, data_neg_id, snap, "commit")
	_check(_result_category(r1) == ERR_CORRUPT, "negative instance_id → CORRUPTED_SAVE")

	# Duplicate instance_id.
	var data_dup_id := {
		"schema_version": 1, "width": 13, "height": 10,
		"records": [
			{"instance_id": 1, "footprint_cells": [[0, 0]], "access_cells": [], "rotation": 0},
			{"instance_id": 1, "footprint_cells": [[2, 0]], "access_cells": [], "rotation": 0},
		],
	}
	var r2 := _deserialize(B, data_dup_id, snap, "commit")
	_check(_result_category(r2) == ERR_CORRUPT, "duplicate instance_id → CORRUPTED_SAVE")

	# Illegal rotation.
	var data_bad_rot := {
		"schema_version": 1, "width": 13, "height": 10,
		"records": [{"instance_id": 1, "footprint_cells": [[0, 0]], "access_cells": [], "rotation": 45}],
	}
	var r3 := _deserialize(B, data_bad_rot, snap, "commit")
	_check(_result_category(r3) == ERR_CORRUPT, "illegal rotation 45 → CORRUPTED_SAVE")

	# Empty footprint.
	var data_empty_fp := {
		"schema_version": 1, "width": 13, "height": 10,
		"records": [{"instance_id": 1, "footprint_cells": [], "access_cells": [], "rotation": 0}],
	}
	var r4 := _deserialize(B, data_empty_fp, snap, "commit")
	_check(_result_category(r4) == ERR_CORRUPT, "empty footprint → CORRUPTED_SAVE")

	# Malformed cell (string).
	var data_bad_cell := {
		"schema_version": 1, "width": 13, "height": 10,
		"records": [{"instance_id": 1, "footprint_cells": ["(1, 2)"], "access_cells": [], "rotation": 0}],
	}
	var r5 := _deserialize(B, data_bad_cell, snap, "commit")
	_check(_result_category(r5) == ERR_CORRUPT, "malformed cell (string) → CORRUPTED_SAVE")

	# Too-short buildable_snapshot.
	var short_snap := PackedByteArray()
	short_snap.resize(13 * 10 - 1)
	var r6 := _deserialize(B, {"schema_version": 1, "width": 13, "height": 10, "records": []}, short_snap, "commit")
	_check(_result_category(r6) == ERR_INTERNAL, "short buildable_snapshot → INTERNAL_ERROR")

	# Missing required keys.
	var data_missing := {
		"schema_version": 1, "width": 13, "height": 10,
		"records": [{"instance_id": 1, "footprint_cells": [[0, 0]], "rotation": 0}],  # no access_cells
	}
	var r7 := _deserialize(B, data_missing, snap, "commit")
	_check(_result_category(r7) == ERR_CORRUPT, "record missing access_cells key → CORRUPTED_SAVE")

	_check(_states_equal(state_before, _full_state(B)), "all structural failures left the grid untouched")


# === failed deserialize emits no signal ===

func _test_failed_deserialize_no_signal() -> void:
	print("\n[signal] failed deserialize emits NO grid_changed")

	var A := _make_open_grid(13, 10)
	_commit(A, 1, [Vector2i(0, 0)], [Vector2i(0, 1)], R0)
	var save_a := _serialize(A)

	var B := _make_open_grid(13, 10)
	_connect_signal(B)
	_deserialize(B, save_a, _snapshot_with_walls(13, 10, [Vector2i(0, 0)]), "commit")
	_check(_signal_count == 0, "geometry-mismatch failure → 0 signals")

	_connect_signal(B)
	var data_oob := {
		"schema_version": 1, "width": 13, "height": 10,
		"records": [{"instance_id": 1, "footprint_cells": [[50, 50]], "access_cells": [], "rotation": 0}],
	}
	_deserialize(B, data_oob, _open_snapshot(13, 10), "commit")
	_check(_signal_count == 0, "OOB failure → 0 signals")


# === empty save emits no signal ===

func _test_empty_save_no_signal() -> void:
	print("\n[signal] empty save into empty grid — success, no signal (nothing changed)")

	var B := _make_open_grid(13, 10)
	var snap := _open_snapshot(13, 10)
	_connect_signal(B)
	var result := _deserialize(B, {"schema_version": 1, "width": 13, "height": 10, "records": []}, snap, "commit")
	_check(_result_success(result), "empty save → success == true")
	_check(_signal_count == 0, "empty save into empty grid → no signal (QA edge case)")
