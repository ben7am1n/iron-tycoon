# Story 002: Per-Cell Density Field

> **Epic**: congestion
> **Status**: Complete — 2026-08-02
> **Layer**: Feature
> **Type**: Logic
> **Estimate**: S — 1 session (≤2h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-02

## Context

**GDD**: `design/gdd/congestion.md`
**Requirement**: `TR-CONG-004`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0005 (Signal Bus & Event Routing)
**ADR Decision Summary**: Per-cell density field [0,1] for the overlay heatmap. Each member splats onto its own cell and (at reduced weight) its 4-neighbors, EMA-smoothed per cell, normalized to [0,1]. Emitted via `congestion_updated()` (S8) once per tick after recompute.

**Engine**: Godot 4.7.1 | **Risk**: LOW
**Engine Notes**: Determinism requires fixed summation order — iterate cells in ascending index order, never hash order.

**Control Manifest Rules (Feature layer)**:
- Required: `congestion_updated()` (S8) emitted once per tick after recompute
- Forbidden: no RNG; no mid-tick yielding
- Guardrail: per-cell kernel cost bounded — splat only self + in-bounds 4-neighbors

---

## Acceptance Criteria

*From GDD `design/gdd/congestion.md`, scoped to this story:*

- [x] AC4 GIVEN arbitrary member distributions (including zero members and dense clusters), WHEN `per_cell_density` is computed, THEN every cell value is a finite float in `[0,1]`
- [x] AC15 GIVEN a single member on cell C with no others, WHEN `raw_cell` is computed, THEN C gets kernel weight 1, its in-bounds 4-neighbors get `w_n`, out-of-bounds neighbors are dropped, and post-clamp values stay in `[0,1]`

---

## Implementation Notes

*Derived from ADR-0005 Implementation Guidelines:*

**Core Rule 4 — per-cell density:**
```
raw_cell(c,t)     = Σ_m kernel(c, cell_m(t))
kernel(c, c_m)    = 1 if c == c_m; w_n if c is a 4-neighbor of c_m; else 0
smoothed(c,t)     = β · raw_cell(c,t) + (1 − β) · smoothed(c,t−1)
density_cell(c,t) = clamp(smoothed(c,t) / D_cell_max, 0, 1)
```
- `w_n = 0.25` (0.15–0.35), `β = 0.4` (0.25–0.6), `D_cell_max = 3` (2–4)
- Each member splats self (1.0) + in-bounds 4-neighbors (w_n); out-of-bounds neighbors dropped, not wrapped, not clamped to edge (AC15)
- Per-cell EMA smoothing (β) — O(1) memory per cell, deterministic

**Determinism (Core Rule 7 / OQ2):**
- Iterate cells in ascending index order; members in ascending member_id order — fixed float-summation order
- Never hash/scene order — float non-associativity would break bit-identical guarantee

**Signal emission:**
- `congestion_updated()` (S8) emitted once per tick after per-equipment + per-cell recompute complete — overlay subscribes

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 001]: per-equipment congestion scalar + EMA
- [Story 003]: `access_reachable` flag, grid_changed handling
- [Story 004]: serialization of prev + per-cell smoothed

---

## QA Test Cases

*Written by qa-lead at story creation. The developer implements against these — do not invent new test cases during implementation.*

- **AC4**: 全域范围
  - Given: arbitrary member distributions (zero members, dense clusters, edge members)
  - When: per_cell_density computed
  - Then: every cell value finite float in [0,1]
  - Edge cases: zero members → all 0; dense cluster → clamped to 1; empty grid corners

- **AC15**: 单成员核
  - Given: single member on cell C, no others
  - When: raw_cell computed
  - Then: C gets kernel weight 1; in-bounds 4-neighbors get w_n; out-of-bounds dropped; post-clamp values in [0,1]
  - Edge cases: C at grid corner (only 2 in-bounds neighbors); C on edge (3 neighbors); C interior (4 neighbors)

---

## Test Evidence

**Story Type**: Logic
**Required evidence**:
- `tests/unit/congestion/per_cell_density_test.gd` — must exist and pass

**Status**: [x] Complete — 2026-08-02

`per_cell_density_test.gd` exists and passes (54 assertions), registered in
`tests/headless_runner.gd` TEST_FILES. Full headless suite: 2745 passed /
0 failed (baseline 2691 + 54 new assertions), 0 SCRIPT ERROR, 3 consecutive
runs with identical per-file results.

Coverage per blocking AC:
- AC4 (range guard): zero members → every cell exactly 0.0 (finite, dense
  field covers all W×H cells); dense cluster (8 members on one cell) →
  smoothed exceeds D_cell_max and clamps to exactly 1.0; three arbitrary
  distributions (edge/corner members, horizontal line, cluster+isolated)
  → every cell finite in [0,1].
- AC15 (single-member kernel): interior cell (3,3) → self raw 1.0, 4
  in-bounds neighbors raw w_n=0.25, far cells absent; corner (0,0) → only
  2 in-bounds neighbors (raw size == 3), out-of-bounds neighbors dropped
  (no negative flat keys); edge (0,3) → 3 in-bounds neighbors (raw size
  == 4); post-EMA densities match β·raw/D_cell_max exactly for all
  placements; full-field post-clamp sweep in [0,1].
- GDD edge case: member leaves → EMA decays by (1−β)=0.6 per tick, never
  snaps to 0 (exponential decay verified tick-by-tick).
- Determinism (Core Rule 7 / OQ2): same member set injected in REVERSED
  array order → bit-identical density_cells after 4 ticks (ascending
  member_id splat order proven); field sizes identical.
- S8 ordering: `congestion_updated` fires once per tick AFTER the per-cell
  recompute — the signal handler reads the fresh field (0.4/3 on tick 1,
  blended value on tick 2).
- Data-driven knobs: beta / w_n / D_cell_max overrides via init config
  verified against exact expected values; out-of-bounds query reads 0.0.

---

## Deviations (documented, not silent)

1. **`raw_cells` / `smoothed_cells` / `density_cells` keyed by flat row-major
   index** (`y * width + x`, matching GridSystem.flat_index) rather than by
   Vector2i. The story formula is cell-based; the flat key is what makes
   "ascending cell order" == "ascending integer index" mechanically true and
   keeps story-004's serialization JSON-safe (int keys, no Vector2i encoding).
2. **Dense EMA pass — every grid cell gets a smoothed/density entry each
   tick** (not a sparse "only splatted cells" dict). Cells with no splat
   still decay via the (1−β)·prev term, which is exactly the GDD edge case
   (zero members → EMA decays toward 0, not an instant snap). Memory is
   O(cells) — one float per cell, per the GDD's "O(1) memory per cell".
3. **`D_cell_max` floored at 0.001 instead of asserted** — same convention
   as CG-001's D_max (Control Manifest forbids assert-based runtime
   differences; positive floor guarantees AC4's never-NaN invariant).
4. **Out-of-bounds neighbors are skipped in the splat; the member's own
   out-of-bounds cell is also skipped defensively** (should never occur —
   MemberSim only places members on-grid). AC15's "out-of-bounds dropped"
   is honored: no negative flat keys, no wrap, no clamp-to-edge.
5. **serialize() shape unchanged** — still `{counter, rng_state}`. Story-004
   owns extending it with per-equipment `prev` + per-cell `smoothed_cells`
   (Core Rule 7 / TR-CONG-006); this story deliberately keeps the save-load
   contract surface byte-identical. A mid-session save on the configured
   path re-warms `smoothed_cells` from 0 on load until story-004 lands.

---

## Dependencies

- Depends on: Story 001 (tick loop + double-buffer structure — this story extends it), member-sim epic (member positions)
- Unlocks: Story 004 (serializes per-cell smoothed values)
