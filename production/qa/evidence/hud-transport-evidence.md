# Evidence: HUD-004 Pause/Speed Transport + Day/Time Display

**Story**: `production/epics/hud/story-004-pause-speed-transport-day-time.md`
**Story Type**: UI (evidence ADVISORY — manual walkthrough + automated hotkey/state logic)
**Engine**: Godot 4.7.1 (GDScript) | **Date**: 2026-08-06
**Status**: Automated coverage ✅ — visual walkthrough pending playable build

---

## 1. Automated Coverage (verified headless)

`godot --headless --script tests/headless_runner.gd` → **4149 passed / 0 failed**
(Story HUD-004 adds +113 assertions over the main-tip baseline of 4036; no new
ObjectDB/resource leaks — identical 218/12 pre-existing baseline counts).

| File | Assertions | Covers |
|------|-----------|--------|
| `tests/unit/hud/transport_test.gd` | 100 (new) | AC1 fresh-boot paused/no-speed, AC4 Space → resume at last-used speed, AC5 1/2/3 immediate speed + implicit unpause, Core Rule 4 same-speed no-op, hotkey→TimeSystem forwarding via `_unhandled_key_input` (echo/release/other-key hygiene), button-click forwarding, dual-focus FOCUS_NONE buttons, exactly-one-active invariant, active-cue visual (outline + filled-dot, never color alone), `time_of_day_icon()` derivation, day/time label updates + rollover on tick_completed, TR-HUD-006 transport-only mutation |
| `tests/unit/hud/hud_state_binding_test.gd` | 73 (was 65) | Updated to the Story-004 transport surface: pause/speed state binding via `get_pause_button()`/`get_speed_button()`/`is_pause_active()`/`get_active_speed()`; read-only discipline now asserts transport is the ONLY allowed mutation (`set_paused`/`set_speed` exist, no economy/grid mutation methods) |
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
