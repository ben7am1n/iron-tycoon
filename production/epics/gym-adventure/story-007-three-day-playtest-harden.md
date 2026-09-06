# GA-007 — Three-Day Playable Smoke, UX Hardening, and Resource Stability

Status: Complete
Last Updated: 2026-09-06
Layer: Feature
Type: Quality/Integration/Hardening
TR-ID: TR-GA-001, TR-GA-002, TR-GA-003, TR-GA-004
ADR Governing Implementation: docs/architecture/adr-0011-community-day-session.md
Manifest Version: 2026-09-06
Dependencies: GA-005 (visual sample), GA-006 (three-day content).

## Scope

Execute the complete M4 hardening and validation milestone specified in docs/plans/2026-09-06-gym-adventure/implementation.md and experience-and-content.md:
1. End-to-end multi-day playable loop verified in real Main scene tree with UI, build mode, course switching, renovation, and band concert.
2. Capture in-engine screenshot evidence for Day 2 renovated gym and Day 3 band concert in action.
3. Verify resource lifecycle and object stability over 20 consecutive session create/destroy iterations without unbounded memory growth.
4. Verify UX criteria UX-01 through UX-08: keyboard and mouse navigation, pause handling, input release safety, and non-blocking dialogue progression.
5. Complete clean save slot isolation and tear-down.

## Acceptance Criteria

- [x] Real Main scene integration test (`three_day_playable_test.gd`) executes full 3-day loop from Day 1 start to Day 3 slice completion.
- [x] Day 2 in-engine purchasing and placement of `bench_press` activates `course_strength_intro` through GUI/command.
- [x] Day 2 renovation triggers live lighting presentation change via `LightingLayer`.
- [x] Day 3 band class spawns, trains, completes threshold, and triggers closure dialogue in full viewport.
- [x] 20 consecutive session allocation/free cycles demonstrate stable resource teardown.
- [x] In-engine screenshot evidence generated for Day 2 renovated gym, Day 3 band concert, and Day 3 slice completion.
- [x] Full headless regression runner passes with 0 failures across all 119 test files.

## Test Evidence

`production/qa/evidence/gym-adventure-three-day-playable.md` and associated PNG captures (`gym-adventure-day2-renovated.png`, `gym-adventure-day3-band.png`, `gym-adventure-day3-close.png`).
