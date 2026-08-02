# tests/unit/member_sim/target_selection_weight_test.gd
# Story MS-002: Target Selection and Weighted Pick
# (production/epics/member-sim/story-002-target-selection-weighted-pick.md)
#
# Covers the BLOCKING ACs (TR-MS-003):
#   - AC10  weight is STRICTLY monotonic in Congestion(t-1): swept range
#           [0, 0.25, 0.5, 0.75, 1.0] produces strictly decreasing weights;
#           A=0.1 vs B=0.8 -> weight_A > weight_B; both extremes stay > 0.
#   - AC11 [UNIT] the weight consumes the PRE-update (t-1) value: a reader
#           holding prev=0.5 while next would be 0.9 serves 0.5 to the pick;
#           the candidate's congestion field equals the prev value.
#   - AC12  every equipment Congestion(t-1)=1.0 -> all weights > 0 (no
#           divide-by-zero, no NaN) and the normalized probabilities sum to
#           1.0 within float tolerance; empty pool after path-check handled
#           gracefully (member LEAVING, no crash).
#   - AC20  equal weights tie-break by ASCENDING equipment_instance_id;
#           2 candidates and 3+ candidates all equal weight resolve
#           deterministically in ascending id order; same-seed runs choose
#           the same target.
# Plus the GDD formula golden example (congestion 0.1/dist 3 -> ~0.714).
#
# Run standalone: godot --headless --script tests/unit/member_sim/target_selection_weight_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const GRID_W := 8
const GRID_H := 6
const ENTRANCE := Vector2i(0, 0)
const EXIT := Vector2i(7, 5)

# Rotation value mirroring GridSystem.Rotation (degree-valued).
const R0 := 0

# GDD anchors the formula asserts against (defaults in member_sim.gd).
const K_CONGESTION := 3.0
const K_PROXIMITY := 0.2
const D_MAX := 16

## Fake congestion reader implementing the congestion-story-001 read surface:
## `per_equipment_congestion(id) -> float` serving the PRE-update `prev`
## buffer (AC11 — the reader never serves `next` mid-tick). `write_next()`
## simulates the Congestion pass writing its compute target; `swap()` the
## end-of-tick buffer swap. Every served read is logged for assertions.
class FakeCongestionReader:
	extends RefCounted

	var prev: Dictionary = {}   # instance_id -> congestion(t-1) in [0,1]
	var next: Dictionary = {}   # instance_id -> congestion(t) write target
	var reads: Array = []       # [instance_id, served_value, ...]

	func per_equipment_congestion(instance_id: int) -> float:
		var v := float(prev.get(instance_id, 0.0))
		reads.append([instance_id, v])
		return v

	func write_next(instance_id: int, value: float) -> void:
		next[instance_id] = value

	func swap() -> void:
		prev = next.duplicate()

	func set_prev(instance_id: int, value: float) -> void:
		prev[instance_id] = value


## Congestion-pass spy used by the integration-style tests: records its
## on_tick into a shared log so the test can assert dispatch order relative
## to the member's congestion reads.
class CongestionSpy:
	extends RefCounted

	var log: Array  # shared — appended "congestion" per on_tick

	func _init(shared_log: Array) -> void:
		log = shared_log

	func on_tick(_tick_count: int) -> void:
		log.append("congestion")


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
	print("  UNIT TEST: MemberSim — Target Selection and Weighted Pick (Story MS-002)")
	print("=".repeat(48))

	_test_ac10_strict_monotonic_sweep()
	_test_ac10_a0p1_beats_b0p8()
	_test_ac10_extremes_still_positive()
	_test_ac10_gdd_golden_example()
	_test_ac10_integration_candidate_weights()
	_test_ac11_unit_reads_prev_not_next()
	_test_ac12_all_congested_weights_positive_normalized()
	_test_ac12_all_congested_pick_succeeds()
	_test_ac12_empty_pool_after_pathcheck_leaves()
	_test_ac20_two_equal_weights_ascending_id()
	_test_ac20_three_equal_weights_ascending_id()
	_test_ac20_deterministic_same_seed_same_target()

	print("\n=== TARGET SELECTION WEIGHT TEST: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


# === Helpers (mirror the MS-001 lifecycle rig) ===

func _MS() -> Script:
	return load("res://src/systems/member_sim.gd") as Script


func _GS() -> Script:
	return load("res://src/systems/grid_system.gd") as Script


func _NAV() -> Script:
	return load("res://src/systems/navigation.gd") as Script


func _SRG() -> Script:
	return load("res://src/systems/seeded_rng.gd") as Script


func _EC() -> Script:
	return load("res://src/systems/equipment_catalog.gd") as Script


func _ED() -> Script:
	return load("res://src/systems/equipment_def.gd") as Script


## Creates an initialized SimulationOrchestrator in the scene tree (delivers
## _ready() synchronously — same pattern as the MS-001 test).
func _make_orchestrator() -> Node:
	var orch: Node = load("res://src/systems/simulation_orchestrator.gd").new()
	root.add_child(orch)
	orch.call("_ready")
	return orch


func _make_grid(with_walls: Array = []) -> RefCounted:
	var gs: RefCounted = _GS().new()
	gs.call("init", GRID_W, GRID_H)
	for y in GRID_H:
		for x in GRID_W:
			gs.call("set_buildable", Vector2i(x, y), true)
	for wall in with_walls:
		gs.call("set_buildable", wall, false)
	gs.call("freeze_buildable")
	return gs


func _make_navigation(grid: RefCounted) -> RefCounted:
	var nav: RefCounted = _NAV().new()
	nav.call("init", grid)
	nav.call("_post_init")
	return nav


func _make_catalog() -> RefCounted:
	var cat: RefCounted = _EC().new()
	var fp: Array[Vector2i] = [Vector2i(0, 0)]
	var ac: Array[Vector2i] = [Vector2i(1, 0)]
	var effects: Array[Dictionary] = []
	var def = _ED().new("treadmill", "Treadmill", ["cardio"], fp, ac, 100, "", effects, 200, 35, 100, 300)
	cat.call("_add_definition", def)
	cat.call("_freeze")
	return cat


func _commit_equipment(gs: RefCounted, instance_id: int, fp: Vector2i, ac: Vector2i) -> void:
	var fp_arr: Array[Vector2i] = [fp]
	var ac_arr: Array[Vector2i] = [ac]
	gs.call("commit", instance_id, fp_arr, ac_arr, R0)


## Builds the full configured MemberSim rig. [equipment] lists {id, fp, ac}
## commits. [congestion_reader] is the Story 002 injected prev-buffer reader
## (optional — when null, congestion is neutral 0.0). [walls] marks extra
## non-buildable cells (unreachable setups). [config] merges over the base
## (zero arrivals so only injected members run).
func _make_rig(
	seed: int,
	equipment: Array = [],
	congestion_reader: Variant = null,
	walls: Array = [],
	config: Dictionary = {}
) -> Dictionary:
	var gs := _make_grid(walls)
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
	}
	for k in config:
		cfg[k] = config[k]
	ms.call("init", orch, srg, gs, nav, cat, ENTRANCE, EXIT, cfg, congestion_reader)
	orch.set("member_sim", ms)
	return {
		"orchestrator": orch,
		"grid_system": gs,
		"navigation": nav,
		"catalog": cat,
		"seeded_rng": srg,
		"member_sim": ms,
	}


## Builds a FULL state-machine member record (the shape _spawn_member
## produces). [overrides] replace any field — used to arm specific states.
func _make_member(
	member_id: int,
	state: String,
	exercises_done: int,
	exercises_per_visit: int,
	cell: Vector2i,
	overrides: Dictionary = {}
) -> Dictionary:
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
		"recently_used_ids": [],
	}
	for k in overrides:
		m[k] = overrides[k]
	return m


func _inject_member(rig: Dictionary, member: Dictionary) -> void:
	(rig["member_sim"].get("members") as Array).append(member)


func _find_member(rig: Dictionary, member_id: int) -> Dictionary:
	for m in (rig["member_sim"].get("members") as Array):
		if m is Dictionary and m.has("member_id") and int(m["member_id"]) == member_id:
			return m
	return {}


func _run_ticks(rig: Dictionary, n: int, start_tick: int = 0) -> void:
	for i in range(n):
		rig["member_sim"].call("on_tick", start_tick + i)


## White-box: the member's candidate entries [{instance_id, weight,
## congestion, dist_cells, novelty, noise}] in ASCENDING id order (the fixed
## summation order — see _build_weighted_candidates). [WB] hook, no RNG.
func _candidates(rig: Dictionary, member: Dictionary) -> Array:
	return rig["member_sim"].call("_build_weighted_candidates", member) as Array


## The public formula surface (Core Rule 3 / GDD Formulas) — the exact
## function the implementation uses per candidate.
func _weight(rig: Dictionary, congestion: float, dist_cells: int, novelty: float, noise: float) -> float:
	return float(rig["member_sim"].call("target_selection_weight", congestion, dist_cells, novelty, noise))


# === AC10: strict monotonicity in congestion ===

func _test_ac10_strict_monotonic_sweep() -> void:
	print("\n[AC10] swept congestion [0, 0.25, 0.5, 0.75, 1.0] -> STRICTLY decreasing weight")
	var rig := _make_rig(101)
	var prev_w := INF
	var ok := true
	for c in [0.0, 0.25, 0.5, 0.75, 1.0]:
		var w := _weight(rig, c, 4, 1.0, 1.0)
		if w >= prev_w:
			ok = false
		prev_w = w
	_check(ok, "AC10: weights strictly decreasing across the swept range (got %s)"
		% [str([_weight(rig, 0.0, 4, 1.0, 1.0), _weight(rig, 0.25, 4, 1.0, 1.0), _weight(rig, 0.5, 4, 1.0, 1.0), _weight(rig, 0.75, 4, 1.0, 1.0), _weight(rig, 1.0, 4, 1.0, 1.0)])])


func _test_ac10_a0p1_beats_b0p8() -> void:
	print("\n[AC10] two candidates identical except congestion: A=0.1 vs B=0.8 -> weight_A > weight_B")
	var rig := _make_rig(102)
	var w_a := _weight(rig, 0.1, 3, 1.0, 1.0)
	var w_b := _weight(rig, 0.8, 3, 1.0, 1.0)
	_check(w_a > w_b, "AC10: weight(0.1)=%.6f > weight(0.8)=%.6f" % [w_a, w_b])


func _test_ac10_extremes_still_positive() -> void:
	print("\n[AC10 edge] congestion at the extremes 0.0 and 1.0 -> BOTH weights stay strictly positive")
	var rig := _make_rig(103)
	var w0 := _weight(rig, 0.0, 4, 1.0, 1.0)
	var w1 := _weight(rig, 1.0, 4, 1.0, 1.0)
	_check(w0 > 0.0 and is_finite(w0), "AC10: weight(0.0)=%.9f > 0 and finite" % w0)
	_check(w1 > 0.0 and is_finite(w1), "AC10: weight(1.0)=%.9f > 0 and finite (epsilon floor intact)" % w1)


func _test_ac10_gdd_golden_example() -> void:
	print("\n[AC10][formula] GDD golden example: congestion 0.1 / dist 3 -> weight ~0.714")
	var rig := _make_rig(104)
	var w := _weight(rig, 0.1, 3, 1.0, 1.0)
	_check(absf(w - 0.714) < 0.01, "AC10[gdd]: weight(0.1,3)=%.4f within 0.01 of the GDD example 0.714" % w)


func _test_ac10_integration_candidate_weights() -> void:
	print("\n[AC10][INT] two real candidates equidistant, congestion A=0.1 / B=0.8 -> weight_A > weight_B in the built pool")
	# Both access cells at Chebyshev distance 3 from the entrance (0,0).
	var equipment: Array = [
		{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)},
		{"id": 2, "fp": Vector2i(2, 3), "ac": Vector2i(3, 3)},
	]
	var reader := FakeCongestionReader.new()
	reader.set_prev(1, 0.1)
	reader.set_prev(2, 0.8)
	var rig := _make_rig(105, equipment, reader)
	_inject_member(rig, _make_member(100, "SELECTING_TARGET", 0, 3, ENTRANCE))

	var entries: Array = _candidates(rig, _find_member(rig, 100))
	_check(entries.size() == 2, "AC10[INT]: two candidates in the pool (got %d)" % entries.size())
	var w1 := 0.0
	var w2 := 0.0
	var cong1 := -1.0
	var cong2 := -1.0
	for e in entries:
		if int(e["instance_id"]) == 1:
			w1 = float(e["weight"])
			cong1 = float(e["congestion"])
		elif int(e["instance_id"]) == 2:
			w2 = float(e["weight"])
			cong2 = float(e["congestion"])
	_check(cong1 == 0.1 and cong2 == 0.8, "AC10[INT]: congestion read through the reader seam (got %s / %s)" % [cong1, cong2])
	_check(w1 > w2, "AC10[INT]: candidate 1 (congestion 0.1) weighs more than candidate 2 (0.8): %.6f > %.6f" % [w1, w2])


# === AC11 [UNIT]: the weight uses the PRE-update (t-1) value ===

func _test_ac11_unit_reads_prev_not_next() -> void:
	print("\n[AC11][UNIT] reader holds prev=0.5, next would be 0.9 -> the pick consumes 0.5 (t-1), never 0.9")
	var equipment: Array = [{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)}]
	var reader := FakeCongestionReader.new()
	reader.set_prev(1, 0.5)
	# The congestion pass LATER in the same tick writes next=0.9 — MemberSim
	# must never see it (the reader serves prev during the whole tick).
	reader.write_next(1, 0.9)
	var rig := _make_rig(106, equipment, reader)
	_inject_member(rig, _make_member(100, "SELECTING_TARGET", 0, 3, ENTRANCE))

	_run_ticks(rig, 1)

	var m := _find_member(rig, 100)
	_check(not m.is_empty() and str(m["state"]) == "WALKING_TO",
		"AC11[UNIT]: member selected a target this tick (state=%s)" % ("" if m.is_empty() else str(m["state"])))
	_check(reader.reads.size() == 1, "AC11[UNIT]: reader queried exactly once for the single candidate (got %d)" % reader.reads.size())
	if reader.reads.size() == 1:
		_check(int(reader.reads[0][0]) == 1 and float(reader.reads[0][1]) == 0.5,
			"AC11[UNIT]: served value is prev 0.5 (t-1), NOT next 0.9 (got %s)" % str(reader.reads[0]))
	var entries: Array = _candidates(rig, m)
	_check(not entries.is_empty() and float(entries[0]["congestion"]) == 0.5,
		"AC11[UNIT]: candidate congestion field == prev 0.5 (weight consumed the pre-update value)")


# === AC12: fully congested floors stay positive + normalized ===

func _test_ac12_all_congested_weights_positive_normalized() -> void:
	print("\n[AC12] every equipment congestion 1.0 -> all weights > 0, no NaN, Σ P_i = 1.0")
	var rig := _make_rig(107)
	# Spread dist/novelty/noise across the formula's input ranges.
	var weights: Array = []
	for d in [0, 4, 15]:
		for nov in [0.2, 0.6, 1.0]:
			for noise in [0.85, 1.0, 1.15]:
				weights.append(_weight(rig, 1.0, d, nov, noise))
	var all_positive := true
	var no_nan := true
	var total := 0.0
	for w in weights:
		if not (w > 0.0):
			all_positive = false
		if is_nan(w):
			no_nan = false
		total += float(w)
	_check(all_positive, "AC12: all %d weights > 0 at congestion 1.0 (epsilon floor)" % weights.size())
	_check(no_nan, "AC12: no NaN across the input spread")
	var sum_p := 0.0
	for w in weights:
		sum_p += float(w) / total
	_check(absf(sum_p - 1.0) < 1e-9, "AC12: Σ P_i = 1.0 within 1e-9 (got %.15f)" % sum_p)


func _test_ac12_all_congested_pick_succeeds() -> void:
	print("\n[AC12][INT] three equipment all congestion 1.0 -> the pick still succeeds (weights > 0, ΣP=1)")
	var equipment: Array = [
		{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)},
		{"id": 2, "fp": Vector2i(4, 2), "ac": Vector2i(5, 2)},
		{"id": 3, "fp": Vector2i(2, 4), "ac": Vector2i(3, 4)},
	]
	var reader := FakeCongestionReader.new()
	for id in [1, 2, 3]:
		reader.set_prev(id, 1.0)
	var rig := _make_rig(108, equipment, reader)
	_inject_member(rig, _make_member(100, "SELECTING_TARGET", 0, 3, ENTRANCE))

	_run_ticks(rig, 1)

	var m := _find_member(rig, 100)
	_check(not m.is_empty() and str(m["state"]) == "WALKING_TO",
		"AC12[INT]: fully congested floor still yields a target (state=%s)" % ("" if m.is_empty() else str(m["state"])))
	var target := int(m["target_equipment_instance_id"])
	_check(target >= 1 and target <= 3, "AC12[INT]: chosen equipment in the pool (got %d)" % target)


func _test_ac12_empty_pool_after_pathcheck_leaves() -> void:
	print("\n[AC12 edge] all candidates unreachable after path-check -> member LEAVING gracefully (zero survivors)")
	var walls: Array = [Vector2i(2, 1), Vector2i(3, 1), Vector2i(4, 1), Vector2i(2, 3), Vector2i(3, 3), Vector2i(4, 3), Vector2i(4, 2)]
	var equipment: Array = [{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)}]
	var reader := FakeCongestionReader.new()
	reader.set_prev(1, 1.0)
	var rig := _make_rig(109, equipment, reader, walls)
	var path: Array = rig["navigation"].call("get_path", ENTRANCE, Vector2i(3, 2))
	_check(path.is_empty(), "AC12[edge]: precondition — access cell unreachable (path empty)")
	_inject_member(rig, _make_member(100, "SELECTING_TARGET", 0, 3, ENTRANCE))

	_run_ticks(rig, 1)

	var m := _find_member(rig, 100)
	_check(not m.is_empty() and str(m["state"]) == "LEAVING",
		"AC12[edge]: zero survivors after path-check -> LEAVING same tick, no crash (state=%s)" % ("" if m.is_empty() else str(m["state"])))


# === AC20: deterministic tie-break by ascending equipment_instance_id ===

func _test_ac20_two_equal_weights_ascending_id() -> void:
	print("\n[AC20] two candidates with EQUAL weight -> tie-break by ascending equipment_instance_id")
	# Both access cells at Chebyshev distance 3 from (0,0), same congestion
	# (reader absent -> neutral 0.0), same novelty (fresh), same noise (1.0).
	var equipment: Array = [
		{"id": 5, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)},
		{"id": 2, "fp": Vector2i(2, 3), "ac": Vector2i(3, 3)},
	]
	var rig := _make_rig(110, equipment)
	_inject_member(rig, _make_member(100, "SELECTING_TARGET", 0, 3, ENTRANCE))
	var member: Dictionary = _find_member(rig, 100)

	var entries: Array = rig["member_sim"].call("_build_weighted_candidates", member) as Array
	_check(entries.size() == 2, "AC20: two candidates in the pool")
	if entries.size() == 2:
		var w_a: float = float(entries[0]["weight"])
		var w_b: float = float(entries[1]["weight"])
		_check(absf(w_a - w_b) < 1e-12, "AC20: precondition — weights are equal (%.12f vs %.12f)" % [w_a, w_b])
		var sorted: Array = entries.duplicate()
		rig["member_sim"].call("_sort_candidates_by_weight", sorted)
		_check(int(sorted[0]["instance_id"]) == 2 and int(sorted[1]["instance_id"]) == 5,
			"AC20: equal weights resolve ascending id 2 before 5 (got %s)" % str([int(sorted[0]["instance_id"]), int(sorted[1]["instance_id"])]))


func _test_ac20_three_equal_weights_ascending_id() -> void:
	print("\n[AC20 edge] 3+ candidates ALL equal weight -> deterministic ascending id order")
	var equipment: Array = [
		{"id": 7, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)},
		{"id": 3, "fp": Vector2i(2, 3), "ac": Vector2i(3, 3)},
		{"id": 1, "fp": Vector2i(1, 3), "ac": Vector2i(0, 3)},
	]
	# All three access cells at Chebyshev distance 3 from (0,0): (3,2), (3,3),
	# (0,3) — max(|dx|,|dy|) == 3 for each.
	var rig := _make_rig(111, equipment)
	_inject_member(rig, _make_member(100, "SELECTING_TARGET", 0, 3, ENTRANCE))
	var member: Dictionary = _find_member(rig, 100)

	var entries: Array = rig["member_sim"].call("_build_weighted_candidates", member) as Array
	_check(entries.size() == 3, "AC20[3]: three candidates in the pool")
	if entries.size() == 3:
		var all_equal := true
		for e in entries:
			if absf(float(e["weight"]) - float(entries[0]["weight"])) > 1e-12:
				all_equal = false
		_check(all_equal, "AC20[3]: precondition — all three weights equal")
		var sorted: Array = entries.duplicate()
		rig["member_sim"].call("_sort_candidates_by_weight", sorted)
		_check(
			int(sorted[0]["instance_id"]) == 1 and int(sorted[1]["instance_id"]) == 3 and int(sorted[2]["instance_id"]) == 7,
			"AC20[3]: deterministic ascending id 1,3,7 (got %s)" % str([int(sorted[0]["instance_id"]), int(sorted[1]["instance_id"]), int(sorted[2]["instance_id"])])
		)


func _test_ac20_deterministic_same_seed_same_target() -> void:
	print("\n[AC20][INT] same seed + equal weights -> both runs choose the SAME target (deterministic end-to-end)")
	var equipment: Array = [
		{"id": 5, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)},
		{"id": 2, "fp": Vector2i(2, 3), "ac": Vector2i(3, 3)},
	]
	var rig_a := _make_rig(0xAC20AC20, equipment)
	var rig_b := _make_rig(0xAC20AC20, equipment)
	_inject_member(rig_a, _make_member(100, "SELECTING_TARGET", 0, 3, ENTRANCE))
	_inject_member(rig_b, _make_member(100, "SELECTING_TARGET", 0, 3, ENTRANCE))

	_run_ticks(rig_a, 1)
	_run_ticks(rig_b, 1)

	var ma := _find_member(rig_a, 100)
	var mb := _find_member(rig_b, 100)
	var ta := int(ma["target_equipment_instance_id"])
	var tb := int(mb["target_equipment_instance_id"])
	_check(ta == tb, "AC20[INT]: same seed -> same chosen target (got %d vs %d)" % [ta, tb])
	_check(ta == 2 or ta == 5, "AC20[INT]: target is one of the equal-weight candidates (got %d)" % ta)
