## GridSystem — core cell data model for the gym floor grid.
##
## Stores three orthogonal dimensions per cell:
##   - occupant_id: PackedInt32Array, indexed by flat_index (y * width + x)
##     -1 = empty sentinel. 0 is a legal occupant_id (first piece placed).
##   - buildable: PackedByteArray, same flat_index scheme, 0/1 values.
##     Set once during level load, then frozen (read-only during gameplay).
##   - access_ids: Dictionary[int, Array] — sparse, keyed by flat_index.
##     Multiple occupant_ids can share the same access cell.
##
## occupant_id and access_ids are completely independent — one never
## affects the other. GridSystem stores only integer occupant_id,
## never equipment type or zone membership.
##
## Extends SimSystem (RefCounted-based). Injected via SimulationOrchestrator,
## never accessed through Autoload/singleton.
class_name GridSystem extends SimSystem


# === Storage (private — never expose as public API) ===

var _occupant_id: PackedInt32Array = []
var _buildable: PackedByteArray = []
var _access_ids: Dictionary = {}  # Vector2i → Array[int] (occupant_ids)
var _width: int = 0
var _height: int = 0
var _buildable_frozen: bool = false


# === Lifecycle ===

## Initializes grid storage for the given dimensions.
## Allocates PackedInt32Array and PackedByteArray at width * height.
## occupant_id cells default to -1 (empty). buildable cells default to 0.
func init(grid_width: int, grid_height: int) -> void:
	super.init()
	_width = grid_width
	_height = grid_height
	var size := _width * _height
	_occupant_id.resize(size)
	_buildable.resize(size)
	for i in size:
		_occupant_id[i] = -1
		_buildable[i] = 0
	_access_ids.clear()
	_buildable_frozen = false


func _post_init() -> void:
	pass


# === Read Methods ===

## Returns the occupant_id at [cell], or -1 if the cell is empty.
## This read is completely independent of buildable state —
## setting buildable=false on a cell does not affect get_occupant_id().
func get_occupant_id(cell: Vector2i) -> int:
	_assert_initialized()
	if not is_in_bounds(cell):
		return -1
	return _occupant_id[flat_index(cell)]


## Returns whether [cell] is flagged as buildable.
## buildable is static after level load — set once, then frozen.
func get_buildable(cell: Vector2i) -> bool:
	_assert_initialized()
	if not is_in_bounds(cell):
		return false
	return _buildable[flat_index(cell)] != 0


## Returns the list of occupant_ids that have [cell] registered as
## their access cell. Returns an empty array if this cell is not
## anyone's access cell.
func get_access_ids(cell: Vector2i) -> Array:  # Array[int]
	_assert_initialized()
	if _access_ids.has(cell):
		return (_access_ids[cell] as Array).duplicate()
	return []


# === Buildable Setup (level load only) ===

## Sets the buildable flag for a single cell.
## Must be called BEFORE freeze_buildable() — after the level is loaded,
## this method push_errors and no-ops to enforce immutability.
func set_buildable(cell: Vector2i, value: bool) -> void:
	_assert_initialized()
	if _buildable_frozen:
		push_error("GridSystem: set_buildable() called after level load. Buildable state is frozen.")
		return
	if not is_in_bounds(cell):
		push_error("GridSystem: set_buildable() called on out-of-bounds cell %s." % cell)
		return
	_buildable[flat_index(cell)] = 1 if value else 0


## Sets buildable for multiple cells at once. Same freeze check as set_buildable().
func set_buildable_bulk(cells: Array, value: bool) -> void:
	_assert_initialized()
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
	_assert_initialized()
	_buildable_frozen = true


# === Occupant ID Operations ===

## Commits [occupant_id] to [cell]. Returns true on success.
## Returns false if the cell already has an occupant (mutually-exclusive
## single-value semantics — see TR-GS-008).
##
## occupant_id = 0 is legal (first piece placed). The empty check uses
## explicit comparison against -1, never truthiness.
func commit_occupant(cell: Vector2i, occupant_id: int) -> bool:
	_assert_initialized()
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
	_assert_initialized()
	if not is_in_bounds(cell):
		push_error("GridSystem: clear_occupant() on out-of-bounds cell %s." % cell)
		return
	_occupant_id[flat_index(cell)] = -1


# === Access ID Operations ===

## Registers [occupant_id] as having [cell] as an access cell.
## Multiple occupant_ids can share the same access cell
## (non-mutually-exclusive multi-value semantics — see TR-GS-009).
func commit_access(cell: Vector2i, occupant_id: int) -> void:
	_assert_initialized()
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
	_assert_initialized()
	if not is_in_bounds(cell):
		push_error("GridSystem: clear_access() on out-of-bounds cell %s." % cell)
		return
	if not _access_ids.has(cell):
		return
	var arr: Array = _access_ids[cell]
	arr.erase(occupant_id)
	if arr.is_empty():
		_access_ids.erase(cell)


# === Geometry Helpers ===

## Returns true if [cell] is within [0, width) × [0, height).
func is_in_bounds(cell: Vector2i) -> bool:
	_assert_initialized()
	return cell.x >= 0 and cell.x < _width and cell.y >= 0 and cell.y < _height


## Returns the grid dimensions as (width, height).
func get_dimensions() -> Vector2i:
	_assert_initialized()
	return Vector2i(_width, _height)


## Converts a 2D cell coordinate to a flat array index.
## Uses row-major order: flat_index = row * width + col.
func flat_index(cell: Vector2i) -> int:
	return cell.y * _width + cell.x


# === Footprint Transform ===

## Transforms canonical footprint and access cells to world coordinates
## given an anchor cell and rotation.
##
## Returns a Dictionary with "footprint" (Array[Vector2i]) and "access"
## (Array[Vector2i]) keys.
##
## At rotation=0°, world_cell = anchor + canonical_cell.
## Full 4-branch rotation transform is Story 003 — this implements the
## 0° case only, sufficient for AC-C3.1.
func get_transformed_cells(
	footprint: Array,   # Array[Vector2i] — canonical (0°) footprint cells
	access: Array,      # Array[Vector2i] — canonical (0°) access cells
	anchor: Vector2i,
	rotation: int       # 0, 90, 180, 270
) -> Dictionary:
	_assert_initialized()

	var transformed_footprint: Array[Vector2i] = []
	var transformed_access: Array[Vector2i] = []

	if rotation == 0:
		for cell in footprint:
			transformed_footprint.append(anchor + (cell as Vector2i))
		for cell in access:
			transformed_access.append(anchor + (cell as Vector2i))
	else:
		# Full 4-branch rotation is Story 003 — for now, push_error
		# on unsupported rotations to prevent silent incorrect behavior.
		push_error("GridSystem: get_transformed_cells() only supports rotation=0° in Story 001. Full rotation is Story 003.")

	return {
		"footprint": transformed_footprint,
		"access": transformed_access,
	}
