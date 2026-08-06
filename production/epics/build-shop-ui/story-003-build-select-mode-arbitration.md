# Story 003: Build/Select Mode Arbitration

> **Epic**: build-shop-ui
> **Status**: Ready
> **Layer**: Presentation
> **Type**: Integration
> **Estimate**: S — 1 session (≤2h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-06

## Context

**GDD**: `design/gdd/build-shop-ui.md` (Core Rule 4)
**Requirement**: `TR-BSUI-004`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0005 (Signal Bus & Event Routing)
**ADR Decision Summary**: Build mode and select mode are mutually exclusive. The UI subscribes to `SelectionSystem.selection_changed`; while a selection is active (non-null), the new-placement ghost/preview is suppressed so build previews don't render over a selected piece. Starting a placement drag while a piece is selected first clears the selection (build takes over) — no dual ghosts. Exactly one spatial "mode" visually active at a time (Pillar 3).

**Engine**: Godot 4.7.1 | **Risk**: LOW
**Engine Notes**: Signal subscription + visibility state; no new engine APIs. Typed signal connections only.

**Control Manifest Rules (Presentation layer)**:
- Required: typed signal connections only
- Forbidden: string-based signal connections

---

## Acceptance Criteria

*From GDD `design/gdd/build-shop-ui.md`, scoped to this story:*

- [ ] AC6 GIVEN a piece is selected (`selection_changed` non-null), WHEN the player is in the gym, THEN the new-placement ghost is suppressed (no dual ghost)
- [ ] Core Rule 4 GIVEN a placement drag starts while a piece is selected, WHEN the drag begins, THEN the selection is cleared first (build takes over) — no dual ghosts
- [ ] Core Rule 4 GIVEN no selection, WHEN the player drags, THEN the placement ghost renders normally

---

## Implementation Notes

*Derived from ADR-0005 + GDD Core Rule 4:*

**Mode arbitration (TR-BSUI-004)**:
- Subscribe to `selection_changed` (SelectionSystem — signal emitted from Story SEL-001)
- `selection_changed(non-null)` → select mode: new-placement ghost/preview SUPPRESSED (palette still visible)
- `selection_changed(null)` → idle: ghost allowed again
- Palette mouse-down (build) while a piece is selected → clear the selection FIRST (build takes over), then the drag proceeds

**Exactly one spatial mode at a time (Pillar 3)**:
- Build drag active → selection suppressed (SelectionSystem Story SEL-001 AC12: clicks don't resolve during drag)
- Selection active → placement ghost suppressed (this story)
- The two suppression directions together guarantee no dual ghosts

**4.7.1 pitfalls**:
- `class_name` follows `extends` immediately; headless cross-script refs via `preload` aliases
- Signal connections typed: `selection_changed.connect(_on_selection_changed)`

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 001]: palette rendering
- [Story 002]: purchase gating / one-drag invariant (the drag itself is PlacementSystem's)
- [Story 004]: drag handoff visuals, confirm/cancel cues
- SelectionSystem epic: the `selection_changed` signal source (SEL-001) and click-suppression-during-drag (SEL-001 AC12)

---

## QA Test Cases

*Derived from GDD acceptance criteria. Integration story — automated coverage required where practical.*

- **AC6**: 选中时抑制幽灵
  - Given: a piece selected (`selection_changed` non-null)
  - When: player is in the gym (no drag)
  - Then: new-placement ghost suppressed; palette still visible
  - Edge cases: selection cleared mid-hover → ghost allowed again immediately

- **Core Rule 4**: 拖拽接管
  - Given: a piece selected; palette mouse-down on an affordable item
  - When: the drag begins
  - Then: selection cleared first; placement ghost renders for the new drag (no dual ghost)
  - Edge cases: can_purchase false → no drag, selection unchanged

- **Idle**: 正常渲染
  - Given: no selection
  - When: player drags
  - Then: placement ghost renders normally
  - Edge cases: selection arrives mid-drag → ghost suppressed on the fly (SelectionSystem suppresses clicks, not this story)

---

## Test Evidence

**Story Type**: Integration
**Required evidence**:
- `tests/integration/build_shop_ui/mode_arbitration_test.gd` OR interaction test — must exist and pass (suppression on selection, build-takes-over, restore on deselect)

**Status**: [ ] Not yet created

---

## Dependencies

- Depends on: Story 002 (purchase gating — the drag initiation this story arbitrates with), SelectionSystem (`selection_changed` — emitted from SEL-001)
- Unlocks: Story 004 (handoff/confirm cues)
