## TimeSystem — deterministic tick accumulator, speed control, and pause.
##
## Story: time-system / story-002-tick-accumulator-speed-pause.md
## Req:   TR-TS-001 (custom fixed-timestep accumulator, TICK_DURATION_SECONDS = 0.1),
##        TR-TS-002 (MAX_TICKS_PER_FRAME = 8 clamp, speed in {0,1,2,3}, pause freezes
##                   accumulator entirely), TR-TS-012 (72,000-tick drift < 1e-6)
## ADR:   ADR-0001 (DI Container & Scene Bootstrap)
##
## The deterministic clock backbone. Each engine frame, the SimulationOrchestrator
## forwards its _process(delta) here; process() accumulates `delta * speed_multiplier`
## wall-seconds into tick_accumulator and fires whole ticks at TICK_DURATION_SECONDS
## (0.1s, 10 Hz) intervals by calling back _orchestrator._advance_tick() per tick.
## Tick timing is fully independent of Godot's _physics_process and of Timer nodes.
##
## CLASS HIERARCHY — DEVIATION FROM STORY SKETCH (documented, not silent):
## The Story 002 sketch shows `class_name TimeSystem extends RefCounted`, but
## ADR-0001 (the governing implementation ADR this story cites) mandates the
## SimSystem two-phase init pattern (_mark_initialized/_assert_initialized/
## system_name) for every one of the 12 simulation systems — same precedent
## already documented in GridStateReader's header. So TimeSystem extends SimSystem.
##
## TICK COUNT OWNERSHIP — DEVIATION FROM STORY SKETCH (documented, not silent):
## The sketch shows a private `tick_count` field on TimeSystem. Story 001 locked
## tick_count ownership on SimulationOrchestrator (_advance_tick() increments it,
## tick_completed emits it — GDD Core Rule 4; verified by TS-001 AC5/AC19 tests).
## Having two counters would risk divergence. TimeSystem therefore exposes
## get_tick_count() as a DELEGATE to _orchestrator.get_tick_count() — one source
## of truth, GDD-compatible public surface (HUD/Economy read TimeSystem's getter).
## serialize() reads through the same delegate; deserialize() Phase B restores
## the counter via _orchestrator._restore_tick_count() (the orchestrator's
## Story-004 write path).
##
## SERIALIZATION (Story TS-004) — seeded RNG injection:
## The sketch shows `_seeded_rng` as a field. init() takes it as a SECOND
## parameter (default null) so Story 001/002's `time_system.init(self)` call
## sites keep working while the SaveLoad epic supplies the real wiring later.
## With null, serialize() push_errors and returns {} (guard-contract safe
## default), and deserialize() fails loudly — no RNG state can be restored
## without a SeededRNG, and inventing one would break the determinism contract.
## Tests wire the full assembly explicitly (orchestrator + SeededRNG + systems).
##
## PAUSE SEMANTICS (Control Manifest — Foundation layer):
## - pause is an EARLY RETURN before the `+=` — never "add zero". Repeated no-op
##   accumulation would creep float error across long paused sessions (AC14).
## - _last_speed records speed selections made WHILE paused; resume() uses the
##   last-selected speed (> 0), defaulting to 1x if 0 or never chosen (AC18).
## - set_speed(0) while running is equivalent to pause() (TR-TS-002: 0 = paused).
##   NOTE: per the story sketch, _last_speed is assigned BEFORE the pause check,
##   so set_speed(0) while running leaves _last_speed == 0; a later resume()
##   therefore returns to 1x, not the pre-pause speed. That exact behavior is
##   what the sketch specifies; QA edge cases only pin "set_speed(0) while paused
##   stays paused".
##
## MAX_TICKS_PER_FRAME = 8 catch-up clamp: after a frame hitch, at most 8 ticks
## fire this frame; leftover time carries forward in tick_accumulator and drains
## over subsequent frames. No tick is skipped, merged, or reordered — the tick
## sequence (and thus replay determinism, GDD Core Rule 8) is frame-rate
## independent (AC12).
##
## RELEASE-MODE CAVEAT: set_speed() validates via assert() exactly as the story
## sketch specifies. assert() is stripped in release builds, so an invalid speed
## would pass through unvalidated there — acceptable for MVP (HUD only ever
## offers SPEED_OPTIONS values); revisit if untrusted callers appear.
class_name TimeSystem extends SimSystem

## Sim ticks per real second at 1x speed (locked — GDD tick_duration_formula).
const TICKS_PER_SECOND := 10

## Wall-seconds represented by one tick. `1.0 / 10` is exactly 0.1 in IEEE754
## double (verified), satisfying AC11's exact equality check. Never runtime-mutable.
const TICK_DURATION_SECONDS := 1.0 / TICKS_PER_SECOND  # 0.1

## Safety clamp on ticks fired per process() call (GDD speed_to_realtime_formula).
const MAX_TICKS_PER_FRAME := 8

## Available speed multipliers; 0 = paused (TR-TS-002).
const SPEED_OPTIONS: Array = [0, 1, 2, 3]

## Seconds of accumulated sim-time not yet consumed by a whole tick.
## Leftover time is NEVER discarded — it carries forward to the next frame.
var tick_accumulator: float = 0.0

## Player-selected sim speed. 0 while paused (kept in sync by pause()/resume()).
var speed_multiplier: int = 1

## True = accumulator frozen entirely (early return in process(), no accumulation).
var paused: bool = true  # always start paused (GDD Core Rule 9, story sketch)

## Last speed selection (recorded even while paused) — resume() uses this.
var _last_speed: int = 1

## Injected composition root. process() calls back _advance_tick() per tick.
## Story-001 established the orchestrator as the tick-count owner; TimeSystem
## delegates get_tick_count() to it (see class header).
var _orchestrator: SimulationOrchestrator

## Injected SeededRNG registry (Story TS-004). Null until wired — see class
## header "SERIALIZATION — seeded RNG injection" for the null semantics.
var _seeded_rng: SeededRNG


## Two-phase init (ADR-0001). Injects the orchestrator back-reference used to
## fire ticks, plus the SeededRNG registry serialize()/deserialize() delegate
## to (Story TS-004; optional with a null default for compatibility with the
## Story 001/002 call site — see class header). Safe to call once; a second
## call pushes an error via SimSystem._mark_initialized() and leaves state
## untouched.
func init(orchestrator: SimulationOrchestrator, seeded_rng: SeededRNG = null) -> void:
	if not _mark_initialized():
		return
	_orchestrator = orchestrator
	_seeded_rng = seeded_rng


func system_name() -> String:
	return "TimeSystem"


## Render-frame driver. Called by SimulationOrchestrator._process(delta) every
## frame. Accumulates `delta * speed_multiplier`, fires up to MAX_TICKS_PER_FRAME
## whole ticks, and carries the remainder forward.
##
## Pause is an early return BEFORE the `+=` — not "add zero" — so paused frames
## contribute no float-precision creep (AC3/AC14). No ticks fire while paused,
## which structurally guarantees no on_tick() call and therefore no RNG draw
## (AC3's RNG clause becomes directly assertable in Story 003 when SeededRNG
## lands; the observable proxy here is tick_completed staying silent).
func process(delta: float) -> void:
	if not _assert_initialized():
		return
	if paused or speed_multiplier == 0:
		return  # early return — no accumulation, no float drift
	tick_accumulator += delta * speed_multiplier
	var ticks_to_fire := mini(floori(tick_accumulator / TICK_DURATION_SECONDS), MAX_TICKS_PER_FRAME)
	tick_accumulator -= ticks_to_fire * TICK_DURATION_SECONDS
	for _i in ticks_to_fire:
		_orchestrator._advance_tick()


## Sets the sim speed. Only SPEED_OPTIONS values are valid (assert, per story
## sketch). Never resets tick_accumulator and never touches tick_count (AC4).
## While paused, records the selection as _last_speed but has no effect until
## resume() (GDD speed state machine: PAUSED + pick speed -> stays PAUSED).
func set_speed(speed: int) -> void:
	if not _assert_initialized():
		return
	assert(speed in SPEED_OPTIONS, "Invalid speed: %d" % speed)
	_last_speed = speed
	if not paused and speed == 0:
		pause()
	elif not paused:
		speed_multiplier = speed


## Freezes the accumulator at its current value. Preserves _last_speed so a
## later resume() restores the pre-pause speed selection (GDD state machine).
func pause() -> void:
	if not _assert_initialized():
		return
	paused = true
	speed_multiplier = 0


## Unfreezes and resumes at the last-selected speed (> 0), defaulting to 1x
## when the last selection was 0 or never made (AC18, story QA edge case).
func resume() -> void:
	if not _assert_initialized():
		return
	paused = false
	speed_multiplier = _last_speed if _last_speed > 0 else 1


func is_paused() -> bool:
	if not _assert_initialized():
		return true  # safe default: treat uninitialized as paused (no ticks)
	return paused


## Returns the current speed multiplier (0 = paused) — HUD/GDD public surface.
func get_speed_multiplier() -> int:
	if not _assert_initialized():
		return 0
	return speed_multiplier


## Current abstract tick counter — DELEGATES to the orchestrator (Story 001 owns
## the counter; see class header). 0 before the first tick.
func get_tick_count() -> int:
	if not _assert_initialized():
		return 0
	return _orchestrator.get_tick_count()


## Composite return value for TimeSystem.deserialize(). Carries the verdict
## and every collected validation error (Phase A failures do not short-circuit
## — the caller sees all problems at once). Plain data-transfer object.
class TimeSystemDeserializeResult extends RefCounted:
	var ok: bool = false
	var errors: Array[String] = []

	func add_error(msg: String) -> void:
		errors.append(msg)


## Returns the full serializable time-system state (GDD Core Rule 7):
##   { tick_count, tick_accumulator, speed_multiplier, paused, _last_speed,
##     master_seed: "0x…", per_system_rng_states: { name: "0x…", … } }
## Pure read — no side effects. Int64 values (master_seed, RNG states) are
## hex strings per ADR-0002; tick_count/accumulator/speed are native JSON-safe
## numbers (tick_count is a plain counter, never a 64-bit bit pattern).
## Delegates RNG serialization to SeededRNG.serialize().
## Guard: with no wired SeededRNG, push_error + {} (see class header).
func serialize() -> Dictionary:
	if not _assert_initialized():
		return {}
	if _seeded_rng == null:
		push_error("TimeSystem.serialize(): seeded_rng not wired — call init(orchestrator, seeded_rng)")
		return {}
	var rng_data: Dictionary = _seeded_rng.serialize()
	return {
		"tick_count": get_tick_count(),
		"tick_accumulator": tick_accumulator,
		"speed_multiplier": speed_multiplier,
		"paused": paused,
		"_last_speed": _last_speed,
		"master_seed": rng_data["master_seed"],
		"per_system_rng_states": rng_data["per_system_rng_states"],
	}


## Two-phase deserialize: Phase A validates EVERYTHING with zero mutation;
## Phase B commits only if Phase A passed (ADR-0002 / story design note).
## Failures are returned, never push_error'd (corrupt save = normal outcome).
##
## Required fields (hard failure, no invented defaults — AC17):
##   tick_count (int), master_seed (hex string), per_system_rng_states
##   (Dictionary with an entry per registered system — AC16).
## Optional with documented defaults: tick_accumulator (0.0), speed_multiplier
## (1), _last_speed (1).
##
## Core Rule 9 (AC10): load ALWAYS resumes PAUSED. The saved speed_multiplier
## is read into _last_speed first, then paused=true + speed_multiplier=0 are
## forced — the player sees their last speed preserved but the sim frozen.
## RNG state is committed by _seeded_rng.deserialize() (itself two-phase).
func deserialize(data: Dictionary) -> TimeSystemDeserializeResult:
	var result := TimeSystemDeserializeResult.new()
	if not _assert_initialized():
		result.add_error("TimeSystem.deserialize(): called before init()")
		return result
	if _seeded_rng == null:
		result.add_error("TimeSystem.deserialize(): seeded_rng not wired — cannot restore RNG state")
		return result

	# --- Phase A: validate (zero mutation) ---
	# Collect ALL errors (story design note: no short-circuit on first error).
	if not data.has("tick_count") or typeof(data["tick_count"]) != TYPE_INT:
		result.add_error("TimeSystem.deserialize: missing or invalid 'tick_count'")
	if not data.has("master_seed") or not data["master_seed"] is String:
		result.add_error("TimeSystem.deserialize: missing or invalid 'master_seed'")
	if not data.has("per_system_rng_states") or not data["per_system_rng_states"] is Dictionary:
		result.add_error("TimeSystem.deserialize: missing or invalid 'per_system_rng_states'")

	# Delegate RNG validation to SeededRNG (still Phase A — no mutation at
	# TimeSystem level; SeededRNG.deserialize is itself two-phase, so a
	# failure there commits nothing).
	#
	# CRITICAL: only delegate when TimeSystem's OWN Phase A passed. The RNG
	# data may be perfectly valid even when e.g. tick_count is missing — if
	# we delegated regardless, SeededRNG's Phase B would COMMIT RNG state
	# during a load that is about to fail, violating the two-phase contract
	# ("nothing mutated on any failed load" — QA AC16/17). Guarding the
	# delegation on zero local errors preserves all-or-nothing atomicity.
	if result.errors.is_empty():
		var rng_result: Variant = _seeded_rng.deserialize({
			"master_seed": data.get("master_seed", ""),
			"per_system_rng_states": data.get("per_system_rng_states", {}),
		})
		if not rng_result.ok:
			for err in rng_result.errors:
				result.add_error(err)

	if not result.errors.is_empty():
		return result  # Phase A failed — NOTHING was mutated

	# --- Phase B: commit (only if all valid) ---
	_orchestrator._restore_tick_count(int(data["tick_count"]))
	tick_accumulator = float(data.get("tick_accumulator", 0.0))
	_last_speed = int(data.get("_last_speed", int(data.get("speed_multiplier", 1))))

	# Core Rule 9: load always resumes PAUSED regardless of saved paused/speed
	paused = true
	speed_multiplier = 0

	result.ok = true
	return result
