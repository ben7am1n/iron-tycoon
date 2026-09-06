# GA-006 — Three-Day Content Expansion and Event Progression

Status: Complete
Last Updated: 2026-09-06
Layer: Feature
Type: Gameplay/Narrative/Simulation
TR-ID: TR-GA-001, TR-GA-002, TR-GA-003, TR-GA-004
ADR Governing Implementation: docs/architecture/adr-0011-community-day-session.md
Manifest Version: 2026-09-06
Dependencies: GA-004 (playable loop), GA-005 (visual sample).

## Scope

Extend the verified single-day community loop into the complete three-day narrative progression specified in docs/plans/2026-09-06-gym-adventure/experience-and-content.md and design/gdd/gym-adventure.md:
1. Day 2: Station arrival positioning feedback from Day 1, course selection enabling `course_strength_intro` (requiring `bench_press`), Aluo Day 2 lyrics interaction, second guidance request, and Day 2 closing band invitation (`band_invitation`).
2. Day 3: Band event preparation, replacing the four course seats with the four band members (`singer_aluo` and three band mates), band event attendance (`band_event_attended`), and threshold-checked event completion (`band_event_complete`) leading to the slice ending dialogue.
3. Master Lin's gym renovation: 120-cash upgrade (`gym_renovated`), verified against Economy ledger with presentation lighting and sign enhancements.
4. Permanent event idempotency: `aluo_met`, `aluo_first_class`, `band_invitation`, `band_event_attended`, `band_event_complete`, `gym_renovated` committed atomically without repeat emissions or reward stacking.
5. Save/load round-trip across Day 2 and Day 3 with complete state restoration.

## Acceptance Criteria

- [x] DayCycleSystem supports course selection (`select_course`) between `course_endurance_intro` and `course_strength_intro`, enforcing required equipment existence on grid (`bench_press` + `yoga_mat` for strength).
- [x] Master Lin's renovation command (`renovate_gym`) verifies cash >= 120, deducts exactly 120 via Economy, commits `gym_renovated`, and rejects duplicate renovation or insufficient balance.
- [x] Day 2 progression includes Day 1 station arrival advice in PREP, Day 2 Aluo dialogue in OUTING, and automatically triggers `band_invitation` at Day 2 CLOSE if `aluo_first_class` was achieved.
- [x] Day 3 replaces standard course participants with the 4 band members when `band_invitation` is active, commits `band_event_attended` at class start, and commits `band_event_complete` when all four members meet the 30s training threshold.
- [x] Day 3 CLOSE presents the band closure dialogue when `band_event_complete` is achieved; non-completion allows seamless continuation into supplementary days without losing progression.
- [x] Visual lighting and presentation layer reflect `gym_renovated` status with enhanced entrance sign / counter illumination.
- [x] Complete two-phase save/load round-trip preserves Day 2/3 state, selected course, renovation flag, and all permanent story events with zero sandbox pollution.
- [x] Full regression suite passes with 0 failures.

## Implementation Notes

- Maintain strict separation of concerns: DayCycleSystem owns community session progression; Economy owns cash deductions; MemberSim owns member movements.
- UI commands route strictly through `DayCycleSystem.command()`.
- Backward compatibility: Day 1 saves deserialize cleanly with sensible defaults.

## Test Evidence

- Integration test: `tests/integration/gym_adventure/three_day_progression_test.gd` (51 passed, 0 failed).
- Master test suite: `tests/headless_runner.gd` (118 test files, 6,382 passed, 0 failed).
- Detailed verification document: `production/qa/evidence/gym-adventure-three-day.md`.
