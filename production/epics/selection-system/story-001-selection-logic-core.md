# Story 001: Selection Logic Core + Instance Mapping

> **Epic**: selection-system
> **Status**: Ready
> **Layer**: Presentation
> **Type**: Logic
> **Estimate**: M — 2 sessions (≤4h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-06

## Context

**GDD**: `design/gdd/selection-system.md`
**Requirement**: `TR-SEL-001`, `TR-SEL-004`, `TR-SEL-005`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0005 (Signal Bus & Event Routing — Input Bridge Pattern §5); ADR-0006 (Economy credit — not used in this story, but the interface exists)
**ADR Decision Summary**: SelectionSystem is a **RefCounted** logic object (no scene-tree presence, same DI discipline as GridSystem/PlacementSystem). It maintains a single current selection and a self-maintained `instance_id → {equipment_id, anchor, rotation}` mapping built by subscribing to PlacementSystem's `placement_committed` signal and GridSystem's `grid_changed` signal. It reads GridSystem via `get_occupant_id(cell)` only (per-consumer contract). A thin presentation-layer **bridge Node** forwards clicks/key events (Story 002).

**Engine**: Godot 4.7.1 | **Risk**: MEDIUM
**Engine Notes**: RefCounted logic + bridge Node; `RefCounted` signal support is stable (`signal` works on any Object subclass). Typed signal connections. `class_name` follows `extends` immediately; headless cross-script refs via `preload` aliases.

**Control Manifest Rules (Presentation layer)**:
- Required: typed signal connections only; bridge Node pattern for RefCounted input-requiring systems
- Forbidden: string-based signal connections; autoload singletons for system access

---

## Acceptance Criteria

*From GDD `design/gdd/selection-system.md`, scoped to this story:*

- [ ] AC1 GIVEN nothing selected, WHEN the player clicks a placed instance, THEN the outline+icon+toolbar appear within one frame and `selection_changed(instance_id, …)` fires
- [ ] AC2 GIVEN a selection, WHEN the player clicks empty buildable floor, THEN selection clears, the toolbar disappears, and `selection_changed(null)` fires
- [ ] AC9 GIVEN a selected piece A, WHEN the player clicks a different placed piece B, THEN selection swaps directly to B (no intermediate deselect)
- [ ] AC10 GIVEN a selected piece A, WHEN the player clicks A again, THEN it is a no-op — selection stays on A, no signal fires, no toolbar flicker
- [ ] AC11 GIVEN a selected piece, WHEN the piece is removed externally, THEN selection clears and `selection_changed(null)` fires
- [ ] AC12 GIVEN a placement drag is active (PlacementSystem `is_dragging()` true), WHEN the player clicks on the grid, THEN SelectionSystem does not resolve a new selection
- [ ] Core Rule 1 GIVEN the player presses Esc, WHEN no sell-confirm is pending, THEN selection clears (keyboard wiring lands in Story 002; the deselect logic itself lives here)

---

## Implementation Notes

*Derived from ADR-0005 + GDD Core Rules 1/2/6:*

**Single-select logic (Core Rule 1, TR-SEL-001)**:
- Click a placed instance → select it (resolve via `GridSystem.get_occupant_id(cell)` → local mapping → full instance data)
- Click empty buildable floor, or a different placed piece (direct swap), or Esc → deselect (swap = no intermediate deselect)
- Click the already-selected piece → **no-op** (not a toggle-off — avoids accidentally closing a panel the player is reading)
- Multi-select is out of MVP

**Instance mapping (Core Rule 8 + TR-SEL-005)**:
- Self-maintains `instance_id → {equipment_id, anchor, rotation}` by subscribing to `placement_committed(instance_id, equipment_id, footprint_cells)` (PlacementSystem) and `grid_changed` (GridSystem)
- Reads GridSystem via `get_occupant_id(cell)` ONLY — not `get_placed_instances()`/`get_snapshot()` (per-consumer contract)

**Signal (Core Rule 6, TR-SEL-004)**:
- `selection_changed(instance_id: int, equipment_def: EquipmentDef, cell: Vector2i, rotation: int)`, or `selection_changed(null)` on deselect
- Arity matters — verify emit arity matches the declaration (GDScript does not check arity at parse time; a mismatch produces a runtime error)

**Suppression during drag (Edge Cases, AC12)**:
- While PlacementSystem `is_dragging()` returns true, clicks do NOT resolve a new selection (modes never fight)

**External invalidation (Edge Cases, AC11)**:
- If the selected `instance_id` no longer resolves in GridSystem (sold elsewhere / grid change), selection clears and `selection_changed(null)` fires

**No scene-tree** (TR-SEL-008): the logic object never receives `_input()` / creates timers via `get_tree()` — the bridge (Story 002) owns those.

**4.7.1 pitfalls**:
- `var x := expr` fails on Variant returns → explicit `: int` / `: Vector2i` when reading GridSystem state
- `RefCounted` signal connections survive across `await` boundaries — but there should be no `await` in pure selection resolution

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 002]: bridge Node (click/key forwarding, sell-confirm timer, dual-focus keyboard)
- [Story 003]: sell flow (soft-confirm, refund via Economy.credit, fade-out)
- [Story 004]: contextual toolbar (Inspect/Move/Sell buttons) + selection cue (outline/glow/icon) + Move handoff
- [Story 005]: load-time mapping rebuild

---

## QA Test Cases

*Derived from GDD acceptance criteria. Logic story — automated coverage required (BLOCKING).*

- **AC1**: 点击选中
  - Given: nothing selected
  - When: click a placed instance
  - Then: selection resolves within one frame; `selection_changed(instance_id, …)` fires
  - Edge cases: click on empty floor of a multi-cell footprint's gap cell (no resolution)

- **AC2**: 点击空地取消
  - Given: a selection
  - When: click empty buildable floor
  - Then: selection clears; `selection_changed(null)` fires
  - Edge cases: click on non-buildable floor (no deselect — only buildable floor deselects per GDD)

- **AC9/AC10**: 直接换选 / 重复点击
  - Given: piece A selected
  - When: click different piece B → selection swaps directly (no intermediate deselect)
  - When: click A again → no-op, no signal, no flicker

- **AC11**: 外部失效
  - Given: a selected piece
  - When: the piece is removed externally
  - Then: selection clears; `selection_changed(null)` fires

- **AC12**: 拖拽抑制
  - Given: PlacementSystem `is_dragging()` true
  - When: click on the grid
  - Then: no new selection resolves

---

## Test Evidence

**Story Type**: Logic
**Required evidence**:
- `tests/unit/selection_system/selection_logic_test.gd` — must exist and pass (single-select, swap, no-op, external invalidation, drag suppression, signal arity)

**Status**: [ ] Not yet created

---

## Dependencies

- Depends on: GridSystem (`get_occupant_id`), PlacementSystem (`placement_committed`, `is_dragging`), EquipmentCatalog (`get_definition`) — all implemented in src/
- Unlocks: Story 002 (bridge), Story 005 (load rebuild)
