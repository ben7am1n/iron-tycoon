# QA Evidence — BSUI-004: Drag Handoff & Purchase Confirm + Silent-Cancel Cue

> **Story**: production/epics/build-shop-ui/story-004-drag-handoff-purchase-confirm.md
> **Epic**: build-shop-ui (Presentation layer)
> **Date**: 2026-08-07
> **Engine**: Godot 4.7.1 (headless-verified)
> **Story Type**: UI — evidence ADVISORY (manual walkthrough) + automated cue-trigger coverage

## Summary

The drag handoff is complete: PlacementSystem owns the drag lifecycle
(ghost, validity tint, rotation, commit/reject/cancel — the UI does NOT
re-implement any of it), and `BuildShopPalette` now renders the three
resolution outcomes the GDD/UX spec require:

- **AC7 — 拖拽结束恢复**: the palette's per-frame drag-resolution poll
  re-enables the palette AND re-greys every tile against the CURRENT balance
  whenever a palette-initiated drag leaves DRAGGING (commit / reject /
  silent cancel). Commit already re-greys via `balance_changed` (Shop's
  spend-on-commit); reject/cancel get the idempotent refresh from the poll.
- **AC10 — 静默取消提示**: a silent cancel (Esc / out-of-bounds drop /
  focus-loss — PlacementSystem emits NOTHING by design) is detected by the
  poll via Shop's still-set `_purchase_in_flight` flag, Shop is notified
  (`notify_silent_cancel`, zero spend — Core Rule 2 step 3), and a
  lightweight return-to-palette cue fires (`silent_cancel_cue` signal + a
  short warm-white modulate flash, `CUE_DURATION = 0.4s`, self-limiting).
  The resolution is no longer invisible.
- **shop-purchase.md Core Rule 4 — 购买确认**: a purchase-initiated commit
  triggers the purchase-confirm cue (`purchase_confirm_cue` signal + warm
  gold flash) from the `placement_committed` handler — NOT from
  `balance_changed`. A cost-0 purchase never fires `balance_changed` (Core
  Rule 2b skips `spend(0)`) but still gets its confirmation feel. Relocate
  commits (no palette gate) and rejects produce no confirm cue.

The cue visual is a modulate flash only — deliberately NOT the 4.7 Control
offset-transform API, which must not break the HBox container layout (the
story's engine-risk note). The two signals are the audio-director hook for
the optional audio half of the cues.

| File | Class | Role |
|------|-------|------|
| `src/ui/build_shop_palette.gd` | `BuildShopPalette` | Story-004 cue machinery: typed `placement_committed` subscription, palette-local `_drag_equipment_id` purchase tracking, `_poll_drag_resolution` (AC7 re-grey + AC10 silent-cancel discriminator), `_start_confirm_cue`/`_start_return_cue` + `_decay_cues` + `_apply_cue_visual` (single modulate authority) |
| `src/ui/palette_availability.gd` | `PaletteAvailability` | Contract gains `is_purchase_in_flight()` — the silent-cancel discriminator query the poll consumes |
| `src/ui/placeholder_palette_availability.gd` | `PlaceholderPaletteAvailability` | Implements `is_purchase_in_flight() -> false` (placeholder never sets a flag; render-only rigs unchanged) |

Automated coverage: `tests/unit/build_shop_ui/drag_feedback_test.gd` — **104
asserts, 0 failed** (registered in `tests/headless_runner.gd` TEST_FILES).

Full suite: **4193 passed, 0 failed** (4089 pre-existing + 104 new).

## Blocking AC Verification

### AC7 — 拖拽结束恢复 (drag ends -> palette re-enables + re-greys)

- ✅ Automated (commit): drag → move → drop commits → balance 500→150 →
  poll → `is_drag_in_flight()` false; treadmill AND bench_press re-greyed
  to UNAFFORDABLE (150 < 200); free_dumbbell stays full-tint; modulate
  returns to WHITE after the confirm cue decays.
- ✅ Automated edge (reject): occupied-cell drop → `placement_rejected` →
  poll → palette re-enabled, balance unchanged (500) → bench_press still
  AFFORDABLE (same grey state); no cue flashes (reject is signalled —
  rejection tooltips are CFO-004's system).
- ✅ Automated edge (silent cancel): Esc → poll → palette re-enabled,
  balance unchanged → treadmill still AFFORDABLE; Shop flag cleared via
  `notify_silent_cancel`.

### AC10 — 静默取消提示 (silent cancel -> return-to-palette cue)

- ✅ Automated (Esc): drag starts (palette dims, flag set) → `on_cancel`
  (PlacementSystem emits NOTHING) → poll detects flag still set →
  `is_return_cue_active()` true; `silent_cancel_cue` fired exactly once
  with the equipment_id; Shop flag cleared; balance untouched; item back to
  idle AFFORDABLE visual; modulate = the return flash.
- ✅ Automated edge (out-of-bounds drop): mouse-move to (50,50) → `on_drop`
  (OOB = silent cancel, AC8) → same cue, no spend.
- ✅ Automated edge (focus-loss): `on_focus_lost` (routes to the same
  silent-cancel path, AC17) → same cue, no spend.
- ✅ Automated edge (self-limiting): after `CUE_DURATION` of `_process`,
  the return cue clears and modulate returns to WHITE.
- ✅ Automated edge (gate-swallowed attempt): `is_dragging()` already true →
  Shop's structural backstop blocks the mouse-down → NO drag ever started,
  so NO phantom return cue (the item never left its idle visual — a flash on
  an inert item would be noise, not feedback). Interpretation note: the
  GDD's AC10 "e.g." lumps the swallowed attempt with the real silent
  cancels; the load-bearing case — a VISIBLE drag ending with no signal —
  gets the full cue; the swallowed attempt gets the correct no-op.

### shop-purchase.md Core Rule 4 — 购买确认 (confirm on committed, not balance_changed)

- ✅ Automated (paid commit): purchase drag → move → drop →
  `is_confirm_cue_active()` true; `purchase_confirm_cue` fired exactly once
  with the equipment_id; balance spent exactly once; Shop flag cleared; no
  return cue.
- ✅ Automated (cost-0 — the Core Rule 4 discriminator): free item commit →
  SpendSpyEconomy proves `spend()` called ZERO times (Core Rule 2b), zero
  `balance_changed` emissions, balance untouched — AND the confirm cue still
  fires. The cue lives on `placement_committed`, not on the balance signal.
- ✅ Automated edge (relocate commit): a real `begin_relocate` re-commit
  (same `placement_committed` signal, no palette gate) → NO confirm cue
  (Core Rule 2a — relocate is not a purchase).
- ✅ Automated edge (reject): rejected drop → NO confirm cue, NO return cue.
- ✅ Automated edge (mismatch): commit for a different equipment_id while a
  palette drag is in flight → NO confirm cue (defensive guard — the
  palette's `_drag_equipment_id` match).
- ✅ Automated discriminator (balance change alone): `economy.spend(50)`
  fires `balance_changed` with NO commit → NO confirm cue. The cue is
  commit-driven.

## Guardrails

- ✅ Control Manifest: typed signal connections only
  (`placement_committed.connect(_on_placement_committed)`); no string-based
  connects.
- ✅ Signal-order independence: the palette tracks `_drag_equipment_id`
  locally instead of consulting Shop's `_purchase_in_flight` flag in the
  confirm handler — Shop's own listener (connected first in the
  composition root) clears the flag inside the same emit, so consulting it
  there would miss every purchase. Palette-local tracking works regardless
  of connect order.
- ✅ Story-001/002/003 compatibility: palette init signature unchanged;
  `palette_state_test` (72), `purchase_gate_test` (86), and
  `mode_arbitration_test` (53) pass unchanged. Placeholder availability
  implements the new contract query (false) so render-only rigs are
  unaffected.
- ✅ 4.7 rendering risk respected: cue animation uses modulate flash only —
  no Control offset transforms, container layout untouched.
- ✅ Test hygiene: fixed the pre-existing vacuous `emit_signal` in
  `purchase_gate_test.gd:637` (raw Array literal fails the typed
  `Array[Vector2i]` handler conversion, so the mismatch branch never ran;
  the palette's new subscription surfaced the conversion error). The typed
  array now exercises Shop's mismatch branch for real.

## Files Changed

- `src/ui/build_shop_palette.gd` (Story-004 cue machinery — see table)
- `src/ui/palette_availability.gd` (contract: `is_purchase_in_flight()`)
- `src/ui/placeholder_palette_availability.gd` (implements the query)
- `tests/unit/build_shop_ui/drag_feedback_test.gd` (new, 104 asserts)
- `tests/unit/build_shop_ui/purchase_gate_test.gd` (typed-array emit fix)
- `tests/headless_runner.gd` (register `drag_feedback_test`)

## Known Gaps / Future Work

- The actual drag-ghost renderer does not exist yet (PlacementSystem's
  `preview_validity_changed` + `ModeArbitration.is_ghost_suppressed()` are
  the signals it will follow) — carried over from Story 003's known gaps;
  no story in this epic owns it.
- The audio half of the cues is the audio-director's hook
  (`purchase_confirm_cue` / `silent_cancel_cue` signals) — no sound assets
  exist yet.
- The UX spec's keyboard-drag path (Tab/Enter/R/Esc) still routes through
  the same gate when it lands (UX OQ3 — MVP leans implicit).
