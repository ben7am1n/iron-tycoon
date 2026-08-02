# tests/unit/time_system/orchestrator_tick_dispatch_test.gd
# Story TS-001: SimulationOrchestrator and Tick Dispatch
# (production/epics/time-system/story-001-orchestrator-tick-dispatch.md)
#
# Covers the BLOCKING ACs:
#   - AC5       dispatch order [MemberSim, Congestion, Satisfaction, Economy]
#               -> tick_count increments AFTER all calls -> tick_completed emits
#               once with the NEW value (arity 1, per ADR-0005 S2)
#   - AC19      the 8-tick clamp: each tick independently completes the FULL
#               sequence — no batching, no short-circuiting, unique monotonic
#               tick_count per tick, exactly one emission per tick
#   - AC-INIT-1 init() called twice -> assert() fires (Orchestrator via
#               subprocess probe; individual RefCounted system GridSystem via
#               SimSystem._mark_initialized push_error probe)
#   - AC-INIT-2 public methods (_advance_tick, get_tick_count, serialize)
#               before init() -> push_error() + safe default (subprocess probe)
#   - AC-NO-AWAIT [ADVISORY] static grep: no await/yield statement anywhere
#               in src/ (no on_tick implementations exist yet; this is the
#               Story-001-available approximation of the code-review rule)
# plus the topological-init (Tier 0-7) enforcement through _ready() and the
# QA edge cases (empty tick sequence, tick_completed subscriber count change).
#
# NOTE on _ready() in headless: this runner executes run_all() synchronously
# inside _init(), BEFORE the SceneTree main loop delivers NOTIFICATION_READY.
# _make_orchestrator() therefore invokes orch.call("_ready") directly after
# root.add_child() — the exact code path the engine would call, exercised
# deterministically. (Verified empirically: without the explicit call,
# _ready() never fires during the test.)
#
# Run standalone: godot --headless --script tests/unit/time_system/orchestrator_tick_dispatch_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

# Subprocess probe path — keep in sync with orchestrator_error_probe.gd.
const PROBE_SCRIPT_PATH := "res://tests/unit/time_system/orchestrator_error_probe.gd"

# Static-grep pattern for AC-NO-AWAIT: an await/yield statement anywhere on a
# line, but never inside a comment (a '#' before the keyword excludes it).
# Heuristic limitation (documented, ADVISORY): string literals containing the
# keywords would be false positives — src/ currently has none.
const AWAIT_YIELD_RE := "(?m)^[^#]*\\b(await|yield)\\b.*$"


## Spy implementing the TickableSystem convention contract
## (func on_tick(tick_count: int) -> void — NO await/yield). Records into
## shared arrays so the test can assert exact dispatch order and the exact
## tick_count each call received.
class Spy:
	extends RefCounted

	var name: String
	var call_log: Array   # shared — appends name per call
	var tick_args: Array  # shared — appends tick_count per call

	func _init(p_name: String, p_call_log: Array, p_tick_args: Array) -> void:
		name = p_name
		call_log = p_call_log
		tick_args = p_tick_args

	func on_tick(tick_count: int) -> void:
		call_log.append(name)
		tick_args.append(tick_count)


var _pass := 0
var _fail := 0

# tick_completed observation. Bound methods (NOT lambdas — GDScript lambdas
# capture local variables by value, so a lambda counter would never update).
var _emit_count := 0
var _emit_payloads: Array = []
var _emit_count_b := 0
var _emit_payloads_b: Array = []


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
	print("  UNIT TEST: SimulationOrchestrator — Tick Dispatch (Story TS-001)")
	print("=".repeat(48))

	_test_ready_topological_init()
	_test_fixed_order_constant()
	_test_ac5_dispatch_order_single_tick()
	_test_ac5_second_tick_sees_new_count()
	_test_ac5_emit_exactly_once_per_tick()
	_test_ac19_eight_ticks_full_sequence()
	_test_empty_tick_sequence()
	_test_tick_completed_subscriber_count_change()
	_test_ac_init_1_orchestrator_double_init_probe()
	_test_ac_init_1_individual_system_double_init_probe()
	_test_ac_init_2_before_init_probe()
	_test_init_clean_probe()
	_test_ac_no_await_static_grep()

	print("\n=== ORCHESTRATOR TICK DISPATCH TEST: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


# === Helpers ===

## Creates a SimulationOrchestrator in the scene tree and delivers _ready()
## synchronously (see header note — headless _init() precedes the engine's
## ready notification).
func _make_orchestrator() -> Node:
	var O: Script = load("res://src/systems/simulation_orchestrator.gd") as Script
	var orch: Node = O.new()
	root.add_child(orch)
	orch.call("_ready")
	return orch


## Installs 4 spy systems in the LOCKED order and returns [call_log, tick_args].
func _install_spies(orch: Node) -> Array:
	var call_log: Array = []
	var tick_args: Array = []
	var spies: Array = [
		Spy.new("MemberSim", call_log, tick_args),
		Spy.new("Congestion", call_log, tick_args),
		Spy.new("Satisfaction", call_log, tick_args),
		Spy.new("Economy", call_log, tick_args),
	]
	orch.set("_tick_systems", spies)
	return [call_log, tick_args]


func _reset_emit() -> void:
	_emit_count = 0
	_emit_payloads = []
	_emit_count_b = 0
	_emit_payloads_b = []


func _on_tick_completed(tick_count: int) -> void:
	_emit_count += 1
	_emit_payloads.append(tick_count)


func _on_tick_completed_b(tick_count: int) -> void:
	_emit_count_b += 1
	_emit_payloads_b.append(tick_count)


## Runs orchestrator_error_probe.gd in an ISOLATED subprocess (same pattern
## as the grid/equipment probes) — GDScript has no in-process push_error /
## assert capture, so the rejection paths are verified via the child's merged
## stdout+stderr. read_stderr=true merges both streams.
func _run_probe(mode: String) -> Dictionary:
	var exe := OS.get_executable_path()
	var project_root := ProjectSettings.globalize_path("res://")
	var probe_path := ProjectSettings.globalize_path(PROBE_SCRIPT_PATH)

	var args: Array[String] = ["--headless", "--path", project_root, "--script", probe_path, "--", mode]

	var output: Array = []
	var exit_code := OS.execute(exe, args, output, true)
	var output_text: String = "".join(output)

	return {"output": output_text, "exit_code": exit_code}


func _test_ready_topological_init() -> void:
	print("\n[Topological init] _ready() runs init() — Tier 0 systems constructed")
	var orch := _make_orchestrator()
	var catalog: Variant = orch.get("equipment_catalog")
	_check(catalog != null, "equipment_catalog constructed by _ready()->init()")
	_check(catalog is EquipmentCatalog, "equipment_catalog is an EquipmentCatalog instance")
	_check(orch.call("get_tick_count") == 0, "fresh orchestrator tick_count == 0")
	var ser: Variant = orch.call("serialize")
	_check(
		ser is Dictionary and (ser as Dictionary).is_empty(),
		"serialize() after init returns empty stub Dictionary (Story 004 fills it)"
	)


func _test_fixed_order_constant() -> void:
	print("\n[TR-TS-003] FIXED_TICK_ORDER textually locks the dispatch order")
	var gd: GDScript = load("res://src/systems/simulation_orchestrator.gd") as GDScript
	var order: Variant = gd.get_script_constant_map()["FIXED_TICK_ORDER"]
	_check(order is Array and (order as Array).size() == 4, "FIXED_TICK_ORDER has exactly 4 entries")
	_check(
		order == ["MemberSim", "Congestion", "Satisfaction", "Economy"],
		"FIXED_TICK_ORDER == [MemberSim, Congestion, Satisfaction, Economy] (got %s)" % [order]
	)


func _test_ac5_dispatch_order_single_tick() -> void:
	print("\n[AC5] one tick — order [MemberSim, Congestion, Satisfaction, Economy] -> increment -> emit once")
	var orch := _make_orchestrator()
	_reset_emit()
	orch.connect("tick_completed", Callable(self, "_on_tick_completed"))
	var install := _install_spies(orch)
	var call_log: Array = install[0]
	var tick_args: Array = install[1]

	orch.call("_advance_tick")

	_check(
		call_log == ["MemberSim", "Congestion", "Satisfaction", "Economy"],
		"recorded call order == [MemberSim, Congestion, Satisfaction, Economy] (got %s)" % [call_log]
	)
	_check(
		tick_args == [0, 0, 0, 0],
		"all spies saw tick_count 0 — dispatch happens BEFORE increment (got %s)" % [tick_args]
	)
	_check(orch.call("get_tick_count") == 1, "tick_count incremented to 1 AFTER dispatch")
	_check(_emit_count == 1, "tick_completed emitted exactly once per tick")
	_check(_emit_payloads == [1], "tick_completed payload == new tick_count 1 (got %s)" % [_emit_payloads])
	_check(
		_emit_payloads.size() == 1 and int(_emit_payloads[0]) == int(orch.call("get_tick_count")),
		"emit payload matches get_tick_count()"
	)


func _test_ac5_second_tick_sees_new_count() -> void:
	print("\n[AC5 edge] second tick — dispatch sees the incremented count, emit carries 2")
	var orch := _make_orchestrator()
	_reset_emit()
	orch.connect("tick_completed", Callable(self, "_on_tick_completed"))
	var install := _install_spies(orch)
	var call_log: Array = install[0]
	var tick_args: Array = install[1]

	orch.call("_advance_tick")
	orch.call("_advance_tick")

	_check(call_log.size() == 8, "two ticks dispatch 8 on_tick calls total")
	_check(
		tick_args == [0, 0, 0, 0, 1, 1, 1, 1],
		"second tick's spies saw tick_count 1 — monotonic per-tick counts (got %s)" % [tick_args]
	)
	_check(_emit_payloads == [1, 2], "two emissions carry [1, 2] (got %s)" % [_emit_payloads])


func _test_ac5_emit_exactly_once_per_tick() -> void:
	print("\n[AC5] emit frequency — 5 ticks -> exactly 5 emissions")
	var orch := _make_orchestrator()
	_reset_emit()
	orch.connect("tick_completed", Callable(self, "_on_tick_completed"))
	for i in 5:
		orch.call("_advance_tick")
	_check(_emit_count == 5, "5 ticks emit tick_completed exactly 5 times")
	_check(_emit_payloads.size() == 5, "5 emissions each carry one payload")


func _test_ac19_eight_ticks_full_sequence() -> void:
	print("\n[AC19] 8-tick clamp — each tick independently completes the FULL sequence (no batching)")
	var orch := _make_orchestrator()
	_reset_emit()
	orch.connect("tick_completed", Callable(self, "_on_tick_completed"))
	var install := _install_spies(orch)
	var call_log: Array = install[0]
	var tick_args: Array = install[1]

	for i in 8:
		orch.call("_advance_tick")

	var expected_calls: Array = []
	var expected_args: Array = []
	for t in 8:
		for sys in ["MemberSim", "Congestion", "Satisfaction", "Economy"]:
			expected_calls.append(sys)
			expected_args.append(t)

	_check(call_log.size() == 32, "8 ticks dispatch 32 on_tick calls total — no batching")
	_check(
		call_log == expected_calls,
		"call order across 8 ticks == full sequence repeated 8 times (got %s)" % [call_log]
	)
	_check(
		tick_args == expected_args,
		"each tick's 4 calls see that tick's unique tick_count (got %s)" % [tick_args]
	)
	_check(orch.call("get_tick_count") == 8, "tick_count == 8 after 8 ticks")
	_check(_emit_count == 8, "tick_completed emitted exactly 8 times (once per tick)")
	_check(
		_emit_payloads == [1, 2, 3, 4, 5, 6, 7, 8],
		"emissions carry unique monotonic counts [1..8] (got %s)" % [_emit_payloads]
	)
	var grouped_ok := true
	for t in 8:
		var group := call_log.slice(t * 4, t * 4 + 4)
		if group != ["MemberSim", "Congestion", "Satisfaction", "Economy"]:
			grouped_ok = false
	_check(grouped_ok, "every tick's 4 calls are the exact fixed order — no short-circuiting")


func _test_empty_tick_sequence() -> void:
	print("\n[edge] empty _tick_systems — still increments + emits exactly once")
	var orch := _make_orchestrator()
	_reset_emit()
	orch.connect("tick_completed", Callable(self, "_on_tick_completed"))
	orch.set("_tick_systems", [])
	orch.call("_advance_tick")
	_check(orch.call("get_tick_count") == 1, "empty sequence still increments tick_count")
	_check(_emit_count == 1, "empty sequence still emits tick_completed once")
	_check(_emit_payloads == [1], "empty sequence emits with the new count 1")


func _test_tick_completed_subscriber_count_change() -> void:
	print("\n[edge] subscriber count changes — every connected subscriber receives each emission")
	var orch := _make_orchestrator()
	_reset_emit()
	orch.connect("tick_completed", Callable(self, "_on_tick_completed"))
	orch.call("_advance_tick")
	_check(_emit_count == 1, "1 subscriber receives the emission")

	orch.connect("tick_completed", Callable(self, "_on_tick_completed_b"))
	orch.call("_advance_tick")
	_check(_emit_count == 2, "after adding 2nd subscriber, first keeps receiving")
	_check(_emit_count_b == 1, "second subscriber receives from its connect point on")
	_check(_emit_payloads_b == [2], "second subscriber sees the same payload (2) as the first")

	orch.disconnect("tick_completed", Callable(self, "_on_tick_completed_b"))
	orch.call("_advance_tick")
	_check(_emit_count == 3, "after disconnecting 2nd subscriber, first keeps receiving")
	_check(_emit_count_b == 1, "disconnected subscriber no longer receives")


func _test_ac_init_1_orchestrator_double_init_probe() -> void:
	print("\n[AC-INIT-1] Orchestrator init() twice -> assert fires (subprocess probe)")
	var r := _run_probe("init_twice")
	var out: String = r["output"]
	_check(r["exit_code"] == 0, "probe exited 0 (assert aborts frame, not process)")
	_check(out.find("Assertion failed") != -1, "probe output contains Godot 'Assertion failed'")
	_check(out.find("TICK_COUNT_AFTER_DOUBLE_INIT=0") != -1, "tick_count intact (0) after rejected double init")
	_check(out.find("CATALOG_PRESENT_AFTER_DOUBLE_INIT=1") != -1, "first init's systems intact after rejected double init")


func _test_ac_init_1_individual_system_double_init_probe() -> void:
	print("\n[AC-INIT-1] individual RefCounted system — GridSystem.init() twice -> push_error (subprocess probe)")
	var r := _run_probe("grid_init_twice")
	var out: String = r["output"]
	_check(r["exit_code"] == 0, "probe exited 0")
	_check(out.find("SimSystem: init() called twice.") != -1, "probe output contains SimSystem double-init push_error")
	_check(out.find("GRID_STILL_4X4=1") != -1, "rejected second init did not resize the grid (state intact)")


func _test_ac_init_2_before_init_probe() -> void:
	print("\n[AC-INIT-2] public methods before init() -> push_error + safe default (subprocess probe)")
	var r := _run_probe("before_init")
	var out: String = r["output"]
	_check(r["exit_code"] == 0, "probe exited 0")
	_check(
		out.find("ERROR: SimulationOrchestrator: method called before init().") != -1,
		"probe output contains the guard's push_error"
	)
	_check(out.find("TICK_COUNT_BEFORE_INIT=0") != -1, "get_tick_count() safe default == 0")
	_check(out.find("EMIT_COUNT_BEFORE_INIT=0") != -1, "_advance_tick() before init emits nothing")
	_check(out.find("SERIALIZE_BEFORE_INIT_EMPTY=1") != -1, "serialize() before init safe default == {}")


func _test_init_clean_probe() -> void:
	print("\n[topological init control] init() once — NO push_error / assert in output")
	var r := _run_probe("init_once")
	var out: String = r["output"]
	_check(r["exit_code"] == 0, "probe exited 0")
	_check(out.find("ERROR:") == -1, "clean init produces NO ERROR lines")
	_check(out.find("Assertion failed") == -1, "clean init produces NO assert failures")
	_check(out.find("CATALOG_PRESENT=1") != -1, "init() constructs EquipmentCatalog (Tier 0)")


func _test_ac_no_await_static_grep() -> void:
	print("\n[AC-NO-AWAIT][ADVISORY] static grep — no await/yield statement in src/")
	print("  no on_tick() implementations exist yet — this scans for ANY await/yield statement")
	var violations: Array[String] = []
	_scan_src_for_await_yield("res://src", violations)
	_check(violations.is_empty(), "no await/yield statements in src/ (found: %s)" % [violations])


func _scan_src_for_await_yield(dir_path: String, violations: Array) -> void:
	var dir := DirAccess.open(dir_path)
	if dir == null:
		return
	dir.list_dir_begin()
	var entry := dir.get_next()
	while entry != "":
		if entry.begins_with("."):
			entry = dir.get_next()
			continue
		var child := "%s/%s" % [dir_path, entry]
		if dir.current_is_dir():
			_scan_src_for_await_yield(child, violations)
		elif entry.ends_with(".gd"):
			var f := FileAccess.open(child, FileAccess.READ)
			if f != null:
				var text := f.get_as_text()
				f.close()
				var re := RegEx.new()
				re.compile(AWAIT_YIELD_RE)
				for m in re.search_all(text):
					violations.append("%s: %s" % [child, m.get_string().strip_edges()])
		entry = dir.get_next()
	dir.list_dir_end()
