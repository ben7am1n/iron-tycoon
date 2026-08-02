# tests/unit/time_system/seeded_rng_error_probe.gd
# Story 003: SeededRNG — subprocess assert/push_error probe.
#
# WHY THIS FILE EXISTS: AC15 (duplicate register_system -> assert), the
# lsr() invalid-shift assert, and AC6's "get_rng before register -> push_error"
# each literally require observing an assert() or push_error() firing.
# GDScript provides no in-process capture of assert/push_error output, so —
# exactly like Story 003 of grid-system (grid_rotation_assert_probe.gd) —
# these calls run in an ISOLATED child godot process and the parent test
# asserts on the child's merged stdout+stderr, where assert() prints as
# "Assertion failed" and push_error() prints as "ERROR: SeededRNG: ...".
#
# Godot 4.7.1 assert() semantics (verified empirically, see
# grid_rotation_assert_probe.gd header): a firing assert aborts the REST OF
# THE CURRENT FUNCTION FRAME — statements textually after it in that function
# do not run — but the CALLER keeps running normally. It does NOT terminate
# the process. So a probe whose register_system() second call fires an assert
# still reaches print("PROBE_OPERATION_COMPLETED") + quit(0): the assert
# aborts register_system()'s own frame, and this script's _init() (the
# caller) continues past the call site.
#
# Deliberately NOT named *_test.gd — it does not implement the
# run_all() -> Dictionary contract (see tests/README.md) and must NOT be
# picked up by headless_runner.gd's registry-coverage scan.
#
# argv (after "--"): <mode>
#   "register_twice"       — init(12345); register "Economy" twice
#                            -> second register_system fires assert
#   "get_rng_unregistered" — init(12345); get_rng("Ghost") -> push_error,
#                            returns null, script continues
#   "register_ok"          — init(12345); register "Economy"; get_rng twice
#                            -> NO assert, NO error (clean control)
#   "lsr_shift_zero"       — SeededRNG.lsr(5, 0) -> assert (shift out of range)
#   "lsr_shift_64"         — SeededRNG.lsr(5, 64) -> assert (shift out of range)
#
# Output contract:
#   stdout contains "PROBE_OPERATION_COMPLETED" iff the operation returned
#     normally (no process-level failure).
#   Combined stdout+stderr contains "Assertion failed" iff an assert fired.
#   Combined stdout+stderr contains "ERROR: SeededRNG:" iff a push_error fired.
#   exit code 0 — the operation ran to completion, quit(0) reached, regardless
#     of whether an assert fired partway through (assert does not stop the
#     process).
#   exit code QUIT_CODE_TIMEOUT — reserved for a genuinely hung child (e.g.
#     an infinite loop in a future mode, not an assert); not expected to fire.
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
	var SRG: Script = load("res://src/systems/seeded_rng.gd") as Script
	var srg: RefCounted = SRG.new()

	match mode:
		"register_twice":
			srg.call("init", 12345)
			srg.call("register_system", "Economy")
			# Second registration of the same name must fire assert(false).
			srg.call("register_system", "Economy")
		"get_rng_unregistered":
			srg.call("init", 12345)
			var rng = srg.call("get_rng", "Ghost")
			if rng != null:
				printerr("PROBE ERROR: get_rng returned non-null for unregistered name")
				quit(3)
				return
		"register_ok":
			srg.call("init", 12345)
			srg.call("register_system", "Economy")
			var a = srg.call("get_rng", "Economy")
			var b = srg.call("get_rng", "Economy")
			if a == null or b == null:
				printerr("PROBE ERROR: get_rng returned null for registered name")
				quit(4)
				return
		"lsr_shift_zero":
			SRG.lsr(5, 0)
		"lsr_shift_64":
			SRG.lsr(5, 64)
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
