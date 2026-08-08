# tests/unit/environment_art/environment_art_test.gd
# Phase 5 — EnvironmentArt（V3 §12 环境装饰精灵工厂）单元测试
#
# 验证 src/presentation/environment_art.gd：
#   - art map 结构合法（等宽行、已知图例字符）
#   - 纹理尺寸 = art px × ART_SCALE
#   - 语义色正确（单一色源 palette；植物绿、陶盆、accent、金属、暖黑）
#   - 无纯黑/纯白像素（25d §3）
#   - decor 实例后缀解析（"water_bottle_t1"→"water_bottle"、"plant_fore_1"→"plant"）
#   - 未知 prop_id 返回 null（兜底不崩溃）
#   - 缓存：同 prop_id 返回同一纹理
#   - V3 §12 必需元素齐全（水瓶/毛巾/配重/植物/音箱/卷垫/风扇/水杯架/饮水机/
#     垃圾桶/消防栓/招牌/计时器 —— 场景 storytelling 素材单）
#
# Run standalone: godot --headless --script tests/unit/environment_art/environment_art_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const EnvironmentArtScript := preload("res://src/presentation/environment_art.gd")
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
	print("  UNIT TEST: EnvironmentArt — V3 §12 场景 storytelling 精灵")
	print("=".repeat(48))

	_test_map_structure()
	_test_texture_sizes()
	_test_semantic_colors()
	_test_no_pure_black_white()
	_test_decor_suffix_resolution()
	_test_unknown_returns_null()
	_test_cache()
	_test_storytelling_budget()

	print("\n=== ENVIRONMENT ART TEST: %d passed, %d failed ===\n" % [_pass, _fail])
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
	var art = EnvironmentArtScript.new()
	for prop_id in EnvironmentArtScript.ART_MAPS:
		var rows: Array = EnvironmentArtScript.ART_MAPS[prop_id]
		_check(rows.size() > 0, "%s has rows" % prop_id)
		if rows.is_empty():
			continue
		var width := String(rows[0]).length()
		var all_equal := true
		for row in rows:
			if String(row).length() != width:
				all_equal = false
		_check(all_equal, "%s rows are equal width (%d)" % [prop_id, width])


# === 2. 纹理尺寸 ===

func _test_texture_sizes() -> void:
	var art = EnvironmentArtScript.new()
	for prop_id in EnvironmentArtScript.ART_MAPS:
		var tex := art.texture_for(prop_id)
		_check(tex != null, "%s texture built" % prop_id)
		if tex == null:
			continue
		var size: Vector2i = art.texture_size(prop_id)
		var art_size: Vector2i = art.art_size(prop_id)
		_check(size == art_size * art.ART_SCALE, "%s texture size = art × scale" % prop_id)


# === 3. 语义色（单一色源 palette） ===

func _test_semantic_colors() -> void:
	var art = EnvironmentArtScript.new()
	var checks := {
		"plant": PaletteScript.PLANT_GREEN,
		"water_bottle": PaletteScript.ACCENT_YELLOW,
		"speaker": PaletteScript.METAL_HIGHLIGHT,
		"fountain": PaletteScript.ACCENT_CYAN,
		"hydrant": PaletteScript.ACCENT_ORANGE,
		"trash": PaletteScript.WALL_DARK,
		"sign_entrance": PaletteScript.ACCENT_YELLOW,
	}
	for prop_id in checks:
		var tex := art.texture_for(prop_id)
		var img := tex.get_image()
		_check(_image_contains(img, checks[prop_id], 0.05),
			"%s contains %s" % [prop_id, (checks[prop_id] as Color).to_html(false)])


# === 4. 无纯黑/纯白（25d §3） ===

func _test_no_pure_black_white() -> void:
	var art = EnvironmentArtScript.new()
	for prop_id in EnvironmentArtScript.ART_MAPS:
		var img := art.texture_for(prop_id).get_image()
		_check(not _image_contains(img, Color.BLACK, 0.02), "%s has NO pure black" % prop_id)
		_check(not _image_contains(img, Color.WHITE, 0.02), "%s has NO pure white" % prop_id)


# === 5. decor 实例后缀解析 ===

func _test_decor_suffix_resolution() -> void:
	var art = EnvironmentArtScript.new()
	var resolved := {
		"water_bottle_t1": "water_bottle",
		"dumbbell_s1": "dumbbell",
		"dumbbell_s2": "dumbbell",
		"plant_f1": "plant",
		"plant_fore_1": "plant",
		"plant_fore_2": "plant",
		"fan_b1": "fan",
		"cup_holder_b1": "cup_holder",
	}
	for key in resolved:
		var tex := art.texture_for(key)
		_check(tex != null, "decor '%s' resolves to texture (base %s)" % [key, resolved[key]])
		# 同基键同纹理（缓存共享语义，不强制同一实例 —— 只要求都能建出）
		var base_tex := art.texture_for(resolved[key])
		_check(tex.get_size() == base_tex.get_size(), "decor '%s' size matches base '%s'" % [key, resolved[key]])
		# 回归（Phase 5 实测）：suffixed id 的 texture_size / art_size 必须解析
		# 基键 —— 否则绘制层 draw_texture_rect 用 (0,0) 尺寸画出空精灵。
		var ts := art.texture_size(key)
		_check(ts == Vector2i(base_tex.get_size()), "decor '%s' texture_size resolves base (%s)" % [key, ts])
		var asize := art.art_size(key)
		_check(asize == art.art_size(resolved[key]), "decor '%s' art_size resolves base (%s)" % [key, asize])


# === 6. 未知 id ===

func _test_unknown_returns_null() -> void:
	var art = EnvironmentArtScript.new()
	_check(art.texture_for("nonexistent_prop") == null, "unknown prop returns null (no crash)")
	_check(art.art_size("nope") == Vector2i.ZERO, "unknown art_size returns ZERO")


# === 7. 缓存 ===

func _test_cache() -> void:
	var art = EnvironmentArtScript.new()
	var a := art.texture_for("plant")
	var b := art.texture_for("plant")
	_check(a == b, "same prop returns cached texture")


# === 8. V3 §12 必需元素单 ===

func _test_storytelling_budget() -> void:
	var art = EnvironmentArtScript.new()
	var required := [
		"water_bottle", "towel", "poster_run", "dumbbell", "chalk_box",
		"plant", "speaker", "mat_rolled", "fan", "cup_holder",
		"fountain", "trash", "hydrant", "timer_bike", "sign_entrance", "tv",
	]
	for prop_id in required:
		_check(EnvironmentArtScript.ART_MAPS.has(prop_id),
			"V3 §12 storytelling prop '%s' exists" % prop_id)
		_check(art.texture_for(prop_id) != null, "V3 §12 prop '%s' texture builds" % prop_id)


# === helpers ===

func _image_contains(img: Image, color: Color, tol: float) -> bool:
	for y in img.get_height():
		for x in img.get_width():
			var p := img.get_pixel(x, y)
			if p.a > 0.5 and _color_distance(p, color) <= tol:
				return true
	return false


func _color_distance(a: Color, b: Color) -> float:
	var dr := a.r - b.r
	var dg := a.g - b.g
	var db := a.b - b.b
	return sqrt(dr * dr + dg * dg + db * db)
