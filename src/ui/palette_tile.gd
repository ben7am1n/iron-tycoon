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

var _icon_label: Label
var _name_label: Label
var _price_label: Label
var _lock_label: Label


## One-time construction: builds the icon/name/price/lock child hierarchy and
## renders the initial state. p_cost is the Butter price from
## EquipmentCatalog.get_definition(id).cost.
func setup(p_equipment_id: String, p_display_name: String, p_cost: int) -> void:
	equipment_id = p_equipment_id
	_build_children(p_display_name, p_cost)
	set_state(State.UNAFFORDABLE)


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


## The rendered icon slot content (placeholder glyph until art lands).
func get_icon_text() -> String:
	return _icon_label.text


func _build_children(p_display_name: String, p_cost: int) -> void:
	custom_minimum_size = Vector2(96, 96)
	# Phase D v2: 深色半透明 tile 面板 + Butter 亮色描边 + 轻微圆角。
	# 状态灰化走 modulate（_apply_state_visual，色盲安全契约不变），
	# stylebox 颜色不参与状态判定。
	var sb := UiTheme.make_panel_style(UiTheme.panel_border(), 8, 2)
	add_theme_stylebox_override("panel", sb)
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL

	var stack := VBoxContainer.new()
	stack.alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(stack)

	# Icon slot — Phase D v2: 商店→Peach 描边填充式图标（art-bible §7
	# outlined-fill；placeholder 字形保留，测试固定 length > 0）。
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
func _apply_state_visual() -> void:
	match state:
		State.AFFORDABLE:
			modulate = Color.WHITE
			_lock_label.visible = false
		State.UNAFFORDABLE:
			modulate = COLOR_GREYED_MODULATE
			_lock_label.visible = false
		State.LOCKED:
			modulate = COLOR_GREYED_MODULATE
			_lock_label.visible = true


## First rune of the display name — a stable per-item placeholder glyph.
func _placeholder_glyph(p_display_name: String) -> String:
	if p_display_name.is_empty():
		return "?"
	return p_display_name.substr(0, 1).to_upper()
