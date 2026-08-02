# Story 003: credit() Interface and No-Satisfaction Structure

> **Epic**: economy
> **Status**: Ready
> **Layer**: Feature
> **Type**: Logic
> **Estimate**: S — 1 session (≤2h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-02

## Context

**GDD**: `design/gdd/economy.md`
**Requirement**: `TR-ECON-008`, `TR-ECON-004`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0006 (Economy Credit Interface)
**ADR Decision Summary**: `credit(amount: int, reason: String) -> bool` — the symmetric counterpart to `spend()`. Adds `amount` to balance, rejects `amount ≤ 0`, emits `balance_changed` with positive delta, `reason` audit-only. Refund formula owned by SelectionSystem, never Economy (Economy never knows equipment costs or refund rates). Never call `spend(-refund)` as a credit workaround.

**Engine**: Godot 4.7.1 | **Risk**: LOW
**Engine Notes**: Pure integer arithmetic; no engine dependency.

**Control Manifest Rules (Feature layer)**:
- Required: `credit(amount, reason) -> bool`; `reason` audit-only
- Required: refund formula owned by SelectionSystem, not Economy
- Forbidden: `spend(-refund)` as a credit workaround (blocked by design)
- Forbidden: refund rate in Economy (REFUND_RATE = 0.5 owned by SelectionSystem)

---

## Acceptance Criteria

*From GDD `design/gdd/economy.md`, scoped to this story:*

- [ ] AC7 No satisfaction dependency (structural check): GIVEN Economy's revenue path, WHEN a test double with `global_satisfaction` / `satisfaction_modifier` properties that throw-on-read is attached as a dependency, THEN calling revenue accrual N times never invokes any satisfaction accessor and `balance == starting_capital + N × R_visit`
- [ ] AC15 (integration, advisory) Progress never locks: GIVEN `balance = 0`, WHEN one `member_completed_visit` event is processed directly, THEN `balance == R_visit` and `can_afford(R_visit)` returns true. The upstream guarantee (satisfaction modifier floors at 0.5 → arrivals persist → completions eventually occur) is tested by Satisfaction's own integration suite, not duplicated here

*(credit() itself is defined by ADR-0006 — the implementation contract is in the ADR, with the structural no-satisfaction check here.)*

---

## Implementation Notes

*Derived from ADR-0006 Implementation Guidelines:*

**ADR-0006 §1 — credit method:**
```gdscript
func credit(amount: int, reason: String) -> bool:
    if amount <= 0:
        push_warning("Economy.credit() rejected: amount=%d must be > 0 (reason: %s)" % [amount, reason])
        return false
    balance += amount
    balance_changed.emit(balance, +amount)
    return true
```
- Rejects amount ≤ 0 (zero and negative) — symmetric with spend()
- Emits `balance_changed(new_balance, +amount)` on success
- `reason` is debug/audit-only label (e.g. "sell:instance_5") — no gameplay effect
- Works alongside `member_completed_visit` revenue path without conflict (both add money; neither reads the other)

**ADR-0006 §2 — symmetry:**
- Refund formula (`floor(0.5 × original_cost)`) owned by SelectionSystem's sell logic, NOT Economy — Economy accepts whatever amount the caller provides
- Economy never knows equipment prices or refund rates
- `balance` floor 0, no ceiling
- Never use `spend(-refund)` — blocked by spend()'s amount ≤ 0 guard (story 002)

**TR-ECON-004 — no satisfaction reference (AC7):**
- Structural check: test double with `global_satisfaction`/`satisfaction_modifier` properties that throw-on-read attached as dependency — revenue accrual N times never invokes any satisfaction accessor; balance == starting_capital + N × R_visit

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 001]: balance + revenue (income path)
- [Story 002]: spend()/can_afford gating
- [Story 004]: serialization + determinism + no-decay
- selection-system epic: the sell action + refund formula (consumer)

---

## QA Test Cases

*Written by qa-lead at story creation. The developer implements against these — do not invent new test cases during implementation.*

- **AC7**: 无满意度依赖结构检查
  - Given: test double with global_satisfaction/satisfaction_modifier properties that throw-on-read attached as dependency
  - When: revenue accrual called N times
  - Then: never invokes any satisfaction accessor; balance == starting_capital + N × R_visit
  - Edge cases: N = 0, N = 1, N = many — no accessor ever touched

- **AC15**: 永不锁死 (integration, advisory)
  - Given: balance = 0
  - When: one member_completed_visit processed directly
  - Then: balance == R_visit; can_afford(R_visit) returns true
  - Edge cases: after spend to zero; after multiple accruals

---

## Test Evidence

**Story Type**: Logic
**Required evidence**:
- `tests/unit/economy/credit_no_satisfaction_test.gd` — must exist and pass (AC7, AC15)

**Status**: [ ] Not yet created

---

## Dependencies

- Depends on: Story 001 (balance state, balance_changed emission), ADR-0006 (already Accepted)
- Unlocks: Story 004 (serialization), selection-system epic (sell action consumes credit)
