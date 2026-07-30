# ADR-0001: DI Container & Scene Bootstrap

## Status
Accepted

**Gate**: TD-ADR APPROVED 2026-07-22 — `@abstract` on RefCounted verified non-functional in Godot 4.7.1; manual `_init()` guard confirmed as correct primary enforcement. All @abstract references removed from code examples and decision text. Engine Compatibility table updated with verified findings.

## Date
2026-07-21

## Engine Compatibility

| Field | Value |
|-------|-------|
| **Engine** | Godot 4.7.1 |
| **Domain** | Core / Scripting |
| **Knowledge Risk** | HIGH — version is 4 releases beyond LLM training cutoff |
| **References Consulted** | `docs/engine-reference/godot/VERSION.md`, `docs/engine-reference/godot/breaking-changes.md`, `docs/engine-reference/godot/deprecated-apis.md`, `docs/engine-reference/godot/current-best-practices.md` |
| **Post-Cutoff APIs Used** | `RefCounted` as simulation base class (stable); `@abstract` decorator (4.5+) is **NOT** used — verified non-functional on `RefCounted` in 4.7.1 (see Decision section 2) |
| **Verification Required** | Manual `_init()` guard: verify that `SimSystem.new()` produces a `push_error` at runtime in Godot 4.7.1; verify that `RefCounted` instances survive across `await` boundaries without premature free |
| **Verified (2026-07-22)** | `@abstract` on `RefCounted`: **FAILED** — engine does NOT enforce. `RefCounted`+`@abstract` instantiates silently. `@abstract` applies to `Node`/`Control` only. Manual `_init()` guard confirmed correct approach. |

## ADR Dependencies

| Field | Value |
|-------|-------|
| **Depends On** | None |
| **Enables** | ADR-0002 (Storage Format), ADR-0003 (GridStateReader Contract), all future ADRs that reference any of the 12 simulation systems |
| **Blocks** | All src/ implementation — no game code can be written until DI and bootstrap patterns are decided |
| **Ordering Note** | Must be Accepted before any `src/` code is written; test infrastructure (GUT + simulation harness) depends on constructor signatures defined here |

## Context

### Problem Statement

The game has 12 simulation systems (GridSystem, TimeSystem, PlacementSystem, Navigation,
MemberSim, Congestion, ZoneRules, Satisfaction, Economy, Shop, SelectionSystem, SaveLoad),
all designed as `RefCounted` objects with no scene-tree presence. Each has typed
dependencies on other systems. Without a defined injection pattern, constructor signature
convention, and initialization order, the systems will either couple through Autoload
singletons (untestable) or have ad-hoc wiring that breaks when load order changes.

This decision must be made first — it defines the "skeleton" that all other ADRs
reference for constructor signatures and lifecycle.

### Constraints

- All 12 systems are `RefCounted` — no `Node` inheritance, no scene-tree attachment
- GDScript `RefCounted` does not support typed `_init()` arguments cleanly; a factory
  or two-phase init pattern is needed
- Godot 4.5+ `@abstract` was considered for base-class contract enforcement but is
  **not available for `RefCounted`** — verified non-functional in 4.7.1 (Node/Control only).
  A manual `_init()` guard is used instead.
- Input-requiring systems (PlacementSystem, SelectionSystem) need Node bridges because
  `RefCounted` cannot receive `_input()` or `_process()` callbacks
- TimeSystem must be initialized before any tick-driven system calls `register_system()`
- Initialization is a strict topological order — no cycles exist, but ordering within
  tiers must be enforced by the orchestrator
- Per technical preferences: DI over Autoload, systems must be testable in isolation
  with mocked dependencies
- `EquipmentCatalog` and `LevelLoader` are external data sources whose instantiation
  details are outside the scope of this ADR. `EquipmentCatalog.load(strict_mode, data_path)`
  reads catalog definitions from a `.tres` or `.json` file; `LevelLoader` provides
  the `buildable_snapshot` for GridSystem deserialization. Their exact type (Resource,
  RefCounted, or Node) will be decided by their respective system ADRs.

### Requirements

- Every system receives its dependencies through typed parameters, never through
  global lookups or Autoload string-names
- Initialization order is enforced programmatically (not by convention or comment)
- Unit tests can construct any system in isolation by injecting mock dependencies
- The scene tree bootstrap is a single composition root — no scattered `add_child()`
  calls in `_ready()` across multiple scenes
- Save/Load can reconstruct the exact same initialization sequence deterministically
- Systems that need input (PlacementSystem, SelectionSystem) receive it through a
  thin bridge Node, not by becoming Nodes themselves

## Decision

### 1. Two-Phase Init Pattern (Factory Method over `_init()`)

All simulation systems expose an `init(...)` method that receives typed dependencies,
rather than using GDScript's `_init()`. This avoids GDScript's limitations with
`RefCounted` constructor overloading and makes the dependency list visible in
the method signature.

```gdscript
# Base class for all simulation systems
class_name SimSystem extends RefCounted

## Manual guard: prevents direct instantiation of the base class.
## @abstract is NOT used — verified non-functional on RefCounted in Godot 4.7.1.
func _init() -> void:
    if get_script() == SimSystem:
        push_error("SimSystem is abstract — do not instantiate directly")

## Called once after all dependencies are injected.
## Override in subclasses for post-init setup (e.g., TimeSystem.register_system()).
func _post_init() -> void:
    pass
```

Concrete example:

```gdscript
class_name PlacementSystem extends SimSystem

var _grid: GridSystem
var _catalog: EquipmentCatalog

func init(grid: GridSystem, catalog: EquipmentCatalog) -> void:
    _grid = grid
    _catalog = catalog
```

**Key rule**: `init()` must only be called once. Calling `init()` on an already-initialized
system is a hard error (assertion in debug; logged in release). A system's `init()` may
store references but must not trigger side effects — side effects go in `_post_init()`.

### 2. SimSystem Base Class Hierarchy (Manual Abstract Guard)

A single `SimSystem` base class enforces that all systems share the
`_post_init()` hook and provides a `system_name()` debug method. Direct
instantiation of `SimSystem` is prevented by a **manual `_init()` guard**:

```gdscript
class_name SimSystem extends RefCounted

func _init() -> void:
    if get_script() == SimSystem:
        push_error("SimSystem is abstract — do not instantiate directly")
```

**Why not `@abstract`?** Godot 4.5 introduced `@abstract` for `Node`-derived
classes, but it is **NOT** supported on `RefCounted` in Godot 4.7.1. Testing
(2026-07-22) confirmed:
- `RefCounted` classes with `@abstract` instantiate silently — no engine-level enforcement
- `get_class()` returns `"RefCounted"` for all inner classes regardless of `@abstract`
- Missing override methods are NOT detected at parse time or runtime
- The `@abstract` keyword applies to `Node`/`Control` scene classes only

The manual `_init()` guard is therefore the **primary** enforcement mechanism,
not a fallback. It fires at runtime (during `new()`) and produces a visible
`push_error` in the Godot debugger output. This is a weaker guarantee than
parse-time rejection — it relies on the guard being present in the `_init()`
method and on tests or developer attention catching the error message.
However, since the base class is written once and never needs to change, this
is sufficient: the guard is verified by a one-time GUT smoke test
(see Validation Criteria #1).

`_post_init()` is a concrete method with an empty default body — it is NOT
abstract or guarded. Only systems that need post-injection setup (e.g.,
`TimeSystem.register_system()`) override it. Making it mandatory would force
stateless systems like ZoneRules or GridSystem to declare empty method bodies,
producing no-op boilerplate.

### 3. Presentation Bridge Pattern

Systems that need Godot input events or frame callbacks use a **thin bridge Node**.
The bridge is a minimal Node owned by the composition root; it forwards events to
the RefCounted system and holds no logic of its own.

```gdscript
## Thin Node that forwards mouse/keyboard input to PlacementSystem.
## Owned by SimulationOrchestrator. Zero logic — pure forwarding.
class_name PlacementInputBridge extends Node

var _system: PlacementSystem

func init(system: PlacementSystem) -> void:
    _system = system
    set_process_input(true)

func _input(event: InputEvent) -> void:
    if event is InputEventMouseButton:
        if event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
            _system.on_mouse_pressed(_to_grid(event.position))
        elif event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
            _system.on_drop()
    elif event is InputEventMouseMotion:
        _system.on_mouse_moved(_to_grid(event.position))
    elif event is InputEventKey:
        if event.keycode == KEY_R and event.pressed:
            _system.on_rotate_pressed()
        elif event.keycode == KEY_ESCAPE and event.pressed:
            _system.on_cancel()
    elif event is InputEventKey and event.keycode == KEY_ESCAPE and event.pressed:
        _system.on_cancel()

func _notification(what: int) -> void:
    if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT:
        _system.on_focus_lost()

func _to_grid(screen_pos: Vector2) -> Vector2i:
    return _system.world_to_grid(screen_pos)  # PlacementSystem exposes public world_to_grid()
```

Bridges are created for:
- **PlacementInputBridge** — mouse drag, rotate (R), cancel (Esc)
- **SelectionInputBridge** — click to select, Del to sell, Esc to deselect

Systems with no input requirements (GridSystem, TimeSystem, Navigation, MemberSim,
Congestion, ZoneRules, Satisfaction, Economy, Shop, SaveLoad) have no bridge.

### 4. SimulationOrchestrator — Single Composition Root

One `Node`-based class, `SimulationOrchestrator`, is the single composition root.
It is attached to the main scene and owns all 12 systems + bridges.

```
SimulationOrchestrator (Node)
├── Systems (RefCounted, held as fields)
│   ├── GridSystem
│   ├── TimeSystem
│   ├── PlacementSystem
│   ├── Navigation
│   ├── MemberSim
│   ├── Congestion
│   ├── ZoneRules
│   ├── Satisfaction
│   ├── Economy
│   ├── Shop
│   ├── SelectionSystem
│   └── SaveLoad
├── Bridges (Node children)
│   ├── PlacementInputBridge
│   └── SelectionInputBridge
└── Tick Loop
    └── _on_tick_timer_timeout() → drives TimeSystem → cascade
```

### 5. Initialization Order (Enforced Topologically)

`SimulationOrchestrator._ready()` executes initialization in strict order. Each tier
completes fully before the next begins:

```
Tier 0 — Leaf nodes (no upstream deps):
  catalog = EquipmentCatalog.load(strict_mode, data_path)
  grid = GridSystem.new(); grid.init(level_definition)
  time = TimeSystem.new(); time.init(master_seed)

Tier 1 — Depends on Tier 0:
  placement = PlacementSystem.new(); placement.init(grid, catalog)
  nav = Navigation.new(); nav.init(grid)

Tier 2 — Depends on Tier 1 + Tier 0:
  member_sim = MemberSim.new(); member_sim.init(grid, nav, catalog, time)
  zone_rules = ZoneRules.new(); zone_rules.init(catalog)

Tier 3 — Depends on Tier 2 + Tier 0:
  congestion = Congestion.new(); congestion.init(time, member_sim, grid, nav, catalog)

Tier 4 — Depends on Tier 3 + Tier 2:
  satisfaction = Satisfaction.new(); satisfaction.init(time, zone_rules, congestion, member_sim)

Tier 5 — Depends on Tier 2 + Tier 0:
  economy = Economy.new(); economy.init(time, member_sim)

Tier 6 — Depends on Tier 5 + Tier 1 + Tier 0:
  shop = Shop.new(); shop.init(economy, catalog, placement)
  selection = SelectionSystem.new(); selection.init(grid, catalog, economy, placement)

Tier 7 — Coordinator (depends on all):
  save_load = SaveLoad.new(); save_load.init(time, grid, member_sim, congestion,
      satisfaction, economy, placement, selection, nav, level_loader)

Post-init (all systems exist):
  for sys in all_systems: sys._post_init()   # register_system() calls happen here
  SaveLoad hooks tick_completed via time
  bridges created and attached
  TimeSystem starts paused
```

Tier 4 (Satisfaction) and Tier 5 (Economy) have no mutual dependency and logically
could init in parallel, but GDScript has no threading — sequential init is fine.

### 6. Tick Loop

The orchestrator uses `_process(delta)` to accumulate time and drive the tick
cycle. This is more robust than a `Timer` node for a fixed-interval simulation:
it correctly handles frame spikes (catching up with multiple ticks per frame,
capped at `MAX_TICKS_PER_FRAME = 8`) and avoids timer drift on unstable
framerates.

```gdscript
func _process(delta: float) -> void:
    _time_system.accumulate(delta)
    while _time_system.has_tick_ready():
        _on_tick()
        _time_system.commit_tick()
```

Each tick, `_on_tick()` calls systems in fixed order:
```
MemberSim.on_tick()    → moves members, updates reservations
Congestion.on_tick()   → reads MemberSim positions, updates prev/next
Satisfaction.on_tick() → reads Congestion(t-1) + ZoneRules, updates global_satisfaction
Economy.on_tick()      → reads member_completed_visit events, adjusts balance
```

`TimeSystem.tick_completed(tick_count)` fires at the end of each tick sequence —
SaveLoad hooks this for boundary-save and HUD updates tick display.

Tick order is **hardcoded in the orchestrator**, not configurable. Changing it
would break the Congestion(t-1) feedback loop contract.

### Architecture Diagram

```
┌──────────────────────────────────────────────────────────────┐
│                    SCENE TREE (Godot)                         │
│                                                               │
│  Main.tscn                                                    │
│  └── SimulationOrchestrator (Node)                            │
│      ├── PlacementInputBridge (Node)                          │
│      │   └── forwards → PlacementSystem (RefCounted)          │
│      ├── SelectionInputBridge (Node)                          │
│      │   └── forwards → SelectionSystem (RefCounted)          │
│      ├── HUD (Node) — reads Economy, Satisfaction, TimeSystem │
│      ├── BuildShopUI (Node) — reads Shop, Economy, Catalog    │
│      ├── Overlay (Node) — reads Congestion, GridSystem        │
│      └── _process(delta) — tick driver (delta accumulation)    │
│                                                               │
│  ┌──────────────────────────────┐                             │
│  │   RefCounted Systems (held   │                             │
│  │   as fields on Orchestrator) │                             │
│  │                              │                             │
│  │  ┌──────────┐  ┌──────────┐ │                             │
│  │  │GridSystem│  │TimeSystem│ │  Foundation                  │
│  │  └────┬─────┘  └────┬─────┘ │                             │
│  │       │              │       │                              │
│  │  ┌────┴─────┐       │       │                             │
│  │  │Placement │  ┌────┴─────┐ │  Core                        │
│  │  │Navigation│  │MemberSim │ │                              │
│  │  └────┬─────┘  └────┬─────┘ │                             │
│  │       │              │       │                              │
│  │  ┌────┴─────┐  ┌────┴─────┐ │                             │
│  │  │ZoneRules │  │Congestion│ │  Feature                     │
│  │  └────┬─────┘  └────┬─────┘ │                              │
│  │       │              │       │                              │
│  │  ┌────┴─────┐  ┌────┴─────┐ │                             │
│  │  │Satisfact │  │ Economy  │ │  Feature                     │
│  │  └──────────┘  └────┬─────┘ │                              │
│  │                     │       │                              │
│  │  ┌──────────┐  ┌────┴─────┐ │                             │
│  │  │  Shop    │  │Selection │ │  Feature / Presentation       │
│  │  └──────────┘  └──────────┘ │                              │
│  │                             │                              │
│  │  ┌──────────────────────┐   │                             │
│  │  │      SaveLoad        │   │  Foundation (Coordinator)    │
│  │  └──────────────────────┘   │                              │
│  └──────────────────────────────┘                             │
└──────────────────────────────────────────────────────────────┘
```

### Key Interfaces

#### SimSystem Base

```gdscript
class_name SimSystem extends RefCounted

## Manual guard: prevents direct instantiation of the base class.
## @abstract is NOT used — verified non-functional on RefCounted in Godot 4.7.1.
func _init() -> void:
    if get_script() == SimSystem:
        push_error("SimSystem is abstract — do not instantiate directly")

## Called after all system.init() calls complete. Override for side effects
## that require all dependencies to be fully initialized.
func _post_init() -> void:
    pass

## Returns a short name for logging / debug (e.g. "GridSystem").
## Override in subclasses.
func system_name() -> String:
    return "SimSystem"
```

#### Injection Contract (per system)

| System | Constructor (`init()` signature) | Post-Init Action |
|--------|----------------------------------|------------------|
| GridSystem | `init(level_definition: Dictionary)` | none |
| TimeSystem | `init(master_seed: int)` | none |
| PlacementSystem | `init(grid: GridSystem, catalog: EquipmentCatalog)` | none |
| Navigation | `init(grid: GridSystem)` | none |
| MemberSim | `init(grid: GridSystem, nav: Navigation, catalog: EquipmentCatalog, time: TimeSystem)` | `time.register_system("MemberSim")` |
| ZoneRules | `init(catalog: EquipmentCatalog)` | none (stateless) |
| Congestion | `init(time: TimeSystem, member_sim: MemberSim, grid: GridSystem, nav: Navigation, catalog: EquipmentCatalog)` | `time.register_system("Congestion")` |
| Satisfaction | `init(time: TimeSystem, zone_rules: ZoneRules, congestion: Congestion, member_sim: MemberSim)` | `time.register_system("Satisfaction")` |
| Economy | `init(time: TimeSystem, member_sim: MemberSim)` | `time.register_system("Economy")` |
| Shop | `init(economy: Economy, catalog: EquipmentCatalog, placement: PlacementSystem)` | none |
| SelectionSystem | `init(grid: GridSystem, catalog: EquipmentCatalog, economy: Economy, placement: PlacementSystem)` | none |
| SaveLoad | `init(time: TimeSystem, grid: GridSystem, member_sim: MemberSim, congestion: Congestion, satisfaction: Satisfaction, economy: Economy, placement: PlacementSystem, selection: SelectionSystem, nav: Navigation, level_loader: LevelLoader)` | subscribes to `time.tick_completed` |

## Alternatives Considered

### Alternative 1: Autoload Singletons

- **Description**: Register each system as a Godot Autoload. Any system accesses
  any other via `GridSystem.instance` or similar global accessor.
- **Pros**: Zero wiring code; Godot native; systems are trivially accessible from
  any scene
- **Cons**: Systems untestable in isolation (cannot mock Autoloads); hidden
  dependency graph (no way to know what depends on what without reading all source);
  load-order conflicts are silent data races; violates project technical preference
  of "DI over Autoload"
- **Rejection Reason**: Directly contradicts project coding standard requiring
  dependency injection for testability. Autoload coupling makes unit tests
  impossible without global state teardown between tests.

### Alternative 2: Godot Resources (.tres) as DI Container

- **Description**: Define each system as a `Resource` subclass. Wire dependencies
  via `@export var grid_system: GridSystem` in the editor. Godot resolves references
  from .tres files.
- **Pros**: Visual editor wiring; hot-reload of individual systems during development;
  Godot-native serialization
- **Cons**: `Resource` has heavier lifecycle than `RefCounted` (reference counting
  with caching); `@export` on typed custom Resources has unpredictable behavior
  in Godot 4.x; editor-based wiring breaks in headless CI (tests can't load .tres
  files reliably); circular reference risk in Godot's resource loader
- **Rejection Reason**: Editor-coupled wiring is incompatible with headless CI
  testing. The GUT test runner does not load .tres dependency graphs reliably.
  This would make the "testable in isolation" requirement impossible to satisfy.

### Alternative 3: Pure Constructor Injection via _init()

- **Description**: Pass all dependencies through GDScript's `_init()` method
  using positional or dictionary arguments.
- **Pros**: Single-phase init; dependencies immutable after construction;
  most idiomatic OOP pattern
- **Cons**: GDScript `RefCounted._init()` does not support typed parameters in
  a way that subclasses can cleanly override; passing 4-10 typed parameters
  through `_init()` with GDScript's limited overloading is fragile; `_init()`
  runs before the object is fully allocated — certain GDScript features are
  unavailable
- **Rejection Reason**: Practical GDScript limitation. Two-phase init
  (`init()` + `_post_init()`) is the idiomatic GDScript workaround for
  `RefCounted` constructor limitations, used by the engine's own patterns
  (e.g., `Resource.setup_local_to_scene()`).

## Consequences

### Positive

- Every system's dependencies are visible in its `init()` signature — no hidden coupling
- Systems are testable in isolation: GUT tests construct `MySystem.new()` and inject
  mock dependencies via `init()`
- The topological initialization order is enforced by the orchestrator, not by
  convention — reordering requires an explicit code change with review
- Bridges isolate input handling from simulation logic; the bridge can be replaced
  for automated testing without touching the system
- Single composition root makes it trivial to add a "reset simulation" feature
  (discard orchestrator, reconstruct all systems)

### Negative

- Two-phase init means a window exists where the system is constructed but
  `init()` has not been called. Systems must guard against use-before-init
  (assertion in each public method)
- `SimulationOrchestrator` is a largish class (~150-200 lines of wiring) — but
  this is intentional: it's the only place where the full dependency graph is
  spelled out
- Adding a new system requires touching exactly two places: the system file
  and the orchestrator's `_ready()` — not scattered across the codebase
- Bridges add boilerplate (~40-60 lines each) for input-forwarding classes
  that contain zero logic

### Risks

- **Manual `_init()` guard is runtime-only (no parse-time enforcement)**: The guard
  in `SimSystem._init()` fires at runtime when `SimSystem.new()` is called, producing
  a `push_error` in the Godot debugger. It does NOT prevent the instance from being
  created — it only prints an error. This is the best available enforcement for
  `RefCounted` base classes in Godot 4.7.1 (since `@abstract` is `Node`/`Control`-only).
  Mitigation: a GUT smoke test explicitly calls `SimSystem.new()` and asserts that
  `push_error` was emitted. All concrete system tests verify that their system's
  `new()+init()` succeeds without error.
- **Premature RefCounted free across `await` boundaries**: Godot's RefCounted
  instances are freed when their reference count hits zero. If a system is
  referenced only by a local variable in an async method and that method
  `await`s, the RefCounted can be freed mid-await. Mitigation: all systems
  are held as permanent `var` fields on the SimulationOrchestrator (a Node),
  keeping one permanent reference alive for the lifetime of the session.
  System-level RefCounted free during normal gameplay is therefore impossible
  — the `await` release risk applies only to (a) the Orchestrator itself being
  freed (game exit, scene reload) or (b) a system method creating temporary
  RefCounted objects at an `await` boundary without holding a reference.
  **Guidance**: system methods should avoid `await` — use signal-based
  sequencing (`tick_completed`, `placement_committed`) or timer callbacks
  instead. If a system method must use `await`, it must hold a `var _keep =
  self` local before the await point.
- **Orchestrator becoming a God object**: The orchestrator owns wiring, ticks,
  and bridges — it could accumulate logic over time. Mitigation: the orchestrator's
  contract is "wiring + tick dispatch + bridge ownership." Any logic beyond that
  belongs in a system. This is enforced by code review against a checklist:
  does the orchestrator method have any `if` statement not related to mode/state
  toggling?

## GDD Requirements Addressed

| GDD System | Requirement | How This ADR Addresses It |
|------------|-------------|--------------------------|
| grid-system.md | "Must be instantiated before any spatial consumer" | Initialization order Tier 0 — GridSystem is created before all dependents |
| time-system.md | "register_system() must be called during init, before ticks fire" | `_post_init()` phase handles all `register_system()` calls after all systems exist, before tick timer starts |
| placement-system.md | "Depends on GridSystem and EquipmentCatalog; must receive both via constructor" | `PlacementSystem.init(grid, catalog)` signature defined |
| navigation.md | "Depends on GridSystem; AStarGrid2D configured at init" | `Navigation.init(grid)` signature; Tier 1 ordering ensures GridSystem exists first |
| member-sim.md | "Depends on TimeSystem, GridSystem, Navigation, EquipmentCatalog" | `MemberSim.init(grid, nav, catalog, time)` signature; `_post_init()` registers with TimeSystem |
| congestion.md | "Reads MemberSim positions after MemberSim tick completes" | Tick order fixed: MemberSim → Congestion → Satisfaction → Economy; Congestion(t-1) feedback loop preserved |
| zone-rules.md | "Pure function; receives GridStateReader as parameter, not held reference" | `ZoneRules.init(catalog)` — no grid_system in init; snapshot passed at call time |
| satisfaction.md | "Depends on TimeSystem, ZoneRules, Congestion, MemberSim" | `Satisfaction.init(time, zone_rules, congestion, member_sim)` signature |
| economy.md | "Depends on TimeSystem and MemberSim; revenue from member_completed_visit" | `Economy.init(time, member_sim)` signature; signal subscription in `_post_init()` |
| shop-purchase.md | "Depends on Economy, EquipmentCatalog, PlacementSystem" | `Shop.init(economy, catalog, placement)` signature |
| selection-system.md | "Depends on GridSystem, EquipmentCatalog, Economy, PlacementSystem" | `SelectionSystem.init(grid, catalog, economy, placement)` signature |
| save-load.md | "Coordinates serialize/deserialize on all systems; strict load order" | `SaveLoad.init(...)` receives all systems; load order enforced in SaveLoad itself (ADR-0002 details serialization) |

## Performance Implications
- **CPU**: Negligible — init happens once at boot. Tick dispatch is 4 sequential
  function calls per tick (≤0.1ms total for dispatch overhead).
- **Memory**: 12 RefCounted system objects (~1-5 KB each) + 2 bridge Nodes (~200
  bytes each). Total orchestrator overhead < 50 KB.
- **Load Time**: All system construction happens in `_ready()`, before the first
  frame. With 12 lightweight RefCounted objects, total init time is < 1ms.
- **Network**: N/A — single-player, no networking.

## Migration Plan
N/A — this is a greenfield project. No existing code to migrate.

## Validation Criteria
1. `SimSystem.new()` (base class) produces a `push_error` at runtime (verified via
   GUT `assert_errored` or equivalent) — confirms the manual `_init()` guard works
2. A GUT test constructs any system in isolation: `var sys = MySystem.new(); sys.init(mock_dep1, mock_dep2)`
   succeeds
3. A GUT test verifies that calling `init()` twice on the same system triggers
   an assertion failure
4. `SimulationOrchestrator._ready()` completes without error in a headless
   `godot --headless --script tests/setup/test_orchestrator_init.gd` run
5. A minimal scene with SimulationOrchestrator runs 100 ticks with all 12
   systems wired and produces no errors in the Godot debugger output

## Related Decisions
- ADR-0002: Storage Format — Save Blob, Catalog Data, Level Geometry (uses init signatures defined here)
- ADR-0003: GridStateReader Contract — defines `get_placed_instances()` signature that ZoneRules depends on
- `docs/architecture/architecture.md` — System Layer Map and Data Flow sections (source of truth for layer assignments)
- `design/gdd/systems-index.md` — System registry with status for all 12 systems
