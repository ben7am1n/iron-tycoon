# UX Spec: Selection UI

> **Status**: ✅ Approved (2026-08-02 — ux-design gate, gate-check item #4)
> **Author**: user + ux-designer
> **Last Updated**: 2026-08-02
> **Journey Phase(s)**: Unknown — no player journey map yet (see Open Questions OQ1)
> **Template**: UX Spec
> **Platform Target**: PC desktop (macOS primary, Windows secondary); Keyboard/Mouse primary, Gamepad partial, Touch none
> **Source GDD**: `design/gdd/selection-system.md` (#13) — normative for rules; this spec is the visual/interaction formalization.
> **Implements Pillar**: Pillar 1 (空间即玩法 — curating your placed layout) · Pillar 2 (松弛不紧绷 — safe, no-regret experimentation) · Pillar 3 (一眼看懂 — clear, calm selection state)

---

## Purpose & Player Need

The player arrives at the Selection UI context wanting to **inspect, move, or sell
equipment that is already placed on the grid** — the curator's tool. The player goal:
"look over this machine, nudge it somewhere better, or sell the one that never fit —
and none of it should feel risky." If this interaction were hard to use, the core
"再挪一下试试" loop would stall: rearranging is half of Pillar 1, and a selection
that is unclear, fights the placement drag, or punishes selling would break Pillar 2's
safe-experimentation promise. The single most important thing: **the selected piece is
unambiguous, and every action (Inspect / Move / Sell) is one obvious, calm step away.**

---

## Player Context on Arrival

- **When first encountered**: immediately after the player has placed a few pieces
  (they will naturally click a placed machine to see what it is).
- **What they were just doing**: placing equipment via the shop palette, or watching
  members flow and noticing a bottleneck (a crowded or idle machine) they want to fix.
- **Emotional state**: curious and in-control (calm, exploring) — the game has no
  failure states, so no stress to assume.
- **Voluntary or sent**: voluntary — the player clicks a placed piece because they
  want to do something with it; the game never forces selection.

---

## Navigation Position

This lives **in-game, on the grid itself** — it is not a separate screen. The context:

```
[Main menu]
   └─ [Game session (HUD always on)]
        ├─ Shop palette (edge-docked, always available)
        ├─ Grid interaction: click placed piece → SELECTION MODE  ← this spec
        │     ├─ Inspect → Equipment Info Panel (opens on top)
        │     ├─ Move → Placement relocate drag (hands off to build mode)
        │     └─ Sell → soft-confirm → removed
        └─ Flow overlay (toggle H) — can coexist; selection cue and overlay layers
           are independent (overlay access-blocked icons stay visible during selection)
```

It is a **context-dependent state** (only when a piece is selected), not a
top-level destination. It is reachable from anywhere on the grid; the only "entry"
is clicking a placed piece (or keyboard grid-cursor Enter).

---

## Entry & Exit Points

| Entry Source | Trigger | Player carries this context |
|---|---|---|
| Game grid | Click a placed piece (SelectionSystem resolves cell → occupant) | The selected instance; grid layout unchanged |
| Game grid | Keyboard grid cursor + Enter on a placed piece | Same as above |

| Exit Destination | Trigger | Notes |
|---|---|---|
| None selected | Click empty buildable floor / Esc | Toolbar + cue disappear; `selection_changed(null)` fires |
| Another selection | Click a different placed piece | Direct swap — no intermediate deselect |
| Placement relocate (build mode) | Press Move | Selection clears instantly; ghost handed off to PlacementSystem |
| (piece removed) | Sell confirmed / piece removed externally | Selection clears; `selection_changed(null)` fires |
| Equipment Info Panel | Press Inspect | Panel opens above; selection remains active underneath |

---

## Layout Specification

### Information Hierarchy

1. **The selected piece** — the single most important thing; the cue must be instant and unambiguous.
2. **What I can do with it** — Inspect / Move / Sell, visible near the piece (secondary to the cue, but within one glance).
3. **What I'll get if I sell** — the +$X amount appears *inside the confirm morph* (consequence before committing).
4. (Discoverable, not immediately visible) — piece details (name, stats, effects) in the Info Panel behind Inspect.

### Layout Zones

```
┌──────────────────────────────────────────────────────────────┐
│ [HUD top bar — money, satisfaction, day/time, transport]      │
│                                                               │
│                                          ┌──────────┐         │
│                                          │ Inspect  │         │
│    ░░░░░░░░░░░░░░░░░░░░░░░░              ├──────────┤         │
│    ░░ ╔══════════╗ ░░░░░░░░              │ Move     │         │
│    ░░ ║ [tread]◥ ║ ░░░░░░░░              ├──────────┤         │
│    ░░ ╚══════════╝ ░░░░░░░░              │ Sell ──► │         │
│    ░░░░░░░░░░░░░░░░░░░░░░░░              │ "Confirm │         │
│           ▲ 2px Soft Charcoal outline    │  sell    │         │
│           + corner selected icon         │  +$175"  │         │
│                                           └──────────┘         │
│  [Shop palette rack — bottom edge]                             │
└──────────────────────────────────────────────────────────────┘
```

- **Zone A — Grid**: the play area; the selection cue renders over the selected footprint cells.
- **Zone B — Contextual toolbar**: anchored near the selection, offset to the nearest free side (never covering the piece).
- **Zone C — HUD**: unchanged; no HUD element changes during selection.
- **Zone D — Shop palette**: remains visible but **suppresses the new-placement ghost** while a selection is active (mode arbitration); palette items stay interactive except during a drag.

### Component Inventory

| Component | Type | Content | Interactive | Pattern |
|---|---|---|---|---|
| Selection cue | outline + glow + corner icon | marks selected footprint | no | Selection Cue |
| Toolbar: Inspect | button | "Inspect" | yes | Contextual Action Toolbar |
| Toolbar: Move | button | "Move" | yes (disabled during placement drag) | Contextual Action Toolbar |
| Toolbar: Sell | button → morphs | "Sell" → "Confirm sell +$X" (2 s) | yes | Soft-Confirm |
| (opens) Equipment Info Panel | panel | piece name/stats/effects | yes (close) | Modal/Panel (#17 — future) |

### ASCII Wireframe

See Layout Zones above; the wireframe is the canonical top-down view:
selected treadmill (1×2) with outline + corner icon, toolbar offset right,
palette along the bottom, HUD top bar. Toolbar positions adapt to the nearest free
side if the piece is at a screen edge.

---

## States & Variants

| State / Variant | Trigger | What Changes |
|---|---|---|
| Default | A placed piece is selected | Cue (outline+glow+icon) + toolbar appear within one frame |
| None selected | No piece selected | Nothing shown — no cue, no toolbar |
| Swap | Click a different placed piece | Cue + toolbar move to the new piece within one frame (no flicker) |
| Sell-confirm pending | Sell pressed | Sell button morphs to "Confirm sell +$X" (Butter) for 2 s |
| Sell-confirm reverted | 2 s elapse / Esc / click-away | Button reverts to "Sell"; no sale |
| Move handoff | Move pressed | Selection clears; Placement relocate drag begins |
| External invalidation | Selected piece removed (sold elsewhere / grid change) | Selection clears; `selection_changed(null)` fires |
| During placement drag | A purchase drag is active | Selection suppressed — clicks don't resolve (modes never fight) |
| Loading | (n/a) | **No loading state**: selection resolves synchronously from GridSystem/SelectionSystem state; nothing is fetched async |
| Reduced-motion variant | Setting ON | Selection cue static (no breathe); sell morph still instant |

---

## Interaction Map

Input methods: **Keyboard/Mouse** (primary), Gamepad partial (stretch). Mapping for keyboard/mouse:

| Component | Action | Input | Immediate feedback | Outcome |
|---|---|---|---|---|
| Placed piece | Select | Left-click | Cue + toolbar appear (1 frame) | `selection_changed(id, def, cell, rot)` fires |
| Empty floor | Deselect | Left-click | Cue + toolbar disappear | `selection_changed(null)` fires |
| (any) | Deselect / cancel | Esc | Cue + toolbar disappear; cancels pending soft-confirm | `selection_changed(null)` fires (if selected) |
| Different placed piece | Swap | Left-click | Cue + toolbar move (1 frame) | Selection swaps directly |
| Same selected piece | Re-click | Left-click | **No-op** — nothing flickers | No signal (GDD #13 Core Rule 1) |
| Inspect button | Open info | Left-click / Enter | Panel opens | Equipment Info Panel (#17) shows piece |
| Move button | Relocate | Left-click / Enter | Selection clears; ghost appears at piece position | PlacementSystem relocate begins |
| Sell button | Start soft-confirm | Left-click / Enter / **Del** | Button morphs to "Confirm sell +$X" | Pending state (2 s) |
| Confirm sell | Complete sale | Left-click / Enter (while pending) | Piece fades out gently; money credits | Economy credit; selection clears |
| Grid cursor (keyboard) | Move focus | Arrows | Focus cell indicator moves | cell cursor moves |
| Grid cursor | Select | Enter | Cue + toolbar appear | same as click select |
| (all) | Cancel drag/pending | Esc | reverts / deselects | universal cancel |

**Keyboard-only path**: Tab → grid focus; arrows move cell cursor; Enter selects;
Tab continues to toolbar (Inspect → Move → Sell); Left/Right switch toolbar buttons;
Enter activates; Del triggers soft-confirm on the Sell button; Esc deselects/cancels.
This path must exist and reach all elements (MVP polish level per interaction-patterns.md OQ3).

**Gamepad (partial)**: d-pad moves the grid cursor; A selects; B cancels (Esc-equivalent);
X opens Inspect; Y = Move; no gamepad-specific sell shortcut (MVP — see AQ2).

---

## Events Fired

| Player Action | Event Fired | Payload / Data |
|---|---|---|
| Select a piece | `selection_changed(instance_id, equipment_def, cell, rotation)` | instance id, def, anchor cell, rotation |
| Deselect | `selection_changed(null)` | — |
| Swap selection | `selection_changed(...)` (new piece) | new instance payload |
| Move pressed | `begin_relocate(instance_id)` (PlacementSystem) | instance id |
| Sell confirmed | Economy `credit(refund)` + grid removal | refund amount; piece removed |
| Inspect pressed | (Info Panel #17 open) — no analytics event | — (analytics later, none in MVP) |
| Sell-confirm reverted | none | deliberate: a timeout/cancel is not an event |

Note: Sell modifies persistent economy state (refund) — flagged for architecture
attention (Economy credit path is an interface gap, GDD #13 Core Rule 7 / OQ1).

---

## Transitions & Animations

- **Enter (selection appears)**: cue + toolbar fade/slide in ~150 ms (cue outline + glow; toolbar scales from the piece). No flash.
- **Exit (deselect)**: reverse ~120 ms fade out; instant removal acceptable.
- **Swap**: cue moves directly to the new piece (~150 ms) — no intermediate deselect animation.
- **Sell morph**: button morphs to "Confirm sell +$X" over ~120 ms (Butter); reverts on timeout/Esc (reverse morph).
- **Sell success**: piece **fades out gently** (~300 ms) — no destruction particles/sound (GDD #13 Visual/Audio).
- **Reduced motion**: cue static (no breathe), morph instant, fade still applies (information, not decoration).

---

## Data Requirements

| Data | Source System | Read / Write | Notes |
|---|---|---|---|
| Selected instance id | SelectionSystem | Read | from click resolution |
| Equipment def (name, stats) | EquipmentCatalog | Read | for info panel + refund basis |
| Anchor cell + rotation | SelectionSystem (mapping) | Read | rebuilt from GridSystem on load (GDD #13 Core Rule 8) |
| Refund amount | Economy (credit path) | Read (computed) | `int(round(refund_rate × cost))`; refund_rate Economy-owned (provisional 0.5) |
| Balance (for +$X display) | Economy | Read | updates live during pending state |
| Grid occupant at cell | GridSystem `get_occupant_id(cell)` | Read | click resolution |
| Placement drag state | PlacementSystem `is_dragging()` | Read | disables Move; suppresses selection during drag |

**Ownership guard**: no game state is owned by the UI — SelectionSystem holds
selection; the toolbar is pure presentation + input routing (bridge Node).

**Update frequency**: cue/toolbar update on `selection_changed` (event-driven);
balance display during pending sell reads current value (no polling).

**Null handling**: if the selected instance no longer resolves (external removal),
selection clears and `selection_changed(null)` fires (GDD #13 Edge Cases).

---

## Accessibility

- **Tier**: Standard (WCAG-AA) per `design/ux/accessibility-requirements.md`.
- Colorblind-safe selection cue: Soft Charcoal outline + corner icon (shape carries state) — AC8 of GDD #13.
- Keyboard path complete: Tab/arrows/Enter/Esc/Del (see Interaction Map); Del never bypasses the soft-confirm.
- **Focus vs selection distinction**: the keyboard grid-cursor focus indicator (2px outline + inset) is visually distinct from the selection cue (outline + corner icon) so "focused" never reads as "selected".
- Contrast: toolbar text ≥16px @1080p, AA; Butter confirm state contrasts on the palette background.
- No flashing: the breathe cycle is 1.5 s (≤1/sec); reduced-motion disables it.
- Screen reader: not applicable beyond standard UI labels (tier = Standard).

---

## Localization Considerations

| Element | Max chars (EN) | Risk |
|---|---|---|
| Toolbar labels (Inspect / Move / Sell) | ≤ 8 | LOW — short labels; "Confirm sell +$X" must fit one line at 1.5× UI scale (HIGH PRIORITY) |
| "Confirm sell +$X" | ~20 | **HIGH PRIORITY** — 40% expansion (e.g. DE "Verkauf bestätigen +175 $") must not wrap or clip at 1.5× scale |
| Refund amount formatting | locale-formattable | currency symbol position + thousands separators must not collide with icon |

---

## Acceptance Criteria

- [ ] **Screen opens/responds within 1 frame of click**: clicking a placed piece shows the selection cue + toolbar within one frame (~16 ms at 60fps), no perceptible delay.
- [ ] **All selection states work**: select, deselect (click-empty / Esc), direct swap, re-click no-op — each matches the GDD #13 AC1–AC3, AC9–AC10 behavior.
- [ ] **Sell soft-confirm works**: Sell → "Confirm sell +$X" for 2 s; second click sells (piece fades, balance credits `int(round(refund_rate × cost))` once); 2 s timeout / Esc reverts with no sale and no balance change.
- [ ] **Move hands off cleanly**: pressing Move clears the selection and PlacementSystem's relocate ghost appears at the piece's position within one frame; Move is disabled while a placement drag is active.
- [ ] **Modes never fight**: during an active placement drag, clicking the grid does not resolve a selection; with a piece selected, the new-placement ghost is suppressed.
- [ ] **Keyboard-only path**: Tab + arrows + Enter + Del + Esc reaches and operates every toolbar element and the grid cursor; Del triggers the same soft-confirm as clicking Sell.
- [ ] **Colorblind pass**: with the screen desaturated, the selected piece is still identifiable via outline shape + corner icon; sell-confirm state via button text/morph, not color.
- [ ] **Reduced-motion**: with reduced-motion ON, the selection cue is static (no breathe) and the sell morph is instant — no information is lost.
- [ ] **External invalidation**: if the selected piece is removed by another path, the selection clears and `selection_changed(null)` fires.
- [ ] **Resolution robustness**: at 1280×720, 1920×1080, and 2560×1440 with UI scale 1.5×, the toolbar, selection cue, and info-panel entry never overlap the selected piece or clip off-screen; text stays ≥16px @1080p.
- [ ] **Load robustness**: after a save load with placed pieces, the first click on a piece correctly selects it (SelectionSystem mapping rebuilt — GDD #13 Core Rule 8).

---

## Open Questions

| # | Question | Owner | Target Resolution |
|---|---|---|---|
| OQ1 | Player journey map not yet created. Template available at `.claude/docs/templates/player-journey.md`. Run `/ux-design` Phase 2b or create it manually to establish player context for this screen. | ux-designer / producer | Before first UI playtest |
| OQ2 | Equipment Info Panel (#17) layout is not specced (Vertical Slice) — this spec only opens it; its internal layout gets its own `/ux-design` when #17 is designed. | ux-designer | When #17 starts |
| OQ3 | Toolbar exact anchor offset (nearest free side) and keyboard-drag polish level — presentation decisions to confirm in `/team-ui` Phase 1. | ux-designer / ui-programmer | team-ui kickoff |
