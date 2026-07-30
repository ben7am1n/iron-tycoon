# ZoneRules (static adjacency / packing, pure function)

> **Status**: In Design
> **Author**: user + agents
> **Last Updated**: 2026-07-20
> **Implements Pillar**: Pillar 1 (空间即玩法 — creates the "cluster for synergy" pull that makes layout a real optimization puzzle) · Pillar 2 (松弛不紧绷 — all effects are non-negative bonuses, never penalties) · Pillar 3 (一眼看懂 — synergy is previewable before you commit)
> **Creative Director Review (CD-GDD-ALIGN)**: Skipped — Lean review mode (not a PHASE-GATE at lean).
> **Design intent (validated 2026-07-18)**: the concept prototype (`prototypes/gym-flow-concept/REPORT.md`) confirmed that *spreading* equipment to relieve member congestion feels great. ZoneRules exists to supply the **countervailing reason to cluster** — same-zone synergy — so the player faces a genuine trade-off (cluster for synergy vs spread for flow) rather than a one-way "always spread" answer. That tension *is* the puzzle.

## Overview

ZoneRules is the **pure function** that scores the *static* quality of a placed layout. Given a read-only snapshot of the gym floor, it computes, for every placed equipment instance, a small set of non-negative effect bonuses — `zone_synergy` (reward for putting same-function equipment orthogonally adjacent), `spaciousness` (reward for leaving open breathing room around a machine), and it passes through each equipment's authored `comfort` — and returns them per instance. It owns **no state and no randomness**: `evaluate(snapshot)` depends only on its inputs, so the *exact same function* scores both a committed layout (real snapshot) and a placement **preview** (a speculative snapshot with a hypothetical piece added), which is how the drag-preview can show "+zone synergy" before you drop, with no dependency cycle back to PlacementSystem. Critically, ZoneRules is **static and member-independent**: it measures the *geometry* of the layout (what's next to what, how much open space), never live member crowding — that dynamic half belongs to Congestion (#7). Together the two form the core spatial-optimization tension: ZoneRules pulls the player to cluster for synergy, Congestion pushes them to spread for flow, and resolving that is the game.

## Player Fantasy

ZoneRules has no direct fantasy of its own — the player never thinks "the zone-rules system." What they feel is the *pull to arrange things well*: the small, satisfying "+力量区协同" that lights up when they nudge two strength machines together, and the quiet dilemma that follows — cluster them for the synergy, or spread them out so the members flow? That dilemma is the entire reason the game is a puzzle and not just decoration, and ZoneRules is where the "clustering is *good*" half of it lives. It serves Pillar 1 (layout has real consequences), Pillar 2 (it only ever *rewards* — a scattered layout simply earns less bonus, it is never punished, so tinkering stays stress-free), and Pillar 3 (the synergy is legible *in the preview*, so the player learns the rule by seeing it, not by reading a manual). The feeling to protect is "ooh, if I move this here, that lights up" — the gentle magnetic tug that makes "再挪一下试试" worth doing.

## Detailed Design

### Core Rules

1. **Pure function, member-independent.** The sole entry point is `evaluate(snapshot: GridStateReader) -> Dictionary`. It reads only the snapshot (and an injected, immutable EquipmentCatalog reference — see Rule 3); it holds no mutable state, performs no RNG, and never reads live member positions/queues (that is Congestion #7). Same inputs → bit-identical output.

2. **Preview == commit equivalence.** Because `evaluate` is pure and takes the abstract `GridStateReader` (the shared read base class of both the real `GridSystem` and a `GridSnapshot`), it cannot tell a real snapshot from a speculative one. Evaluating a speculative snapshot that contains hypothetical piece X placed **must** equal evaluating the real snapshot after X is actually committed (for the same resulting instance set). The placement preview (Overlay #8 / PlacementSystem) obtains zone effects by building a speculative snapshot with the dragged piece assigned a stable provisional `instance_id`, then calling the same `evaluate`.

3. **Required snapshot contract (an addition to `GridStateReader`).** GridSystem cells store only an integer `occupant_id` — deliberately *not* the equipment type. To score zones, ZoneRules needs, per placed instance, its **type** and cells. It therefore requires the snapshot to expose:
   `get_placed_instances() -> Array[PlacedInstance]`, where `PlacedInstance = {instance_id: int, equipment_id: String, footprint_cells: Array[Vector2i], access_cells: Array[Vector2i]}`.
   This method is **not** in GridStateReader's current read contract (`is_solid` / `get_occupant_id` / `get_access_cells` / `get_dimensions`) — adding it is a hard prerequisite, handed to GridSystem / `/create-architecture` (see Open Questions). The `access_cells` field is **plural** (`Array[Vector2i]`), matching GridSystem's existing per-instance storage. `PlacedInstance` will be a concrete `class_name` (or inner class) at architecture time — the inline notation here is pseudocode for the field list. ZoneRules then looks up `EquipmentCatalog.get_definition(equipment_id)` for `zone_membership` and the authored `comfort` value. (Catalog is immutable, so holding a reference keeps `evaluate` pure.)

4. **Effect-tag vocabulary (fulfills EquipmentCatalog OQ#1).** The `effects: Array[{tag, magnitude}]` container that EquipmentCatalog authors uses **exactly one** ZoneRules-defined *input* tag; the other two tags are ZoneRules *outputs* and are never authored in the Catalog:

   | Tag | Meaning | Source | Range |
   |---|---|---|---|
   | `comfort` | Intrinsic ambience of an equipment type (mirrors, mats, fans) — placement-independent | **Catalog-declared input** (authored per type in `effects`) | `[0.0, 1.0]` |
   | `zone_synergy` | Bonus for orthogonal adjacency to same-zone equipment | **ZoneRules-computed output** | `[0.0, S_max)` |
   | `spaciousness` | Bonus for open breathing room around the instance | **ZoneRules-computed output** | `[0.0, C_max]` |

   All three are **non-negative by construction** — ZoneRules never subtracts. A poor layout earns 0 on a tag; it is never punished (Pillar 2 enforced at the vocabulary level, not by a downstream clamp).

5. **Zones (MVP).** Three, matching the art-bible color language: **力量区 Strength** (Sage), **有氧区 Cardio** (Sky), **团课/社交区 Social** (Peach). Equipment with empty `zone_membership` simply never earns `zone_synergy`. `zone_membership` may be an Array (an equipment can belong to multiple zones); two instances are "same-zone" if they share **≥ 1** zone (OR-match).

6. **Adjacency is orthogonal only; perimeter-normalized.** Two instances are adjacent iff any footprint cell of one shares an **orthogonal edge** (共边) with any footprint cell of the other. Diagonal (corner-only) touching is **not** adjacency — consistent with the no-corner-cut movement rule (Navigation), so the synergy geometry matches the walkability geometry. `n_same_i` counts **distinct neighboring instances** (not shared edges). The raw count is then divided by `N_max_i` (the instance's orthogonal perimeter cell count, excluding own cells) to produce the normalized ratio `r_i` fed into the synergy formula — this ensures all footprint sizes earn the same synergy for the same proportion of zone-cohesive neighbors.

7. **Output shape.** `evaluate` returns `Dictionary[instance_id -> {comfort, zone_synergy, spaciousness, total}]`, where `total = comfort + zone_synergy + spaciousness` (a pure sum; all terms non-negative so `total` is too). Satisfaction (#10) consumes this **per-instance** dict directly (so it can weight by the specific equipment a member used, not a smeared average). A secondary convenience field `layout_summary = mean(total over instances)` may be exposed for quick UI display (#17) but is **not** the primary interface.

8. **Determinism.** Iteration over placed instances runs in a fixed order (ascending `instance_id`). The current formulas are order-independent sums, but the fixed order is mandated so future extensions can't silently introduce order-dependence.

### States and Transitions

ZoneRules is **stateless** — a pure function with no lifecycle, no player-facing states, and nothing serialized. It is called on demand: by the placement preview each drag frame (against a speculative snapshot) and by Satisfaction (#10) when it needs current layout scores. It does **not** subscribe to `grid_changed` and does **not** cache — callers decide when to re-evaluate.

### Interactions with Other Systems

- **Upstream dependencies (hard)**:
  - **GridSystem**: `get_snapshot()` / `get_speculative_snapshot(deltas)` returning a `GridStateReader`, which must expose the new `get_placed_instances()` (Core Rule 3); plus `is_solid` / `get_dimensions` for `spaciousness`.
  - **EquipmentCatalog**: `get_definition(equipment_id)` for `zone_membership` and the authored `comfort` magnitude (immutable, injected).
- **Downstream consumers (none have GDDs yet)**:
  - **Satisfaction (#10)**: consumes the per-instance effect dict as a layout-quality input.
  - **Placement preview (PlacementSystem #4 / Overlay #8)**: calls `evaluate` on a speculative snapshot to show live zone-effect feedback during a drag.
  - **Equipment Info Panel (#17, VS)**: may display an instance's current effect breakdown / `layout_summary`.
- **Explicit non-dependency**: Congestion (#7) — ZoneRules reads no member data; the two are complementary (static vs dynamic), not dependent.

## Formulas

> All magnitude constants are **provisional MVP anchors** for the fun-validation playtest, not final balance.

The **zone_synergy** formula is defined as:

`zone_synergy_i = S_max × (1 − e^(−k × r_i))`

where `r_i = n_same_i / N_max_i` (**perimeter-normalized** neighbor ratio).

**Variables:**
| Variable | Symbol | Type | Range | Description |
|----------|--------|------|-------|-------------|
| Same-zone neighbors | `n_same_i` | int | ≥ 0 | count of **distinct** instances sharing ≥1 zone with i, via orthogonal footprint-edge adjacency |
| Max possible neighbors | `N_max_i` | int | ≥ 1 | number of **distinct cells** on instance i's orthogonal perimeter (i.e., unique in-bounds cells orthogonally adjacent to `footprint_cells`, excluding i's own cells). For a 1×1 footprint this is 4; for a 2×2 it is 8; for a 1×3 it is 8, etc. |
| Neighbor ratio | `r_i` | float | `[0.0, 1.0]` | `n_same_i / N_max_i` — proportion of perimeter neighbors that are same-zone. Normalizing by perimeter ensures all footprint sizes reach the same synergy ceiling at the same "proportion of neighborhood filled," so bigger equipment does **not** get strictly more synergy than smaller equipment |
| Saturation ceiling | `S_max` | float | provisional 1.0 | maximum synergy bonus |
| Growth rate | `k` | float | provisional 2.4 | diminishing-returns rate (scaled up from 0.6 to compensate for `r_i ∈ [0,1]` input domain vs the old integer domain) |
| Synergy bonus | `zone_synergy_i` | float | `[0, S_max)` | output for instance i |

**Perimeter normalization rationale:** without normalization, a 2×2 footprint (perimeter = 8 cells) could touch up to 8 distinct same-zone neighbors, reaching synergy ~0.99, while a 1×1 footprint caps at 4 neighbors (~0.91). This creates a hidden incentive to prefer large equipment — violating Pillar 3 ("一眼看懂") and the "no dominant strategy" intent. Normalizing by `N_max_i` means a 1×1 with 4/4 same-zone neighbors and a 2×2 with 8/8 same-zone neighbors both reach the same `r_i = 1.0` → identical synergy. The puzzle is about **proportion of zone cohesion**, not raw perimeter surface area.

**Output Range:** `[0, S_max)` — 0 with no same-zone neighbors, asymptotically approaching but never reaching `S_max`. **Example** (`S_max=1.0, k=2.4`): `r=0 → 0.0`; `r=0.25 (1×1 with 1/4 neighbors) → 0.451`; `r=0.75 (1×1 with 3/4 neighbors) → 0.835`; `r=1.0 (fully surrounded) → 0.909`. Clustering beyond ~75% same-zone perimeter coverage adds almost nothing — synergy does **not** scale infinitely, so "wall off a giant strength blob" is not a dominant strategy. A 1×1 and a 2×2 at the same `r_i` produce identical synergy.

---

The **spaciousness** formula is defined as:

`spaciousness_i = C_max × (open_adj_i / total_adj_i)`

**Variables:**
| Variable | Symbol | Type | Range | Description |
|----------|--------|------|-------|-------------|
| Adjacent cells | `total_adj_i` | int | ≥ 0 | in-bounds cells orthogonally adjacent to i's `footprint_cells ∪ access_cells`, excluding i's own cells |
| Open adjacent cells | `open_adj_i` | int | `[0, total_adj_i]` | subset where `is_solid == false` (static: walls + placed footprints, **no member data**) |
| Spaciousness cap | `C_max` | float | provisional 0.5 | gentle bonus ceiling |
| Spaciousness bonus | `spaciousness_i` | float | `[0, C_max]` | output for instance i |

**Output Range:** `[0, C_max]`. Reads only static solidity — **zero overlap with Congestion's dynamic member-density field**, which is what keeps the static/dynamic split clean. `total_adj_i == 0` (fully walled in — shouldn't occur under placement rules) is defined as `spaciousness_i = 0`, never a divide-by-zero. **Example:** 6 adjacent cells, 4 open → `0.5 × (4/6) = 0.333`.

## Edge Cases

- **Empty layout** (no placed equipment): `evaluate` returns an empty `Dictionary`, no error.
- **A lone equipment** (no neighbors): `zone_synergy = 0` exactly; `spaciousness` computes normally (usually high — lots of open space).
- **Multi-zone equipment** (`zone_membership` is an Array): OR-match — any single shared zone between two instances makes them same-zone for synergy.
- **Cross-zone adjacency** (two instances share no zone): **neutral (0)** — never a penalty. Mixing zones is not punished, it just earns no synergy (Pillar 2).
- **Speculative preview snapshot**: the hypothetical dragged piece must be present in `get_placed_instances()` with a stable provisional `instance_id`, so the instance set is structurally identical to a committed one — this is what makes preview==commit hold without special-casing (Core Rule 2).
- **`total_adj_i == 0`**: `spaciousness_i = 0` (guard against divide-by-zero).
- **An `occupant_id` with no matching EquipmentCatalog definition** (stale/corrupt type id): that instance contributes `comfort=0` and `zone_synergy=0` for itself and is excluded from neighbors' `n_same`; its `spaciousness` is still computed geometrically. The anomaly is reported through an **injected, capturable channel** (a `strict_mode`-style flag / `on_invalid_equipment` callback), **not a bare `assert()`** — a bare assert is a no-op in release and cannot be tested in headless CI, so ZoneRules mirrors EquipmentCatalog's injectable-`strict_mode` pattern to keep the two branches deterministically testable. It signals an upstream invariant violation (PlacementSystem committed an instance whose type isn't in the Catalog), not a ZoneRules bug.
- **Determinism**: repeated `evaluate` on the same snapshot returns identical output; instances iterated in ascending `instance_id`.

## Dependencies

**Upstream dependencies (hard)**:

| System | Interface | Nature |
|---|---|---|
| GridSystem | `get_snapshot()` / `get_speculative_snapshot(deltas)` → `GridStateReader` incl. **new** `get_placed_instances()`; `is_solid` / `get_dimensions` | Hard |
| EquipmentCatalog | `get_definition(equipment_id)` → `zone_membership`, authored `comfort` | Hard (immutable, injected) |

**Downstream dependents** (none have GDDs yet): Satisfaction (#10, per-instance effect dict), PlacementSystem #4 / Overlay #8 (speculative-snapshot preview), Equipment Info Panel (#17, VS).

**Explicit non-dependency**: Congestion (#7) — no member data read; complementary static-vs-dynamic split.

**Bidirectional consistency notes**:
- EquipmentCatalog's GDD lists ZoneRules as the owner of the `effects` tag vocabulary (its OQ#1) — **fulfilled here**: only `comfort` is authored in Catalog `effects`; `zone_synergy`/`spaciousness` are computed outputs, never authored. EquipmentCatalog's GDD already lists ZoneRules as a hard downstream consumer of `zone_membership`/`effects`.
- GridSystem's GDD must add `get_placed_instances()` to its `GridStateReader` read contract and list ZoneRules as consumer (currently lists ZoneRules under `get_snapshot`/`evaluate`). Verify at `/consistency-check`.

## Tuning Knobs

| Knob | Default | Safe Range | Too Low | Too High |
|---|---|---|---|---|
| **`S_max`** (zone_synergy ceiling) ⭐ | 1.0 | 0.5–1.5 | Clustering barely rewarded — no reason to group by function, loses half the puzzle | Synergy dominates; players cluster everything and eat the congestion cost anyway |
| **`k`** (synergy growth rate) | 0.6 | 0.4–1.0 | Need many neighbors to see any bonus — feels unresponsive | Bonus maxes at 1 neighbor — no incentive to build a real zone |
| **`C_max`** (spaciousness ceiling) | 0.5 | 0.3–0.8 | Open space unrewarded — only flow/congestion argues for spreading | Competes with `zone_synergy`, blurs the trade-off |
| **`S_max` : `C_max` ratio** ⭐ | ~2:1 | — | If ≤1:1, spreading wins on the ZoneRules side too and the "cluster" pull disappears | If ≫2:1, clustering always wins regardless of congestion |

**The ⭐ knobs are the pull-vs-push dials.** `zone_synergy` (via `S_max`) is meant to be the *dominant, intentional* reason to cluster; `spaciousness` a quieter secondary nudge to spread (the *loud* reason to spread is dynamic congestion, on Congestion #7's side). This calibration is **provisional and unconfirmed until Satisfaction (#10) exists** — its formula decides how these bonuses actually reach the player, so the final balance must be reconciled there (same pattern as the MemberSim↔Congestion provisional contract). Tune the whole thing at the order-8 fun-validation playtest.

## Visual/Audio Requirements

ZoneRules produces data, not pixels — its category is Gameplay/logic, not on the mandatory Visual/Audio list. The *visible* manifestation (a "+力量区协同" cue lighting up during a drag preview, an effect breakdown in the Info Panel) is owned by its consumers: **Placement preview / Overlay #8** renders the live synergy feedback during a drag, and **Equipment Info Panel #17** shows the per-instance breakdown. This GDD imposes one requirement on them, per Pillar 3: the synergy feedback must appear **in the preview, before commit**, so the player learns the rule by seeing cause→effect. No audio owned here (a soft positive cue on gaining synergy is a nice-to-have for audio-director, not required for MVP).

## UI Requirements

None of its own — deferred to the consumers (Overlay #8 preview feedback; Equipment Info Panel #17). ZoneRules exposes the per-instance dict and `layout_summary`; how they are displayed is those systems' UX.

## Acceptance Criteria

> ZoneRules is a **Logic** story — every criterion requires a **BLOCKING** automated unit test in `tests/unit/zone_rules/`, using fake `GridStateReader` / `EquipmentCatalog` stubs (constructing a real grid+placement stack is too heavy). Tags: `[WB]` needs a white-box hook/stub.

1. **[WB]** GIVEN a fixed snapshot S with N placed instances, **WHEN** `evaluate(S)` is called 100 times in sequence, **THEN** every call returns bit-identical Dictionary values (no variance, no time/order dependence, no RNG).
2. **[WB]** GIVEN a speculative snapshot with hypothetical piece X (provisional `instance_id` P), **WHEN** `evaluate(speculative)` is diffed against `evaluate(real snapshot after X is committed)` for the same resulting instance set, **THEN** every shared instance_id's `{comfort, zone_synergy, spaciousness, total}` are identical. *(The single most important test — preview==commit.)*
3. GIVEN two same-zone instances touching only diagonally (no shared edge), **WHEN** `evaluate()` runs, **THEN** neither counts the other in `n_same_i` (zone_synergy unaffected).
4. GIVEN a 1×1 instance (N_max=4) with `n_same_i` = 0, 1, 3, **WHEN** zone_synergy is computed, **THEN** `r_i` = 0, 0.25, 0.75 and synergy values are 0.0, ≈0.451, ≈0.835 (tol 1e-4); AND for `r_i` = 1.0 (fully surrounded), `zone_synergy_i < 1.0` strictly (never reaches `S_max`).
4b. GIVEN a 2×2 instance (N_max=8) with `n_same_i` = 2 and a 1×1 instance (N_max=4) with `n_same_i` = 1, **WHEN** zone_synergy is computed, **THEN** both have `r_i` = 0.25 and produce **identical** synergy values (tol 1e-4). *(Validates perimeter normalization — footprint size does not advantage synergy.)*
5. **[WB]** GIVEN a 2×2 instance A and a neighbor B sharing 2 separate edges with A, **WHEN** `n_same` for A is computed, **THEN** A excludes its own cells AND counts B exactly once (not per shared edge); AND `N_max_A` = 8 (the 2×2's perimeter cell count).
6. GIVEN an instance with `total_adj_i = 4, open_adj_i = 2`, **WHEN** spaciousness is computed, **THEN** `spaciousness_i == 0.25` exactly (`0.5 × 2/4`).
7. GIVEN an instance whose `footprint ∪ access` yields `total_adj_i == 0`, **WHEN** spaciousness is computed, **THEN** `spaciousness_i == 0.0`, no exception.
8. GIVEN any valid snapshot including worst-case cross-zone clutter, **WHEN** `evaluate()` runs, **THEN** `comfort_i, zone_synergy_i, spaciousness_i, total_i ≥ 0` for every instance (never negative).
9. GIVEN A=`[Strength,Cardio]` adjacent to B=`[Cardio,Social]`, **WHEN** `evaluate()` runs, **THEN** A and B count each other (share Cardio — OR-match).
10. GIVEN A=`[Strength]` adjacent to B=`[Social]` with no shared zone, **WHEN** `evaluate()` runs, **THEN** neither counts the other; the pair contributes 0, never negative.
11. GIVEN `get_placed_instances()` returns `[]`, **WHEN** `evaluate()` runs, **THEN** it returns an empty Dictionary.
12. GIVEN exactly 1 placed instance with no neighbors, **WHEN** `evaluate()` runs, **THEN** `zone_synergy_i == 0.0` and `total_i == comfort_i + spaciousness_i`.
13. **[WB]** GIVEN the implementation file `zone_rules.gd`, **WHEN** its source is scanned (grep / static analysis), **THEN** it references **only** the documented `GridStateReader` read contract methods (`get_placed_instances`, `is_solid`, `get_dimensions`) and `EquipmentCatalog.get_definition` — no member-position, queue-length, or other dynamic-state API appears anywhere in the file. *(This is the enforceable static-only guarantee; it cannot be tested via differing fake snapshots because no member-position field exists on `GridStateReader` by contract.)*
14. GIVEN any valid snapshot, **WHEN** `evaluate()` returns, **THEN** every value Dictionary contains **exactly** `{comfort, zone_synergy, spaciousness, total}` — no missing/extra keys.
15a. **[WB]** GIVEN a placed instance whose `equipment_id` has no EquipmentCatalog definition, **WHEN** `evaluate()` runs with `strict_mode=false`, **THEN** it returns normally, that instance's row is `{comfort=0, zone_synergy=0, spaciousness=<computed>, total=spaciousness}`, it is excluded from neighbors' `n_same`, AND the injected `on_invalid_equipment` callback is invoked exactly once with the offending `instance_id` and `equipment_id`.
15b. **[WB]** GIVEN the same setup with `strict_mode=true`, **WHEN** `evaluate()` runs, **THEN** it does **not** return a normal result — the injected error channel captures a structured error (the exact mechanism — custom error object, signal, or return-type variant — is deferred to OQ4 / architecture time; the requirement is that it is deterministically observable by a test harness **without** relying on stderr capture, process exit code, or `assert()`).
16. GIVEN placed instances whose `instance_id`s are non-contiguous (e.g. 2, 7, 40), **WHEN** `evaluate()` iterates, **THEN** iteration is in ascending `instance_id` order (Dictionary preserves insertion order but does not auto-sort — the implementation must sort).
17. GIVEN an instance adjacent to the grid boundary (fewer in-bounds neighbors), **WHEN** `total_adj_i` is computed, **THEN** out-of-bounds cells are excluded from `total_adj_i` (not counted as solid or open).

**Not pure black-box**: AC1/2/5/13/15a/15b need fake `GridStateReader`/`EquipmentCatalog` stubs and (AC15a/15b) the injected error channel — flagged above; all acceptable as white-box unit tests.

## Open Questions

| # | Question | Owner | Target Resolution |
|---|---|---|---|
| OQ1 | **Hard prerequisite**: `GridStateReader` must add `get_placed_instances() -> Array[PlacedInstance]` where `PlacedInstance = {instance_id: int, equipment_id: String, footprint_cells: Array[Vector2i], access_cells: Array[Vector2i]}` (note: `access_cells` is **plural**, matching GridSystem's existing per-instance storage). The bare read contract (`is_solid`/`get_occupant_id`/`get_access_cells`/`get_dimensions`) does not expose instance→type, and ZoneRules cannot score zones without it. GridSystem cells store only `occupant_id`, so this also implies GridSystem/its snapshot must carry the `instance_id → equipment_id` map. **Deeper gap than "add a method":** GridSystem's current `PlacementRecord` stores `{footprint_cells, access_cells, rotation}` with **no `equipment_id` field**, and `commit()` signatures in grid-system.md are self-contradictory (Core Rule 7 vs interaction table). Resolving this requires adding `equipment_id` to `PlacementRecord`'s serialized shape — a schema change, not just a read-contract addition. Blocks ZoneRules implementation. | GridSystem GDD + `/create-architecture` | Before `/dev-story` of ZoneRules; add to GridSystem's read contract AND resolve `commit()` signature contradiction |
| OQ2 | `spaciousness` currently uses open-space ratio only. Window/edge proximity as an additional `comfort`-style input (the concept's "靠窗+舒适度") is deferred — window cells are a **level-feature input that doesn't exist yet**, same class of gap as `entrance_cell`/`exit_cell` (MemberSim OQ5). | GridSystem / level definition | When level features (windows) are designed |
| OQ3 | **PARTIALLY RESOLVED.** Satisfaction (#10) now exists (`satisfaction.md`) and consumes `total_i` via `use_quality_i = w_zone × (total_i / Z_NORM) − w_cong × congestion_i` with equal weights `w_zone = w_cong = 0.5` and `Z_NORM = 2.0`. The output dict shape is confirmed compatible. **Remaining**: final `S_max`/`k`/`C_max` calibration is still deferred to the fun-validation playtest (OQ5), where it must be tuned jointly with Satisfaction's weights and Congestion's `k_congestion`. | game-designer, post-playtest | At the fun-validation milestone (jointly with OQ5) |
| OQ4 | The invalid-`equipment_id` handling uses an injected `strict_mode`/`on_invalid_equipment` channel rather than a bare `assert()`, so both branches are testable in headless CI (mirrors EquipmentCatalog's `strict_mode` injection). Confirm the exact injection shape at architecture time. | Implementing programmer / `/create-architecture` | At `/dev-story` time |
| OQ5 | `S_max` / `k` / `C_max` are provisional MVP anchors. The pull-vs-push strength (does clustering-for-synergy meaningfully trade against spreading-for-flow?) can only be dialed in at the order-8 fun-validation playtest, alongside Congestion's `k_congestion`. | game-designer, post-playtest | At the fun-validation milestone |
