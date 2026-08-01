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
## Extends SimSystem (ADR-0001 two-phase init pattern). Injected via
## SimulationOrchestrator, never accessed through Autoload/singleton.
##
## In the future, GridStateReader will be inserted as an intermediate
## base class between SimSystem and GridSystem (Story 006).
class_name GridSystem extends SimSystem


## Rotation values usable when placing equipment (GDD D.1, TR-GS-029).
## Degree-valued (0/90/180/270) to match the D.1 rotation formula directly.
##
## NOTE -- deliberate discrepancy, not yet reconciled (see tech-debt register):
## ADR-0003's illustrative PlacedInstance.rotation sketch uses quarter-turn
## count (0,1,2,3) instead of degrees. PlacedInstance does not exist yet
## (Story 006) and neither does the commit-time caller that would set
## rotation (Story 005) -- whoever builds those must explicitly decide how
## this enum's degree values map to that convention. Do not silently assume.
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
