## MemberSim — member lifecycle state machine core (Story MS-001).
##
## Story: member-sim / story-001-lifecycle-state-machine-core.md
## Req:   TR-MS-001 (tick-driven, runs FIRST; all randomness via the
##        get_rng("MemberSim") sub-stream), TR-MS-002 (lifecycle state machine:
##        ENTERING -> SELECTING_TARGET -> WALKING_TO -> [QUEUEING] -> USING ->
##        LEAVING -> GONE), TR-MS-008 (arrival Bernoulli formula), TR-MS-009
##        (use_duration formula), TR-MS-010 (exercises_per_visit formula),
##        TR-MS-012 (member_id never reused), TR-MS-013 (entrance_cell /
##        exit_cell hard dependency), TR-MS-014 (member_completed_visit S5)
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
##     machine's grid/navigation/catalog/entrance/exit/config) default to null
##     so pre-wiring call sites keep working; TR-MS-013 says the composition
##     root supplies entrance/exit at init.
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
## STATE MACHINE SCOPE (skeleton): the full transition list per Core Rule 2.
## Deliberately deferred to neighbouring stories and NOT implemented here:
##   - QUEUEING + the access-cell reservation map        -> Story 003
##   - weighted target pick / candidate pool / top-K     -> Story 002
##   - grid_version path invalidation / patience give-up -> Story 004
##   - full serialization of member state                -> Story 005
## The skeleton resolves target selection to the FIRST reachable candidate in
## ascending equipment_instance_id order (deterministic; Core Rule 6 / AC20's
## tie-break) and walks straight to USING on arrival (no queue slot — story
## 003 owns that).
##
## AC1 / QA "wanders ~20 ticks" NOTE: the story QA edge case describes an
## empty gym as "member wanders ~20 ticks then leaves calmly". The BLOCKING
## assertion is "state == LEAVING by end of the same tick" (no extra tick
## stalled), so the skeleton implements immediate LEAVING on an empty
## candidate pool. The calm-wander behavior belongs to Story 004's patience
## system (out of scope here).
##
## USE-DURATION NOTE (skeleton): TR-MS-009 rolls duration from per-equipment
## catalog fields, but the instance_id -> equipment_id resolution does not
## exist yet (GridSystem stores only integer occupant_id; PlacedInstance.
## equipment_id is "" until the equipment-catalog wiring lands). The skeleton
## therefore rolls from the config's default use-duration range; the
## catalog-injected per-equipment roll lands with Story 002/005.
##
## CONFIG DICTIONARY (data-driven seam): all gameplay tuning values arrive
## via the init [config] Dictionary (defaults = GDD Tuning Knobs anchors). A
## future game-config file (JSON) maps directly onto this shape — the
## composition root owns the values, never hardcoded per-run behaviour here.
class_name MemberSim extends SimSystem

# === State machine (Core Rule 2) ===
# QUEUEING is deliberately absent from the implemented set — it lands with
# Story 003's reservation map.
const STATE_ENTERING := "ENTERING"
const STATE_SELECTING_TARGET := "SELECTING_TARGET"
const STATE_WALKING_TO := "WALKING_TO"
const STATE_USING := "USING"
const STATE_LEAVING := "LEAVING"
const STATE_GONE := "GONE"
const VALID_STATES: Array[String] = [
	STATE_ENTERING, STATE_SELECTING_TARGET, STATE_WALKING_TO,
	STATE_USING, STATE_LEAVING, STATE_GONE,
]

## Why a member left the gym (drives S5 emission — quota-met departures only).
const REASON_QUOTA_MET := "quota_met"
const REASON_NO_CANDIDATES := "no_candidates"

# === Config keys (see class header — the data-driven seam) ===
const CONFIG_MAX_CONCURRENT_MEMBERS := "max_concurrent_members"
const CONFIG_BASE_ARRIVAL_RATE_PER_MIN := "base_arrival_rate_per_min"
const CONFIG_SATISFACTION_MODIFIER := "satisfaction_modifier"
const CONFIG_USE_DURATION_MEAN_TICKS := "use_duration_mean_ticks"
const CONFIG_USE_DURATION_STDDEV_TICKS := "use_duration_stddev_ticks"
const CONFIG_USE_DURATION_MIN_TICKS := "use_duration_min_ticks"
const CONFIG_USE_DURATION_MAX_TICKS := "use_duration_max_ticks"
const CONFIG_LEAVING_TIMEOUT_TICKS := "leaving_timeout_ticks"
const CONFIG_EXERCISES_MEAN := "exercises_mean"
const CONFIG_EXERCISES_STDDEV := "exercises_stddev"
const CONFIG_EXERCISES_MIN := "exercises_min"
const CONFIG_EXERCISES_MAX := "exercises_max"

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
##        cached_path: Array[Vector2i], leaving_timeout_ticks,
##        use_ticks_remaining (USING only), leaving_reason (LEAVING only)}
var members: Array = []

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

# === Tuning values (GDD Tuning Knobs anchors; see class header) ===
var _max_concurrent_members: int = 15
var _base_arrival_rate_per_min: float = 4.0
var _satisfaction_modifier: float = 1.0  # placeholder until Satisfaction #10 (OQ3)
var _use_duration_mean_ticks: int = 200
var _use_duration_stddev_ticks: int = 35
var _use_duration_min_ticks: int = 100
var _use_duration_max_ticks: int = 300
var _leaving_timeout_ticks: int = 300
var _exercises_mean: float = 3.0
var _exercises_stddev: float = 1.0
var _exercises_min: int = 1
var _exercises_max: int = 5


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
func init(
	orchestrator: SimulationOrchestrator,
	seeded_rng: SeededRNG,
	grid: GridStateReader = null,
	navigation: Navigation = null,
	catalog: EquipmentCatalog = null,
	entrance_cell: Vector2i = Vector2i(-1, -1),
	exit_cell: Vector2i = Vector2i(-1, -1),
	config: Dictionary = {}
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
	_apply_config(config)
	_seeded_rng.register_system(system_name())


## Reads the [config] Dictionary into the tuning fields. Missing keys keep
## the GDD-anchor defaults (see class header). Values are coerced with int()/
## float() so a future JSON config file maps onto this shape directly.
func _apply_config(config: Dictionary) -> void:
	_max_concurrent_members = int(config.get(CONFIG_MAX_CONCURRENT_MEMBERS, _max_concurrent_members))
	_base_arrival_rate_per_min = float(config.get(CONFIG_BASE_ARRIVAL_RATE_PER_MIN, _base_arrival_rate_per_min))
	_satisfaction_modifier = float(config.get(CONFIG_SATISFACTION_MODIFIER, _satisfaction_modifier))
	_use_duration_mean_ticks = int(config.get(CONFIG_USE_DURATION_MEAN_TICKS, _use_duration_mean_ticks))
	_use_duration_stddev_ticks = int(config.get(CONFIG_USE_DURATION_STDDEV_TICKS, _use_duration_stddev_ticks))
	_use_duration_min_ticks = int(config.get(CONFIG_USE_DURATION_MIN_TICKS, _use_duration_min_ticks))
	_use_duration_max_ticks = int(config.get(CONFIG_USE_DURATION_MAX_TICKS, _use_duration_max_ticks))
	_leaving_timeout_ticks = int(config.get(CONFIG_LEAVING_TIMEOUT_TICKS, _leaving_timeout_ticks))
	_exercises_mean = float(config.get(CONFIG_EXERCISES_MEAN, _exercises_mean))
	_exercises_stddev = float(config.get(CONFIG_EXERCISES_STDDEV, _exercises_stddev))
	_exercises_min = int(config.get(CONFIG_EXERCISES_MIN, _exercises_min))
	_exercises_max = int(config.get(CONFIG_EXERCISES_MAX, _exercises_max))


func system_name() -> String:
	return "MemberSim"


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
	_process_arrival()
	_process_members()


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
	match str(member["state"]):
		STATE_ENTERING:
			_on_entering(member)
		STATE_SELECTING_TARGET:
			_on_selecting_target(member)
		STATE_WALKING_TO:
			_on_walking_to(member)
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


## SELECTING_TARGET evaluation (Core Rule 2). Three outcomes:
##   (a) visit quota reached      -> LEAVING regardless of candidates (AC2)
##   (b) no reachable candidate   -> LEAVING the same tick (AC1 — the visible
##       "walked in, turned around, left" flow signal; never stalls)
##   (c) candidate found          -> WALKING_TO (skeleton pick: first
##       reachable candidate in ascending equipment_instance_id order — Story
##       002 replaces this with the weighted pick)
func _on_selecting_target(member: Dictionary) -> void:
	if int(member["exercises_done"]) >= int(member["exercises_per_visit"]):
		_begin_leaving(member, REASON_QUOTA_MET)
		return
	var target_id := _pick_reachable_target(member)
	if target_id == -1:
		_begin_leaving(member, REASON_NO_CANDIDATES)
		return
	var access_cells: Array = _grid.get_access_cells(target_id)
	var path: Array[Vector2i] = _navigation.get_path(member["cell"], access_cells[0])
	if path.is_empty():
		_begin_leaving(member, REASON_NO_CANDIDATES)
		return
	member["target_equipment_instance_id"] = target_id
	member["cached_path"] = path
	member["state"] = STATE_WALKING_TO


## Builds the skeleton candidate pool: every placed instance, ascending
## equipment_instance_id (explicit sort — get_placed_instances() order is
## stable within a grid version but NOT guaranteed across commits, so sorting
## is what makes the pick deterministic), excluding nothing else — the
## reservation "fully spoken for" filter is Story 003, the preference/novelty
## weighting is Story 002. Returns the first candidate with a non-empty path
## to its access cell, or -1 when NONE is reachable (AC1's "zero
## reachable/available candidates").
##
## PERFORMANCE NOTE: this path-checks every candidate. Story 002 replaces the
## pool with the top-K (3-5) weight-ordered subset precisely to bound this
## cost; the skeleton optimizes for correctness, not for the perf budget.
func _pick_reachable_target(member: Dictionary) -> int:
	var instances: Array = _grid.get_placed_instances()
	var ids: Array[int] = []
	for inst in instances:
		ids.append(int(inst.instance_id))
	ids.sort()
	var from: Vector2i = member["cell"]
	for instance_id in ids:
		var access_cells: Array = _grid.get_access_cells(instance_id)
		if access_cells.is_empty():
			continue  # no access cell — cannot be used
		if not _navigation.get_path(from, access_cells[0]).is_empty():
			return instance_id
	return -1


## WALKING_TO: consumes the cached path one cell per tick. The skeleton has
## no grid_version stamp (Story 004 owns path invalidation); it defensively
## aborts back to SELECTING_TARGET if the next cell has become solid
## (e.g. equipment placed onto the path mid-walk). On arrival at the access
## cell -> USING (the QUEUEING/reservation branch lands with Story 003).
func _on_walking_to(member: Dictionary) -> void:
	var path: Array = member["cached_path"]
	# get_path() includes both endpoints — skip the current cell.
	while not path.is_empty() and path[0] == member["cell"]:
		path.remove_at(0)
	if path.is_empty():
		_start_using(member)
		return
	var next_cell: Vector2i = path[0]
	if _grid.is_solid(next_cell):
		member["cached_path"] = []
		member["target_equipment_instance_id"] = -1
		member["state"] = STATE_SELECTING_TARGET
		return
	member["cell"] = next_cell
	path.remove_at(0)
	member["cached_path"] = path
	if path.is_empty():
		_start_using(member)


## Enters USING at the access cell. The skeleton has no reservation
## occupancy — the member is simply on the access cell (Story 003 owns the
## occupant/next_claimant mechanics). use_ticks_remaining is rolled once.
func _start_using(member: Dictionary) -> void:
	member["state"] = STATE_USING
	member["use_ticks_remaining"] = _roll_use_duration()


## USING: counts down the use duration. Only SUCCESSFULLY completed uses
## count toward the visit quota (GDD Formulas — abandoned queues neither
## count nor reset). On completion: quota met -> LEAVING, else SELECTING_TARGET.
func _on_using(member: Dictionary) -> void:
	member["use_ticks_remaining"] = int(member["use_ticks_remaining"]) - 1
	if int(member["use_ticks_remaining"]) > 0:
		return
	member["exercises_done"] = int(member["exercises_done"]) + 1
	member["target_equipment_instance_id"] = -1
	member["cached_path"] = []
	if int(member["exercises_done"]) >= int(member["exercises_per_visit"]):
		_begin_leaving(member, REASON_QUOTA_MET)
	else:
		member["state"] = STATE_SELECTING_TARGET


## LEAVING: paths to the single exit_cell with the same per-cell walk as
## WALKING_TO. A defensive safety timeout forces GONE if no exit path ever
## resolves — Pillar 2 forbids a permanently stuck member (AC21). The
## timeout counts DOWN ONLY while the member is genuinely stuck (repath
## empty); while a path resolves and is walked, it holds — a transient
## blockage mid-leave must never cause a premature GONE (AC21 edge case).
func _on_leaving(member: Dictionary, to_remove: Array) -> void:
	var path: Array = member["cached_path"]
	while not path.is_empty() and path[0] == member["cell"]:
		path.remove_at(0)
	if not path.is_empty():
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


## Enters LEAVING. Records WHY (drives S5) and arms the safety timeout.
func _begin_leaving(member: Dictionary, reason: String) -> void:
	member["state"] = STATE_LEAVING
	member["leaving_reason"] = reason
	member["leaving_timeout_ticks"] = _leaving_timeout_ticks
	member["target_equipment_instance_id"] = -1
	member["cached_path"] = []  # repath from the current cell on the first LEAVING tick


## Terminal transition: marks the member GONE (removed at tick end; the id is
## retired forever — TR-MS-012) and emits S5 exactly once, ONLY for quota-met
## departures (ADR-0005 — walk-failure/patience-exhaust earn nothing).
func _mark_gone(member: Dictionary, to_remove: Array) -> void:
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
		"leaving_timeout_ticks": 0,
	}
	members.append(member)


## Number of active (non-removed) members. GONE members are removed at the
## end of the tick they leave, so roster size IS the active count.
func _active_count() -> int:
	return members.size()


## TR-MS-010: exercises_per_visit = round(clamp(randfn(mean * visit_length_
## modifier, stddev), min, max)). visit_length_modifier is the satisfaction
## hook (OQ3, placeholder 1.0 for now). Drawn once on entry.
func _roll_exercises_per_visit() -> int:
	var raw: float = _rng().randfn(_exercises_mean, _exercises_stddev)
	return clampi(roundi(raw), _exercises_min, _exercises_max)


## Resolved at spawn and stored (Core Rule 7 — never a re-derivable seed).
## Story 002 owns the profile SHAPE (per-member preference weights); the
## skeleton stores the single preference-noise draw the GDD defines
## (Uniform(0.85, 1.15) — pref_noise_i in target_selection_weight).
func _roll_preference_profile() -> Dictionary:
	return {"preference_noise": _rng().randf_range(0.85, 1.15)}


## TR-MS-009: use_duration = round(clamp(randfn(mean, stddev), min, max)).
## Skeleton NOTE (class header): per-equipment values come from the config's
## default range until instance_id -> equipment_id resolution lands (Story
## 002/005) — the injected catalog is accepted but not yet queried.
func _roll_use_duration() -> int:
	var raw: float = _rng().randfn(float(_use_duration_mean_ticks), float(_use_duration_stddev_ticks))
	return clampi(roundi(raw), _use_duration_min_ticks, _use_duration_max_ticks)


## Returns the full MemberSim state as a JSON-safe Dictionary:
##   { counter: int, members: Array, member_id_counter: int,
##     rng_state: "0x…" }
## Pure read — no draws, no mutation (SL-001 AC1 counts serialize calls, so
## serialize stays side-effect free). members are stored VERBATIM — legacy
## roster entries and full state-machine records alike — so both shapes
## round-trip unchanged (the integration tests' byte-identical contract).
## rng_state is the CURRENT sub-stream state (hex per ADR-0002).
func serialize() -> Dictionary:
	if not _assert_initialized():
		return {}
	return {
		"counter": counter,
		"members": members,
		"member_id_counter": _member_id_counter,
		"rng_state": SeededRNG.int64_to_hex(_rng().state),
	}


## Two-phase deserialize (TR-SL-005, ADR-0002).
##
## Phase A validates EVERYTHING with zero mutation; Phase B commits only if
## Phase A passed. Failures are returned, never push_error'd (corrupt save =
## normal outcome). [validate_only] runs Phase A and returns the verdict
## without committing (SaveLoad Phase A protocol).
##
## AC9 (grid is the source of truth): every member's equipment reference —
## legacy `equipment_instance_id` or full `target_equipment_instance_id` (>= 0)
## — must be present in [known_instance_ids] (the set extracted from the
## save's grid records that GridSystem Phase A validated). A member
## referencing an absent id fails the WHOLE load; never a silent orphan.
##
## Required fields (hard failure, no invented defaults):
##   counter (int), members (Array of member records), rng_state ("0x" hex).
## Optional: member_id_counter (int — present in skeleton-era blobs; absent
## in SL-002-era stub blobs, which keep the current counter).
func deserialize(data: Dictionary, validate_only: bool = false, known_instance_ids: Array = []) -> StubDeserializeResult:
	var result := StubDeserializeResult.new()
	if not _assert_initialized():
		return StubDeserializeResult.fail("MemberSim.deserialize(): called before init()")

	# --- Phase A: validate (zero mutation) ---
	if not data.has("counter") or typeof(data["counter"]) != TYPE_INT:
		result.errors.append("MemberSim: missing or invalid 'counter'")

	if data.has("member_id_counter") and typeof(data["member_id_counter"]) != TYPE_INT:
		result.errors.append("MemberSim: invalid 'member_id_counter'")

	if not data.has("members") or not (data["members"] is Array):
		result.errors.append("MemberSim: missing or invalid 'members'")
	else:
		_validate_members(data["members"], known_instance_ids, result)

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
	if data.has("member_id_counter"):
		_member_id_counter = int(data["member_id_counter"])
	_rng().state = SeededRNG.hex_to_int64(str(data["rng_state"]))
	return result


## Validates one member array's records against the grid-derived instance ids
## (AC9) and structural rules. Collects ALL problems (no short-circuit).
func _validate_members(member_data: Array, known_instance_ids: Array, result: StubDeserializeResult) -> void:
	for i in member_data.size():
		var member: Variant = member_data[i]
		if not (member is Dictionary):
			result.errors.append("MemberSim: member %d malformed (not a Dictionary)" % i)
			continue
		if not member.has("member_id") or typeof(member["member_id"]) != TYPE_INT:
			result.errors.append("MemberSim: member %d malformed (need int member_id)" % i)
			continue
		var member_id := int(member["member_id"])
		if member.has("state"):
			if typeof(member["state"]) != TYPE_STRING:
				result.errors.append("MemberSim: member %d state must be a String" % i)
				continue
			if not VALID_STATES.has(str(member["state"])):
				result.errors.append("MemberSim: member %d unknown state '%s'" % [i, str(member["state"])])
		# AC9 — the grid is the source of truth: any equipment reference
		# absent from the validated grid fails the WHOLE load. Legacy blobs
		# carry equipment_instance_id; skeleton-era blobs carry
		# target_equipment_instance_id (-1 = none).
		if member.has("equipment_instance_id"):
			var equipment_id := int(member["equipment_instance_id"])
			if not known_instance_ids.has(equipment_id):
				result.errors.append("MemberSim: member %s references unknown equipment_instance_id %d" % [str(member_id), equipment_id])
		if member.has("target_equipment_instance_id") and int(member["target_equipment_instance_id"]) >= 0:
			var target_id := int(member["target_equipment_instance_id"])
			if not known_instance_ids.has(target_id):
				result.errors.append("MemberSim: member %s references unknown target_equipment_instance_id %d" % [str(member_id), target_id])
