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

## Calm empty-catalog hint (GDD Edge Cases: "nothing available yet", no error,
## no crash).
const EMPTY_HINT_TEXT := "Nothing available yet"

## Injected read-only catalog (composition-root owned).
var _catalog: EquipmentCatalog
## Injected balance ledger — the re-grey trigger source.
var _economy: Economy
## Injected Shop query surface (Story 002's Shop, or the story-001
## placeholder). Typed via preload alias.
var _availability: PaletteAvailabilityScript
## equipment_id -> PaletteTile. Built once in init() from catalog order.
var _tiles: Dictionary = {}
## "Nothing available yet" label — visible only when the catalog is empty.
var _empty_hint: Label
var _initialized: bool = false


## Two-phase init (mirrors the SimSystem guard pattern with push_error, not
## assert — testable and release-safe). Stores injected dependencies, builds
## the tile rack, subscribes to S6 balance_changed, and derives initial
## availability states. A second init() call is a hard error (logged, no-op).
func init(p_catalog: EquipmentCatalog, p_economy: Economy, p_availability: PaletteAvailabilityScript) -> void:
	if _initialized:
		push_error("BuildShopPalette.init() called twice")
		return
	_initialized = true
	_catalog = p_catalog
	_economy = p_economy
	_availability = p_availability
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
## (rising AND falling: items light up AND re-grey).
func _refresh_all() -> void:
	for id in _tiles.keys():
		var tile: PaletteTileScript = _tiles[id]
		tile.set_state(_derive_state(id))
	palette_refreshed.emit()


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
