# tests/unit/floor_art/floor_art_test.gd
# Asset-first floor tile composition: mapping, loading, clean detail budgets,
# semantic zone placement, repeat alignment, deterministic fallback, and cache.
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"
const FloorArtScript := preload("res://src/presentation/floor_art.gd")

const GRID_W := 13
const GRID_H := 10
const CELL := 32

const EXPECTED_PATHS := {
	"strength": "res://assets/tiles/floor_strength.png",
	"cardio": "res://assets/tiles/floor_cardio.png",
	"flex": "res://assets/tiles/floor_flex.png",
	"walkway": "res://assets/tiles/floor_walkway.png",
}

var _pass := 0
var _fail := 0


func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	var result := run_all()
	quit(1 if int(result["fail"]) > 0 else 0)


func run_all() -> Dictionary:
	print("=".repeat(56))
	print("  UNIT TEST: FloorArt — clean asset-first tile pipeline")
	print("=".repeat(56))
	_test_asset_mapping_and_load()
	_test_asset_detail_budget()
	_test_image_size_and_zone_semantics()
	_test_tile_repeat_alignment()
	_test_noise_generators_removed()
	_test_missing_assets_fall_back_cleanly()
	_test_determinism_and_cache()
	print("\n=== FLOOR ART TEST: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(condition: bool, message: String) -> void:
	if condition:
		_pass += 1
		print("  PASS: " + message)
	else:
		_fail += 1
		print("  FAIL: " + message)


func _make_art():
	var art = FloorArtScript.new()
	art.init(GRID_W, GRID_H, CELL)
	return art


func _test_asset_mapping_and_load() -> void:
	var art = _make_art()
	for material in EXPECTED_PATHS:
		_check(art.asset_path_for(material) == EXPECTED_PATHS[material],
			"%s maps to %s" % [material, EXPECTED_PATHS[material]])
		_check(art.is_using_asset(material), "%s loads authored PNG" % material)
		_check(art.tile_size(material) == Vector2i(32, 32),
			"%s tile is native 32x32" % material)


func _test_asset_detail_budget() -> void:
	for material in EXPECTED_PATHS:
		var img := Image.new()
		var err := img.load(EXPECTED_PATHS[material])
		_check(err == OK, "%s raw PNG decodes" % material)
		if err != OK:
			continue
		var counts: Dictionary = {}
		var opaque := true
		for y in img.get_height():
			for x in img.get_width():
				var c := img.get_pixel(x, y)
				opaque = opaque and is_equal_approx(c.a, 1.0)
				var key := c.to_html(false)
				counts[key] = int(counts.get(key, 0)) + 1
		var dominant := 0
		for key in counts:
			dominant = maxi(dominant, int(counts[key]))
		var details := img.get_width() * img.get_height() - dominant
		var ratio := float(details) / float(img.get_width() * img.get_height())
		_check(ratio <= 0.15,
			"%s detail %.1f%% <= 15%%" % [material, ratio * 100.0])
		_check(opaque, "%s contains only opaque authored pixels" % material)


func _test_image_size_and_zone_semantics() -> void:
	var img: Image = _make_art().build_image()
	_check(img.get_size() == Vector2i(GRID_W * CELL, GRID_H * CELL),
		"composed image is 416x320")
	var strength := img.get_pixel(96, 160)
	var cardio := img.get_pixel(224, 160)
	var flex := img.get_pixel(336, 160)
	var walkway := img.get_pixel(110, 12)
	_check(_lum(strength) < 0.40, "strength reads as dark rubber")
	_check(_lum(cardio) > _lum(strength) + 0.15,
		"cardio warm gray separates from strength")
	_check(flex.r > flex.b + 0.10 and flex.r > flex.g,
		"flex reads as warm wood")
	_check(_lum(walkway) > _lum(cardio) + 0.10,
		"walkway is the lightest floor material")
	_check(_color_distance(strength, cardio) > 0.18 \
		and _color_distance(cardio, flex) > 0.12,
		"zone centers remain immediately distinguishable")


func _test_tile_repeat_alignment() -> void:
	var img: Image = _make_art().build_image()
	var samples := {
		"strength": Vector2i(37, 37),
		"cardio": Vector2i(165, 37),
		"flex": Vector2i(293, 37),
		"walkway": Vector2i(5, 5),
	}
	for material in samples:
		var p: Vector2i = samples[material]
		var base := img.get_pixelv(p)
		_check(base == img.get_pixelv(p + Vector2i(32, 0)),
			"%s repeats exactly every 32px on x" % material)
		# Walkway's top band is only one cell high, so verify y repetition in the
		# unobstructed right walkway column instead.
		if material == "walkway":
			p = Vector2i(389, 37)
			base = img.get_pixelv(p)
		_check(base == img.get_pixelv(p + Vector2i(0, 32)),
			"%s repeats exactly every 32px on y" % material)


func _test_noise_generators_removed() -> void:
	var art = _make_art()
	for method in [
		"_paint_cluster_zone",
		"_paint_stroke",
		"_paint_blob",
		"_draw_wear",
		"_wear_path",
		"_bite_zone_edges",
		"_draw_transition_bands",
	]:
		_check(not art.has_method(method), "%s program-noise path is absent" % method)


func _test_missing_assets_fall_back_cleanly() -> void:
	var missing := {
		"strength": "res://assets/tiles/missing-strength.png",
		"cardio": "res://assets/tiles/missing-cardio.png",
		"flex": "res://assets/tiles/missing-flex.png",
		"walkway": "res://assets/tiles/missing-walkway.png",
	}
	var art = FloorArtScript.new(true, missing)
	art.init(GRID_W, GRID_H, CELL)
	for material in missing:
		_check(not art.is_using_asset(material),
			"missing %s PNG selects programmatic fallback" % material)
		_check(art.tile_size(material) == Vector2i(32, 32),
			"%s fallback remains 32x32" % material)
	var img: Image = art.build_image()
	_check(_lum(img.get_pixel(96, 160)) < 0.45,
		"fallback strength keeps dark-rubber semantics")
	_check(_lum(img.get_pixel(110, 12)) > 0.60,
		"fallback walkway keeps light-tile semantics")


func _test_determinism_and_cache() -> void:
	var art = _make_art()
	var a: Image = art.build_image()
	var b: Image = art.build_image()
	_check(a.get_data() == b.get_data(), "two builds are bit-identical")
	var t1: ImageTexture = art.texture()
	var t2: ImageTexture = art.texture()
	_check(t1 == t2, "texture() reuses the composed ImageTexture")
	_check(t1.get_size() == Vector2(GRID_W * CELL, GRID_H * CELL),
		"cached texture keeps world size")


func _lum(c: Color) -> float:
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b


func _color_distance(a: Color, b: Color) -> float:
	return sqrt(pow(a.r - b.r, 2) + pow(a.g - b.g, 2) + pow(a.b - b.b, 2))
