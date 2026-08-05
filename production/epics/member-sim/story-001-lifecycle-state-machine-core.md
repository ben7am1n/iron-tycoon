# Story 001: Lifecycle State Machine Core

> **Epic**: member-sim
> **Status**: Complete — 2026-08-05
> **Layer**: Feature
> **Type**: Logic
> **Estimate**: M — 2 sessions (≤4h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-02

## Context

**GDD**: `design/gdd/member-sim.md`
**Requirement**: `TR-MS-001`, `TR-MS-002`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0003 (GridStateReader Contract); ADR-0004 (Seeded RNG); ADR-0005 (Signal Bus & Event Routing)
**ADR Decision Summary**: MemberSim is a `RefCounted` `SimSystem` with two-phase `init()`/`_post_init()`, manual `_init()` guard, and exactly-once RNG sub-stream registration via `TimeSystem.get_rng("MemberSim")`. It runs FIRST in the hardcoded tick dispatch. Members iterate in ascending `member_id` order — never scene-tree or hash order.

**Engine**: Godot 4.7.1 | **Risk**: LOW
**Engine Notes**: `SimSystem` base uses a manual `_init()` guard (not `@abstract` — non-functional on `RefCounted` in 4.7.1). Every public method guards against use-before-init. No `await` inside `on_tick()` — tick-boundary = safe save point.

**Control Manifest Rules (Feature layer)**:
- Required: Two-phase init; `init()` only called once; every public method guards use-before-init
- Required: Tick dispatch fixed order MemberSim → Congestion → Satisfaction → Economy; no mid-tick yielding
- Forbidden: Never call `init()` twice; never trigger side effects in `init()`
- Forbidden: Autoload singletons for system access

---

## Acceptance Criteria

*From GDD `design/gdd/member-sim.md`, scoped to this story:*

- [ ] AC1 GIVEN a member in SELECTING_TARGET with zero reachable/available candidates, WHEN `on_tick()` runs, THEN the member is LEAVING by the end of the same tick (no extra tick spent stalled)
- [ ] AC2 GIVEN a member whose `exercises_done == exercises_per_visit`, WHEN SELECTING_TARGET evaluates, THEN state → LEAVING regardless of candidate availability
- [ ] AC6 GIVEN a fixed RNG seed and a scripted arrival/tick timeline, WHEN the sim runs twice, THEN the full state trace (positions, states, reservation maps) is byte-identical across both runs
- [ ] AC15 GIVEN `current_member_count == max_concurrent_members` and an arrival draw succeeds, WHEN the tick processes, THEN no member spawns, `member_id_counter` is NOT incremented, and no error/door-queue is created
- [ ] AC21 GIVEN a LEAVING member for whom no exit path ever resolves, WHEN the defensive safety timeout elapses, THEN the member is forced to GONE (never permanently stuck — Pillar 2)

---

## Implementation Notes

*Derived from ADR-0003 + ADR-0004 + ADR-0005 Implementation Guidelines:*

**State machine skeleton (Core Rule 2):**
- States: `ENTERING → SELECTING_TARGET → WALKING_TO → [QUEUEING] → USING → (SELECTING_TARGET | LEAVING) → GONE`
- `ENTERING` is a pass-through spawn tick — immediately evaluates SELECTING_TARGET the same tick
- Iterate active members in **ascending `member_id` order** every tick (Array kept sorted or explicit sort)
- Active members stored in a Dictionary keyed by `member_id` plus a sorted id Array for iteration (or maintain insertion in id order)

**Tick sequencing (Core Rule 1):**
- Each tick: (a) run arrival check FIRST (draw from RNG sub-stream), (b) update every active member exactly once
- RNG consumption order is fixed: arrival roll(s) first, then per-member updates in member_id order (only members spawning/reselecting draw)

**Spawn / despawn (Core Rule 6):**
- Instantiate at level's single `entrance_cell`, assign `member_id = member_id_counter++`, roll `preference_profile`, insert into id-sorted collection
- At `max_concurrent_members` cap: arrival skips that tick — soft cap, never a failure, counter NOT incremented (AC15)
- Despawn on GONE: plain removal; id retired forever
- `entrance_cell`/`exit_cell` are a HARD upstream dependency on GridSystem/level definition (TR-MS-013) — the orchestrator must supply them at init

**LEAVING safety timeout (AC21):**
- Defensive timeout forces GONE if no exit path ever resolves — Pillar 2 forbids a permanently stuck member
- Use a per-member `leaving_timeout_ticks` counter decremented each LEAVING tick

**Determinism (AC6):**
- All randomness via `get_rng("MemberSim")`; fixed consumption order; ascending member_id iteration
- `preference_profile` resolved at spawn and stored (not re-derivable seed)

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 002]: target-selection weighted pick (candidate pool, weights, top-K, path-check, draw)
- [Story 003]: reservation map + contention resolution
- [Story 004]: path invalidation, patience give-up, mid-use interrupts
- [Story 005]: serialization of member_id_counter + full state, AC22 flow hypothesis

---

## QA Test Cases

*Written by qa-lead at story creation. The developer implements against these — do not invent new test cases during implementation.*

- **AC1**: 零候选同 tick 离开
  - Given: member in SELECTING_TARGET, no reachable/available candidates
  - When: on_tick() runs
  - Then: state == LEAVING by end of same tick; no extra tick spent stalled
  - Edge cases: empty gym (no equipment at all) — member wanders ~20 ticks then leaves calmly

- **AC2**: 配额满足即离开
  - Given: exercises_done == exercises_per_visit
  - When: SELECTING_TARGET evaluates
  - Then: state → LEAVING regardless of candidate availability
  - Edge cases: quota reached while candidates are plentiful — still leaves

- **AC6**: 确定性重放
  - Given: fixed RNG seed + scripted arrival/tick timeline
  - When: sim runs twice
  - Then: full state trace (positions, states, reservation maps) byte-identical
  - Edge cases: run with different frame pacing (same tick count) — identical output

- **AC15**: 容量门
  - Given: current_member_count == max_concurrent_members, arrival draw succeeds
  - When: tick processes
  - Then: no member spawns; member_id_counter NOT incremented; no error/door-queue
  - Edge cases: count exactly at cap vs just under cap (spawn allowed)

- **AC21**: 退出安全超时
  - Given: LEAVING member, no exit path ever resolves
  - When: defensive safety timeout elapses
  - Then: member forced to GONE (never permanently stuck)
  - Edge cases: exit path blocked mid-leave then unblocked — no premature GONE

---

## Test Evidence

**Story Type**: Logic
**Required evidence**:
- `tests/unit/member_sim/lifecycle_state_machine_test.gd` — must exist and pass

**Status**: [ ] Not yet created

---

## Dependencies

- Depends on: grid-system epic (occupancy reads, `get_placed_instances`, `entrance_cell`/`exit_cell`), navigation epic (`get_path`), equipment-catalog epic (use_duration fields), time-system epic (tick dispatch, SeededRNG)
- Unlocks: Story 002 (target selection), Story 003 (reservations), Story 004 (path invalidation), Story 005 (serialization)
