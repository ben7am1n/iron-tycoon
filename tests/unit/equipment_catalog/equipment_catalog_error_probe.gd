# tests/unit/equipment_catalog/equipment_catalog_error_probe.gd
# Story 001: EquipmentDef Data Model and Catalog Container — subprocess probe.
#
# WHY THIS FILE EXISTS: AC-FROZEN.1 requires push_error() to fire on
# pre-freeze queries and AC-FROZEN.2 requires assert() to fire on post-freeze
# writes. GDScript provides no in-process capture of push_error output, and a
# firing assert() aborts the rest of the current function frame (verified in
# Story 003, see docs/tech-debt-register.md) — so, exactly like the
# grid_rotation_assert_probe / grid_commit_clear_error_probe /
# grid_guardrail_error_probe / grid_state_reader_error_probe pattern, each
# rejection path runs in an ISOLATED child godot process and the parent test
# asserts on the child's merged stdout+stderr.
#
# Deliberately NOT named *_test.gd — it does not implement the
# run_all() -> Dictionary contract (see tests/README.md) and must NOT be
# picked up by headless_runner.gd's registry-coverage scan.
#
# argv (after "--"): <mode>
#   "query_before_freeze"  — call all 3 public queries on an unfrozen
#                            catalog: 3 push_error lines ("before freeze()"),
#                            null/false/[] safe defaults.
#   "query_missing_id"     — frozen catalog, get_definition(unknown id):
#                            1 push_error line ("no definition for id"),
#                            returns null.
#   "add_after_freeze"     — frozen catalog, _add_definition(): assert fires.
#   "double_freeze"        — _freeze() twice: assert fires.
#
# Output contract:
#   stdout contains "PROBE_OPERATION_COMPLETED" iff the operation returned
#     normally (no assert fired — an assert aborts only the current frame,
#     execution continues past it).
#   Combined stdout+stderr contains "Assertion failed" iff an assert fired
#     (Godot's own format, read via OS.execute()'s read_stderr=true, which
#     merges both streams into the caller's single output array).
#   Combined stdout+stderr contains "ERROR:" iff a push_error() fired
#     (Godot prints push_error as "ERROR: <message>").
#   exit code 0 — the operation ran to completion, quit(0) reached,
#     regardless of whether an assert fired partway through it.
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
	var ED: Script = load("res://src/systems/equipment_def.gd") as Script
	var EC: Script = load("res://src/systems/equipment_catalog.gd") as Script

	match mode:
		"query_before_freeze":
			var cat: RefCounted = EC.new()
			cat.call("get_definition", "treadmill")
			cat.call("get_all_ids")
			cat.call("has_definition", "treadmill")
		"query_missing_id":
			var cat: RefCounted = EC.new()
			cat.call("_add_definition", _make_def(ED, "treadmill"))
			cat.call("_freeze")
			cat.call("get_definition", "nonexistent")
		"add_after_freeze":
			var cat: RefCounted = EC.new()
			cat.call("_add_definition", _make_def(ED, "treadmill"))
			cat.call("_freeze")
			# Write path after freeze — must assert (AC-FROZEN.2).
			cat.call("_add_definition", _make_def(ED, "dumbbell"))
		"double_freeze":
			var cat: RefCounted = EC.new()
			cat.call("_add_definition", _make_def(ED, "treadmill"))
			cat.call("_freeze")
			# Second freeze — must assert (QA edge case for AC-FROZEN.2).
			cat.call("_freeze")
		_:
			printerr("PROBE ERROR: unknown mode '%s'" % mode)
			quit(2)
			return

	print("PROBE_OPERATION_COMPLETED")
	quit(0)


## Builds a valid canonical-0° fixture def. TYPED arrays are required — Godot's
## typed-array parameter boundary rejects untyped literals through
## Object.call() with a SCRIPT ERROR that would pollute the very output this
## probe measures (tech-debt register, Story 005 entry).
func _make_def(ED: Script, id: String) -> RefCounted:
	var zone: Array = ["cardio"]
	var footprint: Array[Vector2i] = [Vector2i(0, 0), Vector2i(1, 0)]
	var access: Array[Vector2i] = [Vector2i(0, 1)]
	var effects: Array[Dictionary] = [{"tag": "comfort", "magnitude": 0.1}]
	var def: RefCounted = ED.new(
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
	return def


## Safety net: if something unexpected aborted _init() before reaching
## quit(), the SceneTree main loop keeps running. Force an exit after a few
## frames instead of hanging the parent test run forever.
func _process(_delta: float) -> bool:
	_frames += 1
	if _frames >= SAFETY_NET_FRAMES:
		quit(QUIT_CODE_TIMEOUT)
	return false
