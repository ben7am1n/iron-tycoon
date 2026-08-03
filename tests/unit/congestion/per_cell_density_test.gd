# tests/unit/congestion/per_cell_density_test.gd
# Story CG-002: Per-Cell Density Field
# (production/epics/congestion/story-002-per-cell-density-field.md)
#
# BLOCKING ACs covered (TR-CONG-004):
#   AC4  arbitrary member distributions (zero members, dense clusters, edge
#        members) -> every cell value is a finite float in [0,1]
#   AC15 single member on cell C -> C gets kernel weight 1, in-bounds
#        4-neighbors get w_n, out-of-bounds dropped, post-clamp values in
#        [0,1] (corner 2 neighbors / edge 3 / interior 4)
#
# Plus (story contract surface):
#   - Core Rule 4 formulas: raw = Sigma kernel; smoothed = beta*raw +
#     (1-beta)*smoothed_prev; density = clamp(smoothed / D_cell_max)
#   - GDD edge case: zero members -> EMA decays toward 0, not an instant snap
#   - fixed float-summation order: members ascending member_id, cells
#     ascending flat index (bit-identical run-to-run)
#   - S8 congestion_updated emitted once per tick AFTER the per-cell
#     recompute completes (the signal handler reads the fresh field)
#   - data-driven knobs: beta / w_n / D_cell_max via init config
#
# Run standalone: godot --headless --script tests/unit/congestion/per_cell_density_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const GRID_W := 10
const GRID_H := 8
const R0 := 0
const EPS := 1e-9

var _pass := 0
var _fail := 0


func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	var result := run_all()
	quit(1 if int(result["fail"]) > 0 else 0)


func run_all() -> Dictionary:
	print("=".repeat(48))
	print("  UNIT TEST: Congestion — Per-Cell Density Field (Story CG-002)")
	print("=".repeat(48))

	_test_ac4_zero_members_all_zero()
	_test_ac4_dense_cluster_clamped()
	_test_ac4_arbitrary_distributions_finite()
	_test_ac15_interior_kernel()
	_test_ac15_corner_kernel()
	_test_ac15_edge_kernel()
	_test_ac15_post_clamp_range()
	_test_ema_decay_not_snap()
	_test_determinism_ascending_member_order()
	_test_s8_recompute_before_emit()
	_test_config_knobs()

	print("\n=== PER-CELL DENSITY TEST: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


func _check_float(actual: float, expected: float, msg: String) -> void:
	if absf(actual - expected) < EPS:
		_pass += 1
		print("  PASS: %s (got %s)" % [msg, str(actual)])
	else:
		_fail += 1
		print("  FAIL: %s (got %s, expected %s)" % [msg, str(actual), str(expected)])


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


## Real GridSystem: GRID_W x GRID_H all buildable, frozen, with the given
## equipment committed (may be empty — the per-cell field only needs dims).
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


## Real MemberSim instance — NOT init'd; the test injects members directly
## through the public var (same data shape Congestion consumes).
func _make_member_sim() -> RefCounted:
	return _MS().new()


## Real Congestion, configured with the real grid + member_sim + config.
func _make_congestion(gs: RefCounted, ms: RefCounted, config: Dictionary = {}) -> Dictionary:
	var srg: RefCounted = _SRG().new()
	srg.call("init", 0xCAFE002)
	var orch := _make_orchestrator()
	var cong: RefCounted = (load("res://src/systems/congestion.gd") as Script).new()
	cong.call("init", orch, srg, gs, ms, config)
	return {"congestion": cong, "seeded_rng": srg, "orchestrator": orch}


func _member(member_id: int, state: String, cell: Vector2i) -> Dictionary:
	return {"member_id": member_id, "state": state, "cell": cell}


## Flat row-major index — MUST match GridSystem.flat_index / Congestion.
func _fi(cell: Vector2i) -> int:
	return cell.y * GRID_W + cell.x


# === AC4: zero members ===

func _test_ac4_zero_members_all_zero() -> void:
	print("\n[AC4] zero members -> every cell finite float in [0,1], all 0.0")
	var gs := _make_grid([])
	var ms := _make_member_sim()
	ms.set("members", [])
	var rig := _make_congestion(gs, ms)
	var cong: RefCounted = rig["congestion"]

	cong.call("on_tick", 0)
	var all_zero := true
	var all_finite := true
	for y in GRID_H:
		for x in GRID_W:
			var v: float = cong.call("per_cell_density", Vector2i(x, y))
			if not is_finite(v):
				all_finite = false
			if v != 0.0:
				all_zero = false
			if v < 0.0 or v > 1.0:
				all_finite = false
	_check(all_finite, "AC4: zero members — every cell finite float in [0,1]")
	_check(all_zero, "AC4: zero members — every cell exactly 0.0")

	# Dense field is also readable via the exposed dict (same size as grid).
	var density_size: int = (cong.get("density_cells") as Dictionary).size()
	_check(density_size == GRID_W * GRID_H,
		"AC4: density_cells covers all %d cells (got %d)" % [GRID_W * GRID_H, density_size])


# === AC4: dense cluster ===

func _test_ac4_dense_cluster_clamped() -> void:
	print("\n[AC4] dense cluster -> clamped to 1.0 at the pile, all cells in [0,1]")
	var gs := _make_grid([])
	var ms := _make_member_sim()
	# 8 members stacked on one interior cell: raw = 8.0 -> smoothed = 0.4*8
	# = 3.2 -> density = 3.2/3 > 1 -> clamped to 1.0.
	var members: Array = []
	for i in 8:
		members.append(_member(100 + i, "WALKING_TO", Vector2i(5, 4)))
	ms.set("members", members)
	var rig := _make_congestion(gs, ms)
	var cong: RefCounted = rig["congestion"]

	cong.call("on_tick", 0)
	_check_float(cong.call("per_cell_density", Vector2i(5, 4)), 1.0,
		"AC4: dense pile cell clamped to exactly 1.0")
	_check((cong.get("smoothed_cells") as Dictionary).get(_fi(Vector2i(5, 4))) > 3.0,
		"AC4: smoothed at pile exceeds D_cell_max (3.0) — clamp is active")

	# Neighbors of the pile also receive w_n splats from 8 members: raw = 2.0,
	# smoothed = 0.8 -> density = 0.8/3 ~ 0.2667 — still in [0,1].
	var nv: float = cong.call("per_cell_density", Vector2i(6, 4))
	_check_float(nv, 0.8 / 3.0, "AC4: neighbor of dense pile in [0,1] (%s)" % str(nv))

	# Sweep: every cell finite in [0,1].
	var all_ok := true
	for y in GRID_H:
		for x in GRID_W:
			var v: float = cong.call("per_cell_density", Vector2i(x, y))
			if not is_finite(v) or v < 0.0 or v > 1.0:
				all_ok = false
	_check(all_ok, "AC4: dense cluster — every cell finite float in [0,1]")


# === AC4: arbitrary distributions sweep ===

func _test_ac4_arbitrary_distributions_finite() -> void:
	print("\n[AC4] arbitrary distributions (edge members, corners, clusters) — all finite [0,1]")
	var distributions: Array = [
		# members only on edges/corners
		[Vector2i(0, 0), Vector2i(9, 0), Vector2i(0, 7), Vector2i(9, 7)],
		# a horizontal line of members
		[Vector2i(2, 3), Vector2i(3, 3), Vector2i(4, 3), Vector2i(5, 3)],
		# dense cluster + isolated member far away
		[Vector2i(1, 1), Vector2i(1, 2), Vector2i(2, 1), Vector2i(2, 2), Vector2i(8, 6)],
	]
	for dist_idx in distributions.size():
		var gs := _make_grid([])
		var ms := _make_member_sim()
		var members: Array = []
		for i in (distributions[dist_idx] as Array).size():
			members.append(_member(1000 + i, "WALKING_TO", distributions[dist_idx][i]))
		ms.set("members", members)
		var rig := _make_congestion(gs, ms)
		var cong: RefCounted = rig["congestion"]
		cong.call("on_tick", 0)

		var all_ok := true
		var max_v := 0.0
		var min_v := 1.0
		for y in GRID_H:
			for x in GRID_W:
				var v: float = cong.call("per_cell_density", Vector2i(x, y))
				if not is_finite(v) or v < 0.0 or v > 1.0:
					all_ok = false
				max_v = maxf(max_v, v)
				min_v = minf(min_v, v)
		_check(all_ok,
			"AC4: distribution %d — every cell finite float in [0,1] (min %s, max %s)"
			% [dist_idx, str(min_v), str(max_v)])


# === AC15: interior kernel ===

func _test_ac15_interior_kernel() -> void:
	print("\n[AC15] single member interior -> self 1.0, 4 in-bounds neighbors w_n")
	var gs := _make_grid([])
	var ms := _make_member_sim()
	ms.set("members", [_member(7, "USING", Vector2i(3, 3))])
	var rig := _make_congestion(gs, ms)
	var cong: RefCounted = rig["congestion"]

	cong.call("on_tick", 0)
	var raw: Dictionary = cong.get("raw_cells")

	# C gets kernel weight 1.
	_check_float(raw.get(_fi(Vector2i(3, 3)), 0.0), 1.0, "AC15: interior cell raw == 1.0")
	# In-bounds 4-neighbors get w_n (0.25).
	for dir in [Vector2i.LEFT, Vector2i.RIGHT, Vector2i.UP, Vector2i.DOWN]:
		var neighbor: Vector2i = Vector2i(3, 3) + dir
		_check_float(raw.get(_fi(neighbor), 0.0), 0.25,
			"AC15: interior neighbor %s raw == w_n" % str(neighbor))
	# Non-neighbor cells get nothing (absent == 0.0).
	_check(raw.get(_fi(Vector2i(5, 5)), -1.0) == -1.0,
		"AC15: far cell has no raw entry")

	# Post-EMA + clamp: smoothed(C) = 0.4*1 = 0.4 -> density 0.4/3.
	var d_c: float = cong.call("per_cell_density", Vector2i(3, 3))
	_check_float(d_c, 0.4 / 3.0, "AC15: interior density = beta*1 / D_cell_max")
	# Neighbor: smoothed = 0.4*0.25 = 0.1 -> density 0.1/3.
	var d_n: float = cong.call("per_cell_density", Vector2i(2, 3))
	_check_float(d_n, 0.1 / 3.0, "AC15: neighbor density = beta*w_n / D_cell_max")


# === AC15: corner kernel ===

func _test_ac15_corner_kernel() -> void:
	print("\n[AC15] single member at grid corner -> only 2 in-bounds neighbors get w_n")
	var gs := _make_grid([])
	var ms := _make_member_sim()
	ms.set("members", [_member(7, "USING", Vector2i(0, 0))])
	var rig := _make_congestion(gs, ms)
	var cong: RefCounted = rig["congestion"]

	cong.call("on_tick", 0)
	var raw: Dictionary = cong.get("raw_cells")

	_check_float(raw.get(_fi(Vector2i(0, 0)), 0.0), 1.0, "AC15: corner cell raw == 1.0")
	# Only (1,0) and (0,1) are in-bounds; (-1,0) and (0,-1) dropped.
	_check_float(raw.get(_fi(Vector2i(1, 0)), 0.0), 0.25, "AC15: corner neighbor (1,0) raw == w_n")
	_check_float(raw.get(_fi(Vector2i(0, 1)), 0.0), 0.25, "AC15: corner neighbor (0,1) raw == w_n")
	_check(raw.get(_fi(Vector2i(0, 0)) - 1, -1.0) == -1.0
		and raw.get(-1, -1.0) == -1.0,
		"AC15: out-of-bounds neighbors dropped (no negative flat keys)")
	# Only 3 entries total: self + 2 in-bounds neighbors.
	_check(raw.size() == 3, "AC15: corner splat has exactly 3 raw entries (got %d)" % raw.size())


# === AC15: edge kernel ===

func _test_ac15_edge_kernel() -> void:
	print("\n[AC15] single member on grid edge (non-corner) -> 3 in-bounds neighbors get w_n")
	var gs := _make_grid([])
	var ms := _make_member_sim()
	ms.set("members", [_member(7, "USING", Vector2i(0, 3))])
	var rig := _make_congestion(gs, ms)
	var cong: RefCounted = rig["congestion"]

	cong.call("on_tick", 0)
	var raw: Dictionary = cong.get("raw_cells")

	_check_float(raw.get(_fi(Vector2i(0, 3)), 0.0), 1.0, "AC15: edge cell raw == 1.0")
	# In-bounds: (1,3), (0,2), (0,4). Out-of-bounds: (-1,3).
	_check_float(raw.get(_fi(Vector2i(1, 3)), 0.0), 0.25, "AC15: edge neighbor (1,3) raw == w_n")
	_check_float(raw.get(_fi(Vector2i(0, 2)), 0.0), 0.25, "AC15: edge neighbor (0,2) raw == w_n")
	_check_float(raw.get(_fi(Vector2i(0, 4)), 0.0), 0.25, "AC15: edge neighbor (0,4) raw == w_n")
	_check(raw.size() == 4, "AC15: edge splat has exactly 4 raw entries (got %d)" % raw.size())


# === AC15: post-clamp range ===

func _test_ac15_post_clamp_range() -> void:
	print("\n[AC15] post-clamp values stay in [0,1] for all placements")
	for cell in [Vector2i(3, 3), Vector2i(0, 0), Vector2i(0, 3), Vector2i(9, 7), Vector2i(4, 0)]:
		var gs := _make_grid([])
		var ms := _make_member_sim()
		ms.set("members", [_member(1, "USING", cell)])
		var rig := _make_congestion(gs, ms)
		var cong: RefCounted = rig["congestion"]
		cong.call("on_tick", 0)

		var all_ok := true
		for y in GRID_H:
			for x in GRID_W:
				var v: float = cong.call("per_cell_density", Vector2i(x, y))
				if not is_finite(v) or v < 0.0 or v > 1.0:
					all_ok = false
		_check(all_ok, "AC15: single member at %s — post-clamp all cells in [0,1]" % str(cell))


# === EMA decay (GDD edge case) ===

func _test_ema_decay_not_snap() -> void:
	print("\n[EDGE] zero members after a populated tick -> EMA decays, not instant snap")
	var gs := _make_grid([])
	var ms := _make_member_sim()
	ms.set("members", [_member(7, "USING", Vector2i(3, 3))])
	var rig := _make_congestion(gs, ms)
	var cong: RefCounted = rig["congestion"]

	cong.call("on_tick", 0)
	var d0: float = cong.call("per_cell_density", Vector2i(3, 3))
	_check_float(d0, 0.4 / 3.0, "EDGE: populated tick density (0.4/3)")

	# Member leaves: raw = 0 everywhere next tick -> smoothed *= (1-beta).
	ms.set("members", [])
	cong.call("on_tick", 1)
	var d1: float = cong.call("per_cell_density", Vector2i(3, 3))
	_check_float(d1, (0.6 * 0.4) / 3.0, "EDGE: one empty tick decays by (1-beta) = 0.6")
	_check(d1 > 0.0 and d1 < d0, "EDGE: decays but never snaps to 0 instantly (%s -> %s)" % [str(d0), str(d1)])

	# Sustained empty ticks decay exponentially toward 0.
	var prev := d1
	for t in range(2, 8):
		cong.call("on_tick", t)
		var dv: float = cong.call("per_cell_density", Vector2i(3, 3))
		_check(dv < prev, "EDGE: tick %d decays further (%s < %s)" % [t, str(dv), str(prev)])
		prev = dv


# === Determinism / fixed order ===

func _test_determinism_ascending_member_order() -> void:
	print("\n[ORDER] members splat ascending member_id; two instances bit-identical")
	var gs := _make_grid([])

	# Same member SET, injected in OPPOSITE array order: ascending [1,2,3]
	# vs descending [3,2,1]. The splat must sort by member_id, so both
	# instances produce bit-identical fields.
	var ms_a := _make_member_sim()
	ms_a.set("members", [
		_member(1, "WALKING_TO", Vector2i(4, 4)),
		_member(2, "USING", Vector2i(4, 3)),
		_member(3, "QUEUEING", Vector2i(5, 4)),
	])
	var ms_b := _make_member_sim()
	ms_b.set("members", [
		_member(3, "QUEUEING", Vector2i(5, 4)),
		_member(2, "USING", Vector2i(4, 3)),
		_member(1, "WALKING_TO", Vector2i(4, 4)),
	])
	var rig_a := _make_congestion(gs, ms_a)
	var rig_b := _make_congestion(gs, ms_b)
	var cong_a: RefCounted = rig_a["congestion"]
	var cong_b: RefCounted = rig_b["congestion"]

	for t in range(4):
		cong_a.call("on_tick", t)
		cong_b.call("on_tick", t)

	var identical := true
	var da: Dictionary = cong_a.get("density_cells")
	var db: Dictionary = cong_b.get("density_cells")
	for y in GRID_H:
		for x in GRID_W:
			if absf(float(da.get(_fi(Vector2i(x, y)), 0.0)) - float(db.get(_fi(Vector2i(x, y)), 0.0))) > 0.0:
				identical = false
	_check(identical, "ORDER: bit-identical density_cells despite reversed member array order")
	_check((cong_a.get("density_cells") as Dictionary).size()
		== (cong_b.get("density_cells") as Dictionary).size(),
		"ORDER: identical field sizes")


# === S8 ordering ===

func _test_s8_recompute_before_emit() -> void:
	print("\n[S8] congestion_updated fires AFTER the per-cell recompute — handler reads the fresh field")
	var gs := _make_grid([])
	var ms := _make_member_sim()
	ms.set("members", [_member(7, "USING", Vector2i(3, 3))])
	var rig := _make_congestion(gs, ms)
	var cong: RefCounted = rig["congestion"]

	var observed: Array = []
	cong.connect("congestion_updated", func() -> void:
		# At emit time the current tick's field must already be visible.
		observed.append(cong.call("per_cell_density", Vector2i(3, 3))))

	cong.call("on_tick", 0)
	_check(observed.size() == 1, "S8: emitted exactly once per tick (got %d)" % observed.size())
	_check(observed.size() == 1 and absf(float(observed[0]) - 0.4 / 3.0) < EPS,
		"S8: handler sees the fresh density (0.4/3) at emit time (got %s)"
		% (str(observed[0]) if observed.size() > 0 else "none"))

	# Second tick with same member: EMA blends (raw stays 1.0).
	cong.call("on_tick", 1)
	_check(observed.size() == 2, "S8: second tick emitted once more (got %d)" % observed.size())
	var expected2: float = (0.4 * 1.0 + 0.6 * 0.4) / 3.0
	_check(observed.size() == 2 and absf(float(observed[1]) - expected2) < EPS,
		"S8: second emit sees blended value (%s)" % str(observed[1]))


# === Config knobs ===

func _test_config_knobs() -> void:
	print("\n[CONFIG] beta / w_n / D_cell_max are data-driven via init config")
	var gs := _make_grid([])
	var ms := _make_member_sim()
	ms.set("members", [_member(7, "USING", Vector2i(3, 3))])
	var rig := _make_congestion(gs, ms, {"beta": 0.5, "w_n": 0.5, "D_cell_max": 2.0})
	var cong: RefCounted = rig["congestion"]

	cong.call("on_tick", 0)
	var raw: Dictionary = cong.get("raw_cells")
	_check_float(raw.get(_fi(Vector2i(3, 3)), 0.0), 1.0, "CONFIG: self raw unchanged (1.0)")
	_check_float(raw.get(_fi(Vector2i(2, 3)), 0.0), 0.5, "CONFIG: w_n=0.5 applied to neighbor")

	var d_c: float = cong.call("per_cell_density", Vector2i(3, 3))
	_check_float(d_c, 0.5 / 2.0, "CONFIG: beta=0.5, D_cell_max=2 -> density 0.25")
	var d_n: float = cong.call("per_cell_density", Vector2i(2, 3))
	_check_float(d_n, 0.5 * 0.5 / 2.0, "CONFIG: neighbor density 0.125")

	# Out-of-bounds query reads 0.0.
	_check_float(cong.call("per_cell_density", Vector2i(-1, 0)), 0.0,
		"CONFIG: out-of-bounds cell reads 0.0")
	_check_float(cong.call("per_cell_density", Vector2i(GRID_W, 0)), 0.0,
		"CONFIG: x == GRID_W reads 0.0")
