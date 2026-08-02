## PlacementSystem — the single interactive surface for placing and
## relocating gym equipment; sole allocator of `instance_id`.
##
## Story: placement-system / story-004-instance-id-resume-after-load.md
## Req:   TR-PS-006 (instance_id allocation: single monotonic counter;
##        next_instance_id = max(all occupant_ids) + 1 on load),
##        TR-PS-007 (stores NO data in the save file; counter fully
##        reconstructible from GridSystem)
## ADR:   ADR-0001 (DI Container & Scene Bootstrap — init(grid, catalog),
##        SimSystem two-phase init), ADR-0002 (Storage Format — systems with
##        no serializable state omit serialize()/deserialize()),
##        ADR-0003 (GridStateReader Contract — the granted read surface the
##        resume scan uses)
##
## SCOPE (Story 004): the `instance_id` monotonic counter and its
## resume-after-load recomputation ONLY. The drag/rotate/drop lifecycle,
## commit/reject signals, and relocation land in Stories 001-003/005; this
## file deliberately exposes no drag state yet.
##
## CORE RULE 8 (GDD) — instance_id resume after load:
##   next_instance_id = 0 if S = ∅; else max(S) + 1, where
##   S = {occupant_id(c) : c ∈ cells, occupant_id(c) ≠ -1}
## The resume runs on EVERY load — not just boot — and is invoked by the
## composition root (SaveLoad.load() Phase B step 3, TR-SL-003) AFTER
## GridSystem's own deserialize() commit. The counter is SELF-HEALING: it
## never trusts a separately-stored counter value, only what is actually on
## the grid, so a bad save edit can never desync it (AC13).
##
## TRUTHINESS PITFALL: `0` is a fully legal instance_id (the first piece
## ever placed). The occupancy check MUST be `occupant_id != -1` — never
## GDScript's truthy idiom `if occupant_id:`, which treats a legal 0 as
## empty. AC12 exists specifically to catch this.
##
## SERIALIZATION (TR-PS-007, ADR-0002): PlacementSystem contributes NOTHING
## to the save blob — no serialize()/deserialize(). Its only save-adjacent
## behavior is the read-only recomputation in rederive_counter(), which runs
## after GridSystem's own deserialize() completes.
class_name PlacementSystem extends SimSystem

## Injected grid — the sole truth source for the resume scan (ADR-0001
## Tier 1: PlacementSystem.init(grid, catalog)). GridSystem extends
## GridStateReader, so get_occupant_id() / get_dimensions() (the granted
## read surface, ADR-0003) are available; the write methods
## (can_place/commit/clear) are consumed by the Stories 001-005 interaction
## logic, not by this story.
var _grid: GridSystem

## Injected equipment catalog — UNUSED by Story 004 (the resume scans only
## the grid). Stored now because ADR-0001 locks the init(grid, catalog)
## signature; Story 001 (drag lifecycle) is the first consumer.
var _catalog: EquipmentCatalog

## The instance_id monotonic counter (GDD Core Rules 7/8) — the next id to
## allocate on a successful new-placement commit. Incremented ONLY by the
## Story 002 commit path (not yet landed); recomputed from grid occupancy
## by rederive_counter() on every load. 0 is the fresh-game value: the
## first-ever placed piece gets id 0 (AC11).
var _next_instance_id: int = 0


## Two-phase init (ADR-0001). Stores the injected grid (truth source for
## the resume scan) and catalog (unused until Story 001). Exactly once —
## a second call is a hard error (SimSystem._mark_initialized guard).
func init(grid: GridSystem, catalog: EquipmentCatalog) -> void:
	if not _mark_initialized():
		return
	_grid = grid
	_catalog = catalog


func system_name() -> String:
	return "PlacementSystem"


## Public read of the instance_id counter (GDD Core Rule 8 output). Used by
## tests to observe resume results (AC11-13) and by the Story 002 commit
## path, which consumes this value when allocating a new instance_id.
##
## Before-init safe default: 0 (the fresh-game counter value), per the
## SimSystem guard contract (push_error + safe default, never a crash).
func get_next_instance_id() -> int:
	if not _assert_initialized():
		return 0
	return _next_instance_id


## Resume-after-load recomputation (GDD Core Rule 8, instance_id_resume_formula,
## TR-PS-006) — the ONLY save-adjacent behavior on this system.
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
## grid (AC13).
##
## The `!= -1` comparison is load-bearing: id 0 is legal and must count as
## present (AC12). Never use a truthy check here.
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
			# (first piece placed) and must be counted as present (AC12).
			if occupant_id != -1 and occupant_id > max_occupant_id:
				max_occupant_id = occupant_id
	# Explicit empty-set branch: max() over ∅ is undefined (GDD formula).
	_next_instance_id = 0 if max_occupant_id == -1 else max_occupant_id + 1


## WHITE-BOX TEST SEAM (Story 004 / AC13 precondition) — test-only.
##
## AC13 requires a PlacementSystem whose counter has drifted to a stray
## value (999) while the grid holds a different reality, to prove
## rederive_counter() re-derives from grid occupancy and ignores the
## counter's current value. Production code can never write a stray value
## into the counter (no serialize path exists — TR-PS-007), so the only way
## to construct the precondition is this seam — the same documented pattern
## as AC4's _test_set_rotation_unchecked(). Reachable only from
## tests/unit/placement_system/; never from any production call site.
func _test_set_next_instance_id(value: int) -> void:
	_next_instance_id = value
