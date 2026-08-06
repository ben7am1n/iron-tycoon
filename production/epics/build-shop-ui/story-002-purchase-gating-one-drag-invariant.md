# Story 002: Purchase Gating + One-Drag Invariant + Hover Save-$X

> **Epic**: build-shop-ui
> **Status**: Ready
> **Layer**: Presentation
> **Type**: Logic
> **Estimate**: M — 2 sessions (≤4h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-06

## Context

**GDD**: `design/gdd/build-shop-ui.md` (Core Rules 2/3/5)
**Requirement**: `TR-BSUI-003`, `TR-BSUI-005`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0005 (Signal Bus & Event Routing); ADR-0006 (Economy credit — balance readout basis)
**ADR Decision Summary**: The palette mouse-down calls `Shop.can_purchase(id)` BEFORE a drag starts; if false, nothing happens (block-at-selection, Pillar 3). While a purchase drag is in flight, the UI disables all other palette interactions (one-drag invariant — Shop's safety proof depends on it). Hover on greyed items shows "Save $X more" (X = cost − balance).

**⚠️ Shop (#12) NOT implemented — implement the minimal Shop query surface here**: `src/systems/` has NO Shop. Per `design/gdd/shop-purchase.md` Core Rules 1/2/5, the minimal surface is:
- `can_purchase(equipment_id) -> bool = is_unlocked(equipment_id) AND (cost == 0 OR Economy.can_afford(cost))` (cost-0 short-circuit REQUIRED — Economy rejects `can_afford(0)`)
- `is_unlocked(equipment_id) = (unlock_requirement == null)` — any non-null → false (fail-closed MVP stub)
- `_purchase_in_flight = {equipment_id, cost} | null` set at drag-start (gated on `can_purchase` AND `PlacementSystem.is_dragging()` false), cleared on commit/reject/cancel
- Conditional listener on `placement_committed`: if `_purchase_in_flight` set and `equipment_id` matches → `Economy.spend(cost)` exactly once (skipped for cost-0); if null → relocate commit, ignore
This is small integration glue fully specified by shop-purchase.md; if a dedicated Shop card is split out later, the logic migrates cleanly.

**Engine**: Godot 4.7.1 | **Risk**: MEDIUM
**Engine Notes**: Logic lives in a small RefCounted Shop (per shop-purchase.md) + UI gate checks; Control `_input` for palette; dual-focus (4.6+) for keyboard. `class_name` follows `extends` immediately.

**Control Manifest Rules (Presentation layer)**:
- Required: typed signal connections only
- Forbidden: string-based signal connections

---

## Acceptance Criteria

*From GDD `design/gdd/build-shop-ui.md`, scoped to this story:*

- [ ] AC4 GIVEN an affordable, unlocked item, WHEN the player mouse-downs it, THEN a PlacementSystem placement drag begins for that `equipment_id` (after `can_purchase` passes)
- [ ] AC5 GIVEN a purchase drag is in flight, WHEN the player tries to start another purchase, THEN it is blocked (one-drag invariant holds)
- [ ] AC9 GIVEN a greyed/unaffordable palette item, WHEN the player hovers it, THEN a tooltip or inline label shows "Save $X more" where `X = cost - balance`
- [ ] Shop Core Rule 1 GIVEN a locked item, WHEN `can_purchase` is queried, THEN it returns false (unlock check first)
- [ ] Shop Core Rule 2b GIVEN a cost-0 item's drag commits, WHEN the commit resolves, THEN no `Economy.spend(0)` call is made (skipped) — placement completes, money untouched

---

## Implementation Notes

*Derived from shop-purchase.md Core Rules 1/2/3/5 + build-shop-ui.md Core Rules 2/3:*

**Gate at drag-start (block-at-selection, TR-BSUI-003)**:
- Palette mouse-down → `Shop.can_purchase(id)`; if true AND `PlacementSystem.is_dragging()` false → set `_purchase_in_flight` + initiate PlacementSystem drag; if false → inert (greyed/locked)
- If `PlacementSystem.is_dragging()` already true → do NOTHING (no flag, no drag attempt — Shop's structural backstop; a second mouse-down while DRAGGING is silently ignored by PlacementSystem AC16)

**One-purchase-drag-at-a-time (TR-BSUI-003, Core Rule 3)**:
- While a purchase drag is in flight, the UI disables all other palette interactions (no second drag, no other purchase) — this is the invariant Shop's money-safety proof relies on (balance monotonically non-decreasing during a drag → a passed gate always yields a successful spend at commit)

**Deduct-on-commit (shop-purchase.md Core Rule 2)**:
- Money spent ONLY on `placement_committed`, ONLY for purchase-initiated drags (relocate commits ignored — `_purchase_in_flight` null)
- `equipment_id` mismatch branch: leave flag untouched, no spend (defensive, expected unreachable under one-drag invariant)
- Cost-0: skip `Economy.spend(0)` entirely (Economy rejects amount ≤ 0); just clear the flag

**Hover Save-$X (TR-BSUI-005, AC9)**:
- Hovering a greyed/unaffordable item surfaces "Save $X more" where `X = cost - balance` (sourced from EquipmentCatalog + Economy — both exposed)
- Locked items: lock tooltip (distinct from affordability)

**4.7.1 pitfalls**:
- `var x := expr` fails on Variant returns → explicit `: bool` for `can_afford`/`is_dragging` results
- Typed signal connections only for `placement_committed` listener

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 001]: palette rendering of the greyed/locked states (this story supplies the query + hover text)
- [Story 003]: build/select mode arbitration
- [Story 004]: drag ghost visuals, purchase-confirm cue, silent-cancel return cue

---

## QA Test Cases

*Derived from GDD + shop-purchase.md acceptance criteria. Logic story — automated coverage required (BLOCKING).*

- **AC4**: 可负担启动拖拽
  - Given: affordable, unlocked item
  - When: mouse-down on palette item
  - Then: `can_purchase` true; `_purchase_in_flight` set; PlacementSystem drag begins for that equipment_id
  - Edge cases: `is_dragging()` already true → no flag, no drag; locked item → can_purchase false → no drag

- **AC5**: 单拖拽不变量
  - Given: a purchase drag in flight
  - When: second palette interaction attempted
  - Then: blocked (palette disabled; structural gate also no-ops)
  - Edge cases: second can_purchase pass during drag → true no-op, no flag change

- **AC9**: Save-$X 提示
  - Given: greyed/unaffordable item (cost C, balance B)
  - When: hover
  - Then: tooltip/inline shows "Save $X more" where X = C − B
  - Edge cases: X = 0 (just affordable — full-tint, no tooltip); locked item → lock tooltip not Save-$X

- **Shop Core Rule 1**: 解锁优先
  - Given: locked item that is also cost-0
  - When: can_purchase queried
  - Then: false (unlock checked before the cost-0 affordability short-circuit)

- **Shop Core Rule 2b**: 免费件不 spend
  - Given: cost-0 item drag commits
  - When: placement_committed resolves with _purchase_in_flight set
  - Then: no Economy.spend(0) call; flag cleared; placement complete
  - Edge cases: relocate commit (flag null) → no spend, no flag change

---

## Test Evidence

**Story Type**: Logic
**Required evidence**:
- `tests/unit/build_shop_ui/purchase_gate_test.gd` — must exist and pass (can_purchase gate incl. cost-0 short-circuit, one-drag invariant, spend-on-commit exactly once, hover Save-$X derivation)

**Status**: [ ] Not yet created

---

## Dependencies

- Depends on: Story 001 (palette rendering states), Economy (`can_afford`, `spend`, `balance_changed` — exist), PlacementSystem (`is_dragging`, `placement_committed`, `begin_drag` — exist), EquipmentCatalog (`get_definition` → cost/unlock_requirement — exist)
- Unlocks: Story 003 (arbitration), Story 004 (handoff/confirm cues)
