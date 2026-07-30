# ADR-0005: Signal Bus & Event Routing — Connection Patterns, Tick Dispatch, and grid_changed Propagation

## Status
Accepted

**Gate**: ADR-0001 Accepted, ADR-0004 Accepted (depends-on cleared) 2026-07-22. RefCounted signal support is stable Godot feature; ADR-0001 manual _init() guard does not affect signal architecture.

## Date
2026-07-21

## Engine Compatibility

| Field | Value |
|-------|-------|
| **Engine** | Godot 4.7.1 |
| **Domain** | Core / Scripting (event routing, signal architecture) |
| **Knowledge Risk** | HIGH — version is 4 releases beyond LLM training cutoff |
| **References Consulted** | `docs/engine-reference/godot/VERSION.md`, `docs/engine-reference/godot/breaking-changes.md`, `docs/engine-reference/godot/current-best-practices.md`, `docs/architecture/adr-0001-di-container-scene-bootstrap.md` |
| **Post-Cutoff APIs Used** | `RefCounted` signal support (stable Godot feature — `signal` keyword works on any `Object` subclass, which `RefCounted` is), `Signal.emit()` arity enforcement (unchanged), `tween_await()` (4.7 — not used for event routing) |
| **Verification Required** | Verify that `RefCounted` signal connections survive across `await` boundaries without premature free; verify that signal emit arity mismatch produces a runtime error (not silent) in 4.7.1 — this is critical because GDScript does not check arity at parse time |

## ADR Dependencies

| Field | Value |
|-------|-------|
| **Depends On** | ADR-0001 (DI Container — defines which systems are RefCounted and where bridge Nodes live), ADR-0004 (Seeded RNG — TickContext.rng is passed through the tick dispatch, not via signal) |
| **Enables** | ADR-0006 (Economy credit interface — `member_completed_visit` signal is the trigger), ADR for Save/Load UI wiring, all implementation stories |
| **Blocks** | Any implementation that creates cross-system communication — without a catalog of who emits what and who subscribes, two implementors will invent incompatible protocols |
| **Ordering Note** | Must be Accepted before `src/` code for any system that emits or subscribes to a cross-system signal begins |

## Context

### Problem Statement

The architecture defines 12 RefCounted simulation systems that need to communicate
across layer boundaries. Three distinct communication patterns exist:

1. **Tick dispatch** — TimeSystem drives 4 systems in a fixed order each tick.
   This must be deterministic (same order every tick), non-reentrant (no system's
   `on_tick()` can trigger another tick), and render-decoupled.
2. **Cross-system events** — e.g. `grid_changed` (GridSystem → Navigation, Overlay,
   PlacementSystem), `member_completed_visit` (MemberSim → Economy), `placement_committed`
   (PlacementSystem → SelectionSystem, Overlay). These are fire-and-forget notifications
   with 1:N fan-out.
3. **Input forwarding** — Godot input events arrive at scene-tree `Node`s, but
   PlacementSystem and SelectionSystem are `RefCounted` objects with no scene-tree
   presence. A bridge pattern is needed.

Without a formal catalog of which system owns which signal, which systems subscribe,
and what the payload contract is, two implementors will inevitably produce
incompatible protocols — one expects `grid_changed(cells: Array)` while the other
emits `grid_changed(cells: PackedVector2Array)`.

### Constraints

- All simulation systems extend `RefCounted`, not `Node` (ADR-0001). Godot's
  `signal` keyword works on `RefCounted` (it subclasses `Object`), but there is
  a practical concern: signal connections are reference-counted, and a `RefCounted`
  that goes out of scope while connected will cause crashes. The orchestrator must
  own all systems for the session lifetime.
- GDScript does **not** check signal arity at parse time — emitting 1 arg when
  the connected callable expects 2 produces a runtime error. Every signal must
  have a documented, enforced arity.
- Systems that need input events (`_input()`, `_unhandled_input()`,
  `_unhandled_key_input()`) cannot receive them as `RefCounted` — only `Node`
  subclasses receive input callbacks. A bridge Node is required.
- Godot 4.6 introduced a **dual-focus system**: keyboard/gamepad focus is
  separate from mouse/touch focus. The bridge Node must handle input routing
  consistent with this model — keyboard shortcuts (Esc, Del, R) should use
  `_unhandled_key_input()` (focus-independent), while mouse clicks should use
  `_unhandled_input()` with coordinate conversion.
- Per ADR-0001: the orchestrator is a single `Node` composition root. Bridges
  are owned by the orchestrator, not scattered across scenes.
- No Autoload singletons (forbidden pattern per ADR-0001).

### Requirements

- Every cross-system signal must have exactly one owner (the system whose file
  defines it) and a documented payload contract
- Tick dispatch must be a hardcoded sequence of direct method calls — not
  signal-driven (to prevent reentrant ticks and guarantee order)
- Two systems that never directly reference each other must still be able to
  communicate through signals (e.g., Economy reads `member_completed_visit`
  from MemberSim but receives it as a connected signal, not a direct dep)
- Input events must arrive at RefCounted systems as plain method calls with
  parsed parameters (cells, not screen pixels)
- All signal arities must be documented and enforced by GUT tests

## Decision

### 1. Godot Native Signals on RefCounted — No Custom EventBus

All cross-system signals use Godot's built-in `signal` keyword on `RefCounted`
systems. No custom EventBus singleton, no string-based message dispatch.

```gdscript
# In grid_system.gd — GridSystem owns and emits grid_changed
extends SimSystem
signal grid_changed(footprint_cells_changed: Array, access_cells_changed: Array)

# In navigation.gd — Navigation subscribes during _post_init()
func _post_init() -> void:
    _grid_system.grid_changed.connect(_on_grid_changed)

func _on_grid_changed(footprint_cells: Array, access_cells: Array) -> void:
    for cell in footprint_cells + access_cells:
        _astar.set_point_solid(cell.x, cell.y, _grid_system.is_solid(cell))
    _astar.update()
```

**Why not a custom EventBus:**
- Godot signals are the engine's native pub/sub — they carry type information
  (for documentation), integrate with the editor's signal dock (for debugging),
  and have zero overhead beyond a dictionary lookup per emit.
- A custom EventBus would add an extra layer of indirection, require string-based
  event names (typo-prone), and lose Godot's built-in signal debugging.
- The project already has 8 distinct cross-system signals — they have clear
  owners and consumers, not a generic "anything can emit anything" pattern
  that would justify a bus.

**Why not Autoload signal bus:** Explicitly forbidden by ADR-0001
(`direct_autoload_coupling`). A RefCounted EventBus passed via DI would be
functionally identical to native signals but with more boilerplate.

**Signal emit arity enforcement:** Every signal emit must pass the exact number
of arguments declared in the signal definition. GDScript does not enforce this at
parse time — it crashes at runtime. GUT tests must verify that each signal
emits with the correct arity (see Signal Catalog §3 and Validation Criteria).

### 2. Tick Dispatch: Direct Method Calls, NOT Signal-Driven

`SimulationOrchestrator._advance_tick()` calls each system's `on_tick()` via
direct method invocation in a hardcoded sequence:

```gdscript
func _advance_tick() -> void:
    var ctx := TickContext.new(_time_system.tick_count, _time_system)
    _member_sim.on_tick(ctx)
    _congestion.on_tick(ctx)
    _satisfaction.on_tick(ctx)
    _economy.on_tick(ctx)
    _time_system.increment_tick()
    _time_system.tick_completed.emit(_time_system.tick_count)
```

**Why direct calls, not signals:**
- A `tick` signal would be reentrant by default — a system's slot could
  theoretically emit another tick, creating a stack overflow or infinite loop.
  Direct calls are visibly sequential and non-reentrant.
- The order is semantically meaningful (MemberSim before Congestion, etc.)
  and must be enforced programmatically, not by connect order (which is fragile).
- GDScript is single-threaded, so direct calls guarantee synchronous completion
  before the next system runs — this is what makes "tick boundary" free for
  SaveLoad (time-system.md Core Rule 5).

The only signal in the tick sequence is `tick_completed(tick_count)`, emitted
at the **end** after all systems have run — this is the hook SaveLoad uses for
tick-boundary saves and is the one place where signal-based notification is
appropriate (it's fire-and-forget, with no expectation of returning data).

### 3. Cross-System Signal Catalog

Every cross-system signal is documented here with its owner, consumers, payload,
and arity. No signal exists outside this catalog — any new signal added to a GDD
must be registered here via an ADR amendment.

| # | Signal | Owner | Consumers | Payload | Frequency | Arity |
|---|--------|-------|-----------|---------|-----------|-------|
| S1 | `grid_changed(footprint_cells_changed: Array, access_cells_changed: Array)` | GridSystem | Navigation, Congestion/Overlay, SelectionSystem, PlacementSystem (indirect — PlacementSystem triggers it via `commit()`/`clear()`) | Two `Array[Vector2i]` — cells whose occupancy or access_ids changed | Once per `commit()` or `clear()` call (NOT per drag frame) | 2 |
| S2 | `tick_completed(tick_count: int)` | TimeSystem | SaveLoad (subscribe for boundary saves), HUD (optional — poll `get_tick_count()` instead) | Current tick count (post-increment) | Once per tick (10 Hz) | 1 |
| S3 | `placement_committed(instance_id: int, equipment_id: String, footprint_cells: Array[Vector2i])` | PlacementSystem | SelectionSystem (rebuild mapping), Congestion/Overlay (visual feedback), Build/Shop UI (clear purchase state) | New instance metadata | Once per successful placement | 3 |
| S4 | `placement_rejected(equipment_id: String, anchor: Vector2i, rotation: int, fail_code: int)` | PlacementSystem | Congestion/Overlay (reason-specific feedback) | Rejection metadata with GridSystem's `PlacementFailCode` | Once per rejected drop (NOT on silent cancel) | 4 |
| S5 | `member_completed_visit(member_id: int)` | MemberSim | Economy (revenue trigger), Satisfaction (fold member accumulator) | Member ID that completed their visit quota | Per quota-met departure (NOT on walk-failure or patience exhaust) | 1 |
| S6 | `balance_changed(new_balance: int, delta: int)` | Economy | HUD (display update), Shop (re-evaluate can_afford for displayed items) | New balance and signed change amount | Per balance mutation (income or spend) | 2 |
| S7 | `selection_changed(instance_id: int, equipment_def: Dictionary, cell: Vector2i, rotation: int)` or `selection_changed()` with no args on deselect | SelectionSystem | Info Panel (#17), Build/Shop UI (suppress placement mode while selected) | Selected instance data, or empty on deselect | Per selection/deselection action | 4 or 0 |
| S8 | `congestion_updated()` | Congestion | Congestion/Flow Overlay (#8) — triggers heatmap Image redraw | None (overlay reads current Congestion state directly) | Once per tick after Congestion recomputes (10 Hz) | 0 |

**Signals explicitly NOT in this catalog** (they are internal to a single system):
- `satisfaction_penalty` (MemberSim internal — Satisfaction reads it via
  direct method call during its `on_tick()`, not a signal subscription)
- Timer signals (2s sell-confirm timer — owned by SelectionSystem's bridge
  Node, not simulation state)
- `_process`/`_input` callbacks (engine-owned, forwarded by bridges)

### 4. TickContext Passes RNG, Not Signals

`TickContext` is a lightweight data object passed to each system's `on_tick()`:

```gdscript
class TickContext:
    var tick_count: int
    var rng: RandomNumberGenerator   # this system's sub-stream, or null

    func _init(p_tick_count: int, p_rng: RandomNumberGenerator = null) -> void:
        tick_count = p_tick_count
        rng = p_rng
```

The orchestrator constructs one `TickContext` per tick and passes it to all four
tick-driven systems. Only systems that registered for RNG (MemberSim) receive a
non-null `rng`; others (Congestion, Satisfaction, Economy in current design)
receive `rng = null`.

**Why TickContext carries RNG, not a signal:** The RNG sub-stream is per-system
state that must be available during `on_tick()`. Passing it through a signal
would be indirect and would couple the tick dispatch order to signal connection
order. `TickContext` is a plain data struct — zero overhead, zero indirection.

### 5. Input Bridge Pattern — Node Forwarding to RefCounted

Systems that need input (PlacementSystem #4, SelectionSystem #13) receive it
through a **thin bridge Node** owned by the SimulationOrchestrator:

```
┌─────────────────────────────────────────────────────────┐
│  Scene Tree (main.tscn)                                  │
│  ┌───────────────────────────────────────────────────┐  │
│  │  SimulationOrchestrator (Node)                     │  │
│  │  ┌─────────────────┐  ┌────────────────────────┐  │  │
│  │  │ PlacementBridge  │  │  SelectionBridge       │  │  │
│  │  │ (Node2D/Control) │  │  (Control)             │  │  │
│  │  │                  │  │                        │  │  │
│  │  │ _unhandled_input │  │ _unhandled_key_input   │  │  │
│  │  │      ↓           │  │      ↓                 │  │  │
│  │  │ PlacementSystem  │  │  SelectionSystem       │  │  │
│  │  │ (RefCounted)     │  │  (RefCounted)          │  │  │
│  │  │ .on_drag_start() │  │  .on_cell_clicked()    │  │  │
│  │  │ .on_mouse_moved()│  │  .on_esc_pressed()     │  │  │
│  │  │ .on_rotate()     │  │  .on_del_pressed()     │  │  │
│  │  │ .on_drop()       │  │  .on_sell_confirm()    │  │  │
│  │  │ .on_cancel()     │  │                        │  │  │
│  │  └─────────────────┘  └────────────────────────┘  │  │
│  └───────────────────────────────────────────────────┘  │
└─────────────────────────────────────────────────────────┘
```

Bridge rules:
- The bridge converts engine-space coordinates to grid-space cells
  (`GridSystem.world_to_grid()`) before calling system methods — the
  RefCounted system never sees screen pixels.
- Keyboard shortcuts (Esc, Del, R) use `_unhandled_key_input()` for
  focus-independent handling (per Godot 4.6 dual-focus).
- Mouse events use `_unhandled_input()` with `InputEventMouseButton` /
  `InputEventMouseMotion` filters — NOT `_process()` polling per
  placement-system.md's mouse-move forwarding requirement.
- The bridge owns timer creation (e.g., SelectionSystem's 2s sell-confirm
  timer via `SceneTree.create_timer()`) — `RefCounted` cannot create timers.
- Bridges are created and attached by the orchestrator in `_ready()`.
  They are **not** separate scenes — they exist only as children of the
  orchestrator Node.

### Architecture Diagram — Full Signal Flow

```
┌─────────────────────────────────────────────────────────────────────┐
│  TICK LOOP (direct method calls — not signals)                       │
│                                                                      │
│  SimulationOrchestrator._advance_tick()                              │
│    ├─ MemberSim.on_tick(ctx)                                         │
│    ├─ Congestion.on_tick(ctx)    → emit congestion_updated()  [S8]  │
│    ├─ Satisfaction.on_tick(ctx)                                      │
│    ├─ Economy.on_tick(ctx)                                           │
│    └─ TimeSystem.tick_completed.emit()                        [S2]  │
│         └─ SaveLoad (subscriber) → boundary save if requested        │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│  EVENT FLOW (Godot native signals on RefCounted)                     │
│                                                                      │
│  GridSystem                                                          │
│    grid_changed [S1] ──────┬──→ Navigation (rebuild AStarGrid2D)    │
│                            ├──→ Congestion/Overlay (redraw icons)    │
│                            ├──→ SelectionSystem (rebuild mapping)    │
│                            └──→ PlacementSystem (indirect — own)     │
│                                                                      │
│  PlacementSystem                                                     │
│    placement_committed [S3] ─→ SelectionSystem, Overlay, Shop UI     │
│    placement_rejected [S4]  ─→ Overlay (reason feedback)             │
│                                                                      │
│  MemberSim                                                           │
│    member_completed_visit [S5] ─→ Economy (revenue), Satisfaction    │
│                                                                      │
│  Economy                                                             │
│    balance_changed [S6] ─→ HUD, Shop (recheck can_afford)            │
│                                                                      │
│  SelectionSystem                                                     │
│    selection_changed [S7] ─→ Info Panel, Shop UI                     │
└─────────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────────┐
│  INPUT FLOW (Bridge Node → RefCounted method calls)                  │
│                                                                      │
│  Godot InputEvent                                                    │
│    → PlacementBridge._unhandled_input()                              │
│        → PlacementSystem.on_drag_start(eq_id) / .on_mouse_moved()    │
│    → SelectionBridge._unhandled_key_input()                          │
│        → SelectionSystem.on_esc_pressed() / .on_del_pressed()        │
│    → SelectionBridge (mouse click → cell conversion)                 │
│        → SelectionSystem.on_cell_clicked(cell)                       │
└─────────────────────────────────────────────────────────────────────┘
```

### Key Interfaces

| Interface | Signature | Pattern | Notes |
|-----------|-----------|---------|-------|
| Tick dispatch | `SimulationOrchestrator._advance_tick() -> void` | Direct call (hardcoded sequence) | Synchronous, non-reentrant, fixed order |
| Tick notification | `TimeSystem.tick_completed(tick_count: int)` | Signal (S2) | Fire-and-forget at end of tick sequence |
| Grid change | `GridSystem.grid_changed(footprint: Array, access: Array)` | Signal (S1) | Two `Array[Vector2i]` — placement and removal use the same signal |
| Placement result | `PlacementSystem.placement_committed(...)` / `placement_rejected(...)` | Signal (S3/S4) | Separate signals for success vs. failure |
| Visit completion | `MemberSim.member_completed_visit(member_id: int)` | Signal (S5) | Quota-met departures only |
| Balance update | `Economy.balance_changed(new_balance: int, delta: int)` | Signal (S6) | Signed delta for HUD animation direction |
| Selection state | `SelectionSystem.selection_changed(...)` | Signal (S7) | 4-arg for select, 0-arg for deselect |
| Congestion update | `Congestion.congestion_updated()` | Signal (S8) | No payload — overlay reads state directly |
| Input forwarding | `System.on_<event>(parsed_params)` | Direct call (via bridge) | Bridge converts screen → cell coordinates |

## Alternatives Considered

### Alternative 1: Custom EventBus Singleton (string-keyed)

- **Description**: A single `EventBus` Autoload (or DI-injected RefCounted) with
  `emit("grid_changed", data)` / `subscribe("grid_changed", callback)` using
  string keys.
- **Pros**: Decouples systems completely — no `signal` declarations needed on
  emitting classes. Easy to add subscribers without modifying the emitter.
- **Cons**: String-based event names are typo-prone (no compile-time check).
  No editor integration for debugging. Requires a custom subscription tracking
  implementation (leak-prone). Duplicates what Godot signals already do.
- **Rejection Reason**: Adds complexity without adding capability. Godot's
  native signals provide the same decoupling (subscribers don't need the
  emitter as a dependency — they receive it via DI and call `.connect()`).
  The only scenario where an EventBus wins is when the emitter and subscriber
  literally cannot know about each other — but in this architecture, the
  orchestrator wires everything explicitly, so that scenario never arises.

### Alternative 2: Tick Dispatch via Signal Chain

- **Description**: Each system connects to a `tick` signal; systems emit
  `tick_done` when finished; the next system's `tick_done` subscriber fires.
  The tick order is encoded in signal connection order.
- **Pros**: Visually "reactive." Adding a new system between two existing ones
  requires only reconnecting signals, not editing the orchestrator method.
- **Cons**: Order is implicit (connection order), not visible in one place.
  Reentrant by default — a buggy `tick_done` emit could trigger an infinite
  loop. Harder to debug (stack traces show signal machinery, not clear
  "System A → System B" flow). Adding a system requires touching connect()
  calls in the orchestrator anyway (to create the instance) — the
  editing-the-orchestrator-method argument is spurious.
- **Rejection Reason**: The hardcoded method-call sequence is the simplest
  thing that works. It makes the tick order visible in one 5-line method,
  prevents reentrancy by construction, and produces clean stack traces.
  The "flexibility" of signal-chained ticks is not needed — the tick order
  changes at design time, not runtime.

### Alternative 3: Polling Instead of Signals for Cross-System Events

- **Description**: No cross-system signals at all. Consumers poll the producer's
  state each tick (e.g., Economy checks `MemberSim.get_completed_visits_this_tick()`
  during its `on_tick()`).
- **Pros**: No signal connection lifecycle to manage. Deterministic by construction
  (polling happens at a known point in the tick sequence). Easier to test (direct
  state inspection, no signal counting).
- **Cons**: Couples consumers to the producer's internal state shape. Economy
  must know that MemberSim tracks "completed visits this tick" as a list.
  Adds polling methods to producers that exist only for consumers. Misses the
  "push" semantics of events — a polled list must be cleared each tick or it
  accumulates. The extra polling methods on producers are exactly the coupling
  that signals avoid.
- **Rejection Reason**: Signals are the established pattern for 1:N fire-and-forget
  notifications in Godot. The existing GDDs (grid-system.md, placement-system.md,
  economy.md) already define signal-based contracts — switching to polling would
  require rewriting 6+ GDDs. The signal catalog (§3) provides the deterministic
  semantics (documented emit points, fixed arities) that make signals auditable,
  while keeping the decoupling value.

## Consequences

### Positive

- Every cross-system event has a documented owner and payload — no ambiguity
  about who emits what or which system a subscriber should connect to.
- Godot's native signal system provides editor tooling, stack traces with signal
  names, and zero-overhead dispatch.
- Tick dispatch as direct calls is trivially auditable, non-reentrant, and
  produces clean stack traces.
- Bridge pattern isolates input handling from simulation logic — PlacementSystem
  and SelectionSystem are headless-testable without mocking Godot input events.
- The arity catalog prevents the most common GDScript signal bug (emit 1 arg
  when callable expects 2 → runtime crash).

### Negative

- Signal connection lifecycle is manual — every `connect()` needs a corresponding
  concern about disconnection. Mitigation: systems live for the entire session
  (orchestrator owns them), so disconnection is never needed in normal operation.
  Headless tests construct systems in isolation and never connect signals (they
  call methods directly).
- The signal catalog (§3) is a manual list — adding a signal without updating
  this ADR creates drift. Mitigation: `/architecture-review` checks GDD signal
  declarations against this catalog.
- Bridges add ~50 lines of boilerplate per input-requiring system. Mitigation:
  the bridge is the simplest possible Node — it converts coordinates and
  forwards calls. No logic lives there.

### Risks

- **Risk**: `RefCounted` signal connections cause crashes if a system is freed
  while subscribers still hold connections.
  **Mitigation**: Systems are owned by the orchestrator for the session lifetime.
  No system is dynamically created or destroyed after init. GUT tests that
  construct-and-discard systems must explicitly disconnect or avoid connecting.
- **Risk**: Signal emit arity mismatch is a runtime error, not a parse error —
  it could slip past CI if the specific code path isn't tested.
  **Mitigation**: Every signal's emit site is covered by a GUT test that
  verifies the signal fires with the correct number of arguments (see
  Validation Criteria).
- **Risk**: The `tick_completed` signal fires synchronously during
  `_advance_tick()`. If a subscriber (SaveLoad) performs heavy work in its slot,
  it blocks the tick loop.
  **Mitigation**: SaveLoad's tick-boundary save is a synchronous serialize of
  ~7 small dictionaries — profiled at <1ms. If this ever becomes a concern,
  the save can be deferred to the next idle frame without changing the signal
  contract.

## GDD Requirements Addressed

| GDD System | Requirement | How This ADR Addresses It |
|------------|-------------|--------------------------|
| grid-system.md | Core Rule 7: `commit()`/`clear()` emit `grid_changed` signal | Catalogs S1 with exact payload (two `Array[Vector2i]`), owner (GridSystem), and consumer list |
| grid-system.md | AC-C7.4: `grid_changed` fires exactly once with correct cells | Arity enforced at 2; GUT test requirement for emit count |
| placement-system.md | Core Rule 5/6: `placement_committed` / `placement_rejected` signals | Catalogs S3/S4 with payloads, ownership (PlacementSystem), and the "silent cancel emits neither" rule |
| placement-system.md | Input routing contract: bridge Node forwards mouse/keyboard as method calls | Formalizes the bridge pattern (§5) — screen→cell conversion, `_unhandled_input()` for mouse, `_unhandled_key_input()` for keys |
| selection-system.md | Input routing contract: bridge Node forwards clicks and key events | Same bridge pattern — `on_cell_clicked(cell)`, `on_esc_pressed()`, `on_del_pressed()` |
| selection-system.md | `selection_changed` signal (4-arg select, 0-arg deselect) | Catalogs S7 with both arities documented |
| economy.md | Core Rule 2: `member_completed_visit` → revenue trigger | Catalogs S5 — MemberSim owns the signal, Economy subscribes |
| economy.md | Core Rule 5: `balance_changed` signal for HUD | Catalogs S6 — signed delta for HUD animation direction |
| member-sim.md | Downstream signals: `member_completed_visit` for Economy, satisfaction events for Satisfaction | Catalogs S5; clarifies that satisfaction events are direct method calls during `on_tick()`, not separate signals |
| navigation.md | Core Rule 3: subscribe to `grid_changed` for solidity sync | Catalogs S1 consumer list; specifies that `set_point_solid()` + `update()` must happen in the signal handler |
| congestion-flow-overlay.md | Core Rule 3: refresh on `congestion_updated` signal | Catalogs S8 — no-payload signal, overlay reads Congestion state directly |
| save-load.md | Core Rule 1: tick-boundary saves via `tick_completed` hook | Catalogs S2 — SaveLoad subscribes, save fires between ticks |
| save-load.md | OQ2 (RESOLVED): `tick_completed` signal already exists | Confirms S2 exists and SaveLoad is the documented subscriber |
| time-system.md | Core Rule 4: fixed system call order | Tick dispatch is a hardcoded direct-call sequence in `SimulationOrchestrator._advance_tick()` |
| time-system.md | Core Rule 5: no mid-tick yielding → tick boundary is free | Direct calls are synchronous and non-reentrant — this is enforced by the pattern, not a runtime check |
| time-system.md | AC5: `tick_completed` emits at end of each tick sequence | S2 is emitted after all `on_tick()` calls and `increment_tick()` |

## Performance Implications

- **CPU**: Signal emit is O(subscribers) — all signals in this catalog have
  1–4 subscribers. Negligible per emit (<1µs). Tick dispatch is 4 direct method
  calls — the cheapest possible dispatch mechanism.
- **Memory**: Signal connections are stored as arrays on the emitting object.
  ~20 total connections across 8 signals. Negligible.
- **Load Time**: Bridge Nodes are created at scene init — 2 Nodes × ~200 bytes.
  Negligible.
- **Network**: N/A (single-player).

## Migration Plan

This is a greenfield decision — no existing code to migrate. All GDDs already
define their signals consistent with this catalog.

If a future system needs a new cross-system signal:
1. Define it in the system's GDD with owner, payload, and consumer list.
2. Add it to the Signal Catalog (§3) via an ADR amendment (or update this ADR).
3. Register it in `docs/registry/architecture.yaml` under `interfaces:`.
4. Add a GUT test verifying the arity and emit condition.

## Validation Criteria

1. **Arity test for every signal in the catalog**: For each of S1–S8, a GUT
   test connects a spy callable and verifies the emit passes the declared
   number of arguments (not 0 when expecting 2, etc.).
2. **Emit-count test**: `grid_changed` fires exactly once per `commit()`/`clear()`
   and zero times during drag preview (grid-system.md AC-C7.4, AC-C7.3, AC-X.3).
3. **Silent cancel test**: Esc, focus-loss, and drop-outside-grid emit neither
   `placement_committed` nor `placement_rejected` (placement-system.md AC23).
4. **Tick order test**: A GUT integration test verifies that `MemberSim.on_tick()`
   runs before `Congestion.on_tick()` within a single `_advance_tick()` call.
5. **Tick boundary test**: `tick_completed` is the last thing emitted in
   `_advance_tick()` — no `on_tick()` call occurs after it.
6. **Bridge coordinate conversion test**: A GUT test calls bridge methods with
   screen coordinates and verifies the RefCounted system receives grid-cell
   coordinates (not screen pixels).

## Related Decisions

- **ADR-0001** (DI Container): defines the orchestrator as a single Node
  composition root, owns all systems + bridges, enforces `_post_init()` as the
  signal connection phase.
- **ADR-0004** (Seeded RNG): `TickContext.rng` passes the per-system RNG
  sub-stream — the tick dispatch is how RNG arrives at consuming systems.
- **ADR-0006** (pending, Economy credit interface): `member_completed_visit`
  (S5) is the signal that triggers Economy's revenue path — ADR-0006 defines
  the `credit()` method that the sell path (SelectionSystem) needs, which is
  the other half of Economy's external interface.
