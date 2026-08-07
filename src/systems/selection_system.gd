## SelectionSystem — single-select logic core + instance mapping
## (selection-system epic, Story 001; TR-SEL-001/004/005; GDD Core Rules
## 1/6/8; ADR-0005 S7).
##
## RefCounted logic object with NO scene-tree presence (TR-SEL-008) — the
## same DI discipline as GridSystem/PlacementSystem. A thin presentation
## bridge Node (Story 002) forwards clicks as on_cell_clicked(cell) and
## keyboard events as on_esc_pressed().
##
## GRID READ CONTRACT (grid-system.md per-consumer table, AC-X.4):
##   SelectionSystem reads GridSystem occupancy via get_occupant_id(cell)
##   ONLY — never get_placed_instances()/get_snapshot()/get_access_cells()
##   (bulk state). Two additional PER-CELL queries are required by the ACs:
##   get_buildable(cell) (AC2: only buildable floor deselects) and
##   is_in_bounds(cell) (click validation; the bridge must not forward OOB).
##   All three are single-cell reads of the same character; the mapping is
##   self-maintained and never bulk-reads the grid.
##   ONE SANCTIONED EXCEPTION — the load-time rebuild (Story 005 / Core
##   Rule 8 / TR-SEL-006): rebuild_mapping() reads get_placed_instances(),
##   the GDD's granted "load-time bulk read surface for mapping rebuild".
##   The runtime maintenance paths never bulk-read; only this one-time load
##   step does (and it is the mapping's ONLY other input — see below).
##
## INSTANCE MAPPING (TR-SEL-005 / Core Rule 8) — self-maintained
##   instance_id → {equipment_id, anchor, rotation, footprint_cells},
## built by subscribing to:
##   - PlacementSystem.placement_committed(instance_id, equipment_id,
##     footprint_cells) — the add/refresh path. The signal carries NO
##     rotation, so rotation is DERIVED by matching the transformed
##     footprint against the catalog def at each of the four rotations
##     (the transform formula is GridSystem's GDD D.1, replicated locally
##     so SelectionSystem keeps its GridSystem calls to per-cell reads).
##   - GridSystem.grid_changed(footprint_cells_changed, access_cells_changed)
##     — the reconciliation path. Cells whose occupant vanished are matched
##     against mapping footprints; owning entries are dropped; if the
##     dropped instance was selected, selection clears and
##     selection_changed(null) fires (AC11 external invalidation; also the
##     relocate pickup, which per GDD Core Rule 3 clears selection the
##     instant Move hands off).
##   - Load-time rebuild (Story 005 / Core Rule 8 / TR-SEL-006/007): on
##     load, NO placement_committed or grid_changed fires, so the mapping
##     is rebuilt by rebuild_mapping() from the loaded grid — scan every
##     occupied cell (per-cell reads, the same surface as the runtime
##     path), group by occupant_id, and recover {equipment_id, rotation,
##     anchor} by matching the transformed footprint against the catalog
##     (the grid stores only integer occupant_id — TR-GS — so equipment
##     identity is recovered geometrically; see rebuild_mapping()).
##     SelectionSystem contributes NOTHING to the save blob (TR-SL-008);
##     this rebuild is its only load-side restoration.
##
## SIGNAL (TR-SEL-004 / Core Rule 6 / ADR-0005 S7):
##   select:   selection_changed.emit(instance_id, def, anchor_cell, rotation)
##             — EXACTLY FOUR arguments
##   deselect: selection_changed.emit(null) — EXACTLY ONE argument
## GDScript dispatches exactly the args passed to emit() (probe-verified in
## 4.7.1: emitting fewer args than declared is legal, emitting more is a
## runtime error; a connected callable with FEWER parameters than emitted
## args errors, so handlers must declare optional params). Consumers MUST
## declare handlers that accept 1..4 args, e.g.
##   func _on_selection_changed(instance_id = null, equipment_def = null,
##                              cell = null, rotation = null) -> void
## and treat a null instance_id as deselect. NEVER test truthiness of
## instance_id — 0 is a legal selected instance.
##
## NO SCENE-TREE / NO AWAIT (TR-SEL-008): this object never receives
## _input(), never creates timers via get_tree(), and selection resolution
## is pure synchronous logic (no await) — the bridge owns all of that.
class_name SelectionSystem extends SimSystem


## S7 in the ADR-0005 Signal Catalog (arity 4 on select, 1 on deselect —
## see class doc for the engine semantics and the consumer contract).
signal selection_changed(instance_id: int, equipment_def: EquipmentDef, cell: Vector2i, rotation: int)


## Injected grid — occupancy truth, read via get_occupant_id(cell) only
## (plus get_buildable/is_in_bounds per-cell queries, see class doc).
var _grid: GridSystem

## Injected placement — is_dragging() suppression (AC12) and the
## placement_committed subscription (mapping add/refresh).
var _placement: PlacementSystem

## Injected catalog — def lookup for the select payload and for the
## rotation/anchor derivation at mapping-build time.
var _catalog: EquipmentCatalog


## Current selection; -1 = none (GridSystem's empty sentinel convention).
## 0 is a fully legal selected instance_id — comparisons must be explicit
## (never GDScript truthiness).
var _selected_instance_id: int = -1

## instance_id → entry. Entry shape:
##   { "equipment_id": String,
##     "anchor": Vector2i,                  # min-offset of transformed fp∪ac
##                                          # (PlacedInstance.anchor convention,
##                                          # AC-D5.2 — see _derive_entry)
##     "rotation": int,                     # degree-valued Rotation, derived by
##                                          # footprint matching (lowest match —
##                                          # deterministic for symmetric shapes)
##     "footprint_cells": Array[Vector2i] } # transformed footprint, owned copy
##                                          # (grid_changed reconciliation)
var _mapping: Dictionary = {}


## Two-phase init (ADR-0001). Stores the injected dependencies; NO side
## effects (signal subscriptions live in _post_init). Exactly once — a
## second call is a hard error (SimSystem._mark_initialized guard).
func init(grid: GridSystem, placement: PlacementSystem, catalog: EquipmentCatalog) -> void:
	if not _mark_initialized():
		return
	_grid = grid
	_placement = placement
	_catalog = catalog


func system_name() -> String:
	return "SelectionSystem"


## Side effects — the mapping's two signal subscriptions (ADR-0001: init()
## stores references only; connections go here). The orchestrator calls
## this once after all systems exist; unit tests call it explicitly to wire
## the mapping. Missing dependencies are a wiring error — loud, no silent
## partial wiring.
func _post_init() -> void:
	if not _assert_initialized():
		return
	if _grid == null or _placement == null:
		push_error("SelectionSystem._post_init() — grid/placement not injected; mapping will not be wired.")
		return
	_grid.grid_changed.connect(_on_grid_changed)
	_placement.placement_committed.connect(_on_placement_committed)


# === Click / keyboard entry points (bridge forwards, Story 002) ===

## CLICK RESOLUTION (Core Rule 1, TR-SEL-001) — the bridge (Story 002)
## converts screen→cell and calls this. Pure synchronous logic, no await.
##   - placed piece            → select (AC1); different piece → direct swap
##                               with no intermediate deselect (AC9);
##                               already-selected piece → NO-OP (AC10)
##   - empty BUILDABLE floor   → deselect (AC2); non-buildable floor → no-op
##   - placement drag active   → no resolution at all (AC12)
func on_cell_clicked(cell: Vector2i) -> void:
	if not _assert_initialized():
		return
	# AC12: while PlacementSystem owns a drag, clicks never resolve a
	# selection (modes never fight).
	if _placement != null and _placement.is_dragging():
		return
	if _grid == null:
		push_error("SelectionSystem: on_cell_clicked() called with no grid injected.")
		return
	if not _grid.is_in_bounds(cell):
		return  # the bridge must not forward OOB cells; silently ignore
	var occupant_id: int = _grid.get_occupant_id(cell)
	if occupant_id == -1:
		# Empty floor. AC2 edge case: only BUILDABLE floor deselects —
		# clicking a non-buildable cell is a silent no-op.
		if _grid.get_buildable(cell):
			_clear_selection()
		return
	# A placed piece.
	if occupant_id == _selected_instance_id:
		return  # AC10: re-clicking the selected piece is a NO-OP (not a toggle-off)
	_select_instance(occupant_id)


## ESC — deselect (Core Rule 1; Story 001 owns the deselect logic, Story
## 002's bridge forwards the key). No-op when nothing is selected. The
## pending-sell-confirm cancel is Story 003's bridge-side state.
func on_esc_pressed() -> void:
	if not _assert_initialized():
		return
	_clear_selection()


## Programmatic deselect — the build/select arbitration's build-take-over
## entry (build-shop-ui GDD Core Rule 4, story BSUI-003): the palette
## clears an active selection BEFORE starting a placement drag, so the
## placement ghost and the selection outline can never coexist (no dual
## ghost). Semantically identical to on_esc_pressed() (same _clear_selection
## + selection_changed(null) emission, no-op when nothing is selected)
## without the key-event connotation — the UI calls this when build takes
## over, not when the player presses Esc. ModeArbitration invokes it via
## its begin_build() handoff.
func clear_selection() -> void:
	if not _assert_initialized():
		return
	_clear_selection()


## Current selected instance_id, or -1 when none. 0 is a legal selection —
## compare explicitly, never truthiness. Before-init safe default: -1
## (Control Manifest guard contract).
func get_selected_instance_id() -> int:
	if not _assert_initialized():
		return -1
	return _selected_instance_id


# === Selection resolution internals ===

## Resolves [instance_id] through the local mapping and emits the select
## payload. Direct swap (AC9): overwrites the selection state without an
## intermediate deselect emission.
func _select_instance(instance_id: int) -> void:
	if not _mapping.has(instance_id):
		# Story 005's load-time rebuild runs before any click; a click that
		# resolves an instance with no mapping entry is a data-consistency
		# error (piece predates this system / rebuild missing). Loud, no-op.
		push_error("SelectionSystem: click resolved instance_id %d but the mapping has no entry (load-time rebuild missing?)." % instance_id)
		return
	var entry: Dictionary = _mapping[instance_id]
	var equipment_id: String = entry["equipment_id"]
	var def: EquipmentDef = _catalog.get_definition(equipment_id)
	if def == null:
		push_error("SelectionSystem: catalog lost definition for '%s' (mapping inconsistency)." % equipment_id)
		return
	# Explicit typed reads — Dictionary access returns Variant (4.7 pitfall).
	var anchor: Vector2i = entry["anchor"]
	var rotation: int = entry["rotation"]
	_selected_instance_id = instance_id
	# Exactly 4 args — arity must match the signal declaration (TR-SEL-004;
	# GDScript does not check arity at parse time).
	selection_changed.emit(instance_id, def, anchor, rotation)


## Clears the selection and emits selection_changed(null) — EXACTLY ONE
## argument (TR-SEL-004). No-op (no signal) when nothing is selected.
func _clear_selection() -> void:
	if _selected_instance_id == -1:
		return
	_selected_instance_id = -1
	selection_changed.emit(null)


# === Mapping maintenance (TR-SEL-005) ===

## placement_committed handler — the mapping's add/refresh path. Anchor +
## rotation are DERIVED from the transformed footprint by matching against
## the catalog def (the signal carries no rotation). A catalog miss is a
## data-consistency error: loud, no entry recorded (the click path will
## then fail loudly too rather than resolve a half-built entry).
func _on_placement_committed(instance_id: int, equipment_id: String, footprint_cells: Array[Vector2i]) -> void:
	if not _assert_initialized():
		return
	var derived := _derive_entry(equipment_id, footprint_cells)
	if derived.is_empty():
		return  # catalog miss already push_error'd — record nothing
	_mapping[instance_id] = {
		"equipment_id": equipment_id,
		"anchor": derived["anchor"],
		"rotation": derived["rotation"],
		"footprint_cells": footprint_cells.duplicate(),  # owned copy (defensive)
	}


## grid_changed handler — the mapping's reconciliation path. On every
## commit/clear, changed cells whose occupant vanished (get_occupant_id ==
## -1) are matched against mapping footprints; owning entries are dropped.
## If the dropped instance was selected → selection clears +
## selection_changed(null) (AC11 external invalidation; also the relocate
## pickup, which per GDD Core Rule 3 clears selection the instant Move
## hands off). Commit-side additions are NOT handled here —
## placement_committed follows grid_changed in the same operation and owns
## entry creation.
func _on_grid_changed(footprint_cells_changed: Array[Vector2i], access_cells_changed: Array[Vector2i]) -> void:
	if not _assert_initialized():
		return
	var removed: Array[int] = []
	for cell in footprint_cells_changed:
		var occupant: int = _grid.get_occupant_id(cell)
		if occupant != -1:
			continue  # still occupied — nothing to reconcile
		for instance_id in _mapping.keys():
			if removed.has(instance_id):
				continue
			if _cells_contain(_mapping[instance_id]["footprint_cells"], cell):
				removed.append(instance_id)
	for instance_id in removed:
		_mapping.erase(instance_id)
		if instance_id == _selected_instance_id:
			_clear_selection()


## Load-time mapping rebuild (Core Rule 8, TR-SEL-006/007) — the mapping's
## THIRD input: seeded from the loaded grid instead of runtime signals.
##
## Called by SaveLoad.load() Phase B step 3a (TR-SL-003) AFTER
## GridSystem.deserialize() commit and BEFORE the session unpauses — no
## placement_committed or grid_changed fires during load, so without this
## step the mapping would be empty and the first click would fail to
## resolve (the UX load-robustness AC).
##
## Source: GridSystem's LOAD-TIME BULK READ SURFACE — get_placed_instances()
## (GDD dependency table: "get_occupant_id(cell) + load-time bulk read
## surface for mapping rebuild (Core Rule 8)"). The DTO carries each
## restored instance's footprint, access, ANCHOR, and ROTATION — the last
## two are authoritative (they were written to the PlacementRecord at
## commit time and round-trip through the save blob verbatim), so the
## rebuild copies them directly. Only equipment_id needs recovery: the grid
## stores just integer occupant_id (TR-GS), so identity is matched
## geometrically against the catalog at the KNOWN rotation.
##
## Why the bulk surface and not a per-cell scan: rotation is order-
## ambiguous from occupied cells alone. The runtime _derive_entry resolves
## R0 vs R180 for a straight 1×2 by the ARRAY ORDER of placement_committed's
## footprint (canonical def order preserved at commit); a row-major cell
## scan loses that order, and the min-offset match would collapse R180 to
## R0. The save blob stores the rotation, GridSystem restores it, and the
## bulk surface carries it — so the rebuild reproduces the runtime mapping
## EXACTLY (TR-SEL-007: "mapping after load equals mapping before save").
##
## Idempotent: rebuilds the mapping from scratch — running twice yields the
## identical mapping (QA idempotency case). Also resets the selection to
## none (GDD States: "(at load) mapping rebuilt → none selected").
##
## TR-SEL-007: SelectionSystem contributes NOTHING to the save blob; this
## rebuild is its ONLY load-side restoration (derived state).
##
## Edge cases:
## - zero placed pieces → empty mapping, no error
## - an occupant whose footprint matches NO catalog def → data-consistency
##   error (shouldn't happen): push_error + skip the entry (the piece stays
##   on the grid but cannot be selected — loud, never a half-built entry)
func rebuild_mapping() -> void:
	if not _assert_initialized():
		return
	if _grid == null:
		push_error("SelectionSystem: rebuild_mapping() called with no grid injected.")
		return
	if _catalog == null:
		push_error("SelectionSystem: rebuild_mapping() called with no catalog injected.")
		return
	# Rebuild the mapping from scratch (idempotent) and reset the selection
	# (GDD States: "(at load) mapping rebuilt → none selected").
	_mapping = {}
	_selected_instance_id = -1
	for placed in _grid.get_placed_instances():
		var equipment_id := _match_equipment_id(placed)
		if equipment_id == "":
			continue  # no catalog match — already push_error'd; skip entry
		_mapping[placed.instance_id] = {
			"equipment_id": equipment_id,
			"anchor": placed.anchor,          # authoritative — restored from the save
			"rotation": placed.rotation,      # authoritative — restored from the save
			"footprint_cells": placed.footprint_cells.duplicate(),  # owned copy
		}


## Recovers the equipment_id for one restored PlacedInstance by matching its
## transformed footprint against the catalog AT THE INSTANCE'S KNOWN
## ROTATION (the rotation is restored grid data, not derived). Returns ""
## (after push_error) when no def reproduces the footprint — the caller
## skips the entry (data-consistency error; should never happen).
##
## Matching is ORDER-INDEPENDENT: serialization sorts cells lexicographically
## (_serialize_cells), so the DTO's footprint order is never the canonical
## def order. The placement anchor is derived from the MIN-OFFSET
## relationship (placement_anchor = min(footprint) − min(rotated_offsets))
## and verified by exact set equality — rotation is a bijection on offsets
## plus a constant anchor shift, so set equality with equal cardinality is
## an exact match.
##
## Determinism: catalog id order (get_all_ids = file order) — the FIRST
## match wins, so identical-footprint defs resolve deterministically.
func _match_equipment_id(placed: PlacedInstance) -> String:
	var observed: Array[Vector2i] = placed.footprint_cells
	for equipment_id in _catalog.get_all_ids():
		var def: EquipmentDef = _catalog.get_definition(equipment_id)
		if def == null:
			continue  # catalog lost a def mid-session; try the next id
		var wh := _declared_bounds(def.footprint_cells, def.access_cells)
		var w := wh.x
		var h := wh.y
		var rotated_offsets: Array[Vector2i] = []
		for cell in def.footprint_cells:
			rotated_offsets.append(_rotate_offset(cell.x, cell.y, placed.rotation, w, h))
		if rotated_offsets.size() != observed.size():
			continue  # wrong cardinality — cannot match
		var placement_anchor: Vector2i = _min_offset(observed) - _min_offset(rotated_offsets)
		if _footprint_matches(def.footprint_cells, observed, placed.rotation, w, h, placement_anchor):
			return equipment_id
	# No def reproduces this footprint — data inconsistency (shouldn't
	# happen: the piece predates the catalog or the catalog changed).
	# NOTE: %s with a typed Array RHS is treated as an args list — str() wrap.
	push_error("SelectionSystem: rebuild_mapping() — no catalog definition matches footprint %s." % str(observed))
	return ""


# === Anchor/rotation derivation (the mapping's only other input) ===

## Derives {anchor, rotation} for a newly committed placement from the
## transformed footprint + catalog def (placement_committed carries no
## rotation). Returns {} (after push_error) when the catalog misses the
## equipment_id — the caller records nothing.
##
## Rotation: the lowest rotation r ∈ {0, 90, 180, 270} whose transform of
## the canonical def footprint at the implied placement anchor reproduces
## the signal's transformed footprint as a set. The lowest-match rule makes
## symmetric shapes (1×1, 2×2) deterministic: they always resolve to R0.
##
## Anchor: min-offset of the transformed footprint ∪ access — the
## PlacedInstance.anchor convention (AC-D5.2). Access cells are
## reconstructed from the catalog def at the matched rotation because the
## signal carries only the footprint; this keeps the payload anchor
## consistent with what GridSystem.get_placed_instances() reports.
func _derive_entry(equipment_id: String, footprint_cells: Array[Vector2i]) -> Dictionary:
	var def: EquipmentDef = _catalog.get_definition(equipment_id)
	if def == null:
		push_error("SelectionSystem: placement_committed for unknown equipment '%s' — mapping entry not recorded." % equipment_id)
		return {}
	var wh := _declared_bounds(def.footprint_cells, def.access_cells)
	var w := wh.x
	var h := wh.y
	var first_cell: Vector2i = footprint_cells[0]
	var rotations: Array[int] = [
		GridSystem.Rotation.R0,
		GridSystem.Rotation.R90,
		GridSystem.Rotation.R180,
		GridSystem.Rotation.R270,
	]
	for rot in rotations:
		var offset0 := _rotate_offset(def.footprint_cells[0].x, def.footprint_cells[0].y, rot, w, h)
		var placement_anchor := first_cell - offset0
		if _footprint_matches(def.footprint_cells, footprint_cells, rot, w, h, placement_anchor):
			var union_min := _union_min_offset(def.footprint_cells, def.access_cells, rot, w, h)
			return {
				"anchor": placement_anchor + union_min,
				"rotation": rot,
			}
	# No rotation matches — the footprint came from a different def/rotation
	# than the catalog knows. Data inconsistency; be loud and record R0 with
	# the footprint min-offset anchor so the piece stays selectable.
	push_error("SelectionSystem: no rotation of '%s' matches transformed footprint %s (mapping inconsistency)." % [equipment_id, footprint_cells])
	return {"anchor": _min_offset(footprint_cells), "rotation": GridSystem.Rotation.R0}


## True iff transforming every canonical def footprint cell at [rot] by
## [placement_anchor] reproduces [transformed_footprint] as a set. Rotation
## is a bijection on offsets plus a constant anchor shift, so set equality
## with equal cardinality is an exact match (order-independent — robust to
## any future reordering of the signal payload).
func _footprint_matches(canonical_fp: Array[Vector2i], transformed_fp: Array[Vector2i], rot: int, w: int, h: int, placement_anchor: Vector2i) -> bool:
	if canonical_fp.size() != transformed_fp.size():
		return false
	var seen: Dictionary = {}
	for cell in transformed_fp:
		seen[cell] = true
	for cell in canonical_fp:
		var transformed: Vector2i = placement_anchor + _rotate_offset(cell.x, cell.y, rot, w, h)
		if not seen.has(transformed):
			return false
	return true


## Min offset of the transformed footprint ∪ access at [rot] — the
## PlacedInstance.anchor convention requires the min over the UNION
## (AC-D5.2), and placement_committed carries only the footprint, so access
## cells are reconstructed from the catalog def.
func _union_min_offset(canonical_fp: Array[Vector2i], canonical_ac: Array[Vector2i], rot: int, w: int, h: int) -> Vector2i:
	var offsets: Array[Vector2i] = []
	for cell in canonical_fp + canonical_ac:
		offsets.append(_rotate_offset(cell.x, cell.y, rot, w, h))
	return _min_offset(offsets)


## Local replication of GridSystem._transform_cell / GDD D.1 — the same
## 4-branch rotation math (R0/R90/R180/R270 with the union (W, H)). Kept
## local so SelectionSystem's GridSystem calls stay per-cell reads only
## (the per-consumer contract). Illegal rotations are loud and return ZERO
## (internal helper; callers only pass the four legal values).
func _rotate_offset(x: int, y: int, rot: int, w: int, h: int) -> Vector2i:
	match rot:
		GridSystem.Rotation.R0:
			return Vector2i(x, y)
		GridSystem.Rotation.R90:
			return Vector2i(h - 1 - y, x)
		GridSystem.Rotation.R180:
			return Vector2i(w - 1 - x, h - 1 - y)
		GridSystem.Rotation.R270:
			return Vector2i(y, w - 1 - x)
		_:
			push_error("SelectionSystem: _rotate_offset() illegal rotation %d." % rot)
			return Vector2i.ZERO


## Min (x, y) offset across [cells]; Vector2i.ZERO for empty (mirrors
## GridSystem._min_offset semantics).
func _min_offset(cells: Array) -> Vector2i:
	if cells.is_empty():
		return Vector2i.ZERO
	var first: Vector2i = cells[0]
	var min_x := first.x
	var min_y := first.y
	for cell in cells:
		var c: Vector2i = cell
		min_x = min(min_x, c.x)
		min_y = min(min_y, c.y)
	return Vector2i(min_x, min_y)


## Declared bounding box (w, h) of footprint ∪ access — GDD D.1's (W, H)
## used by the rotation transform (mirrors GridSystem.declared_bounds).
func _declared_bounds(footprint_cells: Array[Vector2i], access_cells: Array[Vector2i]) -> Vector2i:
	var all: Array = []
	all.append_array(footprint_cells)
	all.append_array(access_cells)
	var min_c := _min_offset(all)
	var max_x := min_c.x
	var max_y := min_c.y
	for cell in all:
		var c: Vector2i = cell
		max_x = max(max_x, c.x)
		max_y = max(max_y, c.y)
	return Vector2i(max_x - min_c.x + 1, max_y - min_c.y + 1)


## True iff [cells] contains [cell] (membership helper for the mapping's
## footprint arrays during grid_changed reconciliation).
func _cells_contain(cells: Array, cell: Vector2i) -> bool:
	for c in cells:
		if c == cell:
			return true
	return false
