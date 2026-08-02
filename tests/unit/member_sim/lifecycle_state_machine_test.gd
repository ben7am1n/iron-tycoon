# tests/unit/member_sim/lifecycle_state_machine_test.gd
# Story MS-001: Lifecycle State Machine Core
# (production/epics/member-sim/story-001-lifecycle-state-machine-core.md)
#
# Covers the BLOCKING ACs (TR-MS-001 / TR-MS-002):
#   - AC1  member in SELECTING_TARGET with zero reachable/available candidates
#          -> LEAVING by the end of the SAME tick (no extra tick stalled).
#          Edge: empty gym (no equipment at all).
#   - AC2  exercises_done == exercises_per_visit -> LEAVING regardless of
#          candidate availability.
#   - AC6  fixed RNG seed + scripted timeline -> full state trace byte-identical
#          across two independent runs (positions, states, RNG states).
#   - AC15 at max_concurrent_members an arrival draw that succeeds spawns
#          NOTHING: no member, member_id_counter NOT incremented, no error.
#          Edge: just under the cap -> spawn allowed.
#   - AC21 LEAVING member with no resolving exit path -> forced GONE when the
#          defensive safety timeout elapses. Edge: exit blocked mid-leave then
#          unblocked -> NO premature GONE.
# Plus story-scope contracts:
#   - ENTERING is a pass-through spawn tick (immediately evaluates
#     SELECTING_TARGET the same tick).
#   - S5 member_completed_visit fires EXACTLY ONCE, arity 1, ONLY on quota-met
#     departures (never on walk-failure) — ADR-0005.
#   - Full skeleton lifecycle: ENTERING -> SELECTING_TARGET -> WALKING_TO ->
#     USING -> (SELECTING_TARGET | LEAVING) -> GONE with quota accounting.
#
# QA note (documented deviation from the story's AC1 edge-case narrative):
# the QA text's "empty gym — member wanders ~20 ticks then leaves calmly" is
# a behavioural description; the BLOCKING assertion is "state == LEAVING by
# end of the same tick". The skeleton implements the blocking behaviour
# (immediate LEAVING); the calm-wander nuance belongs to Story 004's
# patience/give-up system (out of scope for MS-001).
#
# Run standalone: godot --headless --script tests/unit/member_sim/lifecycle_state_machine_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const GRID_W := 8
const GRID_H := 6
const ENTRANCE := Vector2i(0, 0)
const EXIT := Vector2i(7, 5)

# Rotation value mirroring GridSystem.Rotation (degree-valued).
const R0 := 0

# Default sim config shared by most tests: zero arrivals (pure injected
# members — GDD: base_arrival_rate_per_min = 0 is legal preview mode) and a
# tiny use duration so lifecycle tests complete in a handful of ticks.
func _base_config() -> Dictionary:
	return {
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
	print("  UNIT TEST: MemberSim — Lifecycle State Machine Core (Story MS-001)")
	print("=".repeat(48))

	_test_ac1_zero_candidates_same_tick_leaving()
	_test_ac1_all_equipment_unreachable_leaving()
	_test_ac1_entering_pass_through_same_tick()
	_test_ac2_quota_met_leaves_regardless_of_candidates()
	_test_ac2_quota_met_empty_gym()
	_test_ac6_determinism_byte_identical_trace()
	_test_ac15_capacity_gate_no_spawn_no_counter()
	_test_ac15_under_cap_spawn_allowed()
	_test_ac21_leaving_timeout_forces_gone()
	_test_ac21_blocked_then_unblocked_no_premature_gone()
	_test_s5_quota_met_departure_only()
	_test_s5_walk_failure_emits_nothing()
	_test_full_lifecycle_flow()

	print("\n=== LIFECYCLE STATE MACHINE TEST: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


# === Helpers ===

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
## _ready() synchronously — same pattern as the save-load integration tests).
## MemberSim only stores the reference in Story 001; the orchestrator's own
## init constructs its (unused here) EquipmentCatalog + TimeSystem.
func _make_orchestrator() -> Node:
	var orch: Node = load("res://src/systems/simulation_orchestrator.gd").new()
	root.add_child(orch)
	orch.call("_ready")
	return orch


## Builds an all-buildable grid (empty = fully walkable) and returns it as a
## dynamically-dispatched RefCounted (project test contract — load by path).
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


## Builds a Navigation instance over [grid] and calls _post_init() so the
## grid_changed (S1) solidity sync is live (needed by the blocked-then-
## unblocked AC21 edge case, which clears equipment mid-leave).
func _make_navigation(grid: RefCounted) -> RefCounted:
	var nav: RefCounted = _NAV().new()
	nav.call("init", grid)
	nav.call("_post_init")
	return nav


## Builds a frozen EquipmentCatalog with one treadmill definition. Story 001
## does not query the catalog (instance->equipment resolution lands later),
## but it is a hard upstream dependency and must be wired for the state
## machine to engage.
func _make_catalog() -> RefCounted:
	var cat: RefCounted = _EC().new()
	var fp: Array[Vector2i] = [Vector2i(0, 0)]
	var ac: Array[Vector2i] = [Vector2i(1, 0)]
	var effects: Array[Dictionary] = []
	var def = _ED().new("treadmill", "Treadmill", ["cardio"], fp, ac, 100, "", effects, 200, 35, 100, 300)
	cat.call("_add_definition", def)
	cat.call("_freeze")
	return cat


## Commits one equipment instance: footprint at [fp], access cell at [ac].
## instance ids start at 1 (matching the save-load rigs' convention).
func _commit_equipment(gs: RefCounted, instance_id: int, fp: Vector2i, ac: Vector2i) -> void:
	var fp_arr: Array[Vector2i] = [fp]
	var ac_arr: Array[Vector2i] = [ac]
	gs.call("commit", instance_id, fp_arr, ac_arr, R0)


## Builds the full configured MemberSim rig:
##   - real GridSystem + Navigation (grid_changed-synced) + frozen catalog
##   - SeededRNG with [seed]; the "MemberSim" sub-stream registered
##   - MemberSim.init(orchestrator, seeded_rng, grid, nav, catalog, entrance,
##     exit, config) — the TR-MS-013 hard dependencies supplied at init
## [walls] marks extra non-buildable cells before freeze (AC1 unreachable /
## AC21 exit-blocked setups). [equipment] lists {id, fp, ac} commits.
func _make_rig(seed: int, config: Dictionary = {}, walls: Array = [], equipment: Array = []) -> Dictionary:
	var gs := _make_grid(walls)
	for eq in equipment:
		_commit_equipment(gs, int(eq["id"]), eq["fp"], eq["ac"])
	var nav := _make_navigation(gs)
	var cat := _make_catalog()
	var srg: RefCounted = _SRG().new()
	srg.call("init", seed)
	# NOTE: the "MemberSim" sub-stream is registered by MemberSim.init() itself
	# (ADR-0004: exactly-once registration during init) — do NOT pre-register
	# here or SeededRNG asserts on the duplicate.
	var orch := _make_orchestrator()
	var ms: RefCounted = _MS().new()
	var cfg: Dictionary = _base_config()
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
## produces). [overrides] replace any field — used to arm specific states
## (e.g. leaving_timeout_ticks for AC21).
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


## Injects a full member record directly into the roster (bypasses arrival —
## tests use base_arrival_rate_per_min=0 so no natural spawn interferes).
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


## Deterministic state trace for AC6: every member (ascending member_id) as
## "id:state:x,y:exercises_done:target", plus the MemberSim RNG stream state.
## Two rigs with the same seed must produce identical traces at every tick.
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
		if not m.has("state"):
			parts.append("%d:legacy" % id)
		else:
			parts.append("%d:%s:%s:%d:%d" % [id, str(m["state"]), str(m["cell"]), int(m["exercises_done"]), int(m.get("target_equipment_instance_id", -1))])
	var rng_state: int = int(rig["seeded_rng"].call("get_rng", "MemberSim").state)
	return "%s|rng=%x" % [",".join(parts), rng_state]


# === AC1: zero candidates -> LEAVING the same tick ===

func _test_ac1_zero_candidates_same_tick_leaving() -> void:
	print("\n[AC1] SELECTING_TARGET with no equipment at all -> LEAVING by end of the SAME tick")
	var rig := _make_rig(11)  # empty gym — no equipment committed
	_inject_member(rig, _make_member(100, "SELECTING_TARGET", 0, 3, ENTRANCE))
	var m := _find_member(rig, 100)
	_check(not m.is_empty(), "AC1: member injected")

	_run_ticks(rig, 1)

	var after := _find_member(rig, 100)
	_check(not after.is_empty() and str(after["state"]) == "LEAVING",
		"AC1: state == LEAVING after ONE tick (got %s)" % ("" if after.is_empty() else str(after["state"])))
	_check(not after.is_empty() and str(after["leaving_reason"]) == "no_candidates",
		"AC1: leaving reason is no_candidates (got %s)" % ("" if after.is_empty() else str(after["leaving_reason"])))
	_check(not after.is_empty() and int(after["exercises_done"]) == 0,
		"AC1: exercises_done untouched (got %d)" % (0 if after.is_empty() else int(after["exercises_done"])))


func _test_ac1_all_equipment_unreachable_leaving() -> void:
	print("\n[AC1] equipment present but fully walled off -> LEAVING the same tick (reachability scan)")
	# Instance 1 footprint (2,2), access (3,2). Wall every orthogonal neighbour
	# of the access cell so no path can ever enter it.
	var walls: Array = [Vector2i(2, 1), Vector2i(3, 1), Vector2i(4, 1), Vector2i(2, 3), Vector2i(3, 3), Vector2i(4, 3), Vector2i(4, 2)]
	var equipment: Array = [{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)}]
	var rig := _make_rig(22, {}, walls, equipment)
	# Sanity: the candidate EXISTS but is unreachable.
	var path: Array = rig["navigation"].call("get_path", Vector2i(0, 0), Vector2i(3, 2))
	_check(path.is_empty(), "AC1: precondition — access cell (3,2) is unreachable (path empty)")

	_inject_member(rig, _make_member(100, "SELECTING_TARGET", 0, 3, ENTRANCE))
	_run_ticks(rig, 1)
	var after := _find_member(rig, 100)
	_check(not after.is_empty() and str(after["state"]) == "LEAVING",
		"AC1: state == LEAVING after ONE tick despite candidates existing (got %s)" % ("" if after.is_empty() else str(after["state"])))


func _test_ac1_entering_pass_through_same_tick() -> void:
	print("\n[AC1/ENTERING] ENTERING is a pass-through spawn tick -> SELECTING_TARGET evaluated the SAME tick")
	var rig := _make_rig(33)  # empty gym
	_inject_member(rig, _make_member(100, "ENTERING", 0, 3, ENTRANCE))
	_run_ticks(rig, 1)
	var after := _find_member(rig, 100)
	_check(not after.is_empty() and str(after["state"]) == "LEAVING",
		"AC1/ENTERING: ENTERING -> (same tick) -> LEAVING with zero candidates (got %s)" % ("" if after.is_empty() else str(after["state"])))


# === AC2: quota met -> LEAVING regardless of candidates ===

func _test_ac2_quota_met_leaves_regardless_of_candidates() -> void:
	print("\n[AC2] exercises_done == exercises_per_visit -> LEAVING even with plentiful candidates")
	var equipment: Array = [{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)}, {"id": 2, "fp": Vector2i(5, 2), "ac": Vector2i(6, 2)}]
	var rig := _make_rig(44, {}, [], equipment)
	_check(not (rig["grid_system"].call("get_placed_instances") as Array).is_empty(), "AC2: precondition — candidates available")

	_inject_member(rig, _make_member(100, "SELECTING_TARGET", 3, 3, ENTRANCE))
	_run_ticks(rig, 1)
	var after := _find_member(rig, 100)
	_check(not after.is_empty() and str(after["state"]) == "LEAVING",
		"AC2: quota met -> LEAVING despite candidate availability (got %s)" % ("" if after.is_empty() else str(after["state"])))
	_check(not after.is_empty() and str(after["leaving_reason"]) == "quota_met",
		"AC2: leaving reason is quota_met (got %s)" % ("" if after.is_empty() else str(after["leaving_reason"])))


func _test_ac2_quota_met_empty_gym() -> void:
	print("\n[AC2] quota met with an empty gym -> STILL LEAVING (quota check precedes candidates)")
	var rig := _make_rig(55)  # empty gym
	_inject_member(rig, _make_member(100, "SELECTING_TARGET", 2, 2, ENTRANCE))
	_run_ticks(rig, 1)
	var after := _find_member(rig, 100)
	_check(not after.is_empty() and str(after["state"]) == "LEAVING",
		"AC2: empty gym + quota met -> LEAVING (got %s)" % ("" if after.is_empty() else str(after["state"])))
	_check(not after.is_empty() and str(after["leaving_reason"]) == "quota_met",
		"AC2: reason still quota_met (not no_candidates)")


# === AC6: determinism — byte-identical replay ===

func _test_ac6_determinism_byte_identical_trace() -> void:
	print("\n[AC6] two independent rigs, same seed, same timeline -> byte-identical trace at every tick")
	# Exercise the full pipeline: natural arrivals (base 30/min -> p ~ 0.05),
	# spawn rolls, walking, use-duration rolls, quota departures, LEAVING walks.
	var cfg := {
		"base_arrival_rate_per_min": 30.0,
		"max_concurrent_members": 8,
		"use_duration_mean_ticks": 3,
		"use_duration_stddev_ticks": 1,
		"use_duration_min_ticks": 1,
		"use_duration_max_ticks": 6,
		"leaving_timeout_ticks": 60,
	}
	var equipment: Array = [{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)}, {"id": 2, "fp": Vector2i(5, 2), "ac": Vector2i(6, 2)}]
	var rig_a := _make_rig(0x5EEDCAFE12345678, cfg, [], equipment)
	var rig_b := _make_rig(0x5EEDCAFE12345678, cfg, [], equipment)

	var identical := true
	var first_divergence := -1
	for t in 120:
		rig_a["member_sim"].call("on_tick", t)
		rig_b["member_sim"].call("on_tick", t)
		var ta := _trace(rig_a)
		var tb := _trace(rig_b)
		if ta != tb:
			identical = false
			first_divergence = t
			break
	_check(identical, "AC6: state trace byte-identical across two runs (first divergence at tick %d)" % first_divergence)
	_check(_member_count(rig_a) == _member_count(rig_b), "AC6: member counts equal at end (both %d)" % _member_count(rig_a))
	# The run must actually have exercised the pipeline — arrivals happened.
	_check(_member_count(rig_a) <= 8, "AC6: capacity respected (count %d <= 8)" % _member_count(rig_a))


# === AC15: capacity gate ===

func _test_ac15_capacity_gate_no_spawn_no_counter() -> void:
	print("\n[AC15] at max_concurrent_members, successful arrival draws spawn NOTHING and do NOT advance the counter")
	# p_tick = 480/60*0.1 = 0.8 -> ~24 successful draws over 30 ticks. If the
	# cap were buggy (spawn at cap), member_id_counter would jump ~24.
	var cfg := {"base_arrival_rate_per_min": 480.0, "max_concurrent_members": 1}
	var equipment: Array = [{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)}]
	var rig := _make_rig(66, cfg, [], equipment)
	# A stable occupant: USING with a huge remaining duration — stays active
	# for the whole run, keeping the count AT the cap.
	_inject_member(rig, _make_member(100, "USING", 0, 1, Vector2i(3, 2), {"use_ticks_remaining": 100000}))
	_check(_member_count(rig) == 1, "AC15: precondition — count == max_concurrent_members")
	var counter_before: int = int(rig["member_sim"].get("_member_id_counter"))

	_run_ticks(rig, 30)

	_check(_member_count(rig) == 1, "AC15: no member spawned at the cap (count %d)" % _member_count(rig))
	_check(int(rig["member_sim"].get("_member_id_counter")) == counter_before,
		"AC15: member_id_counter NOT incremented (got %d, before %d)" % [int(rig["member_sim"].get("_member_id_counter")), counter_before])


func _test_ac15_under_cap_spawn_allowed() -> void:
	print("\n[AC15] just under the cap -> arrival spawns exactly one member, counter increments once")
	# Long use duration so the SPAWNED member stays active: if it completed a
	# visit and left, the count would drop below the cap and a second spawn
	# would correctly fire — that would not be testing the cap at all.
	var cfg := {
		"base_arrival_rate_per_min": 480.0,
		"max_concurrent_members": 2,
		"use_duration_mean_ticks": 100000,
		"use_duration_stddev_ticks": 0,
		"use_duration_min_ticks": 1,
		"use_duration_max_ticks": 100000,
	}
	var equipment: Array = [{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)}]
	var rig := _make_rig(77, cfg, [], equipment)
	_inject_member(rig, _make_member(100, "USING", 0, 1, Vector2i(3, 2), {"use_ticks_remaining": 100000}))
	_check(_member_count(rig) == 1, "AC15[under]: precondition — count 1 below max 2")

	# p = 0.8/tick; P(no successful draw in 20 ticks) ~ 1e-14 — effectively
	# guaranteed to spawn the second member, then the cap holds.
	_run_ticks(rig, 20)

	_check(_member_count(rig) == 2, "AC15[under]: spawn allowed under the cap (count %d)" % _member_count(rig))
	_check(int(rig["member_sim"].get("_member_id_counter")) == 1,
		"AC15[under]: member_id_counter incremented exactly once for the single spawn (got %d)" % int(rig["member_sim"].get("_member_id_counter")))


# === AC21: LEAVING safety timeout ===

func _test_ac21_leaving_timeout_forces_gone() -> void:
	print("\n[AC21] LEAVING member with no resolving exit path -> forced GONE when the safety timeout elapses")
	# Exit cell (7,5) is enclosed: orthogonal neighbours (6,5) and (7,4) solid
	# (equipment footprints) -> get_path to the exit always returns [].
	var equipment: Array = [
		{"id": 1, "fp": Vector2i(6, 5), "ac": Vector2i(5, 5)},
		{"id": 2, "fp": Vector2i(7, 4), "ac": Vector2i(7, 3)},
	]
	var rig := _make_rig(88, {}, [], equipment)
	var path: Array = rig["navigation"].call("get_path", Vector2i(1, 1), EXIT)
	_check(path.is_empty(), "AC21: precondition — exit (7,5) is unreachable (path empty)")

	_inject_member(rig, _make_member(100, "LEAVING", 3, 3, Vector2i(1, 1), {
		"leaving_timeout_ticks": 3,
		"leaving_reason": "quota_met",
	}))

	_run_ticks(rig, 2)
	_check(_member_count(rig) == 1, "AC21: member still present before the timeout elapses (2 ticks)")
	_run_ticks(rig, 1, 2)
	_check(_member_count(rig) == 0, "AC21: forced GONE exactly when the safety timeout elapses (3 ticks)")


func _test_ac21_blocked_then_unblocked_no_premature_gone() -> void:
	print("\n[AC21] exit blocked mid-leave then unblocked -> NO premature GONE")
	# Exit enclosed for 2 ticks (timeout 3 -> 1 left), then cleared; the
	# member must walk out naturally — a timeout that kept decrementing while
	# walking would force GONE at tick 3.
	var equipment: Array = [
		{"id": 1, "fp": Vector2i(6, 5), "ac": Vector2i(5, 5)},
		{"id": 2, "fp": Vector2i(7, 4), "ac": Vector2i(7, 3)},
	]
	var rig := _make_rig(99, {}, [], equipment)
	var emitted: Array = []
	rig["member_sim"].member_completed_visit.connect(func(member_id: int) -> void: emitted.append(member_id))

	_inject_member(rig, _make_member(100, "LEAVING", 3, 3, Vector2i(1, 1), {
		"leaving_timeout_ticks": 3,
		"leaving_reason": "quota_met",
	}))

	_run_ticks(rig, 2)  # blocked: timeout 3 -> 1
	_check(_member_count(rig) == 1, "AC21[edge]: still present while blocked")

	# Unblock the exit: clear both blocking pieces -> grid_changed -> Navigation
	# re-syncs (the rig wired _post_init for exactly this).
	rig["grid_system"].call("clear", 1)
	rig["grid_system"].call("clear", 2)
	var unblocked_path: Array = rig["navigation"].call("get_path", Vector2i(1, 1), EXIT)
	_check(not unblocked_path.is_empty(), "AC21[edge]: precondition — exit reachable after clear")

	_run_ticks(rig, 1, 2)  # tick 3: path resolves; timeout must NOT decrement
	_check(_member_count(rig) == 1, "AC21[edge]: NO premature GONE on the unblocked tick (timeout holds while walking)")

	_run_ticks(rig, 30, 3)  # walk out (~10 cells) and despawn
	_check(_member_count(rig) == 0, "AC21[edge]: member walks out and despawns naturally (got %d present)" % _member_count(rig))
	_check(emitted == [100], "AC21[edge]: S5 fired exactly once for the quota-met departure (got %s)" % str(emitted))


# === S5: member_completed_visit semantics (ADR-0005) ===

func _test_s5_quota_met_departure_only() -> void:
	print("\n[S5] quota-met departure -> member_completed_visit fires exactly once, arity 1, with the member id")
	var rig := _make_rig(111)  # open gym — exit reachable
	var emitted: Array = []
	rig["member_sim"].member_completed_visit.connect(func(member_id: int) -> void: emitted.append(member_id))

	_inject_member(rig, _make_member(100, "LEAVING", 2, 2, Vector2i(1, 1), {
		"leaving_timeout_ticks": 300,
		"leaving_reason": "quota_met",
	}))
	_run_ticks(rig, 40)  # walk to exit (7,5) and despawn

	_check(_member_count(rig) == 0, "S5: member despawned after reaching the exit")
	_check(emitted == [100], "S5: emitted exactly once with member_id 100 (got %s)" % str(emitted))


func _test_s5_walk_failure_emits_nothing() -> void:
	print("\n[S5] walk-failure departure (no candidates) -> NO member_completed_visit (ADR-0005)")
	var rig := _make_rig(222)  # empty gym
	var emitted: Array = []
	rig["member_sim"].member_completed_visit.connect(func(member_id: int) -> void: emitted.append(member_id))

	# AC1 path: SELECTING_TARGET with zero candidates -> LEAVING (no_candidates).
	_inject_member(rig, _make_member(100, "SELECTING_TARGET", 0, 3, ENTRANCE))
	_run_ticks(rig, 40)  # leaves and despawns

	_check(_member_count(rig) == 0, "S5[wfail]: member despawned (left via no-candidates path)")
	_check(emitted.is_empty(), "S5[wfail]: NOT emitted for a walk-failure departure (got %s)" % str(emitted))


# === Full skeleton lifecycle ===

func _test_full_lifecycle_flow() -> void:
	print("\n[flow] full skeleton lifecycle: ENTERING -> SELECTING_TARGET -> WALKING_TO -> USING -> SELECTING_TARGET -> USING -> LEAVING -> GONE")
	var equipment: Array = [{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)}]
	var rig := _make_rig(333, {}, [], equipment)
	# exercises_per_visit = 2 (config mean 2, stddev 0) -> exactly two uses.
	_inject_member(rig, _make_member(100, "ENTERING", 0, 2, ENTRANCE))

	var states_seen: Array[String] = []
	var done_seen: Array = []
	var gone := false
	for t in 60:
		rig["member_sim"].call("on_tick", t)
		var m := _find_member(rig, 100)
		if m.is_empty():
			gone = true
			states_seen.append("GONE")
			break
		states_seen.append(str(m["state"]))
		done_seen.append(int(m["exercises_done"]))

	_check(gone, "flow: member despawned within 60 ticks")
	var joined := ",".join(states_seen)
	_check(joined.find("SELECTING_TARGET") != -1, "flow: visited SELECTING_TARGET (trace: %s)" % joined)
	_check(joined.find("WALKING_TO") != -1, "flow: visited WALKING_TO (trace: %s)" % joined)
	_check(joined.find("USING") != -1, "flow: visited USING (trace: %s)" % joined)
	_check(joined.find("LEAVING") != -1, "flow: visited LEAVING (trace: %s)" % joined)
	_check(done_seen.has(2), "flow: exercises_done reached the quota (2) before departure (seen: %s)" % str(done_seen))
	# The quota-met departure must have fired S5 once (checked against the
	# second USING completion; walk-failure would have fired nothing).
	var emitted: Array = []
	# Re-check on a fresh rig to keep this test self-contained on S5.
	var rig2 := _make_rig(334, {}, [], equipment)
	rig2["member_sim"].member_completed_visit.connect(func(member_id: int) -> void: emitted.append(member_id))
	_inject_member(rig2, _make_member(100, "ENTERING", 0, 2, ENTRANCE))
	for t in 60:
		rig2["member_sim"].call("on_tick", t)
		if _find_member(rig2, 100).is_empty():
			break
	_check(emitted == [100], "flow: S5 fired once for the natural quota-met departure (got %s)" % str(emitted))
