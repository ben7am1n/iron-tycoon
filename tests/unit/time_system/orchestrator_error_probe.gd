# tests/unit/time_system/orchestrator_error_probe.gd
# Story TS-001: SimulationOrchestrator and Tick Dispatch — subprocess probe.
#
# WHY THIS FILE EXISTS: AC-INIT-1 (init() called twice -> assert fires) and
# AC-INIT-2 (public methods before init() -> push_error + safe default) are
# not observable in-process — GDScript provides no capture of push_error /
# assert output. Following the established repo pattern (grid_rotation_assert_
# probe.gd, grid_guardrail_error_probe.gd, ...), each rejection path runs in
# an ISOLATED child `godot --headless` process and the parent test asserts on
# the child's merged stdout+stderr:
#   - assert() failure   -> Godot's own "Assertion failed" text
#   - push_error()       -> "ERROR: <message>" text
#   - safe defaults      -> explicit PROBE markers printed by this script
#
# Deliberately NOT named *_test.gd — it does not implement the
# run_all() -> Dictionary contract (see tests/README.md) and must NOT be
# picked up by headless_runner.gd's registry-coverage scan.
#
# argv (after "--"): <mode>
#   "init_once"         — happy path: init() once, catalog constructed,
#                         tick_count 0. Expects NO "ERROR:" / "Assertion
#                         failed" in output (clean-init control).
#   "init_twice"        — AC-INIT-1 (Orchestrator): init() twice. Second
#                         call must fire assert. State must stay intact:
#                         tick_count still 0, catalog still present.
#   "grid_init_twice"   — AC-INIT-1 (individual RefCounted system):
#                         GridSystem.init() twice. SimSystem._mark_initialized
#                         must push_error "SimSystem: init() called twice."
#   "before_init"       — AC-INIT-2: public methods (get_tick_count,
#                         _advance_tick, serialize) called before init().
#                         Each must push_error + return its safe default
#                         (0 / no-op-no-emit / {}).
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
var _emit_count := 0


func _init() -> void:
	var args := OS.get_cmdline_user_args()
	if args.is_empty():
		printerr("PROBE ERROR: no mode argument supplied")
		quit(2)
		return

	var mode: String = args[0]
	var O: Script = load("res://src/systems/simulation_orchestrator.gd") as Script

	match mode:
		"init_once":
			var orch: Node = O.new()
			orch.call("init")
			var catalog: Variant = orch.get("equipment_catalog")
			var tc: Variant = orch.call("get_tick_count")
			print("CATALOG_PRESENT=%d" % (1 if catalog != null else 0))
			print("TICK_COUNT_AFTER_INIT=%d" % tc)
			orch.free()  # Node is not in the tree — must free manually or the
			             # process exit reports leaked ObjectDB instances.
		"init_twice":
			var orch: Node = O.new()
			orch.call("init")
			# Second call: assert(false) fires here (AC-INIT-1). assert aborts
			# the rest of init()'s frame but NOT the process — execution
			# continues below, which is exactly what we verify.
			orch.call("init")
			var catalog: Variant = orch.get("equipment_catalog")
			var tc: Variant = orch.call("get_tick_count")
			print("TICK_COUNT_AFTER_DOUBLE_INIT=%d" % tc)
			print("CATALOG_PRESENT_AFTER_DOUBLE_INIT=%d" % (1 if catalog != null else 0))
			orch.free()
		"grid_init_twice":
			var GS: Script = load("res://src/systems/grid_system.gd") as Script
			var gs: RefCounted = GS.new()
			gs.call("init", 4, 4)
			gs.call("init", 5, 5)  # _mark_initialized -> push_error, returns false
			# State-intactness: the rejected second init must NOT resize the
			# grid. (4,4) is OOB for a 4x4 grid (in-bounds means [0,width)), so
			# this stays false only if the first init's dimensions survived.
			print("GRID_STILL_4X4=%d" % (0 if gs.call("is_in_bounds", Vector2i(4, 4)) else 1))
		"before_init":
			var orch: Node = O.new()
			orch.connect("tick_completed", Callable(self, "_on_tick_completed"))
			var tc: Variant = orch.call("get_tick_count")   # push_error + 0
			orch.call("_advance_tick")                       # push_error + no-op (no emit, no increment)
			var ser: Variant = orch.call("serialize")        # push_error + {}
			print("TICK_COUNT_BEFORE_INIT=%d" % tc)
			print("EMIT_COUNT_BEFORE_INIT=%d" % _emit_count)
			print("SERIALIZE_BEFORE_INIT_EMPTY=%d" % (1 if (ser is Dictionary and (ser as Dictionary).is_empty()) else 0))
			orch.free()
		_:
			printerr("PROBE ERROR: unknown mode '%s'" % mode)
			quit(2)
			return

	print("PROBE_OPERATION_COMPLETED")
	quit(0)


func _on_tick_completed(_tick_count: int) -> void:
	_emit_count += 1


## Safety net: if something unexpected aborted _init() before reaching
## quit(), the SceneTree main loop keeps running. Force an exit after a few
## frames instead of hanging the parent test run forever.
func _process(_delta: float) -> bool:
	_frames += 1
	if _frames >= SAFETY_NET_FRAMES:
		quit(QUIT_CODE_TIMEOUT)
	return false
