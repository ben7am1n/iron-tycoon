## EquipmentCatalogLoader — .catalog.json loader + anchor normalization
## (equipment-catalog epic, Story 002; TR-EC-002/003/007; ADR-0002;
## GDD Core Rule 5 + anchor_normalization formula).
##
## Loads a hand-authored, VCS-diffable .catalog.json file into a FROZEN
## EquipmentCatalog (Story 001 container), applying anchor_normalization to
## every entry:
##
##   x' = x - min_x, y' = y - min_y   over footprint_cells ∪ access_cells
##
## so the normalized union always has min == (0,0) (TR-EC-003, AC-C.7).
## Only the canonical 0° orientation is stored — no rotation field, no
## pre-rotated variants (TR-EC-007; EquipmentDef has no rotation field by
## construction, verified by Story 001's AC-CANONICAL.1 test).
##
## Parse path: FileAccess.read + JSON.new().parse() — NOT parse_string() —
## so designer-facing syntax errors carry the offending LINE number via
## json.get_error_line() (AC-JSON.2, ADR-0002 section 6).
##
## Validation scope: this story performs STRUCTURAL parsing only (required
## keys, JSON types, {"x":N,"y":N} cell shape). Semantic validation —
## footprint 1x1/1x2/2x2 shape, access count==1, orthogonal adjacency,
## cost>=0, use_duration_* ranges — is Story 003/004/005 and deliberately
## NOT implemented here. Normalization runs BEFORE validation: Story 003's
## validator receives clean, normalized coordinates (Story 002 design note).
## Determinism guardrail (Control Manifest): same JSON input always produces
## the same EquipmentDef order — catalog insertion order is file order.
class_name EquipmentCatalogLoader extends RefCounted

const CATEGORY_FILE_NOT_FOUND := "FILE_NOT_FOUND"
const CATEGORY_IO_ERROR := "IO_ERROR"
const CATEGORY_JSON_PARSE_ERROR := "JSON_PARSE_ERROR"
const CATEGORY_INVALID_SCHEMA := "INVALID_SCHEMA"
const CATEGORY_INVALID_ENTRY := "INVALID_ENTRY"


## Loads a catalog from `path` (a .catalog.json file).
##
## strict_mode=true: a failing entry fires assert() and aborts the load frame
## (debug/editor posture per GDD Edge Cases — content bugs must be fixed
## before commit; the caller never receives a partial catalog).
## strict_mode=false: failing entries are collected in LoadResult.errors and
## the remaining valid entries still load (release posture — one bad record
## must not block the game from starting).
static func load_from_file(path: String, strict_mode: bool) -> LoadResult:
	if not FileAccess.file_exists(path):
		return LoadResult.fail(CATEGORY_FILE_NOT_FOUND, "Catalog file not found: %s" % path)

	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return LoadResult.fail(
			CATEGORY_IO_ERROR,
			"Cannot open catalog file: %s (open error %d)" % [path, FileAccess.get_open_error()]
		)

	var text := file.get_as_text()
	file.close()

	var json := JSON.new()
	var parse_error := json.parse(text)
	if parse_error != OK:
		return LoadResult.fail(
			CATEGORY_JSON_PARSE_ERROR,
			"Line %d: %s" % [json.get_error_line(), json.get_error_message()]
		)

	var data: Variant = json.get_data()
	if not data is Dictionary or not data.has("equipment"):
		return LoadResult.fail(CATEGORY_INVALID_SCHEMA, "Catalog JSON must have 'equipment' array at root")
	if not data["equipment"] is Array:
		return LoadResult.fail(CATEGORY_INVALID_SCHEMA, "Catalog JSON field 'equipment' must be an array")

	var catalog := EquipmentCatalog.new()
	var errors: Array[LoadError] = []

	for entry in data["equipment"]:
		var result := _load_single_definition(entry)
		if result["ok"]:
			catalog._add_definition(result["def"])
		else:
			errors.append_array(result["errors"])
			if strict_mode:
				assert(
					false,
					"EquipmentCatalog: failed to load '%s': %s" % [result["id"], _errors_summary(result["errors"])]
				)

	catalog._freeze()
	return LoadResult.new_loaded(catalog, errors)


## anchor_normalization (GDD Formulas section, TR-EC-003):
## x' = x - min_x, y' = y - min_y, where (min_x, min_y) is the component-wise
## minimum over footprint_cells ∪ access_cells. Idempotent for already-
## normalized input (min == (0,0) → no transform, AC-D.1). Returns copies —
## never aliases the caller's arrays (defensive posture, consistent with
## EquipmentDef._init duplication).
##
## Precondition: union non-empty. For an EMPTY union (both arrays empty) the
## function degrades to returning copies unchanged — an empty footprint is a
## Story 003 validation failure (AC-C.1), not a loader crash.
static func normalize_anchor(
	footprint_cells: Array[Vector2i],
	access_cells: Array[Vector2i]
) -> Dictionary:
	var all_cells := footprint_cells + access_cells
	if all_cells.is_empty():
		return {"footprint": footprint_cells.duplicate(), "access": access_cells.duplicate()}

	var min_x := all_cells[0].x
	var min_y := all_cells[0].y
	for cell in all_cells:
		min_x = min(min_x, cell.x)
		min_y = min(min_y, cell.y)

	if min_x == 0 and min_y == 0:
		return {"footprint": footprint_cells.duplicate(), "access": access_cells.duplicate()}

	var result_fp: Array[Vector2i] = []
	for cell in footprint_cells:
		result_fp.append(Vector2i(cell.x - min_x, cell.y - min_y))
	var result_ac: Array[Vector2i] = []
	for cell in access_cells:
		result_ac.append(Vector2i(cell.x - min_x, cell.y - min_y))

	return {"footprint": result_fp, "access": result_ac}


# === Per-entry structural parsing (Story 002 scope) ===

## Parses ONE JSON entry into an EquipmentDef (with anchor normalization
## applied, AC-C.7) or a list of structural errors.
## Returns {ok: bool, id: String, def: EquipmentDef, errors: Array[LoadError]}.
static func _load_single_definition(entry: Variant) -> Dictionary:
	if not entry is Dictionary:
		return {
			"ok": false,
			"id": "???",
			"def": null,
			"errors": [LoadError.new("???", CATEGORY_INVALID_ENTRY, "equipment entry must be a JSON object")],
		}

	var errors: Array[LoadError] = []
	var id := _field_string(entry, "id", "???", errors)
	var entry_id := id if id != "" else "???"

	var display_name := _field_string(entry, "display_name", entry_id, errors)
	var zone := _field_string_array(entry, "zone_membership", entry_id, errors)
	var cost := _field_int(entry, "cost", entry_id, errors)
	var unlock := _field_string_or_null(entry, "unlock_requirement", entry_id, errors)
	var use_mean := _field_int(entry, "use_duration_mean_ticks", entry_id, errors)
	var use_stddev := _field_int(entry, "use_duration_stddev_ticks", entry_id, errors)
	var use_min := _field_int(entry, "use_duration_min_ticks", entry_id, errors)
	var use_max := _field_int(entry, "use_duration_max_ticks", entry_id, errors)

	var footprint_parse := _parse_cells(entry.get("footprint_cells"), "footprint_cells", entry_id)
	var access_parse := _parse_cells(entry.get("access_cells"), "access_cells", entry_id)
	var effects_parse := _parse_effects(entry.get("effects"), entry_id)

	if not footprint_parse["ok"]:
		errors.append(footprint_parse["error"])
	if not access_parse["ok"]:
		errors.append(access_parse["error"])
	if not effects_parse["ok"]:
		errors.append(effects_parse["error"])

	if not errors.is_empty():
		return {"ok": false, "id": entry_id, "def": null, "errors": errors}

	var normalized := normalize_anchor(footprint_parse["cells"], access_parse["cells"])
	var def: EquipmentDef = EquipmentDef.new(
		id,
		display_name,
		zone,
		normalized["footprint"],
		normalized["access"],
		cost,
		unlock,
		effects_parse["effects"],
		use_mean,
		use_stddev,
		use_min,
		use_max,
	)
	return {"ok": true, "id": entry_id, "def": def, "errors": []}


## Reads a required String field. On missing/wrong-type, appends an
## INVALID_ENTRY LoadError and returns "".
static func _field_string(entry: Dictionary, key: String, entry_id: String, errors: Array[LoadError]) -> String:
	if not entry.has(key):
		errors.append(LoadError.new(entry_id, CATEGORY_INVALID_ENTRY, "entry missing required field '%s'" % key))
		return ""
	var value: Variant = entry[key]
	if not value is String:
		errors.append(
			LoadError.new(entry_id, CATEGORY_INVALID_ENTRY, "field '%s' must be a string, got %s" % [key, type_string(typeof(value))])
		)
		return ""
	return value


## Reads a required int field. On missing/wrong-type, appends an error and
## returns 0. Accepts both int and integer-valued float — Godot 4.7.1's
## JSON.parse() parses ALL JSON numbers as float (empirically verified:
## "200" arrives as 200.0), so rejecting floats would reject every numeric
## field in a hand-authored catalog. A genuinely fractional float (e.g.
## 200.5 for cost) is rejected with a clear error instead of truncation.
static func _field_int(entry: Dictionary, key: String, entry_id: String, errors: Array[LoadError]) -> int:
	if not entry.has(key):
		errors.append(LoadError.new(entry_id, CATEGORY_INVALID_ENTRY, "entry missing required field '%s'" % key))
		return 0
	var value: Variant = entry[key]
	if _is_int_value(value):
		return int(value)
	errors.append(
		LoadError.new(entry_id, CATEGORY_INVALID_ENTRY, "field '%s' must be an integer, got %s" % [key, type_string(typeof(value))])
	)
	return 0


## Reads a required String-or-null field. null is accepted and converted to
## "" (GDD Core Rule 1: unlock_requirement String / null; Story 001 decision:
## empty string = always available, null is NOT used in EquipmentDef).
static func _field_string_or_null(entry: Dictionary, key: String, entry_id: String, errors: Array[LoadError]) -> String:
	if not entry.has(key):
		errors.append(LoadError.new(entry_id, CATEGORY_INVALID_ENTRY, "entry missing required field '%s'" % key))
		return ""
	var value: Variant = entry[key]
	if value == null:
		return ""
	if not value is String:
		errors.append(
			LoadError.new(entry_id, CATEGORY_INVALID_ENTRY, "field '%s' must be a string or null, got %s" % [key, type_string(typeof(value))])
		)
		return ""
	return value


## Reads a required Array-of-String field (zone_membership). Returns an
## untyped Array matching EquipmentDef.zone_membership's declared type.
static func _field_string_array(entry: Dictionary, key: String, entry_id: String, errors: Array[LoadError]) -> Array:
	var result: Array = []
	if not entry.has(key):
		errors.append(LoadError.new(entry_id, CATEGORY_INVALID_ENTRY, "entry missing required field '%s'" % key))
		return result
	var value: Variant = entry[key]
	if not value is Array:
		errors.append(
			LoadError.new(entry_id, CATEGORY_INVALID_ENTRY, "field '%s' must be an array of strings, got %s" % [key, type_string(typeof(value))])
		)
		return result
	for item in value:
		if not item is String:
			errors.append(
				LoadError.new(entry_id, CATEGORY_INVALID_ENTRY, "field '%s' must contain only strings, found %s" % [key, type_string(typeof(item))])
			)
			return result
		result.append(item)
	return result


## Parses a JSON cell array — Array of {"x": N, "y": N} objects — into
## Array[Vector2i] (Story 002 schema note: "Vector2i serialized as {x,y}
## objects in JSON"). Returns {ok: bool, cells: Array[Vector2i], error: LoadError}.
static func _parse_cells(raw: Variant, key: String, entry_id: String) -> Dictionary:
	var empty: Array[Vector2i] = []
	if raw == null:
		return {
			"ok": false,
			"cells": empty,
			"error": LoadError.new(entry_id, CATEGORY_INVALID_ENTRY, "entry missing required field '%s'" % key),
		}
	if not raw is Array:
		return {
			"ok": false,
			"cells": empty,
			"error": LoadError.new(
				entry_id,
				CATEGORY_INVALID_ENTRY,
				"field '%s' must be an array of {x, y} objects, got %s" % [key, type_string(typeof(raw))]
			),
		}
	var cells: Array[Vector2i] = []
	for i in raw.size():
		var item: Variant = raw[i]
		if not item is Dictionary or not item.has("x") or not item.has("y"):
			return {
				"ok": false,
				"cells": empty,
				"error": LoadError.new(
					entry_id,
					CATEGORY_INVALID_ENTRY,
					"field '%s[%d]' must be an object with integer 'x' and 'y'" % [key, i]
				),
			}
		if not _is_int_value(item["x"]) or not _is_int_value(item["y"]):
			return {
				"ok": false,
				"cells": empty,
				"error": LoadError.new(
					entry_id,
					CATEGORY_INVALID_ENTRY,
					"field '%s[%d]' x/y must be integers, got x=%s y=%s" % [key, i, type_string(typeof(item["x"])), type_string(typeof(item["y"]))]
				),
			}
		cells.append(Vector2i(int(item["x"]), int(item["y"])))
	return {"ok": true, "cells": cells, "error": null}


## Parses the effects array — Array of {"tag": String, "magnitude": number}
## — into Array[Dictionary] with magnitude normalized to float (JSON parses
## "1" as int; the TR-EC-009 container contract is {tag: String, magnitude:
## float}). Returns {ok: bool, effects: Array[Dictionary], error: LoadError}.
static func _parse_effects(raw: Variant, entry_id: String) -> Dictionary:
	var empty: Array[Dictionary] = []
	if raw == null:
		return {
			"ok": false,
			"effects": empty,
			"error": LoadError.new(entry_id, CATEGORY_INVALID_ENTRY, "entry missing required field 'effects'"),
		}
	if not raw is Array:
		return {
			"ok": false,
			"effects": empty,
			"error": LoadError.new(
				entry_id,
				CATEGORY_INVALID_ENTRY,
				"field 'effects' must be an array of {tag, magnitude} objects, got %s" % type_string(typeof(raw))
			),
		}
	var effects: Array[Dictionary] = []
	for i in raw.size():
		var item: Variant = raw[i]
		if not item is Dictionary or not item.has("tag") or not item.has("magnitude"):
			return {
				"ok": false,
				"effects": empty,
				"error": LoadError.new(
					entry_id,
					CATEGORY_INVALID_ENTRY,
					"field 'effects[%d]' must be an object with string 'tag' and number 'magnitude'" % i
				),
			}
		if not item["tag"] is String:
			return {
				"ok": false,
				"effects": empty,
				"error": LoadError.new(
					entry_id,
					CATEGORY_INVALID_ENTRY,
					"field 'effects[%d].tag' must be a string, got %s" % [i, type_string(typeof(item["tag"]))]
				),
			}
		if not (item["magnitude"] is int or item["magnitude"] is float):
			return {
				"ok": false,
				"effects": empty,
				"error": LoadError.new(
					entry_id,
					CATEGORY_INVALID_ENTRY,
					"field 'effects[%d].magnitude' must be a number, got %s" % [i, type_string(typeof(item["magnitude"]))]
				),
			}
		effects.append({"tag": item["tag"], "magnitude": float(item["magnitude"])})
	return {"ok": true, "effects": effects, "error": null}


## True iff the Variant is an int or an integer-valued float. Required
## because Godot 4.7.1's JSON.parse() parses ALL JSON numbers as float
## (empirically verified: "200" -> 200.0, "-3" -> -3.0) — see
## docs/tech-debt-register.md (Story 002 entry).
static func _is_int_value(value: Variant) -> bool:
	if value is int:
		return true
	return value is float and is_equal_approx(value, round(value))


## Joins LoadError messages for the strict_mode assert message — the whole
## point of the debug-abort path is telling the designer WHAT failed.
static func _errors_summary(errors: Array[LoadError]) -> String:
	var parts: Array[String] = []
	for e in errors:
		parts.append(e.message)
	return "; ".join(parts)
