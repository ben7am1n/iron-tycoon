# Story 001: Member Accumulators and use_quality

> **Epic**: satisfaction
> **Status**: In Review
> **Layer**: Feature
> **Type**: Logic
> **Estimate**: M — 2 sessions (≤4h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-03

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

- [x] AC5 Monotonicity — congestion: GIVEN all else fixed, WHEN `Congestion_i(t-1)` for a used instance increases, THEN the using member's `S_member` strictly decreases
- [x] AC6 Monotonicity — synergy: GIVEN all else fixed, WHEN `zone_synergy_i` (hence `total_i`) increases, THEN the using member's `S_member` strictly increases
- [x] AC8 Bounds/clamping: GIVEN any inputs, WHEN computed, THEN `use_quality_i ∈ [−0.5, 0.5]`, `S_member ∈ [0,1]`, `global_satisfaction ∈ [0,1]`
- [x] AC9 Symmetric use signal: GIVEN a perfect use (`total_i` at cap, `Congestion=0`) and a worst use (`total_i=0`, `Congestion=1`), WHEN `use_quality` is computed, THEN the two are `+0.5` and `−0.5` (equal and opposite — neither pull nor push dominates)
- [x] AC10 Zero-use member baseline: GIVEN a member with `n_uses = 0` AND `n_fail = 0` AND `queue_ticks = 0` AND `n_interrupt = 0`, WHEN `S_member` is computed, THEN `avg(use_quality) = 0`, no NaN/exception, and `S_member == S_base == 0.5`

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

**Status**: [x] Complete — use_quality_test.gd 31 asserts all green (see commit message / headless suite 2843/0).

### Implementation summary (SAT-001)

- `src/systems/satisfaction.gd` replaced the SL-002 stub, preserving the SimSystem
  contract exactly: `class_name`, `init(orchestrator, seeded_rng)` with extra
  OPTIONAL params (member_sim, congestion_reader, zone_total_reader Callable,
  config), `system_name() == "Satisfaction"`, `on_tick(tick_count)`,
  `serialize()/deserialize(data, validate_only)` two-phase returning
  `StubDeserializeResult`. Serialize shape stays the stub-era `{counter, rng_state}`
  — story-004 owns the extended shape (member_accumulators + global_satisfaction).
- **No RNG** (TR-SAT-001): sub-stream registered (save-load AC7 contract) but never
  drawn — same pattern as Economy. Pre-wiring rigs (`init(orch, srg)` only) keep the
  stub's `counter += 1` observable; the configured path reads MemberSim's roster
  directly (ADR-0005 §3 note — no signal subscription).
- `member_accumulators[member_id] = {S_acc, n_uses, queue_ticks, n_fail, n_interrupt}`
  (TR-SAT-002) — created on entry, updated from events, folded into
  `global_satisfaction` and discarded on departure. Roster-diff detects all
  departures (including walk-failure / patience-exhaust, which S5 quota-met-only
  would miss); iteration is ascending member_id (Core Rule 8).
- `use_quality_i = w_zone × clamp(total_i / Z_NORM, 0, 1) − w_cong × Congestion_i(t-1)`
  (TR-SAT-003), w_zone = w_cong = 0.5, Z_NORM = 2.0. `Congestion_i(t-1)` is snapshotted
  ONCE at use-start (pending-use record), never re-read at completion — the "read t-1"
  rule verified by the AC5 "use at start vs mid-visit" test. `total_i` consumed via the
  injected `zone_total_reader` Callable (wired to ZoneRules.evaluate per-instance
  dict's `total` — per equipment a member actually used, not a smeared average).
- S_member (Core Rule 4) + the global EMA fold (Core Rule 5, α_g = 0.05 configurable)
  are landed here because the story-001 QA cases (AC5/6/8/10) exercise them; story-002
  adds the penalty-cap test file (AC11/12) and story-003 adds the modifier functions +
  dedicated EMA tests.
- Deviations documented: S_member formula and the global EMA fold landed in story 001
  (needed by the blocking ACs' QA cases), serialization of accumulators deferred to
  story 004.

---

## Dependencies

- Depends on: zone-rules epic (per-instance effect dict), congestion epic story 001/004 (`Congestion_i(t-1)` scalar), member-sim epic story 005 (member events), time-system epic (tick dispatch)
- Unlocks: Story 002 (S_member), Story 003 (global EMA + modifiers)
