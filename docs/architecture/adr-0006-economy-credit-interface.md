# ADR-0006: Economy Credit Interface — Sell-Back Revenue Contract for SelectionSystem

## Status
Accepted

**Gate**: ADR-0005 Accepted (depends-on cleared) 2026-07-22. Knowledge Risk LOW — pure integer arithmetic, no engine dependency.

## Date
2026-07-21

## Engine Compatibility

| Field | Value |
|-------|-------|
| **Engine** | Godot 4.7.1 |
| **Domain** | Core / Gameplay (economy interface contract) |
| **Knowledge Risk** | LOW — pure GDScript logic, no engine API surface affected |
| **References Consulted** | `docs/engine-reference/godot/VERSION.md`, `design/gdd/economy.md`, `design/gdd/selection-system.md`, `design/gdd/shop-purchase.md`, `docs/architecture/adr-0005-signal-bus-event-routing.md` |
| **Post-Cutoff APIs Used** | None |
| **Verification Required** | None — pure integer arithmetic, no engine dependency |

## ADR Dependencies

| Field | Value |
|-------|-------|
| **Depends On** | ADR-0005 (Signal Bus — `balance_changed` signal is emitted by both `credit()` and `spend()`; `member_completed_visit` signal is the other revenue path) |
| **Enables** | SelectionSystem implementation (sell action), Shop implementation (refund display), any future system that adds money (milestone rewards, etc.) |
| **Blocks** | SelectionSystem sell story — cannot credit refunds without this interface |
| **Ordering Note** | Must be Accepted before SelectionSystem (#13) implementation begins |

## Context

### Problem Statement

Economy currently has two money-modifying paths: **internal revenue** via the
`member_completed_visit` signal (MemberSim → Economy, flat $12 per completed visit)
and **external spend** via `spend(amount)` (Shop calls this to buy equipment).
But there is no external path to **add** money. SelectionSystem's sell action
(Core Rule 7: "sell returns refund") needs to credit a refund to the player's
balance — and Economy, as the sole owner of `balance`, must provide the method
that performs the credit.

Without a defined `credit()` interface, SelectionSystem would either:
- Directly write `Economy.balance += refund` (violates state ownership — forbidden
  pattern `direct_cross_system_state_write` in ADR-0001)
- Call `spend(-refund)` as a workaround (hack — `spend()` is semantically a
  deduction, and a negative spend is a loophole that `spend()` already guards against)

This ADR formalizes the missing half of Economy's public interface: a symmetric
`credit()` method that is the mirror of `spend()`.

### Constraints

- `balance` is an `int` (economy.md Core Rule 1) — whole currency units only,
  no floating-point rounding
- `spend()` already triple-gates: `amount > 0`, `amount ≤ balance`, Shop
  pre-checks via `can_afford()`. `credit()` must have symmetric safety gates.
- Economy owns `balance` exclusively — no other system may write it directly
  (state ownership, ADR-0001)
- The refund formula (`refund = floor(0.5 × original_cost)`) is owned by
  SelectionSystem's sell logic, not Economy — Economy's `credit()` accepts
  whatever amount the caller provides (Economy doesn't know equipment prices)
- `balance` has a floor of 0 (defensive `max(0, balance)`) but **no ceiling** —
  there is no meaningful upper bound on how rich a player can get
- Per ADR-0005: `balance_changed(new_balance, delta)` is emitted after every
  balance mutation, including credit

### Requirements

- Economy exposes a `credit(amount: int, reason: String) -> bool` method
- The method validates `amount > 0` (rejects zero and negative)
- The method emits `balance_changed` after mutation, just as `spend()` does
- The `reason` parameter is for debugging/audit only — no gameplay effect
- SelectionSystem computes the refund amount externally and passes it to
  `credit()` — Economy does not know equipment costs or refund rates
- The method works alongside the existing `member_completed_visit` revenue
  path without conflict (both paths add money; neither reads the other)

## Decision

### 1. New Method: `Economy.credit(amount: int, reason: String) -> bool`

```gdscript
## Credits money to the player's balance. Returns true on success.
## Rejects amount <= 0 (returns false, no-op).
## Emits balance_changed(new_balance, +amount) on success.
## reason is an audit-only label (e.g. "sell:instance_5") — no gameplay effect.
func credit(amount: int, reason: String) -> bool:
    if amount <= 0:
        push_warning("Economy.credit() rejected: amount=%d must be > 0 (reason: %s)" % [amount, reason])
        return false

    balance += amount
    balance_changed.emit(balance, +amount)
    _log("credit", amount, reason)   # debug-only, stripped in release
    return true
```

### 2. Symmetry with `spend()`

| Aspect | `spend(amount)` | `credit(amount, reason)` |
|--------|-----------------|--------------------------|
| **Direction** | `balance -= amount` | `balance += amount` |
| **Amount gate** | `amount > 0` | `amount > 0` |
| **Affordability gate** | `amount ≤ balance` | None (no upper limit) |
| **Returns** | `bool` | `bool` |
| **Emits** | `balance_changed(new, -amount)` | `balance_changed(new, +amount)` |
| **Callers** | Shop/Purchase (#12) | SelectionSystem (#13), future milestone rewards |
| **Defense** | Triple-gated (positive, affordable, can_afford pre-check) | Double-gated (positive, balance is unbounded above) |

The asymmetry is intentional: `spend()` checks affordability because the
player must have the money; `credit()` has no analogous "can this be
credited?" check because there is no balance ceiling.

### 3. Refund Formula Owned by SelectionSystem, Not Economy

SelectionSystem computes the refund before calling `credit()`:

```gdscript
# In SelectionSystem.sell():
var original_cost := _catalog.get_definition(equipment_id).cost
var refund := int(floor(original_cost * REFUND_RATE))   # REFUND_RATE = 0.5
_economy.credit(refund, "sell:instance_%d" % instance_id)
```

Economy never knows the refund rate, original cost, or equipment definition.
This keeps Economy a pure "ledger" — it validates the arithmetic properties
of the transaction (amount > 0) but not the business rules (refund rate).
The refund rate is a SelectionSystem concern, documented in
selection-system.md Core Rule 7.

### 4. Relationship with `member_completed_visit` Revenue

Two revenue paths now exist:

```
Path A (internal, signal-driven):
  MemberSim → member_completed_visit(member_id) [S5]
           → Economy.on_member_completed_visit()
           → balance += R_visit ($12)
           → balance_changed.emit(new, +12)

Path B (external, direct call):
  SelectionSystem → Economy.credit(refund, "sell:instance_N")
                 → balance += refund
                 → balance_changed.emit(new, +refund)
```

Both paths:
- Add money (not spend)
- Emit `balance_changed` with positive delta
- Are mutually independent — neither reads the other's state
- Can fire on the same tick without conflict (both are pure additions; sum is
  commutative)

The `reason` string on `credit()` distinguishes Path B from Path A in
debug logs — Path A is always `member_completed_visit`, Path B carries
an explicit reason like `"sell:instance_5"`.

### Architecture Diagram

```
┌──────────────────────────────────────────────────────────────┐
│  Economy (RefCounted)                                         │
│  ┌────────────────────────────────────────────────────────┐  │
│  │  balance: int  (floor 0, no ceiling)                    │  │
│  │                                                         │  │
│  │  == Revenue paths (both add money) ==                    │  │
│  │                                                         │  │
│  │  Path A: signal-driven (internal)                       │  │
│  │    MemberSim.member_completed_visit ──signal──→         │  │
│  │    Economy._on_member_completed_visit(id)               │  │
│  │    balance += R_visit  ($12 flat)                       │  │
│  │                                                         │  │
│  │  Path B: direct call (external — THIS ADR)              │  │
│  │    SelectionSystem.sell()                               │  │
│  │      refund = floor(0.5 × original_cost)                │  │
│  │      Economy.credit(refund, "sell:instance_N")          │  │
│  │      balance += refund                                  │  │
│  │                                                         │  │
│  │  == Spend path ==                                       │  │
│  │    Shop → Economy.spend(amount)                         │  │
│  │    balance -= amount  (guarded: >0, ≤balance)           │  │
│  │                                                         │  │
│  │  == Common output ==                                    │  │
│  │    balance_changed.emit(new_balance, delta)  [S6]       │  │
│  │      → HUD (update display)                             │  │
│  │      → Shop (recheck can_afford for displayed items)    │  │
│  └────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────┘
```

### Key Interfaces

| Interface | Signature | Notes |
|-----------|-----------|-------|
| Credit | `Economy.credit(amount: int, reason: String) -> bool` | Adds `amount` to balance. Rejects `≤ 0`. Emits `balance_changed` with positive delta. |
| Spend | `Economy.spend(amount: int) -> bool` | Existing. Deducts `amount`. Triple-gated. Emits `balance_changed` with negative delta. |
| Affordability | `Economy.can_afford(amount: int) -> bool` | Existing. Pure query, no mutation. Used by Shop for pre-check. |
| Balance signal | `Economy.balance_changed(new_balance: int, delta: int)` | Existing (cataloged as S6). Emitted by both `credit()` and `spend()`. Signed `delta` lets HUD animate direction. |
| Refund rate | `REFUND_RATE = 0.5` (constant in SelectionSystem) | SelectionSystem-owned. Not known to Economy. |

## Alternatives Considered

### Alternative 1: `spend(-refund)` — Negative Spend Workaround

- **Description**: SelectionSystem calls `spend(-refund)` which, if `spend()`
  doesn't validate sign, would add money (negative × negative = positive).
- **Pros**: No new method on Economy. One fewer API surface.
- **Cons**: `spend()` already explicitly guards `amount ≤ 0` (economy.md Core
  Rule 5: "rejects amount ≤ 0"). Calling `spend(-100)` would hit that guard
  and return false — the workaround doesn't work by design. Relaxing the guard
  to allow negative spends would turn `spend()` into a general-purpose
  `adjust_balance()` with ambiguous semantics — is `spend(-100)` a credit or
  a refund? Debug logs would show "spend -100" which is confusing.
- **Rejection Reason**: `spend()` is semantically a deduction. Forcing a credit
  through it is a semantic mismatch, and the existing `amount > 0` guard already
  prevents it. Adding a separate `credit()` keeps the API self-documenting.

### Alternative 2: Economy Owns the Refund Formula

- **Description**: `Economy.refund(equipment_id: String) -> bool` — Economy
  looks up the equipment cost from EquipmentCatalog, computes the refund, and
  credits the balance. SelectionSystem just calls `Economy.refund(id)`.
- **Pros**: Refund logic is centralized — if the refund rate changes, only
  Economy changes.
- **Cons**: Economy would need a dependency on EquipmentCatalog (it currently
  has none — only TimeSystem + MemberSim). This adds a new dependency solely
  for the refund formula. Economy is a pure ledger — it shouldn't know about
  equipment costs. The refund rate is a game design parameter, not an economic
  invariant.
- **Rejection Reason**: Violates Economy's single-responsibility principle
  (pure ledger). SelectionSystem already holds the equipment_id and can look
  up the cost from its own EquipmentCatalog reference — it's one line of code.
  Adding an EquipmentCatalog dependency to Economy for this one use case is
  worse than having SelectionSystem compute the refund.

### Alternative 3: Refund as Negative Spend with a Separate Method Name

- **Description**: `Economy.earn(amount)` — same as `credit()` but uses
  "earn" naming to match the `balance_changed` signal semantics.
- **Pros**: "Earn" vs "credit" naming preference.
- **Cons**: "Credit" is standard accounting terminology (credit = add to account,
  debit = remove from account). "Earn" implies the money was worked for, which
  fits revenue (Path A) but not refunds. Using `credit()` for both refunds and
  future milestone rewards keeps the method generic.
- **Rejection Reason**: Minor naming preference — `credit()` is more general
  and fits all non-revenue money-add use cases (refunds, milestone rewards,
  debug commands).

## Consequences

### Positive

- Economy's public interface is now symmetric: `spend()` for deductions,
  `credit()` for additions. Both emit `balance_changed`.
- SelectionSystem's sell action has a clean, debuggable money path —
  `credit(refund, "sell:instance_N")` is self-documenting in logs.
- The `reason` parameter enables future audit tooling (transaction history,
  "where did my money go?") without changing the interface.
- Future money-adding systems (milestone rewards, achievement bonuses) use
  the same `credit()` method — no new API needed.
- Zero engine risk — pure integer arithmetic, no Godot API dependency.

### Negative

- Two revenue paths (signal-driven via `member_completed_visit` and direct-call
  via `credit()`) could confuse implementors about which to use. Mitigation: the
  distinction is clear — signal-driven is for recurring per-member revenue,
  direct-call is for one-shot external credits.
- `credit()` does not validate the business logic of the amount — a buggy
  caller could credit $1,000,000. Mitigation: GUT tests on the caller side
  (SelectionSystem sell test) verify the refund amount. Economy's job is
  arithmetic correctness, not business-rule enforcement.

### Risks

- **Risk**: A future system calls `credit()` with a negative amount (bug).
  **Mitigation**: `amount ≤ 0` guard rejects it with `push_warning()`. The
  guard is covered by a GUT test.
- **Risk**: `credit()` and `member_completed_visit` fire on the same tick
  and their `balance_changed` emissions are indistinguishable to HUD.
  **Mitigation**: Both carry positive deltas — HUD sums them or processes
  them sequentially. The `reason` string is available for debug differentiation
  but has no gameplay effect.

## GDD Requirements Addressed

| GDD System | Requirement | How This ADR Addresses It |
|------------|-------------|--------------------------|
| economy.md | Core Rule 5: spend interface — `spend(amount) -> bool` triple-gated | Complements `spend()` with symmetric `credit()` — the missing addition counterpart |
| economy.md | OQ3: Shop #12 needs to call Economy to spend money; sell path needs reverse (credit) | Defines `credit()` as the sell-back money path — Shop's OQ3 was about purchase; this is the sell-side counterpart |
| economy.md | AC13: `balance_changed` emits on revenue — `balance_changed(new, +R_visit)` on `member_completed_visit` | Extends `balance_changed` emission to `credit()` — HUD receives a unified signal for all balance changes |
| selection-system.md | Core Rule 7: sell requires Economy credit path — "SelectionSystem therefore needs Economy to expose a credit/earn path for sell-backs" | Defines exactly that path: `credit(amount, reason)` with the refund computed by SelectionSystem |
| selection-system.md | Core Rule 7: refund = 0.5 × cost, integer floor — "sell returns refund to the player" | SelectionSystem computes `floor(0.5 × cost)` and passes it to `credit()`; Economy does not own the refund rate |
| selection-system.md | Dependencies: Economy (credit — "GAP") | Closes the gap — SelectionSystem's Economy dependency changes from "credit (gap)" to "credit(amount, reason)" |
| shop-purchase.md | Deduct-on-commit — "only deduct when placement is committed, not when drag starts" | Unrelated to credit, but `credit()` + `spend()` give Economy a complete external transaction interface that Shop and SelectionSystem share |

## Performance Implications

- **CPU**: `credit()` is one integer addition + one signal emit + one optional
  debug log. <1µs. Identical cost to `spend()`.
- **Memory**: The `reason` string is typically short (<30 chars) and
  garbage-collected after the call. Negligible.
- **Load Time**: None — Economy already exists at init.
- **Network**: N/A.

## Migration Plan

This is a greenfield addition to an existing (but unimplemented) interface.
No code to migrate.

If Economy is implemented before this ADR is Accepted, the `credit()` method
can be added as a single method without changing any existing `spend()` or
`can_afford()` behavior.

## Validation Criteria

1. **Positive amount**: `credit(100, "test")` returns true, balance increases
   by 100, `balance_changed` emits with `+100`.
2. **Zero rejected**: `credit(0, "test")` returns false, balance unchanged,
   no `balance_changed` emitted.
3. **Negative rejected**: `credit(-50, "test")` returns false, balance
   unchanged, `push_warning` triggered.
4. **Spend + credit symmetry**: After `spend(200)` then `credit(50, "refund")`,
   balance is `starting_capital - 150`, and `balance_changed` emitted twice
   (once with `-200`, once with `+50`).
5. **SelectionSystem integration**: A GUT test constructs SelectionSystem +
   Economy, places a $200 equipment, sells it → Economy receives
   `credit(100, "sell:instance_1")` and balance reflects `+100`.
6. **Coexistence with visit revenue**: A GUT test triggers both
   `member_completed_visit` (+$12) and `credit(100, "refund")` in the same
   tick → balance increases by $112, `balance_changed` emitted twice.

## Related Decisions

- **ADR-0005** (Signal Bus): `balance_changed` (S6) is the signal emitted by
  both `credit()` and `spend()` — HUD and Shop subscribe to it.
- **ADR-0001** (DI Container): Economy's `init(time, member_sim)` receives
  its dependencies; the `member_completed_visit` signal connection is set up
  in `_post_init()`.
- **ADR-0004** (Seeded RNG): Economy is deterministic (no RNG) — neither
  `credit()` nor `spend()` consumes randomness.
