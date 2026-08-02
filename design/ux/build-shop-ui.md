# UX Spec: Build / Shop UI

> **Status**: ✅ Approved (2026-08-02 — ux-design gate, gate-check item #4)
> **Author**: user + ux-designer
> **Last Updated**: 2026-08-02
> **Journey Phase(s)**: Unknown — no player journey map yet (see Open Questions OQ1)
> **Template**: UX Spec
> **Platform Target**: PC desktop (macOS primary, Windows secondary); Keyboard/Mouse primary, Gamepad partial, Touch none
> **Source GDDs**: `design/gdd/build-shop-ui.md` (#15, Designed) + `design/gdd/shop-purchase.md` (#12, Approved) — normative for rules; this spec is the visual/interaction formalization.
> **Implements Pillar**: Pillar 1 (空间即玩法 — where buying-and-placing happens) · Pillar 3 (一眼看懂 — a clear, uncluttered build interface) · Pillar 2 (松弛不紧绷 — unaffordable items are calmly greyed, never scolding)

---

## Purpose & Player Need

The player arrives at the Shop wanting to **buy equipment and put it on the floor** —
the workbench of the game. The player goal: "pick up a machine I can afford, drop it
somewhere it fits, and see my gym grow." If this screen were hard to use, the core
loop would stall at the first step — buying is how a thriving gym grows, and the
palette must make every available option obvious (Pillar 3: no buried menus) while
making unavailability *gentle* (Pillar 2: "not yet" is greyed and patient, never a
red denial). The single most important thing: **the player can always see what they
can buy and afford, and picking it up and placing it feels like play, not paperwork.**

---

## Player Context on Arrival

- **When first encountered**: at game start — the starter catalog (a few free/cheap
  pieces) is the first thing the player sees on the palette, inviting the first drag.
- **What they were just doing**: either starting a new game (empty gym, palette
  prominent) or mid-session after earning money (balance rising → items lighting up).
- **Emotional state**: eager and curious (autonomy — "what can I build?"); no stress
  (nothing is lost by trying).
- **Voluntary or sent**: voluntary — the player chooses to browse/buy; the palette
  is always available (edge-docked), so it's ambient rather than a separate visit.

---

## Navigation Position

The Shop palette is **edge-docked and always available** inside the game session —
it is not a separate screen or a modal.

```
[Main menu]
   └─ [Game session (HUD always on)]
        ├─ Shop palette (bottom edge rack)  ← this spec
        │     └─ mouse-down item → placement drag (build mode)
        ├─ Grid interaction: click placed piece → Selection UI (sibling)
        └─ Flow overlay (toggle H) — independent layer
```

It is a **top-level, always-reachable** context (not context-dependent). The build
and select modes are mutually exclusive siblings — one is visually active at a time
(GDD #15 Core Rule 4).

---

## Entry & Exit Points

| Entry Source | Trigger | Player carries this context |
|---|---|---|
| Game session | Always present (palette visible on the screen edge) | Current balance, catalog availability |
| (selection active) | Clicking a palette item first clears any selection (build takes over) | Selection cleared; drag begins |

| Exit Destination | Trigger | Notes |
|---|---|---|
| Build drag active | Palette mouse-down on affordable item | PlacementSystem owns the drag; palette disabled |
| Build drag → commit | Valid drop | Placement commits; Shop spends once; palette re-greys + re-enables |
| Build drag → reject/cancel | Invalid drop / Esc / out-of-bounds | No spend; palette re-enables; reject tooltip or silent-cancel cue |
| (back to select mode) | Placement drag ends | Grid is clickable again; selection re-enabled |

There are no one-way exits: the palette is always available; canceling a drag always
returns the item to the palette with zero cost (deduct-on-commit guarantee).

---

## Layout Specification

### Information Hierarchy

1. **What I can afford right now** — affordable items full-tint and draggable; this is the primary "go" signal.
2. **What I could afford soon** — greyed items with "Save $X more" on hover (legible "almost there").
3. **What isn't available yet** — locked items with a lock icon (distinct from merely-unaffordable).
4. (Discoverable) — item detail (name, stats, effects) via hover tooltip / future info panel.

### Layout Zones

```
┌──────────────────────────────────────────────────────────────┐
│ [HUD top bar — money, satisfaction, day/time, transport]      │
│                                                               │
│                                                               │
│                       G Y M   F L O O R                       │
│                    (placement ghost + overlay)                │
│                                                               │
│                                                               │
│ ┌──────────┬──────────┬──────────┬──────────┬──────────┐     │
│ │  🏃 跑步机 │  🏋 深蹲架 │  ⚙️ 划船机  │  🔒 ???   │  🧘 瑜伽垫 │ ← Bottom-edge rack
│ │  $350    │  $650    │  $200    │  LOCK    │  $100    │    │
│ └──────────┴──────────┴──────────┴──────────┴──────────┘     │
└──────────────────────────────────────────────────────────────┘
```

- **Zone A — Grid (play area)**: where the drag ghost renders; the palette never covers the grid center.
- **Zone B — Palette rack (bottom edge, recommended)**: 5–6 tiles at MVP; each tile = icon + name + Butter price.
- **Zone C — HUD**: unchanged; money display updates live (Count-Up), palette re-greys in sync.
- **Zone D (optional future)**: side-edge rack for narrow windows (16:10 / 4:3) or if the bottom conflicts with gameplay.

### Component Inventory

| Component | Type | Content | Interactive | Pattern |
|---|---|---|---|---|
| Palette tile (affordable) | tile | icon, name, price | yes (mouse-down → drag) | Palette (edge-docked rack) |
| Palette tile (unaffordable) | tile (greyed) | icon, name, price; hover "Save $X more" | no (inert) | Palette + Hover Tooltip |
| Palette tile (locked) | tile (greyed + lock icon) | icon, name, price, lock | no (inert) | Palette |
| Drag ghost | overlay | footprint + access validity tint | (system) | Ghost Preview + Rejection Feedback |
| Rejection tooltip | tooltip | "Won't fit here" / "Blocks the path in" | no | Hover Tooltip (hold-triggered) |
| Silent-cancel cue | feedback | item returns to idle with soft cue | no | Palette (return cue) |

### ASCII Wireframe

See Layout Zones above — bottom-edge rack with 5 tiles, each icon+name+price;
locked tile shows a lock badge; greyed tiles desaturated. During a drag, the ghost
follows the cursor over the grid with footprint/access tinting; palette is visibly
disabled (dimmed) while the drag is in flight.

---

## States & Variants

| State / Variant | Trigger | What Changes |
|---|---|---|
| Default (idle) | Palette shown, no drag | All tiles rendered per availability; affordable full-tint |
| Balance changed | `balance_changed` fires | Palette re-greys; newly affordable items light up within one frame |
| Build drag active | Mouse-down on affordable tile | Palette disabled (one-drag invariant); ghost follows cursor; heatmap dims to ≤20% |
| Drag rejected | Drop on invalid cell | Rejection tooltip (bucket message) after ~400 ms hold; palette re-enables |
| Drag silent-canceled | Esc / out-of-bounds / focus loss | Return-to-palette cue; palette re-enables; no spend |
| Drag committed | Valid drop | Snap-in animation; Shop spends; palette re-greys against new balance |
| Selection active | `selection_changed(non-null)` | New-placement ghost suppressed (no dual ghost); palette still visible |
| Empty / all-locked catalog | No purchasable items | Calm "nothing available yet" hint; nothing draggable; no error |
| Loading | (n/a) | **No loading state**: catalog, availability, and balance are synchronous reads; nothing is fetched async |
| Reduced-motion variant | Setting ON | No bounce on snap-in; tooltips instant; same info |

---

## Interaction Map

Input methods: **Keyboard/Mouse** (primary), Gamepad partial (stretch). Mapping:

| Component | Action | Input | Immediate feedback | Outcome |
|---|---|---|---|---|
| Affordable tile | Start drag | Mouse-down (hold) | Ghost attaches to cursor, snaps to grid | PlacementSystem drag begins; Shop sets `_purchase_in_flight` |
| Tile (any) | Hover | Mouse hover | Affordable: lift + tooltip; greyed: "Save $X more"; locked: lock tooltip | — (no drag) |
| Drag ghost | Move | Mouse move | Ghost re-snaps cell-to-cell; validity tint updates live | preview recomputed |
| Drag ghost | Rotate | **R** / right-click | Ghost rotates 90° | `rotation = (rotation + 90) % 360` |
| Drag ghost | Commit | Mouse-up over valid cell | Snap-in (咔哒 + bounce) | Placement commits; `Economy.spend(cost)` once |
| Drag ghost | Reject | Mouse-up over invalid cell | Rejection tooltip (bucket) | No spend; `placement_rejected` fires |
| Drag ghost | Cancel | Esc / mouse-up outside grid | Silent return cue | No spend; no signal (silent cancel) |
| Palette tile (keyboard) | Focus | Tab / arrows | Focus indicator moves | cell/tile focus |
| Palette tile (keyboard) | Start keyboard drag | Enter | Ghost follows arrow keys; R rotates; Enter commits; Esc cancels | same outcomes as mouse |
| (second tile during drag) | Attempt second drag | Mouse-down | **Blocked** — palette disabled | one-drag invariant holds (no second purchase) |

**Keyboard-only path**: Tab → palette tiles; arrows move tile focus; Enter starts a
keyboard drag (arrows move ghost, R rotates, Enter commits, Esc cancels); Esc from
idle returns to grid. This path must exist and reach every tile (MVP polish level
per interaction-patterns.md OQ3).

**Gamepad (partial)**: d-pad moves tile focus; A starts drag; B cancels; no gamepad
shortcut for rotate beyond the same button mapping (see AQ2).

---

## Events Fired

| Player Action | Event Fired | Payload / Data |
|---|---|---|
| Mouse-down affordable tile | (PlacementSystem drag start; Shop `_purchase_in_flight` set) | equipment_id |
| Placement committed (purchase) | `placement_committed(instance_id, equipment_id, footprint_cells)` → Shop `Economy.spend(cost)` | instance id, equipment id, cells; cost spent once |
| Placement rejected | `placement_rejected(equipment_id, anchor, rotation, fail_code)` | fail code → bucket tooltip |
| Silent cancel | (no signal by design) | palette return cue (UI-side) |
| Palette re-grey | (on `balance_changed` — economy signal) | — |

Note: `spend()` modifies persistent economy state — deduct-on-commit guarantee means
no spend on cancel/reject (Shop GDD Core Rule 2). The one-drag invariant is the
load-bearing guarantee (Shop GDD Core Rule 3) — flagged for architecture attention.

---

## Transitions & Animations

- **Enter (palette)**: palette is always present — no entry transition (or subtle slide-in on first load).
- **Drag pick-up**: ghost attaches to cursor with a small scale-up (~100 ms).
- **Snap-in (commit)**: 咔哒 + slight scale bounce, 120–250 ms (art bible §7); reduced-motion: snap only.
- **Reject**: rejection tooltip fades in after ~400 ms hold; no sound (silence, GDD #8).
- **Silent cancel**: item returns to palette with a lightweight visual/audio return cue (mandatory — resolution not invisible, Shop GDD Core Rule 4b).
- **Grey→tint (affordable now)**: tile transitions from desaturated to full tint over ~150 ms — a quiet "it's yours now" moment.
- **Drag dim**: heatmap dims to ≤20% during a drag (~150 ms) so the ghost reads clearly.

---

## Data Requirements

| Data | Source System | Read / Write | Notes |
|---|---|---|---|
| Catalog items (icon, name, cost) | EquipmentCatalog | Read | via Shop (`can_purchase`, `is_unlocked`) |
| Affordability state | Economy + Shop | Read | re-evaluated on `balance_changed` |
| Lock state | Shop `is_unlocked` | Read | MVP stub: `unlock_requirement == null` |
| "Save $X more" value | Economy + Catalog | Read (computed) | `cost - balance` |
| Drag validity | PlacementSystem (can_place) | Read | live preview, no writes |
| Placement ghost state | PlacementSystem | Read | `is_dragging()` query |
| Selection state | SelectionSystem | Read | `selection_changed` → ghost suppression |
| Balance (HUD) | Economy | Read | HUD owns display; palette re-greys on same signal |

**Ownership guard**: the UI owns **no** game state — no money, no catalog data, no
placement/selection state (GDD #15 Core Rule 5). It renders and routes input only.

**Update frequency**: availability is event-driven (`balance_changed`); drag preview
is per-frame during a drag; ghost validity per-cell on mouse move.

**Null handling**: empty/all-locked catalog → calm "nothing available yet" state (no
error, no crash, GDD #15 Edge Cases).

---

## Accessibility

- **Tier**: Standard (WCAG-AA) per `design/ux/accessibility-requirements.md`.
- Colorblind-safe palette: affordable = full tint, unaffordable = desaturation, locked = desaturation **+ lock icon** (shape, not color-only) — GDD #15 AC8.
- **Locked vs unaffordable must be visually distinct** (Shop GDD Core Rule 5): lock icon is mandatory — a locked item rendered like a merely-unaffordable one teaches a false mental model.
- Keyboard path complete: Tab/arrows/Enter/R/Esc (see Interaction Map).
- Contrast: price text ≥16px @1080p, AA on the palette background; Butter prices contrast on Warm Cream.
- No flashing: nothing flashes; grey→tint is a calm transition (not a pulse).
- Tooltips are supplementary: "Save $X more" also readable from price vs balance comparison (persistent info, not tooltip-only).

---

## Localization Considerations

| Element | Max chars (EN) | Risk |
|---|---|---|
| Tile names (跑步机 / Treadmill…) | ≤ 12 | **HIGH PRIORITY** — 40% expansion must fit the tile at 1.5× UI scale without clipping the price |
| Price display ($350) | ~8 | currency symbol + separators must not collide with the name |
| "Save $X more" tooltip | ~20 | wraps within tooltip bounds; not layout-critical |
| "Nothing available yet" empty state | ~24 | must fit the palette band at 1.5× |

---

## Acceptance Criteria

- [ ] **Palette opens/renders within 100 ms** of game load (or scene entry), showing all catalog tiles with correct availability states; no perceptible delay.
- [ ] **All three availability states render correctly and distinctly**: affordable (full tint, draggable), unaffordable (greyed, inert, hover "Save $X more" = `cost - balance`), locked (greyed + lock icon, inert) — verifiable with color desaturated.
- [ ] **Drag flow works**: mouse-down on an affordable tile starts a placement drag; ghost snaps cell-to-cell; R rotates 90° per press; valid drop commits (placement appears, balance decreases by cost exactly once); invalid drop shows the correct bucket tooltip ("Won't fit here" vs "Blocks the path in") after ~400 ms hold and spends nothing.
- [ ] **One-drag invariant holds**: while a drag is in flight, the palette is disabled — a second mouse-down cannot start a second purchase (no double spend).
- [ ] **Cancel/reject is free**: Esc / out-of-bounds / invalid drop leaves balance unchanged and returns the item to the palette with a visible return cue.
- [ ] **Re-grey on balance change**: when balance crosses an item's cost, that tile becomes full-tint and draggable within one frame of `balance_changed`; when balance drops below, it greys.
- [ ] **Selection arbitration**: with a piece selected, the new-placement ghost is suppressed (no dual ghost); clicking a palette item while a piece is selected clears the selection and starts the drag.
- [ ] **Keyboard-only path**: Tab + arrows + Enter + R + Esc reaches and operates every palette tile and completes a keyboard drag (place, rotate, cancel).
- [ ] **Empty catalog**: with no purchasable items, the palette shows the calm empty state — nothing draggable, no error, no crash.
- [ ] **Colorblind pass**: desaturated screen — affordable/unaffordable/locked still distinguishable via tint-desaturation + lock icon (GDD #15 AC8).
- [ ] **Resolution robustness**: at 1280×720, 1920×1080, and 2560×1440, the palette rack and tiles render correctly with no clipping; tile text and prices ≥16px @1080p at UI scale 1.0×.
- [ ] **UI scale**: at 1.5× UI scale, all tiles and prices fit within the rack with no overlap of the play area.

---

## Open Questions

| # | Question | Owner | Target Resolution |
|---|---|---|---|
| OQ1 | Player journey map not yet created. Template available at `.claude/docs/templates/player-journey.md`. Run `/ux-design` Phase 2b or create it manually to establish player context for this screen. | ux-designer / producer | Before first UI playtest |
| OQ2 | Palette edge (bottom vs side) and tile size — **recommended: bottom-edge rack**, 16:9; side-edge fallback for narrow windows. Confirm in `/team-ui` Phase 1. | ux-designer / ui-programmer | team-ui kickoff |
| OQ3 | Build/select mode affordance — **MVP leans implicit** (mouse-down palette = build; click placed piece = select). Confirm no explicit mode toggle is needed. | ux-designer | team-ui kickoff |
