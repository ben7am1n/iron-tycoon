# tests/unit/equipment_catalog/equipment_catalog_loader_error_probe.gd
# Story 002: JSON Loading and Anchor Normalization — strict_mode assert probe.
#
# WHY THIS FILE EXISTS: strict_mode=true must fire assert() on a failing
# entry (GDD Edge Cases, Story 002 sketch). GDScript provides no in-process
# capture of assert output, and a firing assert() aborts the current function
# frame — so, exactly like equipment_catalog_error_probe.gd (Story 001), the
# rejection path runs in an ISOLATED child godot process and the parent test
# asserts on the child's merged stdout+stderr.
#
# Deliberately NOT named *_test.gd — it does not implement the
# run_all() -> Dictionary contract (see tests/README.md) and must NOT be
# picked up by headless_runner.gd's registry-coverage scan.
#
# argv (after "--"): <mode>
#   "strict_assert"  — load one_invalid_entry.catalog.json with
#                      strict_mode=true: entry 'bad_cost' fails structural
#                      parsing (cost is a string), assert fires inside
#                      load_from_file() and aborts that frame — freeze never
#                      runs — then the probe continues to COMPLETED.
#
# Output contract:
#   stdout contains "PROBE_OPERATION_COMPLETED" iff the operation returned
#     normally (an assert aborts only the current frame, execution continues
#     past it in the caller).
#   Combined stdout+stderr contains "Assertion failed" iff an assert fired
#     (Godot's own format, read via OS.execute()'s read_stderr=true, which
#     merges both streams into the caller's single output array).
#   exit code 0 — the operation ran to completion, quit(0) reached,
#     regardless of whether an assert fired partway through it.
#   exit code QUIT_CODE_TIMEOUT — reserved for a genuinely hung child.
extends SceneTree

const QUIT_CODE_TIMEOUT := 66
const SAFETY_NET_FRAMES := 5
const FIXTURE_PATH := "res://tests/unit/equipment_catalog/fixtures/one_invalid_entry.catalog.json"

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
		"strict_assert":
			# The assert fires inside load_from_file(); the call returns
			# null because the static frame was aborted. The probe ignores
			# the result — what matters is the assert output + completing.
			loader.load_from_file(FIXTURE_PATH, true)
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
