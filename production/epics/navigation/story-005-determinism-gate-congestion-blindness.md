# Story 005: Determinism Gate and Congestion Blindness

> **Epic**: navigation
> **Status**: Complete
> **Layer**: Core
> **Type**: Integration
> **Estimate**: M — 2 sessions (≤4h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-02

## Context

**GDD**: `design/gdd/navigation.md`
**Requirements**: `TR-NAV-004`, `TR-NAV-006`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0007: AStarGrid2D Cross-Rebuild Determinism
**ADR Decision Summary**: Navigation guarantees bit-identical paths for a given occupancy and a given query order — sufficient for save reproducibility iff query order is itself reproducible (MemberSim must iterate members via a stable ordered structure keyed by persistent member id). The AStarGrid2D cross-process tie-break gate **PASSED 2026-07-21** (10/10 independent headless processes bit-identical) — rebuild-on-load is proven correct. The gate test stays in CI and re-runs on every Godot version bump. Navigation is congestion-blind: `Congestion(t-1)` never enters a path's cost; congestion-aware behavior lives entirely in MemberSim's target selection.

**Engine**: Godot 4.7.1 | **Risk**: MEDIUM
**Engine Notes**: The cross-process gate requires spawning separate headless Godot processes (`OS.execute()` from GUT) — the runner must have `godot` on PATH, and the headless binary must match the project's version. The test allocates varying amounts of dummy memory before AStarGrid2D construction to perturb the heap. 10 independent launches rule out pointer-address-dependent tie-breaking.

**Control Manifest Rules (Core layer)**:
- Required: Navigation rebuilds `AStarGrid2D` from `GridSystem.is_solid()` occupancy on load; full rebuild during load sequence step 4
- Required: Determinism gate test stays in CI and re-runs on every Godot version bump — a passing result in 4.7.1 does not guarantee it in 4.7.2
- Forbidden: Never accept non-deterministic pathfinding as a known limitation; never skip the cross-process gate test on Godot version bumps

---

## Acceptance Criteria

*From GDD `design/gdd/navigation.md`, scoped to this story:*

- [ ] AC10 GIVEN a fixed solidity map and fixed call sequence, WHEN run twice in the same process, THEN outputs are element-for-element identical
- [ ] AC11 GIVEN two equal-length candidate paths exist, WHEN a fresh headless process rebuilds `AStarGrid2D` from identical occupancy and queries the same from/to, THEN the chosen path matches a prior process's result. **(PASSED 2026-07-21 — ADR-0007 gate test: 10/10 processes bit-identical.)**
- [ ] AC12 GIVEN identical solidity but artificially varied `Congestion(t-1)` state, WHEN `get_path` is queried both times, THEN outputs are identical (proves zero read access to Congestion)

---

## Implementation Notes

*Derived from ADR-0007 Implementation Guidelines:*

**Same-process determinism (AC10):**
- Fixed solidity map + fixed call sequence → element-for-element identical outputs on repeat runs within one process
- This is the baseline determinism contract — intra-process stability is expected and cheap to assert

**Cross-process gate (AC11 — the ADR-0007 physical gate):**
- Test file: `tests/unit/navigation/tiebreak_cross_rebuild_test.gd` (per ADR-0007 Decision §1)
- Protocol: (1) deterministic occupancy with known symmetry creating ≥1 pair of equal-cost paths; (2) configure AStarGrid2D identically to production; (3) populate solidity; (4) `update()`; (5) record `get_id_path(from, to)` as a golden vector; (6) spawn separate headless Godot processes via `OS.execute()` that repeat steps 1–5 and serialize the result; (7) diff each result against the golden vector; (8) run ≥10 times; (9) all bit-identical → PASS
- **Status: PASSED 2026-07-21** — but the gate test must exist in CI and re-run on every Godot version bump
- Fallback `_lexicographic_stabilize()` is defined (ADR-0007 Decision §3) but NOT active — implement only if the gate ever fails

**Congestion blindness (AC12 / Core Rule 5):**
- Navigation holds no reference to Congestion — verify zero read access by varying Congestion state and asserting identical outputs
- Congestion(t-1) never enters a path's cost; it influences MemberSim's *target selection* only
- Do NOT add congestion-weighted path costs as an optimization — explicitly out of MVP scope

**Forbidden:**
- Never accept non-deterministic pathfinding as a known limitation
- Never skip the gate test on Godot version bumps
- Never feed per-tick-changing values into path cost

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 006]: save→rebuild→same-result round-trip (AC13) — builds on this story's gate
- [MemberSim epic]: stable member iteration order (the other half of the determinism contract); target selection with Congestion(t-1) weights
- [SaveLoad epic]: the load sequence that calls `Navigation.rebuild(occupancy)` at step 4

---

## QA Test Cases

*Written by qa-lead at story creation. The developer implements against these — do not invent new test cases during implementation.*

- **AC10**: 进程内确定性
  - Given: fixed solidity map, fixed call sequence (3 queries, fixed order)
  - When: run twice in the same process
  - Then: outputs element-for-element identical
  - Edge cases: vary query order (determinism contract depends on order — same order required); 100-query sequence

- **AC11**: 跨进程门禁
  - Given: symmetric occupancy with equal-cost path pair
  - When: golden vector recorded, then ≥10 independent headless processes rebuild and query
  - Then: all results bit-identical to golden vector (gate PASSES)
  - Edge cases: heap perturbation (dummy allocations before AStarGrid2D construction); different process launch order

- **AC12**: 拥挤盲性
  - Given: identical solidity, artificially varied Congestion(t-1) state
  - When: get_path queried under both states
  - Then: outputs identical (zero read access to Congestion)
  - Edge cases: extreme congestion values (0 vs saturated); verify via injected spy that no Congestion reference is ever read

---

## Test Evidence

**Story Type**: Integration
**Required evidence**:
- `tests/unit/navigation/tiebreak_cross_rebuild_test.gd` — must exist and pass (ADR-0007 gate test)
- `tests/unit/navigation/determinism_congestion_blind_test.gd` — AC10/AC12 assertions

**Status**: [x] Created and passing — tests/unit/navigation/determinism_congestion_blind_test.gd — 19 assertions (+ tiebreak_cross_rebuild_test.gd 13, 24/24 child processes bit-identical), 0 failures; full suite 2394/0, exit 0 (2026-08-02)

---

## Dependencies

- Depends on: Story 001–004 (query API + solidity model the gate exercises)
- Unlocks: Story 006 (rebuild-on-load round-trip), SaveLoad determinism contract (save-load epic — HARD dependency per ADR-0007)
