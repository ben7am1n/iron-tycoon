# Navigation (AStarGrid2D)

> **Status**: In Design
> **Author**: user + agents
> **Last Updated**: 2026-07-17
> **Implements Pillar**: Foundation — enables Pillar 1 (空间即玩法, member flow) and Pillar 3 (一眼看懂, readable movement)
> **Creative Director Review (CD-GDD-ALIGN)**: Skipped — Lean review mode (not a PHASE-GATE at lean).
>
> ⚠️ **Pinned engine: Godot 4.7.1.** 本 GDD 多处 API 假设在 4.7.1 实测不成立（关键：AStarGrid2D 在 `set_point_solid` 后必须调用 `update()`；`class_name` 在 headless 下不跨脚本全局注册；`draw_string` 参数顺序与旧文档不同）。实现前请读文末「Pinned Engine Caveats」。完整坑清单见 skill `godot-4x-gdscript-pitfalls`。

## Overview

Navigation is the deterministic grid pathfinder every simulated member uses to move through the gym. It wraps a single `AStarGrid2D` instance whose solidity mirrors GridSystem's occupancy: given a start cell and a goal cell, it returns the geometric shortest path as an ordered list of grid cells, or an empty list when no path exists. It is deliberately **congestion-blind** — it pathfinds over *static* occupancy (walls, pillars, placed equipment footprints) only; dynamic member density and queues (Congestion) are never part of a path's cost, and choosing *which* equipment to walk toward is MemberSim's job, not Navigation's. The system exists because Pillar 1 (空间即玩法) requires that where the player places equipment actually shapes how members move — and that this shaping be deterministic (so saves reproduce) and legible (Pillar 3: members visibly walk *around* equipment, never clip through corners). Navigation owns no game state that is serialized: the `AStarGrid2D` is a `RefCounted` object rebuilt from GridSystem occupancy on load, so the save file never carries a path or a baked graph.

## Player Fantasy

Navigation carries no direct fantasy — players never think about "the pathfinder." What they feel is its output: pixel members flowing through the space *the way the layout implies they should*. When the player opens up a clogged aisle, they watch members immediately take the newly-sensible route; when equipment boxes off a corner, members visibly route around it rather than ghosting through. This is the quiet engine under Pillar 1 (the layout has real consequences for movement) and Pillar 3 (those consequences are legible at a glance — a member cutting diagonally through a shelf corner would instantly read as "broken," so Navigation is configured to never do that). The fantasy Navigation protects is *trust*: the player believes the little people are really walking the space they built, so rearranging it feels meaningful rather than cosmetic.

## Detailed Design

### Core Rules

1. **AStarGrid2D configuration (fixed at init).** One `AStarGrid2D` instance, configured once:
   - `region` = a `Rect2i` matching GridSystem's bounding box cell-for-cell, origin-aligned to GridSystem's `(0,0)`.
   - `diagonal_mode = DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES` — diagonal movement is allowed only when **both** flanking orthogonal cells are open. This forbids clipping past even a *single* solid corner (stricter than `AT_LEAST_ONE_WALKABLE`, which still permits a single-corner clip). See Edge Cases and Tuning Knobs for the trade-off.
   - `default_compute_heuristic = default_estimate_heuristic = HEURISTIC_OCTILE` — the only heuristic consistent with the √2 diagonal step cost; Manhattan would overestimate and break A*'s shortest-path optimality.
   - `jumping_enabled = false` — JPS is a large-grid optimization with diagonal-mode interaction subtleties; at 130 cells / 10 Hz it adds an unverified variable for no measurable benefit.

2. **Cell-space only — `cell_size` independence.** Navigation exposes and consumes **grid cells** (`Vector2i`), backed exclusively by `AStarGrid2D.get_id_path()`. `get_point_path()` (world-space) is **forbidden** in Navigation's surface — this makes Navigation's logic provably independent of `cell_size` (whose value is pinned later at `/create-architecture`), by construction rather than by convention.

3. **Solidity sync with GridSystem.** Navigation subscribes to GridSystem's `grid_changed(footprint_cells_changed, access_cells_changed)`. On each emission, for every cell in **both** arrays it calls `set_point_solid(cell, GridSystem.is_solid(cell))` — always re-querying `is_solid`, never assuming true/false (the same signal fires for both placement and removal). Because `set_point_solid()` does **not** take effect until `update()` is called (corrected against 4.7.1 — the earlier "immediate effect" claim was wrong; see Pinned Engine Caveats below), the `grid_changed` handler MUST call `AStarGrid2D.update()` after pushing all solidity changes, and the next `get_path()` — after that `update()` — sees correct solidity. Access cells resolve to non-solid automatically via `is_solid` itself (the locked GridSystem contract), so the handler needs no access-cell special-casing.

4. **Path query API.** Navigation exposes `get_path(from: Vector2i, to: Vector2i) -> Array[Vector2i]`, backed by `AStarGrid2D.get_id_path(from, to)`. Paths are **cell-indexed integers** (deterministic, `cell_size`-independent). No caching — every call recomputes (A* over 130 cells is sub-millisecond; cache-invalidation-on-occupancy-change is a footgun not worth its complexity at this scale). Returns an **empty array** (never `null`) when no path exists, including when `from`/`to` is solid or outside `region`.

5. **Congestion boundary (hard non-goal).** Navigation is congestion-blind. `Congestion(t-1)` never enters a path's cost. Congestion-aware behavior lives entirely in MemberSim's *target selection* (which equipment to head for), not in Navigation's *path* layer (how to get there). Feeding a per-tick-changing value into path cost would force per-tick recomputation and multiply the determinism tie-break risk (see Core Rule 6) from per-placement to per-tick. Congestion-weighted route-shaping (steering members away from crowded aisles) is an explicit **out-of-scope non-goal for MVP**; if ever wanted it must be a separate weighted-cost pass, never AStarGrid2D.

6. **Determinism contract.** Given deterministic `is_solid`, synchronous solidity push, and MemberSim's fixed-first tick order, Navigation guarantees **bit-identical paths for a given occupancy and a given query order** — sufficient for save reproducibility *iff* query order is itself reproducible (MemberSim must iterate members via a stable ordered structure keyed by persistent member id, never a hash-ordered one). **Residual risk (hard-gated):** "same order → same path" is verified, but AStarGrid2D's internal tie-break between two equally-short paths (common in a symmetric room) was **not** proven stable across process restarts / fresh rebuilds. This must be locked by a dedicated test before any save/load feature relies on Navigation determinism — see Acceptance Criteria and Open Questions.

### States and Transitions

Navigation is effectively **stateless between queries** — it holds only the configured `AStarGrid2D` (whose solid flags track GridSystem). It has no player-facing or run-progression states. The only lifecycle transition:

| From | Event | To | Notes |
|---|---|---|---|
| (uninitialized) | init with GridSystem bbox | Ready | `AStarGrid2D.region` set, all cells' solidity seeded from `is_solid` |
| Ready | `grid_changed` fires | Ready | changed cells' solidity re-pushed immediately |
| Ready | save loaded (occupancy restored) | Ready | `AStarGrid2D` rebuilt from restored occupancy; nothing deserialized |

### Interactions with Other Systems

- **Upstream dependencies (hard)**:
  - **GridSystem**: `is_solid(cell)`, `get_dimensions()` (for `region`), and subscription to `grid_changed`.
- **Downstream consumers (none have GDDs yet)**:
  - **MemberSim (#6)**: primary consumer. Calls `get_path(from, to)` each time a member needs a route (target chosen, or a route invalidated by `grid_changed`). Owns target selection (incl. any Congestion(t-1) preference) and re-query-on-invalidation.
  - **Congestion (#7)**: does **not** call Navigation. Congestion reads member positions/routes from MemberSim; Navigation neither reads nor is influenced by Congestion.
- **Serialization note**: Navigation contributes **nothing** to the save file. The `AStarGrid2D` is `RefCounted` and rebuilt from GridSystem occupancy after load.

## Formulas

The **path_step_cost** formula is defined as:

`step_cost(a, b) = 1.0` for orthogonal neighbors; `√2 ≈ 1.41421356` for diagonal neighbors

**Variables:**
| Variable | Symbol | Type | Range | Description |
|----------|--------|------|-------|-------------|
| Move cost between adjacent cells | `step_cost` | float | {1.0, 1.41421356} | Intrinsic AStarGrid2D cost once diagonal movement is enabled |

**Output Range:** Exactly two values; diagonal is √2× orthogonal. **Example:** a path of 3 orthogonal steps + 1 diagonal costs `3·1.0 + 1.41421356 = 4.414…`.

---

The **octile_heuristic** formula is defined as:

`h(n) = (dx + dy) + (√2 - 2) · min(dx, dy)`, where `dx = |target.x - n.x|`, `dy = |target.y - n.y|`

**Variables:**
| Variable | Symbol | Type | Range | Description |
|----------|--------|------|-------|-------------|
| X distance to goal | `dx` | int | [0, 12] | Absolute cell distance in X (grid width 13 → max 12) |
| Y distance to goal | `dy` | int | [0, 9] | Absolute cell distance in Y (grid height 10 → max 9) |
| Heuristic estimate | `h(n)` | float | [0, ~14.5] | Admissible octile estimate; equals true cost on obstacle-free grids |

**Output Range:** 0 (at goal) up to ≈14.5 (opposite corners of a 13×10 grid). Admissible and consistent for octile movement, so A* returns provably shortest paths. `f(n) = g(n) + h(n)` drives node expansion.
**Example:** from `(0,0)` to `(12,9)`: `dx=12, dy=9`, `h = (12+9) + (1.41421356 - 2)·9 = 21 + (-0.58578644)·9 = 21 - 5.272 = 15.728`… (this is the estimate; the true shortest path mixes 9 diagonals + 3 orthogonals = `9·1.414 + 3 = 15.73`, matching — confirming admissibility).

## Edge Cases

- **If no path exists between `from` and `to`**: return an empty array. MemberSim treats "unreachable" as: go idle and re-evaluate target next tick — it must **not** retry the same query in a tight loop.
- **If the target access cell is itself solid-blocked / surrounded** (should be impossible under the GridSystem contract, since access cells are never solid, but its *approaches* could all be walled/occupied): `get_path` returns empty. Log a **debug-only assert** if the access cell itself came back solid — that signals an invariant violation upstream, not a Navigation bug.
- **If `from == to`**: return a single-element array `[from]`. MemberSim treats this as "already arrived."
- **If a member's current cell becomes solid mid-route** (e.g. equipment committed onto its path): MemberSim must re-query on the next `grid_changed` that touches its route and never trust a stale path array. Navigation holds no per-member path, so it has nothing to invalidate itself.
- **If `from` or `to` is out of `region` / out of bounds**: return empty array, no crash (`is_solid` returns true out-of-bounds, so such queries naturally fail closed).
- **Diagonal squeeze between two solids**: structurally impossible under `DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES` — no runtime handling needed.
- **If GridSystem's room is reshaped** (changing `AStarGrid2D.region` clears all solid flags — verified 4.7.1): requires a full re-init, not an incremental push. MVP room is fixed-size so this is documentation-only; flagged for the future `grid_resized` event (SaveLoad/GridSystem territory).

## Dependencies

**Upstream dependencies (hard)**:

| System | Interface | Nature |
|---|---|---|
| GridSystem | `is_solid(cell)`, `get_dimensions()`, subscribe `grid_changed` | Hard |

**Downstream dependents** (none have GDDs yet):

| System | Interface | Nature |
|---|---|---|
| MemberSim (#6) | `get_path(from, to) -> Array[Vector2i]` | Hard |

**Explicit non-dependency**: Congestion (#7) — Navigation neither calls it nor is influenced by it (Core Rule 5). TimeSystem — Navigation is not ticked; it is queried on demand by MemberSim (which *is* ticked). No `on_tick()`.

**Bidirectional consistency note**: GridSystem's GDD should list Navigation as a downstream consumer of `is_solid` / `grid_changed`; verify at next `/consistency-check`.

## Tuning Knobs

| Knob | Default | Safe Range | Too Low / Off | Too High / On |
|---|---|---|---|---|
| `diagonal_mode` | `ONLY_IF_NO_OBSTACLES` | {`NEVER`, `ONLY_IF_NO_OBSTACLES`, `AT_LEAST_ONE_WALKABLE`, `ALWAYS`} | `NEVER` = 4-directional, most grid-honest but movement looks stiff/blocky | `ALWAYS`/`AT_LEAST_ONE_WALKABLE` = members clip through solid corners (breaks Pillar 3 readability) |
| `default_*_heuristic` | `HEURISTIC_OCTILE` | (must match diagonal cost) | Manhattan → non-optimal paths once diagonals enabled | Euclidean → still admissible but slower expansion, no benefit here |
| `jumping_enabled` | `false` | {true, false} | — | `true` adds JPS complexity/diagonal subtleties for no benefit at 130 cells |

**Interaction note**: `diagonal_mode` and `*_heuristic` are coupled — any change to diagonal movement must keep the heuristic consistent with the resulting step cost, or A* loses its shortest-path guarantee. Do not change one without the other. Equipment-placement rules (game-designer / level-designer) must **not** rely on a diagonal 1-cell gap between corner-adjacent items as an intended traffic route, since `ONLY_IF_NO_OBSTACLES` makes such a gap impassable.

## Visual/Audio Requirements

Navigation itself renders nothing and emits no audio — it is pure logic. The *visible* consequence (members walking cell paths) is rendered by MemberSim's presentation and the movement animation. One requirement this GDD imposes on that layer: because paths are cell-indexed integers, the presentation should **interpolate** member world-position between path cells for smooth motion (rather than snapping cell-to-cell), so 10 Hz pathing reads as fluid at 60 fps render (consistent with TimeSystem's tick-vs-render separation). No `DrawableTexture2D` or shader work is owned here.

## Acceptance Criteria

> Navigation is a **Logic** story — every criterion requires a **BLOCKING** automated unit test in `tests/unit/navigation/`.

1. **GIVEN** an empty grid, **WHEN** `get_path((2,2),(2,5))` is called, **THEN** it returns exactly `[(2,2),(2,3),(2,4),(2,5)]`.
2. **GIVEN** an empty grid, **WHEN** `get_path((0,0),(3,3))` is called, **THEN** the returned path has 4 elements (diagonals used), not 7.
3. **GIVEN** the full 4-permutation flank matrix around target `(1,1)` from `(0,0)` — (a) `(1,0)` solid / `(0,1)` open, (b) `(0,1)` solid / `(1,0)` open, (c) both flanks solid, (d) both open — **WHEN** `get_path((0,0),(1,1))` is called, **THEN** in cases (a)/(b) the path never steps directly `(0,0)→(1,1)` and routes around (length ≥ 3); in (c) it returns empty (no route); in (d) the direct diagonal is allowed (length 2).
4. **GIVEN** a target fully enclosed by solid cells, **WHEN** `get_path` is called, **THEN** it returns an empty `Array[Vector2i]` (size 0), never `null`.
5. **GIVEN** any open cell `C`, **WHEN** `get_path(C, C)` is called, **THEN** it returns `[C]`.
6. **GIVEN** two Navigation instances with identical solidity but different `cell_size`, **WHEN** both are queried with the same cell coordinates, **THEN** outputs are element-for-element identical (black-box proof that `get_point_path()` is not used internally).
7. **GIVEN** an open path exists, **WHEN** `grid_changed` marks a path cell solid and the handler calls `update()` after the solidity push, **THEN** the new solid cell is excluded on the next `get_path()` query (the handler MUST call `update()` — see Pinned Engine Caveats; Navigation does NOT copy Congestion's t-1 lag pattern).
8. **GIVEN** `grid_changed` fires for a cell whose solidity did not actually change (same value re-pushed), **WHEN** it is handled, **THEN** subsequent `get_path` results are unchanged and no state is corrupted (idempotent no-op).
9. **GIVEN** an access cell adjacent to an occupied footprint, **WHEN** its solidity is checked via the exposed `is_solid` accessor, **THEN** it is never solid. *(Not pure black-box — requires a test hook exposing per-cell solidity.)*
10. **GIVEN** a fixed solidity map and fixed call sequence, **WHEN** run twice in the same process, **THEN** outputs are element-for-element identical.
11. **GIVEN** two equal-length candidate paths exist, **WHEN** a fresh headless process rebuilds `AStarGrid2D` from identical occupancy and queries the same from/to, **THEN** the chosen path matches a prior process's result. **(PASSED 2026-07-21 — ADR-0007 gate test: 10/10 processes bit-identical.)**
12. **GIVEN** identical solidity but artificially varied `Congestion(t-1)` state, **WHEN** `get_path` is queried both times, **THEN** outputs are identical (proves zero read access to Congestion).
13. **GIVEN** a solidity state pre-save, **WHEN** the game saves (Navigation serializes nothing), reloads, and rebuilds `AStarGrid2D` from persisted occupancy, **THEN** `get_path` for the same from/to returns the pre-save result.
14. **GIVEN** `from`/`to` outside the 13×10 bbox, **WHEN** `get_path` is called, **THEN** it returns an empty array without throwing, and `is_solid(out_of_bounds)` independently returns true.
15. **GIVEN** a displacement of dx=3, dy=2 with no obstacles, **WHEN** the returned path's step costs are summed, **THEN** total = `2·√2 + 1·1.0` within float tolerance (validates `path_step_cost`).

**Not unit-testable as pure black-box**: AC9 (needs a per-cell solidity hook) and AC11 (needs a two-process harness) are flagged above; both are acceptable under GUT conventions but should be built as explicitly white-box/integration tests, not disguised as black-box.

## Pinned Engine Caveats — Godot 4.7.1 (verified during vertical slice)

The following were empirically verified building the 4.7.1 vertical slice and correct
earlier GDD assumptions that were WRONG for 4.7.1:

- **AStarGrid2D solidity needs `update()`.** `set_point_solid(c, solid)` has NO immediate
  effect; you MUST call `AStarGrid2D.update()` after pushing solidity changes (Core Rule 3's
  "immediate effect" note was incorrect for 4.7.1). The `grid_changed` handler must call
  `update()` or paths won't reflect edits.
- **AStarGrid2D is the 4.x API.** `setup()` → `update()`; `find_path()` → `get_id_path()`
  (returns `Array[Vector2i]`); `diagonals_allowed` → `diagonal_mode = AStarGrid2D.DIAGONAL_MODE_NEVER`.
- **`class_name` is NOT globally registered under headless project load** — reference
  cross-script classes via `preload` const aliases + dynamic typing.
- **`class_name` must immediately follow `extends`** (not after const/var).
- **`var x := VariantReturningCall()` fails inference** — give critical locals explicit `: Type`.
- **Lambda closures do not write back to outer-scope locals** — use a `RefCounted` counter
  class with a method callback for signal counting.
- **Signal emit arity must exactly match the connected callable** — a missing 2nd `, []` arg on
  `grid_changed.emit(...)` produces a silent 1-arg call → arity crash.

Full list + reproduction: skill `godot-4x-gdscript-pitfalls`.

## Open Questions

| # | Question | Owner | Target Resolution |
|---|---|---|---|
| OQ1 | ✅ **RESOLVED (2026-07-21)**: AStarGrid2D cross-process tie-break stability verified — ADR-0007 gate PASSED (10/10 processes bit-identical). rebuild-on-load is proven correct. | — | Closed |
| OQ2 | GridSystem's origin convention is assumed to be `(0,0)`. If GridSystem ever uses a non-zero origin, Navigation needs an explicit cell translation, not the current 1:1 assumption. | lead-programmer / GridSystem | At `/create-architecture` |
| OQ3 | Room reshape clears all AStarGrid2D solid flags (verified 4.7.1) → needs a full re-init on a future `grid_resized` event. MVP room is fixed-size, so documentation-only for now. | GridSystem / SaveLoad (#14) | When room reshape/expansion is designed |
| OQ4 | `DIAGONAL_MODE_ONLY_IF_NO_OBSTACLES` makes a diagonal 1-cell gap between two corner-adjacent items **impassable**. Equipment-placement and zone-adjacency rules must not treat such a gap as an intended traffic route. | game-designer / level-designer / ZoneRules (#9) | When ZoneRules (#9) is designed |
