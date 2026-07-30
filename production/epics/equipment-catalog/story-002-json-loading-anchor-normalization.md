# Story 002: JSON Loading and Anchor Normalization

> **Epic**: equipment-catalog
> **Status**: Ready
> **Layer**: Foundation
> **Type**: Logic
> **Estimate**: [hours or t-shirt size — fill before sprint planning]
> **Manifest Version**: 2026-07-23
> **Last Updated**: [set by /dev-story when implementation begins]

## Context

**GDD**: `design/gdd/equipment-catalog.md`
**Requirements**: `TR-EC-002`, `TR-EC-003`, `TR-EC-007`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0002: Storage Format
**ADR Decision Summary**: Catalog loaded from JSON file (`.catalog.json`), hand-authorable, VCS-diffable. Anchor normalization at load: subtract (min_x, min_y) from union bounding box, result must have min == (0,0). Only canonical 0° stored — no pre-rotated variants. `JSON.new(); json.parse()` used for designer-facing error line numbers.

**Engine**: Godot 4.7.1 | **Risk**: LOW
**Engine Notes**: `JSON.parse_string()` (convenience) vs `JSON.new(); json.parse()` (with error line numbers) — use the latter for meaningful error messages. `Vector2i` serialized as `{"x": N, "y": N}` objects in JSON.

**Control Manifest Rules (Foundation layer)**:
- Required: Data-driven configuration — no hardcoded equipment values in .gd files; external JSON only
- Forbidden: Never use Godot Resources (.tres/.res) for runtime equipment data
- Guardrail: Load-time normalization must be deterministic; same JSON input always produces same EquipmentDef order

---

## Acceptance Criteria

*From GDD `design/gdd/equipment-catalog.md`, scoped to this story:*

- [ ] AC-C.7 [BLOCKING][Logic] GIVEN a definition with footprint_cells/access_cells NOT pre-normalized (union min != (0,0)), WHEN loader executes anchor_normalization, THEN normalized coordinates are written into the final EquipmentDef, AND post-normalization union min == (0,0) — catches GridSystem OQ#13 item (b)
- [ ] AC-D.1 [BLOCKING][Logic] GIVEN footprint_cells={(1,0),(2,0)}, access_cells={(0,0)} (already normalized), WHEN anchor_normalization executes, THEN output is footprint={(1,0),(2,0)}, access={(0,0)} — no transform applied (idempotent for already-normalized input)
- [ ] AC-D.2 [BLOCKING][Logic] GIVEN any definition that passes footprint shape and access cell validation, WHEN anchor_normalization executes, THEN every output coordinate component falls in [0, 2] range — bounding-box guarantee (footprint ≤ 2×2 + access orthogonally adjacent ⇒ union ≤ 3×3)
- [ ] AC-JSON.1 [BLOCKING][Logic] GIVEN a valid .catalog.json file with N definitions, WHEN Catalog loads it, THEN N EquipmentDef instances are created with correct field values from JSON
- [ ] AC-JSON.2 [BLOCKING][Logic] GIVEN a malformed JSON file (syntax error), WHEN Catalog attempts to load, THEN loader returns a LoadError with line number information from JSON.parse()

---

## Implementation Notes

*Derived from ADR-0002 + GDD Core Rule 5 + Formula anchor_normalization:*

**anchor_normalization(formula):**
```gdscript
# x' = x - min_x, y' = y - min_y
# where (min_x, min_y) = min{(x,y) : (x,y) ∈ footprint_cells ∪ access_cells}

static func normalize_anchor(footprint_cells: Array[Vector2i], access_cells: Array[Vector2i]) -> Dictionary:
    # Returns {footprint: Array[Vector2i], access: Array[Vector2i]}
    var all_cells := footprint_cells + access_cells
    var min_x := all_cells[0].x
    var min_y := all_cells[0].y
    for c in all_cells:
        min_x = min(min_x, c.x)
        min_y = min(min_y, c.y)
    
    if min_x == 0 and min_y == 0:
        return {"footprint": footprint_cells, "access": access_cells}  # already normalized
    
    var result_fp: Array[Vector2i] = []
    var result_ac: Array[Vector2i] = []
    for c in footprint_cells:
        result_fp.append(Vector2i(c.x - min_x, c.y - min_y))
    for c in access_cells:
        result_ac.append(Vector2i(c.x - min_x, c.y - min_y))
    
    return {"footprint": result_fp, "access": result_ac}
```

**JSON loading:**
```gdscript
static func load_from_file(path: String, strict_mode: bool) -> LoadResult:
    if not FileAccess.file_exists(path):
        return LoadResult.fail("FILE_NOT_FOUND", "Catalog file not found: %s" % path)
    
    var file := FileAccess.open(path, FileAccess.READ)
    var text := file.get_as_text()
    file.close()
    
    var json := JSON.new()
    var error := json.parse(text)
    if error != OK:
        return LoadResult.fail("JSON_PARSE_ERROR",
            "Line %d: %s" % [json.get_error_line(), json.get_error_message()])
    
    var data = json.get_data()
    if not data is Dictionary or not data.has("equipment"):
        return LoadResult.fail("INVALID_SCHEMA", "Catalog JSON must have 'equipment' array at root")
    
    # data.equipment is Array[Dictionary] — each entry is one EquipmentDef
    var catalog := EquipmentCatalog.new()
    var errors: Array[LoadError] = []
    
    for entry in data.equipment:
        var result := _load_single_definition(entry, strict_mode)
        if result.ok:
            catalog._add_definition(result.def)
        else:
            errors.append_array(result.errors)
            if strict_mode:
                assert(false, "EquipmentCatalog: failed to load '%s': %s" % [entry.get("id", "???"), result.errors])
    
    catalog._freeze()
    return LoadResult.new(catalog, errors)
```

**JSON schema for each entry:**
```json
{
  "id": "treadmill_basic",
  "display_name": "Basic Treadmill",
  "zone_membership": ["cardio"],
  "footprint_cells": [{"x": 0, "y": 0}, {"x": 0, "y": 1}],
  "access_cells": [{"x": 1, "y": 0}],
  "cost": 200,
  "unlock_requirement": "",
  "effects": [{"tag": "cardio", "magnitude": 1.0}],
  "use_duration_mean_ticks": 200,
  "use_duration_stddev_ticks": 35,
  "use_duration_min_ticks": 100,
  "use_duration_max_ticks": 300
}
```

**Key design decisions:**
- Normalization is applied BEFORE validation (Story 003) — validator receives clean, normalized coordinates
- JSON entry uses `{"x": N, "y": N}` objects for Vector2i — readable, hand-authorable, VCS-diffable
- `parse()` not `parse_string()` — designer-facing error messages need line numbers
- Normalization must be idempotent: already-normalized input produces same output (AC-D.1 verifies this)

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 001]: EquipmentDef class and Catalog container — this story consumes them
- [Story 003]: Footprint shape validation (1×1/1×2/2×2), access cell count and adjacency checks
- [Story 004]: strict_mode branching and complete validation pipeline integration
- [Story 005]: use-duration field validation
- [Story 006]: provisional cost formula (not part of loading, applies at construction)

---

## QA Test Cases

- **AC-C.7**: 归一化后 min == (0,0)
  - Given: definition with footprint={(1,1),(2,1)}, access={(3,1)} (min_x=1,min_y=1)
  - When: normalize_anchor()
  - Then: output footprint={(0,0),(1,0)}, access={(2,0)}; union min == (0,0)
  - Edge cases: test with negative coordinates (access at (-1,0), footprint at (0,0))

- **AC-D.1**: 已归一化输入不变
  - Given: footprint={(1,0),(2,0)}, access={(0,0)} (already min_x=0,min_y=0)
  - When: normalize_anchor()
  - Then: output identical to input (idempotent)
  - Edge cases: test with footprint already at origin (0,0); test single-cell footprint

- **AC-D.2**: 输出坐标范围 [0,2]
  - Given: any valid definition (footprint ≤ 2×2, access orthogonally adjacent)
  - When: normalize_anchor()
  - Then: every coordinate component (x,y) in footprint AND access is 0, 1, or 2
  - Edge cases: test with access on left side (x negative before normalization); test with 2×2 footprint

- **AC-JSON.1**: 合法 JSON → N 个 EquipmentDef
  - Given: JSON file with 3 valid equipment entries
  - When: load_from_file(path, strict_mode=false)
  - Then: LoadResult.ok, catalog contains 3 definitions, all fields match JSON source
  - Edge cases: test with empty effects array; test with unlock_requirement = ""

- **AC-JSON.2**: JSON 语法错误 → LoadError
  - Given: file with trailing comma or missing brace
  - When: load_from_file()
  - Then: LoadResult with JSON_PARSE_ERROR containing line number
  - Edge cases: test with valid JSON but missing "equipment" key (INVALID_SCHEMA); test with equipment array that's a string instead of array

---

## Test Evidence

**Story Type**: Logic
**Required evidence**:
- `tests/unit/equipment_catalog/catalog_json_loading_test.gd` — must exist and pass

**Status**: [ ] Not yet created

---

## Dependencies

- Depends on: Story 001 (EquipmentDef class and Catalog container)
- Unlocks: Story 003 (validation needs loaded + normalized definitions), Story 004 (validation pipeline uses this loader)
