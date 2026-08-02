# tests/unit/congestion/determinism_no_rng_test.gd
# Story CG-004: Determinism and Serialization
# (production/epics/congestion/story-004-determinism-serialization.md)
#
# BLOCKING ACs covered (TR-CONG-006 / TR-CONG-007):
#   AC1  GIVEN an identical fixed sequence of member states across N ticks,
#        WHEN Congestion processes it twice (two instances), THEN
#        per_equipment_congestion, per_cell_density, and access_reachable
#        are bit-identical run-to-run.
#        Edge cases (QA): N=0 (no state), dense clusters, edge cells,
#        equipment removal mid-run.
#   AC2  [WB] GIVEN the Congestion source, WHEN statically inspected, THEN
#        it contains zero randi/randf/RandomNumberGenerator calls (grep),
#        and no randomize() either.
#
# Plus (story contract surface):
#   - S8 congestion_updated() emitted EXACTLY ONCE per tick after recompute
#   - the fixed float-summation order (ascending equipment_instance_id /
#     ascending flat cell index) is what makes the dual-run bit-identical
#   - serialize() output is a PURE READ (two identical calls -> identical
#     dicts) — no mutation, no RNG draws
#
# Run standalone: godot --headless --script tests/unit/congestion/determinism_no_rng_test.gd
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
	print("  UNIT TEST: Congestion — Determinism + No RNG (Story CG-004)")
	print("=".repeat(48))

	_test_ac1_dual_run_bit_identical()
	_test_ac1_n_zero_no_state()
	_test_ac1_dense_cluster_and_edge_cells()
	_test_ac1_equipment_removal_mid_run()
	_test_s8_emitted_once_per_tick()
	_test_ac2_static_zero_rng_calls()

	print("\n=== DETERMINISM NO-RNG TEST: %d passed, %d failed ===\n" % [_pass, _fail])
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


func _make_orchestrator() -> Node:
	var orch: Node = load("res://src/systems/simulation_orchestrator.gd").new()
	root.add_child(orch)
	orch.call("_ready")
	return orch


## Real GridSystem: GRID_W x GRID_H all buildable, frozen, with the given
## equipment committed. Each entry: {id, fp: Vector2i, ac: Vector2i}.
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


func _make_member_sim() -> RefCounted:
	return _MS().new()


func _make_real_navigation(gs: RefCounted) -> RefCounted:
	var nav: RefCounted = _NAV().new()
	nav.call("init", gs)
	nav.call("_post_init")
	return nav


## Builds a fully configured Congestion rig: real grid + member_sim +
## navigation + entrance (+ _post_init so grid_changed -> access_reachable
## recompute is live, like the real orchestrator). Two rigs built from the
## SAME arguments are the AC1 dual-run pair.
func _make_congestion(
	gs: RefCounted,
	ms: RefCounted,
	nav: RefCounted,
	config: Dictionary = {}
) -> Dictionary:
	var srg: RefCounted = _SRG().new()
	srg.call("init", 0xD3E7E91)
	var orch := _make_orchestrator()
	var cong: RefCounted = (load("res://src/systems/congestion.gd") as Script).new()
	cong.call("init", orch, srg, gs, ms, config, nav, ENTRANCE)
	cong.call("_post_init")
	return {"congestion": cong, "seeded_rng": srg, "orchestrator": orch, "member_sim": ms, "grid_system": gs}


func _member(member_id: int, state: String, cell: Vector2i) -> Dictionary:
	return {"member_id": member_id, "state": state, "cell": cell}


func _reserve(ms: RefCounted, id: int, occupant: Variant = null, claimant: Variant = null) -> void:
	var rec: Dictionary = {}
	if occupant != null:
		rec["occupant"] = occupant
	if claimant != null:
		rec["next_claimant"] = claimant
	(ms.get("reservations") as Dictionary)[id] = rec


## Applies the SAME fixed member-state to both rigs: members array +
## reservations. The sequence is driven externally (the test), so both
## instances see byte-identical inputs every tick.
func _apply_state(rig_a: Dictionary, rig_b: Dictionary, members: Array, reservations: Dictionary) -> void:
	rig_a["member_sim"].set("members", members)
	rig_b["member_sim"].set("members", members)
	rig_a["member_sim"].set("reservations", reservations)
	rig_b["member_sim"].set("reservations", reservations)


## Bit-identical comparison of ALL THREE outputs across both rigs.
## Floats compare with == (IEEE 754 exact — a 1-ULP difference fails).
## Returns true when identical, prints divergence details otherwise.
func _outputs_bit_identical(rig_a: Dictionary, rig_b: Dictionary, label: String) -> bool:
	var ca: RefCounted = rig_a["congestion"]
	var cb: RefCounted = rig_b["congestion"]
	var ok := true

	# 1) per_equipment_congestion for every placed id (ascending scan).
	var ids: Array = ca.call("_ascending_equipment_ids")
	for id in ids:
		var va: float = ca.call("per_equipment_congestion", id)
		var vb: float = cb.call("per_equipment_congestion", id)
		if va != vb:
			print("    DIVERGENCE[%s] per_equipment id=%d: %s vs %s" % [label, id, str(va), str(vb)])
			ok = false

	# 2) per_cell_density for EVERY cell.
	for y in GRID_H:
		for x in GRID_W:
			var va: float = ca.call("per_cell_density", Vector2i(x, y))
			var vb: float = cb.call("per_cell_density", Vector2i(x, y))
			if va != vb:
				print("    DIVERGENCE[%s] cell (%d,%d): %s vs %s" % [label, x, y, str(va), str(vb)])
				ok = false

	# 3) access_reachable for every placed id.
	for id in ids:
		var ra: bool = ca.call("is_access_reachable", id)
		var rb: bool = cb.call("is_access_reachable", id)
		if ra != rb:
			print("    DIVERGENCE[%s] access_reachable id=%d: %s vs %s" % [label, id, str(ra), str(rb)])
			ok = false
	return ok


## The canonical AC1 fixture: 3 equipment (ids 1,2,3) + a fixed 5-tick
## member-state sequence. Returns {rig_a, rig_b} with the sequence pre-run.
func _run_dual_instance_sequence(equipment: Array, sequence: Array) -> Dictionary:
	var gs_a := _make_grid(equipment)
	var gs_b := _make_grid(equipment)
	var ms_a := _make_member_sim()
	var ms_b := _make_member_sim()
	var nav_a := _make_real_navigation(gs_a)
	var nav_b := _make_real_navigation(gs_b)
	var rig_a := _make_congestion(gs_a, ms_a, nav_a)
	var rig_b := _make_congestion(gs_b, ms_b, nav_b)

	for t in sequence.size():
		var step: Dictionary = sequence[t]
		_apply_state(rig_a, rig_b, step.get("members", []), step.get("reservations", {}))
		rig_a["congestion"].call("on_tick", t)
		rig_b["congestion"].call("on_tick", t)
	return {"rig_a": rig_a, "rig_b": rig_b, "gs_a": gs_a, "gs_b": gs_b}


# === AC1: dual-run bit-identical ===

func _test_ac1_dual_run_bit_identical() -> void:
	print("\n[AC1] same 3-equipment fixed member-state sequence, 6 ticks, two instances -> bit-identical")
	var equipment: Array = [
		{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)},
		{"id": 2, "fp": Vector2i(5, 2), "ac": Vector2i(6, 2)},
		{"id": 3, "fp": Vector2i(2, 5), "ac": Vector2i(3, 5)},
	]
	var sequence: Array = [
		{"members": [_member(10, "USING", Vector2i(3, 2))], "reservations": {1: {"occupant": 10}}},
		{"members": [_member(10, "USING", Vector2i(3, 2)), _member(11, "WALKING_TO", Vector2i(4, 4))],
			"reservations": {1: {"occupant": 10}, 2: {"next_claimant": 11}}},
		{"members": [_member(10, "USING", Vector2i(3, 2)), _member(11, "QUEUEING", Vector2i(6, 2)),
			_member(12, "USING", Vector2i(3, 5))],
			"reservations": {1: {"occupant": 10, "next_claimant": 11}, 3: {"occupant": 12}}},
		{"members": [_member(10, "WALKING_TO", Vector2i(4, 2)), _member(12, "USING", Vector2i(3, 5))],
			"reservations": {3: {"occupant": 12}}},
		{"members": [_member(10, "USING", Vector2i(6, 2)), _member(12, "USING", Vector2i(3, 5))],
			"reservations": {2: {"occupant": 10}, 3: {"occupant": 12}}},
		{"members": [_member(10, "USING", Vector2i(6, 2)), _member(12, "WALKING_TO", Vector2i(4, 5)),
			_member(13, "USING", Vector2i(3, 2))],
			"reservations": {2: {"occupant": 10}, 1: {"occupant": 13}}},
	]
	var runs := _run_dual_instance_sequence(equipment, sequence)
	var rig_a: Dictionary = runs["rig_a"]
	var rig_b: Dictionary = runs["rig_b"]

	_check(_outputs_bit_identical(rig_a, rig_b, "AC1-6t"),
		"AC1: all three outputs bit-identical after 6 ticks (per_equipment + per_cell + access_reachable)")

	# Spot-check a known non-trivial value to prove the comparison isn't
	# vacuous: equipment 1 had occupancy tier 2 (occupant+claimant) at tick 3
	# -> prev[1] != 0.0 at the end.
	var v: float = rig_a["congestion"].call("per_equipment_congestion", 1)
	_check(v > 0.0, "AC1: congestion[1] non-zero after the sequence (got %s — comparison is meaningful)" % str(v))


func _test_ac1_n_zero_no_state() -> void:
	print("\n[AC1 edge] N=0 (no ticks, no member state) -> two instances identical (all 0.0 / empty)")
	var equipment: Array = [
		{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)},
		{"id": 2, "fp": Vector2i(5, 2), "ac": Vector2i(6, 2)},
	]
	var runs := _run_dual_instance_sequence(equipment, [])
	var rig_a: Dictionary = runs["rig_a"]
	var rig_b: Dictionary = runs["rig_b"]

	_check(_outputs_bit_identical(rig_a, rig_b, "AC1-N0"),
		"AC1[N0]: fresh instances (zero ticks) bit-identical")

	var v: float = rig_a["congestion"].call("per_equipment_congestion", 1)
	_check(v == 0.0, "AC1[N0]: fresh per_equipment_congestion reads 0.0 (idle)")
	var d: float = rig_a["congestion"].call("per_cell_density", Vector2i(3, 2))
	_check(d == 0.0, "AC1[N0]: fresh per_cell_density reads 0.0")


func _test_ac1_dense_cluster_and_edge_cells() -> void:
	print("\n[AC1 edge] dense cluster (8 members same cell) + edge/corner members -> bit-identical")
	var equipment: Array = [
		{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)},
	]
	# Members: 8 stacked on one interior cell (raw=8 -> smoothed 3.2, clamp
	# to 1.0), plus edge (0,y) and corner (0,0) members whose 4-neighbor
	# kernels drop out-of-bounds contributions.
	var dense: Array = []
	for i in 8:
		dense.append(_member(100 + i, "WALKING_TO", Vector2i(5, 4)))
	var sequence: Array = [
		{"members": dense + [_member(200, "WALKING_TO", Vector2i(0, 0)), _member(201, "USING", Vector2i(0, 3)),
			_member(202, "WALKING_TO", Vector2i(9, 7)), _member(203, "QUEUEING", Vector2i(9, 0))],
			"reservations": {1: {"occupant": 201, "next_claimant": 203}}},
		{"members": dense + [_member(200, "USING", Vector2i(0, 0)), _member(201, "WALKING_TO", Vector2i(1, 3)),
			_member(202, "WALKING_TO", Vector2i(8, 7)), _member(203, "QUEUEING", Vector2i(9, 0))],
			"reservations": {1: {"occupant": 200, "next_claimant": 203}}},
		{"members": dense + [_member(200, "WALKING_TO", Vector2i(0, 1)), _member(202, "USING", Vector2i(9, 7))],
			"reservations": {1: {"occupant": 202}}},
	]
	var runs := _run_dual_instance_sequence(equipment, sequence)
	var rig_a: Dictionary = runs["rig_a"]
	var rig_b: Dictionary = runs["rig_b"]

	_check(_outputs_bit_identical(rig_a, rig_b, "AC1-dense"),
		"AC1[dense+edge]: dense cluster + edge/corner kernels bit-identical")

	var d: float = rig_a["congestion"].call("per_cell_density", Vector2i(5, 4))
	_check(d == 1.0, "AC1[dense]: pile cell clamped to exactly 1.0 (got %s)" % str(d))


func _test_ac1_equipment_removal_mid_run() -> void:
	print("\n[AC1 edge] equipment removal mid-run (grid_changed on both) -> access_reachable + scalars bit-identical")
	var equipment: Array = [
		{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)},
		{"id": 2, "fp": Vector2i(5, 2), "ac": Vector2i(6, 2)},
	]
	var gs_a := _make_grid(equipment)
	var gs_b := _make_grid(equipment)
	var ms_a := _make_member_sim()
	var ms_b := _make_member_sim()
	var nav_a := _make_real_navigation(gs_a)
	var nav_b := _make_real_navigation(gs_b)
	var rig_a := _make_congestion(gs_a, ms_a, nav_a)
	var rig_b := _make_congestion(gs_b, ms_b, nav_b)

	# Ticks 0-3 with both equipment present.
	for t in range(4):
		var members: Array = [_member(10 + t, "USING", Vector2i(3, 2)), _member(20 + t, "WALKING_TO", Vector2i(6, 2))]
		_apply_state(rig_a, rig_b, members, {1: {"occupant": 10 + t}, 2: {"next_claimant": 20 + t}})
		rig_a["congestion"].call("on_tick", t)
		rig_b["congestion"].call("on_tick", t)

	# Remove equipment 2 mid-run — grid_changed fires on BOTH grids; the
	# pending batch flushes at the start of the NEXT tick.
	_clear(gs_a, 2)
	_clear(gs_b, 2)

	for t in range(4, 8):
		var members: Array = [_member(10 + t, "USING", Vector2i(3, 2))]
		_apply_state(rig_a, rig_b, members, {1: {"occupant": 10 + t}})
		rig_a["congestion"].call("on_tick", t)
		rig_b["congestion"].call("on_tick", t)

	_check(_outputs_bit_identical(rig_a, rig_b, "AC1-removal"),
		"AC1[removal]: dual-run bit-identical after equipment 2 removed mid-run")

	# Removal same-tick semantics (Core Rule 6 / AC9): id 2 entries dropped.
	var ca: RefCounted = rig_a["congestion"]
	_check(not (ca.get("prev") as Dictionary).has(2), "AC1[removal]: prev entry for removed id 2 dropped")
	_check(not (ca.get("access_reachable") as Dictionary).has(2), "AC1[removal]: access_reachable entry for removed id 2 dropped")
	# Id 1 still live and non-trivial.
	var v: float = ca.call("per_equipment_congestion", 1)
	_check(v > 0.0, "AC1[removal]: surviving equipment 1 still has a non-zero scalar (got %s)" % str(v))


func _clear(gs: RefCounted, id: int) -> void:
	gs.call("clear", id)


# === S8: congestion_updated once per tick ===

func _test_s8_emitted_once_per_tick() -> void:
	print("\n[S8] congestion_updated emitted EXACTLY once per tick after recompute (count across 5 ticks == 5)")
	var equipment: Array = [{"id": 1, "fp": Vector2i(2, 2), "ac": Vector2i(3, 2)}]
	var gs := _make_grid(equipment)
	var ms := _make_member_sim()
	var nav := _make_real_navigation(gs)
	var rig := _make_congestion(gs, ms, nav)
	var cong: RefCounted = rig["congestion"]

	var emits: Array = []
	cong.connect("congestion_updated", func() -> void: emits.append("ping"))

	ms.set("members", [_member(10, "USING", Vector2i(3, 2))])
	ms.set("reservations", {1: {"occupant": 10}})
	for t in range(5):
		cong.call("on_tick", t)
	_check(emits.size() == 5, "S8: exactly 5 emissions for 5 ticks (got %d)" % emits.size())

	# A signal with arity 0 (no payload) — verified by emitting with a
	# zero-arg connection above; also expose the signal's argument count.
	var args: Array = cong.get_signal_list().filter(func(s): return s["name"] == "congestion_updated")
	_check(not args.is_empty() and int(args[0]["args"].size()) == 0,
		"S8: congestion_updated has arity 0 (no payload)")


# === AC2: static no RNG ===

func _test_ac2_static_zero_rng_calls() -> void:
	print("\n[AC2] static grep: congestion.gd has zero randi/randf/RandomNumberGenerator calls and no randomize()")
	var cong_path := "res://src/systems/congestion.gd"
	_check(FileAccess.file_exists(cong_path), "AC2: congestion.gd exists")

	var f := FileAccess.open(cong_path, FileAccess.READ)
	if f == null:
		_check(false, "AC2: cannot open congestion.gd")
		return
	var source: String = f.get_as_text()
	f.close()

	# Precise call probes. The header DOC deliberately mentions the words
	# "randi/randf" (it documents the zero-call guarantee), so a bare
	# substring search would false-positive. Probe for actual CALL patterns:
	#   randi( / randf( / randf_range( / randi_range(  — global calls
	#   RandomNumberGenerator                              — the class type
	#   randomize(                                         — seeding call
	var lower := source.to_lower()
	var calls_randi := lower.contains("randi(")
	var calls_randf := lower.contains("randf(")
	var rng_type := lower.contains("randomnumbergenerator")
	var randomize_call := lower.contains("randomize(")

	_check(not calls_randi, "AC2: zero randi( calls")
	_check(not calls_randf, "AC2: zero randf( calls")
	_check(not rng_type, "AC2: zero RandomNumberGenerator type references")
	_check(not randomize_call, "AC2: zero randomize() calls")
