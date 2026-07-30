# Story 002: Solidity Formula and Coordinate Conversion

> **Epic**: grid-system
> **Status**: Ready
> **Layer**: Foundation
> **Type**: Logic
> **Estimate**: [hours or t-shirt size — fill before sprint planning]
> **Manifest Version**: 2026-07-23
> **Last Updated**: [set by /dev-story when implementation begins]

## Context

**GDD**: `design/gdd/grid-system.md`
**Requirements**: `TR-GS-016`, `TR-GS-022`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0003: GridStateReader Contract
**ADR Decision Summary**: is_solid(cell) = NOT buildable(cell) OR occupant_id(cell) != -1. access_ids is explicitly excluded from the solidity formula. grid_to_world/world_to_grid use simple floor division by cell_size. world_to_grid returns raw result (no clamp, no error) — calling code must bounds-check before using the output as a grid coordinate.

**Engine**: Godot 4.7.1 | **Risk**: LOW
**Engine Notes**: D.7 confirms set_point_solid() works immediately without update() call — Navigation integration path is cheap. cell_size is a project-level architecture decision not yet finalized — test fixtures should use a configurable cell_size parameter, not a hardcoded value.

**Control Manifest Rules (Foundation layer)**:
- Required: All public methods must guard against use-before-init; init() stores references only, side effects in _post_init()
- Forbidden: Never expose GridSystem's internal storage as public API; never use duck-typing for grid read surface — depend on typed GridStateReader
- Guardrail: Tick dispatch overhead ≤ 0.1ms

---

## Acceptance Criteria

*From GDD `design/gdd/grid-system.md`, scoped to this story:*

- [ ] AC-D3.1 [BLOCKING][Logic] GIVEN buildable=true, occupant_id=-1, access_ids=[7], WHEN querying is_solid, THEN returns false — the second-highest-risk assertion (access_ids must not affect solidity)
- [ ] AC-D3.2 [BLOCKING][Logic] GIVEN buildable=true, occupant_id=7, WHEN querying is_solid (regardless of access_ids), THEN always returns true
- [ ] AC-D3.3 [BLOCKING][Logic] GIVEN buildable=false, WHEN querying is_solid (regardless of occupant_id), THEN always returns true
- [ ] AC-D3.4 [BLOCKING][Logic] GIVEN buildable=true, cell (2,2) occupied by instance_id=0 footprint, WHEN querying is_solid((2,2)), THEN returns true; AND get_occupant_id((2,2)) returns 0 (not -1) — occupant_id=0 is the first piece placed, GDScript truthy check is a BUG
- [ ] AC-D2.2 [BLOCKING][Logic] GIVEN width=13,height=10, WHEN any public query function receives col=-1, col=13, row=-1, or row=10, THEN each case push_error() and returns documented safe default, and must NOT return real data from adjacent row/column
- [ ] AC-D2.3 [BLOCKING][Logic] GIVEN an out-of-bounds coordinate, WHEN calling is_solid(cell), THEN returns true — "outside the room is solid" prevents AStarGrid2D pathing outside bounds
- [ ] AC-D4.1 [BLOCKING][Logic] GIVEN cell_size=32 (test placeholder, unrelated to final architecture decision), cell=(5,3), WHEN calling grid_to_world_corner / grid_to_world_center / world_to_grid, THEN respectively returns (160,96), (176,112), and world_to_grid((170,100)) == (5,3) — all three round-trip consistency covered in one pass
- [ ] AC-C5.1 [BLOCKING][Logic] GIVEN access cell with occupant_id=-1, WHEN querying is_solid on that cell, THEN returns false — access cells are walkable (same assertion as AC-D3.1 but verifies the access-cell scenario specifically)

---

## Implementation Notes

*Derived from ADR-0003 Implementation Guidelines:*

**Solidity formula (D.3):**
```gdscript
func is_solid(cell: Vector2i) -> bool:
    if not _in_bounds(cell):
        push_error("is_solid: cell %s out of bounds" % cell)
        return true  # outside = solid (safety default for AStarGrid2D)
    var idx := _flat_index(cell)
    return not buildable[idx] or occupant_id[idx] != -1
```

**CRITICAL — occupant_id = 0 is LEGAL:**
```gdscript
# ❌ BUG — 0 is falsy in GDScript, silently treats first placed piece as empty
if occupant_id[idx]:
    return true

# ✅ CORRECT — explicit comparison with sentinel
if occupant_id[idx] != -1:
    return true
```

**Coordinate formulas (D.4):**
- `flat_index(col, row) = row * width + col` — bounds-check input first
- `grid_to_world_corner(cell) = cell * cell_size`
- `grid_to_world_center(cell) = cell * cell_size + Vector2(cell_size/2.0, cell_size/2.0)`
- `world_to_grid(world_pos) = floor(world_pos / cell_size)` — returns raw result, does NOT clamp

**Bounds checking (D.2):**
- `_in_bounds(col, row)` must be called before any flat_index calculation
- Out-of-bounds: push_error() + return safe default
- is_solid default for OOB: true (prevents pathing outside room)
- get_occupant_id default for OOB: -1
- Data leak test: construct a fixture where the OOB cell would map via flat_index to a populated adjacent-row cell — assert you DON'T get that value

**Special contract for world_to_grid:**
- Returns raw mathematical result — no clamp, no error, no sentinel
- OOB output (e.g. (-1,-1)) is NORMAL during drag (mouse leaves room)
- Calling code must bounds-check before feeding the result to flat_index/is_solid/can_place
- This is INTENTIONALLY different from D.2 query functions — D.2 guards against "reading non-existent memory"; world_to_grid is a pure conversion where OOB input is expected

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 001]: Cell data model (occupant_id, buildable, access_ids storage), flat_index construction
- [Story 003]: Rotation transform, declared_bounds, TransformedFootprint composite
- [Story 004]: can_place() validation — placement logic is downstream, not needed for solidity
- [Story 005]: commit/clear operations — is_solid doesn't need mutation paths
- [Story 006]: GridStateReader base class — is_solid/get_occupant_id signatures defined there, implemented here

---

## QA Test Cases

- **AC-D3.1**: access_ids 不参与 solidity（第二高危断言）
  - Given: buildable=true, occupant_id=-1, access_ids=[7] (this cell IS someone's access cell)
  - When: calling is_solid(cell)
  - Then: returns false (members can walk on access cells)
  - Edge cases: test with access_ids=[], [7], [7,8,9] — all should return false

- **AC-D3.2**: occupant_id 覆盖一切
  - Given: buildable=true, occupant_id=7, access_ids=[8,9] or []
  - When: calling is_solid regardless of access_ids
  - Then: always returns true (footprint is solid even if it's also someone's access cell)
  - Edge cases: occupant_id=5 with access_ids containing [5] (own access overlapping own footprint = bug in data but formula is unambiguous)

- **AC-D3.3**: buildable=false 恒为 solid
  - Given: buildable=false, occupant_id=-1,5,or any value
  - When: calling is_solid
  - Then: always returns true
  - Edge cases: negative occupant_id with buildable=false — still solid

- **AC-D3.4**: occupant_id=0 不是 falsy（GDScript 陷阱）
  - Given: buildable=true, cell (2,2) occupied by instance_id=0 (first piece ever placed)
  - When: is_solid((2,2)) and get_occupant_id((2,2))
  - Then: is_solid returns true, get_occupant_id returns 0 (NOT -1)
  - Edge cases: this is THE test that catches `if occupant_id:` type bugs

- **AC-D2.2**: 越界拦截不崩溃不泄漏
  - Given: width=13, height=10, construct scenario where OOB coordinate would overlap real data at a different cell
  - When: each public query receives col=-1,13 or row=-1,10
  - Then: push_error() fires, safe default returned, adjacent row/column data NOT leaked
  - Edge cases: test ALL 8 OOB directions (4 corners + 4 edges)

- **AC-D2.3**: is_solid 越界默认 true
  - Given: any out-of-bounds coordinate
  - When: is_solid(OOB_cell)
  - Then: returns true (counterintuitive — "outside = solid" is intentional to prevent AStarGrid2D from pathing outside)
  - Edge cases: verify this default is NOT false (false would let AStarGrid2D path into void)

- **AC-D4.1**: 坐标换算往返一致性
  - Given: cell_size=32, cell=(5,3)
  - When: grid_to_world_corner, grid_to_world_center, world_to_grid
  - Then: corner=(160,96), center=(176,112), reverse world_to_grid((170,100)) = (5,3)
  - Edge cases: cell_size odd number, cell at origin (0,0), cell at max boundary (width-1,height-1)

- **AC-C5.1**: access cell 可步行
  - Given: cell is access_ids=[7] but occupant_id=-1, buildable=true
  - When: is_solid(cell)
  - Then: returns false (same as AC-D3.1, but framed as "can members stand there")
  - Edge cases: multiple access_ids, cleared access cell (access_ids becomes []) — assert transition

---

## Test Evidence

**Story Type**: Logic
**Required evidence**:
- `tests/unit/grid_system/grid_solidity_coords_test.gd` — must exist and pass

**Status**: [ ] Not yet created

---

## Dependencies

- Depends on: Story 001 (cell data model must be implemented first)
- Unlocks: Story 004 (can_place needs is_solid + bounds checking), Story 005 (commit/clear needs occupant_id read), Story 008 (Navigation integration reads is_solid)
