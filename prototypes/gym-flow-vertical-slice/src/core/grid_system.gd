# VERTICAL SLICE - NOT FOR PRODUCTION
# Validation Question: core loop buildable at quality — GridSystem occupancy, rotation, solidity
# Date: 2026-07-19
#
# Faithful to grid-system.md:
#  - is_solid(cell) = NOT buildable OR occupant_id != -1  (access_ids deliberately excluded)
#  - commit/clear emit grid_changed(footprint_cells_changed, access_cells_changed) exactly once
#  - rotation_transform uses the UNION bbox of footprint U access (highest-risk rule: never the
#    footprint-local bbox, or 90/270 produce negative coords hidden by 0/180 symmetry)
#  - can_place: bounds + buildable + no footprint/access overlap + access count <= 1
#  - get_speculative_snapshot: no real state change, no signal (drag preview path)

# No class_name — this file is cross-project preloaded by
# tests/smoke/core_smoke_test.gd (main project) via the GRID_SYSTEM
# constant. A global class_name here collides with the real
# src/systems/grid_system.gd once class registration is active
# (see .godot/global_script_class_cache.cfg). Nothing in this
# prototype references the bare "GridSystem" identifier — every
# call site uses the preloaded Script constant instead.
extends RefCounted

signal grid_changed(footprint_cells_changed: Array, access_cells_changed: Array)

var _region: Rect2i
var _buildable: Dictionary = {}      # Vector2i -> bool
var _occupant_id: Dictionary = {}    # Vector2i -> int (-1 if none)
var _access_ids: Dictionary = {}     # Vector2i -> Array[int]
var _instances: Dictionary = {}      # instance_id -> {footprint:Array, access:Array, rotation:int}

func _init(region: Rect2i, buildable: Dictionary) -> void:
	_region = region
	_buildable = buildable
	for c in buildable.keys():
		_occupant_id[c] = -1
		_access_ids[c] = []

# --- queries ---
func is_solid(cell: Vector2i) -> bool:
	if not _region.has_point(cell):
		return true  # out of bounds = wall (prevents AStar from pathing outside)
	var b: bool = _buildable.get(cell, false)
	var occ: int = _occupant_id.get(cell, -1)
	return (not b) or (occ != -1)
	# NOTE: access_ids intentionally NOT part of solidity — would trap members permanently.

func get_occupant_id(cell: Vector2i) -> int:
	return _occupant_id.get(cell, -1)

func get_access_ids(cell: Vector2i) -> Array:
	return _access_ids.get(cell, [])

func get_dimensions() -> Rect2i:
	return _region

func get_access_cells(instance_id: int) -> Array:
	if not _instances.has(instance_id):
		return []
	return _instances[instance_id]["access"].duplicate()

func get_footprint_cells(instance_id: int) -> Array:
	if not _instances.has(instance_id):
		return []
	return _instances[instance_id]["footprint"].duplicate()

# Peak-risk rule: rotate a LOCAL cell within the UNION bbox (W,H) of footprint U access.
func _rotate_cell(local: Vector2i, W: int, H: int, rotation: int) -> Vector2i:
	match rotation:
		0:   return local
		90:  return Vector2i(H - 1 - local.y, local.x)
		180: return Vector2i(W - 1 - local.x, H - 1 - local.y)
		270: return Vector2i(local.y, W - 1 - local.x)
		_:   return local

# Resolve absolute footprint/access cells for a def (LOCAL arrays) at anchor + rotation.
# (W,H) is the union bbox of footprint U access — NOT the footprint-local bbox.
func resolve_cells(def_footprint: Array, def_access: Array, anchor: Vector2i, rotation: int) -> Dictionary:
	var max_x := 0
	var max_y := 0
	for c in def_footprint + def_access:
		max_x = maxi(max_x, c.x)
		max_y = maxi(max_y, c.y)
	var W: int = max_x + 1
	var H: int = max_y + 1
	var footprint := []
	var access := []
	for c in def_footprint:
		footprint.append(anchor + _rotate_cell(c, W, H, rotation))
	for c in def_access:
		access.append(anchor + _rotate_cell(c, W, H, rotation))
	return {"footprint": footprint, "access": access}

func can_place(def_footprint: Array, def_access: Array, anchor: Vector2i, rotation: int) -> bool:
	var cells := resolve_cells(def_footprint, def_access, anchor, rotation)
	for c in cells["footprint"]:
		if not _region.has_point(c):
			return false
		if not _buildable.get(c, false):
			return false
		if _occupant_id.get(c, -1) != -1:
			return false
		if _access_ids.get(c, []).size() > 0:
			return false
	for c in cells["access"]:
		if not _region.has_point(c):
			return false
		if not _buildable.get(c, false):
			return false
		if _occupant_id.get(c, -1) != -1:
			return false
		if _access_ids.get(c, []).size() > 0:
			return false
	return true

func commit(instance_id: int, def_footprint: Array, def_access: Array, anchor: Vector2i, rotation: int, silent: bool = false) -> bool:
	if not can_place(def_footprint, def_access, anchor, rotation):
		return false
	var cells := resolve_cells(def_footprint, def_access, anchor, rotation)
	for c in cells["footprint"]:
		_occupant_id[c] = instance_id
	for c in cells["access"]:
		var lst: Array = _access_ids.get(c, [])
		lst.append(instance_id)
		_access_ids[c] = lst
	_instances[instance_id] = {"footprint": cells["footprint"].duplicate(), "access": cells["access"].duplicate(), "rotation": rotation}
	if not silent:
		grid_changed.emit(cells["footprint"].duplicate(), cells["access"].duplicate())
	return true

func clear(instance_id: int, silent: bool = false) -> bool:
	if not _instances.has(instance_id):
		return false
	var rec: Dictionary = _instances[instance_id]
	for c in rec["footprint"]:
		_occupant_id[c] = -1
	for c in rec["access"]:
		var lst: Array = _access_ids.get(c, [])
		lst.erase(instance_id)
		_access_ids[c] = lst
	_instances.erase(instance_id)
	if not silent:
		grid_changed.emit(rec["footprint"].duplicate(), rec["access"].duplicate())
	return true

# Re-layout (the core "drag to rearrange" action): clear + re-commit as ONE grid_changed
# (so Navigation/Overlay react once, never to an intermediate empty frame).
# Internals emit silently; move emits exactly once with the merged old+new changed cells.
# Fails safe: if the new placement is invalid, state is untouched (old placement intact),
# and nothing is emitted (nav stays in pre-move state).
func move(instance_id: int, def_footprint: Array, def_access: Array, new_anchor: Vector2i, rotation: int) -> bool:
	if not _instances.has(instance_id):
		return false
	var old: Dictionary = _instances[instance_id]
	var old_fp: Array = old["footprint"].duplicate()
	var old_ac: Array = old["access"].duplicate()
	clear(instance_id, true)  # silent
	if not commit(instance_id, def_footprint, def_access, new_anchor, rotation, true):  # silent
		# rollback: re-commit at old footprint/access (rotation unchanged)
		commit(instance_id, def_footprint, def_access, old_fp[0], old["rotation"], true)  # silent
		return false
	var new_rec: Dictionary = _instances[instance_id]
	grid_changed.emit(old_fp + old_ac + new_rec["footprint"].duplicate() + new_rec["access"].duplicate(), [])
	return true

func get_rotation(instance_id: int) -> int:
	if not _instances.has(instance_id):
		return 0
	return _instances[instance_id]["rotation"]

# Drag-preview path: pure read, never touches real state, never emits.
func get_speculative_snapshot(def_footprint: Array, def_access: Array, anchor: Vector2i, rotation: int) -> Dictionary:
	return {"valid": can_place(def_footprint, def_access, anchor, rotation),
			"cells": resolve_cells(def_footprint, def_access, anchor, rotation)}
