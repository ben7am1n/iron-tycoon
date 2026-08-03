# Story 002: S_member and Penalty Caps

> **Epic**: satisfaction
> **Status**: In Review
> **Layer**: Feature
> **Type**: Logic
> **Estimate**: S — 1 session (≤2h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-03

## Context

**GDD**: `design/gdd/satisfaction.md`
**Requirement**: `TR-SAT-004`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0005 (Signal Bus & Event Routing)
**ADR Decision Summary**: `S_member = clamp(S_base + avg(use_quality over completed uses) − queue_penalty − fail_penalty − interrupt_penalty, 0, 1)` with `S_base = 0.5`. Each penalty term individually capped so one-off event penalties are always smaller in magnitude than the zone/congestion terms — queue noise and bad-luck events never drown out the core spatial-optimization signal.

**Engine**: Godot 4.7.1 | **Risk**: LOW
**Engine Notes**: No RNG; deterministic. `avg(use_quality) = 0` when n_uses = 0 (no divide-by-zero).

**Control Manifest Rules (Feature layer)**:
- Required: fixed tick order; no RNG; no mid-tick yielding
- Guardrail: penalty caps prevent event noise from dominating the spatial signal

---

## Acceptance Criteria

*From GDD `design/gdd/satisfaction.md`, scoped to this story:*

- [x] AC11 Queue penalty cap: GIVEN `queue_ticks_total` far exceeding `queue_norm_ticks`, WHEN `queue_penalty` is computed, THEN it is ≤ 0.3
- [x] AC12 Fail/interrupt penalty caps: GIVEN `n_fail = 10, n_interrupt = 10`, WHEN `fail_penalty` and `interrupt_penalty` are computed, THEN `fail_penalty ≤ 0.30` and `interrupt_penalty ≤ 0.20`

---

## Implementation Notes

*Derived from ADR-0005 Implementation Guidelines:*

**S_member formula (Core Rule 4, TR-SAT-004):**
```
S_member = clamp(S_base + avg(use_quality) − queue_penalty − fail_penalty − interrupt_penalty, 0, 1)
queue_penalty = w_queue × clamp(queue_ticks_total / queue_norm_ticks, 0, 1)
fail_penalty = min(w_fail × n_fail, cap_fail)
interrupt_penalty = min(w_interrupt × n_interrupt, cap_interrupt)
```
- `S_base = 0.5` — a blank visit lands neutral (Pillar 2)
- `w_queue = 0.3`, `queue_norm_ticks = 100` (10 s)
- `w_fail = 0.15`, `cap_fail = 0.30` (max 2 failures contribute) — AC12
- `w_interrupt = 0.20`, `cap_interrupt = 0.20` (max 1 interrupt contributes) — AC12
- `avg(use_quality) = 0` if n_uses = 0 (no divide-by-zero); `S_member = S_base` when all zero
- Max total event penalty = 0.30 + 0.20 + 0.30 = 0.80, always leaving `S_base + avg(use_quality)` dominant for members with positive use events

**Penalty caps rationale:**
- Caps guarantee one-off event penalties are always SMALLER than zone/congestion terms
- Queue noise and bad-luck events never drown out the core spatial-optimization signal

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 001]: accumulator structure + use_quality computation
- [Story 003]: global_satisfaction EMA + modifiers
- [Story 004]: serialization + determinism

---

## QA Test Cases

*Written by qa-lead at story creation. The developer implements against these — do not invent new test cases during implementation.*

- **AC11**: 排队惩罚上限
  - Given: queue_ticks_total far exceeding queue_norm_ticks
  - When: queue_penalty computed
  - Then: ≤ 0.3
  - Edge cases: queue_ticks_total = queue_norm_ticks exactly → 0.3; queue_ticks_total = 0 → 0

- **AC12**: 失败/中断惩罚上限
  - Given: n_fail = 10, n_interrupt = 10
  - When: fail_penalty and interrupt_penalty computed
  - Then: fail_penalty ≤ 0.30; interrupt_penalty ≤ 0.20
  - Edge cases: n_fail = 1 → 0.15; n_fail = 2 → 0.30; n_fail = 3 → still 0.30; n_interrupt = 1 → 0.20; n_interrupt = 2 → still 0.20

---

## Test Evidence

**Story Type**: Logic
**Required evidence**:
- `tests/unit/satisfaction/penalty_caps_test.gd` — must exist and pass (AC11, AC12)

**Status**: [x] Complete — penalty_caps_test.gd 38 asserts all green (AC11, AC12 + guardrail + on_tick wiring), registered in TEST_FILES; full headless suite 2881 passed / 0 failed (was 2843).

### Implementation summary (SAT-002)

- S_member and the capped penalty terms were already landed in SAT-001 (`compute_s_member` +
  `_queue_penalty` / `_fail_penalty` / `_interrupt_penalty` in `src/systems/satisfaction.gd`,
  TR-SAT-004) because the story-001 QA cases (AC5/6/8/10) exercised them. This story owns the
  dedicated penalty-cap test file `tests/unit/satisfaction/penalty_caps_test.gd` (AC11/12) —
  no production-code change was needed; the caps verified as specified:
  - AC11: `queue_penalty = 0.3 × clamp(queue_ticks/100, 0, 1)` — ≤ 0.3 for any count;
    edge `== 100 → 0.3`, `== 0 → 0` (sweep 0..100000, monotonic, saturating).
  - AC12: `fail_penalty = min(0.15×n_fail, 0.30)`, `interrupt_penalty = min(0.20×n_interrupt, 0.20)`
    — at n_fail=10 / n_interrupt=10 the caps hold; edge n_fail 1→0.15 / 2→0.30 / 3→0.30,
    n_interrupt 1→0.20 / 2→0.20.
  - Guardrail: each cap < max |use_quality| (0.5); max total event penalty 0.80 < S_base +
    best avg (1.0) — a perfect use + ALL caps still lands S_member 0.2 (spatial signal
    dominant, never zeroed by event noise).
  - Event path: public API (add_queue_ticks / on_walk_fail / on_interrupt / on_member_departed
    fold-return) + one on_tick roster-diff case (LEAVING no_candidates → n_fail, mid-use
    interrupt → n_interrupt, quota_met NOT a failure) — all capped S_members fold correctly.
- No RNG, no new serialize surface (story-004 owns the extended shape), no production diff.

---

## Dependencies

- Depends on: Story 001 (accumulator structure, use_quality)
- Unlocks: Story 003 (global EMA folds S_member), Story 004 (serialization of accumulators)
