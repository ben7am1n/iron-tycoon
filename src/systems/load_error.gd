## LoadError — structured error envelope for catalog/save loading
## (equipment-catalog epic, Story 002; ADR-0002 section 7; Story 004 DTO).
##
## Every load failure produces a LoadError instead of a bare string so the
## UI layer can distinguish "incompatible version" from "corrupt file" from
## "IO error". Shape follows the Story 004 DTO sketch (equipment_id /
## category / message) — the ADR-0002 sketch's `detail` field is folded into
## `message`; the per-entry errors this epic emits carry the offending entry
## id in `equipment_id` (recorded in docs/tech-debt-register.md).
class_name LoadError extends RefCounted

## The equipment entry id this error belongs to. Empty string for
## file-level / schema-level errors (parse, file-not-found, invalid schema).
var equipment_id: String

## Machine-readable category. Values emitted by the catalog loader:
## FILE_NOT_FOUND, IO_ERROR, JSON_PARSE_ERROR, INVALID_SCHEMA, INVALID_ENTRY.
var category: String

## Human-readable description — safe to show in UI. Includes the JSON parse
## line number for syntax errors (AC-JSON.2) and the offending field name
## for per-entry structural errors.
var message: String

func _init(p_equipment_id: String, p_category: String, p_message: String) -> void:
	equipment_id = p_equipment_id
	category = p_category
	message = p_message
