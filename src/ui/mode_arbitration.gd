## ModeArbitration — build/select mode arbitration for the Build/Shop UI
## (build-shop-ui epic, Story 003; TR-BSUI-004; GDD Core Rule 4; ADR-0005
## S7; UX spec "Selection arbitration" AC).
##
## The two spatial interaction modes — build (PlacementSystem placement
## drag) and select (SelectionSystem selection) — are MUTUALLY EXCLUSIVE.
## Exactly one mode is visually active at a time (Pillar 3); this object is
## the presentation-layer arbiter enforcing the SELECTION side of the rule:
##
##   - While a selection is active (`selection_changed` non-null), the
##     new-placement ghost/preview is SUPPRESSED — is_ghost_suppressed()
##     is the query Story 004's ghost renderer consumes, so a build preview
##     never renders over a selected piece (no dual ghost, AC6).
##   - `selection_changed(null)` → idle: the ghost is allowed again
##     IMMEDIATELY — the handler is synchronous, no await between the
##     deselect emission and the ghost being allowed (AC6 edge).
##   - Starting a build (palette mouse-down → begin_build()) while a piece
##     is selected FIRST clears the selection (build takes over, GDD Core
##     Rule 4). The palette calls begin_build() AFTER the purchase gate
##     passes and BEFORE PlacementSystem.begin_drag(), so a failed gate
##     leaves the selection unchanged, and a real drag never coexists with
##     a selection (no dual ghost).
##
## The OTHER suppression direction — build drag active → selection
## suppressed (clicks don't resolve during a drag) — is SelectionSystem's
## own guarantee (SEL-001 AC12) and is NOT reimplemented here. The two
## directions together guarantee no dual ghost.
##
## Plain RefCounted presentation object (NOT a SimSystem — no tick, no save
## state, same standing as Shop/PaletteAvailability). Owns only the
## transient `_selection_active` flag, derived from SelectionSystem's
## signal — it renders and routes; all state lives in the sim systems.
##
## SIGNAL CONSUMER CONTRACT (ADR-0005 S7 / SelectionSystem class doc):
##   select:   selection_changed.emit(instance_id, def, anchor, rotation)
##             — EXACTLY FOUR arguments
##   deselect: selection_changed.emit(null) — EXACTLY ONE argument
## GDScript dispatches exactly the args passed to emit(); the handler below
## declares 1..4 OPTIONAL params so it accepts both arities, and treats a
## null instance_id as deselect. NEVER tests truthiness of instance_id —
## 0 is a legal selected instance (the first placed piece).
class_name ModeArbitration extends RefCounted

## preload alias for the SelectionSystem cross-reference — the story's
## documented headless pattern (global class cache is editor-generated;
## preload works regardless).
const SelectionSystemScript := preload("res://src/systems/selection_system.gd")


## Injected SelectionSystem — the selection truth source (selection_changed
## subscription) and the clear_selection() target of begin_build().
var _selection: SelectionSystemScript

## True while a selection is active (non-null instance_id in the last
## selection_changed emission); false when idle. Initialized false — the
## pre-init safe default (Control Manifest guard contract).
var _selection_active: bool = false

var _initialized: bool = false


## Two-phase init (mirrors the Shop guard pattern with push_error, not
## assert — testable and release-safe). Stores the injected selection
## system and subscribes to selection_changed with a TYPED signal
## connection (Control Manifest: string-based connects forbidden). A
## second init() call is a hard error (logged, no-op).
func init(selection: SelectionSystemScript) -> void:
	if _initialized:
		push_error("ModeArbitration.init() called twice")
		return
	_initialized = true
	_selection = selection
	_selection.selection_changed.connect(_on_selection_changed)


## True while a selection is active. Pure query — no mutation, no signal.
func is_selection_active() -> bool:
	if not _guard_initialized():
		return false
	return _selection_active


## The ghost-suppression query (TR-BSUI-004, GDD Core Rule 4): true while a
## selection is active — i.e. the new-placement ghost/preview must NOT
## render (no dual ghost). Story 004's ghost renderer consumes this.
## False → the ghost is allowed again (idle). Pure query.
func is_ghost_suppressed() -> bool:
	return is_selection_active()


## Build takes over (GDD Core Rule 4, UX "clicking a palette item first
## clears any selection"): clears the selection FIRST when one is active,
## so PlacementSystem's drag owns the screen alone — no dual ghost. Called
## by the palette after the purchase gate passes and BEFORE
## PlacementSystem.begin_drag(). No-op when idle (nothing to clear). The
## deselect happens synchronously: SelectionSystem emits
## selection_changed(null), this object's handler flips _selection_active
## false in the same call, so the ghost is allowed the instant the drag
## begins.
func begin_build() -> void:
	if not _guard_initialized():
		return
	if _selection_active:
		_selection.clear_selection()


## S7 selection_changed handler — 1..4 optional params per the consumer
## contract (see class doc). A non-null instance_id → select mode (ghost
## suppressed); null → idle (ghost allowed). The explicit `!= null`
## comparison is load-bearing — 0 is a legal selected instance and must
## never read as "no selection" via GDScript truthiness.
func _on_selection_changed(instance_id = null, _equipment_def = null, _cell = null, _rotation = null) -> void:
	_selection_active = instance_id != null


## Control Manifest use-before-init guard (push_error + safe default, never
## assert — the established pattern; verified engine fact: assert aborts
## the frame and corrupts Object-typed returns).
func _guard_initialized() -> bool:
	if not _initialized:
		push_error("ModeArbitration: method called before init()")
		return false
	return true
