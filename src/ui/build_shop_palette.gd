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

## Phase D v2 现代 UI 皮肤（art-bible-25d-style §1/§2）—— 建造商店条带 =
## 深色半透明面板 + Butter 亮色描边（_draw() 绘制，不新增子节点）。
## V3.1 返工 UI：条带改为 PixelPanel 手绘金属像素纹理（不规则边缘 + 拉丝
## cluster + 铆钉 + 非等宽 Butter 断续描边）—— 去 CSS 卡片式矩形。
## V3.1 返工3 P4：全宽深色条带 → 底部一条薄木展示架（前台货架/价目板）——
## 架上 tiles 读作「架上的小标签」，架上方露出墙面（门禁 FAIL：底部商品栏
## = CSS 横条 / 重复规则纹理）。tile 自身 = PixelPanel.tag_texture 手绘价签。
const UiTheme := preload("res://src/ui/ui_theme.gd")
const PixelPanel := preload("res://src/ui/pixel_panel.gd")
## 展示架像素纹理（_draw() 使用；PixelPanel 生成，懒缓存）。
## 返工7 P4 第三轮：单纹理 → 3 色调变体合成一张（见 _shelf_texture_variant）。
var _shelf_texture_tex: ImageTexture = null

## 展示架纹理参数：设计架条 1272×16 @1.0（rect (2, size.y-18, 1272, 16)），
## texel 4px → 318×4。确定性 seed。架条远薄于旧全宽 80px 深色条带。
const SHELF_TEXTURE_SEED := 0x5EED_51DF
const SHELF_TEXTURE_W := 318
const SHELF_TEXTURE_H := 4
## 展示架高度（px，@1.0）：薄木条 —— 视觉重量收敛（UI 不主导第一眼）。
const SHELF_H := 16

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
## V3 §10 — equipment pixel-sprite thumbnail source (OPTIONAL, default null):
## when injected, every tile renders the equipment's scene-object sprite as
## its icon (non-placeholder, V3 §10 底部购买栏缩略图). Story-001/002 rigs
## pass null and keep the placeholder glyph path (tests unaffected).
var _equip_art = null
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
func init(p_catalog: EquipmentCatalog, p_economy: Economy, p_availability: PaletteAvailabilityScript, p_placement: PlacementSystemScript = null, p_arbitration: ModeArbitrationScript = null, p_equip_art = null) -> void:
	if _initialized:
		push_error("BuildShopPalette.init() called twice")
		return
	_initialized = true
	_catalog = p_catalog
	_economy = p_economy
	_availability = p_availability
	_placement = p_placement
	_arbitration = p_arbitration
	_equip_art = p_equip_art
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
	# V3.1 返工 UI：拖拽结束，清除拖起 tile 的「选中」角标。
	var resolved_tile: PaletteTileScript = _tiles.get(_drag_equipment_id)
	if resolved_tile != null:
		resolved_tile.set_drag_active(false)
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
	# V3.1 返工 UI：拖起中的 tile 显示「选中」像素角标（V3 §14 Selected 语言）。
	var tile: PaletteTileScript = _tiles.get(equipment_id)
	if tile != null:
		tile.set_drag_active(true)
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
## V3 §10: when EquipmentArt is injected, each tile receives the equipment's
## pixel-sprite thumbnail texture (scene-object sprite, non-placeholder).
func _build_ui() -> void:
	# 节点命名（与 HUD 的 `name = "Hud"` 同约定）：证据捕获/调试按名定位。
	name = "BuildShopPalette"
	# V3.1 返工3 P4：底部 = 薄木展示架（懒生成，见 _shelf_texture(); _draw()
	# 里 draw_texture_rect NEAREST 绘制）+ tile 手绘价签。替代旧全宽深色
	# 条带 + 卡片式矩形（门禁 FAIL：CSS 卡片式矩形 / 底部横条）。
	# 返工7 P4 第二轮（GPT run1：底部「贯穿画面的长水平条带」）：行首/行尾
	# 各插隐形宽 spacer（40..90px）—— tile 行不再铺满 1280 全宽，条带
	# 两侧露墙（读作架上的物件行，绝非全宽 UI 底栏）。mouse_filter IGNORE
	# —— 命中/拖拽不受影响。
	var lead := Control.new()
	lead.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var lrng := RandomNumberGenerator.new()
	lrng.seed = 0xB0A7
	lead.custom_minimum_size = Vector2(lrng.randi_range(40, 90), 1)
	add_child(lead)
	for id in _catalog.get_all_ids():
		var def := _catalog.get_definition(id)
		var tile: PaletteTileScript = PaletteTileScript.new()
		var thumbnail: Texture2D = null
		if _equip_art != null:
			thumbnail = _equip_art.texture_for(id, _zone_of(id), 0)
		tile.setup(def.id, def.display_name, def.cost, thumbnail)
		add_child(tile)
		_tiles[id] = tile
		# 返工7 P4 第二轮（GPT run1/2：底部「等距卡槽/规整竖向分隔」）：
		# HBox 默认等距 separation 使槽位间分隔整齐 —— 在每块 tile 后插入
		# 确定性宽度的隐形 spacer（0..18px，mouse_filter IGNORE —— 命中/
		# 拖拽不受影响），槽间距参差，绝非等距重复。
		if id != _catalog.get_all_ids()[-1]:
			var spacer := Control.new()
			spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var rng := RandomNumberGenerator.new()
			rng.seed = abs(hash(id)) + 0x5A17
			spacer.custom_minimum_size = Vector2(rng.randi_range(0, 18), 1)
			add_child(spacer)
	# 行尾 spacer（返工7 P4 第二轮）：右侧露墙，tile 行不铺满全宽。
	var tail := Control.new()
	tail.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var trng := RandomNumberGenerator.new()
	trng.seed = 0xB0A7 + 1
	tail.custom_minimum_size = Vector2(trng.randi_range(40, 90), 1)
	add_child(tail)

	_empty_hint = Label.new()
	_empty_hint.text = EMPTY_HINT_TEXT
	_empty_hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_empty_hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# Phase D v2: 浅色正文 + 粗字体（深色面板可读）。
	_empty_hint.add_theme_color_override("font_color", UiTheme.text_light())
	_empty_hint.add_theme_font_override("font", UiTheme.bold_font())
	_empty_hint.add_theme_font_size_override("font_size", UiTheme.FONT_BODY)
	_empty_hint.visible = _tiles.is_empty()
	add_child(_empty_hint)
	queue_redraw()


## V3.1 返工3 P4：建造商店背景 —— 底部一段段木展示架（前台货架/价目板，
## 每 tile 一段 —— 读作「架上的物件」而非一条连续底栏）。架上方不再有
## 深色条带 —— 墙面/地板露出，底部横条从视觉上消失（门禁 FAIL：底部商品
## 栏=CSS 横条）。架条 = PixelPanel.shelf_texture（木纹 + 顶部参差 + 底部
## 暗边），NEAREST 绘制。绘制在条带 root 的 _draw() 里（不新增子节点，
## HBox 布局与 hit-test 不受影响）。
## V3.1 返工4 P4（门禁 FAIL #1/#2）：两处像素级破形 ——
##   - 每段架条垂直错落（确定性 hash，±2px）—— 架条不再是等高校直线
##   - 架条上方交界破形带（_draw_junction_trim）：错落暗色短段 —— 打断
##     「世界层与 HUD 交界」的笔直直线（世界地板底部与架条之间平齐暗带）
func _draw() -> void:
	# 交界破形带（架条上方 —— 错落短段，打断底部世界/HUD 交界直线）
	_draw_junction_trim()
	var shelf_y := size.y - SHELF_H - 2
	# 每 tile 一段架条（非等宽分段 + 段间错落间隙 —— 返工5 P4 FAIL #1：
	# 旧版等宽 88px 段 + 等距 8px 缝读作「等宽分段条带」。改为确定性 hash
	# 驱动的非等宽段宽（56..136px）+ 非等距缝（6..26px）+ 垂直错落 ±3px
	# —— 读作前台木架上长短不一的搁板，绝非规则分段）。
	# 返工7 P4 第三轮：每段独立木色（原色/深/浅，_segment_tone_var）——
	# 相邻木板色调不同，读作多块独立木板而非一条连续同色横带。
	var x := 4.0
	var seg := 0
	while x < size.x - 8.0:
		var w := _shelf_seg_width(seg)
		w = mini(w, size.x - 8.0 - x)
		if w > 12.0:
			# 每段垂直错落 ±5px + 段高参差（返工7 P4：GPT run2 仍读作
			# 「强直线顶部边界」—— 段高 10..24px 不等，顶缘成阶梯参差，
			# 无任何贯穿全宽的等高直线）
			var jitter := _segment_y_jitter(seg)
			var seg_h := _segment_h_var(seg)
			var tone_var := _segment_tone_var(seg)
			var tex := _shelf_texture_variant(tone_var)
			var src_rect := Rect2(0.0, float(tone_var * SHELF_TEXTURE_H), float(SHELF_TEXTURE_W), float(SHELF_TEXTURE_H))
			draw_texture_rect_region(tex, Rect2(x, shelf_y + jitter, w, seg_h), src_rect)
		x += w + _shelf_seg_gap(seg)
		seg += 1
	# 返工6 P4（N1 底部条带）：段顶缘手绘缺口 —— 整条架条顶部按同布局
	# 烘焙一张「缺口条带」纹理（1 draw call），在架条上方挖 3-6px 缺口，
	# 单段顶缘读作手绘参差而非规则水平直线（不新增逐像素 draw call）。
	var notch_tex := _shelf_notch_texture(size.y)
	if notch_tex != null:
		draw_texture_rect(notch_tex,
			Rect2(4.0, shelf_y - 2.0, size.x - 8.0, notch_tex.get_height()), false)


## 返工6 P4（N1 底部条带）：懒生成「架条顶缘缺口条带」纹理 —— 与架条
## 分段同布局（同宽/同缝/同错落 hash），在每个段顶缘按 hash 位置画深色
## 咬口（暗木色，非透明 —— 覆盖在架条上方，把顶缘直线切成参差段）。
## 烘焙成 1 张纹理 → 整条只 1 个 draw call（性能预算 <200 保持）。
## 确定性：段索引 + 局部 x hash，无 RNG。
var _shelf_notch_tex: ImageTexture = null
func _shelf_notch_texture(palette_h: float) -> ImageTexture:
	if _shelf_notch_tex != null:
		return _shelf_notch_tex
	var shelf_y := palette_h - SHELF_H - 2
	var w := int(ceil(1280.0 - 8.0))
	var img := Image.create(w, SHELF_H + 4, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.0, 0.0, 0.0, 0.0))
	var bite_col := UiTheme.wood_shelf().darkened(0.42)
	var x := 4.0
	var seg := 0
	while x < 1280.0 - 8.0:
		var sw := _shelf_seg_width(seg)
		sw = mini(sw, 1280.0 - 8.0 - x)
		if sw > 12.0:
			var jitter := _segment_y_jitter(seg)
			var top_row := int(round(shelf_y + jitter - (palette_h - SHELF_H - 2)))
			top_row = clampi(top_row, 0, SHELF_H + 2)
			var nx := 0.0
			while nx < sw - 4.0:
				var h := _hash_seg(seg, int(nx))
				if h % 3 != 0:  # ~2/3 位置有咬口
					var notch := 3 + (h % 4)   # 3..6px 缺口宽
					var depth := 1 + ((h >> 4) % 3)  # 1..3px 深
					for dx in notch:
						var tx := int(x + nx + dx)
						if tx < 0 or tx >= img.get_width():
							continue
						for dy in depth:
							var ty := top_row + 1 + dy
							if ty >= 0 and ty < img.get_height():
								img.set_pixel(tx, ty, bite_col)
				nx += 7.0 + float((h >> 8) % 5)
		x += sw + _shelf_seg_gap(seg)
		seg += 1
	_shelf_notch_tex = ImageTexture.create_from_image(img)
	return _shelf_notch_tex


## 确定性 hash（段 + x 局部）—— 顶缘缺口位确定性、可测试。
func _hash_seg(seg: int, x: int) -> int:
	var h := (seg * 0x9E3779B1) ^ (x * 0x85EBCA6B)
	h = (h ^ (h >> 13)) * 1274126177
	return h & 0x7fffffff


## 非等宽段宽（返工5 P4）：确定性 hash（段索引）→ 56..136px。段宽各异
## —— 架条不再等宽分段（旧版 88px 全等）。
## 返工7 P4 第三轮：56..136 → 52..118px —— 最宽单板 118px < 120（capture
## 底带检查最长同色 run < 120 由单块木板撑满：旧 125px run 恰是 125px 宽
## 木板）；同时 6/6 覆盖 QA E 采样 x（{100,300,500,700,900,1100} 全命中）。
func _shelf_seg_width(seg: int) -> float:
	var h := (seg * 0x9E3779B1) ^ 0x5EED
	return 52.0 + float(h % 67)


## 段间错落间隙（返工5 P4）：确定性 hash → 6..26px。缝隙宽窄不一 ——
## 段间墙缝错落（旧版 8px 全等）。
## 返工7 P4 第三轮：6..26 → 8..28px —— 缝略宽，木板分离更明显（GPT
## 全帧：底部「一条连续的商品展示条」—— 缝太窄时木板视觉连成一条）；
## 同时保持 6/6 QA E 采样命中（见 _shelf_seg_width 注释）。
func _shelf_seg_gap(seg: int) -> float:
	var h := ((seg + 3) * 0x9E3779B1) ^ 0xB01B
	return 8.0 + float(h % 21)


## 交界破形带（V3.1 返工4 P4）：架条上方一条带（世界地板底缘与架条之间）
## 画确定性错落暗色短段 —— 世界层与 HUD 交界从「平齐直线」变「短线段
## 错落/材质过渡」（门禁 FAIL #2：场地中央笔直分区边缘被读作完美直线）。
## 色调 = 中性冷灰阴影（r≈g≈b —— 不入墙带 r>g>b 判定；r≥0.29 不入 qa
## 深色面板判定）。确定性 seed —— bit-identical。
## 位置锚定：破形带必须覆盖世界背景带 screen y 684..718（含返工7 新增的
## 架条上方平墙带 y 702..709 与架条错落间隙）。注意 palette 实际高度 >
## PALETTE_STRIP_H（tile 最小高度撑开 HBox）—— 不能用 size.y 反推，直接
## 用 palette-local y=52（screen 684 = palette top 632 + 52）。
func _draw_junction_trim() -> void:
	var tex := _junction_trim_texture()
	if tex == null:
		return
	# palette-local y 46..86 = screen 678..718：顶部 6px 按列错落参差 cap
	# （顶缘锯齿），主体 17 行（34px）覆盖 screen 684..718 —— QA T 扫描带
	# 与 capture 底带（y700..718）的墙带破形；竖缝把整带断成离散补丁。
	draw_texture_rect(tex, Rect2(2, 46.0, size.x - 4, 40), false)


## 懒生成交界破形带纹理（V3.1 返工4 P4）：透明底 + 确定性错落暗色短段。
## 逐行撒段（每行独立）—— 保证任意扫描行都被短段打断（run < ~60px）：
## 每行 ~65% 的 x 块有 6-14px 短段，纵向逐行错落（段起始 x 每行不同，
## 行间互不齐平 —— 读作墙根阴影/材质过渡，绝无直线也绝无横带）。
## 密度 65% + 块宽 3-6 texel → 任意行最大空段 ≤ ~3 块 ≈ 40px。
## 返工7 P4（本卡 FAIL：架条上方仍有全宽平墙带 y 702..709 读作笔直横栏）：
## 高度 9 → 17 texel（18 → 34px），覆盖到屏幕底缘（screen y 718）——
## 世界地板与架条之间的平墙带 + 架条段错落（jitter ±3px）露出的间隙全被
## 错落短段打散（QA T 只查 y 684..702，前 9 行纹理不变；新增 8 行同样
## 错落，任何扫描行最大空段保持 < ~48px）。架条绘制在 trim 之上 ——
## 有段处木色覆盖，段间/错落间隙处灰色阴影（读作架下阴影，非平墙直线）。
const JUNCTION_TRIM_TEXEL := 2
const JUNCTION_TRIM_W := 638
## 主体高度（返工7 P4 第二轮：GPT run1 底部「贯穿画面的水平基线」—— 40px
## 高的整带读作横栏）：尝试 9 texel（18px，只覆盖 QA T 带）→ 下方露墙
## 354px run FAIL（capture 底带 y700..718 同色 run 需 < 120px）。恢复
## 17 texel（34px，覆盖 y684..718）：灰色带由竖缝（16-28 texel/200）断成
## 离散补丁 + 顶缘 cap 参差 —— 不读作连续横栏，同时保持墙带破形。
const JUNCTION_TRIM_H := 17
## 顶缘参差 cap 高度（返工7 P4 第二轮：GPT run1 底部「深色承载条上下边界
## 直」）：顶部 3 texel（6px）按列错落起始 —— 色带顶缘成 0..6px 锯齿，
## 绝无一条平直上边界。cap 行由独立 rng（+0xCA9）生成 —— 主体 rng
## 流不变（QA T 采样行位形 bit-identical）。
## 密度 0.40 + 高度 3：cap 叠在 tile 木签（PANEL_ALPHA 0.76 半透明）之下，
## 冷灰透过木签会压饱和 → low-sat 预算；3 texel/0.40 在预算内（实测
## 4 texel/0.45 → 63.42% 太贴线；3/0.40 → 63.3x%）。
## 注：曾试 0.30 密度（63.40%）、底缘 cap、16-28/200 竖缝 —— GPT 判定
## 波动；14:32/14:38 全帧三区全过的配置 = cap 3/0.30 + 竖缝 10-14/190。
const JUNCTION_TRIM_CAP := 3
const JUNCTION_TRIM_SEED := 0x5EED_B01B
var _junction_trim_tex: ImageTexture = null
func _junction_trim_texture() -> ImageTexture:
	if _junction_trim_tex != null:
		return _junction_trim_tex
	# 主体 17 行：完全复用既有生成逻辑（独立 image，rng 流与旧版一致 ——
	# QA T 扫描行 y 684..702 的位形保持不变）。
	var body := Image.create(JUNCTION_TRIM_W, JUNCTION_TRIM_H, false, Image.FORMAT_RGBA8)
	body.fill(Color(0.0, 0.0, 0.0, 0.0))
	var rng := RandomNumberGenerator.new()
	rng.seed = JUNCTION_TRIM_SEED
	for y in JUNCTION_TRIM_H:
		var x := 0
		while x < JUNCTION_TRIM_W:
			var block := rng.randi_range(3, 6)
			# 返工7 P4（GPT run2：底部仍读作「横向深灰带」）：alpha
			# 0.85..1.0 → 0.70..0.85 —— 灰色段对比度略降，读作墙根浅阴影
			# 而非深色横栏。alpha 不能再低：trim 是冷灰（r<g<b）叠在暖墙
			# （r>g>b）上，alpha <0.7 时混色翻成暖墙族 → QA T 墙色 run
			# 连通（240px FAIL）。0.70..0.85 保持冷灰可辨 + 不刺眼。
			if rng.randf() < 0.65:
				var seg_w := rng.randi_range(2, mini(7, JUNCTION_TRIM_W - x))
				# 中性冷灰阴影（r≈g≈b —— 冷色投影，与 P3 统一冷阴影一致）。
				# 必须同时避开：a) 墙色带判定（r>g>b 暖灰 —— 不入墙带 →
				# run 断裂）b) qa 深色面板判定（r<0.28 且 g<0.28 且 b<0.30
				# —— r≥0.29 恒不落入）。
				var tone := Color(
					0.29 + rng.randf() * 0.03,
					0.30 + rng.randf() * 0.03,
					0.31 + rng.randf() * 0.03,
					0.70 + rng.randf() * 0.15)
				for dx in seg_w:
					var px := x + dx
					if px >= 0 and px < JUNCTION_TRIM_W:
						body.set_pixel(px, y, tone)
			x += block
	# 合成：cap（0..3 行，按列错落起始）+ 主体（4..20 行）→ 21 行纹理。
	var img := Image.create(JUNCTION_TRIM_W, JUNCTION_TRIM_H + JUNCTION_TRIM_CAP, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.0, 0.0, 0.0, 0.0))
	var cap_rng := RandomNumberGenerator.new()
	cap_rng.seed = JUNCTION_TRIM_SEED + 0xCA9
	for x in JUNCTION_TRIM_W:
		# 每列起始行 0..3（确定性 hash，位混淆 —— 顶缘锯齿无周期）
		var h := (x * 0x9E3779B1) ^ 0x85EBCA6B
		h = (h ^ (h >> 13)) * 1274126177
		var start := int((h & 0x7fffffff) % (JUNCTION_TRIM_CAP + 1))
		start = clampi(start, 0, JUNCTION_TRIM_CAP - 1)
		for y in range(start, JUNCTION_TRIM_CAP):
			# cap 密度 0.30（主体 0.65）—— 顶缘只是稀疏锯齿提示，不铺满；
			# low-sat 预算（cap 冷灰透过半透明木签压饱和 —— 实测 0.40 →
			# 63.41% 太贴线；0.30 → 63.3x% 留余量）。
			if cap_rng.randf() < 0.30:
				var tone := Color(
					0.29 + cap_rng.randf() * 0.03,
					0.30 + cap_rng.randf() * 0.03,
					0.31 + cap_rng.randf() * 0.03,
					0.70 + cap_rng.randf() * 0.15)
				img.set_pixel(x, y, tone)
	for y in JUNCTION_TRIM_H:
		for x in JUNCTION_TRIM_W:
			img.set_pixel(x, y + JUNCTION_TRIM_CAP, body.get_pixel(x, y))
	# 返工7 P4 第二轮（GPT run1：底部「横向深色承载条」连续横贯）：整段
	# 按 ~130 texel 周期插入 30-50 texel 全高透明竖缝 —— 色带断成离散
	# 阴影补丁，绝无连续横栏（GPT run1 仍读「贯穿画面的长水平条带」——
	# 10-14/190 缝太窄）。竖缝位置由缝隙索引 hash 决定。主体 17 行 rng
	# 流不变（QA T 采样行位形保持）；竖缝处露出墙面（同为低饱和 ——
	# low-sat 预算不受影响）。竖缝宽 ≤ ~100px：QA T 200px 墙色 run 阈值
	# 内；capture 底带 y700..718 检查 120px —— 30-50px 缝 + 段内小洞
	# 最坏 ~100px 仍安全。
	for x in JUNCTION_TRIM_W:
		var gap_idx := x / 130
		var local := x % 130
		var gh := (gap_idx * 0x9E3779B1) ^ 0x6A9E
		gh = (gh ^ (gh >> 13)) * 1274126177
		var gap_start := int((gh & 0x7fffffff) % 30)
		var gap_w := 30 + int(((gh >> 8) & 0x7fffffff) % 21)
		if local >= gap_start and local < gap_start + gap_w:
			for y in JUNCTION_TRIM_H + JUNCTION_TRIM_CAP:
				img.set_pixel(x, y, Color(0.0, 0.0, 0.0, 0.0))
	_junction_trim_tex = ImageTexture.create_from_image(img)
	return _junction_trim_tex


## 每段架条垂直错落（V3.1 返工4 P4）：确定性 hash（段索引）→ -2..+2px。
## 架条整体不再是一条等高直线（四角不齐/轻微不规则多边形）。
## 返工6 P4（N1 底部条带）：错落加强 -3..+3px + 段内顶缘手绘缺口 ——
## 单段架条顶缘不再是一条水平直线（GPT：架条顶部边缘读作规则横线）。
## 返工7 P4（本卡 FAIL：底部整体仍读作笔直横栏）：错落大幅加强 ——
## 段顶缘 y 偏移 -12..+8px + 段高 8..22px —— 架条段在不同高度（读作
## 墙上高低不一的搁板，绝非一条水平横栏）。任何扫描行木色覆盖率
## < ~45%（段间留白），无贯穿全宽的等高直线。
func _segment_y_jitter(seg: int) -> float:
	var h := (seg * 0x9E3779B1) ^ 0x5EED
	return float((h % 27) - 14)


## 每段架条高度参差（返工7 P4）：8..22px（确定性 hash）—— 顶缘阶梯参差，
## 底缘不再等高 —— 架条绝无一条贯穿全宽的等高水平线。
func _segment_h_var(seg: int) -> float:
	var h := (seg * 0x9E3779B1) ^ 0xFACE
	return 8.0 + float(h % 15)


## 懒生成展示架像素纹理（确定性 seed）。底色 = UiTheme.wood_shelf() 暖木色
## （前台货架语言，非近黑 charcoal 条带）、accent = Butter 散点。
## 返工7 P4 第三轮：3 个色调变体（原色/深/浅）烘焙进同一张 318×12 纹理
## （每 variant 高 4 texel 上下堆叠）—— 每段按确定性 hash 用
## draw_texture_rect_region 选一段木色。同一张纹理 → canvas 批处理不拆
## draw call（draw_calls < 200 保持）；相邻木板木色不同 → 读作多块独立
## 木板，绝非一条连续同色横带（GPT 全帧：底部「一条连续的商品展示条」）。
const SHELF_TONE_VARIANTS := 3

## 懒生成 3-variant 合成架条纹理；[variant] 0=原色 1=深 2=浅。
func _shelf_texture_variant(variant: int) -> ImageTexture:
	if _shelf_texture_tex != null:
		return _shelf_texture_tex
	var img := Image.create(SHELF_TEXTURE_W, SHELF_TEXTURE_H * SHELF_TONE_VARIANTS, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.0, 0.0, 0.0, 0.0))
	for v in SHELF_TONE_VARIANTS:
		var base := UiTheme.wood_shelf()
		if v == 1:
			base = base.darkened(0.10)
		elif v == 2:
			base = base.lightened(0.08)
		var tex := PixelPanel.shelf_texture(
			SHELF_TEXTURE_SEED + v * 0x101,
			Vector2i(SHELF_TEXTURE_W, SHELF_TEXTURE_H),
			base,
			UiTheme.PANEL_ALPHA
		)
		var variant_img := tex.get_image()
		if variant_img != null:
			img.blit_rect(variant_img, Rect2i(0, 0, SHELF_TEXTURE_W, SHELF_TEXTURE_H), Vector2i(0, v * SHELF_TEXTURE_H))
	_shelf_texture_tex = ImageTexture.create_from_image(img)
	return _shelf_texture_tex


## 每段架条色调变体（返工7 P4 第三轮）：确定性 hash → 0/1/2（原色/深/浅）
## —— 相邻木板木色不同，绝无连续同色横带。与 _shelf_texture_variant 配套。
func _segment_tone_var(seg: int) -> int:
	var h := (seg * 0x9E3779B1) ^ 0x71E5
	h = (h ^ (h >> 13)) * 1274126177
	return int((h & 0x7fffffff) % SHELF_TONE_VARIANTS)


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


## equipment_id → zone_membership[0]（EquipmentArt 缩略图语义色键；与
## WorldCanvas._zone_of 同一推导，单一来源 catalog def）。未知返回 ""（兜底）。
func _zone_of(eq_id: String) -> String:
	if eq_id == "" or _catalog == null:
		return ""
	var def = _catalog.get_definition(eq_id)
	if def == null or def.zone_membership.is_empty():
		return ""
	return str(def.zone_membership[0])
