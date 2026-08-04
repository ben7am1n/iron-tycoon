# tests/unit/economy/credit_no_satisfaction_test.gd
# Story ECON-003: credit() Interface and No-Satisfaction Structure
# (production/epics/economy/story-003-credit-no-satisfaction-structure.md)
#
# Covers the BLOCKING ACs (TR-ECON-008 / TR-ECON-004, per the story QA test cases):
#   - AC7   no satisfaction dependency (structural check): a test double whose
#           global_satisfaction / satisfaction_modifier properties THROW on read
#           is attached as a dependency (the orchestrator's satisfaction slot);
#           revenue accrual N times (N = 0, 1, many, plus the real S5 MemberSim
#           path) NEVER invokes any satisfaction accessor and
#           balance == starting_capital + N × R_visit.
#   - AC15  progress never locks (integration, advisory): balance = 0 -> one
#           member_completed_visit -> balance == R_visit and can_afford(R_visit)
#           true. Edge: after spend to zero; after multiple accruals.
#
# Plus the ADR-0006 credit() contract (the implementation spec for this story):
#   - credit(amount, reason) -> bool: amount > 0 success -> balance += amount,
#           balance_changed(new, +amount) fires exactly once with a positive
#           delta; reason is audit-only (no gameplay effect).
#   - amount <= 0 rejected: returns false, balance unchanged, NO signal,
#           push_warning logged.
#   - spend/credit symmetry: spend(200) then credit(50) -> net -150, two
#           signals with opposite deltas.
#   - coexistence with visit revenue: member_completed_visit (+12) and
#           credit(100) on the same rig -> +112 total, one signal per path.
#   - forbidden workaround: spend(-refund) as credit is structurally blocked
#           (spend's amount <= 0 gate -> false, no mutation).
#   - refund formula NOT in Economy: no REFUND_RATE constant, no refund()
#           method, no equipment-price knowledge (structural check on source).
#
# NOTE on AC15's can_afford(R_visit) clause: can_afford() is owned by story
# ECON-002 (spend/can_afford triple-gating), which lands on a PARALLEL worktree.
# This file asserts the balance == R_visit clause unconditionally and asserts
# can_afford(R_visit) when the method exists (has_method guard) — so the file
# is green at this story's commit AND becomes stronger once ECON-002 merges.
#
# Run standalone: godot --headless --script tests/unit/economy/credit_no_satisfaction_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const GRID_W := 8
const GRID_H := 6
const ENTRANCE := Vector2i(0, 0)
const EXIT := Vector2i(7, 5)
const R0 := 0

var _pass := 0
var _fail := 0


## Test double whose satisfaction accessors THROW on read. Any code path that
## reads global_satisfaction / satisfaction_modifier increments the counter
## and pushes an error (surfaces as SCRIPT ERROR in headless runs). AC7 asserts
## the counter stays 0 across N revenue accruals — the structural proof that
## Economy's revenue path contains zero satisfaction references.
class SatisfactionThrowingDouble:
	extends RefCounted

	var reads := 0

	var global_satisfaction: float:
		get:
			reads += 1
			push_error("SatisfactionThrowingDouble.global_satisfaction read — Economy must never touch satisfaction")
			return 0.0

	var satisfaction_modifier: float:
		get:
			reads += 1
			push_error("SatisfactionThrowingDouble.satisfaction_modifier read — Economy must never touch satisfaction")
			return 0.0


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
	print("  UNIT TEST: Economy — credit() Interface and No-Satisfaction Structure (Story ECON-003)")
	print("=".repeat(48))

	_test_ac7_no_satisfaction_dependency()
	_test_ac7_s5_path_no_satisfaction()
	_test_ac15_progress_never_locks()
	_test_credit_success_emits_signal()
	_test_credit_reason_audit_only()
	_test_credit_zero_negative_rejected()
	_test_spend_credit_symmetry()
	_test_credit_coexists_with_visit_revenue()
	_test_spend_negative_not_credit()
	_test_no_refund_formula_in_economy()

	print("\n=== CREDIT/NO-SATISFACTION TEST: %d passed, %d failed ===\n" % [_pass, _fail])
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


## Builds a bare Economy unit rig: real orchestrator + SeededRNG + real
## Economy init'd with [config] (defaults: starting_capital 500, r_visit 12).
## Returns the rig for direct method-drive tests (AC7/AC15/credit contract).
func _make_economy_rig(seed: int = 0xEC0003, config: Dictionary = {}) -> Dictionary:
	var srg: RefCounted = _SRG().new()
	srg.call("init", seed)
	var orch := _make_orchestrator()
	var econ: RefCounted = _EC().new()
	econ.call("init", orch, srg, config)
	orch.set("economy", econ)
	return {"orchestrator": orch, "seeded_rng": srg, "economy": econ}


## Attaches a SatisfactionThrowingDouble to the rig's orchestrator satisfaction
## slot (the composition-root position where a real Satisfaction system would
## live). Returns the double so the test can assert reads == 0.
func _attach_throwing_satisfaction(rig: Dictionary) -> RefCounted:
	var dbl: RefCounted = SatisfactionThrowingDouble.new()
	rig["orchestrator"].set("satisfaction", dbl)
	return dbl


## Builds the S5-path rig: REAL MemberSim state machine (grid + navigation +
## catalog + entrance/exit) with the REAL Economy wired via _post_init() so
## the member_completed_visit signal reaches the ledger. base_arrival_rate =
## 0 so no natural spawn interferes (all members injected).
func _make_member_rig(seed: int) -> Dictionary:
	var gs: RefCounted = _GS().new()
	gs.call("init", GRID_W, GRID_H)
	for y in GRID_H:
		for x in GRID_W:
			gs.call("set_buildable", Vector2i(x, y), true)
	gs.call("freeze_buildable")
	var nav: RefCounted = _NAV().new()
	nav.call("init", gs)
	nav.call("_post_init")
	var cat: RefCounted = _ECAT().new()
	var fp: Array[Vector2i] = [Vector2i(0, 0)]
	var ac: Array[Vector2i] = [Vector2i(1, 0)]
	var effects: Array[Dictionary] = []
	var def = _ED().new("treadmill", "Treadmill", ["cardio"], fp, ac, 100, "", effects, 200, 35, 100, 300)
	cat.call("_add_definition", def)
	cat.call("_freeze")

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


## Injects a quota-met LEAVING member (the S5-firing departure path).
func _inject_quota_met_leaving(rig: Dictionary, member_id: int) -> void:
	var m := {
		"member_id": member_id,
		"state": "LEAVING",
		"cell": Vector2i(1, 1),
		"exercises_done": 2,
		"exercises_per_visit": 2,
		"preference_profile": {"preference_noise": 1.0},
		"target_equipment_instance_id": -1,
		"cached_path": [],
		"leaving_timeout_ticks": 300,
		"leaving_reason": "quota_met",
	}
	(rig["member_sim"].get("members") as Array).append(m)


func _member_count(rig: Dictionary) -> int:
	return (rig["member_sim"].get("members") as Array).size()


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


# === AC7: no satisfaction dependency (structural check) ===

func _test_ac7_no_satisfaction_dependency() -> void:
	print("\n[AC7] throwing satisfaction double attached — N revenue accruals NEVER touch any satisfaction accessor")
	# N = 0
	var rig := _make_economy_rig(0xAC7000)
	var dbl := _attach_throwing_satisfaction(rig)
	_check(int(dbl.get("reads")) == 0, "AC7[N=0]: no accrual, satisfaction reads == 0 (got %d)" % int(dbl.get("reads")))
	_check(int(rig["economy"].get("balance")) == 500, "AC7[N=0]: balance == starting_capital == 500 (got %d)" % int(rig["economy"].get("balance")))

	# N = 1
	rig["economy"].call("on_member_completed_visit", 1001)
	_check(int(dbl.get("reads")) == 0, "AC7[N=1]: after 1 accrual, satisfaction reads == 0 (got %d)" % int(dbl.get("reads")))
	_check(int(rig["economy"].get("balance")) == 512, "AC7[N=1]: balance == 500 + 1×12 == 512 (got %d)" % int(rig["economy"].get("balance")))

	# N = many (100 more -> 101 total)
	for i in 100:
		rig["economy"].call("on_member_completed_visit", 2000 + i)
	_check(int(dbl.get("reads")) == 0, "AC7[N=many]: after 101 accruals total, satisfaction reads == 0 (got %d)" % int(dbl.get("reads")))
	_check(int(rig["economy"].get("balance")) == 500 + 101 * 12,
		"AC7[N=many]: balance == starting_capital + 101×R_visit == 1712 (got %d)" % int(rig["economy"].get("balance")))

	# Also assert the SECOND accessor is covered by the same no-touch guarantee
	# (a double whose modifier getter is the only thrower).
	var rig2 := _make_economy_rig(0xAC7001)
	var dbl2 := _attach_throwing_satisfaction(rig2)
	for i in 5:
		rig2["economy"].call("on_member_completed_visit", 3000 + i)
	_check(int(dbl2.get("reads")) == 0, "AC7[edge]: both accessors untouched after 5 accruals (reads == %d)" % int(dbl2.get("reads")))
	_check(int(rig2["economy"].get("balance")) == 560, "AC7[edge]: balance == 500 + 5×12 == 560 (got %d)" % int(rig2["economy"].get("balance")))


func _test_ac7_s5_path_no_satisfaction() -> void:
	print("\n[AC7/S5] real MemberSim quota-met departure -> S5 -> Economy: satisfaction double never read end-to-end")
	var rig := _make_member_rig(0xAC7002)
	var dbl := _attach_throwing_satisfaction(rig)
	_inject_quota_met_leaving(rig, 100)
	_run_ticks(rig, 40)  # walk to exit (7,5) and despawn -> S5 fires
	_check(_member_count(rig) == 0, "AC7/S5: member despawned via quota-met path")
	_check(int(rig["economy"].get("balance")) == 512, "AC7/S5: balance == 512 after S5 revenue (got %d)" % int(rig["economy"].get("balance")))
	_check(int(dbl.get("reads")) == 0, "AC7/S5: satisfaction reads == 0 across the full MemberSim→Economy revenue chain (got %d)" % int(dbl.get("reads")))


# === AC15: progress never locks (integration, advisory) ===

func _test_ac15_progress_never_locks() -> void:
	print("\n[AC15] balance = 0 -> one member_completed_visit -> balance == R_visit; can_afford(R_visit) true")
	# Given: balance = 0 (via config starting_capital 0).
	var rig := _make_economy_rig(0xAC1500, {"starting_capital": 0})
	_check(int(rig["economy"].get("balance")) == 0, "AC15: balance == 0 (got %d)" % int(rig["economy"].get("balance")))
	# When: one member_completed_visit processed directly.
	rig["economy"].call("on_member_completed_visit", 1)
	_check(int(rig["economy"].get("balance")) == 12, "AC15: balance == R_visit == 12 (got %d)" % int(rig["economy"].get("balance")))
	if rig["economy"].has_method("can_afford"):
		_check(bool(rig["economy"].call("can_afford", 12)), "AC15: can_afford(R_visit) == true (ECON-002 landed)")
	else:
		print("  SKIP: can_afford() not yet landed (story ECON-002 parallel worktree) — balance==R_visit asserted")

	# Edge: after spend to zero.
	var rig2 := _make_economy_rig(0xAC1501)
	_check(bool(rig2["economy"].call("spend", 500)), "AC15[edge]: spend(500) drains balance to 0")
	_check(int(rig2["economy"].get("balance")) == 0, "AC15[edge]: balance == 0 (got %d)" % int(rig2["economy"].get("balance")))
	rig2["economy"].call("on_member_completed_visit", 2)
	_check(int(rig2["economy"].get("balance")) == 12, "AC15[edge]: after spend-to-zero, one accrual -> balance == 12 (got %d)" % int(rig2["economy"].get("balance")))
	if rig2["economy"].has_method("can_afford"):
		_check(bool(rig2["economy"].call("can_afford", 12)), "AC15[edge]: can_afford(R_visit) == true after recovery")

	# Edge: after multiple accruals.
	var rig3 := _make_economy_rig(0xAC1502, {"starting_capital": 0})
	rig3["economy"].call("on_member_completed_visit", 3)
	rig3["economy"].call("on_member_completed_visit", 4)
	_check(int(rig3["economy"].get("balance")) == 24, "AC15[edge]: 2 accruals from zero -> balance == 2×R_visit == 24 (got %d)" % int(rig3["economy"].get("balance")))
	if rig3["economy"].has_method("can_afford"):
		_check(bool(rig3["economy"].call("can_afford", 12)), "AC15[edge]: can_afford(R_visit) == true after multiple accruals")


# === ADR-0006 §1: credit() contract ===

func _test_credit_success_emits_signal() -> void:
	print("\n[credit] amount > 0 -> true, balance += amount, balance_changed(new, +amount) fires exactly once")
	var rig := _make_economy_rig(0xEC0300)
	var seen := _spy_balance_changed(rig["economy"])
	var ok: bool = rig["economy"].call("credit", 100, "sell:instance_5")
	_check(ok, "credit(100, 'sell:instance_5') returns true")
	_check(int(rig["economy"].get("balance")) == 600, "balance == 500 + 100 == 600 (got %d)" % int(rig["economy"].get("balance")))
	_check(seen.size() == 1, "exactly one balance_changed emission (got %d)" % seen.size())
	if seen.size() == 1:
		_check(int(seen[0][0]) == 600, "payload new_balance == 600 (got %d)" % int(seen[0][0]))
		_check(int(seen[0][1]) == 100, "payload delta == +amount == +100 (got %d)" % int(seen[0][1]))
	_check(int(seen[0][1]) > 0, "delta is positive (got %d)" % int(seen[0][1]))

	# Larger credit: 250 -> 850.
	var ok2: bool = rig["economy"].call("credit", 250, "milestone")
	_check(ok2 and int(rig["economy"].get("balance")) == 850, "credit(250) -> balance == 850 (got %d)" % int(rig["economy"].get("balance")))
	_check(seen.size() == 2, "two emissions total (got %d)" % seen.size())
	if seen.size() == 2:
		_check(int(seen[1][0]) == 850 and int(seen[1][1]) == 250, "2nd: new=850 delta=+250 (got %s)" % str(seen[1]))


func _test_credit_reason_audit_only() -> void:
	print("\n[credit] reason is audit-only — different labels produce identical balance behavior")
	var rig := _make_economy_rig(0xEC0301)
	var ok_a: bool = rig["economy"].call("credit", 40, "sell:instance_1")
	var ok_b: bool = rig["economy"].call("credit", 40, "debug:give_money")
	var ok_c: bool = rig["economy"].call("credit", 40, "")
	_check(ok_a and ok_b and ok_c, "credit succeeds with sell/debug/empty reason labels")
	_check(int(rig["economy"].get("balance")) == 620, "balance == 500 + 3×40 == 620 regardless of reason (got %d)" % int(rig["economy"].get("balance")))


func _test_credit_zero_negative_rejected() -> void:
	print("\n[credit] amount <= 0 rejected: false, balance unchanged, NO signal, push_warning logged")
	var rig := _make_economy_rig(0xEC0302)
	var seen := _spy_balance_changed(rig["economy"])
	_check(not bool(rig["economy"].call("credit", 0, "zero")), "credit(0, ...) returns false")
	_check(not bool(rig["economy"].call("credit", -100, "negative")), "credit(-100, ...) returns false")
	_check(int(rig["economy"].get("balance")) == 500, "balance unchanged at 500 (got %d)" % int(rig["economy"].get("balance")))
	_check(seen.is_empty(), "NO balance_changed fired for rejected credits (got %d)" % seen.size())
	# Edge: boundary — credit(1) succeeds right after rejections (gate is > 0, not >= 1 quirk).
	var ok: bool = rig["economy"].call("credit", 1, "boundary")
	_check(ok and int(rig["economy"].get("balance")) == 501, "credit(1) succeeds after rejections (got %d)" % int(rig["economy"].get("balance")))


func _test_spend_credit_symmetry() -> void:
	print("\n[credit/spend] symmetry: spend(200) then credit(50) -> net -150, two signals with opposite deltas")
	var rig := _make_economy_rig(0xEC0303)
	var seen := _spy_balance_changed(rig["economy"])
	_check(bool(rig["economy"].call("spend", 200)), "spend(200) succeeds")
	_check(int(rig["economy"].get("balance")) == 300, "balance == 300 after spend (got %d)" % int(rig["economy"].get("balance")))
	var ok: bool = rig["economy"].call("credit", 50, "refund")
	_check(ok, "credit(50, 'refund') succeeds")
	_check(int(rig["economy"].get("balance")) == 350, "balance == 350 after credit (got %d)" % int(rig["economy"].get("balance")))
	_check(seen.size() == 2, "exactly two balance_changed emissions (got %d)" % seen.size())
	if seen.size() == 2:
		_check(int(seen[0][1]) == -200, "1st delta == -200 (spend, got %d)" % int(seen[0][1]))
		_check(int(seen[1][1]) == +50, "2nd delta == +50 (credit, got %d)" % int(seen[1][1]))


func _test_credit_coexists_with_visit_revenue() -> void:
	print("\n[credit/revenue] member_completed_visit (+12) and credit(100) -> +112 total, one signal per path")
	var rig := _make_economy_rig(0xEC0304)
	var seen := _spy_balance_changed(rig["economy"])
	rig["economy"].call("on_member_completed_visit", 77)
	var ok: bool = rig["economy"].call("credit", 100, "refund")
	_check(ok, "credit(100) succeeds alongside visit revenue")
	_check(int(rig["economy"].get("balance")) == 612, "balance == 500 + 12 + 100 == 612 (got %d)" % int(rig["economy"].get("balance")))
	_check(seen.size() == 2, "two emissions — one per path (got %d)" % seen.size())
	if seen.size() == 2:
		_check(int(seen[0][1]) == 12 and int(seen[1][1]) == 100, "deltas == +12 (visit) then +100 (credit) (got %s)" % str(seen))


# === Forbidden workaround + refund ownership ===

func _test_spend_negative_not_credit() -> void:
	print("\n[forbidden] spend(-refund) as a credit workaround is structurally blocked")
	var rig := _make_economy_rig(0xEC0305)
	var seen := _spy_balance_changed(rig["economy"])
	_check(not bool(rig["economy"].call("spend", -100)), "spend(-100) returns false (spend's amount <= 0 gate)")
	_check(int(rig["economy"].get("balance")) == 500, "balance unchanged at 500 (got %d)" % int(rig["economy"].get("balance")))
	_check(seen.is_empty(), "NO balance_changed fired (got %d)" % seen.size())


func _test_no_refund_formula_in_economy() -> void:
	print("\n[ownership] Economy carries NO refund formula / equipment-price knowledge (ADR-0006 §3)")
	var script := _EC()
	# Structural checks on EXECUTABLE code lines (comments may legitimately
	# document the ADR ownership rule — raw-string scans would trip on them).
	var leaked: Array[String] = []
	for line in (script as Script).source_code.split("\n"):
		var trimmed := line.strip_edges()
		if trimmed.is_empty() or trimmed.begins_with("#"):
			continue  # comment/doc line — not executable
		if trimmed.contains("REFUND_RATE") or trimmed.contains("0.5") or trimmed.contains("equipment_cost"):
			leaked.append(trimmed)
	_check(leaked.is_empty(), "no executable line references REFUND_RATE / 0.5 / equipment_cost (leaked: %s)" % str(leaked))
	_check(not (script as Script).get_script_constant_map().has("REFUND_RATE"), "script declares no REFUND_RATE constant")
	var method_names: Array[String] = []
	for m in (script as Script).get_script_method_list():
		method_names.append(String(m.get("name", "")))
	_check(not method_names.has("refund"), "Economy exposes no refund() method (methods: %s)" % str(method_names))
	var rig := _make_economy_rig(0xEC0306)
	_check(not rig["economy"].has_method("refund"), "Economy instance exposes no refund() method")
	# Economy accepts whatever amount the caller provides (SelectionSystem owns
	# floor(0.5 × cost)); a sell-style credit of 100 for a $200 machine works.
	var ok: bool = rig["economy"].call("credit", 100, "sell:instance_7")
	_check(ok and int(rig["economy"].get("balance")) == 600, "credit(100) — the SelectionSystem-computed refund amount — lands (got %d)" % int(rig["economy"].get("balance")))
