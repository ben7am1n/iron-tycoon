# Story 006: GridStateReader and GridSnapshot

> **Epic**: grid-system
> **Status**: Ready
> **Layer**: Foundation
> **Type**: Logic
> **Estimate**: M — 1 day (Sprint 1)
> **Manifest Version**: 2026-07-23
> **Last Updated**: [set by /dev-story when implementation begins]

## Context

**GDD**: `design/gdd/grid-system.md`
**Requirements**: `TR-GS-023` through `TR-GS-025`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0003: GridStateReader Contract
**ADR Decision Summary**: GridStateReader defines a read-only abstract base class (is_solid, get_occupant_id, get_access_cells, get_dimensions). GridSystem subclasses it and adds private write methods (commit, clear, can_place). GridSnapshot subclasses it and provides speculative views via delta dictionaries (_adds, _removes). ZoneRules.evaluate(snapshot: GridStateReader) uses the abstract type — cannot distinguish real from speculative. @abstract is non-functional on RefCounted in 4.7.1 — use manual _init() guard with push_error() + safe defaults as the fallback.

**Engine**: Godot 4.7.1 | **Risk**: MEDIUM
**Engine Notes**: @abstract on RefCounted is verified non-functional in 4.7.1 (Node/Control only). The fallback protocol from GDD OQ#3 must be followed: if override omission is not a hard error, every abstract method stub must include push_error() + a safe default return value. GDScript has no real access control — _commit_in_place/_clear_in_place are convention-protected (underscore prefix) and type-narrowing-protected (GridStateReader type hides them).

**Control Manifest Rules (Core layer)**:
- Required: GridStateReader defines the read-only contract (is_solid, get_occupant_id, get_access_cells, get_dimensions, get_placed_instances). GridSystem subclasses GridStateReader — write methods exist ONLY on GridSystem. PlacedInstance is a typed RefCounted DTO, not a Dictionary. PlacedInstance fields are immutable after construction.
- Forbidden: Never use duck-typing for the grid read surface — consumers must depend on typed GridStateReader parameter; never expose GridSystem's internal reverse_index Dictionary or _occupant_id array as public API

---

## Acceptance Criteria

*From GDD `design/gdd/grid-system.md`, scoped to this story:*

- [ ] AC-GSR.1 [BLOCKING][Logic] GIVEN identical underlying grid state, one from GridSystem instance and one from its get_snapshot(), WHEN calling same set of is_solid/get_occupant_id/get_access_cells/get_dimensions on both, THEN return values are pairwise equal
- [ ] AC-GSR.2 [BLOCKING][Logic] GIVEN width=13,height=10 grid, WHEN calling get_dimensions(), THEN returns Vector2i(13,10), and get_snapshot() afterward preserves dimensions
- [ ] AC-GSR.3 [ADVISORY][Code Review] GIVEN a variable typed GridStateReader holding a GridSnapshot instance, WHEN statically checking callable methods, THEN _commit_in_place/_clear_in_place are NOT in GridStateReader's declared method list
- [ ] AC-X.2 [BLOCKING][Logic] GIVEN a get_snapshot() result, WHEN afterward executing commit/clear on the real grid, THEN the previously-obtained snapshot object's values do NOT change — deep copy semantics
- [ ] AC-X.3 [BLOCKING][Logic] GIVEN real grid state S, WHEN calling get_speculative_snapshot(deltas) and performing arbitrary _commit_in_place/_clear_in_place on the returned snapshot, THEN real grid state still equals S (verified with get_snapshot()), AND no grid_changed emitted

---

## Implementation Notes

*Derived from ADR-0003 + GDD "GridStateReader — 共享只读契约":*

**GridStateReader abstract base class:**
```gdscript
class_name GridStateReader extends RefCounted

# Use manual _init() guard — @abstract is non-functional on RefCounted in 4.7.1
func _init() -> void:
    if get_script() == GridStateReader:
        push_error("GridStateReader is abstract — do not instantiate directly")
        return

# Read-only contract methods — subclasses MUST override
func is_solid(cell: Vector2i) -> bool:
    push_error("GridStateReader.is_solid not overridden by subclass")
    return true  # safe default: "outside is solid" (prevents pathfinding into void)

func get_occupant_id(cell: Vector2i) -> int:
    push_error("GridStateReader.get_occupant_id not overridden by subclass")
    return -1

func get_access_cells(instance_id: int) -> Array[Vector2i]:
    push_error("GridStateReader.get_access_cells not overridden by subclass")
    return []

func get_dimensions() -> Vector2i:
    push_error("GridStateReader.get_dimensions not overridden by subclass")
    return Vector2i.ZERO

func get_placed_instances() -> Array[PlacedInstance]:
    push_error("GridStateReader.get_placed_instances not overridden by subclass")
    return []
```

**OQ#3 fallback protocol:** The push_error() stubs ensure that if a subclass misses an override, the failure is LOUD (push_error) + safe (conservative defaults), not silent. If future Godot versions make @abstract functional on RefCounted, these stubs can be replaced with @abstract decorators.

**GridSystem extends GridStateReader:**
- Overrides all read methods (is_solid, get_occupant_id, get_access_cells, get_dimensions, get_placed_instances)
- Adds private write methods: commit(), clear(), can_place()
- Adds private serialize(), deserialize()
- Injected via SimulationOrchestrator — extends RefCounted, NOT Node

**GridSnapshot extends GridStateReader:**
- Constructed from base GridStateReader + Array[PlacementDelta]
- PlacementDelta = {is_removal: bool, instance_id: int, footprint_cells, access_cells}
- Stores internal _adds and _removes dictionaries (delta maps)
- Read methods check deltas first, fall back to base reader
- Private _commit_in_place / _clear_in_place (underscore = convention only)

**get_speculative_snapshot construction:**
```gdscript
func get_speculative_snapshot(deltas: Array[PlacementDelta]) -> GridSnapshot:
    var snap := get_snapshot()  # deep copy of real state
    for delta in deltas:
        if delta.is_removal:
            snap._clear_in_place(delta.instance_id)
        else:
            snap._commit_in_place(delta.instance_id, delta.footprint_cells, delta.access_cells)
    return snap
```
- Operates on COPY only — real grid untouched
- No grid_changed during preview
- No can_place re-validation in snapshot (delta is pre-validated by PlacementSystem)

**Type narrowing protection:**
- All public APIs returning snapshots type them as GridStateReader
- ZoneRules.evaluate(snapshot: GridStateReader) — abstract type, can't distinguish real vs speculative
- _commit_in_place/_clear_in_place are invisible through the GridStateReader type

**PlacedInstance DTO:**
```gdscript
class_name PlacedInstance extends RefCounted
var instance_id: int
var equipment_id: String
var anchor: Vector2i
var rotation: int
var footprint_cells: Array[Vector2i]
var access_cells: Array[Vector2i]
# Immutable after construction — enforced by convention (GDScript has no readonly modifier)
# Violating this corrupts both base grid and all in-flight snapshots
```

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 001]: Cell data model — GridStateReader delegates to this
- [Story 002]: is_solid() implementation — defined on GridSystem, consumed through abstract interface
- [Story 004]: can_place() — write-side API, NOT on GridStateReader
- [Story 005]: commit/clear — write-side API, NOT on GridStateReader
- [Story 008]: grid_changed signal — emitted by commit/clear, not by snapshot

---

## QA Test Cases

- **AC-GSR.1**: 多态一致性
  - Given: same underlying grid state with 3 placed equipments
  - When: comparing is_solid, get_occupant_id, get_access_cells, get_dimensions between GridSystem and its get_snapshot()
  - Then: all return values pairwise equal for every cell in [0,width)×[0,height)
  - Edge cases: test with access_ids overlap (two equipments share access cell); test after commit+clear sequence

- **AC-GSR.2**: get_dimensions
  - Given: width=13, height=10 grid
  - When: get_dimensions()
  - Then: returns Vector2i(13,10); snapshot preserves same dimensions
  - Edge cases: test after grid resize (not MVP — but assert if resize not supported)

- **AC-GSR.3**: 写方法不可从基类访问（代码审查）
  - Given: GridStateReader-typed variable holding a GridSnapshot
  - When: static code check or review checklist
  - Then: _commit_in_place/_clear_in_place not in declared methods on GridStateReader
  - Edge cases: this is ADVISORY/code-review — GDScript doesn't enforce access control

- **AC-X.2**: 深拷贝语义
  - Given: snapshot S taken at state T
  - When: real grid mutates via commit/clear to state T'
  - Then: S values unchanged (reflects T, not T')
  - Edge cases: verify with access_ids (Dictionary should be duplicated, not shared reference)

- **AC-X.3**: 推测快照不触碰真实存储
  - Given: real grid state S (with known snapshot)
  - When: get_speculative_snapshot(some_deltas), then mutate the returned snapshot arbitrarily
  - Then: real grid state still equals S (compare full snapshots), no grid_changed emitted
  - Edge cases: test with deltas that add and remove the same piece; test with empty deltas array

---

## Test Evidence

**Story Type**: Logic
**Required evidence**:
- `tests/unit/grid_system/grid_state_reader_snapshot_test.gd` — must exist and pass

**Status**: [ ] Not yet created

---

## Dependencies

- Depends on: Story 001 (cell data model), Story 002 (is_solid), Story 005 (commit/clear — without these, no real grid state to snapshot from)
- Unlocks: Story 008 (snapshot use in drag preview performance test)
