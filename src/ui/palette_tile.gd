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

## The three availability states. LOCKED deliberately has its OWN enum value:
## a locked item must render differently from a merely-unaffordable one
## (shop-purchase.md Core Rule 5 — a false mental model otherwise).
enum State { AFFORDABLE, UNAFFORDABLE, LOCKED }

## Art-bible palette (design/art/art-bible.md §4).
const COLOR_BUTTER := Color("f5d97b")       # money/highlight — price text
const COLOR_CHARCOAL := Color("3c3a42")     # text/outline — name text
const COLOR_WARM_CREAM := Color("f4e9d8")   # tile background
const COLOR_GREYED_MODULATE := Color(0.55, 0.55, 0.55)  # achromatic — no hue

## Lock icon placeholder glyph (shape-first). Art pass replaces with a
## texture; the node/visibility contract stays.
const LOCK_GLYPH := "🔒"

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
	var sb := StyleBoxFlat.new()
	sb.bg_color = COLOR_WARM_CREAM
	sb.set_border_width_all(2)
	sb.border_color = COLOR_CHARCOAL
	add_theme_stylebox_override("panel", sb)
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL

	var stack := VBoxContainer.new()
	stack.alignment = BoxContainer.ALIGNMENT_CENTER
	add_child(stack)

	# Icon slot — placeholder glyph until art assets land (see class note).
	_icon_label = Label.new()
	_icon_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_icon_label.text = _placeholder_glyph(p_display_name)
	_icon_label.add_theme_font_size_override("font_size", 28)
	stack.add_child(_icon_label)

	_name_label = Label.new()
	_name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_name_label.text = p_display_name
	_name_label.add_theme_color_override("font_color", COLOR_CHARCOAL)
	_name_label.add_theme_font_size_override("font_size", 14)
	stack.add_child(_name_label)

	_price_label = Label.new()
	_price_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_price_label.text = "$%d" % p_cost
	_price_label.add_theme_color_override("font_color", COLOR_BUTTER)
	_price_label.add_theme_font_size_override("font_size", 16)
	stack.add_child(_price_label)

	_lock_label = Label.new()
	_lock_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_lock_label.text = LOCK_GLYPH
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
