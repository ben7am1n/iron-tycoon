## CongestionGlyph — one per-equipment congestion indicator (Story CFO-002).
##
## GDD Core Rule 4 (TR-CFO-004): the glyph's SHAPE/FILL is the primary
## signal — an empty outline fills from the bottom up as congestion rises
## (battery-icon language, design/ux/accessibility-requirements.md §3.1) —
## with Dusty Rose tint as SECONDARY reinforcement only. Colorblind-safe by
## construction: with color removed, fill level is still readable (the fill
## rect height is a pure function of fill_fraction).
##
## GDD Formula: fill_fraction = clamp(per_equipment_congestion, 0, 1).
## Both set_fill() and the layer's congestion_glyph_fill() clamp defensively.
##
## Rendering: CanvasItem._draw with draw_rect only — deliberately NO text
## (draw_string needs a Font, null under headless; glyphs are shape-based,
## story engine note). The node is a small world-space Node2D child of
## CongestionGlyphLayer, positioned at the equipment anchor's world cell.
##
## 4.7.1 pitfalls respected: class_name follows extends immediately; no
## `var x := expr` on Variant returns; draw_rect takes Rect2/Color/bool/float.
class_name CongestionGlyph extends Node2D

## V3 §2 世界缩放（描边宽度补偿 —— 亚像素描边消失 pitfall，见 world_scale.gd）。
const WorldScale := preload("res://src/presentation/world_scale.gd")

## Dusty Rose — the soft congestion tint (art bible: congestion/needs-
## attention semantic, never harsh red). Secondary channel only.
const DUSTY_ROSE := Color("e0a0a0")
## Soft Charcoal — outline color (art bible #3C3A42; non-pure-black to
## lower contrast pressure, Pillar 2).
const SOFT_CHARCOAL := Color("3c3a42")

## The fill fraction (clamped [0,1]) — AC10's observable. 0 = empty outline,
## 1 = fully filled.
var fill_fraction: float = 0.0
## Icon box size in world px. Injected from the layer's data-driven config
## (glyph_width/glyph_height), never hardcoded here.
var glyph_size: Vector2 = Vector2(16, 20)
## Outline stroke width (px). High-contrast mode (TR-CFO-011) thickens this
## via set_outline_width — the layer owns which width is active.
var outline_width: float = 1.0


func _init(p_size: Vector2, p_outline_width: float) -> void:
	glyph_size = p_size
	outline_width = p_outline_width


## AC10 setter: fill_fraction = clamp(value, 0, 1). Called by the layer on
## every congestion_updated (10 Hz) — never per-frame.
func set_fill(value: float) -> void:
	fill_fraction = clampf(value, 0.0, 1.0)
	queue_redraw()


## High-contrast outline setter (TR-CFO-011): thickens the stroke; the
## shape channel (fill height) is unchanged — color is never the carrier.
func set_outline_width(value: float) -> void:
	outline_width = maxf(value, 0.0)
	queue_redraw()


## The fill rect used by _draw — exposed as a pure function so the
## shape-first contract is headless-testable (Core Rule 4 / AC6): fill
## height is EXACTLY inner_height × fill_fraction, independent of any color
## channel. With fill 0 the rect has zero height (empty outline); with
## fill 1 it covers the full inner box.
func fill_rect() -> Rect2:
	var margin := outline_width + 1.0
	var inner_w := maxf(glyph_size.x - 2.0 * margin, 0.0)
	var inner_h := maxf(glyph_size.y - 2.0 * margin, 0.0)
	var h := inner_h * fill_fraction
	return Rect2(margin, margin + inner_h - h, inner_w, h)


## Renders the glyph: Soft Charcoal outline + Dusty Rose fill whose alpha
## ramps with fill_fraction (secondary reinforcement — the height carries
## the signal). Never pulses/loops (Pillar 2); one static shape.
## Outline width × STROKE_COMPENSATION：WorldRoot scale 0.75 下亚像素描边
## 消失（4.7.1 pitfall，world_scale.gd）—— 数据值（outline_width，测试契约）
## 保持 1.0，绘制时补偿到 ≥1.0 viewport px。
func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, glyph_size), SOFT_CHARCOAL, false,
		outline_width * WorldScale.STROKE_COMPENSATION)
	var fr := fill_rect()
	if fr.size.y > 0.0:
		draw_rect(fr, Color(DUSTY_ROSE.r, DUSTY_ROSE.g, DUSTY_ROSE.b, fill_fraction))
