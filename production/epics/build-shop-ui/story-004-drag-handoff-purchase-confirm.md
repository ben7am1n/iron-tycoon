# Story 004: Drag Handoff + Purchase Confirm + Silent-Cancel Cue

> **Epic**: build-shop-ui
> **Status**: Complete — 2026-08-07
> **Layer**: Presentation
> **Type**: UI
> **Estimate**: M — 2 sessions (≤4h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-07

## Context

**GDD**: `design/gdd/build-shop-ui.md` (Core Rule 2 + shop-purchase.md Core Rule 4)
**Requirement**: `TR-BSUI-003` (handoff part), `TR-BSUI-005` (cancel-cue part)
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0005 (Signal Bus & Event Routing)
**ADR Decision Summary**: The palette mouse-down (gated by Story 002) hands off to `PlacementSystem.begin_drag(equipment_id)` — Placement runs its own DRAGGING flow (ghost, validity tint, commit/reject/cancel). The UI renders: the palette's disabled state during the drag, a purchase-confirm cue on `placement_committed` (Shop spends), and a return-to-palette cue on silent cancel. Block-at-selection requires the UI to compensate at the point of contact (Shop Core Rule 4): silent cancels must produce a lightweight return cue so the resolution is not invisible.

**Engine**: Godot 4.7.1 | **Risk**: MEDIUM
**Engine Notes**: Control palette + input; dual-focus (4.6+) keyboard; Control offset transforms (4.7 NEW) optional for return-cue animation (must not break container layout). `class_name` follows `extends` immediately.

**Control Manifest Rules (Presentation layer)**:
- Required: typed signal connections only
- Forbidden: string-based signal connections

---

## Acceptance Criteria

*From GDD `design/gdd/build-shop-ui.md`, scoped to this story:*

- [x] AC7 GIVEN a placement drag ends (commit/reject/cancel), WHEN it resolves, THEN the palette re-enables and re-greys against the current balance
- [x] AC10 GIVEN a purchase drag that ends in a silent cancel, WHEN the cancel is detected, THEN the palette item returns to its idle-state visual with a lightweight visual/audio return-to-palette cue (resolution is not invisible)
- [x] shop-purchase.md Core Rule 4 GIVEN a purchase-initiated drag successfully lands, WHEN `placement_committed` fires with `_purchase_in_flight` set, THEN a purchase-confirm cue triggers (on committed, NOT on balance_changed — a cost-0 purchase never fires balance_changed but still deserves the confirmation feel)

---

## Implementation Notes

*Derived from ADR-0005 + GDD Core Rule 2 + shop-purchase.md Core Rule 4:*

**Drag handoff (Core Rule 2, AC4/AC7)**:
- Gated palette mouse-down → `PlacementSystem.begin_drag(equipment_id)` (Story 002's gate passed; Shop set `_purchase_in_flight`)
- PlacementSystem owns the drag: ghost, footprint/access validity tint, rotation (R/right-click), commit/reject/cancel — the UI does NOT re-implement any of it
- On drag end (commit/reject/cancel): palette re-enables and re-greys against the current balance (AC7)

**Purchase-confirm cue (shop-purchase.md Core Rule 4)**:
- Trigger on `placement_committed` while `_purchase_in_flight` was set (i.e. the moment a purchase-initiated drag successfully lands) — a soft confirm feel (snap-in / positive cue)
- NOT on `balance_changed` — a cost-0 purchase never fires balance_changed but still deserves the confirmation feel
- A soft "pick up" cue on starting a drag is a nice-to-have (audio-director), never intrusive

**Silent-cancel return cue (AC10)**:
- A silent cancel (Core Rule 2 step 3: e.g. `can_purchase` passed but `PlacementSystem.is_dragging()` was already true — an attempt swallowed with no signal) must produce a lightweight visual/audio return-to-palette cue — the drag's resolution is not invisible to the player
- Also applies to Esc/out-of-bounds/focus-loss cancels: item returns to idle-state visual with a soft cue; no spend; palette re-enables

**Palette disabled during drag (one-drag invariant reinforcement)**:
- While a purchase drag is in flight, the palette is visibly disabled (dimmed) — UI-level reinforcement of Story 002's structural invariant

**4.7.1 pitfalls**:
- `class_name` follows `extends` immediately; headless cross-script refs via `preload` aliases
- Typed signal connections: `placement_committed.connect(...)`, `placement_rejected.connect(...)`

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 001]: palette rendering states
- [Story 002]: can_purchase gate, one-drag invariant, Shop's spend-on-commit listener (this story only renders the confirm/cancel cues)
- [Story 003]: build/select mode arbitration
- Overlay epic: rejection tooltip buckets (CFO-004) — separate system consuming `placement_rejected`

---

## QA Test Cases

*Derived from GDD acceptance criteria. UI story — manual walkthrough plus automated cue-trigger logic where practical.*

- **AC7**: 拖拽结束恢复
  - Given: a placement drag in flight (palette disabled)
  - When: commit / reject / cancel resolves
  - Then: palette re-enables and re-greys against current balance
  - Edge cases: commit (balance dropped → items re-grey); cancel (balance unchanged → same grey state)

- **AC10**: 静默取消提示
  - Given: a drag attempt swallowed with no signal (e.g. can_purchase passed but is_dragging() true)
  - When: the cancel is detected
  - Then: palette item returns to idle visual with a lightweight return-to-palette cue
  - Edge cases: Esc/out-of-bounds/focus-loss cancels — same cue, no spend

- **Core Rule 4**: 购买确认
  - Given: a purchase-initiated drag successfully lands (placement_committed, _purchase_in_flight set)
  - When: commit resolves
  - Then: purchase-confirm cue triggers (even for cost-0 — no balance_changed, but confirmation still shows)
  - Edge cases: relocate commit (flag null) → no purchase confirm cue

---

## Test Evidence

**Story Type**: UI
**Required evidence**:
- `production/qa/evidence/bsui-drag-handoff-evidence.md` — manual walkthrough / sign-off
- Automated coverage of confirm/cancel cue triggers where practical (e.g. `tests/unit/build_shop_ui/drag_feedback_test.gd`)

**Status**: [x] Complete — 2026-08-07

`tests/unit/build_shop_ui/drag_feedback_test.gd` (104 assertions) exists,
passes, and is registered in `tests/headless_runner.gd` TEST_FILES. It covers
AC7 (commit/reject/cancel re-enable + re-grey), AC10 (Esc / OOB / focus-loss
return cue + decay + no-phantom-cue edge), and shop-purchase.md Core Rule 4
(confirm on committed — including the cost-0 no-balance_changed discriminator,
relocate no-confirm, reject no-confirm, mismatch guard, balance-alone
discriminator). Full headless suite: **4193 passed, 0 failed** (4089
pre-existing + 104 new). Evidence: `production/qa/evidence/build-shop-handoff-evidence.md`.

---

## Dependencies

- Depends on: Story 002 (purchase gating — the drag initiation + _purchase_in_flight state), Story 003 (arbitration); PlacementSystem (`begin_drag`, `placement_committed` — exist)
- Unlocks: None (completes the build-shop-ui epic)
