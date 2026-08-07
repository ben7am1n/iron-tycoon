# Evidence: HUD-002 Money Count Tween

**Story**: `production/epics/hud/story-002-money-count-tween.md`
**Story Type**: Visual/Feel (evidence ADVISORY — manual walkthrough + automated tween-logic)
**Engine**: Godot 4.7.1 (GDScript) | **Date**: 2026-08-06
**Status**: ✅ QA terminal review PASS (2026-08-07, qa-tester) — automated coverage verified; visual walkthrough pending playable build (ADVISORY)

---

## 1. Automated Coverage (verified headless)

`godot --headless --script tests/headless_runner.gd` → **3875 passed / 0 failed**
(Story HUD-002 adds +60 new assertions in `money_tween_test.gd` and updates 6
assertions in `hud_state_binding_test.gd` to the Story-002 contract — the S6
handler no longer snaps the label synchronously, it starts a tween; baseline
was 3809 at main tip; no new ObjectDB/resource leaks — identical 218/12
pre-existing baseline counts).

**Independent QA re-run (2026-08-07, qa-tester @ main tip fb4f235)**:
`godot --headless --script tests/headless_runner.gd` → **4036 passed / 0
failed / exit 0 / 0 SCRIPT ERROR**. `money_tween_test.gd` standalone 60/0
exit 0; `hud_state_binding_test.gd` 71/0; `hud_layout_test.gd` 35/0. Leak
baseline at exit: 218 ObjectDB / 12 resources — identical to the documented
pre-existing baseline, no new leaks.

| File | Assertions | Covers |
|------|-----------|--------|
| `tests/unit/hud/money_tween_test.gd` | 60 | AC2 tween creation on `balance_changed`, deterministic easing math (income + spend directions, monotonic, no overshoot), spend desaturation acknowledgment (never red), rapid-change re-target (old tween killed, exactly one live tween), paused-still-animates (render-time, zero tick advance), reduced-motion snap (no tween, no ack), duration knob (default 0.3s + config clamp 0.2–0.5s), refresh_all load-snap, tween callback rounding/formatting, pure `spend_ack_color()` |
| `tests/unit/hud/hud_state_binding_test.gd` | 71 | Updated S6 contract: `balance_changed` starts a tween (target + displayed + label mid-tween assertions), spend triggers ack, rejected overspend leaves tween state untouched |

### Key automated facts (all passing)

- **AC2 count tween**: `credit(100)` on a $500 balance starts a TRANS_QUAD /
  EASE_OUT tween from the current displayed value toward 600 over 0.3s. Mid-tween
  (headless, no frames ticked) the label still shows `$500` and `get_displayed_balance()`
  returns 500 — the label does NOT snap (Story 001's synchronous set was
  deliberately replaced by Story 002's tween).
- **Easing math (deterministic, via `Tween.interpolate_value()` with the exact
  constants the HUD uses)**: `t=0 → 500`, `t=duration → exactly 600`; monotonic
  non-decreasing for income, non-increasing for spend; never overshoots past
  `[from, to]` at any of 11 sample points. A count that briefly showed MORE
  money than the player has would read as a bug — TRANS_QUAD/EASE_OUT is
  monotonic by construction.
- **Spend NEVER red (Pillar 2 absolute)**: `spend(250)` sets the Butter coin
  icon to `spend_ack_color()` — Butter lerped toward gray by 0.35. Hue is
  preserved (h = 0.128, yellow family; probe-verified on 4.7.1), saturation
  drops (0.498 → 0.389), `r > b` (never red-dominant). The NUMBER label color
  stays charcoal throughout. A settle tween restores full Butter over the
  count duration.
- **Edge (rapid)**: 3 credits fired back-to-back — tween #1 is KILLED
  (`is_valid() == false`) the moment tween #2 starts, #2 killed by #3; exactly
  ONE live tween after the burst; target == 660 (the latest); displayed still
  500 (the count continues from wherever the killed tween had reached — no
  queue backlog, no snap-back).
- **Edge (paused)**: TimeSystem paused → `credit(100)` (a sell refund) →
  count tween created and RUNNING while `is_paused()`, with ZERO tick advance
  (ticks 0 → 0). The tween is bound to the scene tree (render-time), not
  gated by sim ticks — exactly the GDD Edge Case.
- **Reduced-motion**: `config["reduced_motion"] = true` → `credit(100)` snaps
  the label to `$600` immediately, no tween, no desaturation; spend snaps too
  and the coin stays full Butter.
- **Duration knob**: default 0.3s; `0.45` honored; `0.1` clamped UP to 0.2;
  `0.9` clamped DOWN to 0.5 (GDD safe range).
- **Load path**: `refresh_all()` snaps money to the loaded balance and kills
  any in-flight tween (a load is not an animation).

## 2. 4.7.1 API Verification Notes

- `tween_await(signal: Signal) -> Tween` **exists** in 4.7.1 (probe-verified:
  `Tween` method list includes `tween_await(signal: 26)`; `26` = Variant.Signal).
  It is the signal-sequencing API ("tween waits on an external signal
  mid-chain") — NOT applicable to a fire-and-forget value tween like the money
  count. The placement-system GDD review (R10) already made this correction.
  The count uses the verified fallback: `create_tween()` +
  `tween_method()`/`tween_property()` chains.
- `Tween.is_finished()` does **NOT** exist in 4.7.1 (probe error). Use
  `is_valid()` / `is_running()`: a fresh tween reports `is_running() == true`;
  a killed tween reports `is_valid() == false`. All tween-state assertions use
  these.
- `Color.desaturated()` does **NOT** exist in 4.7.1 (probe error). The spend
  acknowledgment uses `COLOR_BUTTER.lerp(Color(0.5,0.5,0.5), 0.35)` — verified
  hue-preserving (h stays 0.128), saturation-reducing.
- `create_tween()` works on any Node in 4.7.1 — probe-verified even for nodes
  never added to a tree. No in-tree guard needed (the `is_inside_tree()`
  guard was probed and rejected: it is false for ALL nodes during `--script`
  `_init()`, which would have forced the snap path in every headless rig).
- Theme-override tween path `theme_override_colors/font_color` verified
  readable + tweenable on a Label (probe).

## 3. Manual Walkthrough Checklist (ADVISORY — needs the playable build)

Headless automated coverage cannot certify the *visual feel*; this checklist
is the human sign-off gate once the game scene wires the HUD.

### AC2 — count animation & no red flash

| Step | Expect | Result |
|------|--------|--------|
| Run the game; watch the money label; trigger `credit` (income) | Digits count up from old → new over ~0.3s, easing out (fast start, soft landing) | ☐ |
| Trigger a spend (buy equipment / sell) | Digits count down; coin icon briefly desaturates then settles back to Butter; NO red flash anywhere | ☐ |
| Compare duration feel | Count feels smooth, not laggy (>0.5s) and not a snap (<0.2s) | ☐ |

### Edge (rapid) — multiple changes one tick

| Step | Expect | Result |
|------|--------|--------|
| Fire several balance changes quickly (e.g. multiple departures one tick) | Display targets the latest value; count continues smoothly from where it was; no backlog queue, no lingering through intermediate values | ☐ |

### Edge (paused) — render-time tween

| Step | Expect | Result |
|------|--------|--------|
| Pause the sim; sell an equipment (refund → `credit`) | Count tween still animates while paused (render-time, independent of sim ticks) | ☐ |

### Reduced-motion

| Step | Expect | Result |
|------|--------|--------|
| Enable reduced-motion (config `reduced_motion: true`, future settings #22); change balance | Number snaps to the final value; no tween; no desaturation | ☐ |

## 4. Files Changed

| Path | Purpose |
|------|---------|
| `src/ui/hud.gd` | Money count tween: `_on_balance_changed` → `_start_money_tween` (kill + re-target, TRANS_QUAD/EASE_OUT, `_apply_money_display` callback), `_acknowledge_spend` (desaturation settle, never red), `_snap_money` (reduced-motion), `refresh_all` load-snap, `spend_ack_color()` pure helper, config knobs `money_count_duration` + `reduced_motion`, Story-002 test surface getters |
| `tests/unit/hud/money_tween_test.gd` | Dedicated Story-002 automated coverage (60 asserts) |
| `tests/unit/hud/hud_state_binding_test.gd` | S6 assertions updated to Story-002 contract (tween instead of synchronous snap; 65 → 71 asserts) |
| `tests/headless_runner.gd` | Registered `money_tween_test.gd` in `TEST_FILES` |
| `production/epics/hud/story-002-money-count-tween.md` | Test Evidence status → Created |

## 5. Notes / Handoff to Downstream Stories

- **Story 003 (meter)**: `_meter.value` (0..100) + `get_satisfaction_label()`
  are the seams; the ~1s ease is a DIFFERENT tween on a DIFFERENT element —
  do not reuse `_money_tween`/`_ack_tween` (they are money-scoped and killed
  by money re-targets). Pattern to copy: data-driven duration knob + clamp,
  reduced-motion snap branch, tween-state test surface.
- **Story 004 (transport + day/time icon)**: unaffected by Story 002 — the
  money tween touches only `_money_label`/`_coin_icon` colors + the money
  handler.
- **Reduced-motion source**: currently a config seam (`config["reduced_motion"]`,
  default false). When the global reduced-motion setting (accessibility #22)
  lands, it writes this key — the HUD already honors it.
- **tween_await()**: verified present in 4.7.1 but deliberately NOT used for
  the money count (signal-sequencing API, not value animation). Future
  UI/feedback sequences (e.g. Story 004 button press chains) MAY use it —
  signature `tween_await(signal: Signal) -> Tween`.
