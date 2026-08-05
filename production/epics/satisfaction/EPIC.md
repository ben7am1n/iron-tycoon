# Epic: Satisfaction

> **Layer**: Feature
> **GDD**: design/gdd/satisfaction.md
> **Architecture Module**: Satisfaction — owns `global_satisfaction` EMA, `member_accumulators`; exposes `global_satisfaction: float`, `satisfaction_modifier: float`
> **Status**: Complete — 2026-08-05 (all stories Complete)
> **Stories**: 4 stories created — see below

## Stories

| # | Story | Type | Status | ADR |
|---|-------|------|--------|-----|
| 001 | Member Accumulators and use_quality | Logic | Complete — 2026-08-05 | ADR-0003, ADR-0005 |
| 002 | S_member and Penalty Caps | Logic | Complete — 2026-08-05 | ADR-0005 |
| 003 | global_satisfaction and Modifiers | Logic | Complete — 2026-08-05 | ADR-0005 |
| 004 | Serialization, Determinism and Recovery Loop | Integration | Complete — 2026-08-05 | ADR-0002, ADR-0005 |

## Overview

Satisfaction is the numeric heart that answers "is my layout actually good?" It combines the three signals the rest of the sim produces — ZoneRules' static layout quality (comfort, zone synergy, spaciousness), Congestion's dynamic crowding pressure, and MemberSim's per-member experience events (queueing, failed walks, interrupted uses) — into a per-member satisfaction, then rolls departing members' satisfaction into a slow, gym-level `global_satisfaction` reputation meter. That meter feeds a `satisfaction_modifier` that gently accelerates/slows member arrivals and visit length. Its defining constraint is Pillar 2: satisfaction is a positive-pressure dial, never a failure state — a structural floor guarantees a trickle of arrivals even at rock bottom (anti-death-spiral).

**⚠️ Replacement stub**: `src/systems/satisfaction.gd` is currently a CORE-LAYER INTEGRATION STUB (created for save-load story SL-002). The real Satisfaction replaces this file. It MUST keep the contract surface: `class_name Satisfaction extends SimSystem`, `init(orchestrator, seeded_rng)` with RNG sub-stream registration, `system_name() -> "Satisfaction"`, `serialize()` / `deserialize(data, validate_only)` two-phase protocol. **Note**: the real Satisfaction uses NO RNG (per GDD Core Rule 1) — it may drop the RNG draw but must keep `serialize()` shape consistent with `tests/integration/save_load/` expectations (currently serializes `{counter, rng_state}`; real shape becomes `{global_satisfaction, member_accumulators}` — coordinate the schema change with SaveLoad).

## Governing ADRs

| ADR | Decision Summary | Engine Risk |
|-----|-----------------|-------------|
| ADR-0002: Storage Format | Serialized state: `global_satisfaction` (float) + `member_accumulators` (per-member `{S_acc, n_uses, queue_ticks, n_fail, n_interrupt}`). Floats must use `JSON.stringify(full_precision=true)` for bit-exact save/load. | LOW |
| ADR-0003: GridStateReader Contract | Consumes ZoneRules per-instance effect dict (built on the grid read surface); no direct grid reads of its own. | LOW |
| ADR-0005: Signal Bus & Event Routing | Satisfaction is the third system in the hardcoded tick dispatch (after Congestion). Reads MemberSim events via direct method call during its `on_tick()` (satisfaction events are NOT separate signals — they are direct reads; only `member_completed_visit` S5 is a signal, and Satisfaction may subscribe to it for departure folding). No RNG. | LOW |

## GDD Requirements

| TR-ID | Requirement | ADR Coverage |
|-------|-------------|--------------|
| TR-SAT-001 | Tick-driven, runs after Congestion; deterministic, no RNG | ADR-0005 ✅ |
| TR-SAT-002 | Per-member accumulator: member_accumulators[member_id] = {S_acc, n_uses, queue_ticks, n_fail, n_interrupt} | ADR-0002, ADR-0005 ✅ |
| TR-SAT-003 | use_quality_i = w_zone * clamp(total_i / Z_NORM, 0, 1) - w_cong * Congestion_i(t-1); w_zone = w_cong = 0.5 | ADR-0003, ADR-0005 ✅ |
| TR-SAT-004 | S_member = clamp(S_base + avg(use_quality) - queue_penalty - fail_penalty - interrupt_penalty, 0, 1); S_base=0.5 | ADR-0005 ✅ |
| TR-SAT-005 | global_satisfaction: slow event-driven EMA (alpha_g=0.05); updated only on member departure; init 0.5 | ADR-0005 ✅ |
| TR-SAT-006 | satisfaction_modifier = piecewise-linear; range [0.5, 2.0]; structurally floors at 0.5 (never zero, anti-death-spiral) | ADR-0005 ✅ |
| TR-SAT-007 | visit_length_modifier = 1 + (satisfaction_modifier - 1) * damp, damp=0.5; range [0.75, 1.5] | ADR-0005 ✅ |
| TR-SAT-008 | Self-correcting loop: low satisfaction -> fewer members -> less congestion -> satisfaction recovers | ADR-0005 ✅ |
| TR-SAT-009 | Serialized: global_satisfaction + member_accumulators | ADR-0002 ✅ |
| TR-SAT-010 | Economy does NOT read satisfaction directly; influence is indirect via MemberSim arrival volume | ADR-0005 ✅ |

## Definition of Done

This epic is complete when:
- All stories are implemented, reviewed, and closed via `/story-done`
- All unit acceptance criteria from `design/gdd/satisfaction.md` are verified (AC1–AC16); integration AC17–18 advisory
- `src/systems/satisfaction.gd` stub is fully replaced by the real accumulator + EMA system, preserving the SaveLoad contract surface (schema change coordinated with save-load)
- All Logic stories have passing test files in `tests/unit/satisfaction/`
- Satisfaction tick order verified: runs after Congestion, before Economy in `SimulationOrchestrator._advance_tick()`
- AC15 serialization round-trip and AC1 determinism pass

## Next Step

Work through stories in order — each story's `Depends on:` field tells what must be DONE before it can start.
