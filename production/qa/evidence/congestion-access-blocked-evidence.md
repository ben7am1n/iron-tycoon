# Evidence — CFO-003: Access-Blocked Layer (Default-Visible)

> **Epic**: congestion-flow-overlay
> **Story**: story-003-access-blocked-layer.md
> **Layer**: Presentation | **Type**: Logic
> **Date**: 2026-08-06
> **Requirement**: TR-CFO-001 (access-blocked part), TR-CFO-005, TR-CFO-011 (access-blocked part)
> **ADR**: ADR-0005 (typed signal connections only)

## Summary

The always-on access-blocked layer is implemented as `src/presentation/access_blocked_layer.gd`
(class `AccessBlockedLayer extends Node2D`). It reads the CURRENT
`Congestion.access_reachable` set on `configure()` and materializes a
barricade / broken-link glyph for every flag-present-and-false equipment
**immediately** — the load-bearing Core Rule 5 default-visible clause: no
event gate, no intervening "fade-in on false" trigger, icons are STATIC at
full alpha on scene entry. It is never gated by the heatmap toggle
(`set_heatmap_enabled()` is a deliberate no-op — AC2/AC12), never dimmed by
drag state, and refreshes event-driven only (S1 `grid_changed` for same-frame
removal, S8 `congestion_updated` for reachability flips) with the fade state
machine terminal by construction (AC8).

## Files

| Path | Role |
|------|------|
| `src/presentation/access_blocked_layer.gd` | The always-on layer (Node2D) — icon registry, typed signal connections, fade state machine, `_draw` barricade glyph + hover tooltip, fixed UI-layer scale |
| `tests/unit/congestion_overlay/access_blocked_layer_test.gd` | Automated coverage — 58 asserts, standalone green + registered in `tests/headless_runner.gd` `TEST_FILES` |
| `tests/headless_runner.gd` | Test registered (registry-coverage check enforces it) |

## Automated Coverage (58 asserts, all passing)

Rig: real GridSystem (10×8, frozen) + real Navigation + real Congestion
(grid + member_sim + navigation + entrance cell) + real layer, wired exactly
as the composition root wires them.

| QA case | Asserts | Result |
|---------|---------|--------|
| **Core Rule 5 (load)** — scene loads with already-unreachable equipment → icon materializes immediately on `configure()`, STATIC at full alpha, zero ticks elapsed (no event gate); anchored at the equipment's FIRST access cell | 5 | ✅ |
| **Core Rule 5 edge** — multiple walled-off machines → one icon per instance_id, distinct anchors, no merge / no aggregate "N blocked" entry (Pillar 2) | 4 | ✅ |
| **Core Rule 5 edge** — reachable equipment (flag present & true) → no icon | 2 | ✅ |
| **AC12** — access_reachable false + heatmap toggle OFF → icon still visible; toggle ON/OFF mid-render → icon and set_version unaffected | 5 | ✅ |
| **AC2** — heatmap off + access_reachable flips false (wall commit + one tick) → icon fades in ONCE (alpha 0 → 0.5 → 1.0), then holds STATIC; exactly one set mutation | 8 | ✅ |
| **AC2 edge / AC8** — fade state machine TERMINAL: 9 s of simulated time after the fade → still static, alpha 1.0, zero set mutations (no loop pulse, no flash) | 4 | ✅ |
| **Dynamics** — access_reachable → true (wall cleared) → icon removed after the recompute tick, one mutation | 3 | ✅ |
| **Dynamics edge** — equipment removed → icon removed SAME FRAME via `grid_changed` handler, zero ticks elapsed, one mutation | 4 | ✅ |
| **AC8 edge** — two quiet ticks (no grid change) → icon set untouched, zero mutations (reconcile idempotent, event-driven — no strobe within a stable layout) | 3 | ✅ |
| **Flag-absence semantics** — reachability machinery off (no navigation) → ZERO icons (absence never misreports every machine as walled off); never-seen id → no icon | 3 | ✅ |
| **Fixed UI-layer scale** — `set_camera_zoom(2.0)` → glyph scale 0.5, zoom 0.5 → 2.0; icon ANCHOR positions never move; non-positive zoom rejected | 5 | ✅ |
| **Hover tooltip** — pointer on glyph → visible + target id; pointer away → hidden; copy is the fixed one-liner (never ERROR/exclamation) | 5 | ✅ |
| **AC8 structural** — layer source contains no `AudioStream`, no audio `play()` call, no tween/timer (no repeating animation machinery; silence, Pillar 2) | 3 | ✅ |
| **Reconfigure idempotency** — `configure()` twice → exactly ONE typed connection per signal (verified via `Signal.get_connections()`), icon set rebuilt, quiet tick after reconfigure mutates nothing | 4 | ✅ |

**Suite run** (includes this file):

```
TOTAL: 3486 passed, 0 failed   (3428 existing + 58 new)
RESULT: PASSED
```

Standalone: `godot --headless --script tests/unit/congestion_overlay/access_blocked_layer_test.gd` → 58 passed, 0 failed.

## AC8 (10-second observation)

- **No flash / no loop pulse**: structural + behavioral — the fade state
  machine has a single `fading_in → static` transition and no code path
  returns an icon to `fading_in`; the test simulates 9 s of fade time after
  completion and asserts the icon stays static at full alpha with zero set
  mutations.
- **No failure sound**: structural — the layer source references no
  `AudioStream` and calls no audio `play()`; there is no audio path in this
  story (Pillar 2: information, never alarm).
- The visual 10 s on-screen observation (glyph rendering, fade-in feel,
  tooltip legibility) is a **manual/ADVISORY** step pending the overlay scene
  assembly (story 001 scene infra) — the data-binding logic is fully
  automated above.

## Manual Walkthrough Notes (ADVISORY — pending scene assembly)

Story 001 owns the overlay scene root; the layer is scene-ready as a single
`Node2D` (script `src/presentation/access_blocked_layer.gd`) that the overlay scene
instantiates and `configure()`s with the wired Congestion + GridStateReader +
cell size. Visual verification steps to run once the scene exists:
1. Load a save with a walled-off machine → barricade glyph visible the
   instant the scene appears (no toggle interaction required).
2. Toggle the heatmap OFF/ON → barricade unaffected.
3. Block a machine's only path mid-session → glyph fades in once, holds
   static; unblock → glyph disappears.
4. Zoom the camera in/out → glyph stays constant screen size, anchored above
   the machine's access cell.
5. Hover the glyph → one-line tooltip "Can't be reached — check for a
   blocked path".
