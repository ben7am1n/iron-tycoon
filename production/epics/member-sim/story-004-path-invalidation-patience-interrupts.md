# Story 004: Path Invalidation, Patience and Interrupts

> **Epic**: member-sim
> **Status**: Complete
> **Layer**: Feature
> **Type**: Logic
> **Estimate**: M — 2 sessions (≤4h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-02

## Context

**GDD**: `design/gdd/member-sim.md`
**Requirement**: `TR-MS-007`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0003 (GridStateReader Contract); ADR-0005 (Signal Bus & Event Routing)
**ADR Decision Summary**: Path invalidation compares a cached path's `grid_version` stamp to GridSystem's current version; on mismatch re-query `Navigation.get_path`. Empty result is treated identically whether caused by a new obstacle or the target being deleted — release reservation, reselect-with-retry, else LEAVING.

**Engine**: Godot 4.7.1 | **Risk**: LOW
**Engine Notes**: Navigation paths are `Array[Vector2i]` cell-space paths; `grid_version` is the version stamp exposed by GridSystem.

**Control Manifest Rules (Feature layer)**:
- Required: `member_completed_visit(member_id)` (S5) — quota-met departures only
- Forbidden: no mid-tick yielding in on_tick
- Guardrail: bounded retry counter on reselect — never tight-loop the same query

---

## Acceptance Criteria

*From GDD `design/gdd/member-sim.md`, scoped to this story:*

- [x] AC13 [UNIT] GIVEN a QUEUEING member whose `patience_timer` reaches 0, WHEN the give-up transition fires, THEN `exercises_done` is unchanged and no failure signal distinct from the calm give-up path is emitted
- [x] AC14 [UNIT] GIVEN a member USING equipment E, WHEN E is deleted mid-use, THEN the member transitions to SELECTING_TARGET without crashing and emits exactly one satisfaction-penalty signal
- [x] AC17 [UNIT] GIVEN a cached path's `grid_version` differs from GridSystem's current version on a WALKING_TO tick, WHEN the member updates, THEN `Navigation.get_path` is re-queried exactly once that tick (mock Navigation, assert call count)
- [x] AC18 [UNIT] GIVEN a WALKING_TO member whose repath returns empty for `retry_limit` consecutive attempts, WHEN the limit is exceeded, THEN the member releases its reservation and transitions to LEAVING (bounded-retry exhaustion — distinct from AC1)
- [x] AC19 [UNIT] GIVEN a member that just abandoned equipment E via patience give-up, WHEN it re-runs SELECTING_TARGET the same/next tick, THEN E is excluded by the short-term novelty blacklist (no immediate flip-flop back to E)

---

## Implementation Notes

*Derived from ADR-0003 + ADR-0005 Implementation Guidelines:*

**Path invalidation (Core Rule 5, AC17):**
- Every WALKING_TO / LEAVING tick compares cached path's `grid_version` to GridSystem's current version
- On change: re-query `Navigation.get_path` **exactly once** that tick (AC17 — mock Navigation, assert call count)
- Empty result: treated identically whether "path blocked" or "target gone" — release reservation, reselect-with-retry, else LEAVING. No special-casing
- Bounded retry counter (`retry_limit`) — AC18: exhaustion → release reservation + LEAVING

**Patience give-up (Core Rule 2 QUEUEING, AC13):**
- `patience_threshold_ticks = round(Uniform(patience_min_ticks, patience_max_ticks))` drawn once on entering QUEUEING (30–80 ticks, tune)
- On exhaustion → release reservation, reselect elsewhere with a **short-term blacklist** on this equipment (prevents flip-flop — AC19) → LEAVING if nothing else works
- **Never** shows a failure prompt; **never** resets `exercises_per_visit` progress (Pillar 2) — AC13 asserts `exercises_done` unchanged, no failure signal
- Re-evaluated only when the threshold triggers, not every tick

**Mid-use deletion (Core Rule 2 USING, AC14):**
- If equipment is deleted mid-use (`grid_changed`): interrupt gracefully → SELECTING_TARGET, no crash
- Emit **exactly one** satisfaction-penalty signal (Satisfaction consumes this)
- Note: satisfaction events are direct method reads during Satisfaction's `on_tick()`, not separate cross-system signals (ADR-0005 §3 note)

**Blacklist mechanics (AC19):**
- Short-term no-repeat blacklist: equipment excluded on reselect after patience give-up; entries expire after a few ticks
- Apply temporary novelty penalty to abandoned equipment (as if just-used)

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 001]: state machine skeleton, spawn/despawn, LEAVING safety timeout
- [Story 002]: target-selection weight computation
- [Story 003]: reservation map internals, claim/release
- [Story 005]: serialization of patience state, cached path + grid_version, blacklist

---

## QA Test Cases

*Written by qa-lead at story creation. The developer implements against these — do not invent new test cases during implementation.*

- **AC13**: 耐心耗尽平静放弃
  - Given: QUEUEING member, patience_timer reaches 0
  - When: give-up transition fires
  - Then: exercises_done unchanged; no failure signal distinct from calm give-up path emitted
  - Edge cases: give-up with zero other candidates → wander briefly then retry, never failure prompt

- **AC14**: 使用中删除
  - Given: member USING equipment E
  - When: E deleted mid-use (grid_changed)
  - Then: transitions to SELECTING_TARGET without crashing; emits exactly one satisfaction-penalty signal
  - Edge cases: E deleted while member also has a path cached to it

- **AC17**: 路径失效重查
  - Given: cached path's grid_version differs from GridSystem current version on WALKING_TO tick
  - When: member updates
  - Then: Navigation.get_path re-queried exactly once that tick (mock Navigation, assert call count)
  - Edge cases: grid_version unchanged — zero re-queries; grid_version changes twice in one tick (dedupe)

- **AC18**: 重试耗尽
  - Given: WALKING_TO member, repath returns empty for retry_limit consecutive attempts
  - When: limit exceeded
  - Then: releases reservation and transitions to LEAVING
  - Edge cases: repath empty once then recovers — no premature LEAVING

- **AC19**: 黑名单防翻转
  - Given: member just abandoned E via patience give-up
  - When: re-runs SELECTING_TARGET same/next tick
  - Then: E excluded by short-term novelty blacklist
  - Edge cases: blacklist expiry after N ticks — E becomes eligible again

---

## Test Evidence

**Story Type**: Logic
**Required evidence**:
- `tests/unit/member_sim/path_invalidation_test.gd` — must exist and pass
- `tests/unit/member_sim/patience_interrupt_test.gd` — must exist and pass

**Status**: [x] Complete — 2026-08-02

Both files exist and pass; registered in `tests/headless_runner.gd` TEST_FILES.
Full headless suite: 2568 passed / 0 failed (baseline 2518 + 50 new
assertions), 0 SCRIPT ERROR, run twice with identical per-file results.

Supporting test double: `tests/unit/member_sim/mock_navigation.gd` — a
Navigation subclass whose get_path() counts calls (AC17 exactly-once) and
scripts results (AC18 empty vs recover). NOT a `*_test.gd` file, so it is
never auto-run and needs no TEST_FILES registration.

---

## Deviations (documented, not silent)

1. **grid_version source (supporting change)**: GridSystem did not expose a
   mutation version stamp before this story. Added `_grid_version` bumped
   once per successful `commit()`/`clear()` and the `get_grid_version()`
   read on GridSystem + GridStateReader (safe default 0) + GridSnapshot
   (delegates to base). NOT serialized — on load the counter restarts at 0
   and a restored member's stale stamp triggers exactly one safe re-query
   against the identical rebuilt grid (deterministic). This is an additive
   extension of the ADR-0003 read surface, required by TR-MS-007.
2. **AC5 reservation test upgraded**: the old MS-003 defensive
   `is_solid(next)` abort (release + reselect on any solid next cell) is
   REPLACED by the formal grid_version repath (Core Rule 5). A merely
   blocked path now re-paths AROUND the obstacle and the member keeps
   walking; release only happens on an EMPTY repath. `reservation_map_test.gd`
   `_test_ac5_release_on_blocked_walk` now fully encloses the member (wall +
   footprint) so the repath is empty — the TR-MS-005 release invariant is
   verified through the new mechanism.
3. **AC13 "wander briefly" nuance**: the QA edge "give-up with zero other
   candidates -> wander briefly then retry" is implemented as: the member
   STAYS in SELECTING_TARGET while its give-up blacklist is active (pool
   empty because the only machine is blacklisted), then retries the machine
   once the blacklist expires. Never LEAVING, never a failure prompt —
   matches the BLOCKING assertion (exercises_done unchanged, no failure
   signal) and Pillar 2.
4. **AC14 satisfaction-penalty is a direct read, not a signal** (per
   ADR-0005 §3 note): MemberSim exposes `get_satisfaction_penalty_events()`
   — a per-tick counter reset at the start of each on_tick and incremented
   once per mid-use deletion. Satisfaction consumes it during its own
   on_tick() (which runs after MemberSim in the fixed tick order). The test
   asserts the counter equals exactly 1 after the interrupt tick.
5. **AC18 retry counter placement**: `repath_failures` counts consecutive
   EMPTY path resolutions across the WALKING_TO repath AND the subsequent
   SELECTING_TARGET reselect path-checks (the member bounces between them).
   A successful repath or reselect resets it. Default `repath_retry_limit`
   = 3 (config key), clamped >= 1. LEAVING uses REASON_PATH_BLOCKED,
   deliberately distinct from AC1's no_candidates.

---

## Dependencies

- Depends on: Story 003 (reservation release on give-up), navigation epic (`get_path`, grid_version), grid-system epic (`grid_changed` subscription)
- Unlocks: Story 005 (serialization of path/patience/blacklist state)
