# Story 002: Tick Accumulator, Speed Control, and Pause

> **Epic**: time-system
> **Status**: Ready
> **Layer**: Foundation
> **Type**: Logic
> **Estimate**: [hours or t-shirt size — fill before sprint planning]
> **Manifest Version**: 2026-07-23
> **Last Updated**: [set by /dev-story when implementation begins]

## Context

**GDD**: `design/gdd/time-system.md`
**Requirements**: `TR-TS-001`, `TR-TS-002`, `TR-TS-012`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0001: DI Container & Scene Bootstrap
**ADR Decision Summary**: Custom fixed-timestep accumulator independent of _physics_process. TICK_DURATION_SECONDS = 0.1 (10 Hz). MAX_TICKS_PER_FRAME = 8 safety clamp. Speed in {0, 1, 2, 3}. Pause freezes accumulator entirely (early return before +=, not "add zero"). Float drift checked at 72,000 ticks (< 1e-6s tolerance). Tick loop uses _process(delta) accumulator, not a Timer node.

**Engine**: Godot 4.7.1 | **Risk**: LOW
**Engine Notes**: _process(delta) vs _physics_process: using _process avoids coupling to physics tick rate. Float precision: IEEE754 double has 53 bits of mantissa — 0.1 is not exactly representable but repeated subtraction is stable at this tick count per formula analysis. Timer node explicitly NOT used — direct _process gives full control over accumulator behavior.

**Control Manifest Rules (Foundation layer)**:
- Required: TICK_DURATION_SECONDS as const 0.1 (never runtime-mutable); accumulator early-return on pause (not "add zero")
- Forbidden: Never use Timer node or _physics_process for tick timing; never discard leftover accumulator time
- Guardrail: MAX_TICKS_PER_FRAME = 8; float drift < 1e-6 after 72,000 ticks

---

## Acceptance Criteria

*From GDD `design/gdd/time-system.md`, scoped to this story:*

- [ ] AC1 [BLOCKING][Logic] GIVEN speed=1, tick_accumulator=0, WHEN one _process(delta=0.1) call occurs, THEN exactly 1 tick fires and tick_accumulator returns to ~0
- [ ] AC2 [BLOCKING][Logic] GIVEN speed=1, WHEN a single frame delivers delta=0.25s, THEN exactly 2 ticks fire and tick_accumulator ≈ 0.05s afterward (proves carry-forward, not truncation)
- [ ] AC3 [BLOCKING][Logic] GIVEN speed_multiplier=0, WHEN _process runs repeatedly across a simulated 10s span, THEN tick_count and every per-system RNG state are byte-identical before and after
- [ ] AC4 [BLOCKING][Logic] GIVEN tick_accumulator=0.07s and tick_count=42 at speed=1, WHEN speed_multiplier is set to 3 with no frame processed yet, THEN tick_accumulator stays 0.07s and tick_count stays 42 immediately after the change
- [ ] AC11 [BLOCKING][Logic] GIVEN TICKS_PER_SECOND=10, WHEN TICK_DURATION_SECONDS is read, THEN it equals exactly 0.1
- [ ] AC12 [BLOCKING][Logic] GIVEN speed=2, tick_accumulator=0, WHEN delta=10.0s (hitch), THEN exactly 8 ticks fire (MAX_TICKS_PER_FRAME clamp) and remaining accumulator ≈ 19.2s afterward — NOT discarded
- [ ] AC14 [BLOCKING][Logic] GIVEN speed_multiplier=0, WHEN _process(delta=5.0) runs for 1000 consecutive frames, THEN tick_accumulator remains exactly 0.0 (proves early-return path, not "accumulate-then-never-fire")
- [ ] AC18 [BLOCKING][Logic] GIVEN paused=true and speed changed from 1x to 3x while paused, WHEN resume is triggered, THEN ticks proceed at 3x (the last-selected speed), not the pre-pause speed
- [ ] AC20 [BLOCKING][Logic] GIVEN a fresh 1x-speed run, WHEN 72,000 ticks are simulated (soak test, ~120 real minutes), THEN tick_accumulator drift stays within < 1e-6s of expected value at every tick boundary

---

## Implementation Notes

*Derived from ADR-0001 + GDD Core Rules 1-3 + Formulas:*

**Tick accumulator implementation:**
```gdscript
class_name TimeSystem extends RefCounted

const TICKS_PER_SECOND := 10
const TICK_DURATION_SECONDS := 1.0 / TICKS_PER_SECOND  # 0.1
const MAX_TICKS_PER_FRAME := 8
const SPEED_OPTIONS := [0, 1, 2, 3]  # 0 = paused

var tick_count: int = 0
var tick_accumulator: float = 0.0
var speed_multiplier: int = 1
var paused: bool = true  # always start paused
var _last_speed: int = 1

var _orchestrator: SimulationOrchestrator  # injected — calls back to advance_tick

func process(delta: float) -> void:
    if paused or speed_multiplier == 0:
        return  # early return — no accumulation, no float drift
    
    tick_accumulator += delta * speed_multiplier
    
    # Clamp: fire at most MAX_TICKS_PER_FRAME ticks per frame
    var ticks_to_fire := mini(floori(tick_accumulator / TICK_DURATION_SECONDS), MAX_TICKS_PER_FRAME)
    tick_accumulator -= ticks_to_fire * TICK_DURATION_SECONDS
    
    for _i in range(ticks_to_fire):
        _orchestrator._advance_tick()  # calls back to Orchestrator

func set_speed(speed: int) -> void:
    assert(speed in SPEED_OPTIONS, "Invalid speed: %d" % speed)
    _last_speed = speed
    if not paused and speed == 0:
        pause()
    elif not paused:
        speed_multiplier = speed

func pause() -> void:
    paused = true
    speed_multiplier = 0

func resume() -> void:
    paused = false
    speed_multiplier = _last_speed if _last_speed > 0 else 1

func is_paused() -> bool:
    return paused

func get_tick_count() -> int:
    return tick_count
```

**Speed state machine (from GDD):**
| From | Event | To |
|------|-------|-----|
| RUNNING(speed) | player presses pause | PAUSED |
| PAUSED | player presses resume | RUNNING(last_speed) |
| PAUSED | player picks a speed | PAUSED (records as last_speed) |
| RUNNING(speed) | player changes speed | RUNNING(new_speed) |
| any | save loaded | PAUSED |

**Float drift analysis:**
- 0.1 is NOT exactly representable in IEEE754 double (it's 0.0001100110011... in binary)
- But repeated subtraction pattern `accumulator -= n * 0.1` is stable: the subtraction is exact for multiples of 0.1 within double precision at this magnitude
- 72,000 ticks = 7,200 seconds sim-time = ~120 real minutes at 1x
- Expected drift: < 1e-6 seconds (well within tolerance — ~4 orders of magnitude below perceptible)

**Key design decisions:**
- Early return on pause (not "add zero") — prevents float-precision creep from repeated no-op accumulation
- tick_accumulator carry-forward: leftover time after subtraction stays in accumulator for next frame (never discarded)
- MAX_TICKS_PER_FRAME clamp: fires at most 8 ticks, carries remainder forward — preserves tick sequence, spreads catch-up
- _last_speed records speed selection even while paused — AC18 verifies

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 001]: Orchestrator container and _advance_tick() — this story's process() calls back to it
- [Story 003]: SeededRNG — RNG state is part of tick state but not mutated by the accumulator
- [Story 004]: Serialization — tick_count and accumulator state are serialized there
- [HUD #16]: Speed/pause UI controls — TimeSystem exposes getters; UI implementation is separate

---

## QA Test Cases

*Sourced from `production/qa/qa-plan-sprint-2-2026-08-02.md` — Automated Tests Required (TS-002). Authoritative test file: `tests/unit/time_system/tick_accumulator_test.gd` (~30 assertions).*

**What to test**:
- TICK_DURATION_SECONDS = 0.1 固定步进（accumulator 累积→扣减循环）
- MAX_TICKS_PER_FRAME = 8 catch-up 上限
- speed 1x/2x/3x 切换不重置 accumulator、不触碰 tick_count
- pause（speed_multiplier=0）冻结全部状态；pause/resume 不推进 tick_count
- 同 seed + 同 tick 序列 → replay 位一致（确定性与帧率无关）

**Edge cases**: delta=0、超大 delta（单帧 catch-up 上限）、speed 切换恰在 tick 边界

**Estimated assertions**: ~30

- **AC1**: 单次 0.1s delta → 1 tick
  - Given: speed=1, accumulator=0, tick_count=0
  - When: process(0.1)
  - Then: tick_count=1, accumulator ≈ 0.0 (within epsilon)
  - Edge cases: test with delta exactly 0.099999 (floating point — should NOT fire)

- **AC2**: delta=0.25s → 2 ticks, 0.05s 剩余
  - Given: speed=1, accumulator=0
  - When: process(0.25)
  - Then: 2 ticks fire, accumulator ≈ 0.05
  - Edge cases: test delta=0.199999 → 1 tick; delta=0.200001 → 2 ticks

- **AC3**: pause → 不动
  - Given: speed_multiplier=0
  - When: process() called 100 times with delta=0.1 each
  - Then: tick_count unchanged, RNG state unchanged (byte-identical before/after)
  - Edge cases: test pause from init; test pause after some ticks then resume

- **AC4**: 变速不重置
  - Given: accumulator=0.07, tick_count=42
  - When: set_speed(3), no frame processed
  - Then: accumulator still 0.07, tick_count still 42
  - Edge cases: test speed change from 3→1, 2→3

- **AC11**: TICK_DURATION_SECONDS = 0.1
  - Given: TICKS_PER_SECOND=10
  - When: const is read
  - Then: equals 0.1
  - Edge cases: verify const-ness (cannot be reassigned at runtime)

- **AC12**: hitch → 8 tick clamp
  - Given: speed=2, accumulator=0, delta=10.0s
  - When: process(10.0)
  - Then: accumulator after: 10.0*2 = 20.0 accumulated, 8*0.1 fired = 0.8s consumed, remaining ≈ 19.2s; exactly 8 ticks fired
  - Edge cases: verify accumulator NOT discarded (19.2s carries forward); verify ticks 9-16 fire in next frame

- **AC14**: 暂停早期返回不累积
  - Given: speed_multiplier=0
  - When: process(5.0) called 1000 times
  - Then: accumulator = 0.0 exactly (never accumulated)
  - Edge cases: this is the "early return, not add-zero" path — proves no float drift from paused state

- **AC18**: 暂停时变速 → 恢复后生效
  - Given: paused, last_speed=1
  - When: set_speed(3) while paused, then resume()
  - Then: ticks proceed at speed 3
  - Edge cases: test set_speed(0) while paused (should stay paused); test resume without ever setting speed (last_speed defaults to 1)

- **AC20**: 72,000 tick soak → drift < 1e-6
  - Given: fresh simulation at 1x
  - When: 72,000 ticks simulated (may use fast-forward/test harness, not real-time)
  - Then: at every tick boundary, abs(expected_accumulator - actual_accumulator) < 1e-6
  - Edge cases: this is a regression test — verifies the float-drift "non-issue" doesn't silently become one

---

## Test Evidence

**Story Type**: Logic
**Required evidence**:
- `tests/unit/time_system/tick_accumulator_test.gd` — must exist and pass

**Status**: [ ] Not yet created

---

## Dependencies

- Depends on: Story 001 (Orchestrator container — process() calls back to _advance_tick())
- Unlocks: Story 003 (RNG registration needs tick loop), Story 004 (serialization needs tick_count)
