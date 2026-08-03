# tests/unit/congestion/per_equipment_scalar_test.gd
# Story CG-001: Per-Equipment Congestion Scalar + EMA
# (production/epics/congestion/story-001-per-equipment-congestion-scalar-ema.md)
#
# BLOCKING ACs covered (TR-CONG-001/002/003/009):
#   AC3  range guard — any occupancy {0,1,2} x any N_i >= 0 -> finite float in
#        [0,1], never NaN/negative/>1
#   AC5  MemberSim reads the PREV buffer exactly X at tick t — unaffected by
#        `next` writes later in the same tick
#   AC6  [WB] mid-computation queries serve ALL prev (t-1), never a prev/next mix
#   AC7  alpha=0.3 single-step bound: |Congestion_i(t) - C0| <= 0.3 exactly
#   AC8  9+ idle ticks -> Congestion_i < 0.05 (never snaps to 0 instantly)
#   AC10 occupancy_state never exceeds 2 (queue depth 1 MVP)
#   AC11 N_i excludes occupant/next_claimant even when physically within R
#
# Plus (story contract surface):
#   - S8 congestion_updated: zero-payload signal emitted once per tick after
#     recompute (configured path), zero times in the pre-wiring path
#   - pre-wiring compatibility: serialize {counter, rng_state} shape, two-phase
#     deserialize, counter increments per tick, sub-stream NEVER advances
#   - fixed float-summation order: ascending equipment_instance_id
#
# Run standalone: godot --headless --script tests/unit/congestion/per_equipment_scalar_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const GRID_W := 10
const GRID_H := 8
const R0 := 0

var _pass := 0
var _fail := 0


func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	var result := run_all()
	quit(1 if int(result["fail"]) > 0 else 0)


func run_all() -> Dictionary:
	print("=".repeat(48))
	print("  UNIT TEST: Congestion — Per-Equipment Scalar + EMA (Story CG-001)")
	print("=".repeat(48))

	_test_ac3_range_guard()
	_test_ac5_prev_read_exact_unaffected_by_next()
	_test_ac6_mid_computation_all_prev()
	_test_ac7_ema_single_step_bound()
	_test_ac8_idle_decay_below_005()
	_test_ac10_occupancy_never_exceeds_2()
	_test_ac11_occupant_claimant_excluded_from_density()
	_test_s8_signal_arity_and_emit_count()
	_test_prewiring_contract_preserved()
	_test_fixed_order_ascending_ids_and_determinism()

	print("\n=== PER-EQUIPMENT SCALAR TEST: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


# === Helpers ===

func _GS() -> Script:
	return load("res://src/systems/grid_system.gd") as Script


func _MS() -> Script:
	return load("res://src/systems/member_sim.gd") as Script


func _SRG() -> Script:
	return load("res://src/systems/seeded_rng.gd") as Script


func _make_orchestrator() -> Node:
	var orch: Node = load("res://src/systems/simulation_orchestrator.gd").new()
	root.add_child(orch)
	orch.call("_ready")
	return orch


## Real GridSystem: 10x8 all buildable, frozen, with the given equipment
## committed. Each entry: {id, fp: Vector2i, ac: Vector2i}.
func _make_grid(equipment: Array) -> RefCounted:
	var gs: RefCounted = _GS().new()
	gs.call("init", GRID_W, GRID_H)
	for y in GRID_H:
		for x in GRID_W:
			gs.call("set_buildable", Vector2i(x, y), true)
	gs.call("freeze_buildable")
	for eq in equipment:
		var fp: Array[Vector2i] = [eq["fp"]]
		var ac: Array[Vector2i] = [eq["ac"]]
		gs.call("commit", int(eq["id"]), fp, ac, R0)
	return gs


## Real MemberSim instance — NOT init'd (no navigation/catalog needed); the
## test injects members/reservations directly through the public vars, the
## same data shape the configured system exposes (this is the AC11/AC10
## read surface Congestion consumes).
func _make_member_sim() -> RefCounted:
	return _MS().new()


## Real Congestion, configured with the real grid + member_sim + config.
func _make_congestion(gs: RefCounted, ms: RefCounted, config: Dictionary = {}) -> Dictionary:
	var srg: RefCounted = _SRG().new()
	srg.call("init", 0xCAFE001)
	var orch := _make_orchestrator()
	var cong: RefCounted = (load("res://src/systems/congestion.gd") as Script).new()
	cong.call("init", orch, srg, gs, ms, config)
	return {"congestion": cong, "seeded_rng": srg, "orchestrator": orch}


## Shortcut: a member record at the given cell with the given state.
func _member(member_id: int, state: String, cell: Vector2i) -> Dictionary:
	return {"member_id": member_id, "state": state, "cell": cell}


## Sets reservations[id] = {occupant, next_claimant} (null values omitted).
func _reserve(ms: RefCounted, id: int, occupant: Variant = null, claimant: Variant = null) -> void:
	var rec: Dictionary = {}
	if occupant != null:
		rec["occupant"] = occupant
	if claimant != null:
		rec["next_claimant"] = claimant
	(ms.get("reservations") as Dictionary)[id] = rec


# === AC3: range guard ===

func _test_ac3_range_guard() -> void:
	print("\n[AC3] any occupancy {0,1,2} x any N_i >= 0 -> finite float in [0,1]")
	var eq: Array = [{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)}]
	var gs := _make_grid(eq)
	var ms := _make_member_sim()

	# occupancy 0 x N {0, 1, 3, 50}: no reservation record.
	gs = _make_grid(eq)
	ms = _make_member_sim()
	for n in [0, 1, 3, 50]:
		ms.set("members", [])
		for i in n:
			(ms.get("members") as Array).append(_member(1000 + i, "WALKING_TO", Vector2i(3, 2)))
		var rig := _make_congestion(gs, ms)
		rig["congestion"].call("on_tick", 0)
		var v: float = rig["congestion"].call("per_equipment_congestion", 1)
		_check(is_finite(v) and v >= 0.0 and v <= 1.0,
			"AC3: occ 0, N=%d -> %s in [0,1] finite" % [n, str(v)])

	# occupancy 1 (occupant only) x N {0, 3}: loiterers placed at access cell.
	gs = _make_grid(eq)
	ms = _make_member_sim()
	for n in [0, 3]:
		ms.set("members", [_member(10, "USING", Vector2i(3, 2))])
		for i in n:
			(ms.get("members") as Array).append(_member(100 + i, "WALKING_TO", Vector2i(3, 2)))
		_reserve(ms, 1, 10)
		var rig := _make_congestion(gs, ms)
		rig["congestion"].call("on_tick", 0)
		var v: float = rig["congestion"].call("per_equipment_congestion", 1)
		_check(is_finite(v) and v >= 0.0 and v <= 1.0,
			"AC3: occ 1, N=%d -> %s in [0,1] finite" % [n, str(v)])

	# occupancy 2 (occupant + claimant) x N large: occupant/claimant at access
	# cell are EXCLUDED from N_i (AC11), plus 50 loiterers saturate D_max.
	gs = _make_grid(eq)
	ms = _make_member_sim()
	ms.set("members", [_member(20, "USING", Vector2i(3, 2)), _member(21, "QUEUEING", Vector2i(3, 2))])
	for i in 50:
		(ms.get("members") as Array).append(_member(200 + i, "WALKING_TO", Vector2i(3, 2)))
	_reserve(ms, 1, 20, 21)
	var rig := _make_congestion(gs, ms)
	rig["congestion"].call("on_tick", 0)
	var v2: float = rig["congestion"].call("per_equipment_congestion", 1)
	_check(is_finite(v2) and v2 >= 0.0 and v2 <= 1.0,
		"AC3: occ 2, N=50 loiterers -> %s in [0,1] finite" % str(v2))

	# N_i huge without occupancy: raw = 0.3*dens -> still [0,1].
	gs = _make_grid(eq)
	ms = _make_member_sim()
	for i in 500:
		(ms.get("members") as Array).append(_member(500 + i, "WALKING_TO", Vector2i(3, 2)))
	var rig3 := _make_congestion(gs, ms)
	rig3["congestion"].call("on_tick", 0)
	var v3: float = rig3["congestion"].call("per_equipment_congestion", 1)
	_check(is_finite(v3) and v3 >= 0.0 and v3 <= 1.0,
		"AC3: N=500 (huge) -> %s in [0,1] finite" % str(v3))


# === AC5: t-1 read exact ===

func _test_ac5_prev_read_exact_unaffected_by_next() -> void:
	print("\n[AC5] prev holds X; reads serve exactly X, unaffected by next writes")
	var eq: Array = [{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)}]

	for x in [0.0, 1.0, 0.4]:
		var gs := _make_grid(eq)
		var ms := _make_member_sim()
		# A state that would produce a NEXT value different from X. For X=1.0
		# a busy state keeps next at 1.0 (saturated), so use an IDLE state
		# (raw=0 -> next=0.7); for lower X use a busy state (raw near 1.0).
		if x >= 1.0:
			ms.set("members", [])
		else:
			ms.set("members", [_member(30, "USING", Vector2i(3, 2)), _member(31, "QUEUEING", Vector2i(3, 2))])
			for i in 5:
				(ms.get("members") as Array).append(_member(300 + i, "WALKING_TO", Vector2i(3, 2)))
			_reserve(ms, 1, 30, 31)
		var rig := _make_congestion(gs, ms)
		var cong: RefCounted = rig["congestion"]
		cong.set("prev", {1: x})

		# "MemberSim runs at tick t before Congestion": the read returns X.
		var before: float = cong.call("per_equipment_congestion", 1)
		_check(before == x, "AC5: pre-tick read == X exactly (X=%s, got %s)" % [str(x), str(before)])

		# Next writes happen later in tick t; reads STILL serve prev.
		var new_val: float = cong.call("_compute_equipment", 1)
		_check(new_val != x, "AC5: the state would produce a next != X (next=%s)" % str(new_val))
		var during: float = cong.call("per_equipment_congestion", 1)
		_check(during == x, "AC5: mid-tick read unaffected by next write (X=%s, got %s)" % [str(x), str(during)])

		# After the swap the new value is visible (one-tick lag completed).
		cong.set("next", {1: new_val})
		cong.set("prev", (cong.get("next") as Dictionary))
		var after: float = cong.call("per_equipment_congestion", 1)
		_check(after == new_val, "AC5: post-swap read == next (got %s)" % str(after))


# === AC6: mid-computation all-prev ===

func _test_ac6_mid_computation_all_prev() -> void:
	print("\n[AC6] [WB] mid-computation queries return ALL prev — never a prev/next mix")
	var eq: Array = [
		{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)},
		{"id": 2, "fp": Vector2i(5, 2), "ac": Vector2i(6, 2)},
	]
	var gs := _make_grid(eq)
	var ms := _make_member_sim()
	# Busy equipment 1 (occupant+claimant+loiterers), idle equipment 2.
	ms.set("members", [_member(40, "USING", Vector2i(3, 2)), _member(41, "QUEUEING", Vector2i(3, 2))])
	for i in 5:
		(ms.get("members") as Array).append(_member(400 + i, "WALKING_TO", Vector2i(3, 2)))
	_reserve(ms, 1, 40, 41)

	var rig := _make_congestion(gs, ms)
	var cong: RefCounted = rig["congestion"]
	cong.set("prev", {1: 0.2, 2: 0.8})

	# Simulate mid-computation: only equipment 1 processed so far.
	cong.set("next", {})
	var next1: float = cong.call("_compute_equipment", 1)
	(cong.get("next") as Dictionary)[1] = next1

	# A consumer queries in that window: BOTH entries must be prev.
	var q1: float = cong.call("per_equipment_congestion", 1)
	var q2: float = cong.call("per_equipment_congestion", 2)
	_check(q1 == 0.2, "AC6: equipment 1 processed -> read still prev 0.2 (got %s)" % str(q1))
	_check(q2 == 0.8, "AC6: equipment 2 unprocessed -> read prev 0.8 (got %s)" % str(q2))
	_check(q1 == 0.2 and q2 == 0.8, "AC6: no prev/next mix in the query window")

	# Complete the pass and swap: now both are next.
	var next2: float = cong.call("_compute_equipment", 2)
	(cong.get("next") as Dictionary)[2] = next2
	cong.set("prev", cong.get("next"))
	var a1: float = cong.call("per_equipment_congestion", 1)
	var a2: float = cong.call("per_equipment_congestion", 2)
	_check(a1 == next1 and a2 == next2, "AC6: post-swap reads == next values (got %s, %s)" % [str(a1), str(a2)])


# === AC7: EMA single-step bound ===

func _test_ac7_ema_single_step_bound() -> void:
	print("\n[AC7] alpha=0.3: |Congestion_i(t) - C0| <= 0.3 exactly")
	var eq: Array = [{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)}]

	# raw = 1.0: occupant + claimant + enough loiterers to saturate density.
	var gs1 := _make_grid(eq)
	var ms1 := _make_member_sim()
	ms1.set("members", [_member(50, "USING", Vector2i(3, 2)), _member(51, "QUEUEING", Vector2i(3, 2))])
	for i in 5:
		(ms1.get("members") as Array).append(_member(500 + i, "WALKING_TO", Vector2i(3, 2)))
	_reserve(ms1, 1, 50, 51)
	var rig1 := _make_congestion(gs1, ms1)
	rig1["congestion"].set("prev", {1: 0.5})
	rig1["congestion"].call("on_tick", 0)
	var v1: float = rig1["congestion"].call("per_equipment_congestion", 1)
	# C0=0.5, raw=1 -> 0.3*1 + 0.7*0.5 = 0.65 (diff 0.15)
	_check(absf(v1 - 0.5) <= 0.3 + 1e-9, "AC7: |result - C0| <= 0.3 (C0=0.5 raw=1 -> %s)" % str(v1))
	_check(absf(v1 - 0.65) < 1e-9, "AC7: C0=0.5, raw=1 -> 0.65 exactly (got %s)" % str(v1))

	# raw = 0.0: no reservation, no nearby members.
	var gs2 := _make_grid(eq)
	var ms2 := _make_member_sim()
	ms2.set("members", [])
	var rig2 := _make_congestion(gs2, ms2)
	rig2["congestion"].set("prev", {1: 0.9})
	rig2["congestion"].call("on_tick", 0)
	var v2: float = rig2["congestion"].call("per_equipment_congestion", 1)
	# C0=0.9, raw=0 -> 0.3*0 + 0.7*0.9 = 0.63 (diff 0.27)
	_check(absf(v2 - 0.9) <= 0.3 + 1e-9, "AC7: |result - C0| <= 0.3 (C0=0.9 raw=0 -> %s)" % str(v2))
	_check(absf(v2 - 0.63) < 1e-9, "AC7: C0=0.9, raw=0 -> 0.63 exactly (got %s)" % str(v2))

	# Extreme C0 sweep for the bound, raw at 0: diff == 0.3*C0 <= 0.3.
	for c0 in [0.0, 0.1, 0.5, 1.0]:
		var gs3 := _make_grid(eq)
		var ms3 := _make_member_sim()
		var rig3 := _make_congestion(gs3, ms3)
		rig3["congestion"].set("prev", {1: c0})
		rig3["congestion"].call("on_tick", 0)
		var v3: float = rig3["congestion"].call("per_equipment_congestion", 1)
		_check(absf(v3 - c0) <= 0.3 + 1e-9,
			"AC7: C0=%s raw=0 -> diff %.4f <= 0.3" % [str(c0), absf(v3 - c0)])


# === AC8: decay ===

func _test_ac8_idle_decay_below_005() -> void:
	print("\n[AC8] occupancy 0 + N 0 sustained 9+ ticks -> Congestion < 0.05")
	var eq: Array = [{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)}]
	var gs := _make_grid(eq)
	var ms := _make_member_sim()
	ms.set("members", [])
	var rig := _make_congestion(gs, ms)
	var cong: RefCounted = rig["congestion"]
	cong.set("prev", {1: 1.0})  # start fully congested

	# One idle tick: never snaps to 0 instantly.
	cong.call("on_tick", 0)
	var after1: float = cong.call("per_equipment_congestion", 1)
	_check(after1 == 0.7, "AC8: after 1 idle tick -> 0.7, not 0 (got %s)" % str(after1))

	# Ticks 2..9: (1-alpha)^n = 0.7^n.
	var ticks: int = 1
	for t in range(1, 9):
		cong.call("on_tick", t)
		ticks += 1
	var after9: float = cong.call("per_equipment_congestion", 1)
	_check(after9 < 0.05, "AC8: after 9 idle ticks -> %s < 0.05" % str(after9))
	_check(after9 > 0.0, "AC8: decays exponentially, never instant-snaps to 0 (got %s)" % str(after9))

	# 10th tick continues decaying.
	cong.call("on_tick", 10)
	var after10: float = cong.call("per_equipment_congestion", 1)
	_check(after10 < after9, "AC8: 10th idle tick decays further (%s < %s)" % [str(after10), str(after9)])


# === AC10: queue depth cap ===

func _test_ac10_occupancy_never_exceeds_2() -> void:
	print("\n[AC10] occupancy_state never exceeds 2 (queue depth 1 MVP)")
	var eq: Array = [{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)}]
	var gs := _make_grid(eq)
	var ms := _make_member_sim()

	# No record -> 0 (free).
	ms.set("members", [])
	var rig0 := _make_congestion(gs, ms)
	var occ0: int = rig0["congestion"].call("_occupancy_state", 1)
	_check(occ0 == 0, "AC10: no reservation -> occupancy 0 (got %d)" % occ0)

	# Occupant only -> 1.
	ms.set("members", [_member(60, "USING", Vector2i(3, 2))])
	_reserve(ms, 1, 60)
	var rig1 := _make_congestion(gs, ms)
	var occ1: int = rig1["congestion"].call("_occupancy_state", 1)
	_check(occ1 == 1, "AC10: occupant only -> occupancy 1 (got %d)" % occ1)

	# Occupant + claimant -> 2 (the max tier).
	ms.set("members", [_member(61, "USING", Vector2i(3, 2)), _member(62, "QUEUEING", Vector2i(3, 2))])
	_reserve(ms, 1, 61, 62)
	var rig2 := _make_congestion(gs, ms)
	var occ2: int = rig2["congestion"].call("_occupancy_state", 1)
	_check(occ2 == 2, "AC10: occupant + claimant -> occupancy 2 (got %d)" % occ2)

	# Even a malformed record (extra "claimant2" key) clamps to <= 2: the
	# scalar only reads occupant/next_claimant (queue depth 1 structural cap).
	var ms3 := _make_member_sim()
	(ms3.get("reservations") as Dictionary)[1] = {"occupant": 70, "next_claimant": 71, "claimant2": 72}
	var rig3 := _make_congestion(gs, ms3)
	var occ3: int = rig3["congestion"].call("_occupancy_state", 1)
	_check(occ3 <= 2, "AC10: occupancy defensively clamped <= 2 (got %d)" % occ3)


# === AC11: exclusion from density ===

func _test_ac11_occupant_claimant_excluded_from_density() -> void:
	print("\n[AC11] N_i excludes occupant/next_claimant even when physically within R")
	var eq: Array = [{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)}]
	var gs := _make_grid(eq)
	var ms := _make_member_sim()

	# Occupant + claimant BOTH physically ON the access cell (within R), plus
	# 2 unrelated loiterers on the access cell and 1 far away.
	ms.set("members", [
		_member(80, "USING", Vector2i(3, 2)),      # occupant, at access cell
		_member(81, "QUEUEING", Vector2i(3, 2)),   # next_claimant, at access cell
		_member(82, "WALKING_TO", Vector2i(3, 2)), # loiterer, counted
		_member(83, "WALKING_TO", Vector2i(3, 2)), # loiterer, counted
		_member(84, "WALKING_TO", Vector2i(8, 7)), # far away (cheb 6 > 2), not counted
	])
	_reserve(ms, 1, 80, 81)
	var rig := _make_congestion(gs, ms)
	var n: int = rig["congestion"].call("_nearby_count", 1)
	_check(n == 2, "AC11: N_i == 2 (only the 2 loiterers; occupant+claimant excluded, got %d)" % n)

	# Full scalar reflects the EXCLUDED density: dens = 2/3 (D_max=3), not 4/3.
	rig["congestion"].call("on_tick", 0)
	var v: float = rig["congestion"].call("per_equipment_congestion", 1)
	var expected: float = 0.3 * (0.7 * 1.0 + 0.3 * (2.0 / 3.0)) + 0.7 * 0.0
	_check(absf(v - expected) < 1e-9,
		"AC11: scalar uses excluded density 2/3 (got %s, expected %s)" % [str(v), str(expected)])


# === S8 signal ===

func _test_s8_signal_arity_and_emit_count() -> void:
	print("\n[S8] congestion_updated: zero payload, once per tick after recompute")
	var eq: Array = [{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)}]
	var gs := _make_grid(eq)
	var ms := _make_member_sim()
	var rig := _make_congestion(gs, ms)
	var cong: RefCounted = rig["congestion"]

	var emits: Array = []
	cong.connect("congestion_updated", func() -> void:
		emits.append("ping"))

	cong.call("on_tick", 0)
	cong.call("on_tick", 1)
	_check(emits.size() == 2, "S8: configured path emits once per tick (2 ticks -> %d emits)" % emits.size())


# === Pre-wiring contract ===

func _test_prewiring_contract_preserved() -> void:
	print("\n[PREWIRING] unconfigured instance keeps the SL-002 stub contract")
	var srg: RefCounted = _SRG().new()
	srg.call("init", 0xBEEF002)
	var orch := _make_orchestrator()
	var cong: RefCounted = (load("res://src/systems/congestion.gd") as Script).new()
	cong.call("init", orch, srg)  # pre-wiring: no grid/member_sim

	var state_before: int = int((srg.call("get_rng", "Congestion") as RandomNumberGenerator).state)

	# counter increments per tick; no emission; RNG stream NEVER advances.
	var emits: Array = []
	cong.connect("congestion_updated", func() -> void:
		emits.append("ping"))
	cong.call("on_tick", 0)
	cong.call("on_tick", 1)
	cong.call("on_tick", 2)
	_check(int(cong.get("counter")) == 3, "PREWIRING: counter increments per tick (got %d)" % int(cong.get("counter")))
	_check(emits.is_empty(), "PREWIRING: no congestion_updated emission without a recompute")
	var state_after: int = int((srg.call("get_rng", "Congestion") as RandomNumberGenerator).state)
	_check(state_after == state_before, "PREWIRING: sub-stream never advances (TR-CONG-001 pure function)")

	# serialize shape: {counter, rng_state}, rng_state static.
	var blob: Dictionary = cong.call("serialize")
	_check(blob.has("counter") and int(blob["counter"]) == 3, "PREWIRING: serialize emits counter")
	_check(blob.has("rng_state") and str(blob["rng_state"]).begins_with("0x"),
		"PREWIRING: serialize emits rng_state hex (%s)" % str(blob.get("rng_state", "")))

	# Two-phase deserialize: validate-only passes, commit restores.
	var validate: RefCounted = cong.call("deserialize", blob, true)
	_check(bool(validate.get("ok")), "PREWIRING: Phase A validate passes")
	var commit: RefCounted = cong.call("deserialize", blob, false)
	_check(bool(commit.get("ok")), "PREWIRING: Phase B commit passes")
	_check(int(cong.get("counter")) == 3, "PREWIRING: counter restored on commit")

	# Corrupt payload fails Phase A with zero mutation.
	var bad: Dictionary = {"counter": "x", "rng_state": "zz"}
	var corrupt: RefCounted = cong.call("deserialize", bad, true)
	_check(not bool(corrupt.get("ok")), "PREWIRING: corrupt payload fails Phase A")
	_check(int(cong.get("counter")) == 3, "PREWIRING: failed load mutates nothing")


# === Fixed order + determinism ===

func _test_fixed_order_ascending_ids_and_determinism() -> void:
	print("\n[ORDER] ascending equipment_instance_id + deterministic recompute")
	# Commit equipment in NON-ascending id order (3, 1, 2) — the compute must
	# still iterate ascending (1, 2, 3).
	var gs := _make_grid([
		{"id": 3, "fp": Vector2i(1, 5), "ac": Vector2i(2, 5)},
		{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)},
		{"id": 2, "fp": Vector2i(5, 2), "ac": Vector2i(6, 2)},
	])
	var ms := _make_member_sim()
	ms.set("members", [_member(90, "USING", Vector2i(3, 2)), _member(91, "QUEUEING", Vector2i(3, 2))])
	_reserve(ms, 1, 90, 91)

	var rig := _make_congestion(gs, ms)
	var cong: RefCounted = rig["congestion"]
	var ids: Array = cong.call("_ascending_equipment_ids")
	_check(ids == [1, 2, 3], "ORDER: iteration ids ascending despite commit order (got %s)" % str(ids))

	# Two independent instances, same member state + same seed -> bit-identical.
	var ms_a := _make_member_sim()
	ms_a.set("members", [_member(90, "USING", Vector2i(3, 2)), _member(91, "QUEUEING", Vector2i(3, 2))])
	_reserve(ms_a, 1, 90, 91)
	var rig_a := _make_congestion(gs, ms_a)
	var rig_b := _make_congestion(gs, ms_a)
	for t in range(5):
		rig_a["congestion"].call("on_tick", t)
		rig_b["congestion"].call("on_tick", t)
	var same := true
	for id in ids:
		var va: float = rig_a["congestion"].call("per_equipment_congestion", id)
		var vb: float = rig_b["congestion"].call("per_equipment_congestion", id)
		if va != vb:
			same = false
			print("    ORDER: divergence at id %d: %s vs %s" % [id, str(va), str(vb)])
	_check(same, "ORDER: two instances same seed/state -> bit-identical after 5 ticks")
