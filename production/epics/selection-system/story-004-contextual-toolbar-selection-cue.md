# Story 004: Contextual Toolbar + Selection Cue + Move Handoff

> **Epic**: selection-system
> **Status**: Complete — 2026-08-07 (implementation + headless QA PASS, 5028/0)
> **Layer**: Presentation
> **Type**: UI
> **Estimate**: M — 2 sessions (≤4h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-06

## Context

**GDD**: `design/gdd/selection-system.md`
**Requirement**: `TR-SEL-002`, `TR-SEL-010`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0005 (Signal Bus & Event Routing — bridge drives the toolbar Control)
**ADR Decision Summary**: A contextual toolbar (Inspect / Move / Sell) anchored near the selection — NOT a blocking modal. The bridge Node drives the toolbar Control (morph/revert animations for the Sell soft-confirm). SelectionSystem clears its own selection the instant Move is pressed so PlacementSystem takes sole ghost/preview ownership. UX spec: `design/ux/selection-ui.md`.

**Engine**: Godot 4.7.1 | **Risk**: MEDIUM
**Engine Notes**: Control toolbar; Control offset transforms (4.7 NEW) optional for the anchor/scale animations (must not break container layout — toolbar is likely anchored, not container-packed). dual-focus (4.6+) keyboard path: Tab → grid focus → toolbar. `class_name` follows `extends` immediately.

**Control Manifest Rules (Presentation layer)**:
- Required: typed signal connections only
- Forbidden: string-based signal connections

---

## Acceptance Criteria

*From GDD `design/gdd/selection-system.md`, scoped to this story:*

- [x] AC4 GIVEN a selection, WHEN the player presses Move, THEN SelectionSystem's cue clears (selection released) and PlacementSystem's relocate-ghost appears at that instance's position within one frame
- [x] AC8 GIVEN a colorblind player, WHEN any piece is selected, THEN the selection state is legible from outline shape + icon alone with color desaturated
- [x] Core Rule 2 GIVEN a selection, WHEN the cue renders, THEN it shows a Soft Charcoal 2px outline around the selected footprint cells + a subtle glow in the piece's own tint + a small "selected" corner icon; at most one slow ~1.5s breathe cycle — no harsh flash
- [x] UX AC GIVEN the toolbar renders, WHEN a piece is selected, THEN Inspect / Move / Sell are visible near the piece; Move is disabled during an active placement drag

---

## Implementation Notes

*Derived from ADR-0005 + GDD Core Rules 2/3 + UX spec design/ux/selection-ui.md:*

**Selection cue (Core Rule 2, TR-SEL-010)**:
- Soft Charcoal 2px outline around the selected footprint cells + subtle glow in the piece's own tint + small "selected" corner icon (shape carries state even if outline contrast is missed)
- At most one slow ~1.5s breathe cycle — no harsh flash (Pillar 2)
- Reduced-motion: cue static (no breathe)

**Contextual toolbar (Core Rule 3)**:
- Anchored near the selection, offset to the nearest free side (never covering the piece; adapts at screen edges)
- Inspect — always available; opens Equipment Info Panel (#17 — panel itself is VS, out of scope; the button + open hook live here)
- Move — hands off to PlacementSystem's relocate flow (`begin_relocate(instance_id)`); SelectionSystem clears its own selection the INSTANT Move is pressed (no dual-ownership ambiguity); disabled during any active placement drag (`PlacementSystem.is_dragging()`)
- Sell — morphs into the 2s "Confirm sell +$X" state (Butter; Story 003's state machine driven here)
- Enter/exit animations: fade/slide in ~150 ms; exit ~120 ms fade; swap moves directly to the new piece (~150 ms, no intermediate deselect animation); sell success piece fades out gently (~300 ms)

**Move handoff (AC4)**:
- Move → `begin_relocate(instance_id)` → SelectionSystem cue clears; PlacementSystem relocate-ghost appears at that instance's position within one frame
- Once handed off, the flow is PlacementSystem's (its relocate can be cancelled per its own rules)

**Mode arbitration with the rest of the UI**: `selection_changed` drives the toolbar; while a selection is active, Build/Shop UI suppresses the new-placement ghost (that side is Story BSUI-003; the signal contract is emitted here in Story 001).

**4.7.1 pitfalls**:
- `class_name` follows `extends` immediately; headless cross-script refs via `preload` aliases
- Control offset transforms (4.7 NEW): verify behavior with anchor-based layout before relying on it

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 001]: selection logic core (signal source)
- [Story 002]: bridge Node (input forwarding into the toolbar)
- [Story 003]: sell state machine (refund/confirm logic — this story renders the morph)
- Equipment Info Panel (#17): Vertical Slice, not MVP — only the Inspect button + open hook live here

---

## QA Test Cases

*Derived from GDD acceptance criteria. UI story — manual walkthrough plus automated state assertions where practical.*

- **AC4**: Move 交接
  - Setup: a piece selected
  - When: Move pressed
  - Then: selection cue clears; PlacementSystem relocate-ghost appears at the piece's position within one frame
  - Edge cases: Move while PlacementSystem already dragging (button disabled); Move then cancel (Placement's flow)

- **AC8**: 色盲可辨
  - Setup: any piece selected; desaturate the screen
  - Verify: selection state legible from outline shape + corner icon alone
  - Pass condition: no information carried by color alone

- **Core Rule 2**: 选中提示
  - Setup: select a piece
  - Verify: 2px Soft Charcoal outline + tint glow + corner icon; ≤1 breathe cycle ~1.5s; no flash
  - Pass condition: calm, colorblind-safe cue; no harsh flash

- **Toolbar**: 工具栏可用性
  - Setup: piece selected; then start a placement drag
  - Verify: Inspect/Move/Sell visible near the piece; Move disabled during drag
  - Pass condition: toolbar adapts to nearest free side; Move disabled when `is_dragging()`

---

## Test Evidence

**Story Type**: UI
**Required evidence**:
- [x] `production/qa/evidence/selection-toolbar-evidence.md` — manual walkthrough / sign-off
- [x] Automated coverage of Move-handoff state transitions (AC4) + toolbar/cue state:
  - `tests/unit/selection_system/toolbar_state_test.gd` — 60 asserts: AC4 Move handoff (selection clears instantly + PlacementSystem DRAGGING/relocate ghost picks up), Move disabled during drag (UX AC, per-frame poll), Sell morph (started label "Confirm sell +$X" with exact refund / confirm completes sale / revert restores "Sell"), Inspect open hook, swap/deselect/reduced-motion, double-init guard
  - `tests/unit/selection_system/selection_cue_test.gd` — 27 asserts: Core Rule 2 (Soft Charcoal outline, footprint rect, zone-derived tint, corner icon shape), AC8 colorblind (shape+icon, fixed outline color), one ~1.5s breathe cycle + clamp, reduced-motion static, swap/deselect, double-init guard
  - `tests/unit/selection_system/sell_flow_test.gd` — 64 asserts: SEL-003's sale logic ported to the MERGED bridge API (request_sell_confirm/confirm_sell/_on_sell_confirm_timeout(generation)) — the parent branch's on_sell_pressed/on_sell_confirmed naming was never merged; AC5/6/7/13/14/15 + guards

**Status**: Complete — headless suite 5028 passed, 0 failed (4877 pre-existing + 64 sell_flow + 60 toolbar + 27 cue)

**Composition wiring**: `SimulationOrchestrator` passes `economy` into `SelectionSystem.init(..., economy)` and connects `sel_bridge.sell_confirm_confirmed → selection_system.sell_selected` (typed, Control Manifest). The toolbar/cue are presentation Controls wired by the game scene via `init()` with typed signal connections (the same pattern as Hud/BuildShopPalette); the unit rigs wire them exactly as the composition root does.

---

## Dependencies

- Depends on: Story 003 (sell state machine), Story 002 (bridge driving the toolbar); PlacementSystem (`begin_relocate`, `is_dragging` — exist)
- Unlocks: None (completes the interactive selection surface; Story 005 can land in parallel)
