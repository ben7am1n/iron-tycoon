# Story 004: Preview==Commit Equivalence and Invalid Equipment

> **Epic**: zone-rules
> **Status**: In Review
> **Layer**: Feature
> **Type**: Logic
> **Estimate**: M — 2 sessions (≤4h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-02

## Context

**GDD**: `design/gdd/zone-rules.md`
**Requirement**: `TR-ZR-002` (already satisfied by GridStateReader — verified), plus preview==commit contract (Core Rule 2) and invalid-equipment handling (edge case)
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0001 (DI Container — stateless pure function); ADR-0003 (GridStateReader Contract)
**ADR Decision Summary**: Because `evaluate` is pure and takes the abstract `GridStateReader` (shared read base of both real `GridSystem` and speculative `GridSnapshot`), it cannot tell a real snapshot from a speculative one. Evaluating a speculative snapshot with hypothetical piece X placed MUST equal evaluating the real snapshot after X is committed (same resulting instance set). Invalid-equipment handling uses an injected `strict_mode`/`on_invalid_equipment` channel (mirrors EquipmentCatalog's injectable strict_mode), NOT a bare assert — bare assert is a no-op in release and cannot be tested in headless CI.

**Engine**: Godot 4.7.1 | **Risk**: LOW
**Engine Notes**: `GridSnapshot` provides speculative grid views via delta dictionaries (`_adds`, `_removes`); constructed from a base `GridStateReader` + proposed additions/removals. Immutable after construction.

**Control Manifest Rules (Feature layer)**:
- Required: stateless pure function — same input always same output
- Required: preview == commit equivalence (placement preview passes a speculative snapshot)
- Forbidden: no duck-typing the grid read surface
- Forbidden: bare `assert()` for invalid-equipment detection (use injected channel)

---

## Acceptance Criteria

*From GDD `design/gdd/zone-rules.md`, scoped to this story:*

- [x] AC2 [WB] GIVEN a speculative snapshot with hypothetical piece X (provisional `instance_id` P), WHEN `evaluate(speculative)` is diffed against `evaluate(real snapshot after X is committed)` for the same resulting instance set, THEN every shared instance_id's `{comfort, zone_synergy, spaciousness, total}` are identical. *(The single most important test — preview==commit.)*
- [x] AC15a [WB] GIVEN a placed instance whose `equipment_id` has no EquipmentCatalog definition, WHEN `evaluate()` runs with `strict_mode=false`, THEN it returns normally, that instance's row is `{comfort=0, zone_synergy=0, spaciousness=<computed>, total=spaciousness}`, it is excluded from neighbors' `n_same`, AND the injected `on_invalid_equipment` callback is invoked exactly once with the offending `instance_id` and `equipment_id`
- [x] AC15b [WB] GIVEN the same setup with `strict_mode=true`, WHEN `evaluate()` runs, THEN it does **not** return a normal result — the injected error channel captures a structured error (deterministically observable by a test harness **without** relying on stderr capture, process exit code, or `assert()`)

---

## Implementation Notes

*Derived from ADR-0001 + ADR-0003 Implementation Guidelines:*

**Core Rule 2 — preview == commit:**
- `evaluate` takes the abstract `GridStateReader` — cannot tell real from speculative (TR-GS-025)
- The speculative snapshot must contain the hypothetical piece with a **stable provisional `instance_id`** so the instance set is structurally identical to a committed one — no special-casing
- AC2 diffs evaluate(speculative) against evaluate(real after commit) for the same instance set — every shared id's values identical

**Invalid equipment (edge case):**
- An `occupant_id` with no matching EquipmentCatalog definition (stale/corrupt type id):
  - That instance contributes `comfort=0`, `zone_synergy=0` for itself; excluded from neighbors' `n_same`; spaciousness still computed geometrically
  - Signaled via injected channel: `strict_mode: bool` + `on_invalid_equipment: Callable(instance_id, equipment_id)` — mirrors EquipmentCatalog's injectable strict_mode pattern
  - `strict_mode=false` (AC15a): returns normally with zeroed row + callback invoked exactly once
  - `strict_mode=true` (AC15b): structured error captured via injected channel — deterministically observable by test harness without stderr/exit-code/assert
- Signals an upstream invariant violation (PlacementSystem committed an instance whose type isn't in the Catalog), not a ZoneRules bug

**No serialization (TR-ZR-007):**
- ZoneRules contributes nothing to the save file — stateless pure function

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 001]: evaluate() entry point, effect vocabulary
- [Story 002]: zone_synergy formula
- [Story 003]: spaciousness formula

---

## QA Test Cases

*Written by qa-lead at story creation. The developer implements against these — do not invent new test cases during implementation.*

- **AC2**: 预览==提交
  - Given: speculative snapshot with hypothetical piece X (provisional instance_id P)
  - When: evaluate(speculative) diffed against evaluate(real snapshot after X committed)
  - Then: every shared instance_id's {comfort, zone_synergy, spaciousness, total} identical
  - Edge cases: X adjacent to existing same-zone equipment (synergy changes propagate identically); X isolated

- **AC15a**: 无效装备宽容模式
  - Given: placed instance with equipment_id not in EquipmentCatalog, strict_mode=false
  - When: evaluate() runs
  - Then: returns normally; row = {comfort=0, zone_synergy=0, spaciousness=<computed>, total=spaciousness}; excluded from neighbors' n_same; on_invalid_equipment called exactly once with offending instance_id + equipment_id
  - Edge cases: multiple invalid instances — callback per instance

- **AC15b**: 无效装备严格模式
  - Given: same setup, strict_mode=true
  - When: evaluate() runs
  - Then: does NOT return normal result; injected error channel captures structured error (deterministically observable without stderr/exit-code/assert)
  - Edge cases: test harness asserts via injected channel, not process output

---

## Test Evidence

**Story Type**: Logic
**Required evidence**:
- `tests/unit/zone_rules/preview_commit_test.gd` — AC2 (must exist and pass)
- `tests/unit/zone_rules/invalid_equipment_test.gd` — AC15a/AC15b (must exist and pass)

**Status**: [x] Created — `tests/unit/zone_rules/preview_commit_test.gd` (AC2, 22 asserts) + `tests/unit/zone_rules/invalid_equipment_test.gd` (AC15a/15b + static guards, 30 asserts), both registered in TEST_FILES; full headless suite 2812 passed / 0 failed.

---

## Dependencies

- Depends on: Story 002 (zone_synergy), Story 003 (spaciousness), grid-system epic (`GridSnapshot` speculative view)
- Unlocks: satisfaction epic (consumes per-instance effect dict), placement preview / overlay (presentation layer later)
