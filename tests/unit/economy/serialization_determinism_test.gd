# tests/unit/economy/serialization_determinism_test.gd
# Story ECON-004: Serialization, Determinism and No-Decay
# (production/epics/economy/story-004-serialization-determinism-no-decay.md)
#
# Covers the BLOCKING ACs (TR-ECON-007/009, per the story QA test cases):
#   - AC6   deterministic accrual: a fixed array of member_completed_visit
#           payloads fed directly into Economy.on_member_completed_visit() in
#           two SEPARATE Economy instances -> identical balance trace.
#           Edge: mixed payload order; interleaved spend calls.
#   - AC10  no decay / no upkeep: a period with zero departures and no spend
#           -> ticks advance -> balance UNCHANGED (never decays).
#           Edge: many idle ticks; pause/resume (tick bursts with gaps).
#   - AC12  serialization round-trip: ANY balance -> serialize -> reload ->
#           identical (int, no reconstruction ambiguity); the NEXT accrual
#           matches uninterrupted play.
#           Edge: balance 0, balance 500 (starting), balance after many
#           accruals + spends.
#
# Plus the schema-change contract (story Exit Conditions):
#   - serialize() emits ONLY {balance: int} — the stub-era keys {counter,
#     rng_state} are GONE (GDD Core Rule 7).
#   - two-phase deserialize: validate_only passes with ZERO mutation;
#     missing balance / wrong type / fractional float fail loudly
#     (no invented defaults).
#   - JSON round-trip (JSON.stringify full_precision -> parse -> deserialize)
#     coerces a saved int balance arriving as float (4.7.1 JSON ints are
#     floats) back to int exactly.
#   - stub-era blob {counter, balance, rng_state} STILL LOADS (backward
#     compat coordinated with the save-load integration tests) — the real
#     system tolerates the old keys and commits balance only.
#   - S6 balance_changed(new, delta) fires after every balance mutation with
#     a signed delta (spot-checked on the post-reload accrual path).
#
# Run standalone: godot --headless --script tests/unit/economy/serialization_determinism_test.gd
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
	print("  UNIT TEST: Economy — Serialization, Determinism & No-Decay (Story ECON-004)")
	print("=".repeat(48))

	_test_ac6_deterministic_accrual_two_instances()
	_test_ac6_edge_mixed_order_and_interleaved_spend()
	_test_ac10_no_decay_many_idle_ticks()
	_test_ac10_edge_pause_resume_bursts()
	_test_ac12_roundtrip_balance_edges()
	_test_ac12_next_accrual_matches_uninterrupted()
	_test_ac12_json_roundtrip_float_coercion()
	_test_schema_serialize_only_balance()
	_test_schema_two_phase_validate_zero_mutation()
	_test_schema_corrupt_payloads_fail()
	_test_schema_stub_era_blob_still_loads()

	print("\n=== SERIALIZATION/DETERMINISM TEST: %d passed, %d failed ===\n" % [_pass, _fail])
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
## Each call is a FULLY SEPARATE instance (AC6's two-instance requirement).
func _make_economy_rig(seed: int = 0xEC004) -> Dictionary:
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


## Replays one operation (visit id, spend amount, or tick) against an
## Economy instance, appending the resulting balance to [trace].
func _apply_op(econ: RefCounted, trace: Array, op: Dictionary) -> void:
	var kind: String = op["kind"]
	if kind == "visit":
		econ.call("on_member_completed_visit", int(op["id"]))
	elif kind == "spend":
		econ.call("spend", int(op["amount"]))
	elif kind == "credit":
		econ.call("credit", int(op["amount"]), "test")
	elif kind == "tick":
		econ.call("on_tick", int(op["tick"]))
	trace.append(int(econ.get("balance")))


# === AC6: deterministic accrual ===

func _test_ac6_deterministic_accrual_two_instances() -> void:
	print("\n[AC6] fixed member_completed_visit payload array fed to TWO separate Economy instances -> identical balance trace")
	var payloads: Array = [
		{"id": 101}, {"id": 202}, {"id": 303}, {"id": 404}, {"id": 505},
		{"id": 606}, {"id": 707}, {"id": 808}, {"id": 909}, {"id": 1000},
	]
	var rig_a := _make_economy_rig(0xEC0406)
	var rig_b := _make_economy_rig(0xEC0406)
	var trace_a: Array = []
	var trace_b: Array = []

	for p in payloads:
		_apply_op(rig_a["economy"], trace_a, {"kind": "visit", "id": int(p["id"])})
	for p in payloads:
		_apply_op(rig_b["economy"], trace_b, {"kind": "visit", "id": int(p["id"])})

	_check(trace_a == trace_b, "AC6: identical balance trace across two instances (trace: %s)" % str(trace_a))
	_check(trace_a == [512, 524, 536, 548, 560, 572, 584, 596, 608, 620],
		"AC6: trace is exactly 500 + N×12 (got %s)" % str(trace_a))
	_check(int(rig_a["economy"].get("balance")) == int(rig_b["economy"].get("balance")),
		"AC6: final balances equal (%d)" % int(rig_a["economy"].get("balance")))


func _test_ac6_edge_mixed_order_and_interleaved_spend() -> void:
	print("\n[AC6 edge] mixed payload order + interleaved spend calls -> identical traces")
	var ops_a: Array = [
		{"kind": "visit", "id": 1}, {"kind": "visit", "id": 2},
		{"kind": "spend", "amount": 100}, {"kind": "visit", "id": 3},
		{"kind": "visit", "id": 4}, {"kind": "spend", "amount": 250},
		{"kind": "visit", "id": 5}, {"kind": "credit", "amount": 50},
		{"kind": "visit", "id": 6}, {"kind": "spend", "amount": 30},
	]
	var ops_b: Array = [
		{"kind": "visit", "id": 2}, {"kind": "spend", "amount": 100},
		{"kind": "visit", "id": 1}, {"kind": "visit", "id": 4},
		{"kind": "visit", "id": 3}, {"kind": "spend", "amount": 250},
		{"kind": "credit", "amount": 50}, {"kind": "visit", "id": 6},
		{"kind": "visit", "id": 5}, {"kind": "spend", "amount": 30},
	]
	var rig_a := _make_economy_rig(0xEC0407)
	var rig_b := _make_economy_rig(0xEC0407)
	var trace_a: Array = []
	var trace_b: Array = []

	for op in ops_a:
		_apply_op(rig_a["economy"], trace_a, op)
	for op in ops_b:
		_apply_op(rig_b["economy"], trace_b, op)

	# Different orders give different INTERMEDIATE traces but the SAME final
	# balance (commutative sum — AC9). Both instances stay self-consistent:
	# each one's trace must match its own operation order exactly.
	var expected_a := [512, 524, 424, 436, 448, 198, 210, 260, 272, 242]
	var expected_b := [512, 412, 424, 436, 448, 198, 248, 260, 272, 242]
	_check(trace_a == expected_a, "AC6[edge]: instance A trace matches its op order (got %s)" % str(trace_a))
	_check(trace_b == expected_b, "AC6[edge]: instance B trace matches its op order (got %s)" % str(trace_b))
	_check(int(rig_a["economy"].get("balance")) == int(rig_b["economy"].get("balance")),
		"AC6[edge]: different op orders -> SAME final balance (%d) — commutative sum" % int(rig_a["economy"].get("balance")))


# === AC10: no decay / no upkeep ===

func _test_ac10_no_decay_many_idle_ticks() -> void:
	print("\n[AC10] zero departures + no spend -> 300 ticks -> balance UNCHANGED (never decays)")
	var rig := _make_economy_rig(0xEC0410)
	var econ: RefCounted = rig["economy"]
	var seen := _spy_balance_changed(econ)

	var before := int(econ.get("balance"))
	for i in 300:
		econ.call("on_tick", i)
	_check(int(econ.get("balance")) == before, "AC10: balance still %d after 300 idle ticks (got %d)" % [before, int(econ.get("balance"))])
	_check(seen.is_empty(), "AC10: NO balance_changed fired during idle ticks (got %d)" % seen.size())
	_check(int(econ.get("counter")) == 300, "AC10: counter still advances (runtime observable, got %d)" % int(econ.get("counter")))


func _test_ac10_edge_pause_resume_bursts() -> void:
	print("\n[AC10 edge] pause/resume: tick bursts separated by gaps -> balance unchanged throughout")
	var rig := _make_economy_rig(0xEC0411)
	var econ: RefCounted = rig["economy"]
	var before := int(econ.get("balance"))

	# Burst 1: 100 ticks. "Pause": a gap with no ticks (the sim is frozen).
	for i in 100:
		econ.call("on_tick", i)
	_check(int(econ.get("balance")) == before, "AC10[edge]: balance unchanged after burst 1 (got %d)" % int(econ.get("balance")))

	# Resume burst 2 after a long pause gap — no time passes, no decay.
	for i in 1000:
		econ.call("on_tick", 1000 + i)
	_check(int(econ.get("balance")) == before, "AC10[edge]: balance unchanged after 1000-tick resume burst (got %d)" % int(econ.get("balance")))

	# Even after a credit + spend (real mutations), idle ticks STILL don't decay.
	econ.call("credit", 100, "test")  # 600
	econ.call("spend", 100)           # 500
	var after_mutations := int(econ.get("balance"))
	for i in 50:
		econ.call("on_tick", 2000 + i)
	_check(int(econ.get("balance")) == after_mutations,
		"AC10[edge]: after credit+spend, idle ticks leave balance at %d (got %d)" % [after_mutations, int(econ.get("balance"))])


# === AC12: serialization round-trip ===

func _test_ac12_roundtrip_balance_edges() -> void:
	print("\n[AC12] balance 0 / 500 / after many accruals+spends -> serialize -> reload -> identical")
	var cases: Array = []

	# Case 1: balance 0 (drained).
	var rig0 := _make_economy_rig(0xEC0412)
	rig0["economy"].call("spend", 500)
	cases.append({"label": "balance 0", "rig": rig0, "balance": 0})

	# Case 2: balance 500 (fresh starting capital).
	var rig500 := _make_economy_rig(0xEC0413)
	cases.append({"label": "balance 500 (starting)", "rig": rig500, "balance": 500})

	# Case 3: many accruals + spends -> 500 + 25×12 - 180 - 90 = 530.
	var rigmany := _make_economy_rig(0xEC0414)
	for i in 25:
		rigmany["economy"].call("on_member_completed_visit", 1000 + i)
	rigmany["economy"].call("spend", 180)
	rigmany["economy"].call("credit", 90, "test")
	rigmany["economy"].call("spend", 180)
	cases.append({"label": "after 25 visits + spends/credits", "rig": rigmany, "balance": 530})

	for c in cases:
		var src: Dictionary = c["rig"]
		var expected: int = int(c["balance"])
		var payload: Dictionary = src["economy"].call("serialize")
		_check(int(payload["balance"]) == expected, "AC12[%s]: serialize() balance == %d (got %d)" % [c["label"], expected, int(payload["balance"])])

		var dst := _make_economy_rig(0xEC0415)
		var result: RefCounted = dst["economy"].call("deserialize", payload, false)
		_check(bool(result.get("ok")), "AC12[%s]: deserialize ok (errors: %s)" % [c["label"], str(result.get("errors"))])
		_check(int(dst["economy"].get("balance")) == expected,
			"AC12[%s]: reloaded balance identical (%d, got %d)" % [c["label"], expected, int(dst["economy"].get("balance"))])

		# Reloaded instance is not a fresh 500 — the value came from the save.
		var payload2: Dictionary = dst["economy"].call("serialize")
		_check(int(payload2["balance"]) == expected, "AC12[%s]: re-serialize after reload still %d (got %d)" % [c["label"], expected, int(payload2["balance"])])


func _test_ac12_next_accrual_matches_uninterrupted() -> void:
	print("\n[AC12] next accrual after reload matches uninterrupted play")
	# Build a session with a non-trivial balance, save, and replay the SAME
	# next event into (a) the uninterrupted original and (b) a reloaded clone.
	var rig_orig := _make_economy_rig(0xEC0416)
	for i in 10:
		rig_orig["economy"].call("on_member_completed_visit", 100 + i)
	rig_orig["economy"].call("spend", 60)  # 560
	var payload: Dictionary = rig_orig["economy"].call("serialize")
	_check(int(payload["balance"]) == 560, "AC12: session balance 560 before save (got %d)" % int(payload["balance"]))

	var rig_reloaded := _make_economy_rig(0xEC0417)
	var load_result: RefCounted = rig_reloaded["economy"].call("deserialize", payload, false)
	_check(bool(load_result.get("ok")), "AC12: reload ok (errors: %s)" % str(load_result.get("errors")))
	_check(int(rig_reloaded["economy"].get("balance")) == 560, "AC12: reloaded balance 560")

	# The SAME next event on both: quota-met visit -> +12, one signal each.
	var seen_orig := _spy_balance_changed(rig_orig["economy"])
	var seen_reload := _spy_balance_changed(rig_reloaded["economy"])
	rig_orig["economy"].call("on_member_completed_visit", 999)
	rig_reloaded["economy"].call("on_member_completed_visit", 999)

	_check(int(rig_orig["economy"].get("balance")) == int(rig_reloaded["economy"].get("balance")),
		"AC12: next accrual identical — uninterrupted %d == reloaded %d" % [int(rig_orig["economy"].get("balance")), int(rig_reloaded["economy"].get("balance"))])
	_check(int(rig_orig["economy"].get("balance")) == 572, "AC12: both at 572 (got %d)" % int(rig_orig["economy"].get("balance")))

	_check(seen_orig.size() == 1 and int(seen_orig[0][0]) == 572 and int(seen_orig[0][1]) == 12,
		"AC12: uninterrupted accrual emitted balance_changed(572, +12) once (got %s)" % str(seen_orig))
	_check(seen_reload.size() == 1 and int(seen_reload[0][0]) == 572 and int(seen_reload[0][1]) == 12,
		"AC12: reloaded accrual emitted balance_changed(572, +12) once (S6 after mutation — got %s)" % str(seen_reload))


func _test_ac12_json_roundtrip_float_coercion() -> void:
	print("\n[AC12 edge] JSON round-trip: stringify(full_precision) -> parse -> deserialize (4.7.1 ints arrive as floats)")
	var rig := _make_economy_rig(0xEC0418)
	for i in 7:
		rig["economy"].call("on_member_completed_visit", 200 + i)
	rig["economy"].call("spend", 50)  # 500 + 84 - 50 = 534
	var payload: Dictionary = rig["economy"].call("serialize")

	var json_str := JSON.stringify(payload, "  ", true, true)
	var parsed: Variant = JSON.parse_string(json_str)
	_check(parsed is Dictionary, "AC12[json]: JSON.parse_string returned a Dictionary")
	if not (parsed is Dictionary):
		return
	# 4.7.1 JSON.parse returns integer literals as FLOAT — assert the shape
	# we actually get so the coercion below is honest.
	var balance_field: Variant = (parsed as Dictionary)["balance"]
	_check(typeof(balance_field) == TYPE_FLOAT, "AC12[json]: parsed balance is float in 4.7.1 (got %s)" % type_string(typeof(balance_field)))
	_check(balance_field == 534.0, "AC12[json]: parsed balance value 534.0 (got %s)" % str(balance_field))

	var dst := _make_economy_rig(0xEC0419)
	var result: RefCounted = dst["economy"].call("deserialize", parsed, false)
	_check(bool(result.get("ok")), "AC12[json]: deserialize of JSON-parsed (float) payload ok (errors: %s)" % str(result.get("errors")))
	_check(int(dst["economy"].get("balance")) == 534, "AC12[json]: float balance coerced back to int 534 (got %d)" % int(dst["economy"].get("balance")))
	var re_payload: Dictionary = dst["economy"].call("serialize")
	_check(typeof(re_payload["balance"]) == TYPE_INT and int(re_payload["balance"]) == 534,
		"AC12[json]: re-serialize emits int 534 (no float drift)")


# === Schema change contract ===

func _test_schema_serialize_only_balance() -> void:
	print("\n[schema] serialize() emits ONLY {balance} — stub-era {counter, rng_state} GONE")
	var rig := _make_economy_rig(0xEC041A)
	for i in 3:
		rig["economy"].call("on_tick", i)
	var payload: Dictionary = rig["economy"].call("serialize")

	_check(payload.size() == 1, "schema: payload has exactly 1 key (got %d: %s)" % [payload.size(), str(payload.keys())])
	_check(payload.has("balance"), "schema: key 'balance' present")
	_check(not payload.has("counter"), "schema: stub-era 'counter' key ABSENT")
	_check(not payload.has("rng_state"), "schema: stub-era 'rng_state' key ABSENT")
	_check(typeof(payload["balance"]) == TYPE_INT, "schema: balance is int (got %s)" % type_string(typeof(payload["balance"])))


func _test_schema_two_phase_validate_zero_mutation() -> void:
	print("\n[schema] two-phase: validate_only passes with ZERO mutation")
	var rig := _make_economy_rig(0xEC041B)
	var econ: RefCounted = rig["economy"]
	econ.call("on_member_completed_visit", 1)  # 512
	var payload: Dictionary = econ.call("serialize")

	var before := int(econ.get("balance"))
	var vo: RefCounted = econ.call("deserialize", payload, true)
	_check(bool(vo.get("ok")), "schema: validate_only passes a valid payload")
	_check(int(econ.get("balance")) == before, "schema: validate_only left balance unmutated (%d)" % before)

	# Corrupt payload fails validate_only with ZERO mutation too.
	var corrupt: Dictionary = {"balance": "not-an-int"}
	var vo_bad: RefCounted = econ.call("deserialize", corrupt, true)
	_check(not bool(vo_bad.get("ok")), "schema: validate_only rejects corrupt payload")
	_check(int(econ.get("balance")) == before, "schema: corrupt validate_only left balance unmutated (%d)" % before)


func _test_schema_corrupt_payloads_fail() -> void:
	print("\n[schema] corrupt payloads fail loudly — no invented defaults")
	var rig := _make_economy_rig(0xEC041C)
	var econ: RefCounted = rig["economy"]
	var before := int(econ.get("balance"))

	# Missing balance.
	var no_balance: Dictionary = {}
	var r1: RefCounted = econ.call("deserialize", no_balance, false)
	_check(not bool(r1.get("ok")), "schema: missing 'balance' rejected")
	_check(str(r1.get("errors")).find("balance") != -1, "schema: error names 'balance'")

	# Wrong type (string).
	var str_balance: Dictionary = {"balance": "500"}
	_check(not bool(econ.call("deserialize", str_balance, false).get("ok")), "schema: string balance rejected")

	# Fractional float — whole currency units only (GDD Core Rule 1).
	var frac_balance: Dictionary = {"balance": 12.5}
	var r2: RefCounted = econ.call("deserialize", frac_balance, false)
	_check(not bool(r2.get("ok")), "schema: fractional float balance 12.5 rejected (no silent truncation)")

	# Non-finite float.
	var inf_balance: Dictionary = {"balance": INF}
	_check(not bool(econ.call("deserialize", inf_balance, false).get("ok")), "schema: INF balance rejected")

	# Nothing was mutated by any rejected payload.
	_check(int(econ.get("balance")) == before, "schema: all rejected payloads left balance untouched (%d)" % before)


func _test_schema_stub_era_blob_still_loads() -> void:
	print("\n[schema] stub-era blob {counter, balance, rng_state} STILL LOADS (save-load integration compat)")
	var rig := _make_economy_rig(0xEC041D)
	var econ: RefCounted = rig["economy"]

	var stub_blob := {
		"counter": 42,
		"balance": 777,
		"rng_state": SeededRNG.int64_to_hex(0xEC041D),
	}
	var result: RefCounted = econ.call("deserialize", stub_blob, false)
	_check(bool(result.get("ok")), "schema: stub-era blob loads ok (errors: %s)" % str(result.get("errors")))
	_check(int(econ.get("balance")) == 777, "schema: stub-era balance 777 committed (got %d)" % int(econ.get("balance")))

	# The stub-era keys are tolerated but NOT committed: counter restarts 0,
	# and the Economy RNG stream state is owned by TimeSystem.
	_check(int(econ.get("counter")) == 0, "schema: stub-era counter NOT committed (runtime observable restarts 0, got %d)" % int(econ.get("counter")))
	_check(int(rig["seeded_rng"].call("get_rng", "Economy").state) != 0xEC041D,
		"schema: stub-era rng_state NOT committed (TimeSystem owns the stream)")

	# Re-serialize after loading a stub blob emits the REAL {balance}-only shape.
	var payload: Dictionary = econ.call("serialize")
	_check(payload.size() == 1 and int(payload["balance"]) == 777, "schema: re-serialize after stub-era load is {balance: 777} (got %s)" % str(payload))
