# Epic: Build/Shop UI

> **Layer**: Presentation
> **GDD**: design/gdd/build-shop-ui.md
> **UX Spec**: design/ux/build-shop-ui.md
> **Architecture Module**: Build/Shop UI — palette rendering state, mode arbitration; exposes Shop palette, drag gate
> **Status**: Complete — 2026-08-07
> **Stories**: 4 stories created — see below

## Stories

| # | Story | Type | Status | ADR |
|---|-------|------|--------|-----|
| 001 | Shop Palette Rendering | UI | Complete — 2026-08-06 | ADR-0005 |
| 002 | Purchase Gating + One-Drag Invariant + Hover Save-$X | Logic | Complete — 2026-08-06 | ADR-0005, ADR-0006 |
| 003 | Build/Select Mode Arbitration | Integration | Complete — 2026-08-07 | ADR-0005 |
| 004 | Drag Handoff + Purchase Confirm + Silent-Cancel Cue | UI | Complete — 2026-08-07 | ADR-0005 |

## Overview

Build/Shop UI is the player-facing shell that renders the shop palette and hosts the build interaction — the visual layer that stitches together Shop/Purchase (#12, the buy logic), PlacementSystem (#4, the drag-and-place), and SelectionSystem (#13, managing placed pieces). It renders each catalog item with price and availability (greyed when unaffordable or locked), turns a palette mouse-down into a PlacementSystem drag, and enforces the one-purchase-drag-at-a-time invariant that Shop's money-safety proof depends on. It arbitrates build mode vs select mode so the placement ghost and an active selection never fight. It owns no game state and no money logic — presentation + input routing over three logic systems.

**⚠️ Dependency gap — Shop (#12) NOT implemented**: `src/systems/` has no Shop. The GDD's palette queries `Shop.can_purchase(id)` / `Shop.is_unlocked(id)`, and Shop's one-drag gate checks `PlacementSystem.is_dragging()` + sets `_purchase_in_flight` (spend-on-commit listener on `placement_committed`). Shop's GDD (`design/gdd/shop-purchase.md`) is fully specified and small (gate functions + conditional listener). **Story 002 must implement this minimal Shop surface as integration glue** (per shop-purchase.md Core Rules 1/2/5: `can_purchase = is_unlocked AND (cost == 0 OR Economy.can_afford(cost))`, `is_unlocked = (unlock_requirement == null)`, `_purchase_in_flight` + spend-on-commit listener); if a dedicated Shop card is later split out, the logic migrates cleanly. Economy.spend/can_afford and PlacementSystem.is_dragging/placement_committed already exist (Sprint 4).

**⚠️ Engine note**: Control + `_input`/`_unhandled_input` for palette; dual-focus (4.6+) keyboard handling; Control offset transforms (4.7 NEW) for animated UI (must not break container layout). Palette is a Control hierarchy, not a sim system — no RefCounted DI needed here, but all logic calls go through the existing systems.

## Governing ADRs

| ADR | Decision Summary | Engine Risk |
|-----|-----------------|-------------|
| ADR-0005: Signal Bus & Event Routing | Typed signal connections; UI subscribes to `balance_changed` (re-grey), `selection_changed` (mode arbitration), `placement_committed` (purchase confirm / Shop spend-on-commit listener); palette input via `_input`/`_unhandled_input` on the Control. | MEDIUM |
| ADR-0006: Economy Credit Interface | `Economy.credit()` exists (Sprint 4) — provides the balance readout basis; affordability via `Economy.can_afford(cost)` per Shop Core Rule 1. | LOW |

## GDD Requirements

| TR-ID | Requirement | ADR Coverage |
|-------|-------------|--------------|
| TR-BSUI-001 | Shop palette renders catalog items: icon, name, price; queries Shop.can_purchase and is_unlocked | ADR-0005 ✅ |
| TR-BSUI-002 | Palette re-evaluates greying on Economy.balance_changed signal | ADR-0005 ✅ |
| TR-BSUI-003 | One-purchase-drag-at-a-time: UI disables all other palette interactions during active drag | ADR-0005 ✅ |
| TR-BSUI-004 | Build mode vs select mode mutually exclusive; placement ghost suppressed when selection active | ADR-0005 ✅ |
| TR-BSUI-005 | Hover 'Save $X more' tooltip on greyed items (X = cost - balance) | ADR-0005 ✅ |
| TR-BSUI-006 | Colorblind-safe: affordable/unaffordable/locked distinguishable by tint-desaturation + lock icon shape | ADR-0005 ✅ |

## Definition of Done

This epic is complete when:
- All stories are implemented, reviewed, and closed via `/story-done`
- All acceptance criteria from `design/gdd/build-shop-ui.md` (AC1–AC10) are verified
- The palette Control renders catalog items with greyed/locked states, re-greys on `balance_changed`, and gates drags on `Shop.can_purchase`
- The one-drag invariant holds (palette disabled during drag); build/select mode arbitration works with SelectionSystem
- Hover "Save $X more" tooltip and silent-cancel return cue exist (Shop Core Rule 4 requirements)
- The playable build runs with palette → drag → commit → spend pipeline working end-to-end

## Next Step

Work through stories in order — each story's `Depends on:` field tells what must be DONE before it can start.
