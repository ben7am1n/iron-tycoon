## SimulationOrchestrator — the single composition root Node (ADR-0001 §4).
##
## Story: time-system / story-001-orchestrator-tick-dispatch.md
## Req:   TR-TS-003 (fixed dispatch order), TR-TS-004 (no mid-tick yielding)
## ADR:   ADR-0001 (DI Container & Scene Bootstrap), ADR-0005 (Signal Bus &
##        Event Routing — §2 tick dispatch is direct calls, NOT signals)
##
## This is the ONLY Node that owns simulation systems. All 12 systems are
## held as RefCounted fields (never Autoload, never scene-tree children),
## and input-requiring systems get thin bridge Nodes as children later.
## Initialization happens in _ready() with a topological tier order
## (Tier 0 leaf systems first, Tier 7 coordinator last — ADR-0001 §5).
##
## Story-001 scope note: of the 12 systems, only EquipmentCatalog exists in
## src/ today. init() constructs what exists and leaves the rest null with
## documented expectations — the fields are the contract, the construction
## grows as each system's story lands. Tick dispatch (the dispatch skeleton,
## tick_count, tick_completed) is fully implemented and testable NOW via
## injected spy systems (AC5/AC19). TimeSystem's accumulator (Story 002)
## will drive _advance_tick().
##
## Two-phase init enforcement (Control Manifest, Foundation layer):
##   - init() called twice -> assert(false) fires (AC-INIT-1)
##   - any public method before init() -> push_error() + safe default
##     (AC-INIT-2). Public methods use push_error, NEVER assert — verified
##     engine fact (docs/tech-debt-register.md 2026-08-01): assert(false)
##     aborts the rest of the current function frame and turns Object-typed
##     returns into null, crashing callers. init() returns void, so the
##     assert there is safe and is exactly what AC-INIT-1 requires.
class_name SimulationOrchestrator extends Node

## FIXED tick dispatch order — the textual source of truth for TR-TS-003
## (GDD Core Rule 4, ADR-0005 §2). _advance_tick() iterates _tick_systems
## in array order; this array is populated in code (never by scene-tree
## order or signal connect order), so the sequence below is locked and
## textually visible (Control Manifest guardrail: "tick dispatch order must
## be textually visible and never reorderable by scene tree").
##
##   1. MemberSim    — reads Congestion(t-1), decides targets/routes, moves members
##   2. Congestion   — recomputes density/queues from this tick's post-move state
##   3. Satisfaction — reads Congestion + ZoneRules + MemberSim state
##   4. Economy      — reads Satisfaction, applies revenue/costs
##   then: tick_count += 1; tick_completed.emit(tick_count)
const FIXED_TICK_ORDER: Array[String] = ["MemberSim", "Congestion", "Satisfaction", "Economy"]

## Presentation cell size for the placement input bridge's screen→cell
## conversion (GDD D.4 handoff note: 16 or 32px, finalized at architecture
## stage). GridSystem deliberately never hardcodes this value — every
## coordinate-conversion method takes cell_size as a parameter. The
## composition root owns the presentation decision and injects it into the
## bridge. PL-007.
const PLACEMENT_CELL_SIZE: int = 32

## S2 in the ADR-0005 Signal Catalog — the ONLY signal in the tick sequence.
## Fires at the end of every _advance_tick(), AFTER all on_tick() calls and
## AFTER tick_count has incremented, carrying the NEW tick count. SaveLoad
## hooks this for tick-boundary saves; HUD may poll get_tick_count() instead.
## Arity: exactly 1 int argument (verified by test).
signal tick_completed(tick_count: int)

# === System fields (RefCounted, owned by this Node for the session lifetime) ===
#
# Tier 0 — Foundation leaf systems (no upstream dependencies):
var equipment_catalog  # EquipmentCatalog — constructed in init() (Story 001)
var time_system        # TimeSystem — constructed in init() (Story 002: tick
                       # accumulator / speed / pause). _process() forwards
                       # wall-time here each frame; it decides how many ticks
                       # fire and calls _advance_tick() per tick.
# Tier 1 — depends on Tier 0:
var grid_system        # GridSystem — null until a level-definition source
                       # (LevelLoader) supplies dimensions for init(width,height).
## SL-001: the coordinated-system fields SaveLoad.init() reads (the fields ARE
## the contract — same pattern as grid_system). Null until each system's story
## lands and init() constructs it; SaveLoad treats a null system as an empty {}
## contribution so the save blob key set stays fixed at 8 keys from day one.
var member_sim         # MemberSim — null until its story lands (tick Tier 2)
var congestion         # Congestion — null until its story lands (tick Tier 4)
var satisfaction       # Satisfaction — null until its story lands (tick Tier 5)
var economy            # Economy — null until its story lands (tick Tier 6)
var placement_system   # PlacementSystem — constructed in init() Tier 1 once a
                       # grid exists (LevelLoader story pending; tests inject
                       # grid_system before init()). PL-007.
var selection_system   # SelectionSystem — constructed in init() Tier 6 once a
                       # placement system exists (SEL-001; bridge = Story 002)
var navigation         # Navigation — null until its story lands (Tier 2)
# Tier 2-7 — PlacementSystem, Navigation, MemberSim, ZoneRules, Congestion,
# Satisfaction, Economy, Shop, SelectionSystem, SaveLoad: null until their
# stories land. Deliberately NOT typed — the classes do not exist in src/
# yet, and a typed declaration would be a parse error. The init()/tier
# construction below grows in place as each system's story is implemented.

## Ordered tickable systems, dispatch order = array order (see
## FIXED_TICK_ORDER). Convention contract (NOT an abstract class — story
## "TickableSystem contract"): every element implements
##     func on_tick(tick_count: int) -> void:
##         # must run synchronously to completion — NO await / yield (TR-TS-004)
## Populated by init() as the real systems land; tests inject spies.
var _tick_systems: Array = []

var _tick_count: int = 0
var _initialized: bool = false


## Engine lifecycle hook. Performs the topological init exactly once.
## Guarded so an explicit init() call before entering the tree does not
## double-fire when the node is later added to the tree.
func _ready() -> void:
	if not _initialized:
		init()


## Two-phase init entry point — the Orchestrator's own init() (AC-INIT-1/2).
## Phase 1 constructs every system in tier order and calls each system's
## init(...) (storing references only). Phase 2 calls each system's
## _post_init() for cross-system wiring (all systems must exist first).
## Safe to call once; a second call fires assert(false) per AC-INIT-1.
func init() -> void:
	if _initialized:
		assert(false, "SimulationOrchestrator.init() called twice.")
		return  # unreachable in debug (assert aborts the frame) — kept for release posture
	_initialize_topology()
	_initialized = true


## Returns the current abstract tick counter. 0 before the first tick.
## Guards against use-before-init: push_error() + 0 (AC-INIT-2).
func get_tick_count() -> int:
	if not _guard_initialized():
		return 0
	return _tick_count


## Story-004 write path: restores the tick counter from deserialized save
## data. Called by TimeSystem.deserialize() Phase B AFTER full validation
## passed — this is the only way tick_count is ever written outside
## _advance_tick() (the counter's owner is this orchestrator; see class
## header / TS-001). Guarded like every public method (AC-INIT-2).
func _restore_tick_count(value: int) -> void:
	if not _guard_initialized():
		return
	_tick_count = value


## STUB — kept from TS-001 for the AC-INIT-2 guard contract (safe default {}).
## The REAL Story-004 serialization contract lives on TimeSystem.serialize()
## (GDD Core Rule 7), which SaveLoad calls as a coordination step (SL-001);
## this orchestrator-level method remains empty for MVP.
func serialize() -> Dictionary:
	if not _guard_initialized():
		return {}
	return {}


## Called by TimeSystem (Story 002) once per tick. Drives the fixed
## dispatch sequence: direct synchronous method calls in array order —
## NOT signal-driven (ADR-0005 §2: signals would be reentrant and order
## would depend on connect order). After all on_tick() calls complete,
## increments tick_count, then emits tick_completed(tick_count) exactly
## once (S2). No system may yield mid-tick (TR-TS-004), so this method
## always runs to completion synchronously — every moment external code
## can run is automatically a tick boundary.
func _advance_tick() -> void:
	if not _guard_initialized():
		return
	for system in _tick_systems:
		system.on_tick(_tick_count)  # direct call — contract: on_tick(tick_count: int) -> void
	_tick_count += 1
	tick_completed.emit(_tick_count)


## Render-frame driver. Forwards accumulated wall time to TimeSystem's
## fixed-timestep accumulator (Story 002) when it exists. TimeSystem
## decides how many ticks fire (MAX_TICKS_PER_FRAME clamp lives there —
## GDD speed_to_realtime_formula) and calls _advance_tick() per tick.
func _process(delta: float) -> void:
	if not _initialized:
		return
	if time_system != null:
		time_system.process(delta)


## Guards every public method against use-before-init (AC-INIT-2).
## push_error() + false, never assert — see class doc for the verified
## engine fact about assert() aborts.
func _guard_initialized() -> bool:
	if not _initialized:
		push_error("SimulationOrchestrator: method called before init().")
		return false
	return true


## Topological init (ADR-0001 §5) — Phase 1 construct + Phase 2 wire.
## Each tier completes fully before the next begins; the tier order below
## is the single textual place the dependency order lives.
func _initialize_topology() -> void:
	# --- Phase 1: construct + init, tier by tier ---
	# Tier 0: leaf systems (no upstream dependencies).
	# EquipmentCatalog: constructed here unless a test/boot sequence injected
	# a prepared catalog first (same DI seam as grid_system below — the
	# composition root accepts pre-injected dependencies, ADR-0001 §1).
	if equipment_catalog == null:
		equipment_catalog = EquipmentCatalog.new()
	time_system = TimeSystem.new()
	time_system.init(self)  # Story 002 — injects the orchestrator back-reference
	                        # (process() calls _advance_tick() per fired tick)
	# grid_system   = GridSystem.new(); grid_system.init(width, height)  # needs LevelLoader
	# Tier 1: placement — constructed once a grid exists (LevelLoader story
	# pending; tests inject grid_system before init()). PL-007.
	if grid_system != null:
		placement_system = PlacementSystem.new()
		placement_system.init(grid_system, equipment_catalog)
	# navigation    = Navigation.new(); navigation.init(grid_system)  # its story
	# Tier 6: selection — constructed once placement exists (it subscribes to
	# placement_committed + grid_changed for the instance mapping, SEL-001;
	# the input bridge Node is selection-system Story 002).
	if placement_system != null:
		selection_system = SelectionSystem.new()
		selection_system.init(grid_system, placement_system, equipment_catalog)
	# Tier 2-7: member_sim, zone_rules, congestion, satisfaction, economy,
	#           shop, save_load (stories not yet implemented)
	#
	# When the four tick-driven systems land, populate in the LOCKED order:
	#   _tick_systems = [member_sim, congestion, satisfaction, economy]

	# --- Phase 2: cross-system wiring (all systems exist) ---
	# SelectionSystem is the first system with real _post_init() work (its
	# mapping subscriptions). More systems join here as their stories land;
	# SaveLoad hooks tick_completed here (Story 004); bridges attach here.
	if selection_system != null:
		selection_system._post_init()
	# Placement input bridge (PL-007): created as a child Node by the
	# composition root, NOT a separate scene, NOT owned by the presentation
	# layer (TR-PS-011). The orchestrator holds PlacementSystem as a strong
	# RefCounted field, so destroying/recreating this bridge Node on a scene
	# transition never frees the system and DRAGGING state survives (AC
	# bridge). The bridge receives the grid + presentation cell size to do its
	# own screen→cell conversion (ADR-0005 §5).
	if placement_system != null:
		var bridge := PlacementInputBridge.new()
		bridge.name = "PlacementInputBridge"
		bridge.init(placement_system, grid_system, PLACEMENT_CELL_SIZE)
		add_child(bridge)
