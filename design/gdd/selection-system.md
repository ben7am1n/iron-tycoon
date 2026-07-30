# SelectionSystem (inspect / move / sell placed equipment)

> **Status**: In Review (blocking 已修，待复审 — 2026-07-20 第二轮修订：B1 加载映射重建、R4/R8/R9 AC缺口/精度/意图区分)
> **Author**: user + agents
> **Last Updated**: 2026-07-20
> **Implements Pillar**: Pillar 1 (空间即玩法 — curating your placed layout) · Pillar 2 (松弛不紧绷 — safe, no-regret experimentation) · Pillar 3 (一眼看懂 — clear, calm selection state)
> **Creative Director Review (CD-GDD-ALIGN)**: Skipped — Lean review mode (not a PHASE-GATE at lean).

## Overview

SelectionSystem lets the player inspect, move, and sell equipment that is **already placed** on the grid — the counterpart to PlacementSystem (#4), which places *new* pieces from the shop. It reads GridSystem to resolve "what's at this cell," maintains a single current selection, and offers three actions: **Inspect** (open the Equipment Info Panel), **Move** (hand off to PlacementSystem's relocate flow), and **Sell** (remove the piece and credit a refund via Economy). It is an independent consumer of GridSystem — it does **not** depend on PlacementSystem (they're siblings that both read grid truth), and it owns no spatial state beyond "which instance is selected." Its `selection_changed` signal drives the Info Panel and lets other UI suppress conflicting modes. Its guiding constraint is Pillar 2: managing your gym must feel *safe* — selling is gentle and reversible-in-spirit (you can always rebuy), never a punishing "destroy."

## Player Fantasy

SelectionSystem is the curator's tool — the quiet pleasure of tidying and refining a space you've made your own. You click a machine to look it over, nudge it somewhere better, or sell off the one that never fit, and none of it feels risky: a soft confirm, a gentle fade, a little money back, and you're free to try again. It serves Pillar 2 above all — experimentation must feel *consequence-free* so the "再挪一下试试" itch stays playful, not fraught — and Pillar 1, because managing what's already placed is half of "space is the game." The feeling to protect: the calm, unpunished freedom to rearrange, where even selling reads as tidying rather than loss.

## Detailed Design

### Core Rules

1. **Single-select (MVP).** Clicking a placed instance selects it; clicking empty buildable floor, or a *different* placed piece (direct swap, no deselect-first), or pressing **Esc** deselects. Clicking the already-selected piece is a **no-op** (not a toggle-off — avoids accidentally closing a panel the player is reading). Multi-select is deliberately out of MVP (cognitive load + marquee-drag UX that fights PlacementSystem's drag conventions).

2. **Selection cue — colorblind-safe, calm.** A Soft Charcoal 2px outline around the selected footprint cells, plus a subtle glow in the piece's own tint, plus a small "selected" corner icon (shape carries the state even if outline contrast is missed). At most one slow ~1.5 s breathe cycle — no harsh flash (Pillar 2, no-flashing rule).

3. **Actions — a contextual toolbar near the selection** (not a blocking modal):
   - **Inspect** — always available; opens Equipment Info Panel (#17), fed by `selection_changed`.
   - **Move** — hands off to PlacementSystem's relocate flow. SelectionSystem **clears its own selection the instant Move is pressed**, so PlacementSystem takes sole ghost/preview ownership (no dual-ownership ambiguity).
   - **Sell** — soft inline confirm (Core Rule 4), then credits Economy and removes the piece.

4. **Sell flow — gentle, not punishing.** No "ARE YOU SURE you want to DESTROY" modal. Pressing Sell morphs the button into a 2 s **"Confirm sell +$X"** state (warm Butter tone, the money color — never Dusty Rose/alarm) that auto-reverts if not clicked, or on Esc/click-away. On confirm: the piece **fades out gently** (no destruction particle/sound), Economy is credited the refund, and the selection clears. Selling a machine a member is currently using is allowed — MemberSim handles equipment-deleted-mid-use gracefully (the member reselects), so there's no "you can't sell this right now" friction (Pillar 2).

5. **Keyboard.** Esc = deselect (also cancels a pending sell-confirm). Del = triggers the same Sell **soft-confirm** (not an instant destructive sell — the keyboard must not bypass the confirm). No keyboard shortcut for Move (spatial re-placement needs the pointer).

6. **Emitted signal.** `selection_changed(instance_id: int, equipment_def: EquipmentDef, cell: Vector2i, rotation: int)`, or `selection_changed(null)` on deselect. Info Panel (#17) and Build/Shop UI listen; the shop UI uses it to suppress new-placement ghost previews while an existing piece is selected (avoid two modes fighting).

7. **Sell requires an Economy credit path (interface gap).** Selling **adds** money, but Economy currently exposes only `spend()` externally (income is internal, via `member_completed_visit`). SelectionSystem therefore needs Economy to expose a **credit/earn path** for sell-backs — a small addition to Economy's interface (closes Shop's OQ3). See Dependencies / Open Questions.

8. **Loading-time mapping reconstruction (SaveLoad integration).** After `GridSystem.deserialize()` restores occupancy, SelectionSystem's local `instance_id → {equipment_id, anchor, rotation}` mapping is empty — no `placement_committed` or `grid_changed` fires during load. Before the first player click can resolve `get_occupant_id(cell)`, SelectionSystem must **rebuild its mapping from the loaded grid**: iterate every occupied cell via `GridSystem`'s read surface (or a load-time bulk query), group by `occupant_id`, reconstruct `{instance_id, equipment_id, anchor, rotation}` for each, and seed the mapping. This is a one-time load step — analogous to PlacementSystem's `rederive_counter()` and Navigation's `rebuild()`. After this step, all runtime selection logic works unchanged. The rebuild must run **after** GridSystem deserialize and **before** the first UI frame that could receive a click (i.e. in SaveLoad's Phase B load order, after GridSystem but before the session unpauses). See SaveLoad (#14) Core Rule 3 for the exact slot.

### States and Transitions

| From | Event | To | Notes |
|---|---|---|---|
| none selected | click a placed instance | selected | outline+icon+toolbar appear |
| (at load) | GridSystem deserialized | mapping rebuilt → none selected | one-time load step (Core Rule 8); after rebuild, runtime transitions as normal |
| selected | click empty floor / Esc | none selected | toolbar disappears; cancels pending sell-confirm |
| selected | click a different placed piece | selected (new) | direct swap |
| selected | Move pressed | none selected → PlacementSystem relocate | selection cleared, ghost handed off |
| selected | Sell pressed | sell-confirm pending (2 s) | button shows "Confirm sell +$X" |
| sell-confirm pending | confirm click within 2 s | piece removed, Economy credited, none selected | gentle fade |
| sell-confirm pending | 2 s elapse / Esc / click-away | selected | reverts, no sale |
| selected | selected instance removed externally | none selected | `selection_changed(null)` fires; toolbar disappears |

### Interactions with Other Systems

- **Upstream dependencies (hard)**:
  - **GridSystem (#1)**: `get_occupant_id(cell)` — to resolve "what's at this cell" when the player clicks. SelectionSystem self-maintains an `instance_id → {equipment_id, anchor, rotation}` mapping built by subscribing to PlacementSystem's `placement_committed` signal and GridSystem's `grid_changed` signal. It does **not** use `get_placed_instances()` or `get_snapshot()` — grid-system.md's per-consumer contract (AC-X.4) grants SelectionSystem only `get_occupant_id(cell)`, and that is sufficient: click → cell → occupant_id → local mapping → full instance data.
  - **EquipmentCatalog (#2)**: `get_definition(equipment_id)` — for the payload / info / cost basis of the refund.
  - **Economy (#11)**: a **credit/earn path** for sell-backs (new interface addition — Core Rule 7). The credit call is **synchronous and immediate** (mirrors `spend()`'s timing — not tick-batched), so balance updates and HUD feedback are instant on sell-confirm. This timing must be documented in Economy's own GDD via `/propagate-design-change`.
  - **PlacementSystem (#4)**: its relocate flow, invoked by Move (SelectionSystem yields ownership). SelectionSystem also subscribes to `placement_committed` to maintain its instance mapping (read-only observation, not a call dependency).
- **Downstream consumers** (none have GDDs yet): Equipment Info Panel (#17, `selection_changed`), Build/Shop UI (#15, suppresses ghost during selection).
- **One-way dependency on PlacementSystem (#4)**: SelectionSystem's Move action calls PlacementSystem's `begin_relocate(instance_id)` — a one-way edge (Selection → Placement), reflected as a Hard dependency in the table below. Both also independently consume GridSystem; PlacementSystem never calls back into SelectionSystem.
- **Input routing (architecture contract)**: SelectionSystem is `RefCounted` (no scene-tree presence, same DI discipline as GridSystem/PlacementSystem). It cannot receive `_input()`, `_unhandled_key_input()`, or create timers via `get_tree()`. A thin **presentation-layer bridge Node** forwards clicks as `on_cell_clicked(cell)`, key events as `on_esc_pressed()` / `on_del_pressed()`, and owns the 2s sell-confirm timer (the timer is UI-layer state, not simulation state). The bridge also drives the toolbar Control (morph/revert animations). Esc/Del should be handled via `_unhandled_key_input` on the bridge (focus-independent, per Godot 4.6's dual-focus system). Exact bridge design deferred to `/create-architecture`.

## Formulas

The **sell_back_refund** formula is defined as:

`refund = int(round(refund_rate × EquipmentCatalog.get_definition(equipment_id).cost))`

**Variables:**
| Variable | Symbol | Type | Range | Description |
|----------|--------|------|-------|-------------|
| Refund fraction | `refund_rate` | float | provisional **0.5** (Economy owns final) | fraction of purchase cost credited on sell |
| Equipment cost | `cost` | int | Catalog value (200/350/650) | purchase price |
| Sell-back credit | `refund` | int | e.g. 100 / 175 / 325 at 0.5 | credited to Economy on sell |

**Output Range:** `[0, cost]`. **GDScript note:** `round()` returns float — the explicit `int()` cast is required, not optional, because Economy's `credit()` interface is expected to take `int` (mirroring `spend(int)`). **Boundary test:** at `refund_rate=0.5` and `cost=350`, the raw product is `175.0` → `int(round(175.0))=175` (no precision loss). At odd `cost` (e.g. 201), raw product is `100.5` → `int(round(100.5))=101` (ties round away from zero per GDScript `round()`). **Example:** selling a $350 (1×2) machine at `refund_rate=0.5` credits `$175`. **Rationale:** high enough that rearranging doesn't feel taxed (Pillar 2 — experimentation must feel safe), low enough to discourage buy-sell arbitrage. **`refund_rate` is provisional and owned by Economy** (this GDD proposes 0.5; Economy sets the final value).

## Edge Cases

- **Sell-confirm timeout**: 2 s with no second click → reverts to the normal Sell button; **no destructive default** (never auto-sells).
- **Selecting a piece that's then removed** (sold via another path, or a MemberSim interaction): if the selected `instance_id` no longer resolves in GridSystem, selection clears and `selection_changed(null)` fires.
- **Selling a machine in use**: allowed — MemberSim's equipment-deleted-mid-use handling gracefully reselects the member; no block (Pillar 2).
- **Move then cancel**: once Move hands off, the flow is PlacementSystem's (its relocate can be cancelled per its own rules); SelectionSystem has already cleared its selection.
- **Move while PlacementSystem is already dragging** (e.g. a purchase drag in flight): `begin_relocate()` is a no-op while PlacementSystem is `DRAGGING` (PlacementSystem AC27). SelectionSystem does **not** guard against this — the bridge Node should disable the Move button during any active drag (PlacementSystem's `is_dragging()` query enables this). If it's still called, the handoff silently fails; the selection remains (the caller can detect the stale selection and retry).
- **Relocate displacing a member vs selling displacing a member**: both trigger MemberSim's equipment-deleted-mid-use handling (the member reselects). However, the player intent differs: a relocate is a transient gesture (the member was displaced for ~seconds and the piece returns in a different spot), while a sell is permanent. The mechanical outcome is identical (member reselects) — MemberSim does not distinguish them — but the UX expectations differ: a relocate that displaces a member should ideally surface a brief "member reselected" micro-feedback (owned by the Overlay, not here). This is documented as a recommended UX improvement for the playtest milestone, not a blocking spec gap.
- **Click during an active placement drag**: selection is suppressed while PlacementSystem owns a drag (the two modes don't fight — see `selection_changed` use by the UI).
- **Refund of a cost-0 item**: `refund = 0`; the sale still completes (piece removed), Economy credited 0 (harmless).

## Dependencies

**Upstream dependencies (hard)**:

| System | Interface | Nature |
|---|---|---|
| GridSystem (#1) | `get_occupant_id(cell)` + **load-time bulk read surface** for mapping rebuild (Core Rule 8) | Hard |
| EquipmentCatalog (#2) | `get_definition(id)` | Hard |
| Economy (#11) | **credit path** for sell-back (new) | Hard |
| PlacementSystem (#4) | relocate flow (Move handoff) | Hard (one-way handoff, not a cycle) |
| SaveLoad (#14) | load-order slot — mapping rebuild runs after GridSystem deserialize, before session unpause (Core Rule 8) | Hard (one-time, load only) |

**Downstream dependents** (none have GDDs yet): Equipment Info Panel (#17), Build/Shop UI (#15).

**Bidirectional consistency notes**:
- **Economy** must add a sell-back **credit** method (synchronous, mirrors `spend()`) and list SelectionSystem as a downstream caller in its own Dependencies table — currently missing (violates bidirectional rule). Propagate via `/propagate-design-change` before `/dev-story`.
- **GridSystem** already lists SelectionSystem as a consumer of `get_occupant_id(cell)` (line 742/318). Verify at `/consistency-check`.
- **PlacementSystem** lists SelectionSystem as a one-way caller (Section C line 69). Consistent.

## Tuning Knobs

| Knob | Default | Safe Range | Too Low | Too High |
|---|---|---|---|---|
| `refund_rate` (Economy-owned) | 0.5 | 0.3–0.7 | Selling feels punishing — discourages rearranging (fights Pillar 2) | Buy-sell arbitrage / no cost to churn; trivializes purchase decisions |
| sell-confirm window | 2 s | 1.5–3 s | Too quick to confirm safely | Feels sluggish |

## Visual/Audio Requirements

- **Selection cue**: Soft Charcoal outline + tint glow + corner "selected" icon; one slow breathe, no flash (Core Rule 2).
- **Sell**: the "Confirm sell +$X" morph in warm Butter (never alarm-red); on confirm, a **gentle fade-out** — no destruction particles, no harsh sound (a soft "sold" cue is a nice-to-have for audio-director).
- Colorblind-safe throughout (shape/icon + outline, never color alone). Renders on the UI layer; the contextual toolbar scales with the UI-scale setting.

## UI Requirements

A **contextual action toolbar** (Inspect / Move / Sell) anchored near the current selection — not a blocking modal. Inspect opens the Equipment Info Panel (#17). The Sell soft-confirm lives in this toolbar. This is a UI/Visual story; its detailed layout may also be captured in `design/ux/` via `/ux-design` in Pre-Production.

## Acceptance Criteria

> SelectionSystem is a **UI/Visual + Logic** story — interaction logic (selection resolution, sell credit, signal emission) gets **BLOCKING** unit/interaction tests; visual cues are **ADVISORY** (manual walkthrough). GIVEN-WHEN-THEN:

1. **GIVEN** nothing selected, **WHEN** the player clicks a placed instance, **THEN** the outline+icon+toolbar appear within one frame and `selection_changed(instance_id, …)` fires.
2. **GIVEN** a selection, **WHEN** the player clicks empty buildable floor, **THEN** selection clears, the toolbar disappears, and `selection_changed(null)` fires.
3. **GIVEN** a selection, **WHEN** the player presses Esc, **THEN** selection clears; if a sell-confirm was pending, it also cancels without selling.
4. **GIVEN** a selection, **WHEN** the player presses Move, **THEN** SelectionSystem's cue clears (selection released) and PlacementSystem's relocate-ghost appears at that instance's position within one frame.
5. **GIVEN** a selection, **WHEN** the player clicks Sell, **THEN** the button shows "Confirm sell +$X" for 2 s; if clicked again in that window, the piece is removed, Economy is credited `refund`, and selection clears.
6. **GIVEN** the sell-confirm window is open, **WHEN** 2 s elapse with no second click, **THEN** it reverts to the normal Sell button (no destructive default).
7. **GIVEN** a completed sell of a piece with cost `C`, **WHEN** it resolves, **THEN** Economy's balance increases by exactly `int(round(refund_rate × C))` (credit fires once) — integer credit, matching Economy's `int`-based balance.
8. **GIVEN** a colorblind player, **WHEN** any piece is selected, **THEN** the selection state is legible from outline shape + icon alone with color desaturated.
9. **GIVEN** a selected piece A, **WHEN** the player clicks a different placed piece B, **THEN** selection swaps directly to B (outline+icon+toolbar move to B within one frame, no intermediate deselect).
10. **GIVEN** a selected piece A, **WHEN** the player clicks A again, **THEN** it is a no-op — selection stays on A, no signal fires, no toolbar flicker (Core Rule 1: re-click is not a toggle-off).
11. **GIVEN** a selected piece, **WHEN** the piece is removed externally (sold via another path, or invalidated by grid state change), **THEN** selection clears and `selection_changed(null)` fires (Edge Cases — external invalidation).
12. **GIVEN** a placement drag is active (PlacementSystem `is_dragging()` returns true), **WHEN** the player clicks on the grid, **THEN** SelectionSystem does not resolve a new selection — clicks during a drag are suppressed to avoid modes fighting (Edge Cases — drag suppression).
13. **GIVEN** a piece with `cost = 0` (free starter), **WHEN** sold, **THEN** `refund = 0`, the piece is removed, Economy is credited 0, and `selection_changed(null)` fires — the sale completes cleanly with no money effect.
14. **GIVEN** an `instance_id` that was sold and then a new placement reuses a future `instance_id`, **WHEN** the retired id is queried, **THEN** it does not resolve (the mapping entry was removed on sell, and `instance_id` are never reissued within a session per GridSystem contract).
15. **GIVEN** `refund_rate = 0.5` and `cost = 201` (odd value), **WHEN** the sell resolves, **THEN** `refund = int(round(100.5)) = 101` — the .5 boundary rounds away from zero (GDScript `round()` default), and the result is an `int`.

## Open Questions

| # | Question | Owner | Target Resolution |
|---|---|---|---|
| OQ1 | **Economy credit path** (closes Shop OQ3): Economy must expose a sell-back **credit/earn** method — it currently exposes only `spend` externally. Small interface addition. | Economy (#11) owner | Before `/dev-story`; via `/propagate-design-change` |
| OQ2 | Final `refund_rate` is **Economy's** to set (this GDD proposes 0.5). Confirm during economy balance tuning. | Economy (#11) / economy-designer | At the fun-validation playtest |
| OQ3 | **Selection payload → Equipment Info Panel (#17, VS)**: the `selection_changed` payload feeds the info panel; confirm it carries everything #17 needs when that panel is designed. | Equipment Info Panel (#17) owner | When #17 is designed (VS) |
| OQ4 | ✅ RESOLVED（跨 GDD 评审 2026-07-19, C-B1）：PlacementSystem 经 `begin_relocate(instance_id)` 拥有 relocation（其 Core Rule 1a）——拿起清占用、以同一 id 重新 commit、取消恢复原位。Move handoff 入口已确认。 | — | Closed |