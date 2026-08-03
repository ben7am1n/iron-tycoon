# tests/unit/satisfaction/global_satisfaction_modifiers_test.gd
# Story SAT-003: global_satisfaction and Modifiers
# (production/epics/satisfaction/story-003-global-satisfaction-modifiers.md)
#
# Covers the BLOCKING ACs (TR-SAT-005/006/007, per the story QA test cases):
#   - AC2  modifier bounds + anti-spiral floor: any G in [0,1] ->
#         satisfaction_modifier in [0.5, 2.0]; at G=0 strictly 0.5 (never 0).
#         Edges: G=0, 0.5, 1.0, just below/above 0.5.
#   - AC3  neutral continuity: G=0.5 -> exactly 1.0 (seamless with
#         MemberSim's placeholder). Edge: G=0.4999 vs 0.5 vs 0.5001 — no
#         jump at the piecewise boundary.
#   - AC4  visit-length damping: visit_length_modifier in [0.75, 1.5] and
#         deviation from 1.0 exactly half of satisfaction_modifier's.
#         Edges: G=0 -> 0.75; G=1 -> 1.5; G=0.5 -> 1.0.
#   - AC7  monotonicity — modifier: G1 < G2 -> sm(G1) <= sm(G2)
#         (non-decreasing). Edge: G1=0.49, G2=0.51 across the boundary.
#   - AC13 deterministic multi-departure: members departing on one tick
#         fold in ascending member_id order (reproducible). Edge: ids
#         non-contiguous; same-tick departures with different S_member.
#   - AC14 no silent drift: a tick with no departures leaves
#         global_satisfaction bit-for-bit unchanged. Edge: many
#         consecutive no-departure ticks.
#   - AC16 defensive modifier clamp: G outside [0,1] (upstream bug) is
#         clamped before the piecewise formula; anti-spiral guarantee
#         (modifier >= 0.5) holds. Edge: G=-1, G=2.5, G=NaN (no crash).
#
# The modifier functions are pure (Core Rule 6); the EMA fold is exercised
# through the public event API (on_member_departed) AND through the on_tick
# roster-diff path (ADR-0005 §3 direct reads) so the ascending departure
# sort is the code under test, not a hand-rolled loop.
#
# Float policy: exact == only where the arithmetic is provably exact in
# IEEE double (0.5, 1.0, 2.0, 0.75, 1.5 — all products/sums of powers of
# two); everything else uses the codebase's standard absf() < 1e-9
# tolerance (tick_accumulator_test precedent). The ACs themselves are
# range/order contracts — the bounds, not exact decimals, are the contract.
#
# Run standalone: godot --headless --script tests/unit/satisfaction/global_satisfaction_modifiers_test.gd
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
	print("  UNIT TEST: Satisfaction — global_satisfaction & Modifiers (Story SAT-003)")
	print("=".repeat(48))

	_test_ac2_modifier_bounds()
	_test_ac3_neutral_continuity()
	_test_ac4_visit_length_damping()
	_test_ac7_modifier_monotonic()
	_test_ac13_deterministic_multi_departure()
	_test_ac14_no_silent_drift()
	_test_ac16_defensive_clamp()
	_test_damp_config_override()

	print("\n=== GLOBAL SATISFACTION MODIFIERS TEST: %d passed, %d failed ===\n" % [_pass, _fail])
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
##   [config]        optional init config dict (damp / alpha_g overrides)
## Returns the rig with "sat" + injected doubles for driving.
func _make_rig(zone_totals: Dictionary = {}, member_sim: FakeMemberSim = null, config: Dictionary = {}) -> Dictionary:
	var orch: Node = _make_orchestrator()
	var srg: RefCounted = _SRG().new()
	srg.call("init", 0x5EEDCAFE12345678)

	var cong := FakeCongestion.new()
	var zone_reader := func(instance_id: int) -> float:
		return float(zone_totals.get(instance_id, 0.0))

	var sat: RefCounted = _ST().new()
	sat.call("init", orch, srg, member_sim, cong, zone_reader, config)

	return {"sat": sat, "congestion": cong, "member_sim": member_sim}


# === AC2: modifier bounds + anti-spiral floor ===

func _test_ac2_modifier_bounds() -> void:
	print("\n[AC2] any G in [0,1] -> satisfaction_modifier in [0.5, 2.0]; G=0 strictly 0.5 (never 0)")
	var rig := _make_rig()
	var sat: RefCounted = rig["sat"]

	# Sweep across the whole domain — never leaves [0.5, 2.0].
	var in_bounds := true
	for i in range(0, 101):
		var g := float(i) / 100.0
		var m: float = float(sat.call("satisfaction_modifier", g))
		if m < 0.5 or m > 2.0:
			in_bounds = false
			break
	_check(in_bounds, "AC2: satisfaction_modifier in [0.5, 2.0] across G sweep 0..1 (step 0.01)")

	# QA edges: G=0, 0.5, 1.0, just below/above 0.5.
	var m0: float = float(sat.call("satisfaction_modifier", 0.0))
	_check(m0 == 0.5, "AC2 edge: G=0 -> strictly 0.5 (got %s)" % str(m0))
	_check(m0 != 0.0, "AC2 edge: G=0 modifier is NEVER 0 (anti-death-spiral floor)")

	var m1: float = float(sat.call("satisfaction_modifier", 1.0))
	_check(m1 == 2.0, "AC2 edge: G=1 -> 2.0 (got %s)" % str(m1))

	var m_below: float = float(sat.call("satisfaction_modifier", 0.49))
	var m_above: float = float(sat.call("satisfaction_modifier", 0.51))
	_check_float(m_below, 0.99, "AC2 edge: G=0.49 (< 0.5) -> 0.49 + 0.5 == 0.99")
	_check_float(m_above, 1.02, "AC2 edge: G=0.51 (>= 0.5) -> 2*0.51 == 1.02")
	_check(m_below >= 0.5 and m_above <= 2.0, "AC2 edge: just-below/above values stay in [0.5, 2.0]")


# === AC3: neutral continuity ===

func _test_ac3_neutral_continuity() -> void:
	print("\n[AC3] G=0.5 -> exactly 1.0; no jump at the piecewise boundary (0.4999/0.5/0.5001)")
	var rig := _make_rig()
	var sat: RefCounted = rig["sat"]

	var m05: float = float(sat.call("satisfaction_modifier", 0.5))
	_check(m05 == 1.0, "AC3: G=0.5 -> exactly 1.0 (got %s)" % str(m05))

	# No jump at the boundary: both branches converge to 1.0 at the seam.
	var m_low: float = float(sat.call("satisfaction_modifier", 0.4999))
	var m_high: float = float(sat.call("satisfaction_modifier", 0.5001))
	_check_float(m_low, 0.9999, "AC3 edge: G=0.4999 -> 0.4999 + 0.5 == 0.9999 (left branch)")
	_check_float(m_high, 1.0002, "AC3 edge: G=0.5001 -> 2*0.5001 == 1.0002 (right branch)")
	_check(m_low < m05 and m05 < m_high, "AC3 edge: strictly increasing across the seam (0.4999 < 0.5 < 0.5001) — no jump")
	_check(absf(m_low - m05) < 1e-3 and absf(m_high - m05) < 1e-3, "AC3 edge: boundary gap is tiny — continuous at 0.5")


# === AC4: visit-length damping ===

func _test_ac4_visit_length_damping() -> void:
	print("\n[AC4] visit_length_modifier in [0.75, 1.5]; deviation from 1.0 exactly half of satisfaction_modifier's")
	var rig := _make_rig()
	var sat: RefCounted = rig["sat"]

	# QA edges: G=0 -> 0.75; G=1 -> 1.5; G=0.5 -> 1.0 (all provably exact).
	var v0: float = float(sat.call("visit_length_modifier", 0.0))
	var v1: float = float(sat.call("visit_length_modifier", 1.0))
	var v05: float = float(sat.call("visit_length_modifier", 0.5))
	_check(v0 == 0.75, "AC4 edge: G=0 -> visit_length_modifier 0.75 (got %s)" % str(v0))
	_check(v1 == 1.5, "AC4 edge: G=1 -> visit_length_modifier 1.5 (got %s)" % str(v1))
	_check(v05 == 1.0, "AC4 edge: G=0.5 -> visit_length_modifier 1.0 (got %s)" % str(v05))

	# Range + half-deviation across the whole domain. The relation
	# vlm - 1.0 == (sm - 1.0) * 0.5 is mathematically exact, but the `1.0 + x`
	# addition rounds x's low bits (1-ULP), so tolerance, not bit-equality.
	var in_range := true
	var half_deviation := true
	for i in range(0, 101):
		var g := float(i) / 100.0
		var sm: float = float(sat.call("satisfaction_modifier", g))
		var vlm: float = float(sat.call("visit_length_modifier", g))
		if vlm < 0.75 or vlm > 1.5:
			in_range = false
		if absf(absf(vlm - 1.0) - 0.5 * absf(sm - 1.0)) > 1e-9:
			half_deviation = false
	_check(in_range, "AC4: visit_length_modifier in [0.75, 1.5] across G sweep 0..1")
	_check(half_deviation, "AC4: deviation from 1.0 is EXACTLY half of satisfaction_modifier's across the sweep")


# === AC7: modifier monotonicity ===

func _test_ac7_modifier_monotonic() -> void:
	print("\n[AC7] G1 < G2 -> satisfaction_modifier(G1) <= satisfaction_modifier(G2) (non-decreasing)")
	var rig := _make_rig()
	var sat: RefCounted = rig["sat"]

	# QA edge: across the piecewise boundary.
	var m_low: float = float(sat.call("satisfaction_modifier", 0.49))
	var m_high: float = float(sat.call("satisfaction_modifier", 0.51))
	_check(m_low <= m_high, "AC7 edge: 0.49 vs 0.51 across the boundary -> non-decreasing (%.6f <= %.6f)" % [m_low, m_high])

	# Dense sweep: non-decreasing everywhere.
	var prev: float = -INF
	var monotonic := true
	for i in range(0, 1001):
		var g := float(i) / 1000.0
		var m: float = float(sat.call("satisfaction_modifier", g))
		if m < prev - 1e-12:
			monotonic = false
			break
		prev = m
	_check(monotonic, "AC7: satisfaction_modifier non-decreasing across G sweep 0..1 (step 0.001)")


# === AC13: deterministic multi-departure fold (ascending member_id) ===

func _test_ac13_deterministic_multi_departure() -> void:
	print("\n[AC13] multiple same-tick departures fold in ascending member_id order (reproducible)")
	# Members with NON-CONTIGUOUS ids (3, 7, 12) and DISTINCT S_member:
	#   member 3  — blank visit                    -> S_member = 0.5
	#   member 7  — 1 walk-fail                    -> S_member = 0.35
	#   member 12 — 100 queue ticks (penalty 0.3)  -> S_member = 0.2
	var seeds := func(ms: FakeMemberSim) -> void:
		# Establish the tracked set via one roster pass (populates _last_seen).
		ms.members = [
			{"member_id": 3, "state": "SELECTING_TARGET", "exercises_done": 0, "target_equipment_instance_id": -1},
			{"member_id": 7, "state": "SELECTING_TARGET", "exercises_done": 0, "target_equipment_instance_id": -1},
			{"member_id": 12, "state": "SELECTING_TARGET", "exercises_done": 0, "target_equipment_instance_id": -1},
		]

	# Rig A — the on_tick roster-diff path is the code under test: tick 1
	# tracks the members, tick 2 (empty roster) departs ALL of them in one
	# tick. The fold order is decided by on_tick's departed.sort().
	var ms_a := FakeMemberSim.new()
	var rig_a := _make_rig({}, ms_a)
	var sat_a: RefCounted = rig_a["sat"]
	seeds.call(ms_a)
	sat_a.call("on_tick", 1)
	# Give each member a distinct accumulator through the public event API
	# (same surface MemberSim events would drive).
	sat_a.call("on_member_entered", 3)
	sat_a.call("on_member_entered", 7)
	sat_a.call("on_member_entered", 12)
	sat_a.call("on_walk_fail", 7)
	sat_a.call("add_queue_ticks", 12, 100)
	ms_a.members = []
	sat_a.call("on_tick", 2)  # all three depart on this tick
	var global_a: float = float(sat_a.get("global_satisfaction"))

	# Rig B — the same members folded EXPLICITLY in ascending member_id
	# order (3, 7, 12) via the event API. Bit-identical result proves on_tick
	# chose the ascending order.
	var ms_b := FakeMemberSim.new()
	var rig_b := _make_rig({}, ms_b)
	var sat_b: RefCounted = rig_b["sat"]
	sat_b.call("on_member_entered", 3)
	sat_b.call("on_member_entered", 7)
	sat_b.call("on_member_entered", 12)
	sat_b.call("on_walk_fail", 7)
	sat_b.call("add_queue_ticks", 12, 100)
	sat_b.call("on_member_departed", 3)
	sat_b.call("on_member_departed", 7)
	sat_b.call("on_member_departed", 12)
	var global_asc: float = float(sat_b.get("global_satisfaction"))

	_check(global_a == global_asc, "AC13: on_tick multi-departure fold is BIT-IDENTICAL to explicit ascending order (%s == %s)" % [str(global_a), str(global_asc)])

	# Rig C — descending order produces a DIFFERENT global, proving the fold
	# order is not commutative (the ascending assertion is non-vacuous).
	var rig_c := _make_rig()
	var sat_c: RefCounted = rig_c["sat"]
	sat_c.call("on_member_entered", 3)
	sat_c.call("on_member_entered", 7)
	sat_c.call("on_member_entered", 12)
	sat_c.call("on_walk_fail", 7)
	sat_c.call("add_queue_ticks", 12, 100)
	sat_c.call("on_member_departed", 12)
	sat_c.call("on_member_departed", 7)
	sat_c.call("on_member_departed", 3)
	var global_desc: float = float(sat_c.get("global_satisfaction"))
	_check(global_asc != global_desc, "AC13: descending fold differs (order matters — ascending is the contract, %s != %s)" % [str(global_asc), str(global_desc)])

	# Repro: re-run the on_tick path in a fresh rig — bit-identical.
	var ms_d := FakeMemberSim.new()
	var rig_d := _make_rig({}, ms_d)
	var sat_d: RefCounted = rig_d["sat"]
	seeds.call(ms_d)
	sat_d.call("on_tick", 1)
	sat_d.call("on_member_entered", 3)
	sat_d.call("on_member_entered", 7)
	sat_d.call("on_member_entered", 12)
	sat_d.call("on_walk_fail", 7)
	sat_d.call("add_queue_ticks", 12, 100)
	ms_d.members = []
	sat_d.call("on_tick", 2)
	var global_repro: float = float(sat_d.get("global_satisfaction"))
	_check(global_a == global_repro, "AC13: same sequence in a fresh rig is BIT-IDENTICAL (reproducible)")


# === AC14: no silent drift ===

func _test_ac14_no_silent_drift() -> void:
	print("\n[AC14] ticks with no departures leave global_satisfaction bit-for-bit unchanged")
	var ms := FakeMemberSim.new()
	var rig := _make_rig({}, ms)
	var sat: RefCounted = rig["sat"]

	# Move global off the init 0.5 with one departure so the test is not
	# vacuous (a stuck-at-init value would also be "unchanged"). The member
	# was only ever touched via the event API — on_tick never saw it, so
	# _last_seen is empty: an empty roster afterwards is a TRUE
	# no-departure tick (nothing tracked to vanish).
	sat.call("on_member_entered", 1)
	sat.call("add_queue_ticks", 1, 100)
	sat.call("on_member_departed", 1)
	var g_after_fold: float = float(sat.get("global_satisfaction"))
	_check(g_after_fold != 0.5, "AC14: fold moved global off init (got %s — test not vacuous)" % str(g_after_fold))

	# 50 consecutive EMPTY-roster ticks: nothing is tracked, nothing departs,
	# global must not move a single bit.
	var before: float = g_after_fold
	for t in range(1, 51):
		ms.members = []
		sat.call("on_tick", t)
	_check(float(sat.get("global_satisfaction")) == before, "AC14: 50 empty-roster ticks (nothing tracked) -> bit-for-bit unchanged")

	# 50 ticks with members present but NO departures: the roster stays
	# identical every tick, no member vanishes, global must not move.
	for t in range(51, 101):
		ms.members = [
			{"member_id": 2, "state": "SELECTING_TARGET", "exercises_done": 0, "target_equipment_instance_id": -1},
			{"member_id": 3, "state": "SELECTING_TARGET", "exercises_done": 0, "target_equipment_instance_id": -1},
		]
		sat.call("on_tick", t)
	_check(float(sat.get("global_satisfaction")) == before, "AC14: 50 no-departure ticks (members present, roster identical) -> bit-for-bit unchanged")


# === AC16: defensive modifier clamp ===

func _test_ac16_defensive_clamp() -> void:
	print("\n[AC16] G outside [0,1] (upstream bug) is clamped before the piecewise; modifier >= 0.5 always")
	var rig := _make_rig()
	var sat: RefCounted = rig["sat"]

	# G=-1 -> clamped to 0 -> 0.5 (the anti-spiral floor).
	var m_neg: float = float(sat.call("satisfaction_modifier", -1.0))
	_check(m_neg == 0.5, "AC16: G=-1 -> clamped to 0 -> strictly 0.5 (got %s)" % str(m_neg))

	# G=2.5 -> clamped to 1 -> 2.0.
	var m_over: float = float(sat.call("satisfaction_modifier", 2.5))
	_check(m_over == 2.0, "AC16: G=2.5 -> clamped to 1 -> 2.0 (got %s)" % str(m_over))

	# G=NaN must NOT crash; falls back to neutral anchor 0.5 -> modifier 1.0
	# (>= 0.5 guaranteed).
	var m_nan: float = float(sat.call("satisfaction_modifier", NAN))
	_check(not is_nan(m_nan), "AC16: G=NaN -> no NaN leak (got %s)" % str(m_nan))
	_check(m_nan == 1.0, "AC16: G=NaN -> neutral anchor 0.5 -> modifier 1.0 (got %s)" % str(m_nan))
	_check(m_nan >= 0.5, "AC16: G=NaN -> anti-spiral guarantee modifier >= 0.5 holds")

	# ±Inf are non-finite too — same neutral fallback, no crash.
	var m_pinf: float = float(sat.call("satisfaction_modifier", INF))
	var m_ninf: float = float(sat.call("satisfaction_modifier", -INF))
	_check(m_pinf == 1.0 and m_ninf == 1.0, "AC16: G=±Inf -> neutral 1.0, no crash (got %s, %s)" % [str(m_pinf), str(m_ninf)])

	# The visit leg inherits the defensive clamp through satisfaction_modifier.
	var v_neg: float = float(sat.call("visit_length_modifier", -1.0))
	var v_over: float = float(sat.call("visit_length_modifier", 2.5))
	var v_nan: float = float(sat.call("visit_length_modifier", NAN))
	_check(v_neg == 0.75, "AC16: visit_length_modifier(G=-1) -> 0.75 (got %s)" % str(v_neg))
	_check(v_over == 1.5, "AC16: visit_length_modifier(G=2.5) -> 1.5 (got %s)" % str(v_over))
	_check(v_nan == 1.0 and not is_nan(v_nan), "AC16: visit_length_modifier(G=NaN) -> 1.0, no crash (got %s)" % str(v_nan))


# === damp config override (TR-SAT-007 tuning knob wiring) ===

func _test_damp_config_override() -> void:
	print("\n[damp] config override re-damps the visit leg (GDD tuning knob range 0.3-0.7)")
	var rig := _make_rig({}, null, {"damp": 0.3})
	var sat: RefCounted = rig["sat"]

	# damp=0.3: deviation is 30% of satisfaction_modifier's, not 50%.
	var v0: float = float(sat.call("visit_length_modifier", 0.0))
	var v1: float = float(sat.call("visit_length_modifier", 1.0))
	_check_float(v0, 1.0 + (0.5 - 1.0) * 0.3, "damp=0.3: G=0 -> 1 - 0.15 == 0.85")
	_check_float(v1, 1.0 + (2.0 - 1.0) * 0.3, "damp=0.3: G=1 -> 1 + 0.3 == 1.3")
	_check(float(sat.call("satisfaction_modifier", 0.5)) == 1.0, "damp override does NOT touch satisfaction_modifier (G=0.5 still exactly 1.0)")
