# Story 002: Input Bridge Node + Keyboard Handling

> **Epic**: selection-system
> **Status**: Complete — 2026-08-07 (QA 终审 PASS, t_ff6dffa5)
> **Layer**: Presentation
> **Type**: Integration
> **Estimate**: M — 2 sessions (≤4h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-06

## Context

**GDD**: `design/gdd/selection-system.md`
**Requirement**: `TR-SEL-008`, `TR-SEL-009`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0005 (Signal Bus & Event Routing — Input Bridge Pattern §5)
**ADR Decision Summary**: A thin **bridge Node** owned by the SimulationOrchestrator connects the RefCounted SelectionSystem to the scene tree. The bridge converts engine-space coordinates to grid-space cells, forwards `_unhandled_input` (mouse) / `_unhandled_key_input` (keys, focus-independent per Godot 4.6 dual-focus), and owns timer creation (the 2s sell-confirm timer is UI-layer state, not simulation state). See `src/systems/placement_input_bridge.gd` for the established bridge pattern (PlacementSystem's bridge from the Core layer).

**Engine**: Godot 4.7.1 | **Risk**: MEDIUM
**Engine Notes**: dual-focus (4.6+): keyboard/gamepad focus is separate from mouse/touch focus — handle Esc/Del via `_unhandled_key_input` on the bridge (focus-independent). `class_name` follows `extends` immediately.

**Control Manifest Rules (Presentation layer)**:
- Required: typed signal connections only; bridge Node pattern (§5) — screen→cell conversion, `_unhandled_input` for mouse, `_unhandled_key_input` for keys
- Forbidden: string-based signal connections

---

## Acceptance Criteria

*From GDD `design/gdd/selection-system.md`, scoped to this story:*

- [ ] AC3 GIVEN a selection, WHEN the player presses Esc, THEN selection clears; if a sell-confirm was pending, it also cancels without selling
- [ ] Core Rule 5 GIVEN a selection, WHEN the player presses Del, THEN the same Sell soft-confirm is triggered (not an instant destructive sell — the keyboard must not bypass the confirm)
- [ ] TR-SEL-008 GIVEN the bridge is wired, WHEN the player clicks the grid, THEN the bridge converts screen→cell and forwards `on_cell_clicked(cell)` to the RefCounted SelectionSystem
- [ ] Edge Cases GIVEN the sell-confirm window is open, WHEN 2 s elapse with no second click, THEN it reverts to the normal Sell button (no destructive default) — the bridge's timer fires the revert

---

## Implementation Notes

*Derived from ADR-0005 §5 + GDD Core Rules 5/6:*

**Bridge Node structure** (mirror `src/systems/placement_input_bridge.gd`):
- Node owned/attached by the SimulationOrchestrator in `_ready()`
- Mouse: `_unhandled_input(event)` — on `InputEventMouseButton` left-click, convert screen→cell via GridSystem grid_world_conversion, forward `on_cell_clicked(cell)` to SelectionSystem
- Keys: `_unhandled_key_input(event)` (focus-independent, dual-focus 4.6+) — Esc → `on_esc_pressed()`, Del → `on_del_pressed()`
- Timer ownership: the bridge owns the 2s sell-confirm timer (UI-layer state); on timeout it calls back to the toolbar/SelectionSystem to revert the pending state

**Keyboard rules (Core Rule 5, TR-SEL-009)**:
- Esc = deselect (also cancels a pending sell-confirm — never sells)
- Del = triggers the same Sell soft-confirm (NEVER an instant destructive sell — the keyboard must not bypass the confirm)
- No keyboard shortcut for Move (spatial re-placement needs the pointer)

**Move during drag guard**: if `begin_relocate()` is called while PlacementSystem is DRAGGING, it is a no-op (PlacementSystem AC27); the bridge/UI should disable the Move button during any active drag via `PlacementSystem.is_dragging()`.

**4.7.1 pitfalls**:
- dual-focus: hotkeys must work regardless of which Control has keyboard focus
- Timer via `get_tree().create_timer()` — must be the bridge (a Node), never the RefCounted logic object
- `var x := expr` fails on Variant returns → explicit `: Vector2i` for cell conversion results

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 001]: selection logic core (what the bridge forwards INTO)
- [Story 003]: sell flow (the soft-confirm button morph — the bridge only fires the timer revert)
- [Story 004]: toolbar Control rendering (bridge drives it, doesn't build it)

---

## QA Test Cases

*Derived from GDD acceptance criteria. Integration story — automated coverage required (BLOCKING).*

- **AC3**: Esc 取消
  - Given: a selection (and optionally a pending sell-confirm)
  - When: Esc pressed
  - Then: selection clears; pending sell-confirm cancels without selling; `selection_changed(null)` fires
  - Edge cases: Esc with no selection (no-op); Esc during pending confirm (revert only, selection stays)

- **Core Rule 5**: Del 软确认
  - Given: a selection
  - When: Del pressed
  - Then: the SAME soft-confirm triggers as clicking Sell (button morphs; no instant sale)
  - Edge cases: Del during pending confirm (no double-morph); Del with no selection (no-op)

- **TR-SEL-008**: 桥接转发
  - Given: bridge wired
  - When: left-click on grid
  - Then: screen→cell conversion; `on_cell_clicked(cell)` forwarded to RefCounted SelectionSystem
  - Edge cases: click outside the grid (no conversion / ignored)

- **Timer**: 2s 超时回退
  - Given: sell-confirm pending
  - When: 2 s elapse with no second click
  - Then: reverts to normal Sell button; no sale; no balance change
  - Edge cases: confirm clicked at 1.9s (sale proceeds); timer fires while paused (render-time, not tick-gated)

---

## Test Evidence

**Story Type**: Integration
**Required evidence**:
- `tests/integration/selection_system/bridge_input_test.gd` OR interaction test — must exist and pass (bridge forwarding, Esc/Del semantics, timer revert)

**Status**: [x] Complete — 2026-08-07 (QA 终审 PASS, t_ff6dffa5)

`src/systems/selection_input_bridge.gd` (bridge Node, 367 lines) exists,
owned by `SimulationOrchestrator` (Phase 2, mirrors the placement bridge);
forwards screen→cell clicks via `GridSystem.world_to_grid()` (OOB ignored),
handles Esc/Del via `_unhandled_key_input` (dual-focus 4.6+), owns the
generation-guarded 2s SceneTreeTimer (`process_always=true`), and exposes
`request_sell_confirm()` / `confirm_sell()` / `is_move_blocked()` plus
`sell_confirm_started/reverted/confirmed` signals. Wired into
`SimulationOrchestrator`; `tests/integration/selection_system/
bridge_input_test.gd` (102 assertions) exists, passes, and is registered in
`tests/headless_runner.gd` TEST_FILES. Full headless suite (independent QA
re-run on merged main @ 0fe002e): 4668 passed / 0 failed / exit 0 /
0 SCRIPT ERROR (baseline 4566 at main tip + 102 new; leak profile 218/12
unchanged from pre-existing baseline).

Coverage by AC (exact assert counts, verified against test file):
- **TR-SEL-008** (26): bridge is a child of SimulationOrchestrator and
  forwards to the same SelectionSystem instance; synthetic click at P →
  `world_to_grid(P)` exactly once → `on_cell_clicked(world_to_grid(P))`,
  raw pixels never reach the system; OOB clicks ignored; real place+click
  selects with full payload; empty-floor click deselects; no `_process`
- **AC3** (14): Esc deselects + `selection_changed(null)` fires once; Esc
  no-selection no-op; Esc during pending sell-confirm = revert only
  (selection stays per GDD states table), second Esc deselects
- **Core Rule 5** (11): Del opens the same soft-confirm as Sell
  (`sell_confirm_started` once, NO `sell_confirm_confirmed` — keyboard never
  bypasses the confirm); Del no-selection no-op; Del during pending no
  double-morph
- **Timer** (22): 2s timeout reverts, no sale, selection stays; confirm
  within window → confirmed fires once, stale timeout after is a no-op;
  stale timeout from cancelled window cannot kill a newer window
  (generation guard); `create_timer(duration, true)` render-time wiring
  (fires while paused)
- **Keyboard hygiene** (5): unrelated keys ignored; Esc/Del echo repeats and
  key releases ignored (dual-focus hotkeys)
- **Click-away** (5): grid click while pending reverts then resolves
  normally
- **Move guard** (4): `is_move_blocked()` true while PlacementSystem is
  DRAGGING (AC27), false idle/after
- **External invalidation** (6): piece removed by another path while pending
  → revert, no sale (AC11 via `selection_changed` subscription)
- **Ownership** (5): bridge Node destroyed → SelectionSystem NOT freed,
  selection state + composition-root reference survive
- **Config** (4): `sell_confirm_duration` data-driven, clamped to GDD safe
  range (default 2.0 / 10.0→3.0 / 0.1→1.5 / 1.8→1.8)

---

## Dependencies

- Depends on: Story 001 (selection logic core — the bridge's target), PlacementSystem (`is_dragging` for Move-guard), GridSystem (screen→cell conversion)
- Unlocks: Story 003 (sell flow uses the bridge's timer + Del), Story 004 (toolbar driven by the bridge)
