# tests/unit/member_sim/reservation_map_test.gd
# Story MS-003: Reservation Map and Contention
# (production/epics/member-sim/story-003-reservation-map-contention.md)
#
# Covers the BLOCKING ACs (TR-MS-004 / TR-MS-005 / TR-MS-006):
#   - AC3 [UNIT][WB] members 5 and 7 both target the same free equipment on
#     one tick -> 5 becomes occupant; 7's redraw EXCLUDES that equipment
#     (the fully-spoken-for pool filter). Edge: 7 with no other candidate
#     STAYS in SELECTING_TARGET and retries next tick (never LEAVING from a
#     pure contention loss).
#   - AC4 [UNIT] property test over N randomized ticks (3 seeds x 150 ticks):
#     at every tick boundary, any equipment's reservation record has at most
#     one occupant and at most one next_claimant; no member double-books
#     (one occupant role + one claimant role max across the whole map, never
#     both simultaneously); the map is CONSISTENT with member states
#     (WALKING_TO/QUEUEING member == its target's next_claimant, USING member
#     == its target's occupant).
#   - AC5 [UNIT] release invariant: a member holding next_claimant that
#     leaves WALKING_TO (path blocked) or QUEUEING (patience exhausted)
#     without becoming occupant -> reservations[E].next_claimant is null by
#     the end of the SAME tick (deadlock prevention).
#   - AC16 [UNIT][WB] movement safety: at no tick does a WALKING_TO /
#     QUEUEING member's occupied cell equal a solid footprint cell
#     (GridSystem solid set as oracle); a QUEUEING member stands exactly one
#     cell short of the access cell (Chebyshev distance 1, never ON it) and
#     steps onto the access cell only when it becomes occupant.
# Plus story-scope contracts:
#   - queue depth is exactly 1 (MVP): a third member targeting a machine
#     whose next_claimant is already held stays in SELECTING_TARGET.
#   - candidate pool excludes fully-spoken-for machines for OTHER members but
#     a busy machine with a free queue slot remains claimable.
#   - determinism under contention (TR-MS-006): two rigs, same seed, same
#     timeline -> byte-identical trace INCLUDING the reservation map at every
#     tick (no engine/hash order anywhere in resolution).
#
# Run standalone: godot --headless --script tests/unit/member_sim/reservation_map_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const GRID_W := 8
const GRID_H := 6
const ENTRANCE := Vector2i(0, 0)
const EXIT := Vector2i(7, 5)

# Rotation value mirroring GridSystem.Rotation (degree-valued).
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
	print("  UNIT TEST: MemberSim — Reservation Map and Contention (Story MS-003)")
	print("=".repeat(48))

	_test_ac3_contention_lower_id_wins_and_queues()
	_test_ac3_arrival_clears_queue_slot()
	_test_ac3_redraw_excludes_claimed_machine()
	_test_ac3_no_other_candidate_stays_selecting()
	_test_ac4_property_invariants_randomized()
	_test_ac5_release_on_blocked_walk()
	_test_ac5_release_on_patience_exhaust()
	_test_ac16_walking_never_solid()
	_test_ac16_queueing_one_cell_short_then_occupant()
	_test_queue_depth_one()
	_test_pool_exclusion_free_vs_busy()
	_test_determinism_with_contention()

	print("\n=== RESERVATION MAP TEST: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


# === Helpers (mirror the MS-001/MS-002 rig) ===

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
## commits. [config] merges over the base (zero arrivals so only injected
## members run unless the test raises the arrival rate). Patience defaults to
## the GDD anchors 30-80; tests override where needed.
func _make_rig(
	seed: int,
	equipment: Array = [],
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
		"patience_min_ticks": 30,
		"patience_max_ticks": 80,
	}
	for k in config:
		cfg[k] = config[k]
	ms.call("init", orch, srg, gs, nav, cat, ENTRANCE, EXIT, cfg)
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
		"patience_ticks_remaining": 0,
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


func _reservations(rig: Dictionary) -> Dictionary:
	return rig["member_sim"].get("reservations") as Dictionary


## White-box: the member's candidate entries in ASCENDING id order (the fixed
## summation order — see _build_weighted_candidates). [WB] hook, no RNG.
func _candidates(rig: Dictionary, member: Dictionary) -> Array:
	return rig["member_sim"].call("_build_weighted_candidates", member) as Array


func _id_str(v: Variant) -> String:
	return "-" if v == null else str(int(v))


func _chebyshev(a: Vector2i, b: Vector2i) -> int:
	return maxi(absi(a.x - b.x), absi(a.y - b.y))


# === AC3: contention resolves by ascending member_id ===

func _test_ac3_contention_lower_id_wins_and_queues() -> void:
	print("\n[AC3] members 5 and 7 target the SAME free equipment on one tick -> 5 claims, walks, becomes occupant; 7 redraws, then queues behind 5")
	var equipment: Array = [{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)}]
	# use_duration 100000 keeps 5 USING long enough for 7 to arrive and queue.
	var cfg := {
		"use_duration_mean_ticks": 100000,
		"use_duration_stddev_ticks": 0,
		"use_duration_min_ticks": 1,
		"use_duration_max_ticks": 100000,
	}
	var rig := _make_rig(0xAC3001, equipment, [], cfg)
	_inject_member(rig, _make_member(5, "SELECTING_TARGET", 0, 3, ENTRANCE))
	_inject_member(rig, _make_member(7, "SELECTING_TARGET", 0, 3, ENTRANCE))

	_run_ticks(rig, 1)
	var res: Dictionary = _reservations(rig)
	_check(res.has(1) and res[1]["next_claimant"] == 5,
		"AC3: after one tick member 5 (lower id) holds the queue slot (next_claimant=%s)" % _id_str(res[1]["next_claimant"]))
	_check(res[1]["occupant"] == null, "AC3: machine still free (occupant null) while 5 walks")
	var m5 := _find_member(rig, 5)
	var m7 := _find_member(rig, 7)
	_check(not m5.is_empty() and str(m5["state"]) == "WALKING_TO" and int(m5["target_equipment_instance_id"]) == 1,
		"AC3: member 5 walking to the claimed machine (state=%s target=%s)" % [str(m5["state"]), str(m5.get("target_equipment_instance_id", -1))])

	# [WB] 7's redraw excludes the claimed equipment from its candidate pool.
	var c7: Array = _candidates(rig, m7)
	_check(c7.is_empty(), "AC3[WB]: member 7's redraw EXCLUDES the claimed machine (pool empty: %s)" % str(c7))

	# Keep ticking until 5 arrives and becomes occupant.
	var arrived := false
	var t := 1
	while t < 30 and not arrived:
		_run_ticks(rig, 1, t)
		t += 1
		res = _reservations(rig)
		if res.has(1) and res[1]["occupant"] == 5:
			arrived = true
	_check(arrived, "AC3: member 5 becomes occupant after walking (occupant=%s)" % _id_str(res[1]["occupant"]))
	# 5's own queue-slot claim is gone (it is the occupant now). 7 — updating
	# LATER in the same tick — may already have reclaimed the freed slot, so
	# the boundary value is "7 or momentarily free", never 5 (FIFO handoff).
	_check(res[1]["next_claimant"] != 5,
		"AC3: member 5's queue-slot claim cleared on arrival (now occupant; slot held by %s or free)" % _id_str(res[1]["next_claimant"]))

	# 7 reselects once 5 is occupant (queue slot free again), walks, queues.
	var queued := false
	t = 0
	while t < 40 and not queued:
		_run_ticks(rig, 1, t)
		t += 1
		var m7b := _find_member(rig, 7)
		if not m7b.is_empty() and str(m7b["state"]) == "QUEUEING":
			queued = true
	var m7c := _find_member(rig, 7)
	res = _reservations(rig)
	_check(queued, "AC3: member 7 eventually queues behind 5 (state=%s)" % ("" if m7c.is_empty() else str(m7c["state"])))
	_check(res[1]["occupant"] == 5 and res[1]["next_claimant"] == 7,
		"AC3: final reservation — occupant 5, queue slot 7 (occupant=%s next_claimant=%s)" % [_id_str(res[1]["occupant"]), _id_str(res[1]["next_claimant"])])
	_check(not m7c.is_empty() and _chebyshev(m7c["cell"], Vector2i(3, 2)) == 1 and m7c["cell"] != Vector2i(3, 2),
		"AC3: queuing member 7 stands one cell short of the access cell (cell=%s)" % ("" if m7c.is_empty() else str(m7c["cell"])))


func _test_ac3_arrival_clears_queue_slot() -> void:
	print("\n[AC3][FIFO] single member walks to a free machine -> on arrival reservations flip to {occupant: self, next_claimant: null} (queue slot cleared)")
	var equipment: Array = [{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)}]
	var cfg := {
		"use_duration_mean_ticks": 100000,
		"use_duration_stddev_ticks": 0,
		"use_duration_min_ticks": 1,
		"use_duration_max_ticks": 100000,
	}
	var rig := _make_rig(0xAC300F, equipment, [], cfg)
	_inject_member(rig, _make_member(5, "SELECTING_TARGET", 0, 3, ENTRANCE))
	var res: Dictionary = _reservations(rig)

	_run_ticks(rig, 1)
	res = _reservations(rig)
	_check(res.has(1) and res[1]["next_claimant"] == 5 and res[1]["occupant"] == null,
		"AC3[FIFO]: pre-arrival — member 5 holds the queue slot (occupant=%s next_claimant=%s)" % [_id_str(res[1]["occupant"]), _id_str(res[1]["next_claimant"])])

	var arrived_at: Array = []
	for t in 30:
		_run_ticks(rig, 1, 1 + t)
		res = _reservations(rig)
		if res[1]["occupant"] == 5:
			arrived_at = [t, res[1]["next_claimant"]]
			break
	_check(not arrived_at.is_empty() and arrived_at[1] == null,
		"AC3[FIFO]: on arrival the queue slot is cleared — {occupant: 5, next_claimant: null} (got next_claimant=%s at tick %s)" % [_id_str(arrived_at[1]), str(arrived_at[0])])


func _test_ac3_redraw_excludes_claimed_machine() -> void:
	print("\n[AC3][WB] two machines; 5 claims E1 -> 7's redraw picks the OTHER machine (claimed one excluded)")
	var equipment: Array = [
		{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)},
		{"id": 2, "fp": Vector2i(5, 2), "ac": Vector2i(6, 2)},
	]
	var rig := _make_rig(0xAC3002, equipment)
	_inject_member(rig, _make_member(5, "SELECTING_TARGET", 0, 3, ENTRANCE))
	_inject_member(rig, _make_member(7, "SELECTING_TARGET", 0, 3, ENTRANCE))

	_run_ticks(rig, 1)
	var m5 := _find_member(rig, 5)
	var m7 := _find_member(rig, 7)
	var res: Dictionary = _reservations(rig)
	_check(not m5.is_empty() and int(m5["target_equipment_instance_id"]) == 1,
		"AC3[WB]: member 5 claimed E1 (target=%s)" % str(m5.get("target_equipment_instance_id", -1)))
	_check(not m7.is_empty() and int(m7["target_equipment_instance_id"]) == 2,
		"AC3[WB]: member 7's redraw EXCLUDED E1 and picked E2 (target=%s)" % str(m7.get("target_equipment_instance_id", -1)))
	_check(res.has(1) and res[1]["next_claimant"] == 5 and res.has(2) and res[2]["next_claimant"] == 7,
		"AC3[WB]: each member holds its own machine's queue slot (E1:%s E2:%s)" % [_id_str(res[1]["next_claimant"]), _id_str(res[2]["next_claimant"])])


func _test_ac3_no_other_candidate_stays_selecting() -> void:
	print("\n[AC3 QA edge] loser with NO other candidate STAYS in SELECTING_TARGET (retries next tick — never LEAVING from pure contention)")
	var equipment: Array = [{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)}]
	var rig := _make_rig(0xAC3003, equipment)
	_inject_member(rig, _make_member(5, "SELECTING_TARGET", 0, 3, ENTRANCE))
	_inject_member(rig, _make_member(7, "SELECTING_TARGET", 0, 3, ENTRANCE))

	_run_ticks(rig, 1)
	var m7 := _find_member(rig, 7)
	_check(not m7.is_empty() and str(m7["state"]) == "SELECTING_TARGET",
		"AC3[edge]: member 7 stays SELECTING_TARGET at the tick boundary (got %s)" % ("" if m7.is_empty() else str(m7["state"])))
	_check(not m7.is_empty() and str(m7.get("leaving_reason", "")) != "no_candidates",
		"AC3[edge]: NOT a no-candidates departure (leaving_reason=%s)" % str(m7.get("leaving_reason", "")))

	# It retries next tick: still claimed (5 walking) -> stays. Then once 5
	# arrives and releases the queue slot, the retry SUCCEEDS.
	var still_trying := true
	for i in 3:
		_run_ticks(rig, 1, 1 + i)
		var m7b := _find_member(rig, 7)
		if m7b.is_empty() or str(m7b["state"]) != "SELECTING_TARGET":
			still_trying = false
	_check(still_trying, "AC3[edge]: member 7 keeps retrying while the slot stays claimed (3 ticks)")
	# Now wait for 5 to arrive (occupant) — slot frees — 7's retry succeeds.
	var retried_ok := false
	for i in 40:
		_run_ticks(rig, 1, 4 + i)
		var m7c := _find_member(rig, 7)
		if not m7c.is_empty() and str(m7c["state"]) != "SELECTING_TARGET":
			retried_ok = true
			break
	_check(retried_ok, "AC3[edge]: the retry eventually claims the freed slot (state=%s)" % str(_find_member(rig, 7).get("state", "")))


# === AC4: capacity property over N randomized ticks ===

## Property assertions run at EVERY tick boundary of a randomized timeline.
## Violations are accumulated (no per-assert printing — the property test
## would otherwise emit thousands of PASS lines) and asserted once per seed.
func _test_ac4_property_invariants_randomized() -> void:
	print("\n[AC4] property test over 3 seeds x 150 randomized ticks: at most 1 occupant + 1 next_claimant per record; no member double-books; map consistent with member states; no solid-cell occupation")
	var equipment: Array = [
		{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)},
		{"id": 2, "fp": Vector2i(5, 2), "ac": Vector2i(6, 2)},
		{"id": 3, "fp": Vector2i(2, 4), "ac": Vector2i(3, 4)},
		{"id": 4, "fp": Vector2i(5, 4), "ac": Vector2i(6, 4)},
	]
	var cfg := {
		"base_arrival_rate_per_min": 480.0,  # p ~ 0.8/tick — heavy contention
		"max_concurrent_members": 8,
		"use_duration_mean_ticks": 4,
		"use_duration_stddev_ticks": 0,
		"use_duration_min_ticks": 1,
		"use_duration_max_ticks": 6,
		"leaving_timeout_ticks": 300,
		"patience_min_ticks": 5,   # short patience -> give-ups exercise AC5 release
		"patience_max_ticks": 8,
	}
	var total_checks := 0
	var total_violations := 0
	for seed in [0xAC40A1, 0xAC40A2, 0xAC40A3]:
		var rig := _make_rig(seed, equipment, [], cfg)
		var violations: Array = []
		var checks := 0
		for t in 150:
			rig["member_sim"].call("on_tick", t)
			checks += _property_checks(rig, t, violations)
		total_checks += checks
		total_violations += violations.size()
		if violations.is_empty():
			_check(true, "AC4[seed 0x%X]: %d boundary checks, ZERO violations" % [seed, checks])
		else:
			_check(false, "AC4[seed 0x%X]: %d violations of %d checks (first: %s)" % [seed, violations.size(), checks, str(violations[0])])
	_check(total_violations == 0, "AC4: %d total boundary checks across all seeds, %d violations" % [total_checks, total_violations])


## Runs the AC4 invariant set once for a rig at a tick boundary. Returns the
## number of checks performed; appends human-readable violations.
func _property_checks(rig: Dictionary, tick: int, violations: Array) -> int:
	var checks := 0
	var res: Dictionary = _reservations(rig)
	var occupant_owner: Dictionary = {}  # member_id -> equipment_instance_id
	var claimant_owner: Dictionary = {}  # member_id -> equipment_instance_id
	var member_sim: Object = rig["member_sim"]

	for eq_id in res.keys():
		var rec: Dictionary = res[eq_id]
		checks += 1
		if rec["occupant"] != null and typeof(rec["occupant"]) != TYPE_INT:
			violations.append("t%d E%d occupant not an int" % [tick, eq_id])
		checks += 1
		if rec["next_claimant"] != null and typeof(rec["next_claimant"]) != TYPE_INT:
			violations.append("t%d E%d next_claimant not an int" % [tick, eq_id])
		if rec["occupant"] != null:
			var mid := int(rec["occupant"])
			checks += 1
			if occupant_owner.has(mid):
				violations.append("t%d member %d occupant of BOTH E%d and E%d" % [tick, mid, eq_id, int(occupant_owner[mid])])
			else:
				occupant_owner[mid] = eq_id
		if rec["next_claimant"] != null:
			var mid2 := int(rec["next_claimant"])
			checks += 1
			if claimant_owner.has(mid2):
				violations.append("t%d member %d next_claimant of BOTH E%d and E%d" % [tick, mid2, eq_id, int(claimant_owner[mid2])])
			else:
				claimant_owner[mid2] = eq_id

	# Role exclusivity: no member is simultaneously an occupant AND a claimant
	# (even of different machines).
	for mid in occupant_owner.keys():
		checks += 1
		if claimant_owner.has(mid):
			violations.append("t%d member %d BOTH occupant of E%d and claimant of E%d" % [tick, mid, int(occupant_owner[mid]), int(claimant_owner[mid])])

	# Consistency with member states + AC16 solid oracle.
	for m in (member_sim.get("members") as Array):
		if not (m is Dictionary) or not m.has("state"):
			continue
		var cell: Vector2i = m["cell"]
		checks += 1
		if rig["grid_system"].call("is_solid", cell):
			violations.append("t%d member %d on SOLID cell %s" % [tick, int(m["member_id"]), str(cell)])
		var target := int(m.get("target_equipment_instance_id", -1))
		var st := str(m["state"])
		if target >= 0 and (st == "WALKING_TO" or st == "QUEUEING"):
			checks += 1
			var rec: Variant = res.get(target)
			if not (rec is Dictionary) or rec["next_claimant"] != int(m["member_id"]):
				violations.append("t%d member %d in %s but NOT next_claimant of E%d" % [tick, int(m["member_id"]), st, target])
		elif target >= 0 and st == "USING":
			checks += 1
			var rec2: Variant = res.get(target)
			if not (rec2 is Dictionary) or rec2["occupant"] != int(m["member_id"]):
				violations.append("t%d member %d USING but NOT occupant of E%d" % [tick, int(m["member_id"]), target])
	return checks


# === AC5: release invariant (deadlock prevention) ===

func _test_ac5_release_on_blocked_walk() -> void:
	print("\n[AC5] WALKING_TO member holding next_claimant; path becomes FULLY blocked -> releases the SAME tick")
	var equipment: Array = [{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)}]
	# Wall (0,1) + equipment 2 footprint (1,0) FULLY ENCLOSE the member's cell
	# (0,0) — so the Story 004 repath (grid_version mismatch -> re-query) comes
	# back EMPTY, which is what triggers the release. (A merely-blocked path
	# would be re-pathed AROUND and the member would keep walking — that is
	# the new formal behavior, covered by path_invalidation_test.gd.)
	var rig := _make_rig(0xAC5001, equipment, [Vector2i(0, 1)])
	# Arm: member 100 mid-walk to E1 holding the queue slot; next hop (1,0).
	_inject_member(rig, _make_member(100, "WALKING_TO", 0, 3, Vector2i(0, 0), {
		"target_equipment_instance_id": 1,
		"cached_path": [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(3, 0), Vector2i(3, 1), Vector2i(3, 2)],
	}))
	var res: Dictionary = _reservations(rig)
	res[1] = {"occupant": null, "next_claimant": 100}

	# Commit a second machine whose footprint covers (1,0) — grid_changed
	# re-syncs Navigation solidity AND bumps the grid_version stamp, so the
	# member's cached path is invalidated and re-queried next tick.
	_commit_equipment(rig["grid_system"], 2, Vector2i(1, 0), Vector2i(1, 1))
	_check(rig["grid_system"].call("is_solid", Vector2i(1, 0)), "AC5: precondition — next path cell (1,0) is solid after the commit")
	_check(rig["navigation"].call("get_path", Vector2i(0, 0), Vector2i(3, 2)).is_empty(),
		"AC5: precondition — (0,0) fully enclosed, repath returns empty")

	_run_ticks(rig, 1)
	res = _reservations(rig)
	var m := _find_member(rig, 100)
	_check(not m.is_empty() and str(m["state"]) == "SELECTING_TARGET",
		"AC5: member released and reselected by end of the SAME tick (state=%s)" % ("" if m.is_empty() else str(m["state"])))
	_check(res.has(1) and res[1]["next_claimant"] == null,
		"AC5: reservations[E].next_claimant == null by end of the same tick (got %s)" % _id_str(res[1]["next_claimant"]))


func _test_ac5_release_on_patience_exhaust() -> void:
	print("\n[AC5] QUEUEING member holding next_claimant; patience exhausted -> releases the SAME tick (calm give-up)")
	var equipment: Array = [{"id": 1, "fp": Vector2i(4, 2), "ac": Vector2i(3, 2)}]
	var rig := _make_rig(0xAC5002, equipment)
	# Occupant 100 using E1 for a very long time; claimant 200 queuing one
	# cell short with patience = 1 (give up next tick).
	_inject_member(rig, _make_member(100, "USING", 0, 3, Vector2i(3, 2), {
		"target_equipment_instance_id": 1,
		"use_ticks_remaining": 100000,
	}))
	_inject_member(rig, _make_member(200, "QUEUEING", 0, 3, Vector2i(2, 2), {
		"target_equipment_instance_id": 1,
		"patience_ticks_remaining": 1,
	}))
	var res: Dictionary = _reservations(rig)
	res[1] = {"occupant": 100, "next_claimant": 200}

	_run_ticks(rig, 1)
	res = _reservations(rig)
	var m := _find_member(rig, 200)
	_check(not m.is_empty() and str(m["state"]) == "SELECTING_TARGET",
		"AC5: patience-exhausted member reselects by end of the SAME tick (state=%s)" % ("" if m.is_empty() else str(m["state"])))
	_check(res.has(1) and res[1]["next_claimant"] == null,
		"AC5: reservations[E].next_claimant == null by end of the same tick (got %s)" % _id_str(res[1]["next_claimant"]))
	_check(res[1]["occupant"] == 100, "AC5: the occupant's claim is untouched (occupant=%s)" % _id_str(res[1]["occupant"]))
	_check(not m.is_empty() and m["cell"] == Vector2i(2, 2),
		"AC5: member never stepped onto the occupied access cell (cell=%s)" % ("" if m.is_empty() else str(m["cell"])))


# === AC16: movement safety against the solid set ===

func _test_ac16_walking_never_solid() -> void:
	print("\n[AC16] WALKING_TO member: at NO tick does its occupied cell equal a solid footprint cell (GridSystem solid set as oracle)")
	var equipment: Array = [
		{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)},
		{"id": 2, "fp": Vector2i(5, 2), "ac": Vector2i(6, 2)},
		{"id": 3, "fp": Vector2i(2, 4), "ac": Vector2i(3, 4)},
	]
	var rig := _make_rig(0xAC1601, equipment)
	_inject_member(rig, _make_member(100, "SELECTING_TARGET", 0, 1, ENTRANCE))

	var solid_hits: Array = []
	var walked_cells: Array = []
	for t in 60:
		rig["member_sim"].call("on_tick", t)
		var m := _find_member(rig, 100)
		if m.is_empty():
			break
		if str(m["state"]) == "WALKING_TO":
			walked_cells.append(m["cell"])
		if rig["grid_system"].call("is_solid", m["cell"]):
			solid_hits.append([t, m["cell"]])
	_check(walked_cells.size() > 0, "AC16: member actually walked (observed %d WALKING_TO ticks)" % walked_cells.size())
	_check(solid_hits.is_empty(), "AC16: no WALKING_TO/QUEUEING/… tick ever stood on a solid footprint cell (hits: %s)" % str(solid_hits))


func _test_ac16_queueing_one_cell_short_then_occupant() -> void:
	print("\n[AC16] QUEUEING member stops ONE CELL SHORT of the access cell; steps onto it only when it becomes occupant")
	var equipment: Array = [{"id": 1, "fp": Vector2i(4, 2), "ac": Vector2i(3, 2)}]
	var cfg := {
		"use_duration_mean_ticks": 5,
		"use_duration_stddev_ticks": 0,
		"use_duration_min_ticks": 1,
		"use_duration_max_ticks": 5,
		"patience_min_ticks": 100,
		"patience_max_ticks": 100,
	}
	var rig := _make_rig(0xAC1602, equipment, [], cfg)
	# Occupant 100 using E1 for 20 ticks; member 200 walks from the entrance.
	_inject_member(rig, _make_member(100, "USING", 0, 3, Vector2i(3, 2), {
		"target_equipment_instance_id": 1,
		"use_ticks_remaining": 20,
	}))
	_inject_member(rig, _make_member(200, "SELECTING_TARGET", 0, 3, ENTRANCE))
	var res: Dictionary = _reservations(rig)
	res[1] = {"occupant": 100, "next_claimant": null}

	# Walk until 200 queues (occupant 100 still busy).
	var queued_at: Array = []
	var t := 0
	while t < 20:
		_run_ticks(rig, 1, t)
		t += 1
		var m := _find_member(rig, 200)
		if not m.is_empty() and str(m["state"]) == "QUEUEING":
			queued_at = [t, m["cell"]]
			break
	_check(not queued_at.is_empty(), "AC16: member 200 reached QUEUEING while the machine was busy")
	if not queued_at.is_empty():
		var qcell: Vector2i = queued_at[1]
		_check(qcell != Vector2i(3, 2) and _chebyshev(qcell, Vector2i(3, 2)) == 1,
			"AC16: queue position is exactly one cell short of the access cell (cell=%s, chebyshev=%d)" % [str(qcell), _chebyshev(qcell, Vector2i(3, 2))])
		_check(not rig["grid_system"].call("is_solid", qcell), "AC16: the one-cell-short queue position is not a solid footprint cell")

	# While QUEUEING, the member must keep standing one cell short (no drift).
	var drifted := false
	for i in 10:
		_run_ticks(rig, 1, t + i)
		var m := _find_member(rig, 200)
		if not m.is_empty() and str(m["state"]) == "QUEUEING" and m["cell"] != queued_at[1]:
			drifted = true
	_check(not drifted, "AC16: QUEUEING member never drifts off its one-cell-short position")

	# 100 finishes (20 ticks) -> releases -> 200 (higher id, later in the same
	# tick) steps onto the access cell and becomes occupant.
	var became_occupant := false
	var m2: Dictionary = {}
	while t < 40:
		_run_ticks(rig, 1, t)
		t += 1
		m2 = _find_member(rig, 200)
		if not m2.is_empty() and str(m2["state"]) == "USING":
			became_occupant = true
			break
	_check(became_occupant, "AC16: queuing member becomes occupant when the machine frees (state=%s)" % ("" if m2.is_empty() else str(m2["state"])))
	if became_occupant:
		_check(m2["cell"] == Vector2i(3, 2), "AC16: new occupant stands ON the access cell (cell=%s)" % str(m2["cell"]))
		res = _reservations(rig)
		_check(res[1]["occupant"] == 200 and res[1]["next_claimant"] == null,
			"AC16: reservation flipped to occupant 200 (occupant=%s next_claimant=%s)" % [_id_str(res[1]["occupant"]), _id_str(res[1]["next_claimant"])])


# === Queue depth = 1 (MVP guardrail) ===

func _test_queue_depth_one() -> void:
	print("\n[queue depth] THREE members, ONE machine -> exactly one next_claimant ever; the third stays SELECTING_TARGET")
	var equipment: Array = [{"id": 1, "fp": Vector2i(4, 2), "ac": Vector2i(3, 2)}]
	var cfg := {
		"use_duration_mean_ticks": 100000,
		"use_duration_stddev_ticks": 0,
		"use_duration_min_ticks": 1,
		"use_duration_max_ticks": 100000,
	}
	var rig := _make_rig(0xACD001, equipment, [], cfg)
	_inject_member(rig, _make_member(100, "USING", 0, 3, Vector2i(3, 2), {
		"target_equipment_instance_id": 1,
		"use_ticks_remaining": 100000,
	}))
	_inject_member(rig, _make_member(200, "SELECTING_TARGET", 0, 3, ENTRANCE))
	_inject_member(rig, _make_member(300, "SELECTING_TARGET", 0, 3, ENTRANCE))
	var res: Dictionary = _reservations(rig)
	res[1] = {"occupant": 100, "next_claimant": null}

	_run_ticks(rig, 1)
	res = _reservations(rig)
	var m300 := _find_member(rig, 300)
	_check(res[1]["next_claimant"] == 200, "queue depth: member 200 (first in line) holds the single queue slot (got %s)" % _id_str(res[1]["next_claimant"]))
	_check(not m300.is_empty() and str(m300["state"]) == "SELECTING_TARGET",
		"queue depth: member 300 CANNOT claim — stays SELECTING_TARGET (state=%s)" % ("" if m300.is_empty() else str(m300["state"])))

	# Even after 200 reaches the machine (still busy) the depth stays 1 — 300
	# never squeezes in.
	for i in 8:
		_run_ticks(rig, 1, 1 + i)
	res = _reservations(rig)
	m300 = _find_member(rig, 300)
	_check(res[1]["next_claimant"] == 200, "queue depth: still exactly one claimant after arrival (got %s)" % _id_str(res[1]["next_claimant"]))
	_check(not m300.is_empty() and str(m300["state"]) == "SELECTING_TARGET",
		"queue depth: member 300 still excluded (state=%s)" % ("" if m300.is_empty() else str(m300["state"])))


# === Candidate pool composition (supports AC3 redraw) ===

func _test_pool_exclusion_free_vs_busy() -> void:
	print("\n[pool] fully-spoken-for machine excluded; free machine AND busy-with-free-queue-slot included")
	var equipment: Array = [
		{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)},
		{"id": 2, "fp": Vector2i(5, 2), "ac": Vector2i(6, 2)},
		{"id": 3, "fp": Vector2i(2, 4), "ac": Vector2i(3, 4)},
	]
	var rig := _make_rig(0xACB001, equipment)
	var res: Dictionary = _reservations(rig)
	res[1] = {"occupant": null, "next_claimant": null}   # free machine
	res[2] = {"occupant": 50, "next_claimant": null}     # busy, queue slot free
	res[3] = {"occupant": 60, "next_claimant": 61}       # busy AND claimed
	_inject_member(rig, _make_member(100, "SELECTING_TARGET", 0, 3, ENTRANCE))
	var member: Dictionary = _find_member(rig, 100)

	var entries: Array = _candidates(rig, member)
	var ids: Array = []
	for e in entries:
		ids.append(int(e["instance_id"]))
	ids.sort()
	_check(ids == [1, 2], "pool: claimed machine 3 excluded; free 1 + busy-but-claimable 2 included (got %s)" % str(ids))


# === TR-MS-006: determinism under contention ===

func _test_determinism_with_contention() -> void:
	print("\n[TR-MS-006] two rigs, same seed, heavy contention -> byte-identical trace INCLUDING the reservation map at every tick")
	var equipment: Array = [
		{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)},
		{"id": 2, "fp": Vector2i(5, 2), "ac": Vector2i(6, 2)},
		{"id": 3, "fp": Vector2i(2, 4), "ac": Vector2i(3, 4)},
	]
	var cfg := {
		"base_arrival_rate_per_min": 480.0,
		"max_concurrent_members": 6,
		"use_duration_mean_ticks": 4,
		"use_duration_stddev_ticks": 0,
		"use_duration_min_ticks": 1,
		"use_duration_max_ticks": 6,
		"patience_min_ticks": 6,
		"patience_max_ticks": 9,
	}
	var rig_a := _make_rig(0xD3D3D3, equipment, [], cfg)
	var rig_b := _make_rig(0xD3D3D3, equipment, [], cfg)

	var identical := true
	var first_divergence := -1
	for t in 120:
		rig_a["member_sim"].call("on_tick", t)
		rig_b["member_sim"].call("on_tick", t)
		if _trace(rig_a) != _trace(rig_b):
			identical = false
			first_divergence = t
			break
	_check(identical, "TR-MS-006: full trace (members + reservations + RNG state) byte-identical across two rigs (first divergence at tick %d)" % first_divergence)
	# The run must actually have exercised contention.
	var res_a: Dictionary = _reservations(rig_a)
	var res_b: Dictionary = _reservations(rig_b)
	_check(not res_a.is_empty(), "TR-MS-006: reservations were actually exercised (records: %d)" % res_a.size())
	_check(not res_b.is_empty() and res_a.size() == res_b.size(), "TR-MS-006: both rigs hold the same reservation records")


## Deterministic trace: members ascending id ("id:state:x,y:target"), then
## reservations sorted by equipment_instance_id ("E:o=<occ>:c=<claim>"),
## then the MemberSim RNG stream state. Two rigs with the same seed must
## produce identical traces at every tick.
func _trace(rig: Dictionary) -> String:
	var members: Array = rig["member_sim"].get("members")
	var by_id: Dictionary = {}
	for m in members:
		if m is Dictionary and m.has("member_id"):
			by_id[int(m["member_id"])] = m
	var ids: Array = by_id.keys()
	ids.sort()
	var parts: Array[String] = []
	for id in ids:
		var m: Dictionary = by_id[id]
		parts.append("%d:%s:%s:%d" % [id, str(m["state"]), str(m["cell"]), int(m.get("target_equipment_instance_id", -1))])
	var res: Dictionary = _reservations(rig)
	var eq_ids: Array = res.keys()
	eq_ids.sort()
	for eq_id in eq_ids:
		var rec: Dictionary = res[eq_id]
		parts.append("E%d:o=%s:c=%s" % [eq_id, _id_str(rec["occupant"]), _id_str(rec["next_claimant"])])
	var rng_state: int = int(rig["seeded_rng"].call("get_rng", "MemberSim").state)
	return "%s|%x" % [",".join(parts), rng_state]
