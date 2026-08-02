# tests/unit/placement_system/relocate_flow_test.gd
# Story 005: Relocate Flow
# (production/epics/placement-system/story-005-relocate-flow.md)
#
# Covers the BLOCKING ACs:
#   - AC20  API surface: exactly ONE relocate entry point
#          begin_relocate(instance_id); NO inspect/sell methods (static
#          check)
#   - AC24  begin_relocate(N) then cancel (Esc / focus-loss) -> piece
#          restored to (anchor0, rotation0) under the SAME instance_id,
#          occupancy cell-for-cell identical, no new-id signals
#   - AC25  valid drop at anchor1 -> commit(N, def, anchor1, rotation1)
#          same id, grid_changed exactly once, placement_committed(N, eq_id,
#          new_fp), counter unchanged
#   - AC26  can_place FAIL drop -> silent restore (anchor0, rotation0),
#          placement_rejected does NOT fire
#   - AC27  begin_relocate(M) while DRAGGING -> no-op: push_error(), state
#          unchanged, in-flight drag undisturbed, M grid position unchanged
#   - AC30  member-in-use piece: occupancy clears at drag-start (grid_changed
#          fires once = MemberSim equipment-deleted-mid-use trigger); after
#          cancel the grid position is restored but the member's displaced
#          state is NOT reverted
#
# Engine notes honored (GDD pinned caveats, Godot 4.7.1):
#   - Signal emission counts use RefCounted counter spy classes, NOT lambda
#     closures (lambda closures do NOT write back outer-scope locals).
#   - placement_committed arity exactly 3; placement_rejected exactly 4;
#     grid_changed exactly 2 (GridSystem's own signal).
#   - push_error (AC27) is verified via the subprocess probe
#     placement_error_probe.gd ("relocate_while_dragging" mode), the
#     established pattern for error-output assertions.
#
# Run standalone: godot --headless --script tests/unit/placement_system/relocate_flow_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const GRID_PATH := "res://src/systems/grid_system.gd"
const CATALOG_PATH := "res://src/systems/equipment_catalog.gd"
const EQUIPMENT_DEF_PATH := "res://src/systems/equipment_def.gd"
const PLACEMENT_PATH := "res://src/systems/placement_system.gd"
const SPY_GRID_PATH := "res://tests/unit/placement_system/commit_spy_grid.gd"
const PROBE_SCRIPT_PATH := "res://tests/unit/placement_system/placement_error_probe.gd"

# Rotation values mirror GridSystem.Rotation (degree-valued).
const R0 := 0
const R90 := 90
const R180 := 180
const R270 := 270

var _pass := 0
var _fail := 0


## RefCounted counter spy for placement_committed (S3, 3 args).
class CommittedSpy extends RefCounted:
	var count: int = 0
	var last_instance_id: int = -1
	var last_equipment_id: String = ""
	var last_footprint: Array = []

	func on_committed(instance_id: int, equipment_id: String, footprint_cells: Array) -> void:
		count += 1
		last_instance_id = instance_id
		last_equipment_id = equipment_id
		last_footprint = footprint_cells.duplicate()


## RefCounted counter spy for placement_rejected (S4, 4 args). Relocate AC26
## asserts it NEVER fires on a rejected relocate drop.
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


## RefCounted counter spy for grid_changed (S1, 2 args) — GridSystem's own
## signal. Relocate relies on it for BOTH the drag-start clear (AC30's
## member-displacement trigger) and the commit/restore.
class GridChangedSpy extends RefCounted:
	var count: int = 0
	var last_footprint: Array = []
	var last_access: Array = []

	func on_grid_changed(footprint_changed: Array, access_changed: Array) -> void:
		count += 1
		last_footprint = footprint_changed.duplicate()
		last_access = access_changed.duplicate()


## AC30: MemberSim spy — models the MemberSim equipment-deleted-mid-use
## handling that the grid_changed fired by begin_relocate's clear() triggers.
## The spy watches grid_changed; when the watched piece's cells go EMPTY it
## records a displacement (member lost its equipment). The flag is NEVER
## reset by PlacementSystem — the member's displaced state persists after a
## cancel even though the grid position is restored (AC30's accepted cost).
class MemberSimSpy extends RefCounted:
	var grid: RefCounted = null
	var watched_id: int = -1
	var displacement_count: int = 0
	var member_displaced: bool = false

	func on_grid_changed(footprint_changed: Array, access_changed: Array) -> void:
		if grid == null or watched_id < 0:
			return
		# A displacement = the watched piece's footprint cells went EMPTY.
		# The clear() at drag-start fires this exactly once.
		var became_empty := false
		for cell in footprint_changed:
			if int(grid.call("get_occupant_id", cell)) == -1:
				became_empty = true
				break
		if became_empty:
			displacement_count += 1
			member_displaced = true


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
	print("  UNIT TEST: PlacementSystem — Relocate Flow (Story 005)")
	print("=".repeat(48))

	_test_ac20_api_surface()
	_test_ac24_cancel_restore_same_id()
	_test_ac24_focus_loss_restore()
	_test_ac24_edge_rotation_changed_then_cancel()
	_test_ac25_valid_drop_recommit_same_id()
	_test_ac25_edge_same_cell_drop()
	_test_ac25_edge_rotation_r90()
	_test_ac26_rejected_drop_silent_restore()
	_test_ac26_edge_all_fail_codes()
	_test_ac27_dragging_noop()
	_test_ac30_member_displacement_observable()

	print("\n=== PLACEMENT RELOCATE FLOW TEST: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


# === Fixture helpers ===

## Canonical-0° treadmill fixture def (1x2 footprint + 1 access cell).
func _make_treadmill_def() -> RefCounted:
	var ED: Script = load(EQUIPMENT_DEF_PATH) as Script
	var zone: Array = ["cardio"]
	var footprint: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0)]
	var access: Array[Vector2i] = [Vector2i(0, 1)]
	var effects: Array[Dictionary] = []
	return ED.new(
		"treadmill_01", "Test treadmill_01", zone, footprint, access, 200, "", effects,
		200, 30, 100, 300
	)


## 1x1 dumbbell (footprint (0,0); access (0,1)) — for the 5-FAIL-code matrix.
func _dumbbell_def() -> RefCounted:
	var ED: Script = load(EQUIPMENT_DEF_PATH) as Script
	var zone: Array = ["cardio"]
	var footprint: Array[Vector2i] = [Vector2i(0, 0)]
	var access: Array[Vector2i] = [Vector2i(0, 1)]
	var effects: Array[Dictionary] = []
	return ED.new(
		"dumbbell_01", "Test dumbbell_01", zone, footprint, access, 200, "", effects,
		200, 30, 100, 300
	)


## 1x1 sticker with EMPTY access (AC-C5.5 legal) — for OOB/boundary cases.
func _sticker_def() -> RefCounted:
	var ED: Script = load(EQUIPMENT_DEF_PATH) as Script
	var zone: Array = []
	var footprint: Array[Vector2i] = [Vector2i(0, 0)]
	var access: Array[Vector2i] = []
	var effects: Array[Dictionary] = []
	return ED.new(
		"sticker_01", "Sticker", zone, footprint, access, 10, "", effects,
		100, 0, 50, 150
	)


## Open spy grid (every cell buildable, frozen) recording commit() calls.
func _make_spy_grid(width: int, height: int, blocked_cells: Array = []) -> RefCounted:
	var g: RefCounted = (load(SPY_GRID_PATH) as Script).new()
	g.call("init", width, height)
	for y in height:
		for x in width:
			g.call("set_buildable", Vector2i(x, y), true)
	for cell in blocked_cells:
		g.call("set_buildable", cell, false)
	g.call("freeze_buildable")
	return g


## Frozen catalog holding the given defs.
func _make_catalog(defs: Array) -> RefCounted:
	var EC: Script = load(CATALOG_PATH) as Script
	var cat: RefCounted = EC.new()
	for d in defs:
		cat.call("_add_definition", d)
	cat.call("_freeze")
	return cat


## Builds PlacementSystem wired to [grid] + [catalog] with fresh spies.
## Returns the system; spies are returned via out-dict.
func _make_ps(grid: RefCounted, catalog: RefCounted, spies: Dictionary) -> RefCounted:
	var ps: RefCounted = (load(PLACEMENT_PATH) as Script).new()
	ps.call("init", grid, catalog)

	var committed := CommittedSpy.new()
	var rejected := RejectedSpy.new()
	var changed := GridChangedSpy.new()
	ps.connect("placement_committed", Callable(committed, "on_committed"))
	ps.connect("placement_rejected", Callable(rejected, "on_rejected"))
	grid.connect("grid_changed", Callable(changed, "on_grid_changed"))

	spies["committed"] = committed
	spies["rejected"] = rejected
	spies["changed"] = changed
	return ps


## Places [def_id] via the NORMAL placement flow at (anchor, rotation), using
## [rotate_count] presses to reach the rotation. Returns the allocated
## instance_id (the counter's value at commit time). This is the ONLY way to
## create a piece PlacementSystem knows about (its session map is populated
## on commit — GridSystem stores no equipment type).
func _place_piece(ps: RefCounted, grid: RefCounted, def_id: String, anchor: Vector2i, rotate_count: int) -> int:
	var counter_before: int = ps.call("get_next_instance_id")
	ps.call("begin_drag", def_id)
	for i in rotate_count:
		ps.call("on_rotate_pressed")
	ps.call("on_mouse_moved", anchor)
	ps.call("on_drop")
	return counter_before


## Full-grid occupancy snapshot via the public read API only.
func _occupancy_snapshot(gs: RefCounted) -> Dictionary:
	var dims: Vector2i = gs.call("get_dimensions")
	var occ := {}
	for y in dims.y:
		for x in dims.x:
			occ[Vector2i(x, y)] = gs.call("get_occupant_id", Vector2i(x, y))
	return occ


## Reads the spy grid's recorded commit() calls.
func _commit_calls(grid: RefCounted) -> Array:
	return grid.get("commit_calls")


## Runs placement_error_probe.gd in an ISOLATED subprocess so a firing
## push_error() can be observed by its OUTPUT (pattern established by
## drag_lifecycle_test.gd). Returns {"errored": bool, "output": String,
## "exit_code": int} — output is stdout+stderr COMBINED.
func _run_probe(mode: String) -> Dictionary:
	var exe := OS.get_executable_path()
	var project_root := ProjectSettings.globalize_path("res://")
	var probe_path := ProjectSettings.globalize_path(PROBE_SCRIPT_PATH)
	var args: Array[String] = ["--headless", "--path", project_root, "--script", probe_path, "--", mode]
	var output: Array = []
	var exit_code := OS.execute(exe, args, output, true)
	var output_text: String = "".join(output)
	return {"errored": output_text.find("ERROR:") != -1, "output": output_text, "exit_code": exit_code}


# === AC20: API surface — exactly one relocate entry, no inspect/sell ===

func _test_ac20_api_surface() -> void:
	print("\n[AC20] PlacementSystem public API → exactly one relocate entry (begin_relocate); NO inspect/sell methods")

	var script: Script = load(PLACEMENT_PATH) as Script
	var methods: Array = script.get_script_method_list()

	var begin_relocate_count := 0
	var inspect_methods: Array = []
	var sell_methods: Array = []
	for m in methods:
		var name: String = m.get("name", "")
		if name == "begin_relocate":
			begin_relocate_count += 1
		if name.find("inspect") != -1:
			inspect_methods.append(name)
		if name.find("sell") != -1:
			sell_methods.append(name)

	_check(
		begin_relocate_count == 1,
		"exactly one relocate entry point begin_relocate (found %d)" % begin_relocate_count
	)
	# Verify the signature takes a single int instance_id (via a runtime call
	# guard check: the method exists and is callable with an int).
	var ps: RefCounted = (load(PLACEMENT_PATH) as Script).new()
	_check(ps.has_method("begin_relocate"), "begin_relocate is a callable public method")
	_check(
		inspect_methods.is_empty(),
		"no inspect* method on PlacementSystem (SelectionSystem owns inspection) — found: %s" % str(inspect_methods)
	)
	_check(
		sell_methods.is_empty(),
		"no sell* method on PlacementSystem (SelectionSystem owns selling) — found: %s" % str(sell_methods)
	)


# === AC24: cancel restores (anchor0, rotation0) under the SAME id ===

func _test_ac24_cancel_restore_same_id() -> void:
	print("\n[AC24] begin_relocate(N) + Escape → restored to (anchor0, rotation0), same id, cell-for-cell occupancy, no new-id signals")

	var grid := _make_spy_grid(10, 10)
	var catalog := _make_catalog([_make_treadmill_def()])
	var spies := {}
	var ps := _make_ps(grid, catalog, spies)

	# Place treadmill at anchor0=(2,2), R0 → instance_id 0.
	var n: int = _place_piece(ps, grid, "treadmill_01", Vector2i(2, 2), 0)
	var pre_occ := _occupancy_snapshot(grid)
	var counter_after_place: int = ps.call("get_next_instance_id")
	var committed: CommittedSpy = spies["committed"]
	var rejected: RejectedSpy = spies["rejected"]
	var changed: GridChangedSpy = spies["changed"]
	# Snapshot signal counts AFTER the initial placement so the relocate phase
	# is measured in isolation.
	var committed_baseline := committed.count
	var changed_baseline := changed.count

	ps.call("begin_relocate", n)
	# During the drag the piece is ABSENT from the grid (Core Rule 1a).
	_check(
		grid.call("get_occupant_id", Vector2i(2, 2)) == -1 and grid.call("get_occupant_id", Vector2i(3, 2)) == -1,
		"drag-start: occupancy cleared — (2,2)/(3,2) both empty"
	)
	_check(changed.count == changed_baseline + 1, "drag-start: grid_changed fired exactly once (clear) [baseline=%d now=%d]" % [changed_baseline, changed.count])

	ps.call("on_mouse_moved", Vector2i(7, 7))  # would-be valid target
	ps.call("on_cancel")  # Escape

	_check(
		_occupancy_snapshot(grid) == pre_occ,
		"cancel: grid occupancy matches pre-relocate state cell-for-cell"
	)
	_check(
		grid.call("get_occupant_id", Vector2i(2, 2)) == n and grid.call("get_occupant_id", Vector2i(3, 2)) == n,
		"cancel: piece N restored at anchor0 (occupant %d)" % n
	)
	_check(committed.count == committed_baseline, "cancel: NO placement_committed for a new id (count=%d)" % committed.count)
	_check(rejected.count == 0, "cancel: placement_rejected never fires")
	_check(
		ps.call("get_next_instance_id") == counter_after_place,
		"cancel: next_instance_id unchanged (%d)" % ps.call("get_next_instance_id")
	)

	# Drag state fully cleared — a subsequent relocate works from IDLE.
	ps.call("begin_relocate", n)
	_check(grid.call("get_occupant_id", Vector2i(2, 2)) == -1, "after clear: grid empty again (drag resumed cleanly)")


# === AC24 variant: focus-loss cancel ===

func _test_ac24_focus_loss_restore() -> void:
	print("\n[AC24 EDGE] focus-loss cancel → identical restore to Escape")

	var grid := _make_spy_grid(10, 10)
	var catalog := _make_catalog([_make_treadmill_def()])
	var spies := {}
	var ps := _make_ps(grid, catalog, spies)

	var n: int = _place_piece(ps, grid, "treadmill_01", Vector2i(4, 4), 0)
	var pre_occ := _occupancy_snapshot(grid)
	var committed: CommittedSpy = spies["committed"]
	var rejected: RejectedSpy = spies["rejected"]
	var committed_baseline := committed.count

	ps.call("begin_relocate", n)
	ps.call("on_mouse_moved", Vector2i(8, 8))
	ps.call("on_focus_lost")

	_check(
		_occupancy_snapshot(grid) == pre_occ,
		"focus-loss: grid occupancy matches pre-relocate state cell-for-cell"
	)
	_check(
		grid.call("get_occupant_id", Vector2i(4, 4)) == n,
		"focus-loss: piece N restored at anchor0"
	)
	_check(committed.count == committed_baseline, "focus-loss: NO placement_committed")
	_check(rejected.count == 0, "focus-loss: NO placement_rejected")


# === AC24 edge: rotation changed mid-drag, then cancel → restored to rotation0 ===

func _test_ac24_edge_rotation_changed_then_cancel() -> void:
	print("\n[AC24 EDGE] rotate mid-drag then cancel → restored to original rotation₀, not the rotated value")

	var grid := _make_spy_grid(10, 10)
	var catalog := _make_catalog([_make_treadmill_def()])
	var spies := {}
	var ps := _make_ps(grid, catalog, spies)

	# Place at R180 (rotate twice) so rotation0 != R0 is meaningful.
	var n: int = _place_piece(ps, grid, "treadmill_01", Vector2i(2, 2), 2)
	var pre_occ := _occupancy_snapshot(grid)

	ps.call("begin_relocate", n)
	_check(ps.get("_rotation") == R180, "relocate preserves existing rotation (R180, got %d)" % ps.get("_rotation"))
	ps.call("on_rotate_pressed")  # R180 → R270 mid-drag
	ps.call("on_mouse_moved", Vector2i(5, 5))
	ps.call("on_cancel")

	_check(
		_occupancy_snapshot(grid) == pre_occ,
		"cancel after mid-drag rotation: occupancy cell-for-cell identical (restored to rotation₀)"
	)
	# Verify the restored piece's rotation via the recorded commit call.
	var calls: Array = _commit_calls(grid)
	# calls[0] = initial placement, calls[1] = restore commit.
	_check(calls.size() == 2, "two commits total: initial placement + restore (got %d)" % calls.size())
	if calls.size() == 2:
		_check(
			calls[1]["instance_id"] == n and calls[1]["rotation"] == R180,
			"restore commit: same id %d, rotation back to R180 (got rotation %d)" % [n, calls[1]["rotation"]]
		)


# === AC25: valid drop → same-id re-commit, grid_changed once, counter unchanged ===

func _test_ac25_valid_drop_recommit_same_id() -> void:
	print("\n[AC25] begin_relocate(N) + valid drop at anchor1 → commit(N, def, anchor1, rotation1), grid_changed once, placement_committed, counter unchanged")

	var grid := _make_spy_grid(10, 10)
	var catalog := _make_catalog([_make_treadmill_def()])
	var spies := {}
	var ps := _make_ps(grid, catalog, spies)

	var n: int = _place_piece(ps, grid, "treadmill_01", Vector2i(2, 2), 0)
	var counter_after_place: int = ps.call("get_next_instance_id")
	var committed: CommittedSpy = spies["committed"]
	var rejected: RejectedSpy = spies["rejected"]
	var changed: GridChangedSpy = spies["changed"]
	var committed_baseline := committed.count
	var changed_baseline := changed.count

	ps.call("begin_relocate", n)
	_check(grid.call("get_occupant_id", Vector2i(2, 2)) == -1, "drag-start: anchor0 clear")
	_check(changed.count == changed_baseline + 1, "drag-start: grid_changed once (clear) [baseline=%d now=%d]" % [changed_baseline, changed.count])

	ps.call("on_mouse_moved", Vector2i(6, 6))  # anchor1, still R0
	ps.call("on_drop")

	var calls: Array = _commit_calls(grid)
	# calls[0] = initial placement (id n at (2,2)); calls[1] = relocate commit.
	_check(calls.size() == 2, "two commits total: initial + relocate re-commit (got %d)" % calls.size())
	if calls.size() == 2:
		var c: Dictionary = calls[1]
		_check(c["instance_id"] == n, "AC25a: commit() re-uses the SAME instance_id N=%d (got %d)" % [n, c["instance_id"]])
		_check(c["footprint_cells"] == [Vector2i(6, 6), Vector2i(7, 6)], "AC25a: commit footprint == transformed cells at anchor1 [(6,6),(7,6)]")
		_check(c["rotation"] == R0, "AC25a: commit rotation == rotation1 (R0)")
	_check(changed.count == changed_baseline + 2, "AC25b: grid_changed fires exactly once for the new position (clear + commit = 2 total delta) [baseline=%d now=%d]" % [changed_baseline, changed.count])
	_check(committed.count == committed_baseline + 1, "AC25c: placement_committed emitted exactly once for the relocate")
	_check(
		committed.last_instance_id == n and committed.last_equipment_id == "treadmill_01",
		"AC25c: placement_committed(N, 'treadmill_01', new_fp) — id %d, eq '%s'" % [committed.last_instance_id, committed.last_equipment_id]
	)
	_check(
		committed.last_footprint == [Vector2i(6, 6), Vector2i(7, 6)],
		"AC25c: payload == new footprint cells [(6,6),(7,6)]"
	)
	_check(rejected.count == 0, "AC25: placement_rejected never fires")
	_check(
		ps.call("get_next_instance_id") == counter_after_place,
		"AC25e: next_instance_id unchanged (no increment, got %d)" % ps.call("get_next_instance_id")
	)
	# AC25d: occupancy shows N at anchor1, anchor0 clear.
	_check(
		grid.call("get_occupant_id", Vector2i(6, 6)) == n and grid.call("get_occupant_id", Vector2i(7, 6)) == n,
		"AC25d: N occupies anchor1 cells (6,6)/(7,6)"
	)
	_check(
		grid.call("get_occupant_id", Vector2i(2, 2)) == -1 and grid.call("get_occupant_id", Vector2i(3, 2)) == -1,
		"AC25d: anchor0 is clear"
	)


# === AC25 edge: drop at the SAME cell as origin → still re-commits (no-op relocate) ===

func _test_ac25_edge_same_cell_drop() -> void:
	print("\n[AC25 EDGE] drop at the same cell as the origin → relocate no-op still re-commits under same id")

	var grid := _make_spy_grid(10, 10)
	var catalog := _make_catalog([_make_treadmill_def()])
	var spies := {}
	var ps := _make_ps(grid, catalog, spies)

	var n: int = _place_piece(ps, grid, "treadmill_01", Vector2i(3, 3), 0)
	var counter_after_place: int = ps.call("get_next_instance_id")
	var committed: CommittedSpy = spies["committed"]
	var committed_baseline := committed.count

	ps.call("begin_relocate", n)
	ps.call("on_mouse_moved", Vector2i(3, 3))  # same cell
	ps.call("on_drop")

	var calls: Array = _commit_calls(grid)
	_check(calls.size() == 2, "same-cell drop: two commits total (initial + re-commit, got %d)" % calls.size())
	if calls.size() == 2:
		_check(calls[1]["instance_id"] == n, "same-cell drop: same instance_id reused")
		_check(calls[1]["footprint_cells"] == [Vector2i(3, 3), Vector2i(4, 3)], "same-cell drop: footprint unchanged at (3,3)")
	_check(committed.count == committed_baseline + 1, "same-cell drop: placement_committed still emitted (relocate re-commit)")
	_check(
		ps.call("get_next_instance_id") == counter_after_place,
		"same-cell drop: counter unchanged (%d)" % ps.call("get_next_instance_id")
	)


# === AC25 edge: drop after rotating to R90 ===

func _test_ac25_edge_rotation_r90() -> void:
	print("\n[AC25 EDGE] drop after rotating to R90 → commit(N, def, anchor1, R90)")

	var grid := _make_spy_grid(10, 10)
	var catalog := _make_catalog([_make_treadmill_def()])
	var spies := {}
	var ps := _make_ps(grid, catalog, spies)

	var n: int = _place_piece(ps, grid, "treadmill_01", Vector2i(2, 2), 0)
	var counter_after_place: int = ps.call("get_next_instance_id")

	ps.call("begin_relocate", n)
	ps.call("on_mouse_moved", Vector2i(5, 5))
	ps.call("on_rotate_pressed")  # R0 → R90
	ps.call("on_drop")

	var calls: Array = _commit_calls(grid)
	_check(calls.size() == 2, "R90 drop: two commits total (got %d)" % calls.size())
	if calls.size() == 2:
		var c: Dictionary = calls[1]
		_check(c["instance_id"] == n, "R90 drop: same instance_id reused")
		_check(c["rotation"] == R90, "R90 drop: commit rotation == R90 (got %d)" % c["rotation"])
		# treadmill R90 (union bbox 2x2): footprint (0,0)->(1,0), (1,0)->(1,1);
		# anchored at (5,5) → (6,5),(6,6); access (0,1)->(0,1) → (5,6).
		_check(c["footprint_cells"] == [Vector2i(6, 5), Vector2i(6, 6)], "R90 drop: transformed footprint [(6,5),(6,6)]")
	_check(
		ps.call("get_next_instance_id") == counter_after_place,
		"R90 drop: counter unchanged (%d)" % ps.call("get_next_instance_id")
	)


# === AC26: rejected relocate drop → silent restore, NO placement_rejected ===

func _test_ac26_rejected_drop_silent_restore() -> void:
	print("\n[AC26] can_place FAIL at drop → silent restore (anchor0, rotation0), placement_rejected does NOT fire")

	var grid := _make_spy_grid(10, 10)
	var catalog := _make_catalog([_make_treadmill_def()])
	var spies := {}
	var ps := _make_ps(grid, catalog, spies)

	var n: int = _place_piece(ps, grid, "treadmill_01", Vector2i(2, 2), 0)
	var counter_after_place: int = ps.call("get_next_instance_id")
	var committed: CommittedSpy = spies["committed"]
	var rejected: RejectedSpy = spies["rejected"]
	var changed: GridChangedSpy = spies["changed"]
	var committed_baseline := committed.count
	var changed_baseline := changed.count

	# Occupy (7,2) so a drop at (7,2) overlaps (footprint (7,2)+(8,2)).
	grid.call("commit_occupant", Vector2i(7, 2), 42)
	# Snapshot AFTER the blocker so the comparison isolates the relocate phase.
	var pre_occ := _occupancy_snapshot(grid)

	ps.call("begin_relocate", n)
	ps.call("on_mouse_moved", Vector2i(7, 2))  # OVERLAPS_EXISTING_EQUIPMENT
	ps.call("on_drop")

	_check(
		_occupancy_snapshot(grid) == pre_occ,
		"AC26: rejected relocate drop → occupancy cell-for-cell identical to pre-relocate (silent restore)"
	)
	_check(
		grid.call("get_occupant_id", Vector2i(2, 2)) == n and grid.call("get_occupant_id", Vector2i(3, 2)) == n,
		"AC26: piece N restored at anchor0"
	)
	_check(
		grid.call("get_occupant_id", Vector2i(7, 2)) == 42,
		"AC26: blocker at (7,2) untouched"
	)
	_check(rejected.count == 0, "AC26: placement_rejected does NOT fire (relocate reject is silent)")
	_check(committed.count == committed_baseline, "AC26: NO placement_committed")
	_check(
		ps.call("get_next_instance_id") == counter_after_place,
		"AC26: counter unchanged"
	)


# === AC26 edge: all 5 FAIL codes produce identical silent restore ===

func _test_ac26_edge_all_fail_codes() -> void:
	print("\n[AC26 EDGE] each of the 5 FailCode values → identical silent restore (no placement_rejected, no id consumed)")

	# Mirror GridSystem.FailCode (TR-GS-015).
	var OUT_OF_BOUNDS := 1
	var BLOCKED_BY_ROOM_GEOMETRY := 2
	var OVERLAPS_EXISTING_EQUIPMENT := 3
	var ACCESS_OUT_OF_BOUNDS := 4
	var ACCESS_BLOCKED_BY_ROOM_GEOMETRY := 5

	var cases := [
		{
			"label": "OUT_OF_BOUNDS (footprint extends past right edge)",
			"blocked": [],
			"def": _make_treadmill_def(),
			"cell": Vector2i(9, 9),
			"extra_occupant": Vector2i(-1, -1),  # none
		},
		{
			"label": "BLOCKED_BY_ROOM_GEOMETRY (footprint on wall)",
			"blocked": [Vector2i(5, 5)],
			"def": _dumbbell_def(),
			"cell": Vector2i(5, 5),
			"extra_occupant": Vector2i(-1, -1),
		},
		{
			"label": "OVERLAPS_EXISTING_EQUIPMENT (footprint on occupant)",
			"blocked": [],
			"def": _dumbbell_def(),
			"cell": Vector2i(5, 5),
			"extra_occupant": Vector2i(5, 5),
		},
		{
			"label": "ACCESS_OUT_OF_BOUNDS (access below bottom edge)",
			"blocked": [],
			"def": _dumbbell_def(),
			"cell": Vector2i(9, 9),
			"extra_occupant": Vector2i(-1, -1),
		},
		{
			"label": "ACCESS_BLOCKED_BY_ROOM_GEOMETRY (access on wall)",
			"blocked": [Vector2i(0, 1)],
			"def": _dumbbell_def(),
			"cell": Vector2i(0, 0),
			"extra_occupant": Vector2i(-1, -1),
		},
	]

	for c in cases:
		var grid := _make_spy_grid(10, 10, c["blocked"])
		if c["extra_occupant"] != Vector2i(-1, -1):
			grid.call("commit_occupant", c["extra_occupant"], 77)
		var catalog := _make_catalog([c["def"]])
		var spies := {}
		var ps := _make_ps(grid, catalog, spies)
		var def_id: String = c["def"].get("id")

		# Place the piece at a KNOWN-GOOD origin (1,1) for every case so the
		# only failure is the drop target.
		var n: int = _place_piece(ps, grid, def_id, Vector2i(1, 1), 0)
		var pre_occ := _occupancy_snapshot(grid)
		var counter_after: int = ps.call("get_next_instance_id")
		var rejected: RejectedSpy = spies["rejected"]
		var committed: CommittedSpy = spies["committed"]
		var committed_baseline := committed.count  # the initial placement's own signal

		ps.call("begin_relocate", n)
		ps.call("on_mouse_moved", c["cell"])
		ps.call("on_drop")

		var label: String = c["label"]
		_check(
			_occupancy_snapshot(grid) == pre_occ,
			"%s: occupancy cell-for-cell identical (silent restore)" % label
		)
		_check(rejected.count == 0, "%s: placement_rejected never fires" % label)
		_check(
			committed.count == committed_baseline,
			"%s: placement_committed never fires for the relocate (stays at baseline %d)" % [label, committed_baseline]
		)
		_check(
			ps.call("get_next_instance_id") == counter_after,
			"%s: counter unchanged" % label
		)


# === AC27: begin_relocate while DRAGGING → no-op + push_error ===

func _test_ac27_dragging_noop() -> void:
	print("\n[AC27] begin_relocate(M) while DRAGGING → no-op: push_error(), state unchanged, drag A undisturbed, M grid position unchanged")

	# Subprocess probe: verify push_error fires AND state stays DRAGGING AND
	# no relocate was started (RELOCATE_AFTER=-1).
	var probe := _run_probe("relocate_while_dragging")
	_check(probe["errored"], "AC27: push_error() fires (probe output contains ERROR:)")
	_check(
		probe["output"].find("STATE_AFTER=1") != -1,
		"AC27: state remains DRAGGING (1) after the no-op"
	)
	_check(
		probe["output"].find("RELOCATE_AFTER=-1") != -1,
		"AC27: _relocate_id stays -1 — no relocate was started"
	)
	_check(probe["exit_code"] == 0, "AC27: probe completed normally (exit %d)" % probe["exit_code"])

	# In-process: drag A undisturbed + piece M grid position unchanged.
	var grid := _make_spy_grid(10, 10)
	var catalog := _make_catalog([_make_treadmill_def(), _dumbbell_def()])
	var spies := {}
	var ps := _make_ps(grid, catalog, spies)

	# Place M (dumbbell, id 0) at (1,1); then start drag A (treadmill).
	var m: int = _place_piece(ps, grid, "dumbbell_01", Vector2i(1, 1), 0)
	var m_pos_before: int = int(grid.call("get_occupant_id", Vector2i(1, 1)))

	ps.call("begin_drag", "treadmill_01")  # drag A in flight
	ps.call("on_mouse_moved", Vector2i(8, 8))

	# Attempt begin_relocate(M) — must be a no-op.
	var state_before: int = ps.get("_state")
	var anchor_before: Vector2i = ps.get("_anchor")
	var rotate_before: int = ps.get("_rotation")
	ps.call("begin_relocate", m)

	_check(ps.get("_state") == state_before, "AC27: state unchanged (still DRAGGING)")
	_check(ps.get("_anchor") == anchor_before, "AC27: drag A anchor unchanged")
	_check(ps.get("_rotation") == rotate_before, "AC27: drag A rotation unchanged")
	_check(ps.get("_drag_def").get("id") == "treadmill_01", "AC27: drag A def undisturbed")
	_check(
		grid.call("get_occupant_id", Vector2i(1, 1)) == m_pos_before,
		"AC27: piece M grid position unchanged (occupant %d at (1,1))" % m_pos_before
	)

	# Drag A still completes normally (drop commits a NEW id — relocate M
	# consumed nothing).
	ps.call("on_drop")
	var calls: Array = _commit_calls(grid)
	_check(calls.size() == 2, "AC27: drag A still commits (initial M + A = 2 commits, got %d)" % calls.size())
	if calls.size() == 2:
		_check(
			calls[1]["instance_id"] == 1 and calls[1]["footprint_cells"] == [Vector2i(8, 8), Vector2i(9, 8)],
			"AC27: drag A commit allocated id 1 at (8,8) — M untouched, no id consumed by the no-op"
		)


# === AC30: member displacement is an observable, accepted cost ===

func _test_ac30_member_displacement_observable() -> void:
	print("\n[AC30] member-in-use piece → occupancy clears at drag-start (MemberSim equipment-deleted trigger); cancel restores grid position but NOT member displaced state")

	var grid := _make_spy_grid(10, 10)
	var catalog := _make_catalog([_make_treadmill_def()])
	var spies := {}
	var ps := _make_ps(grid, catalog, spies)

	var n: int = _place_piece(ps, grid, "treadmill_01", Vector2i(2, 2), 0)
	var pre_occ := _occupancy_snapshot(grid)
	var committed: CommittedSpy = spies["committed"]
	var rejected: RejectedSpy = spies["rejected"]
	var committed_baseline := committed.count

	# MemberSim spy: models the equipment-deleted-mid-use handling that reacts
	# to grid_changed. It is injected as a grid_changed subscriber (MemberSim's
	# real integration point), watching the piece N.
	var member := MemberSimSpy.new()
	member.grid = grid
	member.watched_id = n
	grid.connect("grid_changed", Callable(member, "on_grid_changed"))

	# drag-start: occupancy clears immediately → the member's equipment is
	# deleted mid-use. The displacement signal fires HERE (exactly once).
	ps.call("begin_relocate", n)
	_check(
		grid.call("get_occupant_id", Vector2i(2, 2)) == -1 and grid.call("get_occupant_id", Vector2i(3, 2)) == -1,
		"AC30: occupancy clears IMMEDIATELY at drag-start — member sees its equipment deleted"
	)
	_check(
		member.displacement_count == 1 and member.member_displaced,
		"AC30: MemberSim displacement fires exactly once at drag-start (count=%d)" % member.displacement_count
	)

	# cancel → piece's GRID position restored, but the member's displaced
	# state is NOT reverted (the spy flag stays set; PlacementSystem emits no
	# member-restore signal).
	ps.call("on_mouse_moved", Vector2i(8, 8))
	ps.call("on_cancel")
	_check(
		_occupancy_snapshot(grid) == pre_occ,
		"AC30: cancel → grid position restored cell-for-cell"
	)
	_check(
		grid.call("get_occupant_id", Vector2i(2, 2)) == n,
		"AC30: piece N back at anchor0"
	)
	_check(
		member.member_displaced and member.displacement_count == 1,
		"AC30: member displaced state NOT reverted by cancel (displacement_count stays %d)" % member.displacement_count
	)
	_check(committed.count == committed_baseline, "AC30: no placement_committed on the cancel path")
	_check(rejected.count == 0, "AC30: no placement_rejected on the cancel path")
