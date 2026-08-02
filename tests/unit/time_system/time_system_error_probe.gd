# tests/unit/time_system/time_system_error_probe.gd
# Story TS-002: TimeSystem — subprocess probe.
#
# WHY THIS FILE EXISTS: TimeSystem's SimSystem guard paths (init() twice ->
# push_error; public methods before init() -> push_error + safe default) and
# the set_speed() invalid-value assert are not observable in-process — GDScript
# provides no capture of push_error / assert output. Following the established
# repo pattern (orchestrator_error_probe.gd, grid_guardrail_error_probe.gd,
# ...), each rejection path runs in an ISOLATED child `godot --headless`
# process and the parent test asserts on the child's merged stdout+stderr:
#   - assert() failure   -> Godot's own "Assertion failed" text
#   - push_error()       -> "ERROR: <message>" text
#   - safe defaults      -> explicit PROBE markers printed by this script
#
# Deliberately NOT named *_test.gd — it does not implement the
# run_all() -> Dictionary contract (see tests/README.md) and must NOT be
# picked up by headless_runner.gd's registry-coverage scan.
#
# argv (after "--"): <mode>
#   "init_twice"     — TimeSystem.init(orch) twice. Second call must push_error
#                      "SimSystem: init() called twice."; state stays intact
#                      (tick_count still 0, still paused).
#   "before_init"    — public methods (process, set_speed, pause, resume,
#                      is_paused, get_speed_multiplier, get_tick_count) before
#                      init(). Each must push_error + return its safe default.
#   "invalid_speed"  — set_speed(4) after init. Must fire assert("Invalid
#                      speed: 4"); state unchanged (speed_multiplier still 1).
#
# Output contract:
#   stdout contains "PROBE_OPERATION_COMPLETED" iff the operation returned
#     normally (no process abort).
#   Combined stdout+stderr (OS.execute read_stderr=true merges both):
#     "Assertion failed"        iff an assert fired
#     "ERROR: ..."              iff some path fired push_error
#   exit code 0                 — operation ran to completion, quit(0) reached.
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
	var TS: Script = load("res://src/systems/time_system.gd") as Script
	var O: Script = load("res://src/systems/simulation_orchestrator.gd") as Script

	match mode:
		"init_twice":
			# A real orchestrator is needed as the injected back-reference; it
			# does not need _ready()/init() for TimeSystem.init() to accept it.
			var orch: Node = O.new()
			var ts: RefCounted = TS.new()
			ts.call("init", orch)
			ts.call("init", orch)  # _mark_initialized -> push_error, returns false
			print("TICK_COUNT_AFTER_DOUBLE_INIT=%d" % int(ts.call("get_tick_count")))
			print("PAUSED_AFTER_DOUBLE_INIT=%d" % (1 if bool(ts.call("is_paused")) else 0))
			orch.free()  # Node not in tree — free manually or leak-reported at exit
		"before_init":
			var orch: Node = O.new()
			var ts: RefCounted = TS.new()
			ts.call("process", 0.1)          # push_error + no-op
			ts.call("set_speed", 2)          # push_error + no-op
			ts.call("pause")                 # push_error + no-op
			ts.call("resume")                # push_error + no-op
			var tc: Variant = ts.call("get_tick_count")          # push_error + 0
			var sp: Variant = ts.call("get_speed_multiplier")    # push_error + 0
			var paused: Variant = ts.call("is_paused")           # push_error + true
			print("TICK_COUNT_BEFORE_INIT=%d" % tc)
			print("SPEED_BEFORE_INIT=%d" % sp)
			print("PAUSED_BEFORE_INIT=%d" % (1 if bool(paused) else 0))
			orch.free()
		"invalid_speed":
			var orch: Node = O.new()
			var ts: RefCounted = TS.new()
			ts.call("init", orch)
			# set_speed(4): assert("Invalid speed: 4") fires — aborts the rest
			# of set_speed()'s frame but NOT the process; execution continues.
			ts.call("set_speed", 4)
			print("SPEED_AFTER_INVALID=%d" % int(ts.call("get_speed_multiplier")))
			orch.free()
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
