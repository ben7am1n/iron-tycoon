# tests/unit/satisfaction/penalty_caps_test.gd
# Story SAT-002: S_member and Penalty Caps
# (production/epics/satisfaction/story-002-s-member-penalty-caps.md)
#
# Covers the BLOCKING ACs (TR-SAT-004, per the story QA test cases):
#   - AC11 queue penalty cap: queue_ticks_total far exceeding
#         queue_norm_ticks -> queue_penalty <= 0.3. Edge: == norm -> 0.3;
#         == 0 -> 0.
#   - AC12 fail/interrupt penalty caps: n_fail = 10, n_interrupt = 10 ->
#         fail_penalty <= 0.30, interrupt_penalty <= 0.20. Edge: n_fail = 1
#         -> 0.15, = 2 -> 0.30, = 3 -> still 0.30; n_interrupt = 1 -> 0.20,
#         = 2 -> still 0.20.
#   - Guardrail: each penalty term is individually capped so one-off event
#         penalties are always SMALLER in magnitude than the zone/congestion
#         terms — queue noise and bad-luck events never drown out the core
#         spatial-optimization signal. Max total event penalty 0.80 leaves
#         S_base + avg(use_quality) dominant for members with positive uses.
#
# The caps live inside compute_s_member (Core Rule 4 / TR-SAT-004) as
# _queue_penalty / _fail_penalty / _interrupt_penalty. This test exercises
# ONLY the public surface: crafted accumulators through compute_s_member, the
# public event API (add_queue_ticks / on_walk_fail / on_interrupt /
# on_member_departed — which folds and returns S_member), and one on_tick
# integration case proving the roster-diff wiring feeds the counters
# (ADR-0005 §3 direct reads).
#
# Float policy: exact == only where the arithmetic is provably exact in IEEE
# double (0.5, 0.2 via 0.5-0.3, 0.3 via 0.5-0.2, 0.0, 1.0); everything else
# uses the codebase's standard absf() < 1e-9 tolerance (tick_accumulator_test
# precedent). The ACs themselves are inequalities (<= 0.3 / <= 0.30 /
# <= 0.20) — the caps, not the exact values, are the contract.
#
# Run standalone: godot --headless --script tests/unit/satisfaction/penalty_caps_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

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
	print("  UNIT TEST: Satisfaction — S_member Penalty Caps (Story SAT-002)")
	print("=".repeat(48))

	_test_ac11_queue_penalty_cap()
	_test_ac12_fail_interrupt_caps()
	_test_guardrail_noise_never_drowns_signal()
	_test_on_tick_penalty_wiring()
	_test_walk_fail_counts_per_departure()

	print("\n=== PENALTY CAPS TEST: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


## Standard float tolerance (tick_accumulator_test precedent).
func _check_float(actual: float, expected: float, msg: String) -> void:
	_check(absf(actual - expected) < 1e-9, "%s (got %s, exp %s)" % [msg, str(actual), str(expected)])


# === Helpers ===

func _SRG() -> Script:
	return load("res://src/systems/seeded_rng.gd") as Script


func _ST() -> Script:
	return load("res://src/systems/satisfaction.gd") as Script


func _make_orchestrator() -> Node:
	var orch: Node = load("res://src/systems/simulation_orchestrator.gd").new()
	root.add_child(orch)
	orch.call("_ready")
	return orch


## Controllable congestion reader — returns the injected value per
## equipment_instance_id (the CG-004 per_equipment_congestion surface).
class FakeCongestion:
	extends RefCounted

	var values: Dictionary = {}

	func per_equipment_congestion(instance_id: int) -> float:
		return float(values.get(instance_id, 0.0))

	func set_congestion(instance_id: int, value: float) -> void:
		values[instance_id] = value


## Controllable MemberSim read surface — the roster + penalty counter
## Satisfaction's on_tick consumes (ADR-0005 §3 direct reads).
class FakeMemberSim:
	extends RefCounted

	var members: Array = []
	var penalty_events: int = 0

	func get_satisfaction_penalty_events() -> int:
		return penalty_events


## Builds a Satisfaction rig with:
##   [zone_totals]   instance_id -> total_i (ZoneRules per-instance total)
##   [member_sim]    FakeMemberSim or null (null -> event API only, no on_tick)
## Returns the rig with "sat" for driving.
func _make_rig(zone_totals: Dictionary = {}, member_sim: FakeMemberSim = null) -> Dictionary:
	var orch: Node = _make_orchestrator()
	var srg: RefCounted = _SRG().new()
	srg.call("init", 0x5EEDCAFE12345678)

	var cong := FakeCongestion.new()
	var zone_reader := func(instance_id: int) -> float:
		return float(zone_totals.get(instance_id, 0.0))

	var sat: RefCounted = _ST().new()
	sat.call("init", orch, srg, member_sim, cong, zone_reader)

	return {"sat": sat, "congestion": cong, "member_sim": member_sim}


## S_member for an accumulator with ONLY the [overrides] fields set (all other
## counters zero) — extracts each penalty in isolation.
func _s_member(rig: Dictionary, overrides: Dictionary) -> float:
	var acc := {
		"S_acc": 0.0, "n_uses": 0,
		"queue_ticks": 0, "n_fail": 0, "n_interrupt": 0,
	}
	for key in overrides:
		acc[key] = overrides[key]
	return float(rig["sat"].call("compute_s_member", acc))


## With a single penalty term active and nothing else, S_member = S_base −
## penalty (no clamp interference while S_member stays > 0), so the penalty is
## recoverable exactly as S_base − S_member.
func _penalty(rig: Dictionary, overrides: Dictionary) -> float:
	return 0.5 - _s_member(rig, overrides)


# === AC11: queue penalty cap ===

func _test_ac11_queue_penalty_cap() -> void:
	print("\n[AC11] queue_penalty <= 0.3 even when queue_ticks_total far exceeds queue_norm_ticks (100)")
	var rig := _make_rig()

	# Far exceeding: 100000 ticks = 1000x the norm -> clamped to 1.0 -> 0.3.
	var s_far: float = _s_member(rig, {"queue_ticks": 100000})
	_check_float(s_far, 0.2, "AC11: queue 100000 (1000x norm) -> penalty 0.3, S_member 0.5-0.3 == 0.2")

	# Sweep: penalty never exceeds 0.3 and is non-decreasing in queue_ticks.
	var prev_p: float = -1.0
	var capped := true
	var monotonic := true
	for ticks in [0, 25, 50, 99, 100, 101, 250, 500, 1000, 10000, 100000]:
		var p: float = _penalty(rig, {"queue_ticks": ticks})
		if p > 0.3 + 1e-9:
			capped = false
		if p < prev_p - 1e-9:
			monotonic = false
		prev_p = p
	_check(capped, "AC11: queue_penalty <= 0.3 across sweep 0..100000 ticks")
	_check(monotonic, "AC11: queue_penalty non-decreasing in queue_ticks (saturating, never negative)")

	# Edge: exactly at the norm -> exactly the cap.
	var s_norm: float = _s_member(rig, {"queue_ticks": 100})
	_check_float(s_norm, 0.2, "AC11 edge: queue_ticks == queue_norm_ticks (100) -> penalty exactly 0.3")

	# Edge: zero ticks -> zero penalty.
	var s_zero: float = _s_member(rig, {"queue_ticks": 0})
	_check_float(s_zero, 0.5, "AC11 edge: queue_ticks == 0 -> penalty 0, S_member == S_base == 0.5")

	# Event API: queue ticks accumulate per QUEUEING tick; departure folds the
	# capped S_member (on_member_departed returns it).
	var rig2 := _make_rig()
	rig2["sat"].call("on_member_entered", 1)
	rig2["sat"].call("add_queue_ticks", 1, 100000)
	var s_depart_far: float = float(rig2["sat"].call("on_member_departed", 1))
	_check_float(s_depart_far, 0.2, "AC11 event: 100000 queued ticks -> departed S_member 0.2 (penalty 0.3)")

	rig2["sat"].call("on_member_entered", 2)
	rig2["sat"].call("add_queue_ticks", 2, 100)
	var s_depart_norm: float = float(rig2["sat"].call("on_member_departed", 2))
	_check_float(s_depart_norm, 0.2, "AC11 event: exactly 100 queued ticks -> departed S_member 0.2 (penalty 0.3)")

	rig2["sat"].call("on_member_entered", 3)
	var s_depart_zero: float = float(rig2["sat"].call("on_member_departed", 3))
	_check_float(s_depart_zero, 0.5, "AC11 event: no queue ticks -> departed S_member == S_base == 0.5")


# === AC12: fail/interrupt penalty caps ===

func _test_ac12_fail_interrupt_caps() -> void:
	print("\n[AC12] fail_penalty <= 0.30, interrupt_penalty <= 0.20 at n_fail=10, n_interrupt=10 (and caps hold for any count)")
	var rig := _make_rig()

	# n_fail = 10 -> min(0.15*10, 0.30) = 0.30 (capped, not 1.50).
	_check_float(_penalty(rig, {"n_fail": 10}), 0.30, "AC12: n_fail=10 -> fail_penalty == 0.30 (capped)")
	_check_float(_s_member(rig, {"n_fail": 10}), 0.2, "AC12: n_fail=10 -> S_member 0.5-0.30 == 0.2")

	# QA edge cases: 1 -> 0.15; 2 -> 0.30; 3 -> still 0.30 (max 2 contribute).
	_check_float(_penalty(rig, {"n_fail": 1}), 0.15, "AC12 edge: n_fail=1 -> fail_penalty == 0.15")
	_check_float(_penalty(rig, {"n_fail": 2}), 0.30, "AC12 edge: n_fail=2 -> fail_penalty == 0.30")
	_check_float(_penalty(rig, {"n_fail": 3}), 0.30, "AC12 edge: n_fail=3 -> fail_penalty still 0.30")

	# Sweep: never above 0.30, non-decreasing, flat past the cap.
	var prev_fp: float = -1.0
	var fail_capped := true
	var fail_monotonic := true
	for n in range(0, 21):
		var fp: float = _penalty(rig, {"n_fail": n})
		if fp > 0.30 + 1e-9:
			fail_capped = false
		if fp < prev_fp - 1e-9:
			fail_monotonic = false
		prev_fp = fp
	_check(fail_capped, "AC12: fail_penalty <= 0.30 for n_fail 0..20")
	_check(fail_monotonic, "AC12: fail_penalty non-decreasing, saturates at the cap")

	# n_interrupt = 10 -> min(0.20*10, 0.20) = 0.20 (capped, not 2.00).
	_check_float(_penalty(rig, {"n_interrupt": 10}), 0.20, "AC12: n_interrupt=10 -> interrupt_penalty == 0.20 (capped)")
	_check_float(_s_member(rig, {"n_interrupt": 10}), 0.3, "AC12: n_interrupt=10 -> S_member 0.5-0.20 == 0.3")

	# QA edge cases: 1 -> 0.20; 2 -> still 0.20 (max 1 contributes).
	_check_float(_penalty(rig, {"n_interrupt": 1}), 0.20, "AC12 edge: n_interrupt=1 -> interrupt_penalty == 0.20")
	_check_float(_penalty(rig, {"n_interrupt": 2}), 0.20, "AC12 edge: n_interrupt=2 -> interrupt_penalty still 0.20")

	# Sweep: never above 0.20, non-decreasing, flat past the cap.
	var prev_ip: float = -1.0
	var int_capped := true
	var int_monotonic := true
	for n in range(0, 21):
		var ip: float = _penalty(rig, {"n_interrupt": n})
		if ip > 0.20 + 1e-9:
			int_capped = false
		if ip < prev_ip - 1e-9:
			int_monotonic = false
		prev_ip = ip
	_check(int_capped, "AC12: interrupt_penalty <= 0.20 for n_interrupt 0..20")
	_check(int_monotonic, "AC12: interrupt_penalty non-decreasing, saturates at the cap")

	# All three caps hit simultaneously (zero-use member): 0.3+0.3+0.2 = 0.8 >
	# S_base 0.5 -> S_member clamps to 0 (never negative).
	_check_float(_s_member(rig, {"queue_ticks": 100000, "n_fail": 10, "n_interrupt": 10}), 0.0, "AC12: all caps + zero use -> S_member clamped to 0")

	# Event API: on_walk_fail / on_interrupt drive the counters; departure
	# folds the capped S_member.
	var rig2 := _make_rig()
	rig2["sat"].call("on_member_entered", 1)
	for i in range(10):
		rig2["sat"].call("on_walk_fail", 1)
	for i in range(10):
		rig2["sat"].call("on_interrupt", 1)
	var s_both: float = float(rig2["sat"].call("on_member_departed", 1))
	_check_float(s_both, 0.0, "AC12 event: 10 fails + 10 interrupts, no use -> departed S_member 0.0 (0.5-0.30-0.20 clamped)")

	rig2["sat"].call("on_member_entered", 2)
	for i in range(3):
		rig2["sat"].call("on_walk_fail", 2)
	var s_fails: float = float(rig2["sat"].call("on_member_departed", 2))
	_check_float(s_fails, 0.2, "AC12 event: 3 walk-fails -> departed S_member 0.2 (fail penalty capped at 0.30)")

	rig2["sat"].call("on_member_entered", 3)
	for i in range(2):
		rig2["sat"].call("on_interrupt", 3)
	var s_ints: float = float(rig2["sat"].call("on_member_departed", 3))
	_check_float(s_ints, 0.3, "AC12 event: 2 interrupts -> departed S_member 0.3 (interrupt penalty capped at 0.20)")


# === Guardrail: event noise never drowns the spatial signal ===

func _test_guardrail_noise_never_drowns_signal() -> void:
	print("\n[guardrail] each penalty cap < max |use_quality| (0.5); max total event penalty 0.80 < S_base + best avg (1.0)")
	var rig := _make_rig()

	# Every individual cap is strictly smaller than the strongest single use
	# signal (+/-0.5) — a one-off event can never outweigh one good/bad use.
	var qp_cap: float = _penalty(rig, {"queue_ticks": 100000})
	var fp_cap: float = _penalty(rig, {"n_fail": 100})
	var ip_cap: float = _penalty(rig, {"n_interrupt": 100})
	_check(qp_cap < 0.5 and fp_cap < 0.5 and ip_cap < 0.5,
		"guardrail: caps 0.3 / 0.30 / 0.20 all < 0.5 (max |use_quality|)")

	# Perfect use (avg +0.5) + ALL penalties maxed: S_base+avg = 1.0 > 0.80 ->
	# S_member stays positive (0.2). Event noise alone can never zero a member
	# with good use events — the spatial signal stays dominant.
	var acc_perfect_max := {
		"S_acc": 0.5, "n_uses": 1,
		"queue_ticks": 100000, "n_fail": 100, "n_interrupt": 100,
	}
	var s_perfect_max: float = float(rig["sat"].call("compute_s_member", acc_perfect_max))
	_check_float(s_perfect_max, 0.2, "guardrail: perfect use + all caps -> S_member 0.2 (spatial signal 1.0 beats 0.80 noise)")

	var acc_perfect := {
		"S_acc": 0.5, "n_uses": 1,
		"queue_ticks": 0, "n_fail": 0, "n_interrupt": 0,
	}
	var s_perfect: float = float(rig["sat"].call("compute_s_member", acc_perfect))
	_check_float(s_perfect, 1.0, "guardrail: perfect use, no penalties -> S_member 1.0 (0.5+0.5)")

	# Event API: one real perfect use + 10 fails + 10 interrupts + huge queue.
	# use_quality = 0.5*clamp(2.0/2.0) - 0.5*0.0 = +0.5 -> same 0.2 floor.
	var rig2 := _make_rig({5: 2.0})
	rig2["congestion"].set_congestion(5, 0.0)
	rig2["sat"].call("on_member_entered", 1)
	rig2["sat"].call("on_use_started", 1, 5)
	rig2["sat"].call("on_use_completed", 1)
	for i in range(10):
		rig2["sat"].call("on_walk_fail", 1)
	for i in range(10):
		rig2["sat"].call("on_interrupt", 1)
	rig2["sat"].call("add_queue_ticks", 1, 100000)
	var s_event: float = float(rig2["sat"].call("on_member_departed", 1))
	_check_float(s_event, 0.2, "guardrail event: perfect use + max noise -> departed S_member 0.2, never zeroed")


# === on_tick integration: roster-diff wiring feeds the counters ===

func _test_on_tick_penalty_wiring() -> void:
	print("\n[on_tick] LEAVING with failure reason -> n_fail; mid-use interrupt (pending, no exercise) -> n_interrupt; departure folds caps")
	var ms := FakeMemberSim.new()
	var rig := _make_rig({}, ms)
	var sat: RefCounted = rig["sat"]

	# Tick 1: member 10 enters then walk-fails (LEAVING, no_candidates);
	# member 11 starts USING instance 5 (pending use snapshot).
	ms.members = [
		{"member_id": 10, "state": "LEAVING", "exercises_done": 0, "target_equipment_instance_id": -1, "leaving_reason": "no_candidates"},
		{"member_id": 11, "state": "USING", "exercises_done": 0, "target_equipment_instance_id": 5},
	]
	sat.call("on_tick", 1)
	var acc10: Dictionary = sat.call("get_accumulator", 10)
	var acc11: Dictionary = sat.call("get_accumulator", 11)
	_check(int(acc10["n_fail"]) == 1, "on_tick: LEAVING no_candidates -> n_fail == 1 (got %d)" % int(acc10["n_fail"]))
	_check(not sat.call("get_pending_use", 11).is_empty(), "on_tick: member 11 USING -> pending use recorded")

	# Tick 2: member 10 still LEAVING no_candidates — the 2nd LEAVING tick
	# must NOT re-count the same departure (SAT-001F: one walk-fail per
	# departure, not per LEAVING tick); member 11 leaves USING without
	# completing an exercise (quota_met LEAVING, NOT a failure) -> mid-use
	# interrupt, pending erased.
	ms.members = [
		{"member_id": 10, "state": "LEAVING", "exercises_done": 0, "target_equipment_instance_id": -1, "leaving_reason": "no_candidates"},
		{"member_id": 11, "state": "LEAVING", "exercises_done": 0, "target_equipment_instance_id": -1, "leaving_reason": "quota_met"},
	]
	sat.call("on_tick", 2)
	acc10 = sat.call("get_accumulator", 10)
	acc11 = sat.call("get_accumulator", 11)
	_check(int(acc10["n_fail"]) == 1, "on_tick: 2nd LEAVING no_candidates tick does NOT re-count (n_fail stays 1, got %d)" % int(acc10["n_fail"]))
	_check(int(acc11["n_interrupt"]) == 1, "on_tick: left USING without exercise -> n_interrupt == 1 (got %d)" % int(acc11["n_interrupt"]))
	_check(sat.call("get_pending_use", 11).is_empty(), "on_tick: pending use erased on interrupt")
	_check(int(acc11["n_fail"]) == 0, "on_tick: quota_met LEAVING is NOT a walk-failure (n_fail stays 0)")

	# Tick 3: member 11 departs (roster gone) -> folded + discarded. With
	# n_interrupt=1 the fold carries S_member 0.5-0.20 == 0.3.
	ms.members = [
		{"member_id": 10, "state": "LEAVING", "exercises_done": 0, "target_equipment_instance_id": -1, "leaving_reason": "no_candidates"},
	]
	sat.call("on_tick", 3)
	_check(sat.call("get_accumulator", 11).is_empty(), "on_tick: member 11 accumulator discarded on departure")

	# Tick 4: member 10 departs (n_fail=1 -> fail_penalty 0.15, NOT the 0.30
	# cap — one departure counted once, SAT-001F) -> S_member 0.5-0.15 ==
	# 0.35; accumulator discarded; global stays within [0,1] after both folds.
	ms.members = []
	sat.call("on_tick", 4)
	_check(sat.call("get_accumulator", 10).is_empty(), "on_tick: member 10 accumulator discarded on departure")
	var g: float = float(sat.get("global_satisfaction"))
	_check(g >= 0.0 and g <= 1.0, "on_tick: global_satisfaction within [0,1] after penalty folds (got %s)" % str(g))


# === SAT-001F: walk-fail counts ONCE per departure, not per LEAVING tick ===

## Regression for the QA blocking defect (qa_repro_walkfail_overcount.gd):
## MemberSim keeps a member in LEAVING for the whole exit walk (one cell per
## tick), so a per-tick check counted ONE walk-failure departure N times.
## on_walk_fail must fire once per ENTRY into LEAVING with a failure reason.
func _test_walk_fail_counts_per_departure() -> void:
	print("\n[SAT-001F] on_walk_fail fires once per ENTRY into LEAVING (failure reason) — never per LEAVING tick")
	var ms := FakeMemberSim.new()
	var rig := _make_rig({}, ms)
	var sat: RefCounted = rig["sat"]

	# Scenario 1 (the QA repro): one departure, 3 consecutive LEAVING ticks.
	# n_fail must stay exactly 1 — the departure was counted at entry.
	ms.members = [
		{"member_id": 20, "state": "ENTERING", "exercises_done": 0, "target_equipment_instance_id": -1},
	]
	sat.call("on_tick", 1)
	ms.members = [
		{"member_id": 20, "state": "LEAVING", "leaving_reason": "no_candidates", "exercises_done": 0, "target_equipment_instance_id": -1},
	]
	sat.call("on_tick", 2)
	var acc: Dictionary = sat.call("get_accumulator", 20)
	_check(int(acc["n_fail"]) == 1, "SAT-001F: 1st LEAVING no_candidates tick -> n_fail == 1 (got %d)" % int(acc["n_fail"]))
	sat.call("on_tick", 3)
	acc = sat.call("get_accumulator", 20)
	_check(int(acc["n_fail"]) == 1, "SAT-001F: 2nd consecutive LEAVING tick -> n_fail stays 1 (got %d)" % int(acc["n_fail"]))
	sat.call("on_tick", 4)
	acc = sat.call("get_accumulator", 20)
	_check(int(acc["n_fail"]) == 1, "SAT-001F: 3rd consecutive LEAVING tick -> n_fail stays 1 (got %d)" % int(acc["n_fail"]))

	# Scenario 2: the same member departs (GONE), re-enters, and walk-fails
	# again (path_blocked). Each departure counts once in its own visit's
	# accumulator (fresh accumulator starts at 0).
	ms.members = []
	sat.call("on_tick", 5)  # member 20 GONE -> departure fold + discard
	_check(sat.call("get_accumulator", 20).is_empty(), "SAT-001F: member 20 accumulator folded + discarded on departure")
	ms.members = [
		{"member_id": 20, "state": "SELECTING_TARGET", "exercises_done": 0, "target_equipment_instance_id": -1},
	]
	sat.call("on_tick", 6)  # re-enters for visit 2
	ms.members = [
		{"member_id": 20, "state": "LEAVING", "leaving_reason": "path_blocked", "exercises_done": 0, "target_equipment_instance_id": -1},
	]
	sat.call("on_tick", 7)
	acc = sat.call("get_accumulator", 20)
	_check(int(acc["n_fail"]) == 1, "SAT-001F: 2nd departure (path_blocked, fresh visit) -> n_fail == 1 in the NEW accumulator (got %d)" % int(acc["n_fail"]))
	sat.call("on_tick", 8)
	acc = sat.call("get_accumulator", 20)
	_check(int(acc["n_fail"]) == 1, "SAT-001F: 2nd LEAVING tick of the 2nd departure -> n_fail stays 1 (got %d)" % int(acc["n_fail"]))

	# Scenario 3: first-sight already LEAVING (spawned straight into a
	# walk-fail departure) still counts exactly once, then stays put.
	var ms3 := FakeMemberSim.new()
	var rig3 := _make_rig({}, ms3)
	var sat3: RefCounted = rig3["sat"]
	ms3.members = [
		{"member_id": 30, "state": "LEAVING", "leaving_reason": "no_candidates", "exercises_done": 0, "target_equipment_instance_id": -1},
	]
	sat3.call("on_tick", 1)
	ms3.members = [
		{"member_id": 30, "state": "LEAVING", "leaving_reason": "no_candidates", "exercises_done": 0, "target_equipment_instance_id": -1},
	]
	sat3.call("on_tick", 2)
	acc = sat3.call("get_accumulator", 30)
	_check(int(acc["n_fail"]) == 1, "SAT-001F: first-sight LEAVING no_candidates counts once (n_fail 1, got %d)" % int(acc["n_fail"]))

	# Scenario 4 (defensive pin of the edge-detect): LEAVING -> non-LEAVING
	# -> LEAVING counts per ENTRY, so a second entry counts a second time
	# (MemberSim cannot actually exit LEAVING except via GONE, but the
	# per-departure semantic is 'per entry into LEAVING').
	var ms4 := FakeMemberSim.new()
	var rig4 := _make_rig({}, ms4)
	var sat4: RefCounted = rig4["sat"]
	ms4.members = [
		{"member_id": 40, "state": "LEAVING", "leaving_reason": "no_candidates", "exercises_done": 0, "target_equipment_instance_id": -1},
	]
	sat4.call("on_tick", 1)
	ms4.members = [
		{"member_id": 40, "state": "QUEUEING", "exercises_done": 0, "target_equipment_instance_id": -1},
	]
	sat4.call("on_tick", 2)
	ms4.members = [
		{"member_id": 40, "state": "LEAVING", "leaving_reason": "path_blocked", "exercises_done": 0, "target_equipment_instance_id": -1},
	]
	sat4.call("on_tick", 3)
	acc = sat4.call("get_accumulator", 40)
	_check(int(acc["n_fail"]) == 2, "SAT-001F: re-entry into LEAVING (after non-LEAVING) counts a 2nd time (n_fail 2, got %d)" % int(acc["n_fail"]))
