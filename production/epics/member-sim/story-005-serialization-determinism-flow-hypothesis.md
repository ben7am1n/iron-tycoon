# Story 005: Serialization, Determinism and Flow Hypothesis

> **Epic**: member-sim
> **Status**: Complete — 2026-08-02
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

- [x] AC7 [INT] GIVEN a save with `member_id_counter = 42` and no active member id ≥ 42, WHEN a new member spawns after load, THEN its `member_id` is 42 (not `max(active)+1`)
- [x] AC8 [UNIT] GIVEN a load payload missing `member_id_counter` or with `member_id_counter <= max(active member_id)`, WHEN load executes, THEN it fails loudly, never silently substituting a derived value
- [x] AC9 [UNIT] GIVEN a GONE member's retired `member_id`, WHEN any number of later spawns occur across a save/load boundary, THEN that id is never reassigned
- [x] AC22 [INT] GIVEN a full arrival→MemberSim→Congestion tick loop over ~200 ticks run against two layouts (one clumped, one spread) with identical seed and equipment set, WHEN flow is measured, THEN the spread layout shows measurably lower average queue occupancy than the clumped one — the end-to-end "layout causally drives flow" hypothesis check

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

**Status**: [x] Complete — 2026-08-02

Both files exist and pass; registered in `tests/headless_runner.gd` TEST_FILES.
Full headless suite: 2636 passed / 0 failed (baseline 2568 + 68 new
assertions: 56 serialization + 12 flow hypothesis), 0 SCRIPT ERROR, run
twice with identical per-file results.

`serialization_test.gd` (56 assertions): AC7 counter restore (direct
deserialize AND the full SaveLoad blob pipeline — spawn after load gets
exactly 42), AC8 missing/illegal counter fails loudly (validate AND commit,
zero mutation; legacy SL-002-era entries exempt), AC9 retired ids never
reassigned (real GONE cycle + multi-load monotonic sweep), reservation-map
rebuild from claim flags (USING+QUEUEING handoff continues, WALKING_TO
rebuild, load-side AC4 double-claim rejection), JSON.stringify/parse
round-trip (Vector2i cells restored, int fields coerced from JSON floats,
int-keyed blacklists, rebuilt map consistent with member states), and
serialize() purity/determinism.

`flow_hypothesis_test.gd` (12 assertions): AC22 over 200 ticks
(30 warm-up + 170 measured), 3 identical seeds, clumped vs spread (4
treadmill instances each — OQ6). Per-seed spread < clumped AND <= 0.9x
clumped; aggregate reduction 72% (clumped mean 0.339 vs spread mean 0.096
queue-occupancy). Determinism: same seed + layout -> identical averages.

---

## Deviations (documented, not silent)

1. **AC8 counter-vs-max check scope — state-machine members only.**
   The check `member_id_counter <= max(active member_id) -> fail` applies
   to records carrying a `"state"` key (the state machine's members — the
   ids the counter actually allocated). Legacy SL-002-era stub entries
   (`{member_id, equipment_instance_id}`, no state) are passive roster data
   that was never allocated from the counter, so they are EXEMPT. Without
   this, the pre-wiring save-load integration blobs (counter 0 with
   hand-assigned ids 10/11 — SL-003 roundtrip canary, SL-002 load
   orchestration) would fail their loads. The QA's "counter exactly equal
   to max active id fails" is enforced for every state-machine payload.
2. **AC22 Congestion is a test-local double, not the real system.**
   Congestion (#7) does not exist in src/ yet (congestion epic story 001).
   The test injects a small proximity-based double honoring the AC11 /
   TR-CONG-002 contract: MemberSim reads `per_equipment_congestion(id)`
   from a `prev` buffer (one-tick lag) during its on_tick(); the test
   recomputes `next` from member positions after MemberSim and swaps —
   mirroring the real fixed tick order. congestion(id) = min(1, members
   within Chebyshev radius 2 of the access cell / 2) — the "local density"
   term of the GDD's per-equipment congestion formula. The real Congestion
   story must keep this read surface (`per_equipment_congestion(int)`)
   compatible.
3. **`equipment_id_resolver` seam (TR-MS-009).** GridSystem stores only
   integer occupant_id (PlacedInstance.equipment_id is ""), so instance ->
   equipment_id resolution cannot come from the grid. MemberSim.init()
   gained an OPTIONAL 10th parameter: `equipment_id_resolver: Callable`
   (instance_id -> equipment_id), wired by the composition root. When
   present and resolving to a catalog def, `_roll_use_duration` reads the
   def's per-equipment use_duration_* fields (exactly ONE rng draw per use
   start — determinism preserved); absent resolver falls back to the
   config defaults (pre-wiring rigs unchanged).
4. **JSON-safe cell encoding in serialize().** Members' `cell` and
   `cached_path` are emitted as `[x, y]` arrays (same convention as
   GridSystem._serialize_cells) instead of raw Vector2i, so the blob
   survives JSON.stringify/parse with no type ambiguity. deserialize()
   restores Vector2i and coerces ints (JSON.parse returns floats for
   integer literals in 4.7.1) and numeric-string dictionary keys
   (give_up_blacklist). Legacy member records pass through verbatim —
   the SL-003 byte-identical round-trip canary is preserved.
5. **Load-side AC4 mirror.** A payload where two members claim the same
   machine's occupant or queue slot is structurally corrupt (the live
   machine can never produce it) and fails Phase A — extending the
   runtime AC4 capacity invariant to the serialized state.

---

## Dependencies

- Depends on: Story 004 (state machine + path/patience complete), save-load epic (two-phase deserialize protocol, `known_instance_ids` derived context), time-system epic (RNG state restore)
- Unlocks: congestion epic (reads member positions), satisfaction epic (reads member events), economy epic (subscribes to S5)
