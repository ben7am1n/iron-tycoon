## Satisfaction — CORE-LAYER INTEGRATION STUB (Story SL-002).
##
## Story: save-load / story-002-load-orchestration-phase-ab.md (stub plan)
## Req:   TR-SL-005 (non-mutating validate/dry-run deserialize mode)
##
## THIS IS A STUB, marked as a Core-layer integration point: minimal
## serialize/deserialize stand-in so the SaveLoad load pipeline (Phase A
## validate / Phase B commit) is integration-testable now, before the real
## Satisfaction story lands. It keeps the system's public contract surface
## (SimSystem two-phase init, SeededRNG sub-stream registration,
## serialize/deserialize with validate_only) but simulates all behavior
## minimally: on_tick() advances an RNG draw + increments a counter,
## serialize() captures {counter, rng_state}, deserialize() validates and
## restores them. The real Satisfaction story (global_satisfaction +
## member_accumulators) replaces this file.
class_name Satisfaction extends SimSystem

## Injected composition root (unused by the stub; kept for the real system's
## signature symmetry with TimeSystem.init(orchestrator, seeded_rng)).
var _orchestrator: SimulationOrchestrator
## Injected SeededRNG registry — the stub's sub-stream lives here (ADR-0004).
var _seeded_rng: SeededRNG

## Stub state: monotonic counter, incremented per on_tick() — observable
## stand-in for the real system's internal progression.
var counter: int = 0


## Two-phase init (ADR-0001). Registers the Satisfaction RNG sub-stream
## exactly once (assert on duplicate — SeededRNG.register_system is the hard
## gate).
func init(orchestrator: SimulationOrchestrator, seeded_rng: SeededRNG) -> void:
	if not _mark_initialized():
		return
	_orchestrator = orchestrator
	_seeded_rng = seeded_rng
	_seeded_rng.register_system(system_name())


func system_name() -> String:
	return "Satisfaction"


## Stub tick behavior: advances the RNG sub-stream (one draw) and increments
## the counter — the minimal stand-in for the real system's per-tick work.
func on_tick(tick_count: int) -> void:
	if not _assert_initialized():
		return
	counter += 1
	_seeded_rng.get_rng(system_name()).randi()


## Returns the full stub state as a JSON-safe Dictionary:
##   { counter: int, rng_state: "0x…" }
## Pure read — no draws, no counter mutation (SL-001 AC1 counts serialize
## calls, so serialize stays side-effect free).
func serialize() -> Dictionary:
	if not _assert_initialized():
		return {}
	return {
		"counter": counter,
		"rng_state": SeededRNG.int64_to_hex(_seeded_rng.get_rng(system_name()).state),
	}


## Two-phase deserialize (TR-SL-005, ADR-0002).
## Phase A validates EVERYTHING with zero mutation; Phase B commits only if
## Phase A passed. Failures are returned, never push_error'd (corrupt save =
## normal outcome). [validate_only] runs Phase A and returns the verdict
## without committing (SaveLoad Phase A protocol).
## Required fields (hard failure, no invented defaults):
##   counter (int), rng_state ("0x" hex string).
func deserialize(data: Dictionary, validate_only: bool = false) -> StubDeserializeResult:
	var result := StubDeserializeResult.new()
	if not _assert_initialized():
		return StubDeserializeResult.fail("Satisfaction.deserialize(): called before init()")

	# --- Phase A: validate (zero mutation) ---
	if not data.has("counter") or typeof(data["counter"]) != TYPE_INT:
		result.errors.append("Satisfaction: missing or invalid 'counter'")
	if not data.has("rng_state") or not data["rng_state"] is String:
		result.errors.append("Satisfaction: missing or invalid 'rng_state'")
	elif not str(data["rng_state"]).begins_with("0x") or not str(data["rng_state"]).is_valid_hex_number(true):
		result.errors.append("Satisfaction: rng_state must be a 0x hex string")

	if not result.errors.is_empty():
		return result  # Phase A failed — NOTHING was mutated

	result.ok = true
	if validate_only:
		return result  # validated, NOT committed (SaveLoad Phase A)

	# --- Phase B: commit (only if all valid) ---
	counter = int(data["counter"])
	_seeded_rng.get_rng(system_name()).state = SeededRNG.hex_to_int64(str(data["rng_state"]))
	return result
