# Story 001: Pure evaluate() and Effect Vocabulary

> **Epic**: zone-rules
> **Status**: Ready
> **Layer**: Feature
> **Type**: Logic
> **Estimate**: M — 2 sessions (≤4h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-02

## Context

**GDD**: `design/gdd/zone-rules.md`
**Requirement**: `TR-ZR-001`, `TR-ZR-002`, `TR-ZR-003`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0003 (GridStateReader Contract); ADR-0001 (DI Container — stateless-systems exception)
**ADR Decision Summary**: ZoneRules is a stateless pure function: `evaluate(snapshot: GridStateReader) -> Dictionary`. Receives the snapshot as a parameter, holds no persistent reference, may omit `_post_init()`. Requires `get_placed_instances() -> Array[PlacedInstance]` on GridStateReader (already added). Consumes `EquipmentCatalog.get_definition(id)` for `zone_membership` and authored `comfort` (immutable, injected). Never duck-types the grid read surface.

**Engine**: Godot 4.7.1 | **Risk**: LOW
**Engine Notes**: `PlacedInstance` is a typed `RefCounted` DTO with `instance_id`, `equipment_id`, `footprint_cells`, `access_cells` (all immutable after construction). `Array[PlacedInstance]` enables static analysis.

**Control Manifest Rules (Feature layer)**:
- Required: stateless pure function — same input always produces same output
- Forbidden: no RNG; no mutable state; no member-position/queue-length API
- Forbidden: never duck-type the grid read surface — consume typed `GridStateReader`

---

## Acceptance Criteria

*From GDD `design/gdd/zone-rules.md`, scoped to this story:*

- [ ] AC1 [WB] GIVEN a fixed snapshot S with N placed instances, WHEN `evaluate(S)` is called 100 times in sequence, THEN every call returns bit-identical Dictionary values (no variance, no time/order dependence, no RNG)
- [ ] AC8 GIVEN any valid snapshot including worst-case cross-zone clutter, WHEN `evaluate()` runs, THEN `comfort_i, zone_synergy_i, spaciousness_i, total_i ≥ 0` for every instance (never negative)
- [ ] AC11 GIVEN `get_placed_instances()` returns `[]`, WHEN `evaluate()` runs, THEN it returns an empty Dictionary
- [ ] AC12 GIVEN exactly 1 placed instance with no neighbors, WHEN `evaluate()` runs, THEN `zone_synergy_i == 0.0` and `total_i == comfort_i + spaciousness_i`
- [ ] AC13 [WB] GIVEN the implementation file `zone_rules.gd`, WHEN its source is scanned (grep / static analysis), THEN it references **only** the documented `GridStateReader` read contract methods (`get_placed_instances`, `is_solid`, `get_dimensions`) and `EquipmentCatalog.get_definition` — no member-position, queue-length, or other dynamic-state API appears anywhere in the file
- [ ] AC14 GIVEN any valid snapshot, WHEN `evaluate()` returns, THEN every value Dictionary contains **exactly** `{comfort, zone_synergy, spaciousness, total}` — no missing/extra keys
- [ ] AC16 GIVEN placed instances whose `instance_id`s are non-contiguous (e.g. 2, 7, 40), WHEN `evaluate()` iterates, THEN iteration is in ascending `instance_id` order

---

## Implementation Notes

*Derived from ADR-0001 + ADR-0003 Implementation Guidelines:*

**Core Rule 1 — pure function:**
- Sole entry point: `evaluate(snapshot: GridStateReader) -> Dictionary`
- Reads only the snapshot + injected immutable EquipmentCatalog reference; no mutable state, no RNG, never reads live member positions/queues
- `class_name ZoneRules extends RefCounted` — stateless, no SimSystem machinery (ADR-0001 stateless-systems exception)

**Core Rule 3 — snapshot contract:**
- Requires `get_placed_instances() -> Array[PlacedInstance]` (already on GridStateReader ✅)
- Looks up `EquipmentCatalog.get_definition(equipment_id)` for `zone_membership` + authored `comfort`
- `access_cells` is plural (`Array[Vector2i]`)

**Core Rule 4 — effect-tag vocabulary:**
- `comfort`: Catalog-authored input, [0.0, 1.0] — read from `effects` container, tag vocabulary owned by ZoneRules
- `zone_synergy`: ZoneRules-computed output (Story 002)
- `spaciousness`: ZoneRules-computed output (Story 003)
- All three non-negative by construction — ZoneRules never subtracts

**Core Rule 7 — output shape:**
- `evaluate` returns `Dictionary[instance_id -> {comfort, zone_synergy, spaciousness, total}]`
- `total = comfort + zone_synergy + spaciousness` (pure sum; all non-negative)
- Optional `layout_summary = mean(total over instances)` convenience field (not primary interface)

**Core Rule 8 — determinism:**
- Iteration over placed instances in ascending `instance_id` order (Dictionary preserves insertion order but does NOT auto-sort — implementation must sort) — AC16

**Invalid equipment (edge case):**
- An `occupant_id` with no matching catalog definition: contributes comfort=0, zone_synergy=0 for itself, excluded from neighbors' n_same; spaciousness still computed geometrically. Reported via injected `strict_mode`/`on_invalid_equipment` channel (not bare assert) — Story 004

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 002]: zone_synergy formula + perimeter normalization
- [Story 003]: spaciousness formula
- [Story 004]: preview==commit equivalence, invalid-equipment handling via strict_mode channel

---

## QA Test Cases

*Written by qa-lead at story creation. The developer implements against these — do not invent new test cases during implementation.*

- **AC1**: 纯函数确定性
  - Given: fixed snapshot S with N placed instances
  - When: evaluate(S) called 100 times
  - Then: every call returns bit-identical Dictionary values; no variance/order dependence/RNG
  - Edge cases: repeated calls between other evaluations (no hidden state)

- **AC8**: 非负性
  - Given: any valid snapshot including worst-case cross-zone clutter
  - When: evaluate() runs
  - Then: comfort_i, zone_synergy_i, spaciousness_i, total_i ≥ 0 for every instance
  - Edge cases: cross-zone adjacency (neutral 0, never negative); mixed zones

- **AC11**: 空布局
  - Given: get_placed_instances() returns []
  - When: evaluate() runs
  - Then: returns empty Dictionary, no error
  - Edge cases: null-ish empty vs absent field

- **AC12**: 单实例
  - Given: exactly 1 placed instance, no neighbors
  - When: evaluate() runs
  - Then: zone_synergy_i == 0.0; total_i == comfort_i + spaciousness_i
  - Edge cases: spaciousness computes normally (usually high)

- **AC13**: 静态只读
  - Given: zone_rules.gd source
  - When: scanned (grep/static analysis)
  - Then: references only documented GridStateReader methods + EquipmentCatalog.get_definition; no member-position/queue-length/dynamic-state API
  - Edge cases: no references to Congestion, MemberSim, or any live data accessor

- **AC14**: 输出形状
  - Given: any valid snapshot
  - When: evaluate() returns
  - Then: every value Dictionary contains exactly {comfort, zone_synergy, spaciousness, total}
  - Edge cases: missing key never happens; extra key never added

- **AC16**: 非连续 id 排序
  - Given: placed instances with instance_ids 2, 7, 40
  - When: evaluate() iterates
  - Then: iteration in ascending instance_id order
  - Edge cases: Dictionary insertion order differs from id order (implementation sorts)

---

## Test Evidence

**Story Type**: Logic
**Required evidence**:
- `tests/unit/zone_rules/evaluate_purity_test.gd` — must exist and pass (AC1, AC8, AC11, AC12, AC14, AC16)

**Status**: [ ] Not yet created

---

## Dependencies

- Depends on: grid-system epic (GridStateReader + `get_placed_instances`), equipment-catalog epic (`get_definition`, `zone_membership`, `effects` comfort)
- Unlocks: Story 002 (zone_synergy), Story 003 (spaciousness), Story 004 (preview equivalence)
