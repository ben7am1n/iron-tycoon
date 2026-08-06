# Epic: Congestion/Flow Overlay

> **Layer**: Presentation
> **GDD**: design/gdd/congestion-flow-overlay.md
> **Architecture Module**: Congestion/Flow Overlay — ImageTexture for heatmap; 10Hz heatmap rendering, access-blocked icons
> **Status**: Ready
> **Stories**: 4 stories created — see below

## Stories

| # | Story | Type | Status | ADR |
|---|-------|------|--------|-----|
| 001 | Heatmap Layer (ImageTexture + Shader, 10Hz) | Logic | Complete — 2026-08-06 | ADR-0005 |
| 002 | Per-Equipment Congestion Glyph | Visual/Feel | Complete — 2026-08-06 | ADR-0005 |
| 003 | Access-Blocked Layer (Default-Visible) | Logic | Complete — 2026-08-06 | ADR-0005 |
| 004 | Rejection Tooltip + Layer Priority + Drag Dimming | Visual/Feel | Ready | ADR-0005 |

## Overview

The presentation layer that makes the whole MVP hypothesis *visible*: it renders the per-cell density heatmap, the per-equipment congestion glyph, and the always-visible "this machine is walled off" (`access_reachable == false`) warning, and it owns reason-specific feedback when a placement is rejected. It is the payoff surface for Pillar 3 (一眼看懂). It is a pure consumer of Congestion's outputs (`per_cell_density`, `per_equipment_congestion`, `is_access_reachable`, `congestion_updated` signal — all present in `src/systems/congestion.gd`) and PlacementSystem's `placement_rejected` signal. The hard requirement: the `access_reachable` indicator **must be default-visible** on scene load. This is the order-8 fun-validation milestone system — once it exists, the core loop (place → members flow → see crowding → rearrange) is playable end-to-end.

**⚠️ Engine note — DrawableTexture2D 4.7 BYPASS (decision)**: control-manifest.md's Presentation rules say "Use DrawableTexture2D for congestion/flow heatmap overlays", but the GDD (Core Rule 2 + OQ1), the architecture table, and TR-CFO-010 explicitly **bypass DrawableTexture2D for MVP**: it is UNVERIFIED against the local 4.7.1 engine and gives zero benefit at 130 texels. **The GDD is authoritative: use `ImageTexture` + `CanvasItem` shader (per-sampler BILINEAR), `ImageTexture.update()` on `congestion_updated` (10 Hz).** Do NOT adopt DrawableTexture2D in this sprint.

## Governing ADRs

| ADR | Decision Summary | Engine Risk |
|-----|-----------------|-------------|
| ADR-0005: Signal Bus & Event Routing | Typed signal connections; overlay subscribes to `congestion_updated` (10 Hz) and `placement_rejected`; refresh gated to signal, never `_process`. Bridge Node pattern for input; keyboard via `_unhandled_key_input` (dual-focus 4.6+). | MEDIUM |

## GDD Requirements

| TR-ID | Requirement | ADR Coverage |
|-------|-------------|--------------|
| TR-CFO-001 | Three render layers: heatmap (default OFF), per-equipment glyph (toggle-gated), access-blocked (always-on) | ADR-0005 ✅ |
| TR-CFO-002 | Heatmap: 13x10 Image/ImageTexture + CanvasItem shader with per-sampler BILINEAR (exception to global Nearest) | ADR-0005 ✅ |
| TR-CFO-003 | ImageTexture updated ONLY on congestion_updated signal (10 Hz), not in _process | ADR-0005 ✅ |
| TR-CFO-004 | Per-equipment glyph: shape-fill primary, Dusty Rose tint secondary; colorblind-safe by construction | ADR-0005 ✅ |
| TR-CFO-005 | Access-blocked MUST be default-visible on scene load (barricade/broken-link glyph at access cell, always-on) | ADR-0005 ✅ |
| TR-CFO-006 | Placement rejection: 400ms hold delay, 2-bucket messages (footprint/access); 5 FAIL codes collapsed | ADR-0005 ✅ |
| TR-CFO-007 | Information layering priority: access-blocked > placement ghost > congestion glyph > heatmap | ADR-0005 ✅ |
| TR-CFO-008 | Heatmap dims to <=20% opacity during placement drag; restores on drag end | ADR-0005 ✅ |
| TR-CFO-009 | density_to_heat: heat_alpha = smoothstep(low_cut=0.2, high_cut=0.8, density_cell); Dusty Rose #E0A0A0 | ADR-0005 ✅ |
| TR-CFO-010 | DrawableTexture2D explicitly NOT used for MVP (unverified against 4.7.1, zero benefit at 130 texels) | ADR-0005 ✅ |
| TR-CFO-011 | Colorblind/high-contrast: every cue distinguishable by shape/fill/icon alone; high-contrast thickens outlines | ADR-0005 ✅ |

## Definition of Done

This epic is complete when:
- All stories are implemented, reviewed, and closed via `/story-done`
- All acceptance criteria from `design/gdd/congestion-flow-overlay.md` (AC1–AC12) are verified
- The overlay scene (`src/ui/` Control/CanvasItem hierarchy) renders three independent layers; access-blocked icons are visible on scene load regardless of the heatmap toggle
- Data-binding items (AC9–AC12) have automated coverage in `tests/`; visual items have evidence docs in `production/qa/evidence/`
- No `DrawableTexture2D` usage in the heatmap path; `ImageTexture.update()` cadence verified at 10 Hz
- The playable build runs with the overlay togglable via H and the HUD utility button

## Next Step

Work through stories in order — each story's `Depends on:` field tells what must be DONE before it can start.
