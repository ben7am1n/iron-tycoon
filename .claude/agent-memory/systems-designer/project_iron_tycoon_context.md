---
name: project-iron-tycoon-context
description: Locked technical/design context for 撸铁大亨 (Iron Tycoon) gym-sim MVP — tick rate, grid size, access-cell model, fun-validation milestone.
metadata:
  type: project
---

撸铁大亨 (Iron Tycoon) is a cozy top-down gym-management sim (Godot 4.7.1,
GDScript). Key locked constants relevant to any gameplay-formula work in this
project:

- `TICKS_PER_SECOND = 10` (TICK_DURATION_SECONDS = 0.1s), locked in
  `design/gdd/time-system.md`. All duration-type formulas should be expressed
  in ticks, convertible from seconds via this constant.
- Grid is 13×10 bounding box (~110–115 actually-buildable cells after walls/
  pillars eat ~10-15%) — see `grid_width`/`grid_height` in
  `design/registry/entities.yaml`. Provisional MVP value, not final.
- `access_cell_count_max = 1` (registry constant, source
  `equipment-catalog.md`) — **every placed equipment instance supports
  exactly 1 concurrent user** (single-server queue per instance, MVP-locked,
  not currently a tuning knob). This matters for any queueing/congestion
  formula: congestion at an instance is fundamentally a 1-server queue, and
  players relieve congestion by placing *more instances* of a popular type —
  this is the intended lever for Pillar 1 "space is the mechanic."
- Navigation (`design/gdd/navigation.md`) is deterministic AStarGrid2D,
  **congestion-blind** — it returns geometric shortest paths only.
  Congestion-aware behavior must live entirely in MemberSim's *target
  selection*, never in the path layer.
- **Fun-validation milestone**: systems-index.md design order stops at step 8
  (Congestion/Flow Overlay) to prototype+playtest "is tuning layout for flow
  fun?" before Economy/meta systems are designed. MemberSim (step 6) and
  Congestion (step 7) are the numeric heart of that hypothesis test.
- Pillar 2 ("松弛不紧绷" / calm, no failure state) is a hard constraint on
  any gameplay formula in this project: no punishment states, no fail states,
  give-up/abandon behaviors must read as calm and neutral.

See also [[membersim_congestion_interface_contract]].
