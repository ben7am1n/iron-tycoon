# Story 001: Shop Palette Rendering

> **Epic**: build-shop-ui
> **Status**: Complete — 2026-08-06
> **Layer**: Presentation
> **Type**: UI
> **Estimate**: M — 2 sessions (≤4h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-06

## Context

**GDD**: `design/gdd/build-shop-ui.md`
**Requirement**: `TR-BSUI-001`, `TR-BSUI-002`, `TR-BSUI-006`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0005 (Signal Bus & Event Routing)
**ADR Decision Summary**: The palette is a Control hierarchy (scene-tree node, NOT a RefCounted sim system). It renders catalog items and subscribes to `Economy.balance_changed` to re-evaluate greying. Typed signal connections only. UX spec: `design/ux/build-shop-ui.md` (bottom-edge rack, 5-6 tiles at MVP).

**Engine**: Godot 4.7.1 | **Risk**: MEDIUM
**Engine Notes**: Control palette (HBoxContainer/GridContainer of tile Controls); dual-focus (4.6+) keyboard handling; Control offset transforms (4.7 NEW) optional for tile animations (must not break container layout). `class_name` follows `extends` immediately.

**Control Manifest Rules (Presentation layer)**:
- Required: typed signal connections only
- Forbidden: string-based signal connections

---

## Acceptance Criteria

*From GDD `design/gdd/build-shop-ui.md`, scoped to this story:*

- [x] AC1 GIVEN an item the player can't afford, WHEN the palette renders, THEN it is greyed (desaturated, no red) and a mouse-down does not start a drag (drag gating is Story 002's logic — the rendering state is here)
- [x] AC2 GIVEN the balance rises to meet an item's cost, WHEN `balance_changed` fires, THEN that item becomes full-tint within one frame
- [x] AC3 GIVEN a locked item (`unlock_requirement != null`), WHEN the palette renders, THEN it shows a lock icon (shape) 
- [x] AC8 GIVEN a colorblind-simulation pass, WHEN viewing the palette, THEN affordable/unaffordable/locked states are each distinguishable by tint-desaturation + lock icon shape, not color alone
- [x] Core Rule 1 GIVEN the catalog renders, THEN each item shows icon + name + price in Butter

---

## Implementation Notes

*Derived from ADR-0005 + GDD Core Rule 1 + UX spec:*

**Palette rendering (Core Rule 1, TR-BSUI-001)**:
- Edge-docked rack (bottom edge recommended per UX spec), 5-6 tiles at MVP
- Each tile = icon + name + Butter price
- Item data via EquipmentCatalog (through Shop's query layer per TR-BSUI-001 — see Story 002 for the Shop query surface; this story renders whatever availability state the query layer reports)
- Queries: `can_purchase(id)` and `is_unlocked(id)` (Shop surface — Story 002)

**Greying states (Core Rule 1, Pillar 2)**:
- Unaffordable → greyed but visible (calm, NEVER a red "denied")
- Locked (`unlock_requirement != null`) → greyed with a small lock icon (shape, not color-only)
- Affordable → full-tint and draggable (drag gate in Story 002)

**Re-grey on balance_changed (TR-BSUI-002)**:
- Subscribe to `Economy.balance_changed` → re-evaluate availability → newly affordable items light up within one frame

**Colorblind-safe (TR-BSUI-006, AC8)**:
- affordable = full tint; unaffordable = greyed (desaturated); locked = greyed + lock icon shape — distinguishable without color

**Empty/all-locked catalog**: calm "nothing available yet" hint; nothing draggable; no error, no crash.

**4.7.1 pitfalls**:
- `class_name` follows `extends` immediately; headless cross-script refs via `preload` aliases
- `var x := expr` fails on Variant returns → explicit `: bool` for query results

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 002]: Shop query surface (`can_purchase`/`is_unlocked`), one-drag invariant, hover "Save $X more"
- [Story 003]: build/select mode arbitration (ghost suppression)
- [Story 004]: drag handoff, purchase-confirm cue, silent-cancel cue

---

## QA Test Cases

*Derived from GDD acceptance criteria. UI story — manual walkthrough plus automated state assertions.*

- **AC1**: 不可负担置灰
  - Setup: an item the player can't afford
  - Verify: tile greyed (desaturated, no red); mouse-down does not start a drag
  - Pass condition: calm grey; inert

- **AC2**: 余额变化点亮
  - Setup: balance below item cost; then balance rises to meet it
  - When: `balance_changed` fires
  - Then: item full-tint within one frame
  - Pass condition: no manual refresh

- **AC3**: 锁定图标
  - Setup: a locked item
  - Verify: lock icon (shape) shown; not draggable
  - Pass condition: locked ≠ merely-unaffordable (distinct visual)

- **AC8**: 色盲模拟
  - Setup: desaturate screen
  - Verify: three states distinguishable by tint-desaturation + lock icon shape
  - Pass condition: no information by color alone

- **Core Rule 1**: 瓦片内容
  - Setup: palette renders
  - Verify: each tile icon + name + Butter price
  - Pass condition: all catalog items listed; empty catalog shows calm hint

---

## Test Evidence

**Story Type**: UI
**Required evidence**:
- `production/qa/evidence/build-shop-palette-evidence.md` — manual walkthrough / sign-off
- Automated coverage of grey-state derivation where practical (e.g. `tests/unit/build_shop_ui/palette_state_test.gd`)

**Status**: [x] Complete — 2026-08-06

`tests/unit/build_shop_ui/palette_state_test.gd` (72 assertions) exists,
passes, and is registered in `tests/headless_runner.gd` TEST_FILES. Full
headless suite: **3500 passed, 0 failed** (3428 pre-existing + 72 new).
Evidence: `production/qa/evidence/build-shop-palette-evidence.md`.

---

## Dependencies

- Depends on: EquipmentCatalog (`get_definition`), Economy (`balance_changed`) — exist; Shop query surface (Story 002 supplies it; this story may render against a placeholder availability state until then)
- Unlocks: Story 002 (gating consumes the rendered states), Story 003 (arbitration), Story 004 (handoff)
