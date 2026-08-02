# tests/unit/placement_system/commit_success_test.gd
# Story 002: Commit-on-Drop — Success Path
# Covers AC6, AC10, AC21 (blocking) + QA edge cases (zero-move drop, corner
# cell, mixed cancel types, failed drags never consume ids).
#
# Spy discipline (GDD engine note): GDScript lambda closures do NOT write back
# outer-scope locals — every "emitted exactly once" assertion uses a RefCounted
# counter class connected as a signal spy (CommittedSpy / RejectedSpy /
# GridChangedSpy below), never a lambda.
#
# Run standalone: godot --headless --script tests/unit/placement_system/commit_success_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const GRID_PATH := "res://src/systems/grid_system.gd"
const CATALOG_PATH := "res://src/systems/equipment_catalog.gd"
const EQUIPMENT_DEF_PATH := "res://src/systems/equipment_def.gd"
const PLACEMENT_PATH := "res://src/systems/placement_system.gd"
const SPY_GRID_PATH := "res://tests/unit/placement_system/commit_spy_grid.gd"

# Rotation values mirror GridSystem.Rotation (degree-valued).
const R0 := 0
const R90 := 90
const R180 := 180
const R270 := 270

var _pass := 0
var _fail := 0


## RefCounted counter spy for placement_committed (S3, 3 args). The grid
## reference lets the handler record whether GridSystem.commit() had already
## returned at emit time (AC21 ordering assertion).
class CommittedSpy extends RefCounted:
	var count: int = 0
	var last_instance_id: int = -1
	var last_equipment_id: String = ""
	var last_footprint: Array = []
	var grid: RefCounted = null
	var emitted_after_commit_return: bool = false

	func on_committed(instance_id: int, equipment_id: String, footprint_cells: Array) -> void:
		count += 1
		last_instance_id = instance_id
		last_equipment_id = equipment_id
		last_footprint = footprint_cells.duplicate()
		if grid != null:
			emitted_after_commit_return = bool(grid.get("commit_returned"))


## RefCounted counter spy for placement_rejected (S4, 4 args). Success path
## must never fire it (AC21).
class RejectedSpy extends RefCounted:
	var count: int = 0
	var last_equipment_id: String = ""
	var last_anchor: Vector2i = Vector2i.ZERO
	var last_rotation: int = -1
	var last_fail_code: int = -1

	func on_rejected(equipment_id: String, anchor: Vector2i, rotation: int, fail_code: int) -> void:
		count += 1
		last_equipment_id = equipment_id
		last_anchor = anchor
		last_rotation = rotation
		last_fail_code = fail_code


## RefCounted counter spy for grid_changed (S1, 2 args). GridSystem's own
## signal — PlacementSystem must never emit it (Core Rule 5).
class GridChangedSpy extends RefCounted:
	var count: int = 0
	var last_footprint: Array = []
	var last_access: Array = []

	func on_grid_changed(footprint_changed: Array, access_changed: Array) -> void:
		count += 1
		last_footprint = footprint_changed.duplicate()
		last_access = access_changed.duplicate()


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
	print("  UNIT TEST: PlacementSystem — Commit-on-Drop Success Path (Story 002)")
	print("=".repeat(48))

	_test_ac6_full_commit_sequence()
	_test_ac6_edge_zero_mouse_moves()
	_test_ac6_edge_corner_cell()
	_test_ac10_cancels_never_consume_ids()
	_test_ac21_signal_semantics()

	print("\n=== PLACEMENT COMMIT SUCCESS TEST: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


# === Helpers ===

## Builds an open spy grid (all cells buildable, frozen) — commit/clear tests
## care about occupancy, not room geometry. The spy records every commit()
## call so the test can assert exact args (AC6) and emit ordering (AC21).
func _make_open_spy_grid(width: int, height: int) -> RefCounted:
	var Spy: Script = load(SPY_GRID_PATH) as Script
	var gs: RefCounted = Spy.new()
	gs.call("init", width, height)
	for y in height:
		for x in width:
			gs.call("set_buildable", Vector2i(x, y), true)
	gs.call("freeze_buildable")
	return gs


## Builds a frozen EquipmentCatalog holding the given defs (internal loader
## API — exactly how the JSON loader populates then freezes it).
func _make_catalog(defs: Array) -> RefCounted:
	var cat: RefCounted = (load(CATALOG_PATH) as Script).new()
	for d in defs:
		cat.call("_add_definition", d)
	cat.call("_freeze")
	return cat


## Canonical treadmill_01 def: 1×2 footprint + 1 access cell below (the GDD's
## canonical treadmill shape), min offset (0,0) — anchor convention satisfied.
func _make_treadmill_def() -> RefCounted:
	var ED: Script = load(EQUIPMENT_DEF_PATH) as Script
	var zone: Array = ["cardio"]
	var footprint: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0)]
	var access: Array[Vector2i] = [Vector2i(0, 1)]
	var effects: Array[Dictionary] = [{"tag": "cardio", "magnitude": 1.0}]
	return ED.new(
		"treadmill_01", "Treadmill", zone, footprint, access,
		350, "", effects, 200, 30, 100, 300
	)


## Builds a PlacementSystem wired to [grid] + [catalog].
func _make_placement(grid: RefCounted, catalog: RefCounted) -> RefCounted:
	var p: RefCounted = (load(PLACEMENT_PATH) as Script).new()
	p.call("init", grid, catalog)
	return p


## Wires all three spies to [placement] + [grid]. Returns a Dictionary of
## spies for assertion.
func _wire_spies(placement: RefCounted, grid: RefCounted) -> Dictionary:
	var committed := CommittedSpy.new()
	committed.grid = grid
	var rejected := RejectedSpy.new()
	var grid_changed := GridChangedSpy.new()
	placement.connect("placement_committed", Callable(committed, "on_committed"))
	placement.connect("placement_rejected", Callable(rejected, "on_rejected"))
	grid.connect("grid_changed", Callable(grid_changed, "on_grid_changed"))
	return {"committed": committed, "rejected": rejected, "grid_changed": grid_changed}


## Reads the spy grid's recorded commit() calls.
func _commit_calls(grid: RefCounted) -> Array:
	return grid.get("commit_calls")


# === AC6: 成功提交完整序列 ===

func _test_ac6_full_commit_sequence() -> void:
	print("\n[AC6] DRAGGING treadmill_01, can_place=true → drop commits exactly once, grid_changed once")

	var grid := _make_open_spy_grid(10, 10)
	var catalog := _make_catalog([_make_treadmill_def()])
	var placement := _make_placement(grid, catalog)
	var spies := _wire_spies(placement, grid)

	placement.call("begin_drag", "treadmill_01")
	placement.call("on_mouse_moved", Vector2i(3, 3))
	placement.call("on_drop")

	var calls: Array = _commit_calls(grid)
	_check(calls.size() == 1, "commit() called exactly once (count=%d)" % calls.size())
	if calls.size() == 1:
		var c: Dictionary = calls[0]
		_check(c["instance_id"] == 0, "new instance_id allocated == 0 (first placement)")
		# treadmill_01 canonical [(0,0),(1,0)] + access [(0,1)] at anchor (3,3), R0
		_check(c["footprint_cells"] == [Vector2i(3, 3), Vector2i(4, 3)], "commit footprint_cells == transformed cells [(3,3),(4,3)]")
		_check(c["access_cells"] == [Vector2i(3, 4)], "commit access_cells == transformed cells [(3,4)]")
		_check(c["rotation"] == R0, "commit rotation == R0")
	_check((spies["grid_changed"] as GridChangedSpy).count == 1, "grid_changed fires exactly once (count=%d)" % (spies["grid_changed"] as GridChangedSpy).count)
	_check((spies["committed"] as CommittedSpy).count == 1, "placement_committed fires exactly once (count=%d)" % (spies["committed"] as CommittedSpy).count)
	_check((spies["committed"] as CommittedSpy).emitted_after_commit_return, "placement_committed emitted AFTER GridSystem.commit() returned")
	_check((spies["rejected"] as RejectedSpy).count == 0, "placement_rejected never fires")
	# Grid occupancy via public read surface — the commit actually landed.
	_check(grid.call("get_occupant_id", Vector2i(3, 3)) == 0, "footprint cell (3,3) occupied by id 0")
	_check(grid.call("get_occupant_id", Vector2i(4, 3)) == 0, "footprint cell (4,3) occupied by id 0")
	_check(grid.call("get_occupant_id", Vector2i(3, 4)) == -1, "access cell (3,4) NOT footprint-occupied (access is walkable)")


## QA edge: drop with zero mouse moves since drag start — no cell was ever
## entered, so the drop has nothing to commit: silent cancel, no id, no
## commit, no signal, counter unchanged.
func _test_ac6_edge_zero_mouse_moves() -> void:
	print("\n[AC6 EDGE] drop with zero mouse moves since drag start → silent no-op")

	var grid := _make_open_spy_grid(10, 10)
	var catalog := _make_catalog([_make_treadmill_def()])
	var placement := _make_placement(grid, catalog)
	var spies := _wire_spies(placement, grid)

	placement.call("begin_drag", "treadmill_01")
	placement.call("on_drop")  # no on_mouse_moved ever called

	_check(_commit_calls(grid).is_empty(), "zero-move drop: commit() never called")
	_check((spies["grid_changed"] as GridChangedSpy).count == 0, "zero-move drop: grid_changed never fires")
	_check((spies["committed"] as CommittedSpy).count == 0, "zero-move drop: placement_committed never fires")
	_check((spies["rejected"] as RejectedSpy).count == 0, "zero-move drop: placement_rejected never fires")

	# Control: a subsequent normal drag still works and gets the same id the
	# cancelled drag would have consumed — proves the zero-move drop consumed
	# nothing (AC10 discipline applied to this edge).
	placement.call("begin_drag", "treadmill_01")
	placement.call("on_mouse_moved", Vector2i(1, 1))
	placement.call("on_drop")
	var calls: Array = _commit_calls(grid)
	_check(calls.size() == 1 and calls[0]["instance_id"] == 0, "control: next valid drop commits id 0 — zero-move drop consumed nothing")


## QA edge: drop at the exact grid corner cell (0,0) — in-bounds boundary
## must commit normally.
func _test_ac6_edge_corner_cell() -> void:
	print("\n[AC6 EDGE] drop at exact grid corner cell (0,0)")

	var grid := _make_open_spy_grid(10, 10)
	var catalog := _make_catalog([_make_treadmill_def()])
	var placement := _make_placement(grid, catalog)
	var spies := _wire_spies(placement, grid)

	placement.call("begin_drag", "treadmill_01")
	placement.call("on_mouse_moved", Vector2i(0, 0))
	placement.call("on_drop")

	var calls: Array = _commit_calls(grid)
	_check(calls.size() == 1, "corner drop: commit() called exactly once (count=%d)" % calls.size())
	if calls.size() == 1:
		_check(calls[0]["footprint_cells"] == [Vector2i(0, 0), Vector2i(1, 0)], "corner drop: footprint anchored at (0,0)")
	_check((spies["grid_changed"] as GridChangedSpy).count == 1, "corner drop: grid_changed fires exactly once")
	_check((spies["committed"] as CommittedSpy).count == 1, "corner drop: placement_committed fires exactly once")
	_check(grid.call("get_occupant_id", Vector2i(0, 0)) == 0, "corner drop: (0,0) occupied by id 0")


# === AC10: 取消不消耗 id ===

func _test_ac10_cancels_never_consume_ids() -> void:
	print("\n[AC10] counter=0 + 3 cancelled drags (Esc / out-of-bounds / reject) → 4th commit allocates id 0, counter becomes 1")

	var grid := _make_open_spy_grid(10, 10)
	var catalog := _make_catalog([_make_treadmill_def()])
	var placement := _make_placement(grid, catalog)
	var spies := _wire_spies(placement, grid)

	# Pre-place a blocker at (2,2) so a later drop overlapping it is a REJECT
	# (can_place → OVERLAPS_EXISTING_EQUIPMENT), distinct from the other two
	# cancel types. Not counted in AC10's assertions — snapshot before.
	# NOTE: raw untyped array literals FAIL the Array[Vector2i] parameter
	# check through call() — route through typed locals (same pattern as the
	# existing grid tests' _commit() helper).
	var blocker_fp: Array[Vector2i] = [Vector2i(2, 2)]
	var blocker_ac: Array[Vector2i] = []
	grid.call("commit", 99, blocker_fp, blocker_ac, R0)
	var calls_before: Array = _commit_calls(grid)
	var baseline := calls_before.size()
	# The blocker's own grid_changed fired once during setup — snapshot that
	# count so the cancel-phase assertion measures only the 3 cancelled drags.
	var gc_baseline := (spies["grid_changed"] as GridChangedSpy).count

	# Cancel #1 — Esc (silent cancel).
	placement.call("begin_drag", "treadmill_01")
	placement.call("on_cancel")

	# Cancel #2 — drop out of bounds (can_place → OUT_OF_BOUNDS).
	placement.call("begin_drag", "treadmill_01")
	placement.call("on_mouse_moved", Vector2i(50, 50))
	placement.call("on_drop")

	# Cancel #3 — rejected drop overlapping the blocker (can_place → FAIL).
	placement.call("begin_drag", "treadmill_01")
	placement.call("on_mouse_moved", Vector2i(2, 2))
	placement.call("on_drop")

	# After 3 cancellations: no new commits, no grid_changed, no id consumed.
	# placement_rejected fires EXACTLY once — from Cancel #3 (the REJECTED
	# drop), per ADR-0005 S4 / GDD AC22 (Story 003 union semantics: an
	# in-bounds rejected drop emits placement_rejected once; Esc and OOB
	# drops remain silent cancels that emit nothing). The AC10 invariant —
	# cancellations never consume an instance_id — is unchanged.
	_check(_commit_calls(grid).size() == baseline, "3 cancelled drags: commit() count unchanged (%d)" % _commit_calls(grid).size())
	_check((spies["grid_changed"] as GridChangedSpy).count == gc_baseline, "3 cancelled drags: grid_changed never fires (delta 0)")
	_check((spies["committed"] as CommittedSpy).count == 0, "3 cancelled drags: placement_committed never fires (0)")
	_check((spies["rejected"] as RejectedSpy).count == 1, "3 cancelled drags: placement_rejected fires exactly once — the rejected drop (count=%d)" % (spies["rejected"] as RejectedSpy).count)

	# 4th drag commits successfully → allocated id == N == 0, counter → 1.
	placement.call("begin_drag", "treadmill_01")
	placement.call("on_mouse_moved", Vector2i(5, 5))
	placement.call("on_drop")

	var calls: Array = _commit_calls(grid)
	_check(calls.size() == baseline + 1, "4th drag: one new commit (count=%d)" % calls.size())
	if calls.size() == baseline + 1:
		_check(calls[baseline]["instance_id"] == 0, "4th drag: allocated id == N == 0 (cancellations never consumed an id)")

	# Counter became N+1: the NEXT commit must allocate id 1.
	placement.call("begin_drag", "treadmill_01")
	placement.call("on_mouse_moved", Vector2i(6, 6))
	placement.call("on_drop")
	var calls2: Array = _commit_calls(grid)
	_check(calls2.size() == baseline + 2 and calls2[baseline + 1]["instance_id"] == 1, "counter became N+1 — next commit allocates id 1")


# === AC21: placement_committed 语义 ===

func _test_ac21_signal_semantics() -> void:
	print("\n[AC21] successful commit → placement_committed(N, 'treadmill_01', footprint_cells) exactly once, after commit() returns, no placement_rejected")

	var grid := _make_open_spy_grid(10, 10)
	var catalog := _make_catalog([_make_treadmill_def()])
	var placement := _make_placement(grid, catalog)
	var spies := _wire_spies(placement, grid)

	placement.call("begin_drag", "treadmill_01")
	placement.call("on_mouse_moved", Vector2i(7, 7))
	placement.call("on_drop")

	var committed := spies["committed"] as CommittedSpy
	var rejected := spies["rejected"] as RejectedSpy
	var calls: Array = _commit_calls(grid)

	_check(committed.count == 1, "placement_committed emitted exactly once (count=%d)" % committed.count)
	_check(committed.last_instance_id == 0, "arg order #1: instance_id == N == 0 (got %d)" % committed.last_instance_id)
	_check(committed.last_equipment_id == "treadmill_01", "arg order #2: equipment_id == 'treadmill_01' (got '%s')" % committed.last_equipment_id)
	_check(committed.last_footprint == [Vector2i(7, 7), Vector2i(8, 7)], "arg order #3: footprint_cells == transformed cells [(7,7),(8,7)] (got %s)" % [committed.last_footprint])
	if calls.size() == 1:
		var c: Dictionary = calls[0]
		_check(committed.last_footprint == c["footprint_cells"], "payload footprint_cells matches commit()'s footprint exactly")
	_check(committed.emitted_after_commit_return, "emitted AFTER GridSystem.commit() returned (commit_returned=true at emit time)")
	_check(rejected.count == 0, "placement_rejected never fires (count=%d)" % rejected.count)
