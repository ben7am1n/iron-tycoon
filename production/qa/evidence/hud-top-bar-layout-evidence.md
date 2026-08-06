# Evidence: HUD-001 Top-bar Layout & Read-only State Binding

**Story**: `production/epics/hud/story-001-top-bar-layout-state-binding.md`
**Story Type**: UI (evidence ADVISORY — manual walkthrough + automated state-binding)
**Engine**: Godot 4.7.1 (GDScript) | **Date**: 2026-08-06
**Status**: Automated coverage ✅ — visual walkthrough pending playable build

---

## 1. Automated Coverage (verified headless)

`godot --headless --script tests/headless_runner.gd` → **3528 passed / 0 failed**
(Story HUD-001 adds +100 assertions over the Sprint-4 baseline of 3428; no
new ObjectDB/resource leaks — identical 218/12 pre-existing baseline counts).

| File | Assertions | Covers |
|------|-----------|--------|
| `tests/unit/hud/hud_state_binding_test.gd` | 65 | GDD Formulas (day/time derivation with provisional TICKS_PER_DAY), AC8 load-state binding, S6 `balance_changed` subscription, S2 tick refresh, pause/speed state binding, config overrides (`ticks_per_day`, `ui_scale`), double-init guard, TR-HUD-006 read-only discipline (no sim mutation, no popup/toast/badge nodes) |
| `tests/unit/hud/hud_layout_test.gd` | 35 | Core Rule 1 (single top bar, F-pattern order money→satisfaction→time, group contents), AC7 (min font ≥ 16px, top-bar ≤ 8% of 1080p, safe margin ≥ 16px), no bottom bar / side panels, input-transparent HUD |

### Key automated facts (all passing)

- **Day derivation**: `day = 1 + floor(tick_count / TICKS_PER_DAY)`; tick 1799 → Day 1, tick 1800 → Day 2, tick 3600 → Day 3 (provisional 1800 = HUD GDD OQ1, data-driven via `config["ticks_per_day"]`, default 1800).
- **Time-of-day**: `time_of_day = (tick_count mod TICKS_PER_DAY) / TICKS_PER_DAY` ∈ [0,1); displayed as HH:MM (`0.5 → "12:00"`); the sun/clock icon itself is Story 004's scope.
- **AC8 load-state**: a HUD initialized against a rig with balance $1,240 / satisfaction 77% / tick_count 3600 / paused renders `$1,240`, `77%`, `Day 3`, `PAUSED`, `—` on the first `refresh_all()` — no stale pre-load values.
- **S6**: `credit(100)` → label `$600`; `spend(250)` → `$350`; rejected overspend leaves the label untouched.
- **S2**: satisfaction % + meter re-read on `tick_completed` (10 Hz); day rolls over exactly at the TICKS_PER_DAY boundary.
- **Read-only (TR-HUD-006)**: HUD exposes no `set_paused()` / `set_speed()` (transport input is Story 004); refresh + signal handling leave `balance`, `tick_count`, `paused`, `global_satisfaction` untouched; tree contains no popup/toast/badge/dialog nodes; HUD root has exactly one child (TopBar).

## 2. Layout Structure (verified headless, structural)

```
Hud (Control, full-rect, mouse_filter=IGNORE — never blocks the play area)
└── TopBar (HBoxContainer, anchored top, full width, 48px + 16px safe margins)
    ├── MoneyGroup          — 🪙 Butter coin icon + value label        (F-pattern first)
    ├── LeftSpacer          — expand-fill, pushes time group right
    ├── SatisfactionGroup   — face icon + quiet ProgressBar meter + % label
    ├── RightSpacer         — expand-fill
    └── TimeGroup           — DayLabel + TimeOfDayLabel + TransportCluster
                              (TransportCluster: PauseStateLabel + SpeedStateLabel)
```

- **No bottom bar, no side panels**: HUD root has exactly ONE child (TopBar); TopBar has exactly 5 children (3 groups + 2 spacers).
- **AC7 constants**: min font size 16px @1080p at 1.0× UI scale (all 8 labels ≥ 16px verified); top bar strip 48px + 16px safe margin = 64px ≤ 86.4px (8% of 1080p); safe margin ≥ 16px from both screen edges.
- **UI scale**: config `ui_scale` re-lays-out deterministically (verified at 1.5×: margin 24, bar height 72, font 24).

## 3. Manual Walkthrough Checklist (ADVISORY — needs the playable build)

Headless automated coverage cannot certify the *visual* acceptance criteria;
this checklist is the human sign-off gate once the game scene wires the HUD
(composition root + main scene land in the Playable Build task).

### AC7 — resolution & readability

| Step | Expect | Result |
|------|--------|--------|
| Run at 1280×720, 1920×1080, 2560×1440 with UI scale 1.5× | Top bar within safe margins; text ≥ 16px @1080p | ☐ |
| Verify no HUD element overlaps the play area | All three resolutions render the top bar clear of the gym floor | ☐ |

### AC8 — load renders immediately

| Step | Expect | Result |
|------|--------|--------|
| Save a game with known money/satisfaction/day; load it | First frame shows paused state + loaded values | ☐ |
| Compare HUD to the save | No stale pre-load values; pause reflected; values match | ☐ |

### Core Rule 1 — layout (fresh boot)

| Step | Expect | Result |
|------|--------|--------|
| Fresh boot, HUD first renders | Money (Butter, coin icon) top-left | ☐ |
| — | Satisfaction top-center (face + quiet meter + %) | ☐ |
| — | Day/time + transport cluster top-right (pause + speed state) | ☐ |
| — | Nothing else: no bottom bar, no side panels, no popups/toasts/badges | ☐ |

## 4. Files Changed

| Path | Purpose |
|------|---------|
| `src/ui/hud.gd` | The HUD Control hierarchy (code-built, no .tscn): layout + read-only state binding |
| `tests/unit/hud/hud_state_binding_test.gd` | State-binding automated coverage (65 asserts) |
| `tests/unit/hud/hud_layout_test.gd` | Layout automated coverage (35 asserts) |
| `tests/headless_runner.gd` | Registered both new test files in `TEST_FILES` |

## 5. Notes / Handoff to Downstream Stories

- **Story 002 (money tween)**: `_on_balance_changed(new_balance, delta)` is the exact hook; `format_money()` is stable and testable.
- **Story 003 (meter)**: `_meter.value` (0..100) + `get_satisfaction_label()` are the seams; ramp/ease/icon-shape replace the current static fill.
- **Story 004 (transport + day/time icon)**: `PauseStateLabel`/`SpeedStateLabel` become buttons; `format_time_of_day()` → sun/clock icon; hotkeys arrive via `_unhandled_key_input` on this node.
- **TICKS_PER_DAY**: provisional 1800 (HUD GDD OQ1); game-designer owns the final value — change `config["ticks_per_day"]`, no code edit needed.
