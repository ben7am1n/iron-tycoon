# Story 004: Serialization, Determinism and Recovery Loop

> **Epic**: satisfaction
> **Status**: Ready
> **Layer**: Feature
> **Type**: Integration
> **Estimate**: M — 2 sessions (≤4h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-02

## Context

**GDD**: `design/gdd/satisfaction.md`
**Requirement**: `TR-SAT-008`, `TR-SAT-009`, `TR-SAT-010`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0002 (Storage Format); ADR-0005 (Signal Bus & Event Routing)
**ADR Decision Summary**: Serialized: `global_satisfaction` (float) + `member_accumulators` (per-member `{S_acc, n_uses, queue_ticks, n_fail, n_interrupt}`). No RNG. Congestion always read as t-1 snapshot. Fixed departure-fold order (ascending member_id). Economy does NOT read satisfaction directly — influence is indirect via MemberSim arrival volume.

**Engine**: Godot 4.7.1 | **Risk**: LOW
**Engine Notes**: `JSON.stringify(full_precision=true)` for bit-exact float round-trip (ADR-0002). Two-phase deserialize (Phase A validate / Phase B commit).

**Control Manifest Rules (Feature layer)**:
- Required: two-phase deserialize; floats full_precision
- Required: fixed tick order; no RNG; no mid-tick yielding
- Required: Economy does NOT read satisfaction (TR-SAT-010)

---

## Acceptance Criteria

*From GDD `design/gdd/satisfaction.md`, scoped to this story:*

- [ ] AC1 Determinism: GIVEN a fixed event sequence (entered / use-completed with a congestion snapshot / queue / departed), WHEN replayed twice, THEN every `S_member` and `global_satisfaction` value is bit-identical
- [ ] AC15 Serialization round-trip: GIVEN mid-visit accumulators and a `global_satisfaction` value, WHEN serialized and reloaded, THEN the next tick's computation is bit-identical to uninterrupted play. The test must trigger a use-completion or departure after reload to verify accumulator fields survive
- [ ] AC17 (integration, advisory) Self-correcting recovery (no death spiral): GIVEN a maximally-congested gym driving `global_satisfaction` toward 0, WHEN the loop runs (arrivals floor at modifier 0.5 → fewer members → congestion eases), THEN `global_satisfaction` stops falling and recovers by ≥ 0.01 within 200 departures — it never reaches a stuck/zero-arrival state

---

## Implementation Notes

*Derived from ADR-0002 + ADR-0005 Implementation Guidelines:*

**Core Rule 8 — determinism & serialization:**
- Serialized: `global_satisfaction` (float) + `member_accumulators` (per-member `{S_acc, n_uses, queue_ticks, n_fail, n_interrupt}`)
- No RNG; Congestion always read as t-1 snapshot; fixed departure-fold order (ascending member_id)
- AC1: replay identical event sequence twice → bit-identical S_member and global_satisfaction
- AC15: serialize mid-visit accumulators + global value, reload, trigger use-completion/departure after reload → next tick bit-identical to uninterrupted play (accumulator fields survive)

**Core Rule 7 — self-correcting loop (AC17, integration advisory):**
- Loop: satisfaction → arrivals/visit-length → members → congestion → satisfaction — negative feedback on congestion
- Low satisfaction → fewer members → less congestion → satisfaction recovers
- Stabilizes at whatever zone_synergy a layout earns at low congestion (a low-but-nonzero "calm and sparse" equilibrium), never at zero
- Modifier floor (0.5) + exercises_per_visit ≥ 1 floor keep recovery observable
- AC17: maximal congestion → global drops toward 0 → recovers by ≥ 0.01 within 200 departures — never stuck/zero-arrival

**TR-SAT-010 (no direct Economy read):**
- Economy does NOT read global_satisfaction or satisfaction_modifier directly — influence is indirect via MemberSim arrival volume (which the modifier drives). No $ baked into satisfaction.

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 001–003]: accumulator, S_member, global EMA + modifiers (this story wires serialization + loop integration around them)
- congestion epic story 004: Congestion's own serialization

---

## QA Test Cases

*Written by qa-lead at story creation. The developer implements against these — do not invent new test cases during implementation.*

- **AC1**: 确定性重放
  - Given: fixed event sequence (entered / use-completed with congestion snapshot / queue / departed)
  - When: replayed twice
  - Then: every S_member and global_satisfaction bit-identical
  - Edge cases: multiple members, multi-departure ticks, mid-visit save points

- **AC15**: 序列化往返
  - Given: mid-visit accumulators + global_satisfaction value
  - When: serialized and reloaded
  - Then: next tick's computation bit-identical to uninterrupted play; trigger use-completion/departure after reload to verify accumulator fields survive
  - Edge cases: accumulator with n_uses > 0, queue_ticks > 0, penalties; reload exactly at departure boundary

- **AC17**: 自恢复无死亡螺旋 (integration, advisory)
  - Given: maximally-congested gym driving global_satisfaction toward 0
  - When: loop runs (arrivals floor at 0.5 → fewer members → congestion eases)
  - Then: global_satisfaction stops falling and recovers by ≥ 0.01 within 200 departures; never stuck/zero-arrival
  - Edge cases: empty layout (walk-fails); full congestion; repeated save/load during recovery

---

## Test Evidence

**Story Type**: Integration
**Required evidence**:
- `tests/unit/satisfaction/determinism_serialization_test.gd` — AC1/AC15 (must exist and pass)
- `tests/integration/satisfaction/recovery_loop_test.gd` — AC17 (advisory)

**Status**: [ ] Not yet created

---

## Dependencies

- Depends on: Story 003 (global EMA + modifiers), save-load epic (two-phase deserialize protocol)
- Unlocks: economy epic (revenue on quota-met completions), member-sim OQ3 closure (modifier wiring verified end-to-end)
