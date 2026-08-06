# Story 005: Load-Time Mapping Rebuild

> **Epic**: selection-system
> **Status**: Ready
> **Layer**: Presentation
> **Type**: Integration
> **Estimate**: S — 1 session (≤2h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-06

## Context

**GDD**: `design/gdd/selection-system.md`
**Requirement**: `TR-SEL-006`, `TR-SEL-007`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0005 (Signal Bus & Event Routing); SaveLoad load-order contract (architecture.md Save/Load Path — Phase B step 3a)
**ADR Decision Summary**: After `GridSystem.deserialize()` restores occupancy, SelectionSystem's local `instance_id → {equipment_id, anchor, rotation}` mapping is empty — no `placement_committed` or `grid_changed` fires during load. The mapping must be rebuilt from the loaded grid before the first player click can resolve `get_occupant_id(cell)`. This is a one-time load step, analogous to PlacementSystem's `rederive_counter()` and Navigation's `rebuild()`. Wired into SaveLoad's Phase B load order: after GridSystem, before the session unpauses.

**Engine**: Godot 4.7.1 | **Risk**: LOW
**Engine Notes**: Pure data reconstruction over GridSystem's read surface; no new engine APIs. `class_name` follows `extends` immediately.

**Control Manifest Rules (Presentation layer)**:
- Required: typed signal connections only
- Forbidden: string-based signal connections

---

## Acceptance Criteria

*From GDD `design/gdd/selection-system.md`, scoped to this story:*

- [ ] Core Rule 8 GIVEN a loaded game with placed pieces, WHEN the load completes, THEN SelectionSystem's mapping is rebuilt from the loaded grid (iterate every occupied cell, group by `occupant_id`, reconstruct `{instance_id, equipment_id, anchor, rotation}`), before the first UI frame that could receive a click
- [ ] TR-SEL-007 GIVEN a save/load round-trip, THEN sells contribute nothing to the save blob — the mapping is fully reconstructed from GridSystem on load
- [ ] UX AC GIVEN a save load with placed pieces, WHEN the first click on a piece happens, THEN it correctly selects it (mapping rebuilt — design/ux/selection-ui.md "Load robustness")

---

## Implementation Notes

*Derived from ADR-0005 + GDD Core Rule 8 + architecture.md Save/Load Path:*

**Rebuild procedure**:
- Iterate every occupied cell via GridSystem's read surface (or a load-time bulk query), group by `occupant_id`, reconstruct `{instance_id, equipment_id, anchor, rotation}` for each, and seed the mapping
- Must run AFTER `GridSystem.deserialize()` and BEFORE the first UI frame that could receive a click — in SaveLoad's Phase B load order (architecture.md step 3a: `PlacementSystem.rederive_counter()` then `SelectionSystem.rebuild_mapping()` then `Navigation.rebuild()`, before session unpauses)
- After this step, all runtime selection logic works unchanged

**Save-load integration**:
- SelectionSystem contributes NOTHING to the save blob (TR-SEL-007) — `instance_id` mapping is derived state, rebuilt on load
- The rebuild is a one-time load step — do not re-run on every scene entry beyond what the load order requires (must be idempotent — running it twice yields the same mapping)

**Edge cases**:
- Loaded game with zero placed pieces → empty mapping, no error
- Occupant id that appears in grid cells but has no EquipmentCatalog definition → skip/error handling per GridSystem contract (shouldn't happen — data consistency)

**4.7.1 pitfalls**:
- `var x := expr` fails on Variant returns → explicit `: Vector2i` / `: int` for grid reads

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 001]: selection logic core + runtime mapping maintenance (this story only seeds the mapping on load)
- SaveLoad epic internals: the load-order slot is defined by save-load (Sprint 2); this story wires SelectionSystem into it

---

## QA Test Cases

*Derived from GDD acceptance criteria. Integration story — automated coverage required.*

- **TR-SEL-006/Core Rule 8**: 加载重建
  - Given: a save blob with placed pieces; GridSystem deserialized
  - When: Phase B load order runs (after GridSystem, before unpause)
  - Then: mapping rebuilt from occupied cells; first click on a piece resolves correctly
  - Edge cases: zero placed pieces (empty mapping, no error); multi-cell footprints (grouped by occupant_id)

- **TR-SEL-007**: 存档不含映射
  - Given: a session with selections and sells
  - When: save blob is serialized
  - Then: SelectionSystem contributes nothing to the blob
  - Edge cases: mapping after load equals mapping before save (reconstructed, not stored)

- **Idempotency**: 幂等重建
  - Given: a loaded game
  - When: rebuild runs twice
  - Then: identical mapping both times

---

## Test Evidence

**Story Type**: Integration
**Required evidence**:
- `tests/integration/selection_system/load_rebuild_test.gd` — must exist and pass (load-order slot, mapping reconstruction, no-blob-contribution)

**Status**: [ ] Not yet created

---

## Dependencies

- Depends on: Story 001 (selection logic core — mapping structure), SaveLoad (Phase B load order — exists from Sprint 2), GridSystem (occupied-cell read surface)
- Unlocks: None (completes the selection-system epic; parallel to Story 004)
