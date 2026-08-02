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


## Two-phase init (ADR-0001). Injects the orchestrator back-reference used to
## fire ticks. Safe to call once; a second call pushes an error via
## SimSystem._mark_initialized() and leaves state untouched.
func init(orchestrator: SimulationOrchestrator) -> void:
	if not _mark_initialized():
		return
	_orchestrator = orchestrator


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
