# tests/unit/equipment_art/equipment_art_test.gd
# V3 Phase 3 — 设备场景物件像素工厂单元测试
#
# 验证 EquipmentArt（src/presentation/equipment_art.gd）：
#   - art map 结构合法（等宽行、已知图例字符、整 cell 尺寸）
#   - 纹理尺寸 = footprint 像素尺寸（32×32/cell 整数倍）
#   - 语义色正确（cardio→Sky / strength→Sage / flex→Peach，单一色源 palette）
#   - V3 §11 机器深蓝灰轮廓（EQUIP_OUTLINE，非纯黑）；§6 暖高光 / 冷阴影 /
#     青蓝显示灯 accent 存在；zone 色小范围 accent（§14 可购买设备饱和度高）
#   - V3 §5 3/4 top-down 朝向可辨：前端（控制面板/显示屏）与后端（阴影面）
#     区域像素显著不同 —— 前后结构可读
#   - 旋转变体尺寸正确（R90 交换宽高）且旋转后内容仍在（非全透明）
#   - 未知 equipment_id 返回 null（兜底不崩溃）
#
# Run standalone: godot --headless --script tests/unit/equipment_art/equipment_art_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const EquipmentArtScript := preload("res://src/presentation/equipment_art.gd")
const PaletteScript := preload("res://src/palette.gd")

var _pass := 0
var _fail := 0


func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	var result := run_all()
	quit(1 if int(result["fail"]) > 0 else 0)


func run_all() -> Dictionary:
	print("=".repeat(48))
	print("  UNIT TEST: EquipmentArt pixel sprite factory (V3 Phase 3 scene objects)")
	print("=".repeat(48))

	_test_map_structure()
	_test_texture_sizes()
	_test_semantic_colors()
	_test_v3_machine_outline_highlight_shadow_accent()
	_test_v3_orientation_front_back()
	_test_rotation_variants()
	_test_unknown_id_returns_null()
	_test_cache_returns_same_texture()

	print("\n=== EQUIPMENT ART TEST: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


# === 1. map 结构 ===

func _test_map_structure() -> void:
	var art = EquipmentArtScript.new()
	for eq_id in ["treadmill", "bike", "bench_press", "yoga_mat"]:
		var size: Vector2i = art.art_size(eq_id)
		_check(size.x > 0 and size.y > 0, "%s has non-zero art size %s" % [eq_id, size])
		# 16×16 art px per cell → 每 cell 16 行
		var cells_x := size.x / float(art.ART_PER_CELL)
		var cells_y := size.y / float(art.ART_PER_CELL)
		_check(
			cells_x == floor(cells_x) and cells_y == floor(cells_y),
			"%s art size is whole cells (%s×%s / 16)" % [eq_id, size.x, size.y]
		)
		var tex_size: Vector2i = art.texture_size(eq_id)
		_check(
			tex_size == size * art.ART_SCALE,
			"%s texture size = art × scale (%s)" % [eq_id, tex_size]
		)


# === 2. 纹理尺寸 ===

func _test_texture_sizes() -> void:
	var art = EquipmentArtScript.new()
	var expected := {
		"treadmill": Vector2i(2, 1),  # 2×1 footprint → 64×32
		"bike": Vector2i(1, 1),       # 1×1 → 32×32
		"bench_press": Vector2i(2, 2),  # 2×2 → 64×64
		"yoga_mat": Vector2i(1, 1),   # 1×1 → 32×32
	}
	for eq_id in expected:
		var cells: Vector2i = expected[eq_id]
		var tex := art.texture_for(eq_id, "cardio", 0)
		_check(tex != null, "%s texture built" % eq_id)
		if tex == null:
			continue
		var want := Vector2i(
			cells.x * art.ART_PER_CELL * art.ART_SCALE,
			cells.y * art.ART_PER_CELL * art.ART_SCALE
		)
		_check(
			tex.get_size() == Vector2(want.x, want.y),
			"%s texture size %s == %s px (32×32/cell 整数倍)" % [eq_id, tex.get_size(), want]
		)


# === 3. 语义色（区域 accent，§14 可购买设备饱和度高） ===

func _test_semantic_colors() -> void:
	var art = EquipmentArtScript.new()
	# 每种设备的 zone_membership[0] 对应 palette.ZONE_COLORS
	var zone_of := {
		"treadmill": "cardio",
		"bike": "cardio",
		"bench_press": "strength",
		"yoga_mat": "flex",
	}
	for eq_id in zone_of:
		var zone: String = zone_of[eq_id]
		var tex := art.texture_for(eq_id, zone, 0)
		var img := tex.get_image()
		var zone_color: Color = PaletteScript.ZONE_COLORS[zone]
		_check(
			_image_contains(img, zone_color, 0.05),
			"%s contains %s zone accent %s" % [eq_id, zone, zone_color.to_html(false)]
		)


# === 4. V3 §11 机器轮廓 + §6 方向光（暖高光/冷阴影/青蓝显示灯） ===

func _test_v3_machine_outline_highlight_shadow_accent() -> void:
	var art = EquipmentArtScript.new()
	# 机器轮廓：深蓝灰（EQUIP_OUTLINE，§11），非纯黑（§3 禁纯黑粗边）。
	var tex := art.texture_for("treadmill", "cardio", 0)
	var img := tex.get_image()
	_check(
		_image_contains(img, PaletteScript.EQUIP_OUTLINE, 0.05),
		"treadmill contains machine deep-blue-gray outline (V3 §11)"
	)
	_check(
		not _image_contains(img, Color.BLACK, 0.02),
		"treadmill has NO pure black pixels (V3 §3)"
	)
	# 方向光：暖黄/奶白高光（§6 高光暖黄色/奶白色）。
	_check(
		_image_contains(img, PaletteScript.EQUIP_HIGHLIGHT, 0.05),
		"treadmill contains warm highlight (V3 §6 top warm light)"
	)
	# 方向光：冷蓝灰阴影（§6 阴影偏冷、偏蓝灰）。
	_check(
		_image_contains(img, PaletteScript.EQUIP_SHADOW_TONE, 0.05),
		"treadmill contains cool blue-gray shadow (V3 §6)"
	)
	# 显示屏 emissive：青蓝显示灯（§6 部分屏幕青蓝/绿色像素）。
	_check(
		_image_contains(img, PaletteScript.EQUIP_ACCENT_CYAN, 0.05),
		"treadmill contains cyan display pixels (V3 §6 emissive)"
	)
	_check(
		not _image_contains(img, Color.WHITE, 0.02),
		"treadmill has NO pure white pixels (V3 §2 材质概括)"
	)
	# 金属暗面（配重片/飞轮主体）：bench_press 杠铃片存在。
	var bench := art.texture_for("bench_press", "strength", 0)
	_check(
		_image_contains(bench.get_image(), PaletteScript.METAL_DARK, 0.05),
		"bench_press contains metal dark (plates/bar)"
	)
	# 每件设备 ≥3 个主要颜色层级（V3 §5：3-5 个主要颜色层级）：
	# 统计 R0 纹理中不透明、彼此距离 > 0.08 的独立色数。
	var zone_of := {"treadmill": "cardio", "bike": "cardio", "bench_press": "strength", "yoga_mat": "flex"}
	for eq_id in zone_of:
		var t := art.texture_for(eq_id, zone_of[eq_id], 0)
		var levels := _count_color_levels(t.get_image(), 0.08)
		_check(levels >= 3, "%s has >=3 major color levels (got %d, V3 §5)" % [eq_id, levels])


# === 5. V3 §5 3/4 top-down 朝向可辨：前端/后端结构差异 ===

func _test_v3_orientation_front_back() -> void:
	var art = EquipmentArtScript.new()
	# treadmill 前端 = 控制面板（青蓝显示屏），后端 = 阴影面。前后区域色差
	# 显著（display cyan 只在前端；后端是冷阴影/机身暗面）→ 朝向可辨。
	var tex := art.texture_for("treadmill", "cardio", 0)
	var img := tex.get_image()
	var h: int = img.get_height()
	# 前端 = 底部 1/4（console 行），后端 = 顶部 1/4。
	var front_has_cyan := _region_contains(img, Rect2i(0, int(h * 0.75), img.get_width(), h - int(h * 0.75)),
		PaletteScript.EQUIP_ACCENT_CYAN, 0.05)
	var back_has_cyan := _region_contains(img, Rect2i(0, 0, img.get_width(), int(h * 0.25)),
		PaletteScript.EQUIP_ACCENT_CYAN, 0.05)
	_check(front_has_cyan, "treadmill front (console) has cyan display — front-back readable (V3 §5)")
	_check(not back_has_cyan, "treadmill back (rear roller) has NO cyan — distinct from front (V3 §5)")
	# 方向光侧信号：暖高光（W）只在前端 console；冷阴影（S）在后端阴影面。
	var front_has_warm := _region_contains(img, Rect2i(0, int(h * 0.75), img.get_width(), h - int(h * 0.75)),
		PaletteScript.EQUIP_HIGHLIGHT, 0.05)
	var back_has_shadow := _region_contains(img, Rect2i(0, 0, img.get_width(), int(h * 0.25)),
		PaletteScript.EQUIP_SHADOW_TONE, 0.05)
	_check(front_has_warm, "treadmill front (console) has warm highlight — lit side (V3 §6)")
	_check(back_has_shadow, "treadmill back (rear roller) has cool shadow — shaded side (V3 §6)")


# === 6. 旋转变体 ===

func _test_rotation_variants() -> void:
	var art = EquipmentArtScript.new()
	var r0 := art.texture_for("treadmill", "cardio", 0).get_size()
	var r90 := art.texture_for("treadmill", "cardio", 90).get_size()
	var r180 := art.texture_for("treadmill", "cardio", 180).get_size()
	var r270 := art.texture_for("treadmill", "cardio", 270).get_size()
	_check(
		r90 == Vector2(r0.y, r0.x),
		"R90 swaps dims (%s → %s)" % [r0, r90]
	)
	_check(r180 == r0, "R180 restores dims (%s)" % r180)
	_check(r270 == Vector2(r0.y, r0.x), "R270 swaps dims (%s)" % r270)
	# 旋转后内容仍在（非全透明）
	var img90 := art.texture_for("treadmill", "cardio", 90).get_image()
	_check(_image_has_any_opaque(img90), "R90 variant has opaque content")
	# 非法 rotation 回退 R0（不崩溃）
	var bad := art.texture_for("treadmill", "cardio", 45)
	_check(bad != null and bad.get_size() == r0, "illegal rotation falls back to R0")


# === 7. 未知 id ===

func _test_unknown_id_returns_null() -> void:
	var art = EquipmentArtScript.new()
	var tex := art.texture_for("nonexistent_equipment", "cardio", 0)
	_check(tex == null, "unknown equipment_id returns null (no crash)")
	_check(art.art_size("nope") == Vector2i.ZERO, "unknown art_size returns ZERO")


# === 8. 缓存 ===

func _test_cache_returns_same_texture() -> void:
	var art = EquipmentArtScript.new()
	var a := art.texture_for("bike", "cardio", 0)
	var b := art.texture_for("bike", "cardio", 0)
	_check(a == b, "same (id, zone, rotation) returns cached texture")
	var c := art.texture_for("bike", "strength", 0)
	_check(c != null and c != a, "different zone builds distinct texture")


# === helpers ===

func _image_contains(img: Image, color: Color, tol: float) -> bool:
	for y in img.get_height():
		for x in img.get_width():
			var p := img.get_pixel(x, y)
			if p.a > 0.5 and _color_distance(p, color) <= tol:
				return true
	return false


func _region_contains(img: Image, region: Rect2i, color: Color, tol: float) -> bool:
	for y in range(region.position.y, region.end.y):
		for x in range(region.position.x, region.end.x):
			var p := img.get_pixel(x, y)
			if p.a > 0.5 and _color_distance(p, color) <= tol:
				return true
	return false


func _count_color_levels(img: Image, tol: float) -> int:
	# 独立色数：把不透明像素按颜色距离聚簇（贪心）。
	var representatives: Array[Color] = []
	for y in img.get_height():
		for x in img.get_width():
			var p := img.get_pixel(x, y)
			if p.a <= 0.5:
				continue
			var matched := false
			for rep in representatives:
				if _color_distance(p, rep) <= tol:
					matched = true
					break
			if not matched:
				representatives.append(p)
	return representatives.size()


func _color_distance(a: Color, b: Color) -> float:
	var dr := a.r - b.r
	var dg := a.g - b.g
	var db := a.b - b.b
	return sqrt(dr * dr + dg * dg + db * db)


func _image_has_any_opaque(img: Image) -> bool:
	for y in img.get_height():
		for x in img.get_width():
			if img.get_pixel(x, y).a > 0.5:
				return true
	return false
