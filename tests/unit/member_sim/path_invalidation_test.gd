# tests/unit/member_sim/path_invalidation_test.gd
# Story MS-004: Path Invalidation, Patience and Interrupts
# (production/epics/member-sim/story-004-path-invalidation-patience-interrupts.md)
#
# Covers the BLOCKING ACs:
#   - AC17 [UNIT] GIVEN a cached path's grid_version differs from GridSystem's
#     current version on a WALKING_TO tick, WHEN the member updates, THEN
#     Navigation.get_path is re-queried EXACTLY ONCE that tick (mock
#     Navigation, assert call count). Edges: version unchanged -> zero
#     re-queries; version changes twice in one tick -> dedupe to one.
#   - AC18 [UNIT] GIVEN a WALKING_TO member whose repath returns empty for
#     retry_limit consecutive attempts, WHEN the limit is exceeded, THEN the
#     member releases its reservation and transitions to LEAVING
#     (REASON_PATH_BLOCKED — bounded-retry exhaustion, distinct from AC1).
#     Edge: repath empty once then recovers -> NO premature LEAVING.
# Plus: LEAVING shares the same stamp-repath rule (Core Rule 2).
#
# The mock Navigation (mock_navigation.gd) is NOT registered in TEST_FILES —
# it is a test double loaded by path, never auto-run.
#
# Run standalone: godot --headless --script tests/unit/member_sim/path_invalidation_test.gd
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
	print("  UNIT TEST: MemberSim — Path Invalidation and Bounded Retry (Story MS-004)")
	print("=".repeat(48))

	_test_ac17_version_mismatch_requeries_exactly_once()
	_test_ac17_version_unchanged_zero_requeries()
	_test_ac17_two_commits_one_tick_dedupes()
	_test_ac18_retry_limit_exhaustion_leaves()
	_test_ac18_single_failure_then_recovers()
	_test_leaving_share_stamp_repath()

	print("\n=== PATH INVALIDATION TEST: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


# === Helpers (mirror the MS-001/MS-003 rig) ===

func _MS() -> Script:
	return load("res://src/systems/member_sim.gd") as Script


func _GS() -> Script:
	return load("res://src/systems/grid_system.gd") as Script


func _NAV() -> Script:
	return load("res://src/systems/navigation.gd") as Script


func _MOCK_NAV() -> Script:
	return load("res://tests/unit/member_sim/mock_navigation.gd") as Script


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


## Builds a MemberSim rig whose Navigation is the MOCK (get_path call counter
## + scriptable results). [equipment] lists {id, fp, ac} commits. The mock is
## NOT initialized (it never touches the base A* — the override bypasses
## _assert_initialized); MemberSim only calls get_path() on it.
func _make_mock_rig(
	seed: int,
	equipment: Array = [],
	walls: Array = [],
	config: Dictionary = {}
) -> Dictionary:
	var gs := _make_grid(walls)
	for eq in equipment:
		_commit_equipment(gs, int(eq["id"]), eq["fp"], eq["ac"])
	var nav: RefCounted = _MOCK_NAV().new()
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


## The member's cached path to target's access cell — the canonical route the
## AC17/AC18 rigs use for WALKING_TO members.
func _canonical_path() -> Array:
	return [Vector2i(0, 0), Vector2i(1, 0), Vector2i(2, 0), Vector2i(3, 0), Vector2i(3, 1), Vector2i(3, 2)]


# === AC17: path invalidation re-queries Navigation.get_path exactly once ===

func _test_ac17_version_mismatch_requeries_exactly_once() -> void:
	print("\n[AC17] WALKING_TO member, grid version bumped -> Navigation.get_path re-queried EXACTLY ONCE that tick (mock count)")
	var equipment: Array = [{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)}]
	var rig := _make_mock_rig(0xAC1701, equipment)
	var nav: Object = rig["navigation"]
	var gs: Object = rig["grid_system"]
	nav.set("scripted_result", _canonical_path())  # repath succeeds -> member keeps walking

	# Precondition: equipment 1 committed during rig build -> grid version 1.
	var grid_version_before: int = gs.call("get_grid_version")
	_check(grid_version_before == 1, "AC17: precondition — grid version is 1 after the initial commit (got %d)" % grid_version_before)

	# Member 100 mid-walk to E1, holding the queue slot, stamped at version 1.
	_inject_member(rig, _make_member(100, "WALKING_TO", 0, 3, Vector2i(0, 0), {
		"target_equipment_instance_id": 1,
		"cached_path": _canonical_path(),
		"cached_path_grid_version": grid_version_before,
	}))
	var res: Dictionary = _reservations(rig)
	res[1] = {"occupant": null, "next_claimant": 100}

	# Bump the grid version: commit a non-blocking second machine.
	_commit_equipment(gs, 2, Vector2i(5, 2), Vector2i(6, 2))
	_check(gs.call("get_grid_version") == 2, "AC17: precondition — version bumped to 2 (got %d)" % int(gs.call("get_grid_version")))

	_run_ticks(rig, 1)
	_check(nav.get("get_path_call_count") == 1,
		"AC17: exactly ONE re-query on the mismatched tick (mock count=%d)" % int(nav.get("get_path_call_count")))

	var m := _find_member(rig, 100)
	_check(not m.is_empty() and int(m["cached_path_grid_version"]) == 2,
		"AC17: member re-stamped the cached path at the CURRENT version (stamp=%d)" % (0 if m.is_empty() else int(m["cached_path_grid_version"])))

	# A SECOND tick with a stable version must NOT re-query.
	nav.call("reset_call_count")
	_run_ticks(rig, 1)
	_check(nav.get("get_path_call_count") == 0,
		"AC17: zero re-queries on the FOLLOWING tick (stable version; count=%d)" % int(nav.get("get_path_call_count")))


func _test_ac17_version_unchanged_zero_requeries() -> void:
	print("\n[AC17 edge] grid_version UNCHANGED -> zero re-queries (mock count stays 0)")
	var equipment: Array = [{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)}]
	var rig := _make_mock_rig(0xAC1702, equipment)
	var nav: Object = rig["navigation"]
	var gs: Object = rig["grid_system"]
	nav.set("scripted_result", _canonical_path())

	_inject_member(rig, _make_member(100, "WALKING_TO", 0, 3, Vector2i(0, 0), {
		"target_equipment_instance_id": 1,
		"cached_path": _canonical_path(),
		"cached_path_grid_version": int(gs.call("get_grid_version")),
	}))
	var res: Dictionary = _reservations(rig)
	res[1] = {"occupant": null, "next_claimant": 100}

	_run_ticks(rig, 3)
	_check(nav.get("get_path_call_count") == 0,
		"AC17[edge]: ZERO re-queries across 3 ticks with an unchanged version (count=%d)" % int(nav.get("get_path_call_count")))
	var m := _find_member(rig, 100)
	_check(not m.is_empty() and str(m["state"]) == "WALKING_TO",
		"AC17[edge]: member kept walking the cached path (state=%s)" % ("" if m.is_empty() else str(m["state"])))


func _test_ac17_two_commits_one_tick_dedupes() -> void:
	print("\n[AC17 edge] grid_version changes TWICE in one tick -> still exactly ONE re-query (dedupe)")
	var equipment: Array = [{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)}]
	var rig := _make_mock_rig(0xAC1703, equipment)
	var nav: Object = rig["navigation"]
	var gs: Object = rig["grid_system"]
	nav.set("scripted_result", _canonical_path())

	_inject_member(rig, _make_member(100, "WALKING_TO", 0, 3, Vector2i(0, 0), {
		"target_equipment_instance_id": 1,
		"cached_path": _canonical_path(),
		"cached_path_grid_version": int(gs.call("get_grid_version")),
	}))
	var res: Dictionary = _reservations(rig)
	res[1] = {"occupant": null, "next_claimant": 100}

	# TWO commits before a single tick -> version 1 -> 3.
	_commit_equipment(gs, 2, Vector2i(5, 2), Vector2i(6, 2))
	_commit_equipment(gs, 3, Vector2i(5, 4), Vector2i(6, 4))
	_check(int(gs.call("get_grid_version")) == 3, "AC17[edge]: precondition — version bumped twice to 3 (got %d)" % int(gs.call("get_grid_version")))

	_run_ticks(rig, 1)
	_check(nav.get("get_path_call_count") == 1,
		"AC17[edge]: dedupe — ONE re-query despite two version bumps in one tick (count=%d)" % int(nav.get("get_path_call_count")))


# === AC18: bounded retry exhaustion ===

func _test_ac18_retry_limit_exhaustion_leaves() -> void:
	print("\n[AC18] repath empty for retry_limit (3) consecutive attempts -> release reservation + LEAVING (REASON_PATH_BLOCKED)")
	var equipment: Array = [{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)}]
	var rig := _make_mock_rig(0xAC1801, equipment, [], {
		"repath_retry_limit": 3,
	})
	var nav: Object = rig["navigation"]
	nav.set("scripted_result", [])  # every get_path returns EMPTY

	# Stale stamp: cached at version 0 but the grid is at version 1 (the rig's
	# initial commit) -> the FIRST tick MUST re-query (and get empty).
	_inject_member(rig, _make_member(100, "WALKING_TO", 0, 3, Vector2i(0, 0), {
		"target_equipment_instance_id": 1,
		"cached_path": _canonical_path(),
		"cached_path_grid_version": 0,
	}))
	var res: Dictionary = _reservations(rig)
	res[1] = {"occupant": null, "next_claimant": 100}

	# Tick 1: version mismatch -> repath -> EMPTY -> release + first retry.
	_run_ticks(rig, 1)
	var m := _find_member(rig, 100)
	_check(not m.is_empty() and str(m["state"]) == "SELECTING_TARGET",
		"AC18: after ONE empty repath the member retries (SELECTING_TARGET, got %s)" % ("" if m.is_empty() else str(m["state"])))
	res = _reservations(rig)
	_check(res.has(1) and res[1]["next_claimant"] == null,
		"AC18: reservation released on the FIRST empty repath (next_claimant=%s)" % _id_str(res[1]["next_claimant"]))

	# Tick 2: SELECTING_TARGET path-check also empty -> second retry (still no LEAVING).
	_run_ticks(rig, 1, 1)
	m = _find_member(rig, 100)
	_check(not m.is_empty() and str(m["state"]) == "SELECTING_TARGET",
		"AC18: after TWO empty attempts still retrying, no premature LEAVING (state=%s)" % ("" if m.is_empty() else str(m["state"])))

	# Tick 3: retry_limit exhausted -> LEAVING with REASON_PATH_BLOCKED.
	_run_ticks(rig, 1, 2)
	m = _find_member(rig, 100)
	_check(not m.is_empty() and str(m["state"]) == "LEAVING",
		"AC18: limit exceeded -> LEAVING (state=%s)" % ("" if m.is_empty() else str(m["state"])))
	_check(not m.is_empty() and str(m.get("leaving_reason", "")) == "path_blocked",
		"AC18: leaving_reason is path_blocked (distinct from AC1 no_candidates; got %s)" % ("" if m.is_empty() else str(m.get("leaving_reason", ""))))
	_check(int(m.get("repath_failures", 0)) >= 3,
		"AC18: repath_failures reached the limit (%d)" % int(m.get("repath_failures", 0)))


func _test_ac18_single_failure_then_recovers() -> void:
	print("\n[AC18 edge] repath empty ONCE then recovers -> NO premature LEAVING")
	var equipment: Array = [{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)}]
	var rig := _make_mock_rig(0xAC1802, equipment, [], {
		"repath_retry_limit": 3,
	})
	var nav: Object = rig["navigation"]

	# Stale stamp -> first tick re-queries.
	_inject_member(rig, _make_member(100, "WALKING_TO", 0, 3, Vector2i(0, 0), {
		"target_equipment_instance_id": 1,
		"cached_path": _canonical_path(),
		"cached_path_grid_version": 0,
	}))
	var res: Dictionary = _reservations(rig)
	res[1] = {"occupant": null, "next_claimant": 100}

	# Tick 1: repath EMPTY (scripted) -> member bounces to SELECTING_TARGET.
	nav.set("scripted_result", [])
	_run_ticks(rig, 1)
	var m := _find_member(rig, 100)
	_check(not m.is_empty() and str(m["state"]) == "SELECTING_TARGET",
		"AC18[edge]: one empty repath -> retry, NOT LEAVING (state=%s)" % ("" if m.is_empty() else str(m["state"])))

	# Tick 2: repath recovers (scripted path) -> reselect succeeds -> WALKING_TO.
	nav.set("scripted_result", _canonical_path())
	_run_ticks(rig, 1, 1)
	m = _find_member(rig, 100)
	_check(not m.is_empty() and str(m["state"]) == "WALKING_TO",
		"AC18[edge]: recovery — the member is back WALKING_TO after one failure (state=%s)" % ("" if m.is_empty() else str(m["state"])))
	_check(not m.is_empty() and int(m.get("repath_failures", -1)) == 0,
		"AC18[edge]: repath_failures reset to 0 after recovery (got %d)" % int(m.get("repath_failures", -1)))


# === LEAVING shares the stamp-repath rule (Core Rule 2) ===

func _test_leaving_share_stamp_repath() -> void:
	print("\n[LEAVING] cached exit path stamp mismatch -> exit path re-queried exactly once (Core Rule 2)")
	var equipment: Array = [{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)}]
	var rig := _make_mock_rig(0xAC1704, equipment)
	var nav: Object = rig["navigation"]
	var gs: Object = rig["grid_system"]
	var exit_path: Array = [Vector2i(1, 1), Vector2i(2, 1), Vector2i(3, 1), Vector2i(4, 1), Vector2i(5, 1), Vector2i(6, 1), Vector2i(7, 1), Vector2i(7, 2), Vector2i(7, 3), Vector2i(7, 4), Vector2i(7, 5)]
	nav.set("scripted_result", exit_path)

	# Member already mid-leave with a cached exit path stamped at version 1.
	_inject_member(rig, _make_member(100, "LEAVING", 3, 3, Vector2i(1, 1), {
		"cached_path": exit_path,
		"cached_path_grid_version": int(gs.call("get_grid_version")),
		"leaving_reason": "quota_met",
		"leaving_timeout_ticks": 300,
	}))

	# Bump the grid version (non-blocking commit).
	_commit_equipment(gs, 2, Vector2i(5, 2), Vector2i(6, 2))

	_run_ticks(rig, 1)
	_check(nav.get("get_path_call_count") == 1,
		"LEAVING: exactly ONE exit-path re-query on the mismatched tick (count=%d)" % int(nav.get("get_path_call_count")))
	var m := _find_member(rig, 100)
	_check(not m.is_empty() and int(m["cached_path_grid_version"]) == int(gs.call("get_grid_version")),
		"LEAVING: exit path re-stamped at the current version (stamp=%d, version=%d)" % [0 if m.is_empty() else int(m["cached_path_grid_version"]), int(gs.call("get_grid_version"))])
