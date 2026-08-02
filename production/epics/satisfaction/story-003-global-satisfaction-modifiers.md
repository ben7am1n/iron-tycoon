# Story 003: global_satisfaction and Modifiers

> **Epic**: satisfaction
> **Status**: Ready
> **Layer**: Feature
> **Type**: Logic
> **Estimate**: M — 2 sessions (≤4h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-02

## Context

**GDD**: `design/gdd/satisfaction.md`
**Requirement**: `TR-SAT-005`, `TR-SAT-006`, `TR-SAT-007`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0005 (Signal Bus & Event Routing)
**ADR Decision Summary**: `global_satisfaction` is a slow event-driven EMA (α_g = 0.05), updated only on member departure, init 0.5, no silent decay. `satisfaction_modifier ∈ [0.5, 2.0]` piecewise-linear, floors at 0.5 (never 0 — anti-death-spiral). `visit_length_modifier = 1 + (satisfaction_modifier − 1) × damp`, damp = 0.5, range [0.75, 1.5] — the damped leg drives MemberSim's exercises_per_visit (prevents ~modifier² occupancy oscillation).

**Engine**: Godot 4.7.1 | **Risk**: LOW
**Engine Notes**: No RNG; deterministic. Multiple departures on one tick fold in ascending member_id order.

**Control Manifest Rules (Feature layer)**:
- Required: fixed tick order; no RNG; no mid-tick yielding
- Required: MemberSim consumes `visit_length_modifier` (not raw satisfaction_modifier) for exercises_per_visit
- Guardrail: anti-death-spiral floor — modifier never 0

---

## Acceptance Criteria

*From GDD `design/gdd/satisfaction.md`, scoped to this story:*

- [ ] AC2 Modifier bounds + anti-spiral floor: GIVEN any `G ∈ [0,1]`, WHEN `satisfaction_modifier(clamp(G, 0, 1))` is computed, THEN it ∈ `[0.5, 2.0]`, and at `G = 0` it is **strictly 0.5** (never 0). Input defensively clamped to `[0,1]` before the piecewise formula
- [ ] AC3 Neutral continuity: GIVEN `G = 0.5`, WHEN `satisfaction_modifier` is computed, THEN it equals exactly `1.0` (seamless with MemberSim's placeholder)
- [ ] AC4 Visit modifier damping: GIVEN any `G`, WHEN `visit_length_modifier(G)` is computed, THEN it ∈ `[0.75, 1.5]` and its deviation from 1.0 is exactly half that of `satisfaction_modifier(G)`
- [ ] AC7 Monotonicity — modifier: GIVEN two satisfaction values `G1 < G2`, WHEN modifiers are computed, THEN `satisfaction_modifier(G1) ≤ satisfaction_modifier(G2)` (non-decreasing)
- [ ] AC13 Deterministic multi-departure: GIVEN multiple members departing on one tick, WHEN folded into `global_satisfaction`, THEN they fold in ascending `member_id` order (reproducible)
- [ ] AC14 No silent drift: GIVEN a tick with no departures, WHEN it processes, THEN `global_satisfaction(t) == global_satisfaction(t-1)` bit-for-bit
- [ ] AC16 Defensive modifier clamp: GIVEN `G` outside `[0,1]` (e.g., due to an upstream bug), WHEN `satisfaction_modifier(G)` is computed, THEN input is clamped to `[0,1]` before the piecewise formula, and the anti-spiral guarantee (`modifier ≥ 0.5`) holds

---

## Implementation Notes

*Derived from ADR-0005 Implementation Guidelines:*

**Core Rule 5 — global EMA:**
- On each departure: `global_satisfaction(t) = α_g × S_member_departing + (1 − α_g) × global_satisfaction(t-1)`
- α_g = 0.05 (safe 0.02–0.15); init 0.5
- Ticks with no departure: unchanged (no silent decay — AC14)
- Multiple departures on one tick fold in ascending member_id order (AC13)

**Core Rule 6 — modifiers (fulfills MemberSim OQ3):**
```
G_c = clamp(G, 0, 1)  # defensive — AC16
satisfaction_modifier(G_c) = G_c + 0.5  if G_c < 0.5
                             = 2·G_c     if G_c ≥ 0.5
# range [0.5, 2.0]; G_c=0.5 → 1.0 (AC3)
visit_length_modifier(G) = 1 + (satisfaction_modifier(G) − 1) × damp, damp = 0.5
# range [0.75, 1.5] — deviation exactly half (AC4)
```
- `satisfaction_modifier` floors at 0.5 (G=0 → 0.5 strictly — AC2) — the anti-death-spiral mechanism
- `visit_length_modifier` drives MemberSim's exercises_per_visit (damped leg — prevents modifier² occupancy)

**Core Rule 7 — self-correcting loop:**
- Low satisfaction → fewer members → less congestion → satisfaction recovers
- Modifier floor (0.5) + MemberSim's exercises_per_visit ≥ 1 floor guarantee the recovery loop stays observable

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 001]: accumulator structure + use_quality
- [Story 002]: S_member formula + penalty caps
- [Story 004]: serialization + determinism + recovery loop integration

---

## QA Test Cases

*Written by qa-lead at story creation. The developer implements against these — do not invent new test cases during implementation.*

- **AC2**: 修改器边界 + 防螺旋
  - Given: any G ∈ [0,1]
  - When: satisfaction_modifier(clamp(G, 0, 1)) computed
  - Then: ∈ [0.5, 2.0]; at G=0 strictly 0.5 (never 0)
  - Edge cases: G=0, G=0.5, G=1.0, G just below/above 0.5

- **AC3**: 中性连续
  - Given: G = 0.5
  - When: satisfaction_modifier computed
  - Then: exactly 1.0 (seamless with MemberSim placeholder)
  - Edge cases: G=0.4999 vs 0.5 vs 0.5001 — no jump at boundary

- **AC4**: 访问长度阻尼
  - Given: any G
  - When: visit_length_modifier(G) computed
  - Then: ∈ [0.75, 1.5]; deviation from 1.0 exactly half of satisfaction_modifier's
  - Edge cases: G=0 → visit 0.75; G=1 → visit 1.5; G=0.5 → 1.0

- **AC7**: 单调
  - Given: G1 < G2
  - When: modifiers computed
  - Then: satisfaction_modifier(G1) ≤ satisfaction_modifier(G2) (non-decreasing)
  - Edge cases: G1=0.49, G2=0.51 (across piecewise boundary — non-decreasing)

- **AC13**: 多会员折入序
  - Given: multiple members departing on one tick
  - When: folded into global_satisfaction
  - Then: fold in ascending member_id order (reproducible)
  - Edge cases: member ids non-contiguous; same-tick departures with different S_member

- **AC14**: 无漂移
  - Given: tick with no departures
  - When: processes
  - Then: global_satisfaction(t) == global_satisfaction(t-1) bit-for-bit
  - Edge cases: many consecutive no-departure ticks

- **AC16**: 防御钳制
  - Given: G outside [0,1] (upstream bug)
  - When: satisfaction_modifier(G) computed
  - Then: input clamped to [0,1] before piecewise; modifier ≥ 0.5 holds
  - Edge cases: G=-1, G=2.5, G=NaN (must not crash — handle defensively)

---

## Test Evidence

**Story Type**: Logic
**Required evidence**:
- `tests/unit/satisfaction/global_satisfaction_modifiers_test.gd` — must exist and pass (AC2, AC3, AC4, AC7, AC13, AC14, AC16)

**Status**: [ ] Not yet created

---

## Dependencies

- Depends on: Story 002 (S_member feeding the EMA), member-sim epic story 005 (departure events)
- Unlocks: Story 004 (serialization of global_satisfaction), MemberSim OQ3 closure (modifier wiring)
