# src/presentation/lighting_layer.gd — clean asset-first lighting
# Three authored warm-yellow pools, smooth shafts/vignette, one-pixel equipment
# light edges, and tiny screen emitters. No hash/RNG texture synthesis.
class_name LightingLayer extends Node2D

const Palette := preload("res://src/palette.gd")
const WorldLayout := preload("res://src/presentation/world_layout.gd")
const Proj2D := preload("res://src/presentation/oblique_projection.gd")
const EquipmentArt := preload("res://src/presentation/equipment_art.gd")

const LIGHT_POOL_ASSET_PATH := "res://assets/tiles/light_pool.png"
const LIGHT_POOL_ASSET_SIZE := Vector2i(104, 72)
const WARM_LIGHT_COLOR := Color("F5D97B")
const COOL_VIGNETTE_COLOR := Color("263550")
const VIGNETTE_MAX_ALPHA := 0.16

const GLOW_CYAN := "cyan"
const GLOW_GREEN := "green"
const GLOW_WARM := "warm"
const SCREEN_CORE_PX := 2

const EQUIPMENT_GLOWS := {
	"treadmill": {"type": GLOW_CYAN, "offset": Vector2(12, 4)},
	"bike": {"type": GLOW_GREEN, "offset": Vector2(6, 8)},
}

var _grid = null
var _resolver: Callable = Callable()
var _tick_provider: Callable = Callable()
var _initialized := false

var _light_pool_asset: Image = null
var _light_pool_lookup_done := false
var _light_map: ImageTexture = null
var _light_map_image: Image = null
var _projected_light_map: ImageTexture = null
var _projected_light_map_image: Image = null
var _projected_light_origin := Vector2.ZERO

## Inject placed-equipment state, equipment-id resolver, and deterministic tick source.
func init(grid, resolver: Callable, tick_provider: Callable) -> void:
	if _initialized:
		push_error("LightingLayer.init(): called twice")
		return
	_initialized = true
	_grid = grid
	_resolver = resolver
	_tick_provider = tick_provider

func _draw() -> void:
	if _light_map == null:
		_bake_light_map()
	draw_set_transform_matrix(Proj2D.floor_transform())
	draw_texture_rect(_light_map,
		Rect2(Vector2.ZERO, Vector2(WorldLayout.WORLD_W, WorldLayout.WORLD_H)), false)
	draw_set_transform_matrix(Transform2D.IDENTITY)
	if _projected_light_map == null:
		_bake_projected_light_map()
	draw_texture_rect(_projected_light_map,
		Rect2(_projected_light_origin, Vector2(_projected_light_map_image.get_size())), false)
	_draw_equipment_light_edges()
	_draw_equipment_glows()

## Return the deterministic world-space light map, baking it on first use.
func light_map_image() -> Image:
	if _light_map_image == null:
		_bake_light_map()
	return _light_map_image

## Return the deterministic projected lamp-shaft map, baking it on first use.
func projected_light_map_image() -> Image:
	if _projected_light_map_image == null:
		_bake_projected_light_map()
	return _projected_light_map_image

## Return the canvas-space origin of projected_light_map_image().
func projected_light_map_origin() -> Vector2:
	if _projected_light_map_image == null:
		_bake_projected_light_map()
	return _projected_light_origin

## Return true when the authored PNG decoded successfully instead of using fallback.
func is_using_light_pool_asset() -> bool:
	_load_light_pool_asset()
	return _light_pool_asset != null

## Return a copy of the authored/fallback pool image for asset-focused tests.
func light_pool_source_image() -> Image:
	var source := _pool_source()
	return source.duplicate()

## Return the world-space destination rect for one hanging lamp's pool.
func light_pool_rect(index: int) -> Rect2i:
	if index < 0 or index >= WorldLayout.HANGING_LIGHTS.size():
		return Rect2i()
	var light: Dictionary = WorldLayout.HANGING_LIGHTS[index]
	var center: Vector2 = light.get("landing", Vector2.ZERO)
	var half: Vector2 = light.get("pool_half", Vector2(52, 36))
	return Rect2i(
		Vector2i(roundi(center.x - half.x), roundi(center.y - half.y)),
		Vector2i(roundi(half.x * 2.0), roundi(half.y * 2.0)))

func _bake_light_map() -> void:
	var img := Image.create(WorldLayout.WORLD_W, WorldLayout.WORLD_H, false,
		Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	_paint_smooth_vignette(img)
	for i in WorldLayout.HANGING_LIGHTS.size():
		_paint_scaled_pool(img, light_pool_rect(i))
	var floor_light: Dictionary = WorldLayout.FLOOR_LIGHT
	var floor_center: Vector2 = floor_light.get("landing", Vector2.ZERO)
	var floor_half: Vector2 = floor_light.get("pool_half", Vector2(24, 17))
	_paint_scaled_pool(img, Rect2i(
		Vector2i(roundi(floor_center.x - floor_half.x),
			roundi(floor_center.y - floor_half.y)),
		Vector2i(roundi(floor_half.x * 2.0), roundi(floor_half.y * 2.0))), 0.62)
	_light_map_image = img
	_light_map = ImageTexture.create_from_image(img)

func _paint_smooth_vignette(img: Image) -> void:
	var width := float(WorldLayout.EDGE_SHADOW_WIDTH)
	for y in img.get_height():
		for x in img.get_width():
			var edge_distance := minf(minf(x + 0.5, y + 0.5),
				minf(img.get_width() - x - 0.5, img.get_height() - y - 0.5))
			if edge_distance >= width:
				continue
			var edge_t := 1.0 - edge_distance / width
			var alpha := VIGNETTE_MAX_ALPHA * _smoothstep01(edge_t)
			img.set_pixel(x, y, Color(COOL_VIGNETTE_COLOR.r,
				COOL_VIGNETTE_COLOR.g, COOL_VIGNETTE_COLOR.b, alpha))

func _paint_scaled_pool(img: Image, destination: Rect2i, strength: float = 1.0) -> void:
	var source := _pool_source()
	var clipped := destination.intersection(Rect2i(Vector2i.ZERO, img.get_size()))
	if source.is_empty() or clipped.size.x <= 0 or clipped.size.y <= 0:
		return
	for y in range(clipped.position.y, clipped.end.y):
		var v := (y + 0.5 - destination.position.y) / float(destination.size.y)
		var sy := clampi(int(floor(v * source.get_height())), 0, source.get_height() - 1)
		for x in range(clipped.position.x, clipped.end.x):
			var u := (x + 0.5 - destination.position.x) / float(destination.size.x)
			var sx := clampi(int(floor(u * source.get_width())), 0, source.get_width() - 1)
			var color := source.get_pixel(sx, sy)
			color.a *= strength
			# The pool is a single-hue lighting surface, not a mix with the cool
			# vignette beneath it. Transparent pixels leave the vignette untouched.
			if color.a > 0.0:
				img.set_pixel(x, y, color)

func _load_light_pool_asset() -> void:
	if _light_pool_lookup_done:
		return
	_light_pool_lookup_done = true
	if ResourceLoader.exists(LIGHT_POOL_ASSET_PATH, "Texture2D"):
		var resource := ResourceLoader.load(LIGHT_POOL_ASSET_PATH, "Texture2D")
		if resource is Texture2D:
			var imported := (resource as Texture2D).get_image()
			if imported != null and not imported.is_empty():
				_light_pool_asset = imported
				return
	if not FileAccess.file_exists(LIGHT_POOL_ASSET_PATH):
		return
	var raw := Image.new()
	if raw.load(LIGHT_POOL_ASSET_PATH) == OK and not raw.is_empty():
		_light_pool_asset = raw

func _pool_source() -> Image:
	_load_light_pool_asset()
	if _light_pool_asset != null:
		return _light_pool_asset
	return _build_smooth_pool_fallback()

func _build_smooth_pool_fallback() -> Image:
	var size := LIGHT_POOL_ASSET_SIZE
	var img := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	var center := Vector2(size) * 0.5
	var radius := Vector2(size) * 0.5
	for y in size.y:
		for x in size.x:
			var n := Vector2((x + 0.5 - center.x) / radius.x,
				(y + 0.5 - center.y) / radius.y)
			var distance := n.length()
			var alpha := 0.0
			if distance < 1.0:
				alpha = (96.0 / 255.0) * (1.0 - _smoothstep01(distance))
			img.set_pixel(x, y, Color(WARM_LIGHT_COLOR.r,
				WARM_LIGHT_COLOR.g, WARM_LIGHT_COLOR.b, alpha))
	return img

func _bake_projected_light_map() -> void:
	var bounds := Proj2D.bounds()
	_projected_light_origin = Vector2(floor(bounds.position.x), floor(bounds.position.y))
	var end := Vector2(ceil(bounds.end.x), ceil(bounds.end.y))
	var size := Vector2i(int(end.x - _projected_light_origin.x),
		int(end.y - _projected_light_origin.y))
	var img := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for light: Dictionary in WorldLayout.HANGING_LIGHTS:
		var rect: Rect2i = light.get("rect", Rect2i())
		var source := Proj2D.proj(rect.position.x, rect.position.y,
			float(light.get("height", 78.0))) \
			+ (light.get("bulb_local", Vector2.ZERO) as Vector2)
		var landing := Proj2D.project_world(light.get("landing", Vector2.ZERO))
		_paint_smooth_shaft(img, source, landing, 2.0, 15.0)
		_paint_smooth_source(img, source)
	var floor_cfg: Dictionary = WorldLayout.FLOOR_LIGHT
	var base: Vector2 = floor_cfg.get("base", Vector2.ZERO)
	var floor_source := Proj2D.proj(base.x, base.y,
		float(floor_cfg.get("height", 48.0))) \
		+ (floor_cfg.get("bulb_local", Vector2.ZERO) as Vector2)
	var floor_landing := Proj2D.project_world(floor_cfg.get("landing", base))
	_paint_smooth_shaft(img, floor_source, floor_landing, 1.5, 7.0, 0.65)
	_paint_smooth_source(img, floor_source, 0.75)
	_projected_light_map_image = img
	_projected_light_map = ImageTexture.create_from_image(img)

func _paint_smooth_shaft(img: Image, source_canvas: Vector2,
		landing_canvas: Vector2, top_half: float, bottom_half: float,
		strength: float = 1.0) -> void:
	var source := source_canvas - _projected_light_origin
	var landing := landing_canvas - _projected_light_origin
	var axis := landing - source
	var length := axis.length()
	if length < 1.0:
		return
	var direction := axis / length
	var normal := Vector2(-direction.y, direction.x)
	var margin := bottom_half + 2.0
	var min_x := maxi(int(floor(minf(source.x, landing.x) - margin)), 0)
	var max_x := mini(int(ceil(maxf(source.x, landing.x) + margin)), img.get_width())
	var min_y := maxi(int(floor(minf(source.y, landing.y) - margin)), 0)
	var max_y := mini(int(ceil(maxf(source.y, landing.y) + margin)), img.get_height())
	for y in range(min_y, max_y):
		for x in range(min_x, max_x):
			var rel := Vector2(x + 0.5, y + 0.5) - source
			var along := rel.dot(direction)
			if along < 0.0 or along > length:
				continue
			var t := along / length
			var half_width := lerpf(top_half, bottom_half, t)
			var lateral := absf(rel.dot(normal))
			if lateral >= half_width:
				continue
			var cross_fade := 1.0 - _smoothstep01(lateral / half_width)
			var end_fade := 0.45 + 0.55 * sin(PI * t)
			var alpha := (0.035 + 0.105 * cross_fade) * end_fade * strength
			_blend_pixel(img, Vector2i(x, y), Color(WARM_LIGHT_COLOR.r,
				WARM_LIGHT_COLOR.g, WARM_LIGHT_COLOR.b, alpha))

func _paint_smooth_source(img: Image, source_canvas: Vector2,
		strength: float = 1.0) -> void:
	var center := source_canvas - _projected_light_origin
	for dy in range(-2, 3):
		for dx in range(-3, 4):
			var distance := Vector2(dx / 3.0, dy / 2.0).length()
			if distance > 1.0:
				continue
			var alpha := lerpf(0.22, 0.72, 1.0 - _smoothstep01(distance)) * strength
			_blend_pixel(img, Vector2i(roundi(center.x) + dx,
				roundi(center.y) + dy), Color(WARM_LIGHT_COLOR.r,
				WARM_LIGHT_COLOR.g, WARM_LIGHT_COLOR.b, alpha))

func _draw_equipment_light_edges() -> void:
	if _grid == null:
		return
	for inst in _grid.get_placed_instances():
		var fp := _footprint_rect(inst.footprint_cells)
		if fp.size.x <= 0 or fp.size.y <= 0:
			continue
		var eq_id := ""
		if _resolver.is_valid():
			eq_id = str(_resolver.call(inst.instance_id))
		var hit := _equipment_light_hit_canvas(fp, eq_id)
		if not bool(hit.get("lit", false)):
			continue
		var toward: Vector2 = hit.get("toward", Vector2(0, -1))
		var center := Vector2(fp.position) + Vector2(fp.size) * 0.5
		var depth := minf(fp.size.x, fp.size.y) * 0.46
		var edge_center := center + toward * depth
		var perpendicular := Vector2(-toward.y, toward.x)
		var half_length := maxf(fp.size.x, fp.size.y) * 0.32
		var color := WARM_LIGHT_COLOR
		color.a = 0.16 + 0.12 * float(hit.get("strength", 0.0))
		draw_set_transform_matrix(_top_face_transform(_equipment_height_for_id(eq_id)))
		draw_line(edge_center - perpendicular * half_length,
			edge_center + perpendicular * half_length, color, 1.0, false)
		draw_set_transform_matrix(Transform2D.IDENTITY)

## Calculate the nearest local light edge for deterministic tests and rendering.
func _equipment_light_hit_canvas(fp: Rect2i, eq_id: String) -> Dictionary:
	var center := Vector2(fp.position) + Vector2(fp.size) * 0.5
	var nearest := Vector2.ZERO
	var nearest_distance := INF
	for light: Dictionary in WorldLayout.HANGING_LIGHTS:
		var landing: Vector2 = light.get("landing", Vector2.ZERO)
		var distance := center.distance_to(landing)
		if distance < nearest_distance:
			nearest_distance = distance
			nearest = landing
	var floor_landing: Vector2 = WorldLayout.FLOOR_LIGHT.get("landing", Vector2.ZERO)
	var floor_distance := center.distance_to(floor_landing)
	if floor_distance < nearest_distance:
		nearest_distance = floor_distance
		nearest = floor_landing
	if nearest_distance > 112.0:
		return {"lit": false, "point": Vector2.ZERO, "strength": 0.0,
			"toward": Vector2(0, -1)}
	var toward := (nearest - center).normalized()
	if toward.length_squared() < 0.001:
		toward = Vector2(0, -1)
	var hit_world := center + toward * minf(fp.size.x, fp.size.y) * 0.24
	return {
		"lit": true,
		"point": Proj2D.proj(hit_world.x, hit_world.y, _equipment_height_for_id(eq_id) + 1.0),
		"strength": clampf(1.0 - nearest_distance / 112.0, 0.0, 1.0),
		"toward": toward,
	}

func _draw_equipment_glows() -> void:
	if _grid == null:
		return
	var tick := 0
	if _tick_provider.is_valid():
		tick = int(_tick_provider.call())
	var phase := 0.5 + 0.5 * sin(tick * 0.25)
	for inst in _grid.get_placed_instances():
		var eq_id := ""
		if _resolver.is_valid():
			eq_id = str(_resolver.call(inst.instance_id))
		if not EQUIPMENT_GLOWS.has(eq_id):
			continue
		var cfg: Dictionary = EQUIPMENT_GLOWS[eq_id]
		var fp := _footprint_rect(inst.footprint_cells)
		var world_pos := Vector2(fp.position) + (cfg["offset"] as Vector2)
		var pos := Proj2D.proj(world_pos.x, world_pos.y,
			_equipment_height_for_id(eq_id) + 1.0)
		_draw_screen_emitter(Vector2(roundf(pos.x), roundf(pos.y)),
			cfg["type"] as String, phase)

func _draw_screen_emitter(pos: Vector2, glow_type: String, phase: float) -> void:
	var core := _glow_color(glow_type)
	core.a = 0.38 + 0.22 * phase
	draw_rect(Rect2(pos, Vector2(SCREEN_CORE_PX, SCREEN_CORE_PX)), core, true)
	var edge := _glow_color(glow_type)
	edge.a = 0.10 + 0.06 * phase
	draw_rect(Rect2(pos + Vector2(-1, 0), Vector2.ONE), edge, true)
	draw_rect(Rect2(pos + Vector2(2, 1), Vector2.ONE), edge, true)

func _glow_color(glow_type: String) -> Color:
	match glow_type:
		GLOW_GREEN:
			return Palette.EMISSIVE_GREEN
		GLOW_WARM:
			return WARM_LIGHT_COLOR
		_:
			return Palette.EMISSIVE_CYAN

func _footprint_rect(cells: Array) -> Rect2i:
	if cells.is_empty():
		return Rect2i()
	var min_cell := Vector2i(cells[0])
	var max_cell := Vector2i(cells[0])
	for cell in cells:
		min_cell.x = mini(min_cell.x, cell.x)
		min_cell.y = mini(min_cell.y, cell.y)
		max_cell.x = maxi(max_cell.x, cell.x)
		max_cell.y = maxi(max_cell.y, cell.y)
	return Rect2i(min_cell * WorldLayout.CELL,
		(max_cell - min_cell + Vector2i.ONE) * WorldLayout.CELL)

func _equipment_height_for_id(eq_id: String) -> float:
	return float(EquipmentArt.EQUIP_HEIGHTS.get(eq_id, EquipmentArt.DEFAULT_EQUIP_HEIGHT))

func _top_face_transform(height: float) -> Transform2D:
	var floor_transform := Proj2D.floor_transform()
	return Transform2D(floor_transform.x, floor_transform.y,
		floor_transform.origin + Vector2(-height * Proj2D.EXTRUDE_X,
			-height * Proj2D.HEIGHT_SCALE))

func _blend_pixel(img: Image, point: Vector2i, source: Color) -> void:
	if source.a <= 0.0 or point.x < 0 or point.y < 0 \
			or point.x >= img.get_width() or point.y >= img.get_height():
		return
	var destination := img.get_pixelv(point)
	var out_alpha := source.a + destination.a * (1.0 - source.a)
	if out_alpha <= 0.0:
		return
	var destination_weight := destination.a * (1.0 - source.a)
	img.set_pixelv(point, Color(
		(source.r * source.a + destination.r * destination_weight) / out_alpha,
		(source.g * source.a + destination.g * destination_weight) / out_alpha,
		(source.b * source.a + destination.b * destination_weight) / out_alpha,
		out_alpha))

func _smoothstep01(value: float) -> float:
	var t := clampf(value, 0.0, 1.0)
	return t * t * (3.0 - 2.0 * t)
