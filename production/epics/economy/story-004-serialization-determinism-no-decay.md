# Story 004: Serialization, Determinism and No-Decay

> **Epic**: economy
> **Status**: Ready
> **Layer**: Feature
> **Type**: Integration
> **Estimate**: S — 1 session (≤2h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-02

## Context

**GDD**: `design/gdd/economy.md`
**Requirement**: `TR-ECON-007`, `TR-ECON-009`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0002 (Storage Format); ADR-0005 (Signal Bus & Event Routing); ADR-0006 (Economy Credit Interface)
**ADR Decision Summary**: Serialize ONLY `balance: int` — no derived state, a trivial exact round-trip. Deterministic accrual: an identical MemberSim event sequence yields a bit-identical balance across runs and saves. No upkeep (MVP) — a period with zero departures and no spend leaves balance unchanged (never decays).

**Engine**: Godot 4.7.1 | **Risk**: LOW
**Engine Notes**: `balance` is int — no float precision concerns. Two-phase deserialize (Phase A validate / Phase B commit).

**Control Manifest Rules (Feature layer)**:
- Required: two-phase deserialize; serialize only `balance: int`
- Required: `balance_changed(new_balance, delta)` (S6) emitted after every balance mutation
- Forbidden: no RNG; no mid-tick yielding

---

## Acceptance Criteria

*From GDD `design/gdd/economy.md`, scoped to this story:*

- [ ] AC6 Deterministic accrual: GIVEN a fixed array of `member_completed_visit` payloads fed directly into `Economy.on_member_completed_visit()`, WHEN processed in two separate Economy instances, THEN both produce the identical balance trace
- [ ] AC10 No decay / no upkeep: GIVEN a period with zero departures and no `spend` calls, WHEN ticks advance, THEN `balance` is unchanged (never decays)
- [ ] AC12 Serialization round-trip: GIVEN any `balance`, WHEN serialized and reloaded, THEN the value is identical (int, no reconstruction ambiguity) and the next accrual matches uninterrupted play

---

## Implementation Notes

*Derived from ADR-0002 + ADR-0005 + ADR-0006 Implementation Guidelines:*

**Core Rule 7 — determinism & serialization (TR-ECON-009):**
- Serialize ONLY `balance: int` — no derived state, trivial exact round-trip
- Deterministic accrual: identical MemberSim event sequence → bit-identical balance across runs and saves
- AC6: two separate Economy instances fed same event payloads → identical balance trace

**Core Rule 4 — no upkeep (AC10):**
- No per-tick electricity/staff/rent cost
- Zero departures + no spend → balance unchanged, never decays
- A slow month just means a slower save-up — members always keep trickling in so you can always climb back

**Core Rule 1 — tick structure:**
- `on_tick(tick_context)` after Satisfaction (income reflects visits resolved this tick)
- `balance_changed(new_balance, delta)` (S6) emitted after every mutation (income or spend), signed delta

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 001]: balance + revenue
- [Story 002]: spend()/can_afford gating
- [Story 003]: credit() interface

---

## QA Test Cases

*Written by qa-lead at story creation. The developer implements against these — do not invent new test cases during implementation.*

- **AC6**: 确定性记账
  - Given: fixed array of member_completed_visit payloads fed directly into Economy.on_member_completed_visit()
  - When: processed in two separate Economy instances
  - Then: both produce identical balance trace
  - Edge cases: mixed payload order; interleaved spend calls

- **AC10**: 无衰减
  - Given: period with zero departures and no spend calls
  - When: ticks advance
  - Then: balance unchanged (never decays)
  - Edge cases: many idle ticks; pause/resume

- **AC12**: 序列化往返
  - Given: any balance
  - When: serialized and reloaded
  - Then: value identical (int, no reconstruction ambiguity); next accrual matches uninterrupted play
  - Edge cases: balance 0, balance 500 (starting), balance after many accruals + spends

---

## Test Evidence

**Story Type**: Integration
**Required evidence**:
- `tests/unit/economy/serialization_determinism_test.gd` — must exist and pass (AC6, AC10, AC12)

**Status**: [ ] Not yet created

---

## Dependencies

- Depends on: Story 002 (spend), Story 003 (credit), save-load epic (two-phase deserialize protocol)
- Unlocks: shop-purchase epic (spend consumer), HUD (balance_changed subscriber), core_loop_test unlock
