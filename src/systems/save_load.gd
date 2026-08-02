## SaveLoad — the tick-boundary save coordinator (pure coordinator, owns no state).
##
## Story: save-load / story-001-saveblob-tick-boundary.md
## Req:   TR-SL-001 (coordinator, not state owner; tick-boundary saves),
##        TR-SL-002 (blob = {version, master_seed, time_system, grid_system,
##                  member_sim, congestion, satisfaction, economy}),
##        TR-SL-008 (ZoneRules/Navigation/PlacementSystem/SelectionSystem
##                  contribute NOTHING to the blob)
## ADR:   ADR-0002 (Storage Format — save blob is JSON at rest, composed here
##        as a flat Dictionary), ADR-0005 (Signal Bus — S2 tick_completed)
##
## SaveLoad holds no game state of its own: its whole job is to collect each
## coordinated system's serialize() output into ONE flat save blob, and to
## guarantee that collection happens only at a tick boundary (never mid-tick).
## The tick-boundary guarantee is STRUCTURAL, not polled: request_save() only
## sets the _save_pending flag; the actual serialize() calls fire from the
## tick_completed handler, which TimeSystem/Orchestrator emits at the end of
## every tick sequence (S2). Because the tick loop forbids mid-tick yielding,
## every moment external code can run is already a consistent snapshot.
##
## DEVIATION FROM STORY SKETCH (documented, not silent):
## The sketch connects `_time_system.tick_completed`. Story TS-001 locked
## tick_count ownership on SimulationOrchestrator, so the S2 signal is
## DECLARED ON THE ORCHESTRATOR (see simulation_orchestrator.gd header), not
## on TimeSystem. SaveLoad therefore subscribes to _orchestrator.tick_completed
## — same signal, same arity (tick_count: int), different host. The GDD's
## "TimeSystem's tick_completed hook" is satisfied via the orchestrator's
## signal, which TimeSystem's tick dispatch drives.
##
## DEVIATION #2 (serialize-once): the sketch builds the blob by calling
## _time_system.serialize() twice (once for the redundant top-level
## master_seed, once for the time_system payload). AC1 requires serialize() to
## be called exactly once per save request per system, so _perform_save()
## calls each system's serialize() exactly once and reuses the dict.
##
## BLOB SHAPE (TR-SL-002): exactly 8 flat keys, no more, no less.
##   {version, master_seed, time_system, grid_system, member_sim, congestion,
##    satisfaction, economy}
## The top-level master_seed is a READ-ONLY redundancy for save-file
## introspection — TimeSystem's copy is authoritative on load. Systems whose
## orchestrator field is null (stories not yet landed) contribute an empty {}
## so the key set is stable from the first save; load-time validation (Story
## 002) decides whether an empty payload is a valid empty state.
##
## ADR-0002 §3 note: the on-disk envelope ({format_version, payload}) is
## Story 004's concern (file I/O). This story produces the flat Dictionary.
class_name SaveLoad extends RefCounted

## Save blob format version (GDD Core Rule 6 — exact-match on load).
const SAVE_FORMAT_VERSION := 1

## The fixed blob key set — the textual source of truth for TR-SL-002.
## Missing key = load error; key outside this set (e.g. a future system that
## forgot to be added here) = load error (forward-compat gate, guardrail).
const CONTRIBUTING_KEYS := [
	"version", "master_seed",
	"time_system", "grid_system",
	"member_sim", "congestion", "satisfaction", "economy",
]

## Systems that deliberately contribute NOTHING (TR-SL-008): ZoneRules is a
## stateless pure function; Navigation/PlacementSystem/SelectionSystem are
## derived/rebuilt from GridSystem on load. Verified at blob-validation time,
## not just by convention (AC-BLOB-3).
const EXCLUDED_SYSTEMS := [
	"navigation", "placement_system", "selection_system", "zone_rules",
]

# === Coordinated system references — captured at init() from the orchestrator ===
# (the orchestrator's fields ARE the composition-root contract; see
# simulation_orchestrator.gd. Untyped deliberately — MemberSim/Congestion/
# Satisfaction/Economy classes do not exist in src/ yet.)
var _orchestrator: SimulationOrchestrator
var _time_system       # TimeSystem — also the tick_completed boundary source
var _grid_system       # GridSystem
var _member_sim        # MemberSim — null until its story lands
var _congestion        # Congestion — null until its story lands
var _satisfaction      # Satisfaction — null until its story lands
var _economy           # Economy — null until its story lands
# Systems that do NOT serialize but must be rebuilt on load (Story 002) —
# captured now per the story skeleton; Story 002's load orchestration uses
# them: PlacementSystem.rederive_counter(), SelectionSystem.rebuild_mapping(),
# Navigation.rebuild(occupancy).
var _placement_system  # PlacementSystem — null until its story lands
var _selection_system  # SelectionSystem — null until its story lands
var _navigation        # Navigation — null until its story lands

var _save_pending: bool = false
var _initialized: bool = false


## Two-phase init (ADR-0001). Captures the coordinated systems from the
## orchestrator. Safe to call once; a second call fires assert(false)
## (AC-INIT-1 pattern — init() returns void, so the assert is safe: it aborts
## only this frame, matching SimulationOrchestrator.init()).
func init(orchestrator: SimulationOrchestrator) -> void:
	if _initialized:
		assert(false, "SaveLoad.init() called twice")
		return
	_orchestrator = orchestrator
	_time_system = orchestrator.time_system
	_grid_system = orchestrator.grid_system
	_member_sim = orchestrator.member_sim
	_congestion = orchestrator.congestion
	_satisfaction = orchestrator.satisfaction
	_economy = orchestrator.economy
	_placement_system = orchestrator.placement_system
	_selection_system = orchestrator.selection_system
	_navigation = orchestrator.navigation
	_initialized = true


## Phase 2 wiring — subscribes to the tick_completed signal (S2) for the
## boundary-save guarantee. Must be called after init() and after all systems
## exist (the orchestrator calls this when it constructs SaveLoad in a later
## story; tests call it explicitly).
func _post_init() -> void:
	assert(_initialized, "SaveLoad._post_init() called before init()")
	# Subscribe to tick_completed for boundary-save guarantee. Host is the
	# orchestrator (see class header DEVIATION) — signal arity: 1 int.
	if not _orchestrator.tick_completed.is_connected(_on_tick_completed):
		_orchestrator.tick_completed.connect(_on_tick_completed)


## Tick-boundary save hook — connected to the S2 tick_completed signal, which
## fires at the END of each tick sequence (after every on_tick() call and
## after tick_count incremented). Never called directly by UI or _process;
## the only path into _perform_save() while the sim is running.
func _on_tick_completed(tick_count: int) -> void:
	if _save_pending:
		_save_pending = false
		_perform_save()


## THE ONLY public save entry point (called by UI / autosave triggers).
## Deferred save: sets a flag; the actual serialize() calls fire at the next
## tick boundary via _on_tick_completed. While paused no ticks fire, so the
## sim is already frozen at a boundary — save immediately (still structurally
## at a boundary, no mid-tick risk).
func request_save() -> void:
	if not _initialized:
		push_error("SaveLoad.request_save() called before init().")
		return
	_save_pending = true
	if _time_system != null and _time_system.is_paused():
		_save_pending = false
		_perform_save()


## Composes the save blob: exactly the 8 CONTRIBUTING_KEYS, each coordinated
## system's serialize() output collected exactly once. A null system (story
## not yet landed / genuinely empty state) contributes {} — the key is ALWAYS
## present so the blob shape is stable (AC-BLOB-1).
func _perform_save() -> Dictionary:
	if not _initialized:
		push_error("SaveLoad: _perform_save() called before init().")
		return {}
	if _time_system == null:
		push_error("SaveLoad: time_system not wired — cannot compose save blob.")
		return {}
	# Serialize TimeSystem exactly ONCE (AC1: one serialize() call per system
	# per save request) and reuse the dict for the redundant top-level seed.
	var time_data: Dictionary = _time_system.serialize()
	return {
		"version": SAVE_FORMAT_VERSION,
		"master_seed": time_data.get("master_seed", ""),
		"time_system": time_data,
		"grid_system": _serialize_or_empty(_grid_system),
		"member_sim": _serialize_or_empty(_member_sim),
		"congestion": _serialize_or_empty(_congestion),
		"satisfaction": _serialize_or_empty(_satisfaction),
		"economy": _serialize_or_empty(_economy),
	}


## Serializes one coordinated system, treating a not-yet-landed (null) system
## as an empty-state {} contribution. Every coordinated system's serialize()
## returns a Dictionary (their individual contracts, tested in their stories).
func _serialize_or_empty(system) -> Dictionary:
	if system == null:
		return {}
	return system.serialize()


## Validates the blob key contract (TR-SL-002 / guardrail: fixed key set).
## Returns every violation found:
##   - missing required key            -> error
##   - key outside CONTRIBUTING_KEYS   -> error (extra-key forward-compat gate;
##                                        EXCLUDED_SYSTEMS get a specific message)
##   - top-level master_seed diverging from TimeSystem's copy -> error
## Story 002's load path uses this as the first gate; the QA test also asserts
## the freshly composed blob passes with zero errors.
func _validate_blob_keys(blob: Dictionary) -> Array[String]:
	var errors: Array[String] = []

	# Required keys present
	for key in CONTRIBUTING_KEYS:
		if not blob.has(key):
			errors.append("SaveLoad: missing required key '%s' in save blob" % key)

	# No extra keys — the set is fixed (guardrail: extra key = load error).
	# EXCLUDED_SYSTEMS get the specific "should not serialize" message.
	for key in blob.keys():
		if key in CONTRIBUTING_KEYS:
			continue
		if key in EXCLUDED_SYSTEMS:
			errors.append("SaveLoad: unexpected key '%s' in save blob — this system should not serialize" % key)
		else:
			errors.append("SaveLoad: unexpected key '%s' in save blob — the blob key set is fixed" % key)

	# Master seed redundancy check (AC-BLOB-2 — redundancy, not divergence)
	if blob.has("master_seed") and blob.get("time_system") is Dictionary:
		var ts: Dictionary = blob["time_system"]
		if ts.get("master_seed", null) != blob["master_seed"]:
			errors.append("SaveLoad: top-level master_seed diverges from TimeSystem's copy")

	return errors
