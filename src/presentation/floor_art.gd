# src/presentation/floor_art.gd — V3 §1 区域地面材质工厂 + V3.1 P3 手绘 pixel density
#
# V3 §1（区域地面材质规范）+ V3.1 P3（Pixel density 改手绘感）：
#   - 力量训练区：深灰橡胶地垫 —— 多个深灰/灰蓝/暖灰 pixel cluster（非纯色
#     大块填充）、不规则断裂接缝、磨损/汗渍 cluster
#   - 有氧区：偏暖灰/蓝灰地面 —— 不规则暖灰/蓝灰 cluster（无 4px 规则点阵、
#     无等宽边缘压条）
#   - 瑜伽区：暖色木地板 —— 不规则木板分隔（间距抖动、非固定 16px）+ 木纹
#   - 公共通道：浅灰/暖灰瓷砖 —— 断裂 jagged 砖缝（非每 cell 全直线）、
#     瓷砖色差 cluster
#
# V3.1 P3 负面约束（本文件严格执行）：
#   - 无完美直线：接缝/砖缝 = 分段 + 垂直抖动 + 随机断裂（jagged seam）
#   - 无完美矩形：区域边界逐行偏移（jagged fill），非整块矩形填充
#   - 无等宽边框：去掉统一 2px 边缘压条（卡迪奥区不再画 border）
#   - 无重复规则纹理：去掉 4px 周期点阵 / 固定 16px 板缝 / 每 cell 全砖缝
#   - 无纯色大面积填充：每区由多种 cluster（不规则 blob）叠色组成
#
# 实现：把整张地板（世界像素空间 416×320，CELL_SIZE=32）烘焙成一张
# ImageTexture，运行时 1 次 draw_texture_rect —— 替代旧 _draw_floor_zones 的
# 3 次填充 + 3 次描边（draw call 预算友好，V3 §15 性能）。材质细节全部
# 确定性生成（哈希驱动，无 RNG 状态），headless 可测、bit-identical。
#
# 色值单一来源：src/palette.gd（V3 §7 新增 FLOOR_* 色域 + V3.1 P3 CL_* cluster）。
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


# === 公共通道：浅灰/暖灰瓷砖（V3.1 P3 手绘：砖缝断裂 jagged + 色差 cluster） ===

func _draw_walkway(img: Image) -> void:
	var w := img.get_width()
	var h := img.get_height()
	# 瓷砖色差 cluster：每 cell 一个不规则 blob（亮/暗瓷砖色，非规则点阵）。
	for cy in _grid_h:
		for cx in _grid_w:
			var seed := _hash2(cx * 5 + 1, cy * 7 + 3)
			var cx_px := cx * _cell + _cell / 2 + (seed % 5) - 2
			var cy_px := cy * _cell + _cell / 2 + ((seed >> 4) % 5) - 2
			var c: Color = Palette.FLOOR_WALK_CL_LIGHT if (seed + cy) % 3 != 0 \
				else Palette.FLOOR_WALK_CL_DARK
			_paint_blob(img, cx_px, cy_px, 5 + (seed >> 8) % 3, c, seed)
	# 断裂 jagged 砖缝：只在部分 cell 边界画（非每 cell 全直线），每段偏移。
	for gx in range(1, _grid_w):
		if _hash2(gx * 11, 7) % 3 == 0:
			continue  # 跳过部分边界（不完全对称）
		_paint_jagged_seam_v(img, gx * _cell, 0, h, Palette.FLOOR_WALK_GROUT, gx * 31)
	for gy in range(1, _grid_h):
		if _hash2(gy * 13, 5) % 3 == 0:
			continue
		_paint_jagged_seam_h(img, 0, w, gy * _cell, Palette.FLOOR_WALK_GROUT, gy * 17)
	# 少量污渍 cluster（手绘局部细节，不铺满）。
	for i in 24:
		var seed := _hash2(i * 3, i * 5 + 11)
		var px := int(seed % w)
		var py := int((seed >> 6) % h)
		_paint_blob(img, px, py, 2 + (seed >> 12) % 2,
			Palette.FLOOR_WALK_CL_DARK, seed * 7)


# === 区域材质（V3.1 P3：全部多色 cluster + jagged 边缘） ===

func _draw_zones(img: Image) -> void:
	_draw_strength(img)
	_draw_cardio(img)
	_draw_flex(img)


## 力量区：深灰橡胶地垫 —— 多色 cluster（深灰/灰蓝/暖灰）+ 断裂接缝 + 磨损。
func _draw_strength(img: Image) -> void:
	var rect := _zone_px("strength")
	if rect.size.x <= 0 or rect.size.y <= 0:
		return
	var palette := [
		Palette.FLOOR_STRENGTH_BASE,
		Palette.FLOOR_STRENGTH_BLOCK,
		Palette.FLOOR_STRENGTH_CL_GRAYBLUE,
		Palette.FLOOR_STRENGTH_CL_WARMGRAY,
		Palette.FLOOR_STRENGTH_STAIN,
	]
	_paint_cluster_zone(img, rect, palette, Palette.FLOOR_STRENGTH_SEAM, 9, 101)
	# 磨损高光 cluster（稀疏，不铺满）：小块 WEAR 亮色。
	for i in 36:
		var seed := _hash2(i * 7 + 3, i * 11 + 5)
		var wx := rect.position.x + int(seed % rect.size.x)
		var wy := rect.position.y + int((seed >> 5) % rect.size.y)
		_paint_blob(img, wx, wy, 1 + (seed >> 9) % 2, Palette.FLOOR_STRENGTH_WEAR, seed * 3)


## 有氧区：偏暖灰/蓝灰地面 —— 不规则暖灰/蓝灰 cluster（无规则点阵/无压条）。
func _draw_cardio(img: Image) -> void:
	var rect := _zone_px("cardio")
	if rect.size.x <= 0 or rect.size.y <= 0:
		return
	var palette := [
		Palette.FLOOR_CARDIO_BASE,
		Palette.FLOOR_CARDIO_DOT,
		Palette.FLOOR_CARDIO_CL_GRAYBLUE,
		Palette.FLOOR_CARDIO_CL_WARMGRAY,
	]
	_paint_cluster_zone(img, rect, palette, Palette.FLOOR_CARDIO_EDGE, 11, 202)


## 瑜伽区：暖色木地板 —— 不规则木板分隔 + 亮/暗木板 cluster + 木纹。
func _draw_flex(img: Image) -> void:
	var rect := _zone_px("flex")
	if rect.size.x <= 0 or rect.size.y <= 0:
		return
	var palette := [
		Palette.FLOOR_FLEX_BASE,
		Palette.FLOOR_FLEX_CL_LIGHT,
		Palette.FLOOR_FLEX_CL_DARK,
		Palette.FLOOR_FLEX_GRAIN,
	]
	_paint_cluster_zone(img, rect, palette, Palette.FLOOR_FLEX_PLANK, 10, 303)
	# 木纹：稀疏短横线 cluster（手绘木纹，非规则条带）。
	for i in 40:
		var seed := _hash2(i * 5 + 2, i * 9 + 7)
		var gy := rect.position.y + int(seed % rect.size.y)
		var gx := rect.position.x + int((seed >> 5) % (rect.size.x - 6))
		for j in 3 + (seed >> 9) % 3:
			if gx + j < rect.position.x + rect.size.x - 2:
				img.set_pixel(gx + j, gy, Palette.FLOOR_FLEX_GRAIN)


# === V3.1 P3 手绘原语（全部确定性，无 RNG 状态） ===

## 多色 cluster 区域（P3 核心）：jagged 底 + 不规则 blob 叠色 + 断裂接缝。
## [palette] cluster 色表（含 base，第一个 = 底色）；[seam] 接缝色；
## [spacing] 簇间距（px，越小越密）；[seed_base] 确定性种子。
func _paint_cluster_zone(img: Image, rect: Rect2i, palette: Array, seam: Color,
		spacing: int, seed_base: int) -> void:
	_fill_jagged(img, rect, palette[0], seed_base)
	var bleed := maxi(6, spacing)
	for gy in range(rect.position.y - bleed, rect.position.y + rect.size.y + bleed, spacing):
		for gx in range(rect.position.x - bleed, rect.position.x + rect.size.x + bleed, spacing):
			var h := _hash2(gx * 31 + seed_base, gy * 17 + seed_base * 7)
			var cx := gx + (h % 7) - 3
			var cy := gy + ((h >> 4) % 7) - 3
			var r := 3 + (h >> 8) % 4
			var col: Color = palette[(h >> 12) % palette.size()]
			_paint_blob(img, cx, cy, r, col, h ^ seed_base)
	_paint_jagged_seams(img, rect, seam, seed_base * 3)


## 断裂 jagged 接缝（P3 无完美直线）：沿 cell 边界走段，每段垂直偏移 ±2，
## 随机跳过段（不完全对称）。垂直缝。
func _paint_jagged_seam_v(img: Image, x: int, y0: int, y1: int, color: Color,
		seed: int) -> void:
	var y := y0
	while y < y1:
		if y < 0 or y >= img.get_height():
			break
		var seg := 3 + (_hash2(seed + y, x * 5) % 5)
		var off := (_hash2(x * 7 + seed, y * 3) % 5) - 2
		var px := x + off
		if px >= 0 and px < img.get_width():
			if _hash2(x, y + seed * 9) % 3 != 0:  # 断裂：~1/3 段跳过
				var seg_n := mini(seg, y1 - y)
				for i in seg_n:
					img.set_pixel(px, y + i, color)
		y += seg


## 水平版 jagged 缝（沿 y=const 行，横向分段 + 偏移）。
func _paint_jagged_seam_h(img: Image, x0: int, x1: int, y: int, color: Color,
		seed: int) -> void:
	var x := x0
	while x < x1:
		if x < 0 or x >= img.get_width():
			break
		var seg := 3 + (_hash2(seed + x, y * 5) % 5)
		var off := (_hash2(x * 7 + seed, y * 3) % 5) - 2
		var py := y + off
		if py >= 0 and py < img.get_height():
			if _hash2(x, y + seed * 9) % 3 != 0:
				var seg_n := mini(seg, x1 - x)
				for i in seg_n:
					img.set_pixel(x + i, py, color)
		x += seg


## 区域内所有 cell 边界画断裂 jagged 接缝（垂直 + 水平）。
func _paint_jagged_seams(img: Image, rect: Rect2i, color: Color, seed: int) -> void:
	for x in range(rect.position.x + _cell, rect.position.x + rect.size.x, _cell):
		if x <= rect.position.x or x >= rect.position.x + rect.size.x:
			continue
		_paint_jagged_seam_v(img, x, rect.position.y, rect.position.y + rect.size.y, color, seed + x)
	for y in range(rect.position.y + _cell, rect.position.y + rect.size.y, _cell):
		if y <= rect.position.y or y >= rect.position.y + rect.size.y:
			continue
		_paint_jagged_seam_h(img, rect.position.x, rect.position.x + rect.size.x, y, color, seed + y)


## 逐行偏移的矩形填充（P3 无完美矩形：区域边界逐行抖动 ±3）。
func _fill_jagged(img: Image, rect: Rect2i, color: Color, seed: int) -> void:
	for y in range(rect.position.y, rect.position.y + rect.size.y):
		if y < 0 or y >= img.get_height():
			continue
		var xoff := (_hash2(seed + y, y * 3 + seed) % 7) - 3
		for x in range(rect.position.x + xoff, rect.position.x + rect.size.x + xoff):
			if x >= 0 and x < img.get_width():
				img.set_pixel(x, y, color)


## 不规则 blob（P3 手工小色块）：8 角度桶半径抖动 → 边缘不规则、非完美圆。
## 确定性：同 (cx, cy, r, seed) 永远同形状。
func _paint_blob(img: Image, cx: int, cy: int, r: int, color: Color, seed: int) -> void:
	for y in range(cy - r - 2, cy + r + 3):
		for x in range(cx - r - 2, cx + r + 3):
			if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
				continue
			var dx := x - cx
			var dy := y - cy
			var d := sqrt(float(dx * dx + dy * dy))
			if d > float(r) + 2.0:
				continue
			var bucket := int(atan2(float(dy), float(dx)) / TAU * 8.0)
			bucket = (bucket % 8 + 8) % 8
			var jit := (_hash2(seed * 13 + bucket * 7, bucket * 3 + seed) % 7) - 3
			if d <= float(r) + float(jit) * 0.5:
				img.set_pixel(x, y, color)


# === helpers ===

## ZONE_RECTS（cell 坐标）→ 像素 Rect2i。
func _zone_px(zone: String) -> Rect2i:
	if not Palette.ZONE_RECTS.has(zone):
		return Rect2i()
	var r: Rect2i = Palette.ZONE_RECTS[zone]
	return Rect2i(r.position * _cell, r.size * _cell)


## 确定性 2D hash（无 RNG 状态 —— 同输入永远同输出）。
func _hash2(x: int, y: int) -> int:
	var h := x * 374761393 + y * 668265263
	h = (h ^ (h >> 13)) * 1274126177
	return h & 0x7fffffff
