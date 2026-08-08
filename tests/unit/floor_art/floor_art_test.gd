# tests/unit/floor_art/floor_art_test.gd
# Phase 5 — FloorArt（V3 §1 区域地面材质烘焙）单元测试
#
# 验证 src/presentation/floor_art.gd：
#   - 烘焙图像尺寸 = 网格 × cell（416×320）
#   - V3 §1 四种材质存在：力量区深灰橡胶（暗、非 pastel）、有氧区暖灰/蓝灰、
#     瑜伽区暖木色（r>b 暖橙棕）、通道浅灰瓷砖（亮、有砖缝）
#   - 确定性：两次 build_image() bit-identical（同输入同输出）
#   - 瓷砖砖缝存在（cell 边界 Grout 线）
#   - 纹理缓存：texture() 返回同一 ImageTexture 实例
#   - 材质细节存在：力量区磨损/汗渍、瑜伽区木纹（hash 驱动，非纯色块）
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
	print("  UNIT TEST: FloorArt — V3 §1 区域地面材质")
	print("=".repeat(48))

	_test_image_size()
	_test_strength_material()
	_test_cardio_material()
	_test_flex_material()
	_test_walkway_material()
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
	_check(_near(c, PaletteScript.FLOOR_STRENGTH_BASE, 0.12) or _near(c, PaletteScript.FLOOR_STRENGTH_BLOCK, 0.12),
		"strength floor uses rubber palette (got %s)" % c.to_html(false))
	# 非 pastel：不是旧 Sage/Sky/Peach 大色块
	_check(not _near(c, PaletteScript.SAGE, 0.15), "strength floor NOT pastel Sage")
	_check(not _near(c, PaletteScript.SKY, 0.15), "strength floor NOT pastel Sky")
	# 接缝存在：zone 内 cell 边界有更深的 seam（相对 base 变暗）
	var seam := img.get_pixel(128, 160)  # x=128 = cell 4 边界（32*4）
	var seam_ok := _lum(seam) < _lum(PaletteScript.FLOOR_STRENGTH_BASE)
	_check(seam_ok, "strength floor has seams at cell boundaries (seam lum %.3f < base %.3f)" % [_lum(seam), _lum(PaletteScript.FLOOR_STRENGTH_BASE)])


# === 3. 有氧区：偏暖灰/蓝灰（V3 §1） ===

func _test_cardio_material() -> void:
	var art = _make_art()
	var img := art.build_image()
	# cardio zone (5,1,4,8) cells → 像素 (160,32)-(288,288)；采样 zone 中心 (224,160)
	var c := img.get_pixel(224, 160)
	_check(_near(c, PaletteScript.FLOOR_CARDIO_BASE, 0.12) or _near(c, PaletteScript.FLOOR_CARDIO_DOT, 0.12),
		"cardio floor uses warm-gray/blue-gray palette (got %s)" % c.to_html(false))
	_check(not _near(c, PaletteScript.SKY, 0.15), "cardio floor NOT pastel Sky")
	# 细小重复纹理存在：4px 周期点与 base 不同
	var dot := img.get_pixel(162, 162)  # (zone.x+2, zone.y+2) → 4px 周期点
	var has_texture := _color_distance(dot, PaletteScript.FLOOR_CARDIO_DOT) < 0.08
	_check(has_texture or _color_distance(img.get_pixel(166, 166), PaletteScript.FLOOR_CARDIO_DOT) < 0.08,
		"cardio floor has repeating dot texture")


# === 4. 瑜伽区：暖色木地板（V3 §7 木材暖橙棕） ===

func _test_flex_material() -> void:
	var art = _make_art()
	var img := art.build_image()
	# flex zone (9,1,3,8) cells → 像素 (288,32)-(384,288)；采样 zone 中心 (336,160)
	var c := img.get_pixel(336, 160)
	_check(c.r > c.b + 0.05, "flex floor is warm wood (r=%.3f > b=%.3f)" % [c.r, c.b])
	_check(_near(c, PaletteScript.FLOOR_FLEX_BASE, 0.12) or _near(c, PaletteScript.FLOOR_FLEX_PLANK, 0.12),
		"flex floor uses wood palette (got %s)" % c.to_html(false))
	_check(not _near(c, PaletteScript.PEACH, 0.15), "flex floor NOT pastel Peach")
	# 木板分隔存在：每 16px 有更深的 plank 线
	var plank := img.get_pixel(336, 160 + 16)  # zone.y+16 → 第一条 plank 线
	var plank_ok := _lum(plank) < _lum(PaletteScript.FLOOR_FLEX_BASE)
	_check(plank_ok, "flex floor has plank seams every 16px (plank lum %.3f < base %.3f)" % [_lum(plank), _lum(PaletteScript.FLOOR_FLEX_BASE)])


# === 5. 公共通道：浅灰/暖灰瓷砖（比训练区亮，有砖缝） ===

func _test_walkway_material() -> void:
	var art = _make_art()
	var img := art.build_image()
	# walkway：strength zone 上方 row 0（y 0..32）→ 采样 tile 内部 (110, 12)
	# （避开 x=96 / x=128 砖缝线）
	var c := img.get_pixel(110, 12)
	_check(_lum(c) > 0.6, "walkway tile is light (lum %.3f > 0.6)" % _lum(c))
	_check(_near(c, PaletteScript.FLOOR_WALK_BASE, 0.08), "walkway uses warm tile palette (got %s)" % c.to_html(false))
	# 砖缝存在：cell 边界 (x=64, y=8) 是 Grout 线
	var grout := img.get_pixel(64, 8)
	var grout_ok := _lum(grout) < _lum(PaletteScript.FLOOR_WALK_BASE)
	_check(grout_ok, "walkway has grout lines at cell boundaries (grout lum %.3f < tile %.3f)" % [_lum(grout), _lum(PaletteScript.FLOOR_WALK_BASE)])
	# 通道比力量区亮
	_check(_lum(c) > _lum(img.get_pixel(96, 160)) + 0.2,
		"walkway brighter than strength zone (%.3f vs %.3f)" % [_lum(c), _lum(img.get_pixel(96, 160))])


# === 6. 确定性：两次 build bit-identical ===

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


# === 7. 纹理缓存 ===

func _test_texture_cache() -> void:
	var art = _make_art()
	var t1 := art.texture()
	var t2 := art.texture()
	_check(t1 == t2, "texture() returns cached ImageTexture instance")
	_check(t1.get_size() == Vector2(GRID_W * CELL, GRID_H * CELL), "texture size correct")


# === 8. 无 pastel 大片纯色（V3 §7 绝对避免） ===

func _test_no_pastel_large_area() -> void:
	var art = _make_art()
	var img := art.build_image()
	# 三个 zone 中心都不应是旧 pastel 语义色
	var centers := [Vector2i(96, 160), Vector2i(224, 160), Vector2i(336, 160)]
	for p in centers:
		var c := img.get_pixel(p.x, p.y)
		_check(not _near(c, PaletteScript.SAGE, 0.10) and not _near(c, PaletteScript.SKY, 0.10) and not _near(c, PaletteScript.PEACH, 0.10),
			"zone center %s NOT pastel (got %s)" % [p, c.to_html(false)])


# === helpers ===

func _lum(c: Color) -> float:
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b


func _near(a: Color, b: Color, tol: float) -> bool:
	return _color_distance(a, b) <= tol


func _color_distance(a: Color, b: Color) -> float:
	var dr := a.r - b.r
	var dg := a.g - b.g
	var db := a.b - b.b
	return sqrt(dr * dr + dg * dg + db * db)
