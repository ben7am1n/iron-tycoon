# Story 001: Pure evaluate() and Effect Vocabulary

> **Epic**: zone-rules
> **Status**: Complete — 2026-08-03 (QA 终审 PASS, t_f1010c0a)
> **Layer**: Feature
> **Type**: Logic
> **Estimate**: M — 2 sessions (≤4h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-03

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

- [x] AC1 [WB] GIVEN a fixed snapshot S with N placed instances, WHEN `evaluate(S)` is called 100 times in sequence, THEN every call returns bit-identical Dictionary values (no variance, no time/order dependence, no RNG)
- [x] AC8 GIVEN any valid snapshot including worst-case cross-zone clutter, WHEN `evaluate()` runs, THEN `comfort_i, zone_synergy_i, spaciousness_i, total_i ≥ 0` for every instance (never negative)
- [x] AC11 GIVEN `get_placed_instances()` returns `[]`, WHEN `evaluate()` runs, THEN it returns an empty Dictionary
- [x] AC12 GIVEN exactly 1 placed instance with no neighbors, WHEN `evaluate()` runs, THEN `zone_synergy_i == 0.0` and `total_i == comfort_i + spaciousness_i`
- [x] AC13 [WB] GIVEN the implementation file `zone_rules.gd`, WHEN its source is scanned (grep / static analysis), THEN it references **only** the documented `GridStateReader` read contract methods (`get_placed_instances`, `is_solid`, `get_dimensions`) and `EquipmentCatalog.get_definition` — no member-position, queue-length, or other dynamic-state API appears anywhere in the file
- [x] AC14 GIVEN any valid snapshot, WHEN `evaluate()` returns, THEN every value Dictionary contains **exactly** `{comfort, zone_synergy, spaciousness, total}` — no missing/extra keys
- [x] AC16 GIVEN placed instances whose `instance_id`s are non-contiguous (e.g. 2, 7, 40), WHEN `evaluate()` iterates, THEN iteration is in ascending `instance_id` order

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
  - **QA 回填 (2026-08-03)**: PASS — `_test_ac1_pure_function_100_calls_bit_identical`（1+99 次连续调用 `next == first`）+ `_test_ac1_interleaved_calls_no_hidden_state`（A→B→B→A 复评位等同）

- **AC8**: 非负性
  - Given: any valid snapshot including worst-case cross-zone clutter
  - When: evaluate() runs
  - Then: comfort_i, zone_synergy_i, spaciousness_i, total_i ≥ 0 for every instance
  - Edge cases: cross-zone adjacency (neutral 0, never negative); mixed zones
  - **QA 回填 (2026-08-03)**: PASS — 最坏杂乱布局（4 异区共邻 + 无 comfort tag 件 + 多区件）逐行四键全非负；无 tag 件 comfort==0.0

- **AC11**: 空布局
  - Given: get_placed_instances() returns []
  - When: evaluate() runs
  - Then: returns empty Dictionary, no error
  - Edge cases: null-ish empty vs absent field
  - **QA 回填 (2026-08-03)**: PASS — `[]` → `{}`（`result is Dictionary && result.is_empty() && size()==0`），无错误

- **AC12**: 单实例
  - Given: exactly 1 placed instance, no neighbors
  - When: evaluate() runs
  - Then: zone_synergy_i == 0.0; total_i == comfort_i + spaciousness_i
  - Edge cases: spaciousness computes normally (usually high)
  - **QA 回填 (2026-08-03)**: PASS — `zone_synergy == 0.0` 精确相等；`total == comfort + spaciousness`（spaciousness 本期为占位 0.0）；comfort 0.6 直通

- **AC13**: 静态只读
  - Given: zone_rules.gd source
  - When: scanned (grep/static analysis)
  - Then: references only documented GridStateReader methods + EquipmentCatalog.get_definition; no member-position/queue-length/dynamic-state API
  - Edge cases: no references to Congestion, MemberSim, or any live data accessor
  - **QA 回填 (2026-08-03)**: PASS — 独立 grep 复核：仅 `get_placed_instances`(L52) + `get_definition`(L89)（`is_solid`/`get_dimensions` 属白名单但本期不需要）；禁词 get_occupant_id/get_access_cells/get_member_position/get_queue_length/get_position/Congestion/MemberSim 零命中

- **AC14**: 输出形状
  - Given: any valid snapshot
  - When: evaluate() returns
  - Then: every value Dictionary contains exactly {comfort, zone_synergy, spaciousness, total}
  - Edge cases: missing key never happens; extra key never added
  - **QA 回填 (2026-08-03)**: PASS — 每行 `size()==4` 且四键 `has()` 全中（无缺键、无增键）；3 实例 → 3 行

- **AC16**: 非连续 id 排序
  - Given: placed instances with instance_ids 2, 7, 40
  - When: evaluate() iterates
  - Then: iteration in ascending instance_id order
  - Edge cases: Dictionary insertion order differs from id order (implementation sorts)
  - **QA 回填 (2026-08-03)**: PASS — 输入打乱为 [7, 40, 2]，输出 `result.keys() == [2, 7, 40]`（实现显式 `sort_custom` 升序）

---

## Test Evidence

**Story Type**: Logic
**Required evidence**:
- `tests/unit/zone_rules/evaluate_purity_test.gd` — must exist and pass (AC1, AC8, AC11, AC12, AC14, AC16)

**Status**: [x] Complete — 2026-08-03

`tests/unit/zone_rules/evaluate_purity_test.gd` exists and passes: 20/20
assertions standalone (exit 0), covering AC1 (100 sequential bit-identical
calls + interleaved no-hidden-state edge), AC8 (worst-case cross-zone
clutter non-negativity), AC11 (empty layout → empty Dictionary), AC12
(single instance zone_synergy == 0.0, total == comfort + spaciousness),
AC13 (static source scan — only get_placed_instances + get_definition,
zero forbidden dynamic-state tokens; independently re-grepped by QA),
AC14 (exactly the 4 keys per row), AC16 (shuffled [7,40,2] input →
ascending [2,7,40] keys). Registered in `tests/headless_runner.gd`
TEST_FILES. Full headless suite run twice independently by QA: 2702
passed / 0 failed, RESULT PASSED, 0 SCRIPT ERROR, exit 0, per-file
results identical across both runs (51 files, evaluate_purity 20/0 both).

---

## Dependencies

- Depends on: grid-system epic (GridStateReader + `get_placed_instances`), equipment-catalog epic (`get_definition`, `zone_membership`, `effects` comfort)
- Unlocks: Story 002 (zone_synergy), Story 003 (spaciousness), Story 004 (preview equivalence)
