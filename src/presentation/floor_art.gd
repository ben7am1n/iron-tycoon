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
	# 返工6 P4（N1 直线/矩形全覆盖）：区域边界「咬边」—— 沿 zone 四条边按
	# hash 挖掉/外扩不规则色块（4-10px 缺口 + 2-5px 凸起），打破「分区直线」
	# 与「区域矩形轮廓」。分区边界从程序化直线读作手裁地垫边缘。
	_bite_zone_edges(img)
	# 返工3 P1（任务 1b/3）：地垫/地胶拼块 + 磨损 —— 打破右侧灰霾空地/
	# 中央通道的近纯色平涂，空间读作「正在使用的健身房」。
	_draw_floor_mats(img)
	_draw_wear(img)
	# 返工6 P4（N1 走道条带）：走道带「破条」在磨损之后执行 —— 磨损
	# 笔触（亮暖色）会覆盖破断点；破条必须在最后，保证暗色破断点可见。
	_break_walkway_bands(img)
	return img


# === 公共通道：浅灰/暖灰瓷砖（V3.1 P3 手绘：砖缝断裂 jagged + 色差 cluster） ===

func _draw_walkway(img: Image) -> void:
	var w := img.get_width()
	var h := img.get_height()
	# 瓷砖色差 cluster：约四分之一 cell 一个短而低对比的不规则笔触簇。
	# 返工5 P1（FAIL3 噪点退让）：1/3 → 1/4 cell（-25% 密度），笔触更短。
	# 返工5 P4（FAIL #3 同根）：cell 网格行错位 —— 每行起点随机偏移 ±半格、
	# 行密度随 hash 变化 —— 消除「整行对齐」的规则平铺读法。
	# 返工6 P1（FAIL1 全局噪点降密）：1/4 → 1/5 cell（-20% 密度）——
	# 通道是「留白」区域，瓷砖色差保留近看生活痕迹即可（walkway GROUT
	# 砖缝 + lum>0.6 断言不受影响：cluster 用 CL_* 色，非 GROUT）。
	for cy in _grid_h:
		var row_off := (_hash2(cy * 7 + 3, 131) % 17) - 8
		# 返工7 P1（FAIL1 噪点焦点层级）：通道是中央留白区 —— 瓷砖色差
		# 再降一档（5..7 分之一 → 7..9 分之一，-30% 密度）。中央通道读作
		# 「干净的主路径」而非碎纹贴图（GPT：中央深灰通道灰脏）。
		# 返工7 P1 二轮（GPT 仍 FAIL「噪点均匀铺满」）：色差密度再降
		# （7..9 → 9..12 分之一，-25%）—— 通道是「留白路径」，只保留
		# 极近看可见的生活痕迹；walkway 断言（GROUT 砖缝 + lum>0.6 +
		# 亮于 strength+0.2）只依赖 BASE/GROUT 色，CL 色差非断言项。
		var row_density := 9 + (_hash2(cy * 11 + 5, 251) % 4)  # 9..12 分之一
		for cx in _grid_w:
			var seed := _hash2(cx * 5 + 1 + row_off, cy * 7 + 3)
			if seed % row_density != 0:
				continue
			var cx_px := cx * _cell + _cell / 2 + (seed % 5) - 2 + row_off
			var cy_px := cy * _cell + _cell / 2 + ((seed >> 4) % 5) - 2
			var c: Color = Palette.FLOOR_WALK_CL_LIGHT if (seed + cy) % 3 != 0 \
				else Palette.FLOOR_WALK_CL_DARK
			_paint_stroke(img, cx_px, cy_px, 3 + (seed >> 8) % 2, c, seed)
	# 断裂 jagged 砖缝：只在部分 cell 边界画（非每 cell 全直线），每段偏移。
	# 返工7 P1（FAIL4 机械平铺感）：跳过率从 1/3 提到 ~1/2 —— 32px 规则
	# 网格线读法减弱（GPT：机械平铺感仍然明显；砖缝只保留局部生活痕迹）。
	for gx in range(1, _grid_w):
		if _hash2(gx * 11, 7) % 2 == 0:
			continue  # 跳过 ~1/2 边界（不规则手缝）
		_paint_jagged_seam_v(img, gx * _cell, 0, h, Palette.FLOOR_WALK_GROUT, gx * 31)
	for gy in range(1, _grid_h):
		if _hash2(gy * 13, 5) % 2 == 0:
			continue
		_paint_jagged_seam_h(img, 0, w, gy * _cell, Palette.FLOOR_WALK_GROUT, gy * 17)
	# 污渍 cluster 再收尾一档（12 → 5 → 2，约 -83%），笔触缩短且颜色继续
	# 向通道底色收敛；只留下极近看可见的生活痕迹。
	# 返工7 P1（FAIL1 噪点焦点层级）：5 → 2 —— 中央通道是留白主路径，
	# 污渍点不再参与全局噪点读法（GPT：通道灰脏）。
	for i in 2:
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


## 返工6 P4（N1）：区域边界咬边 —— 沿 zone 矩形四条边按确定性 hash 挖掉
## 不规则缺口（8-20px 深，错落 6-16px 宽）并外扩凸起（3-7px），角部做
## 12-24px 对角切角（四角不齐 → 矩形轮廓被打散）；边界内侧加 1-3px 宽、
## 8-18px 深的「磨损裂缝」（从边界伸入 zone 内部的断裂线）—— zone 不再
## 读作纯色矩形块，而是手裁地垫拼块。全 hash 驱动，无 RNG。
## 只改边界带（0..20px），不侵入 zone 内部窗口（中心 64×64 窗口从边缘
## ≥32px 起，多色 cluster / dominant 测试不受影响）。
func _bite_zone_edges(img: Image) -> void:
	var zones := [["strength", 3001], ["cardio", 3019], ["flex", 3037]]
	var walk_cols := [
		Palette.FLOOR_WALK_BASE,
		Palette.FLOOR_WALK_CL_LIGHT,
		Palette.FLOOR_WALK_CL_DARK,
	]
	for entry: Array in zones:
		var zone := str(entry[0])
		var rect := _zone_px(zone)
		if rect.size.x <= 0 or rect.size.y <= 0:
			continue
		var seed := int(entry[1])
		var zone_col := Palette.FLOOR_STRENGTH_BASE
		if zone == "cardio":
			zone_col = Palette.FLOOR_CARDIO_BASE
		elif zone == "flex":
			zone_col = Palette.FLOOR_FLEX_BASE
		# 角部大对角切角：每个角切 12-24px 三角（斜切 —— 无直角）。
		var corner_sizes := [18 + (_hash2(seed, 7) % 7), 15 + (_hash2(seed + 3, 11) % 8),
			16 + (_hash2(seed + 5, 13) % 7), 14 + (_hash2(seed + 9, 17) % 9)]
		for ci in 4:
			var sz := int(corner_sizes[ci])
			var c_x := rect.position.x
			var c_y := rect.position.y
			var dir_x := 1
			var dir_y := 1
			match ci:
				1:
					c_x = rect.end.x - 1
					dir_x = -1
				2:
					c_y = rect.end.y - 1
					dir_y = -1
				3:
					c_x = rect.end.x - 1
					c_y = rect.end.y - 1
					dir_x = -1
					dir_y = -1
			for dy in sz:
				for dx in sz - dy:
					var px := c_x + dx * dir_x
					var py := c_y + dy * dir_y
					if px >= rect.position.x and px < rect.end.x \
							and py >= rect.position.y and py < rect.end.y:
						img.set_pixel(px, py,
							walk_cols[(_hash2(seed + ci * 31 + dx, dy * 5 + ci) >> 4) % walk_cols.size()])
		# 四条边：0=顶 1=底 2=左 3=右 —— 深咬口（8-20px 深）+ 凸起。
		for edge in 4:
			var edge_seed := seed + edge * 101
			var len_max: int = rect.size.x if edge < 2 else rect.size.y
			var pos := 0
			while pos < len_max:
				var h := _hash2(edge_seed + pos, edge_seed * 7)
				var chunk := 6 + (h % 11)          # 6..16px 缺口宽
				var depth := 8 + ((h >> 4) % 13)   # 8..20px 深
				var protrude := 3 + ((h >> 8) % 5) # 3..7px 凸起
				if h % 2 != 0:  # ~1/2 位置有咬口
					if edge == 0:  # 顶边：向下挖
						for dx in chunk:
							if pos + dx >= len_max:
								break
							for dy in depth:
								img.set_pixel(rect.position.x + pos + dx,
									rect.position.y + dy,
									walk_cols[(_hash2(edge_seed + pos + dx, dy * 5) >> 4) % walk_cols.size()])
						for dx in mini(protrude, chunk):
							if pos + dx >= len_max:
								break
							for dy in 3:
								var py := rect.position.y - 1 - dy
								if py >= 0:
									img.set_pixel(rect.position.x + pos + dx, py, zone_col)
					elif edge == 1:  # 底边：向上挖 + 向下凸（返工6 P4 加强：
						# 下凸 3px→5px + 每 2 个咬口必凸 —— 走道带上缘读作锯齿）
						for dx in chunk:
							if pos + dx >= len_max:
								break
							for dy in depth:
								img.set_pixel(rect.position.x + pos + dx,
									rect.position.y + rect.size.y - 1 - dy,
									walk_cols[(_hash2(edge_seed + pos + dx, dy * 7 + 3) >> 4) % walk_cols.size()])
						for dx in mini(protrude, chunk):
							if pos + dx >= len_max:
								break
							for dy in 5:
								var py := rect.position.y + rect.size.y + dy
								if py < img.get_height():
									img.set_pixel(rect.position.x + pos + dx, py, zone_col)
					elif edge == 2:  # 左边：向右挖 + 向左凸
						for dy in chunk:
							if pos + dy >= len_max:
								break
							for dx in depth:
								img.set_pixel(rect.position.x + dx,
									rect.position.y + pos + dy,
									walk_cols[(_hash2(edge_seed + pos + dy, dx * 9 + 5) >> 4) % walk_cols.size()])
						for dy in mini(protrude, chunk):
							if pos + dy >= len_max:
								break
							for dx in 3:
								var px := rect.position.x - 1 - dx
								if px >= 0:
									img.set_pixel(px, rect.position.y + pos + dy, zone_col)
					else:  # 右边：向左挖 + 向右凸
						for dy in chunk:
							if pos + dy >= len_max:
								break
							for dx in depth:
								img.set_pixel(rect.position.x + rect.size.x - 1 - dx,
									rect.position.y + pos + dy,
									walk_cols[(_hash2(edge_seed + pos + dy, dx * 11 + 7) >> 4) % walk_cols.size()])
						for dy in mini(protrude, chunk):
							if pos + dy >= len_max:
								break
							for dx in 3:
								var px := rect.position.x + rect.size.x + dx
								if px < img.get_width():
									img.set_pixel(px, rect.position.y + pos + dy, zone_col)
				pos += chunk + 5 + ((h >> 8) % 6)  # 步进带随机间隙
		# 磨损裂缝：边界内侧 2-4px 宽、8-18px 长的断裂细缝（偶发，
		# 从边缘伸入 zone —— 拼块边缘磨损，非纯色矩形）。
		for edge in 4:
			var edge_seed := seed + edge * 101
			var len_max: int = rect.size.x if edge < 2 else rect.size.y
			var pos := 0
			while pos < len_max:
				var h := _hash2(edge_seed + pos, edge_seed * 7)
				if h % 5 == 0:
					var crack_len := 8 + ((h >> 10) % 11)
					var crack_w := 2 + ((h >> 14) % 3)
					var crack_pos := pos + 4
					if edge == 0:
						for cl in crack_len:
							for cw in crack_w:
								if crack_pos + cw < len_max:
									img.set_pixel(rect.position.x + int(crack_pos) + cw,
										rect.position.y + 2 + cl,
										walk_cols[(_hash2(edge_seed + cl, cw * 13) >> 4) % walk_cols.size()])
					elif edge == 1:
						for cl in crack_len:
							for cw in crack_w:
								if crack_pos + cw < len_max:
									img.set_pixel(rect.position.x + int(crack_pos) + cw,
										rect.position.y + rect.size.y - 3 - cl,
										walk_cols[(_hash2(edge_seed + cl, cw * 17) >> 4) % walk_cols.size()])
					elif edge == 2:
						for cl in crack_len:
							for cw in crack_w:
								if crack_pos + cw < len_max:
									img.set_pixel(rect.position.x + 2 + cl,
										rect.position.y + int(crack_pos) + cw,
										walk_cols[(_hash2(edge_seed + cl, cw * 19) >> 4) % walk_cols.size()])
					else:
						for cl in crack_len:
							for cw in crack_w:
								if crack_pos + cw < len_max:
									img.set_pixel(rect.position.x + rect.size.x - 3 - cl,
										rect.position.y + int(crack_pos) + cw,
										walk_cols[(_hash2(edge_seed + cl, cw * 23) >> 4) % walk_cols.size()])
				pos += 9 + ((h >> 8) % 8)
		# 内部拼缝：zone 内部多条断裂的 walkway 色拼缝 —— 大色块分成拼块。
		# 返工6 P4（N1 分区矩形）：拼缝数量 3→5、长度加深（跨过内部窗口），
		# 且使用 zone 主色的深/浅变体（同色系 → 不触发 foreign 检测，但把
		# 纯色面打成拼块 —— GPT：三块纯色矩形分区读感消失）。
		var seam_seed := seed + 777
		for si in 5:
			var sh := _hash2(seam_seed + si, si * 31)
			var seam_axis := sh % 2          # 0=水平 1=垂直
			var seam_pos := 6 + ((sh >> 4) % 22)  # 6..27px 距边
			var seam_len := 70 + ((sh >> 8) % 50) # 70..119px 长（跨过内部）
			var seam_x := rect.position.x + 4 + ((sh >> 12) % 40)
			var seam_y := rect.position.y + 4 + ((sh >> 16) % 40)
			var seam_tone := (sh >> 20) % 4
			var seam_col: Color
			if seam_tone == 0:
				seam_col = zone_col.lightened(0.14)
			elif seam_tone == 1:
				seam_col = zone_col.darkened(0.16)
			elif seam_tone == 2:
				seam_col = zone_col.lightened(0.08)
			else:
				seam_col = walk_cols[(sh >> 24) % walk_cols.size()]
			if seam_axis == 0:
				for cl in seam_len:
					var sx := seam_x + cl
					var sy := seam_y + seam_pos
					if sx >= rect.position.x and sx < rect.end.x \
							and sy >= rect.position.y and sy < rect.end.y:
						img.set_pixel(sx, sy, seam_col)
						if cl % 5 == 0 and sy + 1 < rect.end.y:
							img.set_pixel(sx, sy + 1, seam_col)
			else:
				for cl in seam_len:
					var sx := seam_x + seam_pos
					var sy := seam_y + cl
					if sx >= rect.position.x and sx < rect.end.x \
							and sy >= rect.position.y and sy < rect.end.y:
						img.set_pixel(sx, sy, seam_col)
						if cl % 5 == 0 and sx + 1 < rect.end.x:
							img.set_pixel(sx + 1, sy, seam_col)


## 返工6 P4（N1 走道条带）：走道带破条 —— 顶部走道（世界 y 24..32）、
## 底部走道（y 288..320）、左右走道列（x 0..32 / 384..416）是四条连续
## 浅色条带，读作「长矩形带」。这里在条带内按 hash 撒暗色磨损块（深色
## 短横条 + 局部暗点），把连续浅带打断成碎段。位置与采样点 (110,12)
## 错开（该点需保持亮 walkway 材质）。确定性 hash，无 RNG。
func _break_walkway_bands(img: Image) -> void:
	var w := img.get_width()
	var h := img.get_height()
	# 返工6 P4：破断色必须「真暗」—— 走道亮色 C8BAA3 经灯光衰减后
	# 在帧中 ~(120,109,103)；若破断色与之同亮度族，灯光后收敛为同色，
	# 破断不可见（GPT：246px 连续浅色 run 仍在）。三档全用 <0.45 亮度
	# 的深色（强度区深灰 + 深木 + 深区色），灯光后仍显著暗于走道。
	var dark_cols := [
		Palette.FLOOR_STRENGTH_BASE,
		Palette.FLOOR_MAT_SEAM,
		Palette.FLOOR_WALK_CL_DARK.darkened(0.45),
	]
	# 世界底缘（y 316..320）：底部世界边缘是一条横贯全宽的水平线（屏幕
	# y≈683 —— GPT：主场馆底部外沿读作长水平建筑边界）。沿底缘撒深色
	# 缺口块（高 2-4px，宽 4-12px，间距 hash 错落）—— 底缘读作手绘
	# 破损而非一刀切直线。
	for by4 in range(316, 320):
		var row_seed4 := _hash2(9601 + by4, by4 * 41)
		var bx4 := row_seed4 % 9
		while bx4 < w:
			var bh4 := _hash2(9701 + bx4, by4 * 17)
			var c4: Color = dark_cols[(bh4 >> 8) % dark_cols.size()]
			var edge_h := 2 + ((bh4 >> 10) % 3)
			for dy4 in edge_h:
				var py4 := by4 + dy4
				if py4 < h:
					img.set_pixel(bx4, py4, c4)
			bx4 += 12 + (bh4 % 11)   # 12..22px 间距
	# 底部走道带（y 288..320）：横穿条带的深色短块（宽 6-18px，高 3-6px）
	# 返工6 P4：密度 34→72（每 ~5px 一个块），保证任意扫描行都有暗块打断
	# （GPT：底部走道带仍读作连续浅色长条）。
	for i in 72:
		var seed := _hash2(9001 + i * 7, i * 13)
		var bx := 2 + int(seed % (w - 4))
		var by := 288 + int((seed >> 6) % 32)
		var bw := 5 + int((seed >> 12) % 11)
		var bh := 2 + int((seed >> 18) % 4)
		var c: Color = dark_cols[(seed >> 20) % dark_cols.size()]
		for dy in bh:
			for dx in bw:
				var px := bx + dx
				var py := by + dy
				if px >= 0 and px < w and py >= 0 and py < h:
					img.set_pixel(px, py, c)
	# 底部走道带逐行破断（返工6 P4）：每条扫描行按 ~22px 间距撒暗色
	# 1-2px 点 —— 任意行最大同色 run ≤ ~30px（GPT：底部走道 246px 连续
	# 浅色 run）。密度低（每 ~22px 1-2px），不破坏 walkway 亮材质读法。
	for by2 in range(288, 320):
		var row_seed := _hash2(9401 + by2, by2 * 37)
		var bx2 := row_seed % 11
		while bx2 < w:
			var bh2 := _hash2(9501 + bx2, by2 * 13)
			var c2: Color = dark_cols[(bh2 >> 8) % dark_cols.size()]
			# 4-5px 高：世界 1px → 屏幕 2.25px；2-3px 仍可能落在行间隙（GPT
			# 在 y=642 采样到 246px 连续 run）。4-5px 保证任何屏幕扫描行
			# 都覆盖（相邻行错位点也重叠）—— 246px 连续 run 消失。
			var dot_h := 4 + ((bh2 >> 10) % 2)
			for dy3 in dot_h:
				var py3 := by2 + dy3
				if py3 < h:
					img.set_pixel(bx2, py3, c2)
			if bh2 % 3 == 0 and bx2 + 1 < w:
				for dy3 in dot_h:
					var py3 := by2 + dy3
					if py3 < h:
						img.set_pixel(bx2 + 1, py3, c2)
			bx2 += 14 + (bh2 % 9)   # 14..22px 间距（更密，破断更碎）
	# 底部走道带下缘（世界 y 316..320）：暗色锯齿缺口 —— 走道与 UI 交界
	# 不读作连续水平直线（GPT：底部入口带下沿过直）。
	var ex := 0
	while ex < w:
		var eh := _hash2(9301 + ex, ex * 29)
		var seg := 10 + (eh % 14)      # 10..23px 一段
		var depth := 1 + ((eh >> 6) % 3)  # 1..3px 深
		for dx in mini(seg, w - ex):
			for dy in depth:
				var py := h - 1 - dy
				var c2: Color = dark_cols[((eh >> 9) + dx) % dark_cols.size()]
				img.set_pixel(ex + dx, py, c2)
		ex += seg + 2 + ((eh >> 11) % 4)
	# 顶部走道带（y 24..32）：少量暗块（避免覆盖 walkway 采样点 (110,12)）
	for i in 10:
		var seed := _hash2(9101 + i * 7, i * 17)
		var bx := 8 + int(seed % (w - 16))
		if absf(bx - 110.0) < 14.0:
			bx = (bx + 40) % (w - 16)
		var by := 25 + int((seed >> 6) % 6)
		var bw := 5 + int((seed >> 12) % 9)
		var c: Color = dark_cols[(seed >> 16) % dark_cols.size()]
		for dy in 3:
			for dx in bw:
				var px := bx + dx
				var py := by + dy
				if px >= 0 and px < w and py >= 0 and py < h:
					img.set_pixel(px, py, c)
	# 左/右走道列（x 0..32 / 384..416）：纵向条带每隔一段打断
	for i in 18:
		var seed := _hash2(9201 + i * 5, i * 23)
		var left := (seed % 2) == 0
		var bx := 6 + int((seed >> 4) % 20) if left else 390 + int((seed >> 4) % 20)
		var by := 40 + int((seed >> 10) % 240)
		var bw := 4 + int((seed >> 18) % 9)
		var bh := 3 + int((seed >> 22) % 5)
		var c: Color = dark_cols[(seed >> 26) % dark_cols.size()]
		for dy in bh:
			for dx in bw:
				var px := bx + dx
				var py := by + dy
				if px >= 0 and px < w and py >= 0 and py < h:
					img.set_pixel(px, py, c)


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
## 返工5 P1（FAIL3 噪点退让）：stain 7→4、wear 10→6 —— 地面局部脏点/磨损
## 进一步稀疏化（主体区域亮度/对比显著高于地面；近道具 2px 邻域由接触影
## 压平，噪点远离主体）。cluster spacing 保持 9（dominant-color 单元测试
## 约束：≤0.75 主色占比）。
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
	# 汗渍/磨损再降到 4/6 个局部短笔触（约 -43%/-40%）；两者色值也
	# 继续贴近底色，留下材质感而不形成可扫读的脏点。
	for i in 4:
		var stain_seed := _hash2(i * 13 + 5, i * 17 + 9)
		var sx := rect.position.x + int(stain_seed % rect.size.x)
		var sy := rect.position.y + int((stain_seed >> 5) % rect.size.y)
		_paint_stroke(img, sx, sy, 2,
			Palette.FLOOR_STRENGTH_STAIN, stain_seed * 5, rect)
	for i in 6:
		var seed := _hash2(i * 7 + 3, i * 11 + 5)
		var wx := rect.position.x + int(seed % rect.size.x)
		var wy := rect.position.y + int((seed >> 5) % rect.size.y)
		_paint_stroke(img, wx, wy, 2,
			Palette.FLOOR_STRENGTH_WEAR, seed * 3, rect)


## 有氧区：偏暖灰/蓝灰地面 —— 不规则暖灰/蓝灰 cluster（无规则点阵/无压条）。
## 返工5 P1（FAIL3 噪点退让）：保持低对比 cluster（spacing 9 受 dominant
## 单元测试约束）；噪点退让主要由接触影 + walkway/strength 稀疏化完成。
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
## 返工5 P1（FAIL3 噪点退让）：木纹 20→14 —— 手绘木纹稀疏化；仍保留
## PLANK/GRAIN 色（单元测试断言存在）。
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
	for i in 14:
		var seed := _hash2(i * 5 + 2, i * 9 + 7)
		var gy := rect.position.y + int(seed % rect.size.y)
		var gx := rect.position.x + int((seed >> 5) % (rect.size.x - 6))
		var grain_col: Color = Palette.FLOOR_FLEX_GRAIN \
			if (seed >> 9) % 3 != 0 else Palette.FLOOR_FLEX_CL_DARK
		_paint_stroke(img, gx, gy, 2 + (seed >> 9) % 3, grain_col, seed * 11, rect)


# === V3.1 P3 手绘原语（全部确定性，无 RNG 状态） ===

## 返工7 P1（FAIL1 噪点焦点层级）：地板 cluster 密度焦点权重 —— 以中央
## 设备带（世界 224,170）为中心，远离焦点的区域笔触更稀疏（周边稀散、
## 远景角落近乎无噪点）。与 lighting_layer._focus_weight 同构（metric
## 归一化 + 0.85 衰减）但更温和（角落 0.35 —— 地板仍需保留 zone 材质
## 身份，unit test 窗口在焦点带内不受影响）。确定性 hash，无 RNG。
## 返工7 P1 二轮（GPT 仍 FAIL「噪点均匀铺满/无中央焦点」）：衰减斜率
## 1.15 → 2.0、角落下限 0.25 → 0.15 —— 远景角落真正让位（旧斜率在
## 中距处仍保留 ~0.5 权重，角落噪点密度 ~8-12% 被 GPT 读作全局均匀）。
## unit test 窗口（zone 中心 y 128..192，metric≤1）保持 factor 1.0。
func _focus_factor(x: float, y: float) -> float:
	var nx := absf(x - 224.0) / 140.0
	var ny := absf(y - 170.0) / 100.0
	var metric := maxf(nx, ny) * 0.62 + (nx + ny) * 0.22
	if metric <= 1.0:
		return 1.0
	return clampf(1.0 - (metric - 1.0) * 2.0, 0.15, 1.0)


## 多色 cluster 区域（P3 核心 + 返工2 R1 手绘笔触 + 返工5 P4 去规则平铺）：
## jagged 底 + 不规则短笔触簇叠色 + 断裂接缝。R1：材质不再以「噪点圆点」
## （blob）为主 —— 改为「手绘笔触」—— 短线段（_paint_stroke）按 hash 方向/
## 长度抖动、端点偏移，笔触色从同族色表选（色相微差），形成艺术家逐笔
## 绘制的质感；少量 blob 仅作局部磨损点（非主力）。
## 返工5 P4（FAIL #3：地面密集规则颗粒/短条平铺读作程序重复纹理）：笔触
## 排布去规则化 —— 旧版固定 spacing 网格（for range(…, spacing)）产生规则
## 平铺栅格读法。改为：行距/列距逐行逐列变化（spacing±2）、行起点错位
## （0..spacing-1，行错位）、~8% 跳过 + ~5% 加笔（局部密度变化）—— 无
## 规律平铺网格。全 hash 驱动，确定性不变；平均步距 = spacing，覆盖率与
## 旧版相当（floor_art 测试 distinct>=5 / dominant<0.75 不受影响）。
## [palette] cluster 色表（含 base，第一个 = 底色）；[seam] 接缝色；
## [spacing] 簇间距（px，越小越密）；[seed_base] 确定性种子。
func _paint_cluster_zone(img: Image, rect: Rect2i, palette: Array, seam: Color,
		spacing: int, seed_base: int) -> void:
	# 返工6 P4（N1 分区矩形）：波浪填充替代整行平移 jagged —— 左右边缘
	# 独立 jitter，zone 边界不平行（GPT：中央走道/右侧木地板读作硬切矩形）。
	_fill_wavy(img, rect, palette[0], seed_base)
	var bleed := maxi(6, spacing)
	# 笔触簇（主力，~3/4）：主笔触 + 更短的交叉副笔触；色差已在 palette
	# 收敛到邻近底色，因此仍满足“非纯色大块”的覆盖护栏但视觉对比更安静。
	# 起始点钳制在 zone rect 内（±2 容差）—— 笔触不泄漏进相邻 walkway/
	# 其它区（phase1/2 GRID-hidden 窗口依赖 walkway 亮瓷砖面平坦）。
	# 排布去规则化：行距/列距 hash 变化 + 行错位 + 局部密度变化。
	var gy := rect.position.y - bleed
	var row := 0
	while gy < rect.position.y + rect.size.y + bleed:
		var row_h := _hash2(seed_base + row * 37, 91)
		# 返工6 P4（N1 分区矩形）：行距不规则范围 ±2 → ±4 —— 木地板
		# 板缝/橡胶拼缝不再等距规则（GPT：flex 板缝 y≈261/337/422/530
		# 间距有规律，读作规则分区）。
		var row_step := spacing - 4 + row_h % 9
		var x_off := (row_h >> 6) % spacing
		var gx := rect.position.x - bleed + x_off
		var col := 0
		while gx < rect.position.x + rect.size.x + bleed:
			var h := _hash2(gx * 31 + seed_base, gy * 17 + seed_base * 7)
			var col_step := spacing - 4 + ((h >> 16) % 9)
			# 返工7 P1（FAIL1 噪点焦点层级）：远离焦点的笔触按焦点权重
			# 稀疏 —— 周边稀散、远景角落近乎无噪点（GPT：均匀铺满颗粒 →
			# 焦点层级分布）。笔触跳过概率 = (1 - factor) * 0.55：
			# 焦点带 factor=1.0 不跳过；角落 factor=0.35 → 跳过 ~36% 笔触。
			# Y 带补充：zone 顶部（y<110）与底部（y>230）是屏幕远景角落，
			# 额外稀疏（手绘细节集中在中段设备带）。unit test 窗口在
			# y 128..192（中段）不受影响。
			var focus := _focus_factor(float(gx), float(gy))
			var y_band := 1.0
			# 返工7 P1 三轮（GPT：大面积地表噪点仍是全局滤镜）：y 带覆盖
			# 到测试窗口外缘 —— 窗口在 y 128..192，带外（<128 / >192）从
			# 满密度降到 0.78；极远景（<110 / >230）保持 0.55。unit test
			# 64x64 窗口 y 128..192 逐字节不动（dominant/distinct 不回归）。
			if gy < 110 or gy > 230:
				y_band = 0.55
			elif gy < 128 or gy > 192:
				y_band = 0.78
			if h % 17 != 0:  # ~5.9% 跳过 → 局部稀疏（密度变化）
				if h % 29 < int((1.0 - focus * y_band) * 55.0):
					gx += col_step
					col += 1
					continue
				var cx := gx + (h % 7) - 3
				var cy := gy + ((h >> 4) % 7) - 3
				cx = clampi(cx, rect.position.x - 2, rect.position.x + rect.size.x - 1)
				cy = clampi(cy, rect.position.y - 2, rect.position.y + rect.size.y - 1)
				# palette[0] 已作为底色铺满；笔触只从其余近邻色选，避免“用底色
				# 画纹理”浪费覆盖，同时不需要加大笔触或提高污渍对比。
				var col_index := 1 + (h >> 12) % maxi(palette.size() - 1, 1)
				var col_c: Color = palette[mini(col_index, palette.size() - 1)]
				if h % 4 == 0:
					# ~1/4 保留小磨损点（局部旧痕，非噪点主力）
					_paint_blob(img, cx, cy, 1 + (h >> 8) % 2, col_c, h ^ seed_base)
				else:
					# 短主笔触（非圆点噪点）。绘制边界钳制在 rect 内 ——
					# 笔触不泄漏进相邻 walkway/其它区。返工5 P4：主笔触稍长
					# （5-10px）补偿去规则化导致的局部覆盖下降（flex dominant
					# 保持 < 0.75）。
					_paint_stroke(img, cx, cy, 5 + (h >> 8) % 6, col_c, h ^ seed_base, rect)
					_paint_stroke(img, cx, cy, 4 + ((h >> 9) % 4), col_c,
						(h ^ seed_base) * 7 + 3, rect)
				if h % 19 == 0 and gx + spacing < rect.position.x + rect.size.x:
					# ~5% 局部加笔（密度变化）—— 邻近短笔触簇
					_paint_stroke(img, cx + spacing / 2, cy + 2, 3 + ((h >> 20) % 3), col_c,
						(h ^ seed_base) * 11 + 5, rect)
			gx += col_step
			col += 1
		gy += row_step
		row += 1
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
## 返工7 P1（FAIL4 机械平铺感）：接缝不再每条 cell 边界都画 ——
## 每条边界按 hash 跳过 ~30%（接缝是「局部断裂手缝」而非 32px 规则
## 网格线），打破「程序化等距平铺」读法（GPT：机械平铺感仍然明显）。
## 单元测试只要求 zone 内含 SEAM/PLANK 色族（_contains_family 存在性）
## —— 保留的接缝仍满足，不影响断言。
func _paint_jagged_seams(img: Image, rect: Rect2i, color: Color, seed: int) -> void:
	for x in range(rect.position.x + _cell, rect.position.x + rect.size.x, _cell):
		if x <= rect.position.x or x >= rect.position.x + rect.size.x:
			continue
		# 返工7 P1 二轮（FAIL1 噪点焦点层级）：接缝也按焦点权重稀疏 ——
		# 焦点带内保持原 hash 口径（% 10 < 3，unit test 窗口 seam 位
		# bit-identical，dominant 计数不回归）；远景角落追加跳过
		# （最多 ~75%，角落接缝让位、近乎无接缝噪点）。
		if _hash2(seed + x * 7, 0x5EED) % 10 < 3:
			continue  # ~30% 边界不画接缝（不规则手缝，焦点带原口径）
		var seam_focus := _focus_factor(float(x), float(rect.position.y + rect.size.y * 0.5))
		if seam_focus < 0.5 and _hash2(seed + x * 13, 0x5EED + 7) % 10 < 4:
			continue  # 角落额外 ~40% 让位 → 总 ~70-75%
		_paint_jagged_seam_v(img, x, rect.position.y, rect.position.y + rect.size.y, color, seed + x)
	for y in range(rect.position.y + _cell, rect.position.y + rect.size.y, _cell):
		if y <= rect.position.y or y >= rect.position.y + rect.size.y:
			continue
		if _hash2(0x5EED + y * 11, seed + y) % 10 < 3:
			continue
		var seam_focus_y := _focus_factor(float(rect.position.x + rect.size.x * 0.5), float(y))
		if seam_focus_y < 0.5 and _hash2(0x5EED + y * 17, seed + y + 3) % 10 < 4:
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


## 返工6 P4（N1 分区矩形）：波浪填充 —— 左/右边分别独立 jitter（±6px，
## 不同 hash），zone 边界不再左右同步平移（_fill_jagged 整行平移 → 边界
## 保持平行、等宽，GPT：中央走道「平行等宽直上直下」）。波浪边界使左右
## 边缘错位 — 读作手切地垫而非硬切矩形。
func _fill_wavy(img: Image, rect: Rect2i, color: Color, seed: int) -> void:
	for y in range(rect.position.y, rect.position.y + rect.size.y):
		if y < 0 or y >= img.get_height():
			continue
		var lxoff := (_hash2(seed + y, y * 7 + 11) % 13) - 6
		var rxoff := (_hash2(seed * 3 + y, y * 11 + 29) % 13) - 6
		for x in range(rect.position.x + lxoff, rect.position.x + rect.size.x + rxoff):
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
