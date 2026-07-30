# Story 001: SimulationOrchestrator and Tick Dispatch

> **Epic**: time-system
> **Status**: Ready
> **Layer**: Foundation
> **Type**: Logic
> **Estimate**: [hours or t-shirt size — fill before sprint planning]
> **Manifest Version**: 2026-07-23
> **Last Updated**: [set by /dev-story when implementation begins]

## Context

**GDD**: `design/gdd/time-system.md`
**Requirements**: `TR-TS-003`, `TR-TS-004`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0001: DI Container & Scene Bootstrap, ADR-0005: Signal Bus & Event Routing
**ADR Decision Summary**: SimulationOrchestrator is the single composition root Node that owns all 12 systems as RefCounted fields and all bridge Nodes as children. Initialization order is enforced topologically in _ready() (Tier 0 through Tier 7). Tick dispatch is a hardcoded sequence of direct method calls (not signal-driven): MemberSim → Congestion → Satisfaction → Economy. tick_completed(tick_count: int) signal (S2) fires at end of each tick sequence. Two-phase init(): init() stores references only, _post_init() performs cross-system wiring. MAX_TICKS_PER_FRAME = 8.

**Engine**: Godot 4.7.1 | **Risk**: MEDIUM
**Engine Notes**: RefCounted classes are NOT Nodes — Orchestrator is the only Node in this architecture, holding strong references to all systems. _ready() is the correct lifecycle hook for topological init. Two-phase init (init + _post_init) is required because cross-system wiring needs all systems to have their own init() completed first. No Autoload — Orchestrator is placed in the scene tree once.

**Control Manifest Rules (Foundation layer)**:
- Required: Two-phase init (init stores refs, _post_init wires cross-system); all public methods guard against use-before-init; fixed dispatch via direct calls (not signals)
- Forbidden: No Autoload for any system; no await/yield in on_tick(); never skip init() (duplicate call = assert)
- Guardrail: MAX_TICKS_PER_FRAME = 8; tick dispatch order must be textually visible and never reorderable by scene tree

---

## Acceptance Criteria

*From GDD `design/gdd/time-system.md`, scoped to this story:*

- [ ] AC5 [BLOCKING][Logic] GIVEN spy/mock MemberSim, Congestion, Satisfaction, Economy registered, WHEN one tick fires, THEN recorded call order is exactly [MemberSim, Congestion, Satisfaction, Economy] → tick_count increments → tick_completed(tick_count) emits with the new value
- [ ] AC19 [BLOCKING][Logic] GIVEN the 8-tick clamp fires, WHEN each of the 8 ticks executes, THEN each individually completes the full MemberSim→Congestion→Satisfaction→Economy→increment→emit sequence — no batching or short-circuiting
- [ ] AC-INIT-1 [BLOCKING][Logic] GIVEN Orchestrator with init() already called, WHEN init() is called a second time, THEN assert() fires
- [ ] AC-INIT-2 [BLOCKING][Logic] GIVEN Orchestrator before init(), WHEN any public method (on_tick, get_tick_count, etc.) is called, THEN push_error() + safe default
- [ ] AC-NO-AWAIT [ADVISORY][Code Review] GIVEN any on_tick() implementation in any system, WHEN code review runs, THEN no await/yield statement exists in any on_tick() body — enforced via static grep, not runtime test

---

## Implementation Notes

*Derived from ADR-0001 + ADR-0005 + GDD Core Rules 4-5:*

**SimulationOrchestrator skeleton:**
```gdscript
class_name SimulationOrchestrator extends Node

# Tier 0: Foundation systems (no dependencies)
var time_system: TimeSystem
var equipment_catalog: EquipmentCatalog

# Tier 1: Systems that depend only on Tier 0
var grid_system: GridSystem

# Tier 2-6: Other systems (PlacementSystem, Navigation, MemberSim, etc.)
# ... populated as GDDs are implemented ...

# Systems with on_tick() — the fixed dispatch order
var _tick_systems: Array[TickableSystem] = []
var _tick_count: int = 0

var _initialized: bool = false

func _ready() -> void:
    # Topological init order:
    # Tier 0: TimeSystem, EquipmentCatalog
    time_system = TimeSystem.new()
    equipment_catalog = EquipmentCatalog.new()
    # ... load catalog ...
    
    # Tier 1: GridSystem
    grid_system = GridSystem.new()
    grid_system.init(width, height)
    
    # ... Tier 2-7 systems ...
    
    # Phase 2: cross-system wiring
    time_system._post_init()
    grid_system._post_init()
    # ... all systems _post_init() ...
    
    _initialized = true

func _process(delta: float) -> void:
    if not _initialized:
        return
    time_system.process(delta)  # handles tick accumulator internally

# Called by TimeSystem when a tick should fire
func _advance_tick() -> void:
    assert(_initialized, "SimulationOrchestrator._advance_tick() called before init")
    
    for system in _tick_systems:
        system.on_tick(_tick_count)  # direct call, NOT signal
    
    _tick_count += 1
    tick_completed.emit(_tick_count)

signal tick_completed(tick_count: int)
```

**TickableSystem contract (convention, not abstract class):**
```gdscript
# Every system called in the tick loop must implement:
# func on_tick(tick_count: int) -> void:
#     # NO await / yield — must run synchronously to completion
```

**Fixed dispatch order:**
```gdscript
# In _ready(), after all systems created and _post_init()'d:
_tick_systems = [
    member_sim,      # 1st: reads Congestion(t-1), moves members
    congestion,       # 2nd: recomputes density from post-move state
    satisfaction,     # 3rd: reads Congestion + ZoneRules + MemberSim
    economy,          # 4th: reads Satisfaction, applies revenue/costs
]
```

**Two-phase init enforcement:**
```gdscript
# On TimeSystem and all RefCounted systems:
var _init_called: bool = false

func init(...) -> void:
    if _init_called:
        assert(false, "%s.init() called twice" % _get_class_name())
        return
    # store references only — no cross-system wiring
    _init_called = true

func _post_init() -> void:
    assert(_init_called, "%s._post_init() called before init()" % _get_class_name())
    # cross-system wiring here
```

**Key design decisions:**
- Orchestrator IS a Node (the only one that owns systems) — placed in scene tree once, handles _process
- Tick dispatch is direct method calls, not signal-driven — guarantees ordering and synchronous completion
- tick_completed signal is the ONLY signal emitted — this is what SaveLoad hooks for tick-boundary saves
- The list of tickable systems is an ordered Array, not scene-tree children — order is textually fixed
- MAX_TICKS_PER_FRAME per-tick dispatch: if 8 ticks fire in one frame, each calls the full dispatch sequence individually (AC19)

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 002]: Tick accumulator logic and speed control — this story receives process(delta) but the accumulator lives in TimeSystem
- [Story 003]: SeededRNG sub-stream derivation — RNG setup happens in _post_init(), but the derivation formula is Story 003
- [Story 004]: Serialization and resume behavior — Orchestrator coordinates, implementations are detail
- [Individual systems]: MemberSim/Congestion/Satisfaction/Economy on_tick() implementations — this story only verifies the dispatch skeleton

---

## QA Test Cases

- **AC5**: 分发顺序验证
  - Given: 4 spy/mock systems registered in order
  - When: one tick fires via _advance_tick()
  - Then: recorded calls = [MemberSim, Congestion, Satisfaction, Economy]; tick_count incremented AFTER all calls; tick_completed emitted ONCE with new tick_count
  - Edge cases: test with empty _tick_systems array (should still increment tick_count and emit); test with tick_count overflow behavior

- **AC19**: 多重 tick 各自独立
  - Given: MAX_TICKS_PER_FRAME=8, tick_accumulator large enough
  - When: _process fires 8 ticks
  - Then: each tick independently calls full dispatch sequence; tick_count increments 8 times; tick_completed emits 8 times (once per tick)
  - Edge cases: verify each tick sees a unique tick_count (monotonically increasing)

- **AC-INIT-1**: 重复 init() 断言
  - Given: system with init() already called
  - When: init() called again
  - Then: assert(false) fires
  - Edge cases: test on both Orchestrator and individual RefCounted systems

- **AC-INIT-2**: 未初始化拒绝
  - Given: Orchestrator before init()
  - When: any public method called
  - Then: push_error() + safe default (null/empty/0)
  - Edge cases: test _advance_tick(), get_tick_count(), serialize() — each must guard

- **AC-NO-AWAIT**: 代码审查 — 无 await/yield
  - Given: all on_tick() implementations in codebase
  - When: code review or static grep
  - Then: no await or yield keyword in any on_tick() body
  - Edge cases: ADVISORY only — not runtime-testable

---

## Test Evidence

**Story Type**: Logic
**Required evidence**:
- `tests/unit/time_system/orchestrator_init_dispatch_test.gd` — must exist and pass

**Status**: [ ] Not yet created

---

## Dependencies

- Depends on: None (Foundation layer — first system created)
- Unlocks: Story 002 (tick accumulator needs Orchestrator container), Story 003 (RNG registration lives in _post_init())
