# Story 003: Satisfaction Meter

> **Epic**: hud
> **Status**: Complete — 2026-08-06 (automated coverage ✅; visual walkthrough pending playable build, ADVISORY by design)
> **Layer**: Presentation
> **Type**: Visual/Feel
> **Estimate**: S — 1 session (≤2h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-06

## Context

**GDD**: `design/gdd/hud.md`
**Requirement**: `TR-HUD-002`, `TR-HUD-003`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0005 (Signal Bus & Event Routing)
**ADR Decision Summary**: The HUD reads `Satisfaction.global_satisfaction` (a plain var, `[0,1]`, slow EMA) and displays a calm meter. Read-only — no event feedback on the HUD.

**Engine**: Godot 4.7.1 | **Risk**: MEDIUM
**Engine Notes**: Meter can be a `ColorRect`/`TextureProgressBar` + Labels; tween via `create_tween()` (verified) or `tween_await()` (4.7 NEW — verify signature first). No shader needed for a simple fill ramp.

**Control Manifest Rules (Presentation layer)**:
- Required: `tween_await()` for UI/feedback sequencing (verify first); typed signal connections only
- Forbidden: string-based signal connections

---

## Acceptance Criteria

*From GDD `design/gdd/hud.md`, scoped to this story:*

- [x] AC3 GIVEN `global_satisfaction` changes, WHEN the HUD reads it, THEN the meter eases to the new fill over ~1 s, icon shape + numeric % both update, and no color ever reads as red/alarm
- [x] AC6 GIVEN a colorblind-simulation pass, WHEN viewing the HUD, THEN money, satisfaction, and speed states are each distinguishable via icon/shape/number alone
- [x] Core Rule 2 GIVEN satisfaction at rock bottom, WHEN the meter renders, THEN it shows a low muted warm tone — never red, never flashing (Pillar 2 absolute), still paired with % + icon

---

## Implementation Notes

*Derived from ADR-0005 + GDD Core Rule 2:*

**Calm meter, never an alarm (TR-HUD-002):**
- Short horizontal/arc meter (NEVER a "health bar" metaphor — that reads as danger)
- Fill ramps: Sage (high) → warm neutral (mid) → soft muted Dusty Rose only at the very low end — never saturated red, never a pulse/alarm animation regardless of value (Pillar 2 absolute)
- Eases to new fill over ~1 s (knob 0.5–1.5 s) — reinforces "this moves slowly, don't panic"
- Reduced-motion: static fill (no ease)

**Colorblind-safe pairing (TR-HUD-003):**
- Always paired with numeric % AND a small face/heart icon whose SHAPE changes (filled vs outline) — state readable without color
- Icon + % update with the meter fill

**Data source**: `Satisfaction.global_satisfaction` (var, `[0,1]`, slow EMA). Read on change (Satisfaction updates it during its tick; the HUD reads on `_process` or a change hook — must stay calm, no alarm thresholds).

**4.7.1 pitfalls**:
- `class_name` follows `extends` immediately; headless cross-script refs via `preload` aliases
- If `global_satisfaction` read returns Variant, use explicit `: float` type

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 001]: top-bar layout + satisfaction % Label initial binding
- [Story 002]: money tween (different element, different tween)
- [Story 004]: transport buttons, day/time display

---

## QA Test Cases

*Derived from GDD acceptance criteria. Visual/Feel story — manual verification plus automated fill-mapping where practical.*

- **AC3**: 缓动与更新 — ✅ Automated (282 asserts in `tests/unit/hud/satisfaction_meter_test.gd`): ease tween created on change with target + default 1.0 s duration; lockstep display (meter/%/icon/fill color from one value); 10 Hz no-op; re-target mid-tween; fill ramp never saturated red. Visual ~1 s ease walkthrough pending playable build (ADVISORY).
- **AC6**: 色盲模拟 — ✅ Automated: % label always present; icon shape (filled vs outline) flips exactly where the ramp enters the rose zone; three zones have distinct (glyph, shape) pairs. Desaturation pass pending playable build (ADVISORY).
- **Core Rule 2 (rock bottom)**: 谷底不报警 — ✅ Automated: `sat=0` renders Dusty Rose (saturation 0.286 < 0.4), ☹ outline icon, 0% label, no repeating tween (loops_left == 1). Visual calm-tone walkthrough pending playable build (ADVISORY).

---

## Test Evidence

**Story Type**: Visual/Feel
**Required evidence**:
- `production/qa/evidence/hud-satisfaction-meter-evidence.md` — manual walkthrough / sign-off
- Automated coverage of the fill/ease mapping where practical (e.g. `tests/unit/hud/satisfaction_meter_test.gd`)

**Status**: [x] Complete — 2026-08-06

`src/ui/hud.gd` now renders the calm satisfaction meter (Story 003): a short
horizontal rounded-fill ProgressBar (NOT a health-bar metaphor) whose fill
ramps Sage (high) → warm neutral (mid) → soft muted Dusty Rose (very low end,
never saturated red), driven by pure static `satisfaction_fill_color(sat)`.
The colorblind-safe pairing is complete: the % label always shows the value
and the face icon SHAPE carries state (`satisfaction_icon` → ☺/🙂/☹,
`satisfaction_icon_shape` → "filled"/"outline"). On a live `global_satisfaction`
change the meter eases over ~1 s (GDD knob `satisfaction_ease_duration`,
0.5–1.5 s safe range) with the % + icon + fill color updating in lockstep via
the single `_apply_satisfaction_display(value)` choke point; re-targets
mid-tween without queue backlog; the 10 Hz tick no-ops on an unchanged target;
the load path (refresh_all/init) SNAPS so loaded values render immediately
(AC8 preserved). Reduced-motion (`config["reduced_motion"]` or the OS
preference) gives a static fill — no tween. Automated coverage:
`tests/unit/hud/satisfaction_meter_test.gd` (282 assertions — fill mapping,
icon shape state, ease behavior, reduced-motion, config knob), registered in
`tests/headless_runner.gd` TEST_FILES; `hud_state_binding_test.gd`
`_test_satisfaction_read_on_tick` updated to the animated contract (+3).
Full headless suite: 4321 passed / 0 failed (baseline 4036 + 285 new), no
new leaks. Visual walkthrough checklist (AC3/AC6/Core Rule 2/reduced-motion)
is documented in the evidence file, pending the playable build for sign-off.

---

## Dependencies

- Depends on: Story 001 (top-bar layout + satisfaction % Label binding) — complete (merge c918b16)
- Unlocks: None directly (parallel branch with Story 002/004)
