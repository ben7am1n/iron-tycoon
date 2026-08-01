# tests/unit/grid_system/grid_state_reader_error_probe.gd
# Story 006: GridStateReader / GridSnapshot — subprocess push_error probe.
#
# WHY THIS FILE EXISTS: the OQ#3 fallback protocol (GDD "GridStateReader — 共享
# 只读契约", Story 006 implementation notes) requires GridStateReader's manual
# _init() guard and un-overridden stubs to push_error — LOUD failure instead of
# silent defaults. GDScript provides no in-process capture of push_error output,
# so — exactly like Story 005's probe (grid_commit_clear_error_probe.gd) —
# these calls run in an ISOLATED child godot process and the parent test asserts
# on the child's merged stdout+stderr, where push_error() prints as
# "ERROR: GridStateReader: ...".
#
# The in-process sibling test (grid_state_reader_snapshot_test.gd) verifies the
# observable CONSEQUENCES (safe default return values); this probe verifies the
# literal "push_error() fires" clause.
#
# Deliberately NOT named *_test.gd — it does not implement the
# run_all() -> Dictionary contract (see tests/README.md) and must NOT be
# picked up by headless_runner.gd's registry-coverage scan.
#
# argv (after "--"): <mode>
#   "abstract_new"    — GridStateReader.new() — MUST push_error (abstract guard)
#   "stub_defaults"   — call each un-overridden stub on a GridStateReader
#                       instance — MUST push_error for each and return the
#                       documented safe default (is_solid=true, occupant=-1,
#                       access=[], dims=ZERO, instances=[])
#   "concrete_control" — GridSystem.new() + GridSnapshot.new() — MUST NOT
#                       push_error (concrete leaves are legal)
#
# Output contract:
#   stdout contains "PROBE_OPERATION_COMPLETED" iff the operation returned
#     normally (no assert fired — none of these modes triggers an assert).
#   Combined stdout+stderr contains "ERROR: GridStateReader: ..." iff a
#     rejection path fired push_error.
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
	var ReaderScript: Script = load("res://src/systems/grid_state_reader.gd") as Script

	match mode:
		"abstract_new":
			# Direct instantiation of the abstract base MUST push_error.
			var reader: RefCounted = ReaderScript.new()
			# Calling a stub on the bare instance is legal (returns safe
			# default) — verifying it does not crash proves the guard is
			# not a hard instantiation error, only a loud warning.
			var v: bool = reader.call("is_solid", Vector2i(0, 0))
			if not v:
				printerr("PROBE ERROR: is_solid safe default not true")
				quit(2)
				return
		"stub_defaults":
			var reader: RefCounted = ReaderScript.new()
			# Each stub MUST push_error + return its safe default.
			var solid_ok: bool = reader.call("is_solid", Vector2i(0, 0)) == true
			var occ_ok: int = reader.call("get_occupant_id", Vector2i(0, 0)) == -1
			var access_ok: bool = (reader.call("get_access_cells", 1) as Array).is_empty()
			var dims_ok: bool = reader.call("get_dimensions") == Vector2i.ZERO
			var instances_ok: bool = (reader.call("get_placed_instances") as Array).is_empty()
			if not (solid_ok and occ_ok and access_ok and dims_ok and instances_ok):
				printerr("PROBE ERROR: stub safe defaults wrong")
				quit(2)
				return
		"concrete_control":
			# Control: concrete leaves must NOT push_error on construction.
			var GS: Script = load("res://src/systems/grid_system.gd") as Script
			var gs: RefCounted = GS.new()
			gs.call("init", 5, 5)
			var SnapScript: Script = load("res://src/systems/grid_snapshot.gd") as Script
			var snap: RefCounted = SnapScript.new()
			snap.call("init", gs)
			# Sanity: snapshot reads work and equal the grid's.
			if snap.call("get_dimensions") != Vector2i(5, 5):
				printerr("PROBE ERROR: control snapshot dimensions wrong")
				quit(2)
				return
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
