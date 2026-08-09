# src/presentation/lighting_layer.gd — V3.1 P4 pixel-based lighting
#
# 附录 V3.1 P4（灯光改 pixel based）：
#   移除大面积圆形 gradient 光斑（Photoshop 光圈感）→ 光以像素局部变化表达：
#     - 墙附近稍暗（近墙像素变暗）：墙边 cool-dark 像素 cluster（dithered）
#     - 灯下稍亮（灯下区域像素变亮）：灯下 warm-bright 像素 cluster（不规则）
#     - 设备附近局部高光（设备边缘/顶面高光像素）：设备 sprite 自带
#       EQUIP_HIGHLIGHT（V3.1 P2 5 色层），本层不再叠圆形光斑
#     - 发光屏幕小范围亮色：屏幕/指示灯 1-3px 亮像素 cluster（呼吸，无圆）
#   V3 §7 暖环境+冷阴影：受光面（灯下/窗光/屏幕）暖亮像素；背光面（墙边）
#   冷暗像素 —— 光影响材质颜色，不是画透明白色圆。
#
# 实现：静态光照（墙边暗角/灯池/窗光/光锥/饮水机/招牌）烘焙成一张 416×320
# RGBA light map（确定性 hash 散射，无 RNG 状态；同输入永远同输出），每帧
# 1 次 draw_texture_rect（预算友好）；动态部分（已放置设备屏幕呼吸光）每帧
# 少量 1-3px draw_rect —— 全层零 draw_circle。
#
# 层级：本节点是 WorldRoot 的子节点（z_index=1，画在 WorldCanvas 之上，
# 但仍在同一低分辨率 pixel space，经 WorldRoot scale 0.75 进 SubViewport）。
# 叠加在成员/设备之上：暖亮像素让受光面偏暖，冷暗像素让墙边偏冷 —— 氛围
# 效果，不遮挡信息（alpha ≤ 0.22）。
#
# 确定性：所有发光/闪烁都由 tick（注入的 tick_provider）驱动 —— headless
# 测试可断言（同 tick 同输出），渲染也稳定。闪烁用 sin(tick) 相位，缓慢
# 呼吸而非刺眼闪烁（art-bible §9 无闪烁）。
#
# headless 可靠性：跨脚本引用一律 preload alias（项目约定）；grid / resolver
# 鸭子类型注入（presentation seam 约定）。
class_name LightingLayer extends Node2D

const Palette := preload("res://src/palette.gd")
const WorldLayout := preload("res://src/presentation/world_layout.gd")
const Proj2D := preload("res://src/presentation/oblique_projection.gd")

## 发光体类型（emissive 载体，V3 §6）：设备屏幕青蓝/绿 + 饮水机/招牌。
const GLOW_CYAN := "cyan"
const GLOW_GREEN := "green"
const GLOW_WARM := "warm"

## 屏幕小亮点 cluster 尺寸（像素，V3.1 P4「小范围亮色」）。
const SCREEN_CORE_PX := 2
const SCREEN_SPILL_PX := 1

var _grid = null        # GridStateReader（placed instances）
var _resolver: Callable = Callable()   # instance_id -> equipment_id
var _tick_provider: Callable = Callable()  # -> int（闪烁相位）

## 发光体配置：equipment_id -> 发光类型 + 屏幕位置偏移（世界 px，相对 footprint 左上）。
const EQUIPMENT_GLOWS := {
	"treadmill": {"type": GLOW_CYAN, "offset": Vector2(12, 4)},
	"bike": {"type": GLOW_GREEN, "offset": Vector2(6, 8)},
}

var _initialized: bool = false
var _light_map: ImageTexture = null
var _light_map_image: Image = null


## 两阶段 init（ADR-0001 形态）：注入 grid / resolver / tick_provider。
func init(grid, resolver: Callable, tick_provider: Callable) -> void:
	if _initialized:
		push_error("LightingLayer.init(): called twice")
		return
	_initialized = true
	_grid = grid
	_resolver = resolver
	_tick_provider = tick_provider


# === 渲染（世界像素空间；headless 下引擎不调用 _draw，防御性检查） ===
# V3.1 P1：光照是贴地氛围（光池/暗角/光锥/辉光都在地面上）—— 全部经
# floor_transform 投影（光池随地板压缩成椭圆、暗角沿地板边缘）。
# V3.1 P4：静态光照 = 一张 light map 纹理（确定性像素散射，非圆）。

func _draw() -> void:
	draw_set_transform_matrix(Proj2D.floor_transform())
	if _light_map == null:
		_bake_light_map()
	draw_texture_rect(_light_map, Rect2(Vector2.ZERO, Vector2(WorldLayout.WORLD_W, WorldLayout.WORLD_H)), false)
	_draw_equipment_glows()
	draw_set_transform_matrix(Transform2D.IDENTITY)


## 取烘焙后的 light map Image（测试用像素断言；未烘焙时先烘焙）。
func light_map_image() -> Image:
	if _light_map_image == null:
		_bake_light_map()
	return _light_map_image


## 烘焙静态 light map：RGBA8，全透明基底 + 逐像素光照散射。确定性（hash）。
func _bake_light_map() -> void:
	var img := Image.create(WorldLayout.WORLD_W, WorldLayout.WORLD_H, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	_paint_edge_shadow(img)
	_paint_light_pools(img)
	_paint_lamp_cones(img)
	_paint_window_light(img)
	_paint_static_glows(img)
	_light_map_image = img
	_light_map = ImageTexture.create_from_image(img)


## 墙边暗角（V3.1 P4 近墙像素变暗）：EDGE_SHADOW_WIDTH 内散射冷蓝灰暗像素，
## 内缘 jagged（hash 概率随距离衰减，非完美矩形带）。
func _paint_edge_shadow(img: Image) -> void:
	var w := WorldLayout.WORLD_W
	var h := WorldLayout.WORLD_H
	var edge := WorldLayout.EDGE_SHADOW_WIDTH
	for y in range(h):
		for x in range(w):
			var d := _edge_distance(x, y)
			if d >= edge:
				continue
			var t := 1.0 - float(d) / float(edge)   # 1=紧贴墙，0=内缘
			# 散射：近墙覆盖率高，内缘抖动 —— 不规则边界，非完美矩形
			if _hash2(x, y) % 100 >= 82 + int(16.0 * t):
				continue
			var a := 0.08 + 0.10 * t * (0.4 + 0.6 * float(_hash2(x + 31, y + 17) % 100) / 100.0)
			# 角落再压一层（空间纵深，V3 §4/§6）
			if x < edge and y < edge or x >= w - edge and y < edge \
					or x < edge and y >= h - edge or x >= w - edge and y >= h - edge:
				a += 0.04
			var c := Palette.LIGHT_EDGE_SHADOW
			img.set_pixel(x, y, Color(c.r, c.g, c.b, minf(a, 0.22)))


## 顶部暖白主光（V3.1 P4 灯下稍亮 / R4 光源落点 + 衰减）：每盏吊灯下方
## warm-bright 像素 cluster —— 中心热核（落点，alpha 0.20-0.36）+ 软光晕
## （衰减 0.13→0.06）。有方向（光锥）、有落点（热核）、有衰减（边缘稀疏）。
## hash 散射保持不规则边界（无圆形 gradient）；衰减快 —— 邻近装饰（瑜伽区
## 植物等）不会被暖池盖过（R3/P5 证据色保持）。中心点 = WorldLayout.LIGHT_POOLS
## （与 LAMP_CONES 吊灯对齐，P0-4 归属来源）。
func _paint_light_pools(img: Image) -> void:
	var r := WorldLayout.LIGHT_POOL_RADIUS
	for center in WorldLayout.LIGHT_POOLS:
		var c: Vector2 = center
		var x0 := int(c.x - r) - 2
		var y0 := int(c.y - r) - 2
		var x1 := int(c.x + r) + 3
		var y1 := int(c.y + r) + 3
		for y in range(maxi(y0, 0), mini(y1, img.get_height())):
			for x in range(maxi(x0, 0), mini(x1, img.get_width())):
				var d := Vector2(x + 0.5, y + 0.5).distance_to(c)
				if d > r + 2.0:
					continue
				var density := clampf(1.0 - d / (r + 2.0), 0.0, 1.0)
				# 概率散射：中心密、边缘疏 —— 边缘 jagged，无平滑径向 gradient。
				# 分段覆盖：核心（r<9）高密度高亮；中距（9..20）恢复旧覆盖
				# （P5 植物亮叶需足量暖叠压低饱和 —— 否则 FOCAL_GREEN_LIGHT
				# 像素越过 sat 0.72 阈值拆出多余焦点簇）；远缘（>20）稀疏
				# （设备 contact shadow 带不被提亮，R1 层级证据保持）。
				var keep := 0.25 + 0.45 * density
				if d < 9.0:
					keep = 0.85
				elif d < 20.0:
					keep = 0.68
				if float(_hash2(x, y) % 1000) / 1000.0 > keep:
					continue
				# 热核（落点）：r<9 中心高亮；中距 alpha ~0.10-0.15（植物暖叠）；
				# 远缘 ~0.05-0.08（阴影带保持）。
				var core_t := clampf(1.0 - d / 9.0, 0.0, 1.0)
				var a := 0.04 + 0.05 * density
				if d < 9.0:
					a = 0.20 + 0.20 * core_t
				elif d < 20.0:
					a = 0.10 + 0.06 * (1.0 - (d - 9.0) / 11.0)
				a *= (0.85 + 0.15 * float(_hash2(x + 7, y + 11) % 100) / 100.0)
				var pool := Palette.LIGHT_TOP_WARM
				img.set_pixel(x, y, Color(pool.r, pool.g, pool.b, minf(a, 0.42)))


## 吊灯光锥（P0-4 光池来源归属）：从灯罩到地面的四边形内散射暖白像素。
## R4 强化「方向」：密度提高到 ~55%，alpha 提高（0.10-0.18，近灯处略亮）——
## 从灯罩到地面的光锥可辨识（V3 §6 顶部暖白灯，灯下亮）。仍是 hash 散射，
## 非实心半透明四边形。
func _paint_lamp_cones(img: Image) -> void:
	for cone in WorldLayout.LAMP_CONES:
		var pts := PackedVector2Array()
		for p: Vector2 in cone:
			pts.append(p)
		var b := _quad_bounds(pts)
		for y in range(maxi(int(b.position.y), 0), mini(int(b.end.y), img.get_height())):
			for x in range(maxi(int(b.position.x), 0), mini(int(b.end.x), img.get_width())):
				if not Geometry2D.is_point_in_polygon(Vector2(x + 0.5, y + 0.5), pts):
					continue
				# 密度：55% 基底 + 近灯处略密（有方向感）
				var t := clampf((float(y) - b.position.y) / maxf(b.end.y - b.position.y, 1.0), 0.0, 1.0)
				var keep := 0.42 + 0.22 * (1.0 - t)
				if _hash2(x, y) % 100 >= int(keep * 100.0):
					continue
				var c := Palette.LIGHT_TOP_WARM
				var a := 0.14 + 0.10 * (1.0 - t) * (0.6 + 0.4 * float(_hash2(x + 3, y + 5) % 100) / 100.0)
				img.set_pixel(x, y, Color(c.r, c.g, c.b, minf(a, 0.24)))


## 窗口斜向自然光（V3.1 P4 像素化 + R4 冷光渗透）：窗下光锥内散射冷蓝灰像素
## （LIGHT_WINDOW_COOL —— V3 §15 cool colored shadows / 窗边冷光渗透，与室内
## 暖光形成冷暖对比）。低密度低 alpha（冷光弱于主光 —— 环境氛围，不压过
## 设备脚下暖池/区域色温对比，R1 层级证据保持）。
func _paint_window_light(img: Image) -> void:
	for window_rect in WorldLayout.WINDOWS:
		var cone := WorldLayout.window_light_cone(window_rect)
		var b := _quad_bounds(cone)
		# 窗光从锥顶（y=22，窗底）开始画：这些像素投影到 screen y≈267
		# （墙基线/baseboard 行），恰好打破墙地交界的 200px 长直线
		# （R3 A-check —— 旧证据同样依赖这一点）。不做 y 下限钳制。
		var y_start := maxi(int(b.position.y), 0)
		for y in range(maxi(y_start, 0), mini(int(b.end.y), img.get_height())):
			for x in range(maxi(int(b.position.x), 0), mini(int(b.end.x), img.get_width())):
				if not Geometry2D.is_point_in_polygon(Vector2(x + 0.5, y + 0.5), cone):
					continue
				if _hash2(x, y) % 100 >= 45:
					continue
				var c := Palette.LIGHT_WINDOW_COOL
				img.set_pixel(x, y, Color(c.r, c.g, c.b, 0.07 + 0.07 * float(_hash2(x + 13, y + 19) % 100) / 100.0))


## 静态发光体（饮水机/招牌/计时器，V3.1 P4 小范围亮色）：1-3px 亮像素 cluster。
## V3.1 P5：新增红广告牌暖红 glow（高饱和焦点 + P4 亮色表达）。
## V3.1 R4：新增瑜伽区暖色落地灯（warm_lamp_f1）小暖池 + 自行车区墙上计时器
## （timer_bike）青蓝小亮点 —— 「落地灯/壁灯/计时器」光源可辨识（第三眼 #1）。
func _paint_static_glows(img: Image) -> void:
	var fountain_pos: Vector2i = WorldLayout.DECOR.get("fountain", Vector2i(-100, -100))
	if fountain_pos.x >= 0:
		_paint_glow_cluster(img, fountain_pos + Vector2i(12, 16), Palette.EMISSIVE_CYAN, 51)
	var sign_pos: Vector2i = WorldLayout.WALL_DECOR.get("sign_entrance", Vector2i(-100, -100))
	if sign_pos.x >= 0:
		_paint_glow_cluster(img, sign_pos + Vector2i(8, 8), Palette.ACCENT_YELLOW, 83)
	# V3.1 P5 红广告牌：暖红 glow（墙下地面），与 P4 静态发光体同一机制。
	var ad_pos: Vector2i = WorldLayout.WALL_DECOR.get("ad_red", Vector2i(-100, -100))
	if ad_pos.x >= 0:
		_paint_glow_cluster(img, ad_pos + Vector2i(8, 16), Palette.FOCAL_RED, 127)
	# V3.1 R4 暖色落地灯（瑜伽区，DECOR warm_lamp_f1）：灯下小暖池 + 灯罩暖亮点。
	var warm_lamp_pos: Vector2i = WorldLayout.DECOR.get("warm_lamp_f1", Vector2i(-100, -100))
	if warm_lamp_pos.x >= 0:
		_paint_floor_lamp_pool(img, Vector2(warm_lamp_pos) + Vector2(16, 28))
		_paint_glow_cluster(img, warm_lamp_pos + Vector2i(12, 12), Palette.ACCENT_ORANGE, 149)
	# V3.1 R4 墙上计时器（自行车区，WALL_DECOR timer_bike）：青蓝小亮点。
	var timer_pos: Vector2i = WorldLayout.WALL_DECOR.get("timer_bike", Vector2i(-100, -100))
	if timer_pos.x >= 0:
		_paint_glow_cluster(img, timer_pos + Vector2i(12, 8), Palette.EMISSIVE_CYAN, 163)


## 单簇小亮点：2×2 核心 + 若干 1px 散落（hash 偏移），无圆。
func _paint_glow_cluster(img: Image, pos: Vector2i, color: Color, seed: int) -> void:
	for dy in range(2):
		for dx in range(2):
			var px := pos.x + dx
			var py := pos.y + dy
			if px >= 0 and py >= 0 and px < img.get_width() and py < img.get_height():
				img.set_pixel(px, py, Color(color.r, color.g, color.b, 0.30))
	for i in 6:
		var ox := (_hash2(seed + i * 3, i * 7) % 5) - 2
		var oy := (_hash2(i * 11, seed + i * 5) % 5) - 2
		var px := pos.x + 2 + ox
		var py := pos.y + 1 + oy
		if px >= 0 and py >= 0 and px < img.get_width() and py < img.get_height():
			img.set_pixel(px, py, Color(color.r, color.g, color.b,
				0.08 + 0.06 * float(_hash2(px, py) % 100) / 100.0))


## V3.1 R4 落地灯小暖池（瑜伽区 warm_lamp_f1）：灯下小范围暖色提亮 ——
## 光源可辨识（灯罩暖亮点 + 灯下暖池，V3 §12「暖色灯」）。半径 16，alpha
## 0.08-0.16（弱于主光池 —— 局部氛围，不抢主吊灯）；hash 散射无圆。
## 色 = 暖白（LIGHT_TOP_WARM，与主池同族 —— 灯光而非高饱和焦点，避免
## P5 焦点簇计数超限）。
func _paint_floor_lamp_pool(img: Image, center: Vector2) -> void:
	var r := 16.0
	var x0 := int(center.x - r) - 1
	var y0 := int(center.y - r) - 1
	var x1 := int(center.x + r) + 2
	var y1 := int(center.y + r) + 2
	for y in range(maxi(y0, 0), mini(y1, img.get_height())):
		for x in range(maxi(x0, 0), mini(x1, img.get_width())):
			var d := Vector2(x + 0.5, y + 0.5).distance_to(center)
			if d > r:
				continue
			if _hash2(x, y) % 100 >= 45:
				continue
			var t := clampf(1.0 - d / r, 0.0, 1.0)
			var a := 0.06 + 0.10 * t * (0.7 + 0.3 * float(_hash2(x + 5, y + 9) % 100) / 100.0)
			var c := Palette.LIGHT_TOP_WARM
			img.set_pixel(x, y, Color(c.r, c.g, c.b, minf(a, 0.16)))


## 已放置设备屏幕呼吸光（V3.1 P4 小范围亮色像素，无圆 halo）：
## 2×2 核心亮像素 + 3 个 1px 散落（hash 偏移）。闪烁 = sin(tick) 相位。
func _draw_equipment_glows() -> void:
	var tick: int = 0
	if _tick_provider.is_valid():
		tick = _tick_provider.call()
	var phase := 0.5 + 0.5 * sin(tick * 0.25)
	if _grid == null:
		return
	for inst in _grid.get_placed_instances():
		var eq_id := ""
		if _resolver.is_valid():
			eq_id = str(_resolver.call(inst.instance_id))
		if not EQUIPMENT_GLOWS.has(eq_id):
			continue
		var cfg: Dictionary = EQUIPMENT_GLOWS[eq_id]
		var fp := _footprint_rect(inst.footprint_cells)
		var glow_pos: Vector2 = Vector2(fp.position) + (cfg["offset"] as Vector2)
		_draw_screen_cluster(glow_pos, cfg["type"] as String, phase)


## 单个屏幕小亮点 cluster：核心 2×2（呼吸 alpha）+ 3 个 1px 散落。
func _draw_screen_cluster(pos: Vector2, glow_type: String, phase: float) -> void:
	var core := _glow_color(glow_type)
	core.a = 0.35 + 0.25 * phase
	draw_rect(Rect2(pos, Vector2(SCREEN_CORE_PX, SCREEN_CORE_PX)), core, true)
	var spill := _glow_color(glow_type)
	spill.a = 0.10 + 0.08 * phase
	var seed := int(pos.x) * 7 + int(pos.y) * 13
	for i in 3:
		var off := Vector2(
			(_hash2(seed + i * 5, i * 3) % 5) - 2,
			(_hash2(i * 7, seed + i) % 5) - 2
		)
		draw_rect(Rect2(pos + off, Vector2(SCREEN_SPILL_PX, SCREEN_SPILL_PX)), spill, true)


## 发光类型 → 基色（V3 §7：青蓝/绿 emissive；招牌暖黄）。
func _glow_color(glow_type: String) -> Color:
	match glow_type:
		GLOW_CYAN:
			return Palette.EMISSIVE_CYAN
		GLOW_GREEN:
			return Palette.EMISSIVE_GREEN
		GLOW_WARM:
			return Palette.ACCENT_YELLOW
		_:
			return Palette.EMISSIVE_CYAN


## footprint 单元格集合 → 像素 Rect2i（min cell × CELL_SIZE）。
func _footprint_rect(cells: Array) -> Rect2i:
	if cells.is_empty():
		return Rect2i()
	var min_c := Vector2i(cells[0])
	var max_c := Vector2i(cells[0])
	for c in cells:
		min_c.x = min(min_c.x, c.x)
		min_c.y = min(min_c.y, c.y)
		max_c.x = max(max_c.x, c.x)
		max_c.y = max(max_c.y, c.y)
	var cell := 32
	var size := (max_c - min_c + Vector2i.ONE) * cell
	return Rect2i(min_c * cell, size)


# === helpers ===

## 到最近墙边（世界矩形四边）的距离。
func _edge_distance(x: int, y: int) -> int:
	var w := WorldLayout.WORLD_W
	var h := WorldLayout.WORLD_H
	return mini(mini(x, y), mini(w - 1 - x, h - 1 - y))


## 四边形包围盒。
func _quad_bounds(pts: PackedVector2Array) -> Rect2:
	var r := Rect2(pts[0], Vector2.ZERO)
	for p in pts:
		r = r.expand(p)
	return r


## 确定性 2D hash（无 RNG 状态 —— 同输入永远同输出）。
func _hash2(x: int, y: int) -> int:
	var h := x * 374761393 + y * 668265263
	h = (h ^ (h >> 13)) * 1274126177
	return h & 0x7fffffff
