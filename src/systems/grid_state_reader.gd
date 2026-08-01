## GridStateReader — read-only abstract base class for any grid state
## (TR-GS-024, ADR-0003, Story 006).
##
## Defines the shared read contract consumed by ZoneRules.evaluate(),
## Satisfaction, Congestion, and placement-preview UI. Two concrete
## implementations exist:
##   - GridSystem   (the real grid; write methods live ONLY here)
##   - GridSnapshot (a speculative view over delta dicts; no writes to real state)
## ZoneRules.evaluate(snapshot: GridStateReader) is typed to this abstract
## base, so it cannot distinguish real from speculative (TR-GS-025).
##
## HIERARCHY — DEVIATION FROM STORY SKETCH (documented, not silent):
## The Story 006 sketch shows `class_name GridStateReader extends RefCounted`,
## but ADR-0003 (the governing implementation ADR this story cites) mandates
## the chain RefCounted → SimSystem → GridStateReader → GridSystem/GridSnapshot:
## GridSystem is a concrete simulation system that MUST keep SimSystem's
## two-phase init machinery (_mark_initialized/_assert_initialized/system_name)
## through a single inheritance chain (ADR-0003 §1 hierarchy diagram). Extending
## RefCounted directly would strip GridSystem of that machinery and break the
## tech-debt #1 resolution (GridSystem should extend GridStateReader, not
## SimSystem — with GridStateReader INSERTED between SimSystem and GridSystem).
##
## @ABSTRACT IS NON-FUNCTIONAL ON RefCounted IN 4.7.1 (verified — see
## ADR-0001 / ADR-0003 engine notes; @abstract only works on Node/Control).
## Fallback protocol (GDD OQ#3): every abstract method carries push_error() +
## a safe default return value, so an override omission is LOUD and safe, never
## silent. A manual _init() guard blocks direct instantiation. If a future
## Godot makes @abstract work on RefCounted, these stubs can be replaced with
## @abstract decorators.
class_name GridStateReader extends SimSystem

## Manual guard — @abstract is non-functional on RefCounted in 4.7.1.
## Subclasses never override _init(), so this always runs on construction;
## get_script() returns this base class only when GridStateReader itself is
## instantiated directly. (SimSystem._init()'s own guard likewise never fires
## for subclasses — get_script() returns the most-derived script.)
func _init() -> void:
	if get_script() == GridStateReader:
		push_error("GridStateReader is abstract — do not instantiate directly")


## Read-only contract methods — subclasses MUST override. Each stub pushes an
## error and returns a conservative safe default if an override is missing,
## per the OQ#3 fallback protocol.

## Returns whether [cell] is solid — impassable for pathfinding.
## Safe default: true ("outside is solid" — prevents pathing into void).
func is_solid(cell: Vector2i) -> bool:
	push_error("GridStateReader.is_solid not overridden by subclass")
	return true


## Returns the occupant_id at [cell], or -1 if the cell is empty.
func get_occupant_id(cell: Vector2i) -> int:
	push_error("GridStateReader.get_occupant_id not overridden by subclass")
	return -1


## Returns the access cells registered for [instance_id] (transformed,
## anchor-offset), or [] if the instance is unknown / has no access cells.
func get_access_cells(instance_id: int) -> Array[Vector2i]:
	push_error("GridStateReader.get_access_cells not overridden by subclass")
	return []


## Returns the grid dimensions as (width, height).
func get_dimensions() -> Vector2i:
	push_error("GridStateReader.get_dimensions not overridden by subclass")
	return Vector2i.ZERO


## Returns all currently placed equipment instances as typed DTOs.
## Order is stable within a single grid state version but not guaranteed
## across commits (ADR-0003) — consumers must not depend on insertion order.
func get_placed_instances() -> Array[PlacedInstance]:
	push_error("GridStateReader.get_placed_instances not overridden by subclass")
	return []
