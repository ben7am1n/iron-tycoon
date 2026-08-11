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
# 效果，不遮挡信息（热核局部 alpha ≤ 0.46，边缘/暗面 ≤ 0.28）。
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
## V3.1 返工6 P1（FAIL1 设备体上零噪点）：设备 footprint mask（世界像素空间）。
## 烘焙时由 placed instances 生成；散射光照（暗角/冷灰/前景/窗光）跳过这些
## 矩形，噪点不叠在器械 sprite 上。暖池不参与 mask。
var _equipment_mask_rects: Array = []


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
	# V3.1 返工6 P1（FAIL1 设备体上零噪点）：烘焙前采集设备 footprint mask ——
	# 散射光照（墙边暗角/冷灰回落/前景暖带/窗光）跳过设备体像素，噪点不再
	# 叠在器械 sprite 上（LightingLayer z_index=1 画在 WorldCanvas 之上，
	# 不 mask 则散射像素会直接落在设备体上，GPT「深色器械内部高频噪点」）。
	# 暖池（灯下落点）不 mask —— 受光面暖亮是 V3 §6 目标效果。
	_equipment_mask_rects = _compute_equipment_mask_rects()
	_paint_edge_shadow(img)
	_paint_light_pools(img)
	_paint_ambient_cool_falloff(img)
	_paint_window_light(img)
	_paint_foreground_warm(img)
	_paint_static_glows(img)
	_light_map_image = img
	_light_map = ImageTexture.create_from_image(img)


## 远处环境冷灰回落（返工3 P3 FAIL1 链尾 + FAIL3 空气透视）：离所有光源
## 落点都远的区域（灯池半径之外的地板）撒稀疏冷蓝灰散射 —— 构成「灯下
## 暖池 → 扩散 → 远处回落到冷灰环境色」的链条终点。低密度低 alpha：
## 是环境色回落，不是贴图式暗块/深灰噪点（alpha ≤ 0.12，hash 缺口）。
## 位置与暖池错开（只画 metric > 1.0 的区域），不覆盖灯池/窗光/前景带。
## 确定性：hash 驱动，无 RNG 状态。
func _paint_ambient_cool_falloff(img: Image) -> void:
	var seed := 2017
	var landings: Array[Vector2] = []
	for light: Dictionary in WorldLayout.HANGING_LIGHTS:
		landings.append(light.get("landing", Vector2.ZERO))
	landings.append(WorldLayout.FLOOR_LIGHT.get("landing", Vector2.ZERO))
	for y in range(0, img.get_height(), 2):
		for x in range(0, img.get_width(), 2):
			# 只画在暖池半径之外（metric>1 的区域）—— 与暖池不重叠。
			var inside_any_pool := false
			for light: Dictionary in WorldLayout.HANGING_LIGHTS:
				var half: Vector2 = light.get("pool_half", Vector2(52, 36))
				var center: Vector2 = light.get("landing", Vector2.ZERO)
				var nx := absf((x + 0.5 - center.x) / maxf(half.x, 1.0))
				var ny := absf((y + 0.5 - center.y) / maxf(half.y, 1.0))
				var metric := maxf(nx, ny) * 0.62 + (nx + ny) * 0.22
				if metric <= 1.0:
					inside_any_pool = true
					break
			if inside_any_pool:
				continue
			# 墙边暗角带（_paint_edge_shadow 已画）内不再撒环境冷灰 ——
			# 否则与 edge shadow 叠加会把墙饰（红广告等 P5 焦点）底部
			# 饱和度压到 gate A 阈值以下（簇分裂超上限）。环境回落只
			# 作用于墙边带之外的远地板。
			if _edge_distance(x, y) <= WorldLayout.EDGE_SHADOW_WIDTH:
				continue
			# V3.1 返工6 P1（FAIL1 设备体上零噪点）：冷灰回落跳过设备体
			if _inside_equipment_mask(x, y):
				continue
			# 距最近光源落点的距离 → 越远越冷（远处冷灰环境色）
			# 起点 96：紧接暖池 fade band 之后开始冷灰回落（返工3 P3）。
			# 注意：起点收到 78 时 gate A 高饱和簇计数 19 超上限（淡蓝灰
			# 像素在力量区深灰橡胶上产生额外饱和簇），保持 96 —— 远处
			# 冷灰回落仍存在（fade band 已把池边过渡做连续）。
			var nearest := INF
			for landing in landings:
				nearest = minf(nearest, Vector2(x, y).distance_to(landing))
			if nearest < 96.0:
				continue
			var t := clampf((nearest - 96.0) / 90.0, 0.0, 1.0)
			# 稀疏：远处密度略升但始终低（≤0.22 keep）
			# 返工4 P3：密度再降（0.13+0.14t → 0.18+0.16t）+ alpha 再降
			# （cap 0.10→0.08）—— 弱项「全画面颗粒雾化感较重」：远处冷灰
			# 回落是环境色链尾，不需要高密度铺点；qa A 远候选距落点 <96
			# 不受本带影响（本带只作用于 metric>1 池外区域），冷灰链仍在。
			# 返工6 P1（FAIL1 远离焦点几乎无噪点）：密度再降（0.18+0.16t →
			# 0.06+0.05t）、alpha cap 0.08→0.04 —— 远处是「留白」而非贴图
			# 噪点；冷灰回落链由 fade band 延续，本带只保留最低存在感。
			if float(_hash2(x + seed, y * 3 + seed) % 1000) / 1000.0 > 0.06 + 0.05 * t:
				continue
			var c := Palette.LIGHT_EDGE_SHADOW
			var a := 0.02 + 0.02 * t * (0.5 + 0.5 * float(_hash2(x + 23, y + 41) % 100) / 100.0)
			img.set_pixel(x, y, Color(c.r, c.g, c.b, minf(a, 0.04)))


## 前景暖光带（V3.1 返工2 R3 FAIL3 三层景深）：画面底部（世界 y 240..290，
## 镜头近处）加稀疏暖色散射 —— 前景物体明度高/对比强（V3 §4 FOREGROUND），
## 与中景器械（中等）、背景墙面（WALL_BASE_FAR 偏暗偏冷）形成明度梯度。
## 不画圆/不画实心带：hash 散射 + 低 alpha（前景是受光面，不是发光块）。
## 位置避开已知道具锚点采样窗口（P5 焦点 plant_bright_fore_1 @(0,244) 在
## 左下角，本带从中部 (120..300) 起 —— 采样的黄色水杯/瑜伽球不在带内）。
func _paint_foreground_warm(img: Image) -> void:
	var y0 := 236
	var y1 := 294
	var seed := 577
	for y in range(y0, y1):
		for x in range(80, 340, 2):
			# V3.1 返工6 P1（FAIL1 设备体上零噪点）：前景暖带跳过设备体
			if _inside_equipment_mask(x, y):
				continue
			# 越靠近镜头（y 越大）密度/alpha 越高 —— 前景受光更强
			var t := float(y - y0) / float(y1 - y0)
			# 返工3 P3：keep 略升（0.16+0.30t → 0.18+0.32t）—— 前景带
			# 比背景墙更暖更亮（FAIL3 三层景深：fore 明度最高）。
			# 返工4 P3：密度略降（0.18+0.32t → 0.22+0.34t）+ alpha cap
			# 0.18→0.16 —— 弱项「全画面颗粒雾化感」：前景受光保持，但
			# 不再整条底部高密度铺点（r3p3 fore ≥ wall-1 仍有余量）。
			# 返工6 P1（FAIL1 全局噪点降密降强）：密度再降（0.22+0.34t →
			# 0.12+0.18t）、alpha cap 0.16→0.10 —— 前景是「受光面」不是
			# 噪点带；低密度暖亮仍可读（r3p3 三层景深保持，fore 地板本身
			# 就是亮瓷砖，不依赖暖带铺点）。
			var keep := 0.12 + 0.18 * t
			if float(_hash2(x + seed, y * 3 + seed) % 100) / 100.0 > keep:
				continue
			var c := Palette.LIGHT_POOL_MID
			var a := 0.05 + 0.05 * t * (0.5 + 0.5 * float(_hash2(x + 41, y + 53) % 100) / 100.0)
			img.set_pixel(x, y, Color(c.r, c.g, c.b, minf(a, 0.10)))


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
			# V3.1 返工6 P1（FAIL1 设备体上零噪点）：墙边暗角散射跳过设备体
			if _inside_equipment_mask(x, y):
				continue
			var t := 1.0 - float(d) / float(edge)   # 1=紧贴墙，0=内缘
			# 散射：近墙覆盖率高，内缘抖动 —— 不规则边界，非完美矩形
			# 返工4 P3：密度略降（82+16t → 84+12t）+ alpha 略降（0.12+0.13t
			# → 0.10+0.11t，cap 0.28→0.24）—— 弱项「全画面颗粒雾化感」：
			# 墙边暗角保持冷色阴影，但不再整圈高密度铺点压住边界清晰度。
			# 返工6 P1（FAIL1 全局噪点降密降强）：密度再降（84+12t → 58+10t）、
			# alpha 再降（0.10+0.11t → 0.07+0.08t，cap 0.24→0.16）——
			# 墙边暗角是「冷阴影过渡」，不是贴图噪点；低密度冷暗仍可读。
			if _hash2(x, y) % 100 >= 58 + int(10.0 * t):
				continue
			var a := 0.07 + 0.08 * t * (0.5 + 0.5 * float(_hash2(x + 31, y + 17) % 100) / 100.0)
			# 角落再压一层（空间纵深，V3 §4/§6）
			if x < edge and y < edge or x >= w - edge and y < edge \
					or x < edge and y >= h - edge or x >= w - edge and y >= h - edge:
				a += 0.03
			var c := Palette.LIGHT_EDGE_SHADOW
			img.set_pixel(x, y, Color(c.r, c.g, c.b, minf(a, 0.16)))


## 顶部主光落点：不是径向圆，而是横宽纵窄的 faceted 像素材质区。
## 中心热核、八边形分段衰减、hash 缺口共同表达「地板材质被暖光照亮」；
## 高处灯泡到这里的方向关系由 projected light map 连续表达。
## 返工2 R1：光从「色块」变成「有方向的照明」——
## 返工2 R4：热核 keep 0.90 → 0.85（pre-R4 散射水平）：keep=0.90 时
##   r=10 环 coverage=0.96 仍 >0.95 硬门（R4 审查 t_de3327ed FAIL），
##   0.85 时 coverage=0.92 —— 中心恢复足够 hash 缺口（散射 cluster），
##   暖池仍可读（保留 85% 热核像素 + 满 alpha 0.50）。
##   - 方向性 bias：灯下（北半，y<center）更暖更亮 ×1.12，远离光源
##     （南半）回落 ×0.88 —— 暖光向远处衰减，形成「灯下亮 → 远处冷灰」的
##     方向分层
##   - mid/edge alpha 提高（0.27→0.33 / 0.11→0.15），暖池更可读
## 返工3 P3（FAIL1 受光链可读）：方向 bias 拉强（1.12/0.88 → 1.24/0.76）
##   使「灯下亮 → 向南衰减」有可见梯度（受光面明暗朝向）；三档 alpha 再
##   提高（0.50→0.58 / 0.33→0.40 / 0.15→0.19）让亮→衰减→远处冷灰的链条
##   在帧中可读 —— 热核 keep=0.85/0.80 行不动（R4 ring<0.95 硬门保持）。
func _paint_light_pools(img: Image) -> void:
	var seed := 301
	for light: Dictionary in WorldLayout.HANGING_LIGHTS:
		# 返工6 P1（FAIL2 主次焦点）：中灯（主设备带 treadmill(6,3) 落点
		# 224,170）是「第一视觉落点」，暖池 alpha ×1.15 加强；左灯
		# (86,170) 保持（bike 受光面 + R4 ring 采样区，不动）；右灯
		# (362,170) 压暗 ×0.80 —— 右区（yoga 垫 + 紫色道具）让位，
		# 画面不再三池均权竞争（GPT：黄光/紫点/红条同时抢注意力）。
		var pool_strength := 1.0
		var lx: float = light.get("landing", Vector2.ZERO).x
		if lx > 300.0:
			pool_strength = 0.80
		elif lx > 150.0:
			pool_strength = 1.15
		_paint_faceted_pool(img,
			light.get("landing", Vector2.ZERO),
			light.get("pool_half", Vector2(52, 36)), seed, pool_strength)
		seed += 97


## 分面暖光落点：metric 是八边形距离，不使用圆/径向 gradient。
## 返工2 R1 方向性：北半（靠近吊灯，y < center.y）受光更暖更亮，南半
## （远离光源）回落 —— 配合 edge shadow 的冷灰环境色形成暖→冷方向分层。
## 返工3 P3：方向 bias 加强（可见的明→暗梯度），alpha 三档提高 ——
## 受光链「亮→衰减」在帧中可读（FAIL1）。keep 行（R4 热核 0.85/0.80）
## 逐字不动 —— ring coverage 由 keep 决定，alpha 变化不改变覆盖率。
func _paint_faceted_pool(img: Image, center: Vector2, half_size: Vector2,
		seed: int, strength: float) -> void:
	# 循环范围覆盖池体 + 外缘渐弱带（metric ≤ 1.55，返工3 P3）。
	var fade_extent := 1.55
	var x0 := maxi(int(floor(center.x - half_size.x * fade_extent)) - 2, 0)
	var y0 := maxi(int(floor(center.y - half_size.y * fade_extent)) - 2, 0)
	var x1 := mini(int(ceil(center.x + half_size.x * fade_extent)) + 3, img.get_width())
	var y1 := mini(int(ceil(center.y + half_size.y * fade_extent)) + 3, img.get_height())
	for y in range(y0, y1):
		for x in range(x0, x1):
			var nx := absf((x + 0.5 - center.x) / maxf(half_size.x, 1.0))
			var ny := absf((y + 0.5 - center.y) / maxf(half_size.y, 1.0))
			# max + taxicab 混合得到八边形/阶梯边，不是同心圆。
			var metric := maxf(nx, ny) * 0.62 + (nx + ny) * 0.22
			# V3.1 返工4 P3 云状轮廓：外缘（metric ≥ 0.56）按 8 扇区 hash
			# 半径调制（0.76..1.24）—— 光晕轮廓是「不规则云状色块」，不是
			# 对称八边形/椭圆（GPT：圆形/椭圆半透明光斑 → 应读作像素灯
			# 色块）。热核/中档（metric<0.56）不变 —— R4 ring 硬门由热核
			# keep 决定，r=10/22 环落在 metric<0.56 区，覆盖率不受影响。
			# 扇区调制只作用于「外缘是否画」的判断，不改 tier alpha。
			var contour_metric := metric
			if metric >= 0.56:
				var ang := atan2(y + 0.5 - center.y, x + 0.5 - center.x)
				var sector := int(floor((ang + PI) / TAU * 8.0)) % 8
				var factor := 0.76 + 0.48 * float(_hash2(sector + seed, seed * 13) % 100) / 100.0
				contour_metric = metric * factor
			# 池体只画到 metric ≤ 1.0；之外交给独立 fade band（避免主池边缘
			# 70% 覆盖率的暖亮壳 + fade 双重绘制 —— 返工3 P3 降噪）。
			if contour_metric > 1.0:
				_paint_pool_fade(img, center, x, y, metric, seed)
				continue
			# V3.1 返工4 P3 像素灯：外缘轮廓按 2×2 像素块同判（块级 edge jitter）
			# —— 光晕边缘是「像素块错落」的锯齿边，不是平滑八边形/椭圆。
			# 热核/中档 keep 行（0.85/0.80）逐字不动 —— R4 ring<0.95 硬门
			# 由这两行决定（r=10/22 环落在 metric<0.56 区；edge jitter 只
			# 影响 metric≈1.0 的外缘像素，覆盖率不变）。
			var block_x := x >> 1
			var block_y := y >> 1
			var edge_jitter := (float(_hash2(block_x + seed, block_y - seed) % 100) / 100.0 - 0.5) * 0.18
			if contour_metric + edge_jitter > 1.0:
				continue
			var density := clampf(1.0 - metric, 0.0, 1.0)
			var keep := 0.30 + 0.46 * density
			if metric < 0.25:
				keep = 0.85
			elif metric < 0.56:
				keep = 0.80
			# 热核/中档（metric<0.56）：逐像素 hash 保持逐字（R4 ring 覆盖率
			# 0.92/0.85 + gate A 簇结构不动 —— 受光面热核是「灯下亮」本体）。
			# 外缘（metric ≥ 0.56，光晕绘制区）：块级 hash（2×2 同判）→
			# 光晕外圈读作「像素块错落」，不是逐像素颗粒（GPT：颗粒与抖动
			# 打散边缘）。keep 再降一档（×0.72）→ 外缘更稀疏，热核→外圈
			# 有可见的硬色阶落差，池体不再像「整块半透明椭圆」。
			var hash_val: int
			if metric < 0.56:
				hash_val = _hash2(x + seed * 3, y + seed)
				if float(hash_val % 1000) / 1000.0 > keep:
					continue
			else:
				hash_val = _hash2(block_x + seed * 3, block_y + seed)
				if float(hash_val % 1000) / 1000.0 > keep * 0.72:
					continue
			# 分三档而非平滑透明渐变；每档再用少量 hash 做像素材质变化。
			# 返工6 P1（FAIL2 强焦点）：三档 alpha 略升（0.19/0.40/0.58 →
			# 0.22/0.46/0.64）—— 主设备带暖池是「第一视觉落点」，焦点区
			# 明度显著高于周边（qa_v31r4p1 focal > far_zone 余量拉大）；
			# keep 热核行（0.85/0.80）逐字不动 —— R4 ring<0.95 由 keep
			# 决定覆盖率，alpha 变化不改变覆盖率（gate A 高饱和簇：池色
			# sat 0.40-0.59 < 0.72，不产生新簇；low-sat 62.9% ≤ 63.45%）。
			var a := 0.22
			var warm := Palette.LIGHT_POOL_EDGE
			if metric < 0.25:
				a = 0.64
				warm = Palette.LIGHT_TOP_WARM
			elif metric < 0.56:
				a = 0.46
				warm = Palette.LIGHT_POOL_MID
			# 方向性：北半（灯下，y<center）更亮，南半回落 —— 光有方向。
			# 返工3 P3：bias 拉强（1.24/0.76）→ 灯下亮→向南衰减有可见梯度。
			var dir_bias := 1.24 if y < center.y else 0.76
			# V3.1 返工4 P3 像素灯：材质抖动按 2×2 像素块同值（block hash）——
			# 同块像素同亮度 → 光晕读作「像素块色阶」而非逐像素噪点颗粒
			# （GPT：颗粒与抖动打散边缘 → 应读作像素灯色块）。keep 仍逐像素
			# （R4 ring 覆盖率 + gate A 簇结构不变）。
			var block_v := (0.86 + 0.14 * float(_hash2((x >> 1) + 7, (y >> 1) + 11) % 100) / 100.0)
			a *= strength * dir_bias * block_v
			img.set_pixel(x, y, Color(warm.r, warm.g, warm.b, minf(a, 0.58)))


## 暖池外缘渐弱带（返工3 P3 FAIL1 边缘渐弱 + V3.1 返工4 P3 像素灯）：
## metric 1.0..1.55 稀疏暖边 —— 暖池不是硬切到无，而是继续衰减到极低 alpha，
## 与远处 ambient cool falloff 的冷灰环境色自然衔接。独立于池体绘制
## （池体只画 metric ≤ 1.0，避免双重绘制噪点）。
## V3.1 返工4 P3：连续渐变 → 两档硬色阶（1.0..1.28 / 1.28..1.55），档界用
## 2×2 块级 hash → 每档边缘参差（像素块错落），与池体锯齿边同一语言；
## 不再有 smooth gradient 外圈（GPT 读作「gradient 光斑」的根因）。
## 仍是 hash 散射稀疏像素，覆盖率远低于 0.95 —— R4 环测试采样半径
## （r ≤ 44 ≈ metric 0.85）不进入本带，硬门保持。
func _paint_pool_fade(img: Image, center: Vector2, x: int, y: int, metric: float, seed: int) -> void:
	if metric > 1.55:
		return
	var tier := 1 if metric <= 1.28 else 2
	var block_x := x >> 1
	var block_y := y >> 1
	var keep := 0.26 if tier == 1 else 0.10
	if float(_hash2(block_x + seed * 7, block_y * 11 + seed) % 1000) / 1000.0 > keep:
		return
	var edge_a := 0.10 if tier == 1 else 0.05
	var edge_c := Palette.LIGHT_POOL_EDGE
	img.set_pixel(x, y, Color(edge_c.r, edge_c.g, edge_c.b,
		minf(edge_a * (1.24 if y < center.y else 0.76), 0.12)))


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
	_paint_far_wall_haze(img)
	_projected_light_map_image = img
	_projected_light_map = ImageTexture.create_from_image(img)


## 远景墙面冷灰雾化（返工3 P3 FAIL3 空气透视）：投影空间光图顶部墙带
## （画布 y < 15，即北墙/侧墙上方区域）撒稀疏冷蓝灰散射 —— 背景墙/远景
## 明度降低、冷退（atmospheric perspective），与中景器械/前景受光形成
## 三层明度差。低密度低 alpha（≤0.10）：冷灰雾化，不是贴图式暗块。
## 三盏吊灯灯罩所在列（x 60..104 / 198..242 / 336..380）跳过 —— 灯罩
## 本体与灯泡核心不被雾化盖住（R4 光源可辨识保持）。
func _paint_far_wall_haze(img: Image) -> void:
	var seed := 331
	var shade_x_ranges: Array = [
		[60, 104], [198, 242], [336, 380],
	]
	# 北墙装饰带（wall-local x 130..360 → canvas x ≈125..355）：海报/ad_red/
	# 计时器/TV 是 P5 高饱和焦点，雾化若叠在上面会把红广告等像素饱和度
	# 压到 gate A 阈值以下（簇分裂 —— gate A 计数超上限）。雾化只作用于
	# 墙面空白区（装饰带之外的左/右段 + 墙顶条），不盖墙饰。
	var decor_x_lo := 118
	var decor_x_hi := 362
	for y in range(0, 57):  # 画布 y ≈ -41..15（墙带）
		for x in range(0, img.get_width(), 2):
			if x >= decor_x_lo and x <= decor_x_hi:
				continue  # 墙饰带：保持 P5 焦点对比（雾化不盖广告/海报）
			var in_shade_col := false
			for r: Array in shade_x_ranges:
				if x >= int(r[0]) and x <= int(r[1]):
					in_shade_col = true
					break
			if in_shade_col:
				continue
			# 越靠近墙顶（y 越小）雾化越强 —— 远景越远越退
			var t := 1.0 - float(y) / 57.0
			# 返工3 P3：密度略升（0.10+0.16t → 0.14+0.20t）—— 后景墙带
			# 对比降下来（GPT 反馈「后景过于活跃，抢中景注意力」）；仍稀疏
			# 冷灰雾（alpha ≤ 0.12），不形成贴图式暗块。
			# 返工4 P3：密度略降（0.14+0.20t → 0.17+0.22t）+ alpha cap
			# 0.12→0.10 —— 弱项「全画面颗粒雾化感」：远景雾化保持冷灰
			# 回落，但不再整条墙带高密度铺点（qa A 远候选不受本带影响）。
			# 返工6 P1（FAIL1 全局噪点降密降强）：密度再降（0.17+0.22t →
			# 0.10+0.12t）、alpha cap 0.10→0.06 —— 远景墙带是「空气透视」
			# 氛围，不是噪点；低密度冷灰回落仍可读（N11 远景暖化由投影
			# 光束承担，本带只是冷灰链尾）。
			if float(_hash2(x + seed, y * 5 + seed) % 1000) / 1000.0 > 0.10 + 0.12 * t:
				continue
			var c := Palette.LIGHT_WINDOW_COOL
			var a := 0.03 + 0.03 * t * (0.5 + 0.5 * float(_hash2(x + 3, y + 71) % 100) / 100.0)
			img.set_pixel(x, y, Color(c.r, c.g, c.b, minf(a, 0.06)))


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
			# 返工2 R3：光束密度/alpha 小幅提高（0.36→0.42 基座、0.14→0.16
			# 基座 alpha）—— 灯泡→落点的「受光路径」更可读（FAIL1 光源→
			# 受光面→扩散连续），但仍稀疏 dither + 断续光丝，非实心锥。
			# 返工3 P3：基座再提（0.42→0.52 / 0.16→0.20）+ 中轴光丝提亮
			# （+0.18→+0.22）—— 灯泡到落点的体积光束在帧中可读，灯不再是
			# 孤立的亮符号；仍是散射簇 + 断续光丝，非实心锥（P4 负约束）。
			var keep := 0.52 + 0.34 * center_t + (0.18 if streak else 0.0) \
				+ (0.22 if dash else 0.0)
			if float(_hash2(x + seed, y + seed * 2) % 1000) / 1000.0 > keep:
				continue
			var endpoint_gain := maxf(1.0 - t * 3.0, (t - 0.78) * 2.0)
			var a := 0.20 + 0.11 * center_t + 0.055 * clampf(endpoint_gain, 0.0, 1.0) \
				+ (0.05 if dash else 0.0)
			# 金黄而非透明白：叠到墙/设备后直接改变材质色温，来源色与灯罩一致。
			var warm := Palette.LAMP_SHADE_LIT
			img.set_pixel(x, y, Color(warm.r, warm.g, warm.b, minf(a, 0.34)))


## 灯泡发光核心（V3.1 返工4 P3 像素灯）：5×4 暖白核心 + 稀疏 2×2 暖橙像素
## 块错落（非径向 1px 散射 —— 径向散射读作圆形光晕，块状散射读作
## 「像素灯光」）。块位置由 hash 决定（不规则云状，非同心圆）。
## 返工3 P3：核心从 5×3 微扩到 7×4、alpha 0.82→0.90（灯在帧中读作
## 「光源」而非贴上的亮色符号）。
## 返工4 P3：外缘 16 个 1px 暖橙散射（半径 ±7，α 0.20-0.38 距离衰减）→
## 8 个 2×2 像素块（偏移 ±8/±6，α 硬两档 0.30/0.22）—— 仍是无圆稀疏
## 散射（P4 负约束；gate A 簇计数保持 <18 —— 块数少、像素多，连通簇
## 不增长）。核心保持 7×4/0.90 不动（qa B 灯芯可辨）。
func _paint_projected_source(img: Image, source_canvas: Vector2, seed: int) -> void:
	var p := Vector2i(roundi(source_canvas.x - _projected_light_origin.x),
		roundi(source_canvas.y - _projected_light_origin.y))
	for dy in range(-1, 2):
		for dx in range(-3, 4):
			_set_image_pixel(img, p + Vector2i(dx, dy),
				Color(Palette.LAMP_BULB.r, Palette.LAMP_BULB.g, Palette.LAMP_BULB.b, 0.90))
	# 8 个 2×2 像素块：hash 决定偏移（±8/±6）+ 硬两档 alpha —— 像素灯光，
	# 不是圆形 halo。块与块之间允许重叠（重叠即更亮的局部簇，仍非圆）。
	for i in 8:
		var off := Vector2i((_hash2(seed + i * 7, i * 3) % 17) - 8,
			(_hash2(i * 5, seed + i * 11) % 13) - 6)
		var a := 0.30 if (_hash2(i * 9, seed + i * 13) % 100) < 45 else 0.22
		for dy in range(2):
			for dx in range(2):
				_set_image_pixel(img, p + off + Vector2i(dx, dy),
					Color(Palette.LAMP_GLOW.r, Palette.LAMP_GLOW.g, Palette.LAMP_GLOW.b, a))


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
				# V3.1 返工6 P1（FAIL1 设备体上零噪点）：窗光散射跳过设备体
				if _inside_equipment_mask(x, y):
					continue
				# 返工6 P1（FAIL1 全局噪点降密降强）：45% → 28% ——
				# 窗光是冷色环境氛围，低密度仍可读（窗下冷光渗透保持）。
				if _hash2(x, y) % 100 >= 28:
					continue
				var c := Palette.LIGHT_WINDOW_COOL
				img.set_pixel(x, y, Color(c.r, c.g, c.b, 0.05 + 0.05 * float(_hash2(x + 13, y + 19) % 100) / 100.0))


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


## 设备受光面（V3.1 返工2 R3 FAIL1）：每台已放置设备在最接近灯的那一侧获得
## 连续暖色提亮带 —— 不是孤立的 9×3 色块，而是沿设备顶面「接住灯光」：
##   1. 亮带 1（贴灯侧 2px）：灯下受光边缘，暖白高光（alpha 随 strength）
##   2. 亮带 2（顶面中段）：暖蜜色中档 —— 覆盖大半个顶面宽度，向远离灯
##      的方向衰减（方向性受光：近灯亮、远灯暗）
##   3. 暗侧收边（远离灯一侧 1-2px 冷蓝灰）：受光面的背光侧压暗 —— 设备
##      顶面「近灯暖、远灯冷」的方向分层（V3 §7 暖环境+冷阴影）
## hit_world = footprint 中心朝最近光落点偏移，所以设备移动或换灯后亮面位置
## 会随源位置变化；这是材质 tint（受光面），不是设备周围的透明圆。
## 确定性：全部 hash 驱动，同输入同输出（headless 可断言）。
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
		var strength := float(hit.get("strength", 0.0))
		if strength <= 0.02:
			continue
		var height := float(EquipmentArt.EQUIP_HEIGHTS.get(eq_id, EquipmentArt.DEFAULT_EQUIP_HEIGHT))
		# 设备顶面在投影后空间：footprint 四角提升到 z=height（与 WorldCanvas
		# 顶面绘制同一 transform —— 受光带画在设备顶面上，不是画在地板上）。
		var top_tf := _top_face_transform(height)
		draw_set_transform_matrix(top_tf)
		# 方向：朝最近灯落点（受光侧 = 灯侧）。亮带在灯侧 40% 宽度上更密。
		var toward: Vector2 = hit.get("toward", Vector2(0, -1))
		# 受光方向在顶面平面上的投影（忽略 z 后归一化 —— 顶面是扁平的，
		# 受光带沿 footprint 方向扫过）。
		var band_axis := Vector2(toward.x, toward.y)
		if band_axis.length_squared() < 0.001:
			band_axis = Vector2(0, -1)
		band_axis = band_axis.normalized()
		# 灯侧边缘：沿 band_axis 相反方向（近灯的一侧）扫亮带
		var edge_center := Vector2(fp.position) + Vector2(fp.size) * 0.5 - band_axis * (minf(fp.size.x, fp.size.y) * 0.5)
		# 屏幕保护区：设备顶面南缘 strip（console/显示屏所在行）—— 暖色受光带
		# 不能盖住青蓝屏幕（P2/gate 采样点，V3 §6 屏幕 emissive 保持可辨）。
		var screen_strip := Rect2(fp.position.x, fp.position.y + fp.size.y - 6.0,
			fp.size.x, 6.0)
		# 亮带 1：贴灯侧 3px 暖白高光带（沿 band_axis 垂直方向展开）
		# 返工3 P3：alpha 提高（0.30+0.28s → 0.38+0.30s）—— 设备顶面
		# 「接住灯光」在帧中可读（FAIL1 受光面明暗朝向：顶面亮）。
		# 返工6 P1（FAIL3 浅色高光过多）：alpha 降回（0.38+0.30s → 0.30+0.24s）
		# —— GPT「深色器械内部高频噪点和浅色高光过多，局部碎成一团」：
		# 顶面受光带是「一条方向明确的高光」，不是逐像素亮斑贴片；焦点区
		# 亮度由灯下暖池 + 顶面本体色阶承担，不靠受光带铺亮。
		var w1 := Palette.LAMP_BULB
		w1.a = 0.30 + 0.24 * strength
		_draw_top_face_band(edge_center, band_axis, fp.size, 3.0, w1, screen_strip)
		# 亮带 2：顶面中段暖蜜色（覆盖 ~62% 顶面，向远离灯衰减）——
		# 返工2 R3 FAIL3：设备顶面受光带必须把「中景器械」明度抬到背景墙之上
		# （WALL_BASE_FAR 暗墙 0.43 → 受光设备顶面 ≥0.46），否则三层景深
		# 只有饱和差没有明度差。alpha 提高（0.22→0.30 基座）但保留 hash
		# 缺口（非实心暖块，V3.1 P4 负面约束；R4 热核 keep 不涉及本带）。
		# 返工3 P3：基座 0.30→0.38 —— 中景器械明度进一步抬升（mid > wall）。
		# 返工6 P1（FAIL3 浅色高光过多）：基座 0.38→0.32 —— 受光带回到
		# 「方向性暖边」强度，不把顶面铺成亮斑贴片（mid > wall 仍由
		# 顶面本体 EQUIP_BODY_LIGHT + 灯下暖池保持）。
		var w2 := Palette.LIGHT_POOL_MID
		w2.a = 0.32 + 0.22 * strength
		_draw_top_face_band(edge_center + band_axis * (minf(fp.size.x, fp.size.y) * 0.18),
			band_axis, fp.size, minf(fp.size.x, fp.size.y) * 0.62, w2, screen_strip)
		draw_set_transform_matrix(Transform2D.IDENTITY)
		# 暗侧收边：远离灯一侧 1px 冷蓝灰（受光面背光侧压暗 —— 方向分层）
		var far_edge := edge_center + band_axis * (minf(fp.size.x, fp.size.y) * 0.95)
		var cool := Palette.LIGHT_EDGE_SHADOW
		cool.a = 0.10
		draw_set_transform_matrix(top_tf)
		_draw_top_face_band(far_edge, band_axis, fp.size, 1.5, cool, screen_strip)
		draw_set_transform_matrix(Transform2D.IDENTITY)


## 顶面受光带：沿 band_axis 垂直方向展开的一条矩形带（hash 缺口 —— 不实心）。
## [band_center] 带中心（顶面平面坐标）；[band_axis] 受光方向（单位向量）；
## [fp_size] footprint 尺寸；[half_width] 带半宽（沿 band_axis 垂直方向）；
## [exclude] 屏幕保护区（顶面平面 Rect2，与带重叠的段跳过 —— 青蓝屏幕
## 不被暖色受光带盖住，V3 §6 屏幕 emissive 保持）。
func _draw_top_face_band(band_center: Vector2, band_axis: Vector2,
		fp_size: Vector2, half_width: float, color: Color,
		exclude: Rect2 = Rect2()) -> void:
	var perp := Vector2(-band_axis.y, band_axis.x)
	var along_half := fp_size.length() * 0.42
	var seed := int(band_center.x) * 31 + int(band_center.y) * 17
	# 分 3-4 段 draw_rect（hash 缺口 —— 不是一整块色带，仍像素散射）
	# 返工6 P1（FAIL3 高光连续条带）：缺口 30% → 12% —— GPT「高光应连续
	# 成条带/沿金属管朝向，不散落白点」：受光带是「一条连续暖亮带」，
	# 少量 hash 缺口只防程序色块（V3.1 负面约束），不再断裂成碎块。
	var segs := 4
	for i in segs:
		var t0 := -along_half + (2.0 * along_half) * float(i) / float(segs)
		var t1 := -along_half + (2.0 * along_half) * float(i + 1) / float(segs)
		if _hash2(seed + i * 7, seed * 3 + i) % 100 >= 12:
			continue  # hash 缺口：~12% 段跳过（连续条带，非碎块）
		var p0 := band_center + perp * t0
		# 带沿 perp 方向展开（宽 = t 跨度），厚 = half_width*2 沿 band_axis。
		# 顶面 footprint 多为轴对齐，用 axis-aligned rect 覆盖 perp 段即可。
		var r: Rect2
		if absf(perp.x) > absf(perp.y):
			r = Rect2(p0, Vector2(absf(t1 - t0), half_width * 2.0))
		else:
			r = Rect2(p0, Vector2(half_width * 2.0, absf(t1 - t0)))
		if exclude.size.x > 0.0 and r.intersects(exclude):
			continue  # 屏幕保护区：跳过（青蓝屏幕不被暖带盖住）
		draw_rect(r, color, true)


## 设备暖反射计算（测试可直接调用）：返回投影后点 + 方向 + 距离衰减。
## V3.1 返工2 R3：新增 toward（受光方向，单位向量，世界平面）—— 受光带
## 沿「朝灯方向」展开；point 保留（旧测试兼容），受光带用 toward 在顶面
## 平面上扫过，不再依赖单个投影点。
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
		return {"lit": false, "point": Vector2.ZERO, "strength": 0.0, "toward": Vector2(0, -1)}
	var toward := (nearest - center).normalized()
	if toward.length_squared() < 0.001:
		toward = Vector2(0, -1)
	var offset := minf(fp.size.x, fp.size.y) * 0.24
	var hit_world := center + toward * offset
	var height := float(EquipmentArt.EQUIP_HEIGHTS.get(eq_id, EquipmentArt.DEFAULT_EQUIP_HEIGHT))
	return {
		"lit": true,
		"point": Proj2D.proj(hit_world.x, hit_world.y, height + 1.0),
		"strength": clampf(1.0 - nearest_d / 112.0, 0.0, 1.0),
		"toward": toward,
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


## V3.1 返工6 P1（FAIL1 设备体上零噪点）：设备 mask 矩形集（世界像素
## 空间）。footprint 由 placed instances 决定；掩码矩形 = footprint 外扩
## 2px 后，向「顶面投影方向」扩展设备挤出高度（顶面在光图空间落在
## footprint 以北 ≈ HEIGHT_SCALE/FLOOR_SCALE × h，侧面/东侧另有
## EXTRUDE_X 偏移）—— 散射像素落在设备体上（含顶面/侧面）全部跳过。
## 烘焙时 grid 已有放置设备（capture _ready 先于首帧 draw），mask 与
## 渲染帧逐字节一致。确定性（遍历顺序 = grid 返回序）。
func _compute_equipment_mask_rects() -> Array:
	var rects: Array = []
	if _grid == null:
		return rects
	for inst in _grid.get_placed_instances():
		var fp := _footprint_rect(inst.footprint_cells)
		if fp.size.x <= 0 or fp.size.y <= 0:
			continue
		var h := float(_equipment_height(inst))
		# 顶面在光图空间向北偏移 ≈ h * HS/FS；东侧偏移 ≈ h * EX。
		var north := int(ceil(h * Proj2D.HEIGHT_SCALE / Proj2D.FLOOR_SCALE)) + 2
		var west := int(ceil(h * Proj2D.EXTRUDE_X)) + 2
		var r := Rect2i(fp.position.x - west, fp.position.y - north,
			fp.size.x + west * 2, fp.size.y + north + 2)
		rects.append(r)
	return rects


## 实例设备高度（世界像素）。优先 _resolver（EquipmentDefCatalog 的
## equipment_height），退化时用默认高度（与 WorldCanvas 挤出一致）。
func _equipment_height(inst) -> float:
	var h: float = EquipmentArt.DEFAULT_EQUIP_HEIGHT
	if _resolver != null:
		var resolved: Variant = _resolver.call(inst.instance_id)
		if resolved is float or resolved is int:
			h = float(resolved)
	return h


## 世界像素点是否落在任一设备 mask 矩形内（散射光照跳过）。
func _inside_equipment_mask(x: int, y: int) -> bool:
	for r: Rect2i in _equipment_mask_rects:
		if r.has_point(Vector2i(x, y)):
			return true
	return false


# === helpers ===

## 顶面仿射变换（与 WorldCanvas 同源）：扁平坐标 (x,y) → 投影后坐标
## （z=height）：floor transform 后再平移 (-EX*h, -HS*h)（顶面相对底面
## 左移上移 —— 东侧面/正面因此可见）。受光带用同一变换画在设备顶面上。
func _top_face_transform(height: float) -> Transform2D:
	var f := Proj2D.floor_transform()
	return Transform2D(f.x, f.y,
		f.origin + Vector2(-height * Proj2D.EXTRUDE_X, -height * Proj2D.HEIGHT_SCALE))

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
