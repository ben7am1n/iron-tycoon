# Story 003: Reservation Map and Contention

> **Epic**: member-sim
> **Status**: Ready
> **Layer**: Feature
> **Type**: Logic
> **Estimate**: M — 2 sessions (≤4h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-02

## Context

**GDD**: `design/gdd/member-sim.md`
**Requirement**: `TR-MS-004`, `TR-MS-005`, `TR-MS-006`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0003 (GridStateReader Contract); ADR-0004 (Seeded RNG); ADR-0005 (Signal Bus & Event Routing)
**ADR Decision Summary**: MemberSim owns the access-cell reservation map `reservations[equipment_instance_id] = {occupant, next_claimant}` — GridSystem explicitly refused to own it. Queue depth capped at 1 for MVP. Contention resolves by ascending `member_id` iteration order only.

**Engine**: Godot 4.7.1 | **Risk**: LOW
**Engine Notes**: GDScript Dictionary keyed by int is fine; keep iteration of reservations in ascending `equipment_instance_id` order for determinism.

**Control Manifest Rules (Feature layer)**:
- Required: `member_completed_visit(member_id)` (S5) — quota-met departures only
- Forbidden: no mid-tick yielding
- Guardrail: queue depth 1 keeps queueing visually simple (Pillar 3)

---

## Acceptance Criteria

*From GDD `design/gdd/member-sim.md`, scoped to this story:*

- [ ] AC3 [UNIT][WB] GIVEN members `member_id` 5 and 7 both targeting the same free equipment on one tick, WHEN the reservation claim resolves, THEN member 5 becomes `occupant` and member 7's redraw excludes that equipment
- [ ] AC4 [UNIT] GIVEN any equipment's reservation record, THEN at most one `member_id` is ever `occupant` and at most one is `next_claimant` at any tick boundary (property test over N randomized ticks)
- [ ] AC5 [UNIT] GIVEN a member holding `next_claimant` for equipment E who leaves WALKING_TO or QUEUEING without becoming `occupant`, WHEN that transition occurs, THEN `reservations[E].next_claimant` is null by the end of that same tick (the release invariant — deadlock prevention)
- [ ] AC16 [UNIT][WB] GIVEN a member in WALKING_TO or QUEUEING, THEN at no tick does its occupied cell equal a solid footprint cell (GridSystem's solid set as oracle) — only access cells and the one-cell-short queue position are permitted equipment-adjacent cells

---

## Implementation Notes

*Derived from ADR-0003 + ADR-0004 + ADR-0005 Implementation Guidelines:*

**Reservation map (Core Rule 4):**
- `reservations[equipment_instance_id] = {occupant: member_id?, next_claimant: member_id?}`
- **Claim rule**: a member may set `next_claimant` iff it is currently null — whether or not `occupant` is null. Free machine → walk and become occupant; busy machine → become the single queue slot
- **On arrival**: if `occupant` is null → claim `occupant = self`, clear `next_claimant`, → USING. Else → QUEUEING (holding `next_claimant`)

**Release invariant (Core Rule 4 — the correctness rule):**
- Any member holding `next_claimant` that leaves WALKING_TO or QUEUEING **without** becoming that equipment's `occupant` must clear `next_claimant` in the **same tick**
- This keeps the lock opportunistic and self-cleaning — the reason "make the access cell solid" was forbidden (that would convert a transient conflict into a permanent deadlock)

**Fairness/determinism (Core Rule 4, TR-MS-006):**
- All contention resolves purely by ascending-`member_id` iteration order; no engine/hash order ever involved
- A lower-`member_id` member claims first; the loser detects the lost race and redraws (bounded retries) — stays in SELECTING_TARGET if pool exhausts this tick, no partial state committed

**Movement safety (AC16):**
- WALKING_TO: member walks on path cells; must never step onto a solid footprint cell
- QUEUEING: stops **one cell short** of the access cell (never steps onto an occupied access cell — avoids sprite overlap)
- Only access cells and the one-cell-short queue position are permitted equipment-adjacent cells
- Test against GridSystem solid set as oracle — assert at no tick does occupied cell equal a solid footprint cell

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 001]: lifecycle state machine skeleton, spawn/despawn
- [Story 002]: target-selection weight computation (the candidate draw that feeds the claim)
- [Story 004]: patience give-up transition (uses blacklist), path invalidation
- [Story 005]: serialization of the reservation map (rebuilt from members' own claim flags on load)

---

## QA Test Cases

*Written by qa-lead at story creation. The developer implements against these — do not invent new test cases during implementation.*

- **AC3**: 竞争解析
  - Given: member_id 5 and 7 both target same free equipment on one tick
  - When: reservation claim resolves
  - Then: member 5 becomes occupant; member 7's redraw excludes that equipment
  - Edge cases: member 7 has no other candidate → stays SELECTING_TARGET; next tick retries

- **AC4**: 容量属性测试
  - Given: any equipment's reservation record
  - When: N randomized ticks processed
  - Then: at most one occupant and at most one next_claimant at any tick boundary
  - Edge cases: member arriving exactly when occupant releases; simultaneous claim attempts

- **AC5**: 释放不变量
  - Given: member holds next_claimant for E, leaves WALKING_TO/QUEUEING without becoming occupant
  - When: that transition occurs
  - Then: reservations[E].next_claimant == null by end of same tick
  - Edge cases: repath-empty → LEAVING path (release + reselect); patience exhaustion → release same tick

- **AC16**: 移动安全
  - Given: member in WALKING_TO or QUEUEING
  - When: ticks advance
  - Then: occupied cell never equals a solid footprint cell (GridSystem solid set as oracle); only access cells and one-cell-short queue position permitted
  - Edge cases: diagonal corner movement must not cut corners; member passing adjacent to equipment

---

## Test Evidence

**Story Type**: Logic
**Required evidence**:
- `tests/unit/member_sim/reservation_map_test.gd` — must exist and pass

**Status**: [ ] Not yet created

---

## Dependencies

- Depends on: Story 002 (target selection — the claim follows the weighted draw), Story 001 (state machine — WALKING_TO/QUEUEING/USING transitions)
- Unlocks: Story 004 (patience give-up uses reservation release), Story 005 (serialization)
