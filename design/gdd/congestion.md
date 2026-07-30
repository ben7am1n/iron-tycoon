# Congestion (+ one-tick routing feedback)

> **Status**: In Design
> **Author**: user + agents
> **Last Updated**: 2026-07-18
> **Implements Pillar**: Pillar 1 (空间即玩法 — turns movement into the flow signal layout drives) · Pillar 3 (一眼看懂 — the data behind the flow/heatmap overlay)
> **Creative Director Review (CD-GDD-ALIGN)**: Skipped — Lean review mode (not a PHASE-GATE at lean).

## Overview

Congestion is the system that turns raw member movement into the "flow" signal the entire MVP hypothesis rests on. Each tick — running **second, after MemberSim has moved everyone** — it measures how crowded the gym is and produces three outputs: (1) a **per-equipment-instance congestion scalar in [0,1]** that MemberSim reads one tick later (`Congestion(t-1)`) to steer members away from crowded machines; (2) a **per-cell density field in [0,1]** that the Congestion/Flow Overlay (#8) renders as a heatmap; and (3) a **per-equipment `access_reachable` flag** (event-driven, recomputed only when the grid changes) that lets the overlay surface, always-visibly, when the player has accidentally walled a machine off. Congestion is a **pure, deterministic function of member positions and states** (no RNG) with temporal smoothing so the signal doesn't flicker as individual members shuffle cell-to-cell. It is the closing half of the `Congestion(t-1) → routing(t)` feedback loop that makes "flow" a real mechanism rather than decoration — and it is congestion, not pathfinding: Navigation never reads it, so it influences *which* equipment members choose, never *how* they walk there.

## Player Fantasy

Congestion has no direct fantasy — it's the invisible measurement layer. But it's the system that makes the player's core feedback loop *legible*: it's what lets a glance at the floor (via the overlay it feeds) say "that corner is jammed, this aisle is smooth." Its job is to make the consequences of layout **visible and causal** — when the player fixes a bottleneck, congestion is what notices the crowd thinning and lets the members respond by spreading out. It quietly upholds Pillar 3 (一眼看懂): the crowd pressure that would otherwise be an invisible emergent property of pathing becomes a smooth, readable value. And it upholds Pillar 2 by being *smoothed and calm* — congestion eases in and out gently rather than snapping, so the floor never reads as a flashing alarm board.

## Detailed Design

### Core Rules

1. **Runs second each tick, over post-move state.** Congestion implements `on_tick(tick_context)` and is invoked **after MemberSim** in TimeSystem's fixed order. It reads the just-updated member positions/states of tick `t` and computes `Congestion(t)`. It uses **no RNG** — it is a pure function of member state (deterministic by construction).

2. **Double-buffering for the one-tick lag.** Congestion holds two persistent structures: `prev` (the authoritative `Congestion(t-1)`, read-only during tick `t`) and `next` (the write target for tick `t`). Sequence each tick: MemberSim reads `prev` → moves members → Congestion computes each equipment's `raw_i(t)` from post-move state, EMA-blends it against `prev[i]`, and writes into `next[i]` → **after all entities are processed**, a single swap `prev ← next` (once per tick, never mid-computation). This is the concrete mechanism of the `Congestion(t-1) → routing(t)` loop: MemberSim always sees a fully-finalized previous buffer, never a half-written current one.

3. **Per-equipment congestion scalar `[0,1]`.** The value MemberSim reads (see Formulas → `per_equipment_congestion`). Built from occupancy tier (free / in-use / in-use-with-queue), local member density around the access cell, and EMA temporal smoothing so it doesn't thrash as one member crosses the density radius. Hard-clamped to `[0,1]` at every step. **0 = idle, 1 = fully congested** — matching the interface MemberSim already committed to.

4. **Per-cell density field `[0,1]`.** For the overlay (see Formulas → `per_cell_density`). Each member splats onto its own cell and (at reduced weight) its 4-neighbors, EMA-smoothed per cell, normalized to `[0,1]`. This is the "可视化拥挤度与动线" data — Congestion produces the numbers; #8 renders them.

5. **Per-equipment `access_reachable` flag (event-driven).** For each equipment, whether *any* path exists from the level `entrance_cell` to its access cell (`Navigation.get_path(entrance_cell, access_cell)` non-empty). Recomputed **only when `grid_changed` fires** (not per-tick — reachability only changes when the layout changes), cached otherwise. This is Congestion's answer to GridSystem's handoff (its OQ#9): the overlay (#8) **must** surface `access_reachable == false` as **default-visible**, because a machine the player has accidentally walled off is exactly the case GridSystem chose not to warn about at placement time — the guarantee that the player can *see* why it's unused is the precondition that made GridSystem's silence acceptable.

6. **Equipment removal drops entries same-tick.** When an equipment is removed (`grid_changed`), its `prev`/`next`/`access_reachable` entries are **deleted the same tick** — not decayed. A stale congestion entry for equipment that no longer exists is a correctness bug (MemberSim must never read a value for a nonexistent machine), not a mere leak.

7. **Determinism & serialization.** Congestion is a pure function of member state, so a given member-state sequence yields bit-identical outputs. **Serialize only `prev`** (the per-equipment scalars) **and the per-cell `smoothed` values** — `next` is transient and fully reconstructible the following tick. On load at a tick boundary, restoring `prev`/`smoothed` makes the next tick's MemberSim read bit-identical to uninterrupted play. `access_reachable` is not serialized — it is recomputed from the restored grid on the first post-load `grid_changed` (or a one-shot recompute on load).

### States and Transitions

Congestion has no player-facing states. Its only lifecycle is the per-tick compute-and-swap and the event-driven reachability recompute:

| From | Event | To | Notes |
|---|---|---|---|
| Ready | `on_tick` (after MemberSim) | Ready | compute `next` from post-move state, EMA-blend, then swap `prev ← next` |
| Ready | `grid_changed` | Ready | recompute `access_reachable` for affected equipment; drop entries for removed equipment |
| Ready | save loaded | Ready | restore `prev` + per-cell `smoothed`; recompute `access_reachable` from grid |

### Interactions with Other Systems

- **Upstream dependencies (hard)**:
  - **TimeSystem**: `on_tick()` (second in order, after MemberSim).
  - **MemberSim**: reads member positions, states, and each equipment's `occupant` / `next_claimant` (post-move).
  - **GridSystem**: subscribes to `grid_changed` (to drop removed equipment and recompute reachability); reads access-cell locations.
  - **Navigation**: `get_path(entrance_cell, access_cell)` for the event-driven `access_reachable` computation.
  - **EquipmentCatalog**: access-cell / footprint lookups via placed instances.
- **Feedback-edge consumer (one-tick lag, not a cycle)**:
  - **MemberSim (#6)**: reads `Congestion(t-1)` (the `prev` buffer) as `Congestion_i(t-1)` in target selection. The tick-order lag breaks the cycle.
- **Downstream consumers (none have GDDs yet)**:
  - **Congestion/Flow Overlay (#8)**: renders `per_cell_density`, per-equipment congestion, and `access_reachable` (the last **default-visible**).
  - **Satisfaction (#10)**: may read per-equipment congestion as an input to satisfaction scoring.
- **Emitted signal**: `congestion_updated` (10 Hz) — fired whenever `prev` / per-cell `smoothed` are refreshed each tick; the Congestion/Flow Overlay (#8) subscribes to this for its heatmap + indicator refresh. (Consistency fix C-I2 — signal name now declared here to match Overlay #8's documented dependency.)
- **Explicit non-dependency**: **Navigation does not read Congestion** — pathfinding is congestion-blind (Navigation's Core Rule 5). Congestion influences target selection only.

## Formulas

> All numeric knobs below are **provisional MVP anchors** for the fun-validation playtest — not final balance.

The **per_equipment_congestion** formula is defined as:

```
occ_i(t)        = occupancy_state_i(t) / 2                 # tier {0,1,2} → {0, 0.5, 1.0}
dens_i(t)       = clamp(N_i(t) / D_max, 0, 1)
raw_i(t)        = clamp(w_occ · occ_i(t) + w_dense · dens_i(t), 0, 1)
Congestion_i(t) = clamp(α · raw_i(t) + (1 − α) · Congestion_i(t−1), 0, 1)
```

**Variables:**
| Variable | Symbol | Type | Range | Description |
|----------|--------|------|-------|-------------|
| Occupancy tier | `occupancy_state_i` | int | {0,1,2} | 0 free, 1 in-use, 2 in-use+queued (queue cap 1 ⇒ max tier 2) |
| Nearby loiterers | `N_i(t)` | int | 0–~10 | members within radius `R` of the access cell, **excluding** `occupant`/`next_claimant` (no double-count) |
| Density divisor | `D_max` | float | 2–5 | density normalization |
| Blend weights | `w_occ, w_dense` | float | sum = 1 (occ dominant) | occupancy vs local density mix |
| EMA factor | `α` | float | 0.15–0.5 | temporal smoothing (τ ≈ 1/α ticks) |
| Output scalar | `Congestion_i(t)` | float | [0,1] | what MemberSim reads next tick |

**Output Range:** Hard-clamped `[0,1]` at both `raw_i` and the EMA step (defensive, even though weights sum to 1). **Example:** occupied+queued → `occ=1.0`; 2 loiterers, `D_max=3` → `dens=0.667`; `w_occ=0.7, w_dense=0.3` → `raw = 0.9`; prior `Congestion_i(t-1)=0.6`, `α=0.3` → `Congestion_i(t) = 0.3(0.9)+0.7(0.6) = 0.69`.

---

The **per_cell_density** formula is defined as:

```
raw_cell(c,t)     = Σ_m kernel(c, cell_m(t))
kernel(c, c_m)    = 1 if c == c_m; w_n if c is a 4-neighbor of c_m; else 0
smoothed(c,t)     = β · raw_cell(c,t) + (1 − β) · smoothed(c,t−1)
density_cell(c,t) = clamp(smoothed(c,t) / D_cell_max, 0, 1)
```

**Variables:**
| Variable | Symbol | Type | Range | Description |
|----------|--------|------|-------|-------------|
| Member cell | `cell_m(t)` | Vector2i | grid | member `m`'s post-move cell |
| Neighbor splat | `w_n` | float | 0.15–0.35 | contribution to von-Neumann neighbors |
| EMA factor (cell) | `β` | float | 0.25–0.6 | per-cell temporal smoothing |
| Cell divisor | `D_cell_max` | float | 2–4 | normalization for overlay coloring |
| Output field | `density_cell(c,t)` | float | [0,1] | overlay-consumed per-cell value |

**Output Range:** `[0,1]` per cell. **Example:** 1 member on `c` (1.0) + 2 members on adjacent cells (`w_n=0.25` each → 0.5) → `raw=1.5`; prior `smoothed=1.0`, `β=0.4` → `smoothed=1.2`; `D_cell_max=3` → `density=0.4`.

---

**Smoothing rationale**: EMA (not a sliding window) — O(1) memory per entity, deterministic, nothing to serialize but one float each. `α=0.3` gives τ≈3.3 ticks (0.33 s) to 63% of a step, ~10 ticks to settle — slow enough that target selection doesn't thrash as one member crosses the density radius, fast enough to feel responsive within a playtester's glance. `β=0.4` for cells can run a touch faster (τ≈2.5 ticks) since cell flicker costs only visual polish, not behavior.

## Edge Cases

- **Zero members**: `raw=0` everywhere; EMA decays exponentially toward 0 (not an instant snap) — intentional, keeps the overlay calm (Pillar 2).
- **One member oscillating across the density radius boundary**: `occupancy_state` is position-independent (tied to occupant/claimant assignment), so only `dens_i` flickers; EMA absorbs it into a stable mid-value — no jitter reaches MemberSim.
- **Equipment removed**: `prev`/`next`/`access_reachable` entries dropped the same tick (Core Rule 6) — never decayed, never left stale.
- **Occupant/queued members and `N_i`**: both `occupant` and `next_claimant` feed `occupancy_state` only and are **excluded** from `N_i`, so the same 1–2 members are never counted in both terms.
- **Clamping**: `raw_i`, `Congestion_i`, and `density_cell` each clamp `[0,1]` every tick, defensively.
- **A machine walled off by the player's layout**: `access_reachable = false`; congestion still computes (it'll trend to 0 as no one can reach it), but the overlay must show the blocked state so the player understands the emptiness — Core Rule 5.
- **On load**: `access_reachable` is recomputed from the restored grid (not serialized); `prev`/`smoothed` are restored exactly.
- **Multiple `grid_changed` events in one tick**: apply all occupancy deltas first, then de-duplicate the set of affected equipment and recompute `access_reachable` **once per affected equipment** — never once per event. Reachability is computed against the final post-batch grid state, never an intermediate.
- **Divide-by-zero guard**: `D_max` and `D_cell_max` are tuning knobs constrained to be `> 0` (asserted at init); a zero divisor is a config error, not a runtime-handled case.
- **Grid-edge cells (<4 neighbors)**: the `per_cell_density` kernel splats `w_n` only to **in-bounds** 4-neighbors; out-of-bounds neighbors are dropped (not wrapped, not clamped to the edge cell) — edge cells simply receive fewer neighbor contributions.
- **Float-summation order (determinism)**: `per_cell_density` sums and per-equipment iteration must run in a **fixed order** (ascending cell index / ascending `equipment_instance_id`), never hash/scene order — otherwise floating-point non-associativity would break the bit-identical guarantee (Core Rule 7). See Open Questions.

## Dependencies

**Upstream dependencies (hard)**:

| System | Interface | Nature |
|---|---|---|
| TimeSystem | `on_tick()` (second, after MemberSim) | Hard |
| MemberSim | member positions/states, per-equipment `occupant`/`next_claimant` | Hard |
| GridSystem | subscribe `grid_changed`, access-cell locations | Hard |
| Navigation | `get_path(entrance_cell, access_cell)` for `access_reachable` | Hard |
| EquipmentCatalog | access-cell/footprint lookups for placed instances | Hard |

**Feedback-edge consumer (one-tick lag)**: MemberSim (#6) reads `Congestion(t-1)`. Not a cycle.

**Downstream dependents** (none have GDDs yet): Congestion/Flow Overlay (#8, all three outputs — `access_reachable` **default-visible**), Satisfaction (#10, per-equipment congestion as a scoring input).

**Explicit non-dependency**: Navigation does not read Congestion.

**Bidirectional consistency note**: MemberSim's GDD already lists Congestion as a feedback-edge dependency and assumes the `[0,1]` per-equipment scalar — that interface is honored here (Core Rule 3). Verify at `/consistency-check`.

## Tuning Knobs

| Knob | Default | Safe Range | Too Low | Too High |
|---|---|---|---|---|
| **`α`** (equipment EMA) ⭐ | 0.3 | 0.15–0.5 | Sluggish — crowd lingers on a just-freed machine, members over-avoid it | Jitter/thrash in target selection — **fun-validation dial** |
| **`w_occ` / `w_dense`** ⭐ | 0.7 / 0.3 | 0.6–0.8 / 0.2–0.4 | Signal steps in coarse 0/0.5/1 jumps only | Reacts to passers-by, misleads routing — **fun-validation dial** |
| `R` (density radius) | 1–2 cells | 1–2 | Misses approach crowding | Counts unrelated traffic |
| `D_max` | 3 | 2–5 | Saturates too easily | Never saturates, density stays low |
| `β` / `D_cell_max` / `w_n` | 0.4 / 3 / 0.25 | 0.25–0.6 / 2–4 / 0.15–0.35 | Overlay-only visual impact | Overlay-only visual impact |

**Fun-validation dials**: `α` and the `w_occ`/`w_dense` mix are the two knobs most likely to be tuned at the order-8 milestone — together they decide whether the congestion signal feels *responsive but stable* (the feeling that makes rearranging satisfying).

## Visual/Audio Requirements

Congestion produces data, not pixels — all rendering is the Congestion/Flow Overlay's (#8) job. This GDD only constrains that consumer: the overlay must (a) render `per_cell_density` as a smooth heatmap (calm palette, not alarm-red — consistent with the art bible), (b) show per-equipment congestion legibly, and (c) surface `access_reachable == false` **default-visible**, not hidden behind an optional toggle (Core Rule 5). No audio is owned here.

## UI Requirements

None of its own. The overlay toggle/legend UI belongs to #8.

## Acceptance Criteria

> Congestion is a **Logic** story — every criterion requires a **BLOCKING** automated unit test in `tests/unit/congestion/`. Tags: `[WB]` needs a white-box hook/spy.

1. **GIVEN** an identical fixed sequence of member states across N ticks, **WHEN** Congestion processes it twice, **THEN** `per_equipment_congestion`, `per_cell_density`, and `access_reachable` are bit-identical run-to-run.
2. **[WB]** **GIVEN** the Congestion source, **WHEN** statically inspected, **THEN** it contains zero `randi`/`randf`/`RandomNumberGenerator` calls (static/grep check).
3. **GIVEN** any `occupancy_state ∈ {0,1,2}` and any `N_i ≥ 0`, **WHEN** `per_equipment_congestion` is computed, **THEN** the result is a finite float in `[0,1]` — never NaN, negative, or > 1.
4. **GIVEN** arbitrary member distributions (including zero members and dense clusters), **WHEN** `per_cell_density` is computed, **THEN** every cell value is a finite float in `[0,1]`.
5. **GIVEN** `prev` holds `Congestion_i(t-1) = X`, **WHEN** MemberSim runs at tick `t` (before Congestion), **THEN** MemberSim reads exactly `X`, unaffected by any writes to `next` later in tick `t`.
6. **[WB]** **GIVEN** Congestion is mid-computation at tick `t` (some equipment processed, some not), **WHEN** a consumer queries `per_equipment_congestion` in that window, **THEN** every entry returned is from `prev` (t-1) — never a prev/next mix.
7. **GIVEN** `Congestion_i(t-1) = C0` and a `raw_i` at either extreme (0 or 1), **WHEN** `Congestion_i(t)` is computed with `α=0.3`, **THEN** `|Congestion_i(t) − C0| ≤ 0.3` exactly.
8. **GIVEN** `occupancy_state=0` and `N_i=0` sustained for 9+ consecutive ticks (`(1-α)^n < 0.05` at `α=0.3`), **WHEN** `Congestion_i` is sampled, **THEN** `Congestion_i < 0.05`.
9. **GIVEN** equipment E has active entries and a `grid_changed` removes E during tick `t`, **WHEN** tick `t+1` begins, **THEN** querying E's id returns "not found," never a stale float.
10. **GIVEN** a queue attempts to exceed 1 waiting member, **WHEN** `occupancy_state` is read, **THEN** it never exceeds 2.
11. **GIVEN** member M is the `occupant` or `next_claimant` of E, **WHEN** `N_i` is computed within radius R, **THEN** M is excluded even if physically within R.
12. **[WB]** **GIVEN** no `grid_changed` fires during tick `t`, **WHEN** Congestion runs its normal per-tick update, **THEN** zero `Navigation.get_path` queries occur that tick (call-count spy).
13. **GIVEN** a `grid_changed` severs the only path from `entrance_cell` to E's access cell, **WHEN** `access_reachable` recomputes, **THEN** `access_reachable[E] == false`.
14. **GIVEN** a save at tick `t` with `prev` + per-cell `smoothed`, **WHEN** loaded and MemberSim runs at `t+1`, **THEN** MemberSim's read matches pre-save `prev` bit-for-bit, and `access_reachable` is recomputed from the loaded grid (not deserialized).
15. **GIVEN** a single member on cell C with no others, **WHEN** `raw_cell` is computed, **THEN** C gets kernel weight 1, its in-bounds 4-neighbors get `w_n`, out-of-bounds neighbors are dropped, and post-clamp values stay in `[0,1]`.
16. **GIVEN** two `grid_changed` events affecting the same equipment E in one tick, **WHEN** they are processed, **THEN** `access_reachable[E]` is recomputed exactly once, against the final post-batch grid state.

**Not pure black-box**: AC2 (static check), AC6 (mid-loop state hook), AC12 (Navigation call-count spy) — flagged above; acceptable as white-box/static tests.

## Open Questions

| # | Question | Owner | Target Resolution |
|---|---|---|---|
| OQ1 | The overlay (#8) **must** render `access_reachable == false` **default-visible** (not behind an optional toggle) — this honors GridSystem's OQ#9 hard requirement that a walled-off machine be visibly explained. Congestion produces the flag; #8 must surface it. | Whoever designs the Congestion/Flow Overlay (#8) | When #8 is designed (next in order) |
| OQ2 | The bit-identical determinism guarantee (AC1) depends on **fixed float-summation order** — per-cell and per-equipment iteration must run in ascending index / `equipment_instance_id` order, never hash order. Must be enforced in implementation; if float non-associativity still bites, fall back to an epsilon-tolerance determinism assertion. | Implementing programmer (systems-designer / gameplay-programmer) | At `/dev-story` time |
| OQ3 | Satisfaction (#10) may read per-equipment congestion as a scoring input — confirm the exact interface (same `[0,1]` scalar? aggregated?) when Satisfaction is designed. | Whoever designs Satisfaction (#10) | When Satisfaction is designed |
| OQ4 | `access_reachable` uses a single `entrance_cell` as the path source (matching MemberSim's single-entrance assumption). If multiple entrances are ever added, reachability must become "reachable from *any* entrance." | GridSystem / level definition | If/when multiple entrances are designed (post-MVP) |
