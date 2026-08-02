# Story 005: Serialization, Determinism and Flow Hypothesis

> **Epic**: member-sim
> **Status**: Ready
> **Layer**: Feature
> **Type**: Integration
> **Estimate**: M — 2 sessions (≤4h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-02

## Context

**GDD**: `design/gdd/member-sim.md`
**Requirement**: `TR-MS-008`, `TR-MS-009`, `TR-MS-010`, `TR-MS-011`, `TR-MS-012`, `TR-MS-013`, `TR-MS-014`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0002 (Storage Format); ADR-0004 (Seeded RNG); ADR-0005 (Signal Bus & Event Routing)
**ADR Decision Summary**: MemberSim serializes its members and `member_id_counter`. `member_id_counter` MUST be serialized explicitly — it cannot be re-derived from the active set (departed GONE ids absent from active set → `max(active)+1` could reuse a retired id, corrupting references). Reservation map is rebuilt from members' own serialized claim flags on load — never serialized as separate truth.

**Engine**: Godot 4.7.1 | **Risk**: LOW
**Engine Notes**: 64-bit RNG state serialized as hex string (not JSON number); restore via `rng.state = hex_to_int()` directly, never re-derive from master_seed.

**Control Manifest Rules (Feature layer)**:
- Required: `member_completed_visit(member_id)` (S5) — quota-met departures only (TR-MS-014)
- Required: serialize state includes member_id_counter, per-member state (member_id, state, cell, cached path + grid_version, target_equipment_instance_id, held reservation flags, patience_timer, exercises_done, resolved preference_profile)
- Required: two-phase deserialize (Phase A validate zero-mutation, Phase B commit all-or-nothing)
- Forbidden: Never serialise 64-bit RNG state as a JSON number literal; never re-derive RNG from master_seed on load

---

## Acceptance Criteria

*From GDD `design/gdd/member-sim.md`, scoped to this story:*

- [ ] AC7 [INT] GIVEN a save with `member_id_counter = 42` and no active member id ≥ 42, WHEN a new member spawns after load, THEN its `member_id` is 42 (not `max(active)+1`)
- [ ] AC8 [UNIT] GIVEN a load payload missing `member_id_counter` or with `member_id_counter <= max(active member_id)`, WHEN load executes, THEN it fails loudly, never silently substituting a derived value
- [ ] AC9 [UNIT] GIVEN a GONE member's retired `member_id`, WHEN any number of later spawns occur across a save/load boundary, THEN that id is never reassigned
- [ ] AC22 [INT] GIVEN a full arrival→MemberSim→Congestion tick loop over ~200 ticks run against two layouts (one clumped, one spread) with identical seed and equipment set, WHEN flow is measured, THEN the spread layout shows measurably lower average queue occupancy than the clumped one — the end-to-end "layout causally drives flow" hypothesis check

---

## Implementation Notes

*Derived from ADR-0002 + ADR-0004 + ADR-0005 Implementation Guidelines:*

**Serialized state (Core Rule 7):**
- `member_id`, state, cell, cached path + its `grid_version`, `target_equipment_instance_id`, held reservation flags (occupant / next_claimant), `patience_timer`, `exercises_done`, resolved `preference_profile` (store resolved value, not re-derivable seed — avoids RNG-order fragility across save boundary), and global `member_id_counter`
- **`member_id_counter` serialized explicitly** (AC7, AC8) — key divergence from PlacementSystem's self-healing `instance_id` re-derivation
- Reservation map rebuilt from members' own serialized claim flags on load — never serialized as separate truth (avoids desync)

**Spawn / despawn formulas (Core Rule 6, TR-MS-008/009/010):**
- `p_tick = clamp(base_arrival_rate_per_min / 60 × TICK_DURATION_SECONDS × satisfaction_modifier × capacity_gate, 0, 1)` — Bernoulli draw per tick
- `use_duration = round(clamp(randfn(mean, stddev), min, max))` — per-equipment fields from EquipmentCatalog (`use_duration_mean_ticks`, etc.)
- `exercises_per_visit = round(clamp(randfn(mean × visit_length_modifier, stddev), min=1, max=5))` — drawn once on entry

**S5 emission (TR-MS-014):**
- `member_completed_visit(member_id)` emitted ONLY on quota-met departures (exercises_done == exercises_per_visit → LEAVING → GONE)
- Walk-failure and patience-exhausted departures must NOT emit it

**AC22 flow hypothesis:**
- Full tick loop over ~200 ticks, two layouts (clumped vs spread), identical seed + equipment set
- Measure average queue occupancy (via Congestion or reservation map) — spread must be measurably lower
- This is the pillar-1 end-to-end check; advisory for CI but BLOCKING for the epic's Definition of Done

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 001–004]: the state machine internals, target selection, reservations, path/patience logic (this story wires serialization + integration around them)
- congestion epic story 004: Congestion's own serialization

---

## QA Test Cases

*Written by qa-lead at story creation. The developer implements against these — do not invent new test cases during implementation.*

- **AC7**: 计数恢复
  - Given: save with member_id_counter = 42, no active member id ≥ 42
  - When: new member spawns after load
  - Then: member_id == 42 (not max(active)+1)
  - Edge cases: active ids 1..5 with counter 42 — new member gets 42

- **AC8**: 缺失计数即失败
  - Given: load payload missing member_id_counter, or member_id_counter <= max(active member_id)
  - When: load executes
  - Then: fails loudly; never silently substitutes a derived value
  - Edge cases: counter exactly equal to max active id (fails); counter missing entirely (fails)

- **AC9**: 退役 id 不复用
  - Given: GONE member's retired member_id
  - When: any number of later spawns across a save/load boundary
  - Then: that id never reassigned
  - Edge cases: many GONE members, many loads, counter monotonic

- **AC22**: 布局决定人流
  - Given: full arrival→MemberSim→Congestion tick loop, ~200 ticks, two layouts (clumped/spread), identical seed + equipment set
  - When: flow measured
  - Then: spread layout shows measurably lower average queue occupancy than clumped
  - Edge cases: both layouts need ≥2 instances of at least one equipment type (OQ6); compare queue occupancy, not raw member count

---

## Test Evidence

**Story Type**: Integration
**Required evidence**:
- `tests/unit/member_sim/serialization_test.gd` — AC7/AC8/AC9 (must exist and pass)
- `tests/integration/member_sim/flow_hypothesis_test.gd` — AC22 (BLOCKING for epic DoD)

**Status**: [ ] Not yet created

---

## Dependencies

- Depends on: Story 004 (state machine + path/patience complete), save-load epic (two-phase deserialize protocol, `known_instance_ids` derived context), time-system epic (RNG state restore)
- Unlocks: congestion epic (reads member positions), satisfaction epic (reads member events), economy epic (subscribes to S5)
