# QA Evidence — SEL-003: Sell Flow (Soft-Confirm + Refund)

> **Story**: production/epics/selection-system/story-003-sell-flow-soft-confirm.md
> **Epic**: selection-system (Presentation layer)
> **Date**: 2026-08-07
> **Engine**: Godot 4.7.1 (headless-verified)
> **Story Type**: Logic — evidence = automated assertions (BLOCKING)

## Summary

The confirmed-sale path is complete and merged on main: pressing Sell opens a
**2 s soft-confirm window** ("Confirm sell +$X" — warm Butter, never an alarm
tone); a second click inside the window removes the piece, credits Economy
the refund **exactly once**, and clears the selection; 2 s of silence, Esc,
or click-away reverts to the normal Sell button — **no destructive default**
(Core Rule 4, TR-SEL-003/009).

The refund is `int(round(REFUND_RATE × cost))` with `REFUND_RATE = 0.5`
(SelectionSystem-owned per ADR-0006 Key Interfaces), an explicit `int()`
cast (GDScript `round()` returns float), and ties rounding away from zero
(cost 201 → `int(round(100.5))` = 101, AC15). Cost-0 pieces sell cleanly
with refund 0 and **no credit call** (Economy rejects `amount <= 0`; the
sale still completes, AC13). Selling a machine a member is using is
**allowed** (MemberSim handles equipment-deleted-mid-use gracefully — Pillar
2; no block).

**History note**: the original SEL-003 branch (wt/t_e4e62360) completed this
story with a DIFFERENT bridge API (`on_sell_pressed`/`on_sell_confirmed`)
that was never merged to main. Main's bridge (t_d0255555) uses
`request_sell_confirm()`/`confirm_sell()` and already carried the three sell
signals (`sell_confirm_started`/`reverted`/`confirmed`). The SEL-003 port
landed inside the SEL-004 implementation commit **1552a5d**, binding the
MERGED names.

| File | Class | Change |
|------|-------|--------|
| `src/systems/selection_system.gd` | `SelectionSystem` | `REFUND_RATE := 0.5` const (SelectionSystem-owned per ADR-0006 Key Interfaces); optional `economy` 4th init param; `sell_selected() -> bool` (the confirmed sale: refund formula with explicit `: int` + `int()` cast, phantom guard, `GridSystem.clear` removal, `Economy.credit(refund, "sell:instance_<id>")` EXACTLY ONCE, skips the call when refund == 0); `get_sell_refund(def)` — the toolbar's "+$X" label reads the SAME formula `sell_selected` applies |
| `src/systems/selection_input_bridge.gd` | `SelectionInputBridge` | (SEL-002, merged) owns the 2s soft-confirm timer: `request_sell_confirm()` (pending flag + generation-bumped timer + `sell_confirm_started`), `confirm_sell()` (cancels pending + emits `sell_confirm_confirmed`), `_on_sell_confirm_timeout(generation)` (generation-guarded revert), `_revert_sell_confirm()` (shared by timeout/Esc/click-away, emits `sell_confirm_reverted`), Del routes through the SAME `request_sell_confirm()` path (no instant destructive sale) |
| `src/systems/simulation_orchestrator.gd` | `SimulationOrchestrator` | Passes `economy` into `SelectionSystem.init(..., economy)`; connects `sel_bridge.sell_confirm_confirmed → selection_system.sell_selected` (typed, Control Manifest) |
| `src/systems/economy.gd` | `Economy` | `credit(amount: int, reason: String) -> bool` (ECON-003, pre-existing): `amount > 0` gate (rejects zero/negative), synchronous + immediate, emits `balance_changed(new, +amount)`; never computes refunds itself |
| `tests/unit/selection_system/sell_flow_test.gd` | — | 64 asserts — soft-confirm window, refund formula incl. .5 boundary, cost-0, retired-id, guards (registered in TEST_FILES) |

Automated coverage: **64 new asserts, 0 failed** (`tests/unit/selection_system/sell_flow_test.gd`,
registered in `tests/headless_runner.gd` TEST_FILES).
Full suite: **5028 passed, 0 failed** (4877 pre-existing + 64 sell_flow +
60 toolbar + 27 cue — the sell_flow file ran in the SEL-004 verification).

## Blocking AC Verification

### AC5/AC6 — 软确认窗口
GIVEN a selection, WHEN the player clicks Sell, THEN the button shows
"Confirm sell +$X" for 2 s; a second click in that window removes the piece,
credits Economy the refund, and clears the selection. 2 s with no second
click reverts to the normal Sell button — no sale, no destructive default.

Automated (`sell_flow_test.gd`):
- request (Sell pressed) → `is_sell_confirm_pending() == true` +
  `sell_confirm_started` emitted once; no selection → request is a no-op
  (returns false)
- second click within the window: `confirm_sell()` → `sell_confirm_confirmed`
  → `sell_selected()` → piece removed from the grid (`get_occupant_id == -1`),
  `selection_changed(null)` fired, `get_selected_instance_id() == -1`
- confirm at the boundary (1.9 s-ish — pending still open) → sale proceeds
- timeout exactly at the window end: `_on_sell_confirm_timeout(current gen)`
  → pending cleared, `sell_confirm_reverted`, NO sale (piece stays on the
  grid), NO balance change, selection stays
- Esc cancels a pending window: same revert, no sale
- stale-timer guard: a timeout from a cancelled/confirmed window
  (generation mismatch) is a silent no-op — can never revert a NEWER window
- double-confirm guard: the second `confirm_sell()` after the first resolved
  is a no-op → credit fires exactly once

### AC7 — 退款公式
GIVEN cost C and refund_rate 0.5, WHEN the sell resolves, THEN balance
increases by exactly `int(round(0.5 × C))` — integer credit, credit fires
EXACTLY ONCE (AC7), `balance_changed` fires once with a positive delta, and
the reason is `"sell:instance_<id>"`.

Automated:
- C=200 → refund 100 (`int(round(100.0))`)
- C=350 → refund 175 (`int(round(175.0))`)
- credit called exactly once per confirmed sale (double-confirm guard
  re-verified here); `balance_changed` delta == +refund
- `get_sell_refund(def)` returns the identical value `sell_selected`
  applies (single source of the formula)

### AC13 — 免费件
GIVEN a piece with cost = 0, WHEN sold, THEN refund = 0, the piece is
removed, Economy is credited 0 (no credit call — the `amount > 0` gate would
reject it with a warning; skipping completes the sale "credited 0
harmlessly"), and `selection_changed(null)` fires.

Automated:
- sale completes: piece removed from grid, `selection_changed(null)` emitted,
  `get_selected_instance_id() == -1`
- Economy balance UNCHANGED and `balance_changed` NOT emitted (no zero-
  credit noise)

### AC14 — 退役 id
GIVEN an instance_id that was sold, WHEN the retired id is queried, THEN it
does not resolve — the mapping entry is removed on sell (via the
grid_changed reconciliation path), and ids are never reissued within a
session.

Automated:
- after sale, `_grid.get_occupant_id(anchor) == -1` (piece gone) and the
  mapping no longer contains the retired id
- a new placement after the sale reuses a FUTURE id (`instance_id` strictly
  greater — no collision with the retired one); clicking the new piece
  resolves the new id, not the retired one

### AC15 — 奇数值边界
GIVEN refund_rate 0.5 and cost 201, WHEN the sell resolves, THEN refund =
`int(round(100.5))` = 101 — ties round away from zero (GDScript `round()`
behaviour), returned as an int (explicit `: int` type + `int()` cast).

Automated: cost 201 → refund == 101, `typeof(refund) == TYPE_INT`, balance
increases by exactly 101.

## Test Evidence

| File | Asserts | Scope |
|------|---------|-------|
| `tests/unit/selection_system/sell_flow_test.gd` | 64 | AC5 confirm removes/credits/clears + boundary confirm; AC6 timeout/Esc revert (no sale, no balance change, selection stays — no destructive default); AC7 exact integer refunds (200→100, 350→175) + credit-once + reason; AC13 cost-0 clean completion (no credit call); AC14 retired id + future-id reuse; AC15 odd .5 tie (201→101); guards (no-selection no-op, no-economy loud error, confirm-without-pending no-op, double-confirm) |

Registered in `tests/headless_runner.gd` TEST_FILES.

**Full headless suite: 5028 passed, 0 failed** (4877 pre-existing + 151 new
across SEL-004's three files: sell_flow 64 + toolbar 60 + cue 27; the
runner's registry check enforces that every `*_test.gd` on disk is
registered — no unregistered file can pass silently).

## Decisions & Notes

- **SEL-003 port adapted to the merged bridge API**: the original task
  branch (wt/t_e4e62360) used `on_sell_pressed()`/`on_sell_confirmed()`
  which were NEVER merged; main's bridge (t_d0255555) uses
  `request_sell_confirm()`/`confirm_sell()`. The sell-flow test binds the
  MERGED names. The three sell signals
  (`sell_confirm_started`/`reverted`/`confirmed`) already existed on main's
  bridge; the port added `sell_selected()` + `REFUND_RATE` + economy
  injection + orchestrator wiring.
- **Refund formula lives in SelectionSystem, not Economy** (ADR-0006 §3 /
  Key Interfaces row: "REFUND_RATE = 0.5 (constant in SelectionSystem) —
  SelectionSystem-owned. Not known to Economy."). The ECON-003 structural
  test pins refund knowledge out of economy.gd; `Economy.credit()` accepts
  whatever amount the caller provides.
- **Cost-0 completes without the credit call** — `credit(0)` is rejected by
  Economy's `amount > 0` gate (returns false + push_warning); GDD says
  "credited 0 harmlessly — the sale still completes", and skipping is the
  no-warning way to complete it (AC13).
- **Selling in use is allowed** (Pillar 2): MemberSim handles
  equipment-deleted-mid-use gracefully (member reselects); no block in
  `sell_selected()`.
- **The 2s window is UI-layer state**: the bridge owns the timer
  (generation-bumped, render-time via `create_timer(duration, true)` so it
  elapses in real seconds even while paused); SelectionSystem owns the
  confirmed sale — the composition root's typed connection joins them.

## Sign-off

- [x] Automated: full headless suite 5028 passed, 0 failed
- [x] AC5 / AC6 / AC7 / AC13 / AC14 / AC15 covered by automated state
      assertions (64 asserts in `sell_flow_test.gd`)
- [ ] Manual desktop walkthrough (pending interactive session — toolbar
      morph rendering is Story 004's surface; this story's logic is fully
      covered headlessly)
