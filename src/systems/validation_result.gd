## ValidationResult — result envelope for semantic catalog validation
## (equipment-catalog epic, Story 003; GDD Core Rule 3/4/6; TR-EC-002).
##
## Returned by EquipmentCatalogLoader.validate_footprint_shape() /
## validate_access_cells() / _validate_definition(). Carries exactly the
## information the loader's strict_mode branch needs to decide abort vs skip
## (AC-C.1/AC-C.2): a boolean outcome plus a machine-readable rule code
## (e.g. "FOOTPRINT_NOT_RECTANGULAR") and a human-readable message naming the
## violated rule — per the Control Manifest rule "All validation errors
## produce LoadError objects with equipment id + rule reference": the loader
## wraps this result's code/message into a LoadError carrying the entry id.
##
## Deliberately minimal — this is a pure data carrier, no logic. The caller
## (Story 003's validators) builds results via the success()/fail() factories;
## the loader (Story 002/004) decides abort vs skip from `.ok`.
##
## NOTE (empirical 4.7.1 constraint, recorded in tech-debt register): the
## static factory is `success()`, NOT `ok()` as in the Story 003 sketch —
## GDScript forbids a member variable and a method sharing the name `ok`.
class_name ValidationResult extends RefCounted

## True iff validation passed.
var ok: bool = false

## Machine-readable rule code of the FIRST failed check (e.g.
## "FOOTPRINT_EMPTY", "FOOTPRINT_NOT_RECTANGULAR", "ACCESS_COUNT",
## "ACCESS_OVERLAPS_FOOTPRINT", "ACCESS_NOT_ADJACENT"). Empty on success().
var code: String = ""

## Human-readable description of the failure — safe to show in the loader's
## assert message and in LoadError.message. Empty on success().
var message: String = ""

func _init(p_ok: bool, p_code: String, p_message: String) -> void:
	ok = p_ok
	code = p_code
	message = p_message


## Factory: a passing result. Named success() not ok() — GDScript does not
## allow a method and a member variable with the same name (see header note).
static func success() -> ValidationResult:
	return ValidationResult.new(true, "", "")


## Factory: a failing result with rule code + message.
static func fail(code: String, message: String) -> ValidationResult:
	return ValidationResult.new(false, code, message)
