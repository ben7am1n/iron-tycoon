# Story 003: Footprint Shape and Access Cell Validation

> **Epic**: equipment-catalog
> **Status**: Ready
> **Layer**: Foundation
> **Type**: Logic
> **Estimate**: [hours or t-shirt size — fill before sprint planning]
> **Manifest Version**: 2026-07-23
> **Last Updated**: [set by /dev-story when implementation begins]

## Context

**GDD**: `design/gdd/equipment-catalog.md`
**Requirements**: `TR-EC-002`, `TR-EC-003`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0002: Storage Format
**ADR Decision Summary**: Load-time validation enforces the cross-document contracts required by GridSystem. Three footprint shapes only: 1×1, 1×2, 2×2 rectangular AABB (no L-shapes, no holes). Exactly 1 access cell orthogonally adjacent to footprint. Access must NOT overlap footprint. These are the specific rules GridSystem's declared_bounds and rotation transform depend on for correctness.

**Engine**: Godot 4.7.1 | **Risk**: LOW
**Engine Notes**: Pure data validation — no engine API risks. Validation run once at startup, not on hot path. Purely computational (set membership, adjacency checks).

**Control Manifest Rules (Foundation layer)**:
- Required: All validation errors produce LoadError objects with equipment id + rule reference
- Forbidden: Never silently skip invalid definitions — always report to caller
- Guardrail: Validation must complete before Catalog._freeze() — no post-freeze modifications

---

## Acceptance Criteria

*From GDD `design/gdd/equipment-catalog.md`, scoped to this story:*

- [ ] AC-C.1 [BLOCKING][Logic] GIVEN a definition with footprint_cells = [] (empty), WHEN Catalog loads with strict_mode=true, THEN assert() aborts; error message includes the entry's id
- [ ] AC-C.2 [BLOCKING][Logic] GIVEN same illegal definition, WHEN Catalog loads with strict_mode=false, THEN the entry is excluded and push_error() fires; all other valid entries still load into final Catalog
- [ ] AC-C.3 [BLOCKING][Logic] GIVEN a definition whose footprint_cells is NOT one of {1×1, 1×2, 2×2} rectangular AABB (e.g. 3-cell L-shape), WHEN loaded, THEN validation fails — same pass/fail as AC-C.1/C.2
- [ ] AC-C.4 [BLOCKING][Logic] GIVEN a definition with access_cells containing 2+ entries, WHEN loaded, THEN validation fails (len(access_cells) != 1)
- [ ] AC-C.5 [BLOCKING][Logic] GIVEN a definition where access_cells is only diagonally adjacent to footprint (shares no edge), WHEN loaded, THEN validation fails
- [ ] AC-C.6 [BLOCKING][Logic] GIVEN a definition where access_cells overlaps with footprint_cells, WHEN loaded, THEN validation fails — catches GridSystem OQ#13 item (c)

---

## Implementation Notes

*Derived from ADR-0002 + GDD Core Rules 3-4 + Core Rule 6(a)(c)(d):*

**Footprint shape validation:**
```gdscript
# Three legal shapes, verified by cell count + bounding box dimensions
const VALID_SHAPES := {
    "1x1": {"cells": 1, "w": 1, "h": 1},
    "1x2": {"cells": 2, "w": 1, "h": 2},  # or w=2,h=1
    "2x2": {"cells": 4, "w": 2, "h": 2},
}

static func validate_footprint_shape(cells: Array[Vector2i]) -> ValidationResult:
    if cells.is_empty():
        return ValidationResult.fail("FOOTPRINT_EMPTY", "footprint_cells must not be empty")
    
    var cell_count := cells.size()
    
    # Bounding box
    var min_x := cells[0].x; var max_x := cells[0].x
    var min_y := cells[0].y; var max_y := cells[0].y
    for c in cells:
        min_x = min(min_x, c.x); max_x = max(max_x, c.x)
        min_y = min(min_y, c.y); max_y = max(max_y, c.y)
    
    var bbox_w := max_x - min_x + 1
    var bbox_h := max_y - min_y + 1
    
    # Check against known shapes
    # Must match cell count AND bounding box dimensions AND be rectangular (cell_count == bbox_w * bbox_h)
    var is_rectangular := cell_count == (bbox_w * bbox_h)
    if not is_rectangular:
        return ValidationResult.fail("FOOTPRINT_NOT_RECTANGULAR",
            "footprint must be rectangular AABB; got %d cells in %dx%d bbox (expected %d cells)" %
            [cell_count, bbox_w, bbox_h, bbox_w * bbox_h])
    
    var is_valid_shape := (bbox_w in [1, 2] and bbox_h in [1, 2]) and cell_count in [1, 2, 4]
    if not is_valid_shape:
        return ValidationResult.fail("FOOTPRINT_INVALID_SHAPE",
            "footprint must be 1×1, 1×2, or 2×2; got %d×%d (%d cells)" % [bbox_w, bbox_h, cell_count])
    
    return ValidationResult.ok()
```

**Access cell validation:**
```gdscript
static func validate_access_cells(access_cells: Array[Vector2i], footprint_cells: Array[Vector2i]) -> ValidationResult:
    # (d) Exactly 1 access cell
    if access_cells.size() != 1:
        return ValidationResult.fail("ACCESS_COUNT",
            "access_cells must have exactly 1 entry; got %d" % access_cells.size())
    
    var ac := access_cells[0]
    
    # (c) Access must not overlap footprint
    if ac in footprint_cells:
        return ValidationResult.fail("ACCESS_OVERLAPS_FOOTPRINT",
            "access cell %s overlaps with footprint" % ac)
    
    # Orthogonal adjacency: must share at least one edge with a footprint cell
    var is_adjacent := false
    for fc in footprint_cells:
        var dx := abs(ac.x - fc.x)
        var dy := abs(ac.y - fc.y)
        if (dx == 1 and dy == 0) or (dx == 0 and dy == 1):
            is_adjacent = true
            break
    
    if not is_adjacent:
        return ValidationResult.fail("ACCESS_NOT_ADJACENT",
            "access cell %s is not orthogonally adjacent to any footprint cell" % ac)
    
    return ValidationResult.ok()
```

**Validation pipeline in loader:**
```gdscript
static func _validate_definition(entry: Dictionary) -> ValidationResult:
    var fp := entry.footprint_cells  # Array[Vector2i], already normalized
    var ac := entry.access_cells
    
    # Ordered checks — first failure returns
    var r := validate_footprint_shape(fp)
    if not r.ok: return r
    
    r = validate_access_cells(ac, fp)
    if not r.ok: return r
    
    return ValidationResult.ok()
```

**Key design decisions:**
- Footprint validation uses bounding-box + cell-count approach: a rectangular AABB means cell_count == bbox_w * bbox_h. This catches holes and L-shapes naturally.
- Validation order: footprint shape → access count → access disjoint → access adjacency. Deterministic error for any given bad input.
- Access adjacency uses Manhattan distance exactly 1 (orthogonal only) — diagonals (dx=1, dy=1) fail
- Two separate validate functions: footprint and access — each independently testable

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 001]: EquipmentDef class (returned on success)
- [Story 002]: JSON loading and anchor normalization (this receives already-normalized coordinates)
- [Story 004]: strict_mode branching logic (this just returns ValidationResult; the caller decides abort vs skip)
- [Story 005]: use-duration field validation (separate validator, same pipeline)
- [Story 006]: cost validation and provisional formula

---

## QA Test Cases

- **AC-C.1**: 空 footprint → assert() (strict_mode=true)
  - Given: entry with footprint_cells=[]
  - When: load with strict_mode=true
  - Then: assert() aborts with entry id in message
  - Edge cases: verify message contains the specific id string

- **AC-C.2**: 空 footprint → 跳过 (strict_mode=false)
  - Given: entry with footprint_cells=[] plus 2 valid entries
  - When: load with strict_mode=false
  - Then: bad entry excluded, push_error() fires, 2 valid entries loaded
  - Edge cases: verify Catalog.get_all_ids() returns only the 2 valid ids

- **AC-C.3**: L 形 footprint 拒绝
  - Given: footprint_cells=[(0,0),(1,0),(1,1)] (3 cells, L-shape, bbox 2×2 but 3 != 4)
  - When: validate_footprint_shape()
  - Then: FOOTPRINT_NOT_RECTANGULAR
  - Edge cases: test with T-shape [(0,0),(1,0),(2,0),(1,1)]; test with "diagonal only" [(0,0),(1,1)] (bbox 2×2, 2 cells but not rectangular)

- **AC-C.4**: 2 个 access 拒绝
  - Given: access_cells=[(1,0),(2,0)]
  - When: validate_access_cells()
  - Then: ACCESS_COUNT error
  - Edge cases: test with 0 access cells; test with 3+ access cells

- **AC-C.5**: 对角相邻拒绝
  - Given: footprint=(0,0), access=(1,1) (diagonal only, dx=1,dy=1)
  - When: validate_access_cells()
  - Then: ACCESS_NOT_ADJACENT
  - Edge cases: test with access at (5,5) (far away); test with access at (2,0) where footprint is at (0,0) (Manhattan distance 2)

- **AC-C.6**: access 与 footprint 重叠拒绝
  - Given: footprint=(0,0), access=(0,0) (same cell)
  - When: validate_access_cells()
  - Then: ACCESS_OVERLAPS_FOOTPRINT
  - Edge cases: test with 2×2 footprint and access at one of its cells

---

## Test Evidence

**Story Type**: Logic
**Required evidence**:
- `tests/unit/equipment_catalog/catalog_footprint_access_validation_test.gd` — must exist and pass

**Status**: [ ] Not yet created

---

## Dependencies

- Depends on: Story 001 (EquipmentDef class), Story 002 (normalized coordinates as input)
- Unlocks: Story 004 (strict_mode integrates these validators into the pipeline)
