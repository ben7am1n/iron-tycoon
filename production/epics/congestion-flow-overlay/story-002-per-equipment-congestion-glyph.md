# Story 002: Per-Equipment Congestion Glyph

> **Epic**: congestion-flow-overlay
> **Status**: Complete — 2026-08-06 (QA 终审 PASS, t_aee1e56d — 2026-08-07)
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
  - **QA 回填 (2026-08-07)**: PASS — glyph_fill_test.gd 93/0 standalone：congestion_glyph_fill(0.69)=0.69（story QA 例）、0/1.0/−0.1/1.5/−1e-9 全 clamp；glyph.set_fill 同范围 clamp；REAL Congestion rig 集成——8 会员聚于 access cell 后 per_equipment_congestion=0.09，glyph fill_fraction == 0.09 逐位相等；会员离开后 EMA 衰减 0.063，fill 精确跟随

- **Core Rule 4**: 形状优先
  - Setup: congestion rises 0 → 1.0
  - Verify: outline fills progressively; Dusty Rose tint as reinforcement
  - Pass condition: fill level readable with color removed
  - **QA 回填 (2026-08-07)**: PASS — fill rect height = inner_h × fill_fraction 纯函数：fill 0 → 零高矩形（空 outline）；1.0 → 满内高 16px；0.69 → 69% 内高且从底部 31% 处起（bottom-up）；0.25/0.5/0.75 严格单调递增。形状与颜色通道解耦（同 fill 两次调用 fill_rect 相等）——去色后可读，色盲安全 by construction（AC6）

- **AC6**: 色盲/高对比
  - Setup: colorblind/high-contrast mode ON
  - Verify: glyph distinguishable by shape/fill alone; outlines thickened in high-contrast
  - Pass condition: no information carried by color alone
  - **QA 回填 (2026-08-07)**: PASS — set_high_contrast(true) → outline 1.0→2.0（config 驱动 1.5/3.0 均验证），fill ratio 精确保持（inner_h 随 margin 收缩但相对填充不变）；切回 false → 恢复 1.0。形状通道从不依赖颜色

- **Removal**: 移除即清除
  - Given: an equipment is removed
  - When: removal is processed
  - Then: its glyph is removed the same frame (no orphan icon)
  - Edge cases: removal during a congestion_updated refresh
  - **QA 回填 (2026-08-07)**: PASS — grid_changed(S1) reconcile 同帧丢弃：clear() 后 glyph 计数立即 1→0，无孤儿；removal 与 S8 refresh 同帧竞争 → reconcile 幂等，refresh_count 仍按信号计数；移除后重放同一 id → 全新 glyph fill 0.0（无陈旧值）。新放置 equipment → 同帧建 glyph（fill 0），下一 S8 填充

---

## Test Evidence

**Story Type**: Visual/Feel
**Required evidence**:
- `production/qa/evidence/cfo-glyph-evidence.md` — manual walkthrough / sign-off
- Automated coverage of fill_fraction mapping where practical (e.g. `tests/unit/congestion_overlay/glyph_fill_test.gd`)

**Status**: [x] Complete — 2026-08-06 (93 asserts green; full headless suite 3809/0 PASSED at tip)

**QA 独立复跑 (t_aee1e56d, 2026-08-07, main tip 6a87202)**:
- `godot --headless --script tests/unit/congestion_overlay/glyph_fill_test.gd` → 93 passed / 0 failed, exit 0
- `godot --headless --script tests/headless_runner.gd` 全量 → 4036 passed / 0 failed, RESULT: PASSED, 0 SCRIPT ERROR；ObjectDB 泄漏 218 / 资源 12 与既有基线完全一致（无新增）
- BLOCKING 三项逐项核对 PASS：AC10（fill_fraction == per_equipment_congestion，clamp [0,1]，含 REAL Congestion rig 集成）、Core Rule 4（形状/填充为主信号，Dusty Rose 仅次）、AC6（去色后仅凭形状/填充可区分；高对比加粗 outline 1.0→2.0，fill ratio 保持）——详见上方 QA Test Cases 回填
- 非 BLOCKING 亦核对 PASS：共享 toggle（跟随真实 HeatmapLayer.toggle_flow_overlay）、10 Hz 信号驱动 cadence（无 _process，结构性验证）、同帧移除/重放、grid_world_conversion 锚定、typed signal.connect 纪律

---

## Dependencies

- Depends on: Story 001 (heatmap layer + shared toggle state + overlay scene infra)
- Unlocks: None directly (Story 004 consumes glyph state for layering priority)
