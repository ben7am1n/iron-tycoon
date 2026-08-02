# HUD Design — 撸铁大亨 (Iron Tycoon)

> **Status**: ✅ Approved (2026-08-02 — ux-design gate, gate-check item #4)
> **Author**: user + ux-designer
> **Last Updated**: 2026-08-02
> **Template**: HUD Design
> **Source GDD**: `design/gdd/hud.md` (#16, ✅ Approved) — this spec is the visual/interaction formalization of that GDD; the GDD remains normative for rules.
> **Implements Pillar**: Pillar 3 (一眼看懂 — the always-on, glanceable state) · Pillar 2 (松弛不紧绷 — a calm dashboard, never an alarm board)
> **Input & Platform**: Keyboard/Mouse primary; Gamepad partial. PC desktop (macOS primary, Windows secondary). UI-scale 0.8×–1.5× integer multipliers.

---

## HUD Philosophy

> **"The quiet frame around the gym, not a cockpit."**

The HUD is a *minimal top bar* showing the three numbers the player steers by —
**money**, **satisfaction**, **time/day** — plus the **pause/speed transport**.
It is read-only state display + transport forwarding; it owns no game state and
never competes with the play area. No popups, no badges, no red alarms, no event
feedback — event feedback lives in-world (VFX), not on the HUD (GDD #16 Core Rule 5).

This is a **"minimal but present"** philosophy (Hollow Knight / Dark Souls register):
only critical decision-relevant information is always visible; everything else is
contextual or on-demand. Density is a *feature*, not a limitation — a glance tells
you you're doing fine.

---

## Information Architecture

### Full Information Inventory

From GDD UI Requirements across all systems (HUD aggregates every system's needs):

| # | Item | Source | Category |
|---|---|---|---|
| 1 | Money balance | Economy (#11) — `balance_changed` | **Must Show** |
| 2 | Satisfaction / reputation | Satisfaction (#10) — `global_satisfaction` | **Must Show** |
| 3 | Day number | TimeSystem (#3) — `tick_count` | **Must Show** |
| 4 | Time of day | TimeSystem (#3) — `tick_count` | **Must Show** |
| 5 | Pause state | TimeSystem (#3) | **Must Show** |
| 6 | Speed level (1×/2×/3×) | TimeSystem (#3) | **Must Show** |
| 7 | Flow-overlay toggle | Overlay (#8) | Contextual (HUD hosts the toggle button) |
| 8 | Event feedback (member unhappy, milestone) | various | **Hidden** — in-world micro-feedback, NOT the HUD (GDD #16 Core Rule 5) |
| 9 | Equipment prices | Catalog (#2) | Hidden from HUD — lives in the Shop palette |
| 10 | Zone/congestion detail | Overlay (#8) | Hidden from HUD — lives in the overlay layers |

**Conflict check**: The philosophy is "minimal but present"; Must Show = 6 compact
items (money, satisfaction, day, time-of-day, pause, speed), all fitting in one top
bar. No conflict — this is the intended sparse state.

### Categorization

| Category | Items | Behavior |
|---|---|---|
| **Must Show** | money, satisfaction, day/time, pause/speed | always visible top bar |
| **Contextual** | flow-overlay toggle | visible as a quiet HUD button; overlay layers are the actual diagnostic |
| **On Demand** | (none on the HUD itself) | settings/legend live in pause menu / hover popovers |
| **Hidden** | event feedback, prices, zone detail | communicated in-world or on the palette/overlay |

---

## Layout Zones

```
┌────────────────────────────────────────────────────────────────────┐
│ [🪙 $1,240]  [😊 78% ▁▂▃▅▇]              [☀ Day 4  ‖ 1× 2× 3×] │  ← Top bar (safe margin ≥ 16px)
│                                                                    │
│                                                                    │
│                       G Y M   F L O O R                            │  ← Play area (never covered)
│                    (grid + members + overlay)                      │
│                                                                    │
│                                                                    │
│                                                                    │
│  [Shop palette rack — bottom edge, see build-shop-ui.md]           │
└────────────────────────────────────────────────────────────────────┘
```

- **Top-left**: money (Butter, coin icon) — highest-frequency value, first reading position (F-pattern).
- **Top-center (or just right of money)**: satisfaction meter — small, quiet, never competing with money.
- **Top-right**: day/time + pause/speed cluster, grouped (related info + actions together).
- **No bottom bar, no persistent side panels** — nothing else lives on the HUD.
- Safe margins: ≥ 16px from screen edges at 1.0× UI scale, scaled with UI scale; elements never overlap the play area at 1.5×.

### Visual Budget

- **Max simultaneous elements**: 6 (money, satisfaction meter, day, time-of-day, pause,
  speed) + 1 contextual (flow-overlay toggle) = **≤ 7 elements** at any time.
- **Max screen coverage**: the top bar occupies ≤ ~8% of vertical screen height at
  1080p (a single ~48–64px strip incl. safe margin); no HUD element ever covers the
  center play area.
- **Notification budget**: 0 — no toasts/badges/popups on the HUD (GDD #16 Core Rule 5);
  any future transient notification must be justified against this budget before
  adoption (interaction-patterns.md — Toast/Badge avoid).
- The flow-overlay toggle is the only contextual addition; its legend is hover-only
  (never a persistent element).

---

## HUD Elements

### 1. Money Display
- **Zone**: top-left; **Category**: Must Show
- **Content**: Butter coin icon + balance number
- **Visual form**: icon + number; digits **count up/down** over ~0.3 s on `balance_changed` (Count-Up pattern); never a red flash on spend — brief desaturation-then-settle
- **Data source**: Economy — `balance_changed(new, delta)`; **Update behavior**: event-driven (tween re-targets to latest value)
- **Animation**: digit tween ~0.3 s (snap under reduced-motion)
- **Accessibility**: coin icon + number (icon + text, never color alone); value ≥16px @1080p

### 2. Satisfaction Meter
- **Zone**: top-center; **Category**: Must Show
- **Content**: short horizontal/arc meter + numeric % + face/heart icon (shape changes: filled vs outline)
- **Visual form**: calm gauge (Status Meter pattern) — fill ramps **Sage (high) → warm neutral (mid) → soft muted Dusty Rose only at the very low end**; **never** saturated red, never a pulse/alarm regardless of value
- **Data source**: Satisfaction — `global_satisfaction` (slow EMA); **Update behavior**: eases to new fill over ~1 s
- **Animation**: ~1 s ease (snap under reduced-motion)
- **Accessibility**: % + shape-changing icon carry the state (colorblind-safe); never a "health bar" metaphor

### 3. Day / Time Display
- **Zone**: top-right (left of transport cluster); **Category**: Must Show
- **Content**: day number + sun/clock-position icon for time-of-day (icon, not color-only)
- **Visual form**: "Day N" + icon
- **Data source**: TimeSystem — `tick_count` → `day = 1 + floor(tick_count / TICKS_PER_DAY)`, `time_of_day = (tick_count mod TICKS_PER_DAY) / TICKS_PER_DAY` (GDD #16 Formulas; `TICKS_PER_DAY` TBD — OQ1)
- **Update behavior**: on tick advance (10 Hz); day number updates on day rollover
- **Animation**: none (or gentle icon position change)

### 4. Pause / Speed Transport Cluster
- **Zone**: top-right (rightmost); **Category**: Must Show
- **Content**: four small buttons — **‖ (pause), 1×, 2×, 3×**
- **Visual form**: small buttons; active one marked by **outline + filled-dot icon** (never color alone); active speed at any moment: exactly one (or none when paused)
- **Data source**: TimeSystem pause/speed state; **Update behavior**: forwarded input; reflects state after toggle/set
- **Animation**: soft click on press (nice-to-have); no alarm
- **Input**: mouse click; **Space** toggles pause; **1/2/3** set speed directly (implicitly unpausing — one action)
- **Accessibility**: active state legible without color; focus order left-to-right; hotkeys work regardless of focus

### 5. Flow-Overlay Toggle (Contextual)
- **Zone**: top-right, grouped with transport (or a small utility button near it)
- **Content**: a quiet button ("flow"/heatmap icon) that toggles the overlay layers (H hotkey)
- **Data source**: Overlay (#8) visibility state; **Update behavior**: on toggle
- **Behavior**: first-ever toggle shows a one-time contextual tip (~4 s); legend popover on hover only (no persistent legend, GDD #8 Core Rule 8)

---

## Dynamic Behaviors

| Condition | HUD behavior |
|---|---|
| Game loads | Renders **paused** immediately with loaded money/satisfaction/day (no stale values) |
| `balance_changed` | Money count-up tween (~0.3 s), Butter throughout; palette re-greys are Shop's concern |
| `global_satisfaction` change | Meter eases to new fill over ~1 s; % + icon update with it |
| Day rolls over | Day number updates; time icon continues |
| Space pressed | Pause toggles; button reflects state; if resuming, last-used speed highlights |
| 1/2/3 pressed | Speed set immediately (unpausing if paused); exactly one speed button active |
| Speed pressed while already at that speed | No-op |
| Placement drag active | HUD unchanged (overlay dims, not HUD); no HUD elements cover the play area |
| Money changes while paused | Count-up still animates (render-time tween, independent of sim ticks) |
| Event feedback (member unhappy, milestone) | **Nothing on HUD** — in-world micro-feedback only (GDD #16 Core Rule 5) |

---

## Platform & Input Variants

| Platform | Variant |
|---|---|
| **PC — Keyboard/Mouse (primary)** | Full spec above; hotkeys Space/1/2/3/H; Tab navigates HUD elements |
| **PC — Gamepad (partial, stretch)** | Left/Right on the top bar moves focus across money → satisfaction → day → transport; A confirms; **note**: gamepad support is a stretch goal — this variant is documented for future, not MVP-blocking (accessibility-requirements.md AQ2) |
| **UI scale** | 0.8×–1.5× integer; top bar reflows to stay within safe margins; no overlap at 1.5× |
| **Aspect ratios** | 16:9 reference; 16:10 / 4:3: top bar keeps left/center/right grouping, spacing compresses; never overlaps play area |

---

## Accessibility

- **Tier**: Standard (WCAG-AA) — per `design/ux/accessibility-requirements.md`.
- Colorblind-safe: money = icon+number; satisfaction = % + shape-changing icon; speed = outline + filled dot. No information by color alone.
- **No red/alarm states ever**: satisfaction at rock bottom shows muted warm tone + % + icon — never red, never flashing (GDD #16 Edge Cases; Pillar 2 absolute).
- Keyboard: Space/1/2/3 always work; Tab order = money → satisfaction → day → transport cluster → overlay toggle.
- Focus indicator (2px outline + inset) distinct from selection cue.
- Reduced-motion: money snap, satisfaction static fill, no breathe/pulse anywhere.
- Text ≥ 16px @1080p; contrast AA; scales with UI scale; high-contrast theme (future #22) must preserve the calm palette while raising contrast.

---

## Tuning Knobs

| Knob | Default | Safe Range | Notes |
|---|---|---|---|
| money count-up duration | 0.3 s | 0.2–0.5 s | too long = laggy; too short = snap |
| satisfaction ease duration | 1.0 s | 0.5–1.5 s | reinforces "slow meter" |
| `TICKS_PER_DAY` | TBD (TimeSystem-owned; provisional ~1800 ≈ 3 real min at 1×) | — | HUD OQ1 — day display mapping |
| heatmap toggle placement | top-right utility | — | presentation choice, confirmed here |

---

## Open Questions

| # | Question | Owner | Target Resolution |
|---|---|---|---|
| OQ1 | **`TICKS_PER_DAY`** — in-game day length in ticks; needed for the day/time display. | TimeSystem / game-designer | Fun-validation playtest (pace of day matters to feel) |
| OQ2 | **Pause-menu shell** (settings + save/load access) is separate from the HUD and not in the MVP systems index — add as a small UI task (shared with SaveLoad's menu note). | producer / ux-designer | Before a shippable build |
| OQ3 | Event micro-feedback (member unhappy, milestone) is deliberately NOT on the HUD — confirm each event has an in-world feedback home when those systems are designed. | those systems' owners | When each is designed |
