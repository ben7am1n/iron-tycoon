# tests/unit/lighting_layer/lighting_layer_test.gd
# Asset-first smooth lighting: authored warm pools, analytic shafts/vignette,
# deterministic screen emitters, and no scatter/hash generation path.
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"
const LightingLayerScript := preload("res://src/presentation/lighting_layer.gd")
const WorldLayout := preload("res://src/presentation/world_layout.gd")
const PaletteScript := preload("res://src/palette.gd")
const Proj2D := preload("res://src/presentation/oblique_projection.gd")

var _pass := 0
var _fail := 0
var _nodes_to_free: Array = []


func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	var result := run_all()
	quit(1 if int(result["fail"]) > 0 else 0)


func run_all() -> Dictionary:
	print("=".repeat(56))
	print("  UNIT TEST: LightingLayer — asset-first smooth lighting")
	print("=".repeat(56))
	_test_init_and_guard()
	_test_asset_pipeline()
	_test_glow_config_and_colors()
	_test_layout_anchors_and_spacing()
	_test_flicker_determinism()
	_test_lighting_budget()
	_test_smooth_light_map()
	_test_smooth_vignette()
	_test_projected_light_relationship()
	_test_equipment_light_hit_direction()
	_test_cast_shadow_direction()
	_test_scatter_paths_removed()
	_free_test_nodes()
	print("\n=== LIGHTING LAYER TEST: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(condition: bool, message: String) -> void:
	if condition:
		_pass += 1
		print("  PASS: " + message)
	else:
		_fail += 1
		print("  FAIL: " + message)


func _make_layer(tick: int = 0) -> Node2D:
	var layer: Node2D = LightingLayerScript.new()
	layer.init(null, Callable(), func() -> int: return tick)
	_nodes_to_free.append(layer)
	return layer


func _test_init_and_guard() -> void:
	var layer := _make_layer()
	layer.call("init", null, Callable(), Callable())
	_check(true, "double-init is a safe no-op")
	_check(layer.light_map_image() != null, "light map bakes without placed-equipment state")
	_check(layer.projected_light_map_image() != null,
		"projected map bakes without placed-equipment state")


func _test_asset_pipeline() -> void:
	var layer := _make_layer()
	_check(LightingLayerScript.LIGHT_POOL_ASSET_PATH == "res://assets/tiles/light_pool.png",
		"production path points to authored light_pool.png")
	_check(FileAccess.file_exists(LightingLayerScript.LIGHT_POOL_ASSET_PATH),
		"light-pool PNG exists on disk")
	_check(layer.is_using_light_pool_asset(), "lighting layer decoded the authored PNG")
	var source: Image = layer.light_pool_source_image()
	_check(source.get_size() == LightingLayerScript.LIGHT_POOL_ASSET_SIZE,
		"asset is exactly 104x72 and matches hanging-lamp spacing")
	var min_alpha := 1.0
	var max_alpha := 0.0
	var single_hue := true
	var warm: Color = LightingLayerScript.WARM_LIGHT_COLOR
	for y in source.get_height():
		for x in source.get_width():
			var color := source.get_pixel(x, y)
			min_alpha = minf(min_alpha, color.a)
			max_alpha = maxf(max_alpha, color.a)
			if color.a > 0.0 and not _near_rgb(color, warm, 0.012):
				single_hue = false
	_check(min_alpha <= 0.001, "asset edge reaches alpha 0")
	_check(max_alpha >= 0.36 and max_alpha <= 0.39,
		"asset center alpha is restrained (%.3f in 0.36..0.39)" % max_alpha)
	_check(single_hue, "all non-transparent asset pixels use only #F5D97B")
	var cy := source.get_height() / 2
	var center := source.get_pixel(source.get_width() / 2, cy).a
	var middle := source.get_pixel(source.get_width() * 3 / 4, cy).a
	var edge := source.get_pixel(source.get_width() - 1, cy).a
	_check(center > middle and middle > edge,
		"asset alpha falls monotonically center -> middle -> edge")
	_check(absf(source.get_pixel(20, cy).a
		- source.get_pixel(source.get_width() - 21, cy).a) <= 0.005,
		"elliptical falloff is horizontally symmetric")


func _test_glow_config_and_colors() -> void:
	var cfg: Dictionary = LightingLayerScript.EQUIPMENT_GLOWS
	_check(cfg.has("treadmill"), "treadmill screen emitter configured")
	_check(cfg.has("bike"), "bike screen emitter configured")
	_check(cfg["treadmill"]["type"] == LightingLayerScript.GLOW_CYAN,
		"treadmill emitter remains cyan")
	_check(cfg["bike"]["type"] == LightingLayerScript.GLOW_GREEN,
		"bike emitter remains green")
	var layer := _make_layer()
	_check(_near_rgb(layer._glow_color(LightingLayerScript.GLOW_CYAN),
		PaletteScript.EMISSIVE_CYAN, 0.01), "cyan maps to EMISSIVE_CYAN")
	_check(_near_rgb(layer._glow_color(LightingLayerScript.GLOW_GREEN),
		PaletteScript.EMISSIVE_GREEN, 0.01), "green maps to EMISSIVE_GREEN")
	_check(_near_rgb(layer._glow_color(LightingLayerScript.GLOW_WARM),
		LightingLayerScript.WARM_LIGHT_COLOR, 0.01), "warm maps to the pool's single hue")


func _test_layout_anchors_and_spacing() -> void:
	var layer := _make_layer()
	_check(WorldLayout.HANGING_LIGHTS.size() == 3, "exactly three hanging lamps configured")
	_check(WorldLayout.HANGING_LIGHTS.size() == WorldLayout.LIGHT_POOLS.size(),
		"each hanging lamp owns one main pool")
	for i in WorldLayout.HANGING_LIGHTS.size():
		var light: Dictionary = WorldLayout.HANGING_LIGHTS[i]
		var landing: Vector2 = light.get("landing", Vector2.ZERO)
		_check(landing.is_equal_approx(WorldLayout.LIGHT_POOLS[i]),
			"lamp %d landing matches canonical pool anchor" % i)
		_check(Vector2(layer.light_pool_rect(i).get_center()).is_equal_approx(landing),
			"lamp %d PNG destination is centered under its fixture" % i)
	for i in range(WorldLayout.HANGING_LIGHTS.size() - 1):
		var left: Rect2i = layer.light_pool_rect(i)
		var right: Rect2i = layer.light_pool_rect(i + 1)
		_check(left.end.x <= right.position.x,
			"main pools %d/%d do not overlap (gap %dpx)" %
			[i, i + 1, right.position.x - left.end.x])
	_check(WorldLayout.EDGE_SHADOW_WIDTH > 0, "smooth cool vignette width configured")
	_check(str(WorldLayout.FLOOR_LIGHT.get("decor_id", "")) == "warm_lamp_f1",
		"small smooth floor-lamp pool remains linked to its fixture")


func _test_flicker_determinism() -> void:
	var phase_a := 0.5 + 0.5 * sin(7 * 0.25)
	var phase_b := 0.5 + 0.5 * sin(7 * 0.25)
	_check(absf(phase_a - phase_b) < 0.001, "same tick gives identical emitter phase")
	_check(phase_a >= 0.0 and phase_a <= 1.0, "emitter phase stays in [0,1]")
	var moving := false
	for tick in range(8, 40):
		if absf((0.5 + 0.5 * sin(tick * 0.25)) - phase_a) > 0.001:
			moving = true
			break
	_check(moving, "screen emitter breathes across ticks")
	_check(_make_layer(7).light_map_image().get_data()
		== _make_layer(999).light_map_image().get_data(),
		"static pool/vignette map is independent of tick")


func _test_lighting_budget() -> void:
	_check(WorldLayout.LIGHT_POOLS.size() <= 4, "main pool count remains restrained")
	_check(LightingLayerScript.EQUIPMENT_GLOWS.size() <= 8,
		"screen emitter types remain restrained")
	_check(LightingLayerScript.LIGHT_POOL_ASSET_SIZE.x
		< WorldLayout.LIGHT_POOLS[0].distance_to(WorldLayout.LIGHT_POOLS[1]),
		"asset width fits the inter-lamp spacing")


func _test_smooth_light_map() -> void:
	var layer := _make_layer()
	var img: Image = layer.light_map_image()
	_check(img.get_size() == Vector2i(WorldLayout.WORLD_W, WorldLayout.WORLD_H),
		"light map keeps world dimensions")
	var all_centers_warm := true
	var all_edges_clear := true
	var no_interior_holes := true
	var alpha_levels := {}
	var single_pool_hue := true
	for i in WorldLayout.HANGING_LIGHTS.size():
		var rect: Rect2i = layer.light_pool_rect(i)
		var center: Vector2i = rect.get_center()
		var center_color := img.get_pixelv(center)
		all_centers_warm = all_centers_warm \
			and center_color.a > 0.35 \
			and _near_rgb(center_color, LightingLayerScript.WARM_LIGHT_COLOR, 0.012)
		all_edges_clear = all_edges_clear and img.get_pixel(rect.position.x,
			center.y).a < 0.01
		for y in range(rect.position.y, rect.end.y):
			for x in range(rect.position.x, rect.end.x):
				var nx: float = (x + 0.5 - center.x) / (rect.size.x * 0.5)
				var ny: float = (y + 0.5 - center.y) / (rect.size.y * 0.5)
				var radius := Vector2(nx, ny).length()
				var color := img.get_pixel(x, y)
				if radius < 0.72 and color.a <= 0.02:
					no_interior_holes = false
				if radius < 0.95 and color.a > 0.0:
					alpha_levels[roundi(color.a * 255.0)] = true
					if not _near_rgb(color, LightingLayerScript.WARM_LIGHT_COLOR, 0.012):
						single_pool_hue = false
	_check(all_centers_warm, "all three centers are clean warm-yellow maxima")
	_check(all_edges_clear, "all three ellipse edges fade to transparent")
	_check(no_interior_holes, "inner 72% of every pool is continuous with no scatter holes")
	_check(alpha_levels.size() >= 60,
		"pool uses a smooth alpha ramp (%d distinct levels)" % alpha_levels.size())
	_check(single_pool_hue, "main pools contain no yellow/white color mixing")
	var rect: Rect2i = layer.light_pool_rect(1)
	var y: int = rect.get_center().y
	var a0 := img.get_pixel(rect.get_center().x, y).a
	var a1 := img.get_pixel(rect.get_center().x + rect.size.x / 4, y).a
	var a2 := img.get_pixel(rect.get_center().x + rect.size.x * 2 / 5, y).a
	_check(a0 > a1 and a1 > a2 and a2 > 0.0,
		"baked pool falls smoothly from center toward edge")
	var second: Image = _make_layer().light_map_image()
	_check(img.get_data() == second.get_data(), "light map rebakes bit-identically")


func _test_smooth_vignette() -> void:
	var img: Image = _make_layer().light_map_image()
	var y := 100
	var a0 := img.get_pixel(0, y).a
	var a6 := img.get_pixel(6, y).a
	var a13 := img.get_pixel(13, y).a
	var a20 := img.get_pixel(20, y).a
	var a25 := img.get_pixel(25, y).a
	_check(a0 > a6 and a6 > a13 and a13 > a20 and a20 > a25,
		"cool edge alpha decreases smoothly inward")
	_check(a0 <= LightingLayerScript.VIGNETTE_MAX_ALPHA + 0.005,
		"vignette alpha remains restrained")
	_check(img.get_pixel(40, y).a <= 0.001, "vignette reaches transparent interior")
	_check(img.get_pixel(6, y).b > img.get_pixel(6, y).r,
		"edge vignette remains cool blue-gray")
	_check(img.get_pixel(6, y) == img.get_pixel(img.get_width() - 7, y),
		"left/right vignette falloff is symmetric")


func _test_projected_light_relationship() -> void:
	var layer := _make_layer()
	var img: Image = layer.projected_light_map_image()
	var origin: Vector2 = layer.projected_light_map_origin()
	_check(img.get_width() > 400 and img.get_height() > 200,
		"projected map covers the full diorama")
	for i in WorldLayout.HANGING_LIGHTS.size():
		var light: Dictionary = WorldLayout.HANGING_LIGHTS[i]
		var rect: Rect2i = light.get("rect", Rect2i())
		var source := Proj2D.proj(rect.position.x, rect.position.y,
			float(light.get("height", 0.0))) \
			+ (light.get("bulb_local", Vector2.ZERO) as Vector2)
		var landing := Proj2D.project_world(light.get("landing", Vector2.ZERO))
		_check(_warm_near(img, source - origin, 5) > 0,
			"lamp %d smooth warm source exists" % i)
		_check(_warm_near(img, source.lerp(landing, 0.5) - origin, 8) > 0,
			"lamp %d smooth shaft reaches its midpoint" % i)
		_check(_warm_near(img, source.lerp(landing, 0.88) - origin, 10) > 0,
			"lamp %d smooth shaft reaches its pool" % i)
	var levels := {}
	var single_hue := true
	for y in range(0, img.get_height(), 2):
		for x in range(0, img.get_width(), 2):
			var color := img.get_pixel(x, y)
			if color.a > 0.0:
				levels[roundi(color.a * 255.0)] = true
				if not _near_rgb(color, LightingLayerScript.WARM_LIGHT_COLOR, 0.012):
					single_hue = false
	_check(levels.size() >= 20, "projected shafts use a smooth alpha ramp")
	_check(single_hue, "projected shafts use the same single warm hue")
	_check(img.get_data() == _make_layer().projected_light_map_image().get_data(),
		"projected source/shaft map is deterministic")


func _test_equipment_light_hit_direction() -> void:
	var layer := _make_layer()
	var left_hit: Dictionary = layer._equipment_light_hit_canvas(
		Rect2i(32, 160, 32, 32), "bike")
	var right_hit: Dictionary = layer._equipment_light_hit_canvas(
		Rect2i(352, 160, 32, 32), "bike")
	_check(bool(left_hit.get("lit", false)) and bool(right_hit.get("lit", false)),
		"equipment under sources receives a one-pixel light edge")
	_check((left_hit.get("point", Vector2.ZERO) as Vector2).x
		!= (right_hit.get("point", Vector2.ZERO) as Vector2).x,
		"equipment edge position follows nearest source")


func _test_cast_shadow_direction() -> void:
	var a := WorldLayout.cast_shadow_offset(Vector2(96, 80), 30.0)
	var b := WorldLayout.cast_shadow_offset(Vector2(96, 80), 30.0)
	_check(a.is_equal_approx(b), "cast-shadow direction remains deterministic")
	var treadmill := WorldLayout.cast_shadow_offset(Vector2(96, 80), 30.0)
	var bike := WorldLayout.cast_shadow_offset(Vector2(80, 176), 36.0)
	var yoga := WorldLayout.cast_shadow_offset(Vector2(304, 80), 6.0)
	_check(treadmill.y > 4.0 and bike.y > 4.0 and yoga.y > 4.0,
		"all equipment shadows still cast south")
	_check(bike.length() > treadmill.length(), "taller equipment casts a longer shadow")
	_check(yoga.length() < treadmill.length(), "low equipment casts a shorter shadow")
	_check(bike.length() < 60.0, "cast-shadow length remains bounded")


func _test_scatter_paths_removed() -> void:
	var layer := _make_layer()
	for method in [
		"_hash2",
		"_paint_faceted_pool",
		"_paint_pool_fade",
		"_paint_ambient_cool_falloff",
		"_paint_foreground_warm",
		"_paint_glow_cluster",
		"_draw_top_face_band",
		"_draw_screen_cluster",
	]:
		_check(not layer.has_method(method), "%s scatter path is absent" % method)
	_check(layer.has_method("_draw_screen_emitter"),
		"small deterministic screen-emitter path remains")
	_check(layer.has_method("_draw_equipment_light_edges"),
		"single-pixel equipment light-edge path remains")


func _warm_near(img: Image, point: Vector2, radius: int) -> int:
	var found := 0
	for y in range(maxi(int(point.y) - radius, 0),
			mini(int(point.y) + radius + 1, img.get_height())):
		for x in range(maxi(int(point.x) - radius, 0),
				mini(int(point.x) + radius + 1, img.get_width())):
			var color := img.get_pixel(x, y)
			if color.a > 0.04 and _near_rgb(color,
					LightingLayerScript.WARM_LIGHT_COLOR, 0.012):
				found += 1
	return found


func _near_rgb(a: Color, b: Color, tolerance: float) -> bool:
	var dr := a.r - b.r
	var dg := a.g - b.g
	var db := a.b - b.b
	return sqrt(dr * dr + dg * dg + db * db) <= tolerance


func _free_test_nodes() -> void:
	for node in _nodes_to_free:
		if is_instance_valid(node):
			node.queue_free()
