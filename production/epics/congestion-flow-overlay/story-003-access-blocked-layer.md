# Story 003: Access-Blocked Layer (Default-Visible)

> **Epic**: congestion-flow-overlay
> **Status**: Complete — 2026-08-06
> **Layer**: Presentation
> **Type**: Logic
> **Estimate**: M — 2 sessions (≤4h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-06

## Context

**GDD**: `design/gdd/congestion-flow-overlay.md`
**Requirement**: `TR-CFO-001` (access-blocked part), `TR-CFO-005`, `TR-CFO-011` (access-blocked part)
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0005 (Signal Bus & Event Routing)
**ADR Decision Summary**: The access-blocked layer is the always-on, never-gated layer. It reads `Congestion.is_access_reachable(instance_id)` (exists in `src/systems/congestion.gd`) and shows a barricade/broken-link glyph at the equipment's access cell. This is the concrete fulfillment of GridSystem's OQ#9 — the ONLY channel through which the player learns a machine is walled off.

**Engine**: Godot 4.7.1 | **Risk**: MEDIUM
**Engine Notes**: `CanvasItem._draw` glyphs; draw_string signature (first arg Font, font_size before color) if the one-line hover tooltip is drawn in-code; fixed UI-layer scale (does not shrink with camera zoom). `class_name` follows `extends` immediately.

**Control Manifest Rules (Presentation layer)**:
- Required: typed signal connections only
- Forbidden: string-based signal connections

---

## Acceptance Criteria

*From GDD `design/gdd/congestion-flow-overlay.md`, scoped to this story:*

- [x] AC2 GIVEN the heatmap is off, WHEN an equipment's `access_reachable` becomes false, THEN its barricade icon appears regardless of toggle state
- [x] AC12 GIVEN `access_reachable` for equipment E is false, WHEN the heatmap toggle is OFF, THEN E's barricade icon is still visible (the always-on layer is independent of the toggle)
- [x] Core Rule 5 (load-bearing) GIVEN a fresh scene entry / save load with already-unreachable equipment, WHEN the overlay reads the current `access_reachable` set, THEN icons materialize for every `false` entry immediately (default-visible, no event gate, no intervening fade-in-on-false trigger required)
- [x] AC8 GIVEN any state in this system renders, WHEN observed over 10 seconds, THEN no element flashes, pulses on a loop, or plays a failure sound

---

## Implementation Notes

*Derived from ADR-0005 + GDD Core Rule 5:*

**Always-on layer (Core Rule 1/5, AC2/AC12)**:
- Renders on the always-on layer — NOT gated by the heatmap toggle, NOT dimmed by drag state
- Distinct barricade / broken-link glyph (Soft Charcoal outline, Dusty Rose fill secondary — shape-first), anchored above the equipment's **access cell**, at a fixed UI-layer scale (does not shrink with camera zoom)
- Fades in once on the false transition, then holds STATIC — no pulse, no loop (a loop reads as an alarm; a one-time fade-in draws the eye once then sits as information) (AC8)

**Default-visible on entry — THE load-bearing clause (Core Rule 5)**:
- On first scene entry (or save load), read the current `access_reachable` set (via `Congestion.is_access_reachable(instance_id)` for all placed instances) and materialize barricade icons for every `false` entry **up front** — no intervening "fade-in on false" trigger required
- A machine walled off in a prior session must be visible the instant the scene appears, not only after the next `grid_changed`
- Subsequent edits during play: the false-transition fade-in governs (edge-case row), but it does NOT relax the on-entry default-visible rule

**Dynamics**:
- `access_reachable` → true, or equipment removed → icon removed (same frame)
- Multiple machines walled off: each shows its own icon; never merge or stack-count; no aggregate "N blocked" alarm (Pillar 2)
- Flicker protection: reachability is event-driven (only on `grid_changed`, not per-tick) — no strobe within a stable layout

**Hover tooltip**: one-line tooltip on hover: "Can't be reached — check for a blocked path" — NEVER "ERROR" or exclamation iconography.

**4.7.1 pitfalls**:
- `var x := expr` fails on Variant returns → explicit `: bool` for `is_access_reachable`
- `is_access_reachable(instance_id)` signature confirmed in src/systems/congestion.gd
- Lambda closures in tests: use a `RefCounted` counter for signal-driven icon-count assertions

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 001]: heatmap layer + toggle infra
- [Story 002]: per-equipment congestion glyph
- [Story 004]: rejection tooltip, drag-dim, layering priority (this layer's priority position is consumed there)

---

## QA Test Cases

*Derived from GDD acceptance criteria. Logic story — automated coverage required for the default-visible contract.*

- **AC12**: 与开关无关
  - Given: access_reachable for E is false, heatmap toggle OFF
  - When: overlay renders
  - Then: E's barricade icon is visible
  - Edge cases: toggle ON/OFF mid-render — icon unaffected

- **AC2**: 事件翻转出现
  - Given: heatmap off; E's access_reachable flips false
  - When: the flip is processed
  - Then: barricade icon fades in once (single fade-in, then static)
  - Edge cases: flickers true↔false across quick edits — event-driven, no strobe within a stable layout

- **Core Rule 5 (load)**: 进场默认可见
  - Given: scene loads with already-unreachable equipment (e.g. saved game with a walled-off machine)
  - When: the overlay reads the current access_reachable set on entry
  - Then: icons materialize for every false entry immediately — no event gate, no fade-in-on-false trigger required
  - Edge cases: multiple walled-off machines — each own icon, no merge/count; equipment removed while icon showing — icon removed same frame

- **AC8**: 无闪烁
  - Setup: any state with access-blocked icons visible
  - Verify: observed over 10 seconds — no flash, no loop pulse, no failure sound
  - Pass condition: one-time fade-in then static; silence

---

## Test Evidence

**Story Type**: Logic
**Required evidence**:
- `tests/unit/congestion_overlay/access_blocked_layer_test.gd` — must exist and pass (default-visible on entry, toggle-independence, same-frame removal)

**Status**: [x] Created and passing — `tests/unit/congestion_overlay/access_blocked_layer_test.gd` (58 asserts, standalone green; registered in `TEST_FILES`). Implements the story QA cases verbatim:
- **Core Rule 5 (load)** 进场默认可见: `AccessBlockedLayer.configure()` reads the current `access_reachable` set and materializes a STATIC full-alpha icon for every flag-present-and-false entry immediately — zero ticks elapsed, no event gate, no fade-in-on-false trigger; edge: multiple walled-off machines → one icon per instance_id, no merge/count/alarm
- **AC12** 与开关无关: `set_heatmap_enabled(false/true)` leaves the icon and `set_version` untouched (always-on layer independent of the toggle)
- **AC2** 事件翻转出现: wall commit + one tick → icon fades in ONCE (alpha 0→0.5→1.0) then holds static; 9 s of simulated time after the fade → still static, zero set mutations (no loop pulse / no strobe on quiet ticks)
- **Dynamics**: `access_reachable` → true → icon removed (S8 reconcile); equipment removed → icon removed SAME FRAME via the `grid_changed` handler before any tick
- **Extras**: flag-absence semantics (reachability machinery off → zero icons), fixed UI-layer scale under camera zoom, hover tooltip state machine, reconfigure idempotency (no duplicate typed signal connections)

**Evidence**: `production/qa/evidence/congestion-access-blocked-evidence.md` (full run: 3486 passed / 0 failed — 3428 existing + 58 new).

---

## Dependencies

- Depends on: Congestion (`is_access_reachable(instance_id)` — exists), GridSystem (grid→world conversion for anchoring at access cells), the overlay scene infra (independent of the heatmap layer — may be built in parallel with Story 001)
- Unlocks: Story 004 (layering priority consumes this layer's position)
