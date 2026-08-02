# Story 001: Per-Equipment Congestion Scalar + EMA

> **Epic**: congestion
> **Status**: Ready
> **Layer**: Feature
> **Type**: Logic
> **Estimate**: M — 2 sessions (≤4h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-02

## Context

**GDD**: `design/gdd/congestion.md`
**Requirement**: `TR-CONG-001`, `TR-CONG-002`, `TR-CONG-003`, `TR-CONG-009`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0005 (Signal Bus & Event Routing)
**ADR Decision Summary**: Congestion runs SECOND each tick (after MemberSim, before Satisfaction). It is a pure function of member state — NO RNG. Double-buffering: `prev` (read-only `Congestion(t-1)`) and `next` (write target); a single swap `prev ← next` after all entities are processed — the concrete mechanism of the `Congestion(t-1) → routing(t)` feedback loop.

**Engine**: Godot 4.7.1 | **Risk**: LOW
**Engine Notes**: `per_equipment_congestion(id) -> float` and `per_cell_density(cell) -> float` are public read methods. Fixed float-summation order is mandatory for determinism (ascending equipment_instance_id).

**Control Manifest Rules (Feature layer)**:
- Required: `congestion_updated()` (S8) — zero payload, emitted once per tick after recompute
- Required: fixed tick order MemberSim → Congestion → Satisfaction → Economy
- Forbidden: no RNG in Congestion (pure function of member state)
- Forbidden: no mid-tick yielding

---

## Acceptance Criteria

*From GDD `design/gdd/congestion.md`, scoped to this story:*

- [ ] AC3 GIVEN any `occupancy_state ∈ {0,1,2}` and any `N_i ≥ 0`, WHEN `per_equipment_congestion` is computed, THEN the result is a finite float in `[0,1]` — never NaN, negative, or > 1
- [ ] AC5 GIVEN `prev` holds `Congestion_i(t-1) = X`, WHEN MemberSim runs at tick `t` (before Congestion), THEN MemberSim reads exactly `X`, unaffected by any writes to `next` later in tick `t`
- [ ] AC6 [WB] GIVEN Congestion is mid-computation at tick `t` (some equipment processed, some not), WHEN a consumer queries `per_equipment_congestion` in that window, THEN every entry returned is from `prev` (t-1) — never a prev/next mix
- [ ] AC7 GIVEN `Congestion_i(t-1) = C0` and a `raw_i` at either extreme (0 or 1), WHEN `Congestion_i(t)` is computed with `α=0.3`, THEN `|Congestion_i(t) − C0| ≤ 0.3` exactly
- [ ] AC8 GIVEN `occupancy_state=0` and `N_i=0` sustained for 9+ consecutive ticks (`(1-α)^n < 0.05` at `α=0.3`), WHEN `Congestion_i` is sampled, THEN `Congestion_i < 0.05`
- [ ] AC10 GIVEN a queue attempts to exceed 1 waiting member, WHEN `occupancy_state` is read, THEN it never exceeds 2
- [ ] AC11 GIVEN member M is the `occupant` or `next_claimant` of E, WHEN `N_i` is computed within radius R, THEN M is excluded even if physically within R

---

## Implementation Notes

*Derived from ADR-0005 Implementation Guidelines:*

**Core Rule 1 & 2 — tick order + double buffer:**
- `on_tick(tick_context)` invoked after MemberSim; reads post-move member positions/states
- Two persistent structures: `prev` (authoritative `Congestion(t-1)`, read-only during tick t) and `next` (write target)
- Sequence each tick: compute each equipment's `raw_i(t)` from post-move state, EMA-blend against `prev[i]`, write into `next[i]`; after ALL entities processed, single swap `prev ← next`

**Core Rule 3 — per-equipment scalar:**
- `occ_i(t) = occupancy_state_i(t) / 2` (tier {0,1,2} → {0, 0.5, 1.0})
- `dens_i(t) = clamp(N_i(t) / D_max, 0, 1)` — N_i = members within radius R of access cell, EXCLUDING occupant/next_claimant (no double-count, AC11)
- `raw_i(t) = clamp(w_occ · occ_i(t) + w_dense · dens_i(t), 0, 1)`
- `Congestion_i(t) = clamp(α · raw_i(t) + (1 − α) · Congestion_i(t−1), 0, 1)`
- Knobs: `w_occ=0.7, w_dense=0.3, α=0.3, R=1-2, D_max=3`
- Hard-clamp [0,1] at both raw_i and EMA step (defensive)

**AC5/AC6 — the prev/next contract:**
- MemberSim reads `prev` only — never a prev/next mix mid-computation
- Public queries (`per_equipment_congestion(id)`) serve from `prev` during the whole tick; `next` is internal until the swap

**AC7/AC8 — EMA bounds:**
- With α=0.3, a single tick moves at most 0.3 from C0
- After 9+ idle ticks, value decays below 0.05

**AC10 — queue cap:**
- `occupancy_state` derives from MemberSim's reservation map (occupant + next_claimant, queue depth 1 MVP) → max tier 2

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 002]: per-cell density field (kernel splat + EMA)
- [Story 003]: `access_reachable` flag, grid_changed handling, equipment removal
- [Story 004]: serialization of prev + per-cell smoothed, determinism gate

---

## QA Test Cases

*Written by qa-lead at story creation. The developer implements against these — do not invent new test cases during implementation.*

- **AC3**: 范围守卫
  - Given: any occupancy_state ∈ {0,1,2}, any N_i ≥ 0
  - When: per_equipment_congestion computed
  - Then: result finite float in [0,1]; never NaN, negative, or > 1
  - Edge cases: N_i huge, occupancy 0 with N_i 0, occupancy 2 with N_i large

- **AC5**: t-1 读取
  - Given: prev holds Congestion_i(t-1) = X
  - When: MemberSim runs at tick t before Congestion
  - Then: MemberSim reads exactly X, unaffected by next writes later in tick t
  - Edge cases: X = 0.0, X = 1.0, X = mid-value with next being written

- **AC6**: 中途查询 prev
  - Given: Congestion mid-computation (some equipment processed, some not)
  - When: consumer queries per_equipment_congestion in that window
  - Then: every entry from prev (t-1); never prev/next mix
  - Edge cases: query during swap itself (still prev)

- **AC7**: EMA 单步界
  - Given: Congestion_i(t-1) = C0, raw_i at 0 or 1
  - When: Congestion_i(t) computed with α=0.3
  - Then: |Congestion_i(t) − C0| ≤ 0.3 exactly
  - Edge cases: C0 = 0.5, raw = 1 → result 0.65 (diff 0.15 ≤ 0.3); C0 = 0.9, raw = 0 → 0.63 (diff 0.27)

- **AC8**: 衰减
  - Given: occupancy_state=0, N_i=0 sustained 9+ consecutive ticks
  - When: Congestion_i sampled
  - Then: Congestion_i < 0.05
  - Edge cases: exactly 9 ticks vs 10 ticks; value never snaps to 0 instantly

- **AC10**: 队列深度
  - Given: queue attempts to exceed 1 waiting member
  - When: occupancy_state read
  - Then: never exceeds 2
  - Edge cases: occupant + 1 claimant (tier 2); occupant only (tier 1)

- **AC11**: 排除 occupant/claimant
  - Given: member M is occupant or next_claimant of E
  - When: N_i computed within radius R
  - Then: M excluded even if physically within R
  - Edge cases: M is both occupant AND within R; other loiterers still counted

---

## Test Evidence

**Story Type**: Logic
**Required evidence**:
- `tests/unit/congestion/per_equipment_scalar_test.gd` — must exist and pass

**Status**: [ ] Not yet created

---

## Dependencies

- Depends on: member-sim epic story 005 (post-move member state + reservation map), navigation epic (`get_path` for reachability — story 003 uses it), time-system epic (tick dispatch)
- Unlocks: Story 002 (density field), Story 003 (access_reachable), Story 004 (serialization)
