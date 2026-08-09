# tests/unit/equipment_art/equipment_art_test.gd
# V3 Phase 3 + V3.1 P2 — 设备场景物件像素工厂单元测试
#
# 验证 EquipmentArt（src/presentation/equipment_art.gd）：
#   - art map 结构合法（等宽行、已知图例字符、整 cell 尺寸）
#   - 纹理尺寸 = footprint 像素尺寸（32×32/cell 整数倍）
#   - 语义色正确（cardio→Sky / strength→Sage / flex→Peach，单一色源 palette）
#   - V3 §11 机器深蓝灰轮廓（EQUIP_OUTLINE，非纯黑）；§6 暖高光 / 冷阴影 /
#     青蓝显示灯 accent 存在；zone 色小范围 accent（§14 可购买设备饱和度高）
#   - V3 §5 3/4 top-down 朝向可辨：前端（控制面板/显示屏）与后端（阴影面）
#     区域像素显著不同 —— 前后结构可读
#   - V3.1 P2（真物体，非图标）：3 方向面（top/front/side）各有手绘 map，
#     每台设备每个面含 5 色层（base/shadow/outline/highlight/accent）；
#     部件可辨 —— treadmill 跑带/扶手/控制台、bench 杠铃片/长凳、bike 飞轮/
#     座椅；设备离开地面（front/side 有支撑结构）
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
	print("  UNIT TEST: EquipmentArt pixel sprite factory (V3 Phase 3 + V3.1 P2)")
	print("=".repeat(48))

	_test_map_structure()
	_test_texture_sizes()
	_test_semantic_colors()
	_test_v3_machine_outline_highlight_shadow_accent()
	_test_v3_orientation_front_back()
	_test_v31p2_face_maps_structure()
	_test_v31p2_five_layers_per_face()
	_test_v31p2_components_recognizable()
	_test_v31p2_equipment_leaves_ground()
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


# === 5.5. V3.1 P2: face map 结构 ===

## V3.1 P2 最低要求：3 方向面（top/front/side）。FACE_MAPS 为每台机器提供
## front（南面，面向相机）与 side（东面）手绘 map。结构断言：等宽行、
## 已知图例字符、非空、尺寸合理（front 宽 = 顶面宽；side 宽 = 顶面高）。
func _test_v31p2_face_maps_structure() -> void:
	var art = EquipmentArtScript.new()
	for eq_id in ["treadmill", "bike", "bench_press"]:
		_check(EquipmentArtScript.FACE_MAPS.has(eq_id),
			"V3.1P2 %s has authored FACE_MAPS (3 facing directions)" % eq_id)
		if not EquipmentArtScript.FACE_MAPS.has(eq_id):
			continue
		var face: Dictionary = EquipmentArtScript.FACE_MAPS[eq_id]
		_check(face.has("front") and face.has("side"),
			"V3.1P2 %s face map has front + side" % eq_id)
		var top_size: Vector2i = art.art_size(eq_id)
		for fname in ["front", "side"]:
			var rows: Array = face.get(fname, [])
			_check(not rows.is_empty(), "V3.1P2 %s.%s non-empty" % [eq_id, fname])
			if rows.is_empty():
				continue
			var width := String(rows[0]).length()
			var all_same := true
			for r in rows:
				if String(r).length() != width:
					all_same = false
			_check(all_same, "V3.1P2 %s.%s equal-width rows (%d)" % [eq_id, fname, width])
			var known := true
			for r in rows:
				for ch in String(r):
					if not "OC123MHWSAZDL.".contains(ch):
						known = false
			_check(known, "V3.1P2 %s.%s uses known legend chars" % [eq_id, fname])
		# front 宽 = 顶面宽（footprint x）；side 宽 = 顶面高（footprint y）
		var front_rows: Array = face.get("front", [])
		var side_rows: Array = face.get("side", [])
		if not front_rows.is_empty():
			_check(String(front_rows[0]).length() == top_size.x,
				"V3.1P2 %s front width %d == top width %d (footprint x)"
				% [eq_id, String(front_rows[0]).length(), top_size.x])
		if not side_rows.is_empty():
			_check(String(side_rows[0]).length() == top_size.y,
				"V3.1P2 %s side width %d == top height %d (footprint y)"
				% [eq_id, String(side_rows[0]).length(), top_size.y])


# === 5.6. V3.1 P2: 每面 5 色层（base/shadow/outline/highlight/accent） ===

## V3.1 P2 最低要求：5 层颜色（base/shadow/outline/highlight/accent）可在
## sprite 像素中找到。对每台设备 × 每个方向面（top/front/side）逐面断言
## 5 层都存在 —— 不是「全局有 5 种颜色」，而是「每一面都画全 5 层」。
func _test_v31p2_five_layers_per_face() -> void:
	var art = EquipmentArtScript.new()
	var zone_of := {"treadmill": "cardio", "bike": "cardio", "bench_press": "strength"}
	var layer_checks := {
		"base": [
			PaletteScript.EQUIP_BODY_DARK, PaletteScript.EQUIP_BODY,
			PaletteScript.EQUIP_BODY_LIGHT, PaletteScript.METAL_DARK,
		],
		"shadow": [PaletteScript.EQUIP_SHADOW_TONE],
		"outline": [PaletteScript.EQUIP_OUTLINE],
		"highlight": [PaletteScript.EQUIP_HIGHLIGHT, PaletteScript.METAL_HIGHLIGHT],
		# accent：青蓝显示灯 A 或区域语义色 Z（V3 §7 高饱和重点色小范围使用）
		"accent": [],
	}
	for eq_id in zone_of:
		var zone: String = zone_of[eq_id]
		layer_checks["accent"] = [
			PaletteScript.EQUIP_ACCENT_CYAN, PaletteScript.ZONE_COLORS[zone],
			PaletteScript.ZONE_COLORS[zone].darkened(0.25),
			PaletteScript.ZONE_COLORS[zone].lightened(0.15),
		]
		# top 面（texture_for）
		var top_img := art.texture_for(eq_id, zone, 0).get_image()
		# front/side 面（raw_face_images —— 未变暗，5 层不被混合污染）
		var raws: Dictionary = art.raw_face_images(eq_id, zone)
		var face_imgs := {
			"front": raws.get("front"), "side": raws.get("side"),
		}
		for layer in layer_checks:
			var colors: Array = layer_checks[layer]
			# top 面
			var top_ok := false
			for c in colors:
				if _image_contains(top_img, c, 0.05):
					top_ok = true
					break
			_check(top_ok, "V3.1P2 %s top has %s layer (5 layers, V3.1 P2)" % [eq_id, layer])
			# front/side 面
			for fname in ["front", "side"]:
				var fimg: Image = face_imgs[fname]
				if fimg == null:
					_check(false, "V3.1P2 %s.%s image built" % [eq_id, fname])
					continue
				var f_ok := false
				for c in colors:
					if _image_contains(fimg, c, 0.05):
						f_ok = true
						break
				_check(f_ok, "V3.1P2 %s.%s has %s layer (5 layers, V3.1 P2)" % [eq_id, fname, layer])


# === 5.7. V3.1 P2: 部件可辨（真物体，非图标） ===

## 每台设备部件必须在 sprite 像素中可辨（V3.1 P2 退出条件「设备像场景物件非
## 图标」）：
##   - treadmill：跑带（M2 履带纹，M）+ 控制台显示屏（A，在 front 面上）
##   - bench_press：杠铃片（H 金属高光）+ 长凳厚度（side 面 Z 条带 + D 端）
##   - bike：飞轮（H 金属盘）+ 座椅（zone 色 Z，在 side 面上）
func _test_v31p2_components_recognizable() -> void:
	var art = EquipmentArtScript.new()
	# treadmill：front 面控制台显示屏（A 青蓝）存在 —— 相机可见面有真实控制台
	var tm_raw: Dictionary = art.raw_face_images("treadmill", "cardio")
	var tm_front: Image = tm_raw.get("front")
	_check(tm_front != null, "V3.1P2 treadmill front face built")
	if tm_front != null:
		_check(_image_contains(tm_front, PaletteScript.EQUIP_ACCENT_CYAN, 0.05),
			"V3.1P2 treadmill front has console display (cyan A) — 控制台可辨")
	# treadmill：跑带 M2 履带纹（METAL_DARK）在 front 面中段 —— 跑带可辨
	_check(_image_contains(tm_front, PaletteScript.METAL_DARK, 0.05),
		"V3.1P2 treadmill front has belt tread (METAL_DARK M) — 跑带可辨")
	# bench_press：side 面 = 杠铃片（H）+ 长凳厚度（zone Z + D 端）
	var bench_raw: Dictionary = art.raw_face_images("bench_press", "strength")
	var bench_side: Image = bench_raw.get("side")
	_check(bench_side != null, "V3.1P2 bench_press side face built")
	if bench_side != null:
		_check(_image_contains(bench_side, PaletteScript.METAL_HIGHLIGHT, 0.05),
			"V3.1P2 bench side has barbell plates (H metal highlight) — 杠铃片可辨")
		_check(_image_contains(bench_side, PaletteScript.ZONE_COLORS["strength"], 0.05),
			"V3.1P2 bench side has bench pad zone color — 长凳可辨")
		_check(_image_contains(bench_side,
			PaletteScript.ZONE_COLORS["strength"].darkened(0.25), 0.05),
			"V3.1P2 bench side has pad end (zone dark) — 长凳厚度可辨")
	# bike：side 面 = 飞轮（H）+ 座椅（zone Z）
	var bike_raw: Dictionary = art.raw_face_images("bike", "cardio")
	var bike_side: Image = bike_raw.get("side")
	_check(bike_side != null, "V3.1P2 bike side face built")
	if bike_side != null:
		_check(_image_contains(bike_side, PaletteScript.METAL_HIGHLIGHT, 0.05),
			"V3.1P2 bike side has flywheel (H metal highlight) — 飞轮可辨")
		_check(_image_contains(bike_side, PaletteScript.ZONE_COLORS["cardio"], 0.05),
			"V3.1P2 bike side has seat (zone accent) — 座椅可辨")


# === 5.8. V3.1 P2: 设备离开地面（front/side 有支撑结构） ===

## V3.1 P2「设备离开地面，不贴地图」：front/side 面底部有支撑结构 —— 用
## 支撑色（body dark / shadow tone）而非透明/空。每台机器 front/side 面的
## 最下两行至少含一个不透明像素，且含 shadow/支撑色（不是悬空剪影）。
func _test_v31p2_equipment_leaves_ground() -> void:
	var art = EquipmentArtScript.new()
	var zone_of := {"treadmill": "cardio", "bike": "cardio", "bench_press": "strength"}
	for eq_id in zone_of:
		var raws: Dictionary = art.raw_face_images(eq_id, zone_of[eq_id])
		for fname in ["front", "side"]:
			var img: Image = raws.get(fname)
			if img == null:
				_check(false, "V3.1P2 %s.%s built (leaves ground check)" % [eq_id, fname])
				continue
			var h := img.get_height()
			var bottom_opaque := false
			var bottom_shadow := false
			for y in range(maxi(0, h - 2 * art.ART_SCALE), h):
				for x in img.get_width():
					var c := img.get_pixel(x, y)
					if c.a > 0.5:
						bottom_opaque = true
						if _color_distance(c, PaletteScript.EQUIP_SHADOW_TONE) <= 0.08 \
								or _color_distance(c, PaletteScript.EQUIP_BODY_DARK) <= 0.08:
							bottom_shadow = true
			_check(bottom_opaque,
				"V3.1P2 %s.%s bottom rows have support structure (leaves ground)" % [eq_id, fname])
			_check(bottom_shadow,
				"V3.1P2 %s.%s bottom rows have shadow/support tone (contact at ground)" % [eq_id, fname])


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
