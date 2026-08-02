# ADR-0003: GridSystem Read Surface — GridStateReader Contract

## Status
Accepted

**Gate**: ADR-0001 Accepted (depends-on cleared) 2026-07-22. @abstract references updated to manual _init() guard pattern per ADR-0001 verified findings.

**Amendment (2026-08-02, member-sim Story 004 / TR-MS-007)**: the read surface
is extended with `get_grid_version() -> int` — the grid mutation version
stamp (bumped once per successful `commit()`/`clear()`), consumed by
MemberSim's cached-path invalidation. Additive: existing implementations
override it (GridSystem returns the counter; GridSnapshot delegates to its
base); the base stub push_errors + returns 0 per the OQ#3 fallback protocol.

## Date
2026-07-21

## Engine Compatibility

| Field | Value |
|-------|-------|
| **Engine** | Godot 4.7.1 |
| **Domain** | Core / Scripting (interface design, data contracts) |
| **Knowledge Risk** | HIGH — version is 4 releases beyond LLM training cutoff |
| **References Consulted** | `docs/engine-reference/godot/VERSION.md`, `docs/engine-reference/godot/breaking-changes.md`, `docs/engine-reference/godot/deprecated-apis.md`, `docs/engine-reference/godot/current-best-practices.md` |
| **Post-Cutoff APIs Used** | `@abstract` decorator (4.5+) — same caveat as ADR-0001: unverified on RefCounted base classes in 4.7.1; `Array[PlacedInstance]` typed arrays (4.0+, stable); `RefCounted` as data-transfer-object base (stable) |
| **Verification Required** | `@abstract` on `GridStateReader extends RefCounted` — same smoke test as ADR-0001; typed `Array[PlacedInstance]` iteration performance with 200+ instances — verify < 0.1ms for full scan at 60fps |

## ADR Dependencies

| Field | Value |
|-------|-------|
| **Depends On** | ADR-0001 (DI Container & Scene Bootstrap — `@abstract` pattern on RefCounted, `SimSystem` base class); ADR-0002 (Storage Format — `serialize()`/`deserialize()` contract for GridSystem) |
| **Enables** | ZoneRules (#9) implementation — this is the **hard blocker** (architecture QQ-06); PlacementSystem speculative preview; all future consumers of batch grid queries |
| **Blocks** | ZoneRules (#9), Satisfaction (#10 — reads ZoneRules output), Congestion overlay visualization, any placement-preview UI |
| **Ordering Note** | Must be Accepted before ZoneRules can be implemented. ZoneRules is stateless and can be implemented immediately after this ADR — it has no other blocking dependencies. |

## Context

### Problem Statement

GridSystem's current read surface (`is_solid`, `get_occupant_id`, `get_access_cells`,
`get_dimensions`) is exclusively single-cell query. ZoneRules.evaluate() needs to
iterate over **all placed equipment instances** — their `equipment_id`, `footprint_cells`,
`access_cells`, rotation, and adjacency relationships — to compute per-instance
`{comfort, zone_synergy, spaciousness, total}`. PlacementSystem's drag preview
needs to evaluate ZoneRules on a **speculative** grid (what if this equipment were
placed here?) without mutating the real grid. Both requirements demand a read
surface that (a) exposes batch iteration, (b) is a stable, typed contract that
consumers can depend on, and (c) supports the same interface for both real and
speculative grid states.

This is architecture QQ-06 — a documented hard blocker. Without this ADR, ZoneRules
cannot be implemented, which blocks Satisfaction, which blocks the core satisfaction-
driven gameplay loop (支柱2 "松弛不紧绷" — player sees gym quality feedback).

### Constraints

- GridSystem is a RefCounted system per ADR-0001 — not a Node, not a Resource
- GridSystem is the **sole writer** — all mutations go through `commit()` / `clear()`
- ZoneRules.evaluate() must be a **pure function** of a grid snapshot — same input
  always produces same output, no side effects, no RNG
- PlacementSystem needs speculative evaluation during drag — if the preview
  allocates a full GridSystem clone per frame, that's 60 clones/s × ~10 KB = 600 KB/s
  of garbage — must be allocation-light
- Congestion also reads access-cell and footprint-cell layout from GridSystem per tick
  (though it has its own subscription to `grid_changed`, not a per-tick full scan)
- GDScript has no `interface` keyword — the contract must be expressed as either
  an `@abstract` base class or a duck-typing convention
- Per ADR-0002, `PlacedInstance` data must survive a JSON round-trip (serialize as
  part of GridSystem's save payload)

### Requirements

- A typed `get_placed_instances() -> Array[PlacedInstance]` method that returns
  all currently placed equipment with their full spatial and identity data
- The same `GridStateReader` interface works for the real grid AND speculative
  snapshots (placement preview) — ZoneRules doesn't care which it's reading
- The real `GridSystem` implements `GridStateReader` directly (subclass)
- Speculative snapshots are cheap to create (no full grid copy) and disposable
- Every `PlacedInstance` carries enough data for ZoneRules to compute:
  `equipment_id` (for catalog lookup), `footprint_cells` (transformed by rotation),
  `access_cells` (transformed), `anchor` position, `rotation`

## Decision

### 1. GridStateReader — @abstract Base Class

`GridStateReader` is an `@abstract` base class extending `SimSystem` (ADR-0001) that
defines the read-only contract for any grid state — the real `GridSystem`, a
speculative snapshot, or a mock in tests. It extends `SimSystem` so that `GridSystem`
(a concrete simulation system) inherits both the lifecycle hooks (`_post_init()`,
`system_name()`) and the read surface through a single inheritance chain:

```
RefCounted
  └── SimSystem (@abstract)          ← ADR-0001: _post_init(), system_name()
        └── GridStateReader (@abstract)  ← This ADR: read-only spatial contract
              ├── GridSystem (concrete)  ← real grid + write methods
              └── GridSnapshot (concrete) ← speculative view, no write
```

Systems that don't need the grid read surface (ZoneRules, Satisfaction, etc.)
extend `SimSystem` directly. Only `GridSystem` and `GridSnapshot` sit below
`GridStateReader` in the hierarchy.

```gdscript
@abstract
class_name GridStateReader extends SimSystem

## Single-cell queries — the existing read surface.

@abstract
func is_solid(cell: Vector2i) -> bool:
    return false

@abstract
func get_occupant_id(cell: Vector2i) -> int:
    return -1

@abstract
func get_access_cells(instance_id: int) -> Array[Vector2i]:
    return []

@abstract
func get_dimensions() -> Vector2i:
    return Vector2i.ZERO

## Batch query — the new capability this ADR adds.

## Returns all currently placed equipment instances with full spatial+identity data.
## Order is stable within a single grid state version but not guaranteed across
## commits — consumers must not depend on insertion order.
@abstract
func get_placed_instances() -> Array[PlacedInstance]:
    return []
```

`GridSystem` (the real grid) subclasses `GridStateReader` and overrides all methods
with real implementations. Speculative snapshots subclass `GridStateReader` and
overrides with deltas over a base grid.

**Why @abstract and not duck-typing**: GDScript has no `interface` keyword. Duck-typing
("pass any RefCounted that happens to have `is_solid()`") works but provides zero
compile-time safety — a typo in a method name produces a runtime error in the middle
of ZoneRules.evaluate(), discovered only when that code path runs. `@abstract` on a
base class gives parse-time enforcement: a subclass that forgets to implement
`get_placed_instances()` fails at script load, not at runtime.

The `@abstract` caveat from ADR-0001 applies here too — if `@abstract` doesn't work
on RefCounted in Godot 4.7.1, the fallback is the same `_init()` self-check pattern.

### 2. PlacedInstance — Typed Data Transfer Object

`PlacedInstance` is a lightweight RefCounted DTO that carries the spatial+identity
data ZoneRules and other consumers need:

```gdscript
class_name PlacedInstance extends RefCounted

var instance_id: int                # unique, allocated by PlacementSystem
var equipment_id: String             # key into EquipmentCatalog
var anchor: Vector2i                 # top-left cell of the bounding box (grid coords)
var rotation: int                    # 0, 1, 2, 3 (0=canonical, 1=90°CW, 2=180°, 3=270°CW)
var footprint_cells: Array[Vector2i] # transformed (rotated + offset by anchor)
var access_cells: Array[Vector2i]    # transformed (rotated + offset by anchor)

## Convenience: the bounding box of footprint ∪ access, useful for spaciousness calc.
func declared_bounds() -> Vector2i:
    # max_x - min_x + 1, max_y - min_y + 1 over footprint_cells ∪ access_cells
    var xs := footprint_cells.map(func(c): return c.x) + access_cells.map(func(c): return c.x)
    var ys := footprint_cells.map(func(c): return c.y) + access_cells.map(func(c): return c.y)
    if xs.is_empty():
        return Vector2i.ZERO
    return Vector2i(xs.max() - xs.min() + 1, ys.max() - ys.min() + 1)
```

**Why a typed class and not Dictionary**: `Dictionary` has no field validation —
`instance["equipment_id"]` silently returns `null` if the key is misspelled.
`PlacedInstance.equipment_id` produces a parse error if the field doesn't exist.
Typed `Array[PlacedInstance]` enables GDScript's static analyzer to catch type
errors before runtime. The memory overhead of a RefCounted wrapper (~100 bytes/instance)
is negligible — 200 placed instances = ~20 KB.

**Why not a lazy iterator**: A lazy iterator (yield one instance at a time) is
premature optimization. ZoneRules needs to scan all instances to compute zone
synergy (pairwise comparisons within a zone). Congestion needs random access to
per-equipment data. The full `Array[PlacedInstance]` is alloc'd once per query
and can be cached by the caller if needed.

### 3. GridSnapshot — Speculative Copy-on-Write

`GridSnapshot` implements `GridStateReader` for speculative evaluation — placement
preview, ZoneRules "what-if" analysis. It is constructed from a base `GridStateReader`
plus a list of deltas, and resolves queries by checking deltas first (overrides),
then falling through to the base:

```gdscript
class_name GridSnapshot extends GridStateReader

var _base: GridStateReader
var _adds: Dictionary[Vector2i, int]        # cell → occupant_id (overrides)
var _removes: Array[Vector2i]                # cells to treat as empty
var _placed_instances_override: Array[PlacedInstance]  # base + deltas, pre-computed

## Construct a speculative view: base grid + add these instances, remove these cells.
## all_atomically is computed once at construction — the snapshot is immutable after.
func init(base: GridStateReader, add_instances: Array[PlacedInstance], remove_instance_ids: Array[int]) -> void:
    _base = base
    _build_deltas(add_instances, remove_instance_ids)
    _build_placed_instances(add_instances, remove_instance_ids)

func is_solid(cell: Vector2i) -> bool:
    if cell in _removes:
        return false
    if cell in _adds:
        return _adds[cell] != -1
    return _base.is_solid(cell)

# ... same pattern for get_occupant_id, get_access_cells

func get_placed_instances() -> Array[PlacedInstance]:
    return _placed_instances_override  # pre-computed, no per-call allocation
```

**Memory model**: A `GridSnapshot` for a single placement preview allocates:
- `_adds` Dictionary: footprint + access cells for one equipment (~4-9 entries)
- `_removes` Array: empty for placement; non-empty for relocate
- `_placed_instances_override` Array: base instances + new instance (shallow copy of refs)
This is ~500 bytes per snapshot, created per drag frame. At 60fps that's 30 KB/s
of allocations — well within budget. The snapshot is garbage-collected when the
drag frame ends.

**Immutability**: Once constructed, a `GridSnapshot` is never mutated. If the base
grid changes (equipment placed/removed), callers must construct a new snapshot.
This is the same semantic as a database snapshot — point-in-time consistent view.

### 4. GridSystem Implements GridStateReader

`GridSystem` subclasses `GridStateReader` and owns the real grid data. It exposes
the full read surface plus write methods that no other `GridStateReader` implementation
has:

```gdscript
class_name GridSystem extends GridStateReader

# --- GridStateReader overrides (real data) ---

func is_solid(cell: Vector2i) -> bool:
    var idx := cell.y * _width + cell.x
    return _buildable[idx] != 1 or _occupant_id[idx] != -1

func get_occupant_id(cell: Vector2i) -> int:
    return _occupant_id[cell.y * _width + cell.x]

func get_access_cells(instance_id: int) -> Array[Vector2i]:
    if not _reverse_index.has(instance_id):
        return []
    return _reverse_index[instance_id].access_cells

func get_dimensions() -> Vector2i:
    return Vector2i(_width, _height)

func get_placed_instances() -> Array[PlacedInstance]:
    var result: Array[PlacedInstance] = []
    for instance_id in _reverse_index:
        result.append(_to_placed_instance(instance_id))
    return result

# --- Write methods (NOT on GridStateReader) ---

func can_place(def: EquipmentDef, anchor: Vector2i, rot: int) -> PlacementCheckResult:
    # ... bounding check, collision check, access-reachable check ...

func commit(instance_id: int, footprint_cells: Array[Vector2i], access_cells: Array[Vector2i]) -> void:
    # ... update _occupant_id, _reverse_index, emit grid_changed ...

func clear(instance_id: int) -> void:
    # ... reverse of commit ...
```

**The write surface is NOT part of GridStateReader.** Consumers that receive a
`GridStateReader` reference cannot call `commit()` or `clear()` — the abstract
base class doesn't define them. This is enforced by the type system: if you have
a `GridStateReader`, you can only read. If you need to write, you need a `GridSystem`
reference, which the DI container only provides to authorized systems (PlacementSystem,
SaveLoad).

### 5. Serialization

Per ADR-0002, GridSystem's `serialize()` returns a Dictionary with the data needed
to reconstruct occupancy and the reverse index:

```gdscript
func serialize() -> Dictionary:
    return {
        "occupant_id": _occupant_id,           # PackedInt32Array, width*height
        "reverse_index": _serialize_reverse_index(),  # {instance_id: {footprint, access, rotation}}
    }

func deserialize(data: Dictionary, mode: String) -> Dictionary:
    if mode == "validate":
        # verify occupant_id length matches width*height, no overlapping footprints
        return _validate_deserialize(data)
    # mode == "commit"
    _occupant_id = data["occupant_id"]
    _rebuild_reverse_index(data["reverse_index"])
    return {"success": true, "error": ""}
```

`PlacedInstance` objects are not stored directly in the save blob — they are
reconstructed from the reverse index on `get_placed_instances()` calls. The
save blob stores the minimal compact representation (`PackedInt32Array` +
`Dictionary` of spatial data), and the read surface wraps it in typed DTOs.

### Architecture Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                    GRID READ SURFACE                         │
│                                                              │
│  GridStateReader (@abstract, RefCounted)                     │
│  ├── is_solid(cell) → bool                                  │
│  ├── get_occupant_id(cell) → int                             │
│  ├── get_access_cells(instance_id) → Array[Vector2i]        │
│  ├── get_dimensions() → Vector2i                             │
│  └── get_placed_instances() → Array[PlacedInstance]    ← NEW │
│                                                              │
│  ┌────────────────────┐  ┌──────────────────────────┐       │
│  │   GridSystem       │  │   GridSnapshot            │       │
│  │   (real grid)      │  │   (speculative view)      │       │
│  │                    │  │                            │       │
│  │  Read:  real data  │  │  Read:  base + deltas     │       │
│  │  Write: commit(),  │  │  Write: NONE (immutable)  │       │
│  │         clear()    │  │                            │       │
│  │  Owns:  PackedInt  │  │  Owns:  delta dicts       │       │
│  │         Arrays +   │  │         (~500 bytes)       │       │
│  │         reverse    │  │                            │       │
│  │         index      │  │                            │       │
│  └────────┬───────────┘  └───────────┬────────────────┘       │
│           │                          │                         │
│  Consumers with GridSystem ref:      Consumers with GridStateReader ref: │
│  • PlacementSystem (commit/clear)    • ZoneRules.evaluate(snapshot)│
│  • SaveLoad (deserialize)            • Satisfaction (via ZoneRules)│
│  • SelectionSystem (rebuild mapping) • PlacementSystem (preview — │
│                                      │   speculative GridSnapshot)│
│                                      │ • Congestion (read-only)   │
│                                      │ • Overlay (read-only)      │
└─────────────────────────────────────────────────────────────┘

PlacedInstance (RefCounted DTO):
  instance_id: int
  equipment_id: String
  anchor: Vector2i
  rotation: int
  footprint_cells: Array[Vector2i]    # transformed
  access_cells: Array[Vector2i]       # transformed
  declared_bounds() → Vector2i
```

### Key Interfaces

#### GridStateReader (full contract)

```gdscript
@abstract
class_name GridStateReader extends SimSystem

@abstract func is_solid(cell: Vector2i) -> bool
@abstract func get_occupant_id(cell: Vector2i) -> int
@abstract func get_access_cells(instance_id: int) -> Array[Vector2i]
@abstract func get_dimensions() -> Vector2i
@abstract func get_placed_instances() -> Array[PlacedInstance]
```

#### PlacedInstance

```gdscript
class_name PlacedInstance extends RefCounted
var instance_id: int
var equipment_id: String
var anchor: Vector2i
var rotation: int
var footprint_cells: Array[Vector2i]
var access_cells: Array[Vector2i]
func declared_bounds() -> Vector2i
```

#### GridSnapshot constructor

```gdscript
class_name GridSnapshot extends GridStateReader
func init(base: GridStateReader, add_instances: Array[PlacedInstance], remove_instance_ids: Array[int]) -> void
```

## Alternatives Considered

### Alternative 1: Duck-Typing (No Base Class)

- **Description**: Define the contract as documentation only — "any object passed
  to ZoneRules.evaluate() must have `is_solid()`, `get_occupant_id()`, etc."
  No base class, no `@abstract`, no type constraint.
- **Pros**: Zero boilerplate; works with any GDScript object; no `@abstract`
  verification risk
- **Cons**: No compile-time safety — a typo in a method name is a runtime crash
  inside ZoneRules.evaluate() discovered only when that code path runs; no IDE
  autocomplete for `GridStateReader` consumers; cannot use `GridStateReader` as
  a typed parameter in `init()` signatures; no way to discover all implementors
  of the contract (grep for method names?)
- **Rejection Reason**: ADR-0001 already committed to `@abstract` for the `SimSystem`
  base class — using duck-typing for the read surface while `@abstract` for the
  simulation base would be inconsistent. If `@abstract` fails on RefCounted, both
  ADR-0001 and this ADR fall back to manual guards together.

### Alternative 2: GridSystem Exposes PlacedInstance Dictionary Directly

- **Description**: Instead of `get_placed_instances()` on an abstract reader,
  GridSystem exposes `reverse_index: Dictionary` as a public read-only property.
  Consumers iterate the dictionary keys and values directly.
- **Pros**: Simplest implementation — no new class, no new method; existing
  internal data structure is already a Dictionary
- **Cons**: Exposes GridSystem's internal storage format to consumers — changing
  from Dictionary to a different data structure later would break all consumers;
  no way to provide a speculative view (speculative snapshot would need to replicate
  the full Dictionary including internal fields); the Dictionary contains mutable
  nested arrays — a consumer could accidentally mutate them, violating the read-only
  contract
- **Rejection Reason**: Violates encapsulation. The whole point of the read surface
  is to decouple consumers from GridSystem's internal representation. Exposing the
  raw Dictionary makes every consumer a coupling point to the storage format.

### Alternative 3: Separate Query Object (CQRS-Style)

- **Description**: GridSystem has no read methods beyond basic single-cell queries.
  Instead, a separate `GridQueryService` (or similar) is injected into consumers
  that need batch queries. The query service translates high-level queries
  ("all instances in zone X") into low-level grid access.
- **Pros**: Clean separation of commands and queries; query service can cache;
  query service can be a different class from the write model
- **Cons**: Adds a layer of indirection for what is fundamentally "iterate the
  reverse index and return typed objects"; the query service would need a reference
  to GridSystem's internal data anyway — it's an extra class that doesn't abstract
  anything GridSystem couldn't expose directly; ZoneRules doesn't need complex
  queries ("all in zone X") — it processes all instances unconditionally
- **Rejection Reason**: Overengineering for the current requirement set. If the
  read surface grows to include filtered/sorted queries ("top 5 most congested
  equipment"), a query service would be justified. For MVP, "give me all instances"
  is the only batch query needed.

## Consequences

### Positive

- ZoneRules is unblocked — it can be implemented as a pure function of
  `GridStateReader`, tested with mock snapshots, and integrated immediately
- `GridStateReader` typed parameter enables GDScript static analysis — a
  consumer that tries to call `commit()` on a `GridStateReader` gets a parse error
- `GridSnapshot` makes placement preview a first-class concept — PlacementSystem
  can evaluate ZoneRules on "grid + pending placement" without mutating the real
  grid, enabling real-time satisfaction preview during drag
- Tests can create `GridSnapshot` instances with hand-crafted instance lists —
  ZoneRules unit tests need no GridSystem, no TimeSystem, no DI container
- The read/write split is enforced by the type system — write methods exist only
  on `GridSystem`, not on `GridStateReader`

### Negative

- Two `@abstract` base classes (`SimSystem` + `GridStateReader`) double the risk
  surface for the Godot 4.7.1 RefCounted-abstract unverified behavior
- `PlacedInstance` as a typed class adds ~40 lines of DTO code — but the
  alternative (Dictionary) adds zero code and infinite debugging
- `get_placed_instances()` allocates `Array[PlacedInstance]` on each call — if
  called 60×/frame (once per system that needs it), that's 60 allocations.
  Mitigation: consumers cache the result within a frame. The real cost is the
  DTO wrapping, not the array allocation.

### Risks

- **`@abstract` on GridStateReader failing in 4.7.1**: Same risk as ADR-0001,
  amplified because `GridStateReader extends SimSystem` — both `@abstract` checks
  are on the same inheritance chain. If `@abstract` fails on `RefCounted` in 4.7.1,
  neither `SimSystem` nor `GridStateReader` is guarded. The fallback is the same
  manual `_init()` guard, applied at both levels. Verification must test the full
  chain: `GridSystem.new()` should succeed (concrete leaf), `GridStateReader.new()`
  should fail, `SimSystem.new()` should fail.
- **PlacedInstance shallow-copy safety**: `GridSnapshot._placed_instances_override`
  shares `PlacedInstance` references with the base grid's array (shallow copy, not
  deep clone). This is correct ONLY if `PlacedInstance` fields are treated as
  immutable after construction. Callers MUST NOT modify `footprint_cells`,
  `access_cells`, or any other field on a `PlacedInstance` returned by
  `get_placed_instances()`. Violating this would corrupt both the base grid's data
  and any in-flight snapshots. This is enforced by convention, not by the type
  system — GDScript has no `readonly` or `final` field modifier.
- **Stale `get_placed_instances()` across tick boundaries**: If a consumer caches
  the `Array[PlacedInstance]` returned by `get_placed_instances()` beyond the current
  tick, the cached data becomes stale when GridSystem commits or clears instances.
  ZoneRules is safe (evaluates within a single tick, or on a disposable
  GridSnapshot). Future consumers that cache across ticks MUST invalidate on
  `grid_changed`. The performance optimization of caching within a frame is fine;
  caching across frames requires explicit invalidation logic.
- **`declared_bounds()` per-call allocation**: Uses `Array.map()` + array
  concatenation, allocating temporary arrays per call. For 200+ instances called
  per frame, precompute bounds and store as a field on `PlacedInstance` instead of
  using the convenience method. The method is safe for one-off or low-frequency use.
- **`get_placed_instances()` performance at scale**: 200+ placed instances with
  `PlacedInstance` DTO wrapping could exceed 0.1ms for a full scan. Mitigation:
  benchmark with 500 instances in CI; if > 0.5ms, add a dirty flag so that
  `get_placed_instances()` returns a cached array, invalidated on `grid_changed`.
  ZoneRules is the only per-tick consumer; Congestion reads per-equipment data
  through its own subscription path.
- **GridSnapshot correctness**: If the delta logic in `GridSnapshot.is_solid()` /
  `get_occupant_id()` has an off-by-one or missed edge case, ZoneRules will compute
  incorrect scores during placement preview — players see wrong satisfaction numbers
  before placing equipment. Mitigation: GUT test that compares `GridSnapshot` output
  to the equivalent full `GridSystem` state after actually committing the same
  placement; the two must produce identical `get_placed_instances()` results.

## GDD Requirements Addressed

| GDD System | Requirement | How This ADR Addresses It |
|------------|-------------|--------------------------|
| zone-rules.md | evaluate(snapshot: GridStateReader) — pure function of grid state | `GridStateReader` defines the typed contract; `GridSnapshot` provides speculative views for drag preview |
| zone-rules.md | zone_synergy: pairwise comparison of equipment in same zone | `get_placed_instances()` returns all instances with `equipment_id` and `zone_membership` (via catalog lookup) |
| zone-rules.md | spaciousness: perimeter check against grid edges + neighbors | `get_placed_instances()` provides `footprint_cells` and `declared_bounds()`; `is_solid()` checks adjacent cells |
| grid-system.md | GridStateReader read surface — is_solid, get_occupant_id, get_access_cells, get_dimensions | Formalized as `@abstract` base class with typed signatures |
| grid-system.md | [GAP] get_placed_instances() — needed by ZoneRules, not yet in contract | **This is the gap this ADR closes.** Defined with full signature, return type, and semantics. |
| placement-system.md | Drag preview: evaluate ZoneRules on speculative grid before commit | `GridSnapshot.init(base, [proposed_instance], [])` — creates a speculative reader without mutating GridSystem |
| satisfaction.md | Per-instance satisfaction scoring via ZoneRules per tick | `GridStateReader` reference (as `GridSnapshot`) passed to `ZoneRules.evaluate()` |

## Performance Implications
- **CPU**: `get_placed_instances()` full scan + `PlacedInstance` wrapping —
  estimate < 0.1ms for 200 instances (10,000 cells grid). ZoneRules.evaluate()
  is the dominant cost, not the read surface. `GridSnapshot` construction is
  < 0.01ms (delta dict of 4-9 entries + one array filter).
- **Memory**: `PlacedInstance` ~100 bytes each → 200 instances = 20 KB for the
  full array. `GridSnapshot` ~500 bytes per preview (disposable). GridSystem's
  compact storage (PackedInt32Array + Dictionary) is unchanged — DTOs are only
  created on read, not stored permanently.
- **Load Time**: No impact — `get_placed_instances()` is not called during load.
  The reverse index is rebuilt during `deserialize()` and DTOs are created on
  first read demand.
- **Network**: N/A — single-player.

## Migration Plan
N/A — greenfield. GridSystem will be implemented with `GridStateReader` as its
base class from the start. Existing GDDs that reference `get_placed_instances()`
as a gap (zone-rules.md OQ1) will have their "GAP" label removed when this ADR
is Accepted.

## Validation Criteria
1. GUT test: `GridStateReader.new()` fails (parse-time or runtime) — confirms
   `@abstract` works on RefCounted in 4.7.1
2. GUT test: create a `GridSnapshot` with 3 base instances + 1 speculative add,
   call `get_placed_instances()` — returns 4 instances with the speculative
   instance's data correct
3. GUT test: `GridSnapshot` speculative remove — create with `remove_instance_ids=[1]`,
   `get_placed_instances()` excludes instance 1
4. GUT test: `ZoneRules.evaluate(mock_grid_state_reader)` with 3 instances in
   the same zone — computes zone_synergy > 0, test passes with known values
5. GUT test: async — `get_placed_instances()` on a 500-instance grid completes
   in < 0.5ms
6. Manual: `GridSystem` subclasses `GridStateReader` — verify that omitting
   `get_placed_instances()` override produces a parse error in Godot 4.7.1

## Related Decisions
- ADR-0001: DI Container & Scene Bootstrap — `@abstract` pattern on `RefCounted`,
  `GridSystem` as `SimSystem` subclass, DI injects `GridSystem` to authorized writers
- ADR-0002: Storage Format — `serialize()`/`deserialize()` contract for GridSystem's
  compact storage format (PackedInt32Array + Dictionary, not PlacedInstance DTOs)
- `design/gdd/grid-system.md` — defines `GridStateReader` as the abstract read surface,
  `get_placed_instances()` as a documented gap
- `design/gdd/zone-rules.md` — OQ1: "GridStateReader must expose get_placed_instances()"
  — this ADR resolves that open question
- `docs/architecture/architecture.md` — QQ-06: "GridSystem get_placed_instances()
  interface" — this ADR closes that hard blocker
