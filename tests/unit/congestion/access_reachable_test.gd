# tests/unit/congestion/access_reachable_test.gd
# Story CG-003: access_reachable and grid_changed Handling
# (production/epics/congestion/story-003-access-reachable-grid-changed-handling.md)
#
# BLOCKING ACs covered (TR-CONG-005):
#   AC9  equipment E removed via grid_changed -> same-tick deletion of
#        prev/next/access_reachable entries; querying E returns "not found"
#        (entry absent), never a stale float. Edge: remove+re-add same tick
#        -> fresh entry state.
#   AC12 [WB] no grid_changed during a tick -> ZERO Navigation.get_path
#        queries that tick (call-count spy via mock_navigation delegate).
#        Edge: tick with member movement only (no layout change) -> still 0.
#   AC13 grid_changed severs the only path from entrance_cell to E's access
#        cell -> access_reachable[E] == false. Edge: narrow corridor blocked
#        by new placement.
#   AC16 two grid_changed events affecting the same equipment E in one tick
#        -> access_reachable recomputed exactly ONCE (spy: N get_path calls,
#        not 2N), against the final post-batch grid state (intermediate
#        state never used).
#
# Plus (story contract surface):
#   - one-shot initial population at init (GDD Core Rule 7 allowance) —
#     equipment placed before init is immediately flagged reachable
#   - is_access_reachable(id) public read; unknown id -> false (flag absence)
#   - Core Rule 6 removal-drop works even WITHOUT navigation (no reachability)
#   - pre-wiring / story-001 rigs (no navigation) leave access_reachable empty
#
# Run standalone: godot --headless --script tests/unit/congestion/access_reachable_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const GRID_W := 10
const GRID_H := 8
const R0 := 0
const ENTRANCE := Vector2i(0, 0)

var _pass := 0
var _fail := 0


func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	var result := run_all()
	quit(1 if int(result["fail"]) > 0 else 0)


func run_all() -> Dictionary:
	print("=".repeat(48))
	print("  UNIT TEST: Congestion — access_reachable + grid_changed (Story CG-003)")
	print("=".repeat(48))

	_test_init_one_shot_population()
	_test_ac12_quiet_tick_zero_path_queries()
	_test_ac12_member_movement_only_zero_queries()
	_test_ac13_severed_path_false()
	_test_ac13_narrow_corridor_blocked()
	_test_ac9_removal_same_tick_not_found()
	_test_ac9_remove_readd_same_tick_fresh_state()
	_test_ac9_removal_drop_without_navigation()
	_test_ac16_two_events_one_recompute_final_state()
	_test_unknown_id_read_defaults()

	print("\n=== ACCESS_REACHABLE TEST: %d passed, %d failed ===\n" % [_pass, _fail])
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


func _NAV() -> Script:
	return load("res://src/systems/navigation.gd") as Script


## The member_sim unit-test mock navigation (NOT a *_test.gd — loaded by path).
func _MOCK_NAV() -> Script:
	return load("res://tests/unit/member_sim/mock_navigation.gd") as Script


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
		_commit(gs, int(eq["id"]), eq["fp"], eq["ac"])
	return gs


func _commit(gs: RefCounted, id: int, fp: Vector2i, ac: Vector2i) -> void:
	var fp_arr: Array[Vector2i] = [fp]
	var ac_arr: Array[Vector2i] = [ac]
	gs.call("commit", id, fp_arr, ac_arr, R0)


func _clear(gs: RefCounted, id: int) -> void:
	gs.call("clear", id)


## Real MemberSim instance — NOT init'd (no navigation/catalog needed); the
## test injects members/reservations directly through the public vars, the
## same data shape the configured system exposes.
func _make_member_sim() -> RefCounted:
	return _MS().new()


## Real Navigation built on [gs], with _post_init called so its AStarGrid2D
## stays in sync with grid_changed (solidity update on commit/clear).
func _make_real_navigation(gs: RefCounted) -> RefCounted:
	var nav: RefCounted = _NAV().new()
	nav.call("init", gs)
	nav.call("_post_init")
	return nav


## Counting spy: mock_navigation with delegate = real Navigation. get_path
## calls increment the counter and delegate to the real A* for realistic
## paths (AC12 zero-call spy + AC16 exactly-once spy).
func _make_spy_navigation(gs: RefCounted) -> Dictionary:
	var real := _make_real_navigation(gs)
	var spy: RefCounted = _MOCK_NAV().new()
	spy.set("delegate", real)
	spy.set("scripted_result", [])
	return {"spy": spy, "real": real}


## Real Congestion, configured with the real grid + member_sim + navigation +
## entrance_cell (+ _post_init to subscribe grid_changed). Returns the rig.
func _make_congestion(
	gs: RefCounted,
	ms: RefCounted,
	nav: RefCounted = null,
	entrance: Vector2i = ENTRANCE,
	config: Dictionary = {}
) -> Dictionary:
	var srg: RefCounted = _SRG().new()
	srg.call("init", 0xCAFE003)
	var orch := _make_orchestrator()
	var cong: RefCounted = (load("res://src/systems/congestion.gd") as Script).new()
	cong.call("init", orch, srg, gs, ms, config, nav, entrance)
	if gs != null:
		cong.call("_post_init")
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


# === Init one-shot population (GDD Core Rule 7 allowance) ===

func _test_init_one_shot_population() -> void:
	print("\n[INIT] one-shot recompute populates access_reachable for equipment placed before init")
	var eq: Array = [{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)}]
	var gs := _make_grid(eq)
	var ms := _make_member_sim()
	var nav := _make_real_navigation(gs)
	var rig := _make_congestion(gs, ms, nav)
	var cong: RefCounted = rig["congestion"]

	_check(bool(cong.call("is_access_reachable", 1)) == true,
		"INIT: equipment 1 (open grid) flagged reachable at init (one-shot)")
	var ar: Dictionary = cong.get("access_reachable")
	_check(ar.has(1) and bool(ar[1]) == true,
		"INIT: access_reachable[1] == true immediately after init")


# === AC12: quiet tick zero path queries ===

func _test_ac12_quiet_tick_zero_path_queries() -> void:
	print("\n[AC12] no grid_changed -> zero Navigation.get_path calls that tick (spy)")
	var eq: Array = [{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)}]
	var gs := _make_grid(eq)
	var ms := _make_member_sim()
	var spy_rig := _make_spy_navigation(gs)
	var rig := _make_congestion(gs, ms, spy_rig["spy"])
	var cong: RefCounted = rig["congestion"]
	var spy: RefCounted = spy_rig["spy"]

	# The one-shot at init consumed some get_path calls — reset the spy so the
	# measurement window is exactly the quiet tick.
	spy.call("reset_call_count")
	cong.call("on_tick", 0)
	_check(int(spy.get("get_path_call_count")) == 0,
		"AC12: quiet tick 0 makes zero get_path calls (got %d)" % int(spy.get("get_path_call_count")))
	cong.call("on_tick", 1)
	_check(int(spy.get("get_path_call_count")) == 0,
		"AC12: quiet tick 1 makes zero get_path calls (got %d)" % int(spy.get("get_path_call_count")))


func _test_ac12_member_movement_only_zero_queries() -> void:
	print("\n[AC12 edge] member movement only (no layout change) -> still zero queries")
	var eq: Array = [{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)}]
	var gs := _make_grid(eq)
	var ms := _make_member_sim()
	ms.set("members", [_member(90, "WALKING_TO", Vector2i(1, 0))])
	var spy_rig := _make_spy_navigation(gs)
	var rig := _make_congestion(gs, ms, spy_rig["spy"])
	var cong: RefCounted = rig["congestion"]
	var spy: RefCounted = spy_rig["spy"]

	spy.call("reset_call_count")
	cong.call("on_tick", 0)
	# Members moved (WALKING_TO at a new cell) — but no grid change.
	ms.set("members", [_member(90, "WALKING_TO", Vector2i(2, 0))])
	cong.call("on_tick", 1)
	_check(int(spy.get("get_path_call_count")) == 0,
		"AC12-edge: two ticks with movement-only still zero get_path calls (got %d)" % int(spy.get("get_path_call_count")))


# === AC13: severed path ===

func _test_ac13_severed_path_false() -> void:
	print("\n[AC13] grid_changed severs the only path -> access_reachable[E] == false")
	var eq: Array = [{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)}]
	var gs := _make_grid(eq)
	var ms := _make_member_sim()
	var nav := _make_real_navigation(gs)
	var rig := _make_congestion(gs, ms, nav)
	var cong: RefCounted = rig["congestion"]

	_check(bool(cong.call("is_access_reachable", 1)) == true,
		"AC13: before the wall, E is reachable (baseline true)")

	# A wall across row y=1 (full width) severs every path from entrance (0,0)
	# to E's access cell (3,2).
	var wall_fp: Array[Vector2i] = []
	for x in GRID_W:
		wall_fp.append(Vector2i(x, 1))
	var wall_ac: Array[Vector2i] = [Vector2i(9, 7)]
	gs.call("commit", 2, wall_fp, wall_ac, R0)

	cong.call("on_tick", 1)  # flush the pending batch
	_check(bool(cong.call("is_access_reachable", 1)) == false,
		"AC13: walled off -> access_reachable[1] == false")
	var ar: Dictionary = cong.get("access_reachable")
	_check(ar.has(1) and bool(ar[1]) == false,
		"AC13: access_reachable dict has E -> false (flag present, not absent)")


func _test_ac13_narrow_corridor_blocked() -> void:
	print("\n[AC13 edge] narrow corridor blocked by new placement -> false")
	# Wall A leaves a single gap at (3,1) forming a corridor down to E's access
	# cell (3,2). Wall B then blocks the gap.
	var eq: Array = [{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)}]
	var gs := _make_grid(eq)
	var ms := _make_member_sim()
	var nav := _make_real_navigation(gs)

	# Corridor walls: row y=1 blocked except x=3 (the corridor mouth).
	var corridor_fp: Array[Vector2i] = []
	for x in GRID_W:
		if x != 3:
			corridor_fp.append(Vector2i(x, 1))
	var corridor_ac: Array[Vector2i] = [Vector2i(9, 7)]
	gs.call("commit", 2, corridor_fp, corridor_ac, R0)

	var rig := _make_congestion(gs, ms, nav)
	var cong: RefCounted = rig["congestion"]
	cong.call("on_tick", 0)
	_check(bool(cong.call("is_access_reachable", 1)) == true,
		"AC13-edge: corridor open -> E reachable (baseline true)")

	# Block the corridor mouth.
	var block_fp: Array[Vector2i] = [Vector2i(3, 1)]
	var block_ac: Array[Vector2i] = [Vector2i(8, 7)]
	gs.call("commit", 3, block_fp, block_ac, R0)
	cong.call("on_tick", 1)
	_check(bool(cong.call("is_access_reachable", 1)) == false,
		"AC13-edge: corridor mouth blocked -> access_reachable[1] == false")


# === AC9: removal same-tick ===

func _test_ac9_removal_same_tick_not_found() -> void:
	print("\n[AC9] grid_changed removes E -> same-tick entry deletion, query returns not-found (never stale)")
	var eq: Array = [{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)}]
	var gs := _make_grid(eq)
	var ms := _make_member_sim()
	ms.set("members", [_member(90, "USING", Vector2i(3, 2))])
	_reserve(ms, 1, 90)
	var nav := _make_real_navigation(gs)
	var rig := _make_congestion(gs, ms, nav)
	var cong: RefCounted = rig["congestion"]

	# Build up an active entry: occupant -> prev[1] = 0.3*(0.7*0.5) = 0.105.
	cong.call("on_tick", 0)
	var stale: float = cong.call("per_equipment_congestion", 1)
	_check(stale > 0.0, "AC9: pre-removal E has a live non-zero scalar (%.4f)" % stale)
	_check(bool(cong.call("is_access_reachable", 1)) == true,
		"AC9: pre-removal E is reachable (baseline)")

	# grid_changed removes E during tick t.
	_clear(gs, 1)

	# Core Rule 6: entries deleted the SAME tick — observable before tick t+1.
	var prev: Dictionary = cong.get("prev")
	var next: Dictionary = cong.get("next")
	var ar: Dictionary = cong.get("access_reachable")
	_check(not prev.has(1), "AC9: prev no longer has E (same-tick drop)")
	_check(not next.has(1), "AC9: next no longer has E (same-tick drop)")
	_check(not ar.has(1), "AC9: access_reachable no longer has E (same-tick drop)")

	# Tick t+1 begins: querying E returns "not found" — never a stale float.
	cong.call("on_tick", 1)
	_check(cong.call("per_equipment_congestion", 1) == 0.0,
		"AC9: per_equipment_congestion(E) == 0.0 neutral (not stale %.4f)" % stale)
	_check(bool(cong.call("is_access_reachable", 1)) == false,
		"AC9: is_access_reachable(E) == false after removal")


func _test_ac9_remove_readd_same_tick_fresh_state() -> void:
	print("\n[AC9 edge] E removed AND re-added in same tick -> new entry, fresh state")
	var eq: Array = [{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)}]
	var gs := _make_grid(eq)
	var ms := _make_member_sim()
	ms.set("members", [_member(90, "USING", Vector2i(3, 2))])
	_reserve(ms, 1, 90)
	var nav := _make_real_navigation(gs)
	var rig := _make_congestion(gs, ms, nav)
	var cong: RefCounted = rig["congestion"]

	cong.call("on_tick", 0)
	var stale: float = cong.call("per_equipment_congestion", 1)
	_check(stale > 0.0, "AC9-edge: pre-removal E has live scalar %.4f" % stale)

	# Remove AND re-add before the next tick — both grid_changed events fire.
	# The re-added machine is fresh (no occupant yet): clear the reservation
	# so the fresh EMA starts from occupancy 0, NOT the stale 0.105 value.
	_clear(gs, 1)
	(ms.get("reservations") as Dictionary).erase(1)
	_commit(gs, 1, Vector2i(2, 2), Vector2i(3, 2))

	var prev: Dictionary = cong.get("prev")
	_check(not prev.has(1), "AC9-edge: stale entry dropped despite same-tick re-add")

	cong.call("on_tick", 1)
	# Re-added machine: fresh EMA from prev=0. The erstwhile occupant is now
	# just a loiterer at the access cell -> dens = 1/3 -> raw = 0.3*(1/3) =
	# 0.1 -> fresh = alpha*raw + (1-alpha)*0 = 0.3*0.1 = 0.03. If the stale
	# prev (0.105) had survived, the blend would be 0.3*0.1 + 0.7*0.105.
	var fresh: float = cong.call("per_equipment_congestion", 1)
	var expected_fresh := 0.3 * (0.3 * (1.0 / 3.0))
	_check(absf(fresh - expected_fresh) < 1e-9 and fresh != stale,
		"AC9-edge: fresh state (%.4f) computed from prev=0, not stale (%.4f)" % [fresh, stale])
	_check(bool(cong.call("is_access_reachable", 1)) == true,
		"AC9-edge: re-added E recomputed reachable (fresh flag)")


func _test_ac9_removal_drop_without_navigation() -> void:
	print("\n[AC9] Core Rule 6 removal-drop works even WITHOUT navigation (no reachability)")
	var eq: Array = [{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)}]
	var gs := _make_grid(eq)
	var ms := _make_member_sim()
	# NO navigation supplied — reachability off, but removal handling is
	# grid-only (Core Rule 6) and must still drop entries.
	var rig := _make_congestion(gs, ms, null, ENTRANCE)
	var cong: RefCounted = rig["congestion"]

	ms.set("members", [_member(90, "USING", Vector2i(3, 2))])
	_reserve(ms, 1, 90)
	cong.call("on_tick", 0)
	var stale: float = cong.call("per_equipment_congestion", 1)
	_check(stale > 0.0, "AC9-no-nav: live scalar before removal %.4f" % stale)

	_clear(gs, 1)
	var prev: Dictionary = cong.get("prev")
	_check(not prev.has(1), "AC9-no-nav: prev entry dropped same tick without navigation")
	cong.call("on_tick", 1)
	_check(cong.call("per_equipment_congestion", 1) == 0.0,
		"AC9-no-nav: query returns neutral 0.0 (never stale %.4f)" % stale)


# === AC16: batch dedupe ===

func _test_ac16_two_events_one_recompute_final_state() -> void:
	print("\n[AC16] two grid_changed events in one tick -> exactly one recompute, final state")
	var eq: Array = [{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)}]
	var gs := _make_grid(eq)
	var ms := _make_member_sim()
	var spy_rig := _make_spy_navigation(gs)
	var spy: RefCounted = spy_rig["spy"]
	var rig := _make_congestion(gs, ms, spy)
	var cong: RefCounted = rig["congestion"]

	# Wall A (partial row) does NOT sever E yet; wall B completes the row and
	# DOES sever. Final post-batch state: E unreachable. Wall access cells sit
	# BELOW the wall line (row 0) so the walls themselves stay reachable.
	var wall_a_fp: Array[Vector2i] = []
	for x in range(6):
		wall_a_fp.append(Vector2i(x, 1))
	var wall_a_ac: Array[Vector2i] = [Vector2i(5, 0)]
	gs.call("commit", 2, wall_a_fp, wall_a_ac, R0)
	var wall_b_fp: Array[Vector2i] = []
	for x in range(6, GRID_W):
		wall_b_fp.append(Vector2i(x, 1))
	var wall_b_ac: Array[Vector2i] = [Vector2i(9, 0)]
	gs.call("commit", 3, wall_b_fp, wall_b_ac, R0)

	spy.call("reset_call_count")
	cong.call("on_tick", 1)  # ONE tick flushes the whole batch
	_check(int(spy.get("get_path_call_count")) == 3,
		"AC16: exactly one recompute over 3 equipment (got %d get_path calls, not 6)" % int(spy.get("get_path_call_count")))
	_check(bool(cong.call("is_access_reachable", 1)) == false,
		"AC16: E recomputed against FINAL post-batch grid state (unreachable)")
	_check(bool(cong.call("is_access_reachable", 2)) == true,
		"AC16: wall A's own access cell still reachable")
	_check(bool(cong.call("is_access_reachable", 3)) == true,
		"AC16: wall B's own access cell still reachable")


# === Unknown-id read defaults ===

func _test_unknown_id_read_defaults() -> void:
	print("\n[READ] unknown/never-seen id reads false (flag absence, not stale)")
	var eq: Array = [{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)}]
	var gs := _make_grid(eq)
	var ms := _make_member_sim()
	var nav := _make_real_navigation(gs)
	var rig := _make_congestion(gs, ms, nav)
	var cong: RefCounted = rig["congestion"]

	_check(bool(cong.call("is_access_reachable", 999)) == false,
		"READ: never-seen id 999 -> false (flag absent)")
	_check(cong.call("per_equipment_congestion", 999) == 0.0,
		"READ: never-seen id 999 -> neutral 0.0 scalar")
