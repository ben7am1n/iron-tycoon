# Build/Shop UI

> **Status**: Designed (2026-07-20 design-review: B1 hover 反馈 AC 已补 + OQ3 可关闭)
> **Author**: user + agents
> **Last Updated**: 2026-07-20
> **Implements Pillar**: Pillar 1 (空间即玩法 — the shell where buying-and-placing happens) · Pillar 3 (一眼看懂 — a clear, uncluttered build interface) · Pillar 2 (松弛不紧绷 — unavailable items are calmly greyed, never scolding)
> **Creative Director Review (CD-GDD-ALIGN)**: Skipped — Lean review mode (not a PHASE-GATE at lean).

## Overview

Build/Shop UI is the player-facing shell that renders the shop palette and hosts the build interaction — the visual layer that stitches together Shop/Purchase (#12, the buy logic), PlacementSystem (#4, the drag-and-place), and SelectionSystem (#13, managing placed pieces). It renders each catalog item with its price and availability (greyed when unaffordable or locked, via Shop's `can_purchase`/`is_unlocked`), turns a palette mouse-down into a PlacementSystem drag, and — critically — **enforces the one-purchase-drag-at-a-time invariant** that Shop's money-safety proof depends on. It also arbitrates **build mode vs select mode** so the placement ghost and an active selection never fight for the screen. It owns no game state and no money logic — it is presentation + input routing over three logic systems.

## Player Fantasy

Build/Shop UI is the workbench of the whole game — the rack of equipment along the edge of your gym, the satisfying grab-and-place of a new machine, the clean sense that everything you can do right now is right there and obvious. It serves Pillar 1 by being *where* space becomes the game, Pillar 3 by keeping the whole build toolset legible at a glance (no buried menus), and Pillar 2 by making unavailability gentle — the machines you can't afford yet simply wait, greyed and patient, until you can. The feeling to protect: the frictionless "pick it up, drop it down" flow that makes building feel like play, not paperwork.

## Detailed Design

### Core Rules

1. **Shop palette rendering.** The palette lists the catalog's purchasable equipment (icon, name, price in Butter). For each item it queries Shop: `can_purchase(id)` and `is_unlocked(id)`. Unaffordable → **greyed but visible** (calm, never a red "denied"). Locked (`unlock_requirement != null`) → greyed with a small **lock icon** (shape, not color-only). Prices update as availability changes. The palette re-evaluates greying on Economy's `balance_changed` (so an item lights up the moment you can afford it).

2. **Palette mouse-down → drag (gated).** On a palette item mouse-down, the UI calls `Shop.can_purchase(id)`. If true, it initiates PlacementSystem's placement drag for that `equipment_id` (Placement runs its own DRAGGING flow). If false, nothing happens (the item is inert/greyed) — the block-at-selection rule from Shop, chosen because Placement's commit has no veto hook (fail clearly *before* the gesture, Pillar 3).

3. **One-purchase-drag-at-a-time invariant (Shop's hard dependency).** While a purchase drag is in flight, the UI **disables all other shop-palette interactions** (no starting a second drag, no other purchase). This is the invariant Shop's safety proof relies on: it guarantees balance is monotonically non-decreasing during a drag, so a passed `can_purchase` gate always yields a successful `spend()` at commit. The UI is the enforcer of this invariant (Shop OQ1).

4. **Build mode vs select mode arbitration.** The two interaction modes are **mutually exclusive**:
   - Starting a placement drag (build) while a piece is selected first clears the selection (or is blocked until deselect) — no dual ghosts.
   - While SelectionSystem has a selection (`selection_changed` non-null), the UI **suppresses the new-placement ghost/preview** so build previews don't render over a selected piece.
   This keeps exactly one spatial "mode" visually active at a time (Pillar 3 — no two systems fighting the cursor).

5. **Presentation + routing only.** Build/Shop UI holds no money, no catalog data (it reads via Shop/Catalog), no placement state (PlacementSystem's), no selection state (SelectionSystem's). It renders their state and routes input. It initiates a drag and enforces the invariant; everything else is delegated.

### States and Transitions

| From | Event | To | Notes |
|---|---|---|---|
| idle (palette shown) | `balance_changed` / catalog change | palette re-greyed | affordable items light up |
| idle | palette item mouse-down, `can_purchase` true | build (PlacementSystem drag active) | other palette interactions disabled (invariant) |
| idle | palette item mouse-down, `can_purchase` false | idle | inert / greyed |
| build (drag active) | commit / reject / cancel | idle | palette re-enabled |
| idle | `selection_changed(non-null)` | select mode | placement ghost suppressed |
| select mode | `selection_changed(null)` | idle | ghost allowed again |

### Interactions with Other Systems

- **Upstream dependencies (hard)**:
  - **Shop/Purchase (#12)**: `can_purchase(id)`, `is_unlocked(id)` (grey items); the UI enforces Shop's one-drag invariant.
  - **PlacementSystem (#4)**: the UI initiates a placement drag on a gated palette mouse-down.
  - **SelectionSystem (#13)**: subscribes to `selection_changed` to suppress the build ghost during a selection.
  - **EquipmentCatalog (#2)** (via Shop): item icons, names, prices.
  - **Economy (#11)**: subscribes to `balance_changed` to re-grey the palette.
- **Lateral**: HUD (#16) is a sibling UI (money display) — no dependency, just co-resident on the UI layer.

## Formulas

Build/Shop UI has **no formulas** — it renders prices from EquipmentCatalog and availability from Shop, and routes input. No math is owned here.

## Edge Cases

- **Click a palette item while a piece is selected**: selection is cleared first (build takes over), so no dual ghost.
- **Attempt a second purchase-drag while one is active**: blocked by the one-drag invariant (Core Rule 3) — the palette is disabled during a drag.
- **Balance rises/falls mid-session**: palette re-greys on `balance_changed`; an item becomes draggable the instant it's affordable (no manual refresh).
- **Empty / all-locked catalog**: palette shows the items greyed (or empty), nothing draggable — no error, no crash (a calm "nothing available yet" if fully empty).
- **Drag cancelled/rejected**: palette re-enables immediately; no money spent (Shop's deduct-on-commit).
- **Placement commits**: Shop spends once; palette re-greys (balance dropped) and re-enables.

## Dependencies

**Upstream dependencies (hard)**:

| System | Interface | Nature |
|---|---|---|
| Shop/Purchase (#12) | `can_purchase`, `is_unlocked`; enforce one-drag invariant | Hard |
| PlacementSystem (#4) | initiate placement drag on gated mouse-down | Hard |
| SelectionSystem (#13) | subscribe `selection_changed` (suppress ghost) | Hard |
| EquipmentCatalog (#2) (via Shop) | icons / names / prices | Hard |
| Economy (#11) | subscribe `balance_changed` (re-grey) | Hard |

**Bidirectional consistency notes**: this GDD fulfills Shop OQ1 (the one-drag invariant enforcer) and the selection-ghost suppression SelectionSystem's `selection_changed` was designed for. Shop, PlacementSystem, and SelectionSystem should each list Build/Shop UI as their presentation consumer. Verify at `/consistency-check`.

## Tuning Knobs

Build/Shop UI owns **no gameplay tuning knobs** — only presentation choices (palette position, item tile size), which are visual-design decisions, not runtime knobs.

## Visual/Audio Requirements

- **Palette**: a rack of equipment tiles (icon + name + Butter price), calm and uncluttered (Pillar 3). Affordable = full tint; unaffordable = greyed (desaturated, never red); locked = greyed + lock icon (shape-first, colorblind-safe).
- **Placement handoff**: the drag ghost is PlacementSystem's (footprint/access tint per its GDD); Build/Shop UI only decides *when* it's allowed (mode arbitration).
- Art-bible palette throughout; scales with the UI-scale setting. Audio: a soft "pick up" cue on starting a drag is a nice-to-have (audio-director), never intrusive.

## UI Requirements

The palette layout (edge-docked rack — bottom or side), tile design, greyed/locked treatments, and the build/select mode affordance are this system's core UI. Detailed layout should be formalized in `design/ux/` (e.g. `design/ux/build-shop-ui.md`) via `/ux-design` in Pre-Production, and reviewed with `/ux-review` before implementation.

## Acceptance Criteria

> Build/Shop UI is a **UI/Visual** story — evidence primarily **ADVISORY** (manual walkthrough); the invariant-enforcement and gating are testable **interaction** logic. GIVEN-WHEN-THEN:

1. **GIVEN** an item the player can't afford, **WHEN** the palette renders, **THEN** it is greyed (desaturated, no red) and a mouse-down does not start a drag.
2. **GIVEN** the balance rises to meet an item's cost, **WHEN** `balance_changed` fires, **THEN** that item becomes full-tint and draggable within one frame.
3. **GIVEN** a locked item (`unlock_requirement != null`), **WHEN** the palette renders, **THEN** it shows a lock icon (shape) and is not draggable.
4. **GIVEN** an affordable, unlocked item, **WHEN** the player mouse-downs it, **THEN** a PlacementSystem placement drag begins for that `equipment_id`.
5. **GIVEN** a purchase drag is in flight, **WHEN** the player tries to start another purchase, **THEN** it is blocked (one-drag invariant holds).
6. **GIVEN** a piece is selected (`selection_changed` non-null), **WHEN** the player is in the gym, **THEN** the new-placement ghost is suppressed (no dual ghost).
7. **GIVEN** a placement drag ends (commit/reject/cancel), **WHEN** it resolves, **THEN** the palette re-enables and re-greys against the current balance.
8. **GIVEN** a colorblind-simulation pass, **WHEN** viewing the palette, **THEN** affordable/unaffordable/locked states are each distinguishable by tint-desaturation + lock icon shape, not color alone.
9. **GIVEN** a greyed/unaffordable palette item, **WHEN** the player hovers it, **THEN** a tooltip or inline label shows "Save $X more" where `X = cost - balance` (sourced from EquipmentCatalog and Economy) — the player gets a legible "almost there" signal without attempting a drag (Shop/Purchase Core Rule 4, mandatory).
10. **GIVEN** a purchase drag that ends in a silent cancel (Core Rule 2 step 3 of shop-purchase.md: e.g. `can_purchase` passed but `PlacementSystem.is_dragging()` was already true — an attempt swallowed with no signal), **WHEN** the cancel is detected, **THEN** the palette item returns to its idle-state visual with a lightweight visual/audio return-to-palette cue, so the resolution is not invisible to the player (Shop/Purchase Core Rule 4, mandatory).

## Open Questions

| # | Question | Owner | Target Resolution |
|---|---|---|---|
| OQ1 | Palette **layout** (edge-docked bottom vs side), tile size, and scroll/paging if the catalog grows beyond a screen — formalize in `/ux-design` + `/ux-review`. | ux-designer | Pre-Production |
| OQ2 | The **build/select mode affordance** — explicit mode toggle, or fully implicit (mouse-down palette = build, click placed piece = select)? MVP leans implicit; confirm at `/ux-design`. | ux-designer | Pre-Production |
| OQ3 | Confirm PlacementSystem's drag-initiation entry point accepts an `equipment_id` from the palette (its GDD describes palette mouse-down starting a drag — verify the exact call). | PlacementSystem (#4) owner | At `/create-architecture` |