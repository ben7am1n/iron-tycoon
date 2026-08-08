## PaletteTile — one shop-palette tile: icon + name + Butter price, with an
## availability state that re-renders the tile (build-shop-ui epic, Story 001;
## TR-BSUI-001/002/006; GDD Core Rule 1).
##
## Renders the three availability states colorblind-safely (AC8, TR-BSUI-006):
##   - AFFORDABLE   → full tint (achromatic white modulate = no tint reduction)
##   - UNAFFORDABLE → greyed (achromatic modulate — equal RGB channels, so NO
##                    hue and NO red survive; "calm grey, never a red denied",
##                    GDD Pillar 2)
##   - LOCKED       → greyed the same way PLUS a lock icon (shape, not color)
## The three states are therefore distinguishable by tint-desaturation
## (lightness) + lock-icon shape, never by color alone.
##
## AC1's drag gating is Story 002's logic — this card ships the RENDERING
## state plus the is_draggable() query Story 002's mouse-down gate consumes.
## The tile is input-ready (mouse_filter STOP + focus_mode FOCUS_ALL for the
## 4.6+ dual-focus keyboard path) so Story 002 needs no tile surgery.
##
## Icon note: the catalog has no icon asset field yet (EquipmentDef carries
## id/name/zones/footprint/cost/unlock/effects/use_duration only), so the icon
## slot renders a placeholder glyph derived from the display name. When art
## lands, swap _icon_label for a TextureRect in _build_children() — the slot
## structure and tests are unchanged.
class_name PaletteTile extends PanelContainer

## Phase D v2 现代 UI 皮肤（art-bible-25d-style §1/§2）—— tile 面板 =
## 深色半透明 + Butter 亮色描边 + 粗字体 + Peach 描边填充式图标（商店→Peach）。
## 状态视觉（modulate 灰化 / 锁图标）保持 art-bible §7 色盲安全契约不变。
const UiTheme := preload("res://src/ui/ui_theme.gd")

## The three availability states. LOCKED deliberately has its OWN enum value:
## a locked item must render differently from a merely-unaffordable one
## (shop-purchase.md Core Rule 5 — a false mental model otherwise).
enum State { AFFORDABLE, UNAFFORDABLE, LOCKED }

## Art-bible palette (design/art/art-bible.md §4).
const COLOR_BUTTER := Color("f5d97b")       # money/highlight — price text
const COLOR_WARM_CREAM := Color("f4e9d8")   # light text on the dark tile
const COLOR_GREYED_MODULATE := Color(0.55, 0.55, 0.55)  # achromatic — no hue

## Lock icon placeholder glyph (shape-first). Art pass replaces with a
## texture; the node/visibility contract stays.
## PHASED-F: 从彩色 emoji 🔒 改为单色 ▣（U+25A3，文本呈现、受 font_color
## 控制 = COLOR_WARM_CREAM；macOS 彩色 emoji 忽略 font_color —— 与 HUD
## 图标同一 bug 类，qa 复验确认）。视觉读作「闭合方盒」= 锁定。
const LOCK_GLYPH := "▣"

## Stable catalog id this tile renders.
var equipment_id: String = ""

## Current availability state. Set via setup() (initial) and set_state()
## (re-grey on balance_changed).
var state: State = State.UNAFFORDABLE

## V3 §10 — equipment pixel-sprite thumbnail (OPTIONAL, default null).
## When provided, the icon slot renders the scene-object sprite (NEAREST)
## instead of the placeholder glyph. Same texture source as the world sprite
## (EquipmentArt), so the purchase bar thumbnail matches the placed object.
var _thumbnail: Texture2D = null

## V3 §10 hover state — true while the pointer is over the tile. Drives:
##   设备略提亮（modulate 亮化） + 黄色像素描边（_draw Butter outline） +
##   轻微上移（缩略图 y 上移，视觉抬起；Control 不动 —— HBox 布局安全）。
var _hovered: bool = false

## V3 §10 hover 亮化：affordable 时 modulate 轻微提亮（暖色，接近 Butter）。
const HOVER_BRIGHTEN := Color(1.08, 1.04, 0.92)
## V3 §10 hover 黄色像素描边色（复用 Palette 单一来源的 EQUIP_HOVER_OUTLINE）。
const HOVER_OUTLINE_COLOR := Color("f5d97b")  # Butter
## V3 §10 hover 上移量（px）：缩略图 icon 向上移，视觉「轻轻抬起」。
const HOVER_LIFT := 3

var _icon_label: Label
var _icon_texture: TextureRect
var _name_label: Label
var _price_label: Label
var _lock_label: Label


## One-time construction: builds the icon/name/price/lock child hierarchy and
## renders the initial state. p_cost is the Butter price from
## EquipmentCatalog.get_definition(id).cost.
## [p_thumbnail] OPTIONAL (V3 §10): equipment pixel sprite; when null the
## placeholder glyph path is kept (story-001/002 rigs, tests).
func setup(p_equipment_id: String, p_display_name: String, p_cost: int, p_thumbnail: Texture2D = null) -> void:
	equipment_id = p_equipment_id
	_thumbnail = p_thumbnail
	_build_children(p_display_name, p_cost)
	set_state(State.UNAFFORDABLE)


## V3 §10 hover enter/leave. Brightens + draws yellow outline + lifts icon.
func _on_mouse_entered() -> void:
	_hovered = true
	_apply_hover_visual()
	queue_redraw()


func _on_mouse_exited() -> void:
	_hovered = false
	_apply_hover_visual()
	queue_redraw()


## V3 §10 hover 状态查询（headless 断言 state，不碰像素）。
func is_hovered() -> bool:
	return _hovered


## V3 §10 hover 描边色（测试查询：黄色像素描边契约）。
func get_hover_outline_color() -> Color:
	return HOVER_OUTLINE_COLOR


## V3 §10 thumbnail 查询（测试：非占位符像素精灵缩略图）。
func get_thumbnail() -> Texture2D:
	return _thumbnail


## Applies the hover visual to the child controls (layout-safe: only the
## icon's own y-offset moves; the tile rect stays put in the HBox).
func _apply_hover_visual() -> void:
	if _icon_texture != null:
		_icon_texture.position.y = -HOVER_LIFT if _hovered else 0
	queue_redraw()


## Re-renders the tile for [p_state] — the palette calls this on every
## balance_changed re-derive. Synchronous: the visual is correct the moment
## the signal handler returns (AC2 "within one frame").
func set_state(p_state: State) -> void:
	state = p_state
	_apply_state_visual()


## The drag gate query Story 002 consumes: only AFFORDABLE tiles may start a
## placement drag. Greyed/locked tiles are inert (AC1/AC3).
func is_draggable() -> bool:
	return state == State.AFFORDABLE


## True when the lock icon is currently shown (state == LOCKED).
func is_locked_visual() -> bool:
	return _lock_label.visible


## True when the tile is greyed (unaffordable OR locked). Affordable tiles
## render full-tint.
func is_greyed() -> bool:
	return state != State.AFFORDABLE


## The rendered display name (Core Rule 1 content readback).
func get_name_text() -> String:
	return _name_label.text


## The rendered Butter price, formatted "$%d" (Core Rule 1 content readback).
func get_price_text() -> String:
	return _price_label.text


## The rendered icon slot content (placeholder glyph until art lands;
## V3 §10 with a thumbnail injected the slot renders the sprite — glyph query
## stays non-empty for backward compat / placeholder path only).
func get_icon_text() -> String:
	if _icon_label == null:
		return ""
	return _icon_label.text


func _build_children(p_display_name: String, p_cost: int) -> void:
	# V3 §15（P0-2 UI 降权）：tile 最小尺寸 96×96 → 88×88 —— 底部购买栏
	# 条带高度同步收紧（main.gd PALETTE_STRIP_H 96→88）。
	custom_minimum_size = Vector2(88, 88)
	# Phase D v2: 深色半透明 tile 面板 + Butter 亮色描边 + 轻微圆角。
	# 状态灰化走 modulate（_apply_state_visual，色盲安全契约不变），
	# stylebox 颜色不参与状态判定。
	# V3 §15（P0-2 UI 降权）：radius 8→2、border 2→3 —— 像素面板语言。
	var sb := UiTheme.make_panel_style(UiTheme.panel_border(), 2, 3)
	add_theme_stylebox_override("panel", sb)
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL
	# V3 §10 hover：鼠标悬停 → 略提亮 + 黄色像素描边 + 轻微上移。
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)

	var stack := VBoxContainer.new()
	stack.alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(stack)

	# Icon slot — V3 §10: equipment pixel-sprite thumbnail (non-placeholder)
	# when provided; else the Phase D v2 outlined-fill placeholder glyph
	# (story-001/002 rigs, tests).
	if _thumbnail != null:
		_icon_texture = TextureRect.new()
		_icon_texture.texture = _thumbnail
		_icon_texture.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		_icon_texture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_icon_texture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		_icon_texture.custom_minimum_size = Vector2(48, 40)
		_icon_texture.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		stack.add_child(_icon_texture)
	else:
		_icon_label = Label.new()
		_icon_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_icon_label.text = _placeholder_glyph(p_display_name)
		UiTheme.apply_outlined_fill(_icon_label, UiTheme.icon_shop(), UiTheme.icon_shop(), 1)
		_icon_label.add_theme_font_override("font", UiTheme.bold_font())
		_icon_label.add_theme_font_size_override("font_size", UiTheme.FONT_ICON)
		stack.add_child(_icon_label)

	_name_label = Label.new()
	_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_name_label.text = p_display_name
	_name_label.add_theme_color_override("font_color", COLOR_WARM_CREAM)
	_name_label.add_theme_font_override("font", UiTheme.bold_font())
	_name_label.add_theme_font_size_override("font_size", UiTheme.FONT_AUX)
	stack.add_child(_name_label)

	_price_label = Label.new()
	_price_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_price_label.text = "$%d" % p_cost
	_price_label.add_theme_color_override("font_color", COLOR_BUTTER)
	_price_label.add_theme_font_override("font", UiTheme.bold_font())
	_price_label.add_theme_font_size_override("font_size", UiTheme.FONT_BODY)
	stack.add_child(_price_label)

	_lock_label = Label.new()
	_lock_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_lock_label.text = LOCK_GLYPH
	_lock_label.add_theme_color_override("font_color", COLOR_WARM_CREAM)
	_lock_label.add_theme_font_size_override("font_size", 20)
	_lock_label.visible = false
	stack.add_child(_lock_label)


## Applies the state's colorblind-safe visual (see class header).
## V3 §10 hover 提亮叠加在 affordability 之上：affordable + hover → 轻微亮化；
## greyed/locked 状态保持灰化（色盲安全契约不变，hover 不破坏 achromatic）。
func _apply_state_visual() -> void:
	var base := Color.WHITE
	match state:
		State.AFFORDABLE:
			base = Color.WHITE
			_lock_label.visible = false
		State.UNAFFORDABLE:
			base = COLOR_GREYED_MODULATE
			_lock_label.visible = false
		State.LOCKED:
			base = COLOR_GREYED_MODULATE
			_lock_label.visible = true
	if _hovered and state == State.AFFORDABLE:
		modulate = HOVER_BRIGHTEN
	else:
		modulate = base


## V3 §10 hover 黄色像素描边：仅 hover 时画 2px Butter outline 于 tile 面板
## 内侧（Control 不动，HBox 布局安全）。draw 在 children 之下 —— outline 位于
## tile 边缘，不遮挡缩略图/文字。
func _draw() -> void:
	if not _hovered:
		return
	var r := Rect2(Vector2(2, 2), size - Vector2(4, 4))
	var c := HOVER_OUTLINE_COLOR
	c.a = 0.9
	draw_rect(r, c, false, 2.0)


## First rune of the display name — a stable per-item placeholder glyph.
func _placeholder_glyph(p_display_name: String) -> String:
	if p_display_name.is_empty():
		return "?"
	return p_display_name.substr(0, 1).to_upper()
