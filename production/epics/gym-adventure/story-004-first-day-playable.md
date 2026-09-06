# GA-004 — First playable community day: controls and world

Status: Complete
Last Updated: 2026-09-06
Layer: Feature
Type: UI
TR-ID: TR-GA-001, TR-GA-003, TR-GA-004
ADR Governing Implementation: docs/architecture/adr-0011-community-day-session.md
Manifest Version: 2026-09-06
Dependencies: GA-001/GA-002; GA-003 API can be integrated concurrently after the foundation gate.

## Acceptance Criteria

- [x] Main exposes community and sandbox entry without overwriting saves; community uses the actual gym/world and scheduled members.
- [x] Player can move coach, arrange fixtures/purchases in PREP, depart, walk/run the park route, return, guide the class, see closing dialogue and save/continue.
- [x] Chinese phase/objective/context UI explains controls, time, stamina, current class and feedback without a debug dashboard obscuring the room.
- [x] Space/Esc/focus pause and key release work; 1/2/3 are contextual choices or pace, never community time speed. Building is unavailable during service.
- [x] Class members visibly walk/wait/train on real devices; park and coach movement reflect logic state, not cosmetic interpolation over fake progress.
- [x] Runtime resource preflight includes community config/fixture; F5/F9 and phase auto-saves preserve the correct mode.
- [x] Actual-window walkthrough and screenshots demonstrate PREP, park, service/class, closing and restored paused state.

## Implementation Notes

Read ADR-0011, experience-and-content.md and runtime-interface.md (coordinate exact schema with GA-003). Keep UI read-only except command calls. Reuse current art for first proof. Own main.gd and new HUD/input/coach/park presentation files; no writes to simulation files. Amend existing renderer only for the needed read seam. Source implementation and evidence are delegated to the UI/engine specialist.

## Test Evidence

Real scene probe or input integration plus production/qa/evidence/gym-adventure-first-day.md. Screenshot capture must use actual Godot viewport, no fabricated reference image.

## Out of Scope

New simulation/business state; full three-day content; production art before first-day proof; commits.
