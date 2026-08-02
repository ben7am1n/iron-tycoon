# tests/unit/equipment_catalog/catalog_use_duration_strict_probe.gd
# Story 005: Use-Duration Field Validation — subprocess probe.
#
# WHY THIS FILE EXISTS: AC-U.1 requires strict_mode=true to fire assert()
# with the failing entry's id; the non-strict rejection path (AC-U.2/U.3)
# requires push_error() on the excluded entry. GDScript provides no
# in-process capture of assert/push_error output, and a firing assert()
# aborts the current function frame (verified in Story 003,
# docs/tech-debt-register.md) — so, exactly like the previous
# equipment_shape_validation_error_probe.gd /
# catalog_pipeline_strict_mode_probe.gd pattern, each rejection path runs
# in an ISOLATED child godot process and the parent test asserts on the
# child's merged stdout+stderr.
#
# Deliberately NOT named *_test.gd — it does not implement the
# run_all() -> Dictionary contract (see tests/README.md) and must NOT be
# picked up by headless_runner.gd's registry-coverage scan.
#
# argv (after "--"): <mode>
#   "strict_mean_zero"  — load use_duration_mean_zero.catalog.json with
#                         strict_mode=true: entry 'mean_zero_rack' fails
#                         USE_DURATION_MEAN_INVALID (mean=0, GDD Core Rule
#                         7 (e)), assert fires inside load_from_file() and
#                         aborts that frame — the frozen catalog is never
#                         returned — then the probe continues to COMPLETED.
#   "nons_mean_zero_excludes" — load use_duration_mean_zero.catalog.json
#                         with strict_mode=false: the bad entry is EXCLUDED,
#                         push_error() fires, and the valid control entry
#                         still loads (verified via CATALOG_IDS line).
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
		"strict_mean_zero":
			# The assert fires inside load_from_file() on 'mean_zero_rack'
			# (mean=0 -> USE_DURATION_MEAN_INVALID); the call returns null
			# because the static frame was aborted. The probe ignores the
			# result — what matters is the assert output + completing.
			loader.load_from_file(FIXTURES_DIR + "use_duration_mean_zero.catalog.json", true)
		"nons_mean_zero_excludes":
			var result: RefCounted = loader.load_from_file(FIXTURES_DIR + "use_duration_mean_zero.catalog.json", false)
			# Print the loaded ids so the parent test can verify the valid
			# control survived while the mean-zero entry was excluded.
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
