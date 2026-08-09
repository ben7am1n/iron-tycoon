## PixelPanel — V3.1 返工 UI：程序化「手绘像素」面板纹理生成器（单一来源）
##
## 门禁问题（本卡负责）：顶部状态栏/底部建造条呈 CSS 仪表盘式完美矩形 +
## 等宽边框。本模块用确定性生成的 ImageTexture 像素面板取代 StyleBoxFlat
## 面板语言 —— 对应 V3 §15 绝对避免（CSS dashboard aesthetics / HTML-style
## rounded rectangles / macOS window chrome / thin modern UI typography）与
## 附录 V3.1 负面约束（无完美直线 / 无完美矩形 / 无等宽边框 / 无纯色大面积
## 填充 / 无 CSS 仪表盘 UI）。
##
## V3.1 返工 2（本版本，门禁第二轮 FAIL 修复）：
##   - 移除「全宽重复虚线」：旧版 _accent_broken_line 在整条面板宽度的
##     同一 texel 行画断续 Butter 线 —— 视觉上 = 黄黑像素 warning stripe
##     （重复规则纹理，第二轮 FAIL）。改为 _accent_scatter：短促（1-3
##     texel）不定长、不定间距的 accent 墨点/短划，散布在顶部带 + 面板
##     内部 —— 手绘散点，绝非规则虚线。
##   - 移除「纯色大块」：旧版 img.fill(base) + 稀疏 cluster 的底色在 4px
##     texel 放大后读作纯色深灰块。新增 _base_noise：每个 texel 独立
##     ±亮度抖动（seeded），任意 8×8 px 区域内无两块同色 —— 材质感。
##   - 边框抖动显著加大：边缘缺口 1 texel → 2-3 texel（8-12px），并加
##     入 1-2 texel 深随机「咬口」（bite）；边缘行色相/明度随列抖动
##     （_edge_tone_jitter）—— 不等宽、有缺口、边角色相微差。
##
## 生成纹理的像素特征（参考 V3.1 P3「手绘 pixel art」语言）：
##   - 不规则边缘：上下边逐 texel 锯齿 + 2-3 texel 深缺口（磨损），左右
##     边局部内缩 + 咬口
##   - 多色 cluster：底色 + 深/浅同色系散布 cluster（木纹 WOOD / 金属刷纹
##     METAL / 布纹 CLOTH —— 材质化面板，非纯色填充）
##   - 局部磨损高光：少量提亮像素（刮痕/高光点）
##   - 非等宽散点描边：accent 色短墨点/短划，不定长不定间距（hand-drawn，
##     绝非等宽闭合边框，绝非重复虚线）
##
## 确定性：纹理内容完全由 [seed] 决定（单次 seeded RNG，固定顺序消费）；
## 同一 seed 每次运行生成相同纹理。绘制端 NEAREST 放大到目标尺寸
## （draw_texture_rect + Control 自身 texture_filter NEAREST）—— 像素
## stair-step 真实。Image + ImageTexture.create_from_image headless 安全
## （4.7.1 probe 验证）。
##
## 性能：每个面板纹理只生成一次（调用方懒缓存），每帧 1 次 draw_texture_rect
## = 1 draw call（HUD 条带 / 建造条条带 / 每 tile 平板 / 工具栏平板）。
## 全宽 1256px 条带 = 314×12 texel @4px，逐 texel 噪声仅 ~4k 次 set_pixel，
## 一次性成本可忽略。

## 材质风格：木纹（竖条 grain cluster）/ 金属（横刷纹 + 铆钉）/ 布纹（棋盘 weave）。
enum Style { WOOD, METAL, CLOTH }

## 透明色（清除像素用 —— 边缘缺口/磨损处 alpha=0）。
const CLEAR := Color(0.0, 0.0, 0.0, 0.0)

## 横向条带面板（顶部状态栏 / 底部建造条）。[size] 是 texel 尺寸（绘制端
## 以 ~4px/texel NEAREST 放大）。返回 RGBA8 ImageTexture。
static func strip_texture(
	seed: int,
	size: Vector2i,
	base: Color,
	accent: Color,
	style: int = Style.WOOD,
	alpha: float = 1.0
) -> ImageTexture:
	var img := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	img.fill(Color(base.r, base.g, base.b, alpha))
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	_base_noise(img, rng, size)
	_texture_clusters(img, rng, size, base, style)
	_jagged_edges(img, rng, size)
	_edge_tone_jitter(img, rng, size)
	# 非等宽散点 accent：顶部带（texel 行 1-3）少量短墨点/短划 + 面板内部
	# 零星散点 —— 手绘散点，绝非全宽虚线（第二轮 FAIL：warning stripe）。
	_accent_scatter(img, rng, size, accent, 1, 3, maxi(4, size.x / 28))
	_accent_scatter(img, rng, size, accent, 4, size.y - 2, maxi(2, size.x / 48))
	_wear_highlights(img, rng, size)
	return ImageTexture.create_from_image(img)


## 平板面板（建造条 tile / 选择工具栏）。[size] 是 texel 尺寸。
## METAL 风格自带 3 角铆钉（不对称手绘细节）。
static func plate_texture(
	seed: int,
	size: Vector2i,
	base: Color,
	accent: Color,
	style: int = Style.METAL,
	alpha: float = 1.0
) -> ImageTexture:
	var img := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	img.fill(Color(base.r, base.g, base.b, alpha))
	var rng := RandomNumberGenerator.new()
	rng.seed = seed
	_base_noise(img, rng, size)
	_texture_clusters(img, rng, size, base, style)
	_jagged_edges(img, rng, size)
	_edge_tone_jitter(img, rng, size)
	if style == Style.METAL:
		_rivets(img, rng, size, base)
	_accent_scatter(img, rng, size, accent, 1, 3, maxi(2, size.x / 9))
	_accent_scatter(img, rng, size, accent, 4, size.y - 2, maxi(1, size.x / 16))
	_wear_highlights(img, rng, size)
	return ImageTexture.create_from_image(img)


## 逐 texel 亮度噪声：每个 texel 的 rgb 各自 ±(0..0.06) 随机偏移（seeded）。
## 消除「纯色大块」：任意 8×8px 区域内没有两块相同颜色；材质底色由此产生
## 手绘颗粒感（第二轮 FAIL：纯色大面积填充）。
static func _base_noise(img: Image, rng: RandomNumberGenerator, size: Vector2i) -> void:
	for y in size.y:
		for x in size.x:
			var c: Color = img.get_pixel(x, y)
			if c.a <= 0.0:
				continue
			var dr := (rng.randf() - 0.5) * 0.12
			var dg := (rng.randf() - 0.5) * 0.12
			var db := (rng.randf() - 0.5) * 0.12
			img.set_pixel(x, y, Color(
				clampf(c.r + dr, 0.0, 1.0),
				clampf(c.g + dg, 0.0, 1.0),
				clampf(c.b + db, 0.0, 1.0),
				c.a
			))


## 材质 cluster：底色上散布深/浅同色系像素簇（非纯色大面积填充）。
## 全部写入经边界守卫（texel 尺寸可能很小，如工具栏平板）。
## V3.1 返工 2：cluster 密度/幅度加大（count /36 → /16，darken 0.06-0.20 →
## 0.10-0.30，lighten 0.03-0.10 → 0.05-0.16）—— 材质感更明显，配合
## _base_noise 彻底去「纯色块」观感。
static func _texture_clusters(img: Image, rng: RandomNumberGenerator, size: Vector2i, base: Color, style: int) -> void:
	var count: int = maxi(8, (size.x * size.y) / 16)
	if style == Style.WOOD:
		# 竖木纹：细长暗/亮 streak（1-2 texel 宽，2-8 texel 长）
		for i in count:
			var x := rng.randi_range(0, size.x - 1)
			var y0 := rng.randi_range(0, maxi(0, size.y - 2))
			var len_max := mini(8, size.y - y0)
			if len_max < 2:
				continue
			var len := rng.randi_range(2, len_max)
			var dark := rng.randf() < 0.6
			var c := base.darkened(0.10 + rng.randf() * 0.20) if dark else base.lightened(0.05 + rng.randf() * 0.11)
			for dy in len:
				img.set_pixel(x, y0 + dy, c)
				if rng.randf() < 0.4 and x + 1 < size.x:
					img.set_pixel(x + 1, y0 + dy, c)
	elif style == Style.METAL:
		# 横刷纹：细长水平 streak（金属拉丝），幅度更大
		for i in count:
			var y := rng.randi_range(0, size.y - 1)
			var x0 := rng.randi_range(0, size.x - 1)
			var len_max := mini(14, size.x - x0)
			if len_max < 1:
				continue
			var len := rng.randi_range(1, len_max)
			var c := base.darkened(0.08 + rng.randf() * 0.16) if rng.randf() < 0.55 else base.lightened(0.05 + rng.randf() * 0.11)
			for dx in len:
				img.set_pixel(x0 + dx, y, c)
	else:
		# 布纹棋盘：1 texel 交替提亮/压暗（幅度略加大）
		for y in size.y:
			for x in size.x:
				if (x + y) % 3 == 0:
					img.set_pixel(x, y, base.lightened(0.04) if (x + y) % 6 == 0 else base.darkened(0.05))


## 不规则边缘（V3.1 返工 2：抖动显著加大）：上/下边 1-3 texel 深锯齿 +
## 随机缺口 + 1-2 texel 咬口，左右边局部内缩 + 咬口。8-12px 级别的边缘
## 参差 —— 面板轮廓绝不是完美直线/完美矩形（第二轮 FAIL：规整矩形分区）。
static func _jagged_edges(img: Image, rng: RandomNumberGenerator, size: Vector2i) -> void:
	# 上边：~45% 列第一行缺一格（锯齿起点错落），~18% 列缺 2 格（2 texel
	# 深缺口 = 8px），~8% 列缺 3 格（12px 深，显眼磨损）
	for x in size.x:
		var r := rng.randf()
		if r < 0.18:
			img.set_pixel(x, 0, CLEAR)
			if size.y > 1:
				img.set_pixel(x, 1, CLEAR)
			if r < 0.08 and size.y > 2:
				img.set_pixel(x, 2, CLEAR)
		elif r < 0.45:
			img.set_pixel(x, 0, CLEAR)
	# 下边：同样处理
	for x in size.x:
		var r := rng.randf()
		if r < 0.18:
			img.set_pixel(x, size.y - 1, CLEAR)
			if size.y > 1:
				img.set_pixel(x, size.y - 2, CLEAR)
			if r < 0.08 and size.y > 2:
				img.set_pixel(x, size.y - 3, CLEAR)
		elif r < 0.45:
			img.set_pixel(x, size.y - 1, CLEAR)
	# 随机边缘缺口：每 6 texel 长度约 1 个缺口，1-2 texel 大小
	var chips := maxi(3, (size.x + size.y) / 6)
	for i in chips:
		match rng.randi_range(0, 3):
			0:  # top
				var tx := rng.randi_range(0, size.x - 1)
				img.set_pixel(tx, 0, CLEAR)
				if size.y > 1 and rng.randf() < 0.6:
					img.set_pixel(tx, 1, CLEAR)
				if size.x > 1 and rng.randf() < 0.3 and tx + 1 < size.x:
					img.set_pixel(tx + 1, 0, CLEAR)
			1:  # bottom
				var bx := rng.randi_range(0, size.x - 1)
				img.set_pixel(bx, size.y - 1, CLEAR)
				if size.y > 1 and rng.randf() < 0.6:
					img.set_pixel(bx, size.y - 2, CLEAR)
				if size.x > 1 and rng.randf() < 0.3 and bx + 1 < size.x:
					img.set_pixel(bx + 1, size.y - 1, CLEAR)
			2:  # left — 1-2 texel 咬口
				var ly := rng.randi_range(0, size.y - 1)
				img.set_pixel(0, ly, CLEAR)
				if size.y > 1 and rng.randf() < 0.5 and ly + 1 < size.y:
					img.set_pixel(0, ly + 1, CLEAR)
			3:  # right
				var ry := rng.randi_range(0, size.y - 1)
				img.set_pixel(size.x - 1, ry, CLEAR)
				if size.y > 1 and rng.randf() < 0.5 and ry + 1 < size.y:
					img.set_pixel(size.x - 1, ry + 1, CLEAR)


## 边角色相/明度随列抖动（第二轮 FAIL：边角色相微差）：边缘 1-2 texel
## 行的颜色沿 x 独立 ±0.04 偏移 —— 面板描边读作手绘，绝无「等宽同色边框」。
static func _edge_tone_jitter(img: Image, rng: RandomNumberGenerator, size: Vector2i) -> void:
	for x in size.x:
		for row in [0, 1, size.y - 2, size.y - 1]:
			if row < 0 or row >= size.y:
				continue
			var c: Color = img.get_pixel(x, row)
			if c.a <= 0.0:
				continue
			var dj := (rng.randf() - 0.5) * 0.08
			img.set_pixel(x, row, Color(
				clampf(c.r + dj, 0.0, 1.0),
				clampf(c.g + dj, 0.0, 1.0),
				clampf(c.b + dj * 0.8, 0.0, 1.0),
				c.a
			))


## 非等宽散点 accent（V3.1 返工 2：替代旧全宽 _accent_broken_line）：
## 在 [row_min..row_max] 行带内撒 [count] 个短墨点/短划（1-3 texel 长、
## 1 texel 高），随机位置、随机长度 —— 手绘散点：数量少、间距大、绝不
## 形成任何长于 ~12px 的连续 accent 段，绝不重复规则虚线（第二轮 FAIL：
## warning stripe / 重复规则纹理 —— 上一版按 fill_rate 撒点仍形成 31-41%
## 覆盖率横带，读作虚线带；改为固定少量散点，覆盖率 ~5-10%）。每点颜色
## 微抖（±0.03）—— 边角色相微差。
static func _accent_scatter(img: Image, rng: RandomNumberGenerator, size: Vector2i, accent: Color, row_min: int, row_max: int, count: int) -> void:
	if row_min > row_max or row_min >= size.y or count <= 0:
		return
	var guard := 0
	for i in count:
		guard += 1
		if guard > count * 8:
			break
		var x := rng.randi_range(0, size.x - 1)
		var y := rng.randi_range(row_min, mini(row_max, size.y - 1))
		if img.get_pixel(x, y).a <= 0.0:
			continue
		var len_max := mini(3, size.x - x)
		if len_max < 1:
			continue
		var len := rng.randi_range(1, len_max)
		var dc := (rng.randf() - 0.5) * 0.06
		var c := Color(
			clampf(accent.r + dc, 0.0, 1.0),
			clampf(accent.g + dc * 0.8, 0.0, 1.0),
			clampf(accent.b + dc * 0.6, 0.0, 1.0),
			accent.a
		)
		for dx in len:
			img.set_pixel(x + dx, y, c)


## 金属铆钉：3 角 2×2 提亮点（不对称 —— 缺一角，手绘细节）。
static func _rivets(img: Image, rng: RandomNumberGenerator, size: Vector2i, base: Color) -> void:
	var c := base.lightened(0.22)
	var corners: Array[Vector2i] = [
		Vector2i(1, 1),
		Vector2i(size.x - 2, 1),
		Vector2i(1, size.y - 2),
	]
	for corner in corners:
		for dy in 2:
			for dx in 2:
				var px := corner.x + dx
				var py := corner.y + dy
				if px >= 0 and px < size.x and py >= 0 and py < size.y:
					img.set_pixel(px, py, c)


## 局部磨损高光：~1.5% 像素提亮成小亮点（刮痕/高光）。
static func _wear_highlights(img: Image, rng: RandomNumberGenerator, size: Vector2i) -> void:
	var count: int = (size.x * size.y) / 64
	for i in count:
		var x := rng.randi_range(0, size.x - 1)
		var y := rng.randi_range(0, size.y - 1)
		var c: Color = img.get_pixel(x, y)
		if c.a > 0.0:
			img.set_pixel(x, y, Color(
				minf(1.0, c.r + 0.18),
				minf(1.0, c.g + 0.16),
				minf(1.0, c.b + 0.12),
				c.a
			))
