# Congestion/Flow Overlay + Placement Feedback

> **Status**: In Design
> **Author**: user + agents
> **Last Updated**: 2026-07-18
> **Implements Pillar**: Pillar 3 (一眼看懂 — the system that makes flow legible at a glance) · Pillar 2 (松弛不紧绷 — information, never alarm) · Pillar 1 (空间即玩法 — reveals the causal link between layout and flow)
> **Creative Director Review (CD-GDD-ALIGN)**: Skipped — Lean review mode (not a PHASE-GATE at lean).
>
> ⚠️ **Pinned engine: Godot 4.7.1.** 本系统的渲染实现（Core Rule 2/4 的 heatmap/glyph/tooltip 文字）须注意：headless 下 `class_name` 不跨脚本全局注册（须 `preload` 别名）；`CanvasItem.draw_string` 的首参是 `Font` 且 `font_size` 在 `color` 之前（与旧文档不同）；`var x := get_*()` 推断失败（须显式 `: Type`）。完整坑清单见 skill `godot-4x-gdscript-pitfalls`。
> **🎯 FUN-VALIDATION MILESTONE**: This is the order-8 system. Once it exists, the core loop (place → members flow → see crowding → rearrange) is playable end-to-end and must be **prototyped and playtested** before building economy/meta.
> **Playtest evidence (2026-07-18)**: the concept prototype validated **PROCEED** (`prototypes/gym-flow-concept/REPORT.md`). Two findings are baked in below: (1) the **per-cell heatmap is the hero feedback channel** — the player's best moment was "让热力图散开感觉很爽" (watching congestion disperse while rearranging), while per-equipment glyphs were nearly ignored → heatmap is **primary**, glyph **secondary** (Core Rules 2 & 4). (2) color-only member rendering was illegible ("看不清谁在排队") → reinforces the shape-first rule; the member-sprite fix itself lives in MemberSim #6.

## Overview

This is the presentation layer that makes the whole MVP hypothesis *visible*. It renders the data the Congestion system computes — a soft per-cell density heatmap, a per-equipment congestion indicator, and the always-visible "this machine is walled off" (`access_reachable == false`) warning — and it owns the reason-specific feedback when a placement is rejected. It is the payoff surface for Pillar 3 (一眼看懂): crowding that would otherwise be an invisible emergent property of member pathing becomes a calm, readable heatmap the player can toggle on to diagnose their layout. It is deliberately gentle (Pillar 2): the heatmap reads as soft fog rather than a spreadsheet, congestion uses a soft Dusty Rose that never flashes, and rejection feedback is a quiet "won't fit" rather than a failure buzz. It renders no game state of its own — it is a pure consumer of Congestion's outputs and PlacementSystem's `placement_rejected` signal — but it carries a hard responsibility: the `access_reachable` indicator **must be default-visible**, because GridSystem deliberately stays silent when the player boxes in a machine, making this overlay the *only* channel through which the player ever learns why that machine sits unused.

## Player Fantasy

This is the "aha" layer. The fantasy is the moment of *understanding*: you notice a machine sitting empty, flip on the flow overlay, and instantly see the pink congestion clotting one aisle while another sits cold — and you *get it*, without reading a number or a tutorial. It's the diagnostic pleasure of a well-designed dashboard: the game hands you exactly enough sight to feel clever, then gets out of the way so you can rearrange and watch the mist clear. It directly serves Pillar 3's promise ("一眼看懂，越品越深") — a glance tells you where the problem is, and the depth of *fixing* it is where mastery lives. And it keeps Pillar 2's calm: every cue here is an invitation to tinker, never a scolding. Reference feel: the legible flow language of Mini Motorways (where you *see* the traffic knot and itch to fix it), rendered in a warm, unhurried, cozy register.

## Detailed Design

### Core Rules

1. **Three render layers, independent visibility.** The system maintains three visual channels with separate visibility rules:
   - **Heatmap layer** — the per-cell density field; **toggle-gated** (default OFF) and auto-dimmed during placement drags.
   - **Per-equipment congestion glyph** — a small shape-filling icon on each equipment; toggle-gated *with* the heatmap.
   - **Access-blocked layer** — the `access_reachable == false` barricade icon; **always-on, never gated** by the toggle or the drag-dim. This is the one element that survives every other layer's visibility rule.

2. **Heatmap rendering (ImageTexture + shader, soft).** The 13×10 density field (`per_cell_density`, `[0,1]` per cell from Congestion) is written into a 13×10 `Image`/`ImageTexture` and sampled by a `CanvasItem` shader over a grid-covering `ColorRect`. The shader forces **bilinear** sampling on *this sampler only* (per-sampler in GDShader, independent of the project's global Nearest filter) so the heatmap reads as **soft fog**, not a per-cell spreadsheet — a deliberate, isolated exception to the pixel-art crispness that fits the cozy/calm aesthetic. Density maps to color via `density_to_heat` (see Formulas): low density stays transparent (calm), only real crowding warms toward Dusty Rose. **`DrawableTexture2D` is explicitly NOT used** for MVP (unverified against 4.7.1, zero benefit at 130 texels) — see Open Questions.

3. **Update cadence: 10 Hz, not per-frame.** The `Image` is rewritten and `ImageTexture.update()` called **only** when Congestion emits its per-tick `congestion_updated` signal (10 Hz), never in `_process`. The shader/ColorRect renders every frame from the currently-bound texture (free); only the CPU-side pixel writes + upload are gated to the sim tick. Equipment glyphs update on the same signal.

4. **Per-equipment congestion glyph (shape-first, secondary channel).** Each equipment instance carries a small icon whose **shape/fill** is the primary signal — an empty outline fills up as congestion rises — with Dusty Rose tint as *secondary* reinforcement only. This satisfies colorblind safety by construction (fill level is readable with color removed). Toggle-gated with the heatmap. **Playtest note (2026-07-18):** in the concept prototype the heatmap (Core Rule 2) carried nearly all of the crowding signal while these per-equipment glyphs were largely ignored — so the glyph is explicitly a **secondary** readout. Prioritize heatmap clarity and its dissipation-on-rearrange responsiveness (the validated "very satisfying" moment) over glyph detail.

5. **Access-blocked indicator (default-visible, the hard requirement).** When an equipment's `access_reachable` flips false, a distinct **barricade / broken-link glyph** (Soft Charcoal outline, Dusty Rose fill secondary — shape-first) fades in once above the equipment's **access cell**, at a fixed UI-layer scale (does not shrink with camera zoom), then holds **static** — no pulse, no loop (a loop would read as an alarm; a one-time fade-in draws the eye once then sits as information). It renders on the always-on layer regardless of the heatmap toggle or drag state. Hover shows a one-line tooltip: *"Can't be reached — check for a blocked path"* — never "ERROR" or exclamation iconography. This is the concrete fulfillment of GridSystem's OQ#9 and Congestion's OQ1. **Default-visible is mandatory, not event-gated: on first scene entry (or save load), every already-unreachable equipment must show its barricade icon immediately, with no intervening "fade-in on false" trigger required** — the overlay reads the current `access_reachable` set on entry and materializes icons for all `false` entries up front. This is the load-bearing clause: a machine the player walled off in a prior session must be visible the instant the scene appears, not only after the next `grid_changed`. The edge-case row "equipment `access_reachable` → false ⇒ Visible (single fade-in)" governs *subsequent* edits during play; it does NOT relax the on-entry default-visible rule.

6. **Placement rejection feedback (2 buckets, not 5 codes).** On `placement_rejected(equipment_id, anchor, rotation, fail_code)` from PlacementSystem, this system shows a single calm cursor-adjacent tooltip **only after the cursor holds ~400 ms over an invalid cell** (prevents flicker while sweeping the grid). The 5 fail codes collapse into 2 buckets, reusing the ghost's existing footprint-vs-access split (PlacementSystem already tints those two cell groups, so the detail is free):
   - **Footprint bucket** (`OUT_OF_BOUNDS`, `BLOCKED_BY_ROOM_GEOMETRY`, `OVERLAPS_EXISTING_EQUIPMENT`) → *"Won't fit here"*
   - **Access bucket** (`ACCESS_OUT_OF_BOUNDS`, `ACCESS_BLOCKED_BY_ROOM_GEOMETRY`) → *"Blocks the path in"*
   No sound is tied to rejection (silence, not a failure buzz — Pillar 2). Five distinct messages would over-teach a zero-stakes, instantly-retriable action.

7. **Information layering priority (contention rule).** When multiple layers compete, the one serving the most *active* decision wins: (1) access-blocked icons — always full opacity, never dimmed; (2) placement ghost — full opacity during a drag; (3) per-equipment congestion glyph — stays visible during a drag (small, decision-relevant); (4) the heatmap — the softest, most ambient layer, which dims to ≤20% opacity during a drag (so the ghost reads clearly) and yields first. Rule of thumb: ambient context yields to active decisions.

8. **No persistent legend.** A permanent color key would raise HUD density and fight Pillar 2. Instead: (a) the toggle button shows a small legend popover **on hover only**; (b) a **one-time contextual tip** the first time the player toggles the overlay on in a session, auto-dismissing after ~4 s or on next click, never shown again. Primary legibility comes from the shape channel itself (outline-to-filled glyphs are self-explanatory like a battery icon).

### States and Transitions

| Element | From | Event | To |
|---|---|---|---|
| Heatmap | Hidden (default) | `toggle_flow_overlay` (H / HUD button) | Visible (tween fade-in); first-ever toggle also shows one-time tip |
| Heatmap | Visible | placement drag begins | Dimmed (≤20% opacity, tween) |
| Heatmap | Dimmed | drag ends | Restored to prior opacity |
| Heatmap | Visible | `toggle_flow_overlay` | Hidden (tween fade-out) |
| Access-blocked icon | Absent | scene load / save load — reads current `access_reachable` set, shows icon for every `false` entry **immediately (default-visible, no event gate)** | Visible (static) |
| Access-blocked icon | Visible | `access_reachable` → true, or equipment removed | Removed |
| Rejection tooltip | Hidden | cursor holds ≥400 ms over invalid cell during drag | Shown (bucket message) |
| Rejection tooltip | Shown | cursor moves to valid cell / drag ends | Hidden |

### Interactions with Other Systems

- **Upstream dependencies (hard)**:
  - **Congestion (#7)**: `per_cell_density` field, per-equipment congestion scalar, `access_reachable` flags, and the `congestion_updated` (10 Hz) signal.
  - **PlacementSystem (#4)**: `placement_rejected(equipment_id, anchor, rotation, fail_code)` signal; and the existing footprint-vs-access ghost tint (this system layers on top, does not replace it).
  - **GridSystem**: cell→world position mapping to anchor icons/heatmap (via the grid_world_conversion `world_to_grid`/`grid_to_world_*` methods; cell-size value pinned at architecture — this system must not hardcode it).
- **Soft dependencies**:
  - **HUD (#16)**: hosts the toggle button in its utility cluster.
  - **Settings & Accessibility (#22)**: colorblind mode, high-contrast, UI scale, and the rebindable `toggle_flow_overlay` action.
- **Downstream**: none — this is a leaf presentation system.

## Formulas

> Presentation-layer mappings; provisional MVP values to tune at the fun-validation playtest.

The **density_to_heat** color mapping is defined as:

`heat_alpha = smoothstep(low_cut, high_cut, density_cell)` ; output color = `Dusty Rose (#E0A0A0)` at `alpha = heat_alpha × heatmap_layer_opacity`

**Variables:**
| Variable | Symbol | Type | Range | Description |
|----------|--------|------|-------|-------------|
| Per-cell density | `density_cell` | float | [0,1] | From Congestion `per_cell_density` |
| Low cutoff | `low_cut` | float | 0.15–0.30 (default 0.2) | Below this, cell stays transparent (calm) |
| High cutoff | `high_cut` | float | 0.6–0.85 (default 0.8) | At/above this, full warmth |
| Layer opacity | `heatmap_layer_opacity` | float | 0–1 (default ~0.6; ≤0.2 during drag) | Global heatmap alpha |
| Output alpha | `heat_alpha` | float | [0,1] | Per-cell overlay alpha before layer opacity |

**Output Range:** `[0,1]` alpha. Below `low_cut` → invisible; above `high_cut` → full Dusty Rose. **Example:** `density_cell=0.5, low_cut=0.2, high_cut=0.8` → `smoothstep(0.2,0.8,0.5)=0.5` → at layer opacity 0.6, effective alpha `0.3` (a soft mid-warmth). During a drag (`opacity=0.2`) the same cell renders at alpha `0.1` — barely-there, so the ghost dominates.

---

The **congestion_glyph_fill** mapping is defined as:

`fill_fraction = clamp(per_equipment_congestion, 0, 1)` (the glyph's outline fills from 0 → full as this rises; Dusty Rose tint applied as secondary channel only)

**Variables:**
| Variable | Symbol | Type | Range | Description |
|----------|--------|------|-------|-------------|
| Per-equipment congestion | `per_equipment_congestion` | float | [0,1] | From Congestion (#7) |
| Glyph fill | `fill_fraction` | float | [0,1] | Fraction of the icon filled (primary, colorblind-safe channel) |

**Output Range:** `[0,1]` fill. **Example:** congestion `0.69` → glyph ~69% filled, tinted soft rose — readable as "quite busy" by fill alone, with color as reinforcement.

## Edge Cases

- **Heatmap toggled while a drag is in progress**: the toggle sets the *target* opacity; the drag-dim still overrides to ≤20% until drag end, then the toggled state (on/off) takes effect. Toggling *off* mid-drag hides it fully on drag end.
- **Multiple machines walled off at once**: each shows its own barricade icon; icons never merge or stack-count — each is anchored to its own access cell. No aggregate "N blocked" alarm (Pillar 2).
- **Equipment removed while its congestion glyph / access-blocked icon is showing**: the icon is removed the same frame the equipment is (this system subscribes to the same removal signal / rebinds to Congestion's dropped entry — never leaves an orphan icon over an empty cell).
- **`access_reachable` flickers true↔false across quick edits**: the icon fades in on false and removes on true; because reachability is event-driven (only on `grid_changed`, not per-tick), it won't strobe within a stable layout — only genuine layout edits move it.
- **Cursor sweeps fast across many invalid cells during a drag**: the 400 ms hold delay suppresses tooltip flicker; the tooltip only appears when the cursor rests.
- **Colorblind / high-contrast mode on**: every cue remains distinguishable by shape/fill/icon alone (color removed); high-contrast thickens glyph outlines and raises heatmap-to-floor contrast.
- **Camera zoom changes**: access-blocked and congestion glyphs render at fixed UI scale (do not shrink with zoom); the heatmap scales with the world grid.
- **No members / empty gym**: density is ~0 everywhere → heatmap renders fully transparent even when toggled on (nothing to show, calmly).

## Dependencies

**Upstream (hard)**:

| System | Interface | Nature |
|---|---|---|
| Congestion (#7) | `per_cell_density`, per-equipment congestion, `access_reachable`, `congestion_updated` (10 Hz) | Hard |
| PlacementSystem (#4) | `placement_rejected(equipment_id, anchor, rotation, fail_code)`; footprint/access ghost tint | Hard |
| GridSystem | cell→world mapping (`grid_world_conversion` methods) | Hard |

**Soft**: HUD (#16, toggle button host); Settings & Accessibility (#22, colorblind/high-contrast/UI-scale/rebind).

**Downstream**: none (leaf presentation system).

**Bidirectional consistency note**: Congestion's GDD lists this overlay as the consumer of all three outputs and names the default-visible `access_reachable` requirement (its OQ1); PlacementSystem's GDD defers reason-specific rejection feedback to this system (its OQ2). Both handoffs are caught here. Verify at `/consistency-check`.

## Tuning Knobs

| Knob | Default | Safe Range | Too Low | Too High |
|---|---|---|---|---|
| `heatmap_layer_opacity` | 0.6 | 0.3–0.8 | Heatmap too faint to read | Too heavy, fights the cozy floor |
| `drag_dim_opacity` | 0.2 | 0.1–0.3 | Heatmap invisible during drag (fine) | Competes with the ghost |
| `low_cut` / `high_cut` (smoothstep) | 0.2 / 0.8 | 0.15–0.30 / 0.6–0.85 | Heatmap shows noise/low traffic (anxious) | Only extreme crowds show (misses mild bottlenecks) |
| `rejection_tooltip_hold_ms` | 400 | 250–600 | Tooltip flickers while sweeping | Feels unresponsive |
| `onetime_tip_duration_s` | 4 | 3–6 | Player misses it | Lingers annoyingly |
| `toggle_flow_overlay` binding | `H` | rebindable | — | — |
| heatmap default state | OFF | {ON, OFF} | — | ON at boot reads as "something's wrong" (Pillar 2) |

## Visual/Audio Requirements

Fully specified above (this system *is* the visual layer). Summary of art-bible compliance: soft Dusty Rose (`#E0A0A0`) for congestion, never harsh red or flashing; Soft Charcoal outlines; shape-first glyphs backing every color cue (colorblind safety for the Sage↔Dusty Rose confusable pair); soft bilinear heatmap as a deliberate, isolated exception to the global Nearest filter; one-time fade-ins, never loops/pulses. **Audio**: no rejection/failure sound (Pillar 2). A soft, optional confirmation tick on successful placement may be specified by audio-director later (not owned here).

> 📌 **Asset Spec** — Visual requirements are defined (heatmap shader, congestion glyph states, barricade icon, tooltip styling). After the art bible is finalized, run `/asset-spec system:congestion-flow-overlay` to produce per-asset visual descriptions, dimensions, and generation prompts.

## UI Requirements

Fully specified above: the `toggle_flow_overlay` control (H key + HUD utility-cluster button), the hover legend popover, the one-time contextual tip, the cursor-adjacent rejection tooltip (2 buckets), and the hover tooltip on the access-blocked icon.

> 📌 **UX Flag** — This system has real UI. In Pre-Production, run `/ux-design` to produce a UX spec for the overlay HUD control and the tooltip/legend components before writing epics; stories should cite `design/ux/[screen].md`, not this GDD directly.

## Acceptance Criteria

> This is a **Visual/UI** story — evidence is primarily **ADVISORY** (screenshot + lead sign-off / manual walkthrough in `production/qa/evidence/`). The data-binding items (AC9–AC12) are testable **logic** and should have automated coverage where practical.

**UI / Visual (manual walkthrough — ADVISORY):**
1. **GIVEN** a fresh game boot, **WHEN** the main scene loads, **THEN** the heatmap is OFF and no legend is on-screen.
2. **GIVEN** the heatmap is off, **WHEN** an equipment's `access_reachable` becomes false, **THEN** its barricade icon appears regardless of toggle state.
3. **GIVEN** a placement drag begins, **WHEN** the heatmap was on, **THEN** it tweens to ≤20% opacity within one drag-frame and restores on drag end.
4. **GIVEN** a rejected drop with a footprint-bucket fail code, **WHEN** the cursor holds 400 ms, **THEN** the tooltip reads "Won't fit here," never a raw fail-code string.
5. **GIVEN** a rejected drop with an access-bucket fail code, **WHEN** the cursor holds 400 ms, **THEN** the tooltip reads "Blocks the path in."
6. **GIVEN** colorblind/high-contrast mode is enabled, **WHEN** congestion or access-blocked states render, **THEN** each is distinguishable by shape/icon alone with color removed.
7. **GIVEN** the player toggles the heatmap on for the first time in a session, **WHEN** it activates, **THEN** a one-time contextual tip appears and never recurs after dismissal.
8. **GIVEN** any state in this system renders, **WHEN** observed over 10 seconds, **THEN** no element flashes, pulses on a loop, or plays a failure sound.

**Data-binding (automated where practical — testable logic):**
9. **GIVEN** Congestion emits `congestion_updated` with a known `per_cell_density` field, **WHEN** the overlay refreshes, **THEN** the heatmap `Image` texels match the field (per-cell), and no refresh occurs on frames without the signal (10 Hz cadence, not per-frame).
10. **GIVEN** an equipment's `per_equipment_congestion` value, **WHEN** its glyph updates, **THEN** `fill_fraction` equals that value (clamped `[0,1]`).
11. **GIVEN** an equipment is removed, **WHEN** the removal is processed, **THEN** its congestion glyph and any barricade icon are removed the same frame (no orphan icon over an empty cell).
12. **GIVEN** `access_reachable` for equipment E is false, **WHEN** the heatmap toggle is OFF, **THEN** E's barricade icon is still visible (the always-on layer is independent of the toggle).

## Pinned Engine Caveats — Godot 4.7.1 (verified during vertical slice)

- **`class_name` not globally registered under headless load** → reference cross-script
  classes via `preload` const aliases (e.g. `const CongScript := preload("res://...")`).
- **`class_name` must follow `extends` immediately** (not after const/var).
- **Rendering API specifics (4.7.1):**
  - `CanvasItem.draw_string(font, position, text, alignment, width, font_size, color, ...)` —
    the FIRST argument is `Font` (use `ThemeDB.fallback_font`, guard `!= null` under headless);
    `font_size` precedes `color`. Any overlay text — the rejection tooltip (Core Rule 6),
    per-equipment glyph labels, the access-blocked hover text — must use this exact signature.
  - Core Rule 2's `ImageTexture` + shader approach is correct for 4.7.1 (avoid `DrawableTexture2D`
    per OQ1). `ImageTexture.update()` is the correct refresh call (Core Rule 3's 10 Hz cadence).
  - `draw_rect` / `draw_circle` / `draw_line` work as documented; pass `Rect2i` / `Vector2` / `Color`.
- **`var x := expr` fails inference on Variant returns** → explicit `: Type` for any local reading
  Congestion/GridSystem state (e.g. `var d: float = _cong.get_density(c)`).
- **Lambda closures do NOT write back outer-scope locals** → use a `RefCounted` counter for any
  signal-driven overlay-update counting in tests.

Full list: skill `godot-4x-gdscript-pitfalls`.

## Open Questions

| # | Question | Owner | Target Resolution |
|---|---|---|---|
| OQ1 | `DrawableTexture2D` (4.7 new) is deferred as a future optimization only. If ever adopted (e.g. a higher-res flow-field effect), verify against the **local 4.7.1** editor: exact class/API surface, `CanvasItem` draw compatibility, and whether it needs `RenderingDevice` (compatibility-renderer support). MVP uses `ImageTexture`+shader. | Implementing programmer (technical-artist) | Post-MVP, only if revisited |
| OQ2 | technical-artist recommends an **ADR** for this rendering-architecture decision (per the coding standard "every system needs an ADR"). Belongs at `/create-architecture`, not now. | technical-director / `/create-architecture` | Architecture phase |
| OQ3 | The heatmap smoothstep cutoffs (`low_cut`/`high_cut`) and `heatmap_layer_opacity` are the visual "does crowding read clearly?" dials — tune at the fun-validation playtest alongside Congestion's `α`/`w_occ`/`w_dense`. | game-designer / art-director, post-playtest | At the order-8 milestone |
| OQ4 | The one-time contextual tip and hover legend copy need final wording (localization-ready). Minor; can be drafted during `/ux-design`. | writer / ux-designer | Pre-Production `/ux-design` |