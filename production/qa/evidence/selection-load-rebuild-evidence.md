# QA Evidence — SEL-005: Load-time Mapping Rebuild

> **Story**: production/epics/selection-system/story-005-load-time-mapping-rebuild.md
> **Epic**: selection-system (Presentation layer — Integration story)
> **Date**: 2026-08-07
> **Engine**: Godot 4.7.1 (headless-verified)
> **Story Type**: Integration — evidence BLOCKING (automated coverage required)

## Summary

`SelectionSystem` gains its load-time mapping rebuild (`rebuild_mapping()`),
the third input to the instance mapping after `placement_committed` and
`grid_changed`. Wired into the existing SaveLoad Phase B load order at step
3a (architecture.md — after `GridSystem.deserialize()`, before MemberSim),
it reconstructs `instance_id → {equipment_id, anchor, rotation,
footprint_cells}` from the loaded grid so the FIRST click after a load
resolves correctly (UX "Load robustness" AC).

| File | Class | Role |
|------|-------|------|
| `src/systems/selection_system.gd` | `SelectionSystem` | `rebuild_mapping()` (load-order slot) + `_match_equipment_id()` (geometric equipment-identity recovery) |

Automated coverage:
- `tests/unit/selection_system/load_rebuild_unit_test.gd` — **76 asserts, 0 failed**
- `tests/integration/selection_system/load_rebuild_test.gd` — **29 asserts, 0 failed**

Full suite: **4877 passed, 0 failed** (independent QA re-run on merged main @ da67aac; main tip baseline 4772 + 105 new; both new files registered in `tests/headless_runner.gd` TEST_FILES; leak profile 218/12 unchanged).

## Key Design Decision: the load-time bulk read surface

The grid stores only integer `occupant_id` — never equipment type (TR-GS) —
so `equipment_id` cannot be read off the loaded grid; it is recovered by
matching each instance's transformed footprint against the catalog. The
rebuild uses GridSystem's **load-time bulk read surface**
(`get_placed_instances()`, the GDD's granted Core Rule 8 read surface) —
NOT a per-cell scan — because rotation is order-ambiguous from occupied
cells alone:

- Runtime `_derive_entry()` resolves R0 vs R180 for a straight 1×2 by the
  ARRAY ORDER of `placement_committed`'s footprint (canonical def order
  preserved at commit). A row-major cell scan loses that order, and a
  min-offset match would collapse an R180 treadmill to R0.
- The save blob stores the rotation; GridSystem restores it into the
  PlacementRecord; `get_placed_instances()` carries it verbatim. The
  rebuild copies anchor + rotation as authoritative restored data and
  derives ONLY equipment_id via order-independent set matching at the
  known rotation. This makes "mapping after load == mapping before save"
  hold exactly (TR-SEL-007), including the R90 symmetric-shape case.

The class doc's GRID READ CONTRACT is updated to document this as the ONE
sanctioned bulk-read exception (runtime maintenance paths still use
per-cell reads only).

## Blocking AC Verification

### Core Rule 8 — 加载重建 (mapping rebuilt from the loaded grid)

- ✅ Automated (unit): grid occupancy committed directly (simulating
  deserialize — no `placement_committed` fires) → pre-rebuild click does
  NOT resolve; after `rebuild_mapping()` the first click selects the piece
  with the correct `{instance_id, equipment_id, anchor, rotation}` payload.
- ✅ Automated (unit): rotation recovery for R0/R90/R180/R270 pieces —
  rotation reconstructed from the loaded grid, not stored in SelectionSystem.
- ✅ Automated (unit): multi-cell footprints grouped by occupant_id — ANY
  footprint cell of a 2×2 bench selects the bench; a separate 1×1 yoga
  remains distinct (direct swap works).
- ✅ Automated (integration): full SaveLoad round-trip — place pieces via the
  real PlacementSystem, save, load into a fresh rig, first click on each
  piece selects it with the pre-save payload preserved.
- ✅ Automated edge (unit): zero placed pieces → empty mapping, no error.
- ✅ Automated edge (unit + integration): occupant whose footprint matches no
  catalog def → push_error + entry skipped (loud data-consistency guard,
  never a half-built entry).

### TR-SEL-007 — 存档不含映射 (sells/selection contribute nothing to the blob)

- ✅ Automated (integration): after a save with a LIVE selection active, the
  blob has NO `selection_system` key and exactly the 8 `CONTRIBUTING_KEYS`
  (SaveLoad contract).
- ✅ Automated (unit): rebuild over a grid whose occupancy was produced by
  real runtime placement reproduces the runtime mapping payloads exactly
  (reconstructed, not stored).
- ✅ Automated (integration): R90 bench round-trips rotation 90 — the
  order-ambiguity trap that a naive per-cell scan would collapse.

### UX AC — 读档后首次点击 (first click after load selects correctly)

- ✅ Automated (integration): fresh rig + load → first click on a placed
  treadmill and a yoga both emit `selection_changed(instance_id, def,
  anchor, rotation)` with the correct payload (mapping rebuilt).
- ✅ Automated (unit): same, at the unit level with a directly-committed
  loaded grid.

### QA Test Cases

- **加载重建**: covered (unit + integration, see Core Rule 8 above).
- **存档不含映射**: covered (blob key absence + payload equality).
- **幂等重建**: ✅ Automated (unit) — `rebuild_mapping()` twice yields
  identical mapping; every payload after rebuild #2 equals rebuild #1, and
  the R90 bench still resolves identically.

## Load-order slot (architecture.md Phase B step 3a)

- ✅ Automated (integration): `SelectionSpy` (extends the REAL
  SelectionSystem) records into the shared rig call log — the log shows
  `SelectionSystem.rebuild_mapping` AFTER `GridSystem.deserialize:commit`
  and BEFORE `MemberSim.deserialize:commit`, exactly once.
- ✅ The existing `tests/integration/save_load/load_orchestration_test.gd`
  AC4 (87 asserts) still passes unchanged — the 9-step commit sequence is
  intact.

## Guardrails

- ✅ Control Manifest: typed signal connections only (rebuild adds no new
  connections; existing `_post_init` wiring untouched).
- ✅ Use-before-init guard on `rebuild_mapping()` (push_error + safe
  no-op, never assert) — verified by the unit GUARD test.
- ✅ GRID READ CONTRACT honored: the sanctioned bulk read is documented in
  the class doc as the ONE load-time exception; runtime paths unchanged.
- ✅ No new engine APIs; `class_name SelectionSystem extends SimSystem`
  (class_name follows extends immediately).

## Files Changed

- `src/systems/selection_system.gd` (add `rebuild_mapping()` +
  `_match_equipment_id()`; class doc contract update)
- `tests/unit/selection_system/load_rebuild_unit_test.gd` (new, 76 asserts)
- `tests/integration/selection_system/load_rebuild_test.gd` (new, 29 asserts)
- `tests/headless_runner.gd` (register both new test files)

## Known Gaps / Future Work

- Equipment-identity recovery assumes catalog footprints are distinguishable
  at the recorded rotation (first-match in catalog order wins for
  identical-footprint defs). A catalog with two defs sharing the exact
  transformed footprint at the same rotation is ambiguous — documented as a
  data-consistency constraint, same limitation as PlacementSystem's
  `_instance_equipment` (the grid cannot recover equipment identity beyond
  geometry).
- Visual "first click after load" walkthrough (actual scene load with the
  bridge + toolbar) is the Story 002/003 presentation layer's domain; the
  logic-level UX AC is proven here headlessly.
