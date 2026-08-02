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
## Validation scope: this story performs STRUCTURAL parsing (required keys,
## JSON types, {"x":N,"y":N} cell shape) AND — since Story 003 — the
## semantic validation of the GridSystem cross-document contract: footprint
## must be a 1x1/1x2/2x2 rectangular AABB (no L-shapes, no holes),
## access_cells exactly 1 entry, orthogonally adjacent, disjoint from
## footprint (TR-EC-002, AC-C.3/4/5/6). Since Story 004: the ordered
## validation PIPELINE (_validate_all) collects one error per FAILING
## sub-validator in deterministic order (AC-PIPELINE.3), and the loader
## detects DUPLICATE ids — first occurrence kept, later occurrences treated
## as validation failures (AC-E.1). Since Story 005: the use_duration_* range
## validation (GDD Core Rule 7 (e)-(h), TR-EC-004) — the cross-document hard
## gate with MemberSim #6 OQ2 — joined the pipeline. Remaining semantic range
## (cost>=0) is Story 007 and still NOT implemented here.
## Normalization runs BEFORE validation: the Story 003 validators receive
## clean, normalized coordinates (Story 002 design note).
## Determinism guardrail (Control Manifest): same JSON input always produces
## the same EquipmentDef order — catalog insertion order is file order.
class_name EquipmentCatalogLoader extends RefCounted

const CATEGORY_FILE_NOT_FOUND := "FILE_NOT_FOUND"
const CATEGORY_IO_ERROR := "IO_ERROR"
const CATEGORY_JSON_PARSE_ERROR := "JSON_PARSE_ERROR"
const CATEGORY_INVALID_SCHEMA := "INVALID_SCHEMA"
const CATEGORY_INVALID_ENTRY := "INVALID_ENTRY"
const CATEGORY_VALIDATION_FAILED := "VALIDATION_FAILED"
const CATEGORY_DUPLICATE_ID := "DUPLICATE_ID"


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
	var seen_ids: Dictionary = {}  # id -> true, first occurrence wins (Story 004, AC-E.1)

	for entry in data["equipment"]:
		# Step 0: Duplicate id check (Story 004, AC-E.1) — FIRST check, before
		# normalization/validation (story key design decision: prevents wasted
		# work). First occurrence claims the id; later occurrences are treated
		# as DUPLICATE_ID failures (GDD Edge Cases: "保留首次出现的定义，后出现的
		# 视为该条记录校验失败").
		var entry_id := _raw_entry_id(entry)
		if entry_id != "" and seen_ids.has(entry_id):
			var dup_err := LoadError.new(
				entry_id,
				CATEGORY_DUPLICATE_ID,
				"Duplicate equipment id '%s'; first occurrence kept" % entry_id
			)
			errors.append(dup_err)
			if strict_mode:
				assert(false, "EquipmentCatalog: %s" % dup_err.message)
			else:
				# GDD Edge Cases: duplicates take the SAME failure path as
				# validation failures — release posture excludes + push_error()
				# (consistent with AC-C.2 / EC-003 decision: non-strict
				# exclusions are recorded via push_error).
				push_error(
					"EquipmentCatalog: excluding duplicate entry '%s': %s"
					% [entry_id, dup_err.message]
				)
			continue  # skip this entry — the first occurrence keeps the id

		if entry_id != "":
			seen_ids[entry_id] = true

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
			else:
				# AC-C.2 / GDD Edge Cases: release posture — the bad entry is
				# EXCLUDED from the catalog but push_error() records it (deep
				# defense; one bad record must not block the game from
				# starting). The valid entries still load below.
				push_error(
					"EquipmentCatalog: excluding invalid entry '%s': %s"
					% [result["id"], _errors_summary(result["errors"])]
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


# === Semantic validation (Story 003 scope, TR-EC-002) ===
#
# These validators enforce the GridSystem cross-document contract that
# declared_bounds / rotation transform depend on (GDD Core Rules 3+4,
# grid-system OQ#11/#13): footprint must be a 1x1 / 1x2 / 2x2 rectangular
# AABB (no L-shapes, no holes); access_cells must have exactly 1 entry that
# is orthogonally adjacent to (and disjoint from) the footprint.
#
# Both are pure functions returning ValidationResult — the loader's
# strict_mode branch (in load_from_file) decides abort vs skip per entry
# (Story 004 owns that branching decision; this story only produces the
# result, per the story's Out of Scope note).

## The three locked footprint shapes, keyed by canonical label. bbox w/h are
## the AABB dimensions; "cells" is the required cell count. The 1x2 label
## covers BOTH orientations (w=1,h=2 and w=2,h=1) — GridSystem handles
## rotation at runtime, the canonical definition is just a straight line
## (GDD Core Rule 3).
const VALID_SHAPES := {
	"1x1": {"cells": 1, "w": 1, "h": 1},
	"1x2": {"cells": 2, "w": 1, "h": 2},  # or w=2,h=1
	"2x2": {"cells": 4, "w": 2, "h": 2},
}


## Validates that `cells` is one of the three locked rectangular AABB
## footprints (AC-C.3: L-shape / hole / diagonal-only / oversized all fail).
## Uses bounding-box + cell-count: a rectangular AABB satisfies
## cell_count == bbox_w * bbox_h, which catches holes and L-shapes
## naturally. Ordered checks — first failure returns (deterministic error
## for any given bad input).
static func validate_footprint_shape(cells: Array[Vector2i]) -> ValidationResult:
	if cells.is_empty():
		return ValidationResult.fail("FOOTPRINT_EMPTY", "footprint_cells must not be empty")

	var cell_count := cells.size()

	# Bounding box
	var min_x := cells[0].x
	var max_x := cells[0].x
	var min_y := cells[0].y
	var max_y := cells[0].y
	for c in cells:
		min_x = min(min_x, c.x)
		max_x = max(max_x, c.x)
		min_y = min(min_y, c.y)
		max_y = max(max_y, c.y)

	var bbox_w := max_x - min_x + 1
	var bbox_h := max_y - min_y + 1

	# Must match cell count AND bounding box dimensions AND be rectangular
	# (cell_count == bbox_w * bbox_h) — the rectangularity check alone
	# catches L-shapes (3 cells in a 2x2 bbox) and holes.
	var is_rectangular := cell_count == (bbox_w * bbox_h)
	if not is_rectangular:
		return ValidationResult.fail(
			"FOOTPRINT_NOT_RECTANGULAR",
			"footprint must be rectangular AABB; got %d cells in %dx%d bbox (expected %d cells)"
			% [cell_count, bbox_w, bbox_h, bbox_w * bbox_h]
		)

	var is_valid_shape := (bbox_w in [1, 2] and bbox_h in [1, 2]) and cell_count in [1, 2, 4]
	if not is_valid_shape:
		return ValidationResult.fail(
			"FOOTPRINT_INVALID_SHAPE",
			"footprint must be 1×1, 1×2, or 2×2; got %d×%d (%d cells)" % [bbox_w, bbox_h, cell_count]
		)

	return ValidationResult.success()


## Validates the access cell contract (GDD Core Rule 4): exactly 1 entry,
## disjoint from footprint, orthogonally adjacent (shares an edge — diagonal
## dx=1,dy=1 is NOT adjacent, AC-C.5; far cells fail, AC-C.5 edge cases).
static func validate_access_cells(
	access_cells: Array[Vector2i],
	footprint_cells: Array[Vector2i]
) -> ValidationResult:
	# (d) Exactly 1 access cell
	if access_cells.size() != 1:
		return ValidationResult.fail(
			"ACCESS_COUNT",
			"access_cells must have exactly 1 entry; got %d" % access_cells.size()
		)

	var ac := access_cells[0]

	# (c) Access must not overlap footprint (GridSystem OQ#13 item (c), AC-C.6)
	if ac in footprint_cells:
		return ValidationResult.fail(
			"ACCESS_OVERLAPS_FOOTPRINT",
			"access cell %s overlaps with footprint" % ac
		)

	# Orthogonal adjacency: must share at least one edge with a footprint cell
	var is_adjacent := false
	for fc in footprint_cells:
		var dx: int = abs(ac.x - fc.x)
		var dy: int = abs(ac.y - fc.y)
		if (dx == 1 and dy == 0) or (dx == 0 and dy == 1):
			is_adjacent = true
			break

	if not is_adjacent:
		return ValidationResult.fail(
			"ACCESS_NOT_ADJACENT",
			"access cell %s is not orthogonally adjacent to any footprint cell" % ac
		)

	return ValidationResult.success()


## Validates the use_duration_* range contract (GDD Core Rule 7 (e)-(h),
## TR-EC-004; AC-U.1..U.5) — the cross-document hard gate with MemberSim
## #6 OQ2: these 4 fields drive the USING-state timer's Gaussian duration
## (`use_duration = clamp(gaussian_rng(mean, stddev), min, max)`). Catalog
## load-time is the SINGLE authority — MemberSim trusts the Catalog output
## and does no defensive re-validation (Story 005 key design decision).
##
## Pure integer range checks (Engine Notes: no engine API risk). Ordered
## checks — first failure returns (deterministic error code for any given
## bad input, same convention as the footprint/access validators):
##   (e) mean > 0         — 0/negative mean = gaussian center ≤ 0 → no
##                          positive duration possible → member stuck in
##                          USING (Pillar 2 "永不卡死"); AC-U.1
##   (f) stddev >= 0      — negative stddev invalid; 0 allowed (deterministic
##                          duration, AC-U.5)
##   (g) min >= 1 AND min <= mean — clamp lower bound; min=0 allows a 0-tick
##                          USING state; min > mean is a nonsensical clamp;
##                          AC-U.3
##   (h) max >= mean AND min <= max — bounded-duration guarantee; AC-U.3
##
## Signature deviation from the Story 005 sketch (`entry: Dictionary`): the
## loader has already parsed the 4 fields into typed ints via _field_int
## (which also fails on missing/non-integer values — "never assume defaults
## for missing use_duration fields" is enforced upstream at the structural
## layer), so the validator takes typed args like the Story 003 validators.
static func validate_use_duration(
	mean: int,
	stddev: int,
	min_val: int,
	max_val: int
) -> ValidationResult:
	# (e) mean > 0
	if mean <= 0:
		return ValidationResult.fail(
			"USE_DURATION_MEAN_INVALID",
			"use_duration_mean_ticks must be > 0; got %d" % mean
		)

	# (f) stddev >= 0
	if stddev < 0:
		return ValidationResult.fail(
			"USE_DURATION_STDDEV_NEGATIVE",
			"use_duration_stddev_ticks must be >= 0; got %d" % stddev
		)

	# (g) min >= 1 AND min <= mean
	if min_val < 1:
		return ValidationResult.fail(
			"USE_DURATION_MIN_TOO_LOW",
			"use_duration_min_ticks must be >= 1; got %d" % min_val
		)
	if min_val > mean:
		return ValidationResult.fail(
			"USE_DURATION_MIN_EXCEEDS_MEAN",
			"use_duration_min_ticks (%d) must be <= mean (%d)" % [min_val, mean]
		)

	# (h) max >= mean AND min <= max
	if max_val < mean:
		return ValidationResult.fail(
			"USE_DURATION_MAX_BELOW_MEAN",
			"use_duration_max_ticks (%d) must be >= mean (%d)" % [max_val, mean]
		)
	if min_val > max_val:
		return ValidationResult.fail(
			"USE_DURATION_RANGE_INVALID",
			"use_duration_min (%d) must be <= max (%d)" % [min_val, max_val]
		)

	return ValidationResult.success()


## Ordered validation pipeline for one definition (Story 003 sketch):
## footprint shape → access count → access disjoint → access adjacency.
## First failure returns — deterministic error for any given bad input.
## Operates on ALREADY-NORMALIZED coordinates (Story 002 runs
## normalize_anchor before this; the union min is guaranteed (0,0)).
static func _validate_definition(
	footprint_cells: Array[Vector2i],
	access_cells: Array[Vector2i]
) -> ValidationResult:
	var r := validate_footprint_shape(footprint_cells)
	if not r.ok:
		return r

	r = validate_access_cells(access_cells, footprint_cells)
	if not r.ok:
		return r

	return ValidationResult.success()


## Ordered validation pipeline for one definition (Story 004, AC-PIPELINE.3):
## runs every sub-validator in deterministic order (footprint shape → access →
## [use-duration: EC-005] → [cost: EC-007]) and collects ONE error per FAILING
## sub-validator — each sub-validator early-exits at its OWN first failure, but
## the pipeline does NOT stop at the first failing validator ("_validate_all
## collects ALL errors per entry, not first-only" — Story 004 key design
## decision; QA case: "returns 3 errors — NOT just the first"; implementation
## notes comment: "first failure reported per sub-validator"). Result order is
## deterministic: the fixed sub-validator order above.
##
## NOTE (spec contradiction, resolved): the BLOCKING AC text "only the FIRST
## failure is reported" and the user's kanban summary ("多失败仅报第一条") can be
## read as per-ENTRY first-only, which contradicts the story's own QA Test
## Cases ("returns 3 errors (FOOTPRINT_EMPTY, ACCESS_COUNT, COST_NEGATIVE) —
## NOT just the first"), the implementation-notes sketch, and the key design
## decision. Resolved toward the detailed spec (3:1 evidence): one error per
## failing sub-validator in deterministic order — this also satisfies the AC's
## "deterministic error ordering" requirement, which is meaningless with a
## single error. Logged in docs/tech-debt-register.md.
##
## The use_duration_* ints are ALREADY parsed/typed by the caller (via
## _field_int, which fails structurally on missing/non-integer values) — this
## pipeline only enforces the GDD Core Rule 7 (e)-(h) RANGE contract.
##
## Extension point: Story 007 (cost) appends its validator here IN THIS FIXED
## ORDER after use-duration — do not reorder (determinism contract).
static func _validate_all(
	footprint_cells: Array[Vector2i],
	access_cells: Array[Vector2i],
	use_mean: int,
	use_stddev: int,
	use_min: int,
	use_max: int
) -> Array[ValidationResult]:
	var failures: Array[ValidationResult] = []

	var r := validate_footprint_shape(footprint_cells)
	if not r.ok:
		failures.append(r)

	r = validate_access_cells(access_cells, footprint_cells)
	if not r.ok:
		failures.append(r)

	# Story 005 (EC-005): use-duration range contract (GDD Core Rule 7 (e)-(h)).
	r = validate_use_duration(use_mean, use_stddev, use_min, use_max)
	if not r.ok:
		failures.append(r)

	# Story 007 (EC-007): validate_cost(...) appended here.

	return failures


## Returns the entry's raw id as a String, or "" when the entry is not a
## Dictionary / has no "id" / id is not a String. Used by the Step 0
## duplicate-id check (Story 004, AC-E.1) — the structural parser (Story 002)
## reports a missing or mistyped id separately as INVALID_ENTRY; this helper
## only needs the id to detect duplicates, and empty ids are deliberately
## NOT tracked (a missing id is a structural error, not a duplicate).
static func _raw_entry_id(entry: Variant) -> String:
	if not entry is Dictionary:
		return ""
	var id_value: Variant = entry.get("id", "")
	if id_value is String:
		return id_value
	return ""


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

	# Story 003/004: semantic validation on the NORMALIZED coordinates (Story 002
	# design note: "validator receives clean, normalized coordinates"). Story 004
	# pipeline collects ALL per-validator failures (AC-PIPELINE.3, deterministic
	# order) — one LoadError per failing validator, all flowing into the loader's
	# strict_mode branch: strict=true aborts (AC-C.1), strict=false excludes +
	# push_error (AC-C.2) — the other valid entries still load.
	var validation_failures := _validate_all(
		normalized["footprint"],
		normalized["access"],
		use_mean,
		use_stddev,
		use_min,
		use_max
	)
	if not validation_failures.is_empty():
		for failure in validation_failures:
			errors.append(
				LoadError.new(
					entry_id,
					CATEGORY_VALIDATION_FAILED,
					"%s: %s" % [failure.code, failure.message]
				)
			)
		return {"ok": false, "id": entry_id, "def": null, "errors": errors}

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
