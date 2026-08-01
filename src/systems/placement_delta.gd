## PlacementDelta — one speculative change to a grid, consumed by
## GridSystem.get_speculative_snapshot() (Story 006, GDD "推测性快照构造").
##
## This is a plain data-transfer object describing either:
##   - an ADD:      is_removal=false, instance_id, footprint_cells, access_cells
##   - a REMOVAL:   is_removal=true,  instance_id (cells are looked up from the
##                  snapshot's placed-instance registry, not from the delta)
##
## Deltas are PRE-VALIDATED by PlacementSystem before reaching the snapshot
## (GDD: "No can_place re-validation in snapshot"). GridSnapshot applies them
## via _commit_in_place/_clear_in_place on a deep copy — the real grid is
## never touched and grid_changed is never emitted.
##
## Defensive duplication (same posture as PlacementRecord): _init() duplicates
## the cell arrays so the delta OWNS its data and a caller mutating its scratch
## arrays cannot corrupt the snapshot's delta dicts.
class_name PlacementDelta extends RefCounted

## true = removal (instance_id only), false = addition (all fields used).
var is_removal: bool

## The instance being added or removed.
var instance_id: int

## Transformed footprint cells (additions only; empty for removals).
var footprint_cells: Array[Vector2i]

## Transformed access cells (additions only; empty for removals).
var access_cells: Array[Vector2i]

func _init(
	p_is_removal: bool,
	p_instance_id: int,
	p_footprint: Array[Vector2i],
	p_access: Array[Vector2i]
) -> void:
	is_removal = p_is_removal
	instance_id = p_instance_id
	footprint_cells = p_footprint.duplicate()
	access_cells = p_access.duplicate()
