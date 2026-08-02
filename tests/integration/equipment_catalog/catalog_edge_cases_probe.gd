# tests/integration/equipment_catalog/catalog_edge_cases_probe.gd
# Story 007: Edge Cases — Empty Catalog, Unlock Requirements, Cost Boundary —
# subprocess probe.
#
# WHY THIS FILE EXISTS: AC-E.2 (cost=-1 must fail validation — but with what
# observable?), AC-E.5 (strict_mode=true must assert on an all-invalid load;
# non-strict must push_error() per excluded entry), AC-E.6 (empty catalog
# get_definition() must push_error + return null), and AC-E.3 (opaque unlock
# loads with NO error and NO warning) all need observable assert/push_error
# output. GDScript provides no in-process capture of assert/push_error output,
# and a firing assert() aborts the current function frame (established pattern,
# Story 001/002/003/004) — so each rejection path runs in an ISOLATED child
# godot process and the parent test asserts on the child's merged
# stdout+stderr.
#
# Deliberately NOT named *_test.gd — it does not implement the
# run_all() -> Dictionary contract (see tests/README.md) and must NOT be
# picked up by headless_runner.gd's registry-coverage scan.
#
# argv (after "--"): <mode>
#   "strict_all_invalid" — load all_cost_negative.catalog.json with
#                          strict_mode=true: the FIRST entry (cost=-1) fires
#                          assert() inside load_from_file() and aborts that
#                          frame — no catalog is returned, the process
#                          continues to COMPLETED. Proves AC-E.5 strict abort.
#   "nons_all_invalid"   — load all_cost_negative.catalog.json with
#                          strict_mode=false: each of the 3 negative-cost
#                          entries is EXCLUDED with push_error() (3 ERROR
#                          lines expected); the frozen catalog has 0 entries
#                          (CATALOG_IDS=[] line). Proves AC-E.5 non-strict.
#   "empty_queries"      — load empty_equipment.catalog.json (0 entries,
#                          valid empty data source), then query the frozen
#                          empty catalog: get_all_ids() -> [] (EMPTY_IDS=[]),
#                          has_definition("any") -> false (HAS_ANY=false),
#                          get_definition("any") -> push_error() + null
#                          (GET_DEF_NULL=true). Proves AC-E.6.
#   "unlock_opaque"      — load unlock_opaque.catalog.json: the entry with
#                          unlock_requirement "milestone_not_yet_designed"
#                          must load successfully with NO error and NO
#                          warning (parent asserts absence of ERROR:/WARNING:
#                          in output) and the opaque string must round-trip
#                          (UNLOCK_VALUE=... line). Proves AC-E.3.
#
# Output contract:
#   stdout contains "PROBE_OPERATION_COMPLETED" iff the operation returned
#     normally (an assert aborts only the current frame, execution continues
#     past it in the caller).
#   Combined stdout+stderr contains "Assertion failed" iff an assert fired.
#   Combined stdout+stderr contains "ERROR:" iff a push_error() fired.
#   exit code 0 — the operation ran to completion, quit(0) reached.
#   exit code QUIT_CODE_TIMEOUT — reserved for a genuinely hung child.
extends SceneTree

const QUIT_CODE_TIMEOUT := 66
const SAFETY_NET_FRAMES := 5
const FIXTURES_DIR := "res://tests/integration/equipment_catalog/fixtures/"

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
		"strict_all_invalid":
			# AC-E.5 strict branch: first failing entry asserts; frame aborts;
			# no catalog returned. What matters is the assert output + completing.
			loader.load_from_file(FIXTURES_DIR + "all_cost_negative.catalog.json", true)
		"nons_all_invalid":
			var result: RefCounted = loader.load_from_file(FIXTURES_DIR + "all_cost_negative.catalog.json", false)
			var catalog: RefCounted = result.get("catalog")
			print("CATALOG_IDS=" + str(catalog.call("get_all_ids")))
			print("RESULT_OK=" + str(result.get("ok")))
		"empty_queries":
			var result: RefCounted = loader.load_from_file(FIXTURES_DIR + "empty_equipment.catalog.json", false)
			var catalog: RefCounted = result.get("catalog")
			print("EMPTY_IDS=" + str(catalog.call("get_all_ids")))
			print("HAS_ANY=" + str(catalog.call("has_definition", "any")))
			# get_definition on unknown id: push_error + null (AC-E.6).
			var def: RefCounted = catalog.call("get_definition", "any")
			print("GET_DEF_NULL=" + str(def == null))
		"unlock_opaque":
			var result: RefCounted = loader.load_from_file(FIXTURES_DIR + "unlock_opaque.catalog.json", false)
			var catalog: RefCounted = result.get("catalog")
			var def: RefCounted = catalog.call("get_definition", "opaque_unlock_rack")
			print("UNLOCK_VALUE=" + str(def.get("unlock_requirement")))
			print("ERRORS_SIZE=" + str((result.get("errors") as Array).size()))
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
