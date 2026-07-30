# PlacementSystem

> **Status**: In Design
> **Author**: user + agents
> **Last Updated**: 2026-07-17
> **Implements Pillar**: Pillar 1 (空间即玩法) — direct mechanism; Pillar 2 (松弛不紧绷) via non-punishing placement failure
> **Creative Director Review (CD-GDD-ALIGN)**: Skipped — Lean review mode (not a PHASE-GATE at lean).
>
> ⚠️ **Pinned engine: Godot 4.7.1.** 本 GDD 的 GDScript 实现需注意：headless 下 `class_name` 不跨脚本全局注册（须 `preload` 别名）；`var x := get_*()` 推断失败（须显式 `: Type`）；lambda 闭包不回写外层变量；signal emit 参数数量须精确匹配。完整坑清单见 skill `godot-4x-gdscript-pitfalls`（含 Formula 段已提到的 `rotation as Rotation` 强转）。

## Overview

PlacementSystem is the single interactive surface through which the player builds their gym: it turns a mouse drag into a live preview (via GridSystem's speculative snapshot, never touching real state), a rotate key-press into a normalized 0/90/180/270 orientation, and a drop into one atomic, GridSystem-validated commit that either succeeds or fails with a specific reason (out-of-bounds, blocked-by-room-geometry, overlaps-existing-equipment, or an access-cell variant of either). It is the sole allocator of `instance_id` for every placed piece of equipment — GridSystem consumes that id but never generates it — and the sole caller that must normalize rotation before GridSystem ever sees it. Architecturally, PlacementSystem is a leaf writer: it owns none of the spatial truth it manipulates (that belongs to GridSystem) and reads none of the equipment data it places (that belongs to EquipmentCatalog) — its entire job is orchestrating the moment-to-moment drag/rotate/drop interaction against those two systems' already-locked contracts. It emits its own `placement_committed` / `placement_rejected` signals for the presentation layer, and it *triggers* GridSystem's `grid_changed` indirectly by calling `GridSystem.commit()` — that signal is owned and emitted by GridSystem, not by PlacementSystem. This system exists because Pillar 1 (空间即玩法) demands that the mechanism of "moving equipment around" itself feel immediate, forgiving, and legible — every failed placement must be a clearly-reasoned "not yet" rather than a punishing mistake (Pillar 2), which is why `can_place`'s specific failure codes exist and why nothing about dragging or previewing ever touches real game state until the player commits.

## Player Fantasy

The moment-to-moment fantasy is the satisfying, tactile feeling of "putting something exactly where it belongs" — picking up a piece of equipment, feeling it snap to the grid, watching the live preview tell you instantly whether this spot works, and committing with a decisive drop that feels earned rather than risky. This is the "再挪一下试试" hook named in the game concept's core loop: because failure is never punishing (a rejected placement just shows a clear reason and lets you try again immediately, no cost, no undo needed), the player is free to experiment liberally — nudging, rotating, second-guessing — without anxiety. Reference points: the tactile satisfaction of Mini Motorways' road-drawing and the zero-risk experimentation of Two Point Hospital's room-building both nail this "confident tinkering" feeling. PlacementSystem is where Pillar 1 (空间即玩法) becomes literally true — the player isn't reading about spatial optimization, their hands are doing it, every single placement — and where Pillar 2 (松弛不紧绷) is proven moment-to-moment rather than just promised: nothing about placing equipment can go permanently wrong. **Scope note**: this "nothing can go permanently wrong" guarantee is about *grid state* — a placement or relocate attempt never corrupts or loses the piece itself, and cancelling always returns it safely. It does not extend to every downstream consequence of an attempt: a relocate that displaces an in-use member is not undone by cancelling (Core Rule 1a), and a wrong *purchase* decision is only reversible later at a real cost (SelectionSystem's sell-back, not free). The pillar holds at the level this system owns; it is not a blanket promise across the whole simulation.

## Detailed Design

### Core Rules

1. **Scope boundary.** PlacementSystem is the single interactive surface for *both* placing new equipment from the catalog **and relocating already-placed equipment** (Core Rule 1a) — it owns every drag/rotate/drop/commit interaction that mutates the grid. *Inspecting* and *selling* placed equipment remain SelectionSystem's (#13) domain. New placement is self-initiated from the shop palette; relocation is initiated **only** by SelectionSystem's Move handoff calling `begin_relocate(instance_id)` — PlacementSystem never spontaneously reaches into a placed instance on its own.

1a. **Relocate flow (owned here).** `begin_relocate(instance_id)` picks up an already-committed piece: it reads the instance's current `def`/`anchor`/`rotation`, **clears its occupancy from GridSystem** (firing `grid_changed`, which lets any in-use member repath exactly as in the sell path — MemberSim's equipment-deleted-mid-use handling applies unchanged), and enters the same `DRAGGING` state as a new placement, seeded with the piece's existing rotation. On a valid drop it **re-commits under the same `instance_id`** (id is preserved, never reallocated). On cancel (Esc / focus-loss) **or a rejected drop** (can_place returns FAIL), it **restores the piece to its original `anchor`/`rotation`** via `GridSystem.commit(same_id, ...)` — relocation is never destructive **to the grid** (Pillar 2). A rejected relocate-drop is NOT analogous to a rejected new-placement drop (which emits `placement_rejected`): it is a silent restoration, identical in outcome to a cancel, because the player already owns the piece and has somewhere safe for it to return to. While a relocate drag is in flight the piece is absent from the grid; this is the one case where PlacementSystem holds transient knowledge of an existing `instance_id`, released the moment the drag resolves.

   **Documented cost — member displacement is not undone by cancel (accepted, not a bug).** Clearing occupancy happens at drag-*start*, before the player has committed to anything — this is deliberate: it's what lets a nudge-one-cell-over relocate preview correctly (the piece isn't colliding with its own old position during `can_place` checks mid-drag). The consequence: if a member was actively using the piece, they are displaced (MemberSim's equipment-deleted-mid-use handling fires) the instant the drag begins — **even if the player immediately cancels**. The grid restores cell-for-cell (AC24), but the member's disrupted visit does not un-disrupt; they've already reselected a new target per MemberSim's own contract. This is a real, if usually minor, simulation-level cost that a "harmless nudge" carries invisibly to the player. It is accepted as a designed tradeoff (see Player Fantasy note below) rather than engineered away, because the alternative — deferring occupancy-clear until commit and having `can_place` specifically exclude the dragged instance's own cells from collision checks — is a materially bigger change to GridSystem's contract for a low-frequency edge case (a member must be *actively mid-use* on the *exact instant* a relocate begins).

2. **Drag initiation.** A drag begins when the player presses the mouse button down on a shop-palette entry (surfacing that entry is Build/Shop UI's (#15) concern). PlacementSystem receives an `equipment_id`, calls `EquipmentCatalog.get_definition(equipment_id)` exactly once at drag-start, and holds that definition for the whole drag — never re-queried mid-drag, since catalog data is immutable by contract.

3. **Live preview.** Each frame the mouse moves to a new grid cell during a drag, PlacementSystem converts the mouse's world position to a cell (via GridSystem's `world_to_grid()`) and calls `GridSystem.can_place(def, anchor, rotation)` against **real** grid state to get the current valid/invalid signal — no mutation happens during a drag, so this pure check is sufficient on its own; nothing is written until commit. (A richer downstream preview — e.g. a future ZoneRules synergy overlay via `get_speculative_snapshot()` — is deferred; that method is granted by GridSystem's contract to ZoneRules, not yet to PlacementSystem, so wiring it here also requires extending that grant — see OQ1.)

4. **Rotation during drag.** Pressing the rotate action while dragging updates a locally-tracked `rotation` via `rotation = (rotation + 90) % 360` — PlacementSystem performs this normalization explicitly, since GridSystem does not. The preview's transformed cells are obtained by calling `GridSystem.get_transformed_cells(def, anchor, rotation)` — PlacementSystem never reimplements rotation math itself or derives its own `(W, H)`, honoring the inherited union-bbox calling convention by construction (there's only one call site: GridSystem's).

5. **Commit on drop — success path.** Releasing the mouse ends the drag. PlacementSystem calls `GridSystem.can_place(def, anchor, rotation)`; on success, it allocates a new `instance_id` (Core Rule 7), then calls `GridSystem.commit(id, def, anchor, rotation)` — **GridSystem itself** fires its `grid_changed(footprint_cells_changed, access_cells_changed)` signal exactly once (PlacementSystem does not own or emit that signal). PlacementSystem then emits its own `placement_committed(instance_id, equipment_id, footprint_cells)` for the presentation layer. Drag state clears; the newly-placed instance now belongs to SelectionSystem's domain (Core Rule 1).

6. **Commit on drop — failure/cancel path.** Two sub-cases, both leaving **no** `instance_id` allocated, no `commit()` call, and no `grid_changed`:
   - **Rejected drop**: the mouse releases *over the grid* but `can_place()` returns one of GridSystem's 5 FAIL codes. PlacementSystem emits `placement_rejected(equipment_id, anchor, rotation, fail_code)` carrying that code, so the presentation layer can show reason-specific feedback (exact visual treatment is Visual/Audio Requirements, out of this rule's scope).
   - **Silent cancel**: the mouse releases outside the grid bounds, or the player presses Escape, or the drag is interrupted (focus loss). The drag ends with **no** signal at all — nothing was ever attempted.
   In both sub-cases nothing was written, so there's nothing to undo — the equipment conceptually "returns to the shop."

7. **`instance_id` allocation.** PlacementSystem owns a single internal monotonically-increasing counter. It is incremented and consumed **only** at the moment of a successful *new-placement* commit (Rule 5) — never at drag-start, never for a canceled or failed drag. **A relocate re-commit (Core Rule 1a) is explicitly excluded from this increment**: it reuses the piece's existing `instance_id` and never touches the counter, even though it is also "a successful commit" in the general sense Rules 5/6 use that phrase for. This carve-out exists here, not just in AC25(e), because a reader of this rule alone should not have to infer it from an acceptance criterion. **There must be exactly one PlacementSystem allocator instance**, dependency-injected (no Autoload), consistent with GridSystem's DI discipline — this catches the failure GridSystem's handoff #1 named explicitly: two allocator instances would each stay individually monotonic yet collectively hand out colliding ids, which GridSystem cannot detect.

8. **`instance_id` resume after load.** On every `deserialize()` — not just once at boot — PlacementSystem recomputes `next_instance_id = max(all occupant_ids currently on the grid) + 1` (0 if the grid is empty), reading GridSystem's own post-load state via the granted `GridStateReader` surface: it scans `get_occupant_id(cell)` across every cell in `get_dimensions()`. It does **not** trust a separately-stored counter value. This is self-healing: a stored "next id" could silently desync from reality (e.g. a bad save edit); re-deriving from what's actually on the grid cannot desync. PlacementSystem itself stores no instance-level data in the save file at all — this counter is entirely reconstructible from GridSystem's state. The resume must run **after** GridSystem's own `deserialize()` completes; that ordering is enforced by the composition root (`SimulationOrchestrator`).

9. **Cost/affordability is explicitly out of scope.** PlacementSystem assumes any drag it receives has already been affordability-cleared by whatever initiated it (Build/Shop UI, #15). It performs no currency check and deducts no cost — see Open Questions for the formal handoff to Shop/Economy.

10. **`is_dragging() -> bool` — public state query (new interface, required by Shop/Purchase #12).** Returns `true` whenever the internal state is `DRAGGING` (new-placement or relocate, any source), `false` when `IDLE`. This is a pure, synchronous, side-effect-free read — it never mutates state and may be called at any time, including mid-drag. It exists because PlacementSystem's own no-op-ignore behavior for a second mouse-down while DRAGGING (Core Rule 11 below, formerly numbered as an Edge Case) is **silent** — it emits no signal of any kind — so any caller that wants to know *before* attempting a second drag whether one is already in flight has no other way to find out. Shop/Purchase (#12) calls this before setting its own `_purchase_in_flight` flag, specifically to avoid setting that flag for an attempt this system is about to swallow silently (see shop-purchase.md Core Rule 2, step 1).

11. **Second mouse-down while DRAGGING is a no-op (renumbered from Edge Cases for visibility, since Rule 10 now depends on it being precisely specified).** PlacementSystem tracks exactly one active drag; a second mouse-down (whether for a new purchase or another relocate attempt) is ignored — no state change, no signal, the in-flight drag's def/rotation/anchor unchanged. This silence is exactly why Rule 10's `is_dragging()` query exists: callers must check *before* attempting, not rely on a rejection signal that will never come.

### States and Transitions

| From | Event | To | Notes |
|---|---|---|---|
| `IDLE` | mouse-down on shop palette item | `DRAGGING` | `equipment_def` queried once from EquipmentCatalog |
| `DRAGGING` | mouse moves to a new cell | `DRAGGING` | preview recomputed via `can_place` against real state |
| `DRAGGING` | rotate action pressed | `DRAGGING` | `rotation = (rotation + 90) % 360`; preview recomputed via `GridSystem.get_transformed_cells` |
| `DRAGGING` | mouse-up over a valid, in-bounds cell | `IDLE` | commit succeeds: `instance_id` allocated, `GridSystem.commit()` fires `grid_changed`; PlacementSystem emits `placement_committed` |
| `DRAGGING` | mouse-up over an invalid cell (`can_place` FAIL) | `IDLE` | rejected: no id/commit/`grid_changed`; emits `placement_rejected(fail_code)` |
| `DRAGGING` | drop outside grid bounds / Escape / focus loss | `IDLE` | silent cancel: no id/commit, no signal at all |

### Interactions with Other Systems

- **Upstream dependencies (hard)** — using only methods GridSystem's per-consumer contract grants PlacementSystem, plus the `GridStateReader` read surface:
  - **GridSystem**: `can_place()`, `commit()`, `clear()`, `get_transformed_cells()`, `world_to_grid()`, and (via `GridStateReader`) `get_occupant_id()` / `get_dimensions()` for the instance_id-resume scan. `get_speculative_snapshot()` is **not yet granted** to PlacementSystem — reserved for the deferred ZoneRules preview (OQ1), which requires extending GridSystem's grant.
  - **EquipmentCatalog**: `get_definition(equipment_id)`.
- **Emitted signals** (PlacementSystem's public output interface):
  - `placement_committed(instance_id: int, equipment_id: String, footprint_cells: Array[Vector2i])` — emitted exactly once immediately after a successful `GridSystem.commit()` (Core Rule 5). Drives commit feedback and lets presentation identify the new instance.
  - `placement_rejected(equipment_id: String, anchor: Vector2i, rotation: int, fail_code: int)` — emitted once per rejected drop, `fail_code` ∈ GridSystem's 5 `PlacementFailCode` values (Core Rule 6). Silent cancels emit nothing.
  - (`grid_changed` is **GridSystem's** signal, not one of PlacementSystem's — see Overview.)
- **Public state query** (PlacementSystem's public read interface, distinct from signals):
  - `is_dragging() -> bool` (Core Rule 10) — synchronous, side-effect-free, callable at any time. Required by Shop/Purchase (#12) before it starts a purchase drag.
- **Downstream consumers (none have GDDs yet)**:
  - **Congestion/Flow Overlay + Placement Feedback (#8)**: subscribes to GridSystem's `grid_changed` and to PlacementSystem's `placement_committed` / `placement_rejected` for visual feedback.
  - **Build/Shop UI (#15)**: initiates drags by `equipment_id`; owns the affordability check *before* starting one (Core Rule 9).
  - **Shop/Purchase (#12)**: calls `is_dragging()` (Core Rule 10) before setting its own in-flight-purchase flag, so it never attempts a drag PlacementSystem will silently swallow (Core Rule 11). This is a **hard** dependency (not "none have GDDs yet" — #12 is Approved).
- **Downstream caller — SelectionSystem (#13)**: SelectionSystem's **Move** action calls `begin_relocate(instance_id)` (Core Rule 1a). This is a **one-way edge (Selection → Placement)**: SelectionSystem depends on PlacementSystem for relocation, but PlacementSystem never calls SelectionSystem. Both also independently consume GridSystem. Inspecting and selling placed pieces remain wholly SelectionSystem's domain.
- **Input routing (architecture contract)**: PlacementSystem is `RefCounted` (no scene-tree presence, consistent with GridSystem's DI discipline). It does **not** receive `_input()`, `_unhandled_input()`, or `_process()` callbacks from Godot — those are `Node`-only. A thin **presentation-layer bridge Node** (owned by the scene tree, likely a `Control` or `Node2D` in the UI layer) must forward mouse/keyboard events as method calls: `on_drag_start(equipment_id)`, `on_mouse_moved(cell)`, `on_rotate_pressed()`, `on_drop()`, `on_cancel()`, `on_focus_lost()`. The bridge also provides `SceneTree` access for any tween creation (`create_tween()` requires a `Node` context). The exact bridge design is deferred to `/create-architecture` — this GDD specifies **what** inputs PlacementSystem reacts to (States table), not **how** they arrive from the engine. All ACs test via direct method calls on PlacementSystem, not via simulated Godot input events.
- **Serialization note**: PlacementSystem contributes **no data of its own** to the save file — its only save-adjacent behavior is the read-only recomputation in Core Rule 8, which runs after GridSystem's own `deserialize()` completes.

## Formulas

The **rotation_increment_formula** formula is defined as:

`rotation' = (rotation + 90) mod 360`

**Variables:**
| Variable | Symbol | Type | Range | Description |
|----------|--------|------|-------|-------------|
| Current rotation | `rotation` | `Rotation` enum | `{0,90,180,270}` | Facing before this rotate keypress |
| New rotation | `rotation'` | `Rotation` enum | `{0,90,180,270}` | Facing after one rotate keypress |

**Output Range:** Closed 4-value set, exhaustive. `mod 360` wraps the 4th press (`270+90=360`) back to `0` — this is exactly the naive-`+=90`-breaks-on-press-4 bug GridSystem's own GDD names and explicitly hands off to this system.
**Precondition (runtime guard, not debug-only):** Before applying the formula, validate `rotation in [R0, R90, R180, R270]`. If invalid: `push_error("PlacementSystem: corrupt rotation %d" % rotation)` + early return (do NOT apply the formula, do NOT update state). This is a **runtime** guard that survives release builds — Godot's `assert()` is stripped in exports and must NOT be the sole defense. An additional `assert()` may coexist as a dev-time early-warning, but the `push_error()` + bail is the load-bearing check. GDScript's `%360` will silently "launder" an already-corrupt value (e.g. a stray `1080` from an unrelated bug → `0`, looking legal) — catch corruption at the input, don't let the modulo mask it.
**GDScript typing note:** `rotation` is typed as the same `Rotation` enum GridSystem itself uses (`R0=0, R90=90, R180=180, R270=270`), not a raw int. Arithmetic on enum values in GDScript 4.x promotes the expression to `int`; the result **must** be explicitly cast back: `rotation = ((rotation + 90) % 360) as Rotation`. Without the `as Rotation` cast, strict typing will reject the assignment.
**Example:** `rotation = 270` (3 presses so far) → 4th press → `((270 + 90) % 360) as Rotation = R0`.

---

The **instance_id_resume_formula** formula is defined as:

`next_instance_id = 0` if `S = ∅`; else `max(S) + 1`, where `S = {occupant_id(c) : c ∈ cells, occupant_id(c) ≠ -1}`

**Variables:**
| Variable | Symbol | Type | Range | Description |
|----------|--------|------|-------|-------------|
| Occupant id at cell | `occupant_id(c)` | int | `{-1} ∪ [0, INT_MAX)` | `-1` is GridSystem's confirmed empty sentinel |
| Occupied-id set | `S` | set[int] | `∅` or subset of `[0, INT_MAX)` | All non-empty occupant ids in the just-loaded snapshot |
| Next id to allocate | `next_instance_id` | int | `[0, INT_MAX)` | Never negative |

**Output Range:** `0` on a brand-new game or an empty-grid save (explicit base case — `max()` over an empty set is undefined, so this must be a branch, not a fallthrough); otherwise `max(S) + 1`.
**Note on the `-1` check:** `0` is a fully legal `instance_id` (the first-ever placed item) — comparing `occupant_id(c) != -1` is correct, but an implementation must never slip into GDScript's truthy-check idiom (`if occupant_id:`) here, since that treats a legitimate `0` as empty.
**Note on scan cost:** a full grid scan (trivial at 130 cells) is the only contract-compliant way to compute `S` — `GridStateReader`'s public interface exposes no "list all instance ids" method, only per-cell `get_occupant_id()`.
**Example:** A 3×3 grid with occupant ids `[-1,-1,2,-1,-1,-1,0,-1,-1]` → `S = {2, 0}` → `next_instance_id = 3`.

## Edge Cases

- **If `EquipmentCatalog.get_definition(equipment_id)` is called with an id that doesn't exist in the catalog** (e.g. stale Build/Shop UI data): fail loudly via `push_error()` and never enter `DRAGGING` — no silent no-op, no crash.
- **If a mouse-down on a shop-palette item occurs while already `DRAGGING` another item**: ignored — see Core Rule 11 (this is now a named rule, not just an edge case, since Core Rule 10's `is_dragging()` query depends on this silence being precisely specified).
- **If a relocate drag is cancelled or its drop is rejected, and a member was using the piece at drag-start**: the member was already displaced when occupancy cleared (Core Rule 1a) and is **not** restored to using the piece merely because the grid position is restored — this is an accepted, documented cost of the relocate-clears-on-start design (see Core Rule 1a's note and Player-Fantasy scope note below), not a bug.
- **If the drag is interrupted by an external event** (window loses focus, alt-tab, app minimized) mid-drag: treated identically to an Escape-cancel (Core Rule 6) — safe by construction, since nothing is written to GridSystem until a successful commit.
- **If the simulation is paused** (TimeSystem `speed_multiplier=0`) while a drag is in progress: no effect whatsoever. PlacementSystem is purely input-driven and never reads tick state — placement works identically whether the sim is paused or running.
- **Each new drag starts at `rotation = R0` (0°)**, regardless of what rotation the previous placement ended on. Rotation is drag-scoped state, not carried across placements — keeps behavior predictable (Pillar 3: every placement starts from the same legible default).
- **If `GridSystem.commit()` were ever called with an `instance_id` that already exists on the grid** (should be structurally impossible given Core Rules 7-8, but not provably impossible from this GDD alone): GridSystem's own contract already rejects invalid/duplicate ids via `push_error()` — this GDD relies on that existing defense rather than duplicating it, and treats any such occurrence as a bug to surface loudly, never silently overwrite.
- **Undo/redo (explicit decision — resolves GridSystem handoff, which demanded this be written down, not left to implementation):** MVP ships **no undo stack**. A mis-placed piece is removed via SelectionSystem's (#13) future sell/remove action, and its `instance_id` is simply retired for the session — **never reissued**, preserving the never-reused invariant GridSystem depends on. If a formal undo/redo is added post-MVP, a redo of a placement **must allocate a new `instance_id`**, never reuse the original — reuse would break that invariant and let SelectionSystem's caches silently point at the wrong instance. See OQ6.

## Dependencies

**Upstream dependencies (hard)**:

| System | Interface | Nature |
|---|---|---|
| GridSystem | `can_place()`, `commit()`, `clear()`, `get_transformed_cells()`, `world_to_grid()`, `get_occupant_id()`/`get_dimensions()` (via `GridStateReader`) | Hard |
| EquipmentCatalog | `get_definition(equipment_id)` | Hard |

**Downstream dependents**:

| System | Interface | Nature |
|---|---|---|
| Congestion/Flow Overlay + Placement Feedback (#8) | subscribes to GridSystem's `grid_changed` + PlacementSystem's `placement_committed` / `placement_rejected` | Hard |
| Build/Shop UI (#15) | initiates drags by `equipment_id`; owns affordability check pre-drag | Hard |
| Shop/Purchase (#12) | calls `is_dragging()` (Core Rule 10, new) before starting a purchase drag | Hard |

**One-way caller**: SelectionSystem (#13) — its Move action invokes PlacementSystem's `begin_relocate(instance_id)` (Selection → Placement, one-way; Placement never calls back). Both independently consume GridSystem. See Section C for the boundary rationale.

**Bidirectional consistency note**: when GridSystem's and EquipmentCatalog's own GDDs are next reviewed (or via `/consistency-check`), confirm they each list PlacementSystem as a downstream dependent — GridSystem's already does per the extraction; EquipmentCatalog's Dependencies table already lists PlacementSystem as a hard downstream consumer of `footprint_cells`/`access_cells`/`cost`. **Shop/Purchase (#12)'s own Dependencies table already lists this `is_dragging()` requirement and flags it as a required propagation into this file — that propagation is now complete as of this revision.**

## Tuning Knobs

PlacementSystem owns no designer-adjustable balance values of its own — it's a deterministic input/state-machine layer over already-owned data. The relevant knobs live elsewhere:
- Footprint size, access cell count, and cost per equipment → EquipmentCatalog's Tuning Knobs
- `cell_size` (world-to-grid conversion) → pinned at `/create-architecture`, applied via GridSystem's `world_to_grid()` (registry formula bundle `grid_world_conversion`)
- Grid dimensions (`grid_width`, `grid_height`) → GridSystem's registered constants

If a future need arises for an interaction-feel parameter (e.g. a drag-sensitivity threshold), it would be added here — none is needed for the continuous drag-follow model decided in Section C.

## Visual/Audio Requirements

**Ghost/preview treatment**: Footprint and access cells render as two visually distinct layers. Footprint: equipment sprite at 65% opacity, Soft Charcoal (`#3C3A42`) 1px solid outline. Access cells: separate overlay at 35% opacity with a diagonal-hatch pattern (not solid fill) so it's never mistaken for occupiable space — the hatch also satisfies a dual-channel (icon/pattern + color) accessibility rule. Both layers use plain `ColorRect`/`Sprite2D` modulate — no `DrawableTexture2D` needed; that stays reserved for the (separately HIGH-RISK-flagged) congestion heatmap.

**Valid vs. invalid**: **Valid** — footprint tints toward Sage, solid outline. **Invalid** — footprint desaturates toward a neutral Soft-Charcoal gray-wash (explicitly *not* red, *not* Dusty Rose — Dusty Rose is already claimed for congestion/needs-attention elsewhere, and reusing it here would blur two distinct meanings, violating Pillar 3's "same color, same concept" clarity), outline switches to dashed/broken (a shape-channel cue, not just color), plus a small muted "can't-place-here" glyph near the cursor. Reads as "not yet," not an alarm — matches Pillar 2.

**Differentiating the 5 failure reasons**: A single unified "invalid" visual state for MVP — teaching 5 distinct visual codes for a consequence-free, instantly-retriable action adds cognitive load the calm pillar doesn't need. One distinction comes for free: since footprint and access are already separate visual layers, *which* layer shows the invalid cue naturally distinguishes a footprint-blocked failure (OUT_OF_BOUNDS / BLOCKED_BY_ROOM_GEOMETRY / OVERLAPS_EXISTING_EQUIPMENT) from an access-blocked one (ACCESS_OUT_OF_BOUNDS / ACCESS_BLOCKED_BY_ROOM_GEOMETRY) without inventing new color language. Full reason text is deferred to a future tooltip (Congestion/Overlay #8's territory).

**Relocate origin placeholder (Core Rule 1a)**: While a relocate drag is in flight, the vacated footprint cells display a Soft Charcoal (`#3C3A42`) **dashed outline** at 40% opacity — no sprite, no fill, just the boundary. This reads as "this spot is reserved / cancel returns here" without competing visually with the active drag ghost. On cancel-restore the outline disappears (piece snaps back); on successful re-commit at a new location the outline fades out over ~200ms. This is load-bearing for Pillar 2: without it, the piece vanishes from the grid mid-drag with no visual anchor, creating a momentary "where did it go" anxiety even though the data is safe.

**Rotation feedback**: Instant swap, not a physical spin (spinning a flat pixel sprite reads as fake-3D). A ~90ms scale-pulse (1.0→1.05→1.0) via `create_tween().tween_property()` acknowledges the input, matching the established "轻弹性" UI motion standard. (Note: `tween_await()` is for "tween waits on an external signal mid-chain" — not applicable here; a plain tween property chain is the correct API for a fire-and-forget pulse.)

**Commit feedback**: A brief settle-bounce + light sparkle (per the art bible's VFX section), plus a short, soft "click/snap" SFX. This is flagged as one minimally-required SFX even if the broader audio system is post-MVP — it's load-bearing for Pillar 4's felt satisfaction on every single placement.

**Engine note**: All preview/highlight rendering uses `ColorRect`/`Sprite2D` modulate — cheap, well-understood, no new engine risk. `DrawableTexture2D` is deliberately not extended to this feature.

## UI Requirements

[To be designed]

## Acceptance Criteria

> Per this project's testing standards, PlacementSystem is a **Logic** story (deterministic state machine) — every criterion below requires a **BLOCKING** automated unit test in `tests/unit/placement_system/`.

1. **GIVEN** `equipment_id="treadmill_01"` exists in EquipmentCatalog and system is IDLE, **WHEN** mouse-down on that palette item, **THEN** `get_definition("treadmill_01")` is called exactly once and no further calls occur for the rest of that drag.
2. **GIVEN** DRAGGING with a held def, **WHEN** the mouse enters a new cell, **THEN** `can_place(def, anchor, rotation)` is called, GridSystem's occupancy is unchanged afterward, and the valid/invalid signal matches the returned bool.
3. **GIVEN** DRAGGING at R90, **WHEN** rotate fires, **THEN** rotation becomes R180 and `get_transformed_cells(def, anchor, R180)` supplies the preview cells (no local transform logic).
4. **GIVEN** rotation is corrupted to an out-of-enum value — injected via a **test-only internal setter** exposed specifically for this test (e.g. `_test_set_rotation_unchecked(value: int)`, documented here as the required white-box seam; this method must not be reachable from any production call site, only from `tests/unit/placement_system/`), **WHEN** rotate fires, **THEN** the precondition guard's `push_error()` fires *before* any write; rotation is never silently laundered to a valid value. **This white-box seam must exist in the implementation before this AC is writable** — it is not optional test infrastructure, it is the only way to construct this precondition at all.
5. **GIVEN** rotation=R270, **WHEN** rotate fires, **THEN** rotation becomes R0 (wrap-around case).
6. **GIVEN** DRAGGING and `can_place`=true for the current cell, **WHEN** mouse-up over it, **THEN** a new `instance_id` is allocated, `commit(id, def, anchor, rotation)` is called exactly once with those args, and `grid_changed` fires exactly once.
7. **GIVEN** `can_place`=false for the current cell, **WHEN** mouse-up, **THEN** the drag ends with no `instance_id` allocated, no `commit()` call, no `grid_changed`.
8. **GIVEN** DRAGGING, **WHEN** mouse-up occurs outside grid bounds, **THEN** the same no-op outcome as AC7.
9. **GIVEN** DRAGGING, **WHEN** Escape is pressed, **THEN** the same no-op outcome as AC7, regardless of current cell validity.
10. **GIVEN** counter=N and 3 prior cancelled drags, **WHEN** a 4th drag commits successfully, **THEN** the allocated id is N (cancellations never consumed an id) and the counter becomes N+1.
11. **GIVEN** a loaded snapshot with zero occupants, **WHEN** `deserialize()` completes, **THEN** `next_instance_id = 0`.
12. **GIVEN** loaded occupant_ids = {0, 2, 5} (no `-1` sentinels among them), **WHEN** `deserialize()` completes, **THEN** `next_instance_id = 6` — specifically confirming id `0` is counted as present, not treated as empty.
13. **GIVEN** a save that (via corruption or a legacy/hand-edited field the real serializer never writes) carries a stray stored counter value of 999, while the grid's actual max occupant id is 3, **WHEN** `deserialize()` completes, **THEN** `next_instance_id = 4` — re-derived from grid occupancy, ignoring the stray 999 entirely (defense-in-depth: the resume trusts grid state, never a stored counter).
14. **GIVEN** PlacementSystem's constructor/DI signature, **WHEN** inspected, **THEN** it accepts no currency/wallet dependency of any kind (static/API-surface check — not a per-drag behavioral test, since Core Rule 9 means there is no currency dependency to ever call in the first place; the prior framing of this AC as "zero calls to a mockable currency API" was vacuous, since no such mock is ever wired in).
15. **GIVEN** `"nonexistent_id"` is absent from EquipmentCatalog, **WHEN** mouse-down occurs on a palette item bound to it, **THEN** `push_error()` fires and state remains IDLE, never entering DRAGGING.
16. **GIVEN** DRAGGING is already active for drag A, **WHEN** a second mouse-down occurs on any palette item, **THEN** it is ignored — no second drag state, drag A's def/rotation/anchor unchanged.
17. **GIVEN** a drag is interrupted by a focus-loss/alt-tab event mid-drag, **WHEN** focus is lost, **THEN** the drag cancels identically to Escape (no `instance_id`, no `commit()`, no `grid_changed`).
18. **GIVEN** `speed_multiplier=0` (paused) throughout a drag, **WHEN** the full lifecycle (start→preview→rotate→commit) executes, **THEN** PlacementSystem makes zero calls to any TimeSystem API, and the outcome is identical to an unpaused drag.
19. **GIVEN** a prior drag committed or was cancelled at some non-R0 rotation, **WHEN** a new drag begins (same or different equipment_id), **THEN** the new drag's rotation starts at R0, not inherited from the previous drag.
20. **GIVEN** PlacementSystem's public API surface, **WHEN** inspected, **THEN** it exposes **exactly one** entry point that starts from an already-committed `instance_id` — `begin_relocate(instance_id)` (Core Rule 1a) — and **no** method for *inspecting* or *selling* a placed instance (those remain SelectionSystem's). Static/API-surface check, not a runtime behavior test.
21. **GIVEN** a successful commit of `equipment_id="treadmill_01"` allocated as `instance_id` N, **WHEN** the commit completes, **THEN** `placement_committed(N, "treadmill_01", footprint_cells)` is emitted exactly once, after `GridSystem.commit()` returns, and no `placement_rejected` fires.
22. **GIVEN** a drop over the grid where `can_place()` returns `FAIL(OVERLAPS_EXISTING_EQUIPMENT)`, **WHEN** the drop resolves, **THEN** `placement_rejected(equipment_id, anchor, rotation, OVERLAPS_EXISTING_EQUIPMENT)` is emitted exactly once and no `placement_committed` fires.
23. **GIVEN** a drag that ends via Escape, focus-loss, or a drop outside grid bounds, **WHEN** it resolves, **THEN** neither `placement_committed` nor `placement_rejected` is emitted (silent cancel).
24. **GIVEN** a relocate started via `begin_relocate(N)` for a piece at `(anchor₀, rotation₀)`, **WHEN** the drag is cancelled (Esc / focus-loss / a rejected drop with no valid landing), **THEN** instance `N` is restored to `(anchor₀, rotation₀)` under the **same** `instance_id`, GridSystem occupancy matches the pre-relocate state cell-for-cell, and no `placement_committed`/`placement_rejected` is emitted for a *new* id.
25. **GIVEN** a relocate started via `begin_relocate(N)` for a piece at `(anchor₀, rotation₀)`, **WHEN** the drag drops on a **different** valid cell `anchor₁` (with possibly rotated `rotation₁`), **THEN**: (a) `GridSystem.commit(N, def, anchor₁, rotation₁)` is called (re-using the **same** `instance_id` N — no new allocation from the counter), (b) `grid_changed` fires exactly once for the new position, (c) `placement_committed(N, equipment_id, new_footprint_cells)` is emitted (same signal as new placement — downstream consumers identify it as a relocate by recognizing a pre-existing `instance_id`), (d) GridSystem occupancy shows N at `anchor₁` and `anchor₀` is clear, (e) the internal `next_instance_id` counter is unchanged (no increment).
26. **GIVEN** a relocate started via `begin_relocate(N)` and the drag drops on the grid but `can_place` returns FAIL, **WHEN** the rejected drop resolves, **THEN** the piece is **restored** to `(anchor₀, rotation₀)` — a rejected relocate-drop is treated identically to a cancel (not left in limbo). `placement_rejected` does NOT fire (relocate reject is silent restoration, not a failed new-placement attempt).
27. **GIVEN** PlacementSystem is already in `DRAGGING` state (any source — new placement or relocate), **WHEN** `begin_relocate(instance_id)` is called, **THEN** it is a no-op: `push_error()` fires, state remains unchanged, the in-flight drag is not disrupted, and the piece identified by `instance_id` remains at its current grid position unaffected.
28. **GIVEN** state is `IDLE`, **WHEN** `is_dragging()` is called, **THEN** it returns `false` with no state change and no side effects (Core Rule 10).
29. **GIVEN** state is `DRAGGING` (either a new-placement drag or a relocate), **WHEN** `is_dragging()` is called at any point mid-drag, **THEN** it returns `true` with no state change and no side effects (Core Rule 10).
30. **GIVEN** a relocate is started via `begin_relocate(N)` for a piece a member is actively using, **WHEN** the drag begins, **THEN** occupancy clears immediately (Core Rule 1a), MemberSim's equipment-deleted-mid-use handling is triggered for that member, **and** — if the drag is subsequently cancelled or rejected — the member's displaced state is **not** reverted even though the piece's grid position is restored (this AC exists to make the documented cost in Core Rule 1a testable/observable, not just narratively described).

**Explicitly out of this GDD's test scope**: duplicate-`instance_id` rejection is GridSystem's own contract (`push_error()` on invalid/duplicate ids) — that behavior must be covered by GridSystem's test suite, not PlacementSystem's. Similarly, whether a retired `instance_id` (from a sold/removed piece) is ever reissued is untestable by PlacementSystem alone, since the counter is grid-derived (Core Rule 8) and sold items simply leave the grid — this invariant can only be exercised once SelectionSystem's sell path exists; tracked in OQ6, not asserted here as a standalone AC.

## Pinned Engine Caveats — Godot 4.7.1 (mixed verification status — see per-item notes)

- **`class_name` not globally registered under headless load** → reference cross-script
  classes via `preload` const aliases (e.g. `const GridSystemScript := preload("res://...")`).
- **`class_name` must follow `extends` immediately** (not after const/var).
- **`var x := expr` fails inference on Variant returns / dict literals** → explicit `: Type`.
  This applies beyond the `rotation` enum cast noted in Formulas (line 84): any local holding
  a `get_*()` result or a dictionary literal must be explicitly typed.
- **Lambda closures do NOT write back outer-scope locals** → use a `RefCounted` counter class
  with a method callback for any signal-driven counting in tests (e.g. asserting
  `grid_changed` fires exactly once — AC6/AC7).
- **Signal emit arity must exactly match the connected callable** — write both args explicitly,
  e.g. `grid_changed.emit(fp_cells, ac_cells)`, never `emit(fp_cells + ac_cells)` as one array
  (that silently emits 1 arg → arity crash). Core Rule 5's "exactly once" guarantee depends on this.
- **`rotation` enum arithmetic** (Formula note, line 84): `(rotation + 90) % 360 as Rotation` —
  **NOT yet engine-verified.** The current vertical-slice prototype
  (`prototypes/gym-flow-vertical-slice/src/sim/placement_system.gd`) types `rotation` as
  plain `int` throughout and never defines a `Rotation` enum or uses this cast — this pattern
  has never actually been run. Treat this as a **known 4.7.x pitfall pattern carried over from
  GDScript typing rules in general**, not as something confirmed working in this project's own
  codebase. **Before `/dev-story` implements this formula, spike the `as Rotation` cast against
  an actual `Rotation` enum in a throwaway script to confirm it compiles and behaves as described**
  — do not assume it from this GDD alone.
- **Other items in this list** (`class_name` headless registration, `var x :=` inference failures,
  lambda closures not writing back outer locals, signal emit arity) are general Godot 4.7.1
  GDScript behaviors well-documented in the `godot-4x-gdscript-pitfalls` skill, not specific to
  something exercised in this project's own vertical slice — treat them as reliable *general*
  engine knowledge, distinct from the rotation-cast claim above which specifically (and
  incorrectly) claimed project-specific verification.
- **Signal-emit arity risk is not limited to `grid_changed`.** `placement_committed(instance_id,
  equipment_id, footprint_cells)` (3 args) and `placement_rejected(equipment_id, anchor, rotation,
  fail_code)` (4 args) carry the identical arity-mismatch risk this section already documents for
  `grid_changed` — write all args explicitly at every `.emit()` call site, and apply the same
  `RefCounted`-counter-class workaround (not a lambda closure) when asserting "emitted exactly
  once" in tests for AC21–23, the same way AC6/AC7 already require it for `grid_changed`.
- **Bridge-Node ownership must be pinned to the composition root, not the presentation layer.**
  Because PlacementSystem is `RefCounted`, it has no `_exit_tree`-equivalent cleanup hook. If the
  presentation-layer bridge Node (not `SimulationOrchestrator`) holds the sole strong reference to
  it, destroying/recreating that Node mid-drag (e.g. a scene transition or pause-menu overlay
  swap) silently frees PlacementSystem and loses `DRAGGING` state with no warning — a case not
  covered by the existing focus-loss/Escape edge cases. `/create-architecture` must pin ownership
  to the composition root.
- **Mouse-move preview forwarding must use input events, not `_process()` polling.** The bridge
  contract (Interactions with Other Systems) lists `_process()` as one of three callback types it
  may forward. If mouse-move preview is wired through `_process()` polling rather than
  `_input()`/`_unhandled_input()` `InputEventMouseMotion` events, `can_place()`/`world_to_grid()`
  would fire every frame regardless of whether the cell actually changed, mismatching the States
  table's "moves to a new cell" event granularity (AC2). `/create-architecture` must pin mouse-move
  forwarding to input events, reserving `_process()` forwarding (if used at all) for other needs.

Full list: skill `godot-4x-gdscript-pitfalls`.

## Open Questions

| # | Question | Owner | Target Resolution |
|---|---|---|---|
| OQ1 | Wiring `get_speculative_snapshot()` into a ZoneRules synergy preview overlay is deferred — ZoneRules (#9) doesn't exist yet. **Also requires extending GridSystem's per-consumer contract**, which currently grants `get_speculative_snapshot()` to ZoneRules only, not PlacementSystem. | Whoever designs ZoneRules (#9); grid-system.md contract update | When ZoneRules is designed |
| OQ2 | Reason-specific failure feedback (tooltip/toast per FAIL code) is deferred to Congestion/Overlay (#8) — cross-references that system's own inherited requirement (from GridSystem) that access-blocked state must be default-visible, not hidden behind a toggle. | Whoever designs Congestion/Flow Overlay (#8) | When #8 is designed |
| OQ3 | The placement commit SFX (Visual/Audio Requirements) is flagged as minimally required at MVP even though the full Audio system (#20) is Vertical-Slice tier, not MVP — needs at least a placeholder asset before this system's own implementation. | audio-director / sound-designer | Before `/dev-story` implementation of this system |
| OQ4 | ✅ **Partially resolved.** PlacementSystem assumes any drag it receives is already affordability-cleared (Core Rule 9). Shop/Purchase (#12, Approved) now specifies this handoff and additionally requires `is_dragging()` (Core Rule 10, added this revision) as a pre-drag gate. Remaining: confirm at `/create-architecture` that Build/Shop UI (#15)'s palette mouse-down → drag-start call site actually threads through Shop's `can_purchase` + `is_dragging` gate correctly (an integration concern, not a spec gap). | Build/Shop UI (#15) owner, at `/create-architecture` | When #15 is designed / architecture phase |
| OQ5 | The valid/invalid visual distinction already pairs color with a shape cue (solid vs. dashed outline), which should satisfy colorblind-mode accessibility requirements — but this should be explicitly confirmed, not assumed. | accessibility-specialist | When Settings & Accessibility (#22) is designed |
| OQ6 | The undo/redo decision is written into Edge Cases (MVP: no undo; retired ids never reissued; post-MVP redo must allocate a new id). This OQ is the forward-pointer to *revisit and implement* that policy if/when a formal undo/redo feature is actually scheduled. | Whoever designs an undo/redo feature (post-MVP) | When undo/redo is scheduled |
