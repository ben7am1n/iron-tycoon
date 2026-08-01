## PlacedInstance — read-only DTO describing one currently-placed equipment
## instance, as returned by GridStateReader.get_placed_instances() (TR-GS-024,
## ADR-0003 §2).
##
## This is a plain data-transfer object carrying the full spatial + identity
## data ZoneRules and other consumers need for one placement: which instance,
## where it is anchored, its rotation, and its transformed (anchor-offset,
## already-rotated) footprint and access cells.
##
## IMMUTABILITY (Control Manifest): fields are immutable after construction.
## GDScript has no readonly modifier — this is enforced by convention. The
## _init() constructor duplicates both cell arrays (same defensive posture as
## PlacementRecord), so the DTO OWNS its data: a caller that mutates a
## scratch array after construction cannot corrupt the reverse index or any
## in-flight GridSnapshot that shares this DTO. Violating immutability
## corrupts both the base grid and all snapshots built from it (ADR-0003
## risk section).
##
## ROTATION CONVENTION (decided here, closing the Story 003 / Story 005
## handoff in docs/tech-debt-register.md): [rotation] stores the
## DEGREE-VALUED GridSystem.Rotation value (0/90/180/270), matching
## PlacementRecord.rotation and GridSystem's commit() — NOT the quarter-turn
## count (0,1,2,3) in ADR-0003's original illustrative sketch. The two
## conventions must not coexist by accident; this DTO adopts degrees.
##
## equipment_id: GridSystem stores only integer occupant_id and deliberately
## never tracks equipment type (TR-GS — "GridSystem stores only integer
## occupant_id, never equipment type or zone membership"). Consumers that
## need the equipment type must resolve instance_id → equipment via the
## equipment-catalog epic (not yet in src/); until then get_placed_instances()
## returns an empty string here.
class_name PlacedInstance extends RefCounted

## Unique instance id, allocated by PlacementSystem (>= 0, monotonic).
var instance_id: int

## Key into EquipmentCatalog (empty until the equipment-catalog epic lands).
var equipment_id: String

## Top-left cell of the instance's declared bounding box (grid coords).
var anchor: Vector2i

## Degree-valued GridSystem.Rotation (0/90/180/270) — see doc comment.
var rotation: int

## Transformed (rotated + anchor-offset) footprint cells.
var footprint_cells: Array[Vector2i]

## Transformed (rotated + anchor-offset) access cells.
var access_cells: Array[Vector2i]

## Constructs the DTO, duplicating both cell arrays so the DTO owns its data
## (caller mutation of the source arrays cannot corrupt the DTO).
func _init(
	p_instance_id: int,
	p_equipment_id: String,
	p_anchor: Vector2i,
	p_rotation: int,
	p_footprint: Array[Vector2i],
	p_access: Array[Vector2i]
) -> void:
	instance_id = p_instance_id
	equipment_id = p_equipment_id
	anchor = p_anchor
	rotation = p_rotation
	footprint_cells = p_footprint.duplicate()
	access_cells = p_access.duplicate()


## Convenience (ADR-0003 §2 / Key Interfaces): the bounding-box size of
## footprint ∪ access — (max_x - min_x + 1, max_y - min_y + 1). Used by
## ZoneRules' spaciousness calculation (Story 009). Returns Vector2i.ZERO for
## an empty cell set. Allocates temporary arrays per call — safe for
## one-off / low-frequency use; precompute if called per frame at scale.
func declared_bounds() -> Vector2i:
	var xs: Array = []
	var ys: Array = []
	for c in footprint_cells:
		xs.append(c.x)
		ys.append(c.y)
	for c in access_cells:
		xs.append(c.x)
		ys.append(c.y)
	if xs.is_empty():
		return Vector2i.ZERO
	var min_x: int = xs[0]
	var max_x: int = xs[0]
	var min_y: int = ys[0]
	var max_y: int = ys[0]
	for i in xs.size():
		min_x = min(min_x, xs[i])
		max_x = max(max_x, xs[i])
		min_y = min(min_y, ys[i])
		max_y = max(max_y, ys[i])
	return Vector2i(max_x - min_x + 1, max_y - min_y + 1)
