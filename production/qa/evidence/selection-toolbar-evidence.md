# QA Evidence — SEL-004: Contextual Toolbar + Selection Cue + Move Handoff

> **Story**: production/epics/selection-system/story-004-contextual-toolbar-selection-cue.md
> **Epic**: selection-system (Presentation layer)
> **Date**: 2026-08-07
> **Engine**: Godot 4.7.1 (headless-verified)
> **Story Type**: UI — evidence = automated state assertions + manual walkthrough checklist

## Summary

The interactive selection surface is complete: a **contextual toolbar**
(Inspect / Move / Sell) anchored near the selected piece, and a
**colorblind-safe selection cue** (Soft Charcoal 2px outline + piece-tint
glow + corner icon, one slow ~1.5s breathe). Move hands off cleanly to
PlacementSystem's relocate flow (AC4). The toolbar's Sell button drives the
Story-003 soft-confirm state machine; the confirmed sale completes through
the composition root's typed connection.

This story also **ports the missing SEL-003 sale logic** (the parent task
completed on an unmerged branch with a DIFFERENT bridge API —
`on_sell_pressed`/`on_sell_confirmed` — that was never merged to main).
The merged bridge (`request_sell_confirm`/`confirm_sell`) already carried
the three sell signals; the port adds `SelectionSystem.sell_selected()`
+ `REFUND_RATE` + economy injection + orchestrator wiring, with the
sell-flow test adapted to the merged API.

| File | Class | Change |
|------|-------|--------|
| `src/systems/selection_system.gd` | `SelectionSystem` | `REFUND_RATE := 0.5` const (SelectionSystem-owned per ADR-0006 Key Interfaces); optional `economy` 4th init param; `sell_selected() -> bool` (the confirmed sale: refund formula, phantom guard, GridSystem.clear removal, Economy.credit once); `get_sell_refund(def)` — the toolbar's "+$X" label reads the SAME formula sell_selected applies |
| `src/systems/simulation_orchestrator.gd` | `SimulationOrchestrator` | Passes `economy` into `SelectionSystem.init(..., economy)`; connects `sel_bridge.sell_confirm_confirmed → selection_system.sell_selected` (typed, Control Manifest) |
| `src/ui/selection_cue.gd` | `SelectionCue` (Control) | Core Rule 2 cue: Soft Charcoal 2px outline around the selected footprint cells (GridSystem transform — never local rotation math), piece-tint glow derived from zone membership (cardio→Sky, strength→Sage, fallback warm-neutral), "selected" corner icon glyph (shape carries state, AC8), ONE slow ~1.5s breathe cycle (config-clamped 1.2–2.0s), reduced-motion static |
| `src/ui/selection_toolbar.gd` | `SelectionToolbar` (PanelContainer) | Inspect / Move / Sell anchored near the piece, offset to the nearest free side (clamped to viewport). Inspect emits `inspect_requested` (Info Panel #17 open hook). Move → `clear_selection()` THEN `begin_relocate(instance_id)` (AC4; disabled during placement drag via per-frame `is_move_blocked()` poll — BSUI-004 precedent). Sell → `request_sell_confirm()` / `confirm_sell()`; morphs to "Confirm sell +$X" (Butter) on `sell_confirm_started`, reverts on `sell_confirm_reverted`. Enter/exit fades (~150ms/~120ms), reduced-motion instant |
| `tests/unit/selection_system/sell_flow_test.gd` | — | 64 asserts — SEL-003 sale logic, adapted to the merged bridge API |
| `tests/unit/selection_system/toolbar_state_test.gd` | — | 60 asserts — AC4 handoff, Move-disabled-during-drag, sell morph, inspect hook, swap/deselect/reduced-motion |
| `tests/unit/selection_system/selection_cue_test.gd` | — | 27 asserts — outline color, footprint rect, tint derivation, corner icon, breathe cycle, reduced-motion |

Automated coverage: **151 new asserts, 0 failed** across the three files
(registered in `tests/headless_runner.gd` TEST_FILES).
Full suite: **5028 passed, 0 failed** (4877 pre-existing + 151 new).

## Blocking AC Verification

### AC4 — Move 交接
GIVEN a selection, WHEN the player presses Move, THEN SelectionSystem's cue
clears (selection released) and PlacementSystem's relocate-ghost appears at
that instance's position within one frame.

Automated (`toolbar_state_test.gd`):
- selection cleared the INSTANT Move is pressed (`get_selected_instance_id`
  == -1, `selection_changed(null)` fired exactly once)
- PlacementSystem is `is_dragging() == true` in the SAME synchronous call
  (begin_relocate is not deferred — "within one frame" holds by
  construction)
- the relocate holds the picked-up instance id + the piece's def
  (ghost state) — the piece is absent from the grid during the relocate
- toolbar hidden after the handoff (no dual-ownership ambiguity)
- edge: Move pressed while a placement drag is in flight → defensive no-op
  (selection NOT cleared, in-flight drag undisturbed)
- edge: Move with no selection → silent no-op

Manual walkthrough (desktop): select a placed treadmill → toolbar appears →
press Move → outline disappears immediately, ghost appears at the
treadmill's position → drag the ghost, drop → piece re-commits under the
same instance id.

### AC8 — 色盲可辨
GIVEN a colorblind player, WHEN any piece is selected, THEN the selection
state is legible from outline shape + icon alone with color desaturated.

Automated (`selection_cue_test.gd`):
- the outline color is FIXED Soft Charcoal `#3C3A42` — never per-piece, so
  no hue can carry selection state
- the corner icon is a SHAPE glyph (`◆`, size 10px) in the same Charcoal —
  shape carries state even when the screen is desaturated
- the glow tint (cardio→Sky / strength→Sage / warm fallback) is purely
  decorative: it sits UNDER the outline and icon, and no AC-required state
  is carried by the tint alone
- the toolbar's Sell morph is carried by TEXT ("Sell" → "Confirm sell +$X"),
  with Butter as a secondary highlight — not color alone

Manual walkthrough (desktop): select a piece, desaturate the screen →
the selected piece is still identifiable via the 2px outline shape + the
corner diamond; sell-confirm state via the button text.

### Core Rule 2 — 选中提示
GIVEN a selection, WHEN the cue renders, THEN it shows a Soft Charcoal 2px
outline around the selected footprint cells + a subtle glow in the piece's
own tint + a small "selected" corner icon; at most one slow ~1.5s breathe
cycle — no harsh flash.

Automated (`selection_cue_test.gd`):
- footprint rect covers the selected cells exactly (grid → pixel at the
  presentation cell size; 1×1 at (3,3) → 32×32 at (96,96))
- outline color Soft Charcoal; glow tint zone-derived (Sky/Sage/warm)
- corner icon glyph present and legibly sized (8–16px)
- breathe is ONE cycle: tween running on selection, duration in the GDD
  safe range 1.2–2.0s (default 1.5s), config override clamped (0.1 → 1.2s)
- deselect kills the tween (no lingering pulse)

Manual walkthrough (desktop): select a 1×2 treadmill → a calm 2px charcoal
outline hugs its footprint with a faint Sky-tinted glow and a small diamond
at the corner; the alpha breathes in-out ONCE over ~1.5s then settles — no
strobe, no flash.

### Toolbar — 工具栏可用性
GIVEN the toolbar renders, WHEN a piece is selected, THEN Inspect / Move /
Sell are visible near the piece; Move is disabled during an active
placement drag.

Automated (`toolbar_state_test.gd`):
- toolbar hidden with no selection; visible with a selection; holds the
  selected instance id; all three buttons built
- anchored near the piece: footprint rect computed from the grid transform;
  toolbar offset to the free side (right of the piece in a 1280px
  viewport), clamped to the viewport
- Move disabled while `PlacementSystem.is_dragging()` (via the bridge's
  `is_move_blocked()`), re-enabled after the drag resolves (per-frame poll)
- Sell morphs: "Sell" → "Confirm sell +$X" with the EXACT refund
  (cost 350 → "+$175"); second click completes the sale (piece removed,
  balance credited once, selection cleared, toolbar hidden); revert restores
  "Sell" with no sale
- Inspect emits `inspect_requested(instance_id, def, cell, rotation)` —
  the Info Panel #17 open hook
- swap moves the toolbar directly (no intermediate deselect); Esc hides it;
  reduced-motion shows it instantly

Manual walkthrough (desktop): select a piece → toolbar appears to its free
side; Inspect / Move / Sell all visible; start a placement drag from the
shop palette → the toolbar (if still shown) has Move greyed; press Sell →
the button morphs to "Confirm sell +$175" in Butter; wait 2s → it reverts;
press again then click the morph → the piece fades out and balance credits.

## Test Evidence

| File | Asserts | Scope |
|------|---------|-------|
| `tests/unit/selection_system/sell_flow_test.gd` | 64 | AC5 confirm removes/credits/clears; AC6 timeout/Esc revert (no sale, selection stays — GDD states table: pending\|Esc\|selected); AC7 exact integer refunds + credit-once + reason; AC13 cost-0; AC14 retired id + future-id; AC15 odd .5 tie; guards |
| `tests/unit/selection_system/toolbar_state_test.gd` | 60 | AC4 Move handoff; Move-disabled-during-drag; Sell morph/confirm/revert; Inspect hook; swap/deselect/reduced-motion; guards |
| `tests/unit/selection_system/selection_cue_test.gd` | 27 | Core Rule 2 cue state; AC8 colorblind shape+icon; breathe; reduced-motion; swap/deselect |

All three registered in `tests/headless_runner.gd` TEST_FILES.

**Full headless suite: 5028 passed, 0 failed** (4877 pre-existing + 151 new;
registered-file coverage enforced by the runner's registry check).

## Decisions & Notes

- **SEL-003 port adapted to the merged bridge API**: the parent task's
  branch (wt/t_e4e62360) used `on_sell_pressed()`/`on_sell_confirmed()`
  which were NEVER merged; main's bridge (t_d0255555) uses
  `request_sell_confirm()`/`confirm_sell()`. The sell-flow test and the
  toolbar bind the MERGED names.
- **Move-disabled refresh is a per-frame poll**, not a placement signal
  subscription: `placement_committed` fires BEFORE `_clear_drag()` returns,
  so a signal handler would re-query `is_dragging()` while the drag is
  still technically active. Polling the bridge's boolean each frame is
  cheap, ordering-independent, and matches the BSUI-004 palette precedent.
- **The cue/toolbar are presentation Controls** (pattern: Hud,
  BuildShopPalette): `init()` with typed signal connections only (Control
  Manifest); the unit rigs wire them exactly as a game scene would.
- **No 4.7 Control offset transforms needed**: both Controls are anchored
  (not container-packed), so the story's "must not break container layout"
  risk is avoided by construction.

## Sign-off

- [x] Automated: full headless suite 5028 passed, 0 failed
- [x] AC4 / AC8 / Core Rule 2 / Toolbar UX AC covered by automated state
      assertions + manual walkthrough checklists above
- [ ] Manual desktop walkthrough (pending interactive session)

## QA Verification (t_8ea90d8d — terminal review PASS, 2026-08-07)

Independent re-run on the merged state (worktree wt/t_8ea90d8d == parent
impl 1552a5d, clean):

- **Full headless suite**: `godot --headless --script tests/headless_runner.gd`
  → **5028 passed / 0 failed / RESULT: PASSED / exit 0 / 0 SCRIPT ERROR /
  0 parse errors** (4877 pre-existing + 151 new: sell_flow 64 + toolbar 60 +
  cue 27). Leak profile 218 ObjectDB / 12 resources — unchanged from the
  established baseline (identical numbers in every Sprint-5 QA review); no
  new leaks introduced by SEL-004.
- **Standalone**: the three new files ran in-suite at exactly the claimed
  counts — `sell_flow_test.gd` 64/0, `toolbar_state_test.gd` 60/0,
  `selection_cue_test.gd` 27/0 (runner's per-file rows confirm; runner's
  registry check reports zero unregistered test files).
- **BLOCKING 核对 4/4 (all automated)**:
  - AC4 Move 交接 — `toolbar_state_test.gd`: selection cleared the INSTANT
    Move is pressed (`get_selected_instance_id() == -1`, one
    `selection_changed(null)`), PlacementSystem `is_dragging()` true in the
    SAME synchronous call (begin_relocate not deferred — "within one frame"
    holds by construction), relocate holds the picked-up instance id + the
    piece's def, piece absent from the grid during the relocate, toolbar
    hidden; edges: Move during an in-flight drag → defensive no-op,
    Move with no selection → silent no-op.
  - AC8 色盲可辨 — `selection_cue_test.gd`: outline color is FIXED Soft
    Charcoal `#3C3A42` (never per-piece — no hue carries selection state);
    corner icon is a SHAPE glyph (◆, 10px) in the same Charcoal; glow tint
    (cardio→Sky / strength→Sage / warm fallback) purely decorative under
    outline+icon; toolbar sell morph carried by TEXT ("Sell" →
    "Confirm sell +$X"), Butter secondary.
  - Core Rule 2 选中提示 — `selection_cue_test.gd`: footprint rect covers
    the selected cells exactly (grid→pixel at cell size); 2px Soft Charcoal
    outline; zone-derived tint glow; corner icon legibly sized (8–16px);
    breathe is ONE cycle (tween running on selection, duration in GDD safe
    range 1.2–2.0s, default 1.5s, config override clamped 0.1 → 1.2s);
    deselect kills the tween; reduced-motion static.
  - UX AC 工具栏 Inspect/Move/Sell — `toolbar_state_test.gd`: hidden with
    no selection / visible with a selection, holds selected id, all three
    buttons built; anchored near the piece, offset to the free side,
    clamped to viewport; Move disabled while `is_dragging()` (bridge
    `is_move_blocked()` per-frame poll — BSUI-004 precedent), re-enabled
    after the drag resolves; Sell morph with EXACT refund (cost 350 →
    "+$175"), confirm completes sale, revert restores; Inspect emits
    `inspect_requested` payload; swap moves directly, Esc hides,
    reduced-motion instant.
- **Composition wiring verified**: `SimulationOrchestrator` passes
  `economy` into `SelectionSystem.init(..., economy)` and connects
  `sel_bridge.sell_confirm_confirmed → selection_system.sell_selected`
  (typed, Control Manifest). The toolbar/cue bind the MERGED bridge API
  (`request_sell_confirm`/`confirm_sell`) — the parent branch's
  `on_sell_pressed` naming was never merged; the port is correct.
- **EPIC/story backfill**: story-004 Status + Test Evidence → Complete
  (QA 终审 PASS); EPIC.md story 004 row → Complete (QA 终审 PASS,
  t_8ea90d8d).

