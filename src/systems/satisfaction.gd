## Satisfaction — member accumulators + per-use quality signal (Story SAT-001).
##
## Story: satisfaction / story-001-member-accumulators-use-quality.md
## Req:   TR-SAT-001 (tick-driven, runs after Congestion; deterministic, no RNG),
##        TR-SAT-002 (member_accumulators[member_id] = {S_acc, n_uses,
##        queue_ticks, n_fail, n_interrupt} — owned here, not MemberSim),
##        TR-SAT-003 (use_quality_i = w_zone * clamp(total_i / Z_NORM, 0, 1)
##        - w_cong * Congestion_i(t-1); w_zone = w_cong = 0.5)
## ADR:   ADR-0005 (Signal Bus — satisfaction events are DIRECT READS from
##        MemberSim during on_tick, §3 note; fixed tick order MemberSim ->
##        Congestion -> Satisfaction -> Economy), ADR-0003 (ZoneRules is a
##        stateless pure function — read via the injected reader seam),
##        ADR-0002 (two-phase deserialize; floats need full_precision)
##
## THIS FILE REPLACES THE SL-002 CORE-LAYER INTEGRATION STUB. The public
## contract surface SaveLoad depends on is preserved exactly:
##   - class_name Satisfaction extends SimSystem
##   - init(orchestrator, seeded_rng) — extra OPTIONAL parameters (member_sim,
##     congestion_reader, zone_total_reader, config) default to null /
##     Callable() / {} so pre-wiring call sites keep working unchanged.
##   - system_name() == "Satisfaction"
##   - on_tick(tick_count: int) -> void  (orchestrator's fixed dispatch)
##   - serialize() / deserialize(data, validate_only) two-phase protocol,
##     returning StubDeserializeResult. The serialize shape EXTENDS the
##     stub's {counter, rng_state} with the story-004 real state
##     (member_accumulators + global_satisfaction, TR-SAT-009) — the
##     stub-era keys are kept so the save-load integration tests'
##     byte-identical contract round-trips unchanged (MemberSim precedent).
##
## PRE-WIRING COMPATIBILITY PATH (documented, not silent): the SL-002/003
## save-load integration tests construct Satisfaction with ONLY
## init(orch, srg) — no member_sim, no readers. Such an instance is NOT
## configured to observe anything, so on_tick() keeps the stub's observable
## behavior (counter += 1) and nothing else. Unlike the stub, this system
## NEVER draws from its RNG sub-stream (TR-SAT-001 — no RNG). The sub-stream
## is still REGISTERED (SaveLoad's AC7 tests iterate get_rng() over all four
## systems); it just never advances, so serializing the static initial state
## is deterministic and restores exactly (the Economy precedent).
##
## ACCUMULATOR LIFECYCLE (Core Rule 2 / TR-SAT-002): created when a member
## enters (roster diff — a member_id seen for the first time), updated from
## that member's events, and on departure folded into global_satisfaction
## then discarded. The accumulator is keyed EXACTLY as
## {S_acc, n_uses, queue_ticks, n_fail, n_interrupt} — story-004 serializes
## this shape. MemberSim's legacy state-less roster entries are exempt
## (mirroring MemberSim's own _update_member exemption) — they are passive
## save-load data, not state-machine members.
##
## USE_QUALITY (Core Rule 3 / TR-SAT-003): when a member STARTS using
## instance i (state -> USING), Satisfaction snapshots Congestion_i(t-1) ONCE
## (single read at use-start — the project-wide "read t-1" rule), stores it
## in a pending-use record, and at use completion (exercises_done increased)
## computes:
##     use_quality_i = w_zone * clamp(total_i / Z_NORM, 0, 1)
##                     - w_cong * Congestion_i(t-1)
## total_i is read via the injected zone_total_reader Callable
## (instance_id -> total), which the composition root wires to
## ZoneRules.evaluate(...).get(instance_id).total — consumed directly per
## equipment a member actually used, never a smeared average. Output
## [-0.5, +0.5] — symmetric (AC9). S_member (Core Rule 4) and the global
## EMA fold are landed here because the story-001 QA cases (AC5/6/8/10)
## exercise them; story-002 adds the penalty-cap test file (AC11/12) and
## story-003 adds the modifier functions + dedicated EMA tests.
##
## EVENT SOURCE (ADR-0005 §3 note): on_tick reads MemberSim DIRECTLY via the
## injected duck-typed reader (members roster + get_satisfaction_penalty_events),
## never via signals. Departures are detected by roster diff (member_id
## disappears from `members`) — this covers ALL departures including
## walk-failure / patience-exhaust, which S5 (member_completed_visit,
## quota-met only) would miss. Processing order is ascending member_id for
## determinism (Core Rule 8).
class_name Satisfaction extends SimSystem

## Data-driven config seam (coding standard: gameplay values never
## hardcoded). init() reads these keys from the optional [config]
## Dictionary; absent keys fall back to the GDD anchors below.
const CONFIG_W_ZONE := "w_zone"
const CONFIG_W_CONG := "w_cong"
const CONFIG_Z_NORM := "z_norm"
const CONFIG_S_BASE := "s_base"
const CONFIG_W_QUEUE := "w_queue"
const CONFIG_QUEUE_NORM_TICKS := "queue_norm_ticks"
const CONFIG_W_FAIL := "w_fail"
const CONFIG_CAP_FAIL := "cap_fail"
const CONFIG_W_INTERRUPT := "w_interrupt"
const CONFIG_CAP_INTERRUPT := "cap_interrupt"
const CONFIG_ALPHA_G := "alpha_g"
const CONFIG_DAMP := "damp"

## GDD Formulas — provisional MVP anchors (playtest tuning).
const W_ZONE := 0.5        ## equal weight — neither cluster nor spread dominates
const W_CONG := 0.5        ## equal weight (the ⭐ master pull-vs-push dial)
const Z_NORM := 2.0        ## anchors a top-tier instance (z ~= 1.0) to full congestion
const S_BASE := 0.5        ## neutral baseline — a blank visit is neither good nor bad
const W_QUEUE := 0.3
const QUEUE_NORM_TICKS := 100  ## 10 s
const W_FAIL := 0.15
const CAP_FAIL := 0.30
const W_INTERRUPT := 0.20
const CAP_INTERRUPT := 0.20
const ALPHA_G := 0.05      ## slow global EMA — one member can't swing reputation
const DAMP := 0.5          ## visit-length leg damping — halves the deviation
                           ## (prevents ~modifier² occupancy oscillation)

## Accumulator key names (TR-SAT-002 — story-004 serializes this exact set).
const ACC_S_ACC := "S_acc"
const ACC_N_USES := "n_uses"
const ACC_QUEUE_TICKS := "queue_ticks"
const ACC_N_FAIL := "n_fail"
const ACC_N_INTERRUPT := "n_interrupt"

## MemberSim leaving reasons that count as a walk-failure (n_fail) — the
## "walked in, turned around, left" and path-blocked departures. quota_met
## is NOT a failure; patience give-up is not a departure at all.
const REASON_NO_CANDIDATES := "no_candidates"
const REASON_PATH_BLOCKED := "path_blocked"

## Injected composition root (kept for signature symmetry; this system
## needs no cross-system signal wiring — satisfaction events are direct
## reads per ADR-0005 §3).
var _orchestrator: SimulationOrchestrator
## Injected SeededRNG registry — the sub-stream is registered here
## (ADR-0004 / save-load AC7 contract) but NEVER drawn (TR-SAT-001).
var _seeded_rng: SeededRNG

## Injected MemberSim read surface (duck-typed, mirroring MemberSim's own
## duck-typed `congestion_reader` seam). Exposes exactly:
##   members: Array   — member records {member_id, state, cell, ...}
##   get_satisfaction_penalty_events() -> int  — mid-use interruptions/tick
var _member_sim: Variant = null

## Injected Congestion read surface (duck-typed): per_equipment_congestion(
## instance_id) -> float in [0,1] — the authoritative Congestion(t-1) buffer
## (CG-004 contract). Null in pre-wiring rigs -> 0.0 (idle).
var _congestion_reader: Variant = null

## Injected ZoneRules total reader: Callable(instance_id) -> float total_i.
## The composition root wires it to ZoneRules.evaluate(snapshot, catalog)
## per-instance dict's "total" — the seam keeps Satisfaction decoupled from
## GridStateReader/EquipmentCatalog (and testable with a fake Callable).
var _zone_total_reader: Callable = Callable()

## Per-tick counter — the stub-era observable, preserved so the serialize
## payload {counter, rng_state} and the save-load byte-identity contract stay
## stable. Not gameplay state (the meter's observable IS global_satisfaction).
var counter: int = 0

## The reputation meter (Core Rule 5 / TR-SAT-005, formula landed here for
## the departure fold; story-003 owns the modifier functions + dedicated EMA
## tests). Init 0.5 — neutral, no false pre-punishment. Folded on departure:
##   global = alpha_g * S_member + (1 - alpha_g) * global, clamped [0,1].
var global_satisfaction: float = S_BASE

## Core Rule 2 state (TR-SAT-002) — member_id -> {S_acc, n_uses, queue_ticks,
## n_fail, n_interrupt}. Owned HERE, not by MemberSim. Serialized by
## story-004 (TR-SAT-009); this story keeps the stub-era serialize shape.
var member_accumulators: Dictionary = {}

## Per-member pending-use record: member_id -> {instance_id, congestion}
## (the single Congestion_i(t-1) snapshot taken at use-START, Core Rule 3).
## Transient — cleared at use completion / interrupt / departure. Not part
## of the serialized accumulator shape (story-004 owns the extended blob).
var _pending_uses: Dictionary = {}

## Last-seen member state for the roster diff: member_id -> {exercises_done}
## (state is read live; exercises_done is the use-completion signal).
var _last_seen: Dictionary = {}

## Tuning fields — mirrors of the GDD anchors, overridable via [config].
var _w_zone: float = W_ZONE
var _w_cong: float = W_CONG
var _z_norm: float = Z_NORM
var _s_base: float = S_BASE
var _w_queue: float = W_QUEUE
var _queue_norm_ticks: int = QUEUE_NORM_TICKS
var _w_fail: float = W_FAIL
var _cap_fail: float = CAP_FAIL
var _w_interrupt: float = W_INTERRUPT
var _cap_interrupt: float = CAP_INTERRUPT
var _alpha_g: float = ALPHA_G
var _damp: float = DAMP


## Two-phase init (ADR-0001). Stores the injected dependencies (all optional
## with safe defaults so `init(orch, srg)` pre-wiring call sites keep
## working), applies the data-driven config, and registers the "Satisfaction"
## RNG sub-stream exactly once (SeededRNG.register_system is the hard gate).
## The stream is registered for the save-load AC7 contract but NEVER drawn
## from (TR-SAT-001 — this system is a pure function of its inputs).
func init(
	orchestrator: SimulationOrchestrator,
	seeded_rng: SeededRNG,
	member_sim: Variant = null,
	congestion_reader: Variant = null,
	zone_total_reader: Callable = Callable(),
	config: Dictionary = {}
) -> void:
	if not _mark_initialized():
		return
	_orchestrator = orchestrator
	_seeded_rng = seeded_rng
	_member_sim = member_sim
	_congestion_reader = congestion_reader
	_zone_total_reader = zone_total_reader
	_apply_config(config)
	_seeded_rng.register_system(system_name())


## Reads the [config] Dictionary into the tuning fields. Missing keys keep
## the GDD anchors (see class header). Coerced with float()/int() so a
## future JSON config file maps onto this shape directly.
func _apply_config(config: Dictionary) -> void:
	_w_zone = float(config.get(CONFIG_W_ZONE, _w_zone))
	_w_cong = float(config.get(CONFIG_W_CONG, _w_cong))
	_z_norm = float(config.get(CONFIG_Z_NORM, _z_norm))
	_s_base = float(config.get(CONFIG_S_BASE, _s_base))
	_w_queue = float(config.get(CONFIG_W_QUEUE, _w_queue))
	_queue_norm_ticks = int(config.get(CONFIG_QUEUE_NORM_TICKS, _queue_norm_ticks))
	_w_fail = float(config.get(CONFIG_W_FAIL, _w_fail))
	_cap_fail = float(config.get(CONFIG_CAP_FAIL, _cap_fail))
	_w_interrupt = float(config.get(CONFIG_W_INTERRUPT, _w_interrupt))
	_cap_interrupt = float(config.get(CONFIG_CAP_INTERRUPT, _cap_interrupt))
	_alpha_g = float(config.get(CONFIG_ALPHA_G, _alpha_g))
	_damp = float(config.get(CONFIG_DAMP, _damp))


func system_name() -> String:
	return "Satisfaction"


## Per-tick entry point — runs THIRD in the orchestrator's fixed dispatch
## (MemberSim -> Congestion -> Satisfaction -> Economy; GDD Core Rule 1), so
## Congestion's t-1 buffer is already finalized when the use-quality snapshot
## reads it. No RNG, no await — deterministic by construction (TR-SAT-001).
##
## PRE-WIRING PATH: member_sim == null -> counter += 1 and nothing else
## (preserves the SL-002 stub's observable behavior for the save-load
## determinism tests; no RNG draw, unlike the stub).
##
## CONFIGURED PATH: reads MemberSim's roster directly (ADR-0005 §3) and
## synthesizes accumulator events: entered (new member_id), queue ticks
## (QUEUEING state), use-start (-> USING, snapshot congestion), use-complete
## (exercises_done increased), mid-use interrupt (left USING without an
## exercise), walk-failure (LEAVING with no_candidates/path_blocked), and
## departed (member_id gone from roster -> fold + discard). All iteration in
## ascending member_id order for determinism (Core Rule 8).
func on_tick(tick_count: int) -> void:
	if not _assert_initialized():
		return
	counter += 1
	if _member_sim == null:
		return  # pre-wiring compatibility — nothing to observe

	# Build the current roster keyed by member_id (legacy state-less entries
	# are exempt — mirroring MemberSim's own _update_member exemption).
	var roster: Dictionary = {}
	for m in _member_sim.members:
		if m is Dictionary and m.has("member_id") and m.has("state"):
			roster[int(m["member_id"])] = m

	# 1) Departures first (fold + discard), ascending member_id — Core Rule 8
	#    fixed order. A member_id we track but the roster no longer has =
	#    departed (GONE removed at MemberSim's tick end).
	var departed: Array = []
	for member_id in _last_seen:
		if not roster.has(member_id):
			departed.append(member_id)
	departed.sort()
	for member_id in departed:
		on_member_departed(member_id)
		_last_seen.erase(member_id)

	# 2) Per-member event intake, ascending member_id.
	var ids: Array = roster.keys()
	ids.sort()
	for member_id in ids:
		_sync_member(member_id, roster[member_id])
		_last_seen[member_id] = {
			"exercises_done": int(roster[member_id].get("exercises_done", 0)),
		}


## Event intake for one member (ascending member_id — deterministic order).
## [member] is the live MemberSim record {member_id, state, exercises_done,
## target_equipment_instance_id, leaving_reason?, ...}.
func _sync_member(member_id: int, member: Dictionary) -> void:
	if not member_accumulators.has(member_id):
		on_member_entered(member_id)

	var state := str(member.get("state", ""))
	var target := int(member.get("target_equipment_instance_id", -1))
	var prev: Dictionary = _last_seen.get(member_id, {})
	var prev_ex := int(prev.get("exercises_done", 0))
	var ex := int(member.get("exercises_done", 0))

	# Queue tick: every tick a member is in QUEUEING counts toward
	# queue_ticks (Core Rule 4 — queue_penalty feeds S_member).
	if state == "QUEUEING":
		add_queue_ticks(member_id, 1)

	# Use START: entering USING with a real target — snapshot Congestion_i(t-1)
	# ONCE here (the "read t-1" rule), never re-read at completion.
	if state == "USING" and target >= 0 and not _pending_uses.has(member_id):
		on_use_started(member_id, target)

	# Use COMPLETE: exercises_done increased since last tick. The pending-use
	# record (captured at use-start) identifies the instance — MemberSim
	# clears target_equipment_instance_id on completion, so the roster alone
	# cannot tell which instance was used (Core Rule 3: per equipment a member
	# actually used, not a smeared average).
	if ex > prev_ex:
		on_use_completed(member_id)

	# Mid-use INTERRUPT (AC14): was USING with a pending use, left USING
	# WITHOUT an exercise completing (equipment deleted mid-use). MemberSim
	# exposes the aggregate count via get_satisfaction_penalty_events(); the
	# per-member attribution comes from this state transition.
	if _pending_uses.has(member_id) and ex == prev_ex and state != "USING":
		on_interrupt(member_id)

	# Walk-FAILURE: entering LEAVING with a failure reason (walked in, turned
	# around / path blocked). quota_met is NOT a failure.
	if state == "LEAVING":
		var reason := str(member.get("leaving_reason", ""))
		if reason == REASON_NO_CANDIDATES or reason == REASON_PATH_BLOCKED:
			on_walk_fail(member_id)


## --- Accumulator lifecycle (public event API — testable directly) ---

## Core Rule 2: a member entered -> create their accumulator, zeroed.
func on_member_entered(member_id: int) -> void:
	if not _assert_initialized():
		return
	if member_accumulators.has(member_id):
		return  # defensive — already tracking
	member_accumulators[member_id] = _new_accumulator()


## Core Rule 3: a member STARTS using instance [instance_id] — take the
## single Congestion_i(t-1) snapshot now (never integrated over the use).
func on_use_started(member_id: int, instance_id: int) -> void:
	if not _assert_initialized():
		return
	var congestion := _read_congestion(instance_id)
	_pending_uses[member_id] = {
		"instance_id": instance_id,
		"congestion": congestion,
	}


## Core Rule 3: a member COMPLETED a use — compute use_quality with the
## use-start congestion snapshot + the current total_i, fold into S_acc.
func on_use_completed(member_id: int) -> void:
	var acc: Dictionary = member_accumulators.get(member_id, {})
	if acc.is_empty():
		return  # defensive — not tracked
	var pending: Dictionary = _pending_uses.get(member_id, {})
	var instance_id := int(pending.get("instance_id", -1))
	var congestion := float(pending.get("congestion", 0.0))
	var total_i := _read_zone_total(instance_id)
	var uq := compute_use_quality(total_i, congestion)
	acc[ACC_S_ACC] = float(acc[ACC_S_ACC]) + uq
	acc[ACC_N_USES] = int(acc[ACC_N_USES]) + 1
	_pending_uses.erase(member_id)


## Core Rule 4: queue ticks accumulate per tick spent in QUEUEING.
func add_queue_ticks(member_id: int, ticks: int) -> void:
	var acc: Dictionary = member_accumulators.get(member_id, {})
	if acc.is_empty():
		return
	acc[ACC_QUEUE_TICKS] = int(acc[ACC_QUEUE_TICKS]) + maxi(ticks, 0)


## Core Rule 4: one walk-failure event (no_candidates / path_blocked departure).
func on_walk_fail(member_id: int) -> void:
	var acc: Dictionary = member_accumulators.get(member_id, {})
	if acc.is_empty():
		return
	acc[ACC_N_FAIL] = int(acc[ACC_N_FAIL]) + 1


## Core Rule 4: one mid-use interruption (equipment deleted mid-use, AC14).
func on_interrupt(member_id: int) -> void:
	var acc: Dictionary = member_accumulators.get(member_id, {})
	if acc.is_empty():
		return
	acc[ACC_N_INTERRUPT] = int(acc[ACC_N_INTERRUPT]) + 1
	_pending_uses.erase(member_id)


## Core Rule 2: a member departed -> compute final S_member, fold into the
## global meter (slow EMA), discard the accumulator. Returns the folded
## S_member (0.0 when the member was never tracked — defensive).
func on_member_departed(member_id: int) -> float:
	var acc: Dictionary = member_accumulators.get(member_id, {})
	if acc.is_empty():
		return 0.0
	# Defensive: an unresolved pending use at departure counts as an interrupt.
	if _pending_uses.has(member_id):
		acc[ACC_N_INTERRUPT] = int(acc[ACC_N_INTERRUPT]) + 1
		_pending_uses.erase(member_id)
	var s_member := compute_s_member(acc)
	_fold_global(s_member)
	member_accumulators.erase(member_id)
	return s_member


## --- Pure formulas (public — the story-001 QA cases test these) ---

## Core Rule 3 / TR-SAT-003: the per-use net signal. w_zone = w_cong = 0.5
## keeps a perfect use (+0.5) and a worst use (-0.5) equal and opposite
## (AC9 — neither pull nor push dominates). total_i is clamped to [0, Z_NORM]
## and congestion to [0,1] defensively, so the output is ALWAYS in
## [-0.5, +0.5] (AC8).
func compute_use_quality(total_i: float, congestion_t_minus_1: float) -> float:
	var z := clampf(total_i / _z_norm, 0.0, 1.0)
	var c := clampf(congestion_t_minus_1, 0.0, 1.0)
	return clampf(_w_zone * z - _w_cong * c, -0.5, 0.5)


## Core Rule 4 / TR-SAT-004: S_member from an accumulator. avg(use_quality)
## is 0 when n_uses = 0 (no divide-by-zero, no NaN — AC10); a blank visit
## with no penalties lands exactly at S_base. Each penalty term is
## individually capped so event noise never drowns the spatial signal.
## Story-002 owns the dedicated penalty-cap tests (AC11/12).
func compute_s_member(acc: Dictionary) -> float:
	var avg := 0.0
	var n_uses := int(acc.get(ACC_N_USES, 0))
	if n_uses > 0:
		avg = float(acc.get(ACC_S_ACC, 0.0)) / float(n_uses)
	var qp := _queue_penalty(int(acc.get(ACC_QUEUE_TICKS, 0)))
	var fp := _fail_penalty(int(acc.get(ACC_N_FAIL, 0)))
	var ip := _interrupt_penalty(int(acc.get(ACC_N_INTERRUPT, 0)))
	var s := _s_base + avg - qp - fp - ip
	# Defensive AC10: never emit NaN/Inf even if an upstream value is corrupt.
	if is_nan(s) or is_inf(s):
		s = 0.0
	return clampf(s, 0.0, 1.0)


## queue_penalty = w_queue * clamp(queue_ticks_total / queue_norm_ticks, 0, 1)
## -> [0, 0.3] (capped by construction).
func _queue_penalty(queue_ticks_total: int) -> float:
	return _w_queue * clampf(float(queue_ticks_total) / float(_queue_norm_ticks), 0.0, 1.0)


## fail_penalty = min(w_fail * n_fail, cap_fail) -> [0, 0.30] (AC12).
func _fail_penalty(n_fail: int) -> float:
	return minf(_w_fail * float(n_fail), _cap_fail)


## interrupt_penalty = min(w_interrupt * n_interrupt, cap_interrupt) -> [0, 0.20] (AC12).
func _interrupt_penalty(n_interrupt: int) -> float:
	return minf(_w_interrupt * float(n_interrupt), _cap_interrupt)


## Core Rule 5: fold one departing member's S_member into the slow global
## EMA. Clamped to [0,1] (AC8 — the meter never leaves bounds).
func _fold_global(s_member: float) -> void:
	global_satisfaction = clampf(
		_alpha_g * s_member + (1.0 - _alpha_g) * global_satisfaction,
		0.0, 1.0
	)


## --- Core Rule 6 modifiers (story-003 / TR-SAT-006 / TR-SAT-007) ---

## Core Rule 6 / TR-SAT-006: satisfaction_modifier — the arrival-rate
## multiplier that fulfills MemberSim's OQ3 placeholder. Piecewise-linear:
##   G_c < 0.5:  G_c + 0.5
##   G_c >= 0.5: 2 * G_c
## so G = 0.5 -> exactly 1.0 (seamless with MemberSim's placeholder — AC3)
## and the range is [0.5, 2.0] (AC2) with a STRUCTURAL floor of 0.5 at G = 0
## (never 0 — the anti-death-spiral mechanism, not an afterthought clamp).
## Input is defensively clamped to [0,1] first (AC16); non-finite inputs
## (NaN/Inf, e.g. an upstream bug) fall back to the neutral anchor 0.5 so
## the modifier can never crash or emit NaN.
func satisfaction_modifier(g: float) -> float:
	var g_c := _clamp_modifier_input(g)
	if g_c < 0.5:
		return g_c + 0.5
	return 2.0 * g_c


## Core Rule 6 / TR-SAT-007: visit_length_modifier — the DAMPED leg driving
## MemberSim's exercises_per_visit. Deviation from 1.0 is exactly half of
## satisfaction_modifier's (damp = 0.5), so range is [0.75, 1.5] (AC4).
## Damping prevents ~modifier² occupancy oscillation (arrivals AND visit
## length would otherwise both scale with the full modifier). Defensive
## clamp is inherited from satisfaction_modifier (AC16).
func visit_length_modifier(g: float) -> float:
	return 1.0 + (satisfaction_modifier(g) - 1.0) * _damp


## AC16: defensive input clamp — G outside [0,1] (upstream bug) is clamped
## before the piecewise formula; non-finite (NaN/±Inf) maps to the neutral
## anchor (0.5) so the anti-spiral guarantee (modifier >= 0.5) still holds.
func _clamp_modifier_input(g: float) -> float:
	if is_nan(g) or is_inf(g):
		return S_BASE
	return clampf(g, 0.0, 1.0)


## --- Read surfaces (tests / story 004) ---

## Returns the live accumulator for [member_id], or {} when not tracked.
func get_accumulator(member_id: int) -> Dictionary:
	return member_accumulators.get(member_id, {})


## Returns the pending-use record for [member_id] ({instance_id, congestion})
## or {} when the member is not mid-use. Observable for tests/debugging.
func get_pending_use(member_id: int) -> Dictionary:
	return _pending_uses.get(member_id, {})


## --- Internals ---

## Fresh zeroed accumulator (TR-SAT-002 exact key set).
func _new_accumulator() -> Dictionary:
	return {
		ACC_S_ACC: 0.0,
		ACC_N_USES: 0,
		ACC_QUEUE_TICKS: 0,
		ACC_N_FAIL: 0,
		ACC_N_INTERRUPT: 0,
	}


## Reads Congestion_i(t-1) from the injected reader (defensively clamped to
## [0,1]). 0.0 when the reader is absent (pre-wiring) or the instance is
## unknown (idle — the neutral starting value).
func _read_congestion(instance_id: int) -> float:
	if _congestion_reader == null:
		return 0.0
	return clampf(float(_congestion_reader.per_equipment_congestion(instance_id)), 0.0, 1.0)


## Reads total_i for [instance_id] through the injected ZoneRules reader
## Callable. 0.0 when the seam is absent (pre-wiring) or the instance is
## unknown (ZoneRules returns no row for a missing instance).
func _read_zone_total(instance_id: int) -> float:
	if not _zone_total_reader.is_valid():
		return 0.0
	return float(_zone_total_reader.call(instance_id))


## Returns the full observable state as a JSON-safe Dictionary:
##   { counter: int, global_satisfaction: float, member_accumulators: Dict,
##     rng_state: "0x…" }
## Pure read — no draws, no mutation (SL-001 AC1 counts serialize calls, so
## serialize stays side-effect free). Story-004 (TR-SAT-009 / Core Rule 8)
## added the real state: the reputation meter float + the per-member
## accumulator dict ({S_acc, n_uses, queue_ticks, n_fail, n_interrupt} —
## TR-SAT-002 exact key set). The stub-era keys {counter, rng_state} are
## KEPT alongside (MemberSim precedent): the save-load integration tests'
## byte-identical contract round-trips whatever serialize() emits, and
## keeping the keys means the stub-era blobs stay structurally compatible.
## The transient bookkeeping (_pending_uses, _last_seen) is deliberately
## NOT serialized — it is re-derived from the loaded MemberSim roster at
## commit (Core Rule 8 serialized set is exactly global_satisfaction +
## member_accumulators; the reservation-map-rebuild precedent, TR-MS-007).
## member_accumulators is deep-duplicated so the caller can never mutate
## live state through the returned dict.
func serialize() -> Dictionary:
	if not _assert_initialized():
		return {}
	return {
		"counter": counter,
		"global_satisfaction": global_satisfaction,
		"member_accumulators": member_accumulators.duplicate(true),
		"rng_state": SeededRNG.int64_to_hex(_seeded_rng.get_rng(system_name()).state),
	}


## Two-phase deserialize (TR-SL-005, ADR-0002).
## Phase A validates EVERYTHING with zero mutation; Phase B commits only if
## Phase A passed. Failures are returned, never push_error'd (corrupt save =
## normal outcome). [validate_only] runs Phase A and returns the verdict
## without committing (SaveLoad Phase A protocol).
## Required fields (hard failure, no invented defaults):
##   counter (int|float), rng_state ("0x" hex string),
##   global_satisfaction (float in [0,1] — Core Rule 8 / TR-SAT-009),
##   member_accumulators (Dictionary: member_id -> accumulator with the
##   TR-SAT-002 exact key set). A stub-era blob missing the two new fields
##   FAILS — the meter/accumulators cannot be restored without them.
## Phase B additionally rebuilds the transient per-member bookkeeping
## (_pending_uses + _last_seen) from the already-loaded MemberSim roster
## (SaveLoad load order puts MemberSim before Satisfaction) — see
## _rebuild_transient_state().
func deserialize(data: Dictionary, validate_only: bool = false) -> StubDeserializeResult:
	var result := StubDeserializeResult.new()
	if not _assert_initialized():
		return StubDeserializeResult.fail("Satisfaction.deserialize(): called before init()")

	# --- Phase A: validate (zero mutation) ---
	# counter may be int or float: JSON.parse returns integer literals as
	# float in 4.7.1 (verified — MemberSim's _is_numeric precedent).
	if not data.has("counter") or not _is_numeric(data["counter"]):
		result.errors.append("Satisfaction: missing or invalid 'counter'")
	if not data.has("rng_state") or not data["rng_state"] is String:
		result.errors.append("Satisfaction: missing or invalid 'rng_state'")
	elif not str(data["rng_state"]).begins_with("0x") or not str(data["rng_state"]).is_valid_hex_number(true):
		result.errors.append("Satisfaction: rng_state must be a 0x hex string")

	# global_satisfaction — required, numeric, finite, in [0,1] (Core Rule 5
	# output range; a corrupt out-of-range meter would silently skew the
	# modifier, so it fails loudly instead).
	if not data.has("global_satisfaction") or not _is_numeric(data["global_satisfaction"]):
		result.errors.append("Satisfaction: missing or invalid 'global_satisfaction'")
	else:
		var g := float(data["global_satisfaction"])
		if is_nan(g) or is_inf(g) or g < 0.0 or g > 1.0:
			result.errors.append("Satisfaction: 'global_satisfaction' must be a finite number in [0,1] (got %s)" % str(g))

	# member_accumulators — Dictionary keyed by member_id, each value an
	# accumulator with the TR-SAT-002 exact key set (collects ALL errors).
	if not data.has("member_accumulators") or not (data["member_accumulators"] is Dictionary):
		result.errors.append("Satisfaction: missing or invalid 'member_accumulators'")
	else:
		_validate_accumulators(data["member_accumulators"], result)

	if not result.errors.is_empty():
		return result  # Phase A failed — NOTHING was mutated

	result.ok = true
	if validate_only:
		return result  # validated, NOT committed (SaveLoad Phase A)

	# --- Phase B: commit (only if all valid) ---
	counter = int(data["counter"])
	_seeded_rng.get_rng(system_name()).state = SeededRNG.hex_to_int64(str(data["rng_state"]))
	global_satisfaction = float(data["global_satisfaction"])
	member_accumulators = _normalize_accumulators(data["member_accumulators"])
	_rebuild_transient_state()
	return result


## Phase A: validates the member_accumulators payload with zero mutation.
## Every key must coerce to an int member_id (int / integral float /
## numeric string — JSON.stringify stringifies Dictionary keys), every
## value must be a Dictionary carrying the TR-SAT-002 exact key set with
## numeric fields, and S_acc must be finite. Collects ALL problems — the
## caller sees every violation, not the first one (TR-SL-004).
func _validate_accumulators(accumulators: Dictionary, result: StubDeserializeResult) -> void:
	var expected := [
		ACC_S_ACC, ACC_N_USES, ACC_QUEUE_TICKS, ACC_N_FAIL, ACC_N_INTERRUPT,
	]
	for raw_key in accumulators:
		var member_id := _coerce_member_key(raw_key)
		if member_id < 0:
			result.errors.append("Satisfaction: invalid member key '%s' in member_accumulators" % str(raw_key))
			continue
		var acc: Variant = accumulators[raw_key]
		if not (acc is Dictionary):
			result.errors.append("Satisfaction: accumulator for member %d is not a Dictionary" % member_id)
			continue
		for field in expected:
			if not (acc as Dictionary).has(field) or not _is_numeric((acc as Dictionary)[field]):
				result.errors.append("Satisfaction: accumulator for member %d missing/invalid '%s'" % [member_id, field])
		var s_acc: Variant = (acc as Dictionary).get(ACC_S_ACC, null)
		if s_acc != null and _is_numeric(s_acc):
			var s_acc_f := float(s_acc)
			if is_nan(s_acc_f) or is_inf(s_acc_f):
				result.errors.append("Satisfaction: accumulator for member %d has non-finite S_acc" % member_id)


## Phase B: rebuilds member_accumulators from the validated payload with
## JSON-safe coercion — keys back to int member_id (JSON stringifies dict
## keys), int counters back to int (JSON.parse returns floats for integer
## literals in 4.7.1), S_acc back to float. The output carries exactly the
## TR-SAT-002 key set; unknown extra keys in the payload are dropped (the
## shape IS the contract — a future field is a schema change, not a silent
## pass-through).
func _normalize_accumulators(accumulators: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for raw_key in accumulators:
		var member_id := _coerce_member_key(raw_key)
		if member_id < 0:
			continue  # Phase A already rejected — unreachable in commit mode
		var acc: Dictionary = accumulators[raw_key]
		out[member_id] = {
			ACC_S_ACC: float(acc.get(ACC_S_ACC, 0.0)),
			ACC_N_USES: int(acc.get(ACC_N_USES, 0)),
			ACC_QUEUE_TICKS: int(acc.get(ACC_QUEUE_TICKS, 0)),
			ACC_N_FAIL: int(acc.get(ACC_N_FAIL, 0)),
			ACC_N_INTERRUPT: int(acc.get(ACC_N_INTERRUPT, 0)),
		}
	return out


## Coerces a member_accumulators key to an int member_id. Accepts int,
## integral float (JSON.parse floats), and numeric strings ("5" —
## JSON.stringify stringifies object keys). Returns -1 for anything else.
func _coerce_member_key(key: Variant) -> int:
	if typeof(key) == TYPE_INT:
		return int(key)
	if typeof(key) == TYPE_FLOAT and is_equal_approx(float(key), round(float(key))):
		return int(key)
	if typeof(key) == TYPE_STRING and str(key).is_valid_int():
		return int(str(key))
	return -1


## True when [v] is int or float — the numeric types a save payload may
## carry (JSON.parse returns floats for integer literals in 4.7.1).
func _is_numeric(v: Variant) -> bool:
	return typeof(v) == TYPE_INT or typeof(v) == TYPE_FLOAT


## Phase B load-side rebuild of the transient per-member bookkeeping (Core
## Rule 8: the serialized set is exactly global_satisfaction +
## member_accumulators; _pending_uses + _last_seen are DERIVED state,
## mirroring MemberSim's reservation-map rebuild precedent — never
## serialized as separate truth). Called only after commit, and only when
## the member_sim read surface is wired (pre-wiring rigs have nothing to
## observe — skip).
##
##   _last_seen[member_id].exercises_done = the loaded roster's current
##     count — prevents a FALSE use-completion on the first tick after
##     load (the member's completed uses already live in S_acc/n_uses).
##   _pending_uses[member_id] = {instance_id, congestion} for every member
##     still USING with a real target — the single Congestion_i(t-1)
##     snapshot is RE-taken at the load boundary (the "read t-1 at
##     use-start" rule applied at reload). This preserves the AC15
##     bit-identity contract under a stable congestion t-1 (the QA
##     scenario), AND keeps the departure-defensive interrupt correct: a
##     member still USING at load who departs next tick must count the
##     interrupt, exactly as uninterrupted play would.
func _rebuild_transient_state() -> void:
	_last_seen.clear()
	_pending_uses.clear()
	if _member_sim == null:
		return
	for m in _member_sim.members:
		if not (m is Dictionary) or not m.has("member_id") or not m.has("state"):
			continue  # legacy state-less roster entries are exempt (on_tick mirror)
		var member_id := int(m["member_id"])
		_last_seen[member_id] = {
			"exercises_done": int(m.get("exercises_done", 0)),
		}
		var state := str(m["state"])
		var target := int(m.get("target_equipment_instance_id", -1))
		if state == "USING" and target >= 0:
			_pending_uses[member_id] = {
				"instance_id": target,
				"congestion": _read_congestion(target),
			}
