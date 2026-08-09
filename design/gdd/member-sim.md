# MemberSim + MemberActivity/usage

> **Status**: In Design
> **Author**: user + agents
> **Last Updated**: 2026-07-18
> **Implements Pillar**: Pillar 1 (空间即玩法 — layout causally drives member flow) · Pillar 2 (松弛不紧绷 — giving up is calm, never punished) · Pillar 3 (一眼看懂 — flow legible at a glance)
> **Creative Director Review (CD-GDD-ALIGN)**: Skipped — Lean review mode (not a PHASE-GATE at lean).
> **Playtest evidence (2026-07-18)**: the core loop was validated **PROCEED** in the concept prototype (`prototypes/gym-flow-concept/REPORT.md`). Its single biggest friction was **queue legibility** — the player "看不清谁在排队" (couldn't tell who was queuing) when member states were shown by color alone. Fix folded into Visual/Audio → State legibility below.

## Overview

MemberSim is the beating heart of the MVP hypothesis — "tuning layout for flow is fun." It simulates the pixel members who enter the gym, choose equipment to use, path toward it, queue when it's busy, use it, and eventually leave. Its entire reason for existing is to make the *quality of the player's layout* visibly and causally shape how smoothly members flow: a clumped layout produces visible bottlenecks and members turning around at the door; a well-spread layout produces smooth, satisfying flow. MemberSim runs **first** each simulation tick (before Congestion), reads `Congestion(t-1)` as a one-tick-lagged preference input to its target selection (so equipment that was crowded last tick becomes less attractive this tick), and drives everything through a seeded RNG sub-stream (`TimeSystem.get_rng("MemberSim")`) so that saves reproduce bit-for-bit. It owns the members themselves (their persistent `member_id`, state, and position), the access-cell reservation mechanism that GridSystem explicitly refused to own, and the member activity lifecycle — but it owns none of the spatial truth (GridSystem), pathfinding (Navigation), or equipment data (EquipmentCatalog) it consumes.

## Player Fantasy

This is where the game's payoff becomes visible. The player doesn't control the members — they control the *space* — and the fantasy is watching the little people you're responsible for move through a place you designed, and *feeling* your design decisions in their behavior. You widen an aisle and the clot of waiting members visibly dissolves into smooth traffic; you tuck the treadmills into a dead-end and watch a queue back up; you spread the popular machines out and the whole floor breathes. This is Pillar 1 made tangible — the members are the proof that layout is really the game. It is also where Pillar 2's promise is kept moment-to-moment: when a member can't get to a machine, they don't fail or punish you — they calmly shrug, wander off to something else, or head home, and you simply note "huh, that corner's awkward" and rearrange. And it's Pillar 3's showcase: a glance at the floor tells you where flow is good and where it's stuck, without reading a single number. Reference: the quiet satisfaction of watching Two Point Hospital patients thread your corridors, or Mini Motorways traffic finding its way — the members are alive enough to care about, calm enough to never stress you.

## Detailed Design

### Core Rules

1. **Tick-driven, runs first.** MemberSim implements `on_tick(tick_context)` and is invoked **first** in TimeSystem's fixed order each tick (before Congestion). Each tick: (a) run the arrival check; (b) update every active member exactly once, iterating in **ascending `member_id` order** (never scene-tree or hash order) so behavior is deterministic.

2. **Member lifecycle state machine.**
   `ENTERING → SELECTING_TARGET → WALKING_TO → [QUEUEING] → USING → (SELECTING_TARGET | LEAVING) → GONE`
   - **ENTERING**: pass-through spawn tick; immediately evaluates SELECTING_TARGET the same tick.
   - **SELECTING_TARGET**: runs the weighted pick (Core Rule 3). Three outcomes: (a) candidate found + reservation claimed → WALKING_TO; (b) **no reachable/available candidate at all → LEAVING immediately** (this is the critical flow-legibility signal — a bad layout produces visible "walked in, turned around, left" members; it must never silently stall); (c) visit quota (`exercises_per_visit`) reached → LEAVING.
   - **WALKING_TO**: consumes the cached path one cell per tick. Each tick, compares the path's `grid_version` stamp to GridSystem's current version; on mismatch, re-queries `Navigation.get_path`. Empty result → release any held reservation, retry SELECTING_TARGET (bounded retry counter) → LEAVING if retries exhausted.
   - **QUEUEING**: the member stops **one cell short** of the access cell (never steps onto an occupied access cell — avoids sprite overlap, serves Pillar 3). It holds a pre-committed reservation (Core Rule 4), so the wait is bounded. A `patience_threshold` timer counts down; on exhaustion → release reservation, reselect elsewhere with a short blacklist on this equipment (prevents flip-flop) → LEAVING if nothing else works.
   - **USING**: exclusive physical occupation of the access cell for `use_duration_ticks`. On completion → SELECTING_TARGET (continue) or LEAVING (visit done). If the equipment is deleted mid-use (`grid_changed`), interrupt gracefully → SELECTING_TARGET, no crash (a satisfaction-penalty signal is emitted for Satisfaction #10 to consume).
   - **LEAVING**: paths to the level's single `exit_cell`, subject to the same repath logic as WALKING_TO. A defensive safety timeout forces GONE if no exit path ever resolves — Pillar 2 forbids a permanently stuck member.
   - **GONE**: removed from the active collection; `member_id` retired forever.

3. **Target selection algorithm.** Per reselect, in this fixed order (all randomness via `get_rng("MemberSim")`):
   1. Build the candidate pool: equipment matching member interest, **excluding** any equipment already fully "spoken for" (its reservation `next_claimant` held by someone else) and any on this member's short-term no-repeat blacklist.
   2. Compute `target_selection_weight` (see Formulas) for each candidate from `Congestion(t-1)`, distance, novelty, resolved preference-type category weight, and per-member preference noise.
   3. **Do not pathfind every candidate.** Sort by weight descending, deterministic tie-break by `equipment_instance_id`, take the top-K (K = 3–5) — a hard performance guard against O(members × equipment) pathing.
   4. Path-check the K in ascending `equipment_instance_id` order via `Navigation.get_path`; drop unreachable; renormalize weights over survivors.
   5. Weighted-random draw over survivors using one `rng.randf()`.
   6. Attempt to claim the reservation (Core Rule 4). If the race is lost this tick (a lower-`member_id` member claimed it first), drop and redraw from remaining survivors (bounded retries); if the pool exhausts this tick, the member simply stays in SELECTING_TARGET next tick (no partial state committed).

4. **Access-cell reservation (the mechanism GridSystem refused to own).** MemberSim owns a single map `reservations[equipment_instance_id] = {occupant: member_id?, next_claimant: member_id?}`. **Queue depth is capped at 1 for MVP** (at most one waiting member per machine — keeps queueing visually simple, Pillar 3).
   - **Claim rule**: a member may set `next_claimant` iff it is currently null — whether or not `occupant` is null. A free machine → walk and become occupant; a busy machine → become the single queue slot.
   - **On arrival**: if `occupant` is null → claim `occupant = self`, clear `next_claimant`, → USING. Else → QUEUEING (already holding `next_claimant`; a guaranteed FIFO of exactly one).
   - **Release invariant (the correctness rule)**: any member holding `next_claimant` that leaves WALKING_TO or QUEUEING **without** becoming that equipment's `occupant` must clear `next_claimant` in the **same tick**. This is precisely what keeps the lock *opportunistic and self-cleaning* rather than blocking — it is why "make the access cell solid" was forbidden (that would convert a transient conflict into a permanent deadlock).
   - **Fairness/determinism**: all contention resolves purely by ascending-`member_id` iteration order; no engine/hash order is ever involved.

5. **Path invalidation.** Every WALKING_TO / LEAVING tick compares the cached path's `grid_version` to GridSystem's current version; on change, re-query `Navigation.get_path`. An empty result is treated identically whether caused by a new obstacle or by the target equipment itself being deleted (its `equipment_instance_id` no longer resolves) — release the reservation, reselect-with-retry, else LEAVING. No special-casing between "path blocked" and "target gone."

6. **Spawn / despawn.** Each tick the arrival check (Bernoulli draw per `member_arrival_rate`) draws from `get_rng("MemberSim")` **first**, before any per-member processing, so RNG consumption order is stable. On success: instantiate at the level's single `entrance_cell`, assign `member_id = member_id_counter++`, roll the member's `preference_profile`, and insert into the `member_id`-sorted active collection. At the occupancy cap (`max_concurrent_members`) the arrival simply skips that tick (no door queue for MVP — a soft cap, never a failure). Despawn is plain removal on GONE; `member_id` is never reused.

7. **Determinism & serialization.**
   - Active members are always iterated in ascending `member_id` order.
   - Per tick, RNG is consumed in a fixed order: arrival roll(s) first, then per-member updates in `member_id` order (only members actually spawning/reselecting draw).
   - **Serialized state**: `member_id`, state, cell, cached path + its `grid_version`, `target_equipment_instance_id`, held reservation flags (occupant / next_claimant), `patience_timer`, `exercises_done`, the **resolved** `preference_profile` (store the resolved value, not a re-derivable seed — avoids RNG-order fragility across the save boundary), and the global `member_id_counter`.
   - **`member_id_counter` must be serialized explicitly — it cannot be re-derived from the active set** (unlike PlacementSystem's `instance_id`, which re-derives from grid occupancy). Departed (GONE) members' ids are not present in the active set, so `max(active member_id) + 1` could **reuse a retired id** — which would corrupt any references. This is the key divergence from PlacementSystem's self-healing approach and the reason MemberSim persists the counter.
   - The **reservation map is rebuilt from members' own serialized claim flags on load**, never serialized as separate truth (avoids desync).

### States and Transitions

| From | Event | To | Notes |
|---|---|---|---|
| — | arrival check succeeds, under cap | `ENTERING` | spawned at `entrance_cell`, `member_id` assigned |
| `ENTERING` | (immediate) | `SELECTING_TARGET` | same tick |
| `SELECTING_TARGET` | candidate found + reservation claimed | `WALKING_TO` | path cached with `grid_version` |
| `SELECTING_TARGET` | no reachable candidate | `LEAVING` | the visible "turned around and left" flow signal |
| `SELECTING_TARGET` | `exercises_per_visit` reached | `LEAVING` | satisfied, going home |
| `WALKING_TO` | arrived, access cell free | `USING` | becomes `occupant` |
| `WALKING_TO` | arrived, access cell busy | `QUEUEING` | holds `next_claimant`, waits one cell short |
| `WALKING_TO` | path invalidated, repath empty, retries exhausted | `LEAVING` | reservation released |
| `QUEUEING` | occupant releases, becomes occupant | `USING` | — |
| `QUEUEING` | `patience_threshold` exhausted | `SELECTING_TARGET` | calm give-up; blacklists this equipment briefly |
| `USING` | `use_duration_ticks` elapsed, quota remaining | `SELECTING_TARGET` | next exercise |
| `USING` | `use_duration_ticks` elapsed, quota met | `LEAVING` | — |
| `USING` | equipment deleted mid-use | `SELECTING_TARGET` | graceful interrupt, satisfaction-penalty signal emitted |
| `LEAVING` | reached `exit_cell` (or safety timeout) | `GONE` | removed; `member_id` retired |

### Interactions with Other Systems

- **Upstream dependencies (hard)**:
  - **TimeSystem**: `on_tick()` (first in order); `get_rng("MemberSim")` (all randomness).
  - **GridSystem**: reads occupancy / access cells; the `grid_version` stamp for path invalidation; **and `entrance_cell` / `exit_cell` — the single spawn/exit cells the lifecycle depends on (Core Rule 6 spawn at `entrance_cell`; LEAVING paths to `exit_cell` with a defensive safety-timeout GONE if no path resolves). These are load-bearing inputs to a state-machine transition, not incidental level decoration, so they are declared a HARD upstream dependency here — not an optional level property. GridSystem's contract (or a level-definition aligned to it) must expose them; see Open Questions OQ5.**
  - **Navigation**: `get_path(from, to) -> Array[Vector2i]`.
  - **EquipmentCatalog**: `get_definition(equipment_id)` — including **new per-equipment use-duration fields this GDD requires EquipmentCatalog to add** (`use_duration_mean_ticks`, `use_duration_stddev_ticks`, `use_duration_min_ticks`, `use_duration_max_ticks`) — see Open Questions.
- **Feedback-edge dependency (one-tick lag, not a cycle)**:
  - **Congestion (#7)**: MemberSim reads `Congestion(t-1)` — assumed to be a **per-equipment-instance normalized scalar in [0,1]** (0 = idle, 1 = fully congested) — as a target-selection preference. Congestion in turn reads MemberSim's member positions/queues to compute `Congestion(t)` *after* MemberSim runs. The one-tick lag (Core Rule 1 ordering) breaks what would otherwise be a cycle. The exact shape of the Congestion value is an **interface assumption on Congestion #7** — see Open Questions.
- **Downstream consumers (none have GDDs yet)**:
  - **Congestion (#7)**: reads member positions / queue state.
  - **Satisfaction (#10)**: consumes MemberSim's emitted signals (queueing time, walk-failures, completed uses, mid-use interruptions).
  - **HUD (#16)**: may display current member count.
- **Serialization**: MemberSim serializes its members and `member_id_counter` (Core Rule 7); it participates in SaveLoad's tick-boundary coordination.

## Formulas

> All values below are **provisional MVP anchors** to be calibrated at the fun-validation playtest — not final balance. Times are in ticks (10 ticks/sec, `TICK_DURATION_SECONDS = 0.1`).

The **member_arrival_rate** formula is defined as:

`p_tick = clamp(base_arrival_rate_per_min / 60 × TICK_DURATION_SECONDS × satisfaction_modifier × capacity_gate, 0, 1)`

**Variables:**
| Variable | Symbol | Type | Range | Description |
|----------|--------|------|-------|-------------|
| Base arrival rate | `base_arrival_rate_per_min` | float | 2–8 (tune) | Members/min at satisfaction = 1.0 |
| Tick duration | `TICK_DURATION_SECONDS` | float | 0.1 (locked) | From time-system.md |
| Satisfaction hook | `satisfaction_modifier` | float | 0.5–2.0, MVP = 1.0 | Placeholder until Satisfaction #10 exists |
| Capacity gate | `capacity_gate` | int {0,1} | — | 0 when `current_member_count ≥ max_concurrent_members` (soft cap, not failure) |
| Per-tick spawn probability | `p_tick` | float | [0,1] | Bernoulli probability of one new member this tick |

**Output Range:** [0,1], typically very small. **Example:** `base = 4/min` → λ = 0.0667/s → `p_tick = 0.00667` (≈ one arrival every 150 ticks / 15 s). Suggested `max_concurrent_members` = 15–20.

---

The **target_selection_weight** formula is defined as:

`weight_i = base_weight × exp(-k_congestion × Congestion_i(t-1)) × exp(-k_proximity × dist_i / D_max) × novelty_factor_i × preference_weight_i × pref_noise_i`
then `P_i = weight_i / Σ_j weight_j` (weighted-random pick via seeded RNG).

**Variables:**
| Variable | Symbol | Type | Range | Description |
|----------|--------|------|-------|-------------|
| Congestion last tick | `Congestion_i(t-1)` | float | [0,1] | Per-equipment congestion read from Congestion #7 |
| Congestion-avoidance strength | `k_congestion` | float | 2–5 (tune) | **Most important knob** — how strongly members avoid crowds |
| Path distance | `dist_i` | int | [0,~15] | `Navigation.get_path` length in cells |
| Normalizer | `D_max` | int | ≈16 | Grid diagonal, for normalizing distance |
| Proximity weight | `k_proximity` | float | 0.1–0.3 (tune) | **Deliberately low** — a weak tie-breaker only; must not override congestion |
| Novelty factor | `novelty_factor_i` | float | {0.2 just-used, 0.6 recent, 1.0} | Suppresses repeating the same machine |
| Preference category weight | `preference_weight_i` | float | {0.8, 1.0, 1.5} | Resolved at spawn from member type and candidate `EquipmentDef.zone_membership` |
| Preference noise | `pref_noise_i` | float | Uniform(0.85, 1.15) | Per-member randomness (seeded) so behavior isn't robotic |
| Selection probability | `P_i` | float | (0,1], Σ = 1 | Normalized pick probability |

**Output Range:** Weights are always strictly positive (exp never reaches 0, with an epsilon floor guarding against total underflow), so even a fully-crowded floor is a probability distribution, never a hard prohibition — this is what keeps behavior non-robotic. **Example:** candidate A (`Congestion=0.1, dist=3`) vs B (`Congestion=0.8, dist=1`), `k_congestion=3, k_proximity=0.2, D_max=16`: `weight_A ≈ 0.741 × 0.963 ≈ 0.714`, `weight_B ≈ 0.0907 × 0.988 ≈ 0.0896` → `P_A ≈ 0.888, P_B ≈ 0.112`. The crowded machine is clearly but not absolutely avoided — exactly the "bad layout → visible bottleneck, good layout → smooth flow" target.

**Resolved preference profiles (A1):** each spawn rolls one of `STRENGTH`, `CARDIO`, `FLEX`, or `BALANCED` with equal probability from the `MemberSim` RNG sub-stream. The type quartile and `pref_noise_i` are resolved from the same uniform sample, preserving the pre-A1 one-draw-per-profile RNG consumption contract and therefore all later seeded lifecycle rolls. The resolved profile stores its type, category-weight map, and `pref_noise_i`. Specialist profiles apply `1.5` to their matching `strength` / `cardio` / `flex` zone and `0.8` to the other two; `BALANCED` applies `1.0` to all three and therefore preserves the prior formula. The resolved profile is serialized verbatim and restored without any new roll (Core Rule 7).

---

The **use_duration** formula is defined as:

`duration_ticks = round(clamp(randfn(use_duration_mean_ticks, use_duration_stddev_ticks), use_duration_min_ticks, use_duration_max_ticks))`

**Variables:**
| Variable | Symbol | Type | Range | Description |
|----------|--------|------|-------|-------------|
| Mean use time | `use_duration_mean_ticks` | int | 150–250 (15–25 s) | Per-equipment; a **new EquipmentCatalog field** (see OQ) |
| Std deviation | `use_duration_stddev_ticks` | int | ~15–20% of mean | Gaussian jitter |
| Clamp bounds | `use_duration_min/max_ticks` | int | ~[0.5×mean, 1.5×mean] | Prevent extreme draws |

**Output Range:** clamped positive tick count. **Example:** treadmill `mean=200 (20 s), stddev=35, clamp[100,300]` → typical 165–235 ticks.

---

The **patience_threshold** formula is defined as:

`patience_threshold_ticks = round(Uniform(patience_min_ticks, patience_max_ticks))` (drawn once on entering QUEUEING)

**Variables:**
| Variable | Symbol | Type | Range | Description |
|----------|--------|------|-------|-------------|
| Patience bounds | `patience_min/max_ticks` | int | 30–80 (3–8 s) | **Second-most-important knob** |

**Output Range:** 30–80 ticks. On reaching the threshold: **calm give-up** — apply a temporary novelty penalty to the abandoned equipment (as if just-used), re-run target selection excluding it; if the candidate set is empty, wander briefly then retry. **Never** shows a failure prompt; **never** resets the member's `exercises_per_visit` progress (Pillar 2). Re-evaluated only when the threshold triggers, not every tick (avoids flip-flopping).

---

The **exercises_per_visit** formula is defined as:

`exercises_per_visit = round(clamp(randfn(mean_exercises × visit_length_modifier, stddev_exercises), min_exercises, max_exercises))` (drawn once on entry)

**Variables:**
| Variable | Symbol | Type | Range | Description |
|----------|--------|------|-------|-------------|
| Mean exercises | `mean_exercises` | float | 3 (MVP) | Satisfaction-driven once #10 lands |
| Std deviation | `stddev_exercises` | float | 1 | — |
| Clamp bounds | `min/max_exercises` | int | [1,5] | — |

**Output Range:** 1–5. Only **successfully completed** uses count toward the quota; abandoned queues neither count nor reset it. On reaching the quota, the member paths to the exit and despawns.

## Edge Cases

- **If the gym has no equipment placed at all**: a spawned member's candidate set is empty → wanders briefly (~20 ticks) then calmly leaves. No failure prompt (Pillar 2).
- **If a member has zero reachable equipment** (all walled off / occupied-and-claimed): SELECTING_TARGET → LEAVING the same tick. Never stalls, never tight-loops the same query.
- **If equipment is deleted while a member is USING it**: graceful interrupt → SELECTING_TARGET; a satisfaction-penalty signal is emitted; no crash.
- **If equipment is deleted while a member is WALKING_TO it**: repath returns empty (target gone) → release reservation, reselect, else LEAVING — handled by the same path-invalidation rule, no special-casing.
- **If two members resolve target selection on the same tick both wanting the last free machine**: resolved by ascending `member_id` — the lower id claims `occupant`/`next_claimant`; the other detects the lost race and redraws.
- **If a member arrives and the access cell was claimed by another in transit**: impossible under the pre-held reservation model — the member held `next_claimant` from selection time, so its slot is guaranteed.
- **If `base_arrival_rate_per_min = 0`**: legal — a pure layout-preview mode with no members.
- **If the floor is fully congested**: weights stay positive (epsilon floor prevents divide-by-zero) → members still distribute probabilistically, never freeze.
- **If only one instance of a needed equipment type exists**: congestion-avoidance degenerates to a pure queue test — the fun-validation playtest needs ≥2 instances of a type to actually exercise the hypothesis (flagged for the playtest protocol).
- **On load, if the serialized `member_id_counter` is missing or lower than an active member's id**: fail the load loudly (do not silently re-derive — that risks reusing a retired id). See Core Rule 7.

## Dependencies

**Upstream dependencies (hard)**:

| System | Interface | Nature |
|---|---|---|
| TimeSystem | `on_tick()` (first in order), `get_rng("MemberSim")` | Hard |
| GridSystem | occupancy / access-cell reads, `grid_version`, **`entrance_cell` / `exit_cell` (hard — the lifecycle's spawn/exit transitions depend on them)** | Hard |
| Navigation | `get_path(from, to) -> Array[Vector2i]` | Hard |
| EquipmentCatalog | `get_definition(id)` + new use-duration fields (OQ) | Hard |

**Feedback-edge (one-tick lag)**: Congestion (#7) — MemberSim reads `Congestion(t-1)`; Congestion reads MemberSim state to compute `Congestion(t)` afterward. Not a cycle (broken by the tick-order lag).

**Downstream dependents** (none have GDDs yet): Congestion (#7, member positions/queues), Satisfaction (#10, emitted signals), HUD (#16, member count).

**Bidirectional consistency note**: TimeSystem, GridSystem, Navigation, and EquipmentCatalog GDDs should each list MemberSim as a downstream consumer; verify at next `/consistency-check`. The EquipmentCatalog use-duration fields are a genuine additive change to an already-Designed GDD — tracked as an Open Question / `/propagate-design-change` item, not silently edited here.

## Tuning Knobs

| Knob | Default | Safe Range | Too Low | Too High |
|---|---|---|---|---|
| **`k_congestion`** ⭐ | 3 | 2–5 | Members ignore crowding — layout quality produces no visible difference (kills the hypothesis) | Over-avoidance — unpopular machines sit permanently empty, looks eerie |
| **`patience_min/max_ticks`** ⭐ | 30–80 | 30–80 | Queues never form — bottlenecks invisible | Queues jam and never move — reads as "clogged," not "tunable" |
| **`max_concurrent_members` / `base_arrival_rate_per_min`** ⭐ | 15–20 / 4 | 15–20 / 2–8 | Too few members — never crowds, hypothesis untestable | Too many — every layout is packed, hiding layout differences |
| `k_proximity` | 0.2 | 0.1–0.3 | Members take odd detours | Overrides congestion signal — breaks the core hypothesis |
| `novelty_factor` (just-used) | 0.2 | 0.2–0.6 | Members repeat one machine, looks dull | Forces excessive variety, unnatural |
| `mean_exercises` | 3 | 1–5 | Members leave too fast, floor feels empty | Members stay too long, floor clogs |
| top-K candidate cap | 4 | 3–5 | May miss a good far option | Pathfinding cost grows toward the budget ceiling |

**The three ⭐ knobs are the fun-validation dials** — `k_congestion` (does layout matter?), patience range (do bottlenecks form and clear?), and member volume (is the floor busy enough to test?). These are what the designer tweaks to *find the fun* at the order-8 milestone.

## Visual/Audio Requirements

- **Member sprites & movement**: members render as cozy pixel figures walking cell-to-cell. Because pathing is 10 Hz cell-based, the presentation **interpolates** world-position between path cells so movement reads as fluid at 60 fps (consistent with TimeSystem's tick-vs-render separation). Walk direction should face travel direction (4- or 8-way facing).
- **State legibility (Pillar 3) — queueing must be the most distinct state.** The four states a player cares about must be distinguishable at a glance — *walking* (moving), *queueing* (standing one cell short of a machine), *using* (on the access cell, a using animation), *leaving* (heading for the exit). **The concept prototype proved this is load-bearing, not polish**: its #1 friction ("看不清谁在排队") came from rendering member states by dot-color alone. Therefore *queueing* must get the **most visually distinct, highest-salience treatment** — a clear waiting pose plus a small "waiting" glyph (e.g. a queue/pause icon), readable by **shape first, not color** (a member's state must be legible with color removed — consistent with the art bible's colorblind rule and Overlay #8's shape-first requirement). Keep the calm palette — no red/flashing on a waiting member; queueing is calm but **unmistakable**, never an alert.
- **Give-up moment**: when a member abandons a queue (Pillar 2), the read should be a calm "shrug and move on," never a distressed or negative cue.
- **Audio**: ambient footsteps / gym murmur are a nice-to-have; no per-member SFX is required for MVP. Flagged to audio-director as low priority.
- No `DrawableTexture2D` or shader work is owned here.

## UI Requirements

MemberSim contributes no screens of its own. The current member count belongs to HUD (#16); per-member inspection (hover to see a member's current activity) is SelectionSystem (#13) / Equipment Info Panel (#17) territory, if desired later. This section is intentionally deferred to those systems.

## Acceptance Criteria

> MemberSim is a **Logic + Integration** story. Unit criteria are **BLOCKING** (`tests/unit/member_sim/`); the end-to-end flow check is a **BLOCKING** integration test (`tests/integration/member_sim/`). Tags: `[UNIT]` pure unit · `[WB]` needs a white-box hook/spy · `[INT]` integration-level.

1. **[UNIT]** GIVEN a member in SELECTING_TARGET with zero reachable/available candidates, **WHEN** `on_tick()` runs, **THEN** the member is LEAVING by the end of the same tick (no extra tick spent stalled).
2. **[UNIT]** GIVEN a member whose `exercises_done == exercises_per_visit`, **WHEN** SELECTING_TARGET evaluates, **THEN** state → LEAVING regardless of candidate availability.
3. **[UNIT][WB]** GIVEN members `member_id` 5 and 7 both targeting the same free equipment on one tick, **WHEN** the reservation claim resolves, **THEN** member 5 becomes `occupant` and member 7's redraw excludes that equipment.
4. **[UNIT]** GIVEN any equipment's reservation record, **THEN** at most one `member_id` is ever `occupant` and at most one is `next_claimant` at any tick boundary (property test over N randomized ticks).
5. **[UNIT]** GIVEN a member holding `next_claimant` for equipment E who leaves WALKING_TO or QUEUEING without becoming `occupant`, **WHEN** that transition occurs, **THEN** `reservations[E].next_claimant` is null by the end of that same tick (the release invariant — deadlock prevention).
6. **[UNIT]** GIVEN a fixed RNG seed and a scripted arrival/tick timeline, **WHEN** the sim runs twice, **THEN** the full state trace (positions, states, reservation maps) is byte-identical across both runs.
7. **[INT]** GIVEN a save with `member_id_counter = 42` and no active member id ≥ 42, **WHEN** a new member spawns after load, **THEN** its `member_id` is 42 (not `max(active)+1`).
8. **[UNIT]** GIVEN a load payload missing `member_id_counter` or with `member_id_counter <= max(active member_id)`, **WHEN** load executes, **THEN** it fails loudly, never silently substituting a derived value.
9. **[UNIT]** GIVEN a GONE member's retired `member_id`, **WHEN** any number of later spawns occur across a save/load boundary, **THEN** that id is never reassigned.
10. **[UNIT]** GIVEN two candidates identical except `Congestion(t-1)` (A=0.1, B=0.8), **WHEN** `target_selection_weight` is computed, **THEN** `weight_A > weight_B` — strictly monotonic in congestion across a swept range.
11. **[UNIT]+[INT]** GIVEN Congestion for E is updated during the current tick's Congestion pass, **WHEN** a member runs SELECTING_TARGET in the *same* tick, **THEN** the weight uses the pre-update (t-1) value; the `[INT]` part asserts MemberSim's registered tick order runs before Congestion's.
12. **[UNIT]** GIVEN every equipment has `Congestion(t-1) = 1.0` (fully congested), **WHEN** weights are computed, **THEN** all weights are > 0 (no divide-by-zero, no NaN) and `Σ P_i = 1.0`.
13. **[UNIT]** GIVEN a QUEUEING member whose `patience_timer` reaches 0, **WHEN** the give-up transition fires, **THEN** `exercises_done` is unchanged and no failure signal distinct from the calm give-up path is emitted.
14. **[UNIT]** GIVEN a member USING equipment E, **WHEN** E is deleted mid-use, **THEN** the member transitions to SELECTING_TARGET without crashing and emits exactly one satisfaction-penalty signal.
15. **[UNIT]** GIVEN `current_member_count == max_concurrent_members` and an arrival draw succeeds, **WHEN** the tick processes, **THEN** no member spawns, `member_id_counter` is NOT incremented, and no error/door-queue is created.
16. **[UNIT][WB]** GIVEN a member in WALKING_TO or QUEUEING, **THEN** at no tick does its occupied cell equal a solid footprint cell (GridSystem's solid set as oracle) — only access cells and the one-cell-short queue position are permitted equipment-adjacent cells.
17. **[UNIT]** GIVEN a cached path's `grid_version` differs from GridSystem's current version on a WALKING_TO tick, **WHEN** the member updates, **THEN** `Navigation.get_path` is re-queried exactly once that tick (mock Navigation, assert call count).
18. **[UNIT]** GIVEN a WALKING_TO member whose repath returns empty for `retry_limit` consecutive attempts, **WHEN** the limit is exceeded, **THEN** the member releases its reservation and transitions to LEAVING (bounded-retry exhaustion — distinct from AC1).
19. **[UNIT]** GIVEN a member that just abandoned equipment E via patience give-up, **WHEN** it re-runs SELECTING_TARGET the same/next tick, **THEN** E is excluded by the short-term novelty blacklist (no immediate flip-flop back to E).
20. **[UNIT]** GIVEN top-K candidate selection where two candidates have equal weight, **WHEN** they are sorted, **THEN** the tie-break is by ascending `equipment_instance_id` (deterministic).
21. **[UNIT]** GIVEN a LEAVING member for whom no exit path ever resolves, **WHEN** the defensive safety timeout elapses, **THEN** the member is forced to GONE (never permanently stuck — Pillar 2).
22. **[INT]** GIVEN a full arrival→MemberSim→Congestion tick loop over ~200 ticks run against two layouts (one clumped, one spread) with identical seed and equipment set, **WHEN** flow is measured, **THEN** the spread layout shows measurably lower average queue occupancy than the clumped one — the end-to-end "layout causally drives flow" hypothesis check.

## Open Questions

| # | Question | Owner | Target Resolution |
|---|---|---|---|
| OQ1 | MemberSim assumes `Congestion(t-1)` is a **per-equipment-instance normalized scalar in [0,1]** (0 idle, 1 fully congested). This is an interface assumption on Congestion (#7) and must be honored (or reconciled) when that GDD is authored. | Whoever designs Congestion (#7) | When Congestion is designed (next in order) |
| OQ2 | MemberSim's `use_duration` needs **new per-equipment fields on EquipmentCatalog** (`use_duration_mean_ticks`, `use_duration_stddev_ticks`, `use_duration_min_ticks`, `use_duration_max_ticks`). ✅ **已于 2026-07-19 在 EquipmentCatalog GDD 落实**：Core Rule 1 字段表新增 4 字段 + 规则7 加载期校验（mean>0 / stddev≥0 / min≤mean≤max）+ AC-U.1–U.4。跨文档门禁闭合，MemberSim 可在 `/dev-story` 前获得合法字段，无需另跑 `/propagate-design-change`。 | EquipmentCatalog GDD owner | ✅ Resolved 2026-07-19 |
| OQ3 | `satisfaction_modifier` (in `member_arrival_rate` and `exercises_per_visit`) is a placeholder = 1.0 until Satisfaction (#10) exists. Satisfaction must wire the real value. | Whoever designs Satisfaction (#10) | When Satisfaction is designed |
| OQ4 | Queue depth is capped at 1 for MVP (one waiting sprite per machine). Revisit if the fun-validation playtest shows deeper queues are needed to make bottlenecks legible. | game-designer, post-playtest | After the order-8 fun-validation milestone |
| OQ5 | Members spawn at a single `entrance_cell` and exit at a single `exit_cell`. **This is now a declared HARD upstream dependency on GridSystem (see Upstream dependencies above) — GridSystem's contract or a level-definition aligned to it must expose `entrance_cell` / `exit_cell` before MemberSim is implementable.** The fun-validation room layout must place them sensibly. | GridSystem / level definition | Before `/dev-story` of MemberSim (or `/prototype` of the core loop) |
| OQ6 | The fun-validation playtest protocol must use **≥2 instances of at least one equipment type** — with only one instance of every type, congestion-avoidance degenerates to a pure queue test and can't exercise the hypothesis. | Whoever runs `/prototype` + `/playtest-report` | At the order-8 milestone |
