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
## STORY 004 (Drag Handoff + Purchase Confirm + Silent-Cancel Cue,
## TR-BSUI-003 handoff part / TR-BSUI-005 cancel-cue part):
##   - AC7: the per-frame drag-resolution poll re-enables the palette AND
##     re-greys every tile against the CURRENT balance whenever a
##     palette-initiated drag leaves DRAGGING (commit/reject/silent cancel).
##   - shop-purchase.md Core Rule 4: a purchase-initiated commit triggers a
##     purchase-confirm cue on placement_committed — NOT on balance_changed
##     (a cost-0 purchase never fires balance_changed but still deserves the
##     confirmation feel). The palette tracks _drag_equipment_id locally and
##     matches the commit's equipment_id — deliberately NOT Shop's flag,
##     because Shop's own placement_committed listener (connected first in
##     the composition root) clears the flag inside the same emit, before
##     this handler runs. Palette-local drag tracking is signal-order
##     independent and excludes relocate commits (which never pass through
##     the palette gate).
##   - AC10: a silent cancel of a STARTED drag (Esc / out-of-bounds /
##     focus-loss — no signal by design) is detected by the poll via Shop's
##     still-set _purchase_in_flight flag; the palette notifies Shop
##     (Core Rule 2 step 3) and shows a lightweight return-to-palette cue so
##     the drag's resolution is not invisible. (A gate-swallowed attempt —
##     is_dragging() already true — never sets the flag and never starts a
##     drag, so it correctly produces NO cue: the item never left idle.)
##     The cue is a short modulate flash (no Control offset transforms —
##     4.7's animated-offset API must not break the HBox container layout).
##   - Cue signals (purchase_confirm_cue / silent_cancel_cue) are the
##     audio-director hook for the optional audio half of the cues.
##
## Node lifecycle: the palette is a scene-tree Control (NOT a RefCounted sim
## system — ADR-0005 "The palette is a Control hierarchy"). Connections to
## Economy die with the node; the composition root owns it for the session.
class_name BuildShopPalette extends HBoxContainer

## Fired after every availability re-derive (init and each balance_changed).
## Story 002/003 hook this for gating re-evaluation. Arity: 0.
signal palette_refreshed

## STORY 004 — purchase-confirm cue (shop-purchase.md Core Rule 4): fired
## exactly once per purchase-initiated commit (placement_committed with a
## matching palette-initiated drag). Carries the purchased equipment_id.
## The audio-director hook for the optional soft confirm sound. Arity: 1.
signal purchase_confirm_cue(equipment_id: String)

## STORY 004 — silent-cancel return cue (GDD AC10, shop-purchase.md Core
## Rule 4): fired exactly once per detected silent cancel (Esc / OOB /
## focus-loss — a palette-initiated drag that ended with no commit/reject
## signal). Carries the equipment_id whose drag was cancelled. The
## audio-director hook for the optional return sound. Arity: 1.
signal silent_cancel_cue(equipment_id: String)

## preload aliases for the NEW sibling classes — the story's documented
## headless pattern: "headless 下 cross-script refs via preload aliases"
## (global class cache is editor-generated; preload works regardless).
const PaletteTileScript := preload("res://src/ui/palette_tile.gd")
const PaletteAvailabilityScript := preload("res://src/ui/palette_availability.gd")
const PlacementSystemScript := preload("res://src/systems/placement_system.gd")
const ModeArbitrationScript := preload("res://src/ui/mode_arbitration.gd")

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

## STORY 004 — cue lifetime (seconds). Lightweight and non-intrusive (UX
## spec: snap-in 120–250 ms; silent-cancel return cue is a soft flash). The
## cue is a brief modulate flash that decays to idle; tests advance the
## palette's _process by this duration to observe the decay.
const CUE_DURATION := 0.4

## STORY 004 — purchase-confirm flash (Core Rule 4): a warm cream/gold tint
## (art-bible §4 Butter family) for the moment a purchase-initiated drag
## successfully lands. Applied to the palette's modulate while the confirm
## cue is active; decays to WHITE. Never touches tile-level state — a greyed
## item stays greyed underneath (the flash is the whole-rack acknowledgement).
const CONFIRM_CUE_MODULATE := Color(1.0, 0.97, 0.82)

## STORY 004 — silent-cancel return flash (AC10): a soft warm-white as the
## item returns to its idle-state visual. Slightly cooler than the confirm
## flash so the two resolutions read differently at a glance.
const RETURN_CUE_MODULATE := Color(1.0, 0.99, 0.93)

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
## Injected mode arbitration (Story 003) — the build/select arbiter. Null
## in story-001/002 rigs (backward compatible); when injected, the palette
## clears an active selection BEFORE starting a drag (build takes over —
## GDD Core Rule 4, no dual ghost).
var _arbitration: ModeArbitrationScript
## equipment_id -> PaletteTile. Built once in init() from catalog order.
var _tiles: Dictionary = {}
## "Nothing available yet" label — visible only when the catalog is empty.
var _empty_hint: Label
var _initialized: bool = false
## One-drag invariant (Core Rule 3, AC5): true while a purchase drag started
## by THIS palette is in flight. Set after the gate passes + begin_drag;
## cleared by _poll_drag_resolution() when PlacementSystem leaves DRAGGING
## (the poll handles commit, reject, AND silent cancel — notify_silent_cancel
## is idempotent so calling it after a committed/rejected resolution is a
## no-op).
var _drag_in_flight: bool = false

## STORY 004 — the equipment_id of the palette-initiated drag currently in
## flight ("" when idle). Palette-local purchase tracking: the purchase-confirm
## handler (Core Rule 4) matches placement_committed's equipment_id against
## this to decide whether the commit was purchase-initiated — deliberately
## independent of Shop's _purchase_in_flight flag, whose listener clears it
## earlier in the same emit (connection order in the composition root).
## Cleared by _poll_drag_resolution() on any resolution.
var _drag_equipment_id: String = ""

## STORY 004 — purchase-confirm cue state (shop-purchase.md Core Rule 4):
## true while the confirm flash is showing. Set by _start_confirm_cue() from
## the placement_committed handler; cleared by _decay_cues() after
## CUE_DURATION seconds. Queried by tests via is_confirm_cue_active().
var _confirm_cue_active: bool = false

## STORY 004 — the equipment_id the active confirm cue acknowledges.
var _confirm_cue_equipment_id: String = ""

## STORY 004 — silent-cancel return cue state (AC10): true while the
## return flash is showing. Set by _start_return_cue() from
## _poll_drag_resolution() when a palette drag ends with no commit/reject
## signal; cleared by _decay_cues(). Queried via is_return_cue_active().
var _return_cue_active: bool = false

## STORY 004 — the equipment_id the active return cue acknowledges.
var _return_cue_equipment_id: String = ""

## STORY 004 — seconds remaining on the currently active cue (0.0 when
## idle). Decremented in _process; when it hits 0 the cue flags clear and
## the palette's modulate returns to the non-cue state.
var _cue_time_remaining: float = 0.0


## Two-phase init (mirrors the SimSystem guard pattern with push_error, not
## assert — testable and release-safe). Stores injected dependencies, builds
## the tile rack, subscribes to S6 balance_changed, and derives initial
## availability states. A second init() call is a hard error (logged, no-op).
##
## p_placement is OPTIONAL and backward-compatible with story-001 rigs: when
## omitted (or null), the palette renders only — no input gating, no drag
## initiation. Story 002's wiring injects the real PlacementSystem to enable
## the mouse-down → gate → drag pipeline.
##
## p_arbitration is OPTIONAL and backward-compatible with story-001/002
## rigs: when omitted (or null), palette mouse-downs do NOT clear an active
## selection. Story 003's wiring injects ModeArbitration to enable the
## build-takes-over handoff (GDD Core Rule 4).
func init(p_catalog: EquipmentCatalog, p_economy: Economy, p_availability: PaletteAvailabilityScript, p_placement: PlacementSystemScript = null, p_arbitration: ModeArbitrationScript = null) -> void:
	if _initialized:
		push_error("BuildShopPalette.init() called twice")
		return
	_initialized = true
	_catalog = p_catalog
	_economy = p_economy
	_availability = p_availability
	_placement = p_placement
	_arbitration = p_arbitration
	_build_ui()
	_economy.balance_changed.connect(_on_balance_changed)
	# STORY 004 — S3 placement_committed subscription (typed, Control
	# Manifest). Only when placement is injected (render-only rigs have no
	# drags to confirm). The purchase-confirm cue fires HERE, on committed —
	# NOT on balance_changed — so a cost-0 purchase (which never fires
	# balance_changed) still gets its confirmation feel (Core Rule 4).
	if _placement != null:
		_placement.placement_committed.connect(_on_placement_committed)
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


## Per-frame palette lifecycle (STORY 004 rework): drag-resolution poll,
## cue decay, and the single modulate authority.
##
## The poll (AC7 + AC10): when a purchase drag started by THIS palette is in
## flight and PlacementSystem leaves DRAGGING, the drag has resolved —
## commit (S3), reject (S4), or silent cancel (Esc/OOB/focus-loss, which
## emits NO signal). For commit/reject, Shop's own listener already cleared
## its flag, so notify_silent_cancel() is a harmless no-op; for silent cancel
## it is the ONLY resolution path — the palette must tell Shop (Core Rule 2
## step 3) AND show the return cue (AC10 — the resolution is not invisible).
## Then the palette re-enables (one-drag invariant released) and re-greys
## every tile against the CURRENT balance (AC7 — idempotent: a commit
## already re-greyed via balance_changed, reject/cancel need the refresh).
func _process(delta: float) -> void:
	if not _initialized:
		return
	_poll_drag_resolution()
	_decay_cues(delta)
	_apply_cue_visual()


## STORY 004 — the drag-resolution poll (AC7/AC10, see _process doc).
## Runs the silent-cancel discriminator BEFORE clearing _drag_in_flight:
## Shop's flag still set ⟺ no commit/reject signal arrived ⟺ silent cancel.
func _poll_drag_resolution() -> void:
	if not _drag_in_flight or _placement == null or _placement.is_dragging():
		return
	if _availability.is_purchase_in_flight():
		# AC10: silent cancel — notify Shop (Core Rule 2 step 3, zero spend)
		# and show the return cue so the resolution is visible.
		_availability.notify_silent_cancel()
		_start_return_cue(_drag_equipment_id)
	_drag_in_flight = false
	_drag_equipment_id = ""
	# AC7: re-grey against the CURRENT balance. Idempotent — after a commit
	# balance_changed already refreshed the tiles; reject/cancel need this.
	_refresh_all()


## STORY 004 — S3 placement_committed handler (shop-purchase.md Core Rule 4).
## Fires the purchase-confirm cue when the commit belongs to a drag THIS
## palette initiated AND the equipment_id matches. Deliberately palette-local:
## Shop's own listener (connected first in the composition root) clears its
## flag inside this same emit, so consulting Shop's flag here would miss
## every purchase — and a cost-0 purchase never fires balance_changed, so
## the cue MUST live on committed, not on the balance signal. Relocate
## commits (no palette gate) never match (_drag_in_flight false) — ignored.
func _on_placement_committed(_instance_id: int, equipment_id: String, _footprint_cells: Array[Vector2i]) -> void:
	if not _initialized or _placement == null:
		return
	if not _drag_in_flight or equipment_id != _drag_equipment_id:
		return
	_start_confirm_cue(equipment_id)


## STORY 004 — starts the purchase-confirm cue (Core Rule 4): sets the
## active flag + equipment, arms the decay timer, emits the signal (the
## audio-director hook), and applies the flash visual immediately so the
## acknowledgement is not deferred a frame.
func _start_confirm_cue(equipment_id: String) -> void:
	_confirm_cue_active = true
	_confirm_cue_equipment_id = equipment_id
	_cue_time_remaining = CUE_DURATION
	purchase_confirm_cue.emit(equipment_id)
	_apply_cue_visual()


## STORY 004 — starts the silent-cancel return cue (AC10): the item returns
## to its idle-state visual with a lightweight flash. Same mechanics as the
## confirm cue; distinct signal + modulate so the two resolutions read
## differently.
func _start_return_cue(equipment_id: String) -> void:
	_return_cue_active = true
	_return_cue_equipment_id = equipment_id
	_cue_time_remaining = CUE_DURATION
	silent_cancel_cue.emit(equipment_id)
	_apply_cue_visual()


## STORY 004 — cue decay: counts the active cue down; at 0 the flags clear
## (and _apply_cue_visual drops back to the non-cue modulate).
func _decay_cues(delta: float) -> void:
	if _cue_time_remaining <= 0.0:
		return
	_cue_time_remaining = maxf(0.0, _cue_time_remaining - delta)
	if _cue_time_remaining <= 0.0:
		_confirm_cue_active = false
		_confirm_cue_equipment_id = ""
		_return_cue_active = false
		_return_cue_equipment_id = ""


## STORY 004 — the single modulate authority: confirm flash > return flash >
## drag dim > idle white. Re-applied every frame so no other code path can
## leave a stale modulate behind (and the flash is naturally self-limiting).
func _apply_cue_visual() -> void:
	if _confirm_cue_active:
		modulate = CONFIRM_CUE_MODULATE
	elif _return_cue_active:
		modulate = RETURN_CUE_MODULATE
	elif _drag_in_flight:
		modulate = DRAG_BLOCKED_MODULATE
	else:
		modulate = Color.WHITE


## STORY 004 — true while the purchase-confirm cue is showing (Core Rule 4).
## Test/UI query.
func is_confirm_cue_active() -> bool:
	return _confirm_cue_active


## STORY 004 — the equipment_id the active confirm cue acknowledges ("" when
## idle). Test/UI query.
func get_confirm_cue_equipment_id() -> String:
	return _confirm_cue_equipment_id


## STORY 004 — true while the silent-cancel return cue is showing (AC10).
## Test/UI query.
func is_return_cue_active() -> bool:
	return _return_cue_active


## STORY 004 — the equipment_id the active return cue acknowledges ("" when
## idle). Test/UI query.
func get_return_cue_equipment_id() -> String:
	return _return_cue_equipment_id


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


## The Story 002 drag gate (AC4/AC5) + Story 003 build-take-over (Core
## Rule 4): a mouse-down on a palette tile.
##
## AC4 — affordable, unlocked item: Shop.begin_purchase_drag() passes
## (can_purchase AND not is_dragging) → PlacementSystem.begin_drag() starts
## the placement drag for that equipment_id; the palette marks the one-drag
## invariant (AC5) and dims the rack.
## AC5 — blocked cases: a purchase drag already in flight (UI-level disable,
## returns false before even asking Shop), the item greyed/locked
## (begin_purchase_drag false → inert), or PlacementSystem already DRAGGING
## (Shop's structural backstop → false). Nothing starts, no flag set.
## Core Rule 4 — build takes over: after the purchase gate passes and
## BEFORE begin_drag, the arbitration clears an active selection (no dual
## ghost). Ordering is deliberate: a FAILED gate (greyed/locked/inert)
## leaves the selection UNCHANGED (QA edge) — build only takes over once
## the drag is actually allowed to proceed.
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
	if _arbitration != null:
		_arbitration.begin_build()  # build takes over: clear selection first (no dual ghost)
	_placement.begin_drag(equipment_id)
	_drag_in_flight = true
	_drag_equipment_id = equipment_id  # STORY 004: palette-local purchase tracking
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
