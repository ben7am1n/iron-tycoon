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


## 烘焙整张地板：瓷砖底 → 区域材质覆盖 → 分区边界过渡带 → 地垫/磨损
## （生活痕迹）。全部确定性（hash 驱动）。
func build_image() -> Image:
	var w := _grid_w * _cell
	var h := _grid_h * _cell
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Palette.FLOOR_WALK_BASE)
	_draw_walkway(img)
	_draw_zones(img)
	# 返工3 P1（任务 1c）：分区边界从「硬分界线」变「材质过渡」—— 沿
	# zone 边缘画 dithered 混合带（相邻材质/通道色交错），消除布局图感。
	_draw_transition_bands(img)
	# 返工3 P1（任务 1b/3）：地垫/地胶拼块 + 磨损 —— 打破右侧灰霾空地/
	# 中央通道的近纯色平涂，空间读作「正在使用的健身房」。
	_draw_floor_mats(img)
	_draw_wear(img)
	return img


# === 公共通道：浅灰/暖灰瓷砖（V3.1 P3 手绘：砖缝断裂 jagged + 色差 cluster） ===

func _draw_walkway(img: Image) -> void:
	var w := img.get_width()
	var h := img.get_height()
	# 瓷砖色差 cluster：约三分之一 cell 一个短而低对比的不规则笔触簇。
	# 仍可读出手绘变化，但大面积观看时不再形成抢眼的散点噪声。
	for cy in _grid_h:
		for cx in _grid_w:
			var seed := _hash2(cx * 5 + 1, cy * 7 + 3)
			if seed % 3 != 0:
				continue
			var cx_px := cx * _cell + _cell / 2 + (seed % 5) - 2
			var cy_px := cy * _cell + _cell / 2 + ((seed >> 4) % 5) - 2
			var c: Color = Palette.FLOOR_WALK_CL_LIGHT if (seed + cy) % 3 != 0 \
				else Palette.FLOOR_WALK_CL_DARK
			_paint_stroke(img, cx_px, cy_px, 3 + (seed >> 8) % 2, c, seed)
	# 断裂 jagged 砖缝：只在部分 cell 边界画（非每 cell 全直线），每段偏移。
	for gx in range(1, _grid_w):
		if _hash2(gx * 11, 7) % 3 == 0:
			continue  # 跳过部分边界（不完全对称）
		_paint_jagged_seam_v(img, gx * _cell, 0, h, Palette.FLOOR_WALK_GROUT, gx * 31)
	for gy in range(1, _grid_h):
		if _hash2(gy * 13, 5) % 3 == 0:
			continue
		_paint_jagged_seam_h(img, 0, w, gy * _cell, Palette.FLOOR_WALK_GROUT, gy * 17)
	# 污渍 cluster 再收尾一档（12 → 7，约 -42%），笔触缩短且颜色继续
	# 向通道底色收敛；只留下近看可见的生活痕迹。
	for i in 7:
		var seed := _hash2(i * 3, i * 5 + 11)
		var px := int(seed % w)
		var py := int((seed >> 6) % h)
		_paint_stroke(img, px, py, 2 + (seed >> 12) % 2,
			Palette.FLOOR_WALK_CL_DARK, seed * 7)


# === 返工3 P1：分区边界过渡 + 地垫/磨损（打破灰霾空地平涂） ===
#
# 任务 1c（分区边界自然过渡）：zone 边缘的「硬切分线」→ dithered 材质
# 混合带 —— zone 色族向 walkway 色族断裂羽化（非等宽边框、非完美直线）。
# 任务 1b（空地明暗变化）：右侧走道列 / 顶部通道 / 底部通道铺暖木橡胶
# 地垫（拼缝 + 磨损），打破近纯色平涂。
# 任务 3（生活痕迹）：使用频繁路径（入口→器械、跑步机前）撒亮/暗磨损
# 笔触 —— 空间读作「正在使用的健身房」。
# 任务 4（人物-环境互动）：QUEUEING 会员所在 cell 铺排队区地垫。
# 全部确定性（hash 驱动，无 RNG 状态）。

## 分区边界过渡带（任务 1c）：沿 zone 四条边在 walkway 侧画 dithered
## 混合带。zone 主色族 + walkway 亮/暗色以 ~30% 密度交错 —— 边界从
## 「硬切分线」变「材质磨损羽化」（V3.1 负面约束：无等宽边框/无完美
## 直线 —— 过渡带本身断裂）。只画在 zone 外侧 6px 带（不侵入 zone
## 内部 —— 分区材质纯度断言不受影响）。
func _draw_transition_bands(img: Image) -> void:
	var zones := [["strength", 711], ["cardio", 719], ["flex", 727]]
	for entry in zones:
		var rect := _zone_px(entry[0])
		_blend_zone_edge(img, rect, _zone_blend_colors(entry[0]), int(entry[1]))


## zone 边界过渡色（任务 1c）：zone 主色 2 + walkway 亮/暗 2 —— 混合带
## 里两种材质都有，羽化而非生硬替换。
func _zone_blend_colors(zone: String) -> Array:
	match zone:
		"strength":
			return [Palette.FLOOR_STRENGTH_BASE, Palette.FLOOR_STRENGTH_BLOCK,
				Palette.FLOOR_WALK_CL_LIGHT, Palette.FLOOR_WALK_CL_DARK]
		"cardio":
			return [Palette.FLOOR_CARDIO_BASE, Palette.FLOOR_CARDIO_CL_WARMGRAY,
				Palette.FLOOR_WALK_CL_LIGHT, Palette.FLOOR_WALK_CL_DARK]
		_:
			return [Palette.FLOOR_FLEX_BASE, Palette.FLOOR_FLEX_CL_LIGHT,
				Palette.FLOOR_WALK_CL_LIGHT, Palette.FLOOR_WALK_CL_DARK]


## 沿 rect 四条边（外侧 6px 带）画 dithered 混合 —— 断裂、非等宽。
func _blend_zone_edge(img: Image, rect: Rect2i, colors: Array, seed: int) -> void:
	var bw := 6
	for y in range(rect.position.y - bw, rect.position.y + 1):
		_blend_row(img, rect.position.x - bw, rect.position.x + rect.size.x + bw,
			y, colors, seed + y * 3)
	for y in range(rect.position.y + rect.size.y - 1, rect.position.y + rect.size.y + bw):
		_blend_row(img, rect.position.x - bw, rect.position.x + rect.size.x + bw,
			y, colors, seed + y * 5)
	for x in range(rect.position.x - bw, rect.position.x + 1):
		_blend_col(img, x, rect.position.y - bw, rect.position.y + rect.size.y + bw,
			colors, seed + x * 7)
	for x in range(rect.position.x + rect.size.x - 1, rect.position.x + rect.size.x + bw):
		_blend_col(img, x, rect.position.y - bw, rect.position.y + rect.size.y + bw,
			colors, seed + x * 11)


## 单行混合带：沿行撒 ~15% 混合色（hash 驱动 —— 断裂不连续）。
func _blend_row(img: Image, x0: int, x1: int, y: int, colors: Array, seed: int) -> void:
	if y < 0 or y >= img.get_height():
		return
	for x in range(maxi(0, x0), mini(x1, img.get_width())):
		var h := _hash2(x * 3 + seed, y * 7 + seed)
		if h % 100 < 15:
			img.set_pixel(x, y, colors[(h >> 6) % colors.size()])


## 单列混合带。
func _blend_col(img: Image, x: int, y0: int, y1: int, colors: Array, seed: int) -> void:
	if x < 0 or x >= img.get_width():
		return
	for y in range(maxi(0, y0), mini(y1, img.get_height())):
		var h := _hash2(x * 5 + seed, y * 3 + seed)
		if h % 100 < 15:
			img.set_pixel(x, y, colors[(h >> 6) % colors.size()])


## 地垫/地胶拼块（任务 1b/3）：在灰霾空地（右侧走道列、顶部通道中段、
## 底部走道、排队区）铺暖木橡胶地垫 —— 打破近纯色平涂，垫上有拼缝 +
## 磨损（生活痕迹）。位置避让 walkway 采样点 (110,12) 与 zone 内部窗口
## （zone 材质纯度断言不受影响）。
func _draw_floor_mats(img: Image) -> void:
	# 顶部通道可见条带地垫（世界 y 24..32 —— 北墙墙面对 y<24 覆盖，
	# 仅 y≥24 的 walkway 条带在画面上可见；垫子落在墙基可见带上）
	_paint_floor_mat(img, Rect2i(160, 24, 200, 8), 811)
	# 右侧走道列地垫（世界 x 386..414 —— 右侧灰霾空地）
	_paint_floor_mat(img, Rect2i(386, 40, 28, 150), 823)
	# 底部走道地垫（出口侧）
	_paint_floor_mat(img, Rect2i(300, 292, 84, 20), 829)
	# 排队区地垫（QUEUEING 会员所在 cell (3,6) 覆盖 —— 任务 4 排队区
	# 地面垫；垫在会员 sprite 之下由 floor 纹理烘焙，会员站垫上）
	_paint_floor_mat(img, Rect2i(96, 192, 32, 28), 837)


## 单块地垫：暖木橡胶底（jagged 边缘，P3 无完美矩形）+ 断裂拼缝 +
## 磨损亮/暗 cluster（手绘短笔触）。
func _paint_floor_mat(img: Image, rect: Rect2i, seed: int) -> void:
	_fill_jagged(img, rect, Palette.FLOOR_MAT_WOOD, seed)
	# 拼缝：垫内 1-2 条断裂 jagged 缝（分隔为拼块，非等宽边框）
	var seam_y := rect.position.y + rect.size.y / 2 + (_hash2(seed, 3) % 5) - 2
	_paint_jagged_seam_h(img, rect.position.x, rect.position.x + rect.size.x,
		seam_y, Palette.FLOOR_MAT_SEAM, seed + 11)
	if rect.size.x > 60:
		var seam_x := rect.position.x + rect.size.x / 3 + (_hash2(seed, 7) % 5) - 2
		_paint_jagged_seam_v(img, seam_x, rect.position.y, rect.position.y + rect.size.y,
			Palette.FLOOR_MAT_SEAM, seed + 13)
	if rect.size.y > 60:
		var seam_x2 := rect.position.x + rect.size.x / 2 + (_hash2(seed, 17) % 5) - 2
		_paint_jagged_seam_v(img, seam_x2, rect.position.y, rect.position.y + rect.size.y,
			Palette.FLOOR_MAT_SEAM, seed + 19)
	# 磨损：亮/暗 cluster 减半，避免地垫比设备更抢眼。
	for i in 7:
		var h := _hash2(seed + i * 3, i * 5 + 1)
		var px := rect.position.x + int(h % maxi(rect.size.x, 1))
		var py := rect.position.y + int((h >> 5) % maxi(rect.size.y, 1))
		var c: Color = Palette.FLOOR_WEAR_LIGHT if h % 2 == 0 else Palette.FLOOR_WEAR_DARK
		_paint_stroke(img, px, py, 2 + (h >> 9) % 3, c, h ^ seed)


## 使用频繁区磨损（任务 3 生活痕迹）：入口→器械的走道路径 + 设备前
## 落地区 —— 亮/暗色差 cluster（脚踩处磨亮、边缘压暗）。手绘笔触。
## 全部在 walkway 上（不侵入 zone 内部窗口 —— 分区材质纯度不受影响）。
func _draw_wear(img: Image) -> void:
	# 三条使用痕迹总面积 2096px² → 1140px²（约 -45.6%）：保留动线暗示，
	# 但让磨损变成需要近看才发现的背景细节。
	_wear_path(img, Rect2i(34, 11, 48, 6), 911)
	_wear_path(img, Rect2i(124, 297, 110, 6), 923)
	# 跑步机区前（treadmill(2,2) 北侧落地区：设备前使用频繁区）
	_wear_path(img, Rect2i(73, 43, 32, 6), 929)


## 在矩形内撒磨损笔触（亮/暗交替 —— 使用频繁区亮度/色差变化）。
func _wear_path(img: Image, rect: Rect2i, seed: int) -> void:
	var count := maxi(2, rect.size.x * rect.size.y / 220)
	for i in count:
		var h := _hash2(seed + i * 7, i * 11 + 3)
		var px := rect.position.x + int(h % maxi(rect.size.x, 1))
		var py := rect.position.y + int((h >> 5) % maxi(rect.size.y, 1))
		var c: Color = Palette.FLOOR_WEAR_LIGHT if (h >> 9) % 2 == 0 else Palette.FLOOR_WEAR_DARK
		_paint_stroke(img, px, py, 2, c, h ^ seed)


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
	]
	_paint_cluster_zone(img, rect, palette, Palette.FLOOR_STRENGTH_SEAM, 9, 101)
	# 汗渍/磨损再降到 7/10 个局部短笔触（约 -42%/-44%）；两者色值也
	# 继续贴近底色，留下材质感而不形成可扫读的脏点。
	for i in 7:
		var stain_seed := _hash2(i * 13 + 5, i * 17 + 9)
		var sx := rect.position.x + int(stain_seed % rect.size.x)
		var sy := rect.position.y + int((stain_seed >> 5) % rect.size.y)
		_paint_stroke(img, sx, sy, 2,
			Palette.FLOOR_STRENGTH_STAIN, stain_seed * 5, rect)
	for i in 10:
		var seed := _hash2(i * 7 + 3, i * 11 + 5)
		var wx := rect.position.x + int(seed % rect.size.x)
		var wy := rect.position.y + int((seed >> 5) % rect.size.y)
		_paint_stroke(img, wx, wy, 2,
			Palette.FLOOR_STRENGTH_WEAR, seed * 3, rect)


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
	_paint_cluster_zone(img, rect, palette, Palette.FLOOR_CARDIO_EDGE, 9, 202)


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
	# 木纹：稀疏短笔触 cluster（手绘木纹，非规则条带）—— 返工2 R1：木纹
	# 使用短倾斜笔触（_paint_stroke），端点/方向抖动，色相微差（GRAIN 与
	# CL_DARK 交替）。
	for i in 20:
		var seed := _hash2(i * 5 + 2, i * 9 + 7)
		var gy := rect.position.y + int(seed % rect.size.y)
		var gx := rect.position.x + int((seed >> 5) % (rect.size.x - 6))
		var grain_col: Color = Palette.FLOOR_FLEX_GRAIN \
			if (seed >> 9) % 3 != 0 else Palette.FLOOR_FLEX_CL_DARK
		_paint_stroke(img, gx, gy, 2 + (seed >> 9) % 3, grain_col, seed * 11, rect)


# === V3.1 P3 手绘原语（全部确定性，无 RNG 状态） ===

## 多色 cluster 区域（P3 核心 + 返工2 R1 手绘笔触）：jagged 底 + 不规则
## 短笔触簇叠色 + 断裂接缝。R1：材质不再以「噪点圆点」（blob）为主 ——
## 改为「手绘笔触」—— 短线段（_paint_stroke）按 hash 方向/长度抖动、
## 端点偏移，笔触色从同族色表选（色相微差），形成艺术家逐笔绘制的质感；
## 少量 blob 仅作局部磨损点（非主力）。
## [palette] cluster 色表（含 base，第一个 = 底色）；[seam] 接缝色；
## [spacing] 簇间距（px，越小越密）；[seed_base] 确定性种子。
func _paint_cluster_zone(img: Image, rect: Rect2i, palette: Array, seam: Color,
		spacing: int, seed_base: int) -> void:
	_fill_jagged(img, rect, palette[0], seed_base)
	var bleed := maxi(6, spacing)
	# 笔触簇（主力，~3/4）：主笔触 + 更短的交叉副笔触；色差已在 palette
	# 收敛到邻近底色，因此仍满足“非纯色大块”的覆盖护栏但视觉对比更安静。
	# 起始点钳制在 zone rect 内（±2 容差）—— 笔触不泄漏进相邻 walkway/
	# 其它区（phase1/2 GRID-hidden 窗口依赖 walkway 亮瓷砖面平坦）。
	for gy in range(rect.position.y - bleed, rect.position.y + rect.size.y + bleed, spacing):
		for gx in range(rect.position.x - bleed, rect.position.x + rect.size.x + bleed, spacing):
			var h := _hash2(gx * 31 + seed_base, gy * 17 + seed_base * 7)
			var cx := gx + (h % 7) - 3
			var cy := gy + ((h >> 4) % 7) - 3
			cx = clampi(cx, rect.position.x - 2, rect.position.x + rect.size.x - 1)
			cy = clampi(cy, rect.position.y - 2, rect.position.y + rect.size.y - 1)
			# palette[0] 已作为底色铺满；笔触只从其余近邻色选，避免“用底色
			# 画纹理”浪费覆盖，同时不需要加大笔触或提高污渍对比。
			var col_index := 1 + (h >> 12) % maxi(palette.size() - 1, 1)
			var col: Color = palette[mini(col_index, palette.size() - 1)]
			if h % 4 == 0:
				# ~1/4 保留小磨损点（局部旧痕，非噪点主力）
				_paint_blob(img, cx, cy, 1 + (h >> 8) % 2, col, h ^ seed_base)
			else:
				# 短主笔触（非圆点噪点）。绘制边界钳制在 rect 内 ——
				# 笔触不泄漏进相邻 walkway/其它区。
				_paint_stroke(img, cx, cy, 5 + (h >> 8) % 5, col, h ^ seed_base, rect)
				_paint_stroke(img, cx, cy, 4 + ((h >> 9) % 4), col,
					(h ^ seed_base) * 7 + 3, rect)
	_paint_jagged_seams(img, rect, seam, seed_base * 3)

## 手绘短笔触（返工2 R1）：5-9px 短线段，方向 8 桶 hash 抖动、端点偏移
## ±2、笔触宽 2-3px（沿垂线微移）—— 像艺术家随手画的一笔，覆盖量与旧
## blob 相当（保证多色 cluster 占比不退化）。确定性：同输入永远同形状。
## [bounds] 可选绘制边界（钳制像素到该矩形内）—— 防止笔触泄漏进相邻区。
func _paint_stroke(img: Image, x: int, y: int, length: int, color: Color,
		seed: int, bounds: Rect2i = Rect2i()) -> void:
	var angle := float((seed % 8) * 45) + float((seed >> 4) % 5) * 3.0 - 6.0
	var rad := deg_to_rad(angle)
	var dx := cos(rad)
	var dy := sin(rad)
	var x0 := x
	var y0 := y
	var x1 := x + int(round(dx * length))
	var y1 := y + int(round(dy * length))
	# 端点抖动 ±2（手绘不齐）
	x1 += (_hash2(seed + 101, x) % 5) - 2
	y1 += (_hash2(seed + 203, y) % 5) - 2
	# 笔触宽 2-3px：垂直方向微移（刷毛宽度）—— 稳定 2px 起
	var thick := 2 + (_hash2(seed + 307, x * 3 + y) % 2)
	# 沿线段逐步画，每步 ±1 抖动（笔触毛边）
	var steps := maxi(1, length)
	for i in steps + 1:
		var t := float(i) / float(steps)
		var px := int(round(lerpf(x0, x1, t)))
		var py := int(round(lerpf(y0, y1, t)))
		px += (_hash2(seed + i * 7, x + y) % 3) - 1
		py += (_hash2(seed + i * 13, y - x) % 3) - 1
		for w in thick:
			var ox := (_hash2(seed + i * 17 + w, px + py) % 3) - 1
			var oy := (_hash2(seed + i * 19 + w, py - px) % 3) - 1
			var wx := px + ox
			var wy := py + oy
			if wx >= 0 and wy >= 0 and wx < img.get_width() and wy < img.get_height():
				if bounds.size.x > 0 and not bounds.has_point(Vector2i(wx, wy)):
					continue
				img.set_pixel(wx, wy, color)


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
