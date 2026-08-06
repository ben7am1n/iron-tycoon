# Story 001: Top-bar Layout & Read-only State Binding

> **Epic**: hud
> **Status**: Ready
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

- [ ] AC7 GIVEN any supported resolution, WHEN the HUD renders, THEN text stays readable at minimum font size and no element overlaps the play area
- [ ] AC8 GIVEN a loaded game, WHEN the HUD renders, THEN it shows the paused state and the loaded money/satisfaction/day immediately (no stale values)
- [ ] Core Rule 1 GIVEN a fresh boot, WHEN the HUD first renders, THEN the top bar shows money (Butter, coin icon) top-left, satisfaction top-center, day/time + pause/speed top-right, and nothing else (no bottom bar, no side panels)

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

- **AC8**: 加载即显示
  - Setup: save a game with known money/satisfaction/day, load it
  - Verify: HUD renders paused state + loaded values immediately on the first frame
  - Pass condition: no stale pre-load values; pause state reflected; values match the save

- **Core Rule 1**: 布局
  - Setup: fresh boot, HUD first renders
  - Verify: money top-left (Butter, coin icon), satisfaction top-center, day/time + transport top-right
  - Pass condition: all three groups present in the F-pattern positions; nothing else on the HUD

---

## Test Evidence

**Story Type**: UI
**Required evidence**:
- `production/qa/evidence/hud-top-bar-layout-evidence.md` — manual walkthrough / screenshot sign-off
- Automated state-binding coverage where practical (e.g. `tests/unit/hud/hud_state_binding_test.gd` verifying day/time derivation from `tick_count` with provisional `TICKS_PER_DAY`)

**Status**: [ ] Not yet created

---

## Dependencies

- Depends on: Economy (balance_changed), Satisfaction (global_satisfaction), TimeSystem (tick_count/pause/speed) — all implemented in src/ (Sprint 3/4). No Presentation-layer prerequisite.
- Unlocks: Story 002 (money tween), Story 003 (satisfaction meter), Story 004 (transport + day/time display)
