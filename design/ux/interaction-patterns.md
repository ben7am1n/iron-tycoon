# Interaction Pattern Library — 撸铁大亨 (Iron Tycoon)

> **Status**: ✅ Approved (2026-08-02 — ux-design gate, gate-check item #4)
> **Author**: user + ux-designer
> **Last Updated**: 2026-08-02
> **Template**: Interaction Pattern Library
> **Implements Pillar**: Pillar 1 (空间即玩法 — the interactions that make layout the game) · Pillar 3 (一眼看懂 — consistent, legible interaction language) · Pillar 2 (松弛不紧绷 — every pattern is calm, safe, and reversible-in-spirit)
> **Input & Platform**: Keyboard/Mouse primary (drag-and-drop), Gamepad partial, Touch none. Target: PC desktop (macOS primary, Windows secondary). See `.claude/docs/technical-preferences.md`.

---

## Overview

This library defines the shared interaction vocabulary for every screen in the game.
The core loop's signature interaction — **drag-snap** (pick equipment from the shop,
drag it onto the grid, see it snap to cells) — was **validated in vertical slice A3**
(see `prototypes/gym-flow-vertical-slice/REPORT.md` §2: deterministic anchor, rotate,
valid/invalid, re-layout all pass). The remaining patterns below are specified so that
Selection UI, HUD, Shop, and the flow overlay all speak one consistent language before
they enter `/team-ui`.

Design principles that govern all patterns:
1. **Calm over alarm** — no red warnings, no flashing, no failure buzzes (Pillar 2, art bible).
2. **Shape + icon + text, never color alone** — colorblind-safe dual channel (accessibility-requirements.md §3.1).
3. **Safe experimentation** — nothing destructive happens on a single careless gesture; everything meaningful is either soft-confirmed or cost-free to retry (Pillar 2).
4. **One mode at a time** — build (placement drag), select (curation), and overlay diagnosis never fight the cursor (GDD #15 Core Rule 4).

---

## Pattern Catalog

| Pattern | Category | Used In |
|---|---|---|
| [Drag-Snap Placement](#drag-snap-placement) | Input / Spatial | Shop (build), Selection (move) |
| [Ghost Preview + Rejection Feedback](#ghost-preview--rejection-feedback) | Feedback / Spatial | Shop (build), Selection (move) |
| [Click Select / Deselect](#click-select--deselect) | Input / Selection | Selection UI, flow overlay |
| [Selection Cue](#selection-cue) | Data Display / Feedback | Selection UI |
| [Contextual Action Toolbar](#contextual-action-toolbar) | Navigation / Overlay | Selection UI |
| [Soft-Confirm](#soft-confirm) | Modal / Overlay | Selection UI (sell) |
| [Palette (edge-docked rack)](#palette-edge-docked-rack) | Navigation / Data Display | Shop |
| [Hover Tooltip](#hover-tooltip) | Feedback / Data Display | Shop, overlay, Selection |
| [Top-Bar HUD Transport](#top-bar-hud-transport) | Navigation / Input | HUD |
| [Status Meter (calm gauge)](#status-meter-calm-gauge) | Data Display | HUD (satisfaction) |
| [Count-Up Value](#count-up-value) | Feedback | HUD (money) |
| [Toggle Overlay (diagnostic)](#toggle-overlay-diagnostic) | Overlay / Navigation | Flow overlay |
| [Modal / Panel (blocking, rare)](#modal--panel-blocking-rare) | Modal / Overlay | Info panel, pause menu (future) |
| [Toast / Badge (avoid)](#toast--badge-avoid) | Feedback | none by default — see note |
| [Button Variants](#button-variants) | Input / Data Display | all screens |
| [Toggle (on/off control)](#toggle-onoff-control) | Input | HUD (overlay), settings (future) |
| [Scroll / Paging (catalog growth)](#scroll--paging-catalog-growth) | Navigation | Shop (future) |

---

## Patterns

### Drag-Snap Placement

**Category**: Input / Spatial
**Used In**: Shop (build flow), Selection (Move → relocate flow)

**Description**: The player presses the mouse down on a shop-palette item (or presses
Move on a selected piece), and the equipment attaches to the cursor as a grid-aligned
ghost. As the cursor moves, the ghost snaps cell-to-cell; a rotate key spins it
90° per press; releasing over a valid spot commits the placement, releasing over an
invalid spot (or pressing Esc / leaving the grid) returns the item to the palette
or restores the moved piece. **Validated in vertical slice A3**: deterministic anchor,
rotate, valid/invalid, and re-layout all pass (REPORT.md §2).

**Specification**:
- Drag starts on mouse-down over an affordable, unlocked palette item; the ghost
  immediately follows the cursor, snapped to the grid.
- Rotate: press **R** (or right-click) during drag → rotation `(rotation + 90) % 360`
  (PlacementSystem formula; GridSystem normalizes to `{0,90,180,270}`).
- Live preview: every cell the ghost covers shows valid/invalid tint (footprint vs
  access cells tinted separately — see Ghost Preview pattern).
- Commit: mouse-up over a valid cell → snap-in animation (art bible: 咔哒 + slight
  scale bounce, 120–250 ms).
- Cancel: Esc, mouse-up outside grid, or focus loss → silent return to palette /
  restore original position (relocate is never destructive to the grid).
- **One drag at a time**: a second mouse-down while dragging is a no-op; the palette
  is disabled during a drag (one-purchase-drag invariant, Shop GDD Core Rule 3).
- Input mapping: mouse drag (primary), R / right-click rotate, Esc cancel.

**Accessibility**:
- Keyboard: the palette must be navigable by Tab/arrows; pressing Enter on a palette
  item starts a "keyboard drag" — ghost follows arrow keys, R rotates, Enter commits,
  Esc cancels. (MVP: this path is required to exist, not to be polished.)
- Valid/invalid must not rely on color alone — the ghost also shows a footprint
  outline and, on invalid, the cursor-adjacent tooltip appears after ~400 ms hold
  (see Ghost Preview).

**When to Use**: Any time the player moves equipment onto or around the grid.
**When NOT to Use**: For selecting/curating already-placed pieces (use Click Select);
for bulk actions (multi-select is out of MVP by design, GDD #13 Core Rule 1).

**Reference**: vertical slice A3 — `prototypes/gym-flow-vertical-slice/` (placement_system.gd).

---

### Ghost Preview + Rejection Feedback

**Category**: Feedback / Spatial
**Used In**: Shop (build), Selection (move)

**Description**: While dragging, the footprint and access cells render as a translucent
ghost tinted by validity: valid cells in the piece's own tint, footprint-invalid in a
muted neutral, access-invalid in soft Dusty Rose — the split already implemented in
PlacementSystem/Overlay. When a drop is rejected, a single calm tooltip appears
cursor-adjacent **after the cursor holds ~400 ms over the invalid cell** (prevents
flicker while sweeping).

**Specification**:
- Two rejection buckets (GDD #8 Core Rule 6): footprint bucket → *"Won't fit here"*;
  access bucket → *"Blocks the path in"*. No sound on rejection (silence, not a buzz).
- Tooltip dismiss: cursor leaves the invalid cell, drag ends, or Esc.
- Ghost stays full-opacity during drag; ambient layers (heatmap) dim to ≤20% so the
  ghost reads clearly (GDD #8 Core Rule 7 contention rule).

**Accessibility**: tooltip is supplementary — the ghost's footprint outline + tint
split carries the state; no color-only signal.

**When to Use**: Every placement/relocate drag.
**When NOT to Use**: For non-spatial confirmations (use Soft-Confirm or inline labels).

---

### Click Select / Deselect

**Category**: Input / Selection
**Used In**: Selection UI, flow overlay

**Description**: A single click on a placed piece selects it; clicking empty
buildable floor or pressing Esc deselects; clicking a *different* placed piece swaps
selection directly (no deselect-first). Clicking the already-selected piece is a
no-op (never a toggle-off — protects a panel the player is reading, GDD #13 Core Rule 1).

**Specification**:
- Selection is single-select only (MVP; multi-select deliberately out).
- During an active placement drag, clicks on the grid do NOT resolve a new selection
  (modes never fight — Build/Shop UI arbitration).
- Input mapping: left-click select/swap, Esc or click-empty deselect, Del = sell
  soft-confirm shortcut.

**Accessibility**: keyboard path — Tab to focus the grid, arrow keys move a cell
cursor, Enter selects the piece under the cursor, Esc deselects. Focus indicator
(cell cursor) is visually distinct from the selection cue.

**When to Use**: Curation of already-placed pieces.
**When NOT to Use**: For placing new pieces (Drag-Snap), or any time a drag is active.

---

### Selection Cue

**Category**: Data Display / Feedback
**Used In**: Selection UI

**Description**: The selected piece is marked by: a Soft Charcoal 2px outline around
its footprint cells, a subtle glow in the piece's own tint, and a small corner
"selected" icon — at most one slow ~1.5 s breathe cycle, no harsh flash (GDD #13
Core Rule 2).

**Specification**:
- Cue appears within one frame of selection; disappears within one frame of deselect.
- The corner icon carries the state even if outline contrast is missed (colorblind-safe).
- Under reduced-motion: static outline + icon, no breathe cycle.

**When to Use**: Any selected placed piece.
**When NOT to Use**: For keyboard *focus* (use the focus indicator — they must remain
visually distinct so "focused" never reads as "selected").

---

### Contextual Action Toolbar

**Category**: Navigation / Overlay
**Used In**: Selection UI

**Description**: When a piece is selected, a small toolbar (Inspect / Move / Sell)
appears anchored near the selection — not a blocking modal. It appears with the
selection and disappears on deselect. Inspect opens the Equipment Info Panel; Move
hands off to the placement relocate flow (selection clears instantly); Sell morphs
into a soft-confirm button (see Soft-Confirm).

**Specification**:
- Toolbar never covers the selected piece; it offsets to the nearest free side.
- Move is disabled while PlacementSystem is dragging (`is_dragging()` query, GDD #13 Edge Cases).
- Keyboard: Tab reaches the toolbar from the grid cursor; Left/Right switch buttons;
  Enter activates.
- Buttons use standard button variants (see below).

**When to Use**: Contextual actions on a selected object.
**When NOT to Use**: When the action set is global or the panel needs to persist
while reading (use a persistent Panel).

---

### Soft-Confirm

**Category**: Modal / Overlay
**Used In**: Selection UI (sell)

**Description**: A destructive-ish action never asks "ARE YOU SURE?" — instead the
action button **morphs in place** into a temporary confirm state: pressing Sell
turns the button into **"Confirm sell +$X"** for **2 s** (warm Butter tone, the money
color — never alarm red). A second click within the window completes the action; a
timeout (2 s), Esc, or click-away reverts the button. **No destructive default** —
it never auto-sells.

**Specification**:
- Window: 2 s (tuning knob, safe range 1.5–3 s).
- The confirm state must show the *consequence* ("+$X") — the player confirms what
  they get, not just that they meant it.
- Revert animation is the same morph reversed; the button returns to normal.
- Keyboard: Del triggers the same soft-confirm (never bypasses it); Enter confirms
  while pending; Esc cancels.

**Accessibility**: The confirm state is text + shape (button morph) — never a color
flash; the 2 s window is generous and has no ticking urgency.

**When to Use**: Any action with a lasting consequence that should be deliberate but
not scary (sell, reset, and — future — delete-zone).
**When NOT to Use**: For reversible or free actions (pick-up, move, toggle) — adding
confirmation friction would break the calm loop.

---

### Palette (edge-docked rack)

**Category**: Navigation / Data Display
**Used In**: Shop

**Description**: The purchasable equipment catalog renders as a rack of tiles along
one screen edge (bottom edge recommended for a 16:9 desktop; side edge for narrower
windows — see `build-shop-ui.md` OQ1 decision). Each tile: equipment icon, name,
price in Butter. States: **affordable** (full tint, draggable), **unaffordable**
(greyed/desaturated, inert, hover shows "Save $X more"), **locked** (greyed + lock
icon, inert, hover shows unlock hint).

**Specification**:
- Palette re-evaluates states on `balance_changed` — an item lights up the instant
  it's affordable (GDD #15 Core Rule 1).
- During a placement drag the palette is disabled (one-drag invariant).
- Tile hover: full-tint lift + tooltip (price, short description); greyed hover:
  "Save $X more" where `X = cost - balance` (mandatory, Shop GDD Core Rule 4).
- Silent-cancel cue: when a drag ends in a silent cancel, the palette item returns
  to idle with a lightweight visual/audio return cue (mandatory — the resolution
  must not be invisible, Shop GDD Core Rule 4b).
- Keyboard: Tab/arrows move the tile focus; Enter starts a keyboard drag.

**Accessibility**: States distinguishable without color (desaturation + lock icon +
text tooltip; see accessibility-requirements.md §4). Tile text ≥16px @1080p.

**When to Use**: A bounded list of purchasable/buildable items the player needs to
see at a glance.
**When NOT to Use**: When the list outgrows one screen — add Scroll/Paging rather
than making tiles smaller.

---

### Hover Tooltip

**Category**: Feedback / Data Display
**Used In**: Shop, flow overlay, Selection (info)

**Description**: A small text bubble appears near the cursor after a short hover
(~400 ms) on an element with additional info. It must **augment** — never be the
sole channel for critical information.

**Specification**:
- Delay ~400 ms; dismiss on mouse-leave, Esc, or after 4 s — never requires a click.
- Position: cursor-adjacent, clamped to screen; never covers the element it explains.
- Rejection tooltips (Ghost Preview) reuse this pattern with a hold-trigger.

**Accessibility**: Tooltips are supplementary; all critical states are readable from
persistent UI. Tooltip text ≥14px, AA contrast.

**When to Use**: Extra detail on hover (prices, "save X more", access-blocked reason).
**When NOT to Use**: For information needed to play (must be persistent) or for
actions (use buttons).

---

### Top-Bar HUD Transport

**Category**: Navigation / Input
**Used In**: HUD

**Description**: The pause/speed cluster sits top-right of the HUD: four small
buttons — **‖ (pause), 1×, 2×, 3×** — the active one marked by outline + filled-dot
icon (never color alone). Hotkeys: Space = toggle pause; 1/2/3 = set speed directly
(implicitly unpausing — one action, not two).

**Specification**:
- Speed buttons show active state via outline + filled dot; clicking an active
  speed again is a no-op.
- On load the HUD renders paused immediately (TimeSystem starts paused).
- Keyboard: Space, 1, 2, 3 (also Tab/Enter for click-free access).

**Accessibility**: Active speed legible without color (outline + dot); focus order
left-to-right across the cluster.

**When to Use**: Any time the player needs global transport (always on HUD).
**When NOT to Use**: For screen-specific actions (use that screen's controls).

---

### Status Meter (calm gauge)

**Category**: Data Display
**Used In**: HUD (satisfaction)

**Description**: A short horizontal meter that reads as a calm gauge, **never** a
"health bar" (which reads as danger). Fill ramps Sage (high) → warm neutral (mid) →
soft muted Dusty Rose only at the very low end. Always paired with numeric % **and**
a small face/heart icon whose shape changes (filled vs outline) — never red, never
pulsing, regardless of value.

**Specification**:
- Eases to new value over ~1 s (reinforces "this moves slowly, don't panic").
- Reduced-motion: static fill, no ease animation (values still update).
- The % number and shape icon always update with the fill.

**When to Use**: Any slow-moving, sentiment-style value (satisfaction, later:
reputation).
**When NOT to Use**: For fast, decision-critical values (those need Count-Up or
event-driven display).

---

### Count-Up Value

**Category**: Feedback
**Used In**: HUD (money)

**Description**: A static icon + number; when the value changes, the digits tween
(count up/down over ~0.3 s) rather than snapping. On spend, no red flash — a brief
desaturation-then-settle is acknowledgment enough.

**Specification**:
- Re-targets mid-tween to the latest value (no queue backlog on rapid changes).
- Reduced-motion: snap to the new value (no tween), same end state.

**When to Use**: Frequently-updated single values (money).
**When NOT to Use**: For gauges (Status Meter) or for values that should feel slow (satisfaction).

---

### Toggle Overlay (diagnostic)

**Category**: Overlay / Navigation
**Used In**: Flow overlay

**Description**: The congestion/flow diagnostic is toggle-gated (hotkey **H** or a
HUD button): per-cell heatmap + per-equipment congestion glyphs fade in/out together
(~250 ms). Default OFF; the heatmap auto-dims to ≤20% during placement drags. The
**access-blocked layer is always-on and never gated** — it must survive every other
layer's visibility rule (GDD #8 Core Rule 1).

**Specification**:
- First-ever toggle in a session shows a one-time contextual tip (~4 s, auto-dismiss,
  never shown again).
- No persistent legend — legend popover on hover only (GDD #8 Core Rule 8).
- Heatmap reads as soft fog (bilinear-sampled ImageTexture + shader, isolated from
  the global Nearest filter); glyphs are outline-to-filled shape-first.

**Accessibility**: The heatmap is a *supplemental* channel — crowding is also
communicated by the shape glyphs and the always-on access-blocked icons; the toggle
is keyboard-reachable (H).

**When to Use**: Any diagnostic overlay that would clutter the calm default state.
**When NOT to Use**: For information that must always be visible (access-blocked).

---

### Modal / Panel (blocking, rare)

**Category**: Modal / Overlay
**Used In**: Equipment Info Panel (future, #17), pause menu (future)

**Description**: A rare, deliberate blocking surface used only when the player needs
focused reading or decision. Everything else in the game prefers non-blocking
patterns (toolbar, soft-confirm in place) to preserve the calm flow.

**Specification**:
- Appear: fade + slight scale (120–250 ms); dismiss: reverse, or Esc.
- Focus is moved into the panel on open and returned to the invoking element on close.
- Esc always closes; a visible Close button also exists.
- Dim the play area behind softly (never a harsh overlay).

**Accessibility**: Focus trap is allowed **only** with a documented Esc exit; panel
must be keyboard-navigable; no content flash on open.

**When to Use**: Info panels, settings, confirm-a-larger-scope action.
**When NOT to Use**: For single-object quick actions (use Contextual Toolbar +
Soft-Confirm).

---

### Toast / Badge (avoid)

**Category**: Feedback

**Description**: Explicitly **avoided as a general pattern**. The HUD GDD Core Rule 5
forbids popups/toasts/badges on the HUD; event feedback belongs to in-world
micro-feedback (VFX: coin particles, satisfaction hearts, sweep effects — art bible §9),
not to screen-corner notifications. If a future system needs transient global
feedback, revisit this decision through the pillar lens (calm, not alarming) before
adopting toasts.

**When NOT to Use**: Default — do not add toast/badge systems to the MVP without
flagging a pillar conflict.

---

### Button Variants

**Category**: Input / Data Display
**Used In**: All screens (toolbar, palette tiles, transport cluster, future panels)

**Description**: A small, consistent family of button treatments so every interactive
control in the game speaks one visual language. Derived from the art bible's rounded,
warm, pixel-outlined UI direction (§7) and the calm (Pillar 2) + colorblind-safe
(dual-channel) rules.

**Specification**:
- **Primary button** — solid warm fill (Butter or Sage), Soft Charcoal outline,
  ≥ 40px tall @1.0× UI scale. Used for the single most-likely action in a context
  (e.g. "Inspect", "Confirm sell +$X").
- **Secondary button** — Warm Cream fill, Soft Charcoal outline. Used for
  alternatives ("Move", "Sell" at rest).
- **Icon button** — icon-only, ≥ 32px hit target, tooltip on hover; active state
  carried by outline + filled-dot (e.g. speed buttons ‖ 1× 2× 3×, overlay toggle).
- **Disabled state** — desaturated + reduced opacity; **never** greyed in a way that
  looks like an unaffordable shop tile (disabled = temporarily unavailable action;
  greyed tile = unaffordable item — distinct treatments, see Palette pattern).
- **Soft-confirm morph** — a secondary button that morphs in place into a primary
  confirm state (Sell → "Confirm sell +$X") with a consequence label; see
  Soft-Confirm pattern.
- Hover: lift + tint (100 ms); Press: 1–2px inset; Focus: 2px outline + inset shadow
  (distinct from selection cue).
- All buttons: keyboard-activatable (Tab + Enter/Space), ≥16px label @1080p, AA contrast.

**When to Use**: Any tappable action.
**When NOT to Use**: For spatial drag interactions (Drag-Snap) or data display
(Status Meter / Count-Up).

---

### Toggle (on/off control)

**Category**: Input
**Used In**: HUD (flow-overlay toggle), settings (future #22)

**Description**: A binary on/off control whose state is visible from its persistent
visual (icon + active treatment), not only while interacting.

**Specification**:
- Persistent state cue: ON = filled-dot + outline highlight; OFF = outline only
  (never color alone).
- Keyboard: Tab to focus, Enter/Space toggles; hotkey shortcut mirrors it (H for
  flow overlay).
- Immediate effect with ~250 ms fade for overlays; toggles that change game behavior
  show their consequence in-world, not via a toast.
- Reduced-motion: state flips instantly (no slide animation).

**When to Use**: Binary settings and layer visibility.
**When NOT to Use**: When the player needs to choose among 3+ states (use the speed
cluster / segmented buttons instead of stacked toggles).

---

## Standard Controls — Not Applicable to MVP

The following standard UI controls are **not required** for the MVP surface and have
no pattern here: **slider** (no continuous-value inputs in MVP; settings use
discrete options), **dropdown / combo box** (no list-in-a-button needed; palettes
use the always-visible rack), **input field** (no free-text entry in MVP),
**tab bar** (no multi-section panels; the info panel #17 will revisit), **progress
bar** (no long operations in MVP; satisfaction uses the Status Meter instead of a
progress metaphor), **data table** (no tabular data screens). If a future system
needs one, it must be added to this library *before* the story that uses it enters
`/team-ui`.

---

### Scroll / Paging (catalog growth)

**Category**: Navigation
**Used In**: Shop (future — catalog > one screen)

**Description**: If the purchasable catalog grows beyond the palette's screen budget,
add paging or a scroll wheel over the rack **without** shrinking tiles below the
minimum tap/read size.

**Specification**: Page indicators (shape + number, not color-only); keyboard
PageUp/PageDown; wheel scroll over the rack; focus follows paging.
**When to Use**: Catalog > ~8–10 tiles at MVP tile size.
**When NOT to Use**: At MVP catalog size (~5–6 items) — paging would add friction
for no benefit.

---

## Animation Standards

| Element | Default | Duration | Reduced-motion |
|---|---|---|---|
| Panel/modal enter | fade + slight scale | 120–250 ms | fade only |
| Panel/modal exit | reverse | 120–250 ms | fade only |
| Palette tile hover | lift + tint | 100 ms | none (static tint) |
| Selection cue | outline+glow appear; slow breathe | 150 ms appear; 1.5 s cycle | static, no breathe |
| Drag snap-in | snap 咔哒 + scale bounce | 120–250 ms | snap only (no bounce) |
| Money count-up | digit tween | ~0.3 s | snap |
| Satisfaction ease | fill tween | ~1.0 s | snap |
| Heatmap toggle | fade in/out | ~250 ms | instant |
| Heatmap drag-dim | fade to ≤20% | ~150 ms | instant |
| Overlay tip | fade in/out | ~300 ms in, auto 4 s | instant |

All motion must respect the art bible: no screen shake, no strobe, no flash ≥3/sec,
everything soft-eased (art bible §7, §9).

## Sound Standards

| Event | Treatment | Pillar guard |
|---|---|---|
| Placement commit | soft 咔哒 + subtle confirm | satisfying, not sharp |
| Drag pick-up | soft "pick up" cue (nice-to-have) | never intrusive |
| Money income | gentle coin tick (nice-to-have) | never a cash-register clatter |
| Pause/speed | soft click (nice-to-have) | never an alarm |
| Sell confirm | soft "sold" cue (nice-to-have) | gentle, warm |
| Rejection | **silence** | no failure buzz (GDD #8) |
| Access-blocked | quiet one-time cue on appear (nice-to-have) | never a loop/alarm |

All sound is optional at MVP (Audio #21 is Vertical Slice); the silence rules are
mandatory regardless.

---

## Navigation & Back Consistency

- **Esc** is the universal cancel/deselect: deselects, cancels pending soft-confirms,
  cancels drags, closes panels. One behavior everywhere.
- **One mode at a time**: only one of (placement drag, selection, overlay-edit) is
  visually active; entering one suppresses the other (GDD #15 Core Rule 4).
- **No back-stack** at MVP — screens are shallow (HUD is always-on; shop palette is
  edge-docked, not a separate screen; info panel opens/closes on selection). A
  formal back-stack only arrives with a pause menu / full-screen shell (HUD OQ2).

---

## Gaps & Patterns Needed

| Gap | Status | Owner |
|---|---|---|
| Gamepad navigation order (HUD + palette + grid cursor) | Open — see accessibility-requirements.md AQ2 | ux-designer / ui-programmer |
| Equipment Info Panel (#17) patterns (tabbed info? stat rows?) | Deferred until #17 is designed | ux-designer |
| Pause menu shell (settings, save/load access) | Deferred — HUD OQ2 | producer / ux-designer |
| Keyboard drag full polish | MVP requires existence, polish deferred | ui-programmer |

---

## Open Questions

| # | Question | Owner | Target Resolution |
|---|---|---|---|
| OQ1 | Palette edge (bottom vs side) and tile size — recommended bottom rack, 16:9; confirm in `/team-ui` Phase 1 (also recorded in build-shop-ui.md). | ux-designer / ui-programmer | team-ui kickoff |
| OQ2 | Build/select mode affordance — MVP leans **implicit** (mouse-down palette = build; click placed piece = select). Confirm no explicit mode toggle needed. | ux-designer | team-ui kickoff |
| OQ3 | Whether the "keyboard drag" (arrows + Enter) ships polished in MVP or as a functional-but-basic path. Accessibility tier requires existence; polish is a scope call. | producer / ui-programmer | MVP scoping |
