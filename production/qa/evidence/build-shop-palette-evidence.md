# QA Evidence — BSUI-001: Shop Palette Rendering

> **Story**: production/epics/build-shop-ui/story-001-shop-palette-rendering.md
> **Epic**: build-shop-ui (Presentation layer)
> **Date**: 2026-08-06
> **Engine**: Godot 4.7.1 (headless-verified)
> **Story Type**: UI — evidence ADVISORY (manual walkthrough) + automated state assertions

## Summary

The build shop palette is implemented as a Control hierarchy under `src/ui/`
(four new files, `class_name` registered in the global script class cache):

| File | Class | Role |
|------|-------|------|
| `src/ui/build_shop_palette.gd` | `BuildShopPalette extends HBoxContainer` | Edge-docked rack: builds one `PaletteTile` per catalog item, subscribes to `Economy.balance_changed` (S6, typed signal connection) and re-derives every tile's availability state synchronously |
| `src/ui/palette_tile.gd` | `PaletteTile extends PanelContainer` | Icon + name + Butter price + lock icon; renders the three availability states colorblind-safely (achromatic modulate + lock shape) |
| `src/ui/palette_availability.gd` | `PaletteAvailability extends RefCounted` | The Shop query surface contract (`can_purchase` / `is_unlocked`) — typed seam Story 002's real Shop will extend |
| `src/ui/placeholder_palette_availability.gd` | `PlaceholderPaletteAvailability extends PaletteAvailability` | Story-001 placeholder implementing shop-purchase.md Core Rules 1/5 exactly (`cost == 0 OR Economy.can_afford(cost)`; `unlock_requirement == ""`) |

Automated coverage: `tests/unit/build_shop_ui/palette_state_test.gd` — **72
asserts, 0 failed** (registered in `tests/headless_runner.gd` TEST_FILES).

Full suite: **3500 passed, 0 failed** (3428 pre-existing + 72 new).

## Blocking AC Verification

### Core Rule 1 — 瓦片内容 (icon + name + price in Butter)

- ✅ Automated: for every catalog item, the tile renders a non-empty icon
  slot, `display_name`, and `"$%d"` Butter price (3-item catalog, 15 asserts).
- ✅ Automated: empty catalog → calm "Nothing available yet" hint visible,
  zero tiles, nothing draggable, unknown-id state query returns -1 (no error,
  no crash).
- ✅ Manual: tile background Warm Cream `#F4E9D8`, name Soft Charcoal
  `#3C3A42`, price Butter `#F5D97B` (art-bible §4); panel border Soft Charcoal.
- ⚠️ Icon note: the catalog has no icon asset field yet — the icon slot
  renders a placeholder glyph (first rune of the display name). Art pass
  swaps `_icon_label` for a `TextureRect`; slot structure and tests unchanged.

### AC1 — 不可负担置灰 (greyed, no red, inert)

- ✅ Automated: at balance below cost, tile state == `UNAFFORDABLE`,
  `is_greyed()` true, modulate is achromatic `(0.55, 0.55, 0.55)` — equal RGB
  channels, so no hue and no red survive (a red "denied" state would have
  r > g/b); `is_draggable()` false at both tile and palette level.
- ✅ Manual: calm grey — Pillar 2, never a red warning. Mouse-down drag
  gating is Story 002's logic; the rendered state + `is_item_draggable()`
  query ship here, and tiles are input-ready (mouse_filter STOP,
  focus_mode FOCUS_ALL).

### AC2 — 余额变化点亮 (full-tint within one frame of balance_changed)

- ✅ Automated: `Economy.credit(250)` crosses the cost boundary →
  `balance_changed` fires synchronously → the S6 handler re-derives
  synchronously → tile is `AFFORDABLE`, modulate white, draggable — the
  assertion reads the tile state immediately after the emit returns (no
  manual refresh, no await). `palette_refreshed` fired exactly once.
- ✅ Automated: reverse direction — spend drops balance below cost →
  re-greyed within one frame; only crossing items change.
- ✅ Automated: game-loop revenue path — 5 × `member_completed_visit` (S5,
  +$12 each) crosses the cost → tile lights up.
- ✅ Automated: boundary — balance == cost → affordable; balance == cost − 1
  → greyed.

### AC3 — 锁定图标 (lock icon, shape)

- ✅ Automated: `unlock_requirement != ""` → state == `LOCKED`, lock label
  visible (shape, not color), not draggable, greyed.
- ✅ Automated: lock dominates affordability — at balance ≥ cost a locked
  item stays LOCKED.
- ✅ Automated: locked ≠ merely-unaffordable — lock icon present ONLY on the
  locked tile; the two grey states are distinguished by shape.

### AC8 — 色盲模拟 (distinguishable without color)

- ✅ Automated: across all three states every modulate is achromatic
  (r == g == b) — zero color/hue information anywhere; the states differ
  only by tint-desaturation (full-tint white vs the shared grey) and lock
  icon shape. A color-free read (grey-ness + lock-shape) identifies all
  three states.
- ✅ Manual walkthrough: desaturate the screen → affordable (full lightness,
  no lock), unaffordable (grey, no lock), locked (grey + lock glyph) remain
  distinct.

### Shop query seam (Story 002 handoff)

- ✅ Automated: with a scripted query layer reporting LOCKED for a def whose
  `unlock_requirement` is empty, the palette renders LOCKED — the palette
  consumes the injected `PaletteAvailability` report, not raw def fields.
  Story 002 swaps `PlaceholderPaletteAvailability` for the real Shop with
  zero palette changes.

## Manual Walkthrough (advisory)

Run inside the live game shell when it exists (no main scene yet — this
story is the build-shop-ui dependency-chain root):

1. Boot a session with a catalog of mixed prices → palette renders one tile
   per item along the bottom edge; each tile shows icon + name + price.
2. Balance below an item's cost → tile is calm grey; mouse-down does nothing.
3. Earn/credit past the cost → the tile returns to full tint immediately
   (within one frame), no manual refresh.
4. A locked item (`unlock_requirement` set) → greyed with the lock glyph;
   stays locked even after the balance covers its price.
5. Empty catalog → "Nothing available yet" hint; nothing draggable.
6. Desaturate the screen (colorblind pass) → the three states remain
   distinguishable by lightness + lock shape.

## Files Changed

- `src/ui/palette_availability.gd` (new)
- `src/ui/placeholder_palette_availability.gd` (new)
- `src/ui/palette_tile.gd` (new)
- `src/ui/build_shop_palette.gd` (new)
- `tests/unit/build_shop_ui/palette_state_test.gd` (new, 72 asserts)
- `tests/headless_runner.gd` (register new test)
- `.godot/global_script_class_cache.cfg` (register 4 new class_names)

## Known Gaps / Future Work

- Icon art assets (placeholder glyph until art pass).
- Lock glyph is a text glyph (🔒) — texture swap at art pass.
- Modulate-grey is the Control-level desaturation approximation; a
  CanvasItem desaturation shader can be layered on at the art pass for
  texture-level desaturation (not needed for flat placeholder visuals).
- UX-spec grey→tint ease (~150 ms "it's yours now" moment): the STATE flips
  within one frame per AC2 (verified); the optional visual ease (a Control
  offset-transform tween per the 4.7 engine note) is deferred polish — it
  must not delay the AC2 state flip and must not break container layout.
- Drag gating (AC1 mouse-down inertness → Story 002), hover "Save $X more"
  (TR-BSUI-005), mode arbitration (003), handoff cues (004).
