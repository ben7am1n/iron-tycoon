# Story 005: Commit, Clear, and Reverse Index

> **Epic**: grid-system
> **Status**: Complete
> **Layer**: Foundation
> **Type**: Logic
> **Estimate**: M — 1 day (Sprint 1)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-02

## Context

**GDD**: `design/gdd/grid-system.md`
**Requirements**: `TR-GS-017`, `TR-GS-018`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0003: GridStateReader Contract
**ADR Decision Summary**: commit() writes occupant_id and access_ids, builds a reverse index entry (instance_id → PlacementRecord{footprint_cells, access_cells, rotation}), and emits grid_changed once. clear() looks up the reverse index to find occupied cells (NO full-grid scan), clears them, removes the index entry, and emits grid_changed. The reverse index is MANDATORY — clear() must use O(footprint+cells) not O(grid). instance_id is consumed by GridSystem (allocated by PlacementSystem); it must be >= 0, monotonic, never reused within a session.

**Engine**: Godot 4.7.1 | **Risk**: MEDIUM
**Engine Notes**: instance_id = 0 is legal (first piece placed) — GDScript truthy checks are a common bug source. PackedInt32Array writes are O(1) by index. Dictionary (reverse index) lookups are amortized O(1). access_ids Array removal is O(k) where k = number of ids at that cell — expected to be single digits in MVP.

**Control Manifest Rules (Foundation layer)**:
- Required: All public methods must guard against use-before-init; init() stores references only; every signal emit must match declared argument count exactly
- Forbidden: Never expose GridSystem's internal reverse_index Dictionary as public API; never use Autoload
- Guardrail: Commit-to-grid must succeed at 130 cells MVP

---

## Acceptance Criteria

*From GDD `design/gdd/grid-system.md`, scoped to this story:*

- [x] AC-C7.1 [BLOCKING][Logic] GIVEN commit(id=9, ...) succeeds, WHEN immediately clear(9), THEN related cells occupant_id back to -1, access_ids remove 9 — proves reverse index correctly used
- [x] AC-C7.2 [BLOCKING][Logic] GIVEN id=9 already in reverse index, WHEN commit(9, ...) again (different cells), THEN call rejected with push_error(), old record NOT overwritten, old cell state unchanged
- [x] AC-C7.3 [BLOCKING][Logic] GIVEN id=99 never committed, WHEN calling clear(99), THEN push_error() fires, full-grid snapshot before and after completely equal, AND grid_changed NOT emitted
- [x] AC-C7.7 [BLOCKING][Logic] GIVEN empty grid, WHEN calling commit(instance_id=-1, ...) or commit(instance_id=-5, ...), THEN each case push_error() and reject commit, full-grid snapshot before/after equal, no grid_changed
- [x] AC-C7.8 [ADVISORY][Code Review] GIVEN an id that was committed then cleared, WHEN committing same id again for a DIFFERENT equipment, THEN GridSystem accepts normally — this IS expected behavior; GridSystem CANNOT detect "reuse", this is the allocator's contract (PlacementSystem)

---

## Implementation Notes

*Derived from ADR-0003 + GDD §C.7:*

**commit(instance_id, footprint_cells, access_cells, rotation):**
```gdscript
func commit(instance_id: int, footprint_cells: Array[Vector2i], access_cells: Array[Vector2i], rotation: int) -> void:
    # Guard checks
    assert(instance_id >= 0, "instance_id must be >= 0; got %d" % instance_id)
    if _reverse_index.has(instance_id):
        push_error("commit: instance_id %d already in reverse index" % instance_id)
        return
    
    # Write footprint occupancy
    for fc in footprint_cells:
        assert(_in_bounds(fc), "commit: footprint cell %s out of bounds" % fc)
        occupant_id[_flat_index(fc)] = instance_id
    
    # Write access ids
    for ac in access_cells:
        assert(_in_bounds(ac), "commit: access cell %s out of bounds" % ac)
        var arr: Array = access_ids.get(ac, [])
        arr.append(instance_id)
        access_ids[ac] = arr
    
    # Write reverse index (the single source of truth for serialization)
    _reverse_index[instance_id] = PlacementRecord.new(footprint_cells, access_cells, rotation)
    
    # Signal — once per commit, not per cell
    grid_changed.emit(footprint_cells, access_cells)
```

**clear(instance_id):**
```gdscript
func clear(instance_id: int) -> void:
    if not _reverse_index.has(instance_id):
        push_error("clear: instance_id %d not in reverse index" % instance_id)
        return
    
    var record: PlacementRecord = _reverse_index[instance_id]
    
    # Clear footprint
    for fc in record.footprint_cells:
        occupant_id[_flat_index(fc)] = -1
    
    # Remove from access_ids (O(k) per cell, k = small in MVP)
    for ac in record.access_cells:
        var arr: Array = access_ids.get(ac, [])
        var idx := arr.find(instance_id)
        if idx != -1:
            arr.remove_at(idx)
        if arr.is_empty():
            access_ids.erase(ac)  # keep dictionary sparse
        else:
            access_ids[ac] = arr
    
    # Remove reverse index entry
    _reverse_index.erase(instance_id)
    
    # Signal
    grid_changed.emit(record.footprint_cells, record.access_cells)
```

**PlacementRecord DTO:**
```gdscript
class PlacementRecord extends RefCounted:
    var footprint_cells: Array[Vector2i]
    var access_cells: Array[Vector2i]
    var rotation: int
    
    func _init(p_footprint: Array[Vector2i], p_access: Array[Vector2i], p_rotation: int) -> void:
        footprint_cells = p_footprint
        access_cells = p_access
        rotation = p_rotation
```

**Key invariants:**
- Reverse index IS the write path for serialization — serialize() dumps it, deserialize() rebuilds from it
- No full-grid scan in clear() — that's why reverse_index exists
- instance_id < 0 rejected (protects the -1 sentinel)
- Duplicate instance_id in commit() rejected (prevents overwrite-leak where old cells become permanently orphaned)
- commit() is called after can_place() passes — commit itself doesn't re-validate (trusts caller)

**instance_id lifecycle contract (cross-system, documented here for GridSystem's enforcement):**
- Allocated by PlacementSystem (monotonic counter, never reused within session)
- Consumed by GridSystem as occupant_id — stored, never allocated
- GridSystem CANNOT detect reuse (a recycled id looks identical to a new one)
- GridSystem's only defense: reject negative ids, reject duplicate-while-active ids
- The "never reuse" contract is PlacementSystem's responsibility — see AC-C7.8

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 001]: Room geometry setup (buildable array), origin convention
- [Story 004]: can_place() validation — commit trusts that can_place already passed
- [Story 007]: serialize/deserialize — reverse index is the source of truth; serialization reads it, not the arrays
- [Story 008]: grid_changed signal payload and subscriber behavior — the emit call is here, the contract is tested there

---

## QA Test Cases

- **AC-C7.1**: commit→clear 往返
  - Given: commit(id=9, fp=[(1,1)], access=[(1,2)]) succeeds
  - When: immediately clear(9)
  - Then: (1,1) occupant_id back to -1, (1,2) access_ids no longer contains 9
  - Edge cases: clear an equipment with 2×2 footprint; clear an equipment with 0 access cells

- **AC-C7.2**: 重复 id commit 被拒
  - Given: id=9 already committed
  - When: commit(9, different_footprint)
  - Then: push_error(), old record untouched, old cells still occupied by 9
  - Edge cases: verify the reject is BEFORE any cell writes (atomic decision)

- **AC-C7.3**: 清除不存在的 id
  - Given: id=99 never committed
  - When: clear(99)
  - Then: push_error(), full snapshot before==after, grid_changed NOT emitted
  - Edge cases: test with id=-1 (should error on commit, not on clear semantics)

- **AC-C7.7**: 负 instance_id 拒绝
  - Given: empty grid
  - When: commit(-1, ...) and commit(-5, ...)
  - Then: each push_error() and reject, no writes, no signal
  - Edge cases: -1 is the sentinel value — test it specifically; also test -MAX_INT

- **AC-C7.8**: id 复用不可检测（文档性）
  - Given: commit(id=5), clear(5), then commit(id=5) for different equipment
  - When: the second commit
  - Then: GridSystem accepts it (no error) — this is DOCUMENTED EXPECTED BEHAVIOR for a reused id
  - Edge cases: this AC is ADVISORY/Code Review only — it documents a capability boundary, not a pass/fail test

---

## Test Evidence

**Story Type**: Logic
**Required evidence**:
- `tests/unit/grid_system/grid_commit_clear_test.gd` — must exist and pass

**Status**: [x] Created and passing — 59 assertions, 0 failures (2026-08-02)

---

## Completion Notes
**Completed**: 2026-08-02
**Criteria**: 4/4 blocking ACs passing (AC-C7.1, AC-C7.2, AC-C7.3, AC-C7.7) plus AC-C7.8 (advisory — behaviorally asserted and documented), the instance_id=0 legal pitfall, before-init guard paths, and the once-per-commit/clear grid_changed signal contract.
**Deviations**:
- The implementation sketch guards instance_id < 0 with `assert()`. Implemented with `push_error()` + return instead, because GDD §C.7 ("commit() 收到 instance_id < 0 → push_error() 并拒绝提交") and AC-C7.7 both literally require push_error(), assert() aborts the current function frame, and assert() is compiled out of release builds while the -1 sentinel protection must be active in release too.
- PlacementRecord is a separate `class_name` DTO file (`src/systems/placement_record.gd`) rather than an inline class inside grid_system.gd, matching the repo's DTO convention (PlacementCheckResult / TransformedFootprint) — Story 007 reads the record type directly from the reverse index.
- Rotation convention decided (closes the Story 003 tech-debt handoff's Story-005 half): commit() takes the degree-valued `GridSystem.Rotation` enum; PlacementRecord.rotation stores the degree int (0/90/180/270). NOT the quarter-turn count in ADR-0003's PlacedInstance sketch — reconciliation with PlacedInstance (when Story 006 builds it) remains tracked in the tech-debt register.
- Defensive duplication (both stronger than the sketch, protecting against the GDD's silent-corruption class): PlacementRecord._init() duplicates its cell arrays so a caller reusing/mutating scratch arrays after commit() cannot corrupt the reverse index; commit()/clear() emit duplicated payload arrays so a signal subscriber mutating the payload cannot corrupt the record.
- commit() dedups access ids per cell (a duplicate access cell in the input would otherwise leave a permanently leaked access registration after clear()'s single-occurrence erase()).
- The literal "push_error() fires" clause of AC-C7.2/C7.3/C7.7 is verified via a subprocess probe (`grid_commit_clear_error_probe.gd`, Story 003's established pattern) because GDScript has no in-process push_error capture; the in-process test verifies the observable consequences (snapshot unchanged, reverse index untouched, no grid_changed).
**Test Evidence**: Logic — `tests/unit/grid_system/grid_commit_clear_test.gd` (59 assertions, 0 failures; full suite 315/315, up from 256; the only ERROR lines in the run are the 10 expected push_errors the ACs require — zero unexpected script errors; probe verified: push_error fires on all three rejection modes and NOT on the legal commit+clear control)

---

## Dependencies

- Depends on: Story 001 (cell data), Story 002 (occupant_id read/write), Story 003 (rotation transform for PlacementRecord), Story 004 (can_place — called before commit)
- Unlocks: Story 006 (snapshots depend on commit/clear for real grid state), Story 007 (serialize reads reverse index), Story 008 (grid_changed emitted by commit/clear)
