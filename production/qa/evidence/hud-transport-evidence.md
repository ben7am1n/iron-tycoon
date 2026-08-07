# Evidence: HUD-004 Pause/Speed Transport + Day/Time Display

**Story**: `production/epics/hud/story-004-pause-speed-transport-day-time.md`
**Story Type**: UI (evidence ADVISORY — manual walkthrough + automated hotkey/state logic)
**Engine**: Godot 4.7.1 (GDScript) | **Date**: 2026-08-06
**Status**: ✅ QA terminal review PASS (2026-08-07, qa-tester card t_f606bc09) — automated coverage verified on merged main; visual walkthrough pending playable build (ADVISORY)

---

## 1. Automated Coverage (verified headless)

`godot --headless --script tests/headless_runner.gd` → **4487 passed / 0 failed**
(QA re-run at merged main, 2026-08-07: story HUD-004 adds +113 assertions over the
main-tip baseline of 4374 = 4036 + BSUI-003 (53) + HUD-003 (285); no new
ObjectDB/resource leaks — identical 218/12 pre-existing baseline counts).

| File | Assertions | Covers |
|------|-----------|--------|
| `tests/unit/hud/transport_test.gd` | 100 (new) | AC1 fresh-boot paused/no-speed, AC4 Space → resume at last-used speed, AC5 1/2/3 immediate speed + implicit unpause, Core Rule 4 same-speed no-op, hotkey→TimeSystem forwarding via `_unhandled_key_input` (echo/release/other-key hygiene), button-click forwarding, dual-focus FOCUS_NONE buttons, exactly-one-active invariant, active-cue visual (outline + filled-dot, never color alone), `time_of_day_icon()` derivation, day/time label updates + rollover on tick_completed, TR-HUD-006 transport-only mutation |
| `tests/unit/hud/hud_state_binding_test.gd` | 82 (incl. HUD-003 additions; HUD-004 +8) | Updated to the Story-004 transport surface: pause/speed state binding via `get_pause_button()`/`get_speed_button()`/`is_pause_active()`/`get_active_speed()`; read-only discipline now asserts transport is the ONLY allowed mutation (`set_paused`/`set_speed` exist, no economy/grid mutation methods) |
| `tests/unit/hud/hud_layout_test.gd` | 40 (was 35) | TransportCluster is now 4 Buttons (`PauseButton` + `SpeedButton1/2/3`); exactly 4 input-capturing (STOP) controls in the tree; button font ≥ 16px |

### Key automated facts (all passing)

- **AC1**: fresh TimeSystem starts paused → pause button shows the active cue
  (filled-dot prefix + outline stylebox override), `get_active_speed() == 0`,
  zero speed buttons highlighted.
- **AC4**: paused + Space → `resume()` at the **last-used** speed (fresh rig: 1×;
  after selecting 3× while paused and re-pausing: 3× — verified the last-speed
  restore, not a hardcoded 1×); the matching speed button shows the active cue.
- **AC5**: pressing 2 while paused unpauses **in the same action** and lands at 2×
  (`set_speed()` records `_last_speed`, then `resume()` applies it — one action
  not two); 1/2/3 each switch immediately while running; exactly one speed button
  active at every running state.
- **Core Rule 4**: pressing the already-active speed re-sets the identical
  multiplier → no state change, no tick fired, no cue flicker (button text
  byte-identical), still unpaused, still exactly one active.
- **Hotkeys (TR-HUD-005)**: Space/1/2/3 forwarded via `_unhandled_key_input`
  (focus-independent, ADR-0005 §5). Echo repeats and key releases ignored;
  A/Enter/Esc/Tab/0/4/9 ignored. Transport buttons are `FOCUS_NONE` so a focused
  Button can never swallow Space under Godot 4.6+ dual-focus (structural).
- **Day/time**: `time_of_day_icon()` maps the [0,1) fraction to a 12-hour clock
  face (`0.0→🕛`, `0.25→🕕`, `0.5→🕛`, `0.75→🕕`, `0.999→🕚`) — icon SHAPE carries
  state, never color alone; `Day N` + icon update on tick_completed; day rolls
  over exactly at TICKS_PER_DAY (1800, data-driven `config["ticks_per_day"]`).
- **TR-HUD-006**: transport forwards touch ONLY TimeSystem pause/speed; balance,
  tick_count, global_satisfaction verified unchanged after hotkey chains.

### QA 独立复跑 (2026-08-07, card t_f606bc09, merged main)

```
$ godot --headless --script tests/unit/hud/transport_test.gd
=== HUD TRANSPORT TEST: 100 passed, 0 failed ===
(exit 0)

$ godot --headless --script tests/headless_runner.gd
TOTAL: 4487 passed, 0 failed
RESULT: PASSED
(exit 0; ObjectDB leak 218 / resources 12 — identical to pre-existing baseline;
 in-suite: transport_test 100/0, hud_state_binding 82/0, hud_layout 40/0,
 satisfaction_meter 282/0 — HUD-003 + HUD-004 coexist cleanly after merge)
```

BLOCKING 核对（逐项）：
- **AC1** PASS — fresh boot: TimeSystem starts paused → PauseButton shows filled-dot
  prefix + outline stylebox override (`is_pause_active()` true), `get_active_speed()==0`,
  0 speed buttons highlighted (`_test_ac1_fresh_boot_paused_no_speed`)
- **AC4** PASS — paused + Space → `resume()` at the LAST-USED speed: fresh rig 1×;
  select 3× while paused → re-pause → Space resumes at 3× not 1×; matching button
  highlighted; exactly one speed active (`_test_ac4_space_resumes_at_last_speed` +
  button-click path)
- **AC5** PASS — 1/2/3 hotkeys change speed immediately; digit while paused unpauses
  in the SAME action (one action not two: `set_speed()` records `_last_speed` then
  `resume()` applies it); exactly-one-active invariant held across a 10-action chain
  (`_test_ac5_*`, `_test_exactly_one_speed_active_invariant`)
- **Core Rule 4** PASS — re-press already-active speed: speed/pause/tick_count all
  unchanged, button text byte-identical (no cue flicker), still unpaused, still
  exactly one active (`_test_core_rule_4_same_speed_noop`)
- **TR-HUD-006** PASS — transport is the ONLY sim mutation: balance/tick_count/
  global_satisfaction unchanged after hotkey chains; only `set_paused`/`set_speed`
  mutation methods exposed, no economy/grid mutation methods (`_test_transport_only_mutation`,
  `_test_read_only_no_mutation`)
- 非 BLOCKING 亦 PASS：hotkey echo/release/other-key hygiene、FOCUS_NONE dual-focus
  结构（4 按钮均 FOCUS_NONE）、active cue 视觉（outline + dot，非纯色）、
  `time_of_day_icon()` 12 小时钟面映射（0/0.25/0.5/0.75/0.999 + 防御 clamp）、
  Day N 随 tick_completed 更新 + TICKS_PER_DAY(1800) 边界回卷、恰好 4 个
  MOUSE_FILTER_STOP 控件（其余全 IGNORE）

## 2. Transport Cluster Structure (verified headless, structural)

```
TimeGroup (top-right)
├── DayLabel            "Day N"
├── TimeOfDayLabel      🕛/🕐/…/🕚 (clock-position icon, not HH:MM text)
└── TransportCluster (HBoxContainer, separation 6)
    ├── PauseButton     "‖" (active while paused: "• ‖" + outline)
    ├── SpeedButton1    "1×" (active at 1×)
    ├── SpeedButton2    "2×" (active at 2×)
    └── SpeedButton3    "3×" (active at 3×)
```

- **Active cue**: filled-dot text prefix (`• `) + charcoal outline stylebox
  override — icon/shape, never color alone (colorblind-safe, GDD Core Rule 4).
- **Exactly one active**: running → exactly one speed button; paused → none,
  pause button active (invariant asserted across a 10-action state chain).
- **Input**: the 4 transport buttons are the ONLY `MOUSE_FILTER_STOP` controls in
  the HUD tree (verified: exactly 4 STOP); everything else stays IGNORE — the
  HUD still never blocks the play area.
- **Hotkey path is keyboard, buttons are mouse**: `FOCUS_NONE` on all four
  buttons means Tab/mouse focus can never route Space into a Button's
  `ui_accept` — `_unhandled_key_input` on the HUD node remains the single
  keyboard transport path (dual-focus 4.6+, ADR-0005 §5).

## 3. Manual Walkthrough Checklist (ADVISORY — needs the playable build)

Headless automated coverage cannot certify the *visual* acceptance criteria;
this checklist is the human sign-off gate once the game scene wires the HUD
(composition root + main scene land in the Playable Build task).

### AC1 — initial paused state

| Step | Expect | Result |
|------|--------|--------|
| Fresh boot, HUD renders | Pause button shows outline + filled-dot; no speed button highlighted | ☐ |
| Compare to TimeSystem state | Matches paused start state | ☐ |

### AC4 — pause resume

| Step | Expect | Result |
|------|--------|--------|
| Game paused; press Space | Sim resumes at last-used speed; that speed button shows outline + dot | ☐ |
| Press Space again | Sim pauses; pause button highlights | ☐ |

### AC5 — hotkey speed change

| Step | Expect | Result |
|------|--------|--------|
| Any state; press 2 | Speed changes immediately (unpauses if paused); exactly one speed button active | ☐ |
| Press 1 and 3 | Each sets the right speed; one active at a time | ☐ |
| While a transport button has mouse focus, press Space | Still toggles pause (hotkeys focus-independent) | ☐ |

### Core Rule 4 — same-speed no-op

| Step | Expect | Result |
|------|--------|--------|
| At 2×; press 2 again | No state change, no flicker; stays 2×, unpaused | ☐ |

### Day/Time — day number & icon

| Step | Expect | Result |
|------|--------|--------|
| Let ticks pass across a TICKS_PER_DAY boundary | Day number increments; clock icon advances with time-of-day | ☐ |
| Check day formula | day = 1 + floor(tick_count / TICKS_PER_DAY) at all points | ☐ |

## 4. Files Changed

| Path | Purpose |
|------|---------|
| `src/ui/hud.gd` | Transport cluster buttons (‖/1×/2×/3×) with outline+dot active cue; `_unhandled_key_input` hotkeys; `set_paused`/`set_speed`/`toggle_pause` forwards; `time_of_day_icon()`; button/active-state getters |
| `tests/unit/hud/transport_test.gd` | Story-004 transport + day/time automated coverage (100 asserts) |
| `tests/unit/hud/hud_state_binding_test.gd` | Updated to Story-004 transport surface (73 asserts) |
| `tests/unit/hud/hud_layout_test.gd` | Updated transport cluster structure + input-scope (40 asserts) |
| `tests/headless_runner.gd` | Registered `transport_test.gd` in `TEST_FILES` |

## 5. Notes / Handoff to Downstream

- **Story 002 (money tween)** / **Story 003 (meter)**: unchanged seams; the
  transport work did not touch money/satisfaction code paths.
- **TICKS_PER_DAY**: provisional 1800 (HUD GDD OQ1); game-designer owns the final
  value — change `config["ticks_per_day"]`, no code edit needed. `time_of_day_icon`
  derives from the same fraction, so the clock face follows automatically.
- **Focus design decision**: transport buttons are `FOCUS_NONE` (documented in
  hud.gd). If a future accessibility pass needs Tab-navigable HUD buttons, the
  Space/1/2/3 hotkeys must be reconciled with Button `ui_accept` consumption
  under dual-focus (e.g. shortcut overrides) — out of scope for this story.
