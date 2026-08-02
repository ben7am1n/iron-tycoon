## StubDeserializeResult — shared composite return value for the Core-layer
## integration stubs (MemberSim/Congestion/Satisfaction/Economy, Story SL-002).
##
## Carries the verdict of a save-data load: whether validation (Phase A) and
## — in commit mode — application (Phase B) succeeded, plus every collected
## validation error (Phase A failures do not short-circuit — the caller sees
## all problems at once, mirroring TimeSystemDeserializeResult). Plain
## data-transfer object.
##
## WHY SHARED (documented, not silent): these four systems are STUBS — the
## task's stub plan (story SL-002 QA) builds minimal serialize/deserialize
## stand-ins so the SaveLoad load pipeline is integration-testable NOW, marked
## as Core-layer integration points. Each real system's story will define its
## own result class (the TimeSystemDeserializeResult precedent); until then
## one shared DTO keeps the stub layer honest and avoids four copies of the
## same 15 lines. Replaced when each system's story lands.
class_name StubDeserializeResult extends RefCounted

## True when Phase A passed and — for commit mode — Phase B applied.
var ok: bool = false

## Structured failure reasons. Empty when ok == true.
var errors: Array[String] = []


## Builds a successful result (errors stays empty).
static func success() -> StubDeserializeResult:
	var r := StubDeserializeResult.new()
	r.ok = true
	return r


## Builds a failure result with one error entry.
static func fail(message: String) -> StubDeserializeResult:
	var r := StubDeserializeResult.new()
	r.errors.append(message)
	return r
