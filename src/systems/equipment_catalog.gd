## EquipmentCatalog — immutable, read-only container of EquipmentDef records
## (equipment-catalog epic, Story 001; TR-EC-005/010; GDD Core Rule 2).
##
## Loaded ONCE at session startup by the JSON loader (Story 002) via the
## internal two-phase API (_add_definition()..._freeze()), then FROZEN for the
## rest of the session. After freeze the ONLY public surface is the three
## read-only queries below — there are no setters/mutators on the public API
## (AC-C.8, static-code-checkable), and every public method guards against
## use-before-freeze with push_error() (AC-FROZEN.1, Control Manifest
## guardrail: "Catalog.is_frozen check on every public method").
##
## No Autoload — the instance is owned by SimulationOrchestrator and injected
## into consumers (ADR-0001, TR-EC-010). It is a plain RefCounted per the
## Story 001 sketch (it is an external data source, not a simulation system;
## ADR-0001 explicitly leaves its type to this system's ADR/story).
##
## AC-IMMUTABLE.1 defensive posture: get_definition() returns a DEEP COPY of
## the stored record (not the shared instance) — a caller that mutates the
## returned EquipmentDef (e.g. appends to footprint_cells) can never corrupt
## the stored definition. This is a deliberate strengthening over the Story 001
## sketch, which returned the stored instance directly: the sketch as-written
## fails BLOCKING AC-IMMUTABLE.1's literal requirement ("caller modifies any
## field of the returned instance -> stored definition unaffected"), so
## copy-on-return is the resolution sanctioned by the AC's own
## "(deep copy or immutable-by-convention)" clause.
class_name EquipmentCatalog extends RefCounted

## String id -> EquipmentDef. Insertion-ordered (GDScript Dictionary), so
## get_all_ids() returns loader insertion order = file order (deterministic).
var _definitions: Dictionary = {}

## Set by _freeze(). Kept for future introspection of the load lifecycle
## (Unloaded -> Validating -> Loaded, GDD States and Transitions); queries
## guard on _is_frozen, which _freeze() sets together with this flag.
var _is_loaded: bool = false

## True once _freeze() completes. All public queries reject calls while
## false with push_error() (AC-FROZEN.1).
var _is_frozen: bool = false


## Returns a DEEP COPY of the EquipmentDef for the given id, or null (with
## push_error()) if the catalog is not yet frozen or the id is unknown.
## Repeated queries for the same id return value-equal copies (AC-C.8).
func get_definition(equipment_id: String) -> EquipmentDef:
	if not _is_frozen:
		push_error("EquipmentCatalog: get_definition() called before freeze()")
		return null
	if not _definitions.has(equipment_id):
		push_error("EquipmentCatalog: no definition for id '%s'" % equipment_id)
		return null
	return _definitions[equipment_id].duplicate_def()


## Returns true iff the given id exists in the catalog. Rejects calls before
## freeze() with push_error() (returns false) — every public method carries
## the is_frozen guard per the Control Manifest guardrail.
func has_definition(equipment_id: String) -> bool:
	if not _is_frozen:
		push_error("EquipmentCatalog: has_definition() called before freeze()")
		return false
	return _definitions.has(equipment_id)


## Returns all definition ids, in loader insertion order (file order).
## Rejects calls before freeze() with push_error() (returns empty array).
func get_all_ids() -> Array[String]:
	if not _is_frozen:
		push_error("EquipmentCatalog: get_all_ids() called before freeze()")
		return []
	var ids: Array[String] = []
	ids.assign(_definitions.keys())
	return ids


## INTERNAL loader API (Story 002) — NOT part of the public read-only surface.
## Adds one validated definition. Must only be called while the catalog is
## still loading: after freeze() this asserts (AC-FROZEN.2 — write paths are
## rejected; the loader never runs after freeze in the normal lifecycle).
func _add_definition(def: EquipmentDef) -> void:
	assert(not _is_frozen, "EquipmentCatalog: cannot add definition after freeze()")
	_definitions[def.id] = def


## INTERNAL loader API (Story 002) — freezes the catalog; after this call no
## write path may execute (AC-FROZEN.2). Must be called exactly once — a
## second call asserts.
func _freeze() -> void:
	assert(not _is_frozen, "EquipmentCatalog: _freeze() called twice")
	_is_frozen = true
	_is_loaded = true
