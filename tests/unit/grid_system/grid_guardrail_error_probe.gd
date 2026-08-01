# tests/unit/grid_system/grid_guardrail_error_probe.gd
# Story 008: Signals, Integration, and Performance — AC-NEG.2 subprocess probe.
#
# WHY THIS FILE EXISTS: AC-NEG.2 requires that commit() and clear() succeed
# normally with NO push_error() when operating on equipment whose access
# cells are completely surrounded (unreachable). GDScript provides no
# in-process capture of push_error output, so — exactly like Story 003/005/006
# probes — the surrounded-fixture commit+clear runs in an ISOLATED child
# godot process and the parent test asserts on the child's merged
# stdout+stderr, where push_error() prints as "ERROR: GridSystem: ...".
#
# This probe is the literal negative control: the fixture has the SAME
# unreachable shape AC-NEG.2 describes, so any future "reachability logic"
# added to GridSystem that push_errors here makes the parent test FAIL.
#
# Deliberately NOT named *_test.gd — it does not implement the
# run_all() -> Dictionary contract (see tests/README.md) and must NOT be
# picked up by headless_runner.gd's registry-coverage scan.
#
# argv (after "--"): <mode>
#   "surrounded_commit_clear" — build 8-cell ring + target with enclosed
#     access, commit target (succeeds), clear target (succeeds) — NO ERROR
#     lines expected anywhere.
#
# Output contract:
#   stdout contains "PROBE_OPERATION_COMPLETED" iff the operation returned
#     normally (no assert fired).
#   Combined stdout+stderr contains "ERROR: GridSystem: ..." iff some
#     rejection path fired push_error — the parent test treats ANY such
#     line as an AC-NEG.2 violation.
#   exit code 0 — the operation ran to completion, quit(0) reached.
#   exit code QUIT_CODE_TIMEOUT — reserved for a genuinely hung child.
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
	gs.call("init", 13, 10)
	for y in 10:
		for x in 13:
			gs.call("set_buildable", Vector2i(x, y), true)
	gs.call("freeze_buildable")

	match mode:
		"surrounded_commit_clear":
			# AC-NEG.2 fixture: ring of 8 single-cell footprints encloses
			# (3,3); target id=7 footprint (5,5), access (3,3) — unreachable.
			var ring: Array[Vector2i] = [
				Vector2i(2, 2), Vector2i(3, 2), Vector2i(4, 2),
				Vector2i(2, 3), Vector2i(4, 3),
				Vector2i(2, 4), Vector2i(3, 4), Vector2i(4, 4),
			]
			for i in ring.size():
				var fp: Array[Vector2i] = [ring[i]]
				var ac: Array[Vector2i] = []
				gs.call("commit", 100 + i, fp, ac, 0)
			# Target commit must succeed normally — NO push_error.
			var t_fp: Array[Vector2i] = [Vector2i(5, 5)]
			var t_ac: Array[Vector2i] = [Vector2i(3, 3)]
			gs.call("commit", 7, t_fp, t_ac, 0)
			# Target clear must succeed normally — NO push_error.
			gs.call("clear", 7)
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
