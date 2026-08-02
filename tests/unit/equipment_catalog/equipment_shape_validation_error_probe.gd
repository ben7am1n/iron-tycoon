# tests/unit/equipment_catalog/equipment_shape_validation_error_probe.gd
# Story 003: Footprint Shape and Access Cell Validation — subprocess probe.
#
# WHY THIS FILE EXISTS: AC-C.1 requires strict_mode=true to fire assert()
# with the failing entry's id; AC-C.2 requires strict_mode=false to fire
# push_error() on the excluded entry. GDScript provides no in-process
# capture of assert/push_error output, and a firing assert() aborts the
# current function frame (verified in Story 003 of grid-system, see
# docs/tech-debt-register.md) — so, exactly like the
# equipment_catalog_loader_error_probe.gd (Story 002) /
# equipment_catalog_error_probe.gd (Story 001) pattern, each rejection path
# runs in an ISOLATED child godot process and the parent test asserts on the
# child's merged stdout+stderr.
#
# Deliberately NOT named *_test.gd — it does not implement the
# run_all() -> Dictionary contract (see tests/README.md) and must NOT be
# picked up by headless_runner.gd's registry-coverage scan.
#
# argv (after "--"): <mode>
#   "strict_empty_footprint"  — load empty_footprint.catalog.json with
#                               strict_mode=true: entry 'empty_footprint_bench'
#                               fails FOOTPRINT_EMPTY, assert fires inside
#                               load_from_file() and aborts that frame — the
#                               frozen catalog is never returned — then the
#                               probe continues to COMPLETED.
#   "nons strict_excludes"     — load empty_footprint.catalog.json with
#                               strict_mode=false: the bad entry is EXCLUDED,
#                               push_error() fires, and the 2 valid entries
#                               still load (verified via CATALOG_IDS line).
#
# Output contract:
#   stdout contains "PROBE_OPERATION_COMPLETED" iff the operation returned
#     normally (an assert aborts only the current frame, execution continues
#     past it in the caller).
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
const FIXTURE_EMPTY := "res://tests/unit/equipment_catalog/fixtures/empty_footprint.catalog.json"

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
		"strict_empty_footprint":
			# The assert fires inside load_from_file(); the call returns
			# null because the static frame was aborted. The probe ignores
			# the result — what matters is the assert output + completing.
			loader.load_from_file(FIXTURE_EMPTY, true)
		"nons strict_excludes":
			var result: RefCounted = loader.load_from_file(FIXTURE_EMPTY, false)
			# Print the loaded ids so the parent test can verify the 2 valid
			# entries survived while the empty-footprint entry was excluded.
			var catalog: RefCounted = result.get("catalog")
			print("CATALOG_IDS=" + str(catalog.call("get_all_ids")))
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
