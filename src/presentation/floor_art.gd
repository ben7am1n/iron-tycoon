# src/presentation/floor_art.gd — V3 §1 区域地面材质工厂（Phase 5）
#
# V3 §1（区域地面材质规范）：最终画面禁止纯色格子。区域区别通过材质表达：
#   - 力量训练区：深灰橡胶地垫（略有色差像素块、接缝、磨损、汗渍、高光）
#   - 有氧区：偏暖灰/蓝灰地面（细小重复纹理、边缘压条）
#   - 瑜伽区：暖色木地板（明显木板方向、像素化木纹）
#   - 公共通道：浅灰/暖灰瓷砖（比训练区亮，有砖缝）
#
# 实现：把整张地板（世界像素空间 416×320，CELL_SIZE=32）烘焙成一张
# ImageTexture，运行时 1 次 draw_texture_rect —— 替代旧 _draw_floor_zones 的
# 3 次填充 + 3 次描边（draw call 预算友好，V3 §15 性能）。材质细节全部
# 确定性生成（哈希驱动，无 RNG 状态），headless 可测、bit-identical。
#
# 色值单一来源：src/palette.gd（V3 §7 新增 FLOOR_* 色域）。
# headless 可靠性：跨脚本引用一律 preload alias（项目约定）。
class_name FloorArt extends RefCounted

const Palette := preload("res://src/palette.gd")

## 世界像素空间尺寸（与 main.gd GRID_W/H × CELL_SIZE 一致；由 init 注入，
## 测试可用小网格验证）。
var _grid_w: int = 13
var _grid_h: int = 10
var _cell: int = 32

var _image: Image = null
var _texture: ImageTexture = null


## 初始化：注入网格尺寸与 cell 尺寸（数据驱动，不硬编码）。重建会清除缓存。
func init(grid_w: int, grid_h: int, cell: int) -> void:
	_grid_w = grid_w
	_grid_h = grid_h
	_cell = cell
	_image = null
	_texture = null


## 生成/取整张地板纹理（惰性烘焙 + 缓存；多次调用返回同一实例）。
func texture() -> ImageTexture:
	if _texture == null:
		_image = build_image()
		_texture = ImageTexture.create_from_image(_image)
	return _texture


## 取烘焙后的 Image（测试用像素断言；未烘焙时先 build_image()）。
func image() -> Image:
	if _image == null:
		_image = build_image()
	return _image


## 烘焙整张地板：瓷砖底 → 区域材质覆盖。全部确定性（hash 驱动）。
func build_image() -> Image:
	var w := _grid_w * _cell
	var h := _grid_h * _cell
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Palette.FLOOR_WALK_BASE)
	_draw_walkway(img)
	_draw_zones(img)
	return img


# === 公共通道：浅灰/暖灰瓷砖（砖缝 + 轻微色差） ===

func _draw_walkway(img: Image) -> void:
	var w := img.get_width()
	var h := img.get_height()
	# 砖缝：每 cell 边界一条 Grout 线（1px，确定性）。
	for x in range(0, w + 1, _cell):
		if x < w:
			_draw_vline(img, x, 0, h, Palette.FLOOR_WALK_GROUT)
	for y in range(0, h + 1, _cell):
		if y < h:
			_draw_hline(img, 0, w, y, Palette.FLOOR_WALK_GROUT)
	# 轻微色差：每 cell 内 2-3 个略深/略亮像素（hash 驱动，无 RNG）。
	for cy in _grid_h:
		for cx in _grid_w:
			var seed := _hash2(cx, cy)
			for i in 3:
				var px := cx * _cell + int((seed * (i + 3)) % (_cell - 2)) + 1
				var py := cy * _cell + int((seed * (i + 7)) % (_cell - 2)) + 1
				var c: Color = Palette.FLOOR_WALK_BASE
				if (seed + i) % 2 == 0:
					c = c.darkened(0.06)
				else:
					c = c.lightened(0.06)
				img.set_pixel(px, py, c)


# === 区域材质 ===

func _draw_zones(img: Image) -> void:
	_draw_strength(img)
	_draw_cardio(img)
	_draw_flex(img)


## 力量区：深灰橡胶地垫 —— 略有色差像素块 + 接缝 + 磨损高光 + 汗渍。
func _draw_strength(img: Image) -> void:
	var rect := _zone_px("strength")
	if rect.size.x <= 0 or rect.size.y <= 0:
		return
	for y in range(rect.position.y, rect.position.y + rect.size.y):
		for x in range(rect.position.x, rect.position.x + rect.size.x):
			img.set_pixel(x, y, Palette.FLOOR_STRENGTH_BASE)
	# 接缝：每 cell 边界 2px 深色线（橡胶块拼接缝）。
	for gx in range(rect.position.x, rect.position.x + rect.size.x + 1, _cell):
		if gx > rect.position.x and gx < rect.position.x + rect.size.x:
			_draw_vline(img, gx, rect.position.y, rect.size.y, Palette.FLOOR_STRENGTH_SEAM, 2)
	for gy in range(rect.position.y, rect.position.y + rect.size.y + 1, _cell):
		if gy > rect.position.y and gy < rect.position.y + rect.size.y:
			_draw_hline(img, rect.position.x, rect.size.x, gy, Palette.FLOOR_STRENGTH_SEAM, 2)
	# 磨损高光 + 汗渍（hash 驱动，确定性；少量点缀不铺满）。
	for y in range(rect.position.y + 2, rect.position.y + rect.size.y - 2):
		for x in range(rect.position.x + 2, rect.position.x + rect.size.x - 2):
			var seed := _hash2(x, y)
			if seed % 97 == 0:
				img.set_pixel(x, y, Palette.FLOOR_STRENGTH_WEAR)
			elif seed % 151 == 0:
				img.set_pixel(x, y, Palette.FLOOR_STRENGTH_STAIN)


## 有氧区：偏暖灰/蓝灰地面 —— 细小重复纹理（每 4px 暗点）+ 边缘压条。
func _draw_cardio(img: Image) -> void:
	var rect := _zone_px("cardio")
	if rect.size.x <= 0 or rect.size.y <= 0:
		return
	for y in range(rect.position.y, rect.position.y + rect.size.y):
		for x in range(rect.position.x, rect.position.x + rect.size.x):
			img.set_pixel(x, y, Palette.FLOOR_CARDIO_BASE)
	# 细小重复纹理：4px 周期暗点（像地砖纹，非纯色）。
	for y in range(rect.position.y + 2, rect.position.y + rect.size.y, 4):
		for x in range(rect.position.x + 2, rect.position.x + rect.size.x, 4):
			img.set_pixel(x, y, Palette.FLOOR_CARDIO_DOT)
	# 边缘压条：区域边界 2px 深色（V3 §1 边缘压条）。
	_draw_border(img, rect, Palette.FLOOR_CARDIO_EDGE, 2)


## 瑜伽区：暖色木地板 —— 横向木板（每 16px 一行）+ 像素化木纹。
func _draw_flex(img: Image) -> void:
	var rect := _zone_px("flex")
	if rect.size.x <= 0 or rect.size.y <= 0:
		return
	for y in range(rect.position.y, rect.position.y + rect.size.y):
		for x in range(rect.position.x, rect.position.x + rect.size.x):
			img.set_pixel(x, y, Palette.FLOOR_FLEX_BASE)
	# 木板分隔：每 16px（半 cell）一条 Plank 线 —— 明显横向木板方向。
	for gy in range(rect.position.y + 16, rect.position.y + rect.size.y, 16):
		_draw_hline(img, rect.position.x, rect.size.x, gy, Palette.FLOOR_FLEX_PLANK)
	# 像素化木纹：hash 驱动的短深色横线（少量，不铺满）。
	for y in range(rect.position.y + 2, rect.position.y + rect.size.y - 2):
		var seed := _hash2(rect.position.x + rect.size.x, y)
		if seed % 29 == 0:
			var start_x := rect.position.x + 2 + int(seed % (rect.size.x - 6))
			for i in 4:
				if start_x + i < rect.position.x + rect.size.x - 2:
					img.set_pixel(start_x + i, y, Palette.FLOOR_FLEX_GRAIN)


# === helpers ===

## ZONE_RECTS（cell 坐标）→ 像素 Rect2i。
func _zone_px(zone: String) -> Rect2i:
	if not Palette.ZONE_RECTS.has(zone):
		return Rect2i()
	var r: Rect2i = Palette.ZONE_RECTS[zone]
	return Rect2i(r.position * _cell, r.size * _cell)


func _draw_vline(img: Image, x: int, y0: int, height: int, color: Color, width: int = 1) -> void:
	for i in width:
		for y in range(y0, y0 + height):
			if x + i < img.get_width():
				img.set_pixel(x + i, y, color)


func _draw_hline(img: Image, x0: int, width: int, y: int, color: Color, width_px: int = 1) -> void:
	for i in width_px:
		for x in range(x0, x0 + width):
			if y + i < img.get_height():
				img.set_pixel(x, y + i, color)


func _draw_border(img: Image, rect: Rect2i, color: Color, width_px: int) -> void:
	for i in width_px:
		for x in range(rect.position.x, rect.position.x + rect.size.x):
			img.set_pixel(x, rect.position.y + i, color)
			img.set_pixel(x, rect.position.y + rect.size.y - 1 - i, color)
		for y in range(rect.position.y, rect.position.y + rect.size.y):
			img.set_pixel(rect.position.x + i, y, color)
			img.set_pixel(rect.position.x + rect.size.x - 1 - i, y, color)


## 确定性 2D hash（无 RNG 状态 —— 同输入永远同输出）。
func _hash2(x: int, y: int) -> int:
	var h := x * 374761393 + y * 668265263
	h = (h ^ (h >> 13)) * 1274126177
	return h & 0x7fffffff
