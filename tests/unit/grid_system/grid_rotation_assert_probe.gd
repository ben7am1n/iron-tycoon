# tests/unit/grid_system/grid_rotation_assert_probe.gd
# Story 003: Rotation Transform and Declared Bounds — subprocess assert probe.
#
# WHY THIS FILE EXISTS (Story 003's OQ#14 resolution):
#
# CORRECTED FINDING (superseding an earlier, incomplete one — see
# docs/tech-debt-register.md, 2026-08-01): Godot 4.7.1's assert(cond, msg),
# when cond is false, aborts the REST OF THE CURRENT FUNCTION FRAME — no
# statement textually after it in that function runs, including a `return`.
# It does NOT terminate the process; the caller of that function keeps
# running normally afterward. Confirmed with an isolated repro: a
# value-typed return (e.g. Vector2i) silently yields its type's zero
# default when the frame aborts; an Object-typed return yields null,
# crashing any caller that dereferences it without a null check.
#
# This script's declared_bounds_* modes call declared_bounds(), whose
# return type is Vector2i (a value type) — so a firing assert there safely
# yields Vector2i.ZERO to this script's own _init(), which ignores the
# return value entirely. Nothing about that scenario can hang: the _init()
# call site doesn't care about the value, and execution proceeds normally to
# the print + quit(0) below. Subprocess isolation is used anyway so the
# child's own "SCRIPT ERROR: Assertion failed" console output can be
# captured and asserted on directly, without this test file needing any
# in-process stderr-capture mechanism (which GDScript doesn't provide).
#
# Deliberately NOT named *_test.gd — it does not implement the
# run_all() -> Dictionary contract (see tests/README.md) and must NOT be
# picked up by headless_runner.gd's registry-coverage scan.
#
# argv (after "--"): <mode> [extra args...]
#   "declared_bounds_violation"   — declared_bounds() on anchor-convention-
#                                    violating (un-normalized) cell data
#   "declared_bounds_ok"          — declared_bounds() on normalized cell data
#   "declared_bounds_empty"       — declared_bounds() on empty footprint_cells
#
# Output contract:
#   stdout contains "PROBE_OPERATION_COMPLETED" iff the operation returned
#     normally (no assert fired).
#   Combined stdout+stderr contains "Assertion failed" (Godot's own format,
#     read via OS.execute()'s read_stderr=true, which merges both streams
#     into the caller's single output array) iff an assert fired.
#   exit code 0                 — the operation ran to completion, quit(0)
#     reached, regardless of whether an assert fired partway through it
#     (assert does not stop this process).
#   exit code QUIT_CODE_TIMEOUT — reserved for a genuinely hung child (e.g.
#     an infinite loop in a future mode, not an assert); not expected to
#     fire for any mode this probe currently implements.
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
	var GS: Script = load("res://src/systems/grid_system.gd") as Script
	var gs: RefCounted = GS.new()
	gs.call("init", 10, 10)

	match mode:
		"rotation":
			var rot := int(args[1])
			var footprint: Array[Vector2i] = [Vector2i(0, 0)]
			var access: Array[Vector2i] = [Vector2i(0, 1)]
			gs.call("get_transformed_cells", footprint, access, Vector2i(0, 0), rot)
		"declared_bounds_violation":
			# min_offset == (1,1), not (0,0) -- violates the anchor convention
			var footprint: Array[Vector2i] = [Vector2i(1, 1)]
			var access: Array[Vector2i] = [Vector2i(1, 2)]
			gs.call("declared_bounds", footprint, access)
		"declared_bounds_ok":
			var footprint: Array[Vector2i] = [Vector2i(0, 0)]
			var access: Array[Vector2i] = [Vector2i(0, 1)]
			gs.call("declared_bounds", footprint, access)
		"declared_bounds_empty":
			var footprint: Array[Vector2i] = []
			var access: Array[Vector2i] = [Vector2i(0, 0)]
			gs.call("declared_bounds", footprint, access)
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
