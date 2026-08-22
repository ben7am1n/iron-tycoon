# src/presentation/floor_art.gd — clean asset-first floor tile compositor
#
# The floor is baked once into the existing world-sized ImageTexture, keeping
# WorldCanvas at one draw call. Material identity now comes from restrained
# hand-authored PNG tiles instead of layered clusters, stains, wear, jitter, or
# jagged edge synthesis. Missing assets fall back to equally clean procedural
# base/seam tiles so the game remains renderable in incomplete checkouts.
class_name FloorArt extends RefCounted

const Palette := preload("res://src/palette.gd")

const ASSET_PATHS := {
	"strength": "res://assets/tiles/floor_strength.png",
	"cardio": "res://assets/tiles/floor_cardio.png",
	"flex": "res://assets/tiles/floor_flex.png",
	"walkway": "res://assets/tiles/floor_walkway.png",
}

const TILE_SIZE := Vector2i(32, 32)

var _grid_w: int = 13
var _grid_h: int = 10
var _cell: int = 32

var _image: Image = null
var _texture: ImageTexture = null
var _asset_images: Dictionary = {}
var _asset_lookup_done: Dictionary = {}
var _asset_paths: Dictionary = {}
var _assets_enabled := true


## [use_assets] and [asset_paths_override] are explicit test/tool seams. The
## production default always prefers the PNG suite.
func _init(use_assets: bool = true, asset_paths_override: Dictionary = {}) -> void:
	_assets_enabled = use_assets
	_asset_paths = ASSET_PATHS.duplicate()
	if not asset_paths_override.is_empty():
		_asset_paths = asset_paths_override.duplicate()


## Inject world grid dimensions. Reinitializing invalidates only the composed
## world image; decoded source tiles remain cached.
func init(grid_w: int, grid_h: int, cell: int) -> void:
	_grid_w = grid_w
	_grid_h = grid_h
	_cell = cell
	_image = null
	_texture = null


func texture() -> ImageTexture:
	if _texture == null:
		_image = build_image()
		_texture = ImageTexture.create_from_image(_image)
	return _texture


func image() -> Image:
	if _image == null:
		_image = build_image()
	return _image


## Compose walkway first, then overwrite the three semantic zone rectangles.
## Edges are intentionally exact and quiet; zone readability comes from value
## and hue differences in the authored tiles, not distressed transition noise.
func build_image() -> Image:
	var size := Vector2i(_grid_w * _cell, _grid_h * _cell)
	var img := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	_draw_walkway(img)
	_draw_zones(img)
	return img


func _draw_walkway(img: Image) -> void:
	_tile_region(img, Rect2i(Vector2i.ZERO, img.get_size()), _tile_image_for("walkway"))


func _draw_zones(img: Image) -> void:
	_draw_strength(img)
	_draw_cardio(img)
	_draw_flex(img)


func _draw_strength(img: Image) -> void:
	_tile_region(img, _zone_px("strength"), _tile_image_for("strength"))


func _draw_cardio(img: Image) -> void:
	_tile_region(img, _zone_px("cardio"), _tile_image_for("cardio"))


func _draw_flex(img: Image) -> void:
	_tile_region(img, _zone_px("flex"), _tile_image_for("flex"))


## Repeat [tile] from the region's own origin and clip to the destination image.
## This keeps seams aligned to the logical cell grid even for test-sized worlds.
func _tile_region(img: Image, region: Rect2i, tile: Image) -> void:
	if tile == null or tile.is_empty() or region.size.x <= 0 or region.size.y <= 0:
		return
	var clipped := region.intersection(Rect2i(Vector2i.ZERO, img.get_size()))
	if clipped.size.x <= 0 or clipped.size.y <= 0:
		return
	var tw := tile.get_width()
	var th := tile.get_height()
	for y in range(clipped.position.y, clipped.end.y):
		var sy := posmod(y - region.position.y, th)
		for x in range(clipped.position.x, clipped.end.x):
			var sx := posmod(x - region.position.x, tw)
			img.set_pixel(x, y, tile.get_pixel(sx, sy))


## True only when the requested material actually decoded from its configured
## PNG path. A missing file selects the clean programmatic fallback.
func is_using_asset(material: String) -> bool:
	return _asset_image_for(material) != null


func asset_path_for(material: String) -> String:
	return str(_asset_paths.get(material, ""))


func tile_size(material: String) -> Vector2i:
	return _tile_image_for(material).get_size()


func _tile_image_for(material: String) -> Image:
	var asset := _asset_image_for(material)
	if asset != null:
		return asset
	return _programmatic_tile_for(material)


func _asset_image_for(material: String) -> Image:
	if not _assets_enabled:
		return null
	if _asset_lookup_done.has(material):
		return _asset_images.get(material)
	_asset_lookup_done[material] = true
	var path := asset_path_for(material)
	if path == "":
		return null
	# Imported/editor/export path first; raw PNG decode keeps --script tests
	# independent of whether the editor has generated .import metadata.
	if ResourceLoader.exists(path, "Texture2D"):
		var resource := ResourceLoader.load(path, "Texture2D")
		if resource is Texture2D:
			var imported := (resource as Texture2D).get_image()
			if imported != null and not imported.is_empty():
				_asset_images[material] = imported
				return imported
	if not FileAccess.file_exists(path):
		return null
	var raw := Image.new()
	if raw.load(path) != OK or raw.is_empty():
		return null
	_asset_images[material] = raw
	return raw


## Clean deterministic fallback: one material base plus only structural seams.
## It intentionally has no cluster/wear/stain/jitter generation path.
func _programmatic_tile_for(material: String) -> Image:
	var img := Image.create(TILE_SIZE.x, TILE_SIZE.y, false, Image.FORMAT_RGBA8)
	match material:
		"strength":
			img.fill(Palette.FLOOR_STRENGTH_BASE)
			_draw_top_left_seam(img, Palette.FLOOR_STRENGTH_SEAM)
		"cardio":
			img.fill(Palette.FLOOR_CARDIO_BASE)
		"flex":
			img.fill(Palette.FLOOR_FLEX_BASE)
			for x in TILE_SIZE.x:
				img.set_pixel(x, 0, Palette.FLOOR_FLEX_PLANK)
				img.set_pixel(x, 16, Palette.FLOOR_FLEX_PLANK)
			for y in range(1, 16):
				img.set_pixel(0, y, Palette.FLOOR_FLEX_PLANK)
			for y in range(17, TILE_SIZE.y):
				img.set_pixel(16, y, Palette.FLOOR_FLEX_PLANK)
		_:
			img.fill(Palette.FLOOR_WALK_BASE)
			_draw_top_left_seam(img, Palette.FLOOR_WALK_GROUT)
	return img


func _draw_top_left_seam(img: Image, color: Color) -> void:
	for x in img.get_width():
		img.set_pixel(x, 0, color)
	for y in range(1, img.get_height()):
		img.set_pixel(0, y, color)


func _zone_px(zone: String) -> Rect2i:
	if not Palette.ZONE_RECTS.has(zone):
		return Rect2i()
	var r: Rect2i = Palette.ZONE_RECTS[zone]
	return Rect2i(r.position * _cell, r.size * _cell)
