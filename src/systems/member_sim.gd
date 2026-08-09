## MemberSim — member lifecycle state machine core (Story MS-001) + weighted
## target selection (Story MS-002) + access-cell reservation map and
## contention (Story MS-003).
##
## Story: member-sim / story-001-lifecycle-state-machine-core.md
##        member-sim / story-002-target-selection-weighted-pick.md
##        member-sim / story-003-reservation-map-contention.md
## Req:   TR-MS-001 (tick-driven, runs FIRST; all randomness via the
##        get_rng("MemberSim") sub-stream), TR-MS-002 (lifecycle state machine:
##        ENTERING -> SELECTING_TARGET -> WALKING_TO -> [QUEUEING] -> USING ->
##        LEAVING -> GONE), TR-MS-003 (target selection: candidate pool,
##        weight from Congestion(t-1)/distance/novelty, top-K=3-5, path-check,
##        weighted-random draw), TR-MS-004 (access-cell reservation map
##        reservations[equipment_instance_id] = {occupant, next_claimant};
##        queue depth 1 MVP), TR-MS-005 (release invariant: a member leaving
##        WALKING_TO/QUEUEING without becoming occupant clears next_claimant
##        the SAME tick — deadlock prevention), TR-MS-006 (fairness: all
##        contention resolves by ascending member_id iteration order, never
##        engine/hash order), TR-MS-008 (arrival Bernoulli formula),
##        TR-MS-009 (use_duration formula), TR-MS-010 (exercises_per_visit
##        formula), TR-MS-012 (member_id never reused), TR-MS-013 (entrance_cell
##        / exit_cell hard dependency), TR-MS-014 (member_completed_visit S5)
## ADR:   ADR-0003 (GridStateReader read surface — occupancy/access reads go
##        through the typed read-only contract, never internal representation),
##        ADR-0004 (SeededRNG sub-stream — fixed RNG consumption order:
##        arrival roll first, then per-member updates in ascending member_id
##        order; state serialized as hex and restored directly),
##        ADR-0005 (Signal Bus — S5 member_completed_visit owned here, fires
##        ONLY on quota-met departures; Satisfaction events are direct reads,
##        not signals)
##
## THIS FILE REPLACES THE SL-002 CORE-LAYER INTEGRATION STUB. The public
## contract surface SaveLoad depends on is preserved exactly:
##   - class_name MemberSim extends SimSystem
##   - init(orchestrator, seeded_rng) — extra OPTIONAL parameters (the state
##     machine's grid/navigation/catalog/entrance/exit/config/congestion_reader
##     default to null so pre-wiring call sites keep working; TR-MS-013 says
##     the composition root supplies entrance/exit at init).
##   - system_name() == "MemberSim"
##   - on_tick(tick_count: int) -> void  (the orchestrator's fixed dispatch)
##   - serialize() / deserialize(data, validate_only, known_instance_ids)
##     two-phase protocol (Phase A zero-mutation validate, Phase B commit),
##     returning StubDeserializeResult (the shared stub DTO is retained until
##     story 005 defines the real result class).
##
## PRE-WIRING COMPATIBILITY PATH (documented, not silent): the SL-002
## save-load integration tests (roundtrip_determinism, load_orchestration)
## construct MemberSim with ONLY init(orchestrator, seeded_rng) — no grid,
## no navigation, no entrance/exit. Such an instance is NOT configured to
## drive the state machine (it cannot path or spawn meaningfully), so
## on_tick() keeps the stub's observable behavior exactly (counter += 1, one
## RNG draw per tick) and members stay passive roster entries. The state
## machine engages only when the system is fully configured. This preserves
## the byte-identical determinism contract of the existing integration tests
## while the real machine ships.
##
## STATE MACHINE SCOPE: Core Rule 2's full transition list. Story 003 (this
## file) adds QUEUEING + the access-cell reservation map (Core Rule 4).
## Story 004 (this file) adds path invalidation (Core Rule 5 / TR-MS-007:
## grid_version stamp re-query, exactly once per tick), the bounded repath
## retry (AC18: retry_limit consecutive empty results -> release + LEAVING),
## the patience give-up short-term blacklist (AC19: no flip-flop back to the
## abandoned machine) and the mid-use deletion interrupt with its
## satisfaction-penalty read surface (AC14).
## STORY 005 SCOPE — serialization, determinism and the flow hypothesis.
## This story closes the epic by wiring the FULL serialization contract:
##   - serialize() emits the JSON-safe cell encoding for member state
##     (`cell` -> [x, y], `cached_path` -> [[x, y], ...] — the same [x, y]
##     convention GridSystem._serialize_cells uses, so the blob survives
##     JSON.stringify/parse with no type ambiguity). member_id_counter is
##     serialized EXPLICITLY (TR-MS-011): it can never be re-derived from
##     the active set, because GONE members' ids are retired forever
##     (TR-MS-012) — max(active)+1 would silently reuse a retired id.
##   - deserialize() enforces AC8: a payload MISSING member_id_counter, or
##     whose member_id_counter <= the max id of any state-machine member in
##     the payload, FAILS loudly — never silently substitutes a derived
##     value. The counter-vs-max check covers state-bearing members only:
##     legacy SL-002-era stub entries ({member_id, equipment_instance_id},
##     no "state" key) are passive roster data that was never allocated
##     from the counter, so they are exempt — this is what keeps the
##     pre-wiring save-load integration tests (SL-003 roundtrip canary,
##     SL-002 load orchestration) passing unchanged while the real machine
##     enforces monotonicity.
##   - the reservation map is REBUILT from members' own serialized claim
##     flags on load (Core Rule 7 — never serialized as separate truth):
##     USING -> occupant, WALKING_TO/QUEUEING -> next_claimant. Load-side
##     AC4 mirror: two members claiming the same machine's occupant or
##     queue slot is a structural corruption and fails validation.
##   - use_duration now reads per-equipment fields from EquipmentCatalog
##     (TR-MS-009) via an optional init-injected `equipment_id_resolver`
##     (instance_id -> equipment_id Callable); absent resolver -> the
##     config defaults (the pre-wiring rigs' deterministic behavior).
## Deliberately deferred to neighbouring stories and NOT implemented here:
##   - (Story 005 removes the last deferral: full serialization + rebuild)
## Story 002 implements the weighted target pick — Core Rule 3:
##   candidate pool (all placed instances ascending equipment_instance_id —
##   no-repeat blacklist is Story 004) -> weight per candidate -> sort desc
##   with deterministic tie-break by ascending id -> top-K (config, 3-5) ->
##   path-check the K in ascending id order -> renormalize over survivors ->
##   ONE rng.randf() weighted draw.
## Story 003 (this file) implements Core Rule 4:
##   reservations[equipment_instance_id] = {occupant: member_id?,
##   next_claimant: member_id?} — MemberSim owns the map (GridSystem refused
##   to), queue depth capped at 1. Claim rule: a member may set next_claimant
##   iff currently null (free machine -> walk + become occupant; busy machine
##   -> become the single queue slot). On arrival: occupant null -> claim
##   occupant + clear next_claimant -> USING; else -> QUEUEING holding
##   next_claimant (guaranteed FIFO of exactly one). Release invariant
##   (TR-MS-005): any member holding next_claimant that leaves WALKING_TO or
##   QUEUEING without becoming occupant clears next_claimant in the SAME tick
##   — the lock stays opportunistic and self-cleaning. Fairness (TR-MS-006):
##   contention resolves purely by ascending-member_id update order; the
##   candidate pool EXCLUDES fully-spoken-for equipment (next_claimant held
##   by another member) — the losing member's redraw skips it (AC3).
##
## STORY 003 SEAM (documented, not silent): the patience give-up transition
## exists here in minimal form (QUEUEING patience countdown -> release +
## SELECTING_TARGET) so the TR-MS-005 release invariant is exercisable; the
## short-term no-repeat blacklist that prevents give-up flip-flop belongs to
## Story 004 (patience give-up + path invalidation). A give-up member may
## therefore re-claim the same equipment on a later reselect — bounded by
## patience each cycle, not by a blacklist.
##
## STORY 004 SCOPE — the formal path-invalidation + patience systems:
##   - PATH INVALIDATION (Core Rule 5, AC17): every WALKING_TO / LEAVING
##     tick compares the cached path's grid_version stamp (member field
##     cached_path_grid_version) against _grid.get_grid_version(); on
##     mismatch, Navigation.get_path is re-queried EXACTLY ONCE that tick.
##     Empty result is treated identically whether the grid changed blocked
##     the path or the target equipment was deleted — release reservation,
##     bounded retry (AC18), else LEAVING. No special-casing.
##   - BOUNDED RETRY (AC18): a repath-empty result increments the member's
##     repath_failures counter; on reaching _repath_retry_limit consecutive
##     failures the member releases its reservation and LEAVING (reason
##     "path_blocked" — distinct from AC1's no_candidates). A successful
##     repath / successful reselect resets the counter.
##   - PATIENCE GIVE-UP BLACKLIST (AC19): on patience exhaustion the member
##     adds the abandoned equipment to its give_up_blacklist (id ->
##     remaining_ticks, decremented per tick) so a same/next-tick reselect
##     excludes it — no immediate flip-flop back. Entries expire after
##     give_up_blacklist_ticks (config) and the machine becomes eligible
##     again. Also applies a temporary novelty penalty (as if just-used).
##   - MID-USE DELETION (AC14): a USING member whose target equipment no
##     longer resolves (access cells empty) interrupts gracefully ->
##     SELECTING_TARGET, emits exactly one satisfaction-penalty event
##     (exposed via get_satisfaction_penalty_events() — the ADR-0005 §3
##     direct method read Satisfaction consumes during its on_tick).
##
## CONGESTION READER SEAM (TR-MS-003 / AC11): the weight consumes
## `Congestion(t-1)` — the PRE-update value — as a per-equipment-instance
## scalar in [0,1]. The real Congestion system (congestion epic story 001)
## owns the double-buffered prev/next state and exposes the read surface
## `per_equipment_congestion(equipment_instance_id) -> float` serving from
## the `prev` buffer during the whole tick. MemberSim receives that reader as
## an optional init dependency (duck-typed object — the class does not exist
## in src/ yet). When absent, congestion is treated as 0.0 (neutral), which
## keeps the pre-wiring and MS-001-era rigs deterministic. Tick ORDER (the
## [INT] half of AC11: MemberSim before Congestion in _advance_tick()) is
## pinned textually by SimulationOrchestrator.FIXED_TICK_ORDER and verified
## by tests/unit/member_sim/tick_order_test.gd.
##
## WEIGHT FORMULA (Core Rule 3 / GDD Formulas):
##   weight_i = BASE_WEIGHT × exp(-k_congestion × Congestion_i(t-1))
##              × exp(-k_proximity × dist_i / D_max)
##              × novelty_factor_i × preference_weight_i × pref_noise_i
##   - dist_i = Chebyshev distance (cells) from the member to the access cell
##     — the geometric proxy, NOT the pathfinding length: Core Rule 3 forbids
##     pathfinding every candidate (top-K guardrail), so the weight is
##     computed before any get_path(); exact reachability is verified only
##     for the top-K.
##   - novelty_factor_i ∈ {0.2 just-used, 0.6 recent, 1.0} — suppressed
##     immediate repeats via the member's recently_used_ids (updated on each
##     completed use).
##   - preference_weight_i = the member's resolved preference-type weight for
##     the candidate EquipmentDef.zone_membership (strength/cardio/flex).
##   - pref_noise_i = the member's stored preference_profile.preference_noise
##     (Uniform(0.85, 1.15), rolled at spawn).
##   - WEIGHT_EPSILON floor keeps every weight strictly positive — fully
##     congested floors never zero out (AC12: no divide-by-zero, no NaN).
##   - Config keys: k_congestion (3), k_proximity (0.2), D_max (16),
##     top_k (4). See class-header CONFIG_* block.
##
## AC1 / QA "wanders ~20 ticks" NOTE: the story QA edge case describes an
## empty gym as "member wanders ~20 ticks then leaves calmly". The BLOCKING
## assertion is "state == LEAVING by end of the same tick" (no extra tick
## stalled), so the skeleton implements immediate LEAVING on an empty
## candidate pool. The calm-wander behavior belongs to Story 004's patience
## system (out of scope here).
##
## USE-DURATION NOTE: TR-MS-009 rolls duration from per-equipment catalog
## fields, resolved via the init-injected `equipment_id_resolver` Callable
## (instance_id -> equipment_id; the GridSystem stores only integer
## occupant_id and PlacedInstance.equipment_id is "" — the resolution is
## the composition root's wiring, not grid data). When the resolver is
## absent or the id doesn't resolve to a catalog def, the roll falls back
## to the config's default use-duration range (the pre-wiring rigs'
## deterministic behavior — Story 005).
##
## CONFIG DICTIONARY (data-driven seam): all gameplay tuning values arrive
## via the init [config] Dictionary (defaults = GDD Tuning Knobs anchors). A
## future game-config file (JSON) maps directly onto this shape — the
## composition root owns the values, never hardcoded per-run behaviour here.
class_name MemberSim extends SimSystem

# === State machine (Core Rule 2) ===
const STATE_ENTERING := "ENTERING"
const STATE_SELECTING_TARGET := "SELECTING_TARGET"
const STATE_WALKING_TO := "WALKING_TO"
const STATE_QUEUEING := "QUEUEING"
const STATE_USING := "USING"
const STATE_LEAVING := "LEAVING"
const STATE_GONE := "GONE"
const VALID_STATES: Array[String] = [
	STATE_ENTERING, STATE_SELECTING_TARGET, STATE_WALKING_TO,
	STATE_QUEUEING, STATE_USING, STATE_LEAVING, STATE_GONE,
]

# === Member preference profiles (A1 gameplay-depth extension) ===
const PREF_STRENGTH := "STRENGTH"
const PREF_CARDIO := "CARDIO"
const PREF_FLEX := "FLEX"
const PREF_BALANCED := "BALANCED"
const PREF_TYPES: Array[String] = [
	PREF_STRENGTH, PREF_CARDIO, PREF_FLEX, PREF_BALANCED,
]

## Resolved category multipliers stored in every newly spawned member's
## preference_profile. Specialists strongly favor their own zone while still
## retaining a positive chance to use the other zones; BALANCED preserves the
## pre-A1 target-selection behavior exactly (all category weights = 1.0).
const PREF_CATEGORY_WEIGHTS := {
	PREF_STRENGTH: {"strength": 1.5, "cardio": 0.8, "flex": 0.8},
	PREF_CARDIO: {"strength": 0.8, "cardio": 1.5, "flex": 0.8},
	PREF_FLEX: {"strength": 0.8, "cardio": 0.8, "flex": 1.5},
	PREF_BALANCED: {"strength": 1.0, "cardio": 1.0, "flex": 1.0},
}

## Story 005: the int-typed fields of a state-machine member record. These
## are validated as numeric on load (int|float — JSON.parse returns floats
## for integer literals in 4.7.1) and coerced to int at commit.
const STATE_MEMBER_INT_KEYS: Array[String] = [
	"exercises_done", "exercises_per_visit", "target_equipment_instance_id",
	"cached_path_grid_version", "repath_failures", "patience_ticks_remaining",
	"leaving_timeout_ticks", "use_ticks_remaining",
	"last_completed_equipment_level", "visit_revenue_multiplier_count",
]

## Why a member left the gym (drives S5 emission — quota-met departures only).
const REASON_QUOTA_MET := "quota_met"
const REASON_NO_CANDIDATES := "no_candidates"
## Story 004 (AC18): repath-empty for retry_limit consecutive attempts —
## bounded-retry exhaustion, deliberately distinct from AC1's
## no_candidates. Also calm: S5 only fires on quota_met, so no signal here.
const REASON_PATH_BLOCKED := "path_blocked"

# === Config keys (see class header — the data-driven seam) ===
const CONFIG_MAX_CONCURRENT_MEMBERS := "max_concurrent_members"
const CONFIG_BASE_ARRIVAL_RATE_PER_MIN := "base_arrival_rate_per_min"
const CONFIG_SATISFACTION_MODIFIER := "satisfaction_modifier"
const CONFIG_VISIT_LENGTH_MODIFIER := "visit_length_modifier"
const CONFIG_USE_DURATION_MEAN_TICKS := "use_duration_mean_ticks"
const CONFIG_USE_DURATION_STDDEV_TICKS := "use_duration_stddev_ticks"
const CONFIG_USE_DURATION_MIN_TICKS := "use_duration_min_ticks"
const CONFIG_USE_DURATION_MAX_TICKS := "use_duration_max_ticks"
const CONFIG_LEAVING_TIMEOUT_TICKS := "leaving_timeout_ticks"
const CONFIG_EXERCISES_MEAN := "exercises_mean"
const CONFIG_EXERCISES_STDDEV := "exercises_stddev"
const CONFIG_EXERCISES_MIN := "exercises_min"
const CONFIG_EXERCISES_MAX := "exercises_max"
const CONFIG_K_CONGESTION := "k_congestion"
const CONFIG_K_PROXIMITY := "k_proximity"
const CONFIG_D_MAX := "D_max"
const CONFIG_TOP_K := "top_k"
const CONFIG_PATIENCE_MIN_TICKS := "patience_min_ticks"
const CONFIG_PATIENCE_MAX_TICKS := "patience_max_ticks"
const CONFIG_REPATH_RETRY_LIMIT := "repath_retry_limit"
const CONFIG_GIVE_UP_BLACKLIST_TICKS := "give_up_blacklist_ticks"

## Weight formula constants (Core Rule 3 / GDD Formulas — see class header).
const BASE_WEIGHT := 1.0
const WEIGHT_EPSILON := 1e-9  # strict positivity floor — AC12 (no NaN, no 0)
const NOVELTY_JUST_USED := 0.2
const NOVELTY_RECENT := 0.6
const NOVELTY_FRESH := 1.0
const NOVELTY_RECENT_WINDOW := 3  # track the last 3 used ids (just-used + 2 recent)

## S5 in the ADR-0005 Signal Catalog. Fires exactly once per quota-met
## departure, when the member transitions to GONE — NEVER on walk-failure
## (AC1/AC2 "no candidates") departures. Arity: exactly 1 int (test-verified).
## Subscribers (Economy, Satisfaction) connect during their _post_init().
signal member_completed_visit(member_id: int)

## Injected composition root (kept for signature symmetry with the stub —
## Story 001's state machine receives its dependencies through init params).
var _orchestrator: SimulationOrchestrator
## Injected SeededRNG registry — this system's sub-stream lives here
## (ADR-0004). All randomness goes through get_rng("MemberSim").
var _seeded_rng: SeededRNG

## The member roster. Public because the SaveLoad integration tests read and
## write it directly (the stub contract — do not rename/type-tighten).
## Each entry is a Dictionary. Two shapes coexist:
##   - LEGACY (pre-state-machine save data / integration tests):
##       {member_id: int, equipment_instance_id: int}
##     Passive — never driven by the state machine, preserved verbatim by
##     serialize()/deserialize() so old blobs round-trip unchanged.
##   - FULL (spawned by the state machine):
##       {member_id, state, cell: Vector2i, exercises_done, exercises_per_visit,
##        preference_profile: Dictionary, target_equipment_instance_id,
##        cached_path: Array[Vector2i], cached_path_grid_version: int (Story 004
##        — the grid_version stamp the cached path was computed at; -1 = never
##        stamped, forces a first-tick re-query),
##        repath_failures: int (Story 004 — consecutive empty repath results,
##        bounded by _repath_retry_limit, AC18),
##        give_up_blacklist: Dictionary (Story 004 — abandoned equipment id ->
##        remaining_ticks; excludes the machine from reselect until expiry, AC19),
##        leaving_timeout_ticks, use_ticks_remaining (USING only),
##        leaving_reason (LEAVING only), patience_ticks_remaining (QUEUEING
##        only — Story 003 patience countdown), recently_used_ids: Array
##        (most-recent-first, capped at NOVELTY_RECENT_WINDOW — drives
##        novelty_factor_i in Story 002)}
var members: Array = []

## Story 003 — the access-cell reservation map (Core Rule 4 / TR-MS-004).
## MemberSim owns it (GridSystem explicitly refused). Keyed by
## equipment_instance_id -> {"occupant": member_id?, "next_claimant":
## member_id?}; null = free. Queue depth is capped at 1 (MVP): at most one
## next_claimant per machine, and the claim rule (next_claimant settable iff
## null) enforces it structurally.
##
## DETERMINISM (TR-MS-006): records are read/written only by KEYED access
## from per-member updates in ascending member_id order — the map itself is
## NEVER iterated for behavior (Dictionary iteration is engine-ordered).
## Consumers iterate placed instances ascending id instead.
##
## SERIALIZATION NOTE (Story 005 owns this): the map is NOT serialized as
## separate truth. Core Rule 7 rebuilds it from members' own claim flags on
## load; until Story 005 lands, a deserialized member mid-claim degrades
## gracefully (its _on_queueing/_handle_arrival defensive branches release
## and reselect instead of deadlocking).
var reservations: Dictionary = {}

## Per-tick counter. Kept from the SL-002 stub as an observable stand-in; the
## pre-wiring compatibility path increments it every tick (integration tests
## rely on the exact stub behaviour). Serialized with the blob.
var counter: int = 0

## Monotonic member id allocator. Serialized EXPLICITLY (TR-MS-011): it can
## never be re-derived from the active set, because GONE members' ids are
## retired forever (TR-MS-012) — max(active)+1 would silently reuse a retired
## id. Story 005 owns the full serialization contract; the skeleton already
## persists it to keep spawns collision-free across a save/load boundary.
var _member_id_counter: int = 0

# === State machine dependencies (TR-MS-013 — supplied at init) ===
var _grid: GridStateReader = null
var _navigation: Navigation = null
var _catalog: EquipmentCatalog = null
var _entrance_cell: Vector2i = Vector2i(-1, -1)  # (-1,-1) = not supplied
var _exit_cell: Vector2i = Vector2i(-1, -1)      # (-1,-1) = not supplied

## Congestion reader seam (Story 002 / TR-MS-003 / AC11). Duck-typed object
## exposing `per_equipment_congestion(equipment_instance_id: int) -> float`
## serving the PRE-update (t-1) value from Congestion's `prev` buffer. The
## real Congestion class does not exist in src/ yet (congestion story 001);
## when absent, congestion is treated as 0.0 (neutral) — never a crash.
var _congestion_reader: Variant = null

## Story 005 (TR-MS-009): resolves an equipment_instance_id to its
## equipment_id String so use_duration can read per-equipment catalog
## fields. GridSystem stores only integer occupant_id (PlacedInstance.
## equipment_id is "") — the resolution is the composition root's wiring.
## A valid resolver returning a known catalog id selects that def's
## use_duration_* fields; otherwise _roll_use_duration falls back to the
## config defaults (the pre-wiring rigs' deterministic behavior).
var _equipment_id_resolver: Callable = Callable()

## A2 upgrade reader. Duck-typed EquipmentUpgradeSystem supplying get_level()
## and attraction_multiplier_for_level(). Optional so pre-A2 rigs remain
## neutral and consume the exact same RNG sequence.
var _upgrade_reader: Variant = null

# === Tuning values (GDD Tuning Knobs anchors; see class header) ===
var _max_concurrent_members: int = 17
var _base_arrival_rate_per_min: float = 4.0
var _satisfaction_modifier: float = 1.0
var _visit_length_modifier: float = 1.0
var _use_duration_mean_ticks: int = 200
var _use_duration_stddev_ticks: int = 35
var _use_duration_min_ticks: int = 100
var _use_duration_max_ticks: int = 300
var _leaving_timeout_ticks: int = 300
var _exercises_mean: float = 3.0
var _exercises_stddev: float = 1.0
var _exercises_min: int = 1
var _exercises_max: int = 5
var _k_congestion: float = 3.0
var _k_proximity: float = 0.2
var _d_max: int = 16
var _top_k: int = 4
var _patience_min_ticks: int = 30
var _patience_max_ticks: int = 80
## Story 004 (AC18): consecutive empty repath results before bounded-retry
## exhaustion -> release reservation + LEAVING. Default 3 (GDD guardrail:
## "never tight-loop the same query"; 1 would make any transient blockage
## force a leave, so >1 gives a real retry window).
var _repath_retry_limit: int = 3
## Story 004 (AC19): how many ticks a patience-give-up equipment stays on the
## member's short-term no-repeat blacklist ("entries expire after a few
## ticks" — 10 ticks = 1s at 10 Hz).
var _give_up_blacklist_ticks: int = 10

## Story 004 (AC14): satisfaction-penalty event counter for the CURRENT tick.
## Reset at the start of every configured on_tick; incremented exactly once
## per mid-use equipment deletion. Satisfaction reads it during ITS on_tick()
## (which runs after MemberSim in the fixed tick order) via
## get_satisfaction_penalty_events() — the ADR-0005 §3 direct method read,
## NOT a cross-system signal.
var _satisfaction_penalty_events: int = 0


## Two-phase init (ADR-0001). Registers the MemberSim RNG sub-stream exactly
## once (SeededRNG.register_system is the hard gate — a duplicate asserts).
##
## [grid] / [navigation] / [catalog] / [entrance_cell] / [exit_cell] are the
## state machine's hard upstream dependencies (TR-MS-013: "the orchestrator
## must supply them at init"). All optional with null/(-1,-1) defaults so the
## SL-002-era call sites `init(orchestrator, seeded_rng)` keep working — an
## instance without grid + navigation + entrance/exit is NOT configured and
## runs the pre-wiring compatibility path (see class header).
##
## [config] carries the data-driven tuning values (class-header CONFIG_*
## keys); missing keys fall back to the GDD anchors.
##
## [congestion_reader] (Story 002) is the duck-typed prev-buffer reader
## (`per_equipment_congestion(id) -> float`, see the _congestion_reader
## field). Optional — when null the weight treats every equipment as
## congestion 0.0, preserving the MS-001-era rigs' determinism.
##
## [equipment_id_resolver] (Story 005, TR-MS-009) is the instance_id ->
## equipment_id Callable the composition root wires (GridSystem does not
## store equipment ids). Optional — when invalid/empty the use-duration
## roll falls back to the config defaults.
func init(
	orchestrator: SimulationOrchestrator,
	seeded_rng: SeededRNG,
	grid: GridStateReader = null,
	navigation: Navigation = null,
	catalog: EquipmentCatalog = null,
	entrance_cell: Vector2i = Vector2i(-1, -1),
	exit_cell: Vector2i = Vector2i(-1, -1),
	config: Dictionary = {},
	congestion_reader: Variant = null,
	equipment_id_resolver: Callable = Callable(),
	upgrade_reader: Variant = null
) -> void:
	if not _mark_initialized():
		return
	_orchestrator = orchestrator
	_seeded_rng = seeded_rng
	_grid = grid
	_navigation = navigation
	_catalog = catalog
	_entrance_cell = entrance_cell
	_exit_cell = exit_cell
	_congestion_reader = congestion_reader
	_equipment_id_resolver = equipment_id_resolver
	_upgrade_reader = upgrade_reader
	_apply_config(config)
	_seeded_rng.register_system(system_name())


## Reads the [config] Dictionary into the tuning fields. Missing keys keep
## the GDD-anchor defaults (see class header). Values are coerced with int()/
## float() so a future JSON config file maps onto this shape directly.
func _apply_config(config: Dictionary) -> void:
	_max_concurrent_members = int(config.get(CONFIG_MAX_CONCURRENT_MEMBERS, _max_concurrent_members))
	_base_arrival_rate_per_min = float(config.get(CONFIG_BASE_ARRIVAL_RATE_PER_MIN, _base_arrival_rate_per_min))
	_satisfaction_modifier = clampf(
		float(config.get(CONFIG_SATISFACTION_MODIFIER, _satisfaction_modifier)), 0.5, 2.0)
	_visit_length_modifier = clampf(
		float(config.get(CONFIG_VISIT_LENGTH_MODIFIER, _visit_length_modifier)), 0.75, 1.5)
	_use_duration_mean_ticks = int(config.get(CONFIG_USE_DURATION_MEAN_TICKS, _use_duration_mean_ticks))
	_use_duration_stddev_ticks = int(config.get(CONFIG_USE_DURATION_STDDEV_TICKS, _use_duration_stddev_ticks))
	_use_duration_min_ticks = int(config.get(CONFIG_USE_DURATION_MIN_TICKS, _use_duration_min_ticks))
	_use_duration_max_ticks = int(config.get(CONFIG_USE_DURATION_MAX_TICKS, _use_duration_max_ticks))
	_leaving_timeout_ticks = int(config.get(CONFIG_LEAVING_TIMEOUT_TICKS, _leaving_timeout_ticks))
	_exercises_mean = float(config.get(CONFIG_EXERCISES_MEAN, _exercises_mean))
	_exercises_stddev = float(config.get(CONFIG_EXERCISES_STDDEV, _exercises_stddev))
	_exercises_min = int(config.get(CONFIG_EXERCISES_MIN, _exercises_min))
	_exercises_max = int(config.get(CONFIG_EXERCISES_MAX, _exercises_max))
	_k_congestion = float(config.get(CONFIG_K_CONGESTION, _k_congestion))
	_k_proximity = float(config.get(CONFIG_K_PROXIMITY, _k_proximity))
	_d_max = int(config.get(CONFIG_D_MAX, _d_max))
	# Top-K guardrail: the GDD pins K to 3-5 (perf cap against O(members ×
	# equipment) pathfinding). Clamp so a misconfigured value can never break
	# the bound.
	_top_k = clampi(int(config.get(CONFIG_TOP_K, _top_k)), 3, 5)
	# Patience bounds (GDD Formulas — second-most-important knob, anchors
	# 30-80). A misconfigured min > max is clamped to a legal single value.
	_patience_min_ticks = maxi(int(config.get(CONFIG_PATIENCE_MIN_TICKS, _patience_min_ticks)), 0)
	_patience_max_ticks = maxi(int(config.get(CONFIG_PATIENCE_MAX_TICKS, _patience_max_ticks)), _patience_min_ticks)
	# Story 004 bounded-retry knob (AC18). Guardrail: at least 1 — a
	# misconfigured 0/negative value would make the FIRST empty repath force
	# LEAVING, defeating the retry window entirely.
	_repath_retry_limit = maxi(int(config.get(CONFIG_REPATH_RETRY_LIMIT, _repath_retry_limit)), 1)
	# Story 004 give-up blacklist duration (AC19).
	_give_up_blacklist_ticks = maxi(int(config.get(CONFIG_GIVE_UP_BLACKLIST_TICKS, _give_up_blacklist_ticks)), 0)


func system_name() -> String:
	return "MemberSim"


## Applies Satisfaction's two feedback legs at a tick boundary. The
## orchestrator calls this before MemberSim's tick, so both the arrival roll
## and any visit spawned on that tick observe one coherent G snapshot.
func set_satisfaction_feedback(arrival_modifier: float, visit_length_modifier: float) -> void:
	if not _assert_initialized():
		return
	_satisfaction_modifier = clampf(arrival_modifier, 0.5, 2.0)
	_visit_length_modifier = clampf(visit_length_modifier, 0.75, 1.5)


## True when every hard upstream dependency has been supplied, i.e. the
## state machine can actually run: a grid read surface, a pathfinder, and
## real entrance/exit cells. Until then on_tick() runs the pre-wiring
## compatibility path (class header).
func _is_configured() -> bool:
	return _grid != null \
		and _navigation != null \
		and _entrance_cell != Vector2i(-1, -1) \
		and _exit_cell != Vector2i(-1, -1)


## Returns this system's RNG sub-stream (ADR-0004). Registered in init().
func _rng() -> RandomNumberGenerator:
	return _seeded_rng.get_rng(system_name())


## Per-tick entry point — invoked FIRST in the orchestrator's fixed dispatch
## (FIXED_TICK_ORDER, TR-TS-003). No await / yield inside: the tick boundary
## stays a safe save point (TR-TS-004).
##
## UNCONFIGURED PATH (pre-wiring compatibility, see class header): preserves
## the SL-002 stub's observable behaviour byte-for-byte (counter += 1, one
## RNG draw) so the existing save-load integration determinism tests keep
## passing unchanged.
##
## CONFIGURED PATH (Core Rule 1): (a) arrival check FIRST — one Bernoulli
## draw from the sub-stream; (b) then every active member is updated exactly
## once, iterating in ASCENDING member_id order (never scene-tree or hash
## order) so behavior is deterministic (Core Rule 6, AC6). Only members
## spawning / starting a use draw from the sub-stream (Core Rule 7).
func on_tick(tick_count: int) -> void:
	if not _assert_initialized():
		return
	counter += 1
	if not _is_configured():
		_seeded_rng.get_rng(system_name()).randi()
		return
	# Story 004 (AC14): per-tick satisfaction-penalty window — reset at the
	# START of the tick so Satisfaction (running later in the fixed order)
	# reads exactly this tick's mid-use deletion events.
	_satisfaction_penalty_events = 0
	_process_arrival()
	_process_members()


## Story 004 (AC14): the ADR-0005 §3 direct read Satisfaction consumes during
## its on_tick() — the number of mid-use equipment deletions this tick
## (exactly one event per interrupted member). Not a cross-system signal.
func get_satisfaction_penalty_events() -> int:
	if not _assert_initialized():
		return 0
	return _satisfaction_penalty_events


## (a) Arrival check — runs FIRST every tick (Core Rule 6). One Bernoulli
## draw from the sub-stream; on success and under the cap, spawns a member at
## the entrance cell.
func _process_arrival() -> void:
	var p_tick := _arrival_probability()
	if _rng().randf() < p_tick:
		_spawn_member()


## (b) Update every active member exactly once in ascending member_id order.
## Members that reach GONE during their update are removed AFTER the loop
## (the id-ordered iteration must not mutate the roster mid-pass — and a
## member's own update may not affect another member's turn, Core Rule 6).
func _process_members() -> void:
	var by_id: Dictionary = {}
	for m in members:
		if m is Dictionary and m.has("member_id"):
			by_id[int(m["member_id"])] = m
	var ids: Array = by_id.keys()
	ids.sort()
	var to_remove: Array = []
	for member_id in ids:
		_update_member(by_id[member_id], to_remove)
	for m in to_remove:
		members.erase(m)


## Dispatches one member's per-tick update by state. Legacy roster entries
## (no "state" key) are passive — skipped, never driven, never despawned.
func _update_member(member: Dictionary, to_remove: Array) -> void:
	if not member.has("state"):
		return
	# Story 004 (AC19): blacklist entries tick down for every active member,
	# regardless of state — the exclusion is time-bounded, not state-bounded.
	_tick_give_up_blacklist(member)
	match str(member["state"]):
		STATE_ENTERING:
			_on_entering(member)
		STATE_SELECTING_TARGET:
			_on_selecting_target(member)
		STATE_WALKING_TO:
			_on_walking_to(member)
		STATE_QUEUEING:
			_on_queueing(member)
		STATE_USING:
			_on_using(member)
		STATE_LEAVING:
			_on_leaving(member, to_remove)
		STATE_GONE:
			to_remove.append(member)


## ENTERING is a pass-through spawn tick — immediately evaluates
## SELECTING_TARGET the same tick (Core Rule 2 / States and Transitions).
func _on_entering(member: Dictionary) -> void:
	member["state"] = STATE_SELECTING_TARGET
	_on_selecting_target(member)


## SELECTING_TARGET evaluation (Core Rule 2). Outcomes:
##   (a) visit quota reached      -> LEAVING regardless of candidates (AC2)
##   (b) no reachable candidate   -> LEAVING the same tick (AC1 — the visible
##       "walked in, turned around, left" flow signal; never stalls)
##   (b') pool emptied by CONTENTION (every remaining machine's queue slot is
##       claimed by another member) -> STAY in SELECTING_TARGET and retry next
##       tick — no partial state committed (Core Rule 3 step 6; AC3 QA edge)
##   (b'') pool emptied by the give-up BLACKLIST (AC19) -> STAY and retry —
##       the excluded machine becomes eligible again after
##       give_up_blacklist_ticks, so this is a temporary exclusion, never a
##       failure prompt (Pillar 2).
##   (c) candidate found          -> WALKING_TO (Story 002: the weighted pick —
##       candidate pool -> weights -> top-K sort -> path-check -> weighted
##       draw; Story 003: claim the reservation's next_claimant slot BEFORE
##       walking — Core Rule 4, TR-MS-004; Story 004: the cached path is
##       stamped with the CURRENT grid_version so WALKING_TO can detect
##       invalidation — Core Rule 5, AC17)
func _on_selecting_target(member: Dictionary) -> void:
	# Defensive invariant: entering SELECTING_TARGET implies NO claim held
	# (every transition into this state releases first — Story 003). This
	# guards the member-aware "fully spoken for" exclusion against a stale
	# residual claim.
	_release_reservation(member)
	if int(member["exercises_done"]) >= int(member["exercises_per_visit"]):
		_begin_leaving(member, REASON_QUOTA_MET)
		return
	var target_id := _pick_weighted_target(member)
	if target_id == -1:
		if _any_fully_spoken_for():
			# Contention, not absence: every remaining machine's single queue
			# slot is held by a lower-`member_id` member. Stay in
			# SELECTING_TARGET (no partial state committed) — a claim slot
			# will free up (release invariant, TR-MS-005) and the retry
			# succeeds. AC3 QA edge.
			return
		if _has_active_give_up_blacklist(member):
			# Story 004 (AC19 / AC13 QA edge): the pool was emptied by the
			# member's own short-term no-repeat blacklist (the machine it just
			# gave up on), not by absence. Stay and retry — the blacklist
			# expires after give_up_blacklist_ticks and the machine becomes
			# eligible again. Never a failure prompt (Pillar 2).
			return
		# Story 004 (AC18): a member already in a repath-failure streak (came
		# here from an empty WALKING_TO repath) treats an empty reselect as
		# another failed attempt — bounded retry, LEAVING only when the streak
		# reaches retry_limit (REASON_PATH_BLOCKED). A member with no streak
		# (counter 0) is a genuine AC1 no-candidates departure.
		var failures := int(member.get("repath_failures", 0))
		if failures > 0:
			failures += 1
			member["repath_failures"] = failures
			if failures >= _repath_retry_limit:
				_begin_leaving(member, REASON_PATH_BLOCKED)
			return
		_begin_leaving(member, REASON_NO_CANDIDATES)
		return
	var access_cells: Array = _grid.get_access_cells(target_id)
	if access_cells.is_empty():
		_begin_leaving(member, REASON_NO_CANDIDATES)
		return
	var path: Array[Vector2i] = _navigation.get_path(member["cell"], access_cells[0])
	if path.is_empty():
		_begin_leaving(member, REASON_NO_CANDIDATES)
		return
	# Story 003: claim the queue slot (Core Rule 4 claim rule — settable iff
	# null, whether or not occupant is null). The candidate pool already
	# excluded fully-spoken-for machines, so the claim normally succeeds; a
	# failed claim means the race was lost this tick (a lower member_id
	# claimed first) — stay in SELECTING_TARGET, no partial state committed
	# (Core Rule 3 step 6, TR-MS-006).
	if not _claim_next_claimant(target_id, int(member["member_id"])):
		return
	member["target_equipment_instance_id"] = target_id
	member["cached_path"] = path
	# Story 004 (AC17): stamp the path with the grid version it was computed
	# at. WALKING_TO re-queries Navigation.get_path on a stamp mismatch.
	member["cached_path_grid_version"] = _grid.get_grid_version()
	# A successful reselect ends any repath-failure streak (AC18).
	member["repath_failures"] = 0
	member["state"] = STATE_WALKING_TO


## Core Rule 3 weighted target selection — the fixed order:
##   1. candidate pool: every placed instance ascending equipment_instance_id
##      (explicit sort — get_placed_instances() order is stable within a grid
##      version but NOT guaranteed across commits). Reservation "fully spoken
##      for" exclusion is Story 003; the no-repeat blacklist is Story 004.
##   2. weight per candidate (see target_selection_weight)
##   3. sort by weight desc, deterministic tie-break ascending id (AC20);
##      take top-K (_top_k, 3-5)
##   4. path-check the K in ascending id order via Navigation.get_path; drop
##      unreachable; renormalize weights over survivors (AC12: ΣP = 1)
##   5. weighted-random draw over survivors with ONE rng.randf() (ADR-0004)
## Returns the chosen equipment_instance_id, or -1 when the pool is empty or
## every top-K candidate is unreachable (AC1 — the caller transitions to
## LEAVING the same tick).
func _pick_weighted_target(member: Dictionary) -> int:
	var candidates := _build_weighted_candidates(member)
	if candidates.is_empty():
		return -1
	_sort_candidates_by_weight(candidates)  # weight desc, tie ascending id
	var k: int = mini(_top_k, candidates.size())
	var top_k: Array = candidates.slice(0, k)

	# Path-check the K in ASCENDING equipment_instance_id order (AC20's fixed
	# scan order); drop unreachable; keep the survivors in ascending id order.
	var top_ids: Array[int] = []
	for c in top_k:
		top_ids.append(int(c["instance_id"]))
	top_ids.sort()
	var survivors: Array = []
	var from: Vector2i = member["cell"]
	for instance_id in top_ids:
		var access_cells: Array = _grid.get_access_cells(instance_id)
		if access_cells.is_empty():
			continue  # no access cell — cannot be used
		var entry: Dictionary = _candidate_entry_by_id(top_k, instance_id)
		if not _navigation.get_path(from, access_cells[0]).is_empty():
			survivors.append(entry)
	if survivors.is_empty():
		return -1  # AC1 / AC12 edge: zero survivors — caller transitions to LEAVING

	# Renormalize over survivors (fixed summation order: ascending id) —
	# Σ P_i = 1.0 (AC12), every P_i > 0 (weights are epsilon-floored).
	var total := 0.0
	for c in survivors:
		total += float(c["weight"])
	var draw := _rng().randf()  # exactly ONE draw (ADR-0004 fixed order)
	var acc := 0.0
	for c in survivors:
		acc += float(c["weight"]) / total
		if draw < acc:
			return int(c["instance_id"])
	return int(survivors[-1]["instance_id"])  # float-tolerance tail guard


## Builds the Story 002 candidate pool with one weight per placed instance:
##   {instance_id, weight, congestion, dist_cells, novelty,
##    preference_weight, noise}
## in ascending equipment_instance_id order (never grid/hash order — the
## deterministic summation order AC12's ΣP depends on).
##
## Story 003 (Core Rule 3 step 1 / TR-MS-004): fully-spoken-for equipment —
## its reservation `next_claimant` is held by another member — is EXCLUDED
## from the pool. This is the AC3 redraw mechanism: the loser of a contention
## race never re-picks the machine its winner already claimed.
##
## Story 004 (Core Rule 3 step 1 / AC19): equipment on this member's
## short-term no-repeat blacklist (abandoned via patience give-up) is also
## EXCLUDED — prevents the immediate flip-flop back to the machine the member
## just gave up on. Entries expire after give_up_blacklist_ticks.
func _build_weighted_candidates(member: Dictionary) -> Array:
	var instances: Array = _grid.get_placed_instances()
	var ids: Array[int] = []
	for inst in instances:
		ids.append(int(inst.instance_id))
	ids.sort()
	var from: Vector2i = member["cell"]
	var noise: float = _pref_noise(member)
	var out: Array = []
	for instance_id in ids:
		var access_cells: Array = _grid.get_access_cells(instance_id)
		if access_cells.is_empty():
			continue  # no access cell — cannot be used
		if _fully_spoken_for(instance_id, int(member["member_id"])):
			continue  # Story 003: queue slot already claimed by another member
		if _on_give_up_blacklist(member, instance_id):
			continue  # Story 004: just abandoned via patience give-up (AC19)
		var dist_cells := _dist_cells(from, access_cells[0])
		var congestion := _congestion_value(instance_id)
		var novelty := _novelty_factor(member, instance_id)
		var preference_weight := _preference_weight(member, instance_id)
		var attraction_multiplier := _upgrade_attraction_multiplier(instance_id)
		out.append({
			"instance_id": instance_id,
			"weight": target_selection_weight(
				congestion, dist_cells, novelty, noise,
				preference_weight, attraction_multiplier),
			"congestion": congestion,
			"dist_cells": dist_cells,
			"novelty": novelty,
			"preference_weight": preference_weight,
			"attraction_multiplier": attraction_multiplier,
			"noise": noise,
		})
	return out


## Deterministic sort: weight DESC, equal weights tie-break by ASCENDING
## equipment_instance_id (AC20). The comparator is total — equal weight + id
## never collide — so the result is stable by construction (no engine-order
## dependence).
func _sort_candidates_by_weight(candidates: Array) -> void:
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var wa: float = float(a["weight"])
		var wb: float = float(b["weight"])
		if wa != wb:
			return wa > wb
		return int(a["instance_id"]) < int(b["instance_id"])
	)


## Returns the first candidate entry whose instance_id matches, or {} when
## absent. Used by the path-check loop to recover the full entry (weight,
## congestion, …) for a survivor by id — the top-K array is sorted by weight,
## but the scan runs in ascending id order.
func _candidate_entry_by_id(candidates: Array, instance_id: int) -> Dictionary:
	for c in candidates:
		if int(c["instance_id"]) == instance_id:
			return c
	return {}


## Core Rule 3 / GDD Formulas target_selection_weight. Public because it is
## the documented formula surface the unit tests assert directly (AC10
## monotonicity sweep, AC12 positivity).
##
## weight = BASE_WEIGHT × exp(-k_congestion × congestion)
##          × exp(-k_proximity × dist_cells / D_max)
##          × novelty_factor × preference_weight × pref_noise
## then floored at WEIGHT_EPSILON so the weight is ALWAYS strictly positive
## (AC12: no divide-by-zero, no NaN, even at congestion 1.0).
func target_selection_weight(
	congestion: float,
	dist_cells: int,
	novelty_factor: float,
	pref_noise: float,
	preference_weight: float = 1.0,
	attraction_multiplier: float = 1.0
) -> float:
	var c := clampf(congestion, 0.0, 1.0)
	var d := maxi(dist_cells, 0)
	var raw := BASE_WEIGHT \
		* exp(-_k_congestion * c) \
		* exp(-_k_proximity * float(d) / float(maxi(_d_max, 1))) \
		* clampf(novelty_factor, 0.0, 1.0) \
		* clampf(preference_weight, 0.0, 2.0) \
		* clampf(attraction_multiplier, 0.0, 2.0) \
		* clampf(pref_noise, 0.0, 2.0)
	return maxf(raw, WEIGHT_EPSILON)


## A2 current-instance attraction multiplier. Missing upgrade wiring is
## neutral for compatibility with tests, old saves, and stripped-down rigs.
func _upgrade_attraction_multiplier(instance_id: int) -> float:
	if _upgrade_reader == null or not _upgrade_reader.has_method("get_level") \
		or not _upgrade_reader.has_method("attraction_multiplier_for_level"):
		return 1.0
	var level := int(_upgrade_reader.call("get_level", instance_id))
	return float(_upgrade_reader.call("attraction_multiplier_for_level", level))


## A2 current level for a completed equipment use. This value is snapshotted
## onto the member before its target id is cleared, keeping later revenue
## deterministic if the equipment changes while the member walks to the exit.
func _upgrade_level(instance_id: int) -> int:
	if _upgrade_reader == null or not _upgrade_reader.has_method("get_level"):
		return 1
	return maxi(1, int(_upgrade_reader.call("get_level", instance_id)))


## Revenue effect for one completed use, snapshotted alongside its level so
## later upgrades cannot retroactively change a visit already in progress.
func _upgrade_revenue_multiplier(level: int) -> float:
	if _upgrade_reader == null \
		or not _upgrade_reader.has_method("revenue_multiplier_for_level"):
		return 1.0
	return maxf(0.0, float(_upgrade_reader.call(
		"revenue_multiplier_for_level", maxi(level, 1))))


## Reads Congestion(t-1) for [instance_id] through the injected reader (the
## `prev` buffer contract — AC11). Absent reader -> 0.0 (neutral). Clamped to
## [0,1] defensively (the real Congestion system guarantees this range).
func _congestion_value(instance_id: int) -> float:
	if _congestion_reader == null:
		return 0.0
	var v: Variant = _congestion_reader.call("per_equipment_congestion", instance_id)
	if typeof(v) != TYPE_FLOAT and typeof(v) != TYPE_INT:
		return 0.0
	return clampf(float(v), 0.0, 1.0)


## Chebyshev distance (cells) from [from] to [to] — the geometric proxy the
## weight uses instead of the pathfinding length (see class header).
func _dist_cells(from: Vector2i, to: Vector2i) -> int:
	return maxi(absi(from.x - to.x), absi(from.y - to.y))


## The member's stored preference noise (pref_noise_i, Uniform(0.85, 1.15),
## rolled at spawn by _roll_preference_profile). Legacy/injected members with
## no profile default to 1.0.
func _pref_noise(member: Dictionary) -> float:
	var profile: Variant = member.get("preference_profile", {})
	if profile is Dictionary and profile.has("preference_noise"):
		return float(profile["preference_noise"])
	return 1.0


## A1 preference multiplier for one equipment candidate. Equipment category
## truth comes from EquipmentCatalog's EquipmentDef.zone_membership through
## the already-injected instance_id -> equipment_id resolver. Missing legacy
## profile data, resolver data, catalog data, or recognized zones is neutral
## (1.0), preserving old saves and test rigs.
func _preference_weight(member: Dictionary, instance_id: int) -> float:
	var profile_value: Variant = member.get("preference_profile", {})
	if not (profile_value is Dictionary):
		return 1.0
	var profile: Dictionary = profile_value
	var category_weights := _resolved_category_weights(profile)
	if category_weights.is_empty():
		return 1.0
	var zones := _equipment_zones(instance_id)
	var found := false
	var best := 0.0
	for zone_value in zones:
		var category := _canonical_preference_category(str(zone_value))
		if category.is_empty() or not category_weights.has(category):
			continue
		var value := clampf(float(category_weights[category]), 0.0, 2.0)
		best = maxf(best, value) if found else value
		found = true
	return best if found else 1.0


## Prefer the stored resolved weights. A type-only injected/older transitional
## record may derive the canonical table without consuming RNG; a pre-A1
## noise-only record remains neutral.
func _resolved_category_weights(profile: Dictionary) -> Dictionary:
	var stored: Variant = profile.get("category_weights", {})
	if stored is Dictionary and not (stored as Dictionary).is_empty():
		return stored
	var preference_type := str(profile.get("type", ""))
	if PREF_CATEGORY_WEIGHTS.has(preference_type):
		return (PREF_CATEGORY_WEIGHTS[preference_type] as Dictionary).duplicate(true)
	return {}


func _equipment_zones(instance_id: int) -> Array:
	if not _equipment_id_resolver.is_valid() or _catalog == null:
		return []
	var equipment_id := str(_equipment_id_resolver.call(instance_id))
	if equipment_id.is_empty() or not _catalog.has_definition(equipment_id):
		return []
	var def: EquipmentDef = _catalog.get_definition(equipment_id)
	return def.zone_membership


## Canonical aliases keep preference semantics compatible with the zone names
## already used by Palette/SelectionCue and plausible future catalog entries.
func _canonical_preference_category(zone: String) -> String:
	match zone.to_lower():
		"strength", "free_weights":
			return "strength"
		"cardio", "aerobic":
			return "cardio"
		"flex", "yoga", "mobility":
			return "flex"
	return ""


## novelty_factor_i: {0.2 just-used, 0.6 recent, 1.0} — suppresses repeating
## the same machine (GDD Formulas). Uses the member's recently_used_ids
## (most-recent-first): index 0 = just-used -> 0.2; within the recent window
## (next NOVELTY_RECENT_WINDOW-1 entries) -> 0.6; else fresh -> 1.0.
func _novelty_factor(member: Dictionary, instance_id: int) -> float:
	var recent: Array = member.get("recently_used_ids", [])
	var idx := recent.find(instance_id)
	if idx == 0:
		return NOVELTY_JUST_USED
	if idx > 0 and idx < NOVELTY_RECENT_WINDOW:
		return NOVELTY_RECENT
	return NOVELTY_FRESH


## Records [instance_id] as the member's most-recently-used equipment
## (Story 002 novelty tracking — called when a use completes). Keeps the list
## most-recent-first and capped at NOVELTY_RECENT_WINDOW.
func _record_recently_used(member: Dictionary, instance_id: int) -> void:
	var recent: Array = member.get("recently_used_ids", [])
	recent.erase(instance_id)  # re-use: move to front
	recent.push_front(instance_id)
	while recent.size() > NOVELTY_RECENT_WINDOW:
		recent.pop_back()
	member["recently_used_ids"] = recent


## WALKING_TO: consumes the cached path one cell per tick. Story 004 (Core
## Rule 5 / AC17) owns path invalidation: every tick compares the cached
## path's `cached_path_grid_version` stamp to _grid.get_grid_version(); on
## mismatch, Navigation.get_path is re-queried EXACTLY ONCE that tick.
## An empty repath result is treated identically whether the grid changed
## blocked the path or the target equipment was deleted — release the held
## reservation the SAME tick (TR-MS-005 / AC5) and bounded-retry (AC18).
##
## Story 003 (Core Rule 4): the member holds the target's `next_claimant`
## slot from selection time. On arrival:
##   - access cell FREE  -> claim `occupant`, clear `next_claimant`, -> USING
##   - access cell BUSY  -> QUEUEING one cell short (never steps onto the
##     occupied access cell — AC16 sprite rule). The last hop is checked
##     BEFORE stepping: if the only remaining path cell is a busy access
##     cell, the member stops at its current cell (the one-cell-short
##     queue position).
func _on_walking_to(member: Dictionary) -> void:
	var target := int(member.get("target_equipment_instance_id", -1))
	var path: Array = member["cached_path"]
	# get_path() includes both endpoints — skip the current cell.
	while not path.is_empty() and path[0] == member["cell"]:
		path.remove_at(0)
	if path.is_empty():
		# Already at the access cell (path fully consumed) — arrive.
		member["cached_path"] = []
		_handle_arrival(member)
		return
	# Story 004 (AC17): path invalidation — compare the cached stamp to the
	# grid's current version. On mismatch re-query Navigation.get_path
	# exactly once this tick (the comparison runs once per tick, so even a
	# version that changes twice within the tick dedupes to one re-query).
	var cached_version := int(member.get("cached_path_grid_version", -1))
	if cached_version != _grid.get_grid_version():
		var access_cells: Array = _grid.get_access_cells(target)
		var repath: Array[Vector2i] = []
		if not access_cells.is_empty():
			repath = _navigation.get_path(member["cell"], access_cells[0])
		if repath.is_empty():
			# Empty result: path blocked OR target gone — the SAME handling
			# (no special-casing, Core Rule 5). Release + bounded retry.
			_handle_repath_failure(member)
			return
		member["cached_path"] = repath
		member["cached_path_grid_version"] = _grid.get_grid_version()
		member["repath_failures"] = 0  # a successful repath ends the streak
		path = repath
		while not path.is_empty() and path[0] == member["cell"]:
			path.remove_at(0)
		if path.is_empty():
			member["cached_path"] = []
			_handle_arrival(member)
			return
	var next_cell: Vector2i = path[0]
	if path.size() == 1 and _access_busy(target):
		# The only hop left lands on an OCCUPIED access cell — queue one
		# cell short instead of stepping onto it (AC16). The member's
		# current cell is by construction the penultimate path cell —
		# adjacent to the access cell.
		_enter_queueing(member, target)
		return
	if _grid.is_solid(next_cell):
		# Defensive: stale path despite a matching stamp (injected edge) —
		# release + bounded retry, identical to a blocked repath.
		_handle_repath_failure(member)
		return
	member["cell"] = next_cell
	path.remove_at(0)
	member["cached_path"] = path
	if path.is_empty():
		_handle_arrival(member)


## Story 004 (Core Rule 5 / AC18): a path resolution came back EMPTY — path
## blocked or target deleted, treated identically. Releases any held claim
## the SAME tick (TR-MS-005 / AC5). Bounded retry: the member returns to
## SELECTING_TARGET; consecutive empty results count on repath_failures and
## exhaustion (>= _repath_retry_limit) releases + LEAVING (REASON_PATH_BLOCKED
## — deliberately distinct from AC1's no_candidates).
func _handle_repath_failure(member: Dictionary) -> void:
	_release_reservation(member)
	member["cached_path"] = []
	member["target_equipment_instance_id"] = -1
	member["repath_failures"] = int(member.get("repath_failures", 0)) + 1
	if int(member["repath_failures"]) >= _repath_retry_limit:
		_begin_leaving(member, REASON_PATH_BLOCKED)
		return
	member["state"] = STATE_SELECTING_TARGET


## Story 003 arrival (Core Rule 4 "On arrival"). The member's cell is the
## access cell of [target_equipment_instance_id] (or it just consumed the
## last path hop onto it).
##   - occupant null + this member holds next_claimant -> claim occupant,
##     clear next_claimant, -> USING (guaranteed FIFO of exactly one)
##   - occupant busy -> QUEUEING one cell short (member already at the
##     queue position — it never stepped onto the busy access cell)
## Defensive fallbacks: target unresolvable (equipment gone / access cell
## list empty) -> release + reselect; member somehow standing on a BUSY
## access cell (loaded/injected edge) -> release + reselect rather than
## violate the AC16 sprite rule.
func _handle_arrival(member: Dictionary) -> void:
	var target := int(member["target_equipment_instance_id"])
	if target < 0:
		_release_reservation(member)
		member["cached_path"] = []
		member["state"] = STATE_SELECTING_TARGET
		return
	var access_cells: Array = _grid.get_access_cells(target)
	if access_cells.is_empty():
		# Target no longer resolvable — release and reselect (defensive;
		# Story 004's grid_version repath handles this formally).
		_release_reservation(member)
		member["target_equipment_instance_id"] = -1
		member["cached_path"] = []
		member["state"] = STATE_SELECTING_TARGET
		return
	var rec: Variant = reservations.get(target)
	var member_id := int(member["member_id"])
	if rec is Dictionary and rec["occupant"] == null and rec["next_claimant"] == member_id:
		# Access cell free and this member holds the queue slot — claim
		# occupancy (Core Rule 4 "On arrival").
		_become_occupant(member, target)
		_start_using(member)
		return
	if rec is Dictionary and rec["occupant"] == null and rec["next_claimant"] != null \
			and rec["next_claimant"] != member_id:
		# Another member holds the queue slot and the machine is free —
		# defensive: never claim out of turn (should be impossible: the
		# pool excludes spoken-for machines). Release and reselect.
		_release_reservation(member)
		member["target_equipment_instance_id"] = -1
		member["cached_path"] = []
		member["state"] = STATE_SELECTING_TARGET
		return
	if member["cell"] == access_cells[0]:
		# Standing on a BUSY access cell (loaded/injected edge) — never
		# occupy it (AC16); release and reselect.
		_release_reservation(member)
		member["target_equipment_instance_id"] = -1
		member["cached_path"] = []
		member["state"] = STATE_SELECTING_TARGET
		return
	# Access cell busy — queue one cell short. The member is at the
	# penultimate path cell (never stepped onto the occupied access cell).
	_enter_queueing(member, target)


## Story 003 QUEUEING (Core Rule 4). The member stands one cell short of the
## access cell, holding the equipment's single next_claimant slot. Each tick:
##   - occupant released (null) + this member holds next_claimant -> step
##     onto the access cell, claim occupant (clears next_claimant), -> USING
##   - occupant still active -> patience countdown; on 0 -> calm give-up:
##     release next_claimant the SAME tick (TR-MS-005 / AC5), reselect.
##     (The short-term no-repeat blacklist that prevents give-up flip-flop
##     belongs to Story 004 — documented seam.)
func _on_queueing(member: Dictionary) -> void:
	var target := int(member["target_equipment_instance_id"])
	var rec: Variant = reservations.get(target) if target >= 0 else null
	var member_id := int(member["member_id"])
	if rec is Dictionary and rec["occupant"] == null and rec["next_claimant"] == member_id:
		# The occupant released — step onto the access cell and start using.
		var access_cells: Array = _grid.get_access_cells(target)
		if access_cells.is_empty():
			_release_reservation(member)
			member["target_equipment_instance_id"] = -1
			member["cached_path"] = []
			member["state"] = STATE_SELECTING_TARGET
			return
		member["cell"] = access_cells[0]
		_become_occupant(member, target)
		_start_using(member)
		return
	if not (rec is Dictionary) or rec["next_claimant"] != member_id:
		# Defensive: the claim is gone (equipment deleted / claim lost) —
		# release and reselect rather than queue forever.
		_release_reservation(member)
		member["target_equipment_instance_id"] = -1
		member["cached_path"] = []
		member["state"] = STATE_SELECTING_TARGET
		return
	# Occupant still active — patience countdown (GDD Formulas; drawn once on
	# entering QUEUEING). Calm give-up on exhaustion (Pillar 2): release the
	# queue slot the SAME tick, reselect elsewhere.
	member["patience_ticks_remaining"] = int(member["patience_ticks_remaining"]) - 1
	if int(member["patience_ticks_remaining"]) <= 0:
		_release_reservation(member)  # TR-MS-005: next_claimant null same tick
		# Story 004 (AC19): the abandoned equipment goes on the member's
		# short-term no-repeat blacklist so a same/next-tick reselect EXCLUDES
		# it — no immediate flip-flop back to the machine just given up on.
		# The entry expires after give_up_blacklist_ticks and the machine
		# becomes eligible again.
		_blacklist_give_up(member, target)
		member["target_equipment_instance_id"] = -1
		member["cached_path"] = []
		member["state"] = STATE_SELECTING_TARGET


## Enters USING at the access cell. Story 003: the caller has already
## claimed `occupant` in the reservation map (_handle_arrival /
## _on_queueing) — the member physically occupies the access cell.
## use_ticks_remaining is rolled once.
func _start_using(member: Dictionary) -> void:
	member["state"] = STATE_USING
	member["use_ticks_remaining"] = _roll_use_duration(int(member["target_equipment_instance_id"]))


## USING: counts down the use duration. Only SUCCESSFULLY completed uses
## count toward the visit quota (GDD Formulas — abandoned queues neither
## count nor reset). On completion:
##   - Story 003: release the `occupant` claim FIRST (same tick) so a
##     QUEUEING next_claimant holder can step in; then
##   - the used equipment becomes the member's most-recently-used (Story 002
##     novelty tracking — suppresses immediate repeats), and
##   - quota met -> LEAVING, else SELECTING_TARGET.
##
## Story 004 (AC14): each tick FIRST checks whether the target equipment was
## deleted mid-use (its access cells no longer resolve). If so, interrupt
## gracefully — release, clear the target + cached path, -> SELECTING_TARGET
## and record EXACTLY ONE satisfaction-penalty event (Satisfaction consumes
## the per-tick counter via get_satisfaction_penalty_events(), ADR-0005 §3).
## No crash, no exercises_done mutation (the interrupted use neither counts
## nor resets — Pillar 2).
func _on_using(member: Dictionary) -> void:
	var target := int(member.get("target_equipment_instance_id", -1))
	if target >= 0 and _grid.get_access_cells(target).is_empty():
		# Equipment deleted mid-use — graceful interrupt (AC14).
		_release_reservation(member)
		member["target_equipment_instance_id"] = -1
		member["cached_path"] = []
		member["state"] = STATE_SELECTING_TARGET
		_satisfaction_penalty_events += 1  # exactly one penalty this tick
		return
	member["use_ticks_remaining"] = int(member["use_ticks_remaining"]) - 1
	if int(member["use_ticks_remaining"]) > 0:
		return
	_release_reservation(member)  # Story 003: occupant claim released same tick
	if int(member["target_equipment_instance_id"]) >= 0:
		var completed_instance_id := int(member["target_equipment_instance_id"])
		_record_recently_used(member, completed_instance_id)
		var completed_level := _upgrade_level(completed_instance_id)
		member["last_completed_equipment_level"] = completed_level
		member["visit_revenue_multiplier_sum"] = \
			float(member.get("visit_revenue_multiplier_sum", 0.0)) \
			+ _upgrade_revenue_multiplier(completed_level)
		member["visit_revenue_multiplier_count"] = \
			int(member.get("visit_revenue_multiplier_count", 0)) + 1
	member["exercises_done"] = int(member["exercises_done"]) + 1
	member["target_equipment_instance_id"] = -1
	member["cached_path"] = []
	if int(member["exercises_done"]) >= int(member["exercises_per_visit"]):
		_begin_leaving(member, REASON_QUOTA_MET)
	else:
		member["state"] = STATE_SELECTING_TARGET


## LEAVING: paths to the single exit_cell with the same per-cell walk as
## WALKING_TO — including Story 004 path invalidation: the cached exit path
## carries a cached_path_grid_version stamp, and every LEAVING tick re-queries
## Navigation.get_path on a mismatch. A defensive safety timeout forces GONE
## if no exit path ever resolves — Pillar 2 forbids a permanently stuck
## member (AC21). The timeout counts DOWN ONLY while the member is genuinely
## stuck (repath empty); while a path resolves and is walked, it holds — a
## transient blockage mid-leave must never cause a premature GONE (AC21 edge
## case). Unlike WALKING_TO, LEAVING does NOT reuse the AC18 bounded-retry
## counter: the leaving_timeout is its bounded fallback (a stuck leaver still
## leaves eventually — AC21).
func _on_leaving(member: Dictionary, to_remove: Array) -> void:
	var path: Array = member["cached_path"]
	while not path.is_empty() and path[0] == member["cell"]:
		path.remove_at(0)
	if not path.is_empty():
		# Story 004 (AC17 applies to LEAVING per Core Rule 5): re-query the
		# exit path EXACTLY ONCE when the grid version moved on.
		if int(member.get("cached_path_grid_version", -1)) != _grid.get_grid_version():
			var repath: Array[Vector2i] = _navigation.get_path(member["cell"], _exit_cell)
			if repath.is_empty():
				member["cached_path"] = []  # blocked mid-leave — timeout next tick
				return
			member["cached_path"] = repath
			member["cached_path_grid_version"] = _grid.get_grid_version()
			path = repath
			while not path.is_empty() and path[0] == member["cell"]:
				path.remove_at(0)
			if path.is_empty():
				_mark_gone(member, to_remove)  # repath landed us on the exit
				return
		var next_cell: Vector2i = path[0]
		if _grid.is_solid(next_cell):
			member["cached_path"] = []  # blocked mid-leave — repath next tick
			return
		member["cell"] = next_cell
		path.remove_at(0)
		member["cached_path"] = path
		if path.is_empty():
			_mark_gone(member, to_remove)  # arrived at exit_cell
		return
	# No usable cached path — check whether we're already at the exit, then
	# try to resolve a path to it.
	if member["cell"] == _exit_cell:
		_mark_gone(member, to_remove)
		return
	var exit_path: Array[Vector2i] = _navigation.get_path(member["cell"], _exit_cell)
	if exit_path.is_empty():
		member["leaving_timeout_ticks"] = int(member["leaving_timeout_ticks"]) - 1
		if int(member["leaving_timeout_ticks"]) <= 0:
			_mark_gone(member, to_remove)  # AC21 — forced GONE, never stuck
		return
	member["cached_path"] = exit_path
	member["cached_path_grid_version"] = _grid.get_grid_version()


## Enters LEAVING. Records WHY (drives S5) and arms the safety timeout.
## Story 003: releases any reservation claim this member still holds
## (occupant from USING quota-met, or next_claimant on any leave path) —
## the release invariant (TR-MS-005) must hold for EVERY exit, never just
## the WALKING_TO/QUEUEING transitions.
func _begin_leaving(member: Dictionary, reason: String) -> void:
	_release_reservation(member)
	member["state"] = STATE_LEAVING
	member["leaving_reason"] = reason
	member["leaving_timeout_ticks"] = _leaving_timeout_ticks
	member["target_equipment_instance_id"] = -1
	member["cached_path"] = []  # repath from the current cell on the first LEAVING tick


## Terminal transition: marks the member GONE (removed at tick end; the id is
## retired forever — TR-MS-012) and emits S5 exactly once, ONLY for quota-met
## departures (ADR-0005 — walk-failure/patience-exhaust earn nothing).
## Story 003 defensive: a despawned member must never leave a stale claim
## behind (deadlock prevention — TR-MS-005).
func _mark_gone(member: Dictionary, to_remove: Array) -> void:
	_release_reservation(member)
	member["state"] = STATE_GONE
	if str(member.get("leaving_reason", "")) == REASON_QUOTA_MET:
		member_completed_visit.emit(int(member["member_id"]))
	to_remove.append(member)


## TR-MS-008 arrival probability:
##   p_tick = clamp(base_arrival_rate_per_min / 60 * TICK_DURATION_SECONDS *
##            satisfaction_modifier * capacity_gate, 0, 1)
## capacity_gate is 0 at the max_concurrent_members cap (soft cap — never a
## failure, never a door queue; AC15).
func _arrival_probability() -> float:
	var capacity_gate := 0.0 if _active_count() >= _max_concurrent_members else 1.0
	var p := _base_arrival_rate_per_min / 60.0 * TimeSystem.TICK_DURATION_SECONDS \
		* _satisfaction_modifier * capacity_gate
	return clampf(p, 0.0, 1.0)


## Spawns one member at the entrance cell (Core Rule 6): assigns
## member_id = member_id_counter++, rolls exercises_per_visit and the
## preference profile (both drawn NOW and stored — never re-derivable seeds,
## Core Rule 7), inserts into the roster. At the cap the spawn is a silent
## no-op: the counter is NOT incremented and no error/door-queue is created
## (AC15 — the counter increment is the observable contract).
func _spawn_member() -> void:
	if _active_count() >= _max_concurrent_members:
		return  # AC15: soft cap — no spawn, no counter increment, no error
	var member_id := _member_id_counter
	_member_id_counter += 1
	var member := {
		"member_id": member_id,
		"state": STATE_ENTERING,
		"cell": _entrance_cell,
		"exercises_done": 0,
		"exercises_per_visit": _roll_exercises_per_visit(),
		"preference_profile": _roll_preference_profile(),
		"target_equipment_instance_id": -1,
		"cached_path": [],
		"cached_path_grid_version": -1,  # Story 004: stamped on first claim
		"repath_failures": 0,            # Story 004: AC18 bounded-retry counter
		"give_up_blacklist": {},         # Story 004: AC19 id -> remaining_ticks
		"leaving_timeout_ticks": 0,
		"patience_ticks_remaining": 0,  # Story 003: rolled on entering QUEUEING
		"recently_used_ids": [],
		"last_completed_equipment_level": 1,
		"visit_revenue_multiplier_sum": 0.0,
		"visit_revenue_multiplier_count": 0,
	}
	members.append(member)


## Returns the equipment level snapshotted by a quota-met member's last
## completed use. Economy calls this synchronously from member_completed_visit
## while the member is still present in the roster. Unknown/legacy ids are L1.
func get_completed_visit_equipment_level(member_id: int) -> int:
	if not _assert_initialized():
		return 1
	for member in members:
		if member is Dictionary and int(member.get("member_id", -1)) == member_id:
			return maxi(1, int(member.get("last_completed_equipment_level", 1)))
	return 1


## Returns the mean revenue multiplier across every successfully completed
## exercise in this visit. Economy reads it synchronously from S5 while the
## member is still in the roster. Legacy saves without the accumulator fall
## back to their last-equipment snapshot for backward compatibility.
func get_completed_visit_revenue_multiplier(member_id: int) -> float:
	if not _assert_initialized():
		return 1.0
	for member in members:
		if member is Dictionary and int(member.get("member_id", -1)) == member_id:
			var count := int(member.get("visit_revenue_multiplier_count", 0))
			if count > 0:
				return float(member.get("visit_revenue_multiplier_sum", float(count))) / float(count)
			return _upgrade_revenue_multiplier(
				maxi(1, int(member.get("last_completed_equipment_level", 1))))
	return 1.0


## Number of active (non-removed) members. GONE members are removed at the
## end of the tick they leave, so roster size IS the active count.
func _active_count() -> int:
	return members.size()


## TR-MS-010: exercises_per_visit = round(clamp(randfn(mean * visit_length_
## modifier, stddev), min, max)). Drawn once on entry from the same tick-
## boundary Satisfaction snapshot used by the arrival roll.
func _roll_exercises_per_visit() -> int:
	var raw: float = _rng().randfn(
		_exercises_mean * _visit_length_modifier, _exercises_stddev)
	return clampi(roundi(raw), _exercises_min, _exercises_max)


## Resolved at spawn and stored (Core Rule 7 — never a re-derivable seed).
## A1 resolves both a uniformly distributed preference type and its category
## weights at spawn from the SAME uniform sample as the existing per-member
## noise. This deliberately preserves the pre-A1 RNG consumption count (one
## draw per profile), so later lifecycle rolls keep their established seeded
## sequence. The sample comes only from the MemberSim RNG sub-stream. The full
## resolved Dictionary is saved, so deserialize restores it directly without
## re-rolling (Core Rule 7).
func _roll_preference_profile() -> Dictionary:
	var rng := _rng()
	var preference_noise := rng.randf_range(0.85, 1.15)
	var unit_sample := clampf((preference_noise - 0.85) / 0.30, 0.0, 1.0)
	var type_index := clampi(floori(unit_sample * float(PREF_TYPES.size())), 0, PREF_TYPES.size() - 1)
	var preference_type := PREF_TYPES[type_index]
	return {
		"type": preference_type,
		"category_weights": (PREF_CATEGORY_WEIGHTS[preference_type] as Dictionary).duplicate(true),
		"preference_noise": preference_noise,
	}


## TR-MS-009: use_duration = round(clamp(randfn(mean, stddev), min, max)).
## Per-equipment fields come from the EquipmentCatalog def the injected
## `equipment_id_resolver` resolves for [target_instance_id] (Story 005).
## When the resolver is absent, the id doesn't resolve, or the catalog has
## no def for it, the config's default range is used — the pre-wiring
## rigs' deterministic behavior. EXACTLY ONE rng draw per use start
## (ADR-0004 fixed RNG consumption order — same as the config-only path).
func _roll_use_duration(target_instance_id: int) -> int:
	var mean := _use_duration_mean_ticks
	var stddev := _use_duration_stddev_ticks
	var min_t := _use_duration_min_ticks
	var max_t := _use_duration_max_ticks
	if _equipment_id_resolver.is_valid() and _catalog != null:
		var equipment_id: String = str(_equipment_id_resolver.call(target_instance_id))
		if not equipment_id.is_empty() and _catalog.has_definition(equipment_id):
			var def: EquipmentDef = _catalog.get_definition(equipment_id)
			mean = def.use_duration_mean_ticks
			stddev = def.use_duration_stddev_ticks
			min_t = def.use_duration_min_ticks
			max_t = def.use_duration_max_ticks
	var raw: float = _rng().randfn(float(mean), float(stddev))
	return clampi(roundi(raw), min_t, max_t)


## GDD Formulas: patience_threshold_ticks = round(Uniform(patience_min_ticks,
## patience_max_ticks)), drawn ONCE on entering QUEUEING (Story 003). The
## countdown is the calm give-up knob (Pillar 2); the give-up blacklist is
## Story 004.
func _roll_patience() -> int:
	return roundi(_rng().randf_range(float(_patience_min_ticks), float(_patience_max_ticks)))


# === Story 003 — access-cell reservation map (Core Rule 4 / TR-MS-004..006) ===

## Get-or-create the reservation record for [instance_id]. Records are ONLY
## created here (claim path) — reads elsewhere use reservations.get() so a
## never-claimed machine never appears in the map. Keyed access only: the
## map is never iterated for behavior (TR-MS-006 — Dictionary iteration is
## engine-ordered).
func _reservation(instance_id: int) -> Dictionary:
	if not reservations.has(instance_id):
		reservations[instance_id] = {"occupant": null, "next_claimant": null}
	return reservations[instance_id]


## True when [instance_id]'s queue slot is already claimed by a DIFFERENT
## member — the "fully spoken for" exclusion (Core Rule 3 step 1 /
## TR-MS-004). A busy machine with a free queue slot is NOT fully spoken for
## (a member may claim the slot and queue). The member's OWN claim never
## excludes the machine from its own pool ("held by someone else" — the AC3
## redraw contract); the release-before-reselect invariant means a
## SELECTING_TARGET member holds no claim anyway.
func _fully_spoken_for(instance_id: int, member_id: int) -> bool:
	var rec: Variant = reservations.get(instance_id)
	return rec is Dictionary and rec["next_claimant"] != null and rec["next_claimant"] != member_id


## True when ANY placed instance's queue slot is claimed by another member.
## Called only when the candidate pool came up empty, to distinguish "no
## reachable equipment at all" (-> LEAVING, AC1) from "every remaining
## machine's queue slot is claimed by another member" (-> stay
## SELECTING_TARGET and retry — the AC3 QA edge). Iterates placed instances
## in ASCENDING id order — never the reservations map itself (TR-MS-006).
func _any_fully_spoken_for() -> bool:
	var instances: Array = _grid.get_placed_instances()
	var ids: Array[int] = []
	for inst in instances:
		ids.append(int(inst.instance_id))
	ids.sort()
	for instance_id in ids:
		var rec: Variant = reservations.get(instance_id)
		if rec is Dictionary and rec["next_claimant"] != null:
			return true
	return false


## Claim rule (Core Rule 4): a member may set next_claimant iff it is
## currently null — whether or not occupant is null (a free machine -> walk
## and become occupant; a busy machine -> become the single queue slot).
## Returns false when the slot is taken (race lost — the caller stays in
## SELECTING_TARGET, no partial state committed; TR-MS-006).
func _claim_next_claimant(instance_id: int, member_id: int) -> bool:
	var rec := _reservation(instance_id)
	if rec["next_claimant"] != null:
		return false
	rec["next_claimant"] = member_id
	return true


## Release invariant (TR-MS-005): clears EVERY claim this member holds on
## its current target — occupant (USING completion) or next_claimant
## (WALKING_TO abort / QUEUEING give-up) — so the same tick that a member
## leaves WALKING_TO or QUEUEING without becoming occupant leaves
## reservations[E].next_claimant null (deadlock prevention). Self-healing by
## member_id match: a claim held by ANOTHER member is never touched. No-op
## when the member holds nothing (idempotent — safe to call on every exit).
func _release_reservation(member: Dictionary) -> void:
	var target := int(member.get("target_equipment_instance_id", -1))
	if target < 0:
		return
	var rec: Variant = reservations.get(target)
	if not (rec is Dictionary):
		return
	var member_id := int(member["member_id"])
	if rec["occupant"] != null and int(rec["occupant"]) == member_id:
		rec["occupant"] = null
	if rec["next_claimant"] != null and int(rec["next_claimant"]) == member_id:
		rec["next_claimant"] = null


## Core Rule 4 "On arrival": the member claims occupancy of the access cell —
## occupant = self, next_claimant cleared (the FIFO of exactly one
## completes). The caller positions the member ON the access cell.
func _become_occupant(member: Dictionary, instance_id: int) -> void:
	var rec := _reservation(instance_id)
	rec["occupant"] = int(member["member_id"])
	rec["next_claimant"] = null


## Enters QUEUEING at the member's CURRENT cell — the one-cell-short queue
## position (never the occupied access cell; AC16 sprite rule). Rolls the
## patience threshold once (GDD Formulas).
func _enter_queueing(member: Dictionary, instance_id: int) -> void:
	member["cached_path"] = []
	member["patience_ticks_remaining"] = _roll_patience()
	member["state"] = STATE_QUEUEING


## True when [instance_id]'s access cell is physically occupied (its
## reservation has a live occupant). Used to decide whether the last walk
## hop may step onto the access cell (AC16 — never step onto an occupied
## access cell).
func _access_busy(instance_id: int) -> bool:
	var rec: Variant = reservations.get(instance_id)
	return rec is Dictionary and rec["occupant"] != null


# === Story 004 — patience give-up short-term blacklist (AC19) ===
#
# give_up_blacklist: Dictionary {equipment_instance_id: remaining_ticks}.
# When a member gives up on a machine (patience exhausted in QUEUEING), the
# machine is excluded from that member's reselect pool until the entry
# expires — no immediate flip-flop back (AC19). Entries are decremented per
# tick by _tick_give_up_blacklist (called from _update_member) and removed at
# 0. The abandoned machine also gets a temporary novelty penalty (as if
# just-used) via _record_recently_used — the GDD's "temporary novelty
# penalty" (patience_threshold formula).
#
# DETERMINISM: the decrement iterates the blacklist, but each entry is
# decremented independently and removals are order-independent — the final
# set of surviving entries does not depend on Dictionary iteration order, so
# the behavior is deterministic (TR-MS-006's never-iterate-dicts-for-behavior
# rule targets the SHARED reservations map, where order decides contention;
# this is per-member state with an order-free operation).

## Adds [instance_id] to the member's give-up blacklist for
## _give_up_blacklist_ticks ticks (refreshes an existing entry). Also applies
## the temporary novelty penalty: the abandoned machine is recorded as
## just-used (novelty_factor 0.2) so even after the blacklist expires the
## member is biased away from it (GDD patience_threshold formula).
func _blacklist_give_up(member: Dictionary, instance_id: int) -> void:
	var blacklist: Dictionary = member.get("give_up_blacklist", {})
	blacklist[instance_id] = _give_up_blacklist_ticks
	member["give_up_blacklist"] = blacklist
	if instance_id >= 0:
		_record_recently_used(member, instance_id)


## True while [instance_id] is on the member's give-up blacklist (AC19 — the
## pool build excludes it). Membership read, no iteration.
func _on_give_up_blacklist(member: Dictionary, instance_id: int) -> bool:
	var blacklist: Dictionary = member.get("give_up_blacklist", {})
	return blacklist.has(instance_id)


## True when the member has ANY non-expired blacklist entry. Used by
## SELECTING_TARGET's empty-pool branch to distinguish "temporarily nothing
## because I just gave up on the only machine" (stay + retry — AC19/AC13 QA
## edge) from "genuinely nothing" (LEAVING — AC1). No failure prompt, ever.
func _has_active_give_up_blacklist(member: Dictionary) -> bool:
	var blacklist: Dictionary = member.get("give_up_blacklist", {})
	return not blacklist.is_empty()


## Decrements every blacklist entry by one tick and removes expired entries.
## Called at the START of every member update (regardless of state) so the
## exclusion is time-bounded, not state-bounded.
func _tick_give_up_blacklist(member: Dictionary) -> void:
	var blacklist: Dictionary = member.get("give_up_blacklist", {})
	if blacklist.is_empty():
		return
	var expired: Array = []
	for instance_id in blacklist.keys():
		var remaining: int = int(blacklist[instance_id]) - 1
		if remaining <= 0:
			expired.append(instance_id)
		else:
			blacklist[instance_id] = remaining
	for instance_id in expired:
		blacklist.erase(instance_id)


## Returns the full MemberSim state as a JSON-safe Dictionary:
##   { counter: int, members: Array, member_id_counter: int,
##     rng_state: "0x…" }
## Pure read — no draws, no mutation (SL-001 AC1 counts serialize calls, so
## serialize stays side-effect free). rng_state is the CURRENT sub-stream
## state (hex per ADR-0002).
##
## Story 005 (Core Rule 7): the members array carries the FULL per-member
## serialized state — member_id, state, cell, cached path + its
## grid_version, target_equipment_instance_id, patience/use/leaving
## timers, exercises_done, the resolved preference_profile, and the
## global member_id_counter. Cells use the project's JSON-safe [x, y]
## encoding (same convention as GridSystem._serialize_cells) so the blob
## survives JSON.stringify/parse with no type ambiguity — raw Vector2i is
## never emitted. Legacy SL-002-era stub entries ({member_id,
## equipment_instance_id}) pass through verbatim so old blobs round-trip
## unchanged (the save-load integration tests' byte-identical contract).
##
## The reservation map is deliberately NOT serialized here — Core Rule 7
## rebuilds it from members' own claim flags on load
## (_rebuild_reservations_from_members). Serializing it separately would
## risk desync.
func serialize() -> Dictionary:
	if not _assert_initialized():
		return {}
	var out_members: Array = []
	for member in members:
		out_members.append(_serialize_member_record(member))
	return {
		"counter": counter,
		"members": out_members,
		"member_id_counter": _member_id_counter,
		"rng_state": SeededRNG.int64_to_hex(_rng().state),
	}


## One member record, JSON-safe: cell -> [x, y], cached_path ->
## [[x, y], ...] (path ORDER preserved — it is a walk path, never sorted).
## Everything else is deep-duplicated verbatim.
func _serialize_member_record(member: Dictionary) -> Dictionary:
	var out: Dictionary = member.duplicate(true)
	if out.has("cell") and out["cell"] is Vector2i:
		out["cell"] = [out["cell"].x, out["cell"].y]
	if out.has("cached_path") and out["cached_path"] is Array:
		var path: Array = []
		for v in out["cached_path"]:
			if v is Vector2i:
				path.append([v.x, v.y])
			else:
				path.append(v)
		out["cached_path"] = path
	return out


## Two-phase deserialize (TR-SL-005, ADR-0002).
##
## Phase A validates EVERYTHING with zero mutation; Phase B commits only if
## Phase A passed. Failures are returned, never push_error'd (corrupt save =
## normal outcome). [validate_only] runs Phase A and returns the verdict
## without committing (SaveLoad Phase A protocol).
##
## AC9 (grid is the source of truth): every member's equipment reference —
## legacy `equipment_instance_id` or full `target_equipment_instance_id`
## (>= 0) — must be present in [known_instance_ids] (the set extracted from
## the save's grid records that GridSystem Phase A validated). A member
## referencing an absent id fails the WHOLE load; never a silent orphan.
##
## Required fields (hard failure, no invented defaults — AC8):
##   counter (int), members (Array of member records),
##   member_id_counter (int — MUST be present; NEVER re-derived from the
##   active set, TR-MS-011: a GONE member's retired id would silently be
##   reused), rng_state ("0x" hex).
##
## AC8 counter-vs-max check: member_id_counter must exceed the max id of
## every STATE-MACHINE member (a record carrying a "state" key) in the
## payload — otherwise the next spawn would reuse a live or retired id.
## Legacy SL-002-era stub entries (no "state" key) are passive roster data
## that was never allocated from the counter and are exempt — this keeps
## the pre-wiring save-load integration tests' blobs (counter 0 with
## hand-assigned ids) loadable while the real machine enforces
## monotonicity. Missing counter, or counter <= max state id, FAILS LOUDLY.
##
## Load-side reservation rebuild (Core Rule 7): after commit the
## reservation map is rebuilt from members' claim flags — USING ->
## occupant, WALKING_TO/QUEUEING -> next_claimant. A payload where two
## members claim the same machine's occupant or queue slot is structurally
## corrupt and fails Phase A (the load-side mirror of the AC4 capacity
## invariant).
func deserialize(data: Dictionary, validate_only: bool = false, known_instance_ids: Array = []) -> StubDeserializeResult:
	var result := StubDeserializeResult.new()
	if not _assert_initialized():
		return StubDeserializeResult.fail("MemberSim.deserialize(): called before init()")

	# --- Phase A: validate (zero mutation) ---
	if not data.has("counter") or not _is_numeric(data["counter"]):
		result.errors.append("MemberSim: missing or invalid 'counter'")

	# AC8 — the counter is the allocator's truth; a missing counter means a
	# new spawn could silently reuse a retired id (TR-MS-011). Never derive.
	if not data.has("member_id_counter") or not _is_numeric(data["member_id_counter"]):
		result.errors.append("MemberSim: missing or invalid 'member_id_counter' — required (AC8: never re-derive from the active set)")

	if not data.has("members") or not (data["members"] is Array):
		result.errors.append("MemberSim: missing or invalid 'members'")
	else:
		_validate_members(data["members"], known_instance_ids, result)
		# AC8 monotonicity: counter must exceed every state-machine member id
		# (a serialized GONE record included — its id must never be reused).
		if data.has("member_id_counter") and _is_numeric(data["member_id_counter"]):
			var max_state_id := _max_state_member_id(data["members"])
			if max_state_id >= 0 and int(data["member_id_counter"]) <= max_state_id:
				result.errors.append("MemberSim: member_id_counter %d <= max active member_id %d — a new spawn would reuse a retired id (AC8)" % [int(data["member_id_counter"]), max_state_id])

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
	_member_id_counter = int(data["member_id_counter"])
	members = _normalize_members(data["members"])
	_rng().state = SeededRNG.hex_to_int64(str(data["rng_state"]))
	_rebuild_reservations_from_members()
	return result


## Validates one member array's records against the grid-derived instance ids
## (AC9) and structural rules. Collects ALL problems (no short-circuit).
## State-machine records (carrying a "state" key) additionally get their
## JSON-safe shapes validated: cell / cached_path must be Vector2i or
## [x, y] (path cells individually), numeric fields must be int|float, and
## the load-side reservation capacity invariant is checked
## (_validate_reservation_claims — at most one occupant + one next_claimant
## per machine, no duplicate member ids).
func _validate_members(member_data: Array, known_instance_ids: Array, result: StubDeserializeResult) -> void:
	var seen_ids: Dictionary = {}
	for i in member_data.size():
		var member: Variant = member_data[i]
		if not (member is Dictionary):
			result.errors.append("MemberSim: member %d malformed (not a Dictionary)" % i)
			continue
		if not member.has("member_id") or not _is_numeric(member["member_id"]):
			result.errors.append("MemberSim: member %d malformed (need numeric member_id)" % i)
			continue
		var member_id := int(member["member_id"])
		if seen_ids.has(member_id):
			result.errors.append("MemberSim: duplicate member_id %d in payload" % member_id)
		seen_ids[member_id] = true
		if not member.has("state"):
			# Legacy SL-002-era stub entry — passive roster data. AC9 only.
			_validate_legacy_member(member, member_id, known_instance_ids, result)
			continue
		_validate_state_member(member, i, member_id, known_instance_ids, result)
	_validate_reservation_claims(member_data, result)


## AC9 for a legacy SL-002-era stub entry ({member_id,
## equipment_instance_id}, no state). The equipment reference must resolve
## against the validated grid.
func _validate_legacy_member(member: Dictionary, member_id: int, known_instance_ids: Array, result: StubDeserializeResult) -> void:
	if not member.has("equipment_instance_id"):
		return
	if not _is_numeric(member["equipment_instance_id"]):
		result.errors.append("MemberSim: member %s has invalid equipment_instance_id" % str(member_id))
		return
	var equipment_id := int(member["equipment_instance_id"])
	if not known_instance_ids.has(equipment_id):
		result.errors.append("MemberSim: member %s references unknown equipment_instance_id %d" % [str(member_id), equipment_id])


## Structural validation for a state-machine member record. Shapes checked
## against what _normalize_member_record will commit — JSON-safe: cells as
## Vector2i or [x, y] arrays, numerics as int|float (JSON.parse returns
## floats for integer literals in 4.7.1), blacklist keys numeric.
func _validate_state_member(member: Dictionary, i: int, member_id: int, known_instance_ids: Array, result: StubDeserializeResult) -> void:
	if typeof(member["state"]) != TYPE_STRING:
		result.errors.append("MemberSim: member %d state must be a String" % i)
		return
	if not VALID_STATES.has(str(member["state"])):
		result.errors.append("MemberSim: member %d unknown state '%s'" % [i, str(member["state"])])
		return
	if not member.has("cell"):
		result.errors.append("MemberSim: member %d missing 'cell'" % i)
	elif not _is_cell_shape_valid(member["cell"]):
		result.errors.append("MemberSim: member %d has malformed cell %s" % [i, str(member["cell"])])
	if member.has("cached_path"):
		if not (member["cached_path"] is Array):
			result.errors.append("MemberSim: member %d cached_path must be an Array" % i)
		else:
			for j in (member["cached_path"] as Array).size():
				if not _is_cell_shape_valid(member["cached_path"][j]):
					result.errors.append("MemberSim: member %d cached_path[%d] malformed %s" % [i, j, str(member["cached_path"][j])])
	for key in STATE_MEMBER_INT_KEYS:
		if member.has(key) and not _is_numeric(member[key]):
			result.errors.append("MemberSim: member %d '%s' must be numeric" % [i, key])
	if member.has("visit_revenue_multiplier_sum") \
		and not _is_numeric(member["visit_revenue_multiplier_sum"]):
		result.errors.append("MemberSim: member %d 'visit_revenue_multiplier_sum' must be numeric" % i)
	if member.has("preference_profile") and not (member["preference_profile"] is Dictionary):
		result.errors.append("MemberSim: member %d preference_profile must be a Dictionary" % i)
	if member.has("give_up_blacklist"):
		if not (member["give_up_blacklist"] is Dictionary):
			result.errors.append("MemberSim: member %d give_up_blacklist must be a Dictionary" % i)
		else:
			for k in (member["give_up_blacklist"] as Dictionary).keys():
				# JSON.parse stringifies Dictionary keys (5 -> "5") — accept
				# int|float keys AND numeric strings; normalize coerces to int.
				if not _is_numeric_key(k) or not _is_numeric(member["give_up_blacklist"][k]):
					result.errors.append("MemberSim: member %d give_up_blacklist entries must be numeric (id -> ticks)" % i)
	if member.has("recently_used_ids"):
		if not (member["recently_used_ids"] is Array):
			result.errors.append("MemberSim: member %d recently_used_ids must be an Array" % i)
		else:
			for v in member["recently_used_ids"]:
				if not _is_numeric(v):
					result.errors.append("MemberSim: member %d recently_used_ids entries must be numeric" % i)
	# AC9 — the grid is the source of truth: a target >= 0 must resolve
	# against the validated grid (legacy blobs carry equipment_instance_id,
	# state-machine blobs carry target_equipment_instance_id; -1 = none).
	if member.has("target_equipment_instance_id"):
		if not _is_numeric(member["target_equipment_instance_id"]):
			result.errors.append("MemberSim: member %s has invalid target_equipment_instance_id" % str(member_id))
		elif int(member["target_equipment_instance_id"]) >= 0:
			var target_id := int(member["target_equipment_instance_id"])
			if not known_instance_ids.has(target_id):
				result.errors.append("MemberSim: member %s references unknown target_equipment_instance_id %d" % [str(member_id), target_id])


## Load-side mirror of the AC4 capacity invariant: at most one member may be
## occupant and at most one next_claimant per machine IN THE PAYLOAD (a
## corrupt save otherwise — the live state machine can never produce two).
## A USING occupant and a QUEUEING next_claimant may coexist on one machine
## (the single queue slot), matching live semantics.
func _validate_reservation_claims(member_data: Array, result: StubDeserializeResult) -> void:
	var occupants: Dictionary = {}   # machine -> member_id
	var claimants: Dictionary = {}   # machine -> member_id
	for member in member_data:
		if not (member is Dictionary) or not member.has("state"):
			continue
		if not member.has("target_equipment_instance_id") or not _is_numeric(member["target_equipment_instance_id"]):
			continue
		var target := int(member["target_equipment_instance_id"])
		if target < 0:
			continue
		var mid := int(member["member_id"])
		match str(member["state"]):
			STATE_USING:
				if occupants.has(target):
					result.errors.append("MemberSim: machine E%d claimed as occupant by BOTH members %d and %d (load-side AC4)" % [target, int(occupants[target]), mid])
				else:
					occupants[target] = mid
			STATE_WALKING_TO, STATE_QUEUEING:
				if claimants.has(target):
					result.errors.append("MemberSim: machine E%d queue slot claimed by BOTH members %d and %d (load-side AC4)" % [target, int(claimants[target]), mid])
				else:
					claimants[target] = mid


## Highest member_id among records carrying a "state" key (state-machine
## members — including a defensively-serialized GONE record, whose id must
## never be reused). Legacy entries are excluded: they were never allocated
## from the counter (see deserialize AC8 note). Returns -1 when no
## state-machine member exists (the AC8 check is then vacuous).
func _max_state_member_id(member_data: Array) -> int:
	var max_id := -1
	for member in member_data:
		if member is Dictionary and member.has("state") and member.has("member_id") and _is_numeric(member["member_id"]):
			max_id = maxi(max_id, int(member["member_id"]))
	return max_id


## Phase B: builds the committed member roster from the validated payload —
## every record normalized so the state machine can run: ints coerced (JSON
## parses integer literals as float in 4.7.1), cells restored to Vector2i,
## give_up_blacklist keys restored to int. Legacy entries are preserved
## verbatim (ids coerced to int).
func _normalize_members(member_data: Array) -> Array:
	var out: Array = []
	for member in member_data:
		out.append(_normalize_member_record(member))
	return out


func _normalize_member_record(member: Dictionary) -> Dictionary:
	var norm: Dictionary = member.duplicate(true)
	norm["member_id"] = int(member["member_id"])
	if not member.has("state"):
		if norm.has("equipment_instance_id") and _is_numeric(norm["equipment_instance_id"]):
			norm["equipment_instance_id"] = int(norm["equipment_instance_id"])
		return norm
	norm["state"] = str(member["state"])
	if member.has("cell"):
		norm["cell"] = _cell_from_variant(member["cell"])
	if member.has("cached_path"):
		var path: Array = []
		for v in member["cached_path"]:
			path.append(_cell_from_variant(v))
		norm["cached_path"] = path
	for key in STATE_MEMBER_INT_KEYS:
		if member.has(key) and _is_numeric(member[key]):
			norm[key] = int(member[key])
	if member.has("visit_revenue_multiplier_sum") \
		and _is_numeric(member["visit_revenue_multiplier_sum"]):
		norm["visit_revenue_multiplier_sum"] = float(member["visit_revenue_multiplier_sum"])
	if member.has("preference_profile") and member["preference_profile"] is Dictionary:
		norm["preference_profile"] = (member["preference_profile"] as Dictionary).duplicate(true)
	if member.has("give_up_blacklist") and member["give_up_blacklist"] is Dictionary:
		var bl: Dictionary = {}
		for k in (member["give_up_blacklist"] as Dictionary).keys():
			bl[int(k)] = int(member["give_up_blacklist"][k])
		norm["give_up_blacklist"] = bl
	if member.has("recently_used_ids") and member["recently_used_ids"] is Array:
		var rui: Array = []
		for v in member["recently_used_ids"]:
			rui.append(int(v))
		norm["recently_used_ids"] = rui
	return norm


## Core Rule 7 load-side rebuild: the reservation map is DERIVED from the
## members' own serialized claim flags — never serialized as separate truth
## (avoids desync). USING -> occupant; WALKING_TO/QUEUEING -> next_claimant.
## Processed in ascending member_id order (TR-MS-006). A USING occupant and
## a QUEUEING next_claimant may coexist on one machine (queue depth 1),
## matching live semantics. Called only after Phase B committed.
func _rebuild_reservations_from_members() -> void:
	reservations.clear()
	var by_id: Dictionary = {}
	for m in members:
		if m is Dictionary and m.has("member_id"):
			by_id[int(m["member_id"])] = m
	var ids: Array = by_id.keys()
	ids.sort()
	for mid in ids:
		var m: Dictionary = by_id[mid]
		if not m.has("state"):
			continue
		var target := int(m.get("target_equipment_instance_id", -1))
		if target < 0:
			continue
		var rec := _reservation(target)
		match str(m["state"]):
			STATE_USING:
				rec["occupant"] = mid
			STATE_WALKING_TO, STATE_QUEUEING:
				rec["next_claimant"] = mid


## True when [v] is a cell-shaped value: a Vector2i, or an Array of exactly
## two numbers ([x, y] — the JSON-safe encoding; JSON.parse returns floats
## for all numbers in 4.7.1). Anything else is structurally corrupt.
func _is_cell_shape_valid(v: Variant) -> bool:
	if v is Vector2i:
		return true
	if not (v is Array) or (v as Array).size() != 2:
		return false
	for component in v:
		if typeof(component) != TYPE_INT and typeof(component) != TYPE_FLOAT:
			return false
	return true


## Converts a cell-shaped variant to Vector2i. Caller MUST have passed
## _is_cell_shape_valid() first.
func _cell_from_variant(v: Variant) -> Vector2i:
	if v is Vector2i:
		return v
	return Vector2i(int(v[0]), int(v[1]))


## True when [v] is int or float — the numeric types a save payload may
## carry (JSON.parse returns floats for integer literals in 4.7.1).
func _is_numeric(v: Variant) -> bool:
	return typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT


## True when [v] is numeric OR a numeric string ("5"). JSON.parse
## stringifies Dictionary keys (give_up_blacklist {5: 3} -> {"5": 3}); the
## value side stays numeric. _normalize_member_record coerces with int().
func _is_numeric_key(v: Variant) -> bool:
	if _is_numeric(v):
		return true
	return typeof(v) == TYPE_STRING and str(v).is_valid_int()
