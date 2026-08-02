# tests/unit/economy/revenue_balance_test.gd
# Story ECON-001: Balance and Flat-Fee Revenue
# (production/epics/economy/story-001-balance-flat-fee-revenue.md)
#
# Covers the BLOCKING ACs (TR-ECON-001..005, per the story QA test cases):
#   - AC1   never negative: income + spend sequence including an overspend
#           (amount > balance) -> balance never < 0 at any point; the
#           overspend call returns false, balance unchanged, no signal.
#           Edge: balance = 0 then spend; balance = 1 then spend(2).
#   - AC8   flat fee: N member_completed_visit events -> balance += N × R_visit
#           ($12). Edge: N = 0, N = 1, N = 100.
#   - AC9   multi-departure determinism: multiple events on one tick -> single
#           deterministic delta N × R_visit (order-independent by construction
#           — commutative sum, no fold order).
#   - AC11  starting capital: fresh Economy instance -> balance == 500.
#           Edge: after deserialize with a saved balance -> NOT reset to 500.
#   - AC13  income emits balance_changed: one event -> balance_changed(new,
#           +R_visit) fires exactly once with a positive delta. Edge: multiple
#           events -> one signal per event, each +R_visit.
#   - AC14  only quota-met departures earn revenue: a real MemberSim rig drives
#           a walk-failure departure (no candidates) and a patience-exhausted
#           departure (queue give-up) -> $0, no balance_changed; a quota-met
#           departure -> +R_visit with one balance_changed.
#
# AC14 uses the REAL MemberSim state machine (grid + navigation + catalog +
# entrance/exit) with Economy wired via _post_init() so the S5
# member_completed_visit signal is exercised end-to-end — the strongest
# evidence that non-quota departures never reach Economy's ledger.
#
# Run standalone: godot --headless --script tests/unit/economy/revenue_balance_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const GRID_W := 8
const GRID_H := 6
const ENTRANCE := Vector2i(0, 0)
const EXIT := Vector2i(7, 5)
const R0 := 0

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
	print("  UNIT TEST: Economy — Balance and Flat-Fee Revenue (Story ECON-001)")
	print("=".repeat(48))

	_test_ac11_starting_capital()
	_test_ac11_deserialize_does_not_reset()
	_test_ac8_flat_fee()
	_test_ac9_multi_departure_determinism()
	_test_ac9_order_independent()
	_test_ac13_income_emits_balance_changed()
	_test_ac1_never_negative()
	_test_ac14_walk_failure_earns_zero()
	_test_ac14_patience_exhaust_earns_zero()
	_test_ac14_quota_met_earns_revenue()
	_test_spend_zero_negative_rejected()
	_test_no_decay_no_upkeep()

	print("\n=== REVENUE/BALANCE TEST: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


# === Helpers ===

func _EC() -> Script:
	return load("res://src/systems/economy.gd") as Script


func _SRG() -> Script:
	return load("res://src/systems/seeded_rng.gd") as Script


func _MS() -> Script:
	return load("res://src/systems/member_sim.gd") as Script


func _GS() -> Script:
	return load("res://src/systems/grid_system.gd") as Script


func _NAV() -> Script:
	return load("res://src/systems/navigation.gd") as Script


func _ECAT() -> Script:
	return load("res://src/systems/equipment_catalog.gd") as Script


func _ED() -> Script:
	return load("res://src/systems/equipment_def.gd") as Script


## Creates an initialized SimulationOrchestrator in the scene tree (delivers
## _ready() synchronously — same pattern as the save-load integration tests).
func _make_orchestrator() -> Node:
	var orch: Node = load("res://src/systems/simulation_orchestrator.gd").new()
	root.add_child(orch)
	orch.call("_ready")
	return orch


## Builds an all-buildable grid and returns it as a dynamically-dispatched
## RefCounted (project test contract — load by path).
func _make_grid() -> RefCounted:
	var gs: RefCounted = _GS().new()
	gs.call("init", GRID_W, GRID_H)
	for y in GRID_H:
		for x in GRID_W:
			gs.call("set_buildable", Vector2i(x, y), true)
	gs.call("freeze_buildable")
	return gs


func _make_navigation(grid: RefCounted) -> RefCounted:
	var nav: RefCounted = _NAV().new()
	nav.call("init", grid)
	nav.call("_post_init")
	return nav


## Builds a frozen EquipmentCatalog with one treadmill definition (the
## member-sim tests' catalog shape).
func _make_catalog() -> RefCounted:
	var cat: RefCounted = _ECAT().new()
	var fp: Array[Vector2i] = [Vector2i(0, 0)]
	var ac: Array[Vector2i] = [Vector2i(1, 0)]
	var effects: Array[Dictionary] = []
	var def = _ED().new("treadmill", "Treadmill", ["cardio"], fp, ac, 100, "", effects, 200, 35, 100, 300)
	cat.call("_add_definition", def)
	cat.call("_freeze")
	return cat


## Commits one equipment instance: footprint at [fp], access cell at [ac].
func _commit_equipment(gs: RefCounted, instance_id: int, fp: Vector2i, ac: Vector2i) -> void:
	var fp_arr: Array[Vector2i] = [fp]
	var ac_arr: Array[Vector2i] = [ac]
	gs.call("commit", instance_id, fp_arr, ac_arr, R0)


## Builds a bare Economy unit rig: real orchestrator + SeededRNG + real
## Economy init'd with the default config (starting_capital 500, r_visit 12).
## Returns the rig for direct method-drive tests (AC1/8/9/11/13).
func _make_economy_rig(seed: int = 0xEC0E001) -> Dictionary:
	var srg: RefCounted = _SRG().new()
	srg.call("init", seed)
	var orch := _make_orchestrator()
	var econ: RefCounted = _EC().new()
	econ.call("init", orch, srg)
	orch.set("economy", econ)
	return {"orchestrator": orch, "seeded_rng": srg, "economy": econ}


## Builds the AC14 rig: REAL MemberSim state machine (grid + navigation +
## catalog + entrance/exit) with the REAL Economy wired via _post_init() so
## the S5 signal reaches the ledger. base_arrival_rate_per_min = 0 so no
## natural spawn interferes (all members injected).
func _make_member_rig(seed: int, equipment: Array = []) -> Dictionary:
	var gs := _make_grid()
	for eq in equipment:
		_commit_equipment(gs, int(eq["id"]), eq["fp"], eq["ac"])
	var nav := _make_navigation(gs)
	var cat := _make_catalog()
	var srg: RefCounted = _SRG().new()
	srg.call("init", seed)
	var orch := _make_orchestrator()
	var ms: RefCounted = _MS().new()
	var cfg: Dictionary = {
		"base_arrival_rate_per_min": 0.0,
		"max_concurrent_members": 15,
		"use_duration_mean_ticks": 2,
		"use_duration_stddev_ticks": 0,
		"use_duration_min_ticks": 1,
		"use_duration_max_ticks": 3,
		"leaving_timeout_ticks": 300,
		"exercises_mean": 2.0,
		"exercises_stddev": 0.0,
		"exercises_min": 1,
		"exercises_max": 5,
		"patience_min_ticks": 30,
		"patience_max_ticks": 80,
	}
	ms.call("init", orch, srg, gs, nav, cat, ENTRANCE, EXIT, cfg)
	orch.set("member_sim", ms)

	var econ: RefCounted = _EC().new()
	econ.call("init", orch, srg)
	orch.set("economy", econ)
	econ.call("_post_init")  # subscribe to S5 member_completed_visit

	return {
		"orchestrator": orch,
		"grid_system": gs,
		"navigation": nav,
		"catalog": cat,
		"seeded_rng": srg,
		"member_sim": ms,
		"economy": econ,
	}


## Builds a FULL state-machine member record (the shape _spawn_member
## produces). [overrides] replace any field — used to arm specific states.
func _make_member(member_id: int, state: String, exercises_done: int, exercises_per_visit: int, cell: Vector2i, overrides: Dictionary = {}) -> Dictionary:
	var m := {
		"member_id": member_id,
		"state": state,
		"cell": cell,
		"exercises_done": exercises_done,
		"exercises_per_visit": exercises_per_visit,
		"preference_profile": {"preference_noise": 1.0},
		"target_equipment_instance_id": -1,
		"cached_path": [],
		"leaving_timeout_ticks": 0,
	}
	for k in overrides:
		m[k] = overrides[k]
	return m


## Injects a full member record directly into the roster (bypasses arrival).
func _inject_member(rig: Dictionary, member: Dictionary) -> void:
	(rig["member_sim"].get("members") as Array).append(member)


func _member_count(rig: Dictionary) -> int:
	return (rig["member_sim"].get("members") as Array).size()


## Finds a member by id in the roster; returns {} when absent.
func _find_member(rig: Dictionary, member_id: int) -> Dictionary:
	for m in (rig["member_sim"].get("members") as Array):
		if m is Dictionary and m.has("member_id") and int(m["member_id"]) == member_id:
			return m
	return {}


## Runs [n] ticks directly on the MemberSim (unit scope — the orchestrator's
## FIXED_TICK_ORDER dispatch is pinned by orchestrator_tick_dispatch_test).
func _run_ticks(rig: Dictionary, n: int, start_tick: int = 0) -> void:
	for i in range(n):
		rig["member_sim"].call("on_tick", start_tick + i)


## Connects a spy to economy.balance_changed, recording every emission as
## [new_balance, delta]. Returns the record array.
func _spy_balance_changed(econ: RefCounted) -> Array:
	var seen: Array = []
	econ.balance_changed.connect(func(new_balance: int, delta: int) -> void: seen.append([new_balance, delta]))
	return seen


# === AC11: starting capital ===

func _test_ac11_starting_capital() -> void:
	print("\n[AC11] fresh Economy instance -> balance == 500 (starting_capital) with no prior events")
	var rig := _make_economy_rig()
	_check(int(rig["economy"].get("balance")) == 500, "AC11: balance == 500 immediately after init (got %d)" % int(rig["economy"].get("balance")))
	_check(int(rig["economy"].get("balance")) == 500, "AC11: still 500 after no events")


func _test_ac11_deserialize_does_not_reset() -> void:
	print("\n[AC11] edge: after deserialize with a saved balance (777) -> NOT reset to 500")
	var rig := _make_economy_rig(0xEC0E11)
	var payload := {
		"counter": 42,
		"balance": 777,
		"rng_state": SeededRNG.int64_to_hex(int(rig["seeded_rng"].call("get_rng", "Economy").state)),
	}
	var result: RefCounted = rig["economy"].call("deserialize", payload, false)
	_check(bool(result.get("ok")), "AC11[edge]: deserialize ok (errors: %s)" % str(result.get("errors")))
	_check(int(rig["economy"].get("balance")) == 777, "AC11[edge]: balance restored to 777, NOT reset to 500 (got %d)" % int(rig["economy"].get("balance")))


# === AC8: flat fee ===

func _test_ac8_flat_fee() -> void:
	print("\n[AC8] N member_completed_visit events -> balance += N × R_visit ($12)")
	# N = 0
	var rig := _make_economy_rig(0xEC0E08)
	_check(int(rig["economy"].get("balance")) == 500, "AC8[N=0]: balance unchanged at 500")
	# N = 1
	rig["economy"].call("on_member_completed_visit", 1001)
	_check(int(rig["economy"].get("balance")) == 512, "AC8[N=1]: balance == 512 after one event (got %d)" % int(rig["economy"].get("balance")))
	# N = 100 (total 101 events -> 500 + 101*12 = 1712)
	for i in 100:
		rig["economy"].call("on_member_completed_visit", 2000 + i)
	_check(int(rig["economy"].get("balance")) == 1712, "AC8[N=100]: 101 events total -> balance == 1712 (got %d)" % int(rig["economy"].get("balance")))


# === AC9: multi-departure determinism ===

func _test_ac9_multi_departure_determinism() -> void:
	print("\n[AC9] multiple member_completed_visit events on one tick -> single deterministic delta N × R_visit")
	var rig := _make_economy_rig(0xEC0E09)
	# 3 events, no ticks between them — the same-tick scenario.
	rig["economy"].call("on_member_completed_visit", 1)
	rig["economy"].call("on_member_completed_visit", 2)
	rig["economy"].call("on_member_completed_visit", 3)
	_check(int(rig["economy"].get("balance")) == 536, "AC9: 3 events same tick -> balance += 36 (500+36=%d got)" % int(rig["economy"].get("balance")))


func _test_ac9_order_independent() -> void:
	print("\n[AC9] order-independence: same event set in different orders -> identical balance (commutative sum)")
	var rig_a := _make_economy_rig(0xEC0E0A)
	var rig_b := _make_economy_rig(0xEC0E0A)
	var events := [11, 22, 33, 44, 55]
	for id in events:
		rig_a["economy"].call("on_member_completed_visit", id)
	for i in range(events.size() - 1, -1, -1):
		rig_b["economy"].call("on_member_completed_visit", events[i])
	_check(int(rig_a["economy"].get("balance")) == int(rig_b["economy"].get("balance")),
		"AC9: order A (ascending) == order B (descending) == %d" % int(rig_a["economy"].get("balance")))
	_check(int(rig_a["economy"].get("balance")) == 500 + 5 * 12, "AC9: total is exactly N × R_visit (got %d)" % int(rig_a["economy"].get("balance")))


# === AC13: income emits balance_changed ===

func _test_ac13_income_emits_balance_changed() -> void:
	print("\n[AC13] one member_completed_visit -> balance_changed(new, +R_visit) fires exactly once, positive delta")
	var rig := _make_economy_rig(0xEC0E13)
	var seen := _spy_balance_changed(rig["economy"])
	rig["economy"].call("on_member_completed_visit", 7)
	_check(seen.size() == 1, "AC13: exactly one balance_changed emission (got %d)" % seen.size())
	if seen.size() >= 1:
		_check(int(seen[0][0]) == 512, "AC13: payload new_balance == 512 (got %d)" % int(seen[0][0]))
		_check(int(seen[0][1]) == 12, "AC13: payload delta == +R_visit == +12 (got %d)" % int(seen[0][1]))
	_check(int(seen[0][1]) > 0, "AC13: delta is positive (got %d)" % int(seen[0][1]))

	# Edge: multiple events -> one signal per event, each +R_visit.
	var seen2 := _spy_balance_changed(rig["economy"])
	rig["economy"].call("on_member_completed_visit", 8)
	rig["economy"].call("on_member_completed_visit", 9)
	_check(seen2.size() == 2, "AC13[edge]: two events -> two balance_changed emissions (got %d)" % seen2.size())
	if seen2.size() == 2:
		_check(int(seen2[0][0]) == 524 and int(seen2[0][1]) == 12, "AC13[edge]: 1st: new=524 delta=+12 (got %s)" % str(seen2[0]))
		_check(int(seen2[1][0]) == 536 and int(seen2[1][1]) == 12, "AC13[edge]: 2nd: new=536 delta=+12 (got %s)" % str(seen2[1]))


# === AC1: never negative ===

func _test_ac1_never_negative() -> void:
	print("\n[AC1] income + spend sequence including an overspend -> balance never < 0; overspend returns false, unchanged")
	var rig := _make_economy_rig(0xEC0E01)
	var seen := _spy_balance_changed(rig["economy"])

	# Income: 3 events -> 536.
	rig["economy"].call("on_member_completed_visit", 1)
	rig["economy"].call("on_member_completed_visit", 2)
	rig["economy"].call("on_member_completed_visit", 3)
	_check(int(rig["economy"].get("balance")) == 536, "AC1: after income balance == 536 (got %d)" % int(rig["economy"].get("balance")))

	# Successful spend: 36 -> 500.
	_check(bool(rig["economy"].call("spend", 36)), "AC1: spend(36) succeeds")
	_check(int(rig["economy"].get("balance")) == 500, "AC1: balance 500 after spend(36) (got %d)" % int(rig["economy"].get("balance")))

	# Overspend: 501 > 500 -> false, unchanged, NO signal.
	var signal_count_before := seen.size()
	var overspend_result: bool = rig["economy"].call("spend", 501)
	_check(not overspend_result, "AC1: spend(501) overspend returns false")
	_check(int(rig["economy"].get("balance")) == 500, "AC1: balance unchanged at 500 after overspend (got %d)" % int(rig["economy"].get("balance")))
	_check(seen.size() == signal_count_before, "AC1: overspend emits NO balance_changed (got %d new)" % (seen.size() - signal_count_before))

	# Drain to 0 then overspend.
	rig["economy"].call("spend", 500)
	_check(int(rig["economy"].get("balance")) == 0, "AC1: balance drained to 0 (got %d)" % int(rig["economy"].get("balance")))
	_check(not bool(rig["economy"].call("spend", 1)), "AC1 edge: balance=0 then spend(1) returns false")
	_check(int(rig["economy"].get("balance")) == 0, "AC1 edge: balance stays 0 (got %d)" % int(rig["economy"].get("balance")))

	# Balance=1 then spend(2) — the QA's second edge.
	var rig2 := _make_economy_rig(0xEC0E02)
	rig2["economy"].call("spend", 499)  # 500 -> 1
	_check(int(rig2["economy"].get("balance")) == 1, "AC1 edge: balance == 1 (got %d)" % int(rig2["economy"].get("balance")))
	_check(not bool(rig2["economy"].call("spend", 2)), "AC1 edge: balance=1 then spend(2) returns false")
	_check(int(rig2["economy"].get("balance")) == 1, "AC1 edge: balance stays 1 (got %d)" % int(rig2["economy"].get("balance")))


# === AC14: only quota-met departures earn revenue ===

func _test_ac14_walk_failure_earns_zero() -> void:
	print("\n[AC14] walk-failure departure (no candidates) -> $0, no balance_changed (real MemberSim S5 path)")
	var rig := _make_member_rig(0xEC0E14)
	var seen := _spy_balance_changed(rig["economy"])

	# Empty gym — member in SELECTING_TARGET with zero candidates -> LEAVING
	# (no_candidates) -> GONE without S5 (member_sim's AC1 path).
	_inject_member(rig, _make_member(100, "SELECTING_TARGET", 0, 3, ENTRANCE))
	_run_ticks(rig, 40)  # leaves and despawns

	_check(_member_count(rig) == 0, "AC14[wfail]: member despawned via walk-failure path")
	_check(int(rig["economy"].get("balance")) == 500, "AC14[wfail]: balance unchanged at 500 (got %d)" % int(rig["economy"].get("balance")))
	_check(seen.is_empty(), "AC14[wfail]: NO balance_changed fired (got %d)" % seen.size())


func _test_ac14_patience_exhaust_earns_zero() -> void:
	print("\n[AC14] patience-exhausted departure (queue give-up) -> $0, no balance_changed (real MemberSim S5 path)")
	var equipment: Array = [{"id": 1, "fp": Vector2i(4, 2), "ac": Vector2i(3, 2)}]
	var rig := _make_member_rig(0xEC0E15, equipment)
	var seen := _spy_balance_changed(rig["economy"])

	# Occupant 100 using E1 very long; claimant 200 queuing one cell short
	# with patience = 1 (gives up next tick). After the give-up, the machine
	# is removed mid-blacklist, so 200's reselect finds NO candidates at all
	# once the blacklist expires -> LEAVING (no_candidates) -> GONE without
	# S5 — the real patience-exhausted departure path (AC19 anti-flip-flop:
	# with the machine still present it would re-queue instead, which never
	# departs — so removal is what makes the departure happen).
	_inject_member(rig, _make_member(100, "USING", 0, 3, Vector2i(3, 2), {
		"target_equipment_instance_id": 1,
		"use_ticks_remaining": 100000,
	}))
	_inject_member(rig, _make_member(200, "QUEUEING", 0, 3, Vector2i(2, 2), {
		"target_equipment_instance_id": 1,
		"patience_ticks_remaining": 1,
	}))
	# Seed the reservation map the same way member_sim's own tests do.
	var reservations: Dictionary = rig["member_sim"].get("reservations")
	reservations[1] = {"occupant": 100, "next_claimant": 200}

	_run_ticks(rig, 2)  # tick 1: give-up -> SELECTING_TARGET (blacklist armed)
	# Precondition: 200 has given up and is reselecting, not still queuing.
	var m200 := _find_member(rig, 200)
	_check(not m200.is_empty() and str(m200["state"]) == "SELECTING_TARGET",
		"AC14[pat]: precondition — patience exhausted, member reselecting (state=%s)" % ("" if m200.is_empty() else str(m200["state"])))

	# Remove the machine mid-blacklist -> reselect finds no candidates.
	rig["grid_system"].call("clear", 1)

	_run_ticks(rig, 40, 2)  # blacklist expires, empty pool -> LEAVING -> GONE

	# Member 200 must have DEPARTED (patience-exhausted path, no quota met).
	# The occupant 100 also departs via the mid-use deletion interrupt (AC14)
	# once the machine is cleared — both are non-quota departures, so neither
	# earns revenue.
	_check(_find_member(rig, 200).is_empty(), "AC14[pat]: patience-exhausted member 200 departed (GONE)")
	_check(int(rig["economy"].get("balance")) == 500, "AC14[pat]: balance unchanged at 500 (got %d)" % int(rig["economy"].get("balance")))
	_check(seen.is_empty(), "AC14[pat]: NO balance_changed fired (got %d)" % seen.size())


func _test_ac14_quota_met_earns_revenue() -> void:
	print("\n[AC14] quota-met departure -> +R_visit with exactly one balance_changed (real MemberSim S5 path)")
	var rig := _make_member_rig(0xEC0E16)
	var seen := _spy_balance_changed(rig["economy"])

	# Quota-met member already LEAVING toward the exit — despawns via the
	# quota-met path -> S5 fires -> Economy accrues.
	_inject_member(rig, _make_member(100, "LEAVING", 2, 2, Vector2i(1, 1), {
		"leaving_timeout_ticks": 300,
		"leaving_reason": "quota_met",
	}))
	_run_ticks(rig, 40)  # walk to exit (7,5) and despawn

	_check(_member_count(rig) == 0, "AC14[q]: member despawned via quota-met path")
	_check(int(rig["economy"].get("balance")) == 512, "AC14[q]: balance == 512 after quota-met departure (got %d)" % int(rig["economy"].get("balance")))
	_check(seen.size() == 1, "AC14[q]: exactly one balance_changed (got %d)" % seen.size())
	if seen.size() == 1:
		_check(int(seen[0][0]) == 512 and int(seen[0][1]) == 12, "AC14[q]: (new=512, delta=+12) got %s" % str(seen[0]))


# === spend gates (defensive — AC1's rejection semantics) ===

func _test_spend_zero_negative_rejected() -> void:
	print("\n[AC1/defensive] spend(0) and spend(negative) rejected: false, balance unchanged, no signal")
	var rig := _make_economy_rig(0xEC0E17)
	var seen := _spy_balance_changed(rig["economy"])
	_check(not bool(rig["economy"].call("spend", 0)), "spend(0) returns false")
	_check(not bool(rig["economy"].call("spend", -100)), "spend(-100) returns false")
	_check(int(rig["economy"].get("balance")) == 500, "balance unchanged at 500 (got %d)" % int(rig["economy"].get("balance")))
	_check(seen.is_empty(), "no balance_changed fired for rejected spends (got %d)" % seen.size())


# === GDD AC10 / no upkeep ===

func _test_no_decay_no_upkeep() -> void:
	print("\n[no-decay] zero departures and no spend across ticks -> balance unchanged (never decays)")
	var rig := _make_economy_rig(0xEC0E18)
	for i in 30:
		rig["economy"].call("on_tick", i)
	_check(int(rig["economy"].get("balance")) == 500, "no-decay: balance still 500 after 30 ticks (got %d)" % int(rig["economy"].get("balance")))
	_check(int(rig["economy"].get("counter")) == 30, "no-decay: counter advanced 30 (observable progression, got %d)" % int(rig["economy"].get("counter")))
