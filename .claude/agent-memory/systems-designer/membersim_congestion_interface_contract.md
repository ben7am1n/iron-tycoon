---
name: membersim-congestion-interface-contract
description: Speculative interface contract between MemberSim's target-selection formula and the not-yet-designed Congestion GDD (#7) — must be reconfirmed when Congestion is authored.
metadata:
  type: project
---

When designing MemberSim + MemberActivity/usage (`design/gdd/` — not yet
written as of 2026-07-18), I proposed that `target_selection_weight` consumes
`Congestion_i(t-1)` as a **normalized scalar in [0,1] per equipment
instance** (0 = free/uncongested, 1 = maximally congested), read with the
project's locked one-tick lag (`design/gdd/systems-index.md`: "Congestion
↔ Routing" resolved via `Congestion(t-1) → target/route selection(t)`).

**Why this is provisional:** Congestion (#7) is designed *after* MemberSim
(#6) in the systems-index design order, so MemberSim's GDD can only state
this as an assumed interface, not a confirmed contract. MemberSim does not
define Congestion's own formula (per-equipment density/queue measure) — only
how its *output* is weighted into member target-selection.

**How to apply:** When Congestion (#7) is actually designed, re-check that
its output range and per-entity granularity (per-equipment-instance vs.
per-cell) match this assumption. If Congestion turns out to be per-cell
rather than per-equipment-instance, or unbounded rather than normalized,
`target_selection_weight`'s `congestion_factor_i = exp(-k_congestion ×
Congestion_i(t-1))` must be revisited — the `k_congestion` tuning range I
proposed (2–5) is calibrated assuming a [0,1] input.

Related: [[project_iron_tycoon_context]].
