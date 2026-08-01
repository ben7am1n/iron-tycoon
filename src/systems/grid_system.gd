## GridSystem — core cell data model for the gym floor grid.
##
## Stores three orthogonal dimensions per cell:
##   - occupant_id: PackedInt32Array, indexed by flat_index (y * width + x)
##     -1 = empty sentinel. 0 is a legal occupant_id (first piece placed).
##   - buildable: PackedByteArray, same flat_index scheme, 0/1 values.
##     Set once during level load, then frozen (read-only during gameplay).
##   - access_ids: Dictionary — Vector2i key → Array value, sparse.
##     Multiple occupant_ids can share the same access cell.
##
## occupant_id and access_ids are completely independent — one never
## affects the other. GridSystem stores only integer occupant_id,
## never equipment type or zone membership.
##
## Extends GridStateReader (TR-GS-024, ADR-0003) which extends SimSystem
## (ADR-0001 two-phase init pattern). GridStateReader was inserted as the
## intermediate base class in Story 006 — this resolves tech-debt #1
## (GridSystem should extend GridStateReader, not SimSystem directly).
## Injected via SimulationOrchestrator, never accessed through
## Autoload/singleton.
##
## The write surface (commit/clear/can_place) exists ONLY here, not on
## GridStateReader — consumers holding a GridStateReader reference can only
## read (ADR-0003 §4, AC-GSR.3).
class_name GridSystem extends GridStateReader


## Rotation values usable when placing equipment (GDD D.1, TR-GS-029).
## Degree-valued (0/90/180/270) to match the D.1 rotation formula directly.
##
## ROTATION CONVENTION (decided in Story 006, closing the Story 003/005
## handoff in docs/tech-debt-register.md): ALL layers store the degree
## value — commit() takes this enum, PlacementRecord.rotation stores the
## degree int, and PlacedInstance.rotation carries the same degree int.
## ADR-0003's original illustrative sketch used quarter-turn counts
## (0,1,2,3); that convention is superseded. Do not introduce quarter-turn
## values anywhere — the two conventions must not coexist.
##
## GDScript does NOT enforce that a Rotation-typed value is actually one of
## these four members at runtime -- illegal values (45, -90, 360) can still
## reach _transform_cell() and MUST hit its assert(false) fallback branch
## (AC-D1.1), never a silent fallthrough to R0.
enum Rotation { R0 = 0, R90 = 90, R180 = 180, R270 = 270 }


## Placement validation failure codes (TR-GS-015, GDD C.6 / AC-C6.x).
## Returned by can_place() in PlacementCheckResult.fail_code.
##
## VALID=0 is the success code — a PlacementCheckResult with valid=true
## always carries VALID. The 5 failure codes are intentionally split between
## footprint and access failure modes (and between OOB vs room-geometry
## within each) so Build UI can render differentiated messages:
##   - footprint OOB vs access OOB: "equipment won't fit" vs
##     "access path extends outside room"
##   - footprint geometry vs access geometry: same split
## OVERLAPS_EXISTING_EQUIPMENT is ONLY for footprint-on-footprint overlap —
## access cells deliberately never fail on occupancy (AC-C5.2/C5.4).
enum FailCode {
	VALID = 0,
	OUT_OF_BOUNDS = 1,
	BLOCKED_BY_ROOM_GEOMETRY = 2,
	OVERLAPS_EXISTING_EQUIPMENT = 3,
	ACCESS_OUT_OF_BOUNDS = 4,
	ACCESS_BLOCKED_BY_ROOM_GEOMETRY = 5,
}


## DeserializeResult error categories (GDD §C.8, Story 007).
##
## The three categories SaveLoad/UI display (GDD "存档加载失败的说明"):
##   - LEVEL_GEOMETRY_MISMATCH     — save disagrees with the CURRENT level:
##                                   dimension mismatch, or a footprint/access
##                                   cell on buildable=false ground.
##   - CORRUPTED_SAVE_OUT_OF_BOUNDS — a cell coordinate outside
##                                   [0,width)×[0,height); intercepted in the
##                                   validation phase, BEFORE any write (no
##                                   PackedArray OOB access possible).
##   - CORRUPTED_SAVE_OVERLAP      — two records share a footprint cell.
##                                   Access-cell overlap is LEGAL and does not
##                                   error (AC-C8.8).
##
## Two structural categories beyond the GDD's three (added because the GDD
## list only covers geometry/corruption classes, not malformed-structure or
## programming-error classes; SaveLoad treats these as load-abort too):
##   - CORRUPTED_SAVE              — malformed save structure: bad
##                                   schema_version, missing keys, non-numeric
##                                   ids/rotations, malformed cells, negative
##                                   or duplicate instance_ids, empty footprint.
##   - INTERNAL_ERROR              — programming error: unknown mode,
##                                   buildable_snapshot size mismatch, or
##                                   use-before-init.
const ERR_LEVEL_GEOMETRY_MISMATCH := "LEVEL_GEOMETRY_MISMATCH"
const ERR_CORRUPTED_SAVE_OUT_OF_BOUNDS := "CORRUPTED_SAVE_OUT_OF_BOUNDS"
const ERR_CORRUPTED_SAVE_OVERLAP := "CORRUPTED_SAVE_OVERLAP"
const ERR_CORRUPTED_SAVE := "CORRUPTED_SAVE"
const ERR_INTERNAL_ERROR := "INTERNAL_ERROR"


## Emitted exactly once per successful commit() or clear() — never per cell,
## never from read-only paths (can_place, get_snapshot — Story 006) and never
## during drag preview (TR-GS-021).
##
## Payload semantics (GDD signal design): the two arrays are "these cells'
## state changed, go re-query" — they do NOT describe the direction of the
## change. A consumer receiving the signal must re-read the cells' current
## values via is_solid() / get_occupant_id() / get_access_ids(), not guess
## from the payload whether a commit or a clear happened. Navigation only
## needs footprint_cells_changed (solidity); ZoneRules/Congestion need both.
##
## The full payload contract (ordering, dedup expectations, subscriber
## behavior) is tested in Story 008; this story declares the signal and
## emits it from the two write paths.
signal grid_changed(footprint_cells_changed: Array[Vector2i], access_cells_changed: Array[Vector2i])


## Marks the system as initialized. Must be called exactly once.
## Parameterized by width and height so that callers get a compile
## error if they forget to initialize the grid. Rejects non-positive
## dimensions without marking the system initialized, so a caller can
## retry with valid values.
func init(grid_width: int, grid_height: int) -> void:
	if grid_width <= 0 or grid_height <= 0:
		push_error("GridSystem: init() requires positive width and height, got (%d, %d)." % [grid_width, grid_height])
		return
	if not _mark_initialized():
		return
	_width = grid_width
	_height = grid_height
	var size := grid_width * grid_height
	_occupant_id.resize(size)
	_buildable.resize(size)
	for i in size:
		_occupant_id[i] = -1
		_buildable[i] = 0
	_access_ids.clear()
	_reverse_index.clear()
	_buildable_frozen = false


func system_name() -> String:
	return "GridSystem"


# === Storage (private — never expose as public API) ===

var _occupant_id: PackedInt32Array = []
var _buildable: PackedByteArray = []
var _access_ids: Dictionary = {}  # Vector2i → Array (occupant_ids)
var _width: int = 0
var _height: int = 0
var _buildable_frozen: bool = false

# === Reverse index (instance_id → PlacementRecord) ===
#
# MANDATORY (TR-GS-017, GDD C.7): clear() must resolve an instance_id to its
# occupied cells via THIS dictionary — never by scanning the whole grid.
# It is also the single source of truth for serialization (Story 007 reads
# this, not the derived occupant_id/access_ids arrays).
#
# NEVER exposed as public API (Control Manifest: Forbidden) — consumers that
# need per-instance data go through the read surface (Story 006's
# GridStateReader / get_placed_instances).
var _reverse_index: Dictionary = {}  # instance_id:int → PlacementRecord


# === Read Methods ===

## Returns the occupant_id at [cell], or -1 if the cell is empty.
## This read is completely independent of buildable state —
## setting buildable=false on a cell does not affect get_occupant_id().
##
## Out-of-bounds cells push_error() and return -1 (GDD D.2) — never the
## real value of an adjacent row/column cell.
func get_occupant_id(cell: Vector2i) -> int:
	if not _assert_initialized():
		return -1
	if not is_in_bounds(cell):
		push_error("GridSystem: get_occupant_id() on out-of-bounds cell %s." % cell)
		return -1
	return _occupant_id[flat_index(cell)]


## Returns whether [cell] is flagged as buildable.
## buildable is static after level load — set once, then frozen.
##
## Out-of-bounds cells push_error() and return false (GDD D.2) — never the
## real value of an adjacent row/column cell.
func get_buildable(cell: Vector2i) -> bool:
	if not _assert_initialized():
		return false
	if not is_in_bounds(cell):
		push_error("GridSystem: get_buildable() on out-of-bounds cell %s." % cell)
		return false
	return _buildable[flat_index(cell)] != 0


## Returns the list of occupant_ids that have [cell] registered as
## their access cell. Returns an empty array if this cell is not
## anyone's access cell.
##
## Out-of-bounds cells push_error() and return [] (GDD D.2) — never the
## real value of an adjacent row/column cell.
func get_access_ids(cell: Vector2i) -> Array:  # Array[int]
	if not _assert_initialized():
		return []
	if not is_in_bounds(cell):
		push_error("GridSystem: get_access_ids() on out-of-bounds cell %s." % cell)
		return []
	if _access_ids.has(cell):
		return (_access_ids[cell] as Array).duplicate()
	return []


## Returns whether [cell] is solid — impassable for pathfinding purposes.
##
## Formula (GDD D.3 / TR-GS-022):
##   is_solid(cell) = NOT buildable(cell) OR occupant_id(cell) != -1
##
## access_ids deliberately do NOT participate in this formula (TR-GS-016) —
## access cells must stay walkable so members can reach and use equipment.
## The occupant_id check uses explicit `!= -1`, never a truthy check —
## occupant_id = 0 (the first piece ever placed) is a legal, solid occupant.
##
## Out-of-bounds cells push_error() and return true — "outside the room is
## solid" is the safety default that keeps AStarGrid2D from pathing outside
## the room bounds (GDD D.2/D.3).
func is_solid(cell: Vector2i) -> bool:
	if not _assert_initialized():
		return true
	if not is_in_bounds(cell):
		push_error("GridSystem: is_solid() on out-of-bounds cell %s." % cell)
		return true
	var idx := flat_index(cell)
	return _buildable[idx] == 0 or _occupant_id[idx] != -1


## Returns the access cells registered for [instance_id] (transformed,
## anchor-offset), per the GridStateReader contract (TR-GS-024). Resolves
## via the reverse index — O(1), never a grid scan. Unknown instance_id
## returns [] (a cleared or never-committed id has no access cells).
##
## Note: this is the instance→cells direction of the read surface. The
## cell→ids direction (get_access_ids(cell)) remains a separate GridSystem
## method; both coexist.
func get_access_cells(instance_id: int) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	if not _assert_initialized():
		return result
	if not _reverse_index.has(instance_id):
		return result
	return (_reverse_index[instance_id] as PlacementRecord).access_cells.duplicate()


## Returns all currently placed equipment instances as typed PlacedInstance
## DTOs (TR-GS-024, ADR-0003 §2), built fresh from the reverse index.
## Order is stable within a single grid state version but not guaranteed
## across commits — consumers must not depend on insertion order.
##
## equipment_id is "" (GridSystem stores only integer occupant_id by design —
## TR-GS; the equipment-catalog epic will resolve id → equipment later).
## anchor is derived as the min-offset of footprint ∪ access (the anchor
## convention, AC-D5.2, guarantees this equals the placement anchor);
## rotation is the degree-valued GridSystem.Rotation int.
func get_placed_instances() -> Array[PlacedInstance]:
	var result: Array[PlacedInstance] = []
	if not _assert_initialized():
		return result
	for instance_id in _reverse_index:
		result.append(_to_placed_instance(instance_id))
	return result


## Builds a PlacedInstance DTO for [instance_id] from its reverse-index
## record. Private helper of get_placed_instances().
func _to_placed_instance(instance_id: int) -> PlacedInstance:
	var record: PlacementRecord = _reverse_index[instance_id]
	var anchor := _min_offset(record.footprint_cells + record.access_cells)
	return PlacedInstance.new(
		instance_id, "", anchor, record.rotation,
		record.footprint_cells, record.access_cells
	)


# === Buildable Setup (level load only) ===

## Sets the buildable flag for a single cell.
## Must be called BEFORE freeze_buildable() — after the level is loaded,
## this method push_errors and no-ops to enforce immutability.
func set_buildable(cell: Vector2i, value: bool) -> void:
	if not _assert_initialized():
		return
	if _buildable_frozen:
		push_error("GridSystem: set_buildable() called after level load. Buildable state is frozen.")
		return
	if not is_in_bounds(cell):
		push_error("GridSystem: set_buildable() called on out-of-bounds cell %s." % cell)
		return
	_buildable[flat_index(cell)] = 1 if value else 0


## Sets buildable for multiple cells at once. Same freeze check as set_buildable().
func set_buildable_bulk(cells: Array, value: bool) -> void:
	if not _assert_initialized():
		return
	if _buildable_frozen:
		push_error("GridSystem: set_buildable_bulk() called after level load. Buildable state is frozen.")
		return
	var byte_val := 1 if value else 0
	for cell in cells:
		if not is_in_bounds(cell):
			push_error("GridSystem: set_buildable_bulk() — out-of-bounds cell %s skipped." % cell)
			continue
		_buildable[flat_index(cell)] = byte_val


## Freezes the buildable mask. After this call, all set_buildable()
## and set_buildable_bulk() calls are rejected with push_error().
## Called exactly once after level load completes.
func freeze_buildable() -> void:
	if not _assert_initialized():
		return
	_buildable_frozen = true


# === Occupant ID Operations ===

## Commits [occupant_id] to [cell]. Returns true on success.
## Returns false if the cell already has an occupant (mutually-exclusive
## single-value semantics).
##
## occupant_id = 0 is legal (first piece placed). The empty check uses
## explicit comparison against -1, never truthiness.
##
## occupant_id = -1 is rejected — it is the reserved empty sentinel and
## committing it would make an occupied cell indistinguishable from an
## empty one.
func commit_occupant(cell: Vector2i, occupant_id: int) -> bool:
	if not _assert_initialized():
		return false
	if occupant_id == -1:
		push_error("GridSystem: commit_occupant() rejected — occupant_id=-1 is the reserved empty sentinel.")
		return false
	if not is_in_bounds(cell):
		push_error("GridSystem: commit_occupant() on out-of-bounds cell %s." % cell)
		return false
	var idx := flat_index(cell)
	if _occupant_id[idx] != -1:
		return false
	_occupant_id[idx] = occupant_id
	return true


## Clears the occupant_id at [cell], setting it back to -1 (empty).
func clear_occupant(cell: Vector2i) -> void:
	if not _assert_initialized():
		return
	if not is_in_bounds(cell):
		push_error("GridSystem: clear_occupant() on out-of-bounds cell %s." % cell)
		return
	_occupant_id[flat_index(cell)] = -1


# === Access ID Operations ===

## Registers [occupant_id] as having [cell] as an access cell.
## Multiple occupant_ids can share the same access cell
## (non-mutually-exclusive multi-value semantics).
func commit_access(cell: Vector2i, occupant_id: int) -> void:
	if not _assert_initialized():
		return
	if not is_in_bounds(cell):
		push_error("GridSystem: commit_access() on out-of-bounds cell %s." % cell)
		return
	if _access_ids.has(cell):
		var arr: Array = _access_ids[cell]
		if not arr.has(occupant_id):
			arr.append(occupant_id)
	else:
		_access_ids[cell] = [occupant_id]


## Removes [occupant_id] from this cell's access_ids list.
## If the list becomes empty, the dictionary entry is removed entirely.
func clear_access(cell: Vector2i, occupant_id: int) -> void:
	if not _assert_initialized():
		return
	if not is_in_bounds(cell):
		push_error("GridSystem: clear_access() on out-of-bounds cell %s." % cell)
		return
	if not _access_ids.has(cell):
		return
	var arr: Array = _access_ids[cell]
	arr.erase(occupant_id)
	if arr.is_empty():
		_access_ids.erase(cell)


# === Commit / Clear (high-level write path, TR-GS-017, GDD C.7) ===
#
# commit()/clear() are the canonical mutation surface for placing and
# removing equipment. They are the ONLY path that touches the reverse
# index, and every commit/clear emits grid_changed exactly once. The raw
# per-cell primitives above (commit_occupant/clear_occupant/commit_access/
# clear_access) remain public for the older story tests and for callers
# that need cell-level control, but new production code should go through
# commit()/clear().

## Commits an equipment placement into the grid (TR-GS-017, GDD C.7,
## AC-C7.x, Story 005).
##
## Contract: called AFTER can_place() returned valid — commit() trusts the
## caller and does NOT re-validate the placement (footprint/access overlap,
## buildable state, rotation legality). It performs exactly the writes
## can_place() greenlit:
##   1. every footprint cell: occupant_id[cell] = instance_id
##   2. every access cell: append instance_id to access_ids[cell]
##      (deduplicated — an id never appears twice on one cell)
##   3. reverse index: instance_id -> PlacementRecord (the single source of
##      truth for serialization, Story 007)
##   4. emit grid_changed ONCE (never per cell) with the committed cells
##
## Rejection paths — each is ATOMIC (decided before any cell write, so a
## rejected commit leaves the grid byte-identical; AC-C7.2's "reject BEFORE
## any cell writes" requirement):
##   - use-before-init (via _assert_initialized — Control Manifest)
##   - instance_id < 0 (AC-C7.7): -1 is the reserved empty sentinel; a
##     negative id would make get_occupant_id() report its cells as empty
##     forever, and clear() could never release them.
##   - duplicate instance_id already active in the reverse index (AC-C7.2):
##     prevents the overwrite-leak where the old record's cells become
##     permanently orphaned (occupied but unreachable by clear()).
##
## PITFALL (Story 005): instance_id = 0 is LEGAL — it is the first piece
## ever placed. All id checks here use explicit comparisons / Dictionary
## has(), NEVER truthiness (a `if instance_id:` check would reject 0).
##
## Deviation from the Story 005 implementation sketch (documented, not
## silent): the sketch guards instance_id >= 0 with assert(). The GDD
## §C.7 ("commit() 收到 instance_id < 0 → push_error() 并拒绝提交") and
## AC-C7.7 both demand push_error(), which assert() does not satisfy —
## assert() aborts the current function frame and is compiled out of
## release builds, while the -1 sentinel protection must be active in
## release too. push_error() + return is used instead.
##
## Debug-only backstop (matches the sketch): each cell is bounds-checked
## with assert() before the PackedInt32Array write. A firing assert
## indicates the caller bypassed can_place() — in debug builds it aborts
## this frame (possibly leaving earlier cells of THIS call written, which
## is acceptable for a programming-error path; the reverse index entry and
## signal are never emitted), in release builds the engine's own packed
## array bounds check guards the write. The ACs do not exercise this path
## — commit() is only ever called with can_place()-validated cells.
func commit(instance_id: int, footprint_cells: Array[Vector2i], access_cells: Array[Vector2i], rotation: Rotation) -> void:
	if not _assert_initialized():
		return
	# AC-C7.7: negative ids rejected BEFORE any write (also protects the
	# -1 empty sentinel). Explicit comparison — never truthiness (id 0 is
	# legal, see pitfall note above).
	if instance_id < 0:
		push_error("GridSystem: commit() rejected — instance_id must be >= 0; got %d. Negative ids collide with the -1 empty sentinel (AC-C7.7)." % instance_id)
		return
	# AC-C7.2: duplicate id rejected BEFORE any write — the old record must
	# survive intact and the old cells must stay occupied. Dictionary.has()
	# is an explicit membership check; id 0 is a legal key, not a falsey
	# miss.
	if _reverse_index.has(instance_id):
		push_error("GridSystem: commit() rejected — instance_id %d is already in the reverse index; a duplicate commit is not allowed (AC-C7.2)." % instance_id)
		return

	# Write footprint occupancy. Direct packed-array write by flat index
	# (GDD D.2); assert is the debug-only backstop for a caller that
	# bypassed can_place().
	for fc in footprint_cells:
		assert(is_in_bounds(fc), "GridSystem: commit() footprint cell %s out of bounds — can_place() should have rejected this placement." % fc)
		_occupant_id[flat_index(fc)] = instance_id

	# Write access ids. Dedup guard keeps access_ids free of duplicate ids
	# per cell — otherwise a duplicate access cell in the input would make
	# clear()'s single-occurrence erase() leave a permanently leaked entry.
	for ac in access_cells:
		assert(is_in_bounds(ac), "GridSystem: commit() access cell %s out of bounds — can_place() should have rejected this placement." % ac)
		if _access_ids.has(ac):
			var arr: Array = _access_ids[ac]
			if not arr.has(instance_id):
				arr.append(instance_id)
		else:
			_access_ids[ac] = [instance_id]

	# Reverse index — the single source of truth for serialization. The
	# record duplicates its inputs (see placement_record.gd header).
	var record := PlacementRecord.new(footprint_cells, access_cells, rotation)
	_reverse_index[instance_id] = record

	# Signal — once per commit, never per cell. Payload arrays are
	# duplicated so a subscriber mutating the payload cannot corrupt the
	# reverse index record (same defensive posture as get_access_ids()).
	grid_changed.emit(record.footprint_cells.duplicate(), record.access_cells.duplicate())


## Removes a previously committed placement from the grid (TR-GS-017,
## GDD C.7, AC-C7.1/C7.3, Story 005).
##
## The reverse index is MANDATORY here (AC-C7.1): the instance's occupied
## cells are resolved via _reverse_index[instance_id] — NEVER by scanning
## the whole grid. Cost is O(footprint_cells + access_cells), not
## O(grid cells). Access-cell id removal is O(k) per cell where k is the
## number of ids sharing that cell (expected single digits in MVP — GDD
## C.5's acknowledged complexity tail).
##
## Sequence:
##   1. footprint cells: occupant_id[cell] = -1
##   2. access cells: remove instance_id from access_ids[cell]; drop the
##      dictionary entry when a cell's list becomes empty (stays sparse)
##   3. remove the reverse index entry
##   4. emit grid_changed ONCE with the cleared cells
##
## Rejection path (ATOMIC — nothing mutated, no signal emitted, AC-C7.3):
##   - use-before-init (via _assert_initialized)
##   - instance_id not in the reverse index: push_error() and return. The
##     id was never committed, or was already cleared. This also covers
##     negative ids (a never-committed -1 falls into this branch — clear()
##     needs no separate negative-id check, per the Story 005 QA notes).
func clear(instance_id: int) -> void:
	if not _assert_initialized():
		return
	if not _reverse_index.has(instance_id):
		push_error("GridSystem: clear() rejected — instance_id %d is not in the reverse index; nothing to clear (AC-C7.3)." % instance_id)
		return

	var record: PlacementRecord = _reverse_index[instance_id]

	# Clear footprint occupancy back to the -1 empty sentinel.
	for fc in record.footprint_cells:
		_occupant_id[flat_index(fc)] = -1

	# Remove this id from every access cell it owns; erase() removes the
	# first occurrence, which is the only one that can exist (commit()
	# dedups access ids per cell).
	for ac in record.access_cells:
		if not _access_ids.has(ac):
			continue
		var arr: Array = _access_ids[ac]
		arr.erase(instance_id)
		if arr.is_empty():
			_access_ids.erase(ac)

	# Drop the reverse index entry — after this, the id is clearable
	# again (AC-C7.8's documented reuse path) and serialize() (Story 007)
	# no longer sees it.
	_reverse_index.erase(instance_id)

	# Signal — once per clear, never per cell. Duplicated payload arrays
	# (same rationale as commit()).
	grid_changed.emit(record.footprint_cells.duplicate(), record.access_cells.duplicate())


# === Snapshot (Story 006) ===

## Returns a deep-copy snapshot of the current grid state (TR-GS-024,
## AC-GSR.1/AC-GSR.2/AC-X.2). The returned GridSnapshot is fully
## self-contained: it wraps a GridSystem copy with duplicated storage
## (_occupant_id/_buildable/_access_ids/_reverse_index), so later
## commit()/clear() on THIS grid cannot change the snapshot's values —
## deep-copy semantics (AC-X.2). No grid_changed is emitted (read-only path).
##
## Before-init safe default: _assert_initialized() push_errors and the
## returned snapshot wraps a fresh UNINITIALIZED GridSystem — its reads then
## behave exactly like reads on an uninitialized grid (push_error + safe
## defaults). Matches the file's loud-failure contract.
func get_snapshot() -> GridSnapshot:
	var snap := GridSnapshot.new()
	if not _assert_initialized():
		snap.init(GridSystem.new())
		return snap
	snap.init(_deep_copy_for_snapshot())
	return snap


## Returns a speculative snapshot: a deep copy of the current state with
## [deltas] applied on top (GDD "推测性快照构造", AC-X.3). Operates on the
## COPY ONLY — the real grid is never touched and no grid_changed is
## emitted. Deltas are pre-validated by PlacementSystem; no can_place
## re-validation happens here.
func get_speculative_snapshot(deltas: Array[PlacementDelta]) -> GridSnapshot:
	var snap := get_snapshot()
	for delta in deltas:
		if delta.is_removal:
			snap._clear_in_place(delta.instance_id)
		else:
			snap._commit_in_place(delta.instance_id, delta.footprint_cells, delta.access_cells)
	return snap


## Creates a new GridSystem with duplicated storage — the deep-copy
## primitive behind get_snapshot()/get_speculative_snapshot() (AC-X.2).
## Every nested container is duplicated: the packed arrays via duplicate(),
## the access_ids inner arrays via per-key duplicate(), and each
## PlacementRecord via its own duplicating constructor.
func _deep_copy_for_snapshot() -> GridSystem:
	var copy := GridSystem.new()
	copy._mark_initialized()
	copy._width = _width
	copy._height = _height
	copy._occupant_id = _occupant_id.duplicate()
	copy._buildable = _buildable.duplicate()
	copy._buildable_frozen = _buildable_frozen
	for cell in _access_ids:
		copy._access_ids[cell] = (_access_ids[cell] as Array).duplicate()
	for instance_id in _reverse_index:
		var record: PlacementRecord = _reverse_index[instance_id]
		copy._reverse_index[instance_id] = PlacementRecord.new(
			record.footprint_cells, record.access_cells, record.rotation
		)
	return copy


	# === Serialization (Story 007) ===

## Serializes the grid's placed instances into a plain Dictionary
## (TR-GS-019, GDD §C.8 rule 8, ADR-0002).
##
## WHAT IS STORED: the reverse index only (instance_id → PlacementRecord),
## NEVER the derived occupant_id / access_ids arrays. The reverse index is
## the single source of truth that structurally cannot desync (GDD §C.8:
## storing both representations would make any one-sided write bug produce a
## silent, load-time-only inconsistency) — and it is the only place rotation
## lives, so serializing it preserves rotation by construction (AC-C8.2).
##
## DETERMINISM (AC-C8.3 / AC-C8.3b): output is fully deterministic —
##   - records sorted by instance_id ASCENDING (Dictionary iteration order
##     is insertion order, so we sort explicitly),
##   - within each record, footprint_cells and access_cells sorted by (y, x)
##     lexicographic.
## Two identically-built grids produce byte-identical output; save→load→save
## produces a byte-identical blob (AC-C8.3b).
##
## JSON-SAFE CELL ENCODING (DEVIATION from the Story 007 sketch, verified
## empirically in 4.7.1): the sketch emits `rec.footprint_cells` — raw
## Vector2i arrays. JSON.stringify() renders Vector2i as the STRING "(1, 2)",
## and JSON.parse_string() returns that string back — a Vector2i cannot
## survive a JSON round-trip in 4.7.1 (probed: STR1 output shows
## "footprint_cells":["(1, 2)"]). The Control Manifest requires the save blob
## to be JSON with JSON.stringify(full_precision, sort_keys) — so cells are
## emitted as [x, y] INT ARRAYS, matching ADR-0002's catalog format
## ("footprint_cells": [[0, 0], [1, 0]]). deserialize() accepts BOTH encodings
## (Vector2i for in-memory round-trips, [x,y] arrays from JSON files) — see
## _cell_from_variant().
##
## buildable is deliberately NOT in the save file (TR-GS-020) — it is level
## geometry, injected separately by the level loader before deserialize().
##
## Before-init safe default: a schema-versioned empty dictionary (width/height
## 0, no records), consistent with the file's loud-failure contract.
func serialize() -> Dictionary:
	if not _assert_initialized():
		return {"schema_version": 1, "width": 0, "height": 0, "records": []}

	var records: Array = []
	var ids: Array = _reverse_index.keys()
	ids.sort()  # ascending by instance_id — deterministic (AC-C8.3)
	for instance_id in ids:
		var rec: PlacementRecord = _reverse_index[instance_id]
		var fp := _serialize_cells(rec.footprint_cells)
		var ac := _serialize_cells(rec.access_cells)
		records.append({
			"instance_id": instance_id,
			"footprint_cells": fp,
			"access_cells": ac,
			"rotation": rec.rotation,
		})

	return {
		"schema_version": 1,
		"width": _width,
		"height": _height,
		"records": records,
	}


## Converts transformed Vector2i cells to JSON-safe [x, y] int arrays, sorted
## by (y, x) lexicographic — deterministic cell ordering within each record
## (GDD §C.8 "确定性写出"; AC-C8.3). See serialize() for why cells are not
## emitted as raw Vector2i.
func _serialize_cells(cells: Array[Vector2i]) -> Array:
	var out: Array = []
	for cell in cells:
		out.append([cell.x, cell.y])
	out.sort_custom(func(a: Array, b: Array): return a[1] < b[1] or (a[1] == b[1] and a[0] < b[0]))
	return out


## Two-stage deserialization (TR-GS-019, ADR-0002, GDD §C.8 rule 8).
##
## Phase A ("validate"): validates EVERY record against [buildable_snapshot]
## with ZERO mutation. Any record-level failure aborts the entire load —
## "no partial recovery" (AC-C8.9) is structural: when Phase A returns a
## failure, nothing has been written, so there is nothing to roll back.
##
## Phase B ("commit"): only reached when Phase A passed fully. Resets the
## grid to empty (occupancy + access + reverse index; buildable is level data
## and is NOT touched), replays every validated record, then emits grid_changed
## EXACTLY ONCE with the union of all committed cells (AC-C8.10).
##
## [buildable_snapshot] is the level's buildable mask (PackedByteArray, one
## byte per cell, row-major) injected by the level loader BEFORE this call —
## it is NOT part of the save data (TR-GS-020). deserialize() cross-validates
## the save against it (dimensions + per-cell buildable), catching
## save-vs-level mismatches (AC-C8.4..C8.6).
##
## [mode] is "validate" (Phase A only, zero mutation) or "commit" (Phase A +
## Phase B). Unknown modes are a programming error → INTERNAL_ERROR.
##
## Validation order (must run in this order — GDD §C.8):
##   1. schema_version exact match (MVP, no migration)      → CORRUPTED_SAVE
##   2. data.width/height == current grid dimensions         → LEVEL_GEOMETRY_MISMATCH
##      (AC-C8.6: returns immediately, no records processed)
##   3. per-record structural shape (ids, rotations, cells)  → CORRUPTED_SAVE
##   4. per-cell bounds, footprint AND access                → CORRUPTED_SAVE_OUT_OF_BOUNDS
##      (BEFORE any buildable_snapshot index or write — AC-C8.7)
##   5. per-cell buildable, footprint AND access             → LEVEL_GEOMETRY_MISMATCH
##      (AC-C8.4/C8.5 — access must be checked too, GDD rule 5 mirror)
##   6. footprint overlap across records (access overlap is
##      legal — AC-C8.8)                                     → CORRUPTED_SAVE_OVERLAP
##
## Strengthening checks (beyond the Story 007 sketch, documented not silent):
##   - negative instance_id (would collide with the -1 empty sentinel and
##     break clear() forever — same class as commit()'s AC-C7.7 rejection)
##   - duplicate instance_id (would orphan the first record's cells — same
##     class as commit()'s AC-C7.2 rejection)
##   - illegal rotation value (would store a state normal can_place() could
##     never produce — same class as AC-C8.5's "no impossible states" rule)
##   - empty footprint (declared_bounds() asserts non-empty, AC-D5.3)
##   - malformed cells (non-Vector2i/non-[x,y] values) → CORRUPTED_SAVE
## All map to CORRUPTED_SAVE: the save data is structurally corrupt.
##
## Rotation is NOT validated against the level (it's pure metadata) but IS
## validated for legality — a record storing rotation=45 would silently
## reintroduce the ADR-0003 quarter-turn/degree ambiguity on reload.
##
## Failures are returned, never push_error'd — corrupt saves and level
## mismatches are NORMAL gameplay outcomes, same convention as can_place()'s
## FAIL codes. push_error is reserved for programming errors (unknown mode,
## buildable_snapshot size mismatch, use-before-init).
func deserialize(data: Dictionary, buildable_snapshot: PackedByteArray, mode: String) -> DeserializeResult:
	if not _assert_initialized():
		return DeserializeResult.fail(ERR_INTERNAL_ERROR, "deserialize() called before init()")

	# Caller contract (level loader): snapshot must cover the full grid.
	# A too-short snapshot would make buildable_snapshot[...] read out of
	# bounds during validation — the same class of PackedArray OOB hazard
	# AC-C8.7 exists to prevent, so we reject it up front (INTERNAL_ERROR:
	# this is a programming error, not a save-data failure).
	if buildable_snapshot.size() != _width * _height:
		return DeserializeResult.fail(
			ERR_INTERNAL_ERROR,
			"buildable_snapshot size %d does not match grid %dx%d — level loader must inject width*height bytes (TR-GS-020)" % [buildable_snapshot.size(), _width, _height]
		)

	# ── Phase A: validate everything, mutate nothing ─────────────────

	# 1. Schema — MVP exact-match only (Story 007 / ADR-0002 version policy).
	if not data.has("schema_version") or int(data.get("schema_version", -1)) != 1:
		return DeserializeResult.fail(
			ERR_CORRUPTED_SAVE,
			"schema_version must be 1 (MVP exact-match, no migration); got %s" % str(data.get("schema_version", "<missing>"))
		)

	# 2. Dimension check — immediately, before any record is processed
	# (AC-C8.6). Missing dims = structurally corrupt save.
	if not data.has("width") or not data.has("height"):
		return DeserializeResult.fail(ERR_CORRUPTED_SAVE, "save data missing width/height")
	if int(data["width"]) != _width or int(data["height"]) != _height:
		return DeserializeResult.fail(
			ERR_LEVEL_GEOMETRY_MISMATCH,
			"grid dimensions differ — save %dx%d, current %dx%d" % [int(data["width"]), int(data["height"]), _width, _height]
		)

	if not data.has("records") or not (data["records"] is Array):
		return DeserializeResult.fail(ERR_CORRUPTED_SAVE, "save data missing 'records' array")

	var all_records: Array = data["records"]
	var all_fp_keys: Dictionary = {}  # "x,y" → instance_id (footprint overlap scan)
	var seen_ids: Dictionary = {}

	for i in all_records.size():
		var record = all_records[i]
		if not (record is Dictionary):
			return DeserializeResult.fail(ERR_CORRUPTED_SAVE, "record %d is not a Dictionary" % i)
		if not record.has("instance_id") or not record.has("footprint_cells") or not record.has("access_cells") or not record.has("rotation"):
			return DeserializeResult.fail(ERR_CORRUPTED_SAVE, "record %d missing required keys (instance_id/footprint_cells/access_cells/rotation)" % i)

		# Strengthening: id + rotation numeric, id >= 0, no duplicate ids.
		var id_val: Variant = record["instance_id"]
		if typeof(id_val) != TYPE_INT and typeof(id_val) != TYPE_FLOAT:
			return DeserializeResult.fail(ERR_CORRUPTED_SAVE, "record %d instance_id is not numeric: %s" % [i, str(id_val)])
		var instance_id := int(id_val)
		if instance_id < 0:
			return DeserializeResult.fail(ERR_CORRUPTED_SAVE, "record %d has negative instance_id %d (collides with the -1 empty sentinel)" % [i, instance_id])
		if seen_ids.has(instance_id):
			return DeserializeResult.fail(ERR_CORRUPTED_SAVE, "duplicate instance_id %d in save data" % instance_id)
		seen_ids[instance_id] = true

		var rot_val: Variant = record["rotation"]
		if typeof(rot_val) != TYPE_INT and typeof(rot_val) != TYPE_FLOAT:
			return DeserializeResult.fail(ERR_CORRUPTED_SAVE, "record %d rotation is not numeric: %s" % [i, str(rot_val)])
		var rotation := int(rot_val)
		if not _is_legal_rotation(rotation):
			return DeserializeResult.fail(ERR_CORRUPTED_SAVE, "record %d has illegal rotation %d (must be 0/90/180/270)" % [i, rotation])

		# Cell arrays must exist and footprint must be non-empty (AC-D5.3).
		var fp_raw: Variant = record["footprint_cells"]
		var ac_raw: Variant = record["access_cells"]
		if not (fp_raw is Array) or not (ac_raw is Array):
			return DeserializeResult.fail(ERR_CORRUPTED_SAVE, "record %d footprint_cells/access_cells must be arrays" % i)
		if (fp_raw as Array).is_empty():
			return DeserializeResult.fail(ERR_CORRUPTED_SAVE, "record %d has empty footprint_cells (equipment with no footprint is not legal)" % i)

		# 3+4. Bounds check (footprint AND access) — BEFORE any write and
		# BEFORE any buildable_snapshot index (AC-C8.7: no PackedArray OOB).
		var fp: Array[Vector2i] = []
		for raw_cell in fp_raw:
			if not _is_cell_shape_valid(raw_cell):
				return DeserializeResult.fail(ERR_CORRUPTED_SAVE, "record %d has malformed footprint cell %s" % [i, str(raw_cell)])
			var cell := _cell_from_variant(raw_cell)
			if not is_in_bounds(cell):
				return DeserializeResult.fail(ERR_CORRUPTED_SAVE_OUT_OF_BOUNDS, "record %d footprint cell %s out of bounds [0,%d)x[0,%d)" % [i, cell, _width, _height])
			fp.append(cell)

		var ac: Array[Vector2i] = []
		for raw_cell in ac_raw:
			if not _is_cell_shape_valid(raw_cell):
				return DeserializeResult.fail(ERR_CORRUPTED_SAVE, "record %d has malformed access cell %s" % [i, str(raw_cell)])
			var cell := _cell_from_variant(raw_cell)
			if not is_in_bounds(cell):
				return DeserializeResult.fail(ERR_CORRUPTED_SAVE_OUT_OF_BOUNDS, "record %d access cell %s out of bounds [0,%d)x[0,%d)" % [i, cell, _width, _height])
			ac.append(cell)

		# 5. Buildable check — footprint AND access (AC-C8.4/C8.5, GDD rule 5
		# mirror). Both must sit on buildable=true ground.
		for cell in fp:
			if buildable_snapshot[flat_index(cell)] == 0:
				return DeserializeResult.fail(ERR_LEVEL_GEOMETRY_MISMATCH, "record %d footprint on non-buildable cell %s" % [i, cell])
		for cell in ac:
			if buildable_snapshot[flat_index(cell)] == 0:
				return DeserializeResult.fail(ERR_LEVEL_GEOMETRY_MISMATCH, "record %d access on non-buildable cell %s" % [i, cell])

		# 6. Footprint overlap — access overlap is LEGAL (AC-C8.8). Duplicate
		# footprint cells within ONE record are also caught here (same "x,y"
		# key twice → overlap between the record and itself).
		for cell in fp:
			var key := "%d,%d" % [cell.x, cell.y]
			if all_fp_keys.has(key):
				return DeserializeResult.fail(
					ERR_CORRUPTED_SAVE_OVERLAP,
					"footprint overlap at %s between ids %d and %d" % [cell, all_fp_keys[key], instance_id]
				)
			all_fp_keys[key] = instance_id

	if mode == "validate":
		return DeserializeResult.ok()  # validated, zero mutation

	if mode == "commit":
		# ── Phase B: commit — all records validated, safe to write ──
		var had_state := not _reverse_index.is_empty()
		_clear_all()  # silent reset; the single signal below covers the change

		var all_fp: Array[Vector2i] = []
		var all_ac: Array[Vector2i] = []
		for record in all_records:
			var instance_id := int(record["instance_id"])
			var fp := _cells_from_variant_array(record["footprint_cells"])
			var ac := _cells_from_variant_array(record["access_cells"])
			_write_record(instance_id, fp, ac, int(record["rotation"]))
			all_fp.append_array(fp)
			all_ac.append_array(ac)

		# Single signal for the entire load (AC-C8.10) — payload is the union
		# of all committed cells. A completely empty load into an already-empty
		# grid emits nothing (nothing changed — Story 007 QA edge case);
		# emptying a populated grid DOES emit (the clear is a real change).
		if had_state or not all_records.is_empty():
			grid_changed.emit(all_fp, all_ac)
		return DeserializeResult.ok()

	return DeserializeResult.fail(ERR_INTERNAL_ERROR, "unknown deserialize mode: %s" % mode)


## Returns true if [v] is a cell-shaped value: a Vector2i, or an Array of
## exactly two numbers ([x, y] — the JSON-safe encoding). Anything else is a
## structurally corrupt save (CORRUPTED_SAVE).
func _is_cell_shape_valid(v: Variant) -> bool:
	if v is Vector2i:
		return true
	if not (v is Array) or (v as Array).size() != 2:
		return false
	var arr: Array = v
	for component in arr:
		if typeof(component) != TYPE_INT and typeof(component) != TYPE_FLOAT:
			return false
	return true


## Converts a cell-shaped variant to Vector2i. Accepts both the JSON-safe
## [x, y] int/float array encoding (JSON.parse_string returns floats for all
## numbers — probed in 4.7.1) and a raw Vector2i (in-memory round-trip).
## Caller MUST have passed _is_cell_shape_valid() first.
func _cell_from_variant(v: Variant) -> Vector2i:
	if v is Vector2i:
		return v
	var arr: Array = v
	return Vector2i(int(arr[0]), int(arr[1]))


## Batch conversion for Phase B — every element already passed
## _is_cell_shape_valid() in Phase A.
func _cells_from_variant_array(cells: Array) -> Array[Vector2i]:
	var out: Array[Vector2i] = []
	for v in cells:
		out.append(_cell_from_variant(v))
	return out


## Resets all placement state to empty: occupancy → -1, access_ids cleared,
## reverse index cleared. buildable is deliberately NOT touched (level
## geometry, frozen after load). Silent — deserialize() emits its single
## grid_changed after the whole batch, never per-record.
func _clear_all() -> void:
	for i in _occupant_id.size():
		_occupant_id[i] = -1
	_access_ids.clear()
	_reverse_index.clear()


## Writes one already-validated record into the occupancy/access/reverse-index
## state. Phase B helper — no re-validation (Phase A already established
## legality; GDD §C.8 step 7: "直接写...不需要重新判定合法性"). Access ids are
## deduplicated per cell, matching commit()'s write semantics. Silent — the
## single grid_changed for the whole load is emitted by deserialize().
func _write_record(instance_id: int, footprint_cells: Array[Vector2i], access_cells: Array[Vector2i], rotation: int) -> void:
	for fc in footprint_cells:
		_occupant_id[flat_index(fc)] = instance_id
	for ac in access_cells:
		if _access_ids.has(ac):
			var arr: Array = _access_ids[ac]
			if not arr.has(instance_id):
				arr.append(instance_id)
		else:
			_access_ids[ac] = [instance_id]
	_reverse_index[instance_id] = PlacementRecord.new(footprint_cells, access_cells, rotation)

# === Geometry Helpers ===

## Returns true if [cell] is within [0, width) × [0, height).
func is_in_bounds(cell: Vector2i) -> bool:
	if not _assert_initialized():
		return false
	return cell.x >= 0 and cell.x < _width and cell.y >= 0 and cell.y < _height


## Returns the grid dimensions as (width, height).
func get_dimensions() -> Vector2i:
	if not _assert_initialized():
		return Vector2i.ZERO
	return Vector2i(_width, _height)


## Converts a 2D cell coordinate to a flat array index.
## Uses row-major order: flat_index = row * width + col.
## Callers must bounds-check with is_in_bounds() first — this method does
## not validate the cell and returns -1 (never a valid index) if called
## before init().
func flat_index(cell: Vector2i) -> int:
	if not _assert_initialized():
		return -1
	return cell.y * _width + cell.x


# === Coordinate Conversion ===
#
# [cell_size] is a required parameter on every method below — NEVER a
# hardcoded constant. The project's final cell_size value is not yet
# decided (GDD D.4 handoff note: 16 or 32px, finalized at architecture
# stage). GridSystem's occupancy/solidity/rotation logic never depends on
# this value; it exists purely for presentation-layer grid<->world math.

## Converts a grid cell to the world-space position of its top-left corner.
## Formula (GDD D.4): grid_to_world_corner(cell) = cell * cell_size.
## Example: grid_to_world_corner(Vector2i(5, 3), 32) == Vector2(160, 96)
func grid_to_world_corner(cell: Vector2i, cell_size: int) -> Vector2:
	if not _assert_initialized():
		return Vector2.ZERO
	return Vector2(cell.x * cell_size, cell.y * cell_size)


## Converts a grid cell to the world-space position of its center point.
## Formula (GDD D.4): grid_to_world_center(cell) = cell * cell_size + cell_size/2.
## Example: grid_to_world_center(Vector2i(5, 3), 32) == Vector2(176, 112)
func grid_to_world_center(cell: Vector2i, cell_size: int) -> Vector2:
	if not _assert_initialized():
		return Vector2.ZERO
	var half := cell_size / 2.0
	return Vector2(cell.x * cell_size + half, cell.y * cell_size + half)


## Converts a world-space position to a grid cell coordinate.
## Formula (GDD D.4): world_to_grid(world_pos) = floor(world_pos / cell_size).
##
## DELIBERATELY DIFFERENT out-of-bounds contract than the query methods
## above (get_occupant_id, get_buildable, is_solid, etc.): this returns the
## raw floor-division result with NO clamping, NO push_error(), and NO
## sentinel. An out-of-bounds result (e.g. (-1,-1)) is normal and expected —
## the mouse leaving the room during a drag produces one every frame.
## Callers MUST bounds-check the result themselves (e.g. via is_in_bounds())
## before feeding it to flat_index(), is_solid(), or can_place(). See GDD
## D.4 for the full rationale for this asymmetry with the D.2 query contract.
## Example: world_to_grid(Vector2(170, 100), 32) == Vector2i(5, 3)
func world_to_grid(world_pos: Vector2, cell_size: int) -> Vector2i:
	if not _assert_initialized():
		return Vector2i.ZERO
	return Vector2i(floori(world_pos.x / cell_size), floori(world_pos.y / cell_size))


# === Footprint Transform ===

## Rotates a single canonical-space cell offset (x, y) into its post-rotation
## offset, per GDD D.1's 4-branch formula:
##   R0:   (x, y)
##   R90:  (H-1-y, x)
##   R180: (W-1-x, H-1-y)
##   R270: (y, W-1-x)
##
## (W, H) MUST be the declared_bounds() of the FULL footprint+access UNION
## (TR-GS-012/013) — never a per-shape local bounding box computed
## independently for footprint vs. access. Passing mismatched (W, H) values
## for the footprint and access transforms is exactly the bug this system's
## highest-risk rule exists to prevent (AC-C4.3): it produces negative
## coordinates at 90/270 degrees, invisible at 0/180 degrees (symmetry masks
## it there).
##
## Illegal rotation values fall through to the `_:` branch and assert(false)
## (AC-D1.1, TR-GS-029) — NEVER a silent fallthrough to the R0 case.
func _transform_cell(x: int, y: int, rot: Rotation, W: int, H: int) -> Vector2i:
	match rot:
		Rotation.R0:
			return Vector2i(x, y)
		Rotation.R90:
			return Vector2i(H - 1 - y, x)
		Rotation.R180:
			return Vector2i(W - 1 - x, H - 1 - y)
		Rotation.R270:
			return Vector2i(y, W - 1 - x)
		_:
			# assert(false) aborts the REST OF THIS FUNCTION FRAME when it
			# fires (verified empirically — see get_transformed_cells()'s
			# guard comment for the full finding). The `return Vector2i.ZERO`
			# below never executes in that case; the frame's own abort yields
			# Vector2i's zero-value default instead, which is harmless here
			# only because Vector2i is a value type, not an Object (an
			# Object-typed return would yield null and crash the caller —
			# see get_transformed_cells(), which is why that method does NOT
			# use assert() in its guard).
			#
			# Unreachable via the only current call site: get_transformed_cells()
			# rejects illegal rotations via _is_legal_rotation() before calling
			# this method at all. This branch is defense-in-depth against a
			# future direct/private caller, and is what literally satisfies
			# TR-GS-029's "exhaust 4 branches + assert(false) fallback" wording.
			assert(false, "GridSystem: illegal rotation value: %s" % rot)
			return Vector2i.ZERO


## Returns true if [rot] is one of the four legal Rotation enum values.
##
## GDScript does not enforce enum membership at runtime — an int outside the
## enum passes straight through a `rotation: Rotation` parameter. This is the
## real gate for TR-GS-029 ("never a silent fallthrough"), because assert()
## alone cannot stop execution in Godot 4.7.1.
func _is_legal_rotation(rot: int) -> bool:
	return rot == Rotation.R0 or rot == Rotation.R90 or rot == Rotation.R180 or rot == Rotation.R270


## Returns the minimum (x, y) offset across [cells], or Vector2i.ZERO for an
## empty array. Used only to check the anchor convention in declared_bounds().
func _min_offset(cells: Array[Vector2i]) -> Vector2i:
	if cells.is_empty():
		return Vector2i.ZERO
	var min_x := cells[0].x
	var min_y := cells[0].y
	for c in cells:
		min_x = min(min_x, c.x)
		min_y = min(min_y, c.y)
	return Vector2i(min_x, min_y)


## Computes the declared bounding box (W, H) of the UNION of [footprint_cells]
## and [access_cells], per GDD D.5:
##   W = max_x + 1, H = max_y + 1  (over footprint_cells UNION access_cells)
##
## This union — not footprint_cells alone — is the (W, H) that
## get_transformed_cells() must pass to BOTH the footprint AND access
## rotation transforms (TR-GS-013). See _transform_cell()'s doc comment for
## why mixing this up is this system's highest-risk bug.
##
## Deviation from ADR-0003's illustrative sketch (documented, not silent):
## the ADR's declared_bounds(equipment_def: EquipmentDef) takes a catalog
## object. EquipmentDef does not exist in src/ yet (equipment-catalog epic is
## out of this sprint's scope) — this signature takes raw typed cell arrays
## instead, matching the existing get_transformed_cells() style. See the
## tech-debt register for the consequence: this signature can no longer
## structurally prevent an external caller from requesting a footprint-only
## bbox (e.g. by passing an empty access_cells) the way the ADR's
## equipment_def-only signature could.
##
## Debug-only asserts (compiled out of release builds — GDD D.5):
##   - the combined cell set must not be empty (AC-D5.3)
##   - the minimum (x, y) across the combined set must be (0, 0) — the
##     anchor convention (AC-D5.2, TR-GS-011). Violated only by un-normalized
##     equipment data; EquipmentCatalog's load-time validation is the real
##     gate in production (this assert is a debug-only backstop for hand-
##     crafted test fixtures).
##
## If either assert fires, it aborts the rest of THIS function frame (see
## get_transformed_cells()'s guard comment for why that matters) and the
## caller receives Vector2i.ZERO instead of a real bounding box — safe here
## specifically because Vector2i is a value type (no null-dereference risk),
## consistent with this file's other value-typed safe defaults
## (get_dimensions(), grid_to_world_corner(), etc. before init()).
## Usage example:
##   var wh := grid_system.declared_bounds(
##       [Vector2i(0, 0), Vector2i(0, 1)], [Vector2i(0, 2)]
##   )
##   # wh == Vector2i(1, 3)
func declared_bounds(footprint_cells: Array[Vector2i], access_cells: Array[Vector2i]) -> Vector2i:
	if not _assert_initialized():
		return Vector2i.ZERO

	var all_cells: Array[Vector2i] = footprint_cells + access_cells
	# Checks footprint_cells specifically, NOT the union: equipment with zero
	# access cells is legal (decorative/storage pieces — see Story 004's
	# AC-C5.5), but equipment with no footprint is not. Asserting on the union
	# would let an empty footprint slip through whenever access_cells happened
	# to be non-empty (AC-D5.3).
	assert(not footprint_cells.is_empty(), "GridSystem: declared_bounds() footprint_cells must not be empty.")
	assert(
		_min_offset(all_cells) == Vector2i.ZERO,
		"GridSystem: declared_bounds() cells violate the anchor convention — union bounding box must start at (0,0)."
	)

	var max_x := 0
	var max_y := 0
	for c in all_cells:
		max_x = max(max_x, c.x)
		max_y = max(max_y, c.y)
	return Vector2i(max_x + 1, max_y + 1)


## Transforms canonical (0 degree) footprint and access cells into
## world-space cells for the given anchor and rotation, returning a
## TransformedFootprint (TR-GS-014).
##
## THE CRITICAL RULE (TR-GS-012/013, AC-C4.3 — this system's single
## highest-risk rule): (W, H) is computed ONCE via declared_bounds() over
## footprint_cells UNION access_cells, and that SAME (W, H) is passed to
## BOTH the footprint transform and the access transform below. Never let
## each transform derive its own local bounding box — that produces negative
## coordinates at 90/270 degrees, and 0/180-degree tests alone cannot catch
## the bug because symmetry masks it there.
##
## Debug-only asserts (compiled out of release, GDD D.5) surface via the
## declared_bounds() call: empty footprint_cells (AC-D5.3) and
## anchor-convention violations (AC-D5.2). Illegal rotation values
## assert(false) inside _transform_cell() (AC-D1.1).
##
## Usage example:
##   var result := grid_system.get_transformed_cells(
##       [Vector2i(0, 0), Vector2i(0, 1)], [Vector2i(0, 2)],
##       Vector2i(3, 3), GridSystem.Rotation.R90
##   )
##   # result.footprint_cells == [Vector2i(5, 3), Vector2i(4, 3)]
##   # result.access_cells == [Vector2i(3, 3)]
##   # result.new_size == Vector2i(3, 1)
func get_transformed_cells(
	footprint_cells: Array[Vector2i],
	access_cells: Array[Vector2i],
	anchor: Vector2i,
	rotation: Rotation
) -> TransformedFootprint:
	var result := TransformedFootprint.new()

	if not _assert_initialized():
		return result

	# Illegal rotation is rejected UP FRONT, before any cell is transformed
	# (TR-GS-029, AC-D1.1).
	#
	# CORRECTED UNDERSTANDING of Godot 4.7.1's assert() (the first version of
	# this guard got this wrong): assert(false, msg) aborts the REMAINDER OF
	# THE CURRENT FUNCTION FRAME when it fires — no statement textually after
	# it in the same function runs, including a `return`. It does NOT
	# terminate the process (the caller's caller keeps running), but within
	# THIS frame, an assert(false) immediately followed by `return result`
	# would make `return result` unreachable dead code. Verified empirically
	# with an isolated repro: a function with an Object-typed return calling
	# assert(false) then attempting to return a constructed value instead
	# returns null to its caller. That is worse than a silent fallthrough —
	# it is a crash waiting to happen the moment the caller dereferences the
	# result, exactly what happened here on the first pass (caught by
	# /code-review, not by the author).
	#
	# Therefore: NO assert() call in this reachable, public-API guard. Only
	# push_error() (which logs without aborting the frame, in both debug AND
	# release builds — unlike assert(), it isn't compiled out) followed by a
	# guaranteed `return result` with the empty, valid, non-null
	# TransformedFootprint constructed at the top of this function. This
	# matches the file's established "loud failure + unusable safe default"
	# contract (cf. is_solid() returning true out of bounds, get_occupant_id()
	# returning -1) using a mechanism that actually delivers on it.
	#
	# _transform_cell()'s own assert(false) fallback branch (TR-GS-029's
	# literal "assert(false) fallback" requirement) is preserved below as
	# defense-in-depth — but this guard makes that branch UNREACHABLE via the
	# only current call path (this method). It exists for any future direct
	# caller of the private _transform_cell(), not for this method's contract.
	if not _is_legal_rotation(rotation):
		push_error("GridSystem: get_transformed_cells() rejected illegal rotation value: %s" % rotation)
		return result

	# THE CRITICAL RULE: (W,H) computed ONCE here, then passed to BOTH loops
	# below. See this method's doc comment and _transform_cell()'s doc
	# comment — never let footprint and access each derive their own bbox.
	var wh := declared_bounds(footprint_cells, access_cells)
	var w := wh.x
	var h := wh.y

	for cell in footprint_cells:
		result.footprint_cells.append(anchor + _transform_cell(cell.x, cell.y, rotation, w, h))
	for cell in access_cells:
		result.access_cells.append(anchor + _transform_cell(cell.x, cell.y, rotation, w, h))

	result.new_size = Vector2i(h, w) if (rotation == Rotation.R90 or rotation == Rotation.R270) else Vector2i(w, h)

	return result


# === Placement Validation ===

## Pure read-only placement validation (TR-GS-015, GDD C.6, Story 004).
##
## Checks whether an equipment with the given canonical (0-degree) footprint
## and access cells, placed at [anchor] with [rotation], is legal on this
## grid. Returns a PlacementCheckResult; valid=true only when every check
## passes (fail_code == FailCode.VALID).
##
## Check sequence — MUST run in this order, early-exit on first failure
## (GDD C.6 §6, ADR-0003):
##   1. Transform canonical cells to world space via get_transformed_cells()
##      (same call both footprint AND access must share — see that method).
##   2. For each footprint cell fc:
##      a. fc in bounds            -> else FAIL: OUT_OF_BOUNDS
##      b. buildable[fc] == true   -> else FAIL: BLOCKED_BY_ROOM_GEOMETRY
##      c. occupant_id[fc] == -1   -> else FAIL: OVERLAPS_EXISTING_EQUIPMENT
##   3. For each access cell ac:
##      a. ac in bounds            -> else FAIL: ACCESS_OUT_OF_BOUNDS
##      b. buildable[ac] == true   -> else FAIL: ACCESS_BLOCKED_BY_ROOM_GEOMETRY
##      c. DO NOT check occupant_id / access_ids — access-on-footprint and
##         access-on-access are allowed by design (AC-C5.2/C5.4, TR-GS-016).
##   4. All pass -> {valid: true, fail_code: VALID}
##
## PURE FUNCTION CONTRACT (AC-C6.5): can_place() must NOT modify any grid
## state, must NOT emit grid_changed, and must NOT push_error for any of the
## 5 expected FAIL codes (those are normal gameplay outcomes). push_error is
## reserved for programming errors only (use-before-init; empty footprint
## input, which would otherwise hit declared_bounds()'s debug assert).
##
## Deviation from ADR-0003's illustrative sketch (documented, not silent):
## the ADR signature is can_place(def: EquipmentDef, ...). EquipmentDef does
## not exist in src/ yet (equipment-catalog epic is out of this sprint's
## scope) — this signature takes raw typed cell arrays instead, matching the
## existing get_transformed_cells() style. See declared_bounds()'s doc
## comment for the same deviation and its tech-debt consequence.
## Rotation is typed as the degree-valued Rotation enum (0/90/180/270),
## consistent with get_transformed_cells() — NOT the quarter-turn int that
## ADR-0003's sketch implies. See the Rotation enum's doc comment for the
## open degree-vs-quarter-turn reconciliation note.
##
## Before-init safe default: {valid: false, fail_code: OUT_OF_BOUNDS} — a
## 0×0 grid can contain nothing. Matches the file's "loud failure + unusable
## safe default" contract (cf. get_occupant_id() returning -1).
func can_place(
	footprint_cells: Array[Vector2i],
	access_cells: Array[Vector2i],
	anchor: Vector2i,
	rotation: Rotation
) -> PlacementCheckResult:
	var result := PlacementCheckResult.new()

	if not _assert_initialized():
		result.fail_code = FailCode.OUT_OF_BOUNDS
		return result

	# Empty footprint is a programming error — declared_bounds() would
	# assert on it in debug builds (AC-D5.3); here it gets a loud push_error
	# plus the documented safe default. Access cells MAY be empty (AC-C5.5).
	if footprint_cells.is_empty():
		push_error("GridSystem: can_place() rejected — footprint_cells must not be empty.")
		result.fail_code = FailCode.OUT_OF_BOUNDS
		return result

	# Illegal rotation values are rejected inside get_transformed_cells()
	# (push_error + empty TransformedFootprint). We must not treat that
	# empty result as a legal placement — the footprint check loop below
	# would vacuously pass. Reject here with the documented safe default.
	# (get_transformed_cells() already push_errored; no second error needed.)
	if not _is_legal_rotation(rotation):
		result.fail_code = FailCode.OUT_OF_BOUNDS
		return result

	var transformed := get_transformed_cells(footprint_cells, access_cells, anchor, rotation)

	for fc in transformed.footprint_cells:
		if not is_in_bounds(fc):
			result.fail_code = FailCode.OUT_OF_BOUNDS
			result.fail_cell = fc
			return result
		if not get_buildable(fc):
			result.fail_code = FailCode.BLOCKED_BY_ROOM_GEOMETRY
			result.fail_cell = fc
			return result
		# Explicit != -1, never a truthy check — occupant_id=0 is legal.
		if get_occupant_id(fc) != -1:
			result.fail_code = FailCode.OVERLAPS_EXISTING_EQUIPMENT
			result.fail_cell = fc
			return result

	# Access cells: geometric hard constraints only (bounds + buildable).
	# Deliberately NO occupant_id / access_ids check — sharing access cells
	# and access-on-footprint are legal by design (AC-C5.2/C5.4, TR-GS-016).
	for ac in transformed.access_cells:
		if not is_in_bounds(ac):
			result.fail_code = FailCode.ACCESS_OUT_OF_BOUNDS
			result.fail_cell = ac
			return result
		if not get_buildable(ac):
			result.fail_code = FailCode.ACCESS_BLOCKED_BY_ROOM_GEOMETRY
			result.fail_cell = ac
			return result

	result.valid = true
	result.fail_code = FailCode.VALID
	return result
