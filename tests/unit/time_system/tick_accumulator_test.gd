# tests/unit/time_system/tick_accumulator_test.gd
# Story TS-002: Tick Accumulator, Speed Control, and Pause
# (production/epics/time-system/story-002-tick-accumulator-speed-pause.md)
#
# Covers the BLOCKING ACs:
#   - AC1       process(0.1) at 1x -> exactly 1 tick, accumulator ~0.0;
#               edge: delta=0.099999 does NOT fire
#   - AC2       process(0.25) -> exactly 2 ticks, accumulator ~0.05 carry-
#               forward; edges: 0.199999 -> 1 tick, 0.200001 -> 2 ticks
#   - AC3       speed_multiplier=0 across a simulated 10s span -> tick_count
#               unchanged; RNG clause structurally guaranteed (no ticks ->
#               no on_tick -> no RNG draw); byte-identity becomes directly
#               assertable in Story 003 when SeededRNG lands (documented)
#   - AC4       set_speed(3) with accumulator=0.07 / tick_count=42 -> both
#               untouched immediately after; edges 3->1, 2->3
#   - AC11      TICK_DURATION_SECONDS == exactly 0.1 (const)
#   - AC12      speed=2, delta=10.0 (hitch) -> exactly 8 ticks, leftover
#               ~19.2s carried forward (NOT discarded); next frame fires
#               ticks 9-16
#   - AC14      paused, process(5.0) x1000 -> accumulator exactly 0.0
#               (early-return path, not "add zero")
#   - AC18      paused, set_speed(3), resume -> proceeds at 3x (last-selected);
#               edges: set_speed(0) while paused stays paused; fresh resume
#               defaults to 1x
#   - AC20      72,000-tick soak at 1x -> drift < 1e-6 at every tick boundary
#               (literal 0.1s-frame run + realistic 1/60 frame-delta stress)
# plus the orchestrator wiring (Story 001 handoff: _ready -> init() constructs
# TimeSystem; _process forwards to time_system.process) and the SimSystem
# guard paths via subprocess probe (init twice, methods before init,
# invalid speed assert).
#
# Float facts verified against IEEE754 double arithmetic before writing:
#   - 1.0/10 == 0.1 exactly; 0.1 - 1*0.1 == 0.0 exactly
#   - 0.25 - 2*0.1 == 0.04999999999999999 (~0.05, assert within 1e-9)
#   - 20.0 - 8*0.1 == 19.2 exactly
#   - 3x delta=0.2: process() computes 0.2*3 = 0.6000000000000001 (1 ulp above
#     the 0.6 literal) -> /0.1 = 6.000000000000001 -> floori = 6 ticks
#   - 1x delta=0.2: 2.0 -> 2 ticks; differential 6 > 2 proves 3x rate
#   - 1/60-frame soak to 72,000 ticks: max |acc - exact_rational_expected|
#     observed 2e-12 (tolerance 1e-6)
#
# Run standalone: godot --headless --script tests/unit/time_system/tick_accumulator_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

# Subprocess probe path — keep in sync with time_system_error_probe.gd.
const PROBE_SCRIPT_PATH := "res://tests/unit/time_system/time_system_error_probe.gd"

var _pass := 0
var _fail := 0


## 被 tests/headless_runner.gd 托管时立即返回 —— 用例由 runner 调用的 run_all() 驱动。
## 否则 script.new() 触发的 _init() 与随后的 run_all() 会让每个用例跑两遍。
func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	var result := run_all()
	quit(1 if int(result["fail"]) > 0 else 0)


## 返回 {"pass": int, "fail": int} —— 见 tests/headless_runner.gd 的测试文件契约
func run_all() -> Dictionary:
	print("=".repeat(48))
	print("  UNIT TEST: TimeSystem — Tick Accumulator / Speed / Pause (Story TS-002)")
	print("=".repeat(48))

	_test_ac11_constants()
	_test_ac1_single_tick()
	_test_ac1_edge_below_tick_duration()
	_test_ac2_two_ticks_carry_forward()
	_test_ac2_edges()
	_test_ac3_paused_frozen()
	_test_ac3_pause_after_ticks_then_resume()
	_test_ac4_speed_change_no_reset()
	_test_ac12_hitch_clamp()
	_test_ac14_pause_early_return()
	_test_ac18_pause_speed_change_resume()
	_test_ac18_edges()
	_test_ac20_soak_literal()
	_test_ac20_soak_stress()
	_test_orchestrator_wiring()
	_test_guard_probe()

	print("\n=== TICK ACCUMULATOR TEST: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


# === Helpers ===

## Creates a SimulationOrchestrator in the scene tree, delivers _ready()
## synchronously (headless _init() precedes the engine's ready notification —
## same pattern as orchestrator_tick_dispatch_test.gd), and returns it with
## its wired TimeSystem. Story 001 handoff: init() constructs TimeSystem.
func _make_orchestrator() -> Node:
	var O: Script = load("res://src/systems/simulation_orchestrator.gd") as Script
	var orch: Node = O.new()
	root.add_child(orch)
	orch.call("_ready")
	return orch


## Returns the wired TimeSystem from an initialized orchestrator.
## TimeSystem is a RefCounted (SimSystem base), NOT a Node — typed as
## RefCounted so GDScript's static checker doesn't null out the return.
func _make_time_system() -> RefCounted:
	var orch := _make_orchestrator()
	var ts: Variant = orch.get("time_system")
	assert(ts != null, "time_system must be constructed by orchestrator init()")
	return ts


## Runs time_system_error_probe.gd in an ISOLATED subprocess (established
## repo pattern — GDScript has no in-process push_error/assert capture).
func _run_probe(mode: String) -> Dictionary:
	var exe := OS.get_executable_path()
	var project_root := ProjectSettings.globalize_path("res://")
	var probe_path := ProjectSettings.globalize_path(PROBE_SCRIPT_PATH)
	var args: Array[String] = ["--headless", "--path", project_root, "--script", probe_path, "--", mode]
	var output: Array = []
	var exit_code := OS.execute(exe, args, output, true)
	return {"output": "".join(output), "exit_code": exit_code}


# === Test cases ===

func _test_ac11_constants() -> void:
	print("\n[AC11] TICK_DURATION_SECONDS == 0.1 exactly; constants are consts")
	var gd: GDScript = load("res://src/systems/time_system.gd") as GDScript
	var consts: Dictionary = gd.get_script_constant_map()
	_check(int(consts["TICKS_PER_SECOND"]) == 10, "TICKS_PER_SECOND == 10 (got %s)" % consts["TICKS_PER_SECOND"])
	_check(float(consts["TICK_DURATION_SECONDS"]) == 0.1, "TICK_DURATION_SECONDS == exactly 0.1 (got %s)" % consts["TICK_DURATION_SECONDS"])
	_check(float(consts["TICK_DURATION_SECONDS"]) == 1.0 / float(consts["TICKS_PER_SECOND"]), "formula 1.0/TICKS_PER_SECOND holds in const map")
	_check(int(consts["MAX_TICKS_PER_FRAME"]) == 8, "MAX_TICKS_PER_FRAME == 8 (got %s)" % consts["MAX_TICKS_PER_FRAME"])
	_check(consts["SPEED_OPTIONS"] == [0, 1, 2, 3], "SPEED_OPTIONS == [0,1,2,3] (got %s)" % consts["SPEED_OPTIONS"])
	# const-ness is enforced at parse time (reassignment is a compile error),
	# so presence in get_script_constant_map() IS the const proof — a plain
	# var would not appear there. Advisory note, not a runtime check.


func _test_ac1_single_tick() -> void:
	print("\n[AC1] process(0.1) at 1x -> exactly 1 tick, accumulator ~0.0")
	var ts := _make_time_system()
	ts.call("resume")  # fresh TimeSystem starts paused (GDD Core Rule 9)
	ts.call("process", 0.1)
	_check(int(ts.call("get_tick_count")) == 1, "exactly 1 tick fired (got %d)" % int(ts.call("get_tick_count")))
	_check(float(ts.get("tick_accumulator")) == 0.0, "tick_accumulator returned to ~0 (exactly 0.0, got %s)" % ts.get("tick_accumulator"))


func _test_ac1_edge_below_tick_duration() -> void:
	print("\n[AC1 edge] delta=0.099999 does NOT fire (float below TICK_DURATION_SECONDS)")
	var ts := _make_time_system()
	ts.call("resume")
	ts.call("process", 0.099999)
	_check(int(ts.call("get_tick_count")) == 0, "no tick fired at delta=0.099999 (got %d)" % int(ts.call("get_tick_count")))
	_check(absf(float(ts.get("tick_accumulator")) - 0.099999) < 1e-9, "accumulator holds 0.099999 for next frame (got %s)" % ts.get("tick_accumulator"))


func _test_ac2_two_ticks_carry_forward() -> void:
	print("\n[AC2] process(0.25) -> exactly 2 ticks + ~0.05s carry-forward (not truncation)")
	var ts := _make_time_system()
	ts.call("resume")
	ts.call("process", 0.25)
	_check(int(ts.call("get_tick_count")) == 2, "exactly 2 ticks fired (got %d)" % int(ts.call("get_tick_count")))
	_check(absf(float(ts.get("tick_accumulator")) - 0.05) < 1e-9, "accumulator ~0.05s remains (got %s)" % ts.get("tick_accumulator"))


func _test_ac2_edges() -> void:
	print("\n[AC2 edge] 0.199999 -> 1 tick; 0.200001 -> 2 ticks (fresh instance each — carry-forward must not leak between edge cases)")
	var ts_a := _make_time_system()
	ts_a.call("resume")
	ts_a.call("process", 0.199999)
	_check(int(ts_a.call("get_tick_count")) == 1, "0.199999 fires exactly 1 tick (got %d)" % int(ts_a.call("get_tick_count")))
	var ts_b := _make_time_system()
	ts_b.call("resume")
	ts_b.call("process", 0.200001)
	_check(int(ts_b.call("get_tick_count")) == 2, "0.200001 fires exactly 2 ticks (got %d)" % int(ts_b.call("get_tick_count")))


func _test_ac3_paused_frozen() -> void:
	print("\n[AC3] speed_multiplier=0 across simulated 10s -> tick_count frozen, accumulator exact 0.0")
	var ts := _make_time_system()
	# Arrange the AC3 precondition speed_multiplier=0: resume to RUNNING first,
	# then set_speed(0) — the RUNNING->PAUSED transition sets speed_multiplier
	# to 0 via pause(). (set_speed(0) from an already-paused state only records
	# _last_speed=0 and leaves speed_multiplier untouched — QA edge case below.)
	ts.call("resume")
	ts.call("set_speed", 0)
	_check(bool(ts.call("is_paused")), "paused after set_speed(0) from running")
	_check(int(ts.call("get_speed_multiplier")) == 0, "speed_multiplier == 0")
	for i in 100:
		ts.call("process", 0.1)  # 10s span
	_check(int(ts.call("get_tick_count")) == 0, "tick_count unchanged (0) after 10s paused (got %d)" % int(ts.call("get_tick_count")))
	_check(float(ts.get("tick_accumulator")) == 0.0, "accumulator exactly 0.0 after 10s paused (got %s)" % ts.get("tick_accumulator"))
	# RNG clause: no ticks -> no on_tick -> no RNG draw, so every per-system
	# RNG state is structurally byte-identical. Direct byte-comparison lands
	# with Story 003 (SeededRNG) — documented deferral, same as TS-001 AC-NO-AWAIT.


func _test_ac3_pause_after_ticks_then_resume() -> void:
	print("\n[AC3 edge] pause after some ticks, freeze, then resume continues deterministically")
	var ts := _make_time_system()
	ts.call("resume")
	for i in 5:
		ts.call("process", 0.1)  # 5 ticks
	ts.call("pause")
	var before: int = int(ts.call("get_tick_count"))
	for i in 100:
		ts.call("process", 0.1)
	_check(int(ts.call("get_tick_count")) == before, "tick_count frozen at %d while paused" % before)
	_check(float(ts.get("tick_accumulator")) == 0.0, "accumulator frozen at exact 0.0")
	ts.call("resume")
	ts.call("process", 0.1)
	_check(int(ts.call("get_tick_count")) == before + 1, "resume advances tick_count by exactly 1 on next 0.1s (got %d)" % int(ts.call("get_tick_count")))


func _test_ac4_speed_change_no_reset() -> void:
	print("\n[AC4] set_speed(3) with accumulator=0.07 / tick_count=42 -> both untouched")
	var ts := _make_time_system()
	ts.call("resume")
	for i in 42:
		ts.call("process", 0.1)  # tick_count == 42
	ts.set("tick_accumulator", 0.07)  # arrange AC4's precondition directly
	ts.call("set_speed", 3)
	_check(float(ts.get("tick_accumulator")) == 0.07, "accumulator stays exactly 0.07 after set_speed(3) (got %s)" % ts.get("tick_accumulator"))
	_check(int(ts.call("get_tick_count")) == 42, "tick_count stays 42 after set_speed(3) (got %d)" % int(ts.call("get_tick_count")))
	# edges: 3->1 and 2->3 also must not reset
	ts.call("set_speed", 1)
	_check(float(ts.get("tick_accumulator")) == 0.07 and int(ts.call("get_tick_count")) == 42, "3->1 does not reset accumulator/tick_count")
	ts.call("set_speed", 2)
	_check(float(ts.get("tick_accumulator")) == 0.07 and int(ts.call("get_tick_count")) == 42, "2->3 does not reset accumulator/tick_count")
	# sanity: the next frame at 3x accumulates 3x faster (0.07 + 3*0.1 = 0.37)
	ts.call("set_speed", 3)
	ts.call("process", 0.1)
	_check(int(ts.call("get_tick_count")) == 45, "next 0.1s at 3x fires 3 ticks (0.37/0.1 floor 3) -> 45 (got %d)" % int(ts.call("get_tick_count")))
	_check(absf(float(ts.get("tick_accumulator")) - 0.07) < 1e-9, "accumulator ~0.07 remains after firing 3 (got %s)" % ts.get("tick_accumulator"))


func _test_ac12_hitch_clamp() -> void:
	print("\n[AC12] speed=2, delta=10.0 (hitch) -> exactly 8 ticks, leftover ~19.2s NOT discarded")
	var ts := _make_time_system()
	ts.call("resume")
	ts.call("set_speed", 2)
	ts.call("process", 10.0)
	_check(int(ts.call("get_tick_count")) == 8, "exactly 8 ticks fired by 10s hitch at 2x (got %d)" % int(ts.call("get_tick_count")))
	_check(absf(float(ts.get("tick_accumulator")) - 19.2) < 1e-9, "leftover ~19.2s carried forward, not discarded (got %s)" % ts.get("tick_accumulator"))
	# edge: ticks 9-16 fire in the next frame (0.1s at 2x adds 0.2 -> 19.4)
	ts.call("process", 0.1)
	_check(int(ts.call("get_tick_count")) == 16, "next frame fires ticks 9-16 -> 16 total (got %d)" % int(ts.call("get_tick_count")))
	_check(absf(float(ts.get("tick_accumulator")) - 18.6) < 1e-9, "leftover ~18.6s after second frame (got %s)" % ts.get("tick_accumulator"))


func _test_ac14_pause_early_return() -> void:
	print("\n[AC14] paused, process(5.0) x1000 -> accumulator exactly 0.0 (early return, not add-zero)")
	var ts := _make_time_system()
	ts.call("set_speed", 0)
	for i in 1000:
		ts.call("process", 5.0)
	_check(float(ts.get("tick_accumulator")) == 0.0, "accumulator exactly 0.0 after 1000 x 5s paused (got %s)" % ts.get("tick_accumulator"))
	_check(int(ts.call("get_tick_count")) == 0, "tick_count still 0 (got %d)" % int(ts.call("get_tick_count")))


func _test_ac18_pause_speed_change_resume() -> void:
	print("\n[AC18] paused + set_speed(3) -> resume proceeds at 3x (last-selected), not pre-pause speed")
	var ts := _make_time_system()
	_check(bool(ts.call("is_paused")), "fresh TimeSystem starts paused")
	ts.call("resume")  # 1x running
	ts.call("pause")
	ts.call("set_speed", 3)  # selection while paused
	_check(int(ts.call("get_speed_multiplier")) == 0, "still paused: speed_multiplier stays 0 after set_speed(3)")
	ts.call("resume")
	_check(int(ts.call("get_speed_multiplier")) == 3, "resume at last-selected 3x (got %d)" % int(ts.call("get_speed_multiplier")))
	# differential rate proof: delta=0.2 at 3x fires 6 ticks; at 1x the same
	# delta fires 2. Float-verified against the engine's actual arithmetic:
	# process() computes 0.2*3 = 0.6000000000000001 (1 ulp above the 0.6
	# literal) -> 0.6000000000000001/0.1 = 6.000000000000001 -> floori 6.
	# 6 > 2 proves the 3x rate (NOT the 1x pre-pause rate).
	ts.call("process", 0.2)
	_check(int(ts.call("get_tick_count")) == 6, "0.2s at 3x fires 6 ticks — 3x rate, not 1x (got %d)" % int(ts.call("get_tick_count")))


func _test_ac18_edges() -> void:
	print("\n[AC18 edge] set_speed(0) while paused stays paused; fresh resume defaults to 1x")
	var ts := _make_time_system()
	ts.call("resume")   # 1x
	ts.call("pause")
	ts.call("set_speed", 0)
	_check(bool(ts.call("is_paused")), "set_speed(0) while paused stays paused")
	_check(int(ts.call("get_speed_multiplier")) == 0, "speed_multiplier stays 0")
	ts.call("resume")
	_check(int(ts.call("get_speed_multiplier")) == 1, "resume after set_speed(0)-while-paused defaults to 1x (got %d)" % int(ts.call("get_speed_multiplier")))
	var ts2 := _make_time_system()
	ts2.call("resume")  # never set a speed explicitly
	_check(int(ts2.call("get_speed_multiplier")) == 1, "resume without ever setting speed defaults to 1x (got %d)" % int(ts2.call("get_speed_multiplier")))


func _test_ac20_soak_literal() -> void:
	print("\n[AC20] 72,000-tick soak at 1x (0.1s frames) -> drift < 1e-6 at every tick boundary")
	var ts := _make_time_system()
	ts.call("resume")
	var max_drift := 0.0
	var ticks_at_boundary := 0
	for i in 72000:
		var acc_before: float = float(ts.get("tick_accumulator"))
		var count_before: int = int(ts.call("get_tick_count"))
		ts.call("process", 0.1)
		if int(ts.call("get_tick_count")) > count_before:
			# tick boundary: expected accumulator == 0.0 (0.1s frame consumed exactly)
			max_drift = maxf(max_drift, absf(float(ts.get("tick_accumulator")) - 0.0))
			ticks_at_boundary += 1
	_check(int(ts.call("get_tick_count")) == 72000, "exactly 72,000 ticks fired (got %d)" % int(ts.call("get_tick_count")))
	_check(ticks_at_boundary == 72000, "all 72,000 boundaries observed")
	_check(max_drift < 1e-6, "max drift at every tick boundary < 1e-6 (got %s)" % max_drift)
	_check(float(ts.get("tick_accumulator")) == 0.0, "final accumulator exactly 0.0 (got %s)" % ts.get("tick_accumulator"))


func _test_ac20_soak_stress() -> void:
	print("\n[AC20 stress] realistic 1/60 frame deltas until 72,000 ticks -> drift < 1e-6 at every boundary")
	var ts := _make_time_system()
	ts.call("resume")
	var max_drift := 0.0
	var frames := 0
	var boundaries := 0
	var fed_units := 0  # exact-rational fed time in units of 1/600s (10 units per 1/60 frame)
	while int(ts.call("get_tick_count")) < 72000:
		var count_before: int = int(ts.call("get_tick_count"))
		ts.call("process", 1.0 / 60.0)
		frames += 1
		fed_units += 10
		if int(ts.call("get_tick_count")) > count_before:
			# exact expected accumulator = fed_units/600 - ticks*0.1, computed
			# in integer units so the reference has ZERO float error
			var ticks: int = int(ts.call("get_tick_count"))
			var expected_units: int = fed_units - ticks * 60
			var expected: float = float(expected_units) / 600.0
			max_drift = maxf(max_drift, absf(float(ts.get("tick_accumulator")) - expected))
			boundaries += 1
	_check(int(ts.call("get_tick_count")) == 72000, "72,000 ticks reached after %d frames" % frames)
	_check(boundaries == 72000, "all 72,000 boundaries observed")
	_check(max_drift < 1e-6, "max drift vs exact-rational reference < 1e-6 (got %s)" % max_drift)
	_check(frames < 500000, "realistic cadence: 1/60 frames <= ~432k (got %d)" % frames)


func _test_orchestrator_wiring() -> void:
	print("\n[handoff] Story 001 -> 002: orchestrator _ready() constructs TimeSystem; _process forwards")
	var orch := _make_orchestrator()
	var ts: Variant = orch.get("time_system")
	_check(ts != null, "orchestrator.time_system constructed by init()")
	_check(ts is TimeSystem, "time_system is a TimeSystem instance")
	_check(bool(ts.call("is_paused")), "wired TimeSystem starts paused")
	# paused: orchestrator._process forwards but no ticks
	orch.call("_process", 0.1)
	_check(int(orch.call("get_tick_count")) == 0, "no ticks while paused through orchestrator._process")
	ts.call("resume")
	orch.call("_process", 0.1)
	_check(int(orch.call("get_tick_count")) == 1, "orchestrator._process forwards 0.1s -> 1 tick (got %d)" % int(orch.call("get_tick_count")))
	_check(int(ts.call("get_tick_count")) == int(orch.call("get_tick_count")), "TimeSystem.get_tick_count() delegates to orchestrator's counter")


func _test_guard_probe() -> void:
	print("\n[SimSystem guards] init-twice / before-init / invalid-speed (subprocess probe)")
	var r := _run_probe("init_twice")
	var out: String = r["output"]
	_check(r["exit_code"] == 0, "init_twice probe exited 0")
	_check(out.find("ERROR: SimSystem: init() called twice.") != -1, "TimeSystem.init() twice -> push_error (probe)")
	_check(out.find("TICK_COUNT_AFTER_DOUBLE_INIT=0") != -1, "state intact after rejected double init")

	r = _run_probe("before_init")
	out = r["output"]
	_check(r["exit_code"] == 0, "before_init probe exited 0")
	_check(out.find("ERROR: SimSystem: method called before init().") != -1, "public methods before init() -> push_error (probe)")
	_check(out.find("TICK_COUNT_BEFORE_INIT=0") != -1, "get_tick_count() before init safe default == 0")
	_check(out.find("SPEED_BEFORE_INIT=0") != -1, "get_speed_multiplier() before init safe default == 0")
	_check(out.find("PAUSED_BEFORE_INIT=1") != -1, "is_paused() before init safe default == true")

	r = _run_probe("invalid_speed")
	out = r["output"]
	_check(r["exit_code"] == 0, "invalid_speed probe exited 0")
	_check(out.find("Assertion failed") != -1, "set_speed(4) fires assert (probe)")
	_check(out.find("SPEED_AFTER_INVALID=1") != -1, "state unchanged after rejected invalid speed (speed_multiplier still 1)")
