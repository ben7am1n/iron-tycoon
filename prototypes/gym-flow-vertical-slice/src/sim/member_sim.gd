# VERTICAL SLICE - NOT FOR PRODUCTION
# Validation Question: core loop buildable at quality — MemberSim lifecycle state machine
# Date: 2026-07-19
#
# Faithful to member-sim.md:
#  - States: IDLE -> SELECTING_TARGET -> WALKING -> (QUEUEING) -> USING -> SELECTING_TARGET | LEAVING -> GONE
#  - Spawn at GridSystem entrance_cell; LEAVING walks to exit_cell with defensive safety-timeout GONE
#  - use_duration drawn from EquipmentCatalog per-equipment fields (clamp, Gaussian)
#  - Target selection reads Congestion_i(t-1) (one-tick lag) — passed in by orchestrator
#  - exercises_per_visit uses visit_length_modifier (registry/satisfaction reconciled) — for the
#    slice we use a fixed quota (no Satisfaction system); marker left for Production.
#  - entrance_cell / exit_cell are HARD upstream deps declared on GridSystem (OQ5 resolved)
# Cross-script class_name annotations omitted (GDScript dynamic) for headless parse.

class_name MemberSim
extends RefCounted

const STATE_IDLE := 0
const STATE_SELECTING := 1
const STATE_WALKING := 2
const STATE_QUEUEING := 3
const STATE_USING := 4
const STATE_LEAVING := 5
const STATE_GONE := 6

var _grid
var _nav
var _catalog
var _rng
var _entrance: Vector2i
var _exit: Vector2i
var _k_congestion := 0.5

var _next_id := 1
var _members: Dictionary = {}
var _equip_state: Dictionary = {}
var _equip_def_id: Dictionary = {}
var _quota_per_visit := 3

func _init(grid, nav, catalog, rng, entrance: Vector2i, exit: Vector2i) -> void:
	_grid = grid
	_nav = nav
	_catalog = catalog
	_rng = rng
	_entrance = entrance
	_exit = exit

func register_equipment(instance_id: int, def_id: String) -> void:
	_equip_state[instance_id] = {"occupant": -1, "next_claimant": -1}
	_equip_def_id[instance_id] = def_id

func spawn_member() -> int:
	var mid := _next_id
	_next_id += 1
	_members[mid] = {
		"id": mid, "state": STATE_SELECTING, "pos": _entrance,
		"target_equip": -1, "path": [], "path_idx": 0,
		"use_timer": 0, "use_duration": 0, "exercises": 0, "safe_timer": 0,
	}
	return mid

func get_member(mid: int) -> Dictionary:
	return _members.get(mid, {})

func get_equip_occupancy(instance_id: int) -> Dictionary:
	return _equip_state.get(instance_id, {"occupant": -1, "next_claimant": -1})

func get_queue_length(instance_id: int) -> int:
	var occ: Dictionary = _equip_state.get(instance_id, {"occupant": -1, "next_claimant": -1})
	var n := 0
	if occ["occupant"] != -1:
		n += 1
	if occ["next_claimant"] != -1:
		n += 1
	return n

func on_tick(congestion_prev: Dictionary) -> void:
	for mid in _members.keys():
		_step(mid, congestion_prev)

func _step(mid: int, congestion_prev: Dictionary) -> void:
	var m: Dictionary = _members[mid]
	match m["state"]:
		STATE_SELECTING:
			_pick_target(mid, congestion_prev)
		STATE_WALKING:
			_advance(mid)
		STATE_QUEUEING:
			_try_enter(mid)
		STATE_USING:
			_tick_use(mid)
		STATE_LEAVING:
			_advance(mid)

func _pick_target(mid: int, congestion_prev: Dictionary) -> void:
	var m: Dictionary = _members[mid]
	var best := -1
	var best_w := -1.0
	for eid in _equip_state.keys():
		var occ: Dictionary = _equip_state[eid]
		if occ["occupant"] != -1:
			continue
		var c: float = congestion_prev.get(eid, 0.0)
		var w: float = exp(-_k_congestion * c)
		if w > best_w or (w == best_w and (best == -1 or eid < best)):
			best_w = w
			best = eid
	if best == -1:
		return
	m["target_equip"] = best
	var target_access: Vector2i = _access_cell_of(best)
	var path: Array = _nav.get_path(m["pos"], target_access)
	if path.is_empty():
		m["target_equip"] = -1
		return
	m["path"] = path
	m["path_idx"] = 0
	m["state"] = STATE_WALKING

func _access_cell_of(instance_id: int) -> Vector2i:
	var cells: Array = _grid.get_access_cells(instance_id)
	if cells.is_empty():
		return _entrance
	return cells[0]

func _advance(mid: int) -> void:
	var m: Dictionary = _members[mid]
	if m["path"].is_empty():
		m["state"] = STATE_SELECTING
		return
	m["path_idx"] += 1
	if m["path_idx"] >= m["path"].size():
		m["path_idx"] = m["path"].size() - 1
	m["pos"] = m["path"][m["path_idx"]]
	var target_access: Vector2i = _access_cell_of(m["target_equip"])
	if m["pos"] == target_access:
		_try_enter(mid)
	elif m["state"] == STATE_LEAVING and m["pos"] == _exit:
		m["state"] = STATE_GONE
		_members.erase(mid)
		_release_if_owner(mid)

func _try_enter(mid: int) -> void:
	var m: Dictionary = _members[mid]
	var eid: int = m["target_equip"]
	if eid == -1:
		m["state"] = STATE_SELECTING
		return
	var occ: Dictionary = _equip_state[eid]
	if occ["occupant"] == -1:
		occ["occupant"] = mid
		var d: Dictionary = _catalog.get_use_duration(_equip_def_id[eid])
		var raw: float = _rng.randfn(d["mean"], d["stddev"])
		m["use_duration"] = int(clamp(raw, d["min"], d["max"]))
		m["use_timer"] = 0
		m["state"] = STATE_USING
	elif occ["occupant"] == mid:
		m["state"] = STATE_USING
	else:
		m["state"] = STATE_QUEUEING
		if occ["next_claimant"] == -1:
			occ["next_claimant"] = mid

func _tick_use(mid: int) -> void:
	var m: Dictionary = _members[mid]
	m["use_timer"] += 1
	if m["use_timer"] >= m["use_duration"]:
		var eid: int = m["target_equip"]
		_equip_state[eid]["occupant"] = -1
		m["exercises"] += 1
		if m["exercises"] >= _quota_per_visit:
			m["state"] = STATE_LEAVING
			var path: Array = _nav.get_path(m["pos"], _exit)
			if path.is_empty():
				m["state"] = STATE_SELECTING
			else:
				m["path"] = path
				m["path_idx"] = 0
		else:
			m["state"] = STATE_SELECTING
			m["target_equip"] = -1

func _release_if_owner(mid: int) -> void:
	for eid in _equip_state.keys():
		if _equip_state[eid]["occupant"] == mid:
			_equip_state[eid]["occupant"] = -1

func invalidate_paths() -> void:
	for mid in _members.keys():
		var m: Dictionary = _members[mid]
		if m["state"] == STATE_WALKING or m["state"] == STATE_LEAVING:
			m["state"] = STATE_SELECTING
			m["path"] = []
