# Story 001: Member Accumulators and use_quality

> **Epic**: satisfaction
> **Status**: Ready
> **Layer**: Feature
> **Type**: Logic
> **Estimate**: M — 2 sessions (≤4h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-02

## Context

**GDD**: `design/gdd/satisfaction.md`
**Requirement**: `TR-SAT-001`, `TR-SAT-002`, `TR-SAT-003`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0003 (GridStateReader Contract); ADR-0005 (Signal Bus & Event Routing)
**ADR Decision Summary**: Satisfaction runs in TimeSystem's fixed order AFTER Congestion (so it can read `Congestion(t-1)`), uses NO RNG, fully deterministic. Maintains `member_accumulators: Dictionary[member_id -> Accumulator]` where `Accumulator = {S_acc, n_uses, queue_ticks, n_fail, n_interrupt}`. `use_quality_i = w_zone × clamp(total_i / Z_NORM, 0, 1) − w_cong × Congestion_i(t-1)` with equal weights.

**Engine**: Godot 4.7.1 | **Risk**: LOW
**Engine Notes**: `JSON.stringify(full_precision=true)` for bit-exact float round-trip of global_satisfaction (ADR-0002).

**Control Manifest Rules (Feature layer)**:
- Required: fixed tick order MemberSim → Congestion → Satisfaction → Economy
- Required: two-phase deserialize; floats need full_precision
- Forbidden: no RNG in Satisfaction; no mid-tick yielding

---

## Acceptance Criteria

*From GDD `design/gdd/satisfaction.md`, scoped to this story:*

- [ ] AC5 Monotonicity — congestion: GIVEN all else fixed, WHEN `Congestion_i(t-1)` for a used instance increases, THEN the using member's `S_member` strictly decreases
- [ ] AC6 Monotonicity — synergy: GIVEN all else fixed, WHEN `zone_synergy_i` (hence `total_i`) increases, THEN the using member's `S_member` strictly increases
- [ ] AC8 Bounds/clamping: GIVEN any inputs, WHEN computed, THEN `use_quality_i ∈ [−0.5, 0.5]`, `S_member ∈ [0,1]`, `global_satisfaction ∈ [0,1]`
- [ ] AC9 Symmetric use signal: GIVEN a perfect use (`total_i` at cap, `Congestion=0`) and a worst use (`total_i=0`, `Congestion=1`), WHEN `use_quality` is computed, THEN the two are `+0.5` and `−0.5` (equal and opposite — neither pull nor push dominates)
- [ ] AC10 Zero-use member baseline: GIVEN a member with `n_uses = 0` AND `n_fail = 0` AND `queue_ticks = 0` AND `n_interrupt = 0`, WHEN `S_member` is computed, THEN `avg(use_quality) = 0`, no NaN/exception, and `S_member == S_base == 0.5`

---

## Implementation Notes

*Derived from ADR-0003 + ADR-0005 Implementation Guidelines:*

**Core Rule 2 — per-member accumulation (owned here, not MemberSim):**
- `member_accumulators: Dictionary[member_id -> Accumulator]`, `Accumulator = {S_acc, n_uses, queue_ticks, n_fail, n_interrupt}`
- Create accumulator when MemberSim signals a member entered; update from events; on departure compute final `S_member`, fold into global meter, discard
- Dictionary is serialized (same granularity as MemberSim's reservations/member_id_counter)

**Core Rule 3 — use_quality (the pull-vs-push resolution):**
- `use_quality_i = w_zone × clamp(total_i / Z_NORM, 0, 1) − w_cong × Congestion_i(t-1)`
- `w_zone = w_cong = 0.5` (equal — neither "cluster for synergy" nor "spread for flow" dominates a single use)
- `total_i` from ZoneRules per-instance dict `{comfort, zone_synergy, spaciousness, total}` (consumed directly, per equipment a member actually used — not a smeared average)
- `Congestion_i(t-1)` read as single snapshot at the moment the member STARTS using i (consistent with project-wide "read t-1" rule), not integrated over the use
- `Z_NORM = 2.0`
- Output [−0.5, +0.5] — symmetric (AC9)

**Tick structure:**
- `on_tick(tick_context)` after Congestion; reads ZoneRules outputs + Congestion scalar + MemberSim events (direct method reads during its on_tick, per ADR-0005 §3 note)
- No RNG — deterministic by construction

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 002]: S_member formula + penalty caps
- [Story 003]: global_satisfaction EMA + satisfaction_modifier/visit_length_modifier
- [Story 004]: serialization + determinism + recovery loop integration

---

## QA Test Cases

*Written by qa-lead at story creation. The developer implements against these — do not invent new test cases during implementation.*

- **AC5**: 拥挤单调性
  - Given: all else fixed, Congestion_i(t-1) increases
  - When: S_member computed
  - Then: using member's S_member strictly decreases
  - Edge cases: congestion sweep 0 → 1; use at start vs mid-visit

- **AC6**: 协同单调性
  - Given: all else fixed, zone_synergy_i (hence total_i) increases
  - When: S_member computed
  - Then: using member's S_member strictly increases
  - Edge cases: total_i sweep 0 → Z_NORM cap; comfort/spaciousness contributions

- **AC8**: 边界钳制
  - Given: any inputs
  - When: computed
  - Then: use_quality_i ∈ [−0.5, 0.5], S_member ∈ [0,1], global_satisfaction ∈ [0,1]
  - Edge cases: total_i = 0 + congestion = 1 (worst); total_i at cap + congestion = 0 (best)

- **AC9**: 对称信号
  - Given: perfect use (total_i at cap, Congestion=0) and worst use (total_i=0, Congestion=1)
  - When: use_quality computed
  - Then: +0.5 and −0.5 (equal and opposite)
  - Edge cases: mid values — symmetric around 0

- **AC10**: 零使用基线
  - Given: member with n_uses=0, n_fail=0, queue_ticks=0, n_interrupt=0
  - When: S_member computed
  - Then: avg(use_quality)=0, no NaN/exception, S_member == S_base == 0.5
  - Edge cases: n_uses=0 with nonzero penalties (S_member = S_base − penalties, clamped ≥ 0)

---

## Test Evidence

**Story Type**: Logic
**Required evidence**:
- `tests/unit/satisfaction/use_quality_test.gd` — must exist and pass (AC5, AC6, AC8, AC9, AC10)

**Status**: [ ] Not yet created

---

## Dependencies

- Depends on: zone-rules epic (per-instance effect dict), congestion epic story 001/004 (`Congestion_i(t-1)` scalar), member-sim epic story 005 (member events), time-system epic (tick dispatch)
- Unlocks: Story 002 (S_member), Story 003 (global EMA + modifiers)
