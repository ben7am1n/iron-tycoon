# Epic: MemberSim

> **Layer**: Feature
> **GDD**: design/gdd/member-sim.md
> **Architecture Module**: MemberSim — owns member state array, reservation map, `member_id_counter`; exposes `member_completed_visit(member_id)` signal
> **Status**: Complete — 2026-08-05 (all stories Complete)
> **Stories**: 5 stories created — see below

## Stories

| # | Story | Type | Status | ADR |
|---|-------|------|--------|-----|
| 001 | Lifecycle State Machine Core | Logic | Complete — 2026-08-05 | ADR-0003, ADR-0004, ADR-0005 |
| 002 | Target Selection and Weighted Pick | Logic | Complete — 2026-08-05 | ADR-0004, ADR-0005 |
| 003 | Reservation Map and Contention | Logic | Complete — 2026-08-05 | ADR-0003, ADR-0004, ADR-0005 |
| 004 | Path Invalidation, Patience and Interrupts | Logic | Complete — 2026-08-05 | ADR-0003, ADR-0005 |
| 005 | Serialization, Determinism and Flow Hypothesis | Integration | Complete — 2026-08-05 | ADR-0002, ADR-0004, ADR-0005 |

## Overview

MemberSim is the beating heart of the MVP hypothesis — "tuning layout for flow is fun." It simulates the pixel members who enter the gym, choose equipment to use, path toward it, queue when it's busy, use it, and eventually leave. It runs **first** each simulation tick (before Congestion), reads `Congestion(t-1)` as a one-tick-lagged preference input to its target selection, and drives everything through a seeded RNG sub-stream (`TimeSystem.get_rng("MemberSim")`) so saves reproduce bit-for-bit. It owns the members themselves (persistent `member_id`, state, position), the access-cell reservation mechanism that GridSystem explicitly refused to own, and the member activity lifecycle — but none of the spatial truth (GridSystem), pathfinding (Navigation), or equipment data (EquipmentCatalog) it consumes.

**⚠️ Replacement stub**: `src/systems/member_sim.gd` is currently a CORE-LAYER INTEGRATION STUB (created for save-load story SL-002 to make the load pipeline testable). The real MemberSim replaces this file. It MUST keep the public contract surface: `class_name MemberSim extends SimSystem`, `init(orchestrator, seeded_rng)` with exactly-once RNG sub-stream registration, `system_name() -> "MemberSim"`, `serialize()` / `deserialize(data, validate_only, known_instance_ids)` two-phase protocol (Phase A zero-mutation validate, Phase B commit). SaveLoad depends on these signatures — do not break them.

## Governing ADRs

| ADR | Decision Summary | Engine Risk |
|-----|-----------------|-------------|
| ADR-0003: GridStateReader Contract | MemberSim reads occupancy/access cells through the typed read surface (`get_occupant_id`, `get_access_cells`, `get_placed_instances`, `is_solid`, `get_dimensions`) — never internal representation. `entrance_cell`/`exit_cell` are a hard level/GridSystem dependency (TR-MS-013). | LOW |
| ADR-0004: Seeded RNG Architecture | All MemberSim randomness via `get_rng("MemberSim")` sub-stream (FNV-1a64 + XOR + SplitMix64). RNG state serialized as hex and restored directly, never re-derived from master_seed. Fixed consumption order per tick: arrival roll first, then per-member updates in ascending `member_id` order. | LOW |
| ADR-0005: Signal Bus & Event Routing | MemberSim is the first system in the hardcoded tick dispatch. Emits `member_completed_visit(member_id)` (S5) only on quota-met departures — walk-failure/patience-exhaust earn nothing. Satisfaction events are direct method reads during its `on_tick()`, not separate signals. | LOW |

## GDD Requirements

| TR-ID | Requirement | ADR Coverage |
|-------|-------------|--------------|
| TR-MS-001 | Tick-driven, runs FIRST each tick before Congestion; all randomness via get_rng('MemberSim') sub-stream | ADR-0004, ADR-0005 ✅ |
| TR-MS-002 | Member lifecycle state machine: ENTERING -> SELECTING_TARGET -> WALKING_TO -> [QUEUEING] -> USING -> LEAVING -> GONE | ADR-0003, ADR-0005 ✅ |
| TR-MS-003 | Target selection: build candidate pool, weight from Congestion(t-1)/distance/novelty, top-K=3-5, path-check, weighted-random draw | ADR-0004, ADR-0005 ✅ |
| TR-MS-004 | Access-cell reservation map: reservations[equipment_instance_id] = {occupant, next_claimant}; queue depth=1 MVP | ADR-0003 ✅ |
| TR-MS-005 | Release invariant: member leaving without becoming occupant must clear next_claimant same tick | ADR-0003 ✅ |
| TR-MS-006 | Fairness/determinism: all contention resolved by ascending member_id iteration order | ADR-0004, ADR-0005 ✅ |
| TR-MS-007 | Path invalidation: compare cached grid_version each tick; on mismatch re-query Navigation | ADR-0003, ADR-0005 ✅ |
| TR-MS-008 | member_arrival_rate: Bernoulli draw = clamp(base/min * TICK_DURATION * satisfaction_modifier * capacity_gate, 0, 1) | ADR-0004 ✅ |
| TR-MS-009 | use_duration = round(clamp(randfn(mean, stddev), min, max)); per-equipment fields from EquipmentCatalog | ADR-0004 ✅ |
| TR-MS-010 | exercises_per_visit = round(clamp(randfn(mean * visit_length_modifier, stddev), min=1, max=5)) | ADR-0004 ✅ |
| TR-MS-011 | member_id_counter MUST be serialized explicitly -- cannot re-derive from active set (retired ids would be reused) | ADR-0002 ✅ |
| TR-MS-012 | member_id never reused; lifecycle ends at GONE, id retired permanently | ADR-0002 ✅ |
| TR-MS-013 | entrance_cell and exit_cell = HARD upstream dependency on GridSystem/level definition | ADR-0003 ✅ |
| TR-MS-014 | Emit member_completed_visit signal (only for quota-met departures) | ADR-0005 ✅ |

## Definition of Done

This epic is complete when:
- All stories are implemented, reviewed, and closed via `/story-done`
- All acceptance criteria from `design/gdd/member-sim.md` are verified (AC1–AC22)
- `src/systems/member_sim.gd` stub is fully replaced by the real state machine, preserving the SaveLoad contract surface
- All Logic and Integration stories have passing test files in `tests/`
- Signal emit arity verified for `member_completed_visit` (1 arg) via GUT spy test
- MemberSim tick order verified: runs before Congestion in `SimulationOrchestrator._advance_tick()`
- AC22 end-to-end flow hypothesis test (spread layout beats clumped on queue occupancy) passes in `tests/integration/member_sim/`

## Next Step

Work through stories in order — each story's `Depends on:` field tells what must be DONE before it can start.
