## BuildShopPalette — the edge-docked shop rack: renders every catalog item
## as a PaletteTile with its availability state, and re-greys on Economy's
## balance_changed signal (build-shop-ui epic, Story 001; TR-BSUI-001/002/006;
## GDD Core Rule 1; ADR-0005).
##
## Presentation + routing only (GDD Core Rule 5): owns no money, no catalog
## data (reads via injected EquipmentCatalog), no placement state. It renders
## the availability state the injected PaletteAvailability query layer reports
## (Story 002 supplies the real Shop; this card ships
## PlaceholderPaletteAvailability as the 占位 availability state).
##
## TR-BSUI-002 / AC2: subscribes to Economy.balance_changed (S6, typed signal
## connection — Control Manifest: string-based connects forbidden) and
## re-derives every tile's state SYNCHRONOUSLY in the handler — no manual
## refresh, no await, so a newly-affordable item is full-tint within one frame
## of the balance mutation.
##
## Drag gating (AC1's mouse-down inertness) is Story 002's logic; this card
## ships the rendered states plus is_item_draggable()/get_state() queries the
## gate consumes.
##
## Node lifecycle: the palette is a scene-tree Control (NOT a RefCounted sim
## system — ADR-0005 "The palette is a Control hierarchy"). Connections to
## Economy die with the node; the composition root owns it for the session.
class_name BuildShopPalette extends HBoxContainer

## Fired after every availability re-derive (init and each balance_changed).
## Story 002/003 hook this for gating re-evaluation. Arity: 0.
signal palette_refreshed

## preload aliases for the NEW sibling classes — the story's documented
## headless pattern: "headless 下 cross-script refs via preload aliases"
## (global class cache is editor-generated; preload works regardless).
const PaletteTileScript := preload("res://src/ui/palette_tile.gd")
const PaletteAvailabilityScript := preload("res://src/ui/palette_availability.gd")
const PlacementSystemScript := preload("res://src/systems/placement_system.gd")

## Calm empty-catalog hint (GDD Edge Cases: "nothing available yet", no error,
## no crash).
const EMPTY_HINT_TEXT := "Nothing available yet"

## Hover tooltip for locked items — distinct from the Save-$X affordability
## text (shop-purchase.md Core Rule 5: locked ≠ merely-unaffordable).
const LOCKED_TOOLTIP := "Locked"

## Hover tooltip template for greyed/unaffordable items (shop-purchase.md
## Core Rule 4, TR-BSUI-005, AC9): "Save $X more" with X = cost - balance.
const SAVE_MORE_FMT := "Save $%d more"

## Dim applied to the whole rack while a purchase drag is in flight (AC5
## one-drag invariant — the palette is visibly disabled). Achromatic, calm.
const DRAG_BLOCKED_MODULATE := Color(0.6, 0.6, 0.6)

## Injected read-only catalog (composition-root owned).
var _catalog: EquipmentCatalog
## Injected balance ledger — the re-grey trigger source.
var _economy: Economy
## Injected Shop query surface (Story 002's Shop, or the story-001
## placeholder). Typed via preload alias.
var _availability: PaletteAvailabilityScript
## Injected PlacementSystem — Story 002's drag initiation target. Null in
## story-001 render-only rigs; when injected, the palette gates mouse-downs
## on Shop.begin_purchase_drag and forwards to PlacementSystem.begin_drag.
var _placement: PlacementSystemScript
## equipment_id -> PaletteTile. Built once in init() from catalog order.
var _tiles: Dictionary = {}
## "Nothing available yet" label — visible only when the catalog is empty.
var _empty_hint: Label
var _initialized: bool = false
## One-drag invariant (Core Rule 3, AC5): true while a purchase drag started
## by THIS palette is in flight. Set after the gate passes + begin_drag;
## cleared by _sync_drag_state() when PlacementSystem leaves DRAGGING (the
## poll handles commit, reject, AND silent cancel — notify_silent_cancel is
## idempotent so calling it after a committed/rejected resolution is a no-op).
var _drag_in_flight: bool = false


## Two-phase init (mirrors the SimSystem guard pattern with push_error, not
## assert — testable and release-safe). Stores injected dependencies, builds
## the tile rack, subscribes to S6 balance_changed, and derives initial
## availability states. A second init() call is a hard error (logged, no-op).
##
## p_placement is OPTIONAL and backward-compatible with story-001 rigs: when
## omitted (or null), the palette renders only — no input gating, no drag
## initiation. Story 002's wiring injects the real PlacementSystem to enable
## the mouse-down → gate → drag pipeline.
func init(p_catalog: EquipmentCatalog, p_economy: Economy, p_availability: PaletteAvailabilityScript, p_placement: PlacementSystemScript = null) -> void:
	if _initialized:
		push_error("BuildShopPalette.init() called twice")
		return
	_initialized = true
	_catalog = p_catalog
	_economy = p_economy
	_availability = p_availability
	_placement = p_placement
	_build_ui()
	_economy.balance_changed.connect(_on_balance_changed)
	_refresh_all()


## Returns the tile Control for [equipment_id], or null if unknown.
func get_tile(equipment_id: String) -> PaletteTileScript:
	return _tiles.get(equipment_id)


## Returns the current PaletteTile.State for [equipment_id], or -1 if unknown.
## Story 002's drag gate reads this to decide whether a mouse-down may start
## a drag.
func get_state(equipment_id: String) -> int:
	var tile: PaletteTileScript = _tiles.get(equipment_id)
	if tile == null:
		return -1
	return tile.state


## The drag-gate query (AC1 rendering state): true ONLY when the item is
## currently AFFORDABLE. Greyed/locked items are inert.
func is_item_draggable(equipment_id: String) -> bool:
	var tile: PaletteTileScript = _tiles.get(equipment_id)
	if tile == null:
		return false
	return tile.is_draggable()


## Number of rendered tiles (0 for an empty catalog — the calm hint shows).
func get_tile_count() -> int:
	return _tiles.size()


## True when the empty-catalog hint is currently visible.
func is_empty_hint_visible() -> bool:
	return _empty_hint != null and _empty_hint.visible


## S6 handler (ADR-0005 §3: balance_changed(new_balance, delta), arity 2).
## Re-derives ALL tile states synchronously — AC2's "within one frame" is
## guaranteed because no await separates the signal from the re-render.
func _on_balance_changed(new_balance: int, delta: int) -> void:
	_refresh_all()


## Per-frame drag-resolution poll (one-drag invariant bookkeeping). When a
## purchase drag started by THIS palette is in flight and PlacementSystem
## leaves DRAGGING, the drag has resolved — commit (S3), reject (S4), or
## silent cancel (Esc/OOB/focus-loss, which emits NO signal). For commit/
## reject, Shop's own listener already cleared its flag, so
## notify_silent_cancel() is a harmless no-op; for silent cancel it is the
## ONLY resolution path — the palette must tell Shop (Core Rule 2 step 3).
## Then the palette re-enables (one-drag invariant released, AC7).
func _process(_delta: float) -> void:
	if not _initialized:
		return
	if _drag_in_flight and (_placement == null or not _placement.is_dragging()):
		if _placement != null:
			_availability.notify_silent_cancel()
		_drag_in_flight = false
		modulate = Color.WHITE


## Control-level input (story-002 engine note: "Control `_input` handles
## palette"). Left mouse-down anywhere is hit-tested against the tile rack;
## a tile hit forwards to on_tile_mouse_down() — the Story 002 drag gate.
## No-ops in story-001 render-only mode (_placement == null).
func _input(event: InputEvent) -> void:
	if not _initialized or _placement == null:
		return
	var mb := event as InputEventMouseButton
	if mb == null or mb.button_index != MOUSE_BUTTON_LEFT or not mb.pressed:
		return
	var equipment_id := _hit_test_tile(mb.position)
	if equipment_id != "":
		on_tile_mouse_down(equipment_id)


## The Story 002 drag gate (AC4/AC5): a mouse-down on a palette tile.
##
## AC4 — affordable, unlocked item: Shop.begin_purchase_drag() passes
## (can_purchase AND not is_dragging) → PlacementSystem.begin_drag() starts
## the placement drag for that equipment_id; the palette marks the one-drag
## invariant (AC5) and dims the rack.
## AC5 — blocked cases: a purchase drag already in flight (UI-level disable,
## returns false before even asking Shop), the item greyed/locked
## (begin_purchase_drag false → inert), or PlacementSystem already DRAGGING
## (Shop's structural backstop → false). Nothing starts, no flag set.
##
## Returns true iff a PlacementSystem drag actually began. Public so headless
## tests drive the gate deterministically (same pattern as
## PlacementSystem.on_drop()).
func on_tile_mouse_down(equipment_id: String) -> bool:
	if not _initialized or _placement == null:
		return false
	if _drag_in_flight:
		return false  # one-drag invariant: palette disabled during a drag (AC5)
	if not _availability.begin_purchase_drag(equipment_id):
		return false  # greyed/locked/inert, or Shop's is_dragging() backstop
	_placement.begin_drag(equipment_id)
	_drag_in_flight = true
	modulate = DRAG_BLOCKED_MODULATE
	return true


## True while a purchase drag started by this palette is in flight (the
## one-drag invariant is active). Test/UI query.
func is_drag_in_flight() -> bool:
	return _drag_in_flight


## Hit-tests a viewport-space position against every tile's global rect.
## Returns the equipment_id of the first tile containing [pos], or "" if the
## click missed the rack (or the palette has no placement wiring).
func _hit_test_tile(pos: Vector2) -> String:
	for id in _tiles.keys():
		var tile: PaletteTileScript = _tiles[id]
		if tile.get_global_rect().has_point(pos):
			return id
	return ""


## Builds the rack: one PaletteTile per catalog id (loader insertion order),
## plus the always-present empty hint (visible only when there are no tiles).
func _build_ui() -> void:
	for id in _catalog.get_all_ids():
		var def := _catalog.get_definition(id)
		var tile: PaletteTileScript = PaletteTileScript.new()
		tile.setup(def.id, def.display_name, def.cost)
		add_child(tile)
		_tiles[id] = tile

	_empty_hint = Label.new()
	_empty_hint.text = EMPTY_HINT_TEXT
	_empty_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_empty_hint.add_theme_font_size_override("font_size", 16)
	_empty_hint.visible = _tiles.is_empty()
	add_child(_empty_hint)


## Re-derives every tile's state through the injected query layer, then
## emits palette_refreshed. Idempotent — safe to call on any balance change
## (rising AND falling: items light up AND re-grey). Also refreshes each
## tile's hover tooltip (AC9 — "Save $X more" / lock tooltip), which the
## palette formats from the Shop's save-more derivation.
func _refresh_all() -> void:
	for id in _tiles.keys():
		var tile: PaletteTileScript = _tiles[id]
		tile.set_state(_derive_state(id))
		tile.tooltip_text = _derive_hover_tooltip(id)
	palette_refreshed.emit()


## The hover tooltip for [equipment_id] (TR-BSUI-005, AC9): "Save $X more"
## with X = cost - balance for greyed/unaffordable items, the lock tooltip
## for locked items, "" for affordable items (full-tint — nothing to save).
## Distinct lock text is mandatory (shop-purchase.md Core Rule 5: a locked
## item must never read as "just save up"). Public query for tests.
func get_hover_tooltip(equipment_id: String) -> String:
	if not _initialized:
		return ""
	var tile: PaletteTileScript = _tiles.get(equipment_id)
	if tile == null:
		return ""
	return _derive_hover_tooltip(equipment_id)


## Formats the tooltip from the Shop query layer's state + save-more
## derivation. A locked item shows the lock tooltip; an unaffordable item
## shows "Save $X more"; an affordable item (save-more <= 0, i.e. X == 0
## just-affordable edge) shows no tooltip.
func _derive_hover_tooltip(equipment_id: String) -> String:
	if not _availability.is_unlocked(equipment_id):
		return LOCKED_TOOLTIP
	var save_more: int = _availability.get_save_more_amount(equipment_id)
	if save_more > 0:
		return SAVE_MORE_FMT % save_more
	return ""


## Derives the colorblind-safe state for one item via the Shop query layer:
## locked (shape) dominates, then affordability, else greyed. Matches
## shop-purchase.md Core Rule 1/5 ordering (can_purchase already requires
## unlocked; the LOCKED branch is what gives locked items their distinct
## visual BEFORE affordability is consulted).
func _derive_state(equipment_id: String) -> int:
	if not _availability.is_unlocked(equipment_id):
		return PaletteTileScript.State.LOCKED
	if _availability.can_purchase(equipment_id):
		return PaletteTileScript.State.AFFORDABLE
	return PaletteTileScript.State.UNAFFORDABLE
