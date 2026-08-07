# Story 004: Pause/Speed Transport + Day/Time Display

> **Epic**: hud
> **Status**: Complete — 2026-08-06
> **Layer**: Presentation
> **Type**: UI
> **Estimate**: M — 2 sessions (≤4h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-06

## Context

**GDD**: `design/gdd/hud.md`
**Requirement**: `TR-HUD-005`, `TR-HUD-006`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0005 (Signal Bus & Event Routing)
**ADR Decision Summary**: Transport controls forward pause/speed input to TimeSystem (`pause()`/`resume()`/`set_speed(int)` — all exist in `src/systems/time_system.gd`). The HUD initiates no other simulation changes. Keyboard handled via `_unhandled_key_input` (focus-independent, dual-focus 4.6+).

**Engine**: Godot 4.7.1 | **Risk**: MEDIUM
**Engine Notes**: Control buttons (Button nodes) + hotkey handling; dual-focus (4.6+) — keyboard input via `_unhandled_key_input` so hotkeys work regardless of focus. Control offset transforms (4.7 NEW) optional for the active-button cue.

**Control Manifest Rules (Presentation layer)**:
- Required: typed signal connections only
- Forbidden: string-based signal connections; never mutate sim state outside the pause/speed forward

---

## Acceptance Criteria

*From GDD `design/gdd/hud.md`, scoped to this story:*

- [x] AC1 GIVEN game start, WHEN the HUD first renders, THEN Pause is shown active and no speed button is highlighted — automated: fresh rig renders pause active + `get_active_speed()==0` + 0 speed buttons highlighted (transport_test.gd `_test_ac1_fresh_boot_paused_no_speed`); TimeSystem starts paused (GDD Core Rule 9)
- [x] AC4 GIVEN the game is paused, WHEN the player presses Space, THEN the sim resumes at the last-used speed and the corresponding speed button highlights — automated: Space after selecting 3× while paused resumes at 3×, not 1× (`_test_ac4_space_resumes_at_last_speed`); button click path verified too
- [x] AC5 GIVEN any state, WHEN the player presses 1/2/3, THEN speed changes immediately (unpausing if needed) and exactly one speed button shows the active cue — automated: digit hotkeys + speed-button clicks; implicit unpause while paused is one action (`_test_ac5_*`); exactly-one-active invariant across a 10-action chain
- [x] Core Rule 4 GIVEN the player presses a speed already active, THEN it is a no-op (stays at that speed, unpaused) — automated: re-press at 2× leaves speed/pause/tick_count/button-text unchanged, no flicker (`_test_core_rule_4_same_speed_noop`)

---

## Implementation Notes

*Derived from ADR-0005 + GDD Core Rule 4:*

**Transport cluster (top-right, rightmost)**:
- Four small buttons: ‖ (pause), 1×, 2×, 3×
- Active one marked with outline + filled-dot icon (NEVER color alone) — active speed at any moment: exactly one (or none when paused)
- Day/time display sits left of the transport cluster: "Day N" + sun/clock-position icon for time-of-day (icon, not color-only) — `day = 1 + floor(tick_count / TICKS_PER_DAY)`, `time_of_day = (tick_count mod TICKS_PER_DAY) / TICKS_PER_DAY` (Formulas; `TICKS_PER_DAY` data-driven, provisional 1800, HUD GDD OQ1 — game-designer owns the final value)

**Hotkeys (TR-HUD-005)**:
- Space = toggle pause; 1/2/3 = set speed directly AND implicitly unpause (one action, not two — pressing 2 while paused resumes at 2×)
- Handled via `_unhandled_key_input` on the HUD node (focus-independent, dual-focus 4.6+)
- Speed pressed while already at that speed: no-op (stays at that speed, unpaused)

**Transport forwarding**:
- Button click / hotkey → `TimeSystem.pause()` / `resume()` / `set_speed(n)`
- After forwarding, reflect the new state (button highlight updates from TimeSystem state — read `is_paused()` / `get_speed_multiplier()`)
- On load, TimeSystem starts paused → HUD renders paused state immediately (AC1/AC8)

**Read-only discipline (TR-HUD-006)**: no popups/toasts/badges; transport is the ONLY simulation mutation the HUD makes.

**4.7.1 pitfalls**:
- `class_name` follows `extends` immediately; headless cross-script refs via `preload` aliases
- Button focus handling under dual-focus: hotkeys must work regardless of which Control has focus

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 001]: top-bar layout, money/satisfaction/day Label initial binding
- [Story 002]: money count tween
- [Story 003]: satisfaction meter

---

## QA Test Cases

*Derived from GDD acceptance criteria. UI story — manual walkthrough plus automated hotkey/state logic where practical.*

- **AC1**: 初始暂停态 ✅ (automated + manual checklist in evidence)
  - Setup: fresh boot, HUD renders
  - Verify: Pause button shown active; no speed button highlighted
  - Pass condition: matches TimeSystem paused start state — **PASS** (transport_test `_test_ac1_fresh_boot_paused_no_speed`; visual sign-off pending playable build)

- **AC4**: 暂停恢复 ✅ (automated)
  - Setup: game paused; press Space
  - Verify: sim resumes at last-used speed; that speed button highlights
  - Pass condition: resume works; exactly one speed button active — **PASS** (`_test_ac4_space_resumes_at_last_speed`: resumed at 3× after 3× was last-selected; 1× default case; pause-button click path)

- **AC5**: 热键变速 ✅ (automated)
  - Setup: any state; press 2
  - Verify: speed changes immediately (unpausing if paused); exactly one speed button active
  - Pass condition: 1/2/3 each set the right speed; pressing while paused unpauses — **PASS** (`_test_ac5_digit_hotkeys_immediate_speed`, `_test_ac5_digit_hotkey_unpauses_from_paused`)

- **Core Rule 4**: 同速无操作 ✅ (automated)
  - Setup: at 2×; press 2 again
  - Verify: no state change, no flicker
  - Pass condition: no-op; stays at that speed, unpaused — **PASS** (`_test_core_rule_4_same_speed_noop`: speed/pause/tick_count/button-text all unchanged)

- **Day/Time**: 天数显示 ✅ (automated)
  - Setup: advance tick_count past TICKS_PER_DAY boundary
  - Verify: day number increments; time icon reflects time-of-day fraction
  - Pass condition: day = 1 + floor(tick_count / TICKS_PER_DAY) at all points — **PASS** (`_test_day_time_label_updates_on_tick`, `_test_day_rollover_boundary`, `_test_time_of_day_icon_pure`; 12-hour clock-face icon is shape-based, never color alone)

---

## Test Evidence

**Story Type**: UI
**Required evidence**:
- `production/qa/evidence/hud-transport-evidence.md` — ✅ created 2026-08-06 (automated coverage complete; manual walkthrough checklist pending the playable build, ADVISORY by design)
- Automated coverage of hotkey→TimeSystem forwarding + day/time derivation — `tests/unit/hud/transport_test.gd` (100 asserts), registered in `headless_runner.gd` TEST_FILES; QA 独立复跑 merged-main full suite 4487 passed / 0 failed (HUD-004 +113 over baseline 4374)

**Status**: [x] Complete — 2026-08-06

---

## Dependencies

- Depends on: Story 001 (top-bar layout + transport cluster placement + state binding)
- Unlocks: None (this completes the HUD epic)
