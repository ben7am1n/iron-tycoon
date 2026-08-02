# Epic: TimeSystem + SimulationOrchestrator + SeededRNG

> **Layer**: Foundation
> **GDD**: design/gdd/time-system.md
> **Architecture Module**: TimeSystem — owns `tick_count`, `master_seed`, RNG sub-stream states, `paused`, `speed_multiplier`; drives the tick loop
> **Status**: Complete
> **Stories**: 4 stories created — see below

## Stories

| # | Story | Type | Status | ADR |
|---|-------|------|--------|-----|
| 001 | SimulationOrchestrator and Tick Dispatch | Logic | Complete | ADR-0001, ADR-0005 |
| 002 | Tick Accumulator, Speed Control, and Pause | Logic | Complete | ADR-0001 |
| 003 | SeededRNG and Sub-Stream Derivation | Logic | Complete | ADR-0004 |
| 004 | Serialization, Deserialization, and Resume Behavior | Integration | Complete | ADR-0002, ADR-0004, ADR-0005 |

## Overview

TimeSystem (paired with the SimulationOrchestrator and a central SeededRNG) is the deterministic clock and scheduling backbone the entire simulation runs on. It owns a single abstract tick counter and drives every other simulation system (MemberSim, Congestion, Satisfaction, Economy) through a fixed, render-decoupled update order each tick. A seeded RNG instance — whose seed and internal state are fully serializable — supplies all randomness so that saves reproduce identically on load. The system uses a custom fixed-timestep accumulator (`TICK_DURATION_SECONDS = 0.1`, 10 Hz) independent of `_physics_process`, with a `MAX_TICKS_PER_FRAME = 8` catch-up cap.

The SimulationOrchestrator is the single composition root Node that owns all 12 systems as `RefCounted` fields and all bridge Nodes as children. Initialization order is enforced topologically in `_ready()` (Tier 0 through Tier 7), and tick dispatch is a hardcoded sequence of direct method calls (not signal-driven): `MemberSim.on_tick()` → `Congestion.on_tick()` → `Satisfaction.on_tick()` → `Economy.on_tick()`. The `tick_completed(tick_count)` signal fires at the end of each tick sequence — this is the hook SaveLoad uses for tick-boundary saves.

RNG sub-streams are derived from `master_seed` via FNV-1a64 → XOR → SplitMix64, pinned to published constants. Each system calls `register_system(name)` exactly once during `_post_init()` and retrieves its stream via the idempotent `get_rng(name)`. On load, RNG state is restored directly (`rng.state = hex_to_int()`), not re-derived. The `lsr()` helper is mandatory because GDScript's `>>` is arithmetic (sign-extending), which would corrupt the SplitMix64 avalanche for values with the high bit set.

## Governing ADRs

| ADR | Decision Summary | Engine Risk |
|-----|-----------------|-------------|
| ADR-0001: DI Container & Scene Bootstrap | `SimulationOrchestrator` is the single composition root Node. Two-phase `init()`/`_post_init()`. `TickContext` passes `tick_count` + per-system `rng` to `on_tick()`. Fixed tick dispatch via direct method calls. `MAX_TICKS_PER_FRAME = 8`. Tick loop uses `_process(delta)` accumulator, not a Timer node. | LOW |
| ADR-0002: Storage Format | All 64-bit integers in save JSON must be hex strings. `JSON.stringify()` uses `full_precision=true` and `sort_keys=true`. RNG state serialized as hex string, restored directly (not re-derived from `master_seed`). | LOW |
| ADR-0004: Seeded RNG Architecture | FNV-1a64 → XOR with `master_seed` → SplitMix64 finaliser for sub-stream derivation. `lsr()` helper required (GDScript `>>` is arithmetic). `register_system()` once per system (hard error on duplicate). `get_rng()` idempotent (returns existing, never creates). RNG state restored directly on load (draw-count-agnostic). | LOW |
| ADR-0005: Signal Bus & Event Routing | Tick dispatch is hardcoded direct calls (not signal-driven). `tick_completed(tick_count: int)` signal (S2) fires at end of tick sequence — the hook SaveLoad uses. `TickContext` documented here; signals S1–S8 catalogued. | LOW |

## GDD Requirements

| TR-ID | Requirement | ADR Coverage |
|-------|-------------|--------------|
| TR-TS-001 | Custom fixed-timestep accumulator independent of _physics_process; TICK_DURATION_SECONDS = 0.1 (10 Hz) | ADR-0001 ✅ |
| TR-TS-002 | MAX_TICKS_PER_FRAME = 8 safety clamp; speed in {0,1,2,3}; pause freezes accumulator entirely | ADR-0001 ✅ |
| TR-TS-003 | Fixed system call order: MemberSim → Congestion → Satisfaction → Economy → tick_count++ → tick_completed | ADR-0005 ✅ |
| TR-TS-004 | No mid-tick yielding (no await in on_tick); guarantees tick-boundary = safe save point | ADR-0005 ✅ |
| TR-TS-005 | Per-system RNG sub-streams via FNV-1a64 + SplitMix64 derivation from master_seed | ADR-0004 ✅ |
| TR-TS-006 | register_system(name) once per system, double=hard error; get_rng(name) idempotent | ADR-0004 ✅ |
| TR-TS-007 | SplitMix64 requires logical right-shift (GDScript >> is arithmetic, must implement lsr helper) | ADR-0004 ✅ |
| TR-TS-008 | serialize(): tick_count, master_seed, per_system_rng_states, speed_multiplier, paused | ADR-0002 ✅ |
| TR-TS-009 | deserialize() restores each sub-stream's exact internal state, not re-derived from master_seed | ADR-0004 ✅ |
| TR-TS-010 | Load always resumes PAUSED regardless of saved speed | ADR-0004 ✅ |
| TR-TS-011 | Determinism contract: same master_seed + same tick sequence = bit-identical replay | ADR-0004 ✅ |
| TR-TS-012 | tick_accumulator float checked for drift across 72,000 ticks (< 1e−6s tolerance) | ADR-0001 ✅ |

## Definition of Done

This epic is complete when:
- All stories are implemented, reviewed, and closed via `/story-done`
- All acceptance criteria from `design/gdd/time-system.md` are verified
- All Logic and Integration stories have passing test files in `tests/`
- `lsr()` helper unit-tested for all SplitMix64 boundary values (high bit set, zero, etc.)
- RNG sub-stream derivation verified: same `master_seed` + same `system_name` produces identical `state` cross-process
- Tick accumulator drift test passes: ≤ 1e−6s error after 72,000 ticks (2 hours sim-time)
- Two-phase init enforced: calling `init()` twice asserts; calling public methods before `init()` asserts
- Tick dispatch order verified by integration test: MemberSim tick fires before Congestion, etc.
- All Visual/Feel and UI stories have evidence docs with sign-off in `production/qa/evidence/`

## Next Step

Run `/create-stories time-system` to break this epic into implementable stories.
