# Evidence: HUD-003 Satisfaction Meter

**Story**: `production/epics/hud/story-003-satisfaction-meter.md`
**Story Type**: Visual/Feel (evidence ADVISORY — manual walkthrough + automated fill/ease mapping)
**Engine**: Godot 4.7.1 (GDScript) | **Date**: 2026-08-06
**Status**: Automated coverage ✅ — visual walkthrough pending playable build

---

## 0. QA Independent Verification (2026-08-07, t_5026b6d9)

Independent re-run by the QA gate on the **integrated** tree (implementation
branch `wt/t_5750594f` merged onto current main tip `5749e4d`, QA worktree
commit `48cdc88`):

| Check | Result |
|-------|--------|
| `tests/unit/hud/satisfaction_meter_test.gd` standalone | **282 passed / 0 failed**, exit 0 |
| `tests/unit/hud/money_tween_test.gd` standalone | **60 passed / 0 failed**, exit 0 |
| `tests/unit/hud/hud_state_binding_test.gd` standalone | **74 passed / 0 failed**, exit 0 |
| Full headless suite `tests/headless_runner.gd` | **4246 passed / 0 failed**, RESULT: PASSED, **0 SCRIPT ERROR** |
| Baseline (main tip `5749e4d`, pre-merge) | 3961 passed / 0 failed → delta **+285 exactly** (282 meter + 3 state-binding contract), zero regressions |
| Leak picture | 218 ObjectDB / 12 resources — identical to baseline, no new leaks |

**Integration caveat**: the implementation branch was forked from `b8c7d3e`,
which predates HUD-002 (money count tween, `1232247`) and BSUI-002 (purchase
gate, `63d0ea9`). As delivered, the branch's `hud.gd` had NO money tween and
its runner registration replaced `money_tween_test.gd` + dropped
`purchase_gate_test.gd`; the "4094/0 at tip" figure was measured on that
stale fork (3809 base + 285), never against current main. The QA merge
resolved this by keeping BOTH feature sets (money tween + satisfaction meter;
all four hud tests + purchase gate registered). The integrated state above is
the correct merge target — do NOT merge the raw parent branch as-is.

### Re-delivery verification (2026-08-07, t_f400b3c7)

The implementation card was re-run on the current main tip `fb4f235` (which
additionally includes SEL-001, +75 asserts over `5749e4d`). The QA-verified
integrated state (merge `48cdc88` content) was re-applied cleanly — `hud.gd`
was byte-identical at both bases, only the runner registration needed manual
merge (SEL-001's `selection_logic_test.gd` entry kept). Independent re-run on
`wt/t_f400b3c7`:

| Check | Result |
|-------|--------|
| `tests/unit/hud/satisfaction_meter_test.gd` standalone | **282 passed / 0 failed**, exit 0 |
| `tests/unit/hud/hud_state_binding_test.gd` standalone | **74 passed / 0 failed**, exit 0 |
| `tests/unit/hud/money_tween_test.gd` standalone | **60 passed / 0 failed**, exit 0 |
| `tests/unit/hud/hud_layout_test.gd` standalone | **35 passed / 0 failed**, exit 0 |
| Full headless suite `tests/headless_runner.gd` | **4321 passed / 0 failed**, RESULT: PASSED |
| Baseline (main tip `fb4f235`, pre-change) | 4036 passed / 0 failed → delta **+285 exactly** (282 meter + 3 state-binding contract), zero regressions |
| Leak picture | 218 ObjectDB / 12 resources — identical to baseline, no new leaks |

### Independent QA re-run (2026-08-07, t_d4771a34 — terminal review)

QA worktree `wt/t_d4771a34` = current main tip `6a87202` + merge of the
re-delivered implementation (`wt/t_f400b3c7` @ `df5a371`); merge was clean
(no overlapping files between the two sides). Re-run by the QA gate:

| Check | Result |
|-------|--------|
| `tests/unit/hud/satisfaction_meter_test.gd` standalone | **282 passed / 0 failed**, exit 0 |
| Full headless suite `tests/headless_runner.gd` | **4321 passed / 0 failed**, RESULT: PASSED, exit 0, **0 SCRIPT ERROR** |
| `tests/unit/hud/hud_state_binding_test.gd` | **74 passed / 0 failed** (in suite) |
| `tests/unit/hud/hud_layout_test.gd` | **35 passed / 0 failed** (in suite — HUD-001 unaffected) |
| `tests/unit/hud/money_tween_test.gd` | **60 passed / 0 failed** (in suite — HUD-002 unaffected) |
| Leak picture | 218 ObjectDB / 12 resources — identical to established baseline, no new leaks |
| Unregistered-test scan | none (runner self-check clean) |

Verdict: **PASS** — all BLOCKING 验收 items (AC3 / AC6 / Core Rule 2) verified.
Story 003 marked Complete with QA 终审 PASS + QA 回填 evidence.

---

## 1. Automated Coverage (verified headless)

`godot --headless --script tests/headless_runner.gd` → **4321 passed / 0 failed**
(Story HUD-003 adds +285 assertions over the current main tip of 4036
(= 3961 at `5749e4d` + 75 SEL-001): +282 in the new meter test, +3 updated
in the state-binding test for the animated contract).

| File | Assertions | Covers |
|------|-----------|--------|
| `tests/unit/hud/satisfaction_meter_test.gd` | 282 | TR-HUD-002 fill ramp (anchors, zone boundaries, continuity, never-alarm sweep, determinism), TR-HUD-003 icon glyph + shape pairing (filled/outline), AC3 ease (tween created on change, lockstep display, 10 Hz no-op, re-target mid-tween), Core Rule 2 rock bottom (muted Dusty Rose, no pulse — loops_left == 1), reduced-motion static fill (config + live setter), `satisfaction_ease_duration` knob (0.5–1.5 s clamp) |
| `tests/unit/hud/hud_state_binding_test.gd` | 74 (was 71) | `_test_satisfaction_read_on_tick` updated to the Story-003 animated contract (tween target + `apply_satisfaction_display` lockstep) |

### Key automated facts (all passing)

- **Fill ramp (TR-HUD-002)**: `satisfaction_fill_color(sat)` is a pure static
  piecewise-linear ramp — `sat >= 0.66` → Sage `#8FBF9F`; `0.33..0.66` → warm
  neutral (`#C9A87C` warm sand) lerping toward Sage; `< 0.33` → Dusty Rose
  `#E0A0A0` lerping toward warm neutral. Entire ramp is muted: worst saturation
  across 101 samples = 0.383 (< 0.4), `r < 0.95` at every fill — **never
  saturated red, never an alarm** (Pillar 2 absolute). Continuous (max per-
  channel delta between adjacent samples ≤ 0.05) and deterministic.
- **Colorblind-safe pairing (TR-HUD-003)**: % label always present; icon
  glyph `☺` (high) / `🙂` (mid) / `☹` (very low) AND icon SHAPE state
  `filled` (sat ≥ 0.33) / `outline` (sat < 0.33). Verified across 101 samples
  that the shape flips exactly where the color ramp enters the rose zone —
  state is never carried by color alone.
- **AC3 ease**: on `global_satisfaction` change (live tick path) the meter
  creates ONE tween toward the new fill over the configured duration
  (default 1.0 s; `config["satisfaction_ease_duration"]`, clamped to the GDD
  safe range 0.5–1.5 s). `_apply_satisfaction_display(v)` is the single choke
  point — meter fill, % label, icon glyph and fill color all derive from the
  same value, so the icon + % update WITH the fill. Re-target mid-tween kills
  the old tween and starts from the CURRENT displayed value (no queue
  backlog); a tick re-reading the same target is a no-op (10 Hz cadence).
- **Load path (AC8 preservation)**: `refresh_all()` / `init()` SNAPS the meter
  to the loaded value (no ease, no stale pre-load values). Only live tick
  changes ease.
- **Core Rule 2 (rock bottom)**: `sat = 0` renders Dusty Rose (muted warm,
  saturation 0.286), `☹` outline icon, `0%` label — and the meter tween plays
  exactly once (`loops_left == 1`, no repeating pulse/animation).
- **Reduced-motion**: `config["reduced_motion"] = true` (or the OS preference
  via `DisplayServer.accessibility_should_reduce_animation()` — verified the
  4.7.1 API surface, headless returns "no pref" → false) gives a STATIC fill:
  meter + % + icon snap, no tween. Live `set_reduced_motion()` flips it at
  runtime.

## 2. Meter Structure (verified headless, structural)

```
SatisfactionGroup (HBoxContainer)
├── FaceIcon (Label)         — ☺ / 🙂 / ☹  (glyph + filled/outline shape carry state)
├── Meter (ProgressBar)      — 0..100, show_percentage=false, 80×8px, rounded
│     └── fill stylebox      — StyleBoxFlat, bg_color = satisfaction_fill_color(displayed)
└── SatisfactionLabel (Label) — "66%" etc. (always present — colorblind-safe channel)
```

- The meter remains a **short horizontal ProgressBar** (8px tall, rounded
  2px-corner fill) — NOT a "health bar" metaphor; calm colors, no pulse.
- The fill stylebox is the ramp carrier: recolored every display step, so the
  fill itself transitions Sage → warm neutral → Dusty Rose with the value.
- No new nodes were added to the HUD tree (root still has exactly one child,
  TopBar) — layout tests from Story 001 remain green.

## 3. Manual Walkthrough Checklist (ADVISORY — needs the playable build)

Headless automated coverage cannot certify the *visual* acceptance criteria;
this checklist is the human sign-off gate once the game scene wires the HUD
(composition root + main scene land in the Playable Build task).

### AC3 — ease & update

| Step | Expect | Result |
|------|--------|--------|
| Game running; satisfaction moves 0.8 → 0.5 | Meter eases to the new fill over ~1 s (not a snap) | ☐ |
| During the ease | % number and icon count/change WITH the fill (lockstep), no drift | ☐ |
| After settling | % matches value; icon shape reflects state | ☐ |
| At every fill | No color reads as red/alarm (muted Sage → warm neutral → Dusty Rose) | ☐ |

### AC6 — colorblind simulation

| Step | Expect | Result |
|------|--------|--------|
| Desaturate the screen (colorblind simulation pass) | Satisfaction state still readable | ☐ |
| — | % label alone carries the exact value | ☐ |
| — | Icon shape (filled vs outline) marks high/mid vs very-low without color | ☐ |

### Core Rule 2 — rock bottom

| Step | Expect | Result |
|------|--------|--------|
| Force satisfaction to its lowest value | Meter shows low muted warm tone (soft Dusty Rose), NOT saturated red | ☐ |
| — | No flashing / pulse / alarm animation — a static calm fill (or the 1 s ease into it) | ☐ |
| — | Still paired with % + icon (☹ outline + 0%) | ☐ |

### Reduced-motion

| Step | Expect | Result |
|------|--------|--------|
| Enable reduced motion (config or OS) | Satisfaction changes snap — no ease animation | ☐ |
| Disable it again | ~1 s ease returns | ☐ |

## 4. Files Changed

| Path | Purpose |
|------|---------|
| `src/ui/hud.gd` | Story-003 meter: ramp + icon-shape pure functions, `_apply_satisfaction_display` lockstep choke point, `_refresh_satisfaction` tween path, `_snap_satisfaction` load path, reduced-motion detection, `satisfaction_ease_duration` config, meter fill stylebox, test-seam getters |
| `tests/unit/hud/satisfaction_meter_test.gd` | Automated coverage (282 asserts) — new |
| `tests/unit/hud/hud_state_binding_test.gd` | `_test_satisfaction_read_on_tick` updated to the animated contract (+3 asserts) |
| `tests/headless_runner.gd` | Registered `satisfaction_meter_test.gd` in `TEST_FILES` |

## 5. Notes / Handoff to Downstream Stories

- **Story 002 (money tween)**: `_on_balance_changed(new_balance, delta)` is the
  exact hook; the re-target-mid-tween pattern proven here (kill + new tween
  from current value, 10 Hz no-op) is the same posture the money tween needs.
- **Story 004 (transport + day/time icon)**: unchanged seams
  (`PauseStateLabel`/`SpeedStateLabel` → buttons; `format_time_of_day()` → icon).
- **Ramp anchors** are named constants (`COLOR_SAGE`, `COLOR_WARM_NEUTRAL`,
  `COLOR_DUSTY_ROSE`) + zone thresholds (`SAT_HIGH_ZONE` 0.66, `SAT_MID_ZONE`
  0.33) — tune without code archaeology.
- **4.7.1 engine notes captured**: `DisplayServer.accessibility_should_reduce_animation()`
  is the reduced-motion API (headless returns -1/"unknown"); `Tween` has NO
  `loops` property and NO `get_total_duration()` — use `set_loops()` /
  `get_loops_left()` and track duration on the HUD; `custom_step()` does not
  advance a scene-tree-bound running tween (headless tests drive the display
  callback via the `apply_satisfaction_display` seam instead).
