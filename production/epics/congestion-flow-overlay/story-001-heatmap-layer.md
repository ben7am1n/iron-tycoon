# Story 001: Heatmap Layer (ImageTexture + Shader, 10Hz)

> **Epic**: congestion-flow-overlay
> **Status**: Complete — 2026-08-06
> **Layer**: Presentation
> **Type**: Logic
> **Estimate**: M — 2 sessions (≤4h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-06

## Context

**GDD**: `design/gdd/congestion-flow-overlay.md`
**Requirement**: `TR-CFO-001` (heatmap part), `TR-CFO-002`, `TR-CFO-003`, `TR-CFO-009`, `TR-CFO-010`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0005 (Signal Bus & Event Routing)
**ADR Decision Summary**: The overlay subscribes to Congestion's `congestion_updated` signal (10 Hz) and refreshes the heatmap `ImageTexture` ONLY on that signal — never in `_process`. Typed signal connections only. Heatmap is a `CanvasItem`-level layer (ColorRect + shader) that renders every frame from the currently-bound texture (free); only CPU-side pixel writes + upload are gated to the sim tick.

**Engine**: Godot 4.7.1 | **Risk**: HIGH
**Engine Notes**: **DrawableTexture2D (4.7 NEW) is deliberately BYPASSED for MVP** — the control manifest's Presentation rule says "use DrawableTexture2D", but the GDD (Core Rule 2 + OQ1), the architecture table, and TR-CFO-010 explicitly reject it: UNVERIFIED against local 4.7.1, zero benefit at 130 texels. **Use `ImageTexture` + CanvasItem shader with per-sampler BILINEAR** (isolated exception to the global Nearest filter). `ImageTexture.update()` is the correct refresh call. Grid is 13×10 cells (per_cell_density field from Congestion).

**Control Manifest Rules (Presentation layer)**:
- Required: typed signal connections only; texture filter Nearest for crisp 2D pixel-art (with the heatmap shader's per-sampler BILINEAR as the deliberate exception)
- Forbidden: string-based signal connections; never use `TileMap`

---

## Acceptance Criteria

*From GDD `design/gdd/congestion-flow-overlay.md`, scoped to this story:*

- [x] AC9 GIVEN Congestion emits `congestion_updated` with a known `per_cell_density` field, WHEN the overlay refreshes, THEN the heatmap `Image` texels match the field (per-cell), and no refresh occurs on frames without the signal (10 Hz cadence, not per-frame)
- [x] AC1 GIVEN a fresh game boot, WHEN the main scene loads, THEN the heatmap is OFF and no legend is on-screen
- [x] AC7 GIVEN the player toggles the heatmap on for the first time in a session, WHEN it activates, THEN a one-time contextual tip appears and never recurs after dismissal
- [x] Formula GIVEN a per-cell density value, WHEN the heatmap renders, THEN `heat_alpha = smoothstep(low_cut=0.2, high_cut=0.8, density_cell)` mapped to Dusty Rose `#E0A0A0`; below `low_cut` the cell stays transparent

---

## Implementation Notes

*Derived from ADR-0005 + GDD Core Rules 2/3/8:*

**Heatmap rendering (Core Rule 2)**:
- 13×10 density field (`Congestion.per_cell_density(cell)` → float `[0,1]`) written into a 13×10 `Image`/`ImageTexture`
- Sampled by a `CanvasItem` shader over a grid-covering `ColorRect`; the shader forces **bilinear** sampling on THIS sampler only (per-sampler in GDShader — independent of the project's global Nearest filter) so the heatmap reads as soft fog
- `density_to_heat`: `heat_alpha = smoothstep(low_cut=0.2, high_cut=0.8, density_cell)`; output color Dusty Rose `#E0A0A0` at `alpha = heat_alpha × heatmap_layer_opacity` (default 0.6)
- Below `low_cut` → invisible (calm); empty gym → density ~0 everywhere → fully transparent

**Update cadence (Core Rule 3, AC9)**:
- `Image` rewritten + `ImageTexture.update()` called ONLY on `congestion_updated` (10 Hz) — never in `_process`
- Shader/ColorRect renders every frame from the currently-bound texture (free)

**Toggle + one-time tip (Core Rule 8 + AC1/AC7)**:
- Heatmap default OFF; `toggle_flow_overlay` (H key + HUD utility-cluster button) toggles with tween fade-in/out
- First-ever toggle in a session shows a one-time contextual tip (~4 s, auto-dismiss or next click, never shown again)
- Hover legend popover on the toggle button only (no persistent legend — Pillar 2)

**Cell→world mapping**: use GridSystem's grid_world_conversion (`grid_to_world_*`); cell size must NOT be hardcoded (architecture pinned value).

**4.7.1 pitfalls**:
- `class_name` not globally registered under headless load → `preload` const aliases for cross-script refs; `class_name` follows `extends` immediately
- `var x := expr` fails on Variant returns → explicit `: float` when reading `per_cell_density`
- Lambda closures do NOT write back outer-scope locals → use a `RefCounted` counter for signal-driven update counting in tests

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 002]: per-equipment congestion glyph (toggle-gated with heatmap)
- [Story 003]: access-blocked layer (always-on, default-visible)
- [Story 004]: rejection tooltip, drag-dim, information layering priority

---

## QA Test Cases

*Derived from GDD acceptance criteria. Logic story — automated coverage required.*

- **AC9**: 10Hz 纹理刷新
  - Given: Congestion emits `congestion_updated` with a known `per_cell_density` field
  - When: the overlay refreshes
  - Then: heatmap Image texels match the field per-cell; no refresh occurs on frames without the signal
  - Edge cases: two signals in one frame (both applied); zero frames without signal (no redundant writes)

- **AC1**: 默认关闭
  - Setup: fresh boot, main scene loads
  - Verify: heatmap OFF; no legend on-screen
  - Pass condition: toggle state OFF; legend only on hover

- **AC7**: 一次性提示
  - Setup: first toggle of the session
  - Verify: one-time tip appears (~4s), auto-dismisses or dismisses on next click, never recurs
  - Pass condition: tip shown exactly once per session

- **Formula**: density_to_heat
  - Given: density_cell = 0.5, low_cut = 0.2, high_cut = 0.8
  - When: heatmap renders
  - Then: heat_alpha = smoothstep(0.2, 0.8, 0.5) ≈ 0.5; at layer opacity 0.6, effective alpha ≈ 0.3; below 0.2 → transparent
  - Edge cases: density 0.1 → alpha 0; density 1.0 → full Dusty Rose

---

## Test Evidence

**Story Type**: Logic
**Required evidence**:
- `tests/unit/congestion_overlay/heatmap_texture_test.gd` — must exist and pass (texel-vs-field equivalence, 10Hz cadence, density_to_heat mapping)

**Status**: [x] Complete — 2026-08-06 (58 asserts green; full headless suite 3486/0 PASSED)

---

## Dependencies

- Depends on: Congestion (src/systems/congestion.gd — `per_cell_density(cell)`, `congestion_updated` signal, both exist), GridSystem (grid_world_conversion), PlacementSystem drag state (for dimming — Story 004)
- Unlocks: Story 002 (glyph shares the toggle), Story 004 (drag-dim targets this layer)
