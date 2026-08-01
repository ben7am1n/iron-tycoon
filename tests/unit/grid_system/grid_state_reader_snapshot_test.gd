# tests/unit/grid_system/grid_state_reader_snapshot_test.gd
# Story 006: GridStateReader and GridSnapshot
# Covers AC-GSR.1 (pairwise equality), AC-GSR.2 (dimensions preserved),
# AC-X.2 (snapshot deep-copy), AC-X.3 (speculative snapshot does NOT touch
# real grid / no signal), AC-GSR.3 (advisory: write methods invisible through
# GridStateReader type), the OQ#3 abstract-guard fallback (via subprocess
# probe), and GridSystem.get_placed_instances() DTO construction.
#
# The literal "push_error() fires" clause of the abstract-base guard is
# verified via the subprocess probe grid_state_reader_error_probe.gd (see
# _test_abstract_guard_probe) — GDScript has no in-process push_error capture,
# same subprocess-isolation pattern as Story 003/005.
# Run standalone: godot --headless --script tests/unit/grid_system/grid_state_reader_snapshot_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

# Rotation values mirror GridSystem.Rotation (degree-valued).
const R0 := 0
const R90 := 90

# Subprocess probe path — keep in sync with grid_state_reader_error_probe.gd.
const PROBE_SCRIPT_PATH := "res://tests/unit/grid_system/grid_state_reader_error_probe.gd"

var _pass := 0
var _fail := 0

# grid_changed observation state — reset per _connect_signal().
var _signal_count := 0


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
	print("  UNIT TEST: GridSystem — GridStateReader / GridSnapshot (Story 006)")
	print("=".repeat(48))

	_test_ac_gsr_1_pairwise_equality()
	_test_ac_gsr_1_pairwise_after_commit_clear()
	_test_ac_gsr_2_dimensions_preserved()
	_test_ac_gsr_3_write_methods_not_on_reader()
	_test_ac_x_2_snapshot_deep_copy()
	_test_ac_x_3_speculative_snapshot_no_touch()
	_test_ac_x_3_empty_deltas()
	_test_ac_x_3_add_then_remove_same_piece()
	_test_speculative_add_reads()
	_test_speculative_remove_reads()
	_test_get_placed_instances_dto()
	_test_snapshot_wraps_copied_state()
	_test_abstract_guard_probe()

	print("\n=== GRID STATE READER/SNAPSHOT TEST: %d passed, %d failed ===\n" % [_pass, _fail])
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
## snapshot semantics, not room geometry.
func _make_open_grid(width: int, height: int) -> RefCounted:
	var gs := _make_grid(width, height)
	for y in height:
		for x in width:
			gs.call("set_buildable", Vector2i(x, y), true)
	gs.call("freeze_buildable")
	return gs


## Runs commit() through call() so a signature change breaks one place.
func _commit(gs: RefCounted, id: int, fp: Array[Vector2i], ac: Array[Vector2i], rot: int) -> void:
	gs.call("commit", id, fp, ac, rot)


func _clear(gs: RefCounted, id: int) -> void:
	gs.call("clear", id)


## Full-grid state capture via the PUBLIC read API — occupant_id + access_ids
## per cell, used for before/after equality assertions (same approach Story
## 004/005 used; this is an assertion helper, NOT the Story 006 snapshot).
func _full_state(gs: RefCounted) -> Dictionary:
	var dims: Vector2i = gs.call("get_dimensions")
	var occ := {}
	var acc := {}
	for y in dims.y:
		for x in dims.x:
			var cell := Vector2i(x, y)
			occ[cell] = gs.call("get_occupant_id", cell)
			acc[cell] = gs.call("get_access_ids", cell)
	return {"dims": dims, "occupant": occ, "access": acc}


func _connect_signal(gs: RefCounted) -> void:
	_signal_count = 0
	gs.connect("grid_changed", Callable(self, "_on_grid_changed"))


func _on_grid_changed(_footprint_changed: Array, _access_changed: Array) -> void:
	_signal_count += 1


## Runs grid_state_reader_error_probe.gd in an ISOLATED subprocess so the
## child's push_error() output ("ERROR: GridStateReader: ...") can be
## asserted on directly (same pattern as Story 005's probe).
func _run_probe(mode: String) -> Dictionary:
	var exe := OS.get_executable_path()
	var project_root := ProjectSettings.globalize_path("res://")
	var probe_path := ProjectSettings.globalize_path(PROBE_SCRIPT_PATH)

	var args: Array[String] = ["--headless", "--path", project_root, "--script", probe_path, "--", mode]

	var output: Array = []
	var exit_code := OS.execute(exe, args, output, true)
	var output_text: String = "".join(output)

	return {"errored": output_text.find("ERROR:") != -1, "output": output_text, "exit_code": exit_code}


# === AC-GSR.1: pairwise equality between GridSystem and its get_snapshot() ===

func _test_ac_gsr_1_pairwise_equality() -> void:
	print("\n[AC-GSR.1] pairwise equality — GridSystem vs get_snapshot() with 3 placed equipments (shared access cell)")

	var gs := _make_open_grid(13, 10)
	_connect_signal(gs)

	var fp0: Array[Vector2i] = [Vector2i(2, 2)]
	var ac0: Array[Vector2i] = [Vector2i(2, 3)]
	var fp1: Array[Vector2i] = [Vector2i(5, 5), Vector2i(6, 5)]
	var ac1: Array[Vector2i] = [Vector2i(5, 6)]
	var fp2: Array[Vector2i] = [Vector2i(8, 1)]
	var ac2: Array[Vector2i] = [Vector2i(2, 3)]  # shared access cell with id 0

	_commit(gs, 0, fp0, ac0, R0)
	_commit(gs, 1, fp1, ac1, R90)
	_commit(gs, 2, fp2, ac2, R0)

	var snap: RefCounted = gs.call("get_snapshot")
	var dims: Vector2i = gs.call("get_dimensions")

	# get_dimensions pairwise
	_check(
		snap.call("get_dimensions") == dims,
		"get_dimensions pairwise equal: %s" % dims
	)

	# is_solid + get_occupant_id for EVERY cell in [0,w)×[0,h)
	var solid_mismatch := 0
	var occ_mismatch := 0
	for y in dims.y:
		for x in dims.x:
			var cell := Vector2i(x, y)
			if snap.call("is_solid", cell) != gs.call("is_solid", cell):
				solid_mismatch += 1
			if snap.call("get_occupant_id", cell) != gs.call("get_occupant_id", cell):
				occ_mismatch += 1
	_check(
		solid_mismatch == 0,
		"is_solid pairwise equal for all %d cells (mismatches=%d)" % [dims.x * dims.y, solid_mismatch]
	)
	_check(
		occ_mismatch == 0,
		"get_occupant_id pairwise equal for all %d cells (mismatches=%d)" % [dims.x * dims.y, occ_mismatch]
	)

	# get_access_cells pairwise for every committed instance id + unknown id
	_check(
		snap.call("get_access_cells", 0) == gs.call("get_access_cells", 0),
		"get_access_cells(0) pairwise equal: %s" % gs.call("get_access_cells", 0)
	)
	_check(
		snap.call("get_access_cells", 1) == gs.call("get_access_cells", 1),
		"get_access_cells(1) pairwise equal: %s" % gs.call("get_access_cells", 1)
	)
	_check(
		snap.call("get_access_cells", 2) == gs.call("get_access_cells", 2),
		"get_access_cells(2) pairwise equal (shared access cell): %s" % gs.call("get_access_cells", 2)
	)
	_check(
		snap.call("get_access_cells", 999) == gs.call("get_access_cells", 999),
		"get_access_cells(unknown id) pairwise equal: []"
	)

	# get_placed_instances content-wise equality (ids + cells)
	var grid_instances: Array = gs.call("get_placed_instances")
	var snap_instances: Array = snap.call("get_placed_instances")
	_check(
		grid_instances.size() == 3 and snap_instances.size() == 3,
		"get_placed_instances both return 3 DTOs (grid=%d snapshot=%d)" % [grid_instances.size(), snap_instances.size()]
	)
	var ids_match := true
	for i in grid_instances.size():
		var gpi: RefCounted = grid_instances[i]
		var spi: RefCounted = snap_instances[i]
		if gpi.get("instance_id") != spi.get("instance_id") \
				or gpi.get("footprint_cells") != spi.get("footprint_cells") \
				or gpi.get("access_cells") != spi.get("access_cells") \
				or gpi.get("rotation") != spi.get("rotation"):
			ids_match = false
	_check(ids_match, "get_placed_instances pairwise equal (id/footprint/access/rotation per DTO)")

	# The 3 commits above emitted 3 signals — reset the counter so the
	# following snapshot reads can prove THEY emit nothing.
	_signal_count = 0
	var snap_read: RefCounted = gs.call("get_snapshot")
	snap_read.call("is_solid", Vector2i(0, 0))
	snap_read.call("get_occupant_id", Vector2i(0, 0))
	snap_read.call("get_access_cells", 0)
	snap_read.call("get_placed_instances")
	_check(_signal_count == 0, "no grid_changed emitted during snapshot reads (count=%d)" % _signal_count)


func _test_ac_gsr_1_pairwise_after_commit_clear() -> void:
	print("\n[AC-GSR.1] pairwise equality after a commit+clear sequence")

	var gs := _make_open_grid(10, 10)

	var fp0: Array[Vector2i] = [Vector2i(1, 1)]
	var ac0: Array[Vector2i] = [Vector2i(1, 2)]
	_commit(gs, 0, fp0, ac0, R0)
	_clear(gs, 0)

	var fp1: Array[Vector2i] = [Vector2i(3, 3)]
	var ac1: Array[Vector2i] = [Vector2i(3, 4), Vector2i(4, 4)]
	_commit(gs, 1, fp1, ac1, R90)

	var snap: RefCounted = gs.call("get_snapshot")
	var dims: Vector2i = gs.call("get_dimensions")

	var equal := true
	for y in dims.y:
		for x in dims.x:
			var cell := Vector2i(x, y)
			if snap.call("is_solid", cell) != gs.call("is_solid", cell) \
					or snap.call("get_occupant_id", cell) != gs.call("get_occupant_id", cell):
				equal = false
	_check(equal, "is_solid/get_occupant_id pairwise equal after commit+clear for all cells")
	_check(
		snap.call("get_access_cells", 1) == gs.call("get_access_cells", 1),
		"get_access_cells(1) pairwise equal after commit+clear: %s" % str(gs.call("get_access_cells", 1))
	)
	_check(
		snap.call("get_access_cells", 0) == gs.call("get_access_cells", 0),
		"get_access_cells(0) pairwise equal after clear (both []): %s" % str(gs.call("get_access_cells", 0))
	)


# === AC-GSR.2: dimensions preserved ===

func _test_ac_gsr_2_dimensions_preserved() -> void:
	print("\n[AC-GSR.2] get_dimensions() == (13,10); snapshot preserves dimensions")

	var gs := _make_open_grid(13, 10)
	_check(gs.call("get_dimensions") == Vector2i(13, 10), "get_dimensions() returns Vector2i(13, 10)")

	var snap: RefCounted = gs.call("get_snapshot")
	_check(
		snap.call("get_dimensions") == Vector2i(13, 10),
		"get_snapshot() preserves dimensions: %s" % snap.call("get_dimensions")
	)

	# After placement + snapshot, dimensions still preserved
	var fp: Array[Vector2i] = [Vector2i(0, 0)]
	var ac: Array[Vector2i] = [Vector2i(1, 0)]
	_commit(gs, 0, fp, ac, R0)
	var snap2: RefCounted = gs.call("get_snapshot")
	_check(
		snap2.call("get_dimensions") == Vector2i(13, 10),
		"get_snapshot() preserves dimensions after placement: %s" % snap2.call("get_dimensions")
	)


# === AC-GSR.3 (advisory): write methods invisible through GridStateReader ===

func _test_ac_gsr_3_write_methods_not_on_reader() -> void:
	print("\n[AC-GSR.3] (advisory) _commit_in_place/_clear_in_place NOT in GridStateReader's declared methods")

	# NOTE: Script.has_method() does NOT reflect GDScript-declared methods in
	# 4.7.1 (verified empirically) — inspect get_script_method_list() instead,
	# which lists the methods DECLARED ON THIS SCRIPT (not inherited).
	var reader_script: Script = load("res://src/systems/grid_state_reader.gd") as Script
	var snapshot_script: Script = load("res://src/systems/grid_snapshot.gd") as Script

	var reader_methods := _script_method_names(reader_script)
	var snapshot_methods := _script_method_names(snapshot_script)

	_check(not reader_methods.has("_commit_in_place"), "GridStateReader does NOT declare _commit_in_place")
	_check(not reader_methods.has("_clear_in_place"), "GridStateReader does NOT declare _clear_in_place")
	_check(snapshot_methods.has("_commit_in_place"), "GridSnapshot DOES declare _commit_in_place (concrete impl)")
	_check(snapshot_methods.has("_clear_in_place"), "GridSnapshot DOES declare _clear_in_place (concrete impl)")

	# The read contract itself is declared on GridStateReader.
	_check(reader_methods.has("is_solid"), "GridStateReader declares is_solid")
	_check(reader_methods.has("get_occupant_id"), "GridStateReader declares get_occupant_id")
	_check(reader_methods.has("get_access_cells"), "GridStateReader declares get_access_cells")
	_check(reader_methods.has("get_dimensions"), "GridStateReader declares get_dimensions")
	_check(reader_methods.has("get_placed_instances"), "GridStateReader declares get_placed_instances")

	# Write methods are NOT on the reader contract either.
	_check(not reader_methods.has("commit"), "GridStateReader does NOT declare commit")
	_check(not reader_methods.has("clear"), "GridStateReader does NOT declare clear")
	_check(not reader_methods.has("can_place"), "GridStateReader does NOT declare can_place")


## Collects the names of methods DECLARED on [script] (not inherited).
## Script.has_method() was verified broken for GDScript-declared methods in
## 4.7.1, so this walks get_script_method_list() instead.
func _script_method_names(script: Script) -> Array[String]:
	var names: Array[String] = []
	for entry in script.get_script_method_list():
		names.append(entry["name"] as String)
	return names


# === AC-X.2: snapshot deep-copy semantics ===

func _test_ac_x_2_snapshot_deep_copy() -> void:
	print("\n[AC-X.2] get_snapshot() result unchanged after real-grid commit/clear (deep copy)")

	var gs := _make_open_grid(10, 10)

	var fp0: Array[Vector2i] = [Vector2i(2, 2)]
	var ac0: Array[Vector2i] = [Vector2i(2, 3)]
	_commit(gs, 0, fp0, ac0, R0)
	var fp1: Array[Vector2i] = [Vector2i(5, 5)]
	var ac1: Array[Vector2i] = [Vector2i(5, 6)]
	_commit(gs, 1, fp1, ac1, R0)

	var snap: RefCounted = gs.call("get_snapshot")
	var before_state := _full_state(gs)
	var before_dims: Vector2i = snap.call("get_dimensions")
	var before_occ0: int = snap.call("get_occupant_id", Vector2i(2, 2))
	var before_occ1: int = snap.call("get_occupant_id", Vector2i(5, 5))
	var before_solid0: bool = snap.call("is_solid", Vector2i(2, 2))
	var before_acc0: Array = snap.call("get_access_cells", 0)
	var before_acc1: Array = snap.call("get_access_cells", 1)
	var before_instances: Array = snap.call("get_placed_instances")

	# Mutate the REAL grid: commit a new instance + clear an existing one.
	_connect_signal(gs)
	var fp2: Array[Vector2i] = [Vector2i(8, 8)]
	var ac2: Array[Vector2i] = [Vector2i(8, 9)]
	_commit(gs, 2, fp2, ac2, R0)
	_clear(gs, 0)
	_check(_signal_count == 2, "sanity: real-grid commit+clear emitted grid_changed twice (count=%d)" % _signal_count)

	# The snapshot's values MUST be unchanged (deep copy semantics).
	_check(
		snap.call("get_dimensions") == before_dims,
		"snapshot dimensions unchanged after real-grid mutation"
	)
	_check(
		snap.call("get_occupant_id", Vector2i(2, 2)) == before_occ0,
		"snapshot occupant_id(2,2) still %d (real grid cleared it)" % before_occ0
	)
	_check(
		snap.call("get_occupant_id", Vector2i(5, 5)) == before_occ1,
		"snapshot occupant_id(5,5) still %d" % before_occ1
	)
	_check(
		snap.call("is_solid", Vector2i(2, 2)) == before_solid0,
		"snapshot is_solid(2,2) still %s" % before_solid0
	)
	_check(
		snap.call("get_access_cells", 0) == before_acc0,
		"snapshot get_access_cells(0) unchanged (access dict deep-copied)"
	)
	_check(
		snap.call("get_access_cells", 1) == before_acc1,
		"snapshot get_access_cells(1) unchanged"
	)
	_check(
		snap.call("get_placed_instances").size() == before_instances.size(),
		"snapshot placed-instance count unchanged (%d)" % before_instances.size()
	)

	# Access_ids deep-copy: mutating a returned access array must not corrupt
	# the snapshot (defensive duplicate posture).
	var snap_acc_array: Array = snap.call("get_access_cells", 1)
	snap_acc_array.clear()
	_check(
		snap.call("get_access_cells", 1) == before_acc1,
		"mutating a returned access array does not corrupt the snapshot"
	)

	# Snapshot's own state is a distinct object graph — verify the wrapped
	# copy diverges from the real grid (which we already proved by mutation).
	var after_state := _full_state(gs)
	_check(
		before_state != after_state,
		"sanity: real grid state DID change (deep-copy test is meaningful)"
	)


# === AC-X.3: speculative snapshot does not touch real grid, no signal ===

func _test_ac_x_3_speculative_snapshot_no_touch() -> void:
	print("\n[AC-X.3] get_speculative_snapshot + arbitrary in-place mutation: real grid untouched, no grid_changed")

	var gs := _make_open_grid(10, 10)
	_connect_signal(gs)

	var fp0: Array[Vector2i] = [Vector2i(1, 1)]
	var ac0: Array[Vector2i] = [Vector2i(1, 2)]
	_commit(gs, 0, fp0, ac0, R0)
	var fp1: Array[Vector2i] = [Vector2i(4, 4), Vector2i(5, 4)]
	var ac1: Array[Vector2i] = [Vector2i(4, 5)]
	_commit(gs, 1, fp1, ac1, R90)

	var state_s := _full_state(gs)
	_check(_signal_count == 2, "sanity: 2 commits emitted 2 signals (count=%d)" % _signal_count)
	_signal_count = 0

	# Build deltas: ADD instance 2 (a new placement) + REMOVE instance 0 (a
	# real instance). Both pre-validated by PlacementSystem in production.
	# NOTE: must be a TYPED Array[PlacementDelta] — Godot's typed-array
	# parameter boundary rejects untyped arrays through call()/new() (same
	# pitfall Story 005's probe documented).
	var add_fp: Array[Vector2i] = [Vector2i(8, 8)]
	var add_ac: Array[Vector2i] = [Vector2i(8, 9)]
	var empty_cells: Array[Vector2i] = []
	var add := PlacementDelta.new(false, 2, add_fp, add_ac)
	var rem := PlacementDelta.new(true, 0, empty_cells, empty_cells)
	var deltas: Array[PlacementDelta] = [add, rem]

	var snap: RefCounted = gs.call("get_speculative_snapshot", deltas)
	_check(_signal_count == 0, "get_speculative_snapshot emitted NO grid_changed (count=%d)" % _signal_count)

	# Speculative view reflects the deltas.
	_check(snap.call("get_occupant_id", Vector2i(8, 8)) == 2, "speculative snapshot: added instance 2 visible at (8,8)")
	_check(snap.call("get_occupant_id", Vector2i(1, 1)) == -1, "speculative snapshot: removed instance 0 gone from (1,1)")
	_check(snap.call("is_solid", Vector2i(8, 8)), "speculative snapshot: (8,8) solid (added)")
	_check(not snap.call("is_solid", Vector2i(1, 1)), "speculative snapshot: (1,1) walkable (removed)")
	_check(snap.call("get_access_cells", 2) == [Vector2i(8, 9)], "speculative snapshot: get_access_cells(2) == delta access")
	_check(snap.call("get_access_cells", 0) == [], "speculative snapshot: get_access_cells(0) == [] after removal")

	# Real grid still equals S.
	var state_after_snap := _full_state(gs)
	_check(
		state_s == state_after_snap,
		"real grid state still equals S after get_speculative_snapshot"
	)

	# Arbitrary in-place mutation on the returned snapshot. Typed arrays —
	# Godot's typed-array parameter boundary rejects untyped literals via
	# call() (same pitfall as Story 005's probe).
	var mut_fp3: Array[Vector2i] = [Vector2i(0, 0)]
	var mut_ac3: Array[Vector2i] = [Vector2i(0, 1)]
	snap.call("_commit_in_place", 3, mut_fp3, mut_ac3)
	snap.call("_clear_in_place", 1)
	var mut_fp4: Array[Vector2i] = [Vector2i(9, 9)]
	var mut_ac4: Array[Vector2i] = []
	snap.call("_commit_in_place", 4, mut_fp4, mut_ac4)
	snap.call("_clear_in_place", 2)

	_check(_signal_count == 0, "in-place snapshot mutation emitted NO grid_changed (count=%d)" % _signal_count)
	var state_final := _full_state(gs)
	_check(
		state_s == state_final,
		"real grid state still equals S after arbitrary _commit_in_place/_clear_in_place on the snapshot"
	)
	_check(gs.call("get_occupant_id", Vector2i(8, 8)) == -1, "real grid never received speculative add 2")
	_check(gs.call("get_occupant_id", Vector2i(1, 1)) == 0, "real grid never lost instance 0")


func _test_ac_x_3_empty_deltas() -> void:
	print("\n[AC-X.3] edge: empty deltas array — speculative snapshot equals real state")

	var gs := _make_open_grid(8, 8)
	var fp0: Array[Vector2i] = [Vector2i(2, 2)]
	var ac0: Array[Vector2i] = [Vector2i(2, 3)]
	_commit(gs, 0, fp0, ac0, R0)

	var empty_deltas: Array[PlacementDelta] = []
	var snap: RefCounted = gs.call("get_speculative_snapshot", empty_deltas)
	var dims: Vector2i = gs.call("get_dimensions")
	var equal := true
	for y in dims.y:
		for x in dims.x:
			var cell := Vector2i(x, y)
			if snap.call("is_solid", cell) != gs.call("is_solid", cell) \
					or snap.call("get_occupant_id", cell) != gs.call("get_occupant_id", cell):
				equal = false
	_check(equal, "empty deltas: speculative snapshot pairwise equals real grid")
	_check(snap.call("get_placed_instances").size() == 1, "empty deltas: snapshot has the 1 real instance")


func _test_ac_x_3_add_then_remove_same_piece() -> void:
	print("\n[AC-X.3] edge: deltas that add and remove the SAME piece — net zero")

	var gs := _make_open_grid(8, 8)
	var fp0: Array[Vector2i] = [Vector2i(2, 2)]
	var ac0: Array[Vector2i] = [Vector2i(2, 3)]
	_commit(gs, 0, fp0, ac0, R0)

	var add_fp: Array[Vector2i] = [Vector2i(6, 6)]
	var add_ac: Array[Vector2i] = [Vector2i(6, 7)]
	var empty_cells: Array[Vector2i] = []
	var add := PlacementDelta.new(false, 5, add_fp, add_ac)
	var rem := PlacementDelta.new(true, 5, empty_cells, empty_cells)
	var deltas: Array[PlacementDelta] = [add, rem]
	var snap: RefCounted = gs.call("get_speculative_snapshot", deltas)

	var dims: Vector2i = gs.call("get_dimensions")
	var equal := true
	for y in dims.y:
		for x in dims.x:
			var cell := Vector2i(x, y)
			if snap.call("is_solid", cell) != gs.call("is_solid", cell) \
					or snap.call("get_occupant_id", cell) != gs.call("get_occupant_id", cell):
				equal = false
	_check(equal, "add-then-remove same piece: snapshot equals real grid (net zero)")
	_check(
		snap.call("get_access_cells", 5) == [],
		"add-then-remove same piece: instance 5 no longer has access cells"
	)
	_check(
		snap.call("get_placed_instances").size() == 1,
		"add-then-remove same piece: only the real instance remains"
	)


# === Speculative read semantics ===

func _test_speculative_add_reads() -> void:
	print("\n[SPEC-ADD] speculative add: footprint/access reads behave like a real commit")

	var gs := _make_open_grid(10, 10)
	var add_fp: Array[Vector2i] = [Vector2i(3, 3), Vector2i(4, 3)]
	var add_ac: Array[Vector2i] = [Vector2i(3, 4)]
	var add := PlacementDelta.new(false, 7, add_fp, add_ac)
	var deltas: Array[PlacementDelta] = [add]
	var snap: RefCounted = gs.call("get_speculative_snapshot", deltas)

	_check(snap.call("get_occupant_id", Vector2i(3, 3)) == 7, "speculative add: (3,3) occupant_id == 7")
	_check(snap.call("get_occupant_id", Vector2i(4, 3)) == 7, "speculative add: (4,3) occupant_id == 7")
	_check(snap.call("is_solid", Vector2i(3, 3)), "speculative add: footprint solid")
	_check(not snap.call("is_solid", Vector2i(5, 3)), "speculative add: untouched cell (5,3) walkable")
	_check(
		snap.call("get_access_cells", 7) == [Vector2i(3, 4)],
		"speculative add: get_access_cells(7) returns delta access cells"
	)
	var instances: Array = snap.call("get_placed_instances")
	_check(instances.size() == 1, "speculative add: placed instances include the new one")
	if instances.size() == 1:
		var pi: RefCounted = instances[0]
		_check(
			pi.get("instance_id") == 7 and pi.get("footprint_cells") == [Vector2i(3, 3), Vector2i(4, 3)],
			"speculative add: PlacedInstance DTO carries id + footprint"
		)
	_check(snap.call("get_dimensions") == Vector2i(10, 10), "speculative add: dimensions preserved")


func _test_speculative_remove_reads() -> void:
	print("\n[SPEC-REMOVE] speculative remove of a real instance")

	var gs := _make_open_grid(10, 10)
	var fp0: Array[Vector2i] = [Vector2i(2, 2)]
	var ac0: Array[Vector2i] = [Vector2i(2, 3)]
	_commit(gs, 0, fp0, ac0, R0)

	var empty_cells: Array[Vector2i] = []
	var rem := PlacementDelta.new(true, 0, empty_cells, empty_cells)
	var deltas: Array[PlacementDelta] = [rem]
	var snap: RefCounted = gs.call("get_speculative_snapshot", deltas)

	_check(snap.call("get_occupant_id", Vector2i(2, 2)) == -1, "speculative remove: (2,2) empty")
	_check(not snap.call("is_solid", Vector2i(2, 2)), "speculative remove: (2,2) walkable (buildable, unoccupied)")
	_check(snap.call("get_access_cells", 0) == [], "speculative remove: get_access_cells(0) == []")
	_check(snap.call("get_placed_instances").size() == 0, "speculative remove: no placed instances left")
	_check(gs.call("get_occupant_id", Vector2i(2, 2)) == 0, "real grid: instance 0 still present (untouched)")


# === GridSystem.get_placed_instances() DTO construction ===

func _test_get_placed_instances_dto() -> void:
	print("\n[DTO] GridSystem.get_placed_instances() builds correct PlacedInstance DTOs")

	var gs := _make_open_grid(10, 10)
	var fp0: Array[Vector2i] = [Vector2i(2, 2), Vector2i(2, 3)]
	var ac0: Array[Vector2i] = [Vector2i(1, 2)]
	_commit(gs, 0, fp0, ac0, R90)

	var instances: Array = gs.call("get_placed_instances")
	_check(instances.size() == 1, "get_placed_instances returns 1 DTO after 1 commit")
	if instances.size() == 1:
		var pi: RefCounted = instances[0]
		_check(pi.get("instance_id") == 0, "DTO instance_id == 0")
		_check(pi.get("equipment_id") == "", "DTO equipment_id == \"\" (GridSystem stores no equipment type)")
		_check(pi.get("rotation") == R90, "DTO rotation == 90 (degree convention)")
		_check(pi.get("footprint_cells") == fp0, "DTO footprint_cells preserved")
		_check(pi.get("access_cells") == ac0, "DTO access_cells preserved")
		_check(pi.get("anchor") == Vector2i(1, 2), "DTO anchor derived as min-offset of footprint ∪ access")

	# A caller mutating the returned DTO arrays must not corrupt the grid
	# (PlacedInstance duplicates its arrays at construction).
	(instances[0] as RefCounted).get("footprint_cells").clear()
	_check(
		gs.call("get_placed_instances")[0].get("footprint_cells") == fp0,
		"mutating a returned DTO's footprint array does not corrupt the reverse index"
	)


# === Snapshot wraps a copied (self-contained) state ===

func _test_snapshot_wraps_copied_state() -> void:
	print("\n[COPY] snapshot wraps an independent copy — mutating snapshot's delta dicts leaves base intact")

	var gs := _make_open_grid(10, 10)
	var fp0: Array[Vector2i] = [Vector2i(1, 1)]
	var ac0: Array[Vector2i] = [Vector2i(1, 2)]
	_commit(gs, 0, fp0, ac0, R0)

	var snap: RefCounted = gs.call("get_snapshot")
	# The snapshot's own _adds dict is separate from the grid — verify the
	# snapshot object graph is NOT the real grid's object graph.
	var snap_base: RefCounted = snap.get("_base")
	_check(snap_base != gs, "snapshot._base is a distinct object from the real grid")
	_check(
		snap_base.call("get_occupant_id", Vector2i(1, 1)) == 0,
		"snapshot._base is an initialized GridSystem copy with the same data"
	)
	_check(
		not (snap_base == gs),
		"snapshot._base is NOT the real grid (deep copy, AC-X.2)"
	)


# === Abstract-guard verification (subprocess probe, OQ#3 fallback) ===

func _test_abstract_guard_probe() -> void:
	print("\n[PROBE] abstract guard + stub safe-defaults fire push_error (subprocess-isolated)")

	var cases := [
		{
			"mode": "abstract_new",
			"expect_error": true,
			"label": "GridStateReader.new() -> push_error (abstract guard)",
		},
		{
			"mode": "stub_defaults",
			"expect_error": true,
			"label": "un-overridden stubs -> push_error + safe defaults",
		},
		{
			"mode": "concrete_control",
			"expect_error": false,
			"label": "control: GridSystem.new() + GridSnapshot.new() -> NO push_error",
		},
	]
	for c in cases:
		var r := _run_probe(c["mode"])
		# exit_code == 0 proves the probe ran to completion (quit(0) reached) —
		# "errored" alone would also match a SCRIPT ERROR crash in the probe.
		_check(
			r["errored"] == c["expect_error"] and r["exit_code"] == 0,
			"%s — probe %s with clean exit 0 (got errored=%s, exit=%d)" % [c["label"], "errored" if c["expect_error"] else "clean", r["errored"], r["exit_code"]]
		)
		if r["errored"] != c["expect_error"] or r["exit_code"] != 0:
			print("      probe output:\n%s" % r["output"])
