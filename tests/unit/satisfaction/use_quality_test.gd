# tests/unit/satisfaction/use_quality_test.gd
# Story SAT-001: Member Accumulators and use_quality
# (production/epics/satisfaction/story-001-member-accumulators-use-quality.md)
#
# Covers the BLOCKING ACs (TR-SAT-001/002/003, per the story QA test cases):
#   - AC5  congestion monotonicity: Congestion_i(t-1) increases -> using
#         member's S_member strictly decreases. Edge: sweep 0 -> 1; the
#         congestion SNAPSHOT is taken at use-start (read t-1 rule), not
#         re-read at completion ("use at start vs mid-visit").
#   - AC6  synergy monotonicity: zone_synergy_i (hence total_i) increases
#         -> S_member strictly increases. Edge: sweep 0 -> Z_NORM cap;
#         comfort/spaciousness contributions fold into total_i.
#   - AC8  bounds: use_quality_i in [-0.5, 0.5], S_member in [0,1],
#         global_satisfaction in [0,1] for ANY inputs (worst: total=0,
#         congestion=1; best: total at cap, congestion=0).
#   - AC9  symmetric use signal: perfect use (+0.5) and worst use (-0.5)
#         are equal and opposite (w_zone = w_cong = 0.5). Edge: mid values
#         symmetric around 0.
#   - AC10 zero-use member baseline: n_uses=0 + all counters zero ->
#         avg(use_quality)=0, no NaN/exception, S_member == S_base == 0.5.
#         Edge: n_uses=0 with nonzero penalties (S_member = S_base -
#         penalties, clamped >= 0).
#
# The QA cases exercise the public event API (on_member_entered /
# on_use_started / on_use_completed / on_member_departed) with an injected
# congestion reader + zone-total reader, so each input is controllable
# independently — exactly the "all else fixed" the monotonicity ACs demand.
# A final on_tick integration case drives the real roster-diff wiring to
# prove the system consumes MemberSim events directly (ADR-0005 §3).
#
# Run standalone: godot --headless --script tests/unit/satisfaction/use_quality_test.gd
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
	print("  UNIT TEST: Satisfaction — Member Accumulators & use_quality (Story SAT-001)")
	print("=".repeat(48))

	_test_ac9_symmetric_use_signal()
	_test_ac8_bounds()
	_test_ac5_congestion_monotonic()
	_test_ac6_synergy_monotonic()
	_test_ac10_zero_use_baseline()
	_test_on_tick_integration()

	print("\n=== USE_QUALITY TEST: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


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
##   [congestion]    FakeCongestion (values dict settable per test)
##   [member_sim]    FakeMemberSim or null (null -> event API only, no on_tick)
## Returns the rig with "sat" + injected doubles for driving.
func _make_rig(zone_totals: Dictionary = {}, congestion: FakeCongestion = null, member_sim: FakeMemberSim = null) -> Dictionary:
	var orch: Node = _make_orchestrator()
	var srg: RefCounted = _SRG().new()
	srg.call("init", 0x5EEDCAFE12345678)

	var cong: FakeCongestion = congestion if congestion != null else FakeCongestion.new()
	var zone_reader := func(instance_id: int) -> float:
		return float(zone_totals.get(instance_id, 0.0))

	var sat: RefCounted = _ST().new()
	sat.call("init", orch, srg, member_sim, cong, zone_reader)

	return {"sat": sat, "congestion": cong, "member_sim": member_sim}


## One complete use cycle via the public event API: member entered, use
## STARTED on [instance_id] (congestion snapshotted NOW), use COMPLETED.
## Returns the rig so the caller can read the accumulator / depart.
func _do_use(rig: Dictionary, member_id: int, instance_id: int) -> void:
	rig["sat"].call("on_member_entered", member_id)
	rig["sat"].call("on_use_started", member_id, instance_id)
	rig["sat"].call("on_use_completed", member_id)


## S_member of a tracked member WITHOUT folding/discarding (reads the live
## accumulator through the public compute_s_member surface).
func _s_member_of(rig: Dictionary, member_id: int) -> float:
	var acc: Dictionary = rig["sat"].call("get_accumulator", member_id)
	return float(rig["sat"].call("compute_s_member", acc))


# === AC9: symmetric use signal ===

func _test_ac9_symmetric_use_signal() -> void:
	print("\n[AC9] perfect use (total at cap, congestion=0) -> +0.5; worst use (total=0, congestion=1) -> -0.5; equal and opposite")
	var rig := _make_rig({5: 2.0})
	var cong: FakeCongestion = rig["congestion"]

	# Perfect use: total_i at cap (>= Z_NORM=2.0), congestion 0.
	cong.set_congestion(5, 0.0)
	_do_use(rig, 1, 5)
	var uq_perfect: float = float(rig["sat"].get_accumulator(1)["S_acc"])
	_check(uq_perfect == 0.5, "AC9: perfect use -> use_quality == +0.5 (got %s)" % str(uq_perfect))

	# Worst use: total_i=0 (instance 99 has no zone total), congestion 1.
	cong.set_congestion(99, 1.0)
	_do_use(rig, 3, 99)  # instance 99 has no zone total -> 0.0
	var uq_worst: float = float(rig["sat"].get_accumulator(3)["S_acc"])
	_check(uq_worst == -0.5, "AC9: worst use -> use_quality == -0.5 (got %s)" % str(uq_worst))

	# Equal and opposite (neither pull nor push dominates).
	_check(uq_perfect == -uq_worst, "AC9: perfect and worst are equal and opposite (+%s vs %s)" % [str(uq_perfect), str(uq_worst)])

	# Mid values — symmetric around 0: total=1.0, congestion=0.5 -> z=0.5 ->
	# 0.5*0.5 - 0.5*0.5 = 0.0. And the mirror around 0: total=1.5, cong=0.25
	# -> 0.5*0.75-0.5*0.25=0.25; total=0.5, cong=0.75 -> 0.5*0.25-0.5*0.75=-0.25.
	rig["sat"].call("on_member_entered", 4)
	rig["sat"].call("on_use_started", 4, 5)
	cong.set_congestion(5, 0.5)
	var mid_uq: float = float(rig["sat"].call("compute_use_quality", 1.0, 0.5))
	_check(mid_uq == 0.0, "AC9: mid value (total=1.0, cong=0.5) -> 0.0 (symmetric around 0, got %s)" % str(mid_uq))

	var plus: float = float(rig["sat"].call("compute_use_quality", 1.5, 0.25))
	var minus: float = float(rig["sat"].call("compute_use_quality", 0.5, 0.75))
	_check(plus == 0.25 and minus == -0.25, "AC9: mirrored mid values are +0.25 and -0.25 (got %s, %s)" % [str(plus), str(minus)])

# === AC8: bounds / clamping ===

func _test_ac8_bounds() -> void:
	print("\n[AC8] any inputs -> use_quality in [-0.5,0.5], S_member in [0,1], global in [0,1]")
	var rig := _make_rig({1: 0.0, 2: 1.0, 3: 2.0, 4: 3.0, 5: 10.0})
	var cong: FakeCongestion = rig["congestion"]

	# Worst (total=0, congestion=1) and best (total at cap, congestion=0).
	_check(float(rig["sat"].call("compute_use_quality", 0.0, 1.0)) == -0.5, "AC8: worst -> -0.5")
	_check(float(rig["sat"].call("compute_use_quality", 3.0, 0.0)) == 0.5, "AC8: best -> +0.5")

	# Sweep extreme inputs — output always inside [-0.5, 0.5].
	var in_bounds := true
	var observed_min := 1.0
	var observed_max := -1.0
	for t in [0.0, 0.1, 0.5, 1.0, 1.5, 2.0, 3.0, 5.0, 10.0]:
		for c in [0.0, 0.1, 0.5, 0.9, 1.0, 2.0]:
			var uq: float = float(rig["sat"].call("compute_use_quality", t, c))
			observed_min = minf(observed_min, uq)
			observed_max = maxf(observed_max, uq)
			if uq < -0.5 or uq > 0.5:
				in_bounds = false
	_check(in_bounds, "AC8: use_quality in [-0.5,0.5] for all sweeps (obs range [%s, %s])" % [str(observed_min), str(observed_max)])

	# S_member in [0,1]: extreme accumulator — worst possible (avg -0.5 +
	# all penalties capped) and best (avg +0.5, zero penalties).
	var worst_acc := {
		"S_acc": -0.5, "n_uses": 1,
		"queue_ticks": 100000, "n_fail": 100, "n_interrupt": 100,
	}
	var best_acc := {
		"S_acc": 0.5, "n_uses": 1,
		"queue_ticks": 0, "n_fail": 0, "n_interrupt": 0,
	}
	var s_worst: float = float(rig["sat"].call("compute_s_member", worst_acc))
	var s_best: float = float(rig["sat"].call("compute_s_member", best_acc))
	_check(s_worst >= 0.0 and s_worst <= 1.0, "AC8: worst S_member in [0,1] (got %s)" % str(s_worst))
	_check(s_best >= 0.0 and s_best <= 1.0, "AC8: best S_member in [0,1] (got %s)" % str(s_best))

	# global_satisfaction stays in [0,1] after folds from extreme S_members.
	cong.set_congestion(1, 0.0)
	rig["sat"].call("on_member_entered", 50)
	rig["sat"].call("on_use_started", 50, 1)  # total 0, cong 0 -> uq 0
	rig["sat"].call("on_use_completed", 50)
	rig["sat"].call("on_member_departed", 50)
	var g1: float = float(rig["sat"].get("global_satisfaction"))
	_check(g1 >= 0.0 and g1 <= 1.0, "AC8: global after fold in [0,1] (got %s)" % str(g1))
	# Fold a near-0 S_member repeatedly — still never negative.
	for i in range(50):
		rig["sat"].call("on_member_entered", 100 + i)
		rig["sat"].call("on_use_started", 100 + i, 1)
		rig["sat"].call("on_use_completed", 100 + i)
		rig["sat"].call("on_member_departed", 100 + i)
	var g2: float = float(rig["sat"].get("global_satisfaction"))
	_check(g2 >= 0.0 and g2 <= 1.0, "AC8: global stays in [0,1] after 50 low folds (got %s)" % str(g2))


# === AC5: congestion monotonicity ===

func _test_ac5_congestion_monotonic() -> void:
	print("\n[AC5] congestion sweep 0 -> 1 (all else fixed) -> S_member strictly decreases")
	# Fixed total 1.0 for instance 7. Each member does ONE use at a congestion
	# level; S_member must strictly decrease as congestion rises.
	var totals := {7: 1.0}
	var prev_s: float = INF
	var strictly_decreasing := true
	for i in range(11):
		var c := float(i) / 10.0  # 0.0 .. 1.0
		var rig := _make_rig(totals)
		rig["congestion"].set_congestion(7, c)
		_do_use(rig, 1, 7)
		var s: float = _s_member_of(rig, 1)
		if s >= prev_s:
			strictly_decreasing = false
		prev_s = s
	_check(strictly_decreasing, "AC5: S_member strictly decreases across congestion 0->1 (last %s)" % str(prev_s))

	# Edge "use at start vs mid-visit": congestion is SNAPSHOTTED at use-start
	# and never re-read at completion. Start with congestion 0.1, raise it to
	# 0.9 mid-use, then complete — the completed use must use the START value.
	var rig := _make_rig(totals)
	rig["congestion"].set_congestion(7, 0.1)
	rig["sat"].call("on_member_entered", 21)
	rig["sat"].call("on_use_started", 21, 7)  # snapshot 0.1
	rig["congestion"].set_congestion(7, 0.9)  # congestion rises mid-use
	rig["sat"].call("on_use_completed", 21)
	var acc21: Dictionary = rig["sat"].call("get_accumulator", 21)
	var uq21: float = float(acc21["S_acc"])
	var expected_uq: float = 0.5 * 0.5 - 0.5 * 0.1  # total 1.0 -> z 0.5; cong 0.1
	_check(uq21 == expected_uq, "AC5: use_quality uses START snapshot 0.1 not mid-use 0.9 (got %s, exp %s)" % [str(uq21), str(expected_uq)])

	# Same scenario completed WITHOUT the mid-use rise for contrast.
	var rig2 := _make_rig(totals)
	rig2["congestion"].set_congestion(7, 0.1)
	rig2["sat"].call("on_member_entered", 22)
	rig2["sat"].call("on_use_started", 22, 7)
	rig2["sat"].call("on_use_completed", 22)
	var uq22: float = float(rig2["sat"].call("get_accumulator", 22)["S_acc"])
	_check(uq21 == uq22, "AC5: mid-use congestion change does NOT alter the use's quality (both %s)" % str(uq21))


# === AC6: synergy (total_i) monotonicity ===

func _test_ac6_synergy_monotonic() -> void:
	print("\n[AC6] total_i sweep 0 -> Z_NORM cap (all else fixed) -> S_member strictly increases")
	# Congestion fixed at 0. Each member does ONE use with a different total_i.
	var prev_s: float = -INF
	var strictly_increasing := true
	for i in range(11):
		var t := float(i) / 5.0  # 0.0 .. 2.0 (Z_NORM cap)
		var rig := _make_rig({8: t})
		rig["congestion"].set_congestion(8, 0.0)
		_do_use(rig, 1, 8)
		var s: float = _s_member_of(rig, 1)
		if s <= prev_s:
			strictly_increasing = false
		prev_s = s
	_check(strictly_increasing, "AC6: S_member strictly increases across total 0->2.0 (last %s)" % str(prev_s))

	# Edge "comfort/spaciousness contributions": total_i is the SUM; the use
	# quality depends on total_i regardless of which tag contributed. Two
	# instances with equal total but different composition score identically.
	var rig := _make_rig({8: 1.2, 9: 1.2})
	rig["congestion"].set_congestion(8, 0.0)
	rig["congestion"].set_congestion(9, 0.0)
	_do_use(rig, 1, 8)  # e.g. comfort-heavy
	_do_use(rig, 2, 9)  # e.g. spaciousness-heavy
	var uq8: float = float(rig["sat"].call("get_accumulator", 1)["S_acc"])
	var uq9: float = float(rig["sat"].call("get_accumulator", 2)["S_acc"])
	_check(uq8 == uq9, "AC6: equal total_i -> equal use_quality across compositions (both %s)" % str(uq8))


# === AC10: zero-use member baseline ===

func _test_ac10_zero_use_baseline() -> void:
	print("\n[AC10] n_uses=0 + zero counters -> avg=0, no NaN, S_member == S_base == 0.5")
	var rig := _make_rig({})
	var zero_acc := {
		"S_acc": 0.0, "n_uses": 0,
		"queue_ticks": 0, "n_fail": 0, "n_interrupt": 0,
	}
	var s: float = float(rig["sat"].call("compute_s_member", zero_acc))
	_check(s == 0.5, "AC10: zero-use accumulator -> S_member == S_base == 0.5 (got %s)" % str(s))
	_check(not is_nan(s) and not is_inf(s), "AC10: no NaN/Inf on zero-use S_member")

	# Through the event API: member enters and departs with NO uses at all.
	rig["sat"].call("on_member_entered", 1)
	var s_depart: float = float(rig["sat"].call("on_member_departed", 1))
	_check(s_depart == 0.5, "AC10: enter->depart with zero events -> S_member == 0.5 (got %s)" % str(s_depart))
	_check(rig["sat"].call("get_accumulator", 1).is_empty(), "AC10: accumulator discarded after departure")

	# Edge: n_uses=0 with NONZERO penalties -> S_member = S_base - penalties,
	# clamped >= 0. (queue cap 0.3 + fail cap 0.30 + interrupt cap 0.20 =
	# 0.80 > 0.5 -> clamps to 0; a single capped penalty stays positive.)
	var edge_acc := {
		"S_acc": 0.0, "n_uses": 0,
		"queue_ticks": 100000, "n_fail": 100, "n_interrupt": 100,
	}
	var s_edge: float = float(rig["sat"].call("compute_s_member", edge_acc))
	_check(s_edge == 0.0, "AC10: zero-use + max penalties -> clamped to 0 (got %s)" % str(s_edge))
	var fail_only := {
		"S_acc": 0.0, "n_uses": 0,
		"queue_ticks": 0, "n_fail": 3, "n_interrupt": 0,
	}
	var s_fail_only: float = float(rig["sat"].call("compute_s_member", fail_only))
	_check(s_fail_only == 0.2, "AC10: zero-use + fail penalty (cap 0.30) -> 0.5-0.30 == 0.2 (got %s)" % str(s_fail_only))


# === on_tick integration: roster-diff consumes MemberSim events (ADR-0005 §3) ===

func _test_on_tick_integration() -> void:
	print("\n[on_tick] roster-diff wiring: entered / use-start snapshot / use-complete / depart -> fold")
	var cong := FakeCongestion.new()
	cong.set_congestion(5, 0.2)
	var ms := FakeMemberSim.new()
	var rig := _make_rig({5: 1.0}, cong, ms)
	var sat: RefCounted = rig["sat"]

	# Tick 1: member 1 enters (state ENTERING), no use yet.
	ms.members = [{"member_id": 1, "state": "ENTERING", "exercises_done": 0, "target_equipment_instance_id": -1}]
	sat.call("on_tick", 1)
	_check(not sat.call("get_accumulator", 1).is_empty(), "on_tick: accumulator created on entry")

	# Tick 2: member walks and STARTS using instance 5 (USING) -> snapshot 0.2.
	ms.members = [{"member_id": 1, "state": "USING", "exercises_done": 0, "target_equipment_instance_id": 5}]
	sat.call("on_tick", 2)
	var pending: Dictionary = sat.call("get_pending_use", 1)
	_check(int(pending.get("instance_id", -1)) == 5, "on_tick: use-start recorded instance 5")
	_check(float(pending.get("congestion", -1.0)) == 0.2, "on_tick: congestion snapshotted at use-start (0.2)")

	# Tick 3: use completes (exercises_done 0 -> 1, back to SELECTING_TARGET).
	ms.members = [{"member_id": 1, "state": "SELECTING_TARGET", "exercises_done": 1, "target_equipment_instance_id": -1}]
	sat.call("on_tick", 3)
	var acc: Dictionary = sat.call("get_accumulator", 1)
	_check(int(acc["n_uses"]) == 1, "on_tick: use completed -> n_uses == 1")
	var expected_uq: float = 0.5 * 0.5 - 0.5 * 0.2  # total 1.0 -> z 0.5; cong 0.2
	_check(float(acc["S_acc"]) == expected_uq, "on_tick: S_acc == use_quality with start snapshot (got %s)" % str(acc["S_acc"]))

	# Tick 4: member departs (roster empty) -> folded into global, discarded.
	ms.members = []
	sat.call("on_tick", 4)
	_check(sat.call("get_accumulator", 1).is_empty(), "on_tick: accumulator discarded on departure")
	var g: float = float(sat.get("global_satisfaction"))
	_check(g >= 0.0 and g <= 1.0, "on_tick: global folded within [0,1] (got %s)" % str(g))

	# Queue ticks accumulate while QUEUEING.
	ms.members = [{"member_id": 2, "state": "QUEUEING", "exercises_done": 0, "target_equipment_instance_id": 5}]
	sat.call("on_tick", 5)
	ms.members = [{"member_id": 2, "state": "QUEUEING", "exercises_done": 0, "target_equipment_instance_id": 5}]
	sat.call("on_tick", 6)
	var acc2: Dictionary = sat.call("get_accumulator", 2)
	_check(int(acc2["queue_ticks"]) == 2, "on_tick: 2 QUEUEING ticks -> queue_ticks == 2 (got %d)" % int(acc2["queue_ticks"]))
