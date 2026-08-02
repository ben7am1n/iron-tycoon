# tests/unit/member_sim/patience_interrupt_test.gd
# Story MS-004: Path Invalidation, Patience and Interrupts
# (production/epics/member-sim/story-004-path-invalidation-patience-interrupts.md)
#
# Covers the BLOCKING ACs:
#   - AC13 [UNIT] GIVEN a QUEUEING member whose patience_timer reaches 0,
#     WHEN the give-up transition fires, THEN exercises_done is unchanged and
#     no failure signal distinct from the calm give-up path is emitted. Edge:
#     give-up with zero other candidates -> wander briefly then retry, never
#     a failure prompt.
#   - AC14 [UNIT] GIVEN a member USING equipment E, WHEN E is deleted
#     mid-use, THEN the member transitions to SELECTING_TARGET without
#     crashing and emits exactly one satisfaction-penalty event. Edge: E
#     deleted while the member also has a path cached to it.
#   - AC19 [UNIT] GIVEN a member that just abandoned equipment E via patience
#     give-up, WHEN it re-runs SELECTING_TARGET the same/next tick, THEN E is
#     excluded by the short-term novelty blacklist. Edge: blacklist expiry
#     after N ticks -> E becomes eligible again.
#
# Run standalone: godot --headless --script tests/unit/member_sim/patience_interrupt_test.gd
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
	print("  UNIT TEST: MemberSim — Patience Give-Up and Mid-Use Interrupt (Story MS-004)")
	print("=".repeat(48))

	_test_ac13_give_up_calm_exercises_unchanged_no_signal()
	_test_ac13_give_up_zero_candidates_retries_never_failure_prompt()
	_test_ac14_mid_use_deletion_interrupts_penalty_once()
	_test_ac14_deleted_with_cached_path_clears_path()
	_test_ac19_give_up_blacklist_excludes_same_next_tick()
	_test_ac19_blacklist_expiry_reelegible()

	print("\n=== PATIENCE INTERRUPT TEST: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


# === Helpers (mirror the MS-001/MS-003 rig — REAL Navigation) ===

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


## Builds the full configured MemberSim rig with REAL Navigation (paths must
## actually resolve for the give-up/interrupt flows). [equipment] lists
## {id, fp, ac} commits. [config] merges over the base.
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
		"repath_retry_limit": 3,
		"give_up_blacklist_ticks": 10,
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
		"cached_path_grid_version": -1,
		"repath_failures": 0,
		"give_up_blacklist": {},
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


func _id_str(v: Variant) -> String:
	return "-" if v == null else str(int(v))


## White-box: the member's candidate entries in ASCENDING id order (the fixed
## summation order — see _build_weighted_candidates). [WB] hook, no RNG.
func _candidates(rig: Dictionary, member: Dictionary) -> Array:
	return rig["member_sim"].call("_build_weighted_candidates", member) as Array


# === AC13: patience give-up is calm — exercises unchanged, no failure signal ===

func _test_ac13_give_up_calm_exercises_unchanged_no_signal() -> void:
	print("\n[AC13] QUEUEING member patience reaches 0 -> calm give-up: exercises_done unchanged, NO failure signal")
	var equipment: Array = [{"id": 1, "fp": Vector2i(4, 2), "ac": Vector2i(3, 2)}]
	var rig := _make_rig(0xAC1301, equipment)
	# Occupant 100 using E1 for a very long time; claimant 200 queuing one
	# cell short with patience = 1 (give up next tick).
	_inject_member(rig, _make_member(100, "USING", 0, 3, Vector2i(3, 2), {
		"target_equipment_instance_id": 1,
		"use_ticks_remaining": 100000,
	}))
	_inject_member(rig, _make_member(200, "QUEUEING", 1, 3, Vector2i(2, 2), {
		"target_equipment_instance_id": 1,
		"patience_ticks_remaining": 1,
	}))
	var res: Dictionary = _reservations(rig)
	res[1] = {"occupant": 100, "next_claimant": 200}

	# Spy on S5 (the only failure-ish signal MemberSim emits — quota-met only).
	var emitted: Array = []
	rig["member_sim"].member_completed_visit.connect(func(member_id: int) -> void: emitted.append(member_id))

	_run_ticks(rig, 1)
	var m := _find_member(rig, 200)
	_check(not m.is_empty() and str(m["state"]) == "SELECTING_TARGET",
		"AC13: give-up transition fires -> SELECTING_TARGET (got %s)" % ("" if m.is_empty() else str(m["state"])))
	_check(not m.is_empty() and int(m["exercises_done"]) == 1,
		"AC13: exercises_done UNCHANGED after give-up (got %d)" % (0 if m.is_empty() else int(m["exercises_done"])))
	_check(emitted.is_empty(), "AC13: NO failure signal emitted (S5 spy empty: %s)" % str(emitted))
	res = _reservations(rig)
	_check(res.has(1) and res[1]["next_claimant"] == null,
		"AC13: queue slot released same tick (next_claimant=%s)" % _id_str(res[1]["next_claimant"]))
	_check(res[1]["occupant"] == 100, "AC13: the occupant's claim is untouched (occupant=%s)" % _id_str(res[1]["occupant"]))
	_check(not m.is_empty() and m["cell"] == Vector2i(2, 2),
		"AC13: member never stepped onto the occupied access cell (cell=%s)" % ("" if m.is_empty() else str(m["cell"])))


func _test_ac13_give_up_zero_candidates_retries_never_failure_prompt() -> void:
	print("\n[AC13 edge] give-up with ZERO other candidates -> wander briefly then retry, never a failure prompt")
	var equipment: Array = [{"id": 1, "fp": Vector2i(4, 2), "ac": Vector2i(3, 2)}]
	var rig := _make_rig(0xAC1302, equipment, [], {
		"give_up_blacklist_ticks": 3,  # short blacklist so the retry happens fast
	})
	_inject_member(rig, _make_member(100, "USING", 0, 3, Vector2i(3, 2), {
		"target_equipment_instance_id": 1,
		"use_ticks_remaining": 100000,
	}))
	_inject_member(rig, _make_member(200, "QUEUEING", 1, 3, Vector2i(2, 2), {
		"target_equipment_instance_id": 1,
		"patience_ticks_remaining": 1,
	}))
	var res: Dictionary = _reservations(rig)
	res[1] = {"occupant": 100, "next_claimant": 200}

	var emitted: Array = []
	rig["member_sim"].member_completed_visit.connect(func(member_id: int) -> void: emitted.append(member_id))

	_run_ticks(rig, 1)  # give-up -> SELECTING_TARGET, E1 blacklisted
	var m := _find_member(rig, 200)
	_check(not m.is_empty() and str(m["state"]) == "SELECTING_TARGET",
		"AC13[edge]: after give-up with no alternatives -> stays SELECTING_TARGET (got %s)" % ("" if m.is_empty() else str(m["state"])))

	# The next few ticks: member retries; NEVER LEAVING, never a failure prompt.
	var saw_leaving := false
	for i in 5:
		_run_ticks(rig, 1, 1 + i)
		var mb := _find_member(rig, 200)
		if mb.is_empty() or str(mb["state"]) == "LEAVING":
			saw_leaving = true
	_check(not saw_leaving, "AC13[edge]: member NEVER went LEAVING during the retry window (no failure prompt)")
	_check(emitted.is_empty(), "AC13[edge]: NO failure signal across the retry window (S5 spy: %s)" % str(emitted))
	# After the blacklist expires (3 ticks) E1 becomes eligible again -> the
	# member retries it. It stands one cell short of the still-busy access
	# cell, so the retry lands it straight back in QUEUEING (never LEAVING).
	var m_end := _find_member(rig, 200)
	_check(not m_end.is_empty() and str(m_end["state"]) == "QUEUEING",
		"AC13[edge]: blacklist expiry lets the member retry E1 -> QUEUEING again (got %s)" % ("" if m_end.is_empty() else str(m_end["state"])))
	_check(not m_end.is_empty() and int(m_end["target_equipment_instance_id"]) == 1,
		"AC13[edge]: the retry re-targeted E1 (target=%s)" % ("" if m_end.is_empty() else str(m_end.get("target_equipment_instance_id", -1))))


# === AC14: mid-use deletion — graceful interrupt + exactly one penalty ===

func _test_ac14_mid_use_deletion_interrupts_penalty_once() -> void:
	print("\n[AC14] member USING E; E deleted mid-use -> SELECTING_TARGET, EXACTLY ONE satisfaction-penalty event")
	var equipment: Array = [{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)}]
	var rig := _make_rig(0xAC1401, equipment)
	_inject_member(rig, _make_member(100, "USING", 1, 3, Vector2i(3, 2), {
		"target_equipment_instance_id": 1,
		"use_ticks_remaining": 100,
	}))
	var res: Dictionary = _reservations(rig)
	res[1] = {"occupant": 100, "next_claimant": null}

	var emitted: Array = []
	rig["member_sim"].member_completed_visit.connect(func(member_id: int) -> void: emitted.append(member_id))

	# Delete E mid-use (between ticks — PlacementSystem's removal path).
	rig["grid_system"].call("clear", 1)
	_check(rig["grid_system"].call("get_access_cells", 1).is_empty(),
		"AC14: precondition — E1's access cells are gone after clear")

	_run_ticks(rig, 1)
	var m := _find_member(rig, 100)
	_check(not m.is_empty() and str(m["state"]) == "SELECTING_TARGET",
		"AC14: mid-use deletion -> SELECTING_TARGET without crashing (got %s)" % ("" if m.is_empty() else str(m["state"])))
	_check(int(rig["member_sim"].call("get_satisfaction_penalty_events")) == 1,
		"AC14: exactly ONE satisfaction-penalty event this tick (got %d)" % int(rig["member_sim"].call("get_satisfaction_penalty_events")))
	_check(not m.is_empty() and int(m["exercises_done"]) == 1,
		"AC14: exercises_done unchanged by the interrupt (got %d)" % (0 if m.is_empty() else int(m["exercises_done"])))
	_check(emitted.is_empty(), "AC14: no S5 failure signal (interrupt is not a quota-met departure): %s" % str(emitted))
	_check(not m.is_empty() and int(m["target_equipment_instance_id"]) == -1,
		"AC14: target cleared after interrupt (target=%s)" % ("" if m.is_empty() else str(m["target_equipment_instance_id"])))

	# Exactly ONE: a second tick with no new deletion -> counter resets to 0.
	_run_ticks(rig, 1, 1)
	_check(int(rig["member_sim"].call("get_satisfaction_penalty_events")) == 0,
		"AC14: no penalty event on the next tick (per-tick window reset; got %d)" % int(rig["member_sim"].call("get_satisfaction_penalty_events")))


func _test_ac14_deleted_with_cached_path_clears_path() -> void:
	print("\n[AC14 edge] E deleted while the member ALSO has a path cached to it -> cached path cleared")
	var equipment: Array = [{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)}]
	var rig := _make_rig(0xAC1402, equipment)
	# USING member that (pathologically) still holds a cached path to E.
	_inject_member(rig, _make_member(100, "USING", 1, 3, Vector2i(3, 2), {
		"target_equipment_instance_id": 1,
		"use_ticks_remaining": 100,
		"cached_path": [Vector2i(3, 1), Vector2i(3, 2)],
	}))
	var res: Dictionary = _reservations(rig)
	res[1] = {"occupant": 100, "next_claimant": null}

	rig["grid_system"].call("clear", 1)
	_run_ticks(rig, 1)
	var m := _find_member(rig, 100)
	_check(not m.is_empty() and (m["cached_path"] as Array).is_empty(),
		"AC14[edge]: cached path cleared on interrupt (path=%s)" % ("" if m.is_empty() else str(m["cached_path"])))
	_check(not m.is_empty() and str(m["state"]) == "SELECTING_TARGET",
		"AC14[edge]: still a graceful SELECTING_TARGET transition (got %s)" % ("" if m.is_empty() else str(m["state"])))


# === AC19: give-up blacklist prevents flip-flop ===

func _test_ac19_give_up_blacklist_excludes_same_next_tick() -> void:
	print("\n[AC19] give-up on E -> same/next-tick reselect EXCLUDES E (short-term novelty blacklist)")
	var equipment: Array = [{"id": 1, "fp": Vector2i(4, 2), "ac": Vector2i(3, 2)}]
	var rig := _make_rig(0xAC1901, equipment, [], {
		"give_up_blacklist_ticks": 10,
	})
	_inject_member(rig, _make_member(100, "USING", 0, 3, Vector2i(3, 2), {
		"target_equipment_instance_id": 1,
		"use_ticks_remaining": 100000,
	}))
	_inject_member(rig, _make_member(200, "QUEUEING", 1, 3, Vector2i(2, 2), {
		"target_equipment_instance_id": 1,
		"patience_ticks_remaining": 1,
	}))
	var res: Dictionary = _reservations(rig)
	res[1] = {"occupant": 100, "next_claimant": 200}

	_run_ticks(rig, 1)  # give-up -> SELECTING_TARGET + blacklist entry on E1
	var m := _find_member(rig, 200)
	_check(not m.is_empty() and str(m["state"]) == "SELECTING_TARGET",
		"AC19: member gave up and is reselecting (got %s)" % ("" if m.is_empty() else str(m["state"])))

	# [WB] Same/next-tick reselect pool must EXCLUDE E1 (blacklisted).
	var entries: Array = _candidates(rig, _find_member(rig, 200))
	var ids: Array = []
	for e in entries:
		ids.append(int(e["instance_id"]))
	_check(ids.is_empty(), "AC19[WB]: E1 EXCLUDED from the reselect pool (pool=%s)" % str(ids))
	_check(not m.is_empty() and (m.get("give_up_blacklist", {}) as Dictionary).has(1),
		"AC19: E1 is on the member's blacklist (blacklist=%s)" % ("" if m.is_empty() else str(m.get("give_up_blacklist", {}))))

	# Next tick: still SELECTING_TARGET (pool stays empty), not LEAVING, not flip-flopped to E1.
	_run_ticks(rig, 1, 1)
	m = _find_member(rig, 200)
	var st_a: String = "" if m.is_empty() else str(m["state"])
	var tg_a: String = "" if m.is_empty() else str(m.get("target_equipment_instance_id", -1))
	_check(not m.is_empty() and str(m["state"]) == "SELECTING_TARGET" and int(m.get("target_equipment_instance_id", -1)) == -1,
		"AC19: next tick reselect did NOT flip back to E1 (state=%s target=%s)" % [st_a, tg_a])


func _test_ac19_blacklist_expiry_reelegible() -> void:
	print("\n[AC19 edge] blacklist expiry after N ticks -> E becomes ELIGIBLE again")
	var equipment: Array = [{"id": 1, "fp": Vector2i(4, 2), "ac": Vector2i(3, 2)}]
	var rig := _make_rig(0xAC1902, equipment, [], {
		"give_up_blacklist_ticks": 3,
	})
	_inject_member(rig, _make_member(100, "USING", 0, 3, Vector2i(3, 2), {
		"target_equipment_instance_id": 1,
		"use_ticks_remaining": 100000,
	}))
	_inject_member(rig, _make_member(200, "QUEUEING", 1, 3, Vector2i(2, 2), {
		"target_equipment_instance_id": 1,
		"patience_ticks_remaining": 1,
	}))
	var res: Dictionary = _reservations(rig)
	res[1] = {"occupant": 100, "next_claimant": 200}

	_run_ticks(rig, 1)  # give-up, blacklist entry {1: 3}
	var m := _find_member(rig, 200)
	_check(not m.is_empty() and (m.get("give_up_blacklist", {}) as Dictionary).has(1),
		"AC19[edge]: blacklist entry created with 3 ticks (got %s)" % ("" if m.is_empty() else str(m.get("give_up_blacklist", {}))))

	# During the blacklist window E1 stays excluded.
	_run_ticks(rig, 2, 1)
	m = _find_member(rig, 200)
	_check(not m.is_empty() and str(m["state"]) == "SELECTING_TARGET",
		"AC19[edge]: still SELECTING_TARGET while blacklisted (got %s)" % ("" if m.is_empty() else str(m["state"])))

	# After expiry (tick 4+): E1 eligible again -> member retries it. It is
	# one cell short of the still-busy access cell, so the retry lands it
	# straight back in QUEUEING (never a failure prompt, never LEAVING).
	_run_ticks(rig, 2, 3)
	m = _find_member(rig, 200)
	_check(not m.is_empty() and int(m["target_equipment_instance_id"]) == 1,
		"AC19[edge]: E1 re-eligible after blacklist expiry — member targets it again (target=%s)" % ("" if m.is_empty() else str(m.get("target_equipment_instance_id", -1))))
	_check(not m.is_empty() and str(m["state"]) == "QUEUEING",
		"AC19[edge]: member is queuing on E1 again after expiry (got %s)" % ("" if m.is_empty() else str(m["state"])))
	# The novelty penalty is also applied — E1 is in recently_used_ids (as-if-just-used).
	_check(not m.is_empty() and (m.get("recently_used_ids", []) as Array).has(1),
		"AC19[edge]: novelty penalty applied — E1 recorded as just-used (recent=%s)" % ("" if m.is_empty() else str(m.get("recently_used_ids", []))))
