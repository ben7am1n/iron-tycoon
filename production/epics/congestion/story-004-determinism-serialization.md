# Story 004: Determinism and Serialization

> **Epic**: congestion
> **Status**: Ready
> **Layer**: Feature
> **Type**: Integration
> **Estimate**: M — 2 sessions (≤4h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-02

## Context

**GDD**: `design/gdd/congestion.md`
**Requirement**: `TR-CONG-006`, `TR-CONG-007`, `TR-CONG-008`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0002 (Storage Format); ADR-0005 (Signal Bus & Event Routing)
**ADR Decision Summary**: Serialize only `prev` (per-equipment scalars) and per-cell `smoothed` values — `next` is transient and fully reconstructible the following tick. `access_reachable` is NOT serialized — recomputed from restored grid on first post-load `grid_changed` (or one-shot recompute on load). Determinism: fixed float-summation order (ascending cell index / ascending equipment_instance_id).

**Engine**: Godot 4.7.1 | **Risk**: LOW
**Engine Notes**: `JSON.stringify(full_precision=true)` for bit-exact float round-trip of smoothed values (ADR-0002).

**Control Manifest Rules (Feature layer)**:
- Required: two-phase deserialize (Phase A validate zero-mutation, Phase B commit)
- Required: `congestion_updated()` (S8) emitted once per tick after recompute
- Forbidden: never serialise RNG state (Congestion has no RNG)
- Forbidden: no mid-tick yielding

---

## Acceptance Criteria

*From GDD `design/gdd/congestion.md`, scoped to this story:*

- [ ] AC1 GIVEN an identical fixed sequence of member states across N ticks, WHEN Congestion processes it twice, THEN `per_equipment_congestion`, `per_cell_density`, and `access_reachable` are bit-identical run-to-run
- [ ] AC2 [WB] GIVEN the Congestion source, WHEN statically inspected, THEN it contains zero `randi`/`randf`/`RandomNumberGenerator` calls (static/grep check)
- [ ] AC14 GIVEN a save at tick `t` with `prev` + per-cell `smoothed`, WHEN loaded and MemberSim runs at `t+1`, THEN MemberSim's read matches pre-save `prev` bit-for-bit, and `access_reachable` is recomputed from the loaded grid (not deserialized)

---

## Implementation Notes

*Derived from ADR-0002 + ADR-0005 Implementation Guidelines:*

**Determinism (AC1):**
- Pure function of member state → identical member-state sequence yields bit-identical outputs
- Fixed float-summation order (Core Rule 7 / OQ2): ascending cell index for per-cell, ascending equipment_instance_id for per-equipment — never hash order
- AC1 runs the same N-tick member-state sequence twice through two Congestion instances → bit-identical

**No RNG (AC2):**
- Static/grep check: zero `randi`/`randf`/`RandomNumberGenerator` calls in congestion.gd

**Serialization (Core Rule 7, AC14):**
- Serialize: `prev` (per-equipment scalars) + per-cell `smoothed` values
- `next` is transient — reconstructible next tick
- `access_reachable` NOT serialized — recomputed from restored grid on first post-load `grid_changed` or a one-shot recompute on load
- Restoring `prev`/`smoothed` at a tick boundary makes next tick's MemberSim read bit-identical to uninterrupted play
- `JSON.stringify(full_precision=true)` for floats; two-phase deserialize (Phase A validate / Phase B commit)

**Signal (TR-CONG-008):**
- `congestion_updated()` (S8) emitted once per tick after recompute — overlay subscribes

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 001]: per-equipment scalar computation
- [Story 002]: per-cell density computation
- [Story 003]: access_reachable flag and grid_changed handling

---

## QA Test Cases

*Written by qa-lead at story creation. The developer implements against these — do not invent new test cases during implementation.*

- **AC1**: 双跑位等同
  - Given: identical fixed member-state sequence across N ticks
  - When: Congestion processes it twice (two instances)
  - Then: per_equipment_congestion, per_cell_density, access_reachable bit-identical run-to-run
  - Edge cases: N=0 (no state), dense clusters, edge cells, equipment removal mid-run

- **AC2**: 静态无 RNG
  - Given: congestion.gd source
  - When: statically inspected (grep)
  - Then: zero randi/randf/RandomNumberGenerator calls
  - Edge cases: no `randomize()` either

- **AC14**: 序列化往返
  - Given: save at tick t with prev + per-cell smoothed
  - When: loaded; MemberSim runs at t+1
  - Then: MemberSim's read matches pre-save prev bit-for-bit; access_reachable recomputed from loaded grid (not deserialized)
  - Edge cases: float precision — smoothed values round-trip bit-exact; load at mid-tick (never — tick-boundary only)

---

## Test Evidence

**Story Type**: Integration
**Required evidence**:
- `tests/unit/congestion/determinism_no_rng_test.gd` — AC1/AC2 (must exist and pass)
- `tests/unit/congestion/serialization_test.gd` — AC14 (must exist and pass)

**Status**: [ ] Not yet created

---

## Dependencies

- Depends on: Story 003 (access_reachable), save-load epic (two-phase deserialize protocol, tick-boundary coordination)
- Unlocks: satisfaction epic (reads Congestion(t-1) scalar), congestion-flow-overlay (presentation layer later)
