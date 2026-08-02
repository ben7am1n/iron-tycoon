## LoadResult — batch result of a catalog load (equipment-catalog epic,
## Story 002/004; ADR-0002 "CatalogLoadResult" intent; GDD Edge Cases).
##
## Carries BOTH the successfully-loaded catalog AND the per-entry errors —
## Story 004 guardrail: "LoadResult must contain both the catalog (with
## valid entries) AND the list of errors (for logging/diagnostics)".
##
## ok semantics: false only for catastrophic failures (file not found,
## JSON parse error, invalid schema) and for a load that produced ZERO
## usable entries; true otherwise — strict_mode=false loads that skip a few
## bad entries still return ok=true with a usable catalog.
##
## Named per the Story 002 sketch (LoadResult); the static factories follow
## the Story 004 DTO sketch exactly (fail() / new_loaded()).
class_name LoadResult extends RefCounted

## True if the load produced a usable (possibly non-empty) catalog.
var ok: bool = false

## The frozen EquipmentCatalog. For catastrophic failures this is an empty
## frozen catalog (ADR-0002: "never silently partial-load" — callers can
## still query it safely and get nulls).
var catalog: EquipmentCatalog

## Per-entry / file-level failures. Empty on a clean load.
var errors: Array[LoadError] = []

func _init() -> void:
	pass


## Static factory for catastrophic file-level failures (Story 002/004 sketch):
## ok=false, an empty FROZEN catalog (safe to query), one LoadError whose
## equipment_id is "" (no single entry is at fault).
static func fail(category: String, message: String) -> LoadResult:
	var result := LoadResult.new()
	result.ok = false
	result.catalog = EquipmentCatalog.new()
	result.catalog._freeze()
	var error_list: Array[LoadError] = [LoadError.new("", category, message)]
	result.errors = error_list
	return result


## Static factory for a completed load (Story 004 sketch): ok mirrors whether
## the frozen catalog holds at least one definition. `catalog` must already
## be frozen (the loader freezes before constructing the result).
static func new_loaded(catalog: EquipmentCatalog, errors: Array[LoadError]) -> LoadResult:
	var result := LoadResult.new()
	result.ok = catalog.get_all_ids().size() > 0
	result.catalog = catalog
	result.errors = errors
	return result
