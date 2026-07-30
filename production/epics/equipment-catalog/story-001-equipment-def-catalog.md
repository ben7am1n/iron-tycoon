# Story 001: EquipmentDef Data Model and Catalog Container

> **Epic**: equipment-catalog
> **Status**: Ready
> **Layer**: Foundation
> **Type**: Logic
> **Estimate**: [hours or t-shirt size — fill before sprint planning]
> **Manifest Version**: 2026-07-23
> **Last Updated**: [set by /dev-story when implementation begins]

## Context

**GDD**: `design/gdd/equipment-catalog.md`
**Requirements**: `TR-EC-001`, `TR-EC-005`, `TR-EC-007`, `TR-EC-009`, `TR-EC-010`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0001: DI Container & Scene Bootstrap, ADR-0002: Storage Format
**ADR Decision Summary**: EquipmentDef is an immutable RefCounted DTO with all fields populated at construction. Catalog extends RefCounted, loaded once at startup via DI injection into SimulationOrchestrator. No Autoload. Catalog frozen after load — only exposes get_definition(id) -> EquipmentDef read-only query. Only canonical 0° orientation stored (4 pre-rotated variants explicitly forbidden). Effects container uses {tag: String, magnitude: float} shape, tag vocabulary owned by ZoneRules.

**Engine**: Godot 4.7.1 | **Risk**: LOW
**Engine Notes**: Standard RefCounted DTO pattern — no special engine considerations. GDScript lacks `readonly` modifier; immutability enforced by convention (no public setters, fields populated at construction time only).

**Control Manifest Rules (Foundation layer)**:
- Required: All public methods must guard against use-before-init; DI over singletons; RefCounted classes only (no Node/Autoload)
- Forbidden: Never expose mutable references to EquipmentDef fields; never use Autoload for Catalog; never store pre-rotated variants (canonical 0° only)
- Guardrail: Catalog.is_frozen check on every public method; push_error() if queried before load

---

## Acceptance Criteria

*From GDD `design/gdd/equipment-catalog.md`, scoped to this story:*

- [ ] AC-C.8 [BLOCKING][Logic] GIVEN successfully loaded Catalog, WHEN any system calls get_definition(id) repeatedly for the same id, THEN both returns are value-equal; AND Catalog's public API surface contains no setter/mutator methods (static code check verifiable)
- [ ] AC-CANONICAL.1 [BLOCKING][Logic] GIVEN an EquipmentDef constructed with canonical 0° footprint/access, WHEN queried, THEN only the original coordinates are stored — no 90°/180°/270° variants generated or stored on the record
- [ ] AC-IMMUTABLE.1 [BLOCKING][Logic] GIVEN an EquipmentDef instance returned by get_definition(), WHEN caller attempts to modify any field (e.g. append to footprint_cells Array), THEN the original stored definition is unaffected (deep copy or immutable-by-convention)
- [ ] AC-FROZEN.1 [BLOCKING][Logic] GIVEN Catalog before load() is called, WHEN get_definition(any_id) is called, THEN push_error() fires, returns null or safe default
- [ ] AC-FROZEN.2 [BLOCKING][Logic] GIVEN Catalog after load() is complete, WHEN any code path attempts to add/remove/modify a definition, THEN the operation is rejected (Catalog exposes no write API)

---

## Implementation Notes

*Derived from ADR-0001 + ADR-0002 + GDD Core Rules 1-2:*

**EquipmentDef DTO:**
```gdscript
class_name EquipmentDef extends RefCounted
# Immutable by convention — all fields populated at _init(), no public setters

var id: String
var display_name: String
var zone_membership: Array  # Array[String]
var footprint_cells: Array[Vector2i]
var access_cells: Array[Vector2i]
var cost: int
var unlock_requirement: String  # empty string = always available (null not used)
var effects: Array[Dictionary]  # [{tag: String, magnitude: float}]
var use_duration_mean_ticks: int
var use_duration_stddev_ticks: int
var use_duration_min_ticks: int
var use_duration_max_ticks: int

func _init(p_id: String, p_display_name: String, p_zone_membership: Array,
           p_footprint_cells: Array[Vector2i], p_access_cells: Array[Vector2i],
           p_cost: int, p_unlock_requirement: String, p_effects: Array[Dictionary],
           p_use_duration_mean: int, p_use_duration_stddev: int,
           p_use_duration_min: int, p_use_duration_max: int) -> void:
    id = p_id
    display_name = p_display_name
    zone_membership = p_zone_membership.duplicate()  # shallow copy guard
    footprint_cells = p_footprint_cells.duplicate()
    access_cells = p_access_cells.duplicate()
    cost = p_cost
    unlock_requirement = p_unlock_requirement
    effects = p_effects.duplicate(true)  # deep copy
    use_duration_mean_ticks = p_use_duration_mean
    use_duration_stddev_ticks = p_use_duration_stddev
    use_duration_min_ticks = p_use_duration_min
    use_duration_max_ticks = p_use_duration_max
```

**Catalog container:**
```gdscript
class_name EquipmentCatalog extends RefCounted

var _definitions: Dictionary = {}  # String id -> EquipmentDef
var _is_loaded: bool = false
var _is_frozen: bool = false

func get_definition(equipment_id: String) -> EquipmentDef:
    if not _is_frozen:
        push_error("EquipmentCatalog: get_definition() called before freeze()")
        return null
    if not _definitions.has(equipment_id):
        push_error("EquipmentCatalog: no definition for id '%s'" % equipment_id)
        return null
    return _definitions[equipment_id]

func has_definition(equipment_id: String) -> bool:
    return _definitions.has(equipment_id)

func get_all_ids() -> Array[String]:
    if not _is_frozen:
        push_error("EquipmentCatalog: get_all_ids() called before freeze()")
        return []
    return _definitions.keys()

# Called by loader after validation — internal API, not public
func _add_definition(def: EquipmentDef) -> void:
    assert(not _is_frozen, "EquipmentCatalog: cannot add after freeze()")
    _definitions[def.id] = def

func _freeze() -> void:
    _is_frozen = true
    _is_loaded = true
```

**Key design decisions:**
- EquipmentDef fields are Array/Dictionary types — immutability is by convention (duplicate on construction, no public setters), not language-enforced
- `unlock_requirement` stored as String (not null-able) — empty string = "always available"; avoids GDScript null-reference pitfalls
- Catalog has two-phase construction: `_add_definition()` during loading, then `_freeze()` makes it read-only
- No Autoload — Catalog instance owned by SimulationOrchestrator, injected into consumers
- Only canonical 0° orientation — rotation is entirely GridSystem's runtime computation (TR-EC-007)

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 002]: JSON loading and anchor normalization — this story defines the container; next story fills it
- [Story 003]: Footprint shape and access cell validation — this story stores what's given; validation is separate
- [Story 004]: strict_mode branching and complete validation pipeline
- [Story 005]: use-duration field validation
- [Story 006]: provisional cost formula

---

## QA Test Cases

- **AC-C.8**: 不可变契约与查询一致性
  - Given: Catalog loaded with at least one definition
  - When: call get_definition(same_id) twice, and enumerate all public method names
  - Then: both returns are equal (same fields, same values); no setter/mutator in public API
  - Edge cases: verify get_definition on non-existent id returns null + push_error(); verify with empty Catalog

- **AC-CANONICAL.1**: 仅存 canonical 0°
  - Given: EquipmentDef constructed with 1×2 footprint + 1 access cell
  - When: inspect the stored fields
  - Then: exactly the provided coordinates stored; no additional 90°/180°/270° arrays present
  - Edge cases: verify EquipmentDef has no rotation field at all (rotation is runtime, not stored)

- **AC-IMMUTABLE.1**: 调用方修改不影响存储
  - Given: EquipmentDef returned by get_definition()
  - When: caller appends to the returned Array (e.g. def.footprint_cells.append(some_cell))
  - Then: subsequent get_definition() returns the original footprint unchanged
  - Edge cases: this tests the .duplicate() in _init() — verify with access_cells too

- **AC-FROZEN.1**: freeze 前拒绝查询
  - Given: Catalog constructed but load() not yet called
  - When: get_definition(any_id)
  - Then: push_error() fires, returns null
  - Edge cases: verify get_all_ids() also errors; verify has_definition() errors

- **AC-FROZEN.2**: freeze 后拒绝修改
  - Given: Catalog after _freeze()
  - When: attempt to call _add_definition() or any write path
  - Then: assert() fires (internal API) or method doesn't exist (public API)
  - Edge cases: verify _freeze() cannot be called twice; verify Catalog has no public remove method

---

## Test Evidence

**Story Type**: Logic
**Required evidence**:
- `tests/unit/equipment_catalog/equipment_def_catalog_test.gd` — must exist and pass

**Status**: [ ] Not yet created

---

## Dependencies

- Depends on: None (Foundation layer — no upstream systems)
- Unlocks: Story 002 (JSON loader needs EquipmentDef class), Story 003 (validation needs Catalog container)
