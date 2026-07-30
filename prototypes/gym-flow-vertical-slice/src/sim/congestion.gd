# VERTICAL SLICE - NOT FOR PRODUCTION
# Validation Question: core loop buildable at quality — Congestion (dynamic member density)
# Date: 2026-07-19
#
# Faithful to congestion.md:
#  - Per-equipment instance congestion scalar in [0,1], EMA-smoothed (alpha=0.3 default).
#    MemberSim reads it at ONE-TICK LAG as Congestion_i(t-1) in target selection.
#  - Per-cell density field in [0,1] for the overlay heatmap, EMA-smoothed (beta=0.4).
#    Summation order FIXED (ascending cell index) for bit-identical determinism.
#  - access_reachable: event-driven, recomputed ONLY on grid_changed (not per-tick),
#    via Navigation.get_path(entrance_cell, access_cell). Cached otherwise.
#  - Determinism: pure function of member state -> bit-identical run-to-run.
# Cross-script class_name annotations omitted (GDScript dynamic) for headless parse.

class_name Congestion
extends RefCounted

const ALPHA := 0.3
const W_OCC := 0.7
const W_DENSE := 0.3
const D_MAX := 4
const BETA := 0.4
const W_N := 0.5
const D_CELL_MAX := 4

var _nav
var _entrance: Vector2i
var _region: Rect2i

var _prev: Dictionary = {}
var _smoothed: Dictionary = {}
var _access_reachable: Dictionary = {}
var _access_mirror: Dictionary = {}

func _init(nav, entrance: Vector2i, region: Rect2i) -> void:
	_nav = nav
	_entrance = entrance
	_region = region

func register_equipment(instance_id: int, access_cell: Vector2i) -> void:
	_prev[instance_id] = 0.0
	_access_reachable[instance_id] = _nav.get_path(_entrance, access_cell) != []

func set_access_mirror(m: Dictionary) -> void:
	_access_mirror = m

func on_tick(members: Dictionary, equip_state: Dictionary) -> void:
	for eid in equip_state.keys():
		var occ: Dictionary = equip_state[eid]
		var occ_state: int = 0
		if occ["occupant"] != -1:
			occ_state = 2
		elif occ["next_claimant"] != -1:
			occ_state = 1
		var n_i := _count_neighbors(members, _access_cell_of(eid))
		var raw: float = W_OCC * (float(occ_state) / 2.0) + W_DENSE * clamp(float(n_i) / float(D_MAX), 0.0, 1.0)
		raw = clamp(raw, 0.0, 1.0)
		var prev_v: float = _prev.get(eid, 0.0)
		_prev[eid] = clamp(ALPHA * raw + (1.0 - ALPHA) * prev_v, 0.0, 1.0)
	_update_density(members)

func _access_cell_of(instance_id: int) -> Vector2i:
	return _access_mirror.get(instance_id, _entrance)

func _count_neighbors(members: Dictionary, cell: Vector2i) -> int:
	var n := 0
	for mid in members.keys():
		var mp: Vector2i = members[mid]["pos"]
		var d: int = abs(mp.x - cell.x) + abs(mp.y - cell.y)
		if d <= 2 and d > 0:
			n += 1
	return n

func _update_density(members: Dictionary) -> void:
	var member_cells := []
	for mid in members.keys():
		member_cells.append(members[mid]["pos"])
	member_cells.sort()
	var new_smoothed: Dictionary = {}
	for x in range(_region.position.x, _region.end.x):
		for y in range(_region.position.y, _region.end.y):
			var c := Vector2i(x, y)
			var instant := 0.0
			if c in member_cells:
				instant += 1.0
			for d: Vector2i in [Vector2i(1,0), Vector2i(-1,0), Vector2i(0,1), Vector2i(0,-1)]:
				var nb: Vector2i = c + d
				if _region.has_point(nb) and nb in member_cells:
					instant += W_N
			instant /= float(D_CELL_MAX)
			var prev_v: float = _smoothed.get(c, 0.0)
			new_smoothed[c] = clamp(BETA * instant + (1.0 - BETA) * prev_v, 0.0, 1.0)
	_smoothed = new_smoothed

func recompute_access(affected_equipment: Array) -> void:
	for eid in affected_equipment:
		var ac: Vector2i = _access_mirror.get(eid, _entrance)
		_access_reachable[eid] = _nav.get_path(_entrance, ac) != []

func get_congestion(instance_id: int) -> float:
	return _prev.get(instance_id, 0.0)

func get_density(cell: Vector2i) -> float:
	return _smoothed.get(cell, 0.0)

func is_access_reachable(instance_id: int) -> bool:
	return _access_reachable.get(instance_id, true)
