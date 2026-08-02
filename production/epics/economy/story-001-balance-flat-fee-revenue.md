# Story 001: Balance and Flat-Fee Revenue

> **Epic**: economy
> **Status**: Ready
> **Layer**: Feature
> **Type**: Logic
> **Estimate**: M — 2 sessions (≤4h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-02

## Context

**GDD**: `design/gdd/economy.md`
**Requirement**: `TR-ECON-001`, `TR-ECON-002`, `TR-ECON-003`, `TR-ECON-004`, `TR-ECON-005`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0005 (Signal Bus & Event Routing); ADR-0006 (Economy Credit Interface)
**ADR Decision Summary**: Economy runs in TimeSystem's fixed order AFTER MemberSim/Congestion/Satisfaction. `balance` is an `int`. Revenue = flat fee `R_visit` ($12) per quota-met completed visit — via `member_completed_visit(member_id)` (S5) subscription. Only quota-met departures earn; walk-failure/patience-exhausted earn $0. Revenue contains ZERO reference to satisfaction (single-channel throughput decoupling). `starting_capital = $500`; balance floor = 0.

**Engine**: Godot 4.7.1 | **Risk**: LOW
**Engine Notes**: Integer money only — never float, no rounding drift. No RNG.

**Control Manifest Rules (Feature layer)**:
- Required: `member_completed_visit(member_id)` (S5) subscription — sole revenue trigger
- Required: `balance_changed(new_balance, delta)` (S6) emitted after every balance mutation with signed delta
- Required: two-phase deserialize; `balance: int` only
- Forbidden: no RNG; no mid-tick yielding

---

## Acceptance Criteria

*From GDD `design/gdd/economy.md`, scoped to this story:*

- [ ] AC1 Never negative: GIVEN a sequence of income and `spend` operations that includes at least one `spend(amount)` where `amount > balance`, WHEN applied, THEN `balance` is never < 0 at any point and the overspend call returns false
- [ ] AC8 Flat fee: GIVEN N `member_completed_visit` events, WHEN income accrues, THEN `balance` increases by exactly `N × R_visit`
- [ ] AC9 Multi-departure determinism: GIVEN multiple `member_completed_visit` events on one tick, WHEN income is applied, THEN the result is a single deterministic delta `N × R_visit` (sum is order-independent by construction)
- [ ] AC11 Starting capital: GIVEN `Economy.new()` (fresh-state constructor), WHEN `balance` is read immediately with no prior events, THEN `balance == 500`
- [ ] AC13 Income emits balance_changed: GIVEN a `member_completed_visit` event processed by Economy, WHEN revenue accrues, THEN `balance_changed(new_balance, +R_visit)` fires exactly once with a positive delta
- [ ] AC14 Only quota-met departures earn revenue: GIVEN a member that departed without meeting their exercise quota (walk-failure or patience-exhausted), WHEN Economy processes the departure, THEN no revenue accrues and no `balance_changed` fires

---

## Implementation Notes

*Derived from ADR-0005 + ADR-0006 Implementation Guidelines:*

**Core Rule 1 & 2 — tick order + revenue:**
- `on_tick(tick_context)` runs after Satisfaction; income reflects visits that resolved this tick
- `balance` is `int` — whole currency units, never float (no drift/rounding across ticks and saves)
- On `member_completed_visit(member_id)`: `balance += R_visit` ($12, safe 8–20), emit `balance_changed(new_balance, +R_visit)`
- **Only quota-met departures earn revenue** (AC14) — walk-in-leave (zero reachable equipment) or patience-exhausted earn $0
- Multiple departures on one tick → single deterministic delta `N × R_visit` (commutative sum, no fold order needed — AC9)

**Core Rule 3 — balance rules:**
- `starting_capital = $500` (AC11) — enough for two 1×1 machines at $200 each
- Floor of 0: defensive `max(0, balance)` (AC1) — never negative; never actually reached in normal flow because spending is pre-validated

**Core Rule 4 — no satisfaction reference (TR-ECON-004):**
- Revenue contains zero reference to `global_satisfaction` / `satisfaction_modifier`
- Satisfaction's economic influence flows entirely through member volume (arrivals), driven upstream — scaling revenue by satisfaction would double-count (more members × more $/member = runaway)

**Signal wiring (ADR-0005):**
- Subscribe to `member_completed_visit(member_id)` (S5) in `_post_init()`
- Emit `balance_changed(new_balance, delta)` (S6) after every balance mutation — signed delta for HUD animation

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 002]: spend()/can_afford triple-gating
- [Story 003]: credit() interface + no-satisfaction structural check
- [Story 004]: serialization + determinism + no-decay

---

## QA Test Cases

*Written by qa-lead at story creation. The developer implements against these — do not invent new test cases during implementation.*

- **AC1**: 永不为负
  - Given: income + spend sequence including an overspend (amount > balance)
  - When: applied
  - Then: balance never < 0 at any point; overspend call returns false
  - Edge cases: balance = 0 then spend; balance = 1 then spend(2)

- **AC8**: 平费用
  - Given: N member_completed_visit events
  - When: income accrues
  - Then: balance increases by exactly N × R_visit
  - Edge cases: N = 0, N = 1, N = 100

- **AC9**: 多会员确定性
  - Given: multiple member_completed_visit events on one tick
  - When: income applied
  - Then: single deterministic delta N × R_visit (order-independent by construction)
  - Edge cases: events processed in different orders → same result

- **AC11**: 初始资金
  - Given: Economy.new() fresh-state constructor
  - When: balance read immediately
  - Then: balance == 500
  - Edge cases: after deserialize with saved balance — not reset to 500

- **AC13**: 收入发信号
  - Given: member_completed_visit event processed
  - When: revenue accrues
  - Then: balance_changed(new_balance, +R_visit) fires exactly once, positive delta
  - Edge cases: multiple events → one signal per event, each +R_visit

- **AC14**: 仅配额达标计费
  - Given: member departed without meeting quota (walk-failure/patience-exhausted)
  - When: Economy processes the departure
  - Then: no revenue accrues; no balance_changed fires
  - Edge cases: walk-in-leave; patience-exhausted; quota-met (revenue fires)

---

## Test Evidence

**Story Type**: Logic
**Required evidence**:
- `tests/unit/economy/revenue_balance_test.gd` — must exist and pass (AC1, AC8, AC9, AC11, AC13, AC14)

**Status**: [ ] Not yet created

---

## Dependencies

- Depends on: member-sim epic story 005 (S5 signal emission), time-system epic (tick dispatch), ADR-0006 (credit interface — story 003)
- Unlocks: Story 002 (spend gating), Story 003 (credit), Story 004 (serialization)
