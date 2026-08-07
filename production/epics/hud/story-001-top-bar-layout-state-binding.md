# Story 001: Top-bar Layout & Read-only State Binding

> **Epic**: hud
> **Status**: Complete — 2026-08-06 (QA 终审 PASS, t_759c1100 — 2026-08-07)
> **Layer**: Presentation
> **Type**: UI
> **Estimate**: M — 2 sessions (≤4h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-06

## Context

**GDD**: `design/gdd/hud.md`
**Requirement**: `TR-HUD-001`, `TR-HUD-007`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0001 (DI Container & Scene Bootstrap); ADR-0005 (Signal Bus & Event Routing)
**ADR Decision Summary**: The HUD is a scene-tree Control hierarchy (NOT a RefCounted sim system). It subscribes to `balance_changed` and reads `global_satisfaction` / TimeSystem pause/speed/tick state; it never mutates sim state except forwarding pause/speed input. Typed signal connections only.

**Engine**: Godot 4.7.1 | **Risk**: MEDIUM
**Engine Notes**: Control offset transforms (4.7 NEW) available for animated UI but must not break container layout. dual-focus (4.6+) → keyboard via `_unhandled_key_input`, focus-independent. `TICKS_PER_DAY` is NOT defined by TimeSystem (HUD GDD OQ1) — use a data-driven provisional value (default 1800) pending the game-designer decision.

**Control Manifest Rules (Presentation layer)**:
- Required: Use `TileMapLayer` for grid/floor (not applicable to HUD itself but the scene it overlays); typed signal connections only
- Required: Use `tween_await()` for UI/feedback sequencing (verify 4.7.1 signature first — post-cutoff)
- Forbidden: Never use `TileMap`; never use string-based signal connections

---

## Acceptance Criteria

*From GDD `design/gdd/hud.md`, scoped to this story:*

- [x] AC7 GIVEN any supported resolution, WHEN the HUD renders, THEN text stays readable at minimum font size and no element overlaps the play area — automated: min font ≥ 16px @1080p, top-bar strip ≤ 8% of 1080p, safe margin ≥ 16px (hud_layout_test.gd); visual pass pending playable build (evidence file §3)
- [x] AC8 GIVEN a loaded game, WHEN the HUD renders, THEN it shows the paused state and the loaded money/satisfaction/day immediately (no stale values) — verified by hud_state_binding_test.gd load-state rig (balance 1240 / 77% / Day 3 / PAUSED rendered on first refresh_all)
- [x] Core Rule 1 GIVEN a fresh boot, WHEN the HUD first renders, THEN the top bar shows money (Butter, coin icon) top-left, satisfaction top-center, day/time + pause/speed top-right, and nothing else (no bottom bar, no side panels) — structural layout verified (hud_layout_test.gd: single TopBar, F-pattern order, group contents); visual pass pending playable build

---

## Implementation Notes

*Derived from ADR-0001 + ADR-0005 Implementation Guidelines:*

**Scene structure** (e.g. `src/ui/hud.gd` + `src/ui/hud.tscn` or built in code):
- One top bar Control (`HBoxContainer` or anchored `Control`), safe margin ≥ 16px from screen edges at 1.0× UI scale, scaled with UI scale
- Three groups left→right: money (Butter coin icon + Label), satisfaction meter (small quiet meter + % Label + face/heart icon), day/time + transport cluster
- The top bar occupies ≤ ~8% of vertical screen height at 1080p; never covers the center play area

**State binding (event-driven, never poll)**:
- Subscribe to `Economy.balance_changed(new_balance, delta)` → update money Label (tween is Story 002's scope; here just set the value)
- Read `Satisfaction.global_satisfaction` (a plain var) → update % Label (meter animation is Story 003's scope)
- Read `TimeSystem.get_tick_count()` → derive `day = 1 + floor(tick_count / TICKS_PER_DAY)`, `time_of_day = (tick_count mod TICKS_PER_DAY) / TICKS_PER_DAY` (Formulas section); `TICKS_PER_DAY` as a data-driven config value (provisional 1800, note HUD GDD OQ1)
- Read `TimeSystem.is_paused()` / `get_speed_multiplier()` → transport cluster state (buttons are Story 004's scope; here bind state)
- On load (game loads / scene enters): render paused state + loaded values immediately — no stale pre-load values (AC8)

**Read-only discipline (Core Rule 5 / TR-HUD-006)**:
- No popups, toasts, or badges on the HUD; event feedback lives in-world, never here
- The HUD initiates no simulation changes except pause/speed (forwarded to TimeSystem — Story 004)

**4.7.1 pitfalls**:
- `class_name` must follow `extends` immediately; under headless load reference cross-script classes via `preload` const aliases
- `var x := expr` fails inference on Variant returns → explicit `: Type` for locals reading system state

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 002]: money count tween animation (~0.3s count-up/down, re-target mid-tween)
- [Story 003]: satisfaction meter ramp (Sage→neutral→muted rose, ~1s ease, icon shape change)
- [Story 004]: pause/speed transport buttons + hotkeys (Space/1/2/3), day/time icon

---

## QA Test Cases

*Derived from GDD acceptance criteria. UI story — manual verification steps plus automated state-binding where practical.*

- **AC7**: 分辨率与可读性
  - Setup: run at 1280×720, 1920×1080, 2560×1440 with UI scale 1.5×
  - Verify: text ≥16px @1080p; no HUD element overlaps the play area
  - Pass condition: all three resolutions render the top bar within safe margins with readable text
  - **QA 回填 (2026-08-07)**: PASS — 自动化 invariants 全绿（hud_layout_test.gd 35/0 standalone）：8 个 HUD label font_size 全部 ≥16px @1080p；TopBar strip 48px + 16px margin ≤ 8% of 1080p；safe margin left/right 均为 16px @1.0×；ui_scale 1.5× 重排确定（margin 24 / bar 72 / font 24）。三分辨率视觉走查步骤已入 evidence §3，待 playable build 后人工签核（主场景组装属后续 story）

- **AC8**: 加载即显示
  - Setup: save a game with known money/satisfaction/day, load it
  - Verify: HUD renders paused state + loaded values immediately on the first frame
  - Pass condition: no stale pre-load values; pause state reflected; values match the save
  - **QA 回填 (2026-08-07)**: PASS — hud_state_binding_test.gd（71/0 standalone，含 HUD-002 后追加的 tween 断言）：load rig balance $1,240 / satisfaction 77% / tick_count 3600 / paused → 首个 refresh_all() 即渲染 $1,240 / 77% / Day 3 / PAUSED / —（速度占位），无陈旧默认值（默认 rig 为 $500/50%/Day 1 可对照）；refresh_all() 重读 live state 无 label 缓存

- **Core Rule 1**: 布局
  - Setup: fresh boot, HUD first renders
  - Verify: money top-left (Butter, coin icon), satisfaction top-center, day/time + transport top-right
  - Pass condition: all three groups present in the F-pattern positions; nothing else on the HUD
  - **QA 回填 (2026-08-07)**: PASS — hud_layout_test.gd 35/0：root 恰一个子节点 TopBar（无 bottom bar / side panel）；F-pattern 顺序 MoneyGroup→LeftSpacer→SatisfactionGroup→RightSpacer→TimeGroup（spacer expand-fill 把 time 推到右侧）；MoneyGroup=CoinIcon(🪙 Butter)+MoneyLabel、SatisfactionGroup=FaceIcon+Meter(ProgressBar 0..100)+%Label、TimeGroup=DayLabel+TimeOfDayLabel+TransportCluster(PauseStateLabel+SpeedStateLabel)；HUD root/topbar/全后代 mouse_filter IGNORE（读-only，无输入捕获）；树内无 popup/toast/badge/dialog 节点；HUD 无 set_paused()/set_speed() 方法（transport 输入属 Story 004）；refresh/signal 处理不改变 balance/tick_count/paused/global_satisfaction

---

## Test Evidence

**Story Type**: UI
**Required evidence**:
- `production/qa/evidence/hud-top-bar-layout-evidence.md` — manual walkthrough / screenshot sign-off
- Automated state-binding coverage where practical (e.g. `tests/unit/hud/hud_state_binding_test.gd` verifying day/time derivation from `tick_count` with provisional `TICKS_PER_DAY`)

**Status**: [x] Complete — 2026-08-06

`src/ui/hud.gd` exists (code-built Control hierarchy) and subscribes to
`balance_changed` (S6), reads `global_satisfaction` + TimeSystem
tick/pause/speed state, and re-renders on `tick_completed` (S2). Two test
files registered in `tests/headless_runner.gd` TEST_FILES:
`tests/unit/hud/hud_state_binding_test.gd` (65 assertions — GDD Formulas
day/time derivation with provisional TICKS_PER_DAY=1800, AC8 load-state
binding, S6/S2 refresh, pause/speed binding, config overrides, TR-HUD-006
read-only) and `tests/unit/hud/hud_layout_test.gd` (35 assertions — Core
Rule 1 structure, AC7 font/margin/height budgets, no bottom/side bars).
Full headless suite: 3528 passed / 0 failed (baseline 3428 + 100 new),
no new leaks. Visual walkthrough checklist (AC7/AC8/Core Rule 1) is
documented in the evidence file, pending the playable build for sign-off.

**QA 独立复跑 (t_759c1100, 2026-08-07, main tip fb4f235 — 含 HUD-001 提交 c918b16)**:
- `godot --headless --script tests/unit/hud/hud_layout_test.gd` → 35 passed / 0 failed, exit 0
- `godot --headless --script tests/unit/hud/hud_state_binding_test.gd` → 71 passed / 0 failed, exit 0（HUD-001 原有断言不变；+6 为 HUD-002 追加的 tween 断言）
- `godot --headless --script tests/headless_runner.gd` 全量 → 4036 passed / 0 failed, exit 0, RESULT: PASSED, 0 SCRIPT ERROR；ObjectDB 泄漏 218 / 资源 12 与既有基线完全一致（无新增）
- AC7/AC8/Core Rule 1 + 只读纪律逐项核对 PASS（详见上方 QA Test Cases 回填）

---

## Dependencies

- Depends on: Economy (balance_changed), Satisfaction (global_satisfaction), TimeSystem (tick_count/pause/speed) — all implemented in src/ (Sprint 3/4). No Presentation-layer prerequisite.
- Unlocks: Story 002 (money tween), Story 003 (satisfaction meter), Story 004 (transport + day/time display)
