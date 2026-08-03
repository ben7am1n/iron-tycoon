## GridSnapshot — speculative read-only view of a grid state (TR-GS-024,
## ADR-0003 §3, Story 006).
##
## Implements the same GridStateReader contract as GridSystem but over a
## DEEP-COPIED base plus delta dicts, so it can answer "what if" questions
## (placement preview, ZoneRules evaluation) without touching the real grid:
##   - _base: the underlying state to fall back to. For GridSystem.get_snapshot()
##     this is a full deep copy of the real grid (AC-X.2 deep-copy semantics);
##     for hand-built snapshots in tests it can be any GridStateReader.
##   - _adds:   Vector2i → int  — footprint cells occupied by speculative adds
##   - _removes: Vector2i → true — base cells cleared by speculative removals
## Read methods check deltas FIRST, then fall back to the base reader
## (GDD "推测性快照构造"). _commit_in_place/_clear_in_place are the private
## write path — underscore = convention only, GDScript has no access control;
## they are invisible through the GridStateReader type (AC-GSR.3).
##
## Deep-copy / no-side-effect guarantees:
##   - get_snapshot() on GridSystem copies all storage; later commit/clear on
##     the real grid CANNOT change a previously-obtained snapshot (AC-X.2).
##   - _commit_in_place/_clear_in_place mutate ONLY this snapshot's delta
##     dicts and its own placed-instance view — never the real grid, never
##     _base, and they never emit grid_changed (AC-X.3).
##   - No can_place re-validation here: deltas are pre-validated by
##     PlacementSystem (GDD — snapshot trusts its input).
##
## PlacedInstance fields for speculative adds: the PlacementDelta format
## carries only {is_removal, instance_id, footprint_cells, access_cells} —
## equipment_id and rotation are NOT in the delta, so speculative instances
## carry equipment_id="" and rotation=0 (R0). anchor is derived as the
## min-offset of footprint ∪ access, the same derivation GridSystem uses.
class_name GridSnapshot extends GridStateReader

## The underlying reader this snapshot falls back to for cells not covered
## by a delta. NEVER the live real grid for get_snapshot()-produced snapshots
## (must be a deep copy — AC-X.2); tests may pass any GridStateReader.
var _base: GridStateReader

## Delta dicts — checked before falling back to _base.
var _adds: Dictionary = {}      # Vector2i → int (occupant_id)
var _removes: Dictionary = {}   # Vector2i → true (cleared cells)

## Resolved placed-instance view: base instances seeded at init, speculative
## adds appended, speculative clears removed. Backs get_placed_instances()
## and get_access_cells(). Values are PlacedInstance DTOs.
var _placed_instances: Dictionary = {}  # instance_id → PlacedInstance


## Builds a snapshot over [base]. Seeds the placed-instance view from
## base.get_placed_instances() so the snapshot is fully self-contained —
## later mutations of the real grid (if [base] is a deep copy of it) cannot
## leak through. Deltas are applied afterwards via _commit_in_place /
## _clear_in_place (see GridSystem.get_speculative_snapshot).
func init(base: GridStateReader) -> void:
	_base = base
	for pi in base.get_placed_instances():
		_placed_instances[pi.instance_id] = pi


func system_name() -> String:
	return "GridSnapshot"


# === Read Methods (GridStateReader contract) ===

## Deltas first: an added cell is solid iff its occupant_id is a real id
## (never -1); a cleared cell falls back to its buildable state — committed
## footprint cells are always buildable, so a cleared cell is walkable.
func is_solid(cell: Vector2i) -> bool:
	if _adds.has(cell):
		return _adds[cell] != -1
	if _removes.has(cell):
		return false
	return _base.is_solid(cell)


func get_occupant_id(cell: Vector2i) -> int:
	if _adds.has(cell):
		return _adds[cell]
	if _removes.has(cell):
		return -1
	return _base.get_occupant_id(cell)


func get_access_cells(instance_id: int) -> Array[Vector2i]:
	if _placed_instances.has(instance_id):
		return (_placed_instances[instance_id] as PlacedInstance).access_cells.duplicate()
	return []


func get_dimensions() -> Vector2i:
	return _base.get_dimensions()


## A speculative snapshot carries its base's mutation stamp (TR-MS-007):
## MemberSim path invalidation compares against the REAL grid's version, and
## a snapshot is a read-only view — its deltas never bump a version counter.
func get_grid_version() -> int:
	return _base.get_grid_version()


## Resolved view: base instances (seeded at init) + speculative adds −
## speculative clears. Order is stable within one snapshot.
func get_placed_instances() -> Array[PlacedInstance]:
	var result: Array[PlacedInstance] = []
	for pi in _placed_instances.values():
		result.append(pi as PlacedInstance)
	return result


# === Private write path (convention-only; NOT on GridStateReader — AC-GSR.3) ===

## Applies a speculative ADD of [instance_id] at [footprint_cells] with
## [access_cells] to THIS snapshot only. No can_place re-validation (deltas
## are pre-validated). Rejects a duplicate instance_id with push_error +
## no-op, mirroring commit()'s AC-C7.2 rejection semantics.
##
## [equipment_id] is an OPTIONAL parameter (default "") so a preview can
## carry the dragged piece's type — the PlacementDelta format does not
## include it yet, but preview==commit (ZoneRules AC2, Core Rule 2) requires
## the speculative instance to score with the same equipment_id the
## committed instance will have. Existing callers that pass only 3 arguments
## keep the legacy behavior (equipment_id="" — the pre-zone-rules grid
## contract, which stores no type by design).
func _commit_in_place(instance_id: int, footprint_cells: Array[Vector2i], access_cells: Array[Vector2i], equipment_id: String = "") -> void:
	if _placed_instances.has(instance_id):
		push_error("GridSnapshot: _commit_in_place() rejected — instance_id %d already present in the snapshot (AC-C7.2 mirror)." % instance_id)
		return
	for cell in footprint_cells:
		_adds[cell] = instance_id
		_removes.erase(cell)  # an add overrides a prior clear of the same cell
	var anchor := _min_offset(footprint_cells + access_cells)
	_placed_instances[instance_id] = PlacedInstance.new(
		instance_id, equipment_id, anchor, 0, footprint_cells, access_cells
	)


## Applies a speculative REMOVAL of [instance_id] to THIS snapshot only.
## Resolves the instance's cells from the snapshot's own placed-instance
## view (never by scanning the grid — mirrors clear()'s reverse-index
## contract). Unknown instance_id → push_error + no-op (AC-C7.3 mirror).
func _clear_in_place(instance_id: int) -> void:
	if not _placed_instances.has(instance_id):
		push_error("GridSnapshot: _clear_in_place() rejected — instance_id %d not in the snapshot's placed-instance view (AC-C7.3 mirror)." % instance_id)
		return
	var instance: PlacedInstance = _placed_instances[instance_id]
	_placed_instances.erase(instance_id)
	for cell in instance.footprint_cells:
		if _adds.has(cell) and _adds[cell] == instance_id:
			# The cell was added by an earlier speculative commit — removing
			# the instance restores the base state, no _removes entry needed.
			_adds.erase(cell)
		elif not _adds.has(cell):
			# The cell was occupied in the base — mark it cleared.
			_removes[cell] = true


## Minimum (x, y) offset across [cells], or Vector2i.ZERO for an empty array.
## Mirrors GridSystem._min_offset (anchor derivation, AC-D5.2 convention).
func _min_offset(cells: Array[Vector2i]) -> Vector2i:
	if cells.is_empty():
		return Vector2i.ZERO
	var min_x := cells[0].x
	var min_y := cells[0].y
	for c in cells:
		min_x = min(min_x, c.x)
		min_y = min(min_y, c.y)
	return Vector2i(min_x, min_y)
