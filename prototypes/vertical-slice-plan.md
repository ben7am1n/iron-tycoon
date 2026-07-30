# Vertical Slice Plan — 撸铁大亨 (Iron Tycoon) · Order-8 Core Loop

> **Drafted**: 2026-07-19 · **By**: Hermes (equivalence of `/vertical-slice` Phase 2–3, CCGS)
> **Status**: DRAFT — pending user approval before any code is written
> **Skill ref**: `.claude/skills/vertical-slice/SKILL.md` · **Review mode**: `lean` (CD-PLAYTEST skipped)

---

## 0. Why a vertical slice (not `/prototype`)

The concept prototype (`prototypes/gym-flow-concept/`, HTML, 2026-07-18) already returned
**PROCEED** — it validated the core fun hypothesis ("rearranging layout for flow is satisfying
on its own"). So order-8 is **not** a concept re-validation. With GDDs #1–#8 all Approved and
the cross-doc consistency check now PASS, the correct CCGS gate is `/vertical-slice`:
*prove the full game loop is buildable at representative quality, on schedule, before
committing to Production.* This is a pre-Production feasibility + fun-survival check, not a
throwaway fun probe.

**What the concept prototype did NOT test** (must be in this slice's acceptance):
1. **Drag-snap hand-feel** — the HTML build used click-to-place, so the Sensation-tier
   "satisfying snap" was never validated.
2. **Shape-first member-state legibility** — the HTML build used color-only dots and failed
   exactly where Overlay #8 predicted ("看不清谁在排队"). This slice must prove the
   shape-first rule (icon+fill, never color alone) works.

---

## 1. Validation Question (falsifiable)

> **Does a player, starting from a pre-placed gym, experience the core fantasy — *"I laid out
> this space and now pixel members flow through it smoothly, and when I rearrange a machine the
> crowding visibly dissolves"* — within 3–5 minutes, without developer guidance; AND can we
> build one such loop in 1–3 weeks at representative (near-production) quality using the
> approved GDDs + Godot 4.7.1 + GUT?**

Two parts, both must hold: **player experience** AND **build feasibility / velocity**.

---

## 2. Scope

### 2.1 Systems in scope (the order-8 closed loop — all Approved)

| # | System | Role in slice | Slice-specific notes |
|---|--------|---------------|----------------------|
| 1 | GridSystem | occupancy truth, `grid_changed` signal, rotation | use real `is_solid`/`commit`/`clear`; deterministic |
| 3 | TimeSystem + SeededRNG | fixed-timestep accumulator, `on_tick()` order, seeded RNG | `get_rng(name)` contract; pause/speed |
| 4 | PlacementSystem | drag-preview (speculative snapshot), rotate, drop-commit, reject reasons | **drag-snap hand-feel is a primary test** |
| 5 | Navigation (AStarGrid2D) | pathing, solidity sync on `grid_changed`, no corner-cut | real AStarGrid2D, not BFS |
| 6 | MemberSim | spawn→target→queue→use→leave lifecycle, `use_duration` from catalog | entrance/exit cells, shape-first queueing pose |
| 7 | Congestion | `per_equipment_congestion` (EMA), `per_cell_density`, `access_reachable` | one-tick lag, deterministic sum order |
| 8 | Overlay + Placement Feedback | density heatmap, per-equipment bars, **always-on access-blocked glyph**, reject feedback | **shape-first legibility is a primary test** |

### 2.2 Explicitly CUT (not in slice — keeps loop to 3–5 min, quality over scope)

- ZoneRules (#9), Satisfaction (#10), Economy (#11), Shop/Purchase (#12), SelectionSystem (#13),
  SaveLoad (#14), Build/Shop UI (#15), HUD (#16) — these are the *extended* loop (money/satisfaction/
  unlocks). The slice runs on a **fixed pre-authored catalog + a scripted member arrival rate**;
  no cash, no satisfaction meter, no save. (CCGS: "cut scope before cutting quality".)
- Equipment Info Panel (#17), Milestones (#18), Progression (#19), Onboarding (#20), Audio (#21),
  Settings/Accessibility (#22) — all VS/Tier-2.
- Art: **placeholder acceptable** (colored rects + distinct glyphs), but member states MUST be
  shape-first (icon+fill), not color-only — this is a design-rule validation, not polish.

### 2.3 The complete loop cycle (start → challenge → resolution)

```
[start]   Pre-placed gym loads (3 machines clumped in a corner, one entrance/exit).
          Members begin spawning at a fixed rate.
[play]    Player watches members pathfind → queue → use → leave.
          Congestion heatmap shows the clump as a solid blob.
[challenge] Player drags a machine to a new cell (drag-snap feedback fires);
            PlacementSystem validates via GridSystem.can_place; on success commits.
            Navigation solidity re-syncs; Congestion recomputes reachability.
[resolution] Member flow re-routes; heatmap visibly dissipates; per-equipment
            congestion bars drop. The "spread the blob → watch it thin" moment lands.
[loop]    Player spontaneously rearranges again (the core fun), or stops — no fail state.
```

### 2.4 Art / audio quality level

- Placeholder geometry (rects), but **distinct shape-first glyphs** for: walking / queuing /
  using / leaving member states, and the access-blocked barricade. Calm palette per art-bible.
- No audio required in slice (Audio #21 is VS). Optional: a single drag-snap click SFX if trivial.

### 2.5 Acceptance criteria (measurable)

| # | Criterion | Source / Why |
|---|-----------|--------------|
| A1 | Full loop demonstrable in ≤5 min by a naive player, no guidance | vertical-slice contract |
| A2 | Rearranging a machine causes a **visible, legible** heatmap dissipation within ~2 s | fun-survival (concept PROCEED core moment) |
| A3 | **Drag-snap** feels deliberate (ghost snaps to grid, clear valid/invalid tint) | fills concept gap #1 |
| A4 | Member states readable **at a glance, shape-first** (no color-only reliance) | fills concept gap #2; validates Overlay #8 |
| A5 | An access-blocked machine shows the **always-on barricade glyph at scene load** (no event gate) | GridSystem OQ#9 / Overlay Core Rule 5 trust chain |
| A6 | Deterministic: same seed + same inputs → bit-identical member states & congestion over N ticks | TimeSystem/RNG contract |
| A7 | 60 fps with ≥10 members + 3 machines on a 13×10 grid | technical-preferences perf budget |
| A8 | GUT tests cover: rotation_transform bounds, `is_solid` contract, `use_duration` clamp validity, congestion sum-order determinism | technical-preferences "Required Tests" |

### 2.6 Hard time limit

**1–3 weeks** (CCGS standard for a vertical slice). **Day-3 sunk-cost checkpoint**: if the full
loop is not demonstrable by day 3 of build, stop and surface the blocker (scope too large or an
architectural assumption wrong) rather than iterating blindly.

---

## 3. Build Plan (bullet form)

- **Week 1 — Foundation + sim**: GridSystem, TimeSystem+RNG, Navigation, then MemberSim +
  Congestion. Headless-GUT-first for the deterministic core (A6, A8). No rendering yet.
- **Week 2 — Interaction + overlay**: PlacementSystem (drag-snap, A3), Overlay #8 (heatmap +
  shape-first states + access-blocked glyph, A4/A5). Wire the full loop (A1/A2).
- **Week 3 — Polish loop + playtest**: tune arrival rate vs capacity band (concept lesson: keep
  ratio where arrangement visibly matters), run ≥1 playtest session, write velocity log, report.

**Architecture / quality standards** (per vertical-slice skill + technical-preferences):
- Follow `docs/architecture/` layering — *note: `design/architecture/` does not exist yet; the
  slice will use the GDD's stated layer boundaries (GridSystem has no TileMapLayer knowledge;
  a `GridVisualizer` adapter sits between). If an ADR is needed mid-build, flag it.*
- Naming: PascalCase classes, snake_case vars, snake_case past-tense signals (`equipment_placed`).
- No hardcoded gameplay values — constants/config (tick rate, arrival rate, capacity band).
- Basic error handling on critical paths (load validation, `can_place` rejection).
- Every file begins with the vertical-slice header comment (skill Phase 4).

**Directory**: `prototypes/gym-flow-vertical-slice/` (throwaway, never refactored into `src/`).
Tests under `prototypes/gym-flow-vertical-slice/tests/` (GUT).

---

## 4. Execution Model (decision needed from user)

CCGS's `/vertical-slice` is `isolation: worktree` + `agent: prototyper` — i.e. it spawns a
**Claude Code subagent in a git worktree** to write the multi-file GDScript. This session is
Hermes (not Claude Code), so the realistic split is:

- **Hermes (this session)**: owns the plan, the acceptance criteria, the design-rule checks
  (A4/A5 against GDDs), the playtest debrief, and the final report. Coordinates and reviews.
- **Claude Code** (`claude` CLI, confirmed present; `.claude/skills` callable as slash prompts):
  executes the actual Godot implementation in a worktree, iterating on build/run errors, under
  the acceptance criteria above.

Alternative: if you prefer Hermes to drive the implementation directly via terminal + the
`godot --headless` CLI for GUT runs, that is possible but slower for multi-file GDScript
authoring (no subagent parallelism, and the 8K-patch limit makes large `.gd` files awkward).

---

## 5. Open Questions for approval

1. **Execution model** — route implementation to Claude Code worktree (recommended), or have
   Hermes drive it directly via terminal?
2. **Slice breadth** — confirm the cut list (no Economy/Satisfaction/Save) is acceptable, or do
   you want Satisfaction/Economy included so the loop shows the satisfaction meter moving?
3. **Seed / room** — use the concept prototype's 13×10 clumped-start room, or a fresh layout?
   (systems-index notes rooms A 10×8 / C 16×12 as bounds; member-sim OQ6 wants ≥2 of one
   equipment type — both should be honored in the slice layout.)
4. **Velocity expectation** — is 1–3 weeks acceptable, or do you want a tighter 1-week
   "proof the loop builds" cut first?

---

*This is a plan document. No `project.godot`, no `.gd` files, no implementation has been created.
Approval of this plan (and the 4 open questions) precedes any code.*
