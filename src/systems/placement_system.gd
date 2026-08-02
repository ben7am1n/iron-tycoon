## PlacementSystem — the single interactive surface through which the player
## builds their gym (placement-system epic; GDD design/gdd/placement-system.md).
##
## PL-006 slice: the public state query `is_dragging()` and the cost-scope
## guarantee on the DI signature. Per Core Rule 9, PlacementSystem performs NO
## currency check and deducts NO cost — any drag it receives is assumed
## affordability-cleared by Shop/Build-UI. Consequently the `init()` signature
## carries exactly GridSystem + EquipmentCatalog (TR-PS-009, AC14); the input
## bridge Node is owned by the composition root (ADR-0001), not injected here.
##
## Core Rule 10 (TR-PS-010): `is_dragging() -> bool` is a pure, synchronous,
## side-effect-free read that returns true whenever the internal drag state is
## DRAGGING (new-placement or relocate, any source) and false when IDLE. It
## exists because a second mouse-down while DRAGGING is a silent no-op (Core
## Rule 11) — callers like Shop/Purchase must check BEFORE attempting, since
## no rejection signal will ever arrive.
##
## Drag-state lifecycle (enter/exit DRAGGING) is Story 001/005 territory and
## is deliberately NOT implemented in this slice — see `_drag_state` and the
## test-only seam below.
##
## Per ADR-0001: RefCounted SimSystem, two-phase init, manual `_init()` guard
## inherited from SimSystem, and a use-before-init guard on every public
## method (Control Manifest Core-layer rule).
class_name PlacementSystem extends SimSystem


## Internal drag state machine (GDD "States and Transitions").
##
## NAMING CONTRACT for the gate merge: this is the shared state that Story 001
## (begin_drag/preview/rotate) and Story 005 (begin_relocate) transition —
## both enter the SAME DRAGGING state (Core Rule 1a: relocate "enters the same
## DRAGGING state as a new placement"). Downstream stories should read/write
## `_drag_state` under this exact name; is_dragging() reflects it verbatim.
enum DragState {
	IDLE = 0,
	DRAGGING = 1,
}


## Emitted exactly once immediately after a successful GridSystem.commit()
## (Core Rule 5, Story 002). Declared here as part of the GDD public output
## interface so AC28/AC29's "no signals emitted" clause is meaningful; the
## emission sites land with Story 002/003.
signal placement_committed(instance_id: int, equipment_id: String, footprint_cells: Array[Vector2i])

## Emitted once per rejected drop with GridSystem's PlacementFailCode
## (Core Rule 6, Story 003). Declared here for the same reason as above.
signal placement_rejected(equipment_id: String, anchor: Vector2i, rotation: int, fail_code: int)


var _grid: GridSystem
var _catalog: EquipmentCatalog

## The one active-drag flag is_dragging() reflects. IDLE by default; only the
## drag lifecycle (Story 001/005) or the test seam below may change it.
var _drag_state: DragState = DragState.IDLE


## Two-phase init (ADR-0001). Signature carries EXACTLY the two hard upstream
## dependencies (TR-PS-009 / AC14): GridSystem + EquipmentCatalog. No
## currency/wallet/economy parameter of any kind — cost/affordability is
## explicitly out of this system's scope (Core Rule 9).
func init(grid: GridSystem, catalog: EquipmentCatalog) -> void:
	if not _mark_initialized():
		return
	_grid = grid
	_catalog = catalog


func system_name() -> String:
	return "PlacementSystem"


## Returns true iff a drag is currently in flight (DRAGGING — new placement or
## relocate, any source); false when IDLE (Core Rule 10, TR-PS-010).
##
## Pure synchronous read: never mutates state, never emits a signal, callable
## at any time including mid-drag. Guards use-before-init per the Control
## Manifest — returns the safe default (false) before init().
func is_dragging() -> bool:
	if not _assert_initialized():
		return false
	return _drag_state == DragState.DRAGGING


## TEST-ONLY white-box seam (same pattern as Story 001's AC4 required seam
## `_test_set_rotation_unchecked`): forces the drag state so PL-006's tests
## can construct DRAGGING (AC29) without Story 001's begin_drag/relocate
## lifecycle, which lands in a parallel worktree. MUST NOT be reachable from
## any production call site — only from tests/unit/placement_system/.
func _test_set_dragging(active: bool) -> void:
	_drag_state = DragState.DRAGGING if active else DragState.IDLE
