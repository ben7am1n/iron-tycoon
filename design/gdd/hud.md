# HUD (money / satisfaction / time)

> **Status**: ✅ Approved（2026-07-20 design-review：无内部设计缺陷，两个 OQ 为跨系统缺口已正确记录）
> **Author**: user + agents
> **Last Updated**: 2026-07-20
> **Implements Pillar**: Pillar 3 (一眼看懂 — the always-on, glanceable state) · Pillar 2 (松弛不紧绷 — a calm dashboard, never an alarm board)
> **Creative Director Review (CD-GDD-ALIGN)**: Skipped — Lean review mode (not a PHASE-GATE at lean).

## Overview

The HUD is the always-on heads-up display: a minimal top-bar showing the three numbers the player steers by — **money**, **satisfaction** (reputation), and **time/day** — plus the **pause/speed** transport controls. It is read-only information plus transport: it owns no game state, only *displays* what Economy, Satisfaction, and TimeSystem expose and *forwards* pause/speed input back to TimeSystem. Its defining constraint is Pillar 2/3: it must stay **sparse and calm** — no popups, no badges, no red alarms, nothing that competes with the play area — because a legible-at-a-glance game is a *sparse* one, not a densely-organized one. It is the quiet frame around the gym, not a cockpit.

## Player Fantasy

The HUD is the calm dashboard of a business you enjoy running — a glance tells you you're doing fine: money ticking up, reputation warm and climbing, the day rolling gently by. It never nags, never flashes, never demands. It serves Pillar 3 by making the whole game-state readable in one look, and Pillar 2 by being *incapable* of stressing you — even a struggling gym reads as "room to grow," shown in soft warm tones, never a red danger light. The feeling to protect: the unhurried confidence of a player in control, who can look up, take stock in a second, and look back down to keep tinkering.

## Detailed Design

### Core Rules

1. **Layout — minimal top bar, corners.**
   - **Top-left**: money (Butter, coin icon) — the highest-frequency value, in the first reading position (F-pattern).
   - **Top-center (or just right of money)**: the satisfaction meter — small and quiet, not competing with money.
   - **Top-right**: day/time display + the pause/speed control cluster, grouped (related info + actions together).
   No bottom bar, no persistent side panels — nothing else lives on the HUD (Pillar 3 = sparse).

2. **Satisfaction meter — calm, slow, never an alarm.** A short horizontal/arc meter (never a "health bar" metaphor — that reads as danger). Fill ramps **Sage (high) → warm neutral (mid) → soft muted Dusty Rose only at the very low end** — never a saturated red, never a pulse or alarm animation *regardless of value* (Pillar 2 is absolute here). Always paired with a numeric % **and** a small face/heart icon whose *shape* changes (filled vs outline) so colorblind players read state without color. Because `global_satisfaction` is a slow EMA, the meter eases to new values over ~1 s — reinforcing "this moves slowly, don't panic."

3. **Money — a gentle count.** A static Butter coin icon + number. On `balance_changed`, the digits **tween** (count up/down over ~0.3 s) rather than snapping. Never a red flash on spend — a brief desaturation-then-settle is acknowledgment enough (Pillar 2).

4. **Time/day + pause/speed.** Shows the current **day number** + a sun/clock-position icon for time-of-day (icon, not color-only). The speed cluster is four small buttons — **‖ (pause), 1×, 2×, 3×** — the active one marked with outline + a filled-dot icon (not color alone). Hotkeys: **Space = toggle pause**; **1 / 2 / 3 = set speed directly** (and implicitly unpause — pressing 2 while paused resumes at 2×, one action not two). On load, TimeSystem starts **paused**, so the HUD renders the paused state immediately (no stale UI).

5. **Read-only + transport only — no event feedback here.** No popups, toasts, or badges layer onto the HUD. Event feedback (a member leaving unhappy, a milestone) belongs to those systems' own in-world micro-feedback, **not** the HUD. The HUD is state display + transport controls, nothing more — this is what keeps it calm.

### States and Transitions

The HUD has no simulation state; it reflects upstream state and forwards transport input:

| From | Event | To | Notes |
|---|---|---|---|
| — | `balance_changed(new, delta)` | money tweens to `new` | ~0.3 s count, Butter throughout |
| — | `global_satisfaction` changes | meter eases to new fill | ~1 s ease; icon + % update |
| — | tick advances | day/time display updates | from `tick_count` |
| — | Space pressed | TimeSystem toggles pause | button reflects new state |
| — | 1/2/3 pressed / speed button clicked | TimeSystem sets speed (unpausing) | one speed button active |
| — | game loaded | renders paused, current values | TimeSystem resumes paused |

### Interactions with Other Systems

- **Upstream dependencies (hard, read/forward only)**:
  - **Economy (#11)**: subscribes to `balance_changed(new, delta)`; displays money.
  - **Satisfaction (#10)**: reads `global_satisfaction ∈ [0,1]`; displays the reputation meter.
  - **TimeSystem (#3)**: reads `tick_count` (→ day/time) and pause/speed state; forwards pause/speed input (Space, 1/2/3) back to TimeSystem.
- The HUD initiates no simulation changes except pause/speed (a pure forward to TimeSystem).

## Formulas

The **time_display** derivation is defined as:

`day = 1 + floor(tick_count / TICKS_PER_DAY)` ; `time_of_day = (tick_count mod TICKS_PER_DAY) / TICKS_PER_DAY`

**Variables:**
| Variable | Symbol | Type | Range | Description |
|----------|--------|------|-------|-------------|
| Elapsed ticks | `tick_count` | int | `[0, ∞)` | from TimeSystem |
| Ticks per in-game day | `TICKS_PER_DAY` | int | provisional; **needs TimeSystem/game-designer to define** (see OQ) | day length |
| Day number | `day` | int | `[1, ∞)` | displayed day |
| Time of day | `time_of_day` | float | `[0,1)` | fraction → sun/clock icon position |

**Output Range:** `day ≥ 1`, `time_of_day ∈ [0,1)`. `TICKS_PER_DAY` is **not yet defined** — provisional example: a "day" of ~3 real minutes at 10 ticks/s, 1× → `TICKS_PER_DAY ≈ 1800`. Flagged as an Open Question (a design decision TimeSystem/game-designer owns). Other than this display mapping, the HUD performs no calculations — money and satisfaction are shown as-is.

## Edge Cases

- **Money changes while paused**: still animates the count (income can't accrue while paused since ticks don't advance, but a sell refund during pause can change balance) — the count tween runs on render time, independent of sim ticks.
- **Satisfaction at rock bottom**: the meter shows a low, muted warm tone — **never** red, never flashing (Pillar 2 absolute). Still paired with % + icon.
- **On load**: HUD renders the paused state and the loaded money/satisfaction/day immediately — no stale pre-load values.
- **Rapid balance changes** (multiple departures one tick): the money tween targets the latest value (re-targets mid-tween, no queue backlog).
- **Speed pressed while already at that speed**: no-op (stays at that speed, unpaused).

## Dependencies

**Upstream dependencies (hard, read/forward)**:

| System | Interface | Nature |
|---|---|---|
| Economy (#11) | subscribe `balance_changed(new, delta)` | Hard |
| Satisfaction (#10) | read `global_satisfaction` | Hard |
| TimeSystem (#3) | read `tick_count`, pause/speed state; forward pause/speed input | Hard |

**Bidirectional consistency notes**: Economy lists HUD as a `balance_changed` subscriber; Satisfaction lists HUD as the reputation-meter display; TimeSystem's pause/speed UI (its OQ5) is fulfilled here. The `TICKS_PER_DAY` mapping needs a TimeSystem/game-designer decision (below). Verify at `/consistency-check`.

## Tuning Knobs

| Knob | Default | Safe Range | Notes |
|---|---|---|---|
| money count-up duration | 0.3 s | 0.2–0.5 s | too long feels laggy; too short = snap |
| satisfaction ease duration | 1.0 s | 0.5–1.5 s | reinforces "slow meter"; too fast reintroduces twitch |
| `TICKS_PER_DAY` | TBD (TimeSystem-owned) | — | see Open Questions |

## Visual/Audio Requirements

Fully specified in Core Rules: Butter money, the calm Sage→neutral→muted-rose satisfaction meter (never red/flashing, icon+% always), the count-up money tween, the icon-marked speed cluster, day + sun/clock icon. Art-bible palette throughout; colorblind-safe (icon/shape + number, never color alone); scales with the UI-scale setting; text ≥ the art bible's minimum readable size at 1080p. Audio: soft, optional cues (a gentle coin tick on income, a soft click on pause/speed) are nice-to-haves for audio-director — never an anxious cash-register or alarm (Pillar 2).

## UI Requirements

The HUD **is** the UI — this whole GDD is its spec. It contributes the top-bar money/satisfaction/time display and the pause/speed transport controls. A separate pause **menu** (settings, save/load access) is a distinct shell, not part of the HUD — flagged (SaveLoad also notes the menu dependency). Detailed visual layout may be formalized in `design/ux/hud.md` via `/ux-design` in Pre-Production.

## Acceptance Criteria

> HUD is a **UI/Visual** story — evidence primarily **ADVISORY** (manual walkthrough). GIVEN-WHEN-THEN:

1. **GIVEN** game start, **WHEN** the HUD first renders, **THEN** Pause is shown active and no speed button is highlighted.
2. **GIVEN** Economy emits `balance_changed`, **WHEN** the value changes, **THEN** the money number animates old→new within ~0.3 s in Butter throughout (no red/error flash on decrease).
3. **GIVEN** `global_satisfaction` changes, **WHEN** the HUD reads it, **THEN** the meter eases to the new fill over ~1 s, icon shape + numeric % both update, and no color ever reads as red/alarm.
4. **GIVEN** the game is paused, **WHEN** the player presses Space, **THEN** the sim resumes at the last-used speed and the corresponding speed button highlights.
5. **GIVEN** any state, **WHEN** the player presses 1/2/3, **THEN** speed changes immediately (unpausing if needed) and exactly one speed button shows the active cue.
6. **GIVEN** a colorblind-simulation pass, **WHEN** viewing the HUD, **THEN** money, satisfaction, and speed states are each distinguishable via icon/shape/number alone.
7. **GIVEN** any supported resolution, **WHEN** the HUD renders, **THEN** text stays readable at minimum font size and no element overlaps the play area.
8. **GIVEN** a loaded game, **WHEN** the HUD renders, **THEN** it shows the paused state and the loaded money/satisfaction/day immediately (no stale values).

## Open Questions

| # | Question | Owner | Target Resolution |
|---|---|---|---|
| OQ1 | **`TICKS_PER_DAY`** — how long is an in-game "day" in ticks? Needed for the day/time display. A design decision TimeSystem/game-designer owns; provisional ~1800 (≈3 real min at 1×). | TimeSystem / game-designer | At the fun-validation playtest (pace of day matters to feel) |
| OQ2 | The **pause menu** shell (settings + save/load access) is separate from the HUD and not in the MVP systems index — add it as a small UI task (shared with SaveLoad's menu note). | producer / ux-designer | Before a shippable build |
| OQ3 | Event micro-feedback (member left unhappy, milestone reached) is deliberately **not** on the HUD — confirm each such event has an in-world feedback home when those systems (Milestones #18, etc.) are designed. | those systems' owners | When each is designed |