# tests/unit/floor_art/floor_art_test.gd
# Phase 5 + V3.1 P3 — FloorArt（V3 §1 区域地面材质烘焙 + P3 手绘 pixel density）
#
# 验证 src/presentation/floor_art.gd：
#   - 烘焙图像尺寸 = 网格 × cell（416×320）
#   - V3 §1 四种材质身份存在：力量区深灰橡胶（暗、非 pastel）、有氧区暖灰/
#     蓝灰、瑜伽区暖木色（r>b 暖橙棕）、通道浅灰瓷砖（亮）
#   - V3.1 P3 手绘核心：每区由多色 pixel cluster 组成 —— 大窗口内 ≥N 个
#     独立色、主色占比 < 0.75（无大面积单色填充）、无 4px 规则点阵
#     （有氧区不再周期重复）、接缝/砖缝/板缝存在但断裂不规则（无完美直线）
#   - V3.1 P3 不规则边缘：区域边界列同时含区域色与通道色（非完美直线矩形）
#   - 确定性：两次 build_image() bit-identical（同输入同输出）
#   - 纹理缓存：texture() 返回同一 ImageTexture 实例
#
# Run standalone: godot --headless --script tests/unit/floor_art/floor_art_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const FloorArtScript := preload("res://src/presentation/floor_art.gd")
const PaletteScript := preload("res://src/palette.gd")

const GRID_W := 13
const GRID_H := 10
const CELL := 32

var _pass := 0
var _fail := 0


func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	var result := run_all()
	quit(1 if int(result["fail"]) > 0 else 0)


func run_all() -> Dictionary:
	print("=".repeat(48))
	print("  UNIT TEST: FloorArt — V3 §1 区域材质 + V3.1 P3 手绘 cluster")
	print("=".repeat(48))

	_test_image_size()
	_test_strength_material()
	_test_cardio_material()
	_test_flex_material()
	_test_walkway_material()
	_test_multi_color_clusters()
	_test_no_regular_dot_grid()
	_test_irregular_edges()
	_test_determinism()
	_test_texture_cache()
	_test_no_pastel_large_area()

	print("\n=== FLOOR ART TEST: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


func _make_art():
	var art = FloorArtScript.new()
	art.init(GRID_W, GRID_H, CELL)
	return art


# === 1. 图像尺寸 ===

func _test_image_size() -> void:
	var art = _make_art()
	var img := art.build_image()
	_check(img.get_width() == GRID_W * CELL, "floor image width == %d (got %d)" % [GRID_W * CELL, img.get_width()])
	_check(img.get_height() == GRID_H * CELL, "floor image height == %d (got %d)" % [GRID_H * CELL, img.get_height()])


# === 2. 力量区：深灰橡胶（V3 §1 深灰橡胶地垫，非 pastel） ===

func _test_strength_material() -> void:
	var art = _make_art()
	var img := art.build_image()
	# strength zone (1,1,4,8) cells → 像素 (32,32)-(160,288)；采样 zone 中心 (96,160)
	var c := img.get_pixel(96, 160)
	_check(_lum(c) < 0.45, "strength floor is dark rubber (lum %.3f < 0.45)" % _lum(c))
	_check(_near_any(c, _strength_colors(), 0.12),
		"strength floor uses rubber cluster palette (got %s)" % c.to_html(false))
	# 非 pastel：不是旧 Sage/Sky/Peach 大色块
	_check(not _near(c, PaletteScript.SAGE, 0.15), "strength floor NOT pastel Sage")
	_check(not _near(c, PaletteScript.SKY, 0.15), "strength floor NOT pastel Sky")
	# 接缝存在：zone 内含 SEAM 色像素（断裂不规则接缝，V3.1 P3 无完美直线但接缝在）
	var rect := _zone_px("strength")
	_check(_contains_family(img, rect, [PaletteScript.FLOOR_STRENGTH_SEAM], 0.04),
		"strength floor has jagged seam clusters (SEAM color present)")


# === 3. 有氧区：偏暖灰/蓝灰（V3 §1） ===

func _test_cardio_material() -> void:
	var art = _make_art()
	var img := art.build_image()
	# cardio zone (5,1,4,8) cells → 像素 (160,32)-(288,288)；采样 zone 中心 (224,160)
	var c := img.get_pixel(224, 160)
	_check(_near_any(c, _cardio_colors(), 0.12),
		"cardio floor uses warm-gray/blue-gray cluster palette (got %s)" % c.to_html(false))
	_check(not _near(c, PaletteScript.SKY, 0.15), "cardio floor NOT pastel Sky")
	# 多色 cluster：中心 32×32 窗口独立色 ≥ 5
	var win := _window_stats(img, 208, 144, 32, 32)
	_check(int(win["distinct"]) >= 5, "cardio floor is multi-cluster (>=5 distinct in 32x32, got %d)" % int(win["distinct"]))


# === 4. 瑜伽区：暖色木地板（V3 §7 木材暖橙棕） ===

func _test_flex_material() -> void:
	var art = _make_art()
	var img := art.build_image()
	# flex zone (9,1,3,8) cells → 像素 (288,32)-(384,288)；采样 zone 中心 (336,160)
	var c := img.get_pixel(336, 160)
	_check(c.r > c.b + 0.05, "flex floor is warm wood (r=%.3f > b=%.3f)" % [c.r, c.b])
	_check(_near_any(c, _flex_colors(), 0.12),
		"flex floor uses wood cluster palette (got %s)" % c.to_html(false))
	_check(not _near(c, PaletteScript.PEACH, 0.15), "flex floor NOT pastel Peach")
	# 板缝存在：zone 内含 PLANK 色（断裂不规则板缝）
	var rect := _zone_px("flex")
	_check(_contains_family(img, rect, [PaletteScript.FLOOR_FLEX_PLANK], 0.04),
		"flex floor has jagged plank seams (PLANK color present)")
	# 木纹存在：GRAIN 色
	_check(_contains_family(img, rect, [PaletteScript.FLOOR_FLEX_GRAIN], 0.04),
		"flex floor has wood grain (GRAIN color present)")


# === 5. 公共通道：浅灰/暖灰瓷砖（比训练区亮，有砖缝） ===

func _test_walkway_material() -> void:
	var art = _make_art()
	var img := art.build_image()
	# walkway：strength zone 上方 row 0（y 0..32）→ 采样 tile 内部 (110, 12)
	var c := img.get_pixel(110, 12)
	_check(_lum(c) > 0.6, "walkway tile is light (lum %.3f > 0.6)" % _lum(c))
	_check(_near_any(c, _walk_colors(), 0.10),
		"walkway uses warm tile cluster palette (got %s)" % c.to_html(false))
	# 砖缝存在：顶部 walkway 条带内含 GROUT 色（断裂 jagged 砖缝）
	var top_band := Rect2i(0, 0, GRID_W * CELL, 32)
	_check(_contains_family(img, top_band, [PaletteScript.FLOOR_WALK_GROUT], 0.04),
		"walkway has jagged grout seams (GROUT color present)")
	# 通道比力量区亮
	_check(_lum(c) > _lum(img.get_pixel(96, 160)) + 0.2,
		"walkway brighter than strength zone (%.3f vs %.3f)" % [_lum(c), _lum(img.get_pixel(96, 160))])


# === 6. V3.1 P3 核心：大面积 = 多色 pixel cluster，无纯色块 ===

func _test_multi_color_clusters() -> void:
	var art = _make_art()
	var img := art.build_image()
	# 每区取内部 64×64 窗口（避开 jagged 边缘带 ±4）：
	#   strength (96-32, 160-32) = (64,128)；cardio 中心 (224,160)；flex (336,160)
	var cases := {
		"strength": [Vector2i(64, 128), _strength_colors()],
		"cardio": [Vector2i(192, 128), _cardio_colors()],
		"flex": [Vector2i(304, 128), _flex_colors()],
	}
	for zone in cases:
		var pos: Vector2i = cases[zone][0]
		var family: Array = cases[zone][1]
		var win := _window_stats(img, pos.x, pos.y, 64, 64)
		var distinct := int(win["distinct"])
		var dominant := float(win["dominant"]) / maxi(int(win["total"]), 1)
		_check(distinct >= 5,
			"P3 %s 64x64 window multi-cluster (>=5 distinct, got %d)" % [zone, distinct])
		_check(dominant < 0.75,
			"P3 %s no dominant single color (dominant %.2f < 0.75)" % [zone, dominant])
		# 窗口内所有非通道色都应属该区色系（区域材质不被其它区污染）
		var foreign := 0
		for y in range(pos.y, pos.y + 64):
			for x in range(pos.x, pos.x + 64):
				var p := img.get_pixel(x, y)
				if not _near_any(p, family, 0.06):
					foreign += 1
		_check(foreign <= int(win["total"]) * 0.04,
			"P3 %s window mostly zone palette (foreign px %d <= 4%%)" % [zone, foreign])


# === 7. V3.1 P3：无重复规则纹理（有氧区无 4px 周期点阵） ===

func _test_no_regular_dot_grid() -> void:
	var art = _make_art()
	var img := art.build_image()
	var rect := _zone_px("cardio")
	# 旧实现：每 4px 周期画 DOT 点 → 4px 网格 100% 命中。P3 要求不规则 cluster：
	# 4px 网格点上 DOT 色占比应 < 60%（cluster 是局部色块，非全格重复）。
	var total := 0
	var dot_hits := 0
	for y in range(rect.position.y + 2, rect.position.y + rect.size.y, 4):
		for x in range(rect.position.x + 2, rect.position.x + rect.size.x, 4):
			total += 1
			if _near(img.get_pixel(x, y), PaletteScript.FLOOR_CARDIO_DOT, 0.04):
				dot_hits += 1
	var ratio := float(dot_hits) / maxi(total, 1)
	_check(ratio < 0.60,
		"P3 cardio no repeating 4px dot grid (dot-hit ratio %.2f < 0.60)" % ratio)


# === 8. V3.1 P3：不规则边缘（区域边界非完美直线矩形） ===

func _test_irregular_edges() -> void:
	var art = _make_art()
	var img := art.build_image()
	# strength 左边界列 x=32：jagged fill 逐行偏移 ±3 + blob bleed → 该列应同时
	# 出现区域色（深灰系）与通道色（浅色）—— 证明边缘是手工不规则，不是
	# 完美垂直直线。若完美矩形填充，该列 100% 区域色。
	var rect := _zone_px("strength")
	var zone_px := 0
	var walk_px := 0
	for y in range(rect.position.y + 6, rect.position.y + rect.size.y - 6):
		var p := img.get_pixel(rect.position.x, y)
		if _near_any(p, _strength_colors(), 0.08):
			zone_px += 1
		elif _near_any(p, _walk_colors(), 0.10):
			walk_px += 1
	_check(zone_px > 0 and walk_px > 0,
		"P3 strength left edge is irregular (zone px %d + walk px %d on boundary col)" % [zone_px, walk_px])


# === 9. 确定性：两次 build bit-identical ===

func _test_determinism() -> void:
	var art = _make_art()
	var a := art.build_image()
	var b := art.build_image()
	var identical := true
	for y in GRID_H * CELL:
		for x in GRID_W * CELL:
			if a.get_pixel(x, y) != b.get_pixel(x, y):
				identical = false
				break
		if not identical:
			break
	_check(identical, "two builds are bit-identical (deterministic, no RNG)")


# === 10. 纹理缓存 ===

func _test_texture_cache() -> void:
	var art = _make_art()
	var t1 := art.texture()
	var t2 := art.texture()
	_check(t1 == t2, "texture() returns cached ImageTexture instance")
	_check(t1.get_size() == Vector2(GRID_W * CELL, GRID_H * CELL), "texture size correct")


# === 11. 无 pastel 大片纯色（V3 §7 绝对避免） ===

func _test_no_pastel_large_area() -> void:
	var art = _make_art()
	var img := art.build_image()
	var centers := [Vector2i(96, 160), Vector2i(224, 160), Vector2i(336, 160)]
	for p in centers:
		var c := img.get_pixel(p.x, p.y)
		_check(not _near(c, PaletteScript.SAGE, 0.10) and not _near(c, PaletteScript.SKY, 0.10) and not _near(c, PaletteScript.PEACH, 0.10),
			"zone center %s NOT pastel (got %s)" % [p, c.to_html(false)])


# === helpers ===

func _zone_px(zone: String) -> Rect2i:
	var r: Rect2i = PaletteScript.ZONE_RECTS[zone]
	return Rect2i(r.position * CELL, r.size * CELL)


func _strength_colors() -> Array:
	return [
		PaletteScript.FLOOR_STRENGTH_BASE,
		PaletteScript.FLOOR_STRENGTH_BLOCK,
		PaletteScript.FLOOR_STRENGTH_CL_GRAYBLUE,
		PaletteScript.FLOOR_STRENGTH_CL_WARMGRAY,
		PaletteScript.FLOOR_STRENGTH_STAIN,
		PaletteScript.FLOOR_STRENGTH_WEAR,
		PaletteScript.FLOOR_STRENGTH_SEAM,
	]


func _cardio_colors() -> Array:
	return [
		PaletteScript.FLOOR_CARDIO_BASE,
		PaletteScript.FLOOR_CARDIO_DOT,
		PaletteScript.FLOOR_CARDIO_CL_GRAYBLUE,
		PaletteScript.FLOOR_CARDIO_CL_WARMGRAY,
		PaletteScript.FLOOR_CARDIO_EDGE,
	]


func _flex_colors() -> Array:
	return [
		PaletteScript.FLOOR_FLEX_BASE,
		PaletteScript.FLOOR_FLEX_CL_LIGHT,
		PaletteScript.FLOOR_FLEX_CL_DARK,
		PaletteScript.FLOOR_FLEX_GRAIN,
		PaletteScript.FLOOR_FLEX_PLANK,
	]


func _walk_colors() -> Array:
	return [
		PaletteScript.FLOOR_WALK_BASE,
		PaletteScript.FLOOR_WALK_CL_LIGHT,
		PaletteScript.FLOOR_WALK_CL_DARK,
	]


## 窗口内颜色统计：{distinct, dominant, total}（html 键精确计数）。
func _window_stats(img: Image, x0: int, y0: int, w: int, h: int) -> Dictionary:
	var counts: Dictionary = {}
	var total := 0
	for y in range(y0, y0 + h):
		for x in range(x0, x0 + w):
			if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
				continue
			var key := img.get_pixel(x, y).to_html(false)
			counts[key] = int(counts.get(key, 0)) + 1
			total += 1
	var distinct := counts.size()
	var dominant := 0
	for k in counts:
		dominant = maxi(dominant, int(counts[k]))
	return {"distinct": distinct, "dominant": dominant, "total": total}


## 矩形区域内是否存在 family 中任一颜色（容差 tol）。
func _contains_family(img: Image, rect: Rect2i, family: Array, tol: float) -> bool:
	for y in range(rect.position.y, rect.position.y + rect.size.y):
		for x in range(rect.position.x, rect.position.x + rect.size.x):
			if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
				continue
			if _near_any(img.get_pixel(x, y), family, tol):
				return true
	return false


func _near_any(c: Color, family: Array, tol: float) -> bool:
	for f in family:
		if _color_distance(c, f) <= tol:
			return true
	return false


func _lum(c: Color) -> float:
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b


func _near(a: Color, b: Color, tol: float) -> bool:
	return _color_distance(a, b) <= tol


func _color_distance(a: Color, b: Color) -> float:
	var dr := a.r - b.r
	var dg := a.g - b.g
	var db := a.b - b.b
	return sqrt(dr * dr + dg * dg + db * db)
