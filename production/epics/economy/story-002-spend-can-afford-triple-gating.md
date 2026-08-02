# Story 002: spend() and can_afford Triple-Gating

> **Epic**: economy
> **Status**: Ready
> **Layer**: Feature
> **Type**: Logic
> **Estimate**: S — 1 session (≤2h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-02

## Context

**GDD**: `design/gdd/economy.md`
**Requirement**: `TR-ECON-006`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0006 (Economy Credit Interface)
**ADR Decision Summary**: `spend(amount)` is triple-gated: (a) `amount > 0`, (b) `amount ≤ balance`, (c) Shop pre-checks with `can_afford` (defense in depth). Both `can_afford(amount)` and `spend(amount)` reject `amount ≤ 0` (return false, no-op — prevents a negative-amount exploit where `spend(-100)` would pass `amount ≤ balance` and increase balance). Emits `balance_changed(new_balance, delta)` after every mutation.

**Engine**: Godot 4.7.1 | **Risk**: LOW
**Engine Notes**: Integer arithmetic only; no engine API surface affected.

**Control Manifest Rules (Feature layer)**:
- Required: `balance_changed(new_balance, delta)` (S6) — signed delta for HUD animation direction
- Forbidden: `spend(-refund)` as a credit workaround — use `credit(amount, reason)` instead (story 003)
- Guardrail: balance floor 0; no ceiling

---

## Acceptance Criteria

*From GDD `design/gdd/economy.md`, scoped to this story:*

- [ ] AC2 Spend gating (overspend): GIVEN `spend(amount)` with `amount > balance`, WHEN called, THEN it returns false, `balance` is unchanged, and no `balance_changed` fires
- [ ] AC3 Spend gating (zero/negative): GIVEN `spend(0)` or `spend(-100)`, WHEN called, THEN it returns false, `balance` is unchanged, and no `balance_changed` fires (prevents negative-amount exploit)
- [ ] AC4 Spend success: GIVEN `spend(amount)` with `amount > 0` and `amount ≤ balance`, WHEN called, THEN it returns true, `balance -= amount`, and `balance_changed(new, -amount)` fires exactly once
- [ ] AC5 can_afford consistency: GIVEN `amount > 0`, WHEN `can_afford(amount)` is true, THEN a subsequent `spend(amount)` with no intervening change succeeds; when false, it fails. Also: `can_afford(0)` and `can_afford(-1)` return false

---

## Implementation Notes

*Derived from ADR-0006 Implementation Guidelines:*

**Core Rule 5 — spend interface:**
- `can_afford(amount) -> bool` and `spend(amount) -> bool`
- Both reject `amount ≤ 0` (return false, no-op) — prevents `spend(-100)` exploit (AC3)
- `spend()` triple-gated: (a) amount > 0, (b) amount ≤ balance, (c) Shop pre-checks via can_afford (defense in depth)
- Economy validates affordability but owns NONE of the purchase UX (that's Shop's)
- Emits `balance_changed(new_balance, delta)` for HUD — after every mutation, signed delta (AC4: -amount)

**AC5 consistency:**
- can_afford true → subsequent spend with no intervening change succeeds; false → fails
- can_afford(0) and can_afford(-1) return false

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 001]: balance + revenue (income path)
- [Story 003]: credit() interface (the mirror of spend)
- [Story 004]: serialization + determinism + no-decay

---

## QA Test Cases

*Written by qa-lead at story creation. The developer implements against these — do not invent new test cases during implementation.*

- **AC2**: 超支拒绝
  - Given: spend(amount), amount > balance
  - When: called
  - Then: returns false; balance unchanged; no balance_changed fires
  - Edge cases: amount = balance + 1; amount = balance + huge

- **AC3**: 零/负拒绝
  - Given: spend(0) or spend(-100)
  - When: called
  - Then: returns false; balance unchanged; no balance_changed fires
  - Edge cases: spend(0), spend(-1), spend(-100) — all rejected

- **AC4**: 成功消费
  - Given: spend(amount), amount > 0, amount ≤ balance
  - When: called
  - Then: returns true; balance -= amount; balance_changed(new, -amount) fires exactly once
  - Edge cases: spend exact balance → balance 0; multiple spends

- **AC5**: 一致性
  - Given: amount > 0
  - When: can_afford(amount) true → subsequent spend succeeds; false → fails
  - Then: consistent; can_afford(0) and can_afford(-1) return false
  - Edge cases: balance change between can_afford and spend (intervening income/spend)

---

## Test Evidence

**Story Type**: Logic
**Required evidence**:
- `tests/unit/economy/spend_gating_test.gd` — must exist and pass (AC2, AC3, AC4, AC5)

**Status**: [ ] Not yet created

---

## Dependencies

- Depends on: Story 001 (balance state, balance_changed emission)
- Unlocks: Story 004 (serialization), shop-purchase epic (consumer of spend/can_afford)
