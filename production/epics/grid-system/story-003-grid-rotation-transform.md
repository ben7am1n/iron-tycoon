# Story 003: Rotation Transform and Declared Bounds

> **Epic**: grid-system
> **Status**: Ready
> **Layer**: Foundation
> **Type**: Logic
> **Estimate**: [hours or t-shirt size — fill before sprint planning]
> **Manifest Version**: 2026-07-23
> **Last Updated**: [set by /dev-story when implementation begins]

## Context

**GDD**: `design/gdd/grid-system.md`
**Requirements**: `TR-GS-011` through `TR-GS-014`, `TR-GS-028`, `TR-GS-029`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0003: GridStateReader Contract
**ADR Decision Summary**: Rotation transform uses a union bounding box (W,H) = declared_bounds(footprint ∪ access). Footprint and access MUST share the same (W,H) for rotation — using footprint-only bbox causes negative coordinates at 90°/270°. The D.1 formula uses 4 explicit branches (0°/90°/180°/270°) with an assert(false) fallback for illegal rotation values. rotation must be typed as GDScript enum, not bare int.

**Engine**: Godot 4.7.1 | **Risk**: MEDIUM
**Engine Notes**: This is the single highest-risk rule in the GDD. Integer grid rotation with W/H swap at 90°/270° is correct by construction but requires exhaustive testing of non-square footprints. 0°/180° tests can create false confidence because symmetry hides bugs.

**Control Manifest Rules (Foundation layer)**:
- Required: Use two-phase init; init() stores references only
- Forbidden: Never use Autoload; never expose internal storage as public API
- Guardrail: N/A (this is correctness-critical, not performance-critical)

---

## Acceptance Criteria

*From GDD `design/gdd/grid-system.md`, scoped to this story:*

- [ ] AC-C4.1 [BLOCKING][Logic] (1×2 treadmill, non-square footprint, exhaust all 4 orientations) GIVEN footprint=[(0,0),(0,1)], access=[(0,2)], declared_bounds (W=1,H=3), anchor=(0,0), WHEN get_transformed_cells for each of {0°,90°,180°,270°}, THEN results exactly match the GDD D.1 table (0°: fp {(0,0),(0,1)} access {(0,2)}; 90°: fp {(2,0),(1,0)} access {(0,0)}; 180°: fp {(0,2),(0,1)} access {(0,0)}; 270°: fp {(0,0),(1,0)} access {(2,0)})
- [ ] AC-C4.2 [BLOCKING][Logic] (1×1 squat rack, cross-validation fixture) GIVEN footprint=[(0,0)], access=[(0,1)], declared_bounds (W=1,H=2), WHEN testing all 4 orientations, THEN results exactly match D.1 table (0°: access (0,1); 90°: access (0,0); 180°: access (0,0); 270°: access (1,0))
- [ ] AC-C4.3 [BLOCKING][Logic] (NEGATIVE — catch "local bbox vs union bbox" bug) GIVEN AC-C4.1 treadmill fixture, WHEN 90° or 270° rotation, THEN access cell BOTH components must be >= 0
- [ ] AC-D1.1 [BLOCKING][Logic] (illegal rotation must NOT silently fallback) GIVEN an illegal rotation value (e.g. 45, -90, 360), WHEN in debug build calling get_transformed_cells, THEN the default branch assert(false, "illegal rotation") triggers
- [ ] AC-D5.1 [BLOCKING][Logic] GIVEN footprint=[(0,0),(1,0),(0,1),(1,1)], access=[(0,2)], WHEN calling declared_bounds, THEN returns (W=2,H=3)
- [ ] AC-D5.2 [BLOCKING][Logic] (debug assert — anchor convention) GIVEN a hand-crafted equipment_def violating anchor convention (min_offset != (0,0)), WHEN in debug/editor build calling get_transformed_cells or declared_bounds, THEN assert() triggers and aborts execution
- [ ] AC-D5.3 [BLOCKING][Logic] (debug assert — empty footprint) GIVEN footprint_cells=[], WHEN in debug build calling get_transformed_cells, THEN assert() triggers

---

## Implementation Notes

*Derived from ADR-0003 + GDD §D.1/D.5:*

**Rotation transform (D.1) — 4 explicit branches:**
```gdscript
enum Rotation { R0 = 0, R90 = 90, R180 = 180, R270 = 270 }

func _transform_cell(x: int, y: int, rot: Rotation, W: int, H: int) -> Vector2i:
    match rot:
        Rotation.R0:   return Vector2i(x, y)
        Rotation.R90:  return Vector2i(H - 1 - y, x)
        Rotation.R180: return Vector2i(W - 1 - x, H - 1 - y)
        Rotation.R270: return Vector2i(y, W - 1 - x)
        _:
            assert(false, "Illegal rotation value: %s" % rot)
            return Vector2i.ZERO  # unreachable, keeps compiler happy
```

**CRITICAL — union bounding box, not footprint-only:**
- (W,H) = declared_bounds(equipment_def) → computes max x/y of footprint_cells ∪ access_cells + 1
- This same (W,H) MUST be passed to both footprint transform AND access transform
- NEVER let each transform internally derive its own local bbox — that's the exact bug AC-C4.3 catches

**TransformedFootprint composite return type:**
```gdscript
class_name TransformedFootprint extends RefCounted
var footprint_cells: Array[Vector2i]
var access_cells: Array[Vector2i]
var new_size: Vector2i  # (new_W, new_H) — W/H swapped at 90/270
```
- get_transformed_cells() returns TransformedFootprint — API shape IS the first line of defense
- Never expose a "transform arbitrary cell set" utility function

**Declared bounds (D.5):**
```gdscript
func declared_bounds(equipment_def: EquipmentDef) -> Vector2i:
    var all_cells := equipment_def.footprint_cells + equipment_def.access_cells
    assert(not all_cells.is_empty(), "equipment_def footprint_cells must not be empty")
    assert(_min_offset(all_cells) == Vector2i.ZERO, "equipment_def violates anchor convention")
    var max_x := 0; var max_y := 0
    for c in all_cells:
        max_x = max(max_x, c.x); max_y = max(max_y, c.y)
    return Vector2i(max_x + 1, max_y + 1)
```

**Debug asserts (D.5):**
- assert() calls are compile-time removed in release builds — zero cost in production
- Debug/CI catches bad equipment_def data; the real gate is EquipmentCatalog loading validation
- All three assert-based ACs (D5.2, D5.3, D1.1) depend on Open Question #14 (assert capture mechanism) — see Story 001 Implementation Notes for the OQ#14 resolution before writing the first GridSystem test

**Footprint shapes locked (permanent constraint):**
- Only 1×1, 1×2, 2×2 rectangular AABB — L-shapes permanently excluded
- This constraint is enforced by EquipmentCatalog, not GridSystem (GridSystem trusts its input)
- Anchor convention: (0,0) = top-left of declared bounding box of canonical(0°) footprint+access union

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 001]: Cell data storage, flat_index, origin convention
- [Story 002]: is_solid() formula, coordinate conversion — rotation doesn't need these
- [Story 004]: can_place() — uses rotation output but validates against grid state (separate story)
- [Story 005]: commit()/clear() — writes rotated cells to grid (separate story)
- [Story 007]: serialize/deserialize — rotation value (int from enum) is stored in PlacementRecord, round-tripped via serialization tests

---

## QA Test Cases

- **AC-C4.1**: 1×2 跑步机 4 朝向穷举
  - Given: footprint=[(0,0),(0,1)], access=[(0,2)], (W=1,H=3), anchor=(0,0)
  - When: get_transformed_cells for each of R0,R90,R180,R270
  - Then: each orientation exactly matches the GDD table (see Acceptance Criteria for full expected values)
  - Edge cases: ensure test fixture doesn't use 0°/180° only — MUST include 90°/270° (symmetry can mask bugs)

- **AC-C4.2**: 1×1 深蹲架 4 朝向交叉验证
  - Given: footprint=[(0,0)], access=[(0,1)], (W=1,H=2)
  - When: same 4-orientation test
  - Then: exactly matches D.1 example table
  - Edge cases: this is deliberately a different shape (1×1fp + 1 access) to cross-validate against AC-C4.1

- **AC-C4.3**: 负向 — footprint-only bbox 会产负坐标
  - Given: same treadmill fixture as AC-C4.1
  - When: 90° or 270° rotation
  - Then: access cell x >= 0 AND access cell y >= 0 (both components non-negative)
  - Edge cases: this test would FAIL if using footprint-only bbox (W=1,H=2) instead of union bbox (W=1,H=3)

- **AC-D1.1**: 非法 rotation 不静默回退
  - Given: rotation values 45, -90, 360 (all outside enum)
  - When: debug build calls get_transformed_cells
  - Then: assert(false) fires for each — NOT silently returning (x,y) as-if rotation=0
  - Edge cases: test each illegal value independently; test that valid values do NOT trigger assert

- **AC-D5.1**: declared_bounds 计算
  - Given: 2×2 footprint=[(0,0),(1,0),(0,1),(1,1)], access=[(0,2)]
  - When: declared_bounds(equipment_def)
  - Then: returns Vector2i(2, 3)
  - Edge cases: test with access=[(0,0)] (access inside footprint but at origin = still takes the max)

- **AC-D5.2**: debug assert — anchor 约定违规
  - Given: hand-crafted def with min_offset != (0,0) (e.g. footprint starts at (1,1))
  - When: debug build calls declared_bounds or get_transformed_cells
  - Then: assert() abort
  - Edge cases: test after anchor_normalization (should pass); test un-normalized raw data (should fail)

- **AC-D5.3**: debug assert — 空 footprint
  - Given: footprint_cells=[]
  - When: debug build calls get_transformed_cells
  - Then: assert() abort (not a graceful return)
  - Edge cases: empty access_cells is fine (per AC-C5.5 in Story 004); only empty footprint is illegal

---

## Test Evidence

**Story Type**: Logic
**Required evidence**:
- `tests/unit/grid_system/grid_rotation_test.gd` — must exist and pass

**Status**: [ ] Not yet created

---

## Dependencies

- Depends on: Story 001 (cell data model, origin convention, equipment_def shape)
- Unlocks: Story 004 (can_place needs rotation output), Story 005 (commit writes rotated cells), Story 007 (serialize stores rotation value)
