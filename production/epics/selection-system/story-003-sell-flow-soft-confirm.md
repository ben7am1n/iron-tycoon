# Story 003: Sell Flow (Soft-Confirm + Refund)

> **Epic**: selection-system
> **Status**: Complete — 2026-08-07 (implementation + headless QA PASS, 5028/0)
> **Layer**: Presentation
> **Type**: Logic
> **Estimate**: M — 2 sessions (≤4h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-06

## Context

**GDD**: `design/gdd/selection-system.md`
**Requirement**: `TR-SEL-003`, `TR-SEL-009` (Del→soft-confirm wired in Story 002; the confirm state machine lives here)
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0005 (Signal Bus & Event Routing); ADR-0006 (Economy Credit Interface)
**ADR Decision Summary**: Sell credits the refund via `Economy.credit(amount: int, reason: String) -> bool` — synchronous, mirrors `spend()`, rejects `amount <= 0`, emits `balance_changed` on success (implemented in Sprint 4 as ECON-003). `refund = int(round(refund_rate × cost))` with `refund_rate` provisional 0.5 (Economy-owned). The 2s soft-confirm window is UI-layer state (bridge owns the timer).

**Engine**: Godot 4.7.1 | **Risk**: LOW
**Engine Notes**: Pure logic + one signal emit; `int(round(x))` cast is required (GDScript `round()` returns float). GDScript `round()` rounds ties away from zero (0.5 → 1).

**Control Manifest Rules (Presentation layer)**:
- Required: typed signal connections only
- Forbidden: string-based signal connections

---

## Acceptance Criteria

*From GDD `design/gdd/selection-system.md`, scoped to this story:*

- [x] AC5 GIVEN a selection, WHEN the player clicks Sell, THEN the button shows "Confirm sell +$X" for 2 s; if clicked again in that window, the piece is removed, Economy is credited `refund`, and selection clears
- [x] AC6 GIVEN the sell-confirm window is open, WHEN 2 s elapse with no second click, THEN it reverts to the normal Sell button (no destructive default)
- [x] AC7 GIVEN a completed sell of a piece with cost `C`, WHEN it resolves, THEN Economy's balance increases by exactly `int(round(refund_rate × C))` (credit fires once) — integer credit, matching Economy's `int`-based balance
- [x] AC13 GIVEN a piece with `cost = 0`, WHEN sold, THEN `refund = 0`, the piece is removed, Economy is credited 0, and `selection_changed(null)` fires — the sale completes cleanly with no money effect
- [x] AC15 GIVEN `refund_rate = 0.5` and `cost = 201` (odd value), WHEN the sell resolves, THEN `refund = int(round(100.5)) = 101` — ties round away from zero
- [x] AC14 GIVEN an `instance_id` that was sold, WHEN the retired id is queried, THEN it does not resolve (mapping entry removed on sell; ids never reissued within a session)

---

## Implementation Notes

*Derived from ADR-0005 + ADR-0006 + GDD Core Rule 4:*

**Sell flow — gentle, not punishing (Core Rule 4)**:
- Pressing Sell morphs the button into a 2 s "Confirm sell +$X" state (warm Butter tone — the money color, NEVER Dusty Rose/alarm)
- Auto-reverts if not clicked within 2 s, or on Esc/click-away (no destructive default)
- On confirm: piece fades out gently (~300 ms — no destruction particles/sound), Economy credited the refund, selection clears

**Refund formula (Formulas section, TR-SEL-003)**:
- `refund = int(round(refund_rate × EquipmentCatalog.get_definition(equipment_id).cost))`
- `refund_rate` provisional 0.5 (Economy-owned — read the value from Economy/config, not hardcoded where avoidable)
- `int()` cast REQUIRED — Economy.credit takes int
- Boundary: cost 350 → 175.0 → 175; cost 201 → 100.5 → 101 (ties away from zero)
- cost 0 → refund 0; sale still completes, Economy credited 0, `selection_changed(null)` fires

**Credit call (ADR-0006)**:
- `Economy.credit(refund, "sell:instance_<id>")` — synchronous and immediate (mirrors spend()'s timing, not tick-batched) so balance/HUD feedback is instant
- Credit fires EXACTLY ONCE per confirmed sell (AC7)
- `credit()` rejects amount ≤ 0 (returns false, no-op) — so the cost-0 path must skip the call OR handle the false return; GDD says credited 0 harmlessly — the sale still completes

**Mapping removal (AC14)**: the `instance_id → data` mapping entry is removed on sell; `instance_id`s are never reissued within a session (GridSystem contract). A retired id does not resolve.

**Selling a machine in use**: allowed — MemberSim handles equipment-deleted-mid-use gracefully (member reselects); no block (Pillar 2).

**4.7.1 pitfalls**:
- `round()` returns float → explicit `int()` cast (AC7/AC15)
- `var x := expr` fails on Variant returns → explicit `: int` for refund computations

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 001]: selection logic core (this story adds the sell action on top)
- [Story 002]: bridge timer (fires the revert callback), Del key (triggers the same confirm)
- [Story 004]: toolbar Control rendering (the morph animation is driven by this story's state machine but rendered there)

---

## QA Test Cases

*Derived from GDD acceptance criteria. Logic story — automated coverage required (BLOCKING).*

- **AC5/AC6**: 软确认窗口
  - Given: a selection; Sell pressed
  - When: button shows "Confirm sell +$X" for 2 s
  - Then: second click in window → piece removed, Economy credited refund once, selection clears; 2 s timeout → reverts to Sell, no sale, no balance change
  - Edge cases: confirm at 1.9s (sale proceeds); timeout exactly at 2s; Esc cancels

- **AC7**: 退款公式
  - Given: cost C, refund_rate 0.5
  - When: sell resolves
  - Then: balance increases by exactly int(round(0.5 × C)); credit fires once
  - Edge cases: C=350 → 175; C=201 → 101; C=200 → 100

- **AC13**: 免费件
  - Given: cost = 0 piece
  - When: sold
  - Then: refund = 0; piece removed; Economy credited 0; `selection_changed(null)` fires
  - Edge cases: credit(0) rejected by Economy — handle as no-op success

- **AC14**: 退役 id
  - Given: an instance_id sold
  - When: the retired id is queried
  - Then: does not resolve (mapping entry removed)
  - Edge cases: new placement reuses a future id — no collision with the retired one

- **AC15**: 奇数值边界
  - Given: refund_rate 0.5, cost 201
  - When: sell resolves
  - Then: refund = int(round(100.5)) = 101 (ties away from zero, int)

---

## Test Evidence

**Story Type**: Logic
**Required evidence**:
- [x] `tests/unit/selection_system/sell_flow_test.gd` — 64 asserts, registered in `tests/headless_runner.gd` TEST_FILES:
  - AC5/AC6 soft-confirm window: request → pending + `sell_confirm_started`; second click → `confirm_sell` → `sell_confirm_confirmed` → `sell_selected` (piece removed, Economy credited EXACTLY once, `selection_changed(null)`); 2s timeout / Esc / click-away → revert, no sale, no balance change, selection stays
  - AC7 refund formula: C=200 → 100, C=350 → 175, credit-once + reason `"sell:instance_<id>"`, `balance_changed` positive delta once
  - AC13 cost-0: refund 0, piece removed, `selection_changed(null)`, Economy NOT credited (skip — credit(0) rejected by Economy's amount > 0 gate)
  - AC14 retired id: after sale the instance_id does not resolve (mapping entry removed via grid_changed reconciliation); a new placement reuses a FUTURE id — no collision
  - AC15 odd boundary: cost 201 → `int(round(100.5))` = 101 (ties away from zero; explicit `: int` + `int()` cast)
  - Guards: confirm without pending window = no-op; double-confirm = credit once; sell with no selection = silent no-op; sell without injected Economy = loud wiring error

**Status**: [x] Complete — headless suite 5028 passed, 0 failed (4877 pre-existing + 64 sell_flow; the SEL-003 port landed inside the SEL-004 implementation commit 1552a5d — the parent branch's `on_sell_pressed`/`on_sell_confirmed` naming was never merged; the port binds the MERGED bridge API `request_sell_confirm`/`confirm_sell`)

**Composition wiring**: `SimulationOrchestrator` passes `economy` into `SelectionSystem.init(..., economy)` and connects `sel_bridge.sell_confirm_confirmed → selection_system.sell_selected` (typed, Control Manifest). The bridge owns the 2s soft-confirm timer (generation-guarded, render-time via `create_timer(duration, true)`); SelectionSystem owns the refund formula (`REFUND_RATE = 0.5`, SelectionSystem-owned per ADR-0006 Key Interfaces), the grid removal (`GridSystem.clear` → grid_changed reconciliation drops the mapping entry — AC14 — and clears the selection — AC5/AC13), and the exactly-once `Economy.credit(refund, "sell:instance_<id>")` (AC7).

---

## Dependencies

- Depends on: Story 002 (bridge timer + Del → this flow), Economy (`credit` — exists), EquipmentCatalog (`get_definition` — exists), GridSystem (occupant removal)
- Unlocks: Story 004 (toolbar's Sell button drives this state machine)
