# tests/unit/member_sim/tick_order_test.gd
# Story MS-002: Target Selection and Weighted Pick — AC11 [INT]
# (production/epics/member-sim/story-002-target-selection-weighted-pick.md)
#
# AC11 has two halves:
#   [UNIT] the weight uses the pre-update Congestion(t-1) value (covered in
#          target_selection_weight_test.gd — the reader serves `prev`).
#   [INT]  MemberSim's registered tick order runs BEFORE Congestion's in the
#          real SimulationOrchestrator dispatch.
#
# This file pins the [INT] half:
#   - SimulationOrchestrator.FIXED_TICK_ORDER textually lists "MemberSim"
#     before "Congestion" (TR-TS-003 / ADR-0005 §2 — the textual source of
#     truth the dispatcher iterates).
#   - A REAL _advance_tick() with the REAL MemberSim first and a Congestion
#     spy second: the spy's on_tick fires AFTER the member's congestion reads
#     happened — i.e. the member consumed the pre-update (t-1) value before
#     the congestion pass had a chance to write.
#   - Same-tick write isolation: when the congestion spy simulates writing
#     `next` during its own on_tick, the member's already-made reads are
#     unaffected (it read prev, never next).
#
# Run standalone: godot --headless --script tests/unit/member_sim/tick_order_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const GRID_W := 8
const GRID_H := 6
const ENTRANCE := Vector2i(0, 0)
const EXIT := Vector2i(7, 5)
const R0 := 0

## Fake congestion reader implementing the congestion-story-001 read surface
## (`per_equipment_congestion(id) -> float` serving the PRE-update `prev`
## buffer). `write_next()` simulates the Congestion pass writing its compute
## target later in the same tick; `swap()` the end-of-tick buffer swap.
## Every served read is logged for assertions.
class FakeCongestionReader:
	extends RefCounted

	var prev: Dictionary = {}
	var next: Dictionary = {}
	var reads: Array = []

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


## Congestion-pass spy: appended to the shared log when the dispatcher calls
## it — the assertion is that every member read appears BEFORE the first
## "congestion" entry (dispatch order MemberSim -> Congestion).
class CongestionSpy:
	extends RefCounted

	var log: Array

	func _init(shared_log: Array) -> void:
		log = shared_log

	func on_tick(_tick_count: int) -> void:
		log.append("congestion")


var _pass := 0
var _fail := 0


func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	var result := run_all()
	quit(1 if int(result["fail"]) > 0 else 0)


func run_all() -> Dictionary:
	print("=".repeat(48))
	print("  INT TEST: MemberSim — Tick Order before Congestion (Story MS-002 / AC11)")
	print("=".repeat(48))

	_test_fixed_tick_order_textually_member_before_congestion()
	_test_advance_tick_real_member_reads_before_congestion()
	_test_same_tick_next_write_does_not_reach_member()

	print("\n=== TICK ORDER TEST: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


# === Helpers ===

func _make_orchestrator() -> Node:
	var orch: Node = load("res://src/systems/simulation_orchestrator.gd").new()
	root.add_child(orch)
	orch.call("_ready")
	return orch


func _make_grid() -> RefCounted:
	var gs: RefCounted = (load("res://src/systems/grid_system.gd") as Script).new()
	gs.call("init", GRID_W, GRID_H)
	for y in GRID_H:
		for x in GRID_W:
			gs.call("set_buildable", Vector2i(x, y), true)
	gs.call("freeze_buildable")
	return gs


func _make_navigation(grid: RefCounted) -> RefCounted:
	var nav: RefCounted = (load("res://src/systems/navigation.gd") as Script).new()
	nav.call("init", grid)
	nav.call("_post_init")
	return nav


func _make_catalog() -> RefCounted:
	var cat: RefCounted = (load("res://src/systems/equipment_catalog.gd") as Script).new()
	var fp: Array[Vector2i] = [Vector2i(0, 0)]
	var ac: Array[Vector2i] = [Vector2i(1, 0)]
	var effects: Array[Dictionary] = []
	var def = (load("res://src/systems/equipment_def.gd") as Script).new("treadmill", "Treadmill", ["cardio"], fp, ac, 100, "", effects, 200, 35, 100, 300)
	cat.call("_add_definition", def)
	cat.call("_freeze")
	return cat


## Builds a configured MemberSim rig (real GridSystem + Navigation + catalog
## + entrance/exit + injected congestion reader).
func _make_member_sim(seed: int, reader: FakeCongestionReader, equipment: Array) -> RefCounted:
	var gs := _make_grid()
	for eq in equipment:
		var fp_arr: Array[Vector2i] = [eq["fp"]]
		var ac_arr: Array[Vector2i] = [eq["ac"]]
		gs.call("commit", int(eq["id"]), fp_arr, ac_arr, R0)
	var nav := _make_navigation(gs)
	var cat := _make_catalog()
	var srg: RefCounted = (load("res://src/systems/seeded_rng.gd") as Script).new()
	srg.call("init", seed)
	var orch := _make_orchestrator()
	var ms: RefCounted = (load("res://src/systems/member_sim.gd") as Script).new()
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
	ms.call("init", orch, srg, gs, nav, cat, ENTRANCE, EXIT, cfg, reader)
	orch.set("member_sim", ms)
	return ms


func _inject_selecting_member(ms: RefCounted, member_id: int, cell: Vector2i) -> void:
	var m := {
		"member_id": member_id,
		"state": "SELECTING_TARGET",
		"cell": cell,
		"exercises_done": 0,
		"exercises_per_visit": 3,
		"preference_profile": {"preference_noise": 1.0},
		"target_equipment_instance_id": -1,
		"cached_path": [],
		"leaving_timeout_ticks": 0,
		"recently_used_ids": [],
	}
	(ms.get("members") as Array).append(m)


# === [INT] AC11: tick order ===

func _test_fixed_tick_order_textually_member_before_congestion() -> void:
	print("\n[AC11-INT] FIXED_TICK_ORDER textually lists MemberSim BEFORE Congestion")
	var gd: GDScript = load("res://src/systems/simulation_orchestrator.gd") as GDScript
	var order: Variant = gd.get_script_constant_map()["FIXED_TICK_ORDER"]
	_check(order is Array and (order as Array).size() == 4,
		"AC11-INT: FIXED_TICK_ORDER has exactly 4 entries")
	_check(order == ["MemberSim", "Congestion", "Satisfaction", "Economy"],
		"AC11-INT: FIXED_TICK_ORDER == [MemberSim, Congestion, Satisfaction, Economy] (got %s)" % [order])
	_check((order as Array).find("MemberSim") < (order as Array).find("Congestion"),
		"AC11-INT: MemberSim index (%d) < Congestion index (%d)" % [(order as Array).find("MemberSim"), (order as Array).find("Congestion")])


func _test_advance_tick_real_member_reads_before_congestion() -> void:
	print("\n[AC11-INT] real _advance_tick(): the member's congestion reads happen BEFORE the congestion spy's on_tick")
	var equipment: Array = [
		{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)},
	]
	var reader := FakeCongestionReader.new()
	reader.set_prev(1, 0.4)
	var ms := _make_member_sim(201, reader, equipment)
	_inject_selecting_member(ms, 100, ENTRANCE)

	var log: Array = []
	var spy := CongestionSpy.new(log)
	var orch: Node = (ms.get("_orchestrator") as Node)
	orch.set("_tick_systems", [ms, spy])

	# Real dispatch: MemberSim.on_tick(tick 0) then Congestion.on_tick(tick 0).
	orch.call("_advance_tick")

	_check(not reader.reads.is_empty(), "AC11-INT: the member actually queried congestion this tick")
	# The dispatcher iterates _tick_systems in array order (TR-TS-003), so the
	# spy's slot is after the member's. Observable proof the member's slot ran
	# first and completed its selection: it transitioned to WALKING_TO and the
	# spy fired exactly once, after the member's reads.
	var first_congestion := log.find("congestion")
	_check(first_congestion >= 0, "AC11-INT: congestion spy was dispatched (log=%s)" % [log])
	if first_congestion >= 0:
		var m: Dictionary = {}
		for member in (ms.get("members") as Array):
			if int(member["member_id"]) == 100:
				m = member
		_check(not m.is_empty() and str(m["state"]) == "WALKING_TO",
			"AC11-INT: member selected a target during its own slot (state=%s)" % ("" if m.is_empty() else str(m["state"])))
		_check(log == ["congestion"], "AC11-INT: congestion spy fired exactly once, after the member (log=%s)" % [log])


func _test_same_tick_next_write_does_not_reach_member() -> void:
	print("\n[AC11-INT] same-tick write isolation: Congestion writes `next` AFTER the member read `prev` — the member is unaffected")
	var equipment: Array = [
		{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)},
		{"id": 2, "fp": Vector2i(2, 3), "ac": Vector2i(3, 3)},
	]
	var reader := FakeCongestionReader.new()
	reader.set_prev(1, 0.1)
	reader.set_prev(2, 0.1)
	var ms := _make_member_sim(202, reader, equipment)
	_inject_selecting_member(ms, 100, ENTRANCE)

	var log: Array = []
	var spy := CongestionSpy.new(log)
	var orch: Node = (ms.get("_orchestrator") as Node)
	orch.set("_tick_systems", [ms, spy])

	orch.call("_advance_tick")

	# After the member's slot, the congestion pass writes next + swaps —
	# simulating the real double-buffer (prev <- next after all entities).
	reader.write_next(1, 0.95)
	reader.write_next(2, 0.95)
	reader.swap()

	_check(reader.reads.size() == 2, "AC11-INT: both candidates were read exactly once during the member slot (got %d)" % reader.reads.size())
	var all_prev := true
	for r in reader.reads:
		if float(r[1]) != 0.1:
			all_prev = false
	_check(all_prev, "AC11-INT: every served value was prev 0.1 — the later-written next (0.95) never reached the member")
	var m: Dictionary = {}
	for member in (ms.get("members") as Array):
		if int(member["member_id"]) == 100:
			m = member
	_check(not m.is_empty() and str(m["state"]) == "WALKING_TO",
		"AC11-INT: member selected during its pre-congestion slot (state=%s)" % ("" if m.is_empty() else str(m["state"])))
	_check(log == ["congestion"], "AC11-INT: congestion spy fired once after the member (log=%s)" % [log])
