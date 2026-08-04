# tests/unit/satisfaction/determinism_serialization_test.gd
# Story SAT-004: Serialization, Determinism and Recovery Loop
# (production/epics/satisfaction/story-004-serialization-determinism-recovery-loop.md)
#
# Covers the BLOCKING ACs (TR-SAT-008/009, per the story QA test cases):
#   - AC1  determinism: a fixed event sequence (entered / use-completed with
#         a congestion snapshot / queue / departed) replayed twice -> every
#         S_member and global_satisfaction bit-identical. Edges: multiple
#         members, multi-departure ticks (roster-diff path), distinct
#         congestion snapshots per instance.
#   - AC15 serialization round-trip: mid-visit accumulators (n_uses > 0,
#         queue_ticks > 0, penalties) + a global_satisfaction value ->
#         serialize -> JSON.stringify(full_precision=true) -> parse ->
#         deserialize -> the next ticks bit-identical to uninterrupted play,
#         with use-completion/departure triggered AFTER reload to prove the
#         accumulator fields survive. Edges: reload exactly at a departure
#         boundary; JSON int->float + key-stringification coercion.
# Plus the deserialize validation contract (Phase A zero-mutation, corrupt
# payloads fail loudly — the story's "no invented defaults" rule).
#
# Serialized shape (Core Rule 8 / TR-SAT-009): global_satisfaction (float)
# + member_accumulators (per-member {S_acc, n_uses, queue_ticks, n_fail,
# n_interrupt}), with the stub-era {counter, rng_state} kept alongside for
# save-load byte-identity. The transient _pending_uses/_last_seen are
# re-derived from the loaded roster at commit (documented in the system).
#
# Determinism policy for AC15: the congestion reader returns FIXED t-1
# values per instance (the QA scenario's "with a congestion snapshot").
# A mid-use member's pending snapshot is re-taken at the load boundary
# (Core Rule 8: pending uses are transient); with stable congestion the
# re-taken snapshot equals the original, so bit-identity holds. The test
# documents this rather than papering over it.
#
# Float policy: exact == for ints and for values provably exact in IEEE
# double; the codebase 1e-9 tolerance for sums of non-power-of-two floats
# (S_acc, global EMA). Bit-identity comparisons between two runs use == on
# floats inside deep-compared Dictionaries (GDScript Dictionary == is deep,
# float == is IEEE bit-equality).
#
# Run standalone: godot --headless --script tests/unit/satisfaction/determinism_serialization_test.gd
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
	print("  UNIT TEST: Satisfaction — Determinism & Serialization (Story SAT-004)")
	print("=".repeat(48))

	_test_ac1_event_api_replay()
	_test_ac1_roster_diff_replay()
	_test_ac15_roundtrip_mid_visit()
	_test_ac15_roundtrip_departure_boundary()
	_test_walk_fail_no_recount_after_reload()
	_test_deserialize_validation()

	print("\n=== DETERMINISM & SERIALIZATION TEST: %d passed, %d failed ===\n" % [_pass, _fail])
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
## Values are FIXED once set: AC15's bit-identity contract needs the
## use-start snapshot re-taken at load to equal the original.
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
##   [config]        optional init config dict
##   [congestion]    optional pre-set FakeCongestion (else empty -> 0.0)
## Returns the rig with "sat" + injected doubles for driving.
func _make_rig(zone_totals: Dictionary = {}, member_sim: FakeMemberSim = null, config: Dictionary = {}, congestion: FakeCongestion = null) -> Dictionary:
	var orch: Node = _make_orchestrator()
	var srg: RefCounted = _SRG().new()
	srg.call("init", 0x5EEDCAFE12345678)

	var cong: FakeCongestion = congestion if congestion != null else FakeCongestion.new()
	var zone_reader := func(instance_id: int) -> float:
		return float(zone_totals.get(instance_id, 0.0))

	var sat: RefCounted = _ST().new()
	sat.call("init", orch, srg, member_sim, cong, zone_reader, config)

	return {"sat": sat, "congestion": cong, "member_sim": member_sim}


## Canonical observable snapshot of the system: the global meter + each
## tracked accumulator's projected S_member (sorted member_id — the same
## ascending order that on_tick processes). Used for trace comparison.
func _snapshot(sat: RefCounted) -> Dictionary:
	var acc_projection := {}
	var ids: Array = sat.get("member_accumulators").keys()
	ids.sort()
	for mid in ids:
		acc_projection[mid] = float(sat.call("compute_s_member", sat.get("member_accumulators")[mid]))
	return {
		"g": float(sat.get("global_satisfaction")),
		"acc": acc_projection,
	}


# === AC1: deterministic replay — event API ===

## The QA event sequence: entered / use-completed with a congestion
## snapshot / queue / departed, three members with DISTINCT outcomes:
##   m1 — one good use (cong 0.4, z 1.5) + 30 queue ticks
##   m2 — one bad use (cong 0.8, z 0.5) + 100 queue ticks + a walk-fail
##   m3 — blank visit with 10 queue ticks
const AC1_ZONE_TOTALS := {1: 0.5, 3: 1.5}
const AC1_CONGESTION := {1: 0.8, 3: 0.4}

func _build_ac1_events() -> Array:
	return [
		{"op": "entered", "id": 1},
		{"op": "use_started", "id": 1, "instance": 3},
		{"op": "use_completed", "id": 1},
		{"op": "queue", "id": 1, "ticks": 30},
		{"op": "departed", "id": 1},
		{"op": "entered", "id": 2},
		{"op": "use_started", "id": 2, "instance": 1},
		{"op": "use_completed", "id": 2},
		{"op": "queue", "id": 2, "ticks": 100},
		{"op": "walk_fail", "id": 2},
		{"op": "departed", "id": 2},
		{"op": "entered", "id": 3},
		{"op": "queue", "id": 3, "ticks": 10},
		{"op": "departed", "id": 3},
	]


func _apply_event(sat: RefCounted, ev: Dictionary, folded: Dictionary) -> void:
	match str(ev["op"]):
		"entered":
			sat.call("on_member_entered", int(ev["id"]))
		"use_started":
			sat.call("on_use_started", int(ev["id"]), int(ev["instance"]))
		"use_completed":
			sat.call("on_use_completed", int(ev["id"]))
		"queue":
			sat.call("add_queue_ticks", int(ev["id"]), int(ev["ticks"]))
		"walk_fail":
			sat.call("on_walk_fail", int(ev["id"]))
		"departed":
			folded[int(ev["id"])] = float(sat.call("on_member_departed", int(ev["id"])))


## Replays the fixed event list in a FRESH rig, capturing after every event:
## the global meter + live accumulator projections + the departure S_member
## values. Returns the trace (Array of Dictionaries — deep == is bit-exact).
func _replay_ac1_events(events: Array) -> Array:
	var cong := FakeCongestion.new()
	for k in AC1_CONGESTION:
		cong.set_congestion(int(k), float(AC1_CONGESTION[k]))
	var rig := _make_rig(AC1_ZONE_TOTALS, null, {}, cong)
	var sat: RefCounted = rig["sat"]
	var folded: Dictionary = {}
	var trace: Array = []
	for ev in events:
		_apply_event(sat, ev, folded)
		var snap := _snapshot(sat)
		snap["dep"] = folded.duplicate(true)
		trace.append(snap)
	return trace


func _test_ac1_event_api_replay() -> void:
	print("\n[AC1] fixed event sequence replayed twice via event API -> every S_member and global bit-identical")
	var events := _build_ac1_events()
	var trace_a := _replay_ac1_events(events)
	var trace_b := _replay_ac1_events(events)
	_check(trace_a == trace_b, "AC1: event-API replay traces bit-identical (%d snapshots)" % trace_a.size())

	# Non-vacuous: departures produced DISTINCT S_member values and moved
	# global off the init 0.5.
	var s1: float = float(trace_a[4]["dep"][1])
	var s2: float = float(trace_a[10]["dep"][2])
	var s3: float = float(trace_a[13]["dep"][3])
	_check(s1 != s2 and s2 != s3 and s1 != s3, "AC1: three departures folded DISTINCT S_member (%.6f / %.6f / %.6f) — replay is non-vacuous" % [s1, s2, s3])
	var g_final: float = float(trace_a[13]["g"])
	_check(g_final != 0.5, "AC1: global_satisfaction moved off init 0.5 (got %s) — fold path exercised" % str(g_final))
	_check(s2 == 0.0, "AC1 edge: worst visit (bad use + queue cap + walk-fail) clamps S_member to 0.0 (got %s)" % str(s2))
	_check_float(s1, 0.585, "AC1: m1 S_member = 0.5 + 0.175 - 0.09 == 0.585")
	_check_float(s3, 0.47, "AC1: m3 S_member = 0.5 - 0.03 == 0.47 (blank visit, queue penalty only)")


# === AC1: deterministic replay — roster-diff path (multi-departure) ===

const ROSTER_ZONE_TOTALS := {1: 1.6, 2: 0.0, 3: 1.2}
const ROSTER_CONGESTION := {1: 0.5, 2: 0.9, 3: 1.0}

## Replays a fixed ROSTER sequence (the on_tick / roster-diff path — the
## production event source, ADR-0005 §3) with non-contiguous member ids
## 3/7/12 and a same-tick multi-departure. Captures the observable state
## after every tick.
func _replay_roster_sequence() -> Array:
	var cong := FakeCongestion.new()
	for k in ROSTER_CONGESTION:
		cong.set_congestion(int(k), float(ROSTER_CONGESTION[k]))
	var ms := FakeMemberSim.new()
	var rig := _make_rig(ROSTER_ZONE_TOTALS, ms, {}, cong)
	var sat: RefCounted = rig["sat"]
	var trace: Array = []

	# tick 1 — members enter (accumulators created)
	ms.members = [
		{"member_id": 3, "state": "SELECTING_TARGET", "exercises_done": 0, "target_equipment_instance_id": -1},
		{"member_id": 7, "state": "SELECTING_TARGET", "exercises_done": 0, "target_equipment_instance_id": -1},
		{"member_id": 12, "state": "SELECTING_TARGET", "exercises_done": 0, "target_equipment_instance_id": -1},
	]
	sat.call("on_tick", 1)
	trace.append(_snapshot(sat))

	# tick 2 — m3/m12 START using (snapshot congestion once), m7 queues
	ms.members = [
		{"member_id": 3, "state": "USING", "exercises_done": 0, "target_equipment_instance_id": 1},
		{"member_id": 7, "state": "QUEUEING", "exercises_done": 0, "target_equipment_instance_id": 2},
		{"member_id": 12, "state": "USING", "exercises_done": 0, "target_equipment_instance_id": 3},
	]
	sat.call("on_tick", 2)
	trace.append(_snapshot(sat))

	# tick 3 — m3/m12 COMPLETE their uses (exercises_done increased), m7
	# queues another tick
	ms.members = [
		{"member_id": 3, "state": "USING", "exercises_done": 1, "target_equipment_instance_id": 1},
		{"member_id": 7, "state": "QUEUEING", "exercises_done": 0, "target_equipment_instance_id": 2},
		{"member_id": 12, "state": "USING", "exercises_done": 1, "target_equipment_instance_id": 3},
	]
	sat.call("on_tick", 3)
	trace.append(_snapshot(sat))

	# tick 4 — ALL THREE depart on one tick (multi-departure fold, ascending)
	ms.members = []
	sat.call("on_tick", 4)
	trace.append(_snapshot(sat))

	return trace


func _test_ac1_roster_diff_replay() -> void:
	print("\n[AC1] fixed roster sequence replayed twice through on_tick -> bit-identical (multi-departure tick)")
	var trace_a := _replay_roster_sequence()
	var trace_b := _replay_roster_sequence()
	_check(trace_a == trace_b, "AC1: roster-diff replay traces bit-identical (%d snapshots)" % trace_a.size())

	# Non-vacuous: the multi-departure tick (4th snapshot) moved global with
	# three distinct S_member folds, and the members are gone afterwards.
	var g_final: float = float(trace_a[3]["g"])
	_check(g_final != 0.5, "AC1: multi-departure fold moved global off 0.5 (got %s)" % str(g_final))
	_check((trace_a[3]["acc"] as Dictionary).is_empty(), "AC1: all three accumulators folded and discarded after the multi-departure tick")
	var g_after_use: float = float(trace_a[2]["g"])
	_check(g_after_use == 0.5, "AC1: no departure -> global unchanged (tick 3: 0.5)")


# === AC15: serialization round-trip — mid-visit ===

## The AC15 scenario constants. Congestion is FIXED per instance so the
## mid-use pending snapshot re-taken at load equals the original (Core Rule
## 8: pending uses are transient — documented determinism policy).
const AC15_ZONE_TOTALS := {1: 1.8, 2: 0.9, 3: 2.0}
const AC15_CONGESTION := {1: 0.3, 2: 0.7, 3: 0.1}

## Builds the pre-save rig and drives it to the save point (tick 10):
##   m3 — completed one use (uq 0.45) and DEPARTED (moved global off 0.5)
##   m1 — RICH mid-visit accumulator: n_uses 2, queue_ticks 3, n_fail 1,
##        n_interrupt 1; LEAVING (no_candidates) at the save boundary
##        (exactly one tick from departure)
##   m2 — MID-USE at the save boundary (USING inst 2, pending snapshot 0.7)
## Returns {rig, sat} with the fake member sim at the save-point roster.
func _drive_to_save_point() -> Dictionary:
	var cong := FakeCongestion.new()
	for k in AC15_CONGESTION:
		cong.set_congestion(int(k), float(AC15_CONGESTION[k]))
	var ms := FakeMemberSim.new()
	var rig := _make_rig(AC15_ZONE_TOTALS, ms, {}, cong)
	var sat: RefCounted = rig["sat"]

	# tick 1 — m1, m3 enter
	ms.members = [
		{"member_id": 1, "state": "SELECTING_TARGET", "exercises_done": 0, "target_equipment_instance_id": -1},
		{"member_id": 3, "state": "SELECTING_TARGET", "exercises_done": 0, "target_equipment_instance_id": -1},
	]
	sat.call("on_tick", 1)
	# tick 2 — m1 starts inst 1 (snapshot 0.3), m3 starts inst 3 (snapshot 0.1)
	ms.members = [
		{"member_id": 1, "state": "USING", "exercises_done": 0, "target_equipment_instance_id": 1},
		{"member_id": 3, "state": "USING", "exercises_done": 0, "target_equipment_instance_id": 3},
	]
	sat.call("on_tick", 2)
	# tick 3 — m1 INTERRUPTED (leaves USING without completing -> n_interrupt
	# 1, queue tick 1), m3 completes use #1 (uq = 0.5*1.0 - 0.5*0.1 = 0.45)
	ms.members = [
		{"member_id": 1, "state": "QUEUEING", "exercises_done": 0, "target_equipment_instance_id": 2},
		{"member_id": 3, "state": "USING", "exercises_done": 1, "target_equipment_instance_id": 3},
	]
	sat.call("on_tick", 3)
	# tick 4 — m1 queue tick 2, m3 DEPARTS (fold S_member 0.95)
	ms.members = [
		{"member_id": 1, "state": "QUEUEING", "exercises_done": 0, "target_equipment_instance_id": 2},
	]
	sat.call("on_tick", 4)
	# tick 5 — m1 queue tick 3, m2 enters
	ms.members = [
		{"member_id": 1, "state": "QUEUEING", "exercises_done": 0, "target_equipment_instance_id": 2},
		{"member_id": 2, "state": "SELECTING_TARGET", "exercises_done": 0, "target_equipment_instance_id": -1},
	]
	sat.call("on_tick", 5)
	# tick 6 — m1 re-starts inst 1 (re-snapshot 0.3), m2 starts inst 2 (0.7)
	ms.members = [
		{"member_id": 1, "state": "USING", "exercises_done": 0, "target_equipment_instance_id": 1},
		{"member_id": 2, "state": "USING", "exercises_done": 0, "target_equipment_instance_id": 2},
	]
	sat.call("on_tick", 6)
	# tick 7 — m1 completes use #1 (uq = 0.5*0.9 - 0.5*0.3 = 0.3)
	ms.members = [
		{"member_id": 1, "state": "USING", "exercises_done": 1, "target_equipment_instance_id": 1},
		{"member_id": 2, "state": "USING", "exercises_done": 0, "target_equipment_instance_id": 2},
	]
	sat.call("on_tick", 7)
	# tick 8 — m1 starts inst 2 (snapshot 0.7)
	ms.members = [
		{"member_id": 1, "state": "USING", "exercises_done": 1, "target_equipment_instance_id": 2},
		{"member_id": 2, "state": "USING", "exercises_done": 0, "target_equipment_instance_id": 2},
	]
	sat.call("on_tick", 8)
	# tick 9 — m1 completes use #2 (uq = 0.5*0.45 - 0.5*0.7 = -0.125)
	ms.members = [
		{"member_id": 1, "state": "USING", "exercises_done": 2, "target_equipment_instance_id": 2},
		{"member_id": 2, "state": "USING", "exercises_done": 0, "target_equipment_instance_id": 2},
	]
	sat.call("on_tick", 9)
	# tick 10 — m1 walk-FAILS (LEAVING no_candidates -> n_fail 1); m2 still
	# mid-use. SAVE POINT: m1 is EXACTLY ONE TICK from departure, m2 is
	# mid-use with a live pending snapshot.
	ms.members = [
		{"member_id": 1, "state": "LEAVING", "leaving_reason": "no_candidates", "exercises_done": 2, "target_equipment_instance_id": -1},
		{"member_id": 2, "state": "USING", "exercises_done": 0, "target_equipment_instance_id": 2},
	]
	sat.call("on_tick", 10)

	return {"rig": rig, "sat": sat, "member_sim": ms, "congestion": cong}


## Continuation rosters AFTER the save point (ticks 11-13): m1 departs at
## 11, m2 completes at 12, m2 departs at 13.
func _apply_continuation(rig: Dictionary) -> Array:
	var sat: RefCounted = rig["sat"]
	var ms: FakeMemberSim = rig["member_sim"]
	var trace: Array = []
	# tick 11 — m1 GONE (departure fold), m2 still using
	ms.members = [
		{"member_id": 2, "state": "USING", "exercises_done": 0, "target_equipment_instance_id": 2},
	]
	sat.call("on_tick", 11)
	trace.append(_snapshot(sat))
	# tick 12 — m2 completes use #1 (uq = 0.5*0.45 - 0.5*0.7 = -0.125)
	ms.members = [
		{"member_id": 2, "state": "USING", "exercises_done": 1, "target_equipment_instance_id": 2},
	]
	sat.call("on_tick", 12)
	trace.append(_snapshot(sat))
	# tick 13 — m2 GONE (departure fold)
	ms.members = []
	sat.call("on_tick", 13)
	trace.append(_snapshot(sat))
	return trace


func _test_ac15_roundtrip_mid_visit() -> void:
	print("\n[AC15] mid-visit accumulators + global -> JSON round-trip (full_precision) -> next ticks bit-identical")

	# --- Path A: uninterrupted play to the save point ---
	var save := _drive_to_save_point()
	var sat_a: RefCounted = save["sat"]
	var ms_a: FakeMemberSim = save["member_sim"]
	var save_roster: Array = ms_a.members.duplicate(true)

	# Rich-state assertions at the save point (the QA edge: accumulator with
	# n_uses > 0, queue_ticks > 0, penalties).
	var g_before: float = float(sat_a.get("global_satisfaction"))
	_check(g_before != 0.5, "AC15: global moved off init 0.5 before save (got %s)" % str(g_before))
	var acc1: Dictionary = sat_a.get("member_accumulators")[1]
	_check(int(acc1["n_uses"]) == 2, "AC15: m1 n_uses == 2 at save (got %d)" % int(acc1["n_uses"]))
	_check(int(acc1["queue_ticks"]) == 3, "AC15: m1 queue_ticks == 3 at save (got %d)" % int(acc1["queue_ticks"]))
	_check(int(acc1["n_fail"]) == 1, "AC15: m1 n_fail == 1 at save (got %d)" % int(acc1["n_fail"]))
	_check(int(acc1["n_interrupt"]) == 1, "AC15: m1 n_interrupt == 1 at save (got %d)" % int(acc1["n_interrupt"]))
	_check_float(float(acc1["S_acc"]), 0.175, "AC15: m1 S_acc == 0.3 + (-0.125) == 0.175")
	var pending2: Dictionary = sat_a.call("get_pending_use", 2)
	_check(int(pending2.get("instance_id", -1)) == 2, "AC15: m2 mid-use at save — pending instance 2")
	_check_float(float(pending2.get("congestion", 0.0)), 0.7, "AC15: m2 pending snapshot == Congestion_2(t-1) == 0.7")

	# --- Serialize -> JSON (full_precision) -> parse ---
	var payload: Dictionary = sat_a.call("serialize")
	var json_str := JSON.stringify(payload, "  ", true, true)
	var parsed: Variant = JSON.parse_string(json_str)
	_check(parsed is Dictionary, "AC15: JSON.stringify(full_precision=true)/parse round-trips the payload")

	# --- Path B: fresh rig, same fakes, restore via deserialize ---
	var cong_b := FakeCongestion.new()
	for k in AC15_CONGESTION:
		cong_b.set_congestion(int(k), float(AC15_CONGESTION[k]))
	var ms_b := FakeMemberSim.new()
	ms_b.members = save_roster.duplicate(true)  # the roster AS OF the save point
	var rig_b := _make_rig(AC15_ZONE_TOTALS, ms_b, {}, cong_b)
	var sat_b: RefCounted = rig_b["sat"]
	var result: RefCounted = sat_b.call("deserialize", parsed)
	_check(bool(result.get("ok")), "AC15: deserialize(JSON-parsed payload) ok (errors: %s)" % str(result.get("errors")))

	# --- Restored state == save-point state (bit-exact) ---
	_check(float(sat_b.get("global_satisfaction")) == g_before, "AC15: global restored bit-exact (%s == %s)" % [str(float(sat_b.get("global_satisfaction"))), str(g_before)])
	var acc1_b: Dictionary = sat_b.get("member_accumulators")[1]
	_check(int(acc1_b["n_uses"]) == 2 and int(acc1_b["queue_ticks"]) == 3 and int(acc1_b["n_fail"]) == 1 and int(acc1_b["n_interrupt"]) == 1,
		"AC15: m1 accumulator fields survive the round-trip (n_uses 2, queue 3, fail 1, interrupt 1)")
	_check(float(acc1_b["S_acc"]) == float(acc1["S_acc"]), "AC15: m1 S_acc restored bit-exact (float full_precision)")
	var pending2_b: Dictionary = sat_b.call("get_pending_use", 2)
	_check(int(pending2_b.get("instance_id", -1)) == 2, "AC15: m2 pending USE rebuilt from the loaded roster (mid-use survives)")
	_check_float(float(pending2_b.get("congestion", 0.0)), 0.7, "AC15: m2 pending congestion re-taken at load == original (fixed t-1)")

	# --- Continue BOTH paths with identical rosters; compare bit-exact ---
	var trace_a := _apply_continuation({"sat": sat_a, "member_sim": ms_a})
	var trace_b := _apply_continuation({"sat": sat_b, "member_sim": ms_b})
	_check(trace_a == trace_b, "AC15: post-reload ticks bit-identical to uninterrupted play (%d snapshots)" % trace_a.size())
	_check((trace_b[0]["acc"] as Dictionary).size() == 1, "AC15: m1 folded+dropped after reload departure (only m2 tracked)")
	_check((trace_b[2]["acc"] as Dictionary).is_empty(), "AC15: m2 folded+dropped — all accumulators consumed after continuation")

	# The departure AFTER reload used the SURVIVED accumulator fields: the
	# uninterrupted fold S_member equals the reloaded fold S_member, and both
	# moved global identically.
	_check(float(trace_a[1]["g"]) == float(trace_b[1]["g"]), "AC15: global after m2's post-reload use-completion bit-identical")


# === AC15 edge: reload exactly at departure boundary ===

func _test_ac15_roundtrip_departure_boundary() -> void:
	print("\n[AC15] edge: reload exactly at a departure boundary -> the departure fold is bit-identical")

	# Path A: build a single member with a rich accumulator, save while the
	# member is STILL IN the roster (about to depart), reload, then let the
	# departure happen.
	var cong := FakeCongestion.new()
	cong.set_congestion(1, 0.6)
	var ms_a := FakeMemberSim.new()
	var rig_a := _make_rig({1: 1.2}, ms_a, {}, cong)
	var sat_a: RefCounted = rig_a["sat"]

	# tick 1 — member 5 enters; tick 2 — starts using inst 1 (snapshot 0.6);
	# tick 3 — completes (uq = 0.5*0.6 - 0.5*0.6 = 0.0); tick 4 — queues
	# (queue_ticks 1); tick 5 — STILL in roster (LEAVING) = departure boundary.
	ms_a.members = [
		{"member_id": 5, "state": "SELECTING_TARGET", "exercises_done": 0, "target_equipment_instance_id": -1},
	]
	sat_a.call("on_tick", 1)
	ms_a.members = [
		{"member_id": 5, "state": "USING", "exercises_done": 0, "target_equipment_instance_id": 1},
	]
	sat_a.call("on_tick", 2)
	ms_a.members = [
		{"member_id": 5, "state": "USING", "exercises_done": 1, "target_equipment_instance_id": 1},
	]
	sat_a.call("on_tick", 3)
	ms_a.members = [
		{"member_id": 5, "state": "QUEUEING", "exercises_done": 1, "target_equipment_instance_id": 1},
	]
	sat_a.call("on_tick", 4)
	ms_a.members = [
		{"member_id": 5, "state": "LEAVING", "leaving_reason": "patience_exhausted", "exercises_done": 1, "target_equipment_instance_id": -1},
	]
	sat_a.call("on_tick", 5)
	var g_at_boundary: float = float(sat_a.get("global_satisfaction"))
	_check(g_at_boundary == 0.5, "AC15 edge: no departure yet at the boundary — global still 0.5")

	# Serialize at the boundary, restore into a fresh rig with the same roster.
	var payload: Dictionary = sat_a.call("serialize")
	var parsed: Variant = JSON.parse_string(JSON.stringify(payload, "  ", true, true))
	var ms_b := FakeMemberSim.new()
	ms_b.members = [
		{"member_id": 5, "state": "LEAVING", "leaving_reason": "patience_exhausted", "exercises_done": 1, "target_equipment_instance_id": -1},
	]
	var cong_b := FakeCongestion.new()
	cong_b.set_congestion(1, 0.6)
	var rig_b := _make_rig({1: 1.2}, ms_b, {}, cong_b)
	var sat_b: RefCounted = rig_b["sat"]
	var result: RefCounted = sat_b.call("deserialize", parsed)
	_check(bool(result.get("ok")), "AC15 edge: deserialize at the departure boundary ok")

	# Next tick: the member departs on BOTH paths. Compare the fold outcome.
	ms_a.members = []
	sat_a.call("on_tick", 6)
	ms_b.members = []
	sat_b.call("on_tick", 6)
	var g_a: float = float(sat_a.get("global_satisfaction"))
	var g_b: float = float(sat_b.get("global_satisfaction"))
	_check(g_a == g_b, "AC15 edge: departure fold after reload bit-identical to uninterrupted (%s == %s)" % [str(g_a), str(g_b)])
	_check(g_a != 0.5, "AC15 edge: the fold actually moved global (non-vacuous — got %s)" % str(g_a))
	# m5's S_member: uq 0.0, queue penalty 0.3*1/100 = 0.003 -> S = 0.497.
	_check_float(g_a, 0.05 * 0.497 + 0.95 * 0.5, "AC15 edge: global == alpha*0.497 + (1-alpha)*0.5 after the fold")


# === SAT-001F: no walk-fail RECOUNT across a save-load boundary ===

## A member mid-exit (LEAVING no_candidates) at the save point was counted
## when it ENTERED LEAVING (SAT-001F per-departure semantics).
## _rebuild_transient_state() seeds _last_seen[member_id].state from the
## loaded roster, so the first post-load LEAVING tick must NOT fire
## on_walk_fail again — without the seeding, prev_state would read "" and
## every reload would recount the departure.
func _test_walk_fail_no_recount_after_reload() -> void:
	print("\n[SAT-001F] save-load: a member mid-exit at the save point is NOT recounted after reload")
	var cong := FakeCongestion.new()
	var ms_a := FakeMemberSim.new()
	var rig_a := _make_rig({}, ms_a, {}, cong)
	var sat_a: RefCounted = rig_a["sat"]

	# tick 1 — member 50 enters; tick 2 — walk-fails (LEAVING no_candidates,
	# n_fail == 1 at entry); tick 3 — SAVE while still mid-exit (the 2nd
	# LEAVING tick keeps n_fail == 1).
	ms_a.members = [
		{"member_id": 50, "state": "ENTERING", "exercises_done": 0, "target_equipment_instance_id": -1},
	]
	sat_a.call("on_tick", 1)
	ms_a.members = [
		{"member_id": 50, "state": "LEAVING", "leaving_reason": "no_candidates", "exercises_done": 0, "target_equipment_instance_id": -1},
	]
	sat_a.call("on_tick", 2)
	ms_a.members = [
		{"member_id": 50, "state": "LEAVING", "leaving_reason": "no_candidates", "exercises_done": 0, "target_equipment_instance_id": -1},
	]
	sat_a.call("on_tick", 3)
	var acc_before: Dictionary = sat_a.get("member_accumulators")[50]
	_check(int(acc_before["n_fail"]) == 1, "SAT-001F: at the save point (2 LEAVING ticks) n_fail == 1 (got %d)" % int(acc_before["n_fail"]))

	# Serialize -> JSON -> parse -> deserialize into a fresh rig with the
	# SAME mid-exit roster (the realistic on-disk round-trip).
	var payload: Dictionary = sat_a.call("serialize")
	var parsed: Variant = JSON.parse_string(JSON.stringify(payload, "  ", true, true))
	var ms_b := FakeMemberSim.new()
	ms_b.members = [
		{"member_id": 50, "state": "LEAVING", "leaving_reason": "no_candidates", "exercises_done": 0, "target_equipment_instance_id": -1},
	]
	var rig_b := _make_rig({}, ms_b, {}, FakeCongestion.new())
	var sat_b: RefCounted = rig_b["sat"]
	var result: RefCounted = sat_b.call("deserialize", parsed)
	_check(bool(result.get("ok")), "SAT-001F: deserialize of mid-exit payload ok")

	# Post-load LEAVING tick: n_fail must stay 1 — the entry was counted
	# pre-save and the rebuild seeded _last_seen.state == "LEAVING".
	ms_b.members = [
		{"member_id": 50, "state": "LEAVING", "leaving_reason": "no_candidates", "exercises_done": 0, "target_equipment_instance_id": -1},
	]
	sat_b.call("on_tick", 4)
	var acc_after: Dictionary = sat_b.get("member_accumulators")[50]
	_check(int(acc_after["n_fail"]) == 1, "SAT-001F: post-reload LEAVING tick does NOT recount (n_fail stays 1, got %d)" % int(acc_after["n_fail"]))

	# Departure fold on BOTH paths. A recount on the reload path would fold
	# n_fail=2 (fail_penalty 0.30 cap) instead of n_fail=1 (0.15), moving
	# global differently — the bit-identity pin proves the fix.
	ms_a.members = []
	sat_a.call("on_tick", 5)
	ms_b.members = []
	sat_b.call("on_tick", 5)
	var g_a: float = float(sat_a.get("global_satisfaction"))
	var g_b: float = float(sat_b.get("global_satisfaction"))
	_check(g_a == g_b, "SAT-001F: departure fold after reload bit-identical to uninterrupted (%s == %s)" % [str(g_a), str(g_b)])
	_check_float(g_a, 0.05 * 0.35 + 0.95 * 0.5, "SAT-001F: global == alpha*0.35 + (1-alpha)*0.5 (n_fail=1 -> fail_penalty 0.15, NOT the 0.30 cap)")
	_check((sat_b.get("member_accumulators") as Dictionary).is_empty(), "SAT-001F: accumulator consumed after the post-reload departure fold")


# === deserialize validation contract ===

func _test_deserialize_validation() -> void:
	print("\n[deserialize] Phase A validation — corrupt payloads fail loudly, no invented defaults")
	var rig := _make_rig()
	var sat: RefCounted = rig["sat"]
	var good: Dictionary = sat.call("serialize")

	# Valid payload passes both phases.
	var ok_res: RefCounted = sat.call("deserialize", good)
	_check(bool(ok_res.get("ok")), "validation: valid serialize() payload passes commit")

	# validate_only passes and mutates NOTHING.
	var counter_before: int = int(sat.get("counter"))
	var vo: RefCounted = sat.call("deserialize", good, true)
	_check(bool(vo.get("ok")), "validation: validate_only passes a valid payload")
	_check(int(sat.get("counter")) == counter_before and float(sat.get("global_satisfaction")) == 0.5,
		"validation: validate_only left the system unmutated")

	# Missing new fields (stub-era blob) -> hard failure.
	var stub_blob: Dictionary = {"counter": 3, "rng_state": "0x0"}
	var stub_res: RefCounted = sat.call("deserialize", stub_blob)
	_check(not bool(stub_res.get("ok")), "validation: stub-era blob missing global_satisfaction/member_accumulators FAILS")
	_check(str(stub_res.get("errors")).find("global_satisfaction") != -1, "validation: error names the missing field")

	# Out-of-range / non-finite global.
	var bad_g: Dictionary = good.duplicate(true)
	bad_g["global_satisfaction"] = 1.5
	_check(not bool(sat.call("deserialize", bad_g).get("ok")), "validation: global_satisfaction 1.5 (> 1) rejected")
	bad_g["global_satisfaction"] = -0.1
	_check(not bool(sat.call("deserialize", bad_g).get("ok")), "validation: global_satisfaction -0.1 (< 0) rejected")
	bad_g["global_satisfaction"] = NAN
	_check(not bool(sat.call("deserialize", bad_g).get("ok")), "validation: global_satisfaction NaN rejected (no silent corrupt meter)")

	# member_accumulators shape violations.
	var bad_accs: Dictionary = good.duplicate(true)
	bad_accs["member_accumulators"] = {"5": {"S_acc": 0.2, "n_uses": 1}}  # missing 4 fields
	var shape_res: RefCounted = sat.call("deserialize", bad_accs)
	_check(not bool(shape_res.get("ok")), "validation: accumulator missing TR-SAT-002 fields rejected")
	_check(str(shape_res.get("errors")).find("queue_ticks") != -1, "validation: error names the missing accumulator field")

	bad_accs["member_accumulators"] = {"5": {"S_acc": "nan", "n_uses": 1, "queue_ticks": 0, "n_fail": 0, "n_interrupt": 0}}
	_check(not bool(sat.call("deserialize", bad_accs).get("ok")), "validation: accumulator with non-numeric field rejected")

	bad_accs["member_accumulators"] = {"abc": {"S_acc": 0.0, "n_uses": 1, "queue_ticks": 0, "n_fail": 0, "n_interrupt": 0}}
	_check(not bool(sat.call("deserialize", bad_accs).get("ok")), "validation: non-numeric member key rejected")

	bad_accs["member_accumulators"] = "not a dict"
	_check(not bool(sat.call("deserialize", bad_accs).get("ok")), "validation: member_accumulators not a Dictionary rejected")

	# JSON-style coercion: counter as float + string member keys round-trip
	# cleanly (the realistic on-disk shape after JSON.parse).
	var json_style: Dictionary = good.duplicate(true)
	json_style["counter"] = 7.0
	json_style["global_satisfaction"] = 0.25
	json_style["member_accumulators"] = {
		"5": {"S_acc": 0.175, "n_uses": 2.0, "queue_ticks": 3.0, "n_fail": 1.0, "n_interrupt": 1.0},
	}
	var json_res: RefCounted = sat.call("deserialize", json_style)
	_check(bool(json_res.get("ok")), "validation: JSON-parsed shape (float counter, string keys, float ints) accepted")
	_check(int(sat.get("counter")) == 7, "validation: float counter coerced to int 7")
	_check((sat.get("member_accumulators") as Dictionary).has(5), "validation: string key '5' coerced to int member_id 5")
	var acc5: Dictionary = sat.get("member_accumulators")[5]
	_check(int(acc5["n_uses"]) == 2 and int(acc5["queue_ticks"]) == 3 and int(acc5["n_fail"]) == 1 and int(acc5["n_interrupt"]) == 1,
		"validation: JSON float int-fields coerced back to int")
