# tests/unit/placement_system/placement_error_probe.gd
# Story PL-001: subprocess probe for push_error assertions (AC4, AC15).
#
# WHY THIS FILE EXISTS: GDScript has no in-process push_error capture — the
# established pattern (grid_rotation_assert_probe.gd, catalog probes) runs
# the error path in an ISOLATED subprocess and asserts on the merged
# stdout+stderr output. The parent test (drag_lifecycle_test.gd) drives this
# via OS.execute and checks for "ERROR:" + the PlacementSystem message + a
# state marker printed after the call.
#
# Deliberately NOT named *_test.gd — it does not implement the
# run_all() -> Dictionary contract (see tests/README.md) and must NOT be
# picked up by headless_runner.gd's registry-coverage scan.
#
# argv (after "--"): <mode>
#   "unknown_id"      — begin_drag("nonexistent_id"): expect push_error from
#                       PlacementSystem AND state marker STATE_AFTER=0 (IDLE)
#   "corrupt_1080"    — begin_drag + _test_set_rotation_unchecked(1080) +
#                       on_rotate_pressed(): expect push_error AND
#                       ROTATION_AFTER=1080 (never laundered)
#   "corrupt_45"      — same with 45
#   "corrupt_neg90"   — same with -90
#
# Output contract:
#   stdout+stderr merged contains "ERROR:" iff push_error fired.
#   "STATE_AFTER=<n>" / "ROTATION_AFTER=<n>" markers prove the write that
#     the guard must NOT have performed (state stayed IDLE / rotation stayed
#     corrupt).
#   "PROBE_OPERATION_COMPLETED" on stdout iff the operation returned normally.
#   exit code 0 on normal completion; QUIT_CODE_TIMEOUT if a firing assert
#     aborted _init() and left the main loop running (safety net below).
extends SceneTree

const QUIT_CODE_TIMEOUT := 66
const SAFETY_NET_FRAMES := 5

var _frames := 0


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		printerr("PROBE ERROR: no mode argument supplied")
		quit(2)
		return

	var mode: String = args[0]

	var grid := _make_open_grid(10, 10)
	var cat := _make_catalog([_make_def("treadmill_01")])
	var ps: RefCounted = _make_system(grid, cat)

	match mode:
		"unknown_id":
			ps.call("begin_drag", "nonexistent_id")
			print("STATE_AFTER=%d" % ps.get("_state"))
		"corrupt_1080":
			ps.call("begin_drag", "treadmill_01")
			ps.call("_test_set_rotation_unchecked", 1080)
			ps.call("on_rotate_pressed")
			print("ROTATION_AFTER=%d" % ps.get("_rotation"))
		"corrupt_45":
			ps.call("begin_drag", "treadmill_01")
			ps.call("_test_set_rotation_unchecked", 45)
			ps.call("on_rotate_pressed")
			print("ROTATION_AFTER=%d" % ps.get("_rotation"))
		"corrupt_neg90":
			ps.call("begin_drag", "treadmill_01")
			ps.call("_test_set_rotation_unchecked", -90)
			ps.call("on_rotate_pressed")
			print("ROTATION_AFTER=%d" % ps.get("_rotation"))
		_:
			printerr("PROBE ERROR: unknown mode '%s'" % mode)
			quit(2)
			return

	print("PROBE_OPERATION_COMPLETED")
	quit(0)


## Safety net: if a firing assert aborted _init() before reaching quit(), the
## SceneTree main loop keeps running (assert() halts only the current call
## stack, not the process — verified empirically). Force an exit after a few
## frames instead of hanging the parent test run forever.
func _process(_delta: float) -> bool:
	_frames += 1
	if _frames >= SAFETY_NET_FRAMES:
		quit(QUIT_CODE_TIMEOUT)
	return false


# === Fixture helpers (mirror drag_lifecycle_test.gd) ===

func _ED() -> Script:
	return load("res://src/systems/equipment_def.gd") as Script


func _make_def(id: String) -> RefCounted:
	var zone: Array = ["cardio"]
	var footprint: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0)]
	var access: Array[Vector2i] = [Vector2i(0, 1)]
	var effects: Array[Dictionary] = []
	return _ED().new(
		id,
		"Test %s" % id,
		zone,
		footprint,
		access,
		200,
		"",
		effects,
		200,
		30,
		100,
		300,
	)


func _make_open_grid(width: int, height: int) -> RefCounted:
	var GS: Script = load("res://src/systems/grid_system.gd") as Script
	var gs: RefCounted = GS.new()
	gs.call("init", width, height)
	for y in height:
		for x in width:
			gs.call("set_buildable", Vector2i(x, y), true)
	gs.call("freeze_buildable")
	return gs


func _make_catalog(defs: Array) -> RefCounted:
	var EC: Script = load("res://src/systems/equipment_catalog.gd") as Script
	var cat: RefCounted = EC.new()
	for d in defs:
		cat.call("_add_definition", d)
	cat.call("_freeze")
	return cat


func _make_system(grid: RefCounted, catalog: RefCounted) -> RefCounted:
	var PS: Script = load("res://src/systems/placement_system.gd") as Script
	var ps: RefCounted = PS.new()
	ps.call("init", grid, catalog)
	return ps
