# tests/unit/placement_system/instance_id_resume_test.gd
# Story 004: instance_id Resume After Load
# (production/epics/placement-system/story-004-instance-id-resume-after-load.md)
#
# Covers the BLOCKING ACs:
#   - AC11  loaded snapshot with zero occupants -> resume completes ->
#          next_instance_id == 0 (brand-new boot AND loaded-empty-grid save)
#   - AC12  loaded occupant_ids = {0, 2, 5} -> next_instance_id == 6 — id 0
#          counted as present, never treated as empty (the `!= -1` rule; a
#          truthy `if occupant_id:` check would fail the {0}-alone edge)
#   - AC13  stray stored counter 999 ignored; grid max occupant id 3 ->
#          next_instance_id == 4 — re-derived from grid occupancy, never a
#          stored counter (defense-in-depth)
# plus the QA edge cases ({0} alone -> 1; {1,2} with no 0 -> 3; stray
# smaller than reality -> always trusts grid), resume-on-EVERY-load (not
# boot-only), the TR-PS-007 static surface check (no serialize/deserialize),
# and the before-init guard contract.
#
# Run standalone: godot --headless --script tests/unit/placement_system/instance_id_resume_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

# Rotation values mirror GridSystem.Rotation (degree-valued).
const R0 := 0

# Grid dimensions — 13x10 = 130 cells, matching the story's "full grid scan
# (trivial at 130 cells)" note. The resume scan covers every cell.
const GRID_W := 13
const GRID_H := 10

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
	print("  UNIT TEST: PlacementSystem — instance_id Resume After Load (Story 004)")
	print("=".repeat(48))

	_test_ac11_empty_grid_resume()
	_test_ac11_loaded_empty_save()
	_test_ac12_loaded_ids_0_2_5()
	_test_ac12_id_zero_alone()
	_test_ac12_ids_1_2_no_zero()
	_test_ac13_stray_counter_999()
	_test_ac13_stray_smaller_than_reality()
	_test_resume_runs_on_every_load()
	_test_tr_ps_007_no_serialize_surface()
	_test_guard_before_init()

	print("\n=== PLACEMENT instance_id RESUME TEST: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


# === Helpers ===

## Builds an all-open grid (every cell buildable, frozen) — resume tests
## care about occupancy, not room geometry.
func _make_open_grid(width: int, height: int) -> RefCounted:
	var GS: Script = load("res://src/systems/grid_system.gd") as Script
	var gs: RefCounted = GS.new()
	gs.call("init", width, height)
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


## Builds a grid_system save payload holding one single-cell footprint per
## id in [ids], at distinct row-0 positions (footprint at (2i, 0), access at
## (2i+1, 0) — no footprint overlap, all in bounds for GRID_W). This is the
## "loaded snapshot" the ACs describe: the grid state rederive_counter()
## reads is produced by GridSystem.deserialize() — the exact production path
## SaveLoad drives before calling PlacementSystem.rederive_counter().
func _blob_with_ids(width: int, height: int, ids: Array) -> Dictionary:
	var records: Array = []
	for i in ids.size():
		var id: int = int(ids[i])
		var x := i * 2
		records.append({
			"instance_id": id,
			"footprint_cells": [[x, 0]],
			"access_cells": [[x + 1, 0]],
			"rotation": R0,
		})
	return {"schema_version": 1, "width": width, "height": height, "records": records}


func _deserialize(gs: RefCounted, data: Dictionary, snap: PackedByteArray, mode: String) -> RefCounted:
	return gs.call("deserialize", data, snap, mode)


## Builds a PlacementSystem wired to [grid]. The catalog dependency is null:
## Story 004's resume logic never touches the catalog — ADR-0001's
## init(grid, catalog) signature is locked now for Story 001's drag
## lifecycle, which is the first catalog consumer.
func _make_placement(grid: RefCounted) -> RefCounted:
	var PS: Script = load("res://src/systems/placement_system.gd") as Script
	var ps: RefCounted = PS.new()
	ps.call("init", grid, null)
	return ps


func _next_id(ps: RefCounted) -> int:
	return int(ps.call("get_next_instance_id"))


# === AC11 — 空网格恢复 ===

## Brand-new game boot: a fresh grid that was never loaded has zero
## occupants (every cell -1) -> next_instance_id == 0.
func _test_ac11_empty_grid_resume() -> void:
	print("\n[AC11] 空网格恢复 — brand-new grid (never loaded): next_instance_id == 0")
	var gs := _make_open_grid(GRID_W, GRID_H)
	var ps := _make_placement(gs)
	ps.call("rederive_counter")
	_check(
		_next_id(ps) == 0,
		"AC11: empty brand-new grid -> next_instance_id == 0 (got %d)" % _next_id(ps)
	)


## Loaded empty-grid save: deserialize with zero records produces the same
## all-empty grid -> next_instance_id == 0.
func _test_ac11_loaded_empty_save() -> void:
	print("\n[AC11] 空网格恢复 — loaded empty-grid save: next_instance_id == 0")
	var gs := _make_open_grid(GRID_W, GRID_H)
	var result: RefCounted = _deserialize(gs, _blob_with_ids(GRID_W, GRID_H, []), _open_snapshot(GRID_W, GRID_H), "commit")
	_check(bool(result.get("success")), "AC11: empty-save load itself succeeds")
	var ps := _make_placement(gs)
	ps.call("rederive_counter")
	_check(
		_next_id(ps) == 0,
		"AC11: loaded empty grid -> next_instance_id == 0 (got %d)" % _next_id(ps)
	)


# === AC12 — id 0 被正确计数 ===

## Loaded occupant_ids = {0, 2, 5}: next_instance_id == 6 — specifically
## confirming id 0 is counted as present, not treated as empty.
func _test_ac12_loaded_ids_0_2_5() -> void:
	print("\n[AC12] 加载 occupant_ids = {0, 2, 5}: next_instance_id == 6 (id 0 被计数)")
	var gs := _make_open_grid(GRID_W, GRID_H)
	var result: RefCounted = _deserialize(gs, _blob_with_ids(GRID_W, GRID_H, [0, 2, 5]), _open_snapshot(GRID_W, GRID_H), "commit")
	_check(bool(result.get("success")), "AC12: {0,2,5} load succeeds")
	var ps := _make_placement(gs)
	ps.call("rederive_counter")
	_check(
		_next_id(ps) == 6,
		"AC12: {0,2,5} -> next_instance_id == 6 (got %d)" % _next_id(ps)
	)


## QA edge — occupant_ids = {0} alone: next == 1 (not 0). This is the case
## that catches a truthy `if occupant_id:` check: id 0 is the ONLY occupant,
## so a truthy check would skip it and report an empty grid (next == 0)
## instead of next == 1.
func _test_ac12_id_zero_alone() -> void:
	print("\n[AC12-edge] occupant_ids = {0} alone: next_instance_id == 1 (not 0)")
	var gs := _make_open_grid(GRID_W, GRID_H)
	var result: RefCounted = _deserialize(gs, _blob_with_ids(GRID_W, GRID_H, [0]), _open_snapshot(GRID_W, GRID_H), "commit")
	_check(bool(result.get("success")), "AC12-edge: {0} load succeeds")
	var ps := _make_placement(gs)
	ps.call("rederive_counter")
	_check(
		_next_id(ps) == 1,
		"AC12-edge: {0} -> next_instance_id == 1 (got %d)" % _next_id(ps)
	)


## QA edge — ids {1, 2} with no 0: next == 3 (max(S) + 1 without id 0).
func _test_ac12_ids_1_2_no_zero() -> void:
	print("\n[AC12-edge] occupant_ids = {1, 2} (no 0): next_instance_id == 3")
	var gs := _make_open_grid(GRID_W, GRID_H)
	var result: RefCounted = _deserialize(gs, _blob_with_ids(GRID_W, GRID_H, [1, 2]), _open_snapshot(GRID_W, GRID_H), "commit")
	_check(bool(result.get("success")), "AC12-edge: {1,2} load succeeds")
	var ps := _make_placement(gs)
	ps.call("rederive_counter")
	_check(
		_next_id(ps) == 3,
		"AC12-edge: {1,2} -> next_instance_id == 3 (got %d)" % _next_id(ps)
	)


# === AC13 — 忽略残留计数器值 ===

## Stray stored counter 999 (corruption/legacy), grid max occupant id 3:
## next_instance_id == 4 — re-derived from grid occupancy, stray 999 ignored.
func _test_ac13_stray_counter_999() -> void:
	print("\n[AC13] 残留计数器 999 被忽略: grid max occupant 3 -> next_instance_id == 4")
	var gs := _make_open_grid(GRID_W, GRID_H)
	var result: RefCounted = _deserialize(gs, _blob_with_ids(GRID_W, GRID_H, [0, 1, 3]), _open_snapshot(GRID_W, GRID_H), "commit")
	_check(bool(result.get("success")), "AC13: {0,1,3} load succeeds")
	var ps := _make_placement(gs)
	# Inject the stray/desynced counter value via the white-box seam — this
	# is the AC13 precondition: production has no path that writes a counter,
	# so only the seam can construct a drifted state (see _test_set_next_instance_id).
	ps.call("_test_set_next_instance_id", 999)
	ps.call("rederive_counter")
	_check(
		_next_id(ps) == 4,
		"AC13: stray 999 ignored -> next_instance_id == 4 (got %d)" % _next_id(ps)
	)


## QA edge — stray value SMALLER than reality (stray 1, actual max 5):
## always trusts the grid -> next 6.
func _test_ac13_stray_smaller_than_reality() -> void:
	print("\n[AC13-edge] 残留计数器 1, 实际 max 5: next_instance_id == 6 (始终信任网格)")
	var gs := _make_open_grid(GRID_W, GRID_H)
	var result: RefCounted = _deserialize(gs, _blob_with_ids(GRID_W, GRID_H, [0, 5]), _open_snapshot(GRID_W, GRID_H), "commit")
	_check(bool(result.get("success")), "AC13-edge: {0,5} load succeeds")
	var ps := _make_placement(gs)
	ps.call("_test_set_next_instance_id", 1)
	ps.call("rederive_counter")
	_check(
		_next_id(ps) == 6,
		"AC13-edge: stray 1, actual max 5 -> next_instance_id == 6 (got %d)" % _next_id(ps)
	)


# === Resume runs on EVERY load, not just boot ===

## A second load with a smaller grid re-derives DOWN: a boot-only resume
## would leave the counter at 6 from the first load; every-load resume
## recomputes to 1 from {0}.
func _test_resume_runs_on_every_load() -> void:
	print("\n[EVERY-LOAD] resume 每次 load 重算, 非仅 boot")
	var gs := _make_open_grid(GRID_W, GRID_H)
	var ps := _make_placement(gs)

	var r1: RefCounted = _deserialize(gs, _blob_with_ids(GRID_W, GRID_H, [0, 2, 5]), _open_snapshot(GRID_W, GRID_H), "commit")
	_check(bool(r1.get("success")), "EVERY-LOAD: first load ({0,2,5}) succeeds")
	ps.call("rederive_counter")
	_check(_next_id(ps) == 6, "EVERY-LOAD: after first load -> next_instance_id == 6")

	var r2: RefCounted = _deserialize(gs, _blob_with_ids(GRID_W, GRID_H, [0]), _open_snapshot(GRID_W, GRID_H), "commit")
	_check(bool(r2.get("success")), "EVERY-LOAD: second load ({0}) succeeds")
	ps.call("rederive_counter")
	_check(
		_next_id(ps) == 1,
		"EVERY-LOAD: after second load -> next_instance_id == 1 (recomputed, not carried; got %d)" % _next_id(ps)
	)


# === TR-PS-007 — PlacementSystem 不向存档写任何数据 ===

## Static surface check: the system exposes no serialize()/deserialize(),
## so it can never contribute a payload to the save blob (ADR-0002).
func _test_tr_ps_007_no_serialize_surface() -> void:
	print("\n[TR-PS-007] PlacementSystem 不向存档写数据 — 无 serialize/deserialize")
	var ps := _make_placement(_make_open_grid(GRID_W, GRID_H))
	_check(not ps.has_method("serialize"), "TR-PS-007: no serialize() on PlacementSystem")
	_check(not ps.has_method("deserialize"), "TR-PS-007: no deserialize() on PlacementSystem")


# === Guard contract (SimSystem / Control Manifest) ===

## Public methods before init() are loud no-ops returning safe defaults —
## never a crash.
func _test_guard_before_init() -> void:
	print("\n[GUARD] before-init: safe defaults, no crash")
	var PS: Script = load("res://src/systems/placement_system.gd") as Script
	var ps: RefCounted = PS.new()  # deliberately skip init()
	ps.call("rederive_counter")    # must be a loud no-op
	_check(
		_next_id(ps) == 0,
		"GUARD: get_next_instance_id() before init -> 0 (safe default)"
	)
