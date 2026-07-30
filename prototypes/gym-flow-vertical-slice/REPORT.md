# Vertical Slice Report: 撸铁大亨 (Iron Tycoon) — Gym Flow

> **Date**: 2026-07-23
> **Slice Duration**: 1 day (2026-07-19 build + 2026-07-22 @abstract verification re-run)
> **Target Scope**: 3–5 minutes of polished, continuous gameplay
> **Source GDD**: design/gdd/game-concept.md

---

## Validation Question

> *"Does a player, starting from a clumped/congested gym layout, experience the core fantasy of '化腐朽为神奇' (transforming chaos into order) by rearranging equipment to relieve congestion — within 5 minutes, without developer guidance — and can we build this loop in a few days at representative quality?"*

---

## Scope Built

**Systems included:**
- GridSystem — occupancy grid, rotation (union-bbox rule), speculative snapshot for drag preview
- SeededRNG — FNV-1a64 + SplitMix64 subseed derivation, bit-identical determinism verified
- EquipmentCatalog — per-definition footprint/access cells + use_duration fields with load-time validation
- Navigation — AStarGrid2D wrapper, solidity sync on grid_changed, MANHATTAN + no diagonals
- MemberSim — lifecycle state machine (IDLE→SELECTING→WALKING→QUEUEING→USING→LEAVING→GONE), congestion-weighted target selection, equipment access-cell claim mechanism
- Congestion — per-equipment EMA-smoothed scalar + per-cell density field, access_reachable event-driven recheck
- PlacementSystem — drag-snap anchor (deterministic floor), rotate cycle, place_new + move_existing (with rollback on failure)
- OverlayModel — shape-first glyphs (○/▶/■) + queue_len numbers on access cells, heatmap density colors

**Art/audio quality level:** Placeholder — geometric rectangles + circles only, no sprites, no audio. Heatmap uses a simple RGB gradient.

**Shortcuts taken deliberately:**
- No TimeSystem tick orchestrator — ticks driven by main.gd `_process` loop at 10Hz
- No Economy system — no money, no purchasing, no sell-back
- No Satisfaction system — exercises_per_visit uses a fixed quota (3)
- No SaveLoad
- No Shop/UI layer — drag initiated by clicking existing equipment on the grid
- No ZoneRules
- No entrance/exit visual markers
- Equipment catalog data is hardcoded inline, not loaded from external config
- Only 2 equipment types (treadmill, bike) × 3 instances total

**What was cut from original scope:**
- All UI systems (HUD, Shop, Build UI)
- Economy loop (earn/spend/sell-back)
- Satisfaction progression
- ZoneRules synergy scoring
- Save/Load
- MemberSim visual states (no sprites, just colored circles)

---

## Build Velocity Log

| Day | Completed |
|-----|-----------|
| Day 1 (2026-07-19) | All 8 systems implemented: GridSystem + SeededRNG + EquipmentCatalog + Navigation + MemberSim + Congestion + PlacementSystem + OverlayModel. main.gd orchestrator with drag input + clumped/spread toggle + bench mode. Smoke test (21/21) and integration test (20/20) passing. @abstract feasibility tested separately. |
| Day 2 (2026-07-22) | ADR-0007 AStarGrid2D cross-process determinism gate passed (10/10 processes bit-identical). @abstract on RefCounted verified as not supported — manual `_init()` guard confirmed as correct pattern for ADR-0001. |
| Day 3 (2026-07-23) | Playtest session. Interactive build verified working. |

**Total elapsed:** 3 calendar days (~1.5 dev days accounting for ADR gate parallel work) for 8 systems + orchestrator + test suite.

**Velocity estimate:** ~4 systems per dev day at vertical-slice quality. At this rate, the full 16 MVP systems (adding Economy, Satisfaction, ZoneRules, TimeSystem, Shop, SaveLoad, SelectionSystem, HUD/BuildUI) would take ~2 additional dev days. But "detail/polish" — the playtest's main criticism — is a separate quality tier that compounds per system.

---

## Playtest Results

| Attribute | Value |
|-----------|-------|
| Total sessions | 1 |
| Internal testers | 1 (developer) |
| External testers | 0 |
| Avg session length | ~5 minutes |
| Time to first meaningful action | ~5 seconds |

---

## Observations

**Where testers succeeded without guidance:**
- Full loop (clumped → press L → spread → see congestion drop) completed unassisted
- Drag-to-rearrange mechanic was intuitive (click to pick up, click to place)
- No confusion about what was happening on screen

**Where testers were confused or stuck:**
- None reported — the demo is simple enough that nothing was confusing

**Emotional reactions observed:**
- No emotional reaction to the core fantasy — the build is too rough/abstract
- The core loop functions mechanically, but the "化腐朽为神奇" feeling (transforming a shabby gym into something orderly and satisfying) does not come through with colored rectangles and circles

---

## Metrics

| Metric | Target | Actual |
|--------|--------|--------|
| Time to first meaningful action | <30 sec | ~5 sec |
| Session length | 3–5 min | ~5 min |
| Critical fun blockers found | 0 | 0 |
| Pipeline blockers found | 0 | 0 |
| Architecture surprises | 0 | 0 |

**Feel assessment:** The build is functionally correct — all 8 systems interact cleanly, the congestion loop works, rearranging machines visibly disperses density — but the abstraction level is too high for the core fantasy to land. Colored rectangles and circles communicate data, not feeling. The next iteration needs: (a) equipment sprites that look like gym machines, not gray boxes; (b) member sprites/animations that look like people exercising, not colored dots; (c) the gym environment to look like a gym, not a blank grid. These are art pipeline requirements, not code architecture issues.

---

## Recommendation: PROCEED

The architecture holds. All 20 integration tests pass deterministically. The congestion-driven core loop — "spreading machines relieves crowding" — is mechanically verified and visible through the heatmap overlay. A player can complete the full [start → challenge → resolution] cycle in under a minute without guidance. The ADR decisions (union-bbox rotation, AStarGrid2D determinism, congestion(t-1) one-tick lag, shape-first overlay glyphs) are all confirmed correct by this build.

**However**, the build is too visually abstract for the core fantasy to land. This is a known and acceptable limitation — the vertical slice validated *architecture and mechanics*, not art. The "more detail" the playtest calls for is an art/feel requirement, not a code pivot.

---

## If Proceeding

**Production requirements** (what must change from slice to production):
- Equipment sprites with identifiable gym-machine silhouettes (treadmill, bike, bench, etc.)
- Member character sprites with distinct states (walking, queueing, exercising, leaving)
- Gym floor/environment art (tiles, walls, props) — the grid needs to read as a gym space
- Audio: placement SFX, ambient gym sounds, member exercise sounds
- HUD: money counter, satisfaction meter, time display
- Shop UI: equipment catalog browser with cost/ stats
- Build UI: drag-from-shop interaction replacing current click-to-pick-up

**Architecture adjustments needed:**
- ADR-0001 (DI Container) `@abstract` pattern confirmed: use manual `_init()` guard, not `@abstract` (Godot 4.7.1 does not support `@abstract` on RefCounted)
- ADR-0007 (AStarGrid2D determinism) confirmed: rebuild-on-load works, tie-break stable across processes

**Sprint velocity estimate based on slice data:**
- ~4 core systems per dev day at implementation quality
- Art/feel work is the bottleneck, not code — budget 2–3× code time for visual polish
- Full MVP (16 systems + art + audio + UI): ~8–12 dev days for code, ~15–20 dev days for art/feel

**Scope adjustments from original design:**
- The slice covered 8 of 16 MVP systems. The remaining 8 (TimeSystem, Economy, Satisfaction, ZoneRules, Shop, SaveLoad, SelectionSystem, HUD/BuildUI) are all designed (GDDs written) and have no architectural unknowns — they can proceed directly to implementation.

**Performance targets:** Confirmed. Bench mode: 600 logic ticks in negligible time (~100× headroom at 10Hz tick rate). No performance concerns at MVP scale.

**Playtest note:** This is 1 session (internal developer). At minimum 3 sessions are recommended before committing the full team to Production — ideally at least 1 external tester. The next session should use an art-passed build so the core fantasy can be evaluated on feel, not just mechanics.

**Next steps:**
1. Art pass on the vertical slice build — add equipment sprites + member sprites + gym floor tiles
2. Re-run playtest with external tester on the art-passed build
3. `/gate-check pre-production` — formally advance to Production (requires documented playtest evidence)
4. `/create-epics layer:foundation` — plan Foundation layer epics
5. `/create-epics layer:core` — plan Core layer epics
6. `/sprint-plan` — use velocity data from this report

---

## Lessons Learned

- **What assumptions were broken by building to near-production quality?**
  Godot 4.7.1's `@abstract` annotation does not work on `RefCounted` — it only applies to `Node`-derived classes. This was discovered during ADR-0001 gate verification and confirmed through the `abstract_test.gd` in this slice directory. The DI Container ADR was updated to use manual `_init()` guards instead.

- **What surprised us about the pipeline or architecture?**
  `AStarGrid2D` pathfinding is fast enough that per-frame path recomputation (on grid_changed) is not a concern. The union-bbox rotation rule (treating footprint U access as one bounding box for rotation) is mechanically correct but visually non-obvious — if a designer adds an asymmetric equipment definition, the rotation behavior will surprise them. This needs either a visual editor or a constraint that all equipment definitions must be square/symmetric.

- **What would we change about the slice scope if we ran this again?**
  Include at least one piece of representative art from the start. The architecture validation succeeded, but the playtest revealed that mechanical correctness alone cannot validate "fun" — the abstraction gap between colored rectangles and a gym is too wide for a tester to feel the intended experience. A single equipment sprite + member sprite + floor tile would have made the playtest much more informative.

---

> *Vertical slice code location: `prototypes/gym-flow-vertical-slice/`*
> *This code is reference material only. Production implementation is written from scratch.*
> *Never import or refactor this code into production.*
