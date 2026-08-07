# Story 004: Rejection Tooltip + Layer Priority + Drag Dimming

> **Epic**: congestion-flow-overlay
> **Status**: Complete — 2026-08-07
> **Layer**: Presentation
> **Type**: Visual/Feel
> **Estimate**: M — 2 sessions (≤4h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-07

## Context

**GDD**: `design/gdd/congestion-flow-overlay.md`
**Requirement**: `TR-CFO-006`, `TR-CFO-007`, `TR-CFO-008`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0005 (Signal Bus & Event Routing)
**ADR Decision Summary**: The overlay subscribes to `PlacementSystem.placement_rejected(equipment_id, anchor, rotation, fail_code)` (exists in src/systems/placement_system.gd) and PlacementSystem drag state (`is_dragging()`) for dimming. Input/feedback via bridge-style event handling per the bridge pattern (§5).

**Engine**: Godot 4.7.1 | **Risk**: MEDIUM
**Engine Notes**: Tooltip drawn via `CanvasItem.draw_string` — first arg is `Font` (ThemeDB.fallback_font, guard `!= null` under headless), `font_size` precedes `color`. 400 ms hold delay via timer (bridge owns timer creation — ADR-0005 §5). dual-focus (4.6+) for keyboard.

**Control Manifest Rules (Presentation layer)**:
- Required: typed signal connections only
- Forbidden: string-based signal connections

---

## Acceptance Criteria

*From GDD `design/gdd/congestion-flow-overlay.md`, scoped to this story:*

- [x] AC4 GIVEN a rejected drop with a footprint-bucket fail code, WHEN the cursor holds 400 ms, THEN the tooltip reads "Won't fit here," never a raw fail-code string
- [x] AC5 GIVEN a rejected drop with an access-bucket fail code, WHEN the cursor holds 400 ms, THEN the tooltip reads "Blocks the path in."
- [x] AC3 GIVEN a placement drag begins, WHEN the heatmap was on, THEN it tweens to ≤20% opacity within one drag-frame and restores on drag end
- [x] Core Rule 7 GIVEN multiple layers compete, WHEN a drag is active, THEN layering priority holds: access-blocked (full opacity, never dimmed) > placement ghost (full) > congestion glyph (visible) > heatmap (dims to ≤20%)

---

## Implementation Notes

*Derived from ADR-0005 + GDD Core Rules 6/7:*

**Placement rejection feedback (Core Rule 6, AC4/AC5)**:
- On `placement_rejected(equipment_id, anchor, rotation, fail_code)`: show a single calm cursor-adjacent tooltip ONLY after the cursor holds ~400 ms over an invalid cell (knob 250–600 ms) — prevents flicker while sweeping
- 5 fail codes collapse into 2 buckets (reusing the ghost's existing footprint-vs-access split):
  - Footprint bucket (`OUT_OF_BOUNDS`, `BLOCKED_BY_ROOM_GEOMETRY`, `OVERLAPS_EXISTING_EQUIPMENT`) → "Won't fit here"
  - Access bucket (`ACCESS_OUT_OF_BOUNDS`, `ACCESS_BLOCKED_BY_ROOM_GEOMETRY`) → "Blocks the path in"
- No sound tied to rejection (silence, not a failure buzz — Pillar 2); never a raw fail-code string
- Tooltip hidden when cursor moves to a valid cell / drag ends

**Drag dimming (Core Rule 7 + AC3)**:
- On drag begin (PlacementSystem `is_dragging()` true): heatmap tweens to ≤20% opacity (knob 0.1–0.3)
- On drag end: restores to the toggled state (ON → prior opacity; OFF → hidden)
- Toggling mid-drag: sets target opacity; drag-dim still overrides to ≤20% until drag end

**Information layering priority (Core Rule 7)**:
1. Access-blocked icons — always full opacity, never dimmed
2. Placement ghost — full opacity during a drag
3. Per-equipment congestion glyph — stays visible during a drag (small, decision-relevant)
4. Heatmap — dims to ≤20% during a drag, yields first
- Rule of thumb: ambient context yields to active decisions

**4.7.1 pitfalls**:
- draw_string signature (Font first, font_size before color) for tooltip text
- `var x := expr` fails on Variant returns → explicit types
- Timer ownership: the 400 ms hold timer is UI-layer state — bridge/overlay node owns it (ADR-0005 §5)

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 001]: heatmap layer + toggle infra (this story dims it, does not build it)
- [Story 002]: congestion glyph (this story orders it, does not render it)
- [Story 003]: access-blocked layer (this story prioritizes it, does not build it)

---

## QA Test Cases

*Derived from GDD acceptance criteria. Visual/Feel story — manual verification plus automated bucket-mapping where practical.*

- **AC4/AC5**: 拒绝提示两桶
  - Given: rejected drop with a footprint-bucket fail code
  - When: cursor holds 400 ms over the invalid cell
  - Then: tooltip reads "Won't fit here" (never a raw fail-code string)
  - And: access-bucket fail code → "Blocks the path in"
  - Edge cases: cursor sweeps fast (no tooltip — hold delay); moves to valid cell (hidden)

- **AC3**: 拖拽变暗
  - Given: heatmap ON
  - When: a placement drag begins
  - Then: heatmap tweens to ≤20% opacity within one drag-frame; restores on drag end
  - Edge cases: toggle OFF mid-drag → hidden fully on drag end; toggle ON mid-drag → restores to ON after drag

- **Core Rule 7**: 层级优先
  - Setup: drag active with all four layers potentially visible
  - Verify: access-blocked icons full opacity; ghost full; glyph visible; heatmap dimmed ≤20%
  - Pass condition: ambient yields to active decisions; access-blocked never dimmed

---

## Test Evidence

**Story Type**: Visual/Feel
**Required evidence**:
- `production/qa/evidence/cfo-feedback-evidence.md` — manual walkthrough / sign-off
- Automated coverage of the fail-code→bucket mapping: `tests/unit/congestion_overlay/rejection_bucket_test.gd` (31 asserts) + `tests/unit/congestion_overlay/drag_dim_priority_test.gd` (47 asserts — AC3 drag-dim + Core Rule 7 priority + controller wiring)

**Status**: [x] Created — 78/0 passing (registered in `tests/headless_runner.gd` TEST_FILES; full suite 3605/0 green 2026-08-06)

---

## Dependencies

- Depends on: Story 001 (heatmap layer — this story dims it), Story 003 (access-blocked layer — this story prioritizes it); PlacementSystem (`placement_rejected`, `is_dragging` — both exist)
- Unlocks: None (completes the overlay epic) — but the overlay controller here (`src/ui/congestion_overlay_controller.gd`) is the natural wiring point for Story 002's glyph and the HUD's toggle/H-key input.
