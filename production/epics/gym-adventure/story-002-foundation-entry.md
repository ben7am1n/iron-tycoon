# GA-002 — Resource preflight and usable save/load controls

Status: In Progress
Last Updated: 2026-09-06
Layer: Foundation
Type: UI
TR-ID: TR-SL-001, TR-SL-004, TR-SL-007
ADR Governing Implementation: docs/architecture/adr-0002-storage-format.md
Related ADR: docs/architecture/adr-0001-di-container-scene-bootstrap.md
Manifest Version: 2026-07-23
Dependencies: GA-001 before final integration acceptance; UI/preflight implementation can proceed independently against existing SaveLoad APIs.

## Acceptance Criteria

- [ ] Main offers visible Chinese save and load controls, pauses on load and gives success/failure feedback; saving while paused works without requiring another simulation tick.
- [ ] Loading refreshes the main resolver from GridSystem identities and clears transient selection/drag/UI state.
- [ ] Required data files are checked and validated before simulation/presentation assembly; absent or malformed required data produces visible failure and a nonzero smoke exit, never a false PASS.
- [ ] User's existing data/expansion.json remains intact and is identified as required deliverable without committing unrelated files.
- [ ] Actual main-scene save/load and a missing-resource startup probe are exercised; UI has screenshot evidence.

## Implementation Notes

SaveLoad is attached through the existing orchestrator and reads its systems. Do not duplicate state or invent another serializer. Newly added helper/controller public methods need doc comments. New saves expose PlacedInstance.equipment_id after GA-001; do not infer by geometry. File writes must preserve a previous valid save on failure; coordinate SaveLoad implementation changes with GA-001 owner. A small focused resource preflight helper may be added; it is governed by ADR-0002.

## Out of Scope

Grid/Placement/Selection/Satisfaction/SaveLoad implementation owned by GA-001; new day gameplay; large composition refactor; commits.

## Test Evidence

tests/integration/save_load/main_save_entry_test.gd (or engine process probe where SceneTree runner cannot host scene lifecycle); production/qa/evidence/gym-adventure-foundation.md.
