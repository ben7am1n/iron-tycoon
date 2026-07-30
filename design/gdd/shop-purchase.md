# Shop / Purchase

> **Status**: In Design
> **Author**: user + agents
> **Last Updated**: 2026-07-20
> **Implements Pillar**: Pillar 1 (空间即玩法 — buying is how a thriving gym grows) · Pillar 2 (松弛不紧绷 — "can't afford yet" is a gentle gate, never a failure)
> **Creative Director Review (CD-GDD-ALIGN)**: Skipped — Lean review mode (not a PHASE-GATE at lean).

## Overview

Shop/Purchase is the thin logic layer that turns "I want to buy this" into "money spent + a new piece placed on the grid." It presents the purchasable equipment (via EquipmentCatalog), gates each item by affordability (Economy) and unlock state, and — crucially — spends money **only when a purchased piece is actually committed to the grid** by PlacementSystem. It is a bridge, not a state owner: it holds no money (Economy does), no equipment data (EquipmentCatalog does), and no placement logic (PlacementSystem does). Its single non-trivial responsibility is the **ordering guarantee**: the player is never charged for a piece they cancel or that fails to place. It achieves this with a deduct-on-commit model — an affordability+unlock gate at drag-start, then a single `spend()` fired by PlacementSystem's `placement_committed` signal — which needs no refund path at all, because if no commit fires, no spend ever happened.

## Player Fantasy

Shop is the "treat yourself" beat of the loop — browsing the rack of equipment you *could* own, watching the ones you can now afford light up as your balance climbs, and the small satisfying commitment of dropping a freshly-bought machine onto your floor. It serves Pillar 1 by being the moment good management cashes out into a bigger gym, and Pillar 2 by making "not yet" completely painless: an unaffordable item is simply, calmly greyed out — no red warning, no scolding, just "keep going and it'll be yours." The feeling to protect: the clean, no-regret purchase — you're never charged for a piece you didn't actually place, and *eventually* you'll be able to sell back a piece you regret (SelectionSystem #13's sell-back, dependent on Economy exposing a credit path — see OQ3; not yet designed).

## Detailed Design

### Core Rules

1. **`can_purchase` gate (unlock AND afford), checked at drag-start.** `can_purchase(equipment_id) -> bool = is_unlocked(equipment_id) AND (cost == 0 OR Economy.can_afford(cost))` where `cost = EquipmentCatalog.get_definition(equipment_id).cost`. The `cost == 0` short-circuit is required because Economy rejects `can_afford(0)` (Economy AC5: `can_afford(0)` returns false) — a free item is trivially affordable without asking Economy. The Build/Shop UI (#15) must call this **before** a shop-palette mouse-down is allowed to become a PlacementSystem drag. If false, the drag never starts (the item is greyed/blocked, with a lock badge for locked items per Core Rule 5). Economy is **not** touched at this point — no reservation, no deduction.

2. **Deduct-on-commit — the ordering guarantee.** Money is spent **only** on `placement_committed`, and **only for purchase-initiated drags** (not relocations — see Core Rule 2a). Sequence:
   1. Player mouse-downs a shop item → UI calls `can_purchase`; **if true AND `PlacementSystem.is_dragging()` is false**, Shop sets `_purchase_in_flight = {equipment_id, cost}` and PlacementSystem begins its normal drag (its own DRAGGING state machine, untouched). **If `PlacementSystem.is_dragging()` is already true** (e.g. a relocate drag in flight via SelectionSystem's `begin_relocate`), Shop does **nothing** — no flag is set, no drag attempt is made. This check exists because PlacementSystem's own AC16 ("second mouse-down while DRAGGING is ignored") is *silent* — it emits no signal of any kind, not even a cancel — so Shop cannot rely on a later event to tell it the drag never started; it must not set the flag in the first place. Build/Shop UI (#15) is expected to disable the palette during any drag as UI-level reinforcement, but Shop's own gate is the structural backstop (see Core Rule 3).
   2. During the drag, Shop is **inert** — no per-cell re-check.
   3. Resolution:
      - **Silent cancel** (Esc / out-of-bounds / focus loss) → no signal → Shop clears `_purchase_in_flight` → money untouched.
      - **`placement_rejected(fail_code)`** → Shop clears `_purchase_in_flight` → money untouched.
      - **`placement_committed(instance_id, equipment_id, footprint_cells)`** → Shop checks `_purchase_in_flight`; if set and `equipment_id` matches, calls `Economy.spend(cost)` **exactly once** (skipped when `cost == 0` — see Core Rule 2b), then clears `_purchase_in_flight`. If `_purchase_in_flight` is null (i.e. this commit is a **relocate** originated by SelectionSystem), Shop does nothing. **If `_purchase_in_flight` is set but `equipment_id` does *not* match** — structurally expected to be unreachable under the one-drag-at-a-time invariant (Core Rule 3), since only one purchase drag can be in flight and its commit must carry the same `equipment_id` it started with — Shop leaves `_purchase_in_flight` untouched and does **not** spend. This branch is named explicitly, not left as an assumed no-op, so it has defined (if defensive) behavior rather than being silently unreachable-by-assertion.
   This needs **no refund path** (Economy exposes only `spend`, no external credit for purchases): if there's no commit, there was no spend.

2a. **Relocate commits are not purchases.** PlacementSystem emits the same `placement_committed` signal for both new placements and relocations (PlacementSystem Core Rule 1a, AC25(c)). Shop's `_purchase_in_flight` flag is the sole disambiguation: it is set **only** when Shop's own `can_purchase` gate passes and a purchase drag begins, never by SelectionSystem's `begin_relocate` path. A `placement_committed` arriving while `_purchase_in_flight` is null is therefore a relocate — Shop ignores it entirely (no spend, no side effect).

2b. **Cost-0 items: skip spend.** When `_purchase_in_flight.cost == 0` (free starter equipment), Shop's listener does **not** call `Economy.spend(0)` — it simply clears `_purchase_in_flight` and the placement is complete. Reason: Economy's contract rejects `spend(amount ≤ 0)` (returns false, no `balance_changed` — Economy Core Rule 5, AC3). Calling `spend(0)` would receive a false return with no signal, creating ambiguity. Skipping the call for cost-0 items is the cleanest resolution: the placement commits, money is untouched (correctly — nothing was owed), and no false return needs interpretation.

3. **Why a single gate at drag-start is safe (not just convenient).** PlacementSystem's commit is atomic and gives Shop no veto between "valid drop resolves" and "commit fires," so the afford check *must* be load-bearing before the drag. This holds **as long as balance cannot decrease between gate and commit** — in MVP that's simply true by construction: the only money faucet mid-drag is `revenue_per_visit` (adds money) and there is no concurrent sink, **provided only one purchase-drag is in flight at a time**. That one-drag-at-a-time invariant is **structurally guaranteed by PlacementSystem itself**: its state machine ignores a second mouse-down while already DRAGGING (PlacementSystem Edge Cases, AC16), and `begin_relocate` is a no-op while DRAGGING (AC27). Shop's own drag-start gate (Core Rule 2, step 1) is the mirror-image guard: it checks `PlacementSystem.is_dragging()` before setting `_purchase_in_flight`, so a purchase attempt during an *existing* drag (including a relocate) never sets the flag in the first place, rather than relying on a signal that PlacementSystem never sends for a swallowed mouse-down. Build/Shop UI (#15) may add *UI-level* reinforcement (greying palette items during a drag), but the structural guarantee rests on PlacementSystem + Shop's own gate, not on #15. Under this invariant, balance is monotonically non-decreasing during a purchase drag, so a passed gate guarantees `spend()` succeeds at commit. **This is a load-bearing design assumption, not an airtight formal proof** — it depends entirely on "no concurrent money sink" remaining true. **Hard requirement, not just a future risk**: if a sell-back credit (SelectionSystem #13 + Economy credit path, closing OQ3) is ever added as a concurrent money *sink*, this monotonicity assumption breaks outright — `spend()` could then fail at commit time even though `can_purchase` passed at gate time. **Before SelectionSystem #13's sell-back path ships, this Core Rule must be revisited and Shop must add a defined resolution for a late `spend()` failure** (e.g. treat it as a rejected commit and leave the piece unplaced, or re-gate at commit) — this is not optional cleanup, it is a precondition for OQ3 closing. Track this as a blocking cross-reference in OQ3, not just a note here.

4. **Affordability gating is block-at-selection**, not allow-drag-then-block-commit. Reasons: PlacementSystem's commit has no veto hook (so block-at-commit is architecturally impossible without inventing new Placement behavior), and Pillar 3 favors failing *clearly before* the drag gesture over letting the player drag a phantom and get rejected at the end. Unaffordable items are greyed out and un-draggable. **This trades away in-gesture feedback, so Build/Shop UI (#15) is required to compensate at the point of contact**: (a) hovering a greyed/unaffordable item must surface how much more is needed (e.g. "save $X more" — sourced from `cost - balance`, both already exposed via EquipmentCatalog/Economy), so the player still gets a legible "almost there" signal without an actual drag attempt; (b) a silent cancel (Core Rule 2, step 3) must still produce a lightweight visual/audio return-to-palette cue, so the drag's resolution isn't invisible to the player. Neither requirement changes Shop's own logic or state machine — both are #15-owned presentation requirements this GDD mandates as a condition of the block-at-selection design.

5. **Unlock gating (MVP stub, fail-closed).** `is_unlocked(equipment_id) = (unlock_requirement == null)`; **any non-null value → false** (no runtime unlock-state source exists yet). Locked items still render but are unbuyable. **Critically, locked items must be visually distinguishable from merely-unaffordable items** (Pillar 3 "一眼看懂"): unaffordable items are greyed out (calmly unavailable), while locked items display an additional **lock badge/icon** so the player can tell "save up more" from "not yet available." The exact lock badge design is Build/Shop UI (#15)'s concern, but the constraint that these two states are visually distinct is **this GDD's requirement** — a locked item rendered identically to an unaffordable one teaches a false mental model ("just save up") that never resolves. When Progression/Unlocks (#19) lands, it replaces the non-null branch with real milestone logic; Shop's `is_unlocked()` signature does not change.

6. **Shop owns minimal, transient purchase state.** It is a **gate function** the UI calls plus a **conditional listener** on `placement_committed`. Its only state is `_purchase_in_flight: {equipment_id, cost} | null` — set at drag-start (Core Rule 2), cleared on commit/reject/cancel (Core Rules 2, 2a). This flag's sole purpose is to distinguish purchase commits from relocate commits (Core Rule 2a). It never persists across drags, is never serialized, and is never read by any other system. Shop never initiates the drag itself (the palette mouse-down does, per PlacementSystem), and never mutates Economy or PlacementSystem beyond the single `spend()` at commit (skipped for cost-0, Core Rule 2b).

### States and Transitions

Shop tracks a single transient flag (`_purchase_in_flight`) to distinguish purchase drags from relocations:

| From | Event | To | Notes |
|---|---|---|---|
| idle (`_purchase_in_flight = null`) | palette mouse-down, `can_purchase` true, `PlacementSystem.is_dragging()` false | purchase drag (`_purchase_in_flight = {id, cost}`) | PlacementSystem begins drag; Shop inert during drag |
| idle | palette mouse-down, `can_purchase` false | idle | drag never starts (greyed/locked item) |
| idle | palette mouse-down, `can_purchase` true, `PlacementSystem.is_dragging()` true | idle | drag never starts, no flag set (Core Rule 2 step 1) — e.g. a relocate is already in flight |
| purchase drag | `placement_committed`, `equipment_id` matches | idle (`_purchase_in_flight = null`) | if `cost > 0`: `Economy.spend(cost)` fires once; if `cost == 0`: skip spend (Core Rule 2b) |
| purchase drag | `placement_rejected` / silent cancel | idle (`_purchase_in_flight = null`) | no spend |
| idle | `placement_committed` while `_purchase_in_flight = null` | idle | relocate commit — Shop ignores (Core Rule 2a) |
| purchase drag | `placement_committed`, `equipment_id` does NOT match | purchase drag (`_purchase_in_flight` unchanged) | defensive branch, expected unreachable (Core Rule 2 step 3) — no spend |

### Interactions with Other Systems

- **Upstream dependencies (hard)**:
  - **Economy (#11)**: `can_afford(amount)`, `spend(amount)`.
  - **EquipmentCatalog (#2)**: `get_definition(id)` → `cost`, `unlock_requirement`.
  - **PlacementSystem (#4)**: subscribes to `placement_committed`; queries `is_dragging()` before starting a drag (Core Rule 2, step 1 — new interface addition, see Dependencies); the palette mouse-down triggers Placement's drag (Placement does zero money checks — that's Shop's gate).
- **Downstream / lateral**:
  - **Build/Shop UI (#15)**: renders the shop palette, calls `can_purchase`/`is_unlocked` to grey items and display lock badges on locked items (Core Rule 5), surfaces hover "save $X more" feedback on greyed items and a non-silent cancel cue (Core Rule 4), and provides UI-level reinforcement of the one-drag-at-a-time invariant (structural guarantee is jointly PlacementSystem's and Shop's own `is_dragging()` gate — Core Rule 3).
  - **Progression/Unlocks (#19, VS)**: future source of real unlock state (replaces the MVP stub).

## Formulas

Shop introduces **no new formulas**. Cost comes from EquipmentCatalog's (validated) `provisional_equipment_cost`; affordability from Economy's `can_afford`. Sell-back pricing is **not** Shop's concern — it belongs to SelectionSystem (#13) / Economy (a sell-back credit). No math is owned here.

## Edge Cases

- **Exactly enough (`balance == cost`)**: gate passes; `spend` leaves balance 0. Fine.
- **One short (`balance == cost − 1`)**: gate blocks; drag never starts.
- **Revenue arrives mid-drag**: harmless — balance only rises, gate stays valid.
- **Cancel mid-drag / invalid drop**: no `placement_committed` → no `spend` (verified by Core Rule 2).
- **Locked item** (`unlock_requirement != null`): `can_purchase` false → unbuyable (MVP).
- **Cost-0 item** (free starter): `can_purchase` gate trivially passes (afford check: `can_afford(0)` — note: Economy rejects `can_afford(0)` per AC5, so Shop must **short-circuit**: when `cost == 0`, skip the `can_afford` call and treat affordability as trivially true). On commit, Shop skips `Economy.spend()` entirely (Core Rule 2b) — the placement commits with no money call. This is correct: nothing was owed, and Economy's strict `amount > 0` contract is never violated.
- **Two purchase-drags attempted at once**: PlacementSystem's state machine ignores a second mouse-down while DRAGGING (AC16) and rejects `begin_relocate` while DRAGGING (AC27) — but that guarantee only stops the *second* drag from starting inside PlacementSystem, silently. Shop's own gate (Core Rule 2, step 1: `can_purchase` AND `PlacementSystem.is_dragging()` false) is what stops it from setting `_purchase_in_flight` for an attempt that PlacementSystem is about to swallow — without this gate, the flag would still get set and never clear (see Core Rule 3). With the gate, a second `can_purchase` pass during any active drag is a true no-op: no flag change, no attempted drag.
- **Palette mouse-down while a relocate drag is already in flight**: same case as above — Shop's `PlacementSystem.is_dragging()` check blocks the flag from being set, so a purchase attempted mid-relocate does nothing (not even a greyed flash), rather than silently corrupting `_purchase_in_flight` for a drag that will never resolve.
- **Locked item that is also cost-0**: `is_unlocked` is checked first in `can_purchase`'s AND (Core Rule 1) — a locked free item is still unbuyable (`can_purchase` false) regardless of the `cost == 0` short-circuit, since the short-circuit only bypasses the *affordability* check, not the unlock check.
- **Negative-cost item** (data error): structurally impossible in normal flow — EquipmentCatalog rejects `cost < 0` at load time (EquipmentCatalog Edge Cases). Shop's trust in Catalog for cost validity is intentional and by design (Shop introduces no formulas of its own).

## Dependencies

**Upstream dependencies (hard)**:

| System | Interface | Nature |
|---|---|---|
| Economy (#11) | `can_afford(amount)`, `spend(amount)` | Hard |
| EquipmentCatalog (#2) | `get_definition(id)` → `cost`, `unlock_requirement` | Hard |
| PlacementSystem (#4) | subscribe `placement_committed`; `is_dragging() -> bool` (**new interface addition** — see below); palette mouse-down starts the drag | Hard |

**Downstream / lateral dependents** (none have GDDs yet): Build/Shop UI (#15, renders palette + enforces one-drag invariant, and now also required to surface hover "save $X more" feedback + a non-silent cancel cue per Core Rule 4), Progression/Unlocks (#19, future unlock source).

**Bidirectional consistency notes**: Economy's GDD lists Shop as the caller of `can_afford`/`spend`. EquipmentCatalog lists Shop as a reader of `cost`/`unlock_requirement`. PlacementSystem's `placement_committed` is consumed here. **PlacementSystem does not currently expose an `is_dragging()` (or equivalent DRAGGING-state) query** — this GDD requires one as a small new interface addition (mirrors how SelectionSystem's OQ1 required a new Economy credit method). Propagate to `placement-system.md` via `/propagate-design-change` before `/dev-story`. The one-drag-at-a-time invariant must appear in Build/Shop UI (#15)'s dependencies when authored. **Before SelectionSystem #13's sell-back credit path ships, Core Rule 3's monotonicity assumption must be re-verified against Economy's new credit interface** — this is a blocking cross-reference, not advisory (see Open Questions OQ3). Verify at `/consistency-check`.

## Tuning Knobs

Shop owns **no tuning knobs** — costs are EquipmentCatalog's (`base_cost`/`tier_step`), affordability is Economy's (`R_visit`, `starting_capital`). The only Shop-level behavior (block-at-selection vs allow-drag) is a fixed design decision (Core Rule 4), not a runtime knob.

## Visual/Audio Requirements

Shop is logic; its visual form — the shop palette, greyed/available states, price labels, locked badges — is **Build/Shop UI (#15)**'s. This GDD only constrains that consumer: unaffordable/locked items must read as *calmly unavailable* (greyed, per the art bible — never a red "denied" flash), with a hover affordance showing how much more is needed (Core Rule 4); a purchase should feel like a small positive commitment (a soft confirm cue, owned by #15 / audio-director). **This confirm cue must trigger on `placement_committed` while `_purchase_in_flight` was set** (i.e. the moment a purchase-initiated drag successfully lands), **not on `balance_changed`** — a cost-0 purchase never fires `balance_changed` (Core Rule 2b) but still deserves the same confirmation feel as a paid purchase. A silent-cancel resolution must also produce a lightweight return-to-palette cue (Core Rule 4). No asset owned here.

## UI Requirements

None of its own — the shop palette and its interactions are Build/Shop UI (#15). Shop exposes `can_purchase(equipment_id)` and `is_unlocked(equipment_id)` for the UI to grey items, and listens for `placement_committed`.

## Acceptance Criteria

> Shop is a **Logic** story — **BLOCKING** unit tests in `tests/unit/shop_purchase/`. Synthesized from economy-designer's guarantees.

1. **GIVEN** a successful `placement_committed`, **WHEN** Shop's listener fires, **THEN** `Economy.spend(cost)` is called **exactly once**, never before commit.
2. **GIVEN** a drag that ends in cancel **or** `placement_rejected`, **WHEN** it resolves, **THEN** **zero** `spend()` calls occur (money untouched).
3. **GIVEN** `can_purchase(equipment_id)` is false, **WHEN** the palette item is moused-down, **THEN** no PlacementSystem drag starts.
4. **GIVEN** an item with `unlock_requirement != null` and no Progression system, **WHEN** `is_unlocked` is evaluated, **THEN** it returns false and `can_purchase` returns false (item is unbuyable).
5. **GIVEN** `can_purchase` was true at drag-start (with `cost > 0`), **WHEN** `placement_committed` fires, **THEN** Shop calls `Economy.spend(cost)` exactly once using the cost captured at gate-time, without re-checking `can_afford` at commit time.
6. **GIVEN** `balance == cost` (with `cost > 0`), **WHEN** purchased and committed, **THEN** `spend` succeeds and balance becomes 0.
7. **GIVEN** a cost-0 item, **WHEN** purchased and committed, **THEN** Shop does **not** call `Economy.spend()` at all (Core Rule 2b), `_purchase_in_flight` is cleared, and no `balance_changed` fires. (Grid placement itself is PlacementSystem's own acceptance criteria, not tested here — Shop owns no grid state.)
8. **GIVEN** a strict test double for Economy/PlacementSystem/EquipmentCatalog that errors on any call not in `{can_afford, spend, EquipmentCatalog.get_definition, subscribing to placement_committed/placement_rejected}`, **WHEN** a full purchase flow (gate → drag → commit) runs, **THEN** no unexpected call is made.
9. **GIVEN** a `placement_committed` signal fires while `_purchase_in_flight` is null (i.e. a relocate commit from SelectionSystem), **WHEN** Shop's listener receives it, **THEN** zero `spend()` calls occur and `_purchase_in_flight` remains null (no field of Shop's state changes).
10. **GIVEN** a purchase drag is in flight (`_purchase_in_flight` is set), **WHEN** a `placement_rejected` or silent cancel resolves, **THEN** `_purchase_in_flight` is cleared and zero `spend()` calls occur.
11. **GIVEN** an item with `unlock_requirement != null`, **WHEN** displayed in the shop palette, **THEN** `is_unlocked` is false, the item is unbuyable, **and** the item is visually distinguishable from a merely-unaffordable item (lock badge present — Core Rule 5).
12. **GIVEN** PlacementSystem is already `DRAGGING` (e.g. a relocate drag in flight via `begin_relocate`), **WHEN** a palette item with `can_purchase(equipment_id) == true` is moused-down, **THEN** Shop calls `PlacementSystem.is_dragging()`, finds it true, does **not** set `_purchase_in_flight`, and no drag-start is attempted (Core Rule 2, step 1).
13. **GIVEN** `_purchase_in_flight = {id: "A", cost: C}` is set, **WHEN** a `placement_committed` fires with a **different** `equipment_id` "B", **THEN** Shop does **not** call `spend()`, and `_purchase_in_flight` remains `{id: "A", cost: C}` unchanged (Core Rule 2, step 3 — defensive, expected-unreachable branch).
14. **GIVEN** a purchase drag is already in flight (`_purchase_in_flight` set), **WHEN** a second palette mouse-down occurs on any item (including the same one), **THEN** `_purchase_in_flight` is unchanged (not overwritten) and no second drag is attempted.
15. **GIVEN** an item with `unlock_requirement != null` **and** `cost == 0`, **WHEN** `can_purchase` is evaluated, **THEN** it returns false (`is_unlocked` gates first; the cost-0 short-circuit only bypasses the affordability check, not the unlock check).

> **No dedicated AC for negative-cost items**: this is a deliberate scope call, not a gap. Shop trusts `EquipmentCatalog.get_definition(id).cost` to already satisfy `cost >= 0`, a contract enforced by EquipmentCatalog's own load-time validation (its AC-E.2, `equipment-catalog.md`) — testing it here would duplicate that GDD's test suite against Shop's own boundary rather than Shop's actual logic.

## Open Questions

| # | Question | Owner | Target Resolution |
|---|---|---|---|
| OQ1 | **Handoff to Build/Shop UI (#15)**: the one-purchase-drag-at-a-time invariant is jointly guaranteed by PlacementSystem (AC16, AC27) **and** Shop's own `is_dragging()` gate (Core Rule 2), so #15 does not need to build new blocking logic. #15 **is required** (not optional) to provide hover "save $X more" feedback on greyed items and a non-silent cancel cue (Core Rule 4) — confirm the exact presentation when #15 is designed. | Build/Shop UI (#15) owner | When #15 is designed |
| OQ2 | **Unlock source**: MVP stub fails-closed on non-null `unlock_requirement`. Progression/Unlocks (#19) replaces the non-null branch with real milestone logic; `is_unlocked()` signature unchanged. | Progression/Unlocks (#19) owner | When #19 is designed (VS) |
| OQ3 | **Sell-back is SelectionSystem (#13)'s concern**, and it needs Economy to expose a **credit path** (Economy currently exposes only `spend` externally; income is internal via `member_completed_visit`). Flagged there; not Shop's job. **However, Shop's own Core Rule 3 monotonicity guarantee is invalidated the moment that credit path exists** — closing this OQ is not just SelectionSystem/Economy's work, it is a **blocking precondition** for Shop: Core Rule 3 must be revisited (define what happens if `spend()` fails at commit despite a passed gate) before #13 ships. | SelectionSystem (#13) + Economy + **Shop (#12) — Core Rule 3 must be revisited**| When #13 is designed (next); Shop's revision is a hard prerequisite, not follow-up cleanup |