# Story 001: Grid Core — Cell Data Model

> **Epic**: grid-system
> **Status**: Complete
> **Layer**: Foundation
> **Type**: Logic
> **Estimate**: S — 1 session (≤2h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-07-25

## Context

**GDD**: `design/gdd/grid-system.md`
**Requirements**: `TR-GS-001` through `TR-GS-009`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0002: Storage Format
**ADR Decision Summary**: GridSystem internal storage uses PackedInt32Array (occupant_id, indexed by flat_index y*width+x), PackedByteArray (buildable, static), and sparse Dictionary (access_ids). All 64-bit ints use hex strings in JSON; FileAccess.store_*() returns bool since Godot 4.4 — every write must check the return value.

**Engine**: Godot 4.7.1 | **Risk**: LOW
**Engine Notes**: PackedInt32Array.duplicate() measured at 0.04μs for 3600 cells — negligible copy cost. Dictionary for access_ids is sparse by design (most cells empty). `@abstract` non-functional on RefCounted in 4.7.1 — verified.

**Control Manifest Rules (Foundation layer)**:
- Required: Use two-phase init for all simulation systems; SimSystem base class extends RefCounted with manual _init() guard; init() must only be called once per system; every public method must guard against use-before-init
- Forbidden: Never use Autoload singletons for system access; never use @abstract on RefCounted; never use _init() with typed parameters on RefCounted for DI; never expose internal storage as public API (all reads through GridStateReader)
- Guardrail: All 12 systems + orchestrator init < 1ms at boot

---

## Acceptance Criteria

*From GDD `design/gdd/grid-system.md`, scoped to this story:*

- [x] AC-C1.1 [BLOCKING][Logic] GIVEN a 5×5 grid, cell (2,2) has buildable=false, WHEN querying get_occupant_id((2,2)), THEN returns -1 — buildable and occupancy don't interfere with each other's reads
- [x] AC-C1.2 [BLOCKING][Logic] GIVEN an initialized GridSystem instance (MVP mode), WHEN set_buildable() is called after level load completes, THEN the call is rejected with push_error(), grid buildable state unchanged
- [x] AC-C2.1 [BLOCKING][Logic] GIVEN empty grid, WHEN committing id=1 to a cell then committing id=2 to the same cell without clearing first, THEN second commit rejected, occupant_id still 1 — proves mutually-exclusive single-value semantics
- [x] AC-C2.2 [BLOCKING][Logic] GIVEN empty grid, WHEN commit(id=1, access=[cell]) then commit(id=2, access=[same cell]) with different footprints, THEN both succeed, access_ids returns [1, 2] — proves non-mutually-exclusive multi-value semantics
- [x] AC-C3.1 [BLOCKING][Logic] GIVEN anchor_cell=(5,5), rotation=0°, WHEN get_transformed_cells, THEN footprint world cells exactly {(5,5),(6,5),(5,6),(6,6)}, access = {(5,7)}
- [x] AC-D2.1 [BLOCKING][Logic] GIVEN width=13,height=10, cell (6,3) has known value, WHEN writing (5,3) then reading (6,3), THEN (6,3) value unchanged — proves flat_index doesn't miscompute causing cross-row writes

---

## Implementation Notes

*Derived from ADR-0001 + ADR-0002 Implementation Guidelines:*

**Storage layout:**
- `occupant_id`: PackedInt32Array, indexed by `flat_index = row * width + col`, initialized to -1 (empty sentinel)
- `buildable`: PackedByteArray, same flat_index scheme, 0/1 values, set once at level load then read-only
- `access_ids`: Dictionary[Vector2i, Array[int]] — sparse, only populated for cells that are someone's access cell
- `occupant_id` and `access_ids` are completely independent fields — never merge them

**Class structure:**
- `GridSystem extends GridStateReader` (GridStateReader is RefCounted-based, covered in Story 006)
- Uses manual `_init()` guard (not `@abstract` — non-functional on RefCounted in 4.7.1)
- Constructor: store width, height; allocate PackedInt32Array and PackedByteArray at width*height

**Key invariants to enforce:**
- `occupant_id = -1` means empty — never use `0` as empty sentinel
- `occupant_id = 0` is legal (first piece placed) — NEVER truthy-check it
- `buildable` set exactly once at level load — runtime calls to `set_buildable()` must `push_error()` and no-op
- Origin (0,0) at room bounding-box top-left, col right-positive, row down-positive
- Orthogonal square grid (CELL_SHAPE_SQUARE) — isometric is art-only

**Forbidden patterns:**
- Never store equipment type or zone membership in GridSystem — only integer occupant_id
- Never use Autoload/singleton pattern for GridSystem — injected via SimulationOrchestrator

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 002]: is_solid() formula, grid_to_world/world_to_grid coordinate conversion, occupant_id=0 falsy trap
- [Story 003]: rotation transform (4 branches), declared_bounds, TransformedFootprint composite
- [Story 004]: can_place() with 5 FAIL codes, placement validation logic
- [Story 005]: commit/clear operations, reverse index, instance_id lifecycle
- [Story 006]: GridStateReader abstract base class, GridSnapshot speculative views
- [Story 007]: serialize/deserialize with two-phase validate-then-commit
- [Story 008]: grid_changed signal, integration tests, performance smoke tests

---

## QA Test Cases

*Written by qa-lead at story creation. The developer implements against these — do not invent new test cases during implementation.*

- **AC-C1.1**: buildable 与 occupancy 读取互不干扰
  - Given: 5×5 grid, cell (2,2) buildable=false
  - When: calling get_occupant_id((2,2))
  - Then: returns -1 (buildable doesn't affect occupancy read)
  - Edge cases: also verify buildable state unchanged after occupant_id writes

- **AC-C1.2**: set_buildable 运行时不可调用
  - Given: an initialized GridSystem after level load
  - When: calling set_buildable() on any cell
  - Then: push_error() fires, buildable array unchanged
  - Edge cases: test multiple cell positions, test both true→false and false→true

- **AC-C2.1**: occupant_id 互斥单值
  - Given: empty grid, commit(id=1, footprint=[cell_A]) succeeds
  - When: commit(id=2, footprint=[cell_A]) without clearing first
  - Then: second commit rejected, cell_A occupant_id still 1
  - Edge cases: commit to overlapping but not identical footprint sets

- **AC-C2.2**: access_ids 非互斥多值
  - Given: empty grid, commit(id=1, access=[cell_B])
  - When: commit(id=2, access=[cell_B]) with different footprint
  - Then: both succeed, cell_B access_ids = [1, 2]
  - Edge cases: order stability (same result regardless of commit order)

- **AC-C3.1**: 锚点约定 + 0° 变换
  - Given: 2×2 footprint=[(0,0),(1,0),(0,1),(1,1)], access=[(0,2)], anchor=(5,5), rotation=0°
  - When: calling get_transformed_cells
  - Then: footprint world cells = {(5,5),(6,5),(5,6),(6,6)}, access = {(5,7)}
  - Edge cases: verify anchor is always the declared bounding box top-left cell

- **AC-D2.1**: 扁平索引无跨行泄漏
  - Given: width=13,height=10, cell (6,3) has known value
  - When: writing (5,3) then reading (6,3)
  - Then: (6,3) retains its original value (flat_index = 3*13+6 = 45, not confused with 5*13+3 = 43... wait, 5,3 = 3*13+5=44, 6,3 = 3*13+6=45 — adjacent indices should not cross-contaminate)
  - Edge cases: test at row boundaries (last cell of row N vs first cell of row N+1)

---

## Test Evidence

**Story Type**: Logic
**Required evidence**:
- `tests/unit/grid_system/grid_core_cell_data_test.gd` — must exist and pass

**Status**: [x] Created and passing — 65 assertions, 0 failures (2026-07-25)

Verified via both entry points:
- `godot --headless --script tests/unit/grid_system/grid_core_cell_data_test.gd`
- `godot --headless --script tests/headless_runner.gd` (project CI entry point)

---

## Dependencies

- Depends on: None (first story in epic)
- Unlocks: Story 002 (solidity formula needs cell data model), Story 003 (rotation needs cell data + declared_bounds)

---

## Completion Notes

**Completed**: 2026-07-25
**Criteria**: 6/6 passing (no deferred items). Test-criterion traceability 100% — every AC maps to a named test function.
**Test Evidence**: Logic story — `tests/unit/grid_system/grid_core_cell_data_test.gd`, 65 assertions / 0 failures (grew from 31 during code review; +34 assertions closed previously-untested guard paths).
**Code Review**: Complete — `/code-review` verdict CHANGES REQUIRED → fixes applied → re-review APPROVED.

### Fixes applied during code review

1. **BUG-GS-001 (correctness)**: `_assert_initialized()` only logged via `push_error()` and never halted execution, so every public method fell through to its body when called before `init()`. Pre-init "safe defaults" were incidental (they relied on `_width`/`_height` defaulting to 0), and `get_transformed_cells()` — which never reads those fields — silently returned a fully computed, valid-looking result. The guard now returns `bool` and all 14 public methods early-return their documented safe default.
2. **ADR-0001 compliance**: `GridSystem` now genuinely `extends SimSystem` instead of duplicating `_initialized`/`_post_init()`/`_assert_initialized()`. `sim_system.gd` was missing its `class_name SimSystem` declaration entirely, which is why the inheritance had been bypassed.
3. **`SimSystem` completeness**: added the ADR-0001 §2 manual `_init()` abstract-instantiation guard and `system_name()` — both specified by ADR-0001 / control-manifest but absent from the original implementation. Closes ADR-0001 Validation Criterion #1.
4. **Sentinel collision**: `commit_occupant(cell, -1)` previously returned `true` while leaving the cell indistinguishable from empty. Now rejected.
5. **Dimension validation**: `init()` now rejects non-positive width/height without consuming the initialized state, so a caller can retry.

### Engine finding (Godot 4.7.1)

`SimSystem` deliberately does **not** declare a shared `init(...)`. Godot 4.7.1's GDScript type checker raises a hard **parse error** ("The function signature doesn't match the parent") when a subclass overrides a same-named parent method with a different parameter list. Since every system needs its own typed `init(...)` (ADR-0001), a base-class `init()` breaks compilation. Subclasses call `_mark_initialized()` internally instead. Verified by isolated reproduction. Note this is a constraint on the *helper naming*, not a flaw in ADR-0001 — ADR-0001 never declared `init()` on the base class.

### Advisory deviations (logged to `docs/tech-debt-register.md`)

- `GridSystem extends SimSystem`, not `GridStateReader` — deferred to Story 006 (that class does not exist yet). ADR-0003's Migration Plan says "from the start."
- `SimSystem` helper names (`_mark_initialized()`, `_assert_initialized()`) are not in ADR-0001's Key Interfaces; they implement ADR-mandated behaviour under new names.
- Untyped `Array` params/returns in `get_access_ids()`, `set_buildable_bulk()`, `get_transformed_cells()` violate the project static-typing standard.
- `.gitignore:43` forces the editor-generated `.godot/global_script_class_cache.cfg` into version control.

### Out-of-scope change (approved)

`prototypes/gym-flow-vertical-slice/src/core/grid_system.gd` — removed a colliding `class_name GridSystem`. Once real class registration was made to work, this shadowed the production class and broke `tests/smoke/core_smoke_test.gd` compilation. Verified against a clean baseline that this failure did not pre-exist.

### Pre-existing issues, NOT introduced by this story

- `tests/integration/core_loop/core_loop_test.gd` fails to load — broken `res://../../prototypes/...` preload paths.
- `tests/headless_runner.gd`'s `run_all()` re-invokes `_init()`, double-counting assertions (also affects `core_smoke_test.gd`).
- `tests/smoke/core_smoke_test.gd` preloads from `prototypes/`, violating `.claude/rules/prototype-code.md` ("No production code may reference or import from `prototypes/`").
