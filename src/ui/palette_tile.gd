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
## V3.1 返工 UI：面板改为 PixelPanel 手绘金属像素平板（不规则边缘 + 拉丝
## cluster + 铆钉 + 非等宽 Butter 断续描边），hover/选中态用断续黄色像素
## 轮廓 + 角标 —— 去 CSS 卡片式矩形（V3 §15 / 附录 V3.1 负面约束）。
const UiTheme := preload("res://src/ui/ui_theme.gd")
const PixelPanel := preload("res://src/ui/pixel_panel.gd")

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

## V3.1 返工 UI — 手绘像素平板纹理参数：设计 tile 88×88 @1.0，texel 4px
## → 22×22。确定性 seed（由 equipment_id hash 派生，每 tile 纹理不同）。
const PLATE_TEXEL := 4
const PLATE_W := 22
const PLATE_H := 22

var _icon_label: Label
var _icon_texture: TextureRect
var _name_label: Label
var _price_label: Label
var _lock_label: Label

## V3.1 返工 UI：懒生成的像素平板纹理（null = 未生成；_draw 首次调用生成）。
var _plate_texture_tex: ImageTexture = null
## V3.1 返工 UI：本 tile 是否处于「拖拽选中」态（建造条拖起中的设备；
## 由 BuildShopPalette 在 begin_drag / 拖拽结束时设置）。选中视觉 = 黄色
## 像素角标（V3 §14 Selected 语言，非模态）。
var _drag_active: bool = false


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


## V3.1 返工 UI：设置「拖拽选中」态（BuildShopPalette 在拖起/结束时调用）。
## 选中视觉 = 黄色像素角标（_draw 绘制）。纯 presentation，不碰 availability。
func set_drag_active(active: bool) -> void:
	if _drag_active == active:
		return
	_drag_active = active
	queue_redraw()


## V3.1 返工 UI：拖拽选中态查询（headless 断言 state，不碰像素）。
func is_drag_active() -> bool:
	return _drag_active


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
	# V3.1 返工 UI：面板 stylebox 透明（保留 content margins 供子节点布局），
	# 像素平板由 _draw() 绘制（PixelPanel 手绘金属平板：不规则边缘 + 拉丝
	# cluster + 铆钉 + 非等宽 Butter 断续描边）。状态灰化走 modulate
	# （_apply_state_visual，色盲安全契约不变），绘制内容随 modulate 一起灰。
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.0, 0.0, 0.0, 0.0)
	sb.border_width_left = 0
	sb.border_width_top = 0
	sb.border_width_right = 0
	sb.border_width_bottom = 0
	sb.content_margin_left = 4.0
	sb.content_margin_right = 4.0
	sb.content_margin_top = 4.0
	sb.content_margin_bottom = 4.0
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


## V3.1 返工 UI：tile 绘制 = 像素金属平板（PixelPanel，懒生成）+
## hover 断续黄色像素轮廓（V3 §14 Hover 语言，手绘非连续矩形）+ 拖拽选中
## 黄色像素角标（V3 §14 Selected 语言）。draw 在 children 之下 —— 平板与
## 轮廓位于 tile 边缘，不遮挡缩略图/文字。
func _draw() -> void:
	var tex := _plate_texture()
	if tex != null:
		draw_texture_rect(tex, Rect2(Vector2.ZERO, size), false)
	if _hovered:
		_draw_pixel_outline()
	if _drag_active:
		_draw_drag_markers()


## 懒生成像素金属平板纹理（seed 由 equipment_id 派生 —— 每 tile 纹理不同；
## 同一 equipment_id 每次运行纹理一致）。底色 = panel_bg() 再压暗（比条带
## 深，tile 与条带层次分离），accent = Butter。
func _plate_texture() -> ImageTexture:
	if _plate_texture_tex == null:
		var base := UiTheme.panel_bg().darkened(0.1)
		_plate_texture_tex = PixelPanel.plate_texture(
			abs(hash(equipment_id)) if equipment_id != "" else 0x71E,
			Vector2i(PLATE_W, PLATE_H),
			base,
			COLOR_BUTTER,
			PixelPanel.Style.METAL,
			0.85
		)
	return _plate_texture_tex


## 断续黄色像素轮廓：沿四边画 2px 粗、6px 长的段（间隔 4px 缺口）+ 两角
## 3×3 色块 —— 手绘「黄色像素轮廓」，绝非等宽闭合矩形边框（V3 §14 /
## V3.1 负面约束）。
func _draw_pixel_outline() -> void:
	var c := HOVER_OUTLINE_COLOR
	c.a = 0.9
	var w := size.x
	var h := size.y
	var seg := 6
	var gap := 4
	for x0 in range(2, w - 2, seg + gap):
		var x1 := mini(x0 + seg, w - 3)
		draw_rect(Rect2(x0, 1, x1 - x0, 2), c, true)
	for x0 in range(2, w - 2, seg + gap):
		var x1 := mini(x0 + seg, w - 3)
		draw_rect(Rect2(x0, h - 3, x1 - x0, 2), c, true)
	for y0 in range(2, h - 2, seg + gap):
		var y1 := mini(y0 + seg, h - 3)
		draw_rect(Rect2(1, y0, 2, y1 - y0), c, true)
	for y0 in range(2, h - 2, seg + gap):
		var y1 := mini(y0 + seg, h - 3)
		draw_rect(Rect2(w - 3, y0, 2, y1 - y0), c, true)
	# 两角 3×3 色块（不对称手绘收尾）
	draw_rect(Rect2(1, 1, 3, 3), c, true)
	draw_rect(Rect2(w - 4, h - 4, 3, 3), c, true)


## 拖拽选中角标：三枚 2×2 Butter 像素钉（缺右下角 —— 不对称，手绘细节）。
func _draw_drag_markers() -> void:
	var c := HOVER_OUTLINE_COLOR
	c.a = 1.0
	draw_rect(Rect2(2, 2, 2, 2), c, true)
	draw_rect(Rect2(size.x - 4, 2, 2, 2), c, true)
	draw_rect(Rect2(2, size.y - 4, 2, 2), c, true)


## First rune of the display name — a stable per-item placeholder glyph.
func _placeholder_glyph(p_display_name: String) -> String:
	if p_display_name.is_empty():
		return "?"
	return p_display_name.substr(0, 1).to_upper()
