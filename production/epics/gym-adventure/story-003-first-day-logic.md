# GA-003 — First playable community day: simulation

Status: Complete
Last Updated: 2026-09-06
Layer: Core
Type: Integration
TR-ID: TR-GA-001, TR-GA-002, TR-GA-003, TR-GA-004
ADR Governing Implementation: docs/architecture/adr-0011-community-day-session.md
Manifest Version: 2026-09-06
Dependencies: GA-001 and GA-002 foundation gate.

## Acceptance Criteria

- [x] Community mode starts PREP with 280 and movable, unsellable borrowed treadmill/yoga mat, separate from the sandbox.
- [x] Shared fixed clock drives PREP/OUTING/SERVICE/CLOSE with pause/focus correctness and fixed service 1x; running service ends at 360 seconds after final settlement.
- [x] Park route supports legal movement, three pace choices, stamina, 180-second formal attempt, 28-bin scoring, practice and return; result and unfinished attempt survive load.
- [x] Eight ordinary arrivals and four class members use real MemberSim positions/navigation. Four blocks reserve two devices; no-purchase AUTO baseline opens by 220 seconds and every seat trains at least 30 seconds.
- [x] Ordinary 12 and class 24 fees are mutually exclusive and once-only; course quality follows GDD. Guidance selection/timing and automatic fallback work without blocking closing.
- [x] First-day Aluo meeting/class/closing exchange has a skip-park route; next day and save continuation retain events and avoid duplicate rewards.
- [x] Complete mode data validates before load mutation; cold disk restore during all active activities is deterministic and resumes paused. Invalid/cross-mode data fails safely.

## Implementation Notes

Read ADR-0011 and all GDD rules, especially GA-A02/A06/A08/A09/A14/A15/A20/A21/A22. New-mode values live in data/gym_adventure.json, seeded from the design tuning without marking the design sample as runtime-loaded. Add a concrete validated baseline fixture. Publish command payload/view schema in docs/plans/2026-09-06-gym-adventure/runtime-interface.md before UI integration. Source ownership: new state/helper files and MemberSim/Economy/SaveLoad/SimulationOrchestrator; all state mutation stays behind APIs. UI agent owns main and presentation. First-day scope is one endurance course; do not claim complete three-day content.

## Test Evidence

tests/integration/gym_adventure/first_day_loop_test.gd and focused unit cases as needed; all registered in the root runner after implementation. Use state boundary cases, real simulator and file roundtrip, not source-string presence checks.

## Out of Scope

main.gd and presentation files; final production art; full three-day stories, second course, unrelated cleanup, commits.
