# Satisfaction

> **Status**: In Design
> **Author**: user + agents
> **Last Updated**: 2026-07-20
> **Implements Pillar**: Pillar 2 (松弛不紧绷 — the meter that never punishes; low satisfaction only slows growth, never fails) · Pillar 1 (空间即玩法 — turns layout quality into a felt payoff) · Pillar 3 (一眼看懂 — a single calm reputation meter)
> **Creative Director Review (CD-GDD-ALIGN)**: Skipped — Lean review mode (not a PHASE-GATE at lean).
> **Interface-anchoring role**: this GDD resolves three provisional interfaces the upstream systems deferred to it — MemberSim's `satisfaction_modifier` (its OQ3), ZoneRules' `S_max`/`C_max` pull-vs-push balance (its OQ3), and Congestion's per-equipment scalar as a satisfaction input (its OQ3).

## Overview

Satisfaction is the numeric heart that answers "is my layout actually good?" It combines the three signals the rest of the sim produces — ZoneRules' *static* layout quality (comfort, zone synergy, spaciousness), Congestion's *dynamic* crowding pressure, and MemberSim's per-member experience events (queueing, failed walks, interrupted uses) — into a per-member satisfaction, then rolls departing members' satisfaction into a slow, gym-level **`global_satisfaction`** reputation meter. That meter feeds a `satisfaction_modifier` that gently accelerates or slows member arrivals and visit length, and (later) drives revenue in Economy (#11). Its defining constraint is Pillar 2: satisfaction is a **positive-pressure dial, never a failure state** — a poor layout simply grows the gym slowly and stabilizes at a calm, sparse, "sad but stable" plateau the player can always recover from by rearranging; there is no bankruptcy, no death spiral, and a structural floor guarantees a trickle of arrivals even at rock bottom. Satisfaction is deliberately the **slow macro meter**: the fast, moment-to-moment "did my rearrangement help?" feedback lives in Congestion's heatmap and ZoneRules' synergy preview (responding in ~1 s); satisfaction is the reputation that builds over tens of seconds behind them.

## Player Fantasy

Satisfaction is where "my gym is *loved*" becomes a number you can watch climb. The player doesn't experience it as a formula — they experience it as the slow, earned rise of a reputation meter after they've untangled a bottleneck and clustered their strength machines just right, and the quiet, guilt-free sag when a layout is cramped (a sag that says "there's room to improve here," never "you failed"). It is the macro reward that makes the micro-tinkering matter: the heatmap tells you *where* the problem is right now, but satisfaction tells you your gym is *becoming* a place people want to come to. It serves Pillar 2 above all — it is engineered so that a bad result is never punishing, only an invitation — and Pillar 1, because it is the meter that finally cashes out "good layout" into "thriving gym." The feeling to protect: watching the meter tick up after a satisfying rearrange, and knowing you earned it.

## Detailed Design

### Core Rules

1. **Tick-driven, deterministic, member-independent of RNG.** Satisfaction runs in TimeSystem's fixed order (after Congestion, so it can read `Congestion(t-1)`), uses **no RNG**, and is fully deterministic for saves. It reads Congestion and ZoneRules outputs and MemberSim events; it writes only its own state.

2. **Per-member accumulation, owned here (not by MemberSim).** Satisfaction maintains `member_accumulators: Dictionary[member_id -> Accumulator]`, where `Accumulator = {S_acc, n_uses, queue_ticks, n_fail, n_interrupt}`. It creates an accumulator when MemberSim signals a member has entered, updates it from that member's events, and on the member's departure computes their final `S_member` and folds it into the global meter, then discards the accumulator. Keeping this here (not in MemberSim's state machine) avoids burdening MemberSim with satisfaction logic. The dictionary is **serialized** (same granularity as MemberSim's already-serialized `reservations` / `member_id_counter`).

3. **Per-use layer-quality signal (`use_quality_i`) — the pull-vs-push resolution.** Each time a member *completes* using equipment instance `i`, Satisfaction records a net signal that balances ZoneRules' reward against Congestion's pressure with **equal weight** (`w_zone = w_cong = 0.5`), so neither "cluster for synergy" nor "spread for flow" can dominate a single use event. `Congestion_i(t-1)` is read as a single snapshot at the moment the member *starts* using `i` (consistent with the project-wide "read t-1" rule), not integrated over the use. See Formulas.

4. **Per-member satisfaction (`S_member`) starts neutral.** A member's visit satisfaction begins at a neutral baseline `S_base = 0.5` (a member who used nothing and hit no trouble lands exactly at "neither good nor bad" — a blank visit is not a punishment, Pillar 2), adjusted by the average of their `use_quality` events minus small, **individually capped** penalties for queueing time, walk-failures, and mid-use interruptions. Each penalty term has an explicit cap (`cap_fail = 0.30`, `cap_interrupt = 0.20`) so one-off event penalties are always **smaller in magnitude** than the zone/congestion terms — queue noise and bad-luck events never drown out the core spatial-optimization signal. Clamped to `[0,1]`. See Formulas.

5. **Global reputation meter (`global_satisfaction`), slow event-driven EMA.** On each member departure, their `S_member` folds into `global_satisfaction` via a slow EMA (`α_g = 0.05`); ticks with no departure leave it unchanged (no silent decay). It initializes to `0.5` (neutral — no false pre-punishment before anyone has visited). Multiple departures on one tick fold in ascending `member_id` order (deterministic). This is the **slow macro meter** by design — the fast "did my rearrange help" feedback is Congestion's heatmap + ZoneRules' preview, not this.

6. **`satisfaction_modifier` (fulfills MemberSim OQ3) + a damped visit modifier.** `global_satisfaction ∈ [0,1]` maps to:
   - **`satisfaction_modifier ∈ [0.5, 2.0]`** — drives MemberSim's **arrival rate**. Piecewise-linear so `G = 0.5 → 1.0` exactly (seamless with MemberSim's current placeholder `1.0`; activating this system causes no jump). **Structurally floors at 0.5** (at `G = 0`) — never 0, so arrivals never stop and recovery is always possible (the anti-death-spiral mechanism, not an afterthought clamp).
   - **`visit_length_modifier ∈ [~0.75, 1.5]`** — a **damped** version driving MemberSim's `exercises_per_visit`. Because arrivals *and* visit length both scaling with the full modifier would make occupancy scale ~modifier² (an oscillation/resonance risk flagged by economy review), the visit-length leg uses half the deviation, keeping the loop gently self-correcting. **MemberSim must consume `visit_length_modifier` (not the raw `satisfaction_modifier`) for `exercises_per_visit`** — a reconciliation on MemberSim's provisional formula (see Dependencies / Open Questions).

7. **Self-correcting loop, no death spiral (verified).** The loop — satisfaction → arrivals/visit-length → members → congestion → satisfaction — is **negative feedback on congestion**: low satisfaction → fewer members → *less* congestion → satisfaction recovers. It stabilizes at whatever `zone_synergy` a layout earns at low congestion (a low-but-nonzero "calm and sparse" equilibrium for a poor layout), never at zero. The `satisfaction_modifier` floor (0.5) plus MemberSim's `exercises_per_visit ≥ 1` floor guarantee the recovery loop stays *observable* (there's always a trickle of members generating signal).

8. **Determinism & serialization.** Serialized: `global_satisfaction` (float) + `member_accumulators` (per-member `{S_acc, n_uses, queue_ticks, n_fail, n_interrupt}`). No RNG. Congestion always read as the `t-1` snapshot. Fixed departure-fold order (ascending `member_id`).

### States and Transitions

Satisfaction has no player-facing states. Its lifecycle is per-member accumulator management + the running global meter:

| From | Event | To | Notes |
|---|---|---|---|
| — | MemberSim signals member entered | accumulator created | `S_acc` etc. zeroed |
| accumulator active | member completes a use of `i` | accumulator updated | append `use_quality_i` |
| accumulator active | member queues / fails / is interrupted | accumulator updated | increment counters |
| accumulator active | member departs (GONE) | folded → global, discarded | compute `S_member`, EMA into `global_satisfaction` |
| — | tick with no departures | unchanged | `global_satisfaction(t) = global_satisfaction(t-1)` |

### Interactions with Other Systems

- **Upstream dependencies (hard)**:
  - **TimeSystem**: `on_tick()` (after Congestion); no `get_rng` (deterministic, no RNG).
  - **ZoneRules (#9)**: per-instance `{comfort, zone_synergy, spaciousness, total}` for machines a member used.
  - **Congestion (#7)**: `Congestion_i(t-1)` per-equipment scalar (read at use-start).
  - **MemberSim (#6)**: per-member events (entered, use-completed with equipment instance id, queue ticks, walk-failures, mid-use interruptions, departed).
- **Downstream consumers**:
  - **MemberSim (#6)**: reads `satisfaction_modifier` (arrival rate) and `visit_length_modifier` (exercises_per_visit) — closes MemberSim OQ3, with the damped-visit reconciliation.
  - **Economy (#11, not yet designed)**: does NOT read satisfaction directly — Economy feels satisfaction **indirectly** via MemberSim's arrival volume (driven by `satisfaction_modifier`). Satisfaction bakes in **no $ amount**; revenue balance is Economy's decision (coordination rule 5).
  - **HUD (#16)**: displays `global_satisfaction` as the reputation meter.
- **Bidirectional consistency notes**: MemberSim's GDD lists `satisfaction_modifier` as a placeholder (its OQ3) — fulfilled here, plus the new `visit_length_modifier` split (MemberSim's `exercises_per_visit` formula must switch to it). ZoneRules (#9) and Congestion (#7) both note their balance is "reconciled when Satisfaction #10 lands" — resolved here via `use_quality`'s equal weights; their registry notes should be cross-referenced. Verify at `/consistency-check`.

## Formulas

> All weights/constants are **provisional MVP anchors** for the fun-validation playtest.

The **use_quality** formula (per completed use of instance `i`):

`use_quality_i = w_zone × clamp(total_i / Z_NORM, 0, 1) − w_cong × Congestion_i(t-1)`

**Variables:**
| Variable | Symbol | Type | Range | Description |
|----------|--------|------|-------|-------------|
| ZoneRules instance total | `total_i` | float | `[0, ~2.409)` | `comfort + zone_synergy + spaciousness` (S_max=1.0, C_max=0.5; range updated for perimeter-normalized zone_synergy, k=2.4) |
| Normalizer | `Z_NORM` | float | 2.0 | anchors a "top-tier" instance (`z≈1.0`) to the same scale as full congestion |
| Congestion at use-start | `Congestion_i(t-1)` | float | `[0,1]` | single snapshot when the member begins USING `i` |
| Zone / congestion weights | `w_zone, w_cong` | float | 0.5 / 0.5 ⭐ | **equal** — the pull-vs-push balance; neither dominates a use |
| Net use signal | `use_quality_i` | float | `[−0.5, +0.5]` | symmetric: a perfect use (+0.5) and a worst use (−0.5) are equal and opposite |

**Output Range:** `[−0.5, +0.5]`. **Example:** `comfort=0.8, zone_synergy=0.451, spaciousness=0.333 → total=1.584 → z=0.792`; `Congestion=0.3` → `use_quality = 0.5·0.792 − 0.5·0.3 = 0.246`.

---

The **S_member** formula (on departure):

`S_member = clamp( S_base + avg(use_quality over completed uses) − queue_penalty − fail_penalty − interrupt_penalty , 0, 1 )`
where `queue_penalty = w_queue · clamp(queue_ticks_total / queue_norm_ticks, 0, 1)`
and `fail_penalty = min(w_fail · n_fail, cap_fail)`, `interrupt_penalty = min(w_interrupt · n_interrupt, cap_interrupt)`

**Variables:**
| Variable | Symbol | Type | Range | Description |
|----------|--------|------|-------|-------------|
| Neutral baseline | `S_base` | float | 0.5 | a blank visit lands neutral, not at 0 (Pillar 2) |
| Avg use quality | `avg(use_quality)` | float | `[−0.5,+0.5]` | `0` if `n_uses = 0` (no divide-by-zero); `S_member = S_base` when `n_uses = 0` and all penalties are 0 |
| Queue penalty | `queue_penalty` | float | `[0, 0.3]` | `w_queue=0.3`, `queue_norm_ticks=100` (10 s) |
| Fail penalty (capped) | `fail_penalty` | float | `[0, 0.30]` | `w_fail=0.15` per event, `cap_fail=0.30` (max 2 failures contribute) |
| Interrupt penalty (capped) | `interrupt_penalty` | float | `[0, 0.20]` | `w_interrupt=0.20` per event, `cap_interrupt=0.20` (max 1 interrupt contributes) |
| Counts | `n_fail, n_interrupt` | int | ≥ 0 | from MemberSim events |
| Visit satisfaction | `S_member` | float | `[0,1]` | folded into the global meter |

**Output Range:** `[0,1]`. Max total event penalty = 0.30 + 0.20 + 0.30 = 0.80 (all three caps hit), always leaving `S_base + avg(use_quality)` as the dominant term for members with any positive use events. **Example:** uses `[0.246, 0.1, −0.05]` → `avg=0.099`; `queue_ticks=40 → penalty=0.12`; no fail/interrupt → `S_member = clamp(0.5+0.099−0.12,0,1) = 0.479`.

---

The **global_satisfaction** formula (event-driven EMA, on each departure):

`global_satisfaction(t) = α_g × S_member_departing + (1 − α_g) × global_satisfaction(t-1)`; unchanged on ticks with no departure.

**Variables:**
| Variable | Symbol | Type | Range | Description |
|----------|--------|------|-------|-------------|
| Global smoothing | `α_g` | float | 0.05 (safe 0.02–0.15) | slow — one member can't swing the gym's reputation |
| Reputation meter | `global_satisfaction` | float | `[0,1]` | init 0.5; what HUD / Economy / the modifier read |

**Output Range:** `[0,1]`. **Example:** `global(t-1)=0.55`, departing `S_member=0.479` → `global(t)=0.05·0.479+0.95·0.55=0.5465`.

---

The **satisfaction_modifier** and **visit_length_modifier** formulas (`G = global_satisfaction`):

`G_c = clamp(G, 0, 1)` (defensive — upstream should guarantee `[0,1]`, but this protects the anti-spiral floor)
`satisfaction_modifier(G_c) = G_c + 0.5` if `G_c < 0.5`; `= 2·G_c` if `G_c ≥ 0.5`  →  range `[0.5, 2.0]`, with `G_c=0.5 → 1.0`
`visit_length_modifier(G) = 1 + (satisfaction_modifier(G) − 1) × damp`, `damp = 0.5`  →  range `[0.75, 1.5]`

**Variables:**
| Variable | Symbol | Type | Range | Description |
|----------|--------|------|-------|-------------|
| Arrival modifier | `satisfaction_modifier` | float | `[0.5, 2.0]` | MemberSim arrival rate; **floors at 0.5**, never 0 (anti-spiral) |
| Damping | `damp` | float | 0.5 | halves the visit-length leg's deviation (prevents ~modifier² occupancy) |
| Visit modifier | `visit_length_modifier` | float | `[0.75, 1.5]` | MemberSim `exercises_per_visit` |

**Output Range:** modifier `[0.5,2.0]`, visit `[0.75,1.5]`. **Example:** `G=0.5465 → modifier=1.093` (reputation rising, recruiting slightly faster); `visit_length_modifier = 1 + 0.093·0.5 = 1.047`.

## Edge Cases

- **No members yet / no departures**: `global_satisfaction` holds at its init `0.5` → `satisfaction_modifier = 1.0` (neutral). No divide-by-zero.
- **A member who used 0 machines (bounced immediately)**: `avg(use_quality) = 0`; `S_member` driven only by any fail penalty, clamped ≥ 0.
- **Fully congested gym**: `use_quality_i` trends to `−0.5`; `S_member` bottoms at 0; but `satisfaction_modifier` floors at 0.5 → a trickle of arrivals persists → congestion eases → recovery. No spiral.
- **Empty layout (no equipment)**: every member walk-fails; `S_member` driven by `n_fail` penalty, clamped at 0; global drifts down but modifier floors at 0.5.
- **Divide-by-zero guards**: `n_uses = 0 → avg = 0`; `queue_penalty` capped at 0.3 regardless of `queue_ticks_total`.
- **Same-zone "spam" degenerate strategy**: already prevented upstream — ZoneRules' `zone_synergy` is asymptotic (diminishing returns, ~no gain past 3 same-zone neighbors, orthogonal-neighbor cap 4), so packing a mega-zone does not scale synergy without bound. Satisfaction inherits that bound; no extra guard needed here.
- **Interior optimum (no dominant strategy)**: with `w_zone = w_cong`, neither max-cluster (high synergy, high congestion) nor max-spread (zero congestion, zero synergy) wins outright — the optimum sits at partial clustering with walkways. This is the intended puzzle; flagged for playtest verification.

## Dependencies

**Upstream dependencies (hard)**:

| System | Interface | Nature |
|---|---|---|
| TimeSystem | `on_tick()` (after Congestion) | Hard |
| ZoneRules (#9) | per-instance `{comfort, zone_synergy, spaciousness, total}` | Hard |
| Congestion (#7) | `Congestion_i(t-1)` per-equipment scalar | Hard |
| MemberSim (#6) | per-member events (entered / use-completed / queue / fail / interrupt / departed) | Hard |

**Downstream dependents**:

| System | Interface | Nature |
|---|---|---|
| MemberSim (#6) | `satisfaction_modifier` (arrivals) + `visit_length_modifier` (exercises_per_visit) | Hard (closes MemberSim OQ3; requires MemberSim to switch its `exercises_per_visit` to the damped modifier) |
| Economy (#11, undesigned) | **Indirect only** — Economy does NOT read `global_satisfaction` or `satisfaction_modifier` directly; it feels satisfaction via MemberSim's arrival volume (which `satisfaction_modifier` drives). Satisfaction bakes in **no $**; revenue balance is Economy's decision. | Soft (indirect) |
| HUD (#16, undesigned) | `global_satisfaction` (reputation meter) | Soft |

**Bidirectional consistency notes**: this GDD resolves the deferred balance in ZoneRules (`S_max`/`C_max` via `use_quality` weights) and Congestion (per-equipment scalar consumed), and fulfills MemberSim OQ3. Those GDDs' registry notes ("reconciled when Satisfaction #10 lands") should be cross-referenced. Verify at `/consistency-check`.

## Tuning Knobs

| Knob | Default | Safe Range | Too Low | Too High |
|---|---|---|---|---|
| **`w_zone` : `w_cong`** ⭐ | 0.5 : 0.5 | keep comparable | If `w_zone ≪ w_cong`: spread-to-empty wins, synergy pointless | If `w_zone ≫ w_cong`: cluster-and-ignore-crowds wins, flow pointless |
| `Z_NORM` | 2.0 | 1.5–2.5 | Zone term saturates early, loses resolution | Zone term never reaches 1, under-weights synergy |
| `α_g` (global EMA) | 0.05 | 0.02–0.15 | Reputation barely moves — rearrangements feel unrewarded at the macro level | Whiplash — one bad member tanks the gym (anxiety, breaks Pillar 2) |
| `S_base` | 0.5 | 0.4–0.6 | Blank visits read as bad (punishing) | Blank visits read as great (no incentive to improve) |
| `w_queue` / `queue_norm_ticks` | 0.3 / 100 | — | Queues never matter | Queue noise drowns the spatial signal |
| `w_fail` / `w_interrupt` | 0.15 / 0.20 | small | One-off events invisible | One-off events dominate over layout quality |
| `cap_fail` / `cap_interrupt` | 0.30 / 0.20 | 0.15–0.50 / 0.10–0.40 | Caps too tight, many-fail visits indistinguishable | Caps too loose, event penalties dominate zone/congestion signal |
| `damp` (visit leg) | 0.5 | 0.3–0.7 | Visit length barely responds | Occupancy oscillation returns (→ modifier²) |
| modifier curve shape | piecewise-linear (`G=0.5→1.0`) | — | — | **Alternative to try at playtest**: a sigmoid `0.5 + 1.5·sigmoid(k·(G−0.5))`, `k≈6–8`, gives a calmer deadband near neutral (economy-designer's preference) but must be anchored so `G=0.5→1.0`; MVP keeps piecewise-linear for clean neutral continuity |

**The ⭐ knob (`w_zone` : `w_cong`) is the master pull-vs-push dial** — it, plus ZoneRules' `S_max`/`C_max` and Congestion's `k_congestion`, are the numbers the fun-validation playtest exists to tune. All provisional.

## Visual/Audio Requirements

Satisfaction produces a number, not pixels. Its visible form is the **reputation meter**, owned by HUD (#16): a single calm gauge showing `global_satisfaction`, rising/falling **slowly and gently** (never a flashing alarm or a red "danger" state — Pillar 2; use the art bible's warm palette, e.g. Butter/Sage for high, a soft neutral for low, never harsh red). A soft positive chime when the meter crosses an upward threshold is a nice-to-have for audio-director (not required for MVP). No asset is owned here.

## UI Requirements

None of its own — the reputation meter is HUD (#16)'s to lay out. This GDD only constrains that the meter read as **calm and slow** (per Visual/Audio), never as a threat.

## Acceptance Criteria

### Unit Tests (BLOCKING) — `tests/unit/satisfaction/`

> Satisfaction is a **Logic** story — all unit-level criteria require a **BLOCKING** automated test. Criteria synthesized from systems-designer (formula/determinism) and economy-designer (loop stability).

1. **Determinism**: GIVEN a fixed event sequence (entered / use-completed with a congestion snapshot / queue / departed), **WHEN** replayed twice, **THEN** every `S_member` and `global_satisfaction` value is bit-identical.
2. **Modifier bounds + anti-spiral floor**: GIVEN any `G ∈ [0,1]`, **WHEN** `satisfaction_modifier(clamp(G, 0, 1))` is computed, **THEN** it ∈ `[0.5, 2.0]`, and at `G = 0` it is **strictly 0.5** (never 0). Input defensively clamped to `[0,1]` before the piecewise formula.
3. **Neutral continuity**: GIVEN `G = 0.5`, **WHEN** `satisfaction_modifier` is computed, **THEN** it equals exactly `1.0` (seamless with MemberSim's placeholder).
4. **Visit modifier damping**: GIVEN any `G`, **WHEN** `visit_length_modifier(G)` is computed, **THEN** it ∈ `[0.75, 1.5]` and its deviation from 1.0 is exactly half that of `satisfaction_modifier(G)`.
5. **Monotonicity — congestion**: GIVEN all else fixed, **WHEN** `Congestion_i(t-1)` for a used instance increases, **THEN** the using member's `S_member` strictly decreases.
6. **Monotonicity — synergy**: GIVEN all else fixed, **WHEN** `zone_synergy_i` (hence `total_i`) increases, **THEN** the using member's `S_member` strictly increases.
7. **Monotonicity — modifier**: GIVEN two satisfaction values `G1 < G2`, **WHEN** modifiers are computed, **THEN** `satisfaction_modifier(G1) ≤ satisfaction_modifier(G2)` (non-decreasing).
8. **Bounds/clamping**: GIVEN any inputs, **WHEN** computed, **THEN** `use_quality_i ∈ [−0.5, 0.5]`, `S_member ∈ [0,1]`, `global_satisfaction ∈ [0,1]`.
9. **Symmetric use signal**: GIVEN a perfect use (`total_i` at cap, `Congestion=0`) and a worst use (`total_i=0`, `Congestion=1`), **WHEN** `use_quality` is computed, **THEN** the two are `+0.5` and `−0.5` (equal and opposite — neither pull nor push dominates).
10. **Zero-use member baseline**: GIVEN a member with `n_uses = 0` AND `n_fail = 0` AND `queue_ticks = 0` AND `n_interrupt = 0`, **WHEN** `S_member` is computed, **THEN** `avg(use_quality) = 0`, no NaN/exception, and `S_member == S_base == 0.5`.
11. **Queue penalty cap**: GIVEN `queue_ticks_total` far exceeding `queue_norm_ticks`, **WHEN** `queue_penalty` is computed, **THEN** it is ≤ 0.3.
12. **Fail/interrupt penalty caps**: GIVEN `n_fail = 10, n_interrupt = 10`, **WHEN** `fail_penalty` and `interrupt_penalty` are computed, **THEN** `fail_penalty ≤ 0.30` and `interrupt_penalty ≤ 0.20`.
13. **Deterministic multi-departure**: GIVEN multiple members departing on one tick, **WHEN** folded into `global_satisfaction`, **THEN** they fold in ascending `member_id` order (reproducible).
14. **No silent drift**: GIVEN a tick with no departures, **WHEN** it processes, **THEN** `global_satisfaction(t) == global_satisfaction(t-1)` bit-for-bit.
15. **Serialization round-trip**: GIVEN mid-visit accumulators and a `global_satisfaction` value, **WHEN** serialized and reloaded, **THEN** the next tick's computation is bit-identical to uninterrupted play. The test must trigger a use-completion or departure after reload to verify accumulator fields survive.
16. **Defensive modifier clamp**: GIVEN `G` outside `[0,1]` (e.g., due to an upstream bug), **WHEN** `satisfaction_modifier(G)` is computed, **THEN** input is clamped to `[0,1]` before the piecewise formula, and the anti-spiral guarantee (`modifier ≥ 0.5`) holds.

### Integration / Playtest Criteria (ADVISORY) — `tests/integration/satisfaction/`

> These criteria require the full tick loop and are **ADVISORY** (not blocking for CI). They verify emergent system behavior that unit tests cannot capture.

17. **Self-correcting recovery (no death spiral)**: GIVEN a maximally-congested gym driving `global_satisfaction` toward 0, **WHEN** the loop runs (arrivals floor at modifier 0.5 → fewer members → congestion eases), **THEN** `global_satisfaction` stops falling and recovers by ≥ 0.01 within 200 departures — it never reaches a stuck/zero-arrival state.
18. **No single dominant strategy**: GIVEN two layouts — one max-clustered (high synergy, high congestion) and one max-spread (zero congestion, zero synergy) — run over a fixed member timeline, **WHEN** their `global_satisfaction` settles, **THEN** neither strictly dominates; a partial-cluster-with-walkways layout scores at least as high as both (interior optimum). *(Playtest-grade integration check; the numeric target is provisional — see OQ4.)*

## Open Questions

| # | Question | Owner | Target Resolution |
|---|---|---|---|
| OQ1 | **MemberSim reconciliation**: MemberSim's `exercises_per_visit` currently uses `satisfaction_modifier`; it must switch to the damped `visit_length_modifier` (to avoid ~modifier² occupancy oscillation). This is a change to MemberSim's provisional formula — via `/propagate-design-change` or a MemberSim edit, not silently. `arrival_rate` continues to use the full `satisfaction_modifier`. | MemberSim GDD owner | Before `/dev-story` of MemberSim or Satisfaction |
| OQ2 | Modifier curve: MVP uses piecewise-linear (clean `G=0.5→1.0`). economy-designer prefers a sigmoid for a calmer deadband near neutral. Try both at the fun-validation playtest and pick by feel; the sigmoid must be anchored so `G=0.5→1.0`. | game-designer / economy-designer, post-playtest | At the fun-validation milestone |
| OQ3 | **Economy (#11) interface**: RESOLVED — Economy does NOT read `global_satisfaction` or `satisfaction_modifier` directly (confirmed by economy.md). Economy feels satisfaction **indirectly** via MemberSim's arrival volume (driven by `satisfaction_modifier`). Satisfaction bakes in **no revenue/$**; Economy owns all $ balance. Downstream dependency table updated accordingly. | — | RESOLVED (2026-07-20, design review) |
| OQ4 | **The master balance** — `w_zone`:`w_cong` (here) × ZoneRules `S_max`/`C_max` × Congestion `k_congestion` — is the joint knob set the whole fun-validation playtest exists to tune. Provisional until then; AC15 (no dominant strategy) is the acceptance gate. | game-designer, post-playtest | At the fun-validation milestone |
| OQ5 | (Optional extra damping) economy-designer suggested rate-limiting the *arrival-count* response (cap % change per in-game minute) to further smooth the population leg. Not in MVP scope; revisit only if the playtest shows population snap/oscillation. | MemberSim / economy-designer | Only if playtest reveals oscillation |
| OQ6 | Window/edge `comfort` inputs (inherited from ZoneRules OQ2) would feed satisfaction indirectly once level-features (windows) exist. No action until then. | GridSystem / level definition | When level features are designed |
