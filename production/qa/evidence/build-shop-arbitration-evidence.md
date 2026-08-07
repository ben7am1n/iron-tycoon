# QA Evidence — BSUI-003: Build/Select Mode Arbitration

> **Story**: production/epics/build-shop-ui/story-003-build-select-mode-arbitration.md
> **Epic**: build-shop-ui (Presentation layer)
> **Date**: 2026-08-07
> **Engine**: Godot 4.7.1 (headless-verified)
> **Story Type**: Integration — evidence BLOCKING (automated coverage required)

## Summary

Build mode and select mode are now mutually exclusive (TR-BSUI-004, GDD Core
Rule 4, ADR-0005 S7). A new presentation-layer arbiter
(`src/ui/mode_arbitration.gd`, `class_name ModeArbitration extends RefCounted`)
subscribes to `SelectionSystem.selection_changed` with a typed signal
connection and owns the SELECTION side of the no-dual-ghost guarantee:

- selection active (`selection_changed` non-null) → the new-placement
  ghost/preview is suppressed (`is_ghost_suppressed()` — the query Story 004's
  ghost renderer consumes); palette stays visible and full-tint;
- `selection_changed(null)` → ghost allowed again immediately (synchronous
  handler — no await between deselect and re-allow);
- palette mouse-down while a piece is selected → `begin_build()` clears the
  selection FIRST (via the new `SelectionSystem.clear_selection()`), then the
  drag proceeds — no dual ghost; a FAILED purchase gate leaves the selection
  unchanged.

The OTHER suppression direction — build drag active → selection suppressed —
is SelectionSystem's own SEL-001 AC12 (clicks don't resolve during a drag) and
is verified end-to-end here, not reimplemented. The two directions together
guarantee exactly one spatial mode visually active at a time (Pillar 3).

| File | Class | Role |
|------|-------|------|
| `src/ui/mode_arbitration.gd` | `ModeArbitration extends RefCounted` | Selection-state tracker + ghost-suppression query + `begin_build()` build-take-over handoff (typed `selection_changed` connection, 1..4 optional-param consumer contract, explicit `!= null` — 0 is a legal instance) |
| `src/systems/selection_system.gd` | `SelectionSystem` | Grows one public method: `clear_selection()` — the programmatic deselect entry (semantically identical to `on_esc_pressed()`, no key-event connotation) the arbitration's build-take-over calls |
| `src/ui/build_shop_palette.gd` | `BuildShopPalette` | Optional 5th init param `arbitration` (backward-compatible); `on_tile_mouse_down` calls `begin_build()` AFTER the purchase gate passes and BEFORE `begin_drag` (ordering keeps a failed gate from touching the selection) |

Automated coverage: `tests/integration/build_shop_ui/mode_arbitration_test.gd`
— **53 asserts, 0 failed** (registered in `tests/headless_runner.gd`
TEST_FILES).

Full suite: **4089 passed, 0 failed** (4036 pre-existing + 53 new).

## Blocking AC Verification

### AC6 — 选中时抑制幽灵 (selection suppresses the ghost)

- ✅ Automated: place a piece, click it → `selection_changed` select emission
  fires once; `ModeArbitration.is_selection_active()` true;
  `is_ghost_suppressed()` true — the new-placement ghost is suppressed (no
  dual ghost).
- ✅ Automated: while selected, the palette is still VISIBLE and full-tint
  (only a drag dims it — the drag dim is the one-drag invariant's visual, not
  a selection effect).
- ✅ Automated edge (mid-hover restore): selection cleared via
  `clear_selection()` → ghost allowed again IMMEDIATELY (synchronous);
  selection cleared via click-empty-buildable-floor (the AC2 deselect path) →
  ghost allowed again immediately too.

### Core Rule 4 — 拖拽接管 (build takes over)

- ✅ Automated: piece selected → palette mouse-down on an affordable item →
  `on_tile_mouse_down` returns true; `get_selected_instance_id()` == -1
  (selection cleared FIRST); exactly ONE `selection_changed(null)` emitted by
  the takeover; `PlacementSystem.is_dragging()` true; arbitration sees idle →
  `is_ghost_suppressed()` false during the new drag — **no dual ghost**.
- ✅ Automated edge: `can_purchase` false (unaffordable after spending down the
  balance) → no drag, selection UNCHANGED, ghost still suppressed, zero
  selection signals. Locked item → same. The failed gate never lets build
  take over.

### Idle — 正常渲染 (ghost renders normally)

- ✅ Automated: no selection → palette mouse-down → drag begins,
  `is_ghost_suppressed()` false throughout; full flow (drag → move → drop)
  commits the placement with the ghost never suppressed.

### Pillar 3 — 无双 ghost (both suppression directions)

- ✅ Automated: build drag active → click on a placed piece's cell does NOT
  resolve a selection (SEL-001 AC12) — no selection signal, selection stays
  clear, drag undisturbed. This is the other half of the mutual-exclusion
  guarantee, verified end-to-end through the real systems.
- ✅ Automated edge: a `selection_changed` emit arriving MID-drag (direct emit
  — unreachable via real input because AC12 suppresses clicks during a drag,
  tested as a pure consumer-robustness check) → `is_ghost_suppressed()` flips
  true ON THE FLY, and back to false on the deselect emit.

## Guardrails

- ✅ Control Manifest: typed signal connection only
  (`selection_changed.connect(_on_selection_changed)`); no string-based
  connects.
- ✅ Use-before-init guard on ModeArbitration public methods (push_error +
  safe default, never assert).
- ✅ `init()` twice on ModeArbitration → logged error, no crash, still
  functional.
- ✅ Signal consumer contract honored: handler declares 1..4 optional params
  (GDScript dispatches exactly the emitted count — the spy proves a 1-arg
  deselect emit vs a 4-arg select emit); explicit `!= null` comparison, never
  truthiness (0 is a legal selected instance).
- ✅ Story-001/002 compatibility: palette init signature backward-compatible
  (optional 5th param); existing palette_state_test (72) and
  purchase_gate_test (86) pass unchanged.

## Files Changed

- `src/ui/mode_arbitration.gd` (new — `ModeArbitration extends RefCounted`)
- `src/systems/selection_system.gd` (add `clear_selection()` public deselect)
- `src/ui/build_shop_palette.gd` (5th init param, build-take-over in
  `on_tile_mouse_down`)
- `tests/integration/build_shop_ui/mode_arbitration_test.gd` (new, 53 asserts)
- `tests/headless_runner.gd` (register new test)
- `.godot/global_script_class_cache.cfg` (register `ModeArbitration` class_name)

## Known Gaps / Future Work

- Story 004 consumes `is_ghost_suppressed()` for the actual ghost renderer
  (the drag ghost visuals do not exist yet — PlacementSystem's
  `preview_validity_changed` is the signal the ghost will follow).
- The palette's build-take-over runs only through `on_tile_mouse_down`; the
  UX spec's keyboard-drag path (Tab/Enter) will route through the same gate
  when it lands (per UX OQ3, MVP leans implicit — no explicit mode toggle).

---

## Independent QA Verification (2026-08-07, qa-tester, t_36ee7a0e)

QA worktree `wt/t_36ee7a0e`; verification against the merged state
(`f3755d8`, BSUI-003 on main) and then the integrated current-main tip.

| Check | Result |
|-------|--------|
| Full headless suite `tests/headless_runner.gd` (merged state `f3755d8` + SEL-001 QA `bb9b372`) | **4089 passed / 0 failed**, RESULT: PASSED, exit 0, 0 SCRIPT ERROR |
| Baseline delta | 4036 pre-existing + **53 new exactly**, zero regressions |
| `mode_arbitration_test.gd` standalone | **53 passed / 0 failed**, exit 0 |
| Assert count audit | 53 `_check` calls verified against test file: AC6 13 / Core Rule 4 18 / Idle 8 / Pillar 3 10 / Guards 4 |
| Post-integration re-run (current main tip `ba416a2`, incl. HUD-003) | **4374 passed / 0 failed**, RESULT: PASSED, exit 0, 0 SCRIPT ERROR — arbitration 53/0 still green |
| Leak picture | 218 ObjectDB instances at exit — identical to established baseline, no new leaks |
| TR-BSUI-004 registry | `docs/architecture/tr-registry.yaml` — active, requirement matches GDD Core Rule 4 |
| Control Manifest | typed `selection_changed.connect(_on_selection_changed)` only; use-before-init push_error guards (never assert) |

Verdict: **PASS** — all BLOCKING 验收 items (AC6 / Core Rule 4 build-take-over /
Core Rule 4 idle) verified by code review + independent re-run. Story 003
marked Complete with QA 终审 PASS (t_36ee7a0e).
