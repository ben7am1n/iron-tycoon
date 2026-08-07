# QA Evidence — SEL-002: Input Bridge Node + Keyboard Handling

> **Story**: production/epics/selection-system/story-002-input-bridge-node.md
> **Epic**: selection-system (Presentation layer)
> **Date**: 2026-08-07
> **Engine**: Godot 4.7.1 (headless-verified)
> **QA 终审**: 2026-08-07 PASS (t_ff6dffa5) — independent merged-main re-run 4668/0
> **Story Type**: Integration — evidence BLOCKING (automated coverage required)

## Summary

`SelectionInputBridge` (`src/systems/selection_input_bridge.gd`) is the
presentation-layer bridge Node that connects the RefCounted SelectionSystem
(Story 001) to the scene tree, mirroring the established
`PlacementInputBridge` pattern (ADR-0005 §5). The composition root
(SimulationOrchestrator) creates it as a child Node in `_initialize_topology()`
Phase 2 and injects the SelectionSystem, GridSystem (for screen→cell
conversion), the presentation cell size, and PlacementSystem (for the
Move-during-drag guard).

The bridge:
- converts screen clicks → grid cells via `GridSystem.world_to_grid()` and
  forwards `on_cell_clicked(cell)` to the RefCounted SelectionSystem (clicks
  outside the grid are ignored — never forwarded OOB)
- handles Esc/Del via `_unhandled_key_input()` — focus-independent per Godot
  4.6 dual-focus (hotkeys work regardless of which Control holds focus)
- OWNS the 2s sell-confirm timer (UI-layer state, never simulation state per
  ADR-0005 §3 "Timer signals" exclusion) with a generation-guarded
  SceneTreeTimer (process_always=true — render-time, fires while paused)
- exposes the sell-confirm entry points Story 003/004 hook: the Sell button
  and Del BOTH call `request_sell_confirm()` (the keyboard never bypasses the
  confirm — TR-SEL-009); `confirm_sell()` emits `sell_confirm_confirmed`
  (Story 003 performs the sale); timeout / Esc / click-away emit
  `sell_confirm_reverted` (no destructive default)
- exposes `is_move_blocked()` (PlacementSystem AC27: Move disabled during any
  active drag)

Automated coverage: `tests/integration/selection_system/bridge_input_test.gd`
— **102 asserts, 0 failed** (registered in `tests/headless_runner.gd`
TEST_FILES).

Full suite: **4668 passed, 0 failed** (independent QA re-run on merged main
@ 0fe002e: baseline 4566 + 102 new; leak profile 218/12 unchanged).

## Blocking AC Verification

### AC3 — Esc 取消 (deselect / cancel sell-confirm)

- ✅ Automated: Esc with a selection → selection clears, `selection_changed
  (null)` fires exactly once (real SelectionSystem through the bridge).
- ✅ Automated edge: Esc with no selection → no-op, no signal.
- ✅ Automated edge: Esc during pending sell-confirm → REVERT ONLY, selection
  STAYS (GDD states table: `sell-confirm pending | Esc | selected | reverts,
  no sale`); no `sell_confirm_confirmed`, no selection_changed emission; a
  second Esc (now no pending) deselects.

### Core Rule 5 / TR-SEL-009 — Del 软确认 (soft-confirm, never instant)

- ✅ Automated: Del with a selection → the SAME soft-confirm as clicking Sell
  (`request_sell_confirm()` opens the window, `sell_confirm_started` fires
  once); NO `sell_confirm_confirmed` — no instant destructive sale; selection
  unchanged.
- ✅ Automated edge: Del with no selection → no-op, no signals.
- ✅ Automated edge: Del during pending confirm → no double-morph (window
  stays open, `sell_confirm_started` fired exactly once).
- ✅ Automated: Esc/Del echo repeats ignored; key releases ignored; unrelated
  keys ignored (dual-focus hotkey hygiene).

### TR-SEL-008 — 桥接转发 (bridge wired: screen→cell→on_cell_clicked)

- ✅ Automated: composition-root boot → `SelectionInputBridge` is a child of
  SimulationOrchestrator and forwards to the SAME SelectionSystem instance
  the composition root owns (TR-PS-011-style ownership).
- ✅ Automated: synthetic `InputEventMouseButton` at screen position P →
  `GridSystem.world_to_grid()` runs exactly once → the system receives
  `on_cell_clicked(world_to_grid(P))` — raw screen pixels (TYPE_VECTOR2)
  NEVER reach the system (spy records every forwarded arg type).
- ✅ Automated: full real flow — place a treadmill via the real
  PlacementSystem, click at its screen cell through the bridge → selection
  resolves to the instance, `selection_changed` fires with the full payload
  (instance_id, def, cell, rotation).
- ✅ Automated: click empty buildable floor through the bridge → deselect +
  `selection_changed(null)` (AC2 via bridge).
- ✅ Automated edge: click OUTSIDE the grid (negative position → cell (-1,-1);
  beyond the grid → cell (12,12)) → ignored, nothing forwarded; the
  bounds-check gate runs (conversion happens, forwarding does not).
- ✅ Automated: right-click and mouse-up are NOT forwarded (left-press only).
- ✅ Automated: no `_process()` override — event-driven only (mirrors
  TR-PS-012's no-polling rule; script-method inspection evidence).

### Edge Case — 2s 超时回退 (timer revert, no destructive default)

- ✅ Automated: pending → timeout handler fires → `sell_confirm_reverted`
  emitted exactly once, window closed, NO `sell_confirm_confirmed` (no sale),
  selection stays selected (states table: `pending | 2s elapse | selected`).
- ✅ Automated edge: confirm clicked within the window ("1.9s" represented
  deterministically as confirm-before-timeout) → `sell_confirm_confirmed`
  fires exactly once, NO revert; the timeout firing AFTER the confirm is a
  silent no-op.
- ✅ Automated edge: stale timeout from a CANCELLED window cannot revert a
  NEWER window (generation guard — window A request+Esc, window B request,
  A's timeout fires → B stays open, no spurious revert; B's own timeout
  closes B).
- ✅ Automated edge: render-time, not tick-gated — script-source inspection
  proves `tree.create_timer(_sell_confirm_duration, true)` (process_always
  = true → fires even while the sim is paused) and the timeout handler is
  connected with the generation bind. (A live SceneTreeTimer cannot be
  created in a `--script` SceneTree `_init()` context — `get_tree()` is null
  for nodes there, probe-verified; the placement bridge test uses the same
  script-inspection evidence pattern for the `_process` absence.)

### Click-away during pending

- ✅ Automated: grid click while pending → confirm reverts (`sell_confirm
  _reverted`), no sale, AND the click resolves normally afterward (empty
  floor click deselects) — GDD states table `pending | click-away | selected`.

### External invalidation reverts pending (GDD states table / AC11)

- ✅ Automated: selected piece removed by ANOTHER path (GridSystem.clear() →
  grid_changed → SelectionSystem AC11 clears selection → selection_changed
  (null)) while a confirm is pending → the bridge's pending window reverts
  (`sell_confirm_reverted`), NO `sell_confirm_confirmed` (no sale of a
  removed piece), selection cleared. The bridge subscribes to
  `selection_changed` in init() so this path — invisible to any bridge input
  handler — still closes the window.

### Move during drag guard (story Implementation Notes / AC27)

- ✅ Automated: `is_move_blocked()` false when IDLE, true while
  PlacementSystem is DRAGGING, false again after the drag ends — Story 004's
  toolbar disables Move via this query.

### AC bridge — ownership survives bridge free

- ✅ Automated: bridge Node destroyed (scene transition) → SelectionSystem
  NOT freed (freed-object detection), selection state survives, composition
  root still holds the SAME system instance.

## Guardrails

- ✅ Control Manifest: typed signal connections only (bridge signals
  connected via `.connect(callable)`); no string-based connects.
- ✅ Control Manifest: gameplay values data-driven — `sell_confirm_duration`
  read from `config["sell_confirm_duration"]`, clamped to the GDD safe range
  (1.5–3.0s): default 2.0, 10.0→3.0, 0.1→1.5, 1.8→1.8 (all automated).
- ✅ ADR-0005 §5 bridge rules: screen→cell conversion BEFORE any system call;
  `_unhandled_input()` for mouse; `_unhandled_key_input()` for keyboard
  (focus-independent, 4.6 dual-focus); bridge owns timer creation (RefCounted
  never creates timers).
- ✅ `class_name` immediately follows `extends` (`class_name
  SelectionInputBridge extends Node` — 4.7 pitfall).
- ✅ The bridge never sells: it fires `sell_confirm_confirmed`; the sale
  (piece removal, Economy credit, selection clear) is Story 003's scope
  (child task t_e4e62360 hooks this signal).

## Files Changed

- `src/systems/selection_input_bridge.gd` (new — `SelectionInputBridge
  extends Node`)
- `src/systems/selection_input_bridge.gd.uid` (new)
- `src/systems/simulation_orchestrator.gd` (Phase 2: create + attach
  SelectionInputBridge, inject system/grid/cell_size/placement)
- `.godot/global_script_class_cache.cfg` (register `SelectionInputBridge`
  class_name — headless-safe class cache, committed)
- `tests/integration/selection_system/bridge_input_test.gd` (new, 102 asserts)
- `tests/headless_runner.gd` (register new test)

## Known Gaps / Future Work

- The ACTUAL sale on `sell_confirm_confirmed` (piece removal, Economy refund
  credit, selection clear, mapping removal) is Story 003 — the bridge only
  fires the signal; "no balance change" on timeout is asserted at the bridge
  layer as "no confirmed signal" (the balance-level assertion lands in
  Story 003's `sell_flow_test.gd`).
- The toolbar Control rendering (button morph to "Confirm sell +$X" on
  `sell_confirm_started`, revert on `sell_confirm_reverted`) is Story 004 —
  the bridge drives it via signals, it doesn't build it.
- Gamepad input (B = cancel, etc.) is a stretch goal per the UX spec — out of
  scope for MVP keyboard/mouse.
