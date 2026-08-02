# tests/unit/equipment_catalog/catalog_pipeline_strict_mode_probe.gd
# Story 004: Validation Pipeline, strict_mode, and Duplicate ID Detection —
# subprocess probe.
#
# WHY THIS FILE EXISTS: AC-E.1 (strict_mode=true must assert on a duplicate
# id), AC-PIPELINE.2 (strict_mode=true must assert on an invalid entry, never
# reaching _freeze()), and AC-C.2's non-strict push_error() requirement need
# observable assert/push_error output. GDScript provides no in-process capture
# of assert/push_error output, and a firing assert() aborts the current
# function frame (verified in Story 003, docs/tech-debt-register.md) — so,
# exactly like the previous equipment_catalog_loader_error_probe.gd /
# equipment_shape_validation_error_probe.gd pattern, each rejection path runs
# in an ISOLATED child godot process and the parent test asserts on the
# child's merged stdout+stderr.
#
# Deliberately NOT named *_test.gd — it does not implement the
# run_all() -> Dictionary contract (see tests/README.md) and must NOT be
# picked up by headless_runner.gd's registry-coverage scan.
#
# argv (after "--"): <mode>
#   "strict_duplicate_id"  — load duplicate_id.catalog.json with
#                            strict_mode=true: the SECOND occurrence of id
#                            "treadmill" fires assert(false) inside
#                            load_from_file() (DUPLICATE_ID path) and aborts
#                            that frame — the frozen catalog is never
#                            returned — then the probe continues to COMPLETED.
#   "strict_invalid_entry" — load pipeline_one_valid_one_invalid.catalog.json
#                            with strict_mode=true: entry 'l_shape_rack' fails
#                            validation (FOOTPRINT_NOT_RECTANGULAR), assert
#                            fires, frame aborts, probe continues.
#   "nons_duplicate_keeps_first" — load duplicate_id.catalog.json with
#                            strict_mode=false: the FIRST occurrence keeps the
#                            id, push_error() fires for the duplicate, and the
#                            catalog holds exactly A's definition (verified via
#                            KEPT_COST line — A costs 200, B costs 999).
#
# Output contract:
#   stdout contains "PROBE_OPERATION_COMPLETED" iff the operation returned
#     normally (an assert aborts only the current frame, execution continues
#     past it in the caller).
#   Combined stdout+stderr contains "Assertion failed" iff an assert fired
#     (Godot's own format, read via OS.execute()'s read_stderr=true, which
#     merges both streams into the caller's single output array).
#   Combined stdout+stderr contains "ERROR:" iff a push_error() fired.
#   exit code 0 — the operation ran to completion, quit(0) reached.
#   exit code QUIT_CODE_TIMEOUT — reserved for a genuinely hung child.
extends SceneTree

const QUIT_CODE_TIMEOUT := 66
const SAFETY_NET_FRAMES := 5
const FIXTURES_DIR := "res://tests/unit/equipment_catalog/fixtures/"

var _frames := 0


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		printerr("PROBE ERROR: no mode argument supplied")
		quit(2)
		return

	var mode: String = args[0]
	var loader: Script = load("res://src/systems/equipment_catalog_loader.gd") as Script

	match mode:
		"strict_duplicate_id":
			# The assert fires inside load_from_file() on the SECOND "treadmill";
			# the call returns null because the static frame was aborted. The
			# probe ignores the result — what matters is the assert output +
			# completing (freeze is textually after the loop, so it never ran).
			loader.load_from_file(FIXTURES_DIR + "duplicate_id.catalog.json", true)
		"strict_invalid_entry":
			loader.load_from_file(FIXTURES_DIR + "pipeline_one_valid_one_invalid.catalog.json", true)
		"nons_duplicate_keeps_first":
			var result: RefCounted = loader.load_from_file(FIXTURES_DIR + "duplicate_id.catalog.json", false)
			# Print the kept definition's cost so the parent test can prove A
			# (cost 200) won over B (cost 999) — get_all_ids() alone cannot
			# distinguish them (same id).
			var catalog: RefCounted = result.get("catalog")
			print("CATALOG_IDS=" + str(catalog.call("get_all_ids")))
			var kept: RefCounted = catalog.call("get_definition", "treadmill")
			print("KEPT_COST=" + str(kept.get("cost")))
		_:
			printerr("PROBE ERROR: unknown mode '%s'" % mode)
			quit(2)
			return

	print("PROBE_OPERATION_COMPLETED")
	quit(0)


## Safety net: if something unexpected aborted _init() before reaching
## quit(), the SceneTree main loop keeps running. Force an exit after a few
## frames instead of hanging the parent test run forever.
func _process(_delta: float) -> bool:
	_frames += 1
	if _frames >= SAFETY_NET_FRAMES:
		quit(QUIT_CODE_TIMEOUT)
	return false
