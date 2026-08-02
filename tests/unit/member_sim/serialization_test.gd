# tests/unit/member_sim/serialization_test.gd
# Story MS-005: Serialization, Determinism and Flow Hypothesis
# (production/epics/member-sim/story-005-serialization-determinism-flow-hypothesis.md)
#
# Covers the BLOCKING ACs (TR-MS-008..014):
#   - AC7 [INT] GIVEN a save with member_id_counter = 42 and no active
#     member id >= 42, WHEN a new member spawns after load, THEN its
#     member_id is 42 (not max(active)+1). Edge: active ids 1..5 with
#     counter 42 -> new member gets 42. Verified both through MemberSim's
#     direct deserialize() and through the full SaveLoad blob pipeline.
#   - AC8 [UNIT] GIVEN a load payload missing member_id_counter, or with
#     member_id_counter <= max(active member_id), WHEN load executes, THEN
#     it fails loudly, never silently substituting a derived value. Edges:
#     counter exactly equal to max active id (fails); counter missing
#     entirely (fails); legacy SL-002-era entries (no "state" key) are
#     exempt — they were never allocated from the counter (preserves the
#     pre-wiring save-load integration tests' contract).
#   - AC9 [UNIT] GIVEN a GONE member's retired member_id, WHEN any number
#     of later spawns occur across a save/load boundary, THEN that id is
#     never reassigned. Verified with a real GONE cycle and with a
#     monotonic-counter spawn sweep across multiple load boundaries.
# Plus the Core Rule 7 load-side contract:
#   - the reservation map is REBUILT from members' own serialized claim
#     flags (USING -> occupant, WALKING_TO/QUEUEING -> next_claimant) —
#     never serialized as separate truth; a restored USING+QUEUEING pair
#     continues correctly (no deadlock).
#   - load-side AC4 mirror: two members claiming the same machine's
#     occupant or queue slot in the payload fails validation.
#   - JSON round-trip: serialize() emits the JSON-safe [x, y] cell encoding
#     (never raw Vector2i); a JSON.stringify/parse round-trip restores
#     Vector2i cells, int fields (JSON parses ints as floats in 4.7.1) and
#     int-keyed blacklists (JSON stringifies dict keys), and the rebuilt
#     reservation map stays consistent with member states.
#
# Run standalone: godot --headless --script tests/unit/member_sim/serialization_test.gd
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
	print("  UNIT TEST: MemberSim — Serialization, Determinism (Story MS-005)")
	print("=".repeat(48))

	_test_ac7_counter_restore_spawns_42()
	_test_ac7_full_blob_round_trip_spawns_42()
	_test_ac7_edge_active_ids_1_to_5()
	_test_ac8_missing_counter_fails_loudly()
	_test_ac8_counter_equal_max_active_fails()
	_test_ac8_counter_below_max_fails()
	_test_ac8_counter_above_max_passes()
	_test_ac8_legacy_payload_exempt()
	_test_ac9_real_gone_cycle_never_reuses()
	_test_ac9_spawn_sweep_across_loads()
	_test_reservation_rebuild_using_queueing_continues()
	_test_reservation_rebuild_walking_to()
	_test_reservation_double_claim_fails()
	_test_json_roundtrip_restores_types()
	_test_serialize_side_effect_free_and_deterministic()

	print("\n=== SERIALIZATION TEST: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


# === Helpers (mirror the MS-003/MS-004 rig) ===

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


func _TS() -> Script:
	return load("res://src/systems/time_system.gd") as Script


func _CG() -> Script:
	return load("res://src/systems/congestion.gd") as Script


func _ST() -> Script:
	return load("res://src/systems/satisfaction.gd") as Script


func _ECO() -> Script:
	return load("res://src/systems/economy.gd") as Script


func _SL() -> Script:
	return load("res://src/systems/save_load.gd") as Script


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
	# treadmill def with per-equipment use-duration fields (TR-MS-009).
	var def = _ED().new("treadmill", "Treadmill", ["cardio"], fp, ac, 100, "", effects, 200, 35, 100, 300)
	cat.call("_add_definition", def)
	cat.call("_freeze")
	return cat


func _commit_equipment(gs: RefCounted, instance_id: int, fp: Vector2i, ac: Vector2i) -> void:
	var fp_arr: Array[Vector2i] = [fp]
	var ac_arr: Array[Vector2i] = [ac]
	gs.call("commit", instance_id, fp_arr, ac_arr, R0)


## Builds the full configured MemberSim rig. [equipment] lists {id, fp, ac}
## commits. [config] merges over the base (zero arrivals unless a test
## raises the rate).
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


## A valid serialized-state payload: the rig's current serialize() output
## with [members] and [member_id_counter] overridden. rng_state stays valid.
func _payload(rig: Dictionary, member_id_counter: int, members: Array) -> Dictionary:
	var s: Dictionary = rig["member_sim"].call("serialize")
	return {
		"counter": s["counter"],
		"members": members,
		"member_id_counter": member_id_counter,
		"rng_state": s["rng_state"],
	}


# === AC7: counter restore — the new spawn gets 42, not max(active)+1 ===

func _test_ac7_counter_restore_spawns_42() -> void:
	print("\n[AC7] load payload with member_id_counter=42 + active ids 1..5 -> _spawn_member assigns id 42 (not max+1=6)")
	var equipment: Array = [
		{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)},
		{"id": 2, "fp": Vector2i(5, 2), "ac": Vector2i(6, 2)},
	]
	var rig := _make_rig(0xAC7001, equipment)
	var members: Array = []
	for i in range(1, 6):
		members.append(_make_member(i, "SELECTING_TARGET", 0, 3, ENTRANCE))
	var payload := _payload(rig, 42, members)
	var known := [1, 2]

	var result: RefCounted = rig["member_sim"].call("deserialize", payload, false, known)
	_check(bool(result.get("ok")), "AC7: deserialize(commit) ok (errors: %s)" % str(result.get("errors")))
	_check(int(rig["member_sim"].get("_member_id_counter")) == 42,
		"AC7: member_id_counter restored to 42 (got %d)" % int(rig["member_sim"].get("_member_id_counter")))

	rig["member_sim"].call("_spawn_member")
	var new_member := _find_member(rig, 42)
	_check(not new_member.is_empty(), "AC7: spawned member has member_id 42 (not max(active)+1=6)")
	_check(int(rig["member_sim"].get("_member_id_counter")) == 43, "AC7: counter advanced to 43")

	# A second spawn continues the monotonic counter.
	rig["member_sim"].call("_spawn_member")
	_check(not _find_member(rig, 43).is_empty(), "AC7: second spawn gets 43 (monotonic)")
	# The pre-existing ids 1..5 are untouched.
	_check((rig["member_sim"].get("members") as Array).size() == 7, "AC7: roster has 5 restored + 2 spawned")


func _test_ac7_full_blob_round_trip_spawns_42() -> void:
	print("\n[AC7][INT] full SaveLoad blob round-trip: save (counter 42) -> load -> spawn -> id 42")
	var src := _make_full_rig(0xAC7002)
	_commit_equipment(src["grid_system"], 1, Vector2i(2, 2), Vector2i(3, 2))
	_commit_equipment(src["grid_system"], 2, Vector2i(5, 2), Vector2i(6, 2))
	var members: Array = []
	for i in range(1, 6):
		members.append(_make_member(i, "SELECTING_TARGET", 0, 3, ENTRANCE))
	src["member_sim"].set("members", members)
	src["member_sim"].set("_member_id_counter", 42)
	var blob: Dictionary = src["save_load"].call("_perform_save")

	var fresh := _make_full_rig(0xAC7002)
	var load_result: RefCounted = fresh["save_load"].call("load", blob, _open_snapshot())
	_check(bool(load_result.get("ok")), "AC7[INT]: full blob load ok (errors: %s)" % str(load_result.get("errors")))
	_check(int(fresh["member_sim"].get("_member_id_counter")) == 42,
		"AC7[INT]: member_id_counter restored through the blob (got %d)" % int(fresh["member_sim"].get("_member_id_counter")))

	fresh["member_sim"].call("_spawn_member")
	_check(not _find_member(fresh, 42).is_empty(), "AC7[INT]: spawn after full load gets id 42")


func _test_ac7_edge_active_ids_1_to_5() -> void:
	print("\n[AC7 QA edge] active ids 1..5 with counter 42 -> new member gets 42 (assert explicitly != 6)")
	var equipment: Array = [{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)}]
	var rig := _make_rig(0xAC7003, equipment)
	var members: Array = []
	for i in range(1, 6):
		members.append(_make_member(i, "SELECTING_TARGET", 0, 3, ENTRANCE))
	var result: RefCounted = rig["member_sim"].call("deserialize", _payload(rig, 42, members), false, [1])
	_check(bool(result.get("ok")), "AC7[edge]: load ok (errors: %s)" % str(result.get("errors")))
	rig["member_sim"].call("_spawn_member")
	var spawned_id := -1
	for m in (rig["member_sim"].get("members") as Array):
		if int(m["member_id"]) > 5:
			spawned_id = int(m["member_id"])
	_check(spawned_id == 42, "AC7[edge]: new member id == 42 (got %d — never max(active)+1=6)" % spawned_id)


# === AC8: missing / illegal counter -> fail loudly, never derive ===

func _test_ac8_missing_counter_fails_loudly() -> void:
	print("\n[AC8] payload MISSING member_id_counter -> validate AND commit fail; nothing mutated")
	var equipment: Array = [{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)}]
	var rig := _make_rig(0xAC8001, equipment)
	var members: Array = [_make_member(1, "SELECTING_TARGET", 0, 3, ENTRANCE)]
	var payload := _payload(rig, 42, members)
	payload.erase("member_id_counter")

	var v_result: RefCounted = rig["member_sim"].call("deserialize", payload, true, [1])
	_check(not bool(v_result.get("ok")), "AC8: validate-only fails on missing counter")
	_check(str(v_result.get("errors")).find("member_id_counter") != -1,
		"AC8: error names member_id_counter (got %s)" % str(v_result.get("errors")))

	var c_result: RefCounted = rig["member_sim"].call("deserialize", payload, false, [1])
	_check(not bool(c_result.get("ok")), "AC8: commit fails on missing counter")
	_check((rig["member_sim"].get("members") as Array).is_empty(),
		"AC8: members NOT committed (roster still empty)")
	_check(int(rig["member_sim"].get("_member_id_counter")) == 0,
		"AC8: counter NOT silently derived (still 0)")


func _test_ac8_counter_equal_max_active_fails() -> void:
	print("\n[AC8 QA edge] counter EXACTLY equal to max active member_id -> fails (next spawn would reuse the id)")
	var equipment: Array = [{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)}]
	var rig := _make_rig(0xAC8002, equipment)
	var members: Array = [_make_member(42, "SELECTING_TARGET", 0, 3, ENTRANCE)]
	var result: RefCounted = rig["member_sim"].call("deserialize", _payload(rig, 42, members), false, [1])
	_check(not bool(result.get("ok")), "AC8: counter == max active id (42) fails")
	_check(str(result.get("errors")).find("max active member_id 42") != -1,
		"AC8: error names the collision (got %s)" % str(result.get("errors")))


func _test_ac8_counter_below_max_fails() -> void:
	print("\n[AC8] counter BELOW max active member_id -> fails (monotonicity violated)")
	var equipment: Array = [{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)}]
	var rig := _make_rig(0xAC8003, equipment)
	var members: Array = [_make_member(42, "SELECTING_TARGET", 0, 3, ENTRANCE)]
	var result: RefCounted = rig["member_sim"].call("deserialize", _payload(rig, 41, members), false, [1])
	_check(not bool(result.get("ok")), "AC8: counter 41 < max active id 42 fails")


func _test_ac8_counter_above_max_passes() -> void:
	print("\n[AC8] counter ABOVE max active member_id -> passes")
	var equipment: Array = [{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)}]
	var rig := _make_rig(0xAC8004, equipment)
	var members: Array = [_make_member(42, "SELECTING_TARGET", 0, 3, ENTRANCE)]
	var result: RefCounted = rig["member_sim"].call("deserialize", _payload(rig, 43, members), false, [1])
	_check(bool(result.get("ok")), "AC8: counter 43 > max active id 42 loads ok (errors: %s)" % str(result.get("errors")))
	_check(int(rig["member_sim"].get("_member_id_counter")) == 43, "AC8: counter restored to 43")


func _test_ac8_legacy_payload_exempt() -> void:
	print("\n[AC8 compat] legacy SL-002-era entries (no 'state' key) are exempt — counter 0 with ids 10/11 loads ok (pre-wiring contract)")
	var equipment: Array = [
		{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)},
		{"id": 2, "fp": Vector2i(5, 2), "ac": Vector2i(6, 2)},
	]
	var rig := _make_rig(0xAC8005, equipment)
	var legacy := [
		{"member_id": 10, "equipment_instance_id": 1},
		{"member_id": 11, "equipment_instance_id": 2},
	]
	var result: RefCounted = rig["member_sim"].call("deserialize", _payload(rig, 0, legacy), false, [1, 2])
	_check(bool(result.get("ok")), "AC8[compat]: legacy payload with counter 0 loads ok (errors: %s)" % str(result.get("errors")))
	# The restored roster keeps the legacy shape (SL-003 byte-identical canary).
	var restored: Array = rig["member_sim"].get("members")
	_check(restored.size() == 2 and not (restored[0] is Dictionary and restored[0].has("state")),
		"AC8[compat]: legacy entries restored verbatim (passive, no state key)")


# === AC9: retired ids are never reassigned ===

func _test_ac9_real_gone_cycle_never_reuses() -> void:
	print("\n[AC9] real GONE cycle: member leaves -> save -> load -> spawn -> retired id never reused")
	var equipment: Array = [
		{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)},
		{"id": 2, "fp": Vector2i(5, 2), "ac": Vector2i(6, 2)},
	]
	# exercises_per_visit=1 + short use -> members complete and leave.
	var cfg := {
		"base_arrival_rate_per_min": 600.0,  # p ~ 1.0/tick — spawn on the first tick
		"use_duration_mean_ticks": 2,
		"use_duration_stddev_ticks": 0,
		"use_duration_min_ticks": 1,
		"use_duration_max_ticks": 3,
		"exercises_mean": 1.0,
		"exercises_stddev": 0.0,
		"exercises_min": 1,
		"exercises_max": 1,
	}
	var rig := _make_rig(0xAC9001, equipment, [], cfg)
	# Track every id that ever exists; retired = seen - still-present.
	var seen: Dictionary = {}
	var retired: Dictionary = {}
	var exited := 0
	for t in 120:
		_run_ticks(rig, 1, t)
		var present: Dictionary = {}
		for m in (rig["member_sim"].get("members") as Array):
			var mid := int(m["member_id"])
			present[mid] = true
			if not seen.has(mid):
				seen[mid] = true
		for mid in seen.keys():
			if not present.has(mid):
				retired[mid] = true
		if not retired.is_empty():
			exited += 1
	_check(not retired.is_empty(), "AC9: at least one member went GONE during the run (retired ids: %s)" % str(retired.keys()))

	var payload: Dictionary = rig["member_sim"].call("serialize")
	var fresh := _make_rig(0xAC9002, equipment, [], cfg)
	var load_result: RefCounted = fresh["member_sim"].call("deserialize", payload, false, [1, 2])
	_check(bool(load_result.get("ok")), "AC9: serialized state loads ok (errors: %s)" % str(load_result.get("errors")))
	var counter_after_load := int(fresh["member_sim"].get("_member_id_counter"))
	_check(counter_after_load > 0, "AC9: counter survives the load (%d)" % counter_after_load)

	# Spawn a burst after load — none may equal a retired id (all retired ids
	# are < counter by construction, and spawns only ever take counter++).
	var roster_before: Array = fresh["member_sim"].get("members").duplicate()
	var collisions: Array = []
	for i in 20:
		fresh["member_sim"].call("_spawn_member")
	var fresh_roster: Array = fresh["member_sim"].get("members")
	for m in fresh_roster:
		var mid := int(m["member_id"])
		if retired.has(mid):
			collisions.append(mid)
	_check(collisions.is_empty(),
		"AC9: 20 post-load spawns NEVER reuse a retired id (collisions: %s)" % str(collisions))
	# Every POST-LOAD spawn (the members added after the load, i.e. not in the
	# restored roster) got an id >= the restored counter.
	var min_post := 1 << 62
	for m in fresh_roster:
		if roster_before.has(m):
			continue
		min_post = mini(min_post, int(m["member_id"]))
	_check(min_post >= counter_after_load,
		"AC9: every post-load spawn id >= restored counter (min %d >= %d)" % [min_post, counter_after_load])


func _test_ac9_spawn_sweep_across_loads() -> void:
	print("\n[AC9] monotonic sweep across MULTIPLE save/load boundaries — ids keep climbing, never revisit the past")
	var equipment: Array = [{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)}]
	var rig := _make_rig(0xAC9003, equipment)
	var prev_max_spawned := -1
	for cycle in 3:
		var members: Array = [_make_member(1, "SELECTING_TARGET", 0, 3, ENTRANCE)]
		var counter := 10 + cycle * 5
		var result: RefCounted = rig["member_sim"].call("deserialize", _payload(rig, counter, members), false, [1])
		_check(bool(result.get("ok")), "AC9[cycle %d]: load with counter %d ok" % [cycle, counter])
		rig["member_sim"].call("_spawn_member")
		rig["member_sim"].call("_spawn_member")
		var spawned: Array = []
		for m in (rig["member_sim"].get("members") as Array):
			if int(m["member_id"]) >= counter:
				spawned.append(int(m["member_id"]))
		_check(spawned == [counter, counter + 1],
			"AC9[cycle %d]: spawns are exactly %d, %d (got %s)" % [cycle, counter, counter + 1, str(spawned)])
		prev_max_spawned = counter + 1
	_check(prev_max_spawned == 21, "AC9: sweep completed across 3 load boundaries (max spawned %d)" % prev_max_spawned)


# === Core Rule 7: reservation map rebuilt from claim flags ===

func _test_reservation_rebuild_using_queueing_continues() -> void:
	print("\n[rebuild] USING member 5 (occupant) + QUEUEING member 7 (next_claimant) -> map rebuilt; 7 steps in when 5 leaves")
	var equipment: Array = [{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)}]
	var rig := _make_rig(0xAC70B1, equipment)
	var members: Array = [
		_make_member(5, "USING", 0, 3, Vector2i(3, 2), {"target_equipment_instance_id": 1, "use_ticks_remaining": 2}),
		_make_member(7, "QUEUEING", 0, 3, Vector2i(3, 3), {"target_equipment_instance_id": 1, "patience_ticks_remaining": 80}),
	]
	var result: RefCounted = rig["member_sim"].call("deserialize", _payload(rig, 100, members), false, [1])
	_check(bool(result.get("ok")), "rebuild: load ok (errors: %s)" % str(result.get("errors")))
	var res: Dictionary = _reservations(rig)
	_check(res.has(1) and res[1]["occupant"] == 5 and res[1]["next_claimant"] == 7,
		"rebuild: reservations[1] = {occupant: 5, next_claimant: 7} (got %s)" % str(res.get(1)))

	# Member 5's use ends -> releases occupant -> 7 steps onto the access cell.
	var m7_using := false
	for t in 10:
		_run_ticks(rig, 1, t)
		var m7 := _find_member(rig, 7)
		if not m7.is_empty() and str(m7["state"]) == "USING":
			m7_using = true
			break
	_check(m7_using, "rebuild: queued member 7 becomes USING after the occupant releases (no deadlock)")
	res = _reservations(rig)
	_check(res[1]["occupant"] == 7 and res[1]["next_claimant"] == null,
		"rebuild: handoff completed — occupant 7, queue slot free (got %s)" % str(res.get(1)))


func _test_reservation_rebuild_walking_to() -> void:
	print("\n[rebuild] WALKING_TO member with a cached path -> next_claimant rebuilt; member keeps walking")
	var equipment: Array = [{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)}]
	var rig := _make_rig(0xAC70B2, equipment)
	var path: Array[Vector2i] = [Vector2i(1, 2), Vector2i(2, 2), Vector2i(3, 2)]
	var members: Array = [
		_make_member(5, "WALKING_TO", 0, 3, Vector2i(1, 2), {
			"target_equipment_instance_id": 1,
			"cached_path": path,
			"cached_path_grid_version": 0,
		}),
	]
	var result: RefCounted = rig["member_sim"].call("deserialize", _payload(rig, 100, members), false, [1])
	_check(bool(result.get("ok")), "rebuild[walk]: load ok (errors: %s)" % str(result.get("errors")))
	var res: Dictionary = _reservations(rig)
	_check(res.has(1) and res[1]["next_claimant"] == 5, "rebuild[walk]: reservations[1].next_claimant == 5 (got %s)" % str(res.get(1)))
	# The restored member's cell is a real Vector2i (not a JSON array).
	var m5 := _find_member(rig, 5)
	_check(not m5.is_empty() and m5["cell"] is Vector2i, "rebuild[walk]: restored cell is Vector2i (got %s)" % str(m5.get("cell")))


func _test_reservation_double_claim_fails() -> void:
	print("\n[load-side AC4] two members claiming the SAME machine's occupant or queue slot -> load fails (corrupt save)")
	var equipment: Array = [{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)}]
	var rig := _make_rig(0xAC70B3, equipment)
	var double_occupant: Array = [
		_make_member(5, "USING", 0, 3, Vector2i(3, 2), {"target_equipment_instance_id": 1}),
		_make_member(7, "USING", 0, 3, Vector2i(3, 3), {"target_equipment_instance_id": 1}),
	]
	var r1: RefCounted = rig["member_sim"].call("deserialize", _payload(rig, 100, double_occupant), false, [1])
	_check(not bool(r1.get("ok")) and str(r1.get("errors")).find("occupant by BOTH") != -1,
		"load-side AC4: double occupant rejected (got %s)" % str(r1.get("errors")))

	var double_claimant: Array = [
		_make_member(5, "QUEUEING", 0, 3, Vector2i(3, 3), {"target_equipment_instance_id": 1}),
		_make_member(7, "QUEUEING", 0, 3, Vector2i(4, 3), {"target_equipment_instance_id": 1}),
	]
	var r2: RefCounted = rig["member_sim"].call("deserialize", _payload(rig, 100, double_claimant), false, [1])
	_check(not bool(r2.get("ok")) and str(r2.get("errors")).find("queue slot claimed by BOTH") != -1,
		"load-side AC4: double queue claim rejected (got %s)" % str(r2.get("errors")))


# === JSON file-path fidelity ===

func _test_json_roundtrip_restores_types() -> void:
	print("\n[JSON] serialize -> JSON.stringify -> parse -> deserialize: Vector2i cells, int fields, int blacklist keys, rebuilt reservations")
	var equipment: Array = [
		{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)},
		{"id": 2, "fp": Vector2i(5, 2), "ac": Vector2i(6, 2)},
	]
	var cfg := {
		"base_arrival_rate_per_min": 480.0,  # heavy spawns -> real state variety
		"use_duration_mean_ticks": 3,
		"use_duration_stddev_ticks": 0,
		"use_duration_min_ticks": 2,
		"use_duration_max_ticks": 4,
		"exercises_mean": 1.0,
		"exercises_stddev": 0.0,
		"exercises_min": 1,
		"exercises_max": 2,
		"patience_min_ticks": 3,
		"patience_max_ticks": 5,
	}
	var rig := _make_rig(0xAC7C01, equipment, [], cfg)
	_run_ticks(rig, 40)
	var live_members: Array = rig["member_sim"].get("members")
	_check(not live_members.is_empty(), "JSON: rig produced live state-machine members after 40 ticks")

	var payload: Dictionary = rig["member_sim"].call("serialize")
	# serialize() emits JSON-safe [x, y] cells — never raw Vector2i.
	var first: Dictionary = payload["members"][0]
	if first.has("cell"):
		_check(first["cell"] is Array and (first["cell"] as Array).size() == 2,
			"JSON: serialize() emits cell as [x, y] array (got %s)" % str(first["cell"]))

	var json_str := JSON.stringify(payload, "  ", true, true)
	var parsed: Variant = JSON.parse_string(json_str)
	_check(parsed is Dictionary, "JSON: JSON.stringify/parse round-trips the payload")

	var fresh := _make_rig(0xAC7C02, equipment, [], cfg)
	var result: RefCounted = fresh["member_sim"].call("deserialize", parsed, false, [1, 2])
	_check(bool(result.get("ok")), "JSON: deserialize(parsed) ok (errors: %s)" % str(result.get("errors")))

	# Types restored: cells Vector2i, member ids int, blacklist keys int.
	var type_ok := true
	var path_ok := true
	for m in (fresh["member_sim"].get("members") as Array):
		if m.has("cell") and not (m["cell"] is Vector2i):
			type_ok = false
		if not (m["member_id"] is int):
			type_ok = false
		if m.has("cached_path"):
			for v in m["cached_path"]:
				if not (v is Vector2i):
					path_ok = false
	_check(type_ok, "JSON: all restored cells are Vector2i and member_ids are int")
	_check(path_ok, "JSON: all restored cached_path entries are Vector2i")

	# Rebuilt reservations are consistent with member states (the AC4
	# consistency half of the load-side contract).
	var res: Dictionary = fresh["member_sim"].get("reservations")
	var consistent := true
	for m in (fresh["member_sim"].get("members") as Array):
		if not m.has("state") or not m.has("target_equipment_instance_id"):
			continue
		var target := int(m["target_equipment_instance_id"])
		if target < 0:
			continue
		var mid := int(m["member_id"])
		match str(m["state"]):
			"USING":
				if not (res.has(target) and res[target]["occupant"] == mid):
					consistent = false
			"WALKING_TO", "QUEUEING":
				if not (res.has(target) and res[target]["next_claimant"] == mid):
					consistent = false
	_check(consistent, "JSON: rebuilt reservation map consistent with restored member states")

	# And the restored sim keeps RUNNING deterministically (no type crash).
	var crashed := false
	for t in 20:
		var err_before := _fail
		fresh["member_sim"].call("on_tick", 100 + t)
		if _fail > err_before:
			crashed = true
			break
	_check(not crashed, "JSON: restored sim runs 20 more ticks without error")


# === serialize() purity ===

func _test_serialize_side_effect_free_and_deterministic() -> void:
	print("\n[serialize] serialize() is pure and deterministic: two calls, identical payload; no RNG draw, no counter mutation")
	var equipment: Array = [{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)}]
	var rig := _make_rig(0xAC7D01, equipment)
	_run_ticks(rig, 5)
	var before := int(rig["member_sim"].get("counter"))
	var rng_before: int = rig["seeded_rng"].call("get_rng", "MemberSim").state
	var a: Dictionary = rig["member_sim"].call("serialize")
	var b: Dictionary = rig["member_sim"].call("serialize")
	_check(str(a) == str(b), "serialize: two calls produce identical payloads")
	_check(int(rig["member_sim"].get("counter")) == before, "serialize: counter unchanged (side-effect free)")
	_check(rig["seeded_rng"].call("get_rng", "MemberSim").state == rng_before, "serialize: no RNG draw (side-effect free)")
	_check(a.has("member_id_counter") and a.has("rng_state") and a.has("counter") and a.has("members"),
		"serialize: blob carries {counter, members, member_id_counter, rng_state}")


# === Full SaveLoad pipeline rig (AC7 [INT]) ===
# Mirrors the SL-003 round-trip rig but wires a CONFIGURED MemberSim (real
# grid + navigation + catalog + entrance/exit) so full state-machine records
# flow through the blob. The derivation steps use the real Navigation (its
# rebuild(grid) signature matches what SaveLoad calls).

func _make_full_rig(master_seed: int) -> Dictionary:
	var orch := _make_orchestrator()
	var srg: RefCounted = _SRG().new()
	srg.call("init", master_seed)

	var ts: RefCounted = _TS().new()
	ts.call("init", orch, srg)
	orch.set("time_system", ts)

	var gs := _make_grid()
	orch.set("grid_system", gs)

	var nav := _make_navigation(gs)
	var cat := _make_catalog()
	var cfg: Dictionary = {
		"base_arrival_rate_per_min": 0.0,
		"max_concurrent_members": 15,
		"use_duration_mean_ticks": 2,
		"use_duration_stddev_ticks": 0,
		"use_duration_min_ticks": 1,
		"use_duration_max_ticks": 3,
		"exercises_mean": 2.0,
		"exercises_stddev": 0.0,
		"exercises_min": 1,
		"exercises_max": 5,
	}
	var member: RefCounted = _MS().new()
	member.call("init", orch, srg, gs, nav, cat, ENTRANCE, EXIT, cfg)
	orch.set("member_sim", member)

	var cong: RefCounted = _CG().new()
	cong.call("init", orch, srg)
	orch.set("congestion", cong)
	var sat: RefCounted = _ST().new()
	sat.call("init", orch, srg)
	orch.set("satisfaction", sat)
	var econ: RefCounted = _ECO().new()
	econ.call("init", orch, srg)
	orch.set("economy", econ)

	# Derivation steps: real Navigation (rebuild signature matches); the
	# other two systems don't exist in src/ yet — inert stand-ins (SL-002
	# DEVIATION #4 pattern).
	orch.set("navigation", nav)
	var placement: RefCounted = _DerivationStub.new()
	orch.set("placement_system", placement)
	var selection: RefCounted = _DerivationStub.new()
	orch.set("selection_system", selection)

	orch.set("_tick_systems", [member, cong, sat, econ])

	var sl: RefCounted = _SL().new()
	sl.call("init", orch)
	sl.call("_post_init")

	return {
		"orchestrator": orch,
		"seeded_rng": srg,
		"time_system": ts,
		"grid_system": gs,
		"navigation": nav,
		"member_sim": member,
		"congestion": cong,
		"satisfaction": sat,
		"economy": econ,
		"save_load": sl,
	}


## Inert derivation stand-in (PlacementSystem/SelectionSystem do not exist
## in src/ yet; SaveLoad null-guards them — SL-002 DEVIATION #4).
class _DerivationStub:
	extends RefCounted

	func rederive_counter() -> void:
		pass

	func rebuild_mapping() -> void:
		pass


## The all-open buildable snapshot matching the 8x6 rig grid (all cells 1).
func _open_snapshot() -> PackedByteArray:
	var snap := PackedByteArray()
	snap.resize(GRID_W * GRID_H)
	snap.fill(1)
	return snap
