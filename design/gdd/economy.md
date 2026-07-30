# Economy

> **Status**: In Design
> **Author**: user + agents
> **Last Updated**: 2026-07-20
> **Implements Pillar**: Pillar 2 (松弛不紧绷 — a purely *additive* resource; no bankruptcy, no debt, no lose condition) · Pillar 1 (空间即玩法 — money is how a good layout cashes out into a growing gym)
> **Creative Director Review (CD-GDD-ALIGN)**: Skipped — Lean review mode (not a PHASE-GATE at lean).
> **Closes EquipmentCatalog OQ2**: grounds the placeholder `provisional_equipment_cost` (200/350/650) against a real revenue model — the values hold, so they graduate from "provisional" to "validated."

## Overview

Economy is the money resource and revenue engine that closes the MVP loop: a good layout raises satisfaction, satisfaction brings more members, more members completing visits earns more cash, and cash buys more/better equipment to improve the layout again. It owns exactly one piece of state — the player's cash **`balance`** (an integer) — and one job: accrue income when members complete their visits, and let Shop/Purchase (#12) spend it. Its defining constraint is Pillar 2: money is a **purely additive, positive resource** — there is no rent, no bills, no upkeep that can drive the balance negative, no bankruptcy, and no lose condition. Running low is a *gate* ("can't afford that yet"), never a punishment. Crucially, Economy deliberately does **not** read satisfaction to compute revenue: because satisfaction already scales member *volume* upstream (via arrival rate), also scaling per-visit revenue by it would double-count satisfaction and produce runaway growth. Instead, revenue is a flat fee per completed visit, so satisfaction's only economic lever is throughput — one clean, auditable growth channel.

## Player Fantasy

Economy is the "white-hat tycoon" fantasy — the quiet satisfaction of a number ticking up because people like the place you built, and the small thrill of watching your balance cross the line that lets you finally afford that squat rack you've been eyeing. It is the honest, stress-free version of the business-builder loop: you never fear a bill, you never go under, you just *earn your way forward*. It serves Pillar 1 by being the meter where "good layout" finally becomes "bigger, better gym" — the reward that makes optimizing worth it — and Pillar 2 by being incapable of hurting you: a slow month just means a slower save-up, and the members always keep trickling in so you can always climb back. The feeling to protect: the "almost there… *there!*" of saving up for the next piece, and the momentum of each new machine making the next one come a little faster.

## Detailed Design

### Core Rules

1. **Tick-driven, deterministic, integer money.** Economy runs in TimeSystem's fixed order **after** MemberSim/Congestion/Satisfaction (so income reflects the visits that resolved this tick). `balance` is an **`int`** (whole currency units — never float, to avoid drift/rounding across ticks and saves). No RNG — revenue is fully deterministic.

2. **Revenue: flat fee per completed visit (quota-met departures only).** When a member reaches their `exercises_per_visit` quota and departs, MemberSim emits `member_completed_visit(member_id)`; Economy adds `R_visit` (provisional **$12**) to the balance and emits `balance_changed(new_balance, +R_visit)`. **Only quota-met departures earn revenue** — members who leave because they found zero reachable equipment (walk-in-leave) or exhausted patience earn **$0**. This preserves the causal chain: good layout → completed visits → revenue. Without this gate, a broken layout where every member immediately leaves would still generate full income, breaking the design intent. **Revenue contains zero reference to `global_satisfaction` / `satisfaction_modifier`** — satisfaction's economic influence flows *entirely* through member volume (arrivals), which it already drives upstream. Scaling revenue by satisfaction too would compound it twice (more members × more $/member) into a runaway curve, violating Pillar 2's calm, non-explosive spirit. Decoupling keeps satisfaction's economic lever to a single channel (throughput), which is auditable and stable.

3. **Balance rules.** `starting_capital` = **$500** (enough for two 1×1 machines at $200 each, so onboarding isn't an empty room, with a taste of "almost afford the next"). Income is applied at Economy's tick slot; multiple departures on one tick produce a single deterministic delta `N × R_visit` (sum is order-independent by construction — unlike Satisfaction's EMA, Economy's accrual is a pure commutative sum, so no fold order is needed). `balance` has a **floor of 0** (defensive `max(0, balance)`, never actually reached in normal flow because spending is pre-validated). It can never go negative.

4. **No upkeep (MVP).** There is **no** per-tick electricity/staff/rent cost. Even a floor-safe upkeep is a *subtractive* step bolted onto a system designed to be purely additive — it risks a "money got taken from me" loss-aversion feel that fights Pillar 2, with no compensating decision layer (no staff/electricity systems exist to make it meaningful). Revisit only post-MVP, and only paired with a matching upside mechanic — never in isolation.

5. **Spend interface (Shop #12 executes the transaction).** Economy exposes `can_afford(amount) -> bool` and `spend(amount) -> bool`. Both **reject `amount ≤ 0`** (returns false, no-op — prevents a negative-amount exploit where `spend(-100)` would pass `amount ≤ balance` and increase the balance). Shop/Purchase (#12) calls `spend()` to buy equipment; `spend()` is **triple-gated**: (a) `amount > 0`, (b) `amount ≤ balance`, (c) Shop is expected to pre-check with `can_afford` (defense in depth). Economy validates affordability but owns none of the purchase *UX* (that's Shop's). It emits `balance_changed(new_balance, delta)` for HUD (#16).

6. **The growth loop is self-limiting, not explosive.** buy machine → satisfaction rises (comfort/zone_synergy) → arrivals rise → throughput rises → afford the next machine, faster each time. The explosion guard is upstream: **`max_concurrent_members` caps population**, so even as satisfaction → 1.0 (modifier → 2.0), throughput ceilings at `cap / mean_visit_duration` — an S-curve, not exponential. Idle cash earns no interest (no compounding hoard incentive), which passively nudges toward reinvestment without punishing patience.

7. **Determinism & serialization.** Serialize **only** `balance: int` — no derived state, a trivial exact round-trip. Deterministic accrual: an identical MemberSim event sequence yields a bit-identical balance across runs and saves.

### States and Transitions

Economy has no player-facing states — just the running `balance` and its income/spend deltas:

| From | Event | To | Notes |
|---|---|---|---|
| — | `member_completed_visit` (quota-met only) | `balance += R_visit`; emits `balance_changed(new, +R_visit)` | at Economy's tick slot; sum is order-independent |
| — | Shop calls `spend(amount)`, `amount ≤ balance` | `balance −= amount`, returns true | emits `balance_changed` |
| — | Shop calls `spend(amount)`, `amount > balance` | unchanged, returns false | the affordability *gate* (not a failure) |

### Interactions with Other Systems

- **Upstream dependencies (hard)**:
  - **TimeSystem**: `on_tick()` (after Satisfaction); deterministic, no `get_rng`.
  - **MemberSim (#6)**: subscribes to `member_completed_visit(member_id)` — the sole revenue trigger.
- **Indirect influence (NOT a direct dependency)**:
  - **Satisfaction (#10)**: Economy does **not** read satisfaction. Satisfaction affects Economy only *indirectly*, by driving member arrival volume upstream. This refines the systems-index's inferred "Economy depends on Satisfaction" — the real direct deps are TimeSystem + MemberSim. Satisfaction's OQ3 ("Economy reads `global_satisfaction`/`satisfaction_modifier`") is **superseded**: HUD reads satisfaction directly for the reputation meter; Economy reads neither.
- **Downstream consumers (none have GDDs yet)**:
  - **Shop/Purchase (#12)**: calls `can_afford` / `spend`; owns the buy UX and (with EquipmentCatalog) the final cost values.
  - **HUD (#16)**: subscribes to `balance_changed`, displays the money counter.

## Formulas

> All values provisional MVP anchors for the fun-validation playtest.

The **revenue_per_visit** formula is defined as:

`balance += R_visit` on each `member_completed_visit`

**Variables:**
| Variable | Symbol | Type | Range | Description |
|----------|--------|------|-------|-------------|
| Per-visit fee | `R_visit` | int | provisional 12 (safe 8–20) | flat cash per completed visit; **no satisfaction multiplier** (avoids double-count) |
| Cash balance | `balance` | int | `[0, ∞)` | never negative |

**Output Range:** each event adds exactly `R_visit`; `balance` is unbounded above, floored at 0. **Example:** 3 members depart on one tick → `balance += 36`.

---

**Economic pacing** (steady-state throughput via Little's Law: `population ≈ arrival_rate × mean_visit_duration`), grounding the cost table:

> ⚠️ **Revised 2026-07-20 (design review).** Prior pacing assumed `mean_visit_duration ≈ 6 min`, which was ~3-4× too high vs. MemberSim's actual per-equipment `use_duration_mean_ticks` (150-250 = 15-25s) × `mean_exercises` (3) ≈ 45-75s active use + walk/queue overhead ≈ **~2 min** realistic mean visit. The population cap (17) does NOT bind in early/mid-game at 4/min arrivals × 2 min = ~8 concurrent. The cap binds only at higher arrival rates (satisfaction_modifier > ~2.0 at extreme conditions) or with more equipment per visit. Additionally, only **quota-met departures** earn revenue — not all departures are completions. Revenue throughput = completions/min, which depends on what fraction of members successfully complete their quota.

| Phase | arrival | visit dur. | population | completions/min | $/min | Next purchase | ~Time to afford |
|---|---|---|---|---|---|---|---|
| Ramp-up (0–5 min) | 4/min | ~2 min | building (~4-6) | ~0.5-1/min (few machines, many walk-failures) | $6-12 | 3rd machine ($200; $100 after start buys 2) | ~10-16 min |
| Early steady (G≈0.55) | 4/min | ~2 min | ~8 (cap not binding) | ~2-3/min (more machines → higher completion rate) | $24-36 | 1×2 upgrade ($350) | ~10-15 min |
| Mid-game (G≈0.7) | ~5.5/min (modifier≈1.4) | ~2.5 min (visit_length↑) | ~14 (approaching cap) | ~3-4/min | $36-48 | 2×2 ($650) | ~14-18 min |

Cumulative: first earned machine ~min 12, first 1×2 ~min 25, first 2×2 ~min 42 — a slightly longer save-up arc than prior estimate, still within a 30-120 min session. The completion-rate dependency adds a real lever: a good layout (higher completion %) earns faster than a bad one, reinforcing the causal chain. **Equipment costs (200/350/650) remain viable against `R_visit=$12` — the pace is longer but within the "satisfying save-up, not a grind" band. Provisional; tune at playtest.**

> ✅ Pacing now grounded on MemberSim's actual `use_duration_mean_ticks` (150-250) × `mean_exercises` (3). Visit duration grows with `visit_length_modifier` (from Satisfaction) — at higher satisfaction, longer visits slightly *reduce* throughput at the population cap, providing a natural self-limiting effect distinct from the cap itself. If playtest lands materially different means, re-check this pacing.

## Edge Cases

- **`balance = 0`**: a *gate* — `can_afford` returns false, purchases are blocked with a neutral "can't afford yet" (never a punitive message or a fail state). Members keep arriving, so the balance always climbs back.
- **A purchase that would overspend**: rejected by `can_afford` (Shop pre-check) and again by `spend` (Economy self-check) — double-gated; balance unchanged.
- **No members / zero-arrival period**: no income; `balance` stays flat, **never decays** (no upkeep). Not a loss.
- **Satisfaction at rock bottom**: arrivals floor at `satisfaction_modifier = 0.5` (upstream) → a trickle of visits persists → income never fully stops → progress is never permanently locked.
- **Negative/zero spend attempts**: `spend(0)` and `spend(negative)` are rejected (return false, no-op) — prevents a negative-amount exploit where `balance -= negative` would increase balance.
- **Non-quota departures**: members who leave without meeting their exercise quota (walk-failure, patience exhaustion) earn $0 — Economy does not process their departure signal.
- **Integer discipline**: all money is `int`; no fractional currency, no rounding drift across ticks/saves.
- **Serialization**: `balance: int` round-trips exactly; no derived or reconstructable state to desync.

## Dependencies

**Upstream dependencies (hard)**:

| System | Interface | Nature |
|---|---|---|
| TimeSystem | `on_tick()` (after Satisfaction) | Hard |
| MemberSim (#6) | subscribe `member_completed_visit(member_id)` | Hard |

**Indirect (not a direct dependency)**: Satisfaction (#10) — influences Economy only via arrival volume; Economy reads no satisfaction data. (Supersedes the index's inferred direct dependency and Satisfaction's OQ3.)

**Downstream dependents** (none have GDDs yet):

| System | Interface | Nature |
|---|---|---|
| Shop/Purchase (#12) | `can_afford(amount)` / `spend(amount)`; owns buy UX + final costs | Hard |
| HUD (#16) | subscribe `balance_changed(new_balance, delta)` | Soft |

**Bidirectional consistency notes**: closes EquipmentCatalog OQ2 (`provisional_equipment_cost` validated). MemberSim must emit `member_completed_visit` (add to its signal set — it currently emits satisfaction-relevant events; this is one more). Satisfaction's OQ3 is superseded (documented above). Verify at `/consistency-check`.

## Tuning Knobs

| Knob | Default | Safe Range | Too Low | Too High |
|---|---|---|---|---|
| **`R_visit`** ⭐ | 12 | 8–20 | Save-up is a grind; can't afford machines within a session | Money trivial; buy everything instantly, no save-up tension |
| `starting_capital` | 500 | 300–800 | Empty-room start, slow onboarding | Player buys the whole MVP set immediately, skips the loop |
| equipment cost table | 200/350/650 (owned by EquipmentCatalog / Shop #12) | — | Everything cheap → no pacing | Machines unaffordable → loop stalls |
| upkeep | **none (MVP)** | keep 0 | — | Any upkeep risks Pillar-2 loss-aversion feel; do not add without a paired upside |

**The ⭐ knob is `R_visit`** — together with the cost table and `max_concurrent_members`, it sets the whole save-up pacing. All provisional; tune at the fun-validation playtest.

## Visual/Audio Requirements

Economy renders no world content — its visible form is the **money counter**, owned by HUD (#16): a calm running total that ticks up on income and down on purchase. A soft, pleasant "income" cue (a gentle coin/chime) on a completed visit, and a satisfying purchase confirmation sound, are nice-to-haves for audio-director (not required for MVP; must stay *pleasant*, never an anxious cash-register alarm — Pillar 2). No asset owned here.

## UI Requirements

None of its own — the money display is HUD (#16)'s; the buy interaction is Shop/Purchase (#12)'s. Economy only exposes the balance + spend interface.

## Acceptance Criteria

### Unit Tests (BLOCKING) — `tests/unit/economy/`

> Economy is a **Logic** story. All unit-level criteria are BLOCKING automated tests.

1. **Never negative**: GIVEN a sequence of income and `spend` operations that includes at least one `spend(amount)` where `amount > balance`, **WHEN** applied, **THEN** `balance` is never < 0 at any point and the overspend call returns false.
2. **Spend gating (overspend)**: GIVEN `spend(amount)` with `amount > balance`, **WHEN** called, **THEN** it returns false, `balance` is unchanged, and no `balance_changed` fires.
3. **Spend gating (zero/negative)**: GIVEN `spend(0)` or `spend(-100)`, **WHEN** called, **THEN** it returns false, `balance` is unchanged, and no `balance_changed` fires (prevents negative-amount exploit).
4. **Spend success**: GIVEN `spend(amount)` with `amount > 0` and `amount ≤ balance`, **WHEN** called, **THEN** it returns true, `balance -= amount`, and `balance_changed(new, -amount)` fires exactly once.
5. **can_afford consistency**: GIVEN `amount > 0`, **WHEN** `can_afford(amount)` is true, **THEN** a subsequent `spend(amount)` with no intervening change succeeds; when false, it fails. Also: `can_afford(0)` and `can_afford(-1)` return false.
6. **Deterministic accrual**: GIVEN a fixed array of `member_completed_visit` payloads fed directly into `Economy.on_member_completed_visit()`, **WHEN** processed in two separate Economy instances, **THEN** both produce the identical balance trace.
7. **No satisfaction dependency (structural check)**: GIVEN Economy's revenue path, **WHEN** a test double with `global_satisfaction` / `satisfaction_modifier` properties that throw-on-read is attached as a dependency, **THEN** calling revenue accrual N times never invokes any satisfaction accessor and `balance == starting_capital + N × R_visit`.
8. **Flat fee**: GIVEN N `member_completed_visit` events, **WHEN** income accrues, **THEN** `balance` increases by exactly `N × R_visit`.
9. **Multi-departure determinism**: GIVEN multiple `member_completed_visit` events on one tick, **WHEN** income is applied, **THEN** the result is a single deterministic delta `N × R_visit` (sum is order-independent by construction).
10. **No decay / no upkeep**: GIVEN a period with zero departures and no `spend` calls, **WHEN** ticks advance, **THEN** `balance` is unchanged (never decays).
11. **Starting capital**: GIVEN `Economy.new()` (fresh-state constructor), **WHEN** `balance` is read immediately with no prior events, **THEN** `balance == 500`.
12. **Serialization round-trip**: GIVEN any `balance`, **WHEN** serialized and reloaded, **THEN** the value is identical (int, no reconstruction ambiguity) and the next accrual matches uninterrupted play.
13. **Income emits balance_changed**: GIVEN a `member_completed_visit` event processed by Economy, **WHEN** revenue accrues, **THEN** `balance_changed(new_balance, +R_visit)` fires exactly once with a positive delta.
14. **Only quota-met departures earn revenue**: GIVEN a member that departed without meeting their exercise quota (walk-failure or patience-exhausted), **WHEN** Economy processes the departure, **THEN** no revenue accrues and no `balance_changed` fires.

### Integration / Playtest Criteria (ADVISORY) — `tests/integration/economy/`

15. **Progress never locks**: GIVEN `balance = 0`, **WHEN** one `member_completed_visit` event is processed directly, **THEN** `balance == R_visit` and `can_afford(R_visit)` returns true. The upstream guarantee (satisfaction modifier floors at 0.5 → arrivals persist → completions eventually occur) is tested by Satisfaction's own integration suite, not duplicated here.

## Open Questions

| # | Question | Owner | Target Resolution |
|---|---|---|---|
| OQ1 | **MemberSim handoff**: Economy's sole revenue trigger is a `member_completed_visit(member_id)` signal that MemberSim must emit **only when a member departs via the quota-met path** (`exercises_done == exercises_per_visit` → LEAVING → GONE). Walk-failure and patience-exhausted departures must NOT emit this signal. MemberSim's current GDD does not declare this signal — add it to MemberSim's signal set and downstream-consumer list via `/propagate-design-change`. | MemberSim GDD owner | Before `/dev-story`; via `/propagate-design-change` or a MemberSim edit |
| OQ2 | ~~The pacing math assumes `mean_visit_duration ≈ 6 min`~~ **REVISED 2026-07-20**: pacing now uses ~2 min mean visit based on MemberSim's actual `use_duration_mean_ticks` (150-250) × `mean_exercises` (3). EquipmentCatalog use-duration fields landed 2026-07-19 (resolved). The pacing table is provisional — re-check if playtest reveals materially different durations. | — | ✅ Partially resolved (fields exist; pacing recalculated; final tune at playtest) |
| OQ3 | **Shop/Purchase (#12)** owns the buy transaction, the final displayed cost, and the purchase UX; Economy exposes `can_afford`/`spend`/`balance_changed`. Confirm the interface (and that Shop, with EquipmentCatalog, owns the cost table) when Shop is designed. | Whoever designs Shop/Purchase (#12) | When Shop is designed (next in order) |
| OQ4 | `R_visit` (12) × cost table (200/350/650) × `starting_capital` (500) × `max_concurrent_members` jointly set the save-up pacing. Provisional; the fun-validation playtest tunes them for the "satisfying save-up, not a grind" feel. | game-designer / economy-designer, post-playtest | At the fun-validation milestone |
| OQ5 | Upkeep is intentionally **absent** in MVP (Pillar 2). If ever added post-MVP, it must be floor-safe AND paired with a matching upside mechanic (staff productivity etc.), never a standalone drain. | economy-designer | Post-MVP only |
