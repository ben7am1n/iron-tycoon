# Concept Prototype Report: 撸铁大亨 (Iron Tycoon) — Core Loop

> **Date**: 2026-07-18
> **Prototype Path**: HTML
> **Concept File**: design/gdd/game-concept.md
> **Prototype**: `prototypes/gym-flow-concept/prototype.html`

---

## Hypothesis

If the player drags equipment around a grid and watches pixel members pathfind to it,
they will feel that *improving the layout for flow* is satisfying on its own — evidenced
by the player spontaneously rearranging equipment to clear a visible bottleneck, the
congestion heatmap visibly responding, and the "just move one more thing" itch.

---

## Riskiest Assumption Tested

The riskiest assumption (the #1 design risk in the concept doc — "空间优化的深度 vs 松弛感的
平衡，只能靠原型验证") was: **can a layout change causally and legibly change member flow, and
is watching that change satisfying enough to be the core loop?**

**Result: proved out.** The single strongest playtest signal was the player saying that
**making the congestion heatmap spread out felt great** — i.e., the causal link "I rearranged
→ the crowding visibly dissolved" landed as a genuine reward, not a chore. That is exactly
the loop the whole game is built on.

---

## Approach

A single self-contained `prototype.html` (Canvas + vanilla JS), built and verified in one
session. It simplifies design orders #1–#8 into one playable loop: a 14×10 walled room with
a left doorway; a palette to place/rotate/move three equipment types (each with a multi-cell
footprint + one access cell); members that spawn, choose a machine weighted against
`Congestion(t-1)` (avoiding crowds), pathfind (8-directional BFS, no corner-cutting), queue,
use, and leave; a per-cell congestion **heatmap** (toggle) and per-equipment congestion bars;
and an "unreachable" ⛔ marker for machines walled off by the player. It opens with **three
machines clumped in the corner** so the bottleneck is visible immediately.

**Path chosen:** HTML
**Reason for path:** The core loop is *not* timing-sensitive (no jump arcs, no combat), so
browser latency doesn't distort the result; HTML is far higher one-shot reliability than the
engine path and runnable/inspectable immediately. Throwaway code is never refactored into
production, so JS vs GDScript is irrelevant here.

**Shortcuts taken (intentional):**
- No determinism / seeded RNG — used `Math.random()` (the real game needs seeded RNG for saves; not relevant to the fun question).
- BFS instead of AStarGrid2D; congestion/target-selection formulas approximated, not the GDD's exact EMA/softmax.
- Placeholder art (colored rects + dots), no animation interpolation of member facing, no sound, no economy/satisfaction/save, no menus.
- Click-to-place rather than hold-drag — so drag-snap *hand-feel* (a Sensation-tier aesthetic) was **not** tested here; only the arrangement→flow loop was.

---

## Result

The player played the live build and reported:

- Overall: **"感觉不错"** (feels good).
- Best moment: **"让热力图散开感觉很爽"** — spreading the machines apart and watching the
  congestion heatmap thin/disperse was the standout satisfying moment.
- Worst / friction moment: **"看不清谁在排队"** — could not tell at a glance which members
  were queuing versus walking or using.

Observed sim behavior during play matched design intent: with the machines clumped, members
piled up (heatmap a solid Dusty Rose blob, 6 queuing, per-equipment congestion pinned near
1.0); the levers to relieve it (spread machines apart to reduce density interference; add
machines to add capacity) both worked and were discoverable.

---

## Metrics

| Metric | Value |
|--------|-------|
| Path used | HTML |
| Iterations to playable | N/A (HTML one-shot; 1 balance tuning pass: member count 14→10, congestion weighting) |
| Prototype duration | ~1 session |
| Playtesters | 1 internal |
| Feel assessment | Rearranging → heatmap dissipation is genuinely satisfying ("很爽"); **queue/member-state legibility is poor** — states shown by dot color only, indistinguishable at a glance |
| Hypothesis verdict | **CONFIRMED** (core satisfaction landed; one readability refinement surfaced) |

---

## Recommendation: PROCEED

The core hypothesis held: the player found rearranging-for-flow satisfying *on its own*,
and named the exact intended reward moment (the heatmap dissolving as machines spread). That
is the loop the whole game rests on, and it works even with placeholder rects and dots. The
one clear friction — "看不清谁在排队" — is not a hole in the concept; it is a **readability**
issue, and notably it *validates a decision already made in the GDDs*: Overlay #8 specifies
that member/congestion states must be shown **shape-first (icon + fill), never color alone**.
The prototype used color-only dots and failed exactly where #8 predicted, which is strong
confirmation that #8's shape-first rule is load-bearing, not optional polish. Proceed —
folding these learnings into the existing GDDs.

---

## If Proceeding

**Note:** This project is unusual — it already has GDDs #1–#8 written *before* this
prototype (the systems index deliberately front-loaded a fun-validation milestone at order 8).
So "proceeding" means **feeding these learnings back into the existing GDDs' Tuning Knobs and
Visual sections**, not writing them from scratch.

- **Core tuning values discovered:**
  - Member-volume-vs-capacity is the dominant balance dial. 10 members / 3 machines is
    *capacity-saturated* (congestion pins near 1.0 regardless of spacing) — confirms
    MemberSim's ⭐ knobs (`max_concurrent_members`, `base_arrival_rate`, `k_congestion`) are
    exactly the right things to tune, and that the playtest room needs enough machine capacity
    that spreading *and* adding both visibly pay off.
  - The **per-cell density heatmap is the hero feedback channel** — more legible and
    satisfying than the per-equipment congestion bars. Congestion #7's `per_cell_density`
    output and #8's soft heatmap are the priority to get right; per-equipment bars are secondary.
- **Assumptions confirmed:**
  - Pillar 1 (空间即玩法) + Pillar 3 (一眼看懂): layout change → visible flow change is legible
    and satisfying. The concept's core bet is sound.
  - Pillar 2 (松弛不紧绷): a saturated, jammed gym read as "a puzzle to fix," not stressful.
- **Assumptions to refine (not disproved):**
  - **Member-state legibility must be shape/icon, not color** — directly validates Overlay #8's
    shape-first rule and MemberSim #6's requirement that *queueing* be a distinct pose/glyph, not
    just a tint. Strengthen the ADVISORY AC in #8 and the Visual/Audio section of #6.
- **Emergent mechanics:**
  - The most compelling interaction was *spreading a clump* (density relief), slightly more than
    *adding capacity* (queue relief). Both matter, but the "spread the blob and watch it thin"
    action is the emotional core — worth centering in onboarding/tutorial (#20) and the
    fun-validation playtest protocol.

**Next steps (adapted — GDDs already exist):**
1. Fold learnings into **MemberSim #6** (Visual/Audio: distinct queueing pose) and **Overlay #8**
   (strengthen shape-first state legibility; center the heatmap-dissipation feedback) — via
   `/quick-design` or a targeted GDD edit.
2. Run the fuller fun-validation playtest per the systems-index protocol: probe room sizes to
   the A(10×8) / C(16×12) bounds, with ≥2 instances of one equipment type (MemberSim OQ6).
3. Continue the design order at **#9 ZoneRules**, or begin `/create-architecture` for #1–#8.
4. (Optional) A quick Godot engine micro-prototype targeting **drag-snap hand-feel**, which this
   HTML click-to-place build did not test.

---

## Lessons Learned

- **What assumptions were broken by actually building this?**
  That per-equipment congestion would be the main readout. In play, the **per-cell heatmap**
  carried the satisfaction; the equipment bars were nearly ignored. Prioritize the heatmap.

- **What surprised us that didn't show up in the brainstorm?**
  How quickly capacity-saturation hides the effect of *spacing*. When demand far exceeds machine
  count, congestion pins high no matter how you arrange — so the game must keep the member/capacity
  ratio in a band where arrangement visibly matters. This is a real design constraint for the
  economy/arrival tuning, surfaced only by building it.

- **What would we test differently next time?**
  Test **drag-snap hand-feel** explicitly (this build used click-to-place, so the Sensation-tier
  "satisfying snap" was untested), and put it in front of a *fresh* player who hasn't seen the
  concept, to get true first-impression legibility data on the member states.

---

> *Prototype code location: `prototypes/gym-flow-concept/`*
> *This code is throwaway. Never refactor into production.*
