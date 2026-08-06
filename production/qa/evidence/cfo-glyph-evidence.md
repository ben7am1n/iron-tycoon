# CFO-002 Evidence — Per-Equipment Congestion Glyph

> **Story**: production/epics/congestion-flow-overlay/story-002-per-equipment-congestion-glyph.md
> **Type**: Visual/Feel (data-binding items automated; visual items manual walkthrough)
> **Date**: 2026-08-06
> **Layer**: Presentation | **Engine**: Godot 4.7.1
> **Status**: Complete — automated coverage green; manual walkthrough pending lead sign-off

## Deliverables

| Artifact | Path |
|---|---|
| Glyph node (battery-icon shape, shape-first) | `src/presentation/congestion_glyph.gd` |
| Glyph layer (shared toggle + 10 Hz refresh + same-frame removal) | `src/presentation/congestion_glyph_layer.gd` |
| Shared-toggle signal added to heatmap (single source of truth) | `src/presentation/heatmap_layer.gd` |
| Automated coverage | `tests/unit/congestion_overlay/glyph_fill_test.gd` (93 asserts) |

## Automated Coverage (headless, deterministic)

Run: `godot --headless --script tests/unit/congestion_overlay/glyph_fill_test.gd` → **93 passed, 0 failed**
Full suite: `godot --headless --script tests/headless_runner.gd` → **3579 passed, 0 failed** (3486 prior + 93 new)

| AC / Rule | Assertion | Result |
|---|---|---|
| AC10 | `fill_fraction = clamp(per_equipment_congestion, 0, 1)` — pure mapping, 0.69 QA example, edges 0 / 1.0 / −0.1 / 1.5 | PASS |
| AC10 (integration) | REAL Congestion rig: glyph fill == `per_equipment_congestion` on tick (0.09), decays exactly after members leave (0.063) | PASS |
| Core Rule 4 | Fill rect height = inner_height × fill_fraction (0 → empty outline, 1 → full, 0.69 → 69%); rises monotonically 0.25/0.5/0.75 | PASS |
| AC6 / TR-CFO-011 | High-contrast thickens outline 1.0 → 2.0 (config-driven 1.5/3.0); fill ratio preserved — color never the carrier | PASS |
| Core Rule 1 | Glyph layer mirrors the REAL `HeatmapLayer.toggle_flow_overlay()` (ON → visible, OFF → hidden); layer created under an ON heatmap adopts ON | PASS |
| Core Rule 3 | `refresh_count` bumps ONLY on `congestion_updated`; no `_process`/`_physics_process` defined (structural); value change without signal → no polling | PASS |
| Edge Case | Equipment removed → glyph dropped same frame via S1 reconcile; removal racing into an S8 refresh → no orphan; re-add → fresh glyph fill 0.0 | PASS |
| Placement | New equipment → glyph same frame (S1), fill 0 until next S8 | PASS |
| Anchoring | `glyph_anchor_position` == `grid_to_world_corner(anchor, cell_size)` + centering/lift; cell_size 32 and 16 both verified (never hardcoded) | PASS |
| Structural | Typed `signal.connect()` only (no string-based connect); glyph renders `draw_rect`, never `draw_string` (shape-based) | PASS |

## Manual Walkthrough Checklist (ADVISORY — visual sign-off)

- [ ] Boot scene → no glyphs visible (toggle OFF by default, mirroring the heatmap)
- [ ] Toggle the flow overlay ON → small battery icons appear above each placed machine
- [ ] Let members queue at a machine → the icon fills bottom-up as `per_equipment_congestion` rises; Dusty Rose tint accompanies the fill
- [ ] Colorblind mode ON → fill height alone still communicates the level (color removed)
- [ ] High-contrast mode ON → glyph outlines visibly thicker
- [ ] Sell/remove a machine → its icon disappears the same frame, no orphan over the empty cell
- [ ] Toggle OFF → all glyphs hide; toggle ON → glyphs return (state preserved, not re-created)
- [ ] Observe over 10 s → no flashing, no pulsing, no failure sounds (Pillar 2)

## Design Notes / Deferred

- **Secondary readout (playtest 2026-07-18)**: the glyph is explicitly secondary — heatmap clarity and dissipation-on-rearrange carry the crowding signal. Implementation is deliberately minimal (16×20 battery icon, no text, no animation).
- **Camera zoom**: GDD edge case says glyphs render at fixed UI scale under zoom. No camera exists in `src/` yet (heatmap is world-space too); glyphs are world-space Node2D anchored via `grid_world_conversion`. Zoom-fixed rendering is deferred to when a camera lands — presentation polish, not gameplay.
- **Toggle wiring**: H key / HUD utility button live in the HUD epic. The heatmap owns the shared toggle state; the glyph layer follows `flow_overlay_toggled` (intra-Presentation signal, deliberately NOT in the ADR-0005 catalog — same exclusion as `one_time_tip_requested`).
- **Settings & Accessibility (#22)**: `set_high_contrast()` is the programmatic seam the settings system will drive; colorblind mode needs no code path because the shape channel is the primary signal by construction.

## Verification Log

```
$ godot --headless --script tests/unit/congestion_overlay/glyph_fill_test.gd
=== GLYPH FILL TEST: 93 passed, 0 failed ===

$ godot --headless --script tests/headless_runner.gd
TOTAL: 3579 passed, 0 failed
RESULT: PASSED
```

**Sign-off**: [ ] lead / creative director — manual walkthrough above
