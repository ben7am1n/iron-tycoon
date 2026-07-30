# 撸铁大亨 (Iron Tycoon) — Master Architecture

## Document Status
- **Version**: 1.0
- **Last Updated**: 2026-07-21
- **Engine**: Godot 4.7.1
- **GDDs Covered**: #1–#16 (MVP) + #17–#22 (VS, deferred)
- **ADRs Referenced**: ADR-0001–ADR-0007 (all 7 required ADRs written, Proposed status, 2026-07-21)
- **Technical Director Sign-Off**: 2026-07-21 — APPROVED
- **Lead Programmer Feasibility**: Skipped (Lean review mode)

## Engine Knowledge Gap Summary

⚠️ Godot 4.7.1 is beyond LLM training cutoff (~4.3). 4 major versions contain
breaking changes and new APIs. Full inventory in Phase 0d above.

**HIGH RISK domains**: GDScript `@abstract` (4.5), dual-focus UI (4.6),
`DrawableTexture2D` (4.7 — unverified), `tween_await()` (4.7), Navigation
dedicated 2D server (4.5).

**Requires runtime verification before production**: AStarGrid2D cross-rebuild
tie-break determinism, `@abstract` missing-override behavior.

## System Layer Map

```
┌────────────────────────────────────────────────────────────────┐
│  PRESENTATION LAYER                                              │
│  #8 Congestion/Flow Overlay · #13 SelectionSystem               │
│  #15 Build/Shop UI · #16 HUD · #17 Info Panel                   │
│  #20 Onboarding · #21 Audio · #22 Settings & Accessibility       │
├────────────────────────────────────────────────────────────────┤
│  FEATURE LAYER                                                   │
│  #6 MemberSim · #7 Congestion · #9 ZoneRules · #10 Satisfaction │
│  #11 Economy · #12 Shop/Purchase · #18 Milestones               │
│  #19 Progression/Unlocks                                         │
├────────────────────────────────────────────────────────────────┤
│  CORE LAYER                                                      │
│  #4 PlacementSystem · #5 Navigation (AStarGrid2D)               │
├────────────────────────────────────────────────────────────────┤
│  FOUNDATION LAYER                                                │
│  #1 GridSystem · #2 EquipmentCatalog · #3 TimeSystem            │
│  #14 SaveLoad (coordinator — owns no state)                     │
├────────────────────────────────────────────────────────────────┤
│  PLATFORM LAYER                                                  │
│  Godot 4.7.1 Engine API                                          │
└────────────────────────────────────────────────────────────────┘
```

### Layer Dependency Rules

1. **Downward-only references**: Higher layers may depend on lower layers.
   Lower layers MUST NOT reference higher layers.
2. **Same-layer communication via signals or Foundation state**: Feature
   systems communicate through shared GridSystem state or TimeSystem signals;
   they do not directly hold references to each other (exception:
   Economy's `balance_changed` signal, MemberSim's `member_completed_visit`).
3. **Presentation reads; Presentation never mutates**: All UI systems are
   read-only consumers of lower-layer state. The only exception is pause/speed
   transport (HUD → TimeSystem) and placement drag initiation
   (Build/Shop UI → PlacementSystem).

### Engine Risk by Layer

| Layer | HIGH RISK Engine Touchpoints |
|-------|------------------------------|
| Foundation | GridSystem: `@abstract` class hierarchy (4.5+); SaveLoad: `FileAccess` return types (4.4+) |
| Core | Navigation: AStarGrid2D determinism (UNVERIFIED); dedicated 2D NavigationServer (4.5) |
| Feature | Pure GDScript math — no special engine risk |
| Presentation | Overlay: `DrawableTexture2D` (4.7, UNVERIFIED — fallback selected); HUD: Control offset transforms (4.7 NEW); dual-focus system (4.6+) for all UI |

## Module Ownership

### Foundation Layer

| Module | Owns | Exposes | Consumes | Engine APIs | Risk |
|--------|------|---------|----------|-------------|------|
| **GridSystem** | `occupant_id` array, `buildable` array, `access_ids` dict, `declared_bounds` per-equipment | `is_solid(cell)`, `get_occupant_id(cell)`, `get_access_cells(instance_id)`, `can_place(def, anchor, rot)`, `commit(id, def, anchor, rot)`, `get_dimensions()`, `grid_changed` signal | EquipmentCatalog (via PlacementSystem relay) | `RefCounted`, `PackedInt32Array`, `PackedByteArray`, `Dictionary` | ⚠️ `@abstract` (4.5+) |
| **EquipmentCatalog** | `EquipmentDef` records (immutable) | `get_definition(id) -> EquipmentDef` | External data file (loaded once at boot) | `RefCounted`, file loading (format TBD by ADR) | LOW |
| **TimeSystem** | `tick_count`, `master_seed`, RNG stream states, `paused`, `speed` | `register_system(fn)`, `get_rng(system_id) -> RNG`, `tick_completed(tick_count)` signal, pause/speed control | MemberSim, Congestion, Satisfaction, Economy (tick order registration) | `RefCounted`, `_process` delta accumulator | LOW |
| **SaveLoad** | Nothing — pure coordinator | `save()`, `load()`, result/error status | serialize/deserialize on: TimeSystem, GridSystem, MemberSim, Congestion, Satisfaction, Economy | `FileAccess` (⚠️ store_* returns bool since 4.4) | ⚠️ FileAccess return types |

### Core Layer

| Module | Owns | Exposes | Consumes | Engine APIs | Risk |
|--------|------|---------|----------|-------------|------|
| **PlacementSystem** | `next_instance_id` counter, drag state (DRAGGING/IDLE), current drag def/anchor/rotation | `begin_drag(equipment_id)`, `begin_relocate(instance_id)`, `is_dragging() -> bool`, `placement_committed` signal, `placement_rejected` signal | GridSystem (can_place, commit), EquipmentCatalog (get_definition) | `RefCounted` | LOW |
| **Navigation** | AStarGrid2D instance (rebuilt on occupancy change) | `get_id_path(from, to) -> Array[Vector2i]`, `rebuild(occupancy)`, `is_reachable(from, to) -> bool` | GridSystem (occupancy) | `AStarGrid2D` | 🔴 AStarGrid2D determinism UNVERIFIED (OQ1) |

### Feature Layer

| Module | Owns | Exposes | Consumes | Engine APIs | Risk |
|--------|------|---------|----------|-------------|------|
| **MemberSim** | member state array, reservation map, `member_id_counter` | `member_completed_visit(member_id)` signal | GridSystem (occupancy), Navigation (paths), EquipmentCatalog (use_duration_*), TimeSystem (tick, RNG) | `RefCounted` | LOW |
| **Congestion** | `prev` buffer, per-cell `smoothed`, per-equipment scalar | `per_equipment_congestion(id) -> float`, `per_cell_density(cell) -> float`, `access_reachable` flag | Navigation (get_path), MemberSim (positions) | `RefCounted` | LOW |
| **ZoneRules** | Nothing (stateless pure function) | `evaluate(snapshot: GridStateReader) -> Array[ZoneResult]` | GridSystem (get_placed_instances — ⚠️ GAP), EquipmentCatalog (zone, effects) | `RefCounted` | LOW |
| **Satisfaction** | `global_satisfaction` EMA, `member_accumulators` | `global_satisfaction: float`, `satisfaction_modifier: float` | Congestion, ZoneRules, MemberSim (visit completions) | `RefCounted` | LOW |
| **Economy** | `balance: int` | `can_afford(amount) -> bool`, `spend(amount) -> bool`, `balance_changed(new, delta)` signal | MemberSim (member_completed_visit), TimeSystem (tick order) | `RefCounted` | LOW |
| **Shop/Purchase** | `_purchase_in_flight` flag | `can_purchase(id) -> bool`, `is_unlocked(id) -> bool` | Economy (can_afford, spend), EquipmentCatalog (cost), PlacementSystem (placement_committed, is_dragging) | `RefCounted` | LOW |

### Presentation Layer

| Module | Owns | Exposes | Consumes | Engine APIs | Risk |
|--------|------|---------|----------|-------------|------|
| **Congestion/Flow Overlay** | ImageTexture for heatmap | 10Hz heatmap rendering, access-blocked icons | Congestion, ZoneRules | `ImageTexture`, `ShaderMaterial`, `_draw` (⚠️ DrawableTexture2D 4.7 bypasse | ⚠️ 4.7 rendering APIs |
| **SelectionSystem** | `instance_id → data` mapping, current selection state | `selection_changed(instance_id \| null)` signal | GridSystem (get_occupant_id), EquipmentCatalog (get_definition), Economy (credit — ⚠️ GAP), PlacementSystem (begin_relocate) | RefCounted + presentation bridge Node | ⚠️ dual-focus (4.6+) |
| **Build/Shop UI** | Palette rendering state, mode arbitration | Shop palette, drag gate | Shop (can_purchase), PlacementSystem (begin_drag, is_dragging), SelectionSystem (selection_changed), Economy (balance_changed) | Control, `_input`/`_unhandled_input` | ⚠️ dual-focus, Control offset transforms |
| **HUD** | Top-bar Control hierarchy | Money display, satisfaction meter, time/day, pause/speed transport | Economy (balance_changed), Satisfaction (global_satisfaction), TimeSystem (pause/speed/count) | Control, Tween (⚠️ tween_await 4.7 NEW) | ⚠️ Control offset transforms, dual-focus |

### Cross-Cutting Ownership Rules

1. **`instance_id` lifecycle**: Allocated by PlacementSystem (`next_instance_id` counter). GridSystem stores it as `occupant_id` but never allocates. SelectionSystem reads it. **No system may reuse a retired id** within a session (GridSystem Core Rule 7).
2. **`equipment_id` (String)**: Defined in EquipmentCatalog. Immutable, session-stable. Used as foreign key by PlacementSystem, SelectionSystem, ZoneRules, Shop.
3. **`master_seed`**: Generated once at new game. Owned by TimeSystem. Duplicated in save blob for introspection only — TimeSystem's copy is authoritative on load.
4. **RNG streams**: Derived by TimeSystem via FNV-1a64 + SplitMix64 from `master_seed`. Each system gets its own stream via `get_rng(system_id)`. Never derive per-system seeds from `master_seed` alone on load — restore stream states exactly.

---

## Data Flow

### 1. Frame Update Path

```
_physics_process (never used — our tick is _process-driven at 10Hz)
_process:
  TimeSystem.accumulate(delta)
    if tick_should_fire:
      foreach system in [MemberSim, Congestion, Satisfaction, Economy]:
        system.tick(delta=0.1)
      TimeSystem.tick_count++
      TimeSystem.emit("tick_completed", tick_count)

SaveLoad hooks into "tick_completed":
  → defers save to fire between ticks (never mid-tick)

Presentation updates on _process (render-driven):
  Overlay: reads per_cell_density every ~100ms (10Hz)
  HUD: reads balance/satisfaction/time on balance_changed/satisfaction change
```

### 2. Event / Signal Path

```
PlacementSystem (drag complete)
  → GridSystem.commit() → GridSystem.grid_changed(footprint_cells, access_cells)
    → Navigation.rebuild(occupancy) — rebuild paths
    → Overlay — redraw heatmap
    → SelectionSystem — invalidate mapping if affected

PlacementSystem.placement_committed(instance_id, equipment_id, footprint_cells)
  → Shop — deduct money (if _purchase_in_flight set)
  → SelectionSystem — add to instance mapping
  → Overlay — placement feedback

MemberSim.member_completed_visit(member_id)
  → Economy.process_visit(member_id)
    → Economy.balance_changed(new, +R_visit)
      → HUD — money tween
      → Build/Shop UI — re-grey palette

SelectionSystem.selection_changed(instance_id | null)
  → Info Panel — show/hide details
  → Build/Shop UI — suppress placement ghost during selection
```

### 3. Save / Load Path

```
SAVE (triggered by player action → deferred to next tick_completed):
  SaveLoad.serialize_all():
    blob = {
      version: SAVE_FORMAT_VERSION,
      master_seed: TimeSystem.master_seed,
      time_system: TimeSystem.serialize(),
      grid_system: GridSystem.serialize(),
      member_sim: MemberSim.serialize(),
      congestion: Congestion.serialize(),
      satisfaction: Satisfaction.serialize(),
      economy: Economy.serialize()
    }
  → write blob to disk

LOAD:
  SaveLoad.load_all(blob):
    Phase A (validate, zero mutation):
      1. GridSystem.deserialize(data, buildable_snapshot) — dry-run
      2. MemberSim.deserialize() — dry-run
      3. ...each system dry-run...
      Any failure → abort, state untouched

    Phase B (commit):
      1. TimeSystem.deserialize() → forces paused=true
      2. GridSystem.deserialize(data, buildable_snapshot) — real
      3. PlacementSystem.rederive_counter() — max(occupant_id)+1
      3a. SelectionSystem.rebuild_mapping() — seed instance mapping
      4. Navigation.rebuild(occupancy)
      5. MemberSim.deserialize() — real
      6. Congestion.deserialize() — real (prev buffer + smoothed)
      7. Satisfaction.deserialize() — real
      8. Economy.deserialize() — real
```

### 4. Initialisation Order

```
New Game boot:
  1. EquipmentCatalog.load(strict_mode)
  2. GridSystem.init(level_definition)
  3. TimeSystem.init(master_seed)
  4. PlacementSystem.init(grid_system, catalog)
  5. Navigation.init(grid_system)
  6. MemberSim.init(grid_system, nav, catalog, time_system)
  7. Congestion.init(nav, member_sim)
  8. Satisfaction.init(congestion, zone_rules, member_sim)
  9. Economy.init(time_system, member_sim)
  10. Shop.init(economy, catalog, placement_system)
  11. SelectionSystem.init(grid_system, catalog, economy, placement_system)
  12. SaveLoad.init(all_above)
  13. Build/Shop UI, HUD, Overlay — scene-tree nodes, subscribe to signals
  14. Game starts PAUSED (TimeSystem rule)
```

---

## API Boundaries

### Foundation → Higher Layers

```
// GridSystem — spatial authority
interface GridSystemReader:
  func is_solid(cell: Vector2i) -> bool
  func get_occupant_id(cell: Vector2i) -> int
  func get_access_cells(instance_id: int) -> Array[Vector2i]
  func get_dimensions() -> Vector2i
  ⚠️ GAP: func get_placed_instances() -> Array[PlacedInstance]  // ZoneRules needs this

interface GridSystemWriter (PlacementSystem only):
  func can_place(def: EquipmentDef, anchor: Vector2i, rotation: int) -> PlacementResult
  func commit(id: int, def: EquipmentDef, anchor: Vector2i, rotation: int) -> void
  signal grid_changed(footprint_cells: Array, access_cells: Array)

// EquipmentCatalog — read-only data
interface EquipmentCatalog:
  func get_definition(id: String) -> EquipmentDef  // returns null if not found
  // loaded once at boot; no mutators

// TimeSystem — tick driver + RNG
interface TimeSystem:
  func register_system(callback: Callable) -> void  // for tick order
  func get_rng(system_id: String) -> SeededRNG
  func set_speed(multiplier: int) -> void  // 1/2/3
  func toggle_pause() -> void
  signal tick_completed(tick_count: int)
```

### Core → Feature Layer

```
// PlacementSystem — drag/commit orchestrator
interface PlacementSystem:
  func begin_drag(equipment_id: String) -> void  // from shop palette
  func begin_relocate(instance_id: int) -> void   // from SelectionSystem Move
  func is_dragging() -> bool                       // synchronous query
  signal placement_committed(instance_id: int, equipment_id: String, footprint_cells: Array[Vector2i])
  signal placement_rejected(equipment_id: String, anchor: Vector2i, rotation: int, fail_code: int)

// Navigation — pathfinding
interface Navigation:
  func get_id_path(from: Vector2i, to: Vector2i) -> Array[Vector2i]
  func rebuild(occupancy: GridSystemReader) -> void
  ⚠️ HARD GATE (Navigation OQ1): determinism of AStarGrid2D across rebuilds MUST be verified before SaveLoad ships
```

### Feature → Feature / Presentation

```
// MemberSim → Economy (cross-feature signal)
signal member_completed_visit(member_id: int)

// Economy → HUD / Shop (read-only + signal)
interface Economy:
  func can_afford(amount: int) -> bool
  func spend(amount: int) -> bool
  ⚠️ GAP: func credit(amount: int) -> void  // sell-back — needed by SelectionSystem
  signal balance_changed(new_balance: int, delta: int)

// Shop → Build/Shop UI
interface Shop:
  func can_purchase(equipment_id: String) -> bool
  func is_unlocked(equipment_id: String) -> bool
```

---

## Architecture Principles

1. **DI over Autoload — RefCounted over Node**. Every simulation system is a
   `RefCounted` instance, constructed at boot and injected by the scene bootstrap.
   No system extends `Node` unless it needs scene-tree access (UI, input). This
   makes systems testable headlessly with GUT.

2. **State ownership is singular**. One system owns each piece of state.
   GridSystem owns occupancy. TimeSystem owns tick. Economy owns balance.
   No shared mutable dictionaries between systems. Signals carry data snapshots.

3. **Pure functions where possible**. ZoneRules.evaluate() is a pure function.
   Congestion(t-1) reads are pure against the previous buffer. Preview passes
   speculative snapshots. This eliminates whole categories of concurrency bugs.

4. **Tick boundary consistency**. No save mid-tick. No mutation across tick
   boundaries without `tick_completed`. The tick is the atomic unit of simulation
   state — a load resumes exactly at the start of the saved tick.

5. **Fail loud, fail early, fail all-or-nothing**. Corrupt save → no partial state.
   Catalog validation failure → strict_mode assert or reject single record.
   Never silently degrade. The "no fail state" Pillar 2 applies to *players*,
   not to the codebase's defensive posture.

---

## ADR Audit

### Existing ADRs

7 ADRs written and in **Proposed** status (2026-07-21):

| ADR | Title | Status | Depends On |
|-----|-------|--------|------------|
| ADR-0001 | DI Container & Scene Bootstrap | Proposed | — |
| ADR-0002 | Storage Format — Save Blob, Catalog Data, Level Geometry | Proposed | ADR-0001 |
| ADR-0003 | GridSystem Read Surface — GridStateReader Contract | Proposed | ADR-0001, ADR-0002 |
| ADR-0004 | Seeded RNG Architecture | Proposed | ADR-0001, ADR-0002 |
| ADR-0005 | Signal Bus & Event Routing | Proposed | ADR-0001, ADR-0004 |
| ADR-0006 | Economy Credit Interface | Proposed | ADR-0005 |
| ADR-0007 | AStarGrid2D Cross-Rebuild Determinism | Proposed | ADR-0001, ADR-0003, ADR-0005 |

All 7 ADRs were approved by Technical Director sign-off on 2026-07-21. Two
hard blockers remain pending physical verification (see Open Questions QQ-01,
QQ-02). Full review at `/architecture-review 2026-07-21`.

### Traceability Coverage

The TR registry (`docs/architecture/tr-registry.yaml`) contains 149 requirement
IDs across all 16 MVP systems, bootstrapped by `/architecture-review` on
2026-07-21. All 149 requirements are covered by at least one ADR — 100% coverage.
No gaps remain.

---

## Required ADRs

### Must Have — Before Any Code (Foundation & Core)

**ADR-0001: DI Container & Scene Bootstrap** — How RefCounted systems are
instantiated, injected, and ordered. Covers: `@abstract` base class hierarchy
verification, the presentation bridge pattern (RefCounted systems get a thin
Node bridge for input/timers), and init order enforcement.
→ **Covers**: TRs from GridSystem(#1), TimeSystem(#3), PlacementSystem(#4),
SelectionSystem(#13), SaveLoad(#14)
→ **Unblocks**: All `src/` code — no system can be written without knowing its
constructor signature and dependency injection pattern.
→ **Engine risk**: `@abstract` (Godot 4.5+) — must verify missing-override
behavior in 4.7.1 headless before adopting.

**ADR-0002: Storage Format — Save Blob, Catalog Data, Level Geometry** —
JSON vs Godot Resource vs custom binary. Covers versioning, strict_mode flag,
migration policy (MVP: exact match only), and where files live on disk.
→ **Covers**: EquipmentCatalog OQ6, SaveLoad OQ5, GridSystem OQ#6
→ **Unblocks**: SaveLoad(#14) implementation, EquipmentCatalog(#2) implementation

**ADR-0003: GridSystem Read Surface — `GridStateReader` Contract** —
Defines the complete read-only interface GridSystem exposes to all consumers.
Specifies the `get_placed_instances()` bulk query that ZoneRules (#9) and
SelectionSystem (#13) need but grid-system.md does not yet define.
→ **Covers**: ZoneRules OQ1 (hard blocker), C-W1 (catalog reconciliation gap)
→ **Unblocks**: ZoneRules(#9) implementation

**ADR-0004: Tick Order & Orchestrator Contract** — Formalizes the tick
sequence (MemberSim → Congestion → Satisfaction → Economy), `tick_completed`
hook, save-at-boundary guarantee, and RNG stream management.
→ **Covers**: TimeSystem OQ1/OQ2/OQ4, SaveLoad Core Rule 1/5
→ **Unblocks**: SaveLoad(#14) determinism guarantee documentation

### Should Have — Before Feature Implementation

**ADR-0005: Presentation Bridge Pattern** — How RefCounted logic systems
(SelectionSystem, PlacementSystem) connect to scene-tree Nodes for input,
timers, and UI. Defines the bridge Node's ownership of `_unhandled_input`,
timer creation, and signal routing.
→ **Covers**: SelectionSystem B2 (refcounted input bridge), Build/Shop UI drag gate

**ADR-0006: Economy Credit Interface** — Adds the `credit(amount)` method to
Economy's public API for sell-back refunds. Defines synchronous timing
(mirrors `spend()`), monotonicity interaction with the one-drag invariant,
and the `balance_changed` emission.
→ **Covers**: SelectionSystem OQ1, Economy OQ3, C-W4

### Can Defer — To Implementation

**ADR-0007: Navigation Determinism Verification** — Documents the result of
AStarGrid2D cross-rebuild tie-break testing in Godot 4.7.1 headless. If
non-deterministic: defines the fallback (e.g. canonical sort of equal-cost
nodes, seeded tie-breaking).
→ **Covers**: Navigation OQ1 (HARD blocker for SaveLoad AC2)

---

## Open Questions

| ID | Summary | Priority | Resolution |
|----|---------|----------|------------|
| QQ-01 | AStarGrid2D cross-rebuild tie-break determinism — unverified in 4.7.1 | **HARD BLOCKER** | ADR-0007 (runtime verification + fallback) |
| QQ-02 | `@abstract` missing-override behavior in 4.7.1 headless | HIGH | ADR-0001 (verify before DI pattern is finalized) |
| QQ-03 | `TICKS_PER_DAY` value — HUD needs it; TimeSystem owns no calendar concept | MEDIUM | game-designer decision before HUD story |
| QQ-04 | Pause menu shell — not in systems-index; SaveLoad and HUD both need it | MEDIUM | producer to add small UI task before shippable build |
| QQ-05 | Economy `credit()` method — defined contract needed before SelectionSystem sell-back can work | MEDIUM | ADR-0006 |
| QQ-06 | GridSystem `get_placed_instances()` — blocking ZoneRules implementation | **HARD BLOCKER** | ADR-0003 |
| QQ-07 | `entrance_cell` / `exit_cell` — MemberSim hard depends; no GDD owns these | MEDIUM | Level definition (ADR-0002 storage format) or GridSystem extension |

