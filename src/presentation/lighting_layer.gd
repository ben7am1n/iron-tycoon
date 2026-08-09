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
# 实现：贴地静态光（墙边暗角/分面灯池/窗光/小发光体）烘焙为 416×320 light
# map；高处灯泡→落点的体积光束另烘焙为投影空间 light map。两张纹理每帧各
# 1 次 draw_texture_rect（确定性 hash，无 RNG）；动态部分只有设备受光边与
# 屏幕呼吸光的少量 1-5px draw_rect —— 全层零 draw_circle。
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
const EquipmentArt := preload("res://src/presentation/equipment_art.gd")

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
var _projected_light_map: ImageTexture = null
var _projected_light_map_image: Image = null
var _projected_light_origin := Vector2.ZERO


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
	draw_set_transform_matrix(Transform2D.IDENTITY)
	# 高处灯泡→地面落点必须在投影后空间连接，不能再随 floor transform 压平。
	if _projected_light_map == null:
		_bake_projected_light_map()
	draw_texture_rect(_projected_light_map,
		Rect2(_projected_light_origin, Vector2(_projected_light_map_image.get_size())), false)
	_draw_equipment_light_hits()
	_draw_equipment_glows()


## 取烘焙后的 light map Image（测试用像素断言；未烘焙时先烘焙）。
func light_map_image() -> Image:
	if _light_map_image == null:
		_bake_light_map()
	return _light_map_image


## 取投影空间静态光图（证据/测试）：包含吊灯长光束、落地灯短投光与灯泡核心。
func projected_light_map_image() -> Image:
	if _projected_light_map_image == null:
		_bake_projected_light_map()
	return _projected_light_map_image


## 投影空间光图左上角（Proj2D canvas 坐标；证据把图像像素还原为画布点）。
func projected_light_map_origin() -> Vector2:
	if _projected_light_map_image == null:
		_bake_projected_light_map()
	return _projected_light_origin


## 烘焙静态 light map：RGBA8，全透明基底 + 逐像素光照散射。确定性（hash）。
func _bake_light_map() -> void:
	var img := Image.create(WorldLayout.WORLD_W, WorldLayout.WORLD_H, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	_paint_edge_shadow(img)
	_paint_light_pools(img)
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


## 顶部主光落点：不是径向圆，而是横宽纵窄的 faceted 像素材质区。
## 中心热核、八边形分段衰减、hash 缺口共同表达「地板材质被暖光照亮」；
## 高处灯泡到这里的方向关系由 projected light map 连续表达。
func _paint_light_pools(img: Image) -> void:
	var seed := 301
	for light: Dictionary in WorldLayout.HANGING_LIGHTS:
		_paint_faceted_pool(img,
			light.get("landing", Vector2.ZERO),
			light.get("pool_half", Vector2(44, 30)), seed, 1.0)
		seed += 97


## 分面暖光落点：metric 是八边形距离，不使用圆/径向 gradient。
func _paint_faceted_pool(img: Image, center: Vector2, half_size: Vector2,
		seed: int, strength: float) -> void:
	var x0 := maxi(int(floor(center.x - half_size.x)) - 2, 0)
	var y0 := maxi(int(floor(center.y - half_size.y)) - 2, 0)
	var x1 := mini(int(ceil(center.x + half_size.x)) + 3, img.get_width())
	var y1 := mini(int(ceil(center.y + half_size.y)) + 3, img.get_height())
	for y in range(y0, y1):
		for x in range(x0, x1):
			var nx := absf((x + 0.5 - center.x) / maxf(half_size.x, 1.0))
			var ny := absf((y + 0.5 - center.y) / maxf(half_size.y, 1.0))
			# max + taxicab 混合得到八边形/阶梯边，不是同心圆。
			var metric := maxf(nx, ny) * 0.62 + (nx + ny) * 0.22
			var edge_jitter := (float(_hash2(x + seed, y - seed) % 100) / 100.0 - 0.5) * 0.10
			if metric + edge_jitter > 1.0:
				continue
			var density := clampf(1.0 - metric, 0.0, 1.0)
			var keep := 0.24 + 0.48 * density
			if metric < 0.27:
				keep = 0.88
			elif metric < 0.55:
				keep = 0.68
			if float(_hash2(x + seed * 3, y + seed) % 1000) / 1000.0 > keep:
				continue
			# 分三档而非平滑透明渐变；每档再用少量 hash 做像素材质变化。
			var a := 0.065
			if metric < 0.27:
				a = 0.30
			elif metric < 0.55:
				a = 0.15
			else:
				a = 0.085
			a *= strength * (0.86 + 0.14 * float(_hash2(x + 7, y + 11) % 100) / 100.0)
			var warm := Palette.LIGHT_TOP_WARM
			img.set_pixel(x, y, Color(warm.r, warm.g, warm.b, minf(a, 0.38)))


## 高处灯泡→地面落点的投影空间光图。与地板 light map 分离：这里不再套
## floor_transform，因此灯罩、光束与落点在最终屏幕上连续。整层烘焙为 1 张
## 纹理（1 draw call），用稀疏条带像素表达 volumetric atmosphere。
func _bake_projected_light_map() -> void:
	var bounds := Proj2D.bounds()
	_projected_light_origin = Vector2(floor(bounds.position.x), floor(bounds.position.y))
	var end := Vector2(ceil(bounds.end.x), ceil(bounds.end.y))
	var size := Vector2i(int(end.x - _projected_light_origin.x),
		int(end.y - _projected_light_origin.y))
	var img := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var seed := 701
	for light: Dictionary in WorldLayout.HANGING_LIGHTS:
		var rect: Rect2i = light.get("rect", Rect2i())
		var height := float(light.get("height", 78.0))
		var bulb_local: Vector2 = light.get("bulb_local", Vector2.ZERO)
		# 灯是 billboard：灯泡画布点 = rect 左上投影 + 纹理内局部点。
		var source := Proj2D.proj(rect.position.x, rect.position.y, height) + bulb_local
		var landing_world: Vector2 = light.get("landing", Vector2.ZERO)
		var landing := Proj2D.project_world(landing_world)
		_paint_projected_shaft(img, source, landing, 3.0, 18.0, seed)
		_paint_projected_source(img, source, seed + 19)
		seed += 113
	# 落地灯短斜投光：同样从灯泡局部点连到东南地面落点。
	var floor_cfg: Dictionary = WorldLayout.FLOOR_LIGHT
	var base: Vector2 = floor_cfg.get("base", Vector2.ZERO)
	var floor_height := float(floor_cfg.get("height", 48.0))
	var floor_source := Proj2D.proj(base.x, base.y, floor_height) \
		+ (floor_cfg.get("bulb_local", Vector2.ZERO) as Vector2)
	var floor_landing_world: Vector2 = floor_cfg.get("landing", base)
	var floor_landing := Proj2D.project_world(floor_landing_world)
	_paint_projected_shaft(img, floor_source, floor_landing, 2.0, 10.0, 1181)
	_paint_projected_source(img, floor_source, 1201)
	_projected_light_map_image = img
	_projected_light_map = ImageTexture.create_from_image(img)


## 稀疏投影光束：沿 source→landing 方向扩张，横向分档 + 纵向断续条带。
func _paint_projected_shaft(img: Image, source_canvas: Vector2,
		landing_canvas: Vector2, top_half: float, bottom_half: float, seed: int) -> void:
	var source := source_canvas - _projected_light_origin
	var landing := landing_canvas - _projected_light_origin
	var axis := landing - source
	var length := axis.length()
	if length < 1.0:
		return
	var direction := axis / length
	var normal := Vector2(-direction.y, direction.x)
	var pts := PackedVector2Array([
		source - normal * top_half, source + normal * top_half,
		landing + normal * bottom_half, landing - normal * bottom_half,
	])
	var b := _quad_bounds(pts)
	for y in range(maxi(int(floor(b.position.y)) - 1, 0),
			mini(int(ceil(b.end.y)) + 2, img.get_height())):
		for x in range(maxi(int(floor(b.position.x)) - 1, 0),
				mini(int(ceil(b.end.x)) + 2, img.get_width())):
			var rel := Vector2(x + 0.5, y + 0.5) - source
			var along := rel.dot(direction)
			if along < 0.0 or along > length:
				continue
			var t := along / length
			var width := lerpf(top_half, bottom_half, t)
			var lateral := absf(rel.dot(normal))
			if lateral > width:
				continue
			var center_t := 1.0 - lateral / maxf(width, 1.0)
			# 中轴/两侧的断续光丝提高方向感；其余区域保持稀疏 dither。
			# dash 只提升像素条带，不填满锥体，最终仍是 pixelated volume。
			var streak := (_hash2(int(along / 3.0) + seed, int(lateral) + seed) % 9) < 2
			var edge_ratio := lateral / maxf(width, 1.0)
			var dash := (int(along) + seed) % 13 < 6 \
				and (lateral < 1.6 or edge_ratio > 0.78)
			var keep := 0.36 + 0.34 * center_t + (0.16 if streak else 0.0) \
				+ (0.22 if dash else 0.0)
			if float(_hash2(x + seed, y + seed * 2) % 1000) / 1000.0 > keep:
				continue
			var endpoint_gain := maxf(1.0 - t * 3.0, (t - 0.78) * 2.0)
			var a := 0.14 + 0.10 * center_t + 0.055 * clampf(endpoint_gain, 0.0, 1.0) \
				+ (0.05 if dash else 0.0)
			# 金黄而非透明白：叠到墙/设备后直接改变材质色温，来源色与灯罩一致。
			var warm := Palette.LAMP_SHADE_LIT
			img.set_pixel(x, y, Color(warm.r, warm.g, warm.b, minf(a, 0.34)))


## 灯泡发光核心：5×3 暖白像素 + 少量 1px 暖橙火花，无圆 halo。
func _paint_projected_source(img: Image, source_canvas: Vector2, seed: int) -> void:
	var p := Vector2i(roundi(source_canvas.x - _projected_light_origin.x),
		roundi(source_canvas.y - _projected_light_origin.y))
	for dy in range(-1, 2):
		for dx in range(-2, 3):
			_set_image_pixel(img, p + Vector2i(dx, dy),
				Color(Palette.LAMP_BULB.r, Palette.LAMP_BULB.g, Palette.LAMP_BULB.b, 0.74))
	for i in 7:
		var off := Vector2i((_hash2(seed + i * 7, i * 3) % 9) - 4,
			(_hash2(i * 5, seed + i * 11) % 7) - 3)
		_set_image_pixel(img, p + off,
			Color(Palette.LAMP_GLOW.r, Palette.LAMP_GLOW.g, Palette.LAMP_GLOW.b, 0.22))


func _set_image_pixel(img: Image, p: Vector2i, color: Color) -> void:
	if p.x >= 0 and p.y >= 0 and p.x < img.get_width() and p.y < img.get_height():
		img.set_pixel(p.x, p.y, color)


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
	# V3.1 R4 暖色落地灯：地面落点使用短斜投光的 landing；灯泡核心在
	# projected map 中贴着竖直灯体画，不能作为地面色块重复绘制。
	var floor_cfg: Dictionary = WorldLayout.FLOOR_LIGHT
	_paint_floor_lamp_pool(img,
		floor_cfg.get("landing", Vector2.ZERO),
		floor_cfg.get("pool_half", Vector2(24, 17)))
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


## 落地灯弱暖落点：复用分面材质光，不画圆；强度低于主吊灯。
func _paint_floor_lamp_pool(img: Image, center: Vector2, half_size: Vector2) -> void:
	_paint_faceted_pool(img, center, half_size, 149, 0.68)


## 设备受光面：每台已放置设备在最接近灯的那一侧获得 2-4px 暖色反射边。
## hit_world = footprint 中心朝最近光落点偏移，所以设备移动或换灯后亮面位置
## 会随源位置变化；这是材质 tint，不是设备周围的透明圆。
func _draw_equipment_light_hits() -> void:
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
		if bool(hit.get("lit", false)) == false:
			continue
		var p: Vector2 = hit.get("point", Vector2.ZERO)
		var strength := float(hit.get("strength", 0.0))
		var warm := Palette.LAMP_SHADE_LIT
		warm.a = 0.18 + 0.18 * strength
		var snapped := Vector2(roundf(p.x), roundf(p.y))
		draw_rect(Rect2(snapped - Vector2(2, 1), Vector2(5, 2)), warm, true)
		var glint := Palette.LAMP_BULB
		glint.a = 0.16 + 0.12 * strength
		draw_rect(Rect2(snapped + Vector2(-1, -2), Vector2(2, 1)), glint, true)


## 设备暖反射计算（测试可直接调用）：返回投影后点与距离衰减。
func _equipment_light_hit_canvas(fp: Rect2i, eq_id: String) -> Dictionary:
	var center := Vector2(fp.position) + Vector2(fp.size) * 0.5
	var nearest := Vector2.ZERO
	var nearest_d := INF
	for light: Dictionary in WorldLayout.HANGING_LIGHTS:
		var landing: Vector2 = light.get("landing", Vector2.ZERO)
		var d := center.distance_to(landing)
		if d < nearest_d:
			nearest_d = d
			nearest = landing
	var floor_landing: Vector2 = WorldLayout.FLOOR_LIGHT.get("landing", Vector2.ZERO)
	var floor_d := center.distance_to(floor_landing)
	if floor_d < nearest_d:
		nearest_d = floor_d
		nearest = floor_landing
	if nearest_d > 112.0:
		return {"lit": false, "point": Vector2.ZERO, "strength": 0.0}
	var toward := (nearest - center).normalized()
	var offset := minf(fp.size.x, fp.size.y) * 0.24
	var hit_world := center + toward * offset
	var height := float(EquipmentArt.EQUIP_HEIGHTS.get(eq_id, EquipmentArt.DEFAULT_EQUIP_HEIGHT))
	return {
		"lit": true,
		"point": Proj2D.proj(hit_world.x, hit_world.y, height + 1.0),
		"strength": clampf(1.0 - nearest_d / 112.0, 0.0, 1.0),
	}


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
		var glow_world: Vector2 = Vector2(fp.position) + (cfg["offset"] as Vector2)
		var height := float(EquipmentArt.EQUIP_HEIGHTS.get(eq_id, EquipmentArt.DEFAULT_EQUIP_HEIGHT))
		# 屏幕属于设备顶面：投影到 z=设备高度，避免旧版 floor_transform 把
		# emissive 亮点落在机器下方地面。
		var glow_pos := Proj2D.proj(glow_world.x, glow_world.y, height + 1.0)
		_draw_screen_cluster(Vector2(roundf(glow_pos.x), roundf(glow_pos.y)),
			cfg["type"] as String, phase)


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
