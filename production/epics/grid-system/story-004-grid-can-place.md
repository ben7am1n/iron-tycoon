# Story 004: Placement Validation — can_place

> **Epic**: grid-system
> **Status**: Complete
> **Layer**: Foundation
> **Type**: Logic
> **Estimate**: S — 0.5 day (Sprint 1)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-02

## Context

**GDD**: `design/gdd/grid-system.md`
**Requirements**: `TR-GS-015`, `TR-GS-016`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0003: GridStateReader Contract
**ADR Decision Summary**: can_place() is a pure read-only function (no side effects, no grid_changed). Returns one of 5 FAIL codes: OUT_OF_BOUNDS, BLOCKED_BY_ROOM_GEOMETRY, OVERLAPS_EXISTING_EQUIPMENT, ACCESS_OUT_OF_BOUNDS, ACCESS_BLOCKED_BY_ROOM_GEOMETRY. Access cells are NOT checked for occupant_id or access_ids overlap — access-on-footprint and access-on-access are allowed by design. The 5 codes are intentionally split between footprint and access failure modes to enable differentiated UI messages.

**Engine**: Godot 4.7.1 | **Risk**: LOW
**Engine Notes**: can_place is on the hot path (called every frame during drag preview) but operates on 130 cells and ≤9 cells per equipment — cost is negligible. No special engine considerations.

**Control Manifest Rules (Foundation layer)**:
- Required: All public methods must guard against use-before-init; init() must only be called once
- Forbidden: Never expose internal storage as public API; never use Autoload/singleton
- Guardrail: Commit-to-grid at 130 cells MVP must succeed; drag smoke test 300 calls < 50ms

---

## Acceptance Criteria

*From GDD `design/gdd/grid-system.md`, scoped to this story:*

- [x] AC-C6.1 [BLOCKING][Logic] GIVEN footprint has one cell out of bounds → FAIL: OUT_OF_BOUNDS (must trigger before other checks)
- [x] AC-C6.2 [BLOCKING][Logic] GIVEN footprint in bounds but on buildable=false cell → FAIL: BLOCKED_BY_ROOM_GEOMETRY
- [x] AC-C6.3 [BLOCKING][Logic] GIVEN footprint legal but overlaps existing occupant → FAIL: OVERLAPS_EXISTING_EQUIPMENT
- [x] AC-C6.4 [BLOCKING][Logic] GIVEN access cell out of bounds → FAIL: ACCESS_OUT_OF_BOUNDS (must return DIFFERENT error code from footprint OOB)
- [x] AC-C6.5 [BLOCKING][Logic] GIVEN any can_place call, WHEN the call completes, THEN full-grid snapshot before and after is exactly equal — can_place is pure read-only, no side effects permitted
- [x] AC-C5.2 [BLOCKING][Logic] GIVEN empty grid, WHEN two commits use identical access cell but different footprints, THEN both succeed (can_place doesn't FAIL due to access overlap)
- [x] AC-C5.3 [BLOCKING][Logic] GIVEN cell (3,3) buildable=false, WHEN can_place access set contains (3,3), THEN returns FAIL: ACCESS_BLOCKED_BY_ROOM_GEOMETRY, AND no grid writes occur
- [x] AC-C5.4 [BLOCKING][Logic] GIVEN equipment A's footprint occupies cell (4,4), WHEN equipment B's access set contains (4,4), THEN can_place returns {valid:true}, commit succeeds, (4,4) occupant_id still A, access_ids contains B
- [x] AC-C5.5 [BLOCKING][Logic] GIVEN equipment with access_cells=[] (decorative/storage), WHEN can_place and commit, THEN both succeed; grid_changed access_cells_changed is empty array (not null); get_access_cells(id) returns empty array

---

## Implementation Notes

*Derived from ADR-0003 + GDD §C.6:*

**can_place signature:**
```gdscript
enum FailCode {
    VALID = 0,
    OUT_OF_BOUNDS = 1,
    BLOCKED_BY_ROOM_GEOMETRY = 2,
    OVERLAPS_EXISTING_EQUIPMENT = 3,
    ACCESS_OUT_OF_BOUNDS = 4,
    ACCESS_BLOCKED_BY_ROOM_GEOMETRY = 5,
}

class PlacementCheckResult extends RefCounted:
    var valid: bool
    var fail_code: int  # FailCode enum value
    var fail_cell: Vector2i  # the specific cell that caused the failure (for UI highlighting)

func can_place(equipment_def: EquipmentDef, anchor_cell: Vector2i, rotation: int) -> PlacementCheckResult:
```

**Check sequence (must follow this order — early-exit on first failure):**
1. Get TransformedFootprint via `get_transformed_cells(equipment_def, rotation)`
2. Apply anchor offset: `world_fp = transformed.footprint_cells + anchor`, `world_ac = transformed.access_cells + anchor`
3. For each footprint cell fc:
   a. fc in bounds of [0,width)×[0,height) → else FAIL: OUT_OF_BOUNDS
   b. buildable[fc] == true → else FAIL: BLOCKED_BY_ROOM_GEOMETRY
   c. occupant_id[fc] == -1 → else FAIL: OVERLAPS_EXISTING_EQUIPMENT
4. For each access cell ac:
   a. ac in bounds → else FAIL: ACCESS_OUT_OF_BOUNDS
   b. buildable[ac] == true → else FAIL: ACCESS_BLOCKED_BY_ROOM_GEOMETRY
   c. DO NOT check occupant_id[ac] or access_ids[ac] — access-on-footprint and access-on-access are allowed
5. All pass → {valid: true, fail_code: VALID}

**Pure function contract:**
- can_place must NOT modify any grid state
- Verify with full snapshot comparison before/after: `get_snapshot() == get_snapshot()` after can_place
- No grid_changed signal emission
- No push_error for expected fail codes (push_error only for programming errors)

**Why access cells don't check occupancy:**
- Two equipments sharing an access cell is allowed — runtime contention handled by MemberSim/Congestion
- Access cell on another's footprint is allowed — "place it too close, see that nobody can use it" is Pillar 2
- Only hard geometric constraints (OOB, buildable=false) block access placement

**FAIL code granularity:**
- Footprint OOB vs Access OOB: different UI messages ("equipment won't fit" vs "access path extends outside room")
- Room geometry failures: same split for differentiated UI
- OVERLAPS_EXISTING_EQUIPMENT is only for footprint-on-footprint overlap

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 001]: Cell data access (occupant_id, buildable) — consumed by can_place, not implemented here
- [Story 002]: is_solid() — separate API; can_place doesn't use solidity
- [Story 003]: Rotation transform — consumed as get_transformed_cells(), not implemented here
- [Story 005]: commit() — the actual write operation; can_place is the read-before-write check
- [Story 008]: grid_changed signal — not emitted during can_place

---

## QA Test Cases

- **AC-C6.1**: footprint 越界 → OUT_OF_BOUNDS
  - Given: equipment footprint that extends past grid edge at a given anchor
  - When: can_place(def, anchor, rotation)
  - Then: returns OUT_OF_BOUNDS, fail_cell is the first OOB cell encountered
  - Edge cases: test all 4 edges independently; test corner placement that's partially OOB

- **AC-C6.2**: footprint 压墙 → BLOCKED_BY_ROOM_GEOMETRY
  - Given: valid footprint coordinates, but one cell has buildable=false
  - When: can_place
  - Then: returns BLOCKED_BY_ROOM_GEOMETRY
  - Edge cases: verify after buildable is set false on previously-distinct cell

- **AC-C6.3**: footprint 重叠 → OVERLAPS_EXISTING_EQUIPMENT
  - Given: existing equipment at some cells, new placement overlaps one cell
  - When: can_place
  - Then: returns OVERLAPS_EXISTING_EQUIPMENT
  - Edge cases: exactly-overlapping (same cells) vs partially-overlapping (one shared cell)

- **AC-C6.4**: access 越界 → ACCESS_OUT_OF_BOUNDS (不同错误码)
  - Given: footprint in bounds but access cell outside grid
  - When: can_place
  - Then: returns ACCESS_OUT_OF_BOUNDS (NOT OUT_OF_BOUNDS)
  - Edge cases: verify error code differs from footprint-OOB with assertion on the enum value itself

- **AC-C6.5**: can_place 纯函数无副作用
  - Given: any grid state
  - When: can_place called (with valid or invalid input)
  - Then: full snapshot before == full snapshot after; no signal emitted; no push_error for VALID/FAIL paths
  - Edge cases: test with valid placement too — no state mutation on success either (can_place doesn't write)

- **AC-C5.2**: access 重叠允许
  - Given: empty grid, commit(id=1, access=[cell_X]) succeeds
  - When: can_place for id=2, also with access=[cell_X]
  - Then: returns valid (no access-overlap failure)
  - Edge cases: test with 3+ equipments sharing same access cell; test after id=1 is cleared

- **AC-C5.3**: access 压墙拒绝
  - Given: cell (3,3) buildable=false
  - When: can_place where access set contains (3,3)
  - Then: ACCESS_BLOCKED_BY_ROOM_GEOMETRY, no writes
  - Edge cases: test with 0 access cells (should not check — skip loop); test with mixed (one valid access + one wall access)

- **AC-C5.4**: access 压在别人 footprint 上允许
  - Given: equipment A at cell (4,4), equipment B's access contains (4,4)
  - When: can_place B, then commit B
  - Then: valid=true, commit succeeds, (4,4) occupant_id=A, access_ids contains B
  - Edge cases: verify after clearing both that cell returns to clean state

- **AC-C5.5**: 0 个 access cells 合法
  - Given: equipment with access_cells=[]
  - When: can_place then commit
  - Then: both succeed; grid_changed access_cells_changed is [] (not null)
  - Edge cases: verify get_access_cells on this id returns []; verify Navigation doesn't need to handle this cell

---

## Test Evidence

**Story Type**: Logic
**Required evidence**:
- `tests/unit/grid_system/grid_can_place_test.gd` — must exist and pass

**Status**: [x] Created and passing — 64 assertions, 0 failures (2026-08-02)

---

## Completion Notes
**Completed**: 2026-08-02
**Criteria**: 9/9 blocking ACs passing (AC-C6.1..C6.5, AC-C5.2..C5.5), plus guard tests for before-init / empty footprint / illegal rotation
**Deviations**:
- ADR-0003's illustrative can_place(def: EquipmentDef, ...) signature uses EquipmentDef, which does not exist in src/ yet (equipment-catalog epic is out of this sprint's scope). Takes raw typed cell arrays instead, matching get_transformed_cells() — same documented deviation as declared_bounds(). Rotation typed as the degree-valued Rotation enum (consistent with get_transformed_cells), not the ADR sketch's bare int/quarter-turn. Both logged to tech-debt-register implications already tracked from Story 003.
- AC-C6.5's "full snapshot comparison" uses a test-side snapshot built from the public read API (get_occupant_id / get_buildable / get_access_ids over every cell), because get_snapshot() itself is Story 006 (GridSnapshot) — out of this story's scope. The AC's intent (pure function, no side effects) is verified with the read surface available today.
- AC-C5.4/C5.5's "commit succeeds" / "access_cells_changed is []" clauses reference commit() (Story 005) and grid_changed (Story 008) — both out of scope. The can_place-side behavior is verified directly; the commit-side post-state is simulated via the raw write primitives (commit_occupant/commit_access) so the AC's described end-state is still asserted today.
**Test Evidence**: Logic — `tests/unit/grid_system/grid_can_place_test.gd` (64 assertions, 0 failures; full suite 256/256, verified with zero SCRIPT ERROR occurrences)

---

## Dependencies

- Depends on: Story 001 (cell data), Story 002 (bounds checking), Story 003 (rotation transform)
- Unlocks: Story 005 (commit calls can_place before writing), Story 008 (integration tests with signals)
