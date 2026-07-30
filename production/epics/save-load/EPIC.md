# Epic: SaveLoad

> **Layer**: Foundation
> **GDD**: design/gdd/save-load.md
> **Architecture Module**: SaveLoad — pure coordinator, owns no state
> **Status**: Ready
> **Stories**: 4 stories created — see below

## Stories

| # | Story | Type | Status | ADR |
|---|-------|------|--------|-----|
| 001 | SaveBlob Composition and Tick-Boundary Hook | Integration | Ready | ADR-0002, ADR-0005 |
| 002 | Load Orchestration — Phase A/B and Load Order | Integration | Ready | ADR-0001, ADR-0002, ADR-0007 |
| 003 | Round-Trip Determinism and Resume-Paused Enforcement | Integration | Ready | ADR-0005, ADR-0007, ADR-0002, ADR-0004 |
| 004 | File I/O, JSON Encoding, and Version Checking | Integration | Ready | ADR-0002 |

## Overview

SaveLoad is a coordinator, not a state owner. It holds no game state of its own. Its job is to (a) collect each sim system's `serialize()` output into one save blob, (b) on load, call each system's `deserialize()` in the one correct order the dependency graph allows, (c) guarantee saves are taken only at tick boundaries — relying on TimeSystem's no-mid-tick-yield rule, and (d) treat a load as all-or-nothing via a two-phase validate-then-commit protocol. No save may half-apply and leave a Frankenstein session.

The save blob is a JSON envelope (`{version, master_seed, time_system, grid_system, member_sim, congestion, satisfaction, economy}`). Four systems contribute nothing to the blob — ZoneRules (stateless pure function), Navigation (rebuilt from GridSystem occupancy on load), PlacementSystem (instance_id counter re-derived from max occupant_id), and SelectionSystem (mapping rebuilt from GridSystem on load). MVP versioning is exact-match only: a mismatch is rejected gracefully with a user-facing message, no crash, no partial load, no auto-migration.

Load order is enforced programmatically: Phase A (validate, zero mutation) runs every system's `deserialize()` in dry-run mode; Phase B (commit) applies only if all systems pass validation. The critical sequence is: TimeSystem → GridSystem → PlacementSystem.rederive → SelectionSystem.rebuild → Navigation.rebuild → MemberSim → Congestion → Satisfaction → Economy. Navigation's AStarGrid2D cross-rebuild determinism was verified 2026-07-21 (ADR-0007 gate PASSED, 10/10 processes bit-identical).

## Governing ADRs

| ADR | Decision Summary | Engine Risk |
|-----|-----------------|-------------|
| ADR-0001: DI Container & Scene Bootstrap | SaveLoad injected into `SimulationOrchestrator`. Initialization order at Tier 7 (last — depends on all coordinated systems). | LOW |
| ADR-0002: Storage Format | Save blob format: JSON (`.sav.json`) with `format_version` envelope. `FileAccess.store_*()` returns `bool` since Godot 4.4 — every write must check the return value. `FileAccess.flush()` called before `f.close()`. 64-bit ints as hex strings. `JSON.stringify()` with `full_precision=true` and `sort_keys=true`. `JSON.parse_string()` for round-trip (self-written JSON, no authoring errors). | MEDIUM |
| ADR-0005: Signal Bus & Event Routing | Save defers to fire from `tick_completed(tick_count)` signal (S2) — structural tick-boundary guarantee, not a runtime check. No mid-tick save possible. | LOW |
| ADR-0007: AStarGrid2D Determinism | Cross-process determinism gate PASSED 2026-07-21 (10/10 processes bit-identical). Navigation serializes nothing — rebuilt from `GridSystem.is_solid()` occupancy on load. Lexicographic path stabilizer fallback defined but not active in 4.7.1. Gate test stays in CI, re-runs on every Godot version bump. | LOW |

## GDD Requirements

| TR-ID | Requirement | ADR Coverage |
|-------|-------------|--------------|
| TR-SL-001 | Coordinator, not state owner; tick-boundary saves via TimeSystem.tick_completed signal | ADR-0005 ✅ |
| TR-SL-002 | Save blob: {version, master_seed, time_system, grid_system, member_sim, congestion, satisfaction, economy} | ADR-0002 ✅ |
| TR-SL-003 | Load order enforced: TimeSystem → GridSystem → PlacementSystem.rederive → SelectionSystem.rebuild → Navigation.rebuild → MemberSim → Congestion → Satisfaction → Economy | ADR-0001 ✅ |
| TR-SL-004 | All-or-nothing: Phase A (validate, zero mutation) → Phase B (commit only if all valid) | ADR-0002 ✅ |
| TR-SL-005 | Every coordinated system's deserialize must support non-mutating validate/dry-run mode | ADR-0002 ✅ |
| TR-SL-006 | Navigation OQ1 (AStarGrid2D cross-rebuild tie-break) = HARD blocking prerequisite | ADR-0007 ✅ |
| TR-SL-007 | Versioning: exact-match only MVP; mismatch rejected gracefully; resume always paused | ADR-0002 ✅ |
| TR-SL-008 | ZoneRules, Navigation, PlacementSystem, SelectionSystem contribute NOTHING to save blob | ADR-0002 ✅ |

## Definition of Done

This epic is complete when:
- All stories are implemented, reviewed, and closed via `/story-done`
- All acceptance criteria from `design/gdd/save-load.md` are verified
- All Logic and Integration stories have passing test files in `tests/`
- Two-phase load verified: Phase A failure leaves all systems untouched (integration test with intentionally corrupt save blob)
- Round-trip determinism verified: save → load → run N ticks → save2 produces byte-identical blob to save → run N ticks → save2 without the intervening load
- Version mismatch produces user-facing error message, no crash, no partial state
- `FileAccess.store_*()` return values checked everywhere; missing check = test failure
- All Visual/Feel and UI stories have evidence docs with sign-off in `production/qa/evidence/`

## Next Step

Run `/create-stories save-load` to break this epic into implementable stories.
