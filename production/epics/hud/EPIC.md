# Epic: HUD

> **Layer**: Presentation
> **GDD**: design/gdd/hud.md
> **UX Spec**: design/ux/hud.md
> **Architecture Module**: HUD — top-bar Control hierarchy; owns money display, satisfaction meter, day/time display, pause/speed transport
> **Status**: Complete — 2026-08-07 (all 4 stories Complete, Sprint 5 gate PASS)
> **Stories**: 4 stories created — see below

## Stories

| # | Story | Type | Status | ADR |
|---|-------|------|--------|-----|
| 001 | Top-bar Layout & Read-only State Binding | UI | Complete — 2026-08-07 (QA 终审 PASS, t_759c1100) | ADR-0001, ADR-0005 |
| 002 | Money Count Tween | Visual/Feel | Complete — 2026-08-07 (QA 终审 PASS, t_e1297966) | ADR-0005 |
| 003 | Satisfaction Meter | Visual/Feel | Complete — 2026-08-07 (QA 终审 PASS, t_d4771a34) | ADR-0005 |
| 004 | Pause/Speed Transport + Day/Time Display | UI | Complete — 2026-08-07 (QA 终审 PASS, t_f606bc09) | ADR-0005 |

## Overview

The HUD is the always-on heads-up display: a minimal top bar showing money, satisfaction, and day/time, plus the pause/speed transport controls. It is read-only information plus transport — it owns no game state, only displays what Economy, Satisfaction, and TimeSystem expose and forwards pause/speed input back to TimeSystem. Its defining constraint is Pillar 2/3: sparse and calm — no popups, no badges, no red alarms. It is the quiet frame around the gym, not a cockpit. It consumes `balance_changed(new, delta)` from Economy, reads `global_satisfaction` from Satisfaction, and reads `tick_count`/pause/speed from TimeSystem; it forwards Space/1/2/3 and button clicks back to TimeSystem. This is the first UI system of the playable build.

**⚠️ Engine note (4.7 NEW)**: `tween_await()` (4.7) is the intended sequencing API for the money/satisfaction animations — but the LLM knowledge cutoff predates it; verify the exact signature against the local 4.7.1 engine before use. Control offset transforms (4.7 NEW) may be used for animated UI but must not break container layout. dual-focus system (4.6+) means keyboard input should be handled via `_unhandled_key_input` on the HUD node (focus-independent).

## Governing ADRs

| ADR | Decision Summary | Engine Risk |
|-----|-----------------|-------------|
| ADR-0001: DI Container & Scene Bootstrap | UI systems are scene-tree Nodes (not RefCounted sim systems); they subscribe to signals from the RefCounted systems. Manual `_init()` guard pattern applies to sim systems only. | LOW |
| ADR-0005: Signal Bus & Event Routing | Typed signal connections (`signal.connect(callable)`), never string-based. UI subscribes to `balance_changed` / reads state; never mutates sim state except forwarding pause/speed to TimeSystem. Bridge Nodes handle input; keyboard via `_unhandled_key_input` (dual-focus 4.6+). | MEDIUM |

## GDD Requirements

| TR-ID | Requirement | ADR Coverage |
|-------|-------------|--------------|
| TR-HUD-001 | Minimal top bar: money (Butter, coin icon), satisfaction meter, day/time + pause/speed cluster | ADR-0001, ADR-0005 ✅ |
| TR-HUD-002 | Satisfaction meter: Sage (high) → warm neutral (mid) → soft muted Dusty Rose (low); never saturated red, never pulse | ADR-0005 ✅ |
| TR-HUD-003 | Satisfaction meter paired with numeric % AND face/heart icon shape change = colorblind-safe | ADR-0005 ✅ |
| TR-HUD-004 | Money count: tween digits old→new over ~0.3s on balance_changed; never red flash on spend | ADR-0005 ✅ |
| TR-HUD-005 | Hotkeys: Space=toggle pause; 1/2/3=set speed and implicitly unpause | ADR-0005 ✅ |
| TR-HUD-006 | Read-only + transport only; no popups, toasts, or badges on HUD | ADR-0005 ✅ |
| TR-HUD-007 | On load: renders paused state and loaded values immediately; money tween independent of sim ticks | ADR-0005 ✅ |

## Definition of Done

This epic is complete when:
- All stories are implemented, reviewed, and closed via `/story-done`
- All acceptance criteria from `design/gdd/hud.md` (AC1–AC8) are verified
- `src/ui/hud.gd` (or equivalent Control hierarchy under `src/ui/`) exists, subscribes to `balance_changed`, reads `global_satisfaction` and TimeSystem pause/speed state, and forwards transport input
- UI stories have evidence docs with sign-off in `production/qa/evidence/` (headless screenshot or manual walkthrough); testable state-binding logic has automated coverage in `tests/`
- The HUD renders the paused state on load (no stale values), and no element overlaps the play area

## Next Step

Work through stories in order — each story's `Depends on:` field tells what must be DONE before it can start.
