## MemberSim — CORE-LAYER INTEGRATION STUB (Story SL-002).
##
## Story: save-load / story-002-load-orchestration-phase-ab.md (stub plan)
## Req:   TR-SL-005 (every coordinated system's deserialize supports a
##        non-mutating validate/dry-run mode), AC9 (member referencing an
##        equipment_instance_id absent from the loaded/validated grid fails
##        the WHOLE load — never a silent orphan)
##
## THIS IS A STUB, marked as a Core-layer integration point: it exists so the
## SaveLoad load pipeline (Phase A validate / Phase B commit) is
## integration-testable NOW, before the real MemberSim story lands. It keeps
## the system's public contract surface (SimSystem two-phase init, SeededRNG
## sub-stream registration, serialize/deserialize with validate_only) and the
## load-bearing AC9 equipment-reference validation, but simulates all other
## behavior minimally: on_tick() advances an RNG draw + increments a counter,
## serialize() captures {counter, members, rng_state}, deserialize() validates
## and restores them. The real MemberSim story replaces this file.
##
## AC9 MECHANICS (documented deviation from the story sketch's 2-arg call):
## the sketch calls _member_sim.deserialize(data, validate_only) with no grid
## context. AC9 requires members to be checked against the LOADED/VALIDATED
## grid — and during Phase A the grid has NOT been committed yet (zero
## mutation), so the live GridSystem is pre-load state and cannot be queried.
## SaveLoad therefore passes the set of instance ids extracted from the save's
## grid records (validated by GridSystem Phase A) as DERIVED CONTEXT — the
## Control Manifest explicitly sanctions "Phase A passes system data plus
## derived context". Third parameter, default empty.
class_name MemberSim extends SimSystem

## Injected composition root (unused by the stub; kept for the real system's
## signature symmetry with TimeSystem.init(orchestrator, seeded_rng)).
var _orchestrator: SimulationOrchestrator
## Injected SeededRNG registry — the stub's sub-stream lives here (ADR-0004).
var _seeded_rng: SeededRNG

## Stub state: the member roster. Each entry: {member_id: int,
## equipment_instance_id: int}. Members reference equipment by the grid's
## instance ids — AC9 validation happens in deserialize().
var members: Array = []

## Stub state: monotonic counter, incremented per on_tick() — observable
## stand-in for the real system's internal progression.
var counter: int = 0


## Two-phase init (ADR-0001). Registers the MemberSim RNG sub-stream exactly
## once (assert on duplicate — SeededRNG.register_system is the hard gate).
func init(orchestrator: SimulationOrchestrator, seeded_rng: SeededRNG) -> void:
	if not _mark_initialized():
		return
	_orchestrator = orchestrator
	_seeded_rng = seeded_rng
	_seeded_rng.register_system(system_name())


func system_name() -> String:
	return "MemberSim"


## Stub tick behavior: advances the RNG sub-stream (one draw) and increments
## the counter — the minimal stand-in for the real system's per-tick work.
## Kept deterministic: the draw consumes from the registered sub-stream, which
## serialize() captures and deserialize() restores bit-exactly.
func on_tick(tick_count: int) -> void:
	if not _assert_initialized():
		return
	counter += 1
	_seeded_rng.get_rng(system_name()).randi()


## Returns the full stub state as a JSON-safe Dictionary:
##   { counter: int, members: [{member_id, equipment_instance_id}, ...],
##     rng_state: "0x…" }
## Pure read — no draws, no counter mutation (the real system's serialize
## contract; SL-001 AC1 counts serialize calls, so serialize stays side-effect
## free). rng_state is the CURRENT sub-stream state (hex per ADR-0002).
func serialize() -> Dictionary:
	if not _assert_initialized():
		return {}
	return {
		"counter": counter,
		"members": members,
		"rng_state": SeededRNG.int64_to_hex(_seeded_rng.get_rng(system_name()).state),
	}


## Two-phase deserialize (TR-SL-005, ADR-0002).
##
## Phase A validates EVERYTHING with zero mutation; Phase B commits only if
## Phase A passed. Failures are returned, never push_error'd (corrupt save =
## normal outcome). [validate_only] runs Phase A and returns the verdict
## without committing (SaveLoad Phase A protocol).
##
## AC9: every member's equipment_instance_id must be present in
## [known_instance_ids] — the set extracted from the save's grid records that
## GridSystem Phase A validated ("the grid is the source of truth"). A member
## referencing an absent id produces "member X references unknown
## equipment_instance_id 99" and fails the whole load; the error is collected
## by SaveLoad with zero mutation anywhere.
##
## Required fields (hard failure, no invented defaults):
##   counter (int), members (Array of {member_id, equipment_instance_id}),
##   rng_state ("0x" hex string).
func deserialize(data: Dictionary, validate_only: bool = false, known_instance_ids: Array = []) -> StubDeserializeResult:
	var result := StubDeserializeResult.new()
	if not _assert_initialized():
		return StubDeserializeResult.fail("MemberSim.deserialize(): called before init()")

	# --- Phase A: validate (zero mutation) ---
	if not data.has("counter") or typeof(data["counter"]) != TYPE_INT:
		result.errors.append("MemberSim: missing or invalid 'counter'")

	if not data.has("members") or not (data["members"] is Array):
		result.errors.append("MemberSim: missing or invalid 'members'")
	else:
		for i in (data["members"] as Array).size():
			var member = data["members"][i]
			if not (member is Dictionary) or not member.has("member_id") or not member.has("equipment_instance_id"):
				result.errors.append("MemberSim: member %d malformed (need member_id + equipment_instance_id)" % i)
				continue
			var equipment_instance_id := int(member["equipment_instance_id"])
			# AC9 — the grid is the source of truth: an id absent from the
			# validated grid fails the WHOLE load, never a silent orphan.
			if not known_instance_ids.has(equipment_instance_id):
				result.errors.append("MemberSim: member %s references unknown equipment_instance_id %d" % [str(member["member_id"]), equipment_instance_id])

	if not data.has("rng_state") or not data["rng_state"] is String:
		result.errors.append("MemberSim: missing or invalid 'rng_state'")
	elif not str(data["rng_state"]).begins_with("0x") or not str(data["rng_state"]).is_valid_hex_number(true):
		result.errors.append("MemberSim: rng_state must be a 0x hex string")

	if not result.errors.is_empty():
		return result  # Phase A failed — NOTHING was mutated

	result.ok = true
	if validate_only:
		return result  # validated, NOT committed (SaveLoad Phase A)

	# --- Phase B: commit (only if all valid) ---
	counter = int(data["counter"])
	members = (data["members"] as Array).duplicate(true)
	_seeded_rng.get_rng(system_name()).state = SeededRNG.hex_to_int64(str(data["rng_state"]))
	return result
