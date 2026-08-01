## PlacementRecord — per-instance spatial record stored in GridSystem's
## reverse index (TR-GS-017, GDD C.7, Story 005).
##
## One record exists per currently-placed equipment instance. It is the
## SINGLE SOURCE OF TRUTH for serialization (Story 007 serializes THIS, not
## the derived occupant_id / access_ids arrays) and for clear() (Story 005:
## clear() resolves an instance_id to its occupied cells via this record —
## never by scanning the grid).
##
## This is a plain data-transfer object — it holds no logic and performs no
## validation itself, mirroring PlacementCheckResult / TransformedFootprint.
## The record's cells are TRANSFORMED world-space cells (already rotated and
## offset by the anchor), exactly what commit() received from the caller.
##
## Rotation convention (decided here, per the Story 003 tech-debt handoff):
## [rotation] stores the DEGREE-VALUED GridSystem.Rotation value the commit
## caller passed (0/90/180/270) — NOT the quarter-turn count (0,1,2,3) that
## ADR-0003's illustrative PlacedInstance.rotation sketch uses. ADR-0003's
## PlacedInstance does not exist yet (Story 006); when it lands, whoever
## builds it must reconcile the two conventions explicitly — see
## docs/tech-debt-register.md (Story 003 / Story 005 entries). Storing as a
## bare int (rather than the Rotation enum type) keeps this DTO decoupled
## from GridSystem, exactly like PlacementCheckResult.fail_code carries
## GridSystem.FailCode values as int.
##
## Defensive duplication (strengthening deviation from the Story 005
## implementation sketch, which assigned caller arrays directly): _init()
## duplicates both cell arrays so the record OWNS its data. A caller that
## mutates or reuses its scratch arrays after commit() cannot silently
## corrupt the reverse index — the record stays stable for clear() and
## serialization. The GDD's core fear is silent bad reads; shared-mutable-
## array aliasing is exactly that class of bug. Cost is negligible (a few
## cells per record, at most once per commit).
class_name PlacementRecord extends RefCounted

## Transformed footprint cells occupied by this instance (grid coordinates).
var footprint_cells: Array[Vector2i]

## Transformed access cells registered as this instance's use cells.
## May be empty (decorative/storage pieces — AC-C5.5).
var access_cells: Array[Vector2i]

## Degree-valued GridSystem.Rotation value (0/90/180/270) this instance was
## committed with. Stored as int — see doc comment for the convention note.
var rotation: int

func _init(p_footprint: Array[Vector2i], p_access: Array[Vector2i], p_rotation: int) -> void:
	footprint_cells = p_footprint.duplicate()
	access_cells = p_access.duplicate()
	rotation = p_rotation
