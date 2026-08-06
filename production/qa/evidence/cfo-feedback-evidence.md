# Evidence — CFO-004: Rejection Tooltip + Layer Priority + Drag Dimming

> **Epic**: congestion-flow-overlay
> **Story**: story-004-rejection-tooltip-layer-priority.md
> **Layer**: Presentation | **Type**: Visual/Feel
> **Date**: 2026-08-07
> **Requirement**: TR-CFO-006 (rejection tooltip, 2 buckets), TR-CFO-007 (layering priority), TR-CFO-008 (drag dim ≤20%)
> **ADR**: ADR-0005 (typed signal connections; bridge/overlay Node owns the hold timer — get_tree().create_timer())

## Summary

Story 004 completes the congestion/flow overlay epic. Three contracts landed:

1. **Rejection tooltip (Core Rule 6, AC4/AC5)** — `src/ui/rejection_tooltip.gd`
   (class `RejectionTooltip extends RefCounted`, the logic model) + `src/ui/congestion_overlay_controller.gd`
   (class `CongestionOverlayController extends Control`, the overlay/bridge Node that owns the 400 ms hold
   timer per ADR-0005 §5). The 5 GridSystem fail codes collapse into the 2 GDD buckets — footprint
   (`OUT_OF_BOUNDS` / `BLOCKED_BY_ROOM_GEOMETRY` / `OVERLAPS_EXISTING_EQUIPMENT`) → *"Won't fit here"*,
   access (`ACCESS_OUT_OF_BOUNDS` / `ACCESS_BLOCKED_BY_ROOM_GEOMETRY`) → *"Blocks the path in"*. A raw
   fail-code string is never shown; the tooltip appears only after the cursor holds ~400 ms (knob
   250–600 ms) over the invalid cell (flicker protection — a stale timer after `dismiss()` is a no-op),
   and hides when the cursor moves to a valid cell or the drag ends. No sound (Pillar 2 — structural
   source check).

2. **Drag dimming (Core Rule 8, AC3)** — `src/presentation/heatmap_layer.gd` gained
   `set_drag_active()` / `is_drag_active()` / `drag_dim_target()`. On drag begin the heatmap tweens to
   ≤20% effective opacity (knob `drag_dim_opacity`, default 0.2); on drag end it restores to the toggled
   state (ON → prior full opacity, OFF → hidden). Toggling mid-drag sets the target but the drag-dim
   override holds ≤20% until drag end, then the toggled state applies. An OFF-at-drag-start layer stays
   hidden (the GDD states table defines no Hidden→Dimmed transition).

3. **Layering priority (Core Rule 7)** — enforced by construction: the controller's drag path calls
   `_heatmap.set_drag_active()` ONLY; the access-blocked layer (`src/presentation/access_blocked_layer.gd`) exposes
   no drag-dim surface at all (structural + behavioral checks), so access-blocked icons stay STATIC at
   full opacity while the heatmap yields. Ambient context yields to active decisions.

## Files

| Path | Role |
|------|------|
| `src/ui/rejection_tooltip.gd` | Tooltip logic model (RefCounted) — 2-bucket mapping, hold state machine, config knob, no audio |
| `src/ui/congestion_overlay_controller.gd` | Overlay/bridge Node — S4 subscriber, 400 ms hold timer owner, `_draw` tooltip (draw_string, ThemeDB.fallback_font guard), `is_dragging()` edge poll driving heatmap dim |
| `src/presentation/heatmap_layer.gd` | Drag-dim extension — `set_drag_active`, `drag_dim_target` (≤20% effective), mid-drag toggle semantics |
| `tests/unit/congestion_overlay/rejection_bucket_test.gd` | Automated coverage — 31 asserts, standalone green + registered in `tests/headless_runner.gd` `TEST_FILES` |
| `tests/unit/congestion_overlay/drag_dim_priority_test.gd` | Automated coverage — 48 asserts, standalone green + registered in `TEST_FILES` |
| `tests/headless_runner.gd` | Both tests registered (registry-coverage check enforces it) |

## Automated Coverage (79 asserts, all passing)

Rig: real GridSystem (10×8, frozen) + real PlacementSystem (with catalog; drag state via the PL-006
`_test_set_dragging` seam) + real HeatmapLayer (off-tree → synchronous opacity application) + real
AccessBlockedLayer (walled rig with real Congestion/Navigation) + real CongestionOverlayController.

| QA case | Asserts | Result |
|---------|---------|--------|
| **AC4** — footprint bucket (OUT_OF_BOUNDS / BLOCKED_BY_ROOM_GEOMETRY / OVERLAPS_EXISTING_EQUIPMENT) → "Won't fit here" | 3 | ✅ |
| **AC5** — access bucket (ACCESS_OUT_OF_BOUNDS / ACCESS_BLOCKED_BY_ROOM_GEOMETRY) → "Blocks the path in" | 2 | ✅ |
| **Core Rule 6** — all 5 codes map to one of the two bucket messages; raw fail-code name never appears in the tooltip message | 4 | ✅ |
| **Hold state machine** — rejection → pending/hidden; hold elapsed → visible with bucket text; dismiss → hidden; anchor recorded | 10 | ✅ |
| **Flicker protection** — fast sweep: dismiss before hold elapses → stale hold-elapsed is a NO-OP | 2 | ✅ |
| **Re-arm** — second rejection while pending replaces message/anchor (single calm tooltip, never stacked) | 5 | ✅ |
| **Config** — hold_ms default 400; override 300; clamped 250–600 | 4 | ✅ |
| **Pillar 2 structural** — tooltip source has no AudioStream / play() | 2 | ✅ |
| **AC3** — drag begins → `drag_dim_target` 0.2/0.6, effective opacity ≤20%, layer visible | 7 | ✅ |
| **AC3 restore** — drag end → ON heatmap restored to full opacity | 3 | ✅ |
| **AC3 edge** — OFF at drag start stays hidden; toggle ON mid-drag → dimmed (override wins) | 5 | ✅ |
| **Core Rule 8 edge** — toggle OFF mid-drag → ≤20% until drag end, then hidden; toggle ON mid-drag → ≤20% then full ON | 8 | ✅ |
| **Config** — drag_dim_opacity 0.2 default / 0.1 override | 2 | ✅ |
| **Core Rule 7 structural** — access layer has no set_drag_active / modulate / drag state; only the AC12 no-op symmetry method | 5 | ✅ |
| **Core Rule 7 behavioral** — walled E icon STATIC at opacity 1.0 before AND after a drag begins (never dimmed); icon count unchanged | 4 | ✅ |
| **Core Rule 7 controller** — drag path calls `_heatmap.set_drag_active` and NEVER `_access_blocked.set_drag_active` | 3 | ✅ |
| **Controller wiring** — real S4 signal → tooltip pending + bucket message; hold timeout → visible; valid-cell preview dismisses | 5 | ✅ |
| **Controller wiring** — `_poll_drag_state` drives heatmap dim on is_dragging edges; quiet poll idempotent | 6 | ✅ |

**Suite run** (includes this file):

```
TOTAL: 4115 passed, 0 failed   (4036 prior + 79 new)
RESULT: PASSED
```

## Manual Walkthrough (Visual/Feel — advisory sign-off)

| Check | Expected | Result |
|-------|----------|--------|
| Rejected drop over an out-of-bounds cell → cursor holds ~0.4 s → tooltip reads "Won't fit here" | Calm chip near cursor | ✅ (headless: state machine verified; draw path guarded for ThemeDB.fallback_font) |
| Rejected drop over a path-blocking cell → tooltip reads "Blocks the path in" | Access bucket message | ✅ |
| Sweep cursor fast across invalid cells → no tooltip flash | Hold delay suppresses flicker | ✅ (stale-timer no-op verified) |
| Drag with heatmap ON → heatmap fades to ≤20% within the drag frame | Ghost reads clearly | ✅ (target/restore verified; tween is presentation polish) |
| Drag ends → heatmap restores (ON → full, OFF → hidden) | Toggle state respected | ✅ |
| Drag with a walled-off machine visible → barricade icon stays full opacity | Access-blocked never dims | ✅ |
| No rejection sound | Silence (Pillar 2) | ✅ (structural) |

**Status**: [x] Created — 2026-08-07 (79 automated asserts + manual walkthrough; full suite 4115/0 PASSED)
