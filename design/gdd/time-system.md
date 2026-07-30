# TimeSystem + SimulationOrchestrator + SeededRNG

> **Status**: In Design
> **Author**: user + agents
> **Last Updated**: 2026-07-17
> **Implements Pillar**: Foundation — enables Pillar 1 (空间即玩法) and Pillar 2 (松弛不紧绷)
> **Creative Director Review (CD-GDD-ALIGN)**: Skipped — Lean review mode (not a PHASE-GATE at lean).

## Overview

TimeSystem (paired with the SimulationOrchestrator and a central SeededRNG) is the deterministic clock and scheduling backbone the entire simulation runs on. It owns a single abstract tick counter and drives every other simulation system (MemberSim, Congestion, Economy, and eventually Satisfaction) through a fixed, render-decoupled update order each tick, while a seeded RNG instance — whose seed and internal state are fully serializable — supplies all randomness so that saves reproduce identically on load. TimeSystem does not track calendar days or time-of-day; it exposes only tick count and tick rate, and any human-readable "day N" or clock display is derived downstream (e.g. by HUD) from that raw count. The player's only direct touchpoint with this system is pause and simulation-speed control — the tick loop itself is otherwise invisible infrastructure. This system exists because without a single owner of "what tick are we on, in what order do systems run, and where does randomness come from," saves cannot reproduce (Pillar 2's "always safe to stop and reconsider" promise breaks), and downstream systems like Congestion's one-tick-lag feedback loop have no stable notion of "current" vs "previous" state to read from.

## Player Fantasy

TimeSystem itself carries no direct fantasy — players never think about "the tick loop." What they feel is the downstream guarantee it provides: total control over pacing, with zero risk in stopping. Because pause and speed controls are cheap, instant, and always available, the player never feels rushed into a placement decision or punished for taking their time to study a congestion problem — the game's clock is a tool the player wields, not a countdown that threatens them. This directly serves Pillar 2 (松弛不紧绷): the felt safety of "I can always stop, look, and think" only exists because TimeSystem guarantees that pausing/resuming and saving are always safe, deterministic, and lossless. Reference point: Two Point Hospital and Cairo-series management games both let players freeze the world to plan without penalty — TimeSystem is the infrastructure that makes that promise trustworthy rather than just a UI toggle (a fast-forward button players don't trust to save correctly undermines this fantasy).

## Detailed Design

### Core Rules

1. **Tick advancement (custom fixed-timestep accumulator).** TimeSystem owns `tick_accumulator: float` (seconds) and a constant `TICK_DURATION_SECONDS`. Each engine `_process(delta)`: if not paused, `tick_accumulator += delta * speed_multiplier`. While `tick_accumulator >= TICK_DURATION_SECONDS`: subtract `TICK_DURATION_SECONDS` and fire one tick via `_advance_tick()`. This is fully independent of Godot's `_physics_process` internals — sim-time-per-tick is constant; only wall-clock cadence changes with speed, so the tick sequence is identical regardless of framerate.

2. **Pause.** `speed_multiplier = 0` halts accumulation entirely. No ticks fire. `tick_count`, all system state, and RNG state are frozen. Pausing/resuming never advances `tick_count`.

3. **Speed change.** Switching among 1x/2x/3x never resets `tick_accumulator` or touches `tick_count` — it only changes how fast future accumulation happens. Speed changes are safe at any moment, not just tick boundaries, because they never mutate simulation state.

4. **Fixed system call order.** `SimulationOrchestrator._advance_tick()` invokes ticking systems in one hardcoded order, defined here (not left to scene-tree node order or `process_priority` tricks):
   1. MemberSim — reads Congestion(t-1), decides targets/routes, moves members
   2. Congestion — recomputes density/queues from this tick's post-move state (becomes next tick's t-1)
   3. Satisfaction — reads Congestion + ZoneRules + MemberSim state
   4. Economy — reads Satisfaction, applies revenue/costs
   5. Orchestrator increments `tick_count`, then emits `tick_completed(tick_count)`
   This order is a placeholder for step 5 onward — it gets confirmed/refined as each dependent system's own GDD is authored — but the *principle* that one central, textually-visible order exists is locked now.

5. **No mid-tick yielding (this is what makes "tick boundary" free).** No system's `on_tick()` implementation may contain `await` or otherwise yield control mid-tick. Because GDScript is single-threaded, this guarantees `_advance_tick()` always runs to completion synchronously before control returns to the engine loop — which means **every moment external code (like SaveLoad) can run is automatically a tick boundary**. No runtime "is it safe to save" check is needed; it's enforced by this code-discipline rule, not a guard.

6. **RNG sub-streams (registration vs. access are separate operations).** TimeSystem's SeededRNG owns one `master_seed: int64`. Each consuming system calls `register_system(system_name)` **exactly once** during setup; this derives and stores that system's own `RandomNumberGenerator`, seeded via `rng_subseed_derivation_formula` over `(master_seed, system_name)` — never by drawing N values from a shared master stream (that would make every system's randomness order-sensitive to every other system's call count). Registering an already-registered `system_name` is a **hard error** (it signals two systems colliding on one stream — see Edge Cases). After registration, a system fetches its stream via `get_rng(system_name)`, which is **idempotent and repeatable**: it returns the same already-registered generator (carrying its current advanced state) on every call, and never creates or reseeds anything. No system constructs or seeds its own RNG. (The two-method split exists because a single name-keyed accessor cannot both be safe to call repeatedly by the legitimate owner *and* fail on a colliding second registrant — those are distinct operations.)

7. **Serialization contract.** `TimeSystem.serialize()` returns `{tick_count, master_seed, per_system_rng_states: {name: state}, speed_multiplier, paused}`. `deserialize()` restores each RNG sub-stream's exact internal state (not just its derived seed, since state has advanced since derivation).

8. **Determinism contract.** Given the same `master_seed` and the same sequence of ticks, replay is bit-identical. Player pause duration and speed choices are explicitly **not** part of this contract's required inputs — pausing for 5 seconds vs. 5 minutes of real time produces identical subsequent simulation, because `tick_count` and RNG state only advance on actual ticks. This is what makes Pillar 2's "never punished for taking your time" literally true at the systems level, not just a UX promise.

9. **Load always resumes paused.** Loading a save always enters `PAUSED`, regardless of the speed saved. Rationale: gives the player a beat to survey the restored state before the simulation resumes affecting it — consistent with Pillar 2.

### States and Transitions

| From | Event | To | Notes |
|---|---|---|---|
| `RUNNING(speed)` | player presses pause | `PAUSED` | accumulator frozen at current value |
| `PAUSED` | player presses resume | `RUNNING(last_speed)` | accumulator resumes from frozen value, no reset; uses `last_speed` (defaults to 1x if never set) |
| `PAUSED` | player picks a speed | `PAUSED` | records the selection as `last_speed`; **stays paused** until an explicit resume (see Edge Cases and AC18) |
| `RUNNING(speed)` | player changes speed | `RUNNING(new_speed)` | accumulator untouched; only future accumulation rate changes |
| any | save loaded | `PAUSED` | always — see Core Rule 9 |

### Interactions with Other Systems

- **Upstream dependencies**: none — Foundation layer.
- **Downstream consumers** (none have GDDs yet):
  - **MemberSim (#6)**: implements `on_tick(tick_context: TickContext)`, called 1st each tick. `TickContext = {tick_count: int, rng: RandomNumberGenerator}` (its own sub-stream).
  - **Congestion (#7)**: implements `on_tick(...)`, called 2nd. Its own storage — not TimeSystem's — holds the t-1 value MemberSim reads; TimeSystem only guarantees the *ordering* that makes that value stable and available.
  - **Satisfaction (#10)**: implements `on_tick(...)`, called 3rd.
  - **Economy (#11)**: implements `on_tick(...)`, called 4th; may read `TimeSystem.get_tick_count()` for elapsed-time calculations.
  - **HUD (#16)**: does **not** get an `on_tick()` call (presentation runs on render frames, not sim ticks). Instead it polls `get_tick_count()` / `get_speed_multiplier()` / `is_paused()` each render frame and derives any "Day N" display itself — TimeSystem owns no calendar concept (per the earlier decision).
  - **SaveLoad (#14)**: calls `TimeSystem.serialize()/deserialize()`; relies on Core Rule 5 (no mid-tick yielding) to get "always at a tick boundary" for free, without needing a runtime check.

## Formulas

The **tick_duration_formula** formula is defined as:

`TICK_DURATION_SECONDS = 1.0 / TICKS_PER_SECOND`

**Variables:**
| Variable | Symbol | Type | Range | Description |
|----------|--------|------|-------|-------------|
| Ticks per second | TICKS_PER_SECOND | int (const) | 10 (locked) | Sim ticks per real second at 1x speed |
| Tick duration | TICK_DURATION_SECONDS | float (const) | 0.1 (locked) | Wall-seconds represented by one tick |

**Output Range:** Fixed constant, not runtime-variable: `TICK_DURATION_SECONDS = 0.1`.
**Example:** `TICKS_PER_SECOND = 10` → `TICK_DURATION_SECONDS = 0.1s` → one tick fires every 100ms of accumulated sim-time at 1x speed.

---

The **speed_to_realtime_formula** formula is defined as:

`wall_seconds_per_tick(speed) = TICK_DURATION_SECONDS / speed` (speed > 0; no ticks fire when speed = 0)

**Variables:**
| Variable | Symbol | Type | Range | Description |
|----------|--------|------|-------|-------------|
| Speed multiplier | speed_multiplier | int | {0, 1, 2, 3} | Player-selected sim speed |
| Wall seconds per tick | wall_seconds_per_tick | float | 0.033–0.1 | Real seconds between tick firings |
| Max ticks per frame | MAX_TICKS_PER_FRAME | int (const) | 8 (locked) | Safety clamp on ticks fired per `_process()` call |

**Output Range:** 0.1s (1x) down to ≈0.033s (3x); paused (0x) never fires. At the extreme of a frame hitch, ticks-per-frame is clamped:
```
ticks_this_frame = min(floor(tick_accumulator / TICK_DURATION_SECONDS), MAX_TICKS_PER_FRAME)
tick_accumulator -= ticks_this_frame * TICK_DURATION_SECONDS   # leftover carries forward, never discarded
```
This paces tick delivery across more frames after a hitch — it never skips, reorders, or duplicates a tick, so the bit-identical tick sequence (Core Rule 8) is preserved regardless of real frame timing.

**Example:** At 60fps (delta ≈ 16.6ms) and 3x speed: `tick_accumulator += 0.0166 × 3 = 0.05s` per frame → one tick fires roughly every 2 frames, nowhere near the 8-tick clamp. A 1-second hitch at 3x would otherwise queue 30 ticks; the clamp fires 8, carries the remaining accumulated time forward, and drains it over subsequent frames.

---

The **rng_subseed_derivation_formula** formula is defined as:

```
# All right-shifts below are LOGICAL (zero-filling). GDScript's native `>>` on
# int is ARITHMETIC (sign-extending), so implement a helper:
#   lsr(z, k) = (z >> k) & ((1 << (64 - k)) - 1)
# FNV-1a 64: offset basis 0xCBF29CE484222325, prime 0x100000001B3, over UTF-8 bytes.
name_hash = FNV1A64(system_name)
combined  = master_seed XOR name_hash
z = combined
z = (z XOR lsr(z, 30)) * 0xBF58476D1CE4E5B9
z = (z XOR lsr(z, 27)) * 0x94D049BB133111EB
sub_seed  = z XOR lsr(z, 31)
```

**Variables:**
| Variable | Symbol | Type | Range | Description |
|----------|--------|------|-------|-------------|
| Master seed | master_seed | int64 | full int64 | Global run seed (new-game or restored) |
| System name | system_name | String | e.g. "MemberSim" | Identifies the consuming system |
| Name hash | name_hash | int64 (wraps) | full int64 | FNV-1a 64 digest of `system_name`'s UTF-8 bytes |
| Combined | combined | int64 (wraps) | full int64 | XOR of `master_seed` and `name_hash` |
| Derived sub-seed | sub_seed | int64 (wraps) | full int64 | Final seed passed to that system's `RandomNumberGenerator.seed` |

**Output Range:** Full 64-bit space, uniformly distributed by construction (SplitMix64 is a proven bijective avalanche finalizer — **but only under logical right-shift**; the `lsr()` helper above is mandatory precisely because GDScript's native `>>` is arithmetic and would sign-extend for the ~50% of `master_seed`/`combined` values with the high bit set, breaking the avalanche/uniformity the formula relies on). Relies on GDScript `int`'s guaranteed 64-bit two's-complement wraparound for the multiplies — no external library needed. Deliberately **not** GDScript's built-in `hash()` (not contractually stable across engine versions) and **not** simple addition (`master_seed + hash(name)` would correlate similarly-named systems' streams). The FNV constants and the `lsr` semantics are pinned above so the AC13 golden-vector test is reproducible.
**Example:** `master_seed = 123456789`, `system_name = "Congestion"` → `name_hash` computed once (deterministic per string) → XOR with `master_seed` → SplitMix64 mix → a specific `sub_seed` (e.g. some large negative or positive int64 — sign is irrelevant, `RandomNumberGenerator.seed` accepts the full range). Same inputs always reproduce the identical `sub_seed`.

## Edge Cases

- **If `speed_multiplier` is 0 (paused)**: `tick_accumulator` does not accumulate at all — an early return before the `+=`, not an inert "add zero" — to avoid any float-precision creep from repeated no-op additions across long paused sessions.
- **If a single frame's delta would produce more ticks than `MAX_TICKS_PER_FRAME` (8)** (e.g. alt-tab hitch): fire exactly 8 ticks this frame, keep the remaining accumulated time in `tick_accumulator`, and drain it across subsequent frames. No tick is skipped, merged, or reordered — see `speed_to_realtime_formula`.
- **If a loaded save's `per_system_rng_states` entry for a given system is missing or fails to parse**: `deserialize()` fails loudly for the whole load, rather than silently re-deriving that system's RNG from `(master_seed, system_name)`. A silent re-derive would discard however many draws that system had already consumed pre-save, breaking determinism invisibly — the player would get a "working" game that has already silently diverged.
- **If `register_system()` is called twice with the same `system_name`** (typo, copy-paste error): TimeSystem asserts/fails at the second registration rather than silently letting two systems share one stream — a shared stream lets one system's draws perturb the other's sequence unpredictably, and this would only surface much later as unreproducible bug reports. (Note: `get_rng()` is deliberately *not* subject to this — it is safe to call repeatedly for an already-registered name and never registers anything. Only a duplicate `register_system()` fails.)
- **If the player changes speed while paused**: the selection is recorded but has no effect until unpaused; resuming uses whatever speed was last selected (defaults to 1x if none was ever chosen).
- **If a loaded save is missing `master_seed` or `tick_count`** (pre-TimeSystem save, or corruption): fail the load loudly. There is no safe default to invent — any invented value produces a game that looks fine but has already broken the determinism contract from tick 0.
- **If `TICK_DURATION_SECONDS` changes between a save's creation and a later load** (e.g. a future balance patch retunes 10Hz→20Hz): explicitly out of scope for MVP. This is a save-migration concern that belongs to SaveLoad's (#14) versioning strategy, not a compatibility promise this GDD makes — flagged in Open Questions.
- **Floating-point drift in `tick_accumulator` over a long session** (60–120 min at 1x ≈ 36,000–72,000 ticks): checked and explicitly a non-issue at IEEE754 double precision and this tick count/granularity — noted here so it isn't silently assumed away.

## Dependencies

**Upstream dependencies**: None. TimeSystem is a Foundation-layer system with no dependencies of its own.

**Downstream dependents** (all "hard" — none of these can function without TimeSystem; none have GDDs yet):

| System | Interface | Nature |
|---|---|---|
| MemberSim (#6) | `on_tick(TickContext)`; `get_rng("MemberSim")` | Hard |
| Congestion (#7) | `on_tick(TickContext)`; `get_rng("Congestion")` | Hard |
| Satisfaction (#10) | `on_tick(TickContext)`; `get_rng("Satisfaction")` | Hard |
| Economy (#11) | `on_tick(TickContext)`; `get_rng("Economy")`; `get_tick_count()` | Hard |
| HUD (#16) | `get_tick_count()`, `get_speed_multiplier()`, `is_paused()` (polled, not pushed) | Hard |
| SaveLoad (#14) | `serialize()` / `deserialize()` | Hard |

**Bidirectional consistency note**: when each of these six systems gets its own GDD, its Dependencies section must list "TimeSystem" as an upstream dependency — this table is the source of truth to check against at that time (or via `/consistency-check`).

## Tuning Knobs

| Knob | Default | Safe Range | Too Low | Too High |
|---|---|---|---|---|
| `TICKS_PER_SECOND` | 10 | 5–20 | Movement/congestion updates look visibly steppy (Pillar 3 readability risk) | Wastes CPU on per-tick MemberSim/Congestion logic for no visible benefit; shrinks the real-time margin before hitting `MAX_TICKS_PER_FRAME` at 3x speed |
| `MAX_TICKS_PER_FRAME` | 8 | 4–15 | After a hitch, simulation "catches up" too slowly — visible slow-motion drift for several seconds | A bad hitch spends more real milliseconds processing many ticks' worth of logic in one frame, causing a visible stutter cascade — the opposite of what the clamp exists to prevent |
| `SPEED_OPTIONS` (available multipliers) | {1, 2, 3} | up to {1,2,3,4} | Fewer options reduces player control over pacing (mild Pillar 2 friction) | Raising the ceiling (e.g. adding 4x) interacts directly with `TICKS_PER_SECOND`: it lowers `wall_seconds_per_tick` further, shrinking headroom before needing >1 tick/frame at 60fps — must be re-validated against `MAX_TICKS_PER_FRAME`, not changed in isolation |

**Interaction note**: `TICKS_PER_SECOND` and `MAX_TICKS_PER_FRAME` jointly determine the worst-case real-time gap the system absorbs gracefully before visible catch-up lag becomes noticeable (at defaults, roughly 8 ticks × 0.1s = 0.8 sim-seconds of buffered tolerance). Changing one without re-checking the other risks silently narrowing or widening that safety margin.

## Visual/Audio Requirements

[To be designed]

## UI Requirements

[To be designed]

## Acceptance Criteria

> Per this project's testing standards, TimeSystem is a **Logic** story (deterministic state machine + formulas) — every criterion below requires a **BLOCKING** automated unit test in `tests/unit/time_system/`.

1. **GIVEN** speed=1, tick_accumulator=0, **WHEN** one `_process(delta=0.1)` call occurs, **THEN** exactly 1 tick fires and tick_accumulator returns to ~0.
2. **GIVEN** speed=1, **WHEN** a single frame delivers delta=0.25s, **THEN** exactly 2 ticks fire and tick_accumulator ≈ 0.05s afterward (proves carry-forward, not truncation).
3. **GIVEN** speed_multiplier=0, **WHEN** `_process` runs repeatedly across a simulated 10s span, **THEN** tick_count and every per-system RNG state are byte-identical before and after.
4. **GIVEN** tick_accumulator=0.07s and tick_count=42 at speed=1, **WHEN** speed_multiplier is set to 3 with no frame processed yet, **THEN** tick_accumulator stays 0.07s and tick_count stays 42 immediately after the change.
5. **GIVEN** spy/mock MemberSim, Congestion, Satisfaction, Economy registered, **WHEN** one tick fires, **THEN** the recorded call order is exactly [MemberSim, Congestion, Satisfaction, Economy] → tick_count increments → `tick_completed(tick_count)` emits with the new value.
6. **GIVEN** `register_system("MemberSim")` has been called once, **WHEN** `get_rng("MemberSim")` is called twice with no draws between calls, **THEN** both calls return the same already-registered generator (same instance and same state), and no re-seeding or re-registration occurs.
7. **GIVEN** master_seed=X, **WHEN** 1000 values are drawn from the "MemberSim" and "Congestion" sub-streams, **THEN** the two sequences are neither identical nor a fixed offset of each other.
8. **GIVEN** a running sim at tick_count=500 with distinct per-system RNG states, **WHEN** `serialize()` then `deserialize()` into a fresh instance, **THEN** tick_count, master_seed, speed_multiplier, paused, and the next 100 RNG draws per system are bit-identical to continuing the original instance.
9. **GIVEN** two runs with identical master_seed to tick 1000, **WHEN** run A pauses 5s and run B pauses 300s at the same tick, **THEN** both produce bit-identical state/RNG output through tick 2000 after resuming.
10. **GIVEN** a save with speed_multiplier=3, paused=false, **WHEN** `deserialize()` completes and the first frame runs, **THEN** no ticks fire and `paused == true`, regardless of the saved paused/speed values.
11. **GIVEN** TICKS_PER_SECOND=10, **WHEN** TICK_DURATION_SECONDS is read, **THEN** it equals exactly 0.1.
12. **GIVEN** speed=2, tick_accumulator=0, **WHEN** delta=10.0s (hitch), **THEN** exactly 8 ticks fire (MAX_TICKS_PER_FRAME clamp) and tick_accumulator == 19.2s afterward — not discarded.
13. **GIVEN** master_seed=12345, system_name="Economy", **WHEN** sub_seed is computed via `rng_subseed_derivation_formula`, **THEN** it matches a hardcoded golden-vector constant every run.
14. **GIVEN** speed_multiplier=0, **WHEN** `_process(delta=5.0)` runs for 1000 consecutive frames, **THEN** tick_accumulator remains exactly 0.0 (proves the early-return path, not "accumulate-then-never-fire").
15. **GIVEN** `register_system("Economy")` has already been called once, **WHEN** `register_system("Economy")` is called a second time, **THEN** it asserts/fails rather than silently creating or sharing a second stream. (A repeated `get_rng("Economy")` call does **not** fail — only a duplicate `register_system()` does.)
16. **GIVEN** a save missing one system's `per_system_rng_states` entry, **WHEN** `deserialize()` runs, **THEN** the entire load fails — no partial load, no re-derive-from-seed fallback.
17. **GIVEN** a save missing `master_seed` or `tick_count`, **WHEN** `deserialize()` runs, **THEN** the load fails loudly with no invented default.
18. **GIVEN** paused=true and speed changed from 1x to 3x while paused, **WHEN** resume is triggered, **THEN** ticks proceed at 3x (the last-selected speed), not the pre-pause speed.
19. **GIVEN** the 8-tick clamp fires (as in AC12), **WHEN** each of the 8 ticks executes, **THEN** each individually completes the full MemberSim→Congestion→Satisfaction→Economy→increment→emit sequence — no batching or short-circuiting.
20. **GIVEN** a fresh 1x-speed run, **WHEN** 72,000 ticks are simulated (soak test, ≈120 real minutes), **THEN** `tick_accumulator` drift stays within a defined tight epsilon (< 1e-6s) of the expected value at every tick boundary — locks in the "non-issue" finding as a regression guard rather than an unstated assumption.

**Not unit-testable as a black-box criterion**: Core Rule 5 ("no mid-tick yielding") is a code-discipline constraint, not an observable input/output behavior — it's enforced via a **static code-review check** (grep for `await`/`yield` inside any `on_tick()` override), not an automated runtime test. Flagged here rather than forced into a false GIVEN-WHEN-THEN.

## Open Questions

| # | Question | Owner | Target Resolution |
|---|---|---|---|
| OQ1 | The fixed system call order (MemberSim→Congestion→Satisfaction→Economy, Core Rule 4) is a placeholder — must be confirmed/refined as each of those systems gets its own GDD. | Whoever designs MemberSim (#6) / Congestion (#7) / Satisfaction (#10) / Economy (#11) | Confirm during each system's own Section C |
| OQ2 | If a future balance patch changes `TICK_DURATION_SECONDS` (e.g. 10Hz→20Hz), existing saves' compatibility is undefined — this GDD explicitly does not make that promise. | SaveLoad GDD (#14) | When SaveLoad is designed, or at `/create-architecture` |
| OQ3 | Whether to raise `SPEED_OPTIONS` beyond 3x post-MVP; if so, must re-validate against the `MAX_TICKS_PER_FRAME` margin (Tuning Knobs interaction note). | game-designer, informed by playtest feedback | After the order-8 fun-validation milestone playtest |
| OQ4 | `rng_subseed_derivation_formula` relies on two GDScript-runtime behaviors that must be verified against actual Godot 4.7.1 (not assumed from spec) and locked by the AC13 golden-vector test before merge: (a) 64-bit two's-complement wraparound of the SplitMix64 multiplies, and (b) the `lsr()` logical-shift helper producing correct zero-filled results (since native `>>` is arithmetic). | Implementing programmer (godot-gdscript-specialist / gameplay-programmer) | At `/dev-story` time for this system, before merge |
| OQ5 | The player-facing pause/speed-control UI (buttons, keybindings, visual state) is out of scope for this GDD and needs its own UX spec. | ux-designer | When HUD (#16) is designed — run `/ux-design` |
