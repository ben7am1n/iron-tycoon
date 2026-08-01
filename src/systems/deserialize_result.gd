## DeserializeResult — composite return value for GridSystem.deserialize().
##
## Carries the verdict of a save-data load: whether validation (Phase A) and
## — in "commit" mode — application (Phase B) succeeded, plus structured
## error entries when they did not. Plain data-transfer object, mirrors
## PlacementCheckResult / TransformedFootprint (no logic of its own).
##
## Error entry shape (GDD §C.8 / Story 007):
##   { "category": String, "message": String, "detail": String }
##   - category: one of GridSystem's ERR_* constants (the three GDD-listed
##     categories SaveLoad/UI display: LEVEL_GEOMETRY_MISMATCH,
##     CORRUPTED_SAVE_OUT_OF_BOUNDS, CORRUPTED_SAVE_OVERLAP; plus
##     CORRUPTED_SAVE / INTERNAL_ERROR for structural and programming
##     failures — see GridSystem.deserialize() for the taxonomy).
##   - message:  short human-readable label (MVP: mirrors the category).
##   - detail:   developer-facing specifics (cell, id, expected vs actual).
##
## Failures are NORMAL OUTCOMES (corrupt save, level mismatch) — they are
## returned, never push_error'd (same convention as can_place()'s FAIL codes;
## push_error is reserved for programming errors).
class_name DeserializeResult extends RefCounted

## True when Phase A passed and — for "commit" mode — Phase B applied.
var success: bool = false

## Structured failure reasons. Empty when success == true.
var errors: Array[Dictionary] = []


## Builds a successful result (errors stays empty).
static func ok() -> DeserializeResult:
	var r := DeserializeResult.new()
	r.success = true
	return r


## Builds a failure result with one error entry.
## [detail] is developer-facing; [message] defaults to [category] (MVP:
## player-facing copy is the SaveLoad/UI layer's responsibility — GDD §C.8).
static func fail(category: String, detail: String) -> DeserializeResult:
	var r := DeserializeResult.new()
	r.errors.append({"category": category, "message": category, "detail": detail})
	return r
