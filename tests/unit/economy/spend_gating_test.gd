# tests/unit/economy/spend_gating_test.gd
# Story ECON-002: spend() and can_afford Triple-Gating
# (production/epics/economy/story-002-spend-can-afford-triple-gating.md)
#
# Covers the BLOCKING ACs (TR-ECON-006, per the story QA test cases):
#   - AC2   overspend rejection: spend(amount) with amount > balance ->
#           false, balance unchanged, NO balance_changed fires.
#           Edge: amount = balance + 1; amount = balance + huge.
#   - AC3   zero/negative rejection: spend(0) / spend(-1) / spend(-100) ->
#           false, balance unchanged, NO balance_changed (prevents the
#           negative-amount exploit where spend(-100) would INCREASE balance).
#   - AC4   spend success: spend(amount) with 0 < amount <= balance -> true,
#           balance -= amount, balance_changed(new, -amount) fires exactly once.
#           Edge: spend exact balance -> balance 0; multiple spends.
#   - AC5   can_afford consistency: can_afford(amount) true -> subsequent
#           spend succeeds; false -> fails. can_afford(0) / can_afford(-1)
#           return false. Edge: balance change between can_afford and spend
#           (intervening income/spend).
#
# Also pins the triple-gating contract (GDD Core Rule 5 / ADR-0006):
#   (a) amount > 0, (b) amount <= balance, (c) Shop pre-check via
#   can_afford() — defense in depth; can_afford is a PURE query (no mutation,
#   no signal).
# Forbidden: spend(-refund) as a credit workaround — spend() rejects
# amount <= 0, so a negative "refund" call is a no-op, never a balance
# increase (credit() lands in Story 003).
#
# Run standalone: godot --headless --script tests/unit/economy/spend_gating_test.gd
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
	print("  UNIT TEST: Economy — spend() and can_afford Triple-Gating (Story ECON-002)")
	print("=".repeat(48))

	_test_ac2_overspend_rejected()
	_test_ac2_overspend_edges()
	_test_ac3_zero_negative_rejected()
	_test_ac4_spend_success()
	_test_ac4_exact_balance_to_zero()
	_test_ac4_multiple_spends()
	_test_ac5_can_afford_consistency()
	_test_ac5_afford_boundary_and_invalid()
	_test_ac5_intervening_change()
	_test_triple_gating_defense_in_depth()
	_test_forbidden_negative_refund_credit()

	print("\n=== SPEND GATING TEST: %d passed, %d failed ===\n" % [_pass, _fail])
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


## Creates an initialized SimulationOrchestrator in the scene tree (delivers
## _ready() synchronously — same pattern as the save-load integration tests).
func _make_orchestrator() -> Node:
	var orch: Node = load("res://src/systems/simulation_orchestrator.gd").new()
	root.add_child(orch)
	orch.call("_ready")
	return orch


## Builds a bare Economy unit rig: real orchestrator + SeededRNG + real
## Economy init'd with the default config (starting_capital 500, r_visit 12).
func _make_economy_rig(seed: int = 0xEC0202) -> Dictionary:
	var srg: RefCounted = _SRG().new()
	srg.call("init", seed)
	var orch := _make_orchestrator()
	var econ: RefCounted = _EC().new()
	econ.call("init", orch, srg)
	orch.set("economy", econ)
	return {"orchestrator": orch, "seeded_rng": srg, "economy": econ}


## Connects a spy to economy.balance_changed, recording every emission as
## [new_balance, delta]. Returns the record array.
func _spy_balance_changed(econ: RefCounted) -> Array:
	var seen: Array = []
	econ.balance_changed.connect(func(new_balance: int, delta: int) -> void: seen.append([new_balance, delta]))
	return seen


# === AC2: overspend rejection ===

func _test_ac2_overspend_rejected() -> void:
	print("\n[AC2] spend(amount > balance) -> false, balance unchanged, NO balance_changed")
	var rig := _make_economy_rig(0xEC0202)
	var econ: RefCounted = rig["economy"]
	var seen := _spy_balance_changed(econ)

	var before := int(econ.get("balance"))
	_check(not bool(econ.call("spend", before + 1)), "AC2: spend(balance+1) returns false")
	_check(int(econ.get("balance")) == before, "AC2: balance unchanged at %d (got %d)" % [before, int(econ.get("balance"))])
	_check(seen.is_empty(), "AC2: NO balance_changed fired (got %d)" % seen.size())

	# Also overspend from a drained balance (the QA's never-negative path).
	_check(bool(econ.call("spend", before)), "AC2[setup]: drain exact balance succeeds")
	_check(int(econ.get("balance")) == 0, "AC2[setup]: balance now 0 (got %d)" % int(econ.get("balance")))
	var seen2 := _spy_balance_changed(econ)
	_check(not bool(econ.call("spend", 1)), "AC2: balance=0 then spend(1) returns false")
	_check(int(econ.get("balance")) == 0, "AC2: balance stays 0 (got %d)" % int(econ.get("balance")))
	_check(seen2.is_empty(), "AC2: overspend at 0 emits NO balance_changed (got %d)" % seen2.size())


func _test_ac2_overspend_edges() -> void:
	print("\n[AC2 edge] amount = balance + 1; amount = balance + huge — both rejected identically")
	var rig := _make_economy_rig(0xEC0203)
	var econ: RefCounted = rig["economy"]
	var seen := _spy_balance_changed(econ)

	var before := int(econ.get("balance"))  # 500
	_check(not bool(econ.call("spend", before + 1)), "AC2[edge]: spend(balance+1 = 501) returns false")
	_check(not bool(econ.call("spend", before + 1000000)), "AC2[edge]: spend(balance + huge) returns false")
	_check(int(econ.get("balance")) == before, "AC2[edge]: balance unchanged at %d (got %d)" % [before, int(econ.get("balance"))])
	_check(seen.is_empty(), "AC2[edge]: no balance_changed after BOTH overspend attempts (got %d)" % seen.size())


# === AC3: zero/negative rejection ===

func _test_ac3_zero_negative_rejected() -> void:
	print("\n[AC3] spend(0) / spend(-1) / spend(-100) -> false, balance unchanged, NO balance_changed")
	var rig := _make_economy_rig(0xEC0204)
	var econ: RefCounted = rig["economy"]
	var seen := _spy_balance_changed(econ)

	var before := int(econ.get("balance"))
	_check(not bool(econ.call("spend", 0)), "AC3: spend(0) returns false")
	_check(not bool(econ.call("spend", -1)), "AC3: spend(-1) returns false")
	_check(not bool(econ.call("spend", -100)), "AC3: spend(-100) returns false")
	_check(int(econ.get("balance")) == before, "AC3: balance unchanged at %d (got %d)" % [before, int(econ.get("balance"))])
	_check(seen.is_empty(), "AC3: NO balance_changed for any rejected spend (got %d)" % seen.size())

	# Same rejections hold after income — gates are state-independent on sign.
	econ.call("on_member_completed_visit", 9001)  # +12 -> 512
	var before2 := int(econ.get("balance"))
	var seen2 := _spy_balance_changed(econ)
	_check(not bool(econ.call("spend", 0)), "AC3: spend(0) still rejected after income")
	_check(not bool(econ.call("spend", -512)), "AC3: spend(-balance) still rejected after income")
	_check(int(econ.get("balance")) == before2, "AC3: balance unchanged at %d after rejections (got %d)" % [before2, int(econ.get("balance"))])
	_check(seen2.is_empty(), "AC3: still no balance_changed for rejected spends (got %d)" % seen2.size())


# === AC4: spend success ===

func _test_ac4_spend_success() -> void:
	print("\n[AC4] spend(amount) 0 < amount <= balance -> true, balance -= amount, balance_changed(new, -amount) once")
	var rig := _make_economy_rig(0xEC0205)
	var econ: RefCounted = rig["economy"]
	var seen := _spy_balance_changed(econ)

	var before := int(econ.get("balance"))  # 500
	_check(bool(econ.call("spend", 200)), "AC4: spend(200) returns true")
	_check(int(econ.get("balance")) == before - 200, "AC4: balance == %d after spend(200) (got %d)" % [before - 200, int(econ.get("balance"))])
	_check(seen.size() == 1, "AC4: exactly one balance_changed (got %d)" % seen.size())
	if seen.size() == 1:
		_check(int(seen[0][0]) == before - 200, "AC4: payload new_balance == %d (got %d)" % [before - 200, int(seen[0][0])])
		_check(int(seen[0][1]) == -200, "AC4: payload delta == -200 (got %d)" % int(seen[0][1]))


func _test_ac4_exact_balance_to_zero() -> void:
	print("\n[AC4 edge] spend exact balance -> true, balance 0, one balance_changed(new=0, -balance)")
	var rig := _make_economy_rig(0xEC0206)
	var econ: RefCounted = rig["economy"]
	var seen := _spy_balance_changed(econ)

	var before := int(econ.get("balance"))  # 500
	_check(bool(econ.call("spend", before)), "AC4[edge]: spend(exact balance) returns true")
	_check(int(econ.get("balance")) == 0, "AC4[edge]: balance == 0 (got %d)" % int(econ.get("balance")))
	_check(seen.size() == 1, "AC4[edge]: exactly one balance_changed (got %d)" % seen.size())
	if seen.size() == 1:
		_check(int(seen[0][0]) == 0, "AC4[edge]: payload new_balance == 0 (got %d)" % int(seen[0][0]))
		_check(int(seen[0][1]) == -before, "AC4[edge]: payload delta == -%d (got %d)" % [before, int(seen[0][1])])


func _test_ac4_multiple_spends() -> void:
	print("\n[AC4 edge] multiple sequential spends -> each true, one balance_changed per spend")
	var rig := _make_economy_rig(0xEC0207)
	var econ: RefCounted = rig["economy"]
	var seen := _spy_balance_changed(econ)

	_check(bool(econ.call("spend", 100)), "AC4[multi]: spend(100) #1 true")
	_check(bool(econ.call("spend", 250)), "AC4[multi]: spend(250) #2 true")
	_check(int(econ.get("balance")) == 150, "AC4[multi]: balance == 150 after 500-100-250 (got %d)" % int(econ.get("balance")))
	_check(seen.size() == 2, "AC4[multi]: exactly two balance_changed (got %d)" % seen.size())
	if seen.size() == 2:
		_check(int(seen[0][0]) == 400 and int(seen[0][1]) == -100, "AC4[multi]: 1st (new=400, delta=-100) got %s" % str(seen[0]))
		_check(int(seen[1][0]) == 150 and int(seen[1][1]) == -250, "AC4[multi]: 2nd (new=150, delta=-250) got %s" % str(seen[1]))


# === AC5: can_afford consistency ===

func _test_ac5_can_afford_consistency() -> void:
	print("\n[AC5] can_afford true -> subsequent spend succeeds; false -> fails")
	var rig := _make_economy_rig(0xEC0208)
	var econ: RefCounted = rig["economy"]

	# can_afford true -> spend succeeds (no intervening change).
	_check(bool(econ.call("can_afford", 300)), "AC5: can_afford(300) true at balance 500")
	_check(bool(econ.call("spend", 300)), "AC5: subsequent spend(300) succeeds")
	_check(int(econ.get("balance")) == 200, "AC5: balance == 200 (got %d)" % int(econ.get("balance")))

	# can_afford false -> spend fails, balance unchanged, no signal.
	var seen := _spy_balance_changed(econ)
	_check(not bool(econ.call("can_afford", 201)), "AC5: can_afford(201) false at balance 200")
	_check(not bool(econ.call("spend", 201)), "AC5: subsequent spend(201) fails")
	_check(int(econ.get("balance")) == 200, "AC5: balance unchanged at 200 (got %d)" % int(econ.get("balance")))
	_check(seen.is_empty(), "AC5: failed pre-checked spend emits NO balance_changed (got %d)" % seen.size())


func _test_ac5_afford_boundary_and_invalid() -> void:
	print("\n[AC5 edge] exact-boundary can_afford; can_afford(0) and can_afford(-1) false")
	var rig := _make_economy_rig(0xEC0209)
	var econ: RefCounted = rig["economy"]

	_check(bool(econ.call("can_afford", 500)), "AC5[edge]: can_afford(exact balance 500) true")
	_check(not bool(econ.call("can_afford", 501)), "AC5[edge]: can_afford(501) false at 500")
	_check(not bool(econ.call("can_afford", 0)), "AC5[edge]: can_afford(0) false")
	_check(not bool(econ.call("can_afford", -1)), "AC5[edge]: can_afford(-1) false")
	_check(not bool(econ.call("can_afford", -100)), "AC5[edge]: can_afford(-100) false")
	# Pure query — no mutation, no signal.
	_check(int(econ.get("balance")) == 500, "AC5[edge]: can_afford calls never mutate balance (got %d)" % int(econ.get("balance")))


func _test_ac5_intervening_change() -> void:
	print("\n[AC5 edge] balance change between can_afford and spend (intervening income/spend)")
	var rig := _make_economy_rig(0xEC020A)
	var econ: RefCounted = rig["economy"]

	# Intervening income: can_afford false at 500, income crosses the line -> true, spend succeeds.
	_check(not bool(econ.call("can_afford", 510)), "AC5[inter]: can_afford(510) false at 500")
	econ.call("on_member_completed_visit", 9002)  # +12 -> 512
	_check(bool(econ.call("can_afford", 510)), "AC5[inter]: after +12 income, can_afford(510) true at 512")
	_check(bool(econ.call("spend", 510)), "AC5[inter]: spend(510) succeeds after income")
	_check(int(econ.get("balance")) == 2, "AC5[inter]: balance == 2 (got %d)" % int(econ.get("balance")))

	# Intervening spend: can_afford true at 500, a spend drains below -> spend now fails.
	var rig2 := _make_economy_rig(0xEC020B)
	var econ2: RefCounted = rig2["economy"]
	_check(bool(econ2.call("can_afford", 300)), "AC5[inter]: can_afford(300) true at 500 (rig2)")
	_check(bool(econ2.call("spend", 400)), "AC5[inter]: intervening spend(400) succeeds -> 100")
	_check(not bool(econ2.call("spend", 300)), "AC5[inter]: later spend(300) fails at balance 100")
	_check(int(econ2.get("balance")) == 100, "AC5[inter]: balance unchanged at 100 (got %d)" % int(econ2.get("balance")))


# === Triple-gating contract ===

func _test_triple_gating_defense_in_depth() -> void:
	print("\n[triple-gate] (a) amount > 0, (b) amount <= balance, (c) can_afford pre-check — all three gates")
	var rig := _make_economy_rig(0xEC020C)
	var econ: RefCounted = rig["economy"]

	# Gate (a): non-positive rejected before affordability is even consulted.
	_check(not bool(econ.call("spend", 0)), "gate(a): spend(0) rejected")
	_check(not bool(econ.call("spend", -1)), "gate(a): spend(-1) rejected")
	# Gate (b): overspend rejected.
	_check(not bool(econ.call("spend", 501)), "gate(b): spend(501) rejected at 500")
	# Gate (c): the Shop-style pre-check chain — can_afford false means the
	# caller should never call spend; if it does anyway, gate (b) still holds.
	var afford_ok := bool(econ.call("can_afford", 200))
	var spend_ok := bool(econ.call("spend", 200))
	_check(afford_ok and spend_ok, "gate(c): can_afford(200) true -> spend(200) true (defense-in-depth chain)")
	_check(int(econ.get("balance")) == 300, "gate(c): balance == 300 after chained purchase (got %d)" % int(econ.get("balance")))
	_check(not bool(econ.call("can_afford", 301)) and not bool(econ.call("spend", 301)), "gate(c): can_afford(301) false at 300 -> spend(301) false")


func _test_forbidden_negative_refund_credit() -> void:
	print("\n[forbidden] spend(-refund) as credit workaround is a NO-OP — never increases balance")
	var rig := _make_economy_rig(0xEC020D)
	var econ: RefCounted = rig["economy"]
	var seen := _spy_balance_changed(econ)

	# A naive "refund via negative spend" would ADD money if the sign gate
	# were missing. ADR-0006 forbids it: credit() (Story 003) is the only
	# money-add path besides visit revenue.
	_check(not bool(econ.call("spend", -100)), "forbidden: spend(-100) returns false (negative-amount exploit blocked)")
	_check(int(econ.get("balance")) == 500, "forbidden: balance NOT increased — still 500 (got %d)" % int(econ.get("balance")))
	_check(seen.is_empty(), "forbidden: no balance_changed fired for the rejected refund attempt (got %d)" % seen.size())
