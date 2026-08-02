# Story 002: Target Selection and Weighted Pick

> **Epic**: member-sim
> **Status**: Ready
> **Layer**: Feature
> **Type**: Logic
> **Estimate**: M — 2 sessions (≤4h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-02

## Context

**GDD**: `design/gdd/member-sim.md`
**Requirement**: `TR-MS-003`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0004 (Seeded RNG); ADR-0005 (Signal Bus & Event Routing)
**ADR Decision Summary**: Target selection consumes `Congestion(t-1)` (the `prev` buffer) as a per-equipment-instance scalar in [0,1]. All randomness via `get_rng("MemberSim")` in a fixed order. Congestion is read as a pre-update value — MemberSim runs before Congestion each tick.

**Engine**: Godot 4.7.1 | **Risk**: LOW
**Engine Notes**: Fixed float-summation order matters for determinism — never sum weights in hash/insertion order.

**Control Manifest Rules (Feature layer)**:
- Required: `member_completed_visit(member_id)` (S5) owned by MemberSim, fired only on quota-met departures
- Forbidden: No mid-tick yielding in on_tick
- Guardrail: Top-K candidate cap (K = 3–5) prevents O(members × equipment) pathfinding

---

## Acceptance Criteria

*From GDD `design/gdd/member-sim.md`, scoped to this story:*

- [ ] AC10 GIVEN two candidates identical except `Congestion(t-1)` (A=0.1, B=0.8), WHEN `target_selection_weight` is computed, THEN `weight_A > weight_B` — strictly monotonic in congestion across a swept range
- [ ] AC11 [UNIT]+[INT] GIVEN Congestion for E is updated during the current tick's Congestion pass, WHEN a member runs SELECTING_TARGET in the *same* tick, THEN the weight uses the pre-update (t-1) value; the [INT] part asserts MemberSim's registered tick order runs before Congestion's
- [ ] AC12 GIVEN every equipment has `Congestion(t-1) = 1.0` (fully congested), WHEN weights are computed, THEN all weights are > 0 (no divide-by-zero, no NaN) and Σ P_i = 1.0
- [ ] AC20 GIVEN top-K candidate selection where two candidates have equal weight, WHEN they are sorted, THEN the tie-break is by ascending `equipment_instance_id` (deterministic)

---

## Implementation Notes

*Derived from ADR-0004 + ADR-0005 Implementation Guidelines:*

**Target selection algorithm (Core Rule 3) — fixed order:**
1. Build candidate pool: equipment matching member interest, excluding fully-spoken-for equipment (reservation `next_claimant` held by another) and short-term no-repeat blacklist
2. Compute `target_selection_weight` per candidate: `weight_i = base_weight × exp(-k_congestion × Congestion_i(t-1)) × exp(-k_proximity × dist_i / D_max) × novelty_factor_i × pref_noise_i`
3. Sort by weight descending, deterministic tie-break by ascending `equipment_instance_id`; take top-K (K = 3–5)
4. Path-check the K in ascending `equipment_instance_id` order via `Navigation.get_path`; drop unreachable; renormalize weights over survivors
5. Weighted-random draw over survivors using one `rng.randf()`
6. Attempt reservation claim (Story 003 handles the map; here the call boundary)

**Weight formula details:**
- `novelty_factor_i` ∈ {0.2 just-used, 0.6 recent, 1.0} — suppresses repeating same machine
- `pref_noise_i` ∈ Uniform(0.85, 1.15) — per-member seeded randomness
- **Epsilon floor** on weights — weights stay strictly positive (never 0, no divide-by-zero, no NaN) — AC12
- `k_congestion = 3` (tune 2–5), `k_proximity = 0.2` (tune 0.1–0.3), `D_max ≈ 16`
- Monotonic in congestion: strictly decreasing weight as `Congestion_i(t-1)` rises — AC10

**t-1 read (AC11):**
- The weight uses the `prev` buffer value — MemberSim never reads the `next` being written later in the same tick
- Verify tick order via the integration test: MemberSim.on_tick() runs before Congestion.on_tick() in `_advance_tick()`

**Tie-break (AC20):**
- Equal weights resolve by ascending `equipment_instance_id` — sort must be stable/deterministic

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 001]: lifecycle state machine skeleton, spawn/despawn, capacity gate
- [Story 003]: reservation map internals, contention resolution, release invariant
- [Story 004]: path invalidation, patience give-up, mid-use interrupts

---

## QA Test Cases

*Written by qa-lead at story creation. The developer implements against these — do not invent new test cases during implementation.*

- **AC10**: 拥挤度单调性
  - Given: two candidates identical except Congestion(t-1), A=0.1 vs B=0.8
  - When: target_selection_weight computed
  - Then: weight_A > weight_B; strict monotonic across a swept congestion range (e.g. 0, 0.25, 0.5, 0.75, 1.0)
  - Edge cases: congestion values at extremes (0.0 and 1.0); both still produce positive weights

- **AC11**: t-1 读取
  - Given: Congestion for E updated during current tick's Congestion pass
  - When: member runs SELECTING_TARGET in the same tick
  - Then: weight uses pre-update (t-1) value; [INT] MemberSim tick order before Congestion
  - Edge cases: congestion changes exactly at tick boundary

- **AC12**: 全拥挤非零权重
  - Given: every equipment has Congestion(t-1) = 1.0
  - When: weights computed
  - Then: all weights > 0; Σ P_i = 1.0 (within float tolerance); no NaN
  - Edge cases: empty candidate pool after path-check (renormalize over zero survivors — handle gracefully)

- **AC20**: 平局决胜
  - Given: two candidates with equal weight in top-K
  - When: sorted
  - Then: tie-break by ascending equipment_instance_id
  - Edge cases: 3+ candidates all equal weight — deterministic ascending id order

---

## Test Evidence

**Story Type**: Logic
**Required evidence**:
- `tests/unit/member_sim/target_selection_weight_test.gd` — must exist and pass
- `tests/unit/member_sim/tick_order_test.gd` — integration-style unit asserting MemberSim before Congestion

**Status**: [ ] Not yet created

---

## Dependencies

- Depends on: Story 001 (state machine core — SELECTING_TARGET entry), congestion epic story 001 (`per_equipment_congestion(id)` prev buffer read), navigation epic (`get_path`)
- Unlocks: Story 003 (reservation contention — claim on selection), Story 004 (patience give-up re-selection)
