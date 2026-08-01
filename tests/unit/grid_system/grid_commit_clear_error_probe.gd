# tests/unit/grid_system/grid_commit_clear_error_probe.gd
# Story 005: Commit, Clear, and Reverse Index — subprocess push_error probe.
#
# WHY THIS FILE EXISTS: AC-C7.2 (duplicate commit), AC-C7.3 (clear unknown
# id), and AC-C7.7 (negative instance_id) each literally require
# push_error() to fire. GDScript provides no in-process capture of
# push_error output, so — exactly like Story 003's assert probe
# (grid_rotation_assert_probe.gd) — these calls run in an ISOLATED child
# godot process and the parent test asserts on the child's merged
# stdout+stderr, where push_error() prints as "ERROR: GridSystem: ...".
# The project-wide limitation is tracked in docs/tech-debt-register.md
# (Story 002 entry; Story 003 entry suggests promoting this subprocess
# pattern to a shared helper if a third story needs it — this is the third).
#
# The in-process sibling test (grid_commit_clear_test.gd) verifies the
# observable CONSEQUENCES of each rejection (snapshot unchanged, reverse
# index untouched, no grid_changed); this probe verifies the literal
# "push_error() fires" clause. Together they cover each AC completely.
#
# Deliberately NOT named *_test.gd — it does not implement the
# run_all() -> Dictionary contract (see tests/README.md) and must NOT be
# picked up by headless_runner.gd's registry-coverage scan.
#
# argv (after "--"): <mode>
#   "commit_negative"   — commit(-1, ...) and commit(-5, ...) on empty grid
#   "commit_duplicate"  — commit(9, fp_a) then commit(9, fp_b, different cells)
#   "clear_unknown"     — clear(99) and clear(-1) on empty grid
#   "commit_clear_ok"   — commit(0, ...) then clear(0) — NO error expected
#
# Output contract:
#   stdout contains "PROBE_OPERATION_COMPLETED" iff the operation returned
#     normally (no assert fired — none of these modes triggers an assert).
#   Combined stdout+stderr contains "ERROR: GridSystem: ..." (push_error's
#     format, read via OS.execute()'s read_stderr=true, which merges both
#     streams into the caller's single output array) iff a rejection path
#     fired push_error.
#   exit code 0 — the operation ran to completion, quit(0) reached.
#   exit code QUIT_CODE_TIMEOUT — reserved for a genuinely hung child; not
#     expected to fire for any mode this probe currently implements.
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
	# All cells buildable so the valid-control mode commits succeed.
	for y in 10:
		for x in 10:
			gs.call("set_buildable", Vector2i(x, y), true)
	gs.call("freeze_buildable")

	match mode:
		"commit_negative":
			# AC-C7.7: both negative ids must push_error and be rejected.
			# NOTE: arrays must be TYPED (Array[Vector2i]) — gs.call()
			# passes them as Variants and Godot's typed-array parameter
			# boundary rejects untyped literals with a SCRIPT ERROR (which
			# would pollute the very "ERROR:" output this probe measures).
			var fp_neg1: Array[Vector2i] = [Vector2i(1, 1)]
			var ac_neg1: Array[Vector2i] = [Vector2i(1, 2)]
			var fp_neg2: Array[Vector2i] = [Vector2i(2, 2)]
			var ac_neg2: Array[Vector2i] = []
			gs.call("commit", -1, fp_neg1, ac_neg1, 0)
			gs.call("commit", -5, fp_neg2, ac_neg2, 180)
		"commit_duplicate":
			# AC-C7.2: the second commit of id 9 (different cells) must
			# push_error and be rejected BEFORE any cell write.
			var fp_a: Array[Vector2i] = [Vector2i(1, 1)]
			var ac_a: Array[Vector2i] = [Vector2i(1, 2)]
			var fp_b: Array[Vector2i] = [Vector2i(3, 3)]
			var ac_b: Array[Vector2i] = [Vector2i(3, 4)]
			gs.call("commit", 9, fp_a, ac_a, 0)
			gs.call("commit", 9, fp_b, ac_b, 90)
		"clear_unknown":
			# AC-C7.3: clearing ids never committed must push_error; -1
			# hits the same unknown-id path (never committed).
			gs.call("clear", 99)
			gs.call("clear", -1)
		"commit_clear_ok":
			# Control: legal commit(id=0) + clear(0) must NOT push_error.
			var fp_ok: Array[Vector2i] = [Vector2i(1, 1)]
			var ac_ok: Array[Vector2i] = [Vector2i(1, 2)]
			gs.call("commit", 0, fp_ok, ac_ok, 0)
			gs.call("clear", 0)
		_:
			printerr("PROBE ERROR: unknown mode '%s'" % mode)
			quit(2)
			return

	print("PROBE_OPERATION_COMPLETED")
	quit(0)


## Safety net: if something unexpected aborted _init() before reaching
## quit(), the SceneTree main loop keeps running. Force an exit after a
## few frames instead of hanging the parent test run forever.
func _process(_delta: float) -> bool:
	_frames += 1
	if _frames >= SAFETY_NET_FRAMES:
		quit(QUIT_CODE_TIMEOUT)
	return false
