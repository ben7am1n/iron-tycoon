# Story 002: Per-Equipment Congestion Glyph

> **Epic**: congestion-flow-overlay
> **Status**: Complete — 2026-08-06
> **Layer**: Presentation
> **Type**: Visual/Feel
> **Estimate**: S — 1 session (≤2h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-06

## Context

**GDD**: `design/gdd/congestion-flow-overlay.md`
**Requirement**: `TR-CFO-001` (glyph part), `TR-CFO-004`, `TR-CFO-011` (glyph part)
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0005 (Signal Bus & Event Routing)
**ADR Decision Summary**: The overlay subscribes to `congestion_updated` (10 Hz) and refreshes per-equipment glyphs on the same signal as the heatmap. Equipment glyphs update on the same cadence — no per-frame work.

**Engine**: Godot 4.7.1 | **Risk**: MEDIUM
**Engine Notes**: `CanvasItem._draw` / draw_rect/draw_circle per the GDD's Pinned Engine Caveats (draw_string signature: first arg is `Font`, `font_size` precedes `color` — only if text is needed; glyphs are shape-based). `class_name` follows `extends` immediately.

**Control Manifest Rules (Presentation layer)**:
- Required: typed signal connections only
- Forbidden: string-based signal connections

---

## Acceptance Criteria

*From GDD `design/gdd/congestion-flow-overlay.md`, scoped to this story:*

- [x] AC10 GIVEN an equipment's `per_equipment_congestion` value, WHEN its glyph updates, THEN `fill_fraction` equals that value (clamped `[0,1]`)
- [x] Core Rule 4 GIVEN any congestion level, WHEN the glyph renders, THEN the shape/fill is the primary signal (an empty outline fills up as congestion rises) with Dusty Rose tint as secondary reinforcement only — colorblind-safe by construction
- [x] AC6 GIVEN colorblind/high-contrast mode is enabled, WHEN congestion renders, THEN it is distinguishable by shape/icon alone with color removed

---

## Implementation Notes

*Derived from ADR-0005 + GDD Core Rule 4:*

**Shape-first, secondary channel (Core Rule 4)**:
- Each equipment instance carries a small icon whose shape/fill is the primary signal — empty outline fills up as congestion rises; Dusty Rose (`#E0A0A0`) tint is secondary reinforcement only
- `fill_fraction = clamp(per_equipment_congestion, 0, 1)` (Formulas section) — readable as "quite busy" by fill alone
- Colorblind-safe by construction: fill level is readable with color removed (TR-CFO-004)
- High-contrast mode thickens glyph outlines (TR-CFO-011)

**Toggle-gated with the heatmap** (Core Rule 1): glyphs show/hide with the heatmap toggle — one shared toggle state.

**Update cadence**: glyphs update on `congestion_updated` (10 Hz), same as the heatmap — never per-frame.

**Equipment removal**: when an equipment is removed, its glyph is removed the same frame (subscribe to the removal signal / rebind to Congestion's dropped entry — never an orphan icon over an empty cell). This cross-cuts with Story 001's layer infra.

**Playtest note**: glyphs are the SECONDARY readout — heatmap clarity and dissipation-on-rearrange responsiveness carry the crowding signal. Do not over-invest in glyph detail.

**4.7.1 pitfalls**:
- `var x := expr` fails on Variant returns → explicit `: float` when reading `per_equipment_congestion(instance_id)` (returns float)
- draw_string signature if text labels are used: first arg Font (ThemeDB.fallback_font, guard != null under headless), font_size before color

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 001]: heatmap layer + toggle infra + one-time tip
- [Story 003]: access-blocked layer (always-on, default-visible)
- [Story 004]: rejection tooltip, drag-dim, layering priority

---

## QA Test Cases

*Derived from GDD acceptance criteria. Visual/Feel story — manual verification plus automated fill-mapping.*

- **AC10**: fill_fraction 映射
  - Given: per_equipment_congestion = 0.69
  - When: glyph updates
  - Then: fill_fraction = 0.69 (clamped [0,1])
  - Edge cases: 0 → empty outline; 1.0 → fully filled; -0.1 / 1.5 → clamped

- **Core Rule 4**: 形状优先
  - Setup: congestion rises 0 → 1.0
  - Verify: outline fills progressively; Dusty Rose tint as reinforcement
  - Pass condition: fill level readable with color removed

- **AC6**: 色盲/高对比
  - Setup: colorblind/high-contrast mode ON
  - Verify: glyph distinguishable by shape/fill alone; outlines thickened in high-contrast
  - Pass condition: no information carried by color alone

- **Removal**: 移除即清除
  - Given: an equipment is removed
  - When: removal is processed
  - Then: its glyph is removed the same frame (no orphan icon)
  - Edge cases: removal during a congestion_updated refresh

---

## Test Evidence

**Story Type**: Visual/Feel
**Required evidence**:
- `production/qa/evidence/cfo-glyph-evidence.md` — manual walkthrough / sign-off
- Automated coverage of fill_fraction mapping where practical (e.g. `tests/unit/congestion_overlay/glyph_fill_test.gd`)

**Status**: [x] Complete — 2026-08-06 (93 asserts green; full headless suite 3579/0 PASSED)

---

## Dependencies

- Depends on: Story 001 (heatmap layer + shared toggle state + overlay scene infra)
- Unlocks: None directly (Story 004 consumes glyph state for layering priority)
