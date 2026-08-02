## PlacementSystem — the single interactive surface for placing and
## relocating gym equipment; sole allocator of `instance_id`.
##
## Stories (Sprint 3, placement-system epic):
##   PL-001 (THIS STORY): drag lifecycle — start / live preview / rotation.
##     Drag initiation, per-cell `can_place` preview with zero writes, and
##     rotation normalization via `((rotation + 90) % 360) as Rotation`.
##   PL-004 (sibling story, merged base): the `instance_id` monotonic
##     counter and its resume-after-load recomputation. Included here as
##     the shared file base so the sprint's parallel branches compose.
## Req:   TR-PS-001 (single interactive surface), TR-PS-002 (live preview
##        via GridSystem.can_place against REAL grid state, no mutation),
##        TR-PS-006/007 (instance_id counter, no save-blob contribution)
## ADR:   ADR-0001 (DI Container & Scene Bootstrap — init(grid, catalog),
##        SimSystem two-phase init), ADR-0003 (GridStateReader Contract —
##        can_place / get_transformed_cells are GridSystem write/query
##        surfaces consumed here; the resume scan uses the granted read
##        surface get_occupant_id()/get_dimensions())
##
## CORE RULE 2 (drag start): a drag begins on mouse-down over a shop
## palette entry. PlacementSystem receives an `equipment_id`, calls
## `EquipmentCatalog.get_definition(equipment_id)` EXACTLY ONCE at
## drag-start, and holds that definition for the whole drag — never
## re-queried mid-drag (catalog data is immutable by contract, AC1).
## Unknown id: `push_error()` and stay IDLE — never enter DRAGGING
## silently (AC15). A second mouse-down while DRAGGING is a silent no-op:
## no state change, no signal, the in-flight drag's def/rotation/anchor
## unchanged (Core Rule 11, AC16).
##
## CORE RULE 3 (live preview): each time the mouse enters a NEW grid cell
## during a drag, `GridSystem.can_place(def cells, anchor, rotation)` runs
## against REAL grid state — a pure read with zero mutation (AC2). The
## valid/invalid result is surfaced on `preview_validity_changed`. Moving
## to the SAME cell twice does not re-run the check (States table event
## granularity: "moves to a new cell").
##
## CORE RULE 4 (rotation): pressing rotate while DRAGGING updates a
## locally-tracked rotation via `rotation = ((rotation + 90) % 360) as
## Rotation` — PlacementSystem performs this normalization explicitly,
## since GridSystem does not. The preview's transformed cells come
## EXCLUSIVELY from `GridSystem.get_transformed_cells(...)` — no local
## transform math, no locally-derived (W, H) (AC3).
##
## RUNTIME PRECONDITION GUARD (rotation, NOT debug-only): before applying
## the formula, validate `rotation in [R0, R90, R180, R270]`. If invalid:
## `push_error("PlacementSystem: corrupt rotation %d" % rotation)` + early
## return (do NOT apply the formula, do NOT update state). Godot's
## `assert()` is stripped in exports — the `push_error()` + bail is the
## load-bearing check. `%360` would silently "launder" an already-corrupt
## value (e.g. a stray 1080 → 0, looking legal) — catch corruption at the
## input (AC4).
##
## TYPING NOTE: `rotation` is typed as the SAME degree-valued Rotation
## enum GridSystem uses (R0=0, R90=90, R180=180, R270=270). Arithmetic on
## enum values in GDScript 4.x promotes the expression to int, so the
## result MUST be cast back with `as GridSystem.Rotation` (verified in a
## headless spike before implementation — the GDD's mandated pre-check).
##
## AC19 (new drag starts at R0): rotation is drag-scoped state. Each new
## drag begins at R0 regardless of what rotation the previous placement
## ended on — never carried across placements.
##
## AC18 (pause independence): PlacementSystem is purely input-driven; it
## never reads tick state and its init() signature carries NO time-system
## dependency. The drag lifecycle behaves identically whether the sim is
## paused or running.
##
## CORE RULE 8 (instance_id resume after load, PL-004):
##   next_instance_id = 0 if S = ∅; else max(S) + 1, where
##   S = {occupant_id(c) : c ∈ cells, occupant_id(c) ≠ -1}
## The resume runs on EVERY load — not just boot — and is invoked by the
## composition root (SaveLoad.load() Phase B step 3, TR-SL-003) AFTER
## GridSystem's own deserialize() commit. The counter is SELF-HEALING: it
## never trusts a separately-stored counter value, only what is actually
## on the grid, so a bad save edit can never desync it.
##
## TRUTHINESS PITFALL: `0` is a fully legal instance_id (the first piece
## ever placed). The occupancy check MUST be `occupant_id != -1` — never
## GDScript's truthy idiom `if occupant_id:`, which treats a legal 0 as
## empty.
##
## SERIALIZATION (TR-PS-007, ADR-0002): PlacementSystem contributes NOTHING
## to the save blob — no serialize()/deserialize(). Its only save-adjacent
## behavior is the read-only recomputation in rederive_counter(), which runs
## after GridSystem's own deserialize() completes.
class_name PlacementSystem extends SimSystem


## Drag state machine (GDD States and Transitions). IDLE = no drag in
## flight; DRAGGING = an active new-placement drag holding a def.
enum DragState { IDLE, DRAGGING }


## Emitted once per live-preview recompute (mouse moved to a NEW cell
## during a drag), carrying the can_place verdict for the CURRENT
## (def, anchor, rotation). Drives the presentation layer's ghost
## valid/invalid tint. The emitted bool ALWAYS equals the bool returned by
## the GridSystem.can_place() call that produced it (AC2).
##
## NOTE: this signal is an extension of the GDD's signal surface (which
## names placement_committed / placement_rejected — Stories 002/003).
## AC2's "the valid/invalid signal matches the returned bool" requires a
## preview-validity signal; none existed in the GDD's Emitted Signals list,
## so this is added here as the minimal contract satisfying AC2.
signal preview_validity_changed(valid: bool)


## Injected grid — the spatial truth source (ADR-0001 Tier 1:
## PlacementSystem.init(grid, catalog)). GridSystem extends
## GridStateReader, so get_occupant_id() / get_dimensions() (the granted
## read surface, ADR-0003) are available for the resume scan; the preview
## surfaces can_place() / get_transformed_cells() are consumed by the
## drag lifecycle.
var _grid: GridSystem

## Injected equipment catalog — queried exactly once per drag via
## get_definition() (AC1); the returned def is held for the whole drag.
var _catalog: EquipmentCatalog


## The instance_id monotonic counter (GDD Core Rules 7/8, PL-004) — the
## next id to allocate on a successful new-placement commit. Incremented
## ONLY by the Story 002 commit path (not yet landed); recomputed from
## grid occupancy by rederive_counter() on every load. 0 is the
## fresh-game value: the first-ever placed piece gets id 0.
var _next_instance_id: int = 0


# === Drag state (PL-001) ===

## Current drag state (DragState). IDLE when no drag is in flight.
var _state: DragState = DragState.IDLE

## The EquipmentDef held for the whole drag (AC1) — populated at
## begin_drag(), never re-queried mid-drag. Null while IDLE.
var _drag_def: EquipmentDef

## Current drag anchor (the cell the mouse is over). Set on each mouse
## move to a new cell; reset to ZERO at drag start (no cell known yet).
var _anchor: Vector2i = Vector2i.ZERO

## Current drag rotation (GridSystem.Rotation, degree-valued). Every new
## drag starts at R0 (AC19); advanced by on_rotate_pressed().
var _rotation: GridSystem.Rotation = GridSystem.Rotation.R0

## Last preview geometry (AC3) — the TransformedFootprint returned by
## GridSystem.get_transformed_cells() after the most recent rotation.
## PlacementSystem never derives (W, H) or transforms cells itself.
var _preview: TransformedFootprint = TransformedFootprint.new()

## Whether the preview has ever run during this drag (first mouse move
## always previews; subsequent moves only on cell change — States table
## "moves to a new cell" event granularity, AC2 no-double-call edge).
var _has_previewed: bool = false

## The last cell the preview ran at. Together with _has_previewed, makes
## a mouse move to the SAME cell a no-op (no can_place call, no signal).
var _last_preview_cell: Vector2i = Vector2i.ZERO


## Two-phase init (ADR-0001). Stores the injected grid and catalog.
## Exactly once — a second call is a hard error (SimSystem._mark_initialized
## guard). Signature carries NO time-system dependency (AC18: the system
## is purely input-driven).
func init(grid: GridSystem, catalog: EquipmentCatalog) -> void:
	if not _mark_initialized():
		return
	_grid = grid
	_catalog = catalog


func system_name() -> String:
	return "PlacementSystem"


## Drag start (Core Rule 2, AC1/AC15/AC16).
##
## Calls EquipmentCatalog.get_definition(equipment_id) EXACTLY once and
## holds the returned def for the whole drag. Unknown id: push_error()
## and stay IDLE (never enter DRAGGING silently, AC15). A second
## mouse-down while DRAGGING is a silent no-op (AC16) — no state change,
## no signal, no catalog query, the in-flight drag untouched.
##
## Every new drag starts at rotation R0 (AC19 — rotation is drag-scoped
## state, never carried across placements).
func begin_drag(equipment_id: String) -> void:
	if not _assert_initialized():
		return
	if _state == DragState.DRAGGING:
		# AC16: second mouse-down while DRAGGING is a no-op — return
		# BEFORE the catalog query so the in-flight drag's def is never
		# disturbed and get_definition is not called a second time.
		return
	var def: EquipmentDef = _catalog.get_definition(equipment_id)
	if def == null:
		# AC15: unknown equipment_id — fail loudly, never enter DRAGGING.
		push_error("PlacementSystem: begin_drag() — unknown equipment_id '%s'" % equipment_id)
		return
	_drag_def = def
	_rotation = GridSystem.Rotation.R0  # AC19: every new drag starts at R0
	_anchor = Vector2i.ZERO
	_preview = TransformedFootprint.new()
	_has_previewed = false
	_last_preview_cell = Vector2i.ZERO
	_state = DragState.DRAGGING


## Live preview (Core Rule 3, AC2): the mouse entered [cell] during a
## drag. Runs GridSystem.can_place(def cells, cell, rotation) against
## REAL grid state — a pure read, zero writes — and emits
## preview_validity_changed(valid) with the returned verdict.
##
## Moving to the SAME cell as the last preview is a no-op (no can_place
## call, no signal) — the States table's event is "mouse moves to a NEW
## cell". Mouse moves while IDLE are silent no-ops.
func on_mouse_moved(cell: Vector2i) -> void:
	if not _assert_initialized():
		return
	if _state != DragState.DRAGGING:
		return  # not dragging — ignore motion silently
	if _has_previewed and cell == _last_preview_cell:
		return  # same cell — no re-preview (no double call)
	_has_previewed = true
	_last_preview_cell = cell
	_anchor = cell
	var result: PlacementCheckResult = _grid.can_place(
		_drag_def.footprint_cells, _drag_def.access_cells, _anchor, _rotation
	)
	preview_validity_changed.emit(result.valid)


## Rotation during drag (Core Rule 4, AC3/AC4/AC5).
##
## Guarded by a RUNTIME precondition (not debug-only): rotation must be
## one of the four legal Rotation values. If corrupt, push_error() fires
## BEFORE any write and the method returns — rotation is never silently
## laundered to a legal value by the modulo (AC4). Then applies
## `((rotation + 90) % 360) as GridSystem.Rotation` (the `as` cast is
## mandatory: enum arithmetic promotes to int in GDScript 4.x) and
## recomputes the preview cells EXCLUSIVELY via
## GridSystem.get_transformed_cells() — no local transform math (AC3).
##
## Rotate while IDLE is a silent no-op.
func on_rotate_pressed() -> void:
	if not _assert_initialized():
		return
	if _state != DragState.DRAGGING:
		return  # no drag — rotate is a silent no-op
	if not _is_legal_rotation(_rotation):
		# AC4: guard fires BEFORE any write — never launder a corrupt value.
		push_error("PlacementSystem: corrupt rotation %d" % _rotation)
		return
	_rotation = ((_rotation + 90) % 360) as GridSystem.Rotation
	_preview = _grid.get_transformed_cells(
		_drag_def.footprint_cells, _drag_def.access_cells, _anchor, _rotation
	)


## WHITE-BOX TEST SEAM (Story 001 / AC4 precondition) — test-only.
##
## AC4 requires a PlacementSystem whose rotation has been corrupted to an
## out-of-enum value (e.g. 1080) to prove the runtime precondition guard
## push_errors and refuses to launder it. Production code can never write
## a corrupt value into _rotation (every write path normalizes), so the
## only way to construct the precondition is this seam — the same
## documented pattern as PL-004's _test_set_next_instance_id(). Reachable
## only from tests/unit/placement_system/; never from any production call
## site. GDScript does not enforce enum membership at runtime, so an int
## assignment into the enum-typed field is accepted (spike-verified).
func _test_set_rotation_unchecked(value: int) -> void:
	if not _assert_initialized():
		return
	_rotation = value


## Returns true iff [rot] is one of the four legal Rotation enum values
## (the runtime guard's membership check — GDScript does not enforce enum
## membership on a Rotation-typed parameter).
func _is_legal_rotation(rot: int) -> bool:
	return (
		rot == GridSystem.Rotation.R0
		or rot == GridSystem.Rotation.R90
		or rot == GridSystem.Rotation.R180
		or rot == GridSystem.Rotation.R270
	)


## Public read of the instance_id counter (GDD Core Rule 8 output, PL-004).
## Used by tests to observe resume results and by the Story 002 commit
## path, which consumes this value when allocating a new instance_id.
##
## Before-init safe default: 0 (the fresh-game counter value), per the
## SimSystem guard contract (push_error + safe default, never a crash).
func get_next_instance_id() -> int:
	if not _assert_initialized():
		return 0
	return _next_instance_id


## Resume-after-load recomputation (GDD Core Rule 8, instance_id_resume_formula,
## TR-PS-006, PL-004) — the ONLY save-adjacent behavior on this system.
##
## Scans every cell in get_dimensions() (130 cells at MVP — trivial) via the
## granted GridStateReader read surface, collects the occupied-id set
##   S = {occupant_id(c) : c ∈ cells, occupant_id(c) ≠ -1}
## then sets
##   next_instance_id = 0 if S = ∅ (explicit branch — max() over an empty
##                        set is undefined, never a fallthrough)
##                    = max(S) + 1 otherwise
##
## Runs on EVERY load (not just boot), invoked by the composition root:
## SaveLoad.load() Phase B step 3 calls this AFTER GridSystem.deserialize()
## commit (TR-SL-003; the AC4 load-order test pins the sequence). It is
## self-healing: trusts grid occupancy only, never a stored counter — a
## stray/desynced counter value is overwritten by what is actually on the
## grid.
##
## The `!= -1` comparison is load-bearing: id 0 is legal and must count as
## present. Never use a truthy check here.
func rederive_counter() -> void:
	if not _assert_initialized():
		return
	if _grid == null:
		push_error("PlacementSystem: rederive_counter() called with no grid injected.")
		return
	var dims: Vector2i = _grid.get_dimensions()
	var max_occupant_id: int = -1  # -1 = "no occupants found yet" sentinel
	for y in dims.y:
		for x in dims.x:
			var occupant_id: int = _grid.get_occupant_id(Vector2i(x, y))
			# Explicit `!= -1` — NEVER truthiness: 0 is a legal occupant id
			# (first piece placed) and must be counted as present.
			if occupant_id != -1 and occupant_id > max_occupant_id:
				max_occupant_id = occupant_id
	# Explicit empty-set branch: max() over ∅ is undefined (GDD formula).
	_next_instance_id = 0 if max_occupant_id == -1 else max_occupant_id + 1


## WHITE-BOX TEST SEAM (Story 004 / AC13 precondition, PL-004) — test-only.
##
## AC13 requires a PlacementSystem whose counter has drifted to a stray
## value (999) while the grid holds a different reality, to prove
## rederive_counter() re-derives from grid occupancy and ignores the
## counter's current value. Production code can never write a stray value
## into the counter (no serialize path exists — TR-PS-007), so the only way
## to construct the precondition is this seam. Reachable only from
## tests/unit/placement_system/; never from any production call site.
func _test_set_next_instance_id(value: int) -> void:
	_next_instance_id = value
