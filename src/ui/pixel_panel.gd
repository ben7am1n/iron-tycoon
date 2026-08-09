## PixelPanel — V3.1 返工 UI：程序化「手绘像素」面板纹理生成器（单一来源）
##
## 门禁问题（本卡负责）：顶部状态栏/底部建造条呈 CSS 仪表盘式完美矩形 +
## 等宽边框。本模块用确定性生成的 ImageTexture 像素面板取代 StyleBoxFlat
## 面板语言 —— 对应 V3 §15 绝对避免（CSS dashboard aesthetics / HTML-style
## rounded rectangles / macOS window chrome / thin modern UI typography）与
## 附录 V3.1 负面约束（无完美直线 / 无完美矩形 / 无等宽边框 / 无纯色大面积
## 填充 / 无 CSS 仪表盘 UI）。
##
## 生成纹理的像素特征（参考 V3.1 P3「手绘 pixel art」语言）：
##   - 不规则边缘：上下边逐 texel 锯齿 + 随机缺口（磨损），左右边局部内缩
##   - 多色 cluster：底色 + 深/浅同色系散布 cluster（木纹 WOOD / 金属刷纹
##     METAL / 布纹 CLOTH —— 材质化面板，非纯色填充）
##   - 局部磨损高光：少量提亮像素（刮痕/高光点）
##   - 非等宽描边：accent 色粗像素线，断续 + 粗细不一（hand-drawn，绝非
##     等宽闭合边框）
##
## 确定性：纹理内容完全由 [seed] 决定（单次 seeded RNG，固定顺序消费）；
## 同一 seed 每次运行生成相同纹理。绘制端 NEAREST 放大到目标尺寸
## （draw_texture_rect + Control 自身 texture_filter NEAREST）—— 像素
## stair-step 真实。Image + ImageTexture.create_from_image headless 安全
## （4.7.1 probe 验证）。
##
## 性能：每个面板纹理只生成一次（调用方懒缓存），每帧 1 次 draw_texture_rect
## = 1 draw call（HUD 条带 / 建造条条带 / 每 tile 平板 / 工具栏平板）。

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
	_texture_clusters(img, rng, size, base, style)
	_jagged_edges(img, rng, size)
	# 非等宽描边：顶部一条断续 accent 像素线（粗细 1-2 texel 交替），
	# 底部几段 2-3 texel 的短缝线 —— 绝非等宽闭合矩形边框。
	_accent_broken_line(img, rng, size, accent, 1, 0.68)
	_accent_stitches(img, rng, size, accent, 3)
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
	_texture_clusters(img, rng, size, base, style)
	_jagged_edges(img, rng, size)
	if style == Style.METAL:
		_rivets(img, rng, size, base)
	_accent_broken_line(img, rng, size, accent, 1, 0.55)
	_accent_stitches(img, rng, size, accent, 2)
	_wear_highlights(img, rng, size)
	return ImageTexture.create_from_image(img)


## 材质 cluster：底色上散布深/浅同色系像素簇（非纯色大面积填充）。
## 全部写入经边界守卫（texel 尺寸可能很小，如工具栏平板）。
static func _texture_clusters(img: Image, rng: RandomNumberGenerator, size: Vector2i, base: Color, style: int) -> void:
	var count: int = maxi(4, (size.x * size.y) / 36)
	if style == Style.WOOD:
		# 竖木纹：细长暗/亮 streak（1-2 texel 宽，2-6 texel 长）
		for i in count:
			var x := rng.randi_range(0, size.x - 1)
			var y0 := rng.randi_range(0, maxi(0, size.y - 2))
			var len_max := mini(6, size.y - y0)
			if len_max < 2:
				continue
			var len := rng.randi_range(2, len_max)
			var dark := rng.randf() < 0.6
			var c := base.darkened(0.06 + rng.randf() * 0.14) if dark else base.lightened(0.03 + rng.randf() * 0.07)
			for dy in len:
				img.set_pixel(x, y0 + dy, c)
				if rng.randf() < 0.4 and x + 1 < size.x:
					img.set_pixel(x + 1, y0 + dy, c)
	elif style == Style.METAL:
		# 横刷纹：细长水平 streak（金属拉丝）
		for i in count:
			var y := rng.randi_range(0, size.y - 1)
			var x0 := rng.randi_range(0, size.x - 1)
			var len_max := mini(12, size.x - x0)
			if len_max < 1:
				continue
			var len := rng.randi_range(1, len_max)
			var c := base.darkened(0.04 + rng.randf() * 0.10) if rng.randf() < 0.55 else base.lightened(0.03 + rng.randf() * 0.06)
			for dx in len:
				img.set_pixel(x0 + dx, y, c)
	else:
		# 布纹棋盘：1 texel 交替提亮/压暗
		for y in size.y:
			for x in size.x:
				if (x + y) % 3 == 0:
					img.set_pixel(x, y, base.lightened(0.025) if (x + y) % 6 == 0 else base.darkened(0.03))


## 不规则边缘：上/下边逐列 1 texel 锯齿 + 随机缺口（磨损），左右边局部内缩。
static func _jagged_edges(img: Image, rng: RandomNumberGenerator, size: Vector2i) -> void:
	# 上边：约 1/3 列第一行缺一格（锯齿起点错落）
	for x in size.x:
		if rng.randf() < 0.33:
			img.set_pixel(x, 0, CLEAR)
	# 下边：约 1/3 列最后一行缺一格
	for x in size.x:
		if rng.randf() < 0.33:
			img.set_pixel(x, size.y - 1, CLEAR)
	# 随机边缘缺口：每 8 texel 长度约 1 个缺口，1-2 texel 大小
	var chips := maxi(2, (size.x + size.y) / 8)
	for i in chips:
		match rng.randi_range(0, 3):
			0:  # top
				var tx := rng.randi_range(0, size.x - 1)
				img.set_pixel(tx, 0, CLEAR)
				if size.y > 1 and rng.randf() < 0.5:
					img.set_pixel(tx, 1, CLEAR)
			1:  # bottom
				var bx := rng.randi_range(0, size.x - 1)
				img.set_pixel(bx, size.y - 1, CLEAR)
				if size.y > 1 and rng.randf() < 0.5:
					img.set_pixel(bx, size.y - 2, CLEAR)
			2:  # left
				var ly := rng.randi_range(0, size.y - 1)
				img.set_pixel(0, ly, CLEAR)
			3:  # right
				var ry := rng.randi_range(0, size.y - 1)
				img.set_pixel(size.x - 1, ry, CLEAR)


## 非等宽 accent 描边：单行断续像素线，随机加粗 1 texel —— 手绘、非等宽。
static func _accent_broken_line(img: Image, rng: RandomNumberGenerator, size: Vector2i, accent: Color, row: int, fill_rate: float) -> void:
	if row >= size.y:
		return
	for x in size.x:
		if rng.randf() < fill_rate:
			img.set_pixel(x, row, accent)
			if rng.randf() < 0.25 and row + 1 < size.y:
				img.set_pixel(x, row + 1, accent)


## 底部短缝线：几段 2-3 texel 的 accent 短横（局部描边，非闭合）。
static func _accent_stitches(img: Image, rng: RandomNumberGenerator, size: Vector2i, accent: Color, count: int) -> void:
	if size.y < 3 or size.x < 3:
		return
	var row := size.y - 2
	for i in count:
		var x0 := rng.randi_range(0, maxi(0, size.x - 4))
		var len_max := mini(3, size.x - x0)
		if len_max < 2:
			continue
		var len := rng.randi_range(2, len_max)
		for dx in len:
			img.set_pixel(x0 + dx, row, accent)
			img.set_pixel(x0 + dx, row + 1, accent)


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
