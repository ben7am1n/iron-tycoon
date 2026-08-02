# tests/unit/placement_system/reject_cancel_test.gd
# Story 003: Rejected Drop and Silent Cancel
# Covers AC7/AC8/AC9/AC17/AC22/AC23 (blocking ACs) — the reject/cancel
# branches of PlacementSystem's drop resolution (GDD Core Rule 6,
# TR-PS-004/005, ADR-0003/0005).
#
# Engine notes honored (GDD pinned caveats, Godot 4.7.1):
#   - Signal emission counts use RefCounted counter spy classes, NOT lambda
#     closures (lambda closures do NOT write back outer-scope locals).
#   - placement_rejected arity is exactly 4 (eq_id, anchor, rotation,
#     fail_code); placement_committed is 3. GDScript does not check arity at
#     parse time — a mismatch crashes at runtime, so the handlers here must
#     declare the exact parameter lists.
#   - No commit-call counting via `commit(instance_id, ...)` with untyped
#     array literals through .call() — the repo's documented typed-array
#     boundary trap. The CommitSpyGrid subclass overrides commit() natively.
#
# Run standalone: godot --headless --script tests/unit/placement_system/reject_cancel_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

# FailCode mirror — MUST stay in sync with GridSystem.FailCode (TR-GS-015).
const VALID := 0
const OUT_OF_BOUNDS := 1
const BLOCKED_BY_ROOM_GEOMETRY := 2
const OVERLAPS_EXISTING_EQUIPMENT := 3
const ACCESS_OUT_OF_BOUNDS := 4
const ACCESS_BLOCKED_BY_ROOM_GEOMETRY := 5

# Rotation values mirror GridSystem.Rotation (degree-valued).
const R0 := 0
const R90 := 90

var _pass := 0
var _fail := 0


## 被 tests/headless_runner.gd 托管时立即返回 —— 用例由 runner 调用的 run_all() 驱动。
func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	var result := run_all()
	quit(1 if int(result["fail"]) > 0 else 0)


## 返回 {"pass": int, "fail": int} —— 见 tests/headless_runner.gd 的测试文件契约
func run_all() -> Dictionary:
	print("=".repeat(48))
	print("  UNIT TEST: PlacementSystem — Rejected Drop & Silent Cancel (Story 003)")
	print("=".repeat(48))

	_test_ac7_reject_no_write_overlaps()
	_test_ac7_all_five_fail_codes_no_write()
	_test_ac8_out_of_bounds_drop_silent_cancel()
	_test_ac8_boundary_cell_in_bounds_normal()
	_test_ac9_escape_silent_cancel_valid_cell()
	_test_ac9_escape_silent_cancel_invalid_cell()
	_test_ac17_focus_loss_silent_cancel()
	_test_ac17_focus_loss_same_path_as_escape()
	_test_ac22_rejected_signal_payload()
	_test_ac23_all_cancel_triggers_no_signals()

	print("\n=== PLACEMENT REJECT/CANCEL TEST: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


# === RefCounted counter spies (NOT lambda closures — engine note) ===

## Counts placement_committed emissions and captures the last payload.
class CommittedCounter extends RefCounted:
	var n: int = 0
	var last_instance_id: int = -1
	var last_equipment_id: String = ""
	var last_footprint: Array = []

	func on_committed(instance_id: int, equipment_id: String, footprint_cells: Array[Vector2i]) -> void:
		n += 1
		last_instance_id = instance_id
		last_equipment_id = equipment_id
		last_footprint = footprint_cells.duplicate()


## Counts placement_rejected emissions and captures the last payload —
## arity 4, order (equipment_id, anchor, rotation, fail_code).
class RejectedCounter extends RefCounted:
	var n: int = 0
	var last_equipment_id: String = ""
	var last_anchor: Vector2i = Vector2i.ZERO
	var last_rotation: int = -1
	var last_fail_code: int = -1

	func on_rejected(equipment_id: String, anchor: Vector2i, rotation: int, fail_code: int) -> void:
		n += 1
		last_equipment_id = equipment_id
		last_anchor = anchor
		last_rotation = rotation
		last_fail_code = fail_code


## Counts grid_changed emissions (AC7/8/9/17/23 assert ZERO on reject/cancel).
class GridChangedCounter extends RefCounted:
	var n: int = 0

	func on_changed(_f: Array, _a: Array) -> void:
		n += 1


## Test-local GridSystem subclass that counts commit() calls. Direct native
## override (NOT .call() with untyped arrays) — the repo's typed-array
## boundary trap does not apply to a typed override.
class CommitSpyGrid extends GridSystem:
	var commit_count: int = 0

	func commit(instance_id: int, footprint_cells: Array[Vector2i], access_cells: Array[Vector2i], rotation: Rotation) -> void:
		commit_count += 1
		super(instance_id, footprint_cells, access_cells, rotation)


# === Fixtures ===

## Open grid (all buildable) wrapped in a CommitSpyGrid so commit() calls are
## observable. [blocked_cells] are set non-buildable BEFORE freeze (the only
## legal order — set_buildable after freeze_buildable is a guarded no-op).
func _make_spy_grid(width: int, height: int, blocked_cells: Array = []) -> CommitSpyGrid:
	var g: CommitSpyGrid = CommitSpyGrid.new()
	g.call("init", width, height)
	for y in height:
		for x in width:
			g.call("set_buildable", Vector2i(x, y), true)
	for cell in blocked_cells:
		g.call("set_buildable", cell, false)
	g.call("freeze_buildable")
	return g


func _PS() -> Script:
	return load("res://src/systems/placement_system.gd") as Script


## Builds a valid canonical-0° fixture def (typed arrays required).
func _make_def(id: String, footprint: Array[Vector2i], access: Array[Vector2i]) -> RefCounted:
	var ED: Script = load("res://src/systems/equipment_def.gd") as Script
	var zone: Array = ["cardio"]
	var effects: Array[Dictionary] = [{"tag": "comfort", "magnitude": 0.1}]
	return ED.new(
		id, "Test %s" % id, zone, footprint, access, 200, "", effects,
		200, 30, 100, 300
	)


## Loads a frozen catalog holding the given defs.
func _make_catalog(defs: Array) -> RefCounted:
	var EC: Script = load("res://src/systems/equipment_catalog.gd") as Script
	var cat: RefCounted = EC.new()
	for d in defs:
		cat.call("_add_definition", d)
	cat.call("_freeze")
	return cat


## Builds PlacementSystem wired to [grid] + [catalog], connected to fresh
## spy counters. Returns the system; spies are returned via out-dict.
func _make_ps(grid: RefCounted, catalog: RefCounted, spies: Dictionary) -> RefCounted:
	var ps: RefCounted = _PS().new()
	ps.call("init", grid, catalog)

	var committed := CommittedCounter.new()
	var rejected := RejectedCounter.new()
	var changed := GridChangedCounter.new()
	ps.connect("placement_committed", Callable(committed, "on_committed"))
	ps.connect("placement_rejected", Callable(rejected, "on_rejected"))
	grid.connect("grid_changed", Callable(changed, "on_changed"))

	spies["committed"] = committed
	spies["rejected"] = rejected
	spies["changed"] = changed
	return ps


## 1x2 treadmill (footprint (0,0),(1,0); access (0,1)) — the story fixture.
func _treadmill_def() -> RefCounted:
	return _make_def("treadmill_01", [Vector2i(0, 0), Vector2i(1, 0)], [Vector2i(0, 1)])


## 1x1 dumbbell (footprint (0,0); access (0,1)).
func _dumbbell_def() -> RefCounted:
	return _make_def("dumbbell_01", [Vector2i(0, 0)], [Vector2i(0, 1)])


## 1x1 sticker with EMPTY access — legal per AC-C5.5 (access may be empty);
## used for boundary-cell commit checks where a below-footprint access cell
## would go out of bounds. The empty access array MUST be a typed
## Array[Vector2i] — the repo's documented typed-array parameter boundary
## rejects untyped literals through ED.new().
func _sticker_def() -> RefCounted:
	var ED: Script = load("res://src/systems/equipment_def.gd") as Script
	var zone: Array = []
	var footprint: Array[Vector2i] = [Vector2i(0, 0)]
	var access: Array[Vector2i] = []
	var effects: Array[Dictionary] = []
	return ED.new(
		"sticker_01", "Sticker", zone, footprint, access, 10, "", effects,
		100, 0, 50, 150
	)


## Full-grid occupancy snapshot via the public read API only. Capture BEFORE
## an action and compare with the snapshot taken AFTER to prove zero writes.
func _occupancy_snapshot(gs: RefCounted) -> Dictionary:
	var dims: Vector2i = gs.call("get_dimensions")
	var occ := {}
	for y in dims.y:
		for x in dims.x:
			occ[Vector2i(x, y)] = gs.call("get_occupant_id", Vector2i(x, y))
	return occ


# === AC7: can_place=false → mouse-up → no id, no commit, no grid_changed ===

func _test_ac7_reject_no_write_overlaps() -> void:
	print("\n[AC7] can_place=false (OVERLAPS) → mouse-up: no instance_id, no commit, no grid_changed, drag cleared")

	var grid := _make_spy_grid(10, 10)
	grid.call("commit_occupant", Vector2i(2, 2), 7)
	var catalog := _make_catalog([_treadmill_def()])
	var spies := {}
	var ps := _make_ps(grid, catalog, spies)

	ps.call("begin_drag", "treadmill_01")
	ps.call("on_mouse_moved", Vector2i(2, 2))  # footprint (2,2)+(3,2); (2,2) occupied
	ps.call("on_drop")

	var rejected: RejectedCounter = spies["rejected"]
	var committed: CommittedCounter = spies["committed"]
	var changed: GridChangedCounter = spies["changed"]
	var spy_grid: CommitSpyGrid = grid

	_check(committed.n == 0, "AC7: placement_committed never fires (n=%d)" % committed.n)
	_check(rejected.n == 1, "AC7: placement_rejected fires exactly once (n=%d)" % rejected.n)
	_check(spy_grid.commit_count == 0, "AC7: commit() never called (count=%d)" % spy_grid.commit_count)
	_check(changed.n == 0, "AC7: grid_changed never fires (n=%d)" % changed.n)
	_check(
		grid.call("get_occupant_id", Vector2i(2, 2)) == 7 and grid.call("get_occupant_id", Vector2i(3, 2)) == -1,
		"AC7: grid occupancy unchanged — (2,2) still occupant 7, (3,2) still empty"
	)
	_check(
		grid.call("get_access_ids", Vector2i(2, 3)).is_empty(),
		"AC7: would-be access cell (2,3) still empty — nothing written"
	)

	# Drag state cleared: a fresh drag over a valid cell commits normally and
	# allocates instance_id 0 (the reject consumed no id — AC10 family).
	ps.call("begin_drag", "treadmill_01")
	ps.call("on_mouse_moved", Vector2i(5, 5))
	ps.call("on_drop")
	_check(
		spy_grid.commit_count == 1 and committed.n == 1 and committed.last_instance_id == 0,
		"AC7: drag cleared — fresh valid drop commits with id 0 (commit_count=%d, id=%d)" % [spy_grid.commit_count, committed.last_instance_id]
	)


# === AC7 edge: all 5 FAIL codes produce the same no-write outcome (AC22 passthrough family) ===

func _test_ac7_all_five_fail_codes_no_write() -> void:
	print("\n[AC7 edge] each of the 5 FailCode values → same no-write outcome + raw fail_code passthrough")

	var cases := [
		{
			"label": "OUT_OF_BOUNDS (footprint extends past right edge)",
			"blocked": [],
			"def": _treadmill_def(),
			"cell": Vector2i(9, 9),   # footprint (9,9)+(10,9) → (10,9) OOB
			"code": OUT_OF_BOUNDS,
		},
		{
			"label": "BLOCKED_BY_ROOM_GEOMETRY (footprint on wall)",
			"blocked": [Vector2i(0, 0)],
			"def": _dumbbell_def(),
			"cell": Vector2i(0, 0),
			"code": BLOCKED_BY_ROOM_GEOMETRY,
		},
		{
			"label": "OVERLAPS_EXISTING_EQUIPMENT (footprint on occupant)",
			"blocked": [],
			"def": _dumbbell_def(),
			"cell": Vector2i(4, 4),
			"code": OVERLAPS_EXISTING_EQUIPMENT,
		},
		{
			"label": "ACCESS_OUT_OF_BOUNDS (access below bottom edge)",
			"blocked": [],
			"def": _dumbbell_def(),
			"cell": Vector2i(9, 9),   # footprint (9,9) in bounds; access (9,10) OOB
			"code": ACCESS_OUT_OF_BOUNDS,
		},
		{
			"label": "ACCESS_BLOCKED_BY_ROOM_GEOMETRY (access on wall)",
			"blocked": [Vector2i(0, 1)],
			"def": _dumbbell_def(),
			"cell": Vector2i(0, 0),   # footprint (0,0) open; access (0,1) wall
			"code": ACCESS_BLOCKED_BY_ROOM_GEOMETRY,
		},
	]

	for c in cases:
		var grid := _make_spy_grid(10, 10, c["blocked"])
		if c["code"] == OVERLAPS_EXISTING_EQUIPMENT:
			grid.call("commit_occupant", c["cell"], 3)
		var catalog := _make_catalog([c["def"]])
		var spies := {}
		var ps := _make_ps(grid, catalog, spies)
		var def_id: String = c["def"].get("id")

		ps.call("begin_drag", def_id)
		ps.call("on_mouse_moved", c["cell"])
		ps.call("on_drop")

		var rejected: RejectedCounter = spies["rejected"]
		var committed: CommittedCounter = spies["committed"]
		var changed: GridChangedCounter = spies["changed"]
		var spy_grid: CommitSpyGrid = grid

		var label: String = c["label"]
		_check(
			rejected.n == 1 and rejected.last_fail_code == c["code"],
			"%s: placement_rejected once with RAW fail_code %d (n=%d)" % [label, c["code"], rejected.n]
		)
		_check(
			rejected.last_equipment_id == def_id and rejected.last_anchor == c["cell"] and rejected.last_rotation == R0,
			"%s: payload order (eq_id='%s', anchor=%s, rotation=%d) correct" % [label, rejected.last_equipment_id, rejected.last_anchor, rejected.last_rotation]
		)
		_check(committed.n == 0, "%s: placement_committed never fires" % label)
		_check(spy_grid.commit_count == 0, "%s: commit() never called" % label)
		_check(changed.n == 0, "%s: grid_changed never fires" % label)

		var before: Dictionary = _occupancy_snapshot(grid)
		# Re-run the same rejected drop on a fresh drag to confirm determinism
		# of the no-write outcome; snapshot must still be identical.
		ps.call("begin_drag", def_id)
		ps.call("on_mouse_moved", c["cell"])
		ps.call("on_drop")
		_check(
			before == _occupancy_snapshot(grid),
			"%s: grid occupancy unchanged across repeated rejected drops (zero writes)" % label
		)


# === AC8: mouse-up outside grid bounds → same no-op, silent cancel ===

func _test_ac8_out_of_bounds_drop_silent_cancel() -> void:
	print("\n[AC8] mouse-up outside grid bounds → no id, no commit, no grid_changed, NO signal")

	for edge in [
		{"label": "left (-1,3)", "cell": Vector2i(-1, 3)},
		{"label": "right (10,3)", "cell": Vector2i(10, 3)},
		{"label": "top (3,-1)", "cell": Vector2i(3, -1)},
		{"label": "bottom (3,10)", "cell": Vector2i(3, 10)},
	]:
		var grid := _make_spy_grid(10, 10)
		var catalog := _make_catalog([_treadmill_def()])
		var spies := {}
		var ps := _make_ps(grid, catalog, spies)

		ps.call("begin_drag", "treadmill_01")
		ps.call("on_mouse_moved", edge["cell"])
		ps.call("on_drop")

		var rejected: RejectedCounter = spies["rejected"]
		var committed: CommittedCounter = spies["committed"]
		var changed: GridChangedCounter = spies["changed"]
		var spy_grid: CommitSpyGrid = grid
		var label: String = edge["label"]
		var before: Dictionary = _occupancy_snapshot(grid)

		_check(committed.n == 0, "AC8 [%s]: placement_committed never fires" % label)
		_check(rejected.n == 0, "AC8 [%s]: placement_rejected never fires — silent cancel" % label)
		_check(spy_grid.commit_count == 0, "AC8 [%s]: commit() never called" % label)
		_check(changed.n == 0, "AC8 [%s]: grid_changed never fires" % label)
		_check(
			before == _occupancy_snapshot(grid),
			"AC8 [%s]: grid occupancy unchanged" % label
		)

		# Drag cleared: fresh drag over a valid cell commits normally.
		ps.call("begin_drag", "treadmill_01")
		ps.call("on_mouse_moved", Vector2i(5, 5))
		ps.call("on_drop")
		_check(
			spy_grid.commit_count == 1,
			"AC8 [%s]: drag cleared — subsequent valid drop commits (commit_count=%d)" % [label, spy_grid.commit_count]
		)


# === AC8 edge: drop exactly at the boundary cell → normal resolution ===

func _test_ac8_boundary_cell_in_bounds_normal() -> void:
	print("\n[AC8 edge] drop at boundary cell (in-bounds side) → commits or rejects normally, never silent")

	# Boundary in-bounds cell with a 1x1 empty-access def: commits normally.
	var grid := _make_spy_grid(10, 10)
	var catalog := _make_catalog([_sticker_def()])
	var spies := {}
	var ps := _make_ps(grid, catalog, spies)

	ps.call("begin_drag", "sticker_01")
	ps.call("on_mouse_moved", Vector2i(9, 9))  # in-bounds corner
	ps.call("on_drop")

	var committed: CommittedCounter = spies["committed"]
	var spy_grid: CommitSpyGrid = grid
	_check(
		spy_grid.commit_count == 1 and committed.n == 1,
		"AC8 edge: boundary in-bounds drop COMMITS (commit_count=%d, committed=%d)" % [spy_grid.commit_count, committed.n]
	)

	# Boundary in-bounds cell with a 1x2 def extending OOB: rejects (not silent).
	var grid2 := _make_spy_grid(10, 10)
	var catalog2 := _make_catalog([_treadmill_def()])
	var spies2 := {}
	var ps2 := _make_ps(grid2, catalog2, spies2)

	ps2.call("begin_drag", "treadmill_01")
	ps2.call("on_mouse_moved", Vector2i(9, 9))  # footprint (9,9)+(10,9) → OOB
	ps2.call("on_drop")

	var rejected2: RejectedCounter = spies2["rejected"]
	_check(
		rejected2.n == 1 and rejected2.last_fail_code == OUT_OF_BOUNDS,
		"AC8 edge: boundary drop with OOB-extending footprint REJECTS with OUT_OF_BOUNDS (n=%d, code=%d)" % [rejected2.n, rejected2.last_fail_code]
	)


# === AC9: Escape → silent cancel, regardless of current cell validity ===

func _test_ac9_escape_silent_cancel_valid_cell() -> void:
	print("\n[AC9] Escape over a VALID cell → still silent cancel (not commit), no signal")

	var grid := _make_spy_grid(10, 10)
	var catalog := _make_catalog([_treadmill_def()])
	var spies := {}
	var ps := _make_ps(grid, catalog, spies)

	ps.call("begin_drag", "treadmill_01")
	ps.call("on_mouse_moved", Vector2i(5, 5))  # would-be VALID cell
	ps.call("on_cancel")

	var rejected: RejectedCounter = spies["rejected"]
	var committed: CommittedCounter = spies["committed"]
	var changed: GridChangedCounter = spies["changed"]
	var spy_grid: CommitSpyGrid = grid
	var before: Dictionary = _occupancy_snapshot(grid)

	_check(committed.n == 0, "AC9: placement_committed never fires — Escape over valid cell does NOT commit")
	_check(rejected.n == 0, "AC9: placement_rejected never fires — silent cancel")
	_check(spy_grid.commit_count == 0, "AC9: commit() never called")
	_check(changed.n == 0, "AC9: grid_changed never fires")
	_check(
		before == _occupancy_snapshot(grid),
		"AC9: grid occupancy unchanged"
	)

	# Drag cleared.
	ps.call("begin_drag", "treadmill_01")
	ps.call("on_mouse_moved", Vector2i(5, 5))
	ps.call("on_drop")
	_check(spy_grid.commit_count == 1, "AC9: drag cleared — subsequent valid drop commits (commit_count=%d)" % spy_grid.commit_count)


func _test_ac9_escape_silent_cancel_invalid_cell() -> void:
	print("\n[AC9 edge] Escape over an INVALID cell → same silent cancel")

	var grid := _make_spy_grid(10, 10)
	grid.call("commit_occupant", Vector2i(6, 6), 5)
	var catalog := _make_catalog([_treadmill_def()])
	var spies := {}
	var ps := _make_ps(grid, catalog, spies)

	ps.call("begin_drag", "treadmill_01")
	ps.call("on_mouse_moved", Vector2i(6, 6))  # overlaps occupant 5
	ps.call("on_cancel")

	var rejected: RejectedCounter = spies["rejected"]
	var committed: CommittedCounter = spies["committed"]
	_check(committed.n == 0, "AC9 edge: placement_committed never fires")
	_check(rejected.n == 0, "AC9 edge: placement_rejected never fires — Escape is silent even over an invalid cell")


# === AC17: focus loss → identical to Escape ===

func _test_ac17_focus_loss_silent_cancel() -> void:
	print("\n[AC17] focus-loss/alt-tab/minimize mid-drag → identical to Escape: no id, no commit, no grid_changed, NO signal")

	var grid := _make_spy_grid(10, 10)
	var catalog := _make_catalog([_treadmill_def()])
	var spies := {}
	var ps := _make_ps(grid, catalog, spies)

	ps.call("begin_drag", "treadmill_01")
	ps.call("on_mouse_moved", Vector2i(5, 5))  # would-be VALID cell
	ps.call("on_focus_lost")

	var rejected: RejectedCounter = spies["rejected"]
	var committed: CommittedCounter = spies["committed"]
	var changed: GridChangedCounter = spies["changed"]
	var spy_grid: CommitSpyGrid = grid
	var before: Dictionary = _occupancy_snapshot(grid)

	_check(committed.n == 0, "AC17: placement_committed never fires")
	_check(rejected.n == 0, "AC17: placement_rejected never fires — silent cancel")
	_check(spy_grid.commit_count == 0, "AC17: commit() never called")
	_check(changed.n == 0, "AC17: grid_changed never fires")
	_check(
		before == _occupancy_snapshot(grid),
		"AC17: grid occupancy unchanged"
	)

	# Drag cleared.
	ps.call("begin_drag", "treadmill_01")
	ps.call("on_mouse_moved", Vector2i(5, 5))
	ps.call("on_drop")
	_check(spy_grid.commit_count == 1, "AC17: drag cleared — subsequent valid drop commits (commit_count=%d)" % spy_grid.commit_count)


func _test_ac17_focus_loss_same_path_as_escape() -> void:
	print("\n[AC17 edge] focus loss routes to the SAME cancel path as Escape (identical observable outcome)")

	var grid_esc := _make_spy_grid(10, 10)
	var catalog_esc := _make_catalog([_treadmill_def()])
	var spies_esc := {}
	var ps_esc := _make_ps(grid_esc, catalog_esc, spies_esc)
	ps_esc.call("begin_drag", "treadmill_01")
	ps_esc.call("on_mouse_moved", Vector2i(3, 3))
	ps_esc.call("on_cancel")

	var grid_focus := _make_spy_grid(10, 10)
	var catalog_focus := _make_catalog([_treadmill_def()])
	var spies_focus := {}
	var ps_focus := _make_ps(grid_focus, catalog_focus, spies_focus)
	ps_focus.call("begin_drag", "treadmill_01")
	ps_focus.call("on_mouse_moved", Vector2i(3, 3))
	ps_focus.call("on_focus_lost")

	var esc: RejectedCounter = spies_esc["rejected"]
	var foc: RejectedCounter = spies_focus["rejected"]
	_check(
		esc.n == 0 and foc.n == 0,
		"AC17 edge: Escape and focus-loss both emit zero signals (esc=%d, focus=%d)" % [esc.n, foc.n]
	)
	_check(
		spies_esc["committed"].n == 0 and spies_focus["committed"].n == 0,
		"AC17 edge: placement_committed zero on both paths"
	)
	_check(
		(grid_esc as CommitSpyGrid).commit_count == 0 and (grid_focus as CommitSpyGrid).commit_count == 0,
		"AC17 edge: commit() zero on both paths"
	)


# === AC22: placement_rejected carries fail_code, emitted exactly once ===

func _test_ac22_rejected_signal_payload() -> void:
	print("\n[AC22] OVERLAPS drop → placement_rejected(eq_id, anchor, rotation, OVERLAPS) exactly once; placement_committed never")

	var grid := _make_spy_grid(10, 10)
	# R90 transform of treadmill (union bbox W=2,H=2): footprint (0,0)→(1,0),
	# (1,0)→(1,1); anchor (2,2) → footprint cells (3,2),(3,3). Occupy (3,2)
	# so the ROTATED footprint overlaps — a drop at R0 would have put the
	# occupant on an access cell (legal) and committed instead.
	grid.call("commit_occupant", Vector2i(3, 2), 7)
	var catalog := _make_catalog([_treadmill_def()])
	var spies := {}
	var ps := _make_ps(grid, catalog, spies)

	ps.call("begin_drag", "treadmill_01")
	ps.call("on_mouse_moved", Vector2i(2, 2))
	ps.call("on_rotate_pressed")  # R0 → R90, verify rotation passes through
	ps.call("on_drop")

	var rejected: RejectedCounter = spies["rejected"]
	var committed: CommittedCounter = spies["committed"]
	var changed: GridChangedCounter = spies["changed"]
	var spy_grid: CommitSpyGrid = grid

	_check(rejected.n == 1, "AC22: placement_rejected emitted EXACTLY once (n=%d)" % rejected.n)
	_check(
		rejected.last_equipment_id == "treadmill_01",
		"AC22: arg1 equipment_id == 'treadmill_01' (got '%s')" % rejected.last_equipment_id
	)
	_check(
		rejected.last_anchor == Vector2i(2, 2),
		"AC22: arg2 anchor == (2,2) (got %s)" % rejected.last_anchor
	)
	_check(
		rejected.last_rotation == R90,
		"AC22: arg3 rotation == 90 (rotated once, got %d)" % rejected.last_rotation
	)
	_check(
		rejected.last_fail_code == OVERLAPS_EXISTING_EQUIPMENT,
		"AC22: arg4 fail_code == OVERLAPS_EXISTING_EQUIPMENT raw value (got %d)" % rejected.last_fail_code
	)
	_check(committed.n == 0, "AC22: placement_committed never fires")
	_check(spy_grid.commit_count == 0, "AC22: commit() never called")
	_check(changed.n == 0, "AC22: grid_changed never fires")


# === AC23: every cancel trigger → neither signal (spies both == 0) ===

func _test_ac23_all_cancel_triggers_no_signals() -> void:
	print("\n[AC23] Escape / focus-loss / out-of-bounds drop → placement_committed AND placement_rejected both == 0")

	var triggers := [
		{"label": "Escape", "action": func(ps: RefCounted) -> void: ps.call("on_cancel")},
		{"label": "focus-loss", "action": func(ps: RefCounted) -> void: ps.call("on_focus_lost")},
		{"label": "out-of-bounds drop", "action": func(ps: RefCounted) -> void: ps.call("on_drop")},
	]

	for t in triggers:
		var grid := _make_spy_grid(10, 10)
		var catalog := _make_catalog([_treadmill_def()])
		var spies := {}
		var ps := _make_ps(grid, catalog, spies)

		ps.call("begin_drag", "treadmill_01")
		ps.call("on_mouse_moved", Vector2i(-1, 3))  # OOB cell for the drop case
		t["action"].call(ps)

		var rejected: RejectedCounter = spies["rejected"]
		var committed: CommittedCounter = spies["committed"]
		var changed: GridChangedCounter = spies["changed"]
		var label: String = t["label"]

		_check(
			committed.n == 0 and rejected.n == 0,
			"AC23 [%s]: BOTH spies == 0 (committed=%d, rejected=%d)" % [label, committed.n, rejected.n]
		)
		_check(changed.n == 0, "AC23 [%s]: grid_changed == 0" % label)
		_check(
			(grid as CommitSpyGrid).commit_count == 0,
			"AC23 [%s]: commit() == 0" % label
		)
