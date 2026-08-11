## src/presentation/world_canvas.gd — 低分辨率世界渲染画布（V3 §2 管线核心）
##
## V3 visual remaster Phase 1：WORLD 层统一 pixel space。本节点是 SubViewport
## 内的世界绘制画布，替代旧 main.gd 的 1280×720 高清 draw_rect 世界路径。
## 所有绘制都在「世界像素空间」（CELL_SIZE=32，13×10 → 416×320）进行，由
## main.gd 的 WorldRoot（scale 0.75）换算到 SubViewport（426×240），再经
## TextureRect nearest 放大到窗口 —— 世界元素（地板/网格/设备/会员/幽灵）全部
## 属于同一个低分辨率 pixel space（V3 §2：WORLD 统一低分辨率，UI 高分辨率）。
##
## 绘制顺序（2.5D 空间层级，art-bible-25d §1 + V3 §4 三层空间 + Phase 4 双层会员）：
##   地板材质（FloorArt 烘焙贴图，V3 §1）→ 环境背景（墙/窗/海报/装饰，V3 §3/
##   §12 BACKGROUND 低对比）→ 结构层 BACKGROUND（储物柜/镜子/空调/墙钟/
##   通风口/门/踢脚线/电线槽/管道，V3 §3/§4 低对比，画在墙面上方）→ 网格线 →
##   结构层 GAMEPLAY（前台）→ 会员中景（walk/idle/tired/satisfied）→ 设备前景 →
##   使用中的会员（叠加在设备上 —— V3 §8 与设备互动姿态）→ 结构层 FOREGROUND
##   （立柱/吊灯，V3 §4 可轻微遮挡）→ 环境前景（大植物，V3 §4 FOREGROUND 可
##   轻微遮挡）→ 放置幽灵（活动决策预览优先级最高）。
## Phase 4（V3 §8）：会员是画面视觉主体 —— sprite 48×48（>cell 32），脚底
## 锚定 cell 底部、头部向上越出 cell；USING 成员锚定到设备 footprint 上
## （跑带/卧推凳/车座/垫面），叠加在设备之上（先画设备、后画使用会员）。
##
## GRID 可见性（V3 §14 可读性）：正常经营模式完全隐藏 tile grid；仅 placement
## mode（PlacementSystem.is_dragging()）显示。默认隐藏；_process 轮询
## is_dragging()（O(1) 状态读，与 CongestionOverlayController._poll_drag_state
## 同一模式），拖拽开始/结束切换可见性并 queue_redraw。
##
## 本节点不持有玩法状态：instance_id→equipment_id 经 resolver Callable 读取
## （数据源仍由 main.gd 的 _instance_defs 维护，MemberSim 同源）；会员朝向缓存
## （_member_facing/_member_last_cell）是 presentation 层状态（纯绘制用）。
##
## headless 可靠性：class_name 仅作编辑器便利，跨脚本引用一律 preload alias
## （项目约定，见 src/main.gd 头部注释）；tick 经 tick_provider Callable 注入，
## 不直接依赖 orchestrator 类型。floor_art / env_art 为 Phase 5 可选注入
## （null 时回退到旧色块地板 / 不画环境装饰 —— 保持既有测试构造兼容）。
class_name WorldCanvas extends Node2D

const Palette := preload("res://src/palette.gd")
const WorldScale := preload("res://src/presentation/world_scale.gd")
const WorldLayout := preload("res://src/presentation/world_layout.gd")
const StructureArt := preload("res://src/presentation/structure_art.gd")
const Proj2D := preload("res://src/presentation/oblique_projection.gd")

## 默认网格可见性（V3 §14）：正常经营模式完全隐藏 grid。
const DEFAULT_GRID_VISIBLE := false

## Hover 上移量（世界 px）：V3 §14「hover 黄色像素轮廓 + 轻微上移」。
## 精灵本体向上偏移 2 世界 px（≈1.5 viewport px，nearest 放大后 ~4.5 屏 px），
## contact shadow 留在原地 —— 视觉上设备「轻轻抬起」。
const HOVER_LIFT_PX := 2.0

## camera fix：天花板只保留为投影画布边缘氛围。中央弱纹理避免抢过地板，
## 两级像素带形成暗角式渐变（不引入 shader，保持低分辨率世界管线）。
const CEILING_CENTER_ALPHA := 0.14
const CEILING_EDGE_BAND := 28.0
const CEILING_OUTER_BAND := 10.0

## SubViewport 逻辑尺寸（与 main.gd WORLD_VIEWPORT_W/H 同源；背景矩形用它
## 扩展覆盖全视口 —— 返工5 P3 N4 消除视口边缘 clear color 平涂带）。
const BG_VIEWPORT_SIZE := Vector2(426, 240)

# === 注入依赖（ADR-0001 两阶段 init 形态） ===
var _grid = null              # GridStateReader：placed instances / conversions
var _catalog = null           # EquipmentCatalog：equipment_id → def（zone/语义色）
var _member = null            # MemberSim：members 数组（位置/状态）
var _member_sprites = null    # MemberSprite：2.5D 像素小人纹理工厂
var _equip_art = null         # EquipmentArt：设备像素精灵纹理工厂
var _placement = null         # PlacementSystem：is_dragging / 幽灵数据
var _arbitration = null       # ModeArbitration：is_ghost_suppressed（Core Rule 4）
var _resolver: Callable = Callable()      # instance_id -> equipment_id
var _tick_provider: Callable = Callable() # -> int（会员动画 tick）
var _cell_size: int = 32
var _floor_art = null         # FloorArt：V3 §1 地板材质烘焙贴图（Phase 5，可空）
var _env_art = null           # EnvironmentArt：V3 §12 环境装饰精灵工厂（Phase 5，可空）
var _structure_art = null     # StructureArt：V3 §3/§4/§13 结构层（Phase 2，可空）

## V3 §14 hover：当前被鼠标悬停的设备 instance_id（-1 = 无）。
## presentation 层状态（纯绘制用），由 _hover_provider 轮询维护 —— 与
## _poll_placement_mode 同一模式（O(1) 状态读，headless 测试直接驱动 setter）。
var _hovered_instance_id: int = -1
## hover 数据源：返回当前悬停的 instance_id（-1 = 无）。由 main.gd 注入
## （根 viewport 鼠标 → _screen_to_world → grid.world_to_grid → occupant）。
var _hover_provider: Callable = Callable()

## 当前网格可见性（V3 §14）。默认 false；仅 placement mode 为 true。
var _grid_visible: bool = DEFAULT_GRID_VISIBLE

## Phase C v2：会员朝向（presentation 层状态，非玩法逻辑 —— 由 cell 移动
## 推断 facing，纯绘制用）。member_id -> bool（true = 朝左）。
var _member_facing: Dictionary = {}
var _member_last_cell: Dictionary = {}

var _initialized: bool = false


## 两阶段 init：注入世界绘制依赖并订阅重绘信号（grid_changed S1 /
## tick_completed S2 / preview_validity_changed —— 与旧 main.gd 的 BUILD-03/04
## 信号驱动重绘约定一致；queue_redraw 幂等合并，headless 下调用无害）。
## [resolver] instance_id -> equipment_id；[tick_provider] -> int（动画 tick）。
## [floor_art] FloorArt（V3 §1 地板材质，Phase 5；null 时回退旧色块地板）。
## [env_art] EnvironmentArt（V3 §12 环境装饰，Phase 5；null 时不画装饰）。
## [structure_art] StructureArt（V3 §3/§4/§13 结构层，Phase 2；null 时不画结构）。
func init(
	grid,
	catalog,
	member,
	member_sprites,
	equip_art,
	placement,
	arbitration,
	resolver: Callable,
	tick_provider: Callable,
	cell_size: int,
	floor_art = null,
	env_art = null,
	structure_art = null
) -> void:
	if _initialized:
		push_error("WorldCanvas.init(): called twice")
		return
	_initialized = true
	# V3 §2 低分辨率世界统一 pixel space：WorldRoot scale 0.75 下设备纹理
	# （Phase 3 16×16 art，ART_SCALE=2 → 每 art px = 1.5 viewport px，非整数）
	# 必须 NEAREST 采样 —— 否则线性过滤在 art px 边界混色（旧 8×8 art 恰好
	# 3 viewport px/art px 整数对齐，掩盖了此问题）。证据脚本 stair-step
	# 断言依赖此硬边（无 bilinear blend）。
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_grid = grid
	_catalog = catalog
	_member = member
	_member_sprites = member_sprites
	_equip_art = equip_art
	_placement = placement
	_arbitration = arbitration
	_resolver = resolver
	_tick_provider = tick_provider
	_cell_size = maxi(cell_size, 1)
	_floor_art = floor_art
	_env_art = env_art
	_structure_art = structure_art
	_grid_visible = DEFAULT_GRID_VISIBLE

	# 信号驱动重绘（typed connections only，Control Manifest Presentation 规则）：
	#   - grid_changed（place=commit / remove=sell）→ 设备上屏/下屏
	# tick_completed（S2，10Hz → 会员移动）与 preview_validity_changed（幽灵
	# tint）由 composition root（main.gd）接向 _on_world_changed —— 这两个信号
	# 分别挂在 orchestrator / placement 上，不在此处强依赖类型。
	if _grid != null and not _grid.grid_changed.is_connected(_on_world_changed):
		_grid.grid_changed.connect(_on_world_changed)


## S1/S2/preview 统一重绘入口。queue_redraw() 幂等合并（一帧内多次调用只重绘
## 一次），headless 下不渲染、调用无害（同旧 main.gd 约定）。
func _on_world_changed(_a = null, _b = null, _c = null, _d = null) -> void:
	if not _initialized:
		return
	queue_redraw()


## 轮询 placement mode（V3 §14）：placement drag 进行中 → 显示 grid，否则隐藏。
## 与 CongestionOverlayController._poll_drag_state 同一模式（O(1) 状态读，无
## 预览/寻路工作 —— 不违反 TR-PS-012）。headless 测试直接驱动本方法。
func _process(_delta: float) -> void:
	_poll_placement_mode()
	_poll_hover()


## 轮询 hover 状态（V3 §14）：_hover_provider 返回当前悬停 instance_id，
## 边沿变化 → queue_redraw。幂等 —— 状态未变时零开销。O(1) 状态读。
func _poll_hover() -> void:
	if not _initialized or not _hover_provider.is_valid():
		return
	var id := int(_hover_provider.call())
	if id == _hovered_instance_id:
		return
	_hovered_instance_id = id
	queue_redraw()


## 注入 hover 数据源（composition root 调用；headless 测试可注入 Fake）。
func set_hover_provider(provider: Callable) -> void:
	_hover_provider = provider


## 查询：当前悬停的设备 instance_id（-1 = 无）。测试/调试入口。
func get_hovered_instance_id() -> int:
	return _hovered_instance_id


## 显式设置 hover（测试/调试入口；正常流程由 _poll_hover 驱动）。
func set_hovered_instance_id(id: int) -> void:
	if _hovered_instance_id == id:
		return
	_hovered_instance_id = id
	queue_redraw()


## Placement-mode 轮询体：is_dragging() 边沿 → 切换网格可见性并重绘。幂等 ——
## 状态未变时零开销。
func _poll_placement_mode() -> void:
	if not _initialized or _placement == null:
		return
	var dragging: bool = _placement.is_dragging()
	if dragging == _grid_visible:
		return
	_grid_visible = dragging
	queue_redraw()


## 查询：当前网格是否可见（V3 §14 —— 正常经营模式完全隐藏）。
func is_grid_visible() -> bool:
	return _grid_visible


## 显式设置网格可见性（测试/调试入口）。正常流程由 _poll_placement_mode 驱动。
func set_grid_visible(visible: bool) -> void:
	if _grid_visible == visible:
		return
	_grid_visible = visible
	queue_redraw()


# === 渲染（投影后世界空间；headless 下引擎不调用 _draw，防御性 null 检查） ===

## V3.1 P1：2.5D 斜俯视绘制顺序（oblique projection，见 oblique_projection.gd）：
##   画布背景（天花板）→ 地板 pass（floor transform 包裹全部贴地内容：
##   地板材质/地面装饰/结构 BACKGROUND/网格）→ 体积墙（北墙/东西墙面 +
##   墙上装饰，画在地板之上 —— 墙脚被地板压住，墙身立起）→ 结构 GAMEPLAY
##   （前台，挤出）→ 设备（顶面+正面+侧面 3 面挤出，有体积）→ 会员中景
##   （billboard 站立，脚底贴地 —— 返工6 P2：画在设备之上，会员下半身
##   不被设备顶面横切；设备顶面受光带与会员脚底接触影形成前后层）→
##   USING 会员前景（叠加在设备上）→ 结构 FOREGROUND（立柱挤出/吊灯挂
##   高处/小道具贴地）→ 环境前景（大植物）→ 放置幽灵（贴地预览）。
##   V3.1 返工6 P2（构图避让）：旧顺序「会员中景 → 设备」使设备顶面
##   （抬升到 z=height 的受光面）在投影中画在行走会员腰/胯之上 ——
##   GPT 第二眼读作「人物站在柜台后，下半身被大面积遮挡」。调整为先画
##   设备、再画中景会员：会员是画面视觉主体（V3 §15 人物视觉权重），
##   其双腿/双脚/接触影始终完整可读；设备仍是前景体积（USING 会员叠加
##   在设备上的逻辑不变）。
func _draw() -> void:
	if _grid == null:
		return
	_draw_canvas_background()
	_draw_floor_pass()
	_draw_2_5d_walls()
	if _structure_art != null:
		_draw_structure_gameplay()
	_draw_equipment()
	_draw_members(false)
	_draw_members(true)
	_draw_structure_foreground()
	_draw_environment_foreground()
	_draw_placement_ghost()


## 画布背景（camera fix + 返工5 P3 N4）：中央只留弱天花板底纹，手绘天花板
## 纹理集中在两级边缘带；随后地板覆盖操作区。避免旧实现把整张高对比纹理
## 铺满 bounds，仍在四周保留 V3.1 P1 的 room-box 氛围。
## 返工5 P3（N4 纯色大面积填充）：背景改为整张烘焙纹理（1 draw call）——
## 覆盖整个 SubViewport（投影空间），消除视口边缘默认 clear color 的纯色
## 奶油条（旧帧左右各 ~70 屏 px 平涂带）；房间盒外延展墙区用更强的手绘
## 天花板纹理（替代旧纯色暗底 —— 旧帧 x≈88..230 / x≈1044..1192 的平涂棕带）。
## structure_art 未注入时回退暗底色。烘焙确定性（hash 驱动，无 RNG）。
var _bg_texture: ImageTexture = null

func _draw_canvas_background() -> void:
	if _bg_texture == null:
		_bg_texture = _bake_background_texture()
	if _bg_texture != null:
		draw_texture_rect(_bg_texture, _viewport_projected_rect(), false)
		return
	# 回退：无 structure_art 时只铺暗底色（保持既有测试构造兼容）。
	var b := Proj2D.bounds()
	var rect := Rect2(b.position - Vector2(8, 8), b.size + Vector2(16, 16))
	draw_rect(rect, Palette.WALL_BASE.darkened(0.38), true)


## 全视口投影矩形（投影空间坐标 → viewport 由 WorldRoot scale/offset 完成）。
## 与 main.gd WORLD_VIEWPORT_OFFSET 同源：覆盖 426×240 SubViewport 全域。
func _viewport_projected_rect() -> Rect2:
	return Rect2(
		-Vector2(Proj2D.viewport_offset(BG_VIEWPORT_SIZE, WorldScale.WORLD_SCALE))
			/ WorldScale.WORLD_SCALE,
		BG_VIEWPORT_SIZE / WorldScale.WORLD_SCALE)


## 烘焙整张背景纹理（返工5 P3 N4）：基色 + 天花板中心弱纹理 + 房间盒边缘
## 两级暗角带 + 房间盒外延展墙区手绘纹理 —— 全部合成一张 RGBA8 贴图，
## 运行时 1 次 draw_texture_rect（draw call 预算：旧 10 次 → 1 次，V3 §15）。
## 确定性：全 hash 驱动（天花板/墙面纹理来自 StructureArt 烘焙），无 RNG。
func _bake_background_texture() -> ImageTexture:
	if _structure_art == null:
		return null
	var vp := _viewport_projected_rect()
	var w := int(ceil(vp.size.x))
	var h := int(ceil(vp.size.y))
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Palette.WALL_BASE.darkened(0.38))
	var ceiling: Image = null
	var ceiling_tex: ImageTexture = _structure_art.ceiling_texture()
	if ceiling_tex != null:
		ceiling = ceiling_tex.get_image()
	if ceiling != null:
		_blend_stretched(img, ceiling, vp, vp, CEILING_CENTER_ALPHA)
		# 返工6 P4（N1 顶部条带）：天花板边缘手绘锯齿 —— 沿天花板区域
		# 顶/底边界（投影空间）按列画 1-3px 参差暗边，打破「深灰横向带
		# 上下边界笔直」的读法（GPT：顶部条带 y≈54-75 深灰带直边）。
		_draw_jagged_ceiling_trim(img, vp)
		# 房间盒边缘两级暗角带（与原 per-frame 绘制同位置同 alpha）。
		var b := Proj2D.bounds()
		var rect := Rect2(b.position - Vector2(8, 8), b.size + Vector2(16, 16))
		_blend_ring(img, ceiling, vp, rect, CEILING_EDGE_BAND, 0.42)
		_blend_ring(img, ceiling, vp, rect, CEILING_OUTER_BAND, 0.34)
		# 延展墙区：更高对比墙面纹理（替代纯色暗底 / 低对比天花板）。
		_blend_extended_walls(img, vp)
	return ImageTexture.create_from_image(img)


## 返工6 P4（N1）：天花板边缘手绘锯齿。背景烘焙的投影空间里，房间盒
## 顶缘（bounds().y 附近）是一条轴对齐直线 —— 在 GPT 帧中读作「顶部
## 深灰横向带上下边界」。这里沿天花板顶/底各画一条逐列 1-3px 参差的暗
## 边（深色小段 + 缺口），把直边打散成手绘锯齿。确定性 hash，无 RNG。
func _draw_jagged_ceiling_trim(img: Image, vp: Rect2) -> void:
	var b := Proj2D.bounds()
	# 天花板带在投影图 y = b.position.y（顶缘）与墙帽交界附近。画两行锯齿。
	var top_y := int(floor(b.position.y - vp.position.y)) + 2
	var bottom_y := int(floor(b.position.y + 8.0 - vp.position.y))
	var x0 := int(floor(b.position.x - vp.position.x))
	var x1 := int(floor(b.end.x - vp.position.x))
	if top_y < 0 or bottom_y >= img.get_height():
		return
	var trim_col := Palette.WALL_BASE.darkened(0.46)
	var x := x0
	while x < x1:
		var h := _hash2(x, 0xCE11)
		var seg := 8 + (h % 12)         # 8..19px 一段
		var depth := 1 + (h >> 4) % 3   # 1..3px 锯齿深度
		for dx in range(0, mini(seg, x1 - x)):
			var col := trim_col
			if (h >> 7) % 5 == 0:
				col = trim_col.darkened(0.08)
			var py := top_y - depth
			if py >= 0 and py < img.get_height():
				img.set_pixel(x + dx, py, col)
			if bottom_y >= 0 and bottom_y < img.get_height():
				img.set_pixel(x + dx, bottom_y + depth - 1, col)
		x += seg + ((h >> 9) % 5)  # 段间缺口


## 把 src 拉伸铺进 dst_rect（投影空间坐标），按 alpha 混合进 img。
## 逐像素最邻近采样（像素风；与运行时 NEAREST 滤镜一致）。
func _blend_stretched(
	img: Image, src: Image, vp: Rect2, dst_rect: Rect2, alpha: float
) -> void:
	var x0 := maxi(int(floor(dst_rect.position.x - vp.position.x)), 0)
	var y0 := maxi(int(floor(dst_rect.position.y - vp.position.y)), 0)
	var x1 := mini(int(ceil(dst_rect.end.x - vp.position.x)), img.get_width())
	var y1 := mini(int(ceil(dst_rect.end.y - vp.position.y)), img.get_height())
	if x1 <= x0 or y1 <= y0:
		return
	var sw := src.get_width()
	var sh := src.get_height()
	var dw := maxf(dst_rect.size.x, 1.0)
	var dh := maxf(dst_rect.size.y, 1.0)
	for py in range(y0, y1):
		for px in range(x0, x1):
			var sx := int(floor((px + vp.position.x - dst_rect.position.x) / dw * sw))
			var sy := int(floor((py + vp.position.y - dst_rect.position.y) / dh * sh))
			sx = clampi(sx, 0, sw - 1)
			sy = clampi(sy, 0, sh - 1)
			var c := src.get_pixel(sx, sy)
			var d := img.get_pixel(px, py)
			img.set_pixel(px, py, Color(
				lerpf(d.r, c.r, alpha),
				lerpf(d.g, c.g, alpha),
				lerpf(d.b, c.b, alpha),
				1.0))


## 四条边缘带（与 _draw_ceiling_edge_ring 同位置）。角落自然叠加更暗。
func _blend_ring(
	img: Image, src: Image, vp: Rect2, rect: Rect2, band: float, alpha: float
) -> void:
	var w := minf(band, rect.size.x * 0.5)
	var h := minf(band, rect.size.y * 0.5)
	_blend_stretched(img, src, vp, Rect2(rect.position, Vector2(rect.size.x, h)), alpha)
	_blend_stretched(img, src, vp, Rect2(
		Vector2(rect.position.x, rect.end.y - h), Vector2(rect.size.x, h)), alpha)
	_blend_stretched(img, src, vp, Rect2(rect.position, Vector2(w, rect.size.y)), alpha)
	_blend_stretched(img, src, vp, Rect2(
		Vector2(rect.end.x - w, rect.position.y), Vector2(w, rect.size.y)), alpha)


## 房间盒外延展墙区（返工5 P3 N4）：西/东侧墙在视口内继续延展（世界 x 超出
## 0..416 的部分），旧实现只铺纯色暗底（帧左右两侧各 ~140 屏 px 的平涂棕带）。
## 改为直接在投影图上手绘墙面语言（WALL_BASE_FAR 底 + 8px 手绘笔触 +
## 稀疏噪点）—— 与真实墙面同源（N4 纯色大面积填充：无平涂带）。
## 经 floor_transform 逆映射：世界坐标 → 投影像素 → 判断是否落在延展矩形内。
## 地板/墙面随后覆盖在正确位置之上 —— 本层只填「墙外空隙」。确定性。
func _blend_extended_walls(img: Image, vp: Rect2) -> void:
	# 延展矩形扩到视口边缘覆盖（世界坐标）：视口左缘投影到 world x 可达
	# ~-113（y=320 时），右缘可达 ~526 —— 固定延展矩形之外还有少量空隙，
	# 用覆盖全视口边缘的矩形兜底（内部会被地板/墙面覆盖，只有空隙可见）。
	var zones := [
		Rect2i(-120, -12, 140, 344),   # 左侧延展（含墙外空隙）
		Rect2i(396, -12, 140, 344),    # 右侧延展（含墙外空隙）
	]
	for wr in zones:
		_paint_extended_wall_face(img, vp, wr, int(wr.position.x) * 31 + int(wr.position.y) * 17)


## 单个延展矩形：逆映射 + 手绘墙面填充（底 + 笔触 + 噪点）。
func _paint_extended_wall_face(img: Image, vp: Rect2, wr: Rect2i, seed: int) -> void:
	var stroke_colors := [
		Palette.WALL_BASE_FAR.darkened(0.08),
		Palette.WALL_BASE_FAR.lightened(0.06),
		Palette.WALL_BASE_FAR.lightened(0.12),
	]
	var base_colors := [
		Palette.WALL_BASE_FAR,
		Palette.WALL_BASE_FAR.lightened(0.04),
	]
	# 世界坐标逐像素逆投影（floor_transform 逆：proj(x,y) = (x+y*S, y*F)）。
	# 直接在投影空间采样 —— 对投影矩形内每个像素求逆映射到世界坐标。
	var pmin := Proj2D.project_world(Vector2(wr.position))
	var pmax := Proj2D.project_world(Vector2(wr.position + wr.size))
	var img_x0 := maxi(int(floor(pmin.x - vp.position.x)), 0)
	var img_y0 := maxi(int(floor(pmin.y - vp.position.y)), 0)
	var img_x1 := mini(int(ceil(pmax.x - vp.position.x)), img.get_width())
	var img_y1 := mini(int(ceil(pmax.y - vp.position.y)), img.get_height())
	for iy in range(img_y0, img_y1):
		for ix in range(img_x0, img_x1):
			var proj_x := vp.position.x + ix
			var proj_y := vp.position.y + iy
			# 逆 floor_transform
			var world_y := proj_y / Proj2D.FLOOR_SCALE
			var world_x := proj_x - world_y * Proj2D.SHEAR
			if world_x < wr.position.x or world_x >= wr.position.x + wr.size.x:
				continue
			if world_y < wr.position.y or world_y >= wr.position.y + wr.size.y:
				continue
			# 墙面底：两档暖灰交替（N11 远景暖化 + N4 色阶微差 —— 非单色平涂）
			var h := _hash2(int(world_x) + seed, int(world_y) * 3 + seed)
			var col: Color = base_colors[(h >> 4) % base_colors.size()]
			# 6px 手绘笔触（与 _bake_side_wall 同族；无装饰大块）
			if h % 6 == 0:
				col = stroke_colors[(h >> 8) % stroke_colors.size()]
			# 稀疏噪点（N4 色阶微差）
			elif h % 11 == 0:
				col = Palette.WALL_BASE.lightened(0.10) if (h >> 12) % 2 == 0 else Palette.WALL_DARK
			var d := img.get_pixel(ix, iy)
			img.set_pixel(ix, iy, Color(
				lerpf(d.r, col.r, 0.94),
				lerpf(d.g, col.g, 0.94),
				lerpf(d.b, col.b, 0.94),
				1.0))


## 地板 pass：全部贴地内容经 floor_transform 一次性投影（V3.1 P1 ——
## 扁平坐标绘制代码原样保留，包一层 draw_set_transform_matrix）。
func _draw_floor_pass() -> void:
	_draw_with_floor_transform(func() -> void:
		_draw_floor_zones()
		_draw_floor_decor()
		if _structure_art != null:
			_draw_structure_layer(StructureArt.LAYER_BACKGROUND)
		if _grid_visible:
			_draw_grid_lines()
	)


## 在 floor_transform 下执行绘制（V3.1 P1）。draw_set_transform_matrix 设置
## 画布仿射变换（含剪切）—— 后续 draw_* 全部经地板投影；结束时恢复单位阵。
## [draw_fn] Callable（闭包绘制体，扁平世界坐标）。
func _draw_with_floor_transform(draw_fn: Callable) -> void:
	draw_set_transform_matrix(Proj2D.floor_transform())
	draw_fn.call()
	draw_set_transform_matrix(Transform2D.IDENTITY)


## 地板：Phase 5 使用 FloorArt 烘焙的材质贴图（V3 §1 区域地面材质 ——
## 力量区深灰橡胶、有氧区暖灰、瑜伽区木地板、通道瓷砖；单次 draw_texture_rect，
## 替代旧色块 + 描边）。floor_art 未注入时回退旧色块（保持既有测试兼容）。
## 在 floor pass 内调用（扁平坐标，经 floor transform 投影）。
func _draw_floor_zones() -> void:
	if _floor_art != null:
		var tex: ImageTexture = _floor_art.texture()
		if tex != null:
			draw_texture_rect(tex, Rect2(Vector2.ZERO, Vector2(
				WorldLayout.WORLD_W, WorldLayout.WORLD_H)), false)
			return
	for zone: String in Palette.ZONE_RECTS:
		var rect: Rect2i = Palette.ZONE_RECTS[zone]
		var px_rect := Rect2i(rect.position * _cell_size, rect.size * _cell_size)
		draw_rect(px_rect, Palette.ZONE_COLORS[zone], true)
		draw_rect(px_rect, Palette.ZONE_BORDER, false, 1.0 * WorldScale.STROKE_COMPENSATION)


## 结构层（V3 §3/§4/§13，Phase 2 StructureArt）：单次 draw_texture_rect 烘焙
## 贴图。BACKGROUND 低对比（降对比降饱和）、GAMEPLAY 前台原色鲜艳、FOREGROUND
## 立柱/吊灯允许轻微遮挡 —— 顺序由 _draw() 控制（见文件头注释）。
## V3.1 P1：BACKGROUND 在 floor pass 内经地板投影 —— 墙上挂饰（镜子/空调/
## 挂钟/通风口）落在墙基附近会被随后绘制的墙面盖住（隐藏），地面结构
## （踢脚线/电线槽/门垫/管道/出口招牌）正确落在墙面上可见。
func _draw_structure_layer(layer: String) -> void:
	var tex: ImageTexture = _structure_art.layer_texture(layer)
	if tex == null:
		return
	draw_texture_rect(tex, Rect2(Vector2.ZERO, Vector2(
		WorldLayout.WORLD_W, WorldLayout.WORLD_H)), false)


# === V3.1 P1 结构层体积（前台/立柱/吊灯 —— 不再扁平贴图） ===

## 前台高度（世界 px）。
const STRUCT_FRONT_DESK_H := 22.0
## V3.1 P1 结构 GAMEPLAY：前台（主要交互对象）—— 体积挤出（顶面+正面+侧面）。
## V3.1 R3（P3 手绘感）：正面不再纯色填充 —— 挤出面之上叠确定性手工木纹
## cluster（暗/亮小色块），打破大面积单色（P3「纯色大面积填充」禁令）。
func _draw_structure_gameplay() -> void:
	if _structure_art == null:
		return
	var rect: Rect2i = _structure_art.structure_rect("front_desk")
	var tex: ImageTexture = _structure_art.structure_texture("front_desk")
	if rect.size.x <= 0 or tex == null:
		return
	_draw_extruded_box(tex, rect, STRUCT_FRONT_DESK_H,
		Palette.DESK_WOOD.darkened(0.22), Palette.DESK_WOOD.darkened(0.4))
	# 正面手工木纹 cluster：沿正面平面（世界 y=y1，z∈[0,h]）撒确定性暗/亮
	# 小色块 —— 正面不再 200px+ 单色直线（P3 手绘感）。
	_draw_desk_front_clusters(rect, STRUCT_FRONT_DESK_H)


## 前台正面手工 cluster（V3.1 R3 / P3）：沿正面平面确定性撒 20 个 2-3px
## 木纹色块（DESK_WOOD 暗/亮变体）。投影到屏幕后叠在正面多边形上，
## 打破「纯色大面积填充」直线 —— 仍是可读的台面结构（V3 §14）。
## z 覆盖全高 [0, height]（含顶部边缘行 —— 顶部行也要打破单色直线）。
func _draw_desk_front_clusters(rect: Rect2i, height: float) -> void:
	var y1 := float(rect.position.y + rect.size.y)
	var x0 := float(rect.position.x)
	var x1 := float(rect.position.x + rect.size.x)
	var cluster_colors := [
		Palette.DESK_WOOD.darkened(0.30),
		Palette.DESK_WOOD.darkened(0.16),
		Palette.DESK_TOP.darkened(0.12),
	]
	for i in 20:
		# 确定性 hash（无 RNG 状态 —— 同输入同输出）
		var h := _front_cluster_hash(i)
		var fx := x0 + 4.0 + float(h % int(maxf(x1 - x0 - 8.0, 1.0)))
		# z 覆盖正面全高 [0, height]（含顶部边缘行 —— 顶部行也要打破单色直线）
		var fz := float((h >> 5) % int(maxf(height + 1.0, 1.0)))
		var c: Color = cluster_colors[(h >> 9) % cluster_colors.size()]
		var p := Proj2D.proj(fx, y1, fz)
		# 2-3px 小色块（不遮正面整体轮廓 —— 只打破大面积单色）
		draw_rect(Rect2(p - Vector2(1, 1), Vector2(2, 2)), c, true)
		if h % 3 == 0:
			draw_rect(Rect2(p + Vector2(1, 0), Vector2(2, 2)), c.darkened(0.1), true)


## 前台 cluster 确定性 hash（R3：同输入同输出，headless 可测）。
func _front_cluster_hash(i: int) -> int:
	var h := i * 374761393 + 5917 * 668265263
	h = (h ^ (h >> 13)) * 1274126177
	return h & 0x7fffffff


## 确定性 2D hash（无 RNG 状态 —— 同输入永远同输出；背景烘焙用）。
func _hash2(x: int, y: int) -> int:
	var h := x * 374761393 + y * 668265263
	h = (h ^ (h >> 13)) * 1274126177
	return h & 0x7fffffff


## V3.1 P1 结构 FOREGROUND：立柱（体积挤出，近景可遮挡）+ 吊灯（挂在
## 高处）+ 小道具（贴地）。替代旧的整层贴图绘制 —— 立柱/吊灯不再扁平。
func _draw_structure_foreground() -> void:
	if _structure_art == null:
		return
	# 立柱 1/2：体积挤出（柱身到墙高）
	for id in ["column_1", "column_2"]:
		var rect: Rect2i = _structure_art.structure_rect(id)
		var tex: ImageTexture = _structure_art.structure_texture(id)
		if rect.size.x <= 0 or tex == null:
			continue
		_draw_extruded_box(tex, rect, Proj2D.WALL_HEIGHT - 10.0,
			Palette.COLUMN_DARK, Palette.COLUMN_DARK.darkened(0.18))
	# 吊灯 1/2/3：rect/高度来自 WorldLayout.HANGING_LIGHTS，与 LightingLayer
	# 的灯泡→落点投光共用锚点，防止灯具与光束屏幕空间断开。
	for light: Dictionary in WorldLayout.HANGING_LIGHTS:
		var id := str(light.get("id", ""))
		var rect: Rect2i = _structure_art.structure_rect(id)
		var tex: ImageTexture = _structure_art.structure_texture(id)
		if rect.size.x <= 0 or tex == null:
			continue
		var height := float(light.get("height", 78.0))
		var pos := Proj2D.proj(rect.position.x, rect.position.y, height)
		draw_texture_rect(tex, Rect2(pos, Vector2(rect.size)), false)
	# 瑜伽区落地灯：竖直 billboard，灯脚落地、灯罩抬高。旧版在 floor pass
	# 中绘制导致 8×8 灯被压成一小块橙色地砖，无法识别为光源。
	_draw_floor_light_fixture()
	# 小道具（壶铃/配重片/纸杯/毛巾 —— 贴地，floor transform）
	_draw_with_floor_transform(func() -> void:
		for id in ["kettlebell_prop", "plate_prop_1", "plate_prop_2",
				"paper_cup_1", "paper_cup_2", "towels_1", "towels_2"]:
			var rect: Rect2i = _structure_art.structure_rect(id)
			var tex: ImageTexture = _structure_art.structure_texture(id)
			if rect.size.x <= 0 or tex == null:
				continue
			draw_texture_rect(tex, Rect2(rect.position, rect.size), false)
	)


## V3.1 R4 落地灯物件：使用 EnvironmentArt 的手绘灯体，但在投影后空间
## 竖直绘制。top 对齐 base 的指定高度，纹理下缘回到地面接触点附近。
func _draw_floor_light_fixture() -> void:
	if _env_art == null:
		return
	var cfg: Dictionary = WorldLayout.FLOOR_LIGHT
	var decor_id := str(cfg.get("decor_id", ""))
	var tex: ImageTexture = _env_art.texture_for(decor_id)
	if tex == null:
		return
	var size := Vector2(_env_art.texture_size(decor_id))
	var base: Vector2 = cfg.get("base", Vector2.ZERO)
	var height := float(cfg.get("height", 48.0))
	var top := Proj2D.proj(base.x, base.y, height)
	draw_texture_rect(tex, Rect2(top - Vector2(size.x * 0.5, 0), size), false)


## 通用体积挤出（V3.1 P1）：东侧面 + 正面 + 顶面。结构/设备共用数学。
## [tex] 顶面纹理（footprint 尺寸，扁平坐标）；[rect] 扁平 footprint；
## [height] 世界高；[front_color]/[side_color] 正面/侧面实色。
func _draw_extruded_box(tex: ImageTexture, rect: Rect2i, height: float,
		front_color: Color, side_color: Color) -> void:
	var x0 := float(rect.position.x)
	var y0 := float(rect.position.y)
	var x1 := x0 + float(rect.size.x)
	var y1 := y0 + float(rect.size.y)
	# 东侧面（x=x1，y∈[y0,y1]，z∈[0,h]）—— 阴影侧
	draw_colored_polygon(PackedVector2Array([
		Proj2D.proj(x1, y0, 0.0), Proj2D.proj(x1, y1, 0.0),
		Proj2D.proj(x1, y1, height), Proj2D.proj(x1, y0, height),
	]), side_color)
	# 正面（y=y1，x∈[x0,x1]，z∈[0,h]）—— 面向相机
	draw_colored_polygon(PackedVector2Array([
		Proj2D.proj(x0, y1, 0.0), Proj2D.proj(x1, y1, 0.0),
		Proj2D.proj(x1, y1, height), Proj2D.proj(x0, y1, height),
	]), front_color)
	# 顶面（z=height）：纹理提升（floor transform + 高度平移）
	draw_set_transform_matrix(_top_face_transform(height))
	draw_texture_rect(tex, Rect2(rect.position, rect.size), false)
	draw_set_transform_matrix(Transform2D.IDENTITY)


## 顶面仿射变换：扁平坐标 (x,y) → 投影后坐标（z=height）：floor transform
## 后再平移 (-EX*h, -H*h)（顶面相对底面左移上移 —— 东侧面/正面因此可见）。
func _top_face_transform(height: float) -> Transform2D:
	var f := Proj2D.floor_transform()
	return Transform2D(f.x, f.y,
		f.origin + Vector2(-height * Proj2D.EXTRUDE_X, -height * Proj2D.HEIGHT_SCALE))


# === V3.1 P1 体积墙（diorama 房间盒） ===

## 体积墙：北墙 + 东西墙面。墙基 = 扁平墙条（WALL_TOP_RECT / 侧墙条），
## 墙面 = 从墙基提升到 z=WALL_HEIGHT 的平行四边形（含墙帽顶面 + 踢脚线）。
## 画在地板 pass 之后 —— 墙脚被地板压住，墙身立起（V3.1 P1 墙壁有体积：
## 正面（墙面）+ 顶面（墙帽）+ 侧面（墙端/门洞）。
func _draw_2_5d_walls() -> void:
	_draw_north_wall()
	_draw_side_wall(true)    # 西墙
	_draw_side_wall(false)   # 东墙


## 北墙（入口 x 0..32 保留门洞）：墙面从墙基 y=24（墙与地板交界）提升到
## z=WALL_HEIGHT。V3.1 P3：墙面 = 手绘粉刷纹理（cluster + jagged 墙帽/踢脚线）
## 经 _north_wall_transform 一次贴图 —— 替代旧的 3 个纯色多边形（面 + 墙帽 +
## 踢脚线），draw call 3→1 且大面积墙面不再纯色填充。
func _draw_north_wall() -> void:
	if _structure_art == null:
		return
	var tex: ImageTexture = _structure_art.wall_face_texture("north")
	if tex == null:
		return
	draw_set_transform_matrix(_north_wall_transform())
	draw_texture_rect(tex, Rect2(32, 0, StructureArt.WALL_NORTH_TEX.x,
		StructureArt.WALL_NORTH_TEX.y), false)
	draw_set_transform_matrix(Transform2D.IDENTITY)
	_draw_north_wall_decor()


## 北墙本地变换：扁平墙条坐标 (fx, fy∈[0,24]) → 墙面屏幕坐标（fy 线性映射
## 到墙高：fy=24（墙基）→ z=0，fy=0（墙顶）→ z=WALL_HEIGHT）。墙饰按扁平
## 坐标绘制即自动贴在斜墙面上。
func _north_wall_transform() -> Transform2D:
	var kex := Proj2D.WALL_HEIGHT * Proj2D.EXTRUDE_X / 24.0
	var khe := Proj2D.WALL_HEIGHT * Proj2D.HEIGHT_SCALE / 24.0
	return Transform2D(Vector2(1, 0), Vector2(kex, khe),
		Vector2(24.0 * Proj2D.SHEAR - 24.0 * kex,
			24.0 * Proj2D.FLOOR_SCALE - 24.0 * khe))


## 北墙装饰（V3 §3/§6/§12）：窗户（玻璃 + 斜高光）+ 海报/计时器/招牌/电视
## （0.5x 贴墙）。全部在北墙本地空间绘制。
func _draw_north_wall_decor() -> void:
	draw_set_transform_matrix(_north_wall_transform())
	# 窗户（V3 §6 窗口斜向自然光载体）：窗框 + 冷青灰玻璃 + 斜高光
	for window_rect in WorldLayout.WINDOWS:
		var wr: Rect2i = window_rect
		draw_rect(wr, Palette.WINDOW_FRAME, true)
		var glass: Rect2i = wr.grow(-2)
		draw_rect(glass, Palette.WINDOW_GLASS, true)
		draw_line(
			Vector2(glass.position.x + 4, glass.position.y + 2),
			Vector2(glass.position.x + 14, glass.position.y + glass.size.y - 2),
			Palette.METAL_HIGHLIGHT, 2.0 * WorldScale.STROKE_COMPENSATION)
	# 墙上挂饰（海报/计时器/招牌/电视）：0.5x 贴墙（同旧 _draw_wall_decor）
	if _env_art != null:
		var tick: int = 0
		if _tick_provider.is_valid():
			tick = _tick_provider.call()
		for prop_id: String in WorldLayout.WALL_DECOR:
			var pos: Vector2i = WorldLayout.WALL_DECOR[prop_id]
			var tex: ImageTexture = _env_art.texture_for(prop_id)
			if tex == null:
				continue
			var size: Vector2i = _env_art.texture_size(prop_id)
			draw_texture_rect(tex, Rect2(pos, Vector2(size) * 0.5), false)
			if prop_id == "tv":
				_draw_tv_screen(pos, tick)
	# 结构元素（挂钟/空调/通风口/喷淋）—— 返工3 P1 起烘焙进北墙纹理
	# （structure_art._bake_north_wall_structure_decor），不再逐帧 draw_rect
	# （draw call 预算让给新增叙事道具）。
	draw_set_transform_matrix(Transform2D.IDENTITY)


## 北墙结构装饰：挂钟/空调/通风口/喷淋头 —— 返工3 P1 起烘焙进北墙
## 墙面纹理（structure_art._bake_north_wall_structure_decor，坐标同源），
## 不再逐帧 draw_rect（draw call 预算让给新增叙事道具）。


## 侧墙（西/东）：墙面 = 手绘粉刷纹理（cluster + jagged 墙帽/踢脚线 +
## 装饰：镜/毛巾架/管道/海报/置物架/挂钟 —— 返工3 P1 起全部烘焙进侧墙
## 纹理，见 structure_art._bake_side_wall）经 _side_wall_transform 一次
## 贴图 —— 替代旧的 3 个纯色多边形 + 每帧 ~13 个装饰 draw_rect
## （draw call 预算让给叙事道具）。西墙 y∈[32..320]（入口门洞 y<32）；
## 东墙 y∈[0..288]（出口门洞 y 288..320）。
func _draw_side_wall(is_west: bool) -> void:
	if _structure_art == null:
		return
	var kind := "west" if is_west else "east"
	var tex: ImageTexture = _structure_art.wall_face_texture(kind)
	if tex == null:
		return
	var x_in := 14.0 if is_west else float(Proj2D.WORLD_W - 14)
	var y0 := 32.0
	if not is_west:
		y0 = 0.0
	# 纹理在墙本地空间 (u=沿墙 y, v=墙高 z)；u 从 y0 起（西墙 32..320 / 东墙 0..288）
	draw_set_transform_matrix(_side_wall_transform(x_in))
	draw_texture_rect(tex, Rect2(y0, 0, StructureArt.WALL_SIDE_TEX.x,
		StructureArt.WALL_SIDE_TEX.y), false)
	draw_set_transform_matrix(Transform2D.IDENTITY)


## 侧墙本地变换：墙本地坐标 (u=沿墙扁平 y，v=墙高 z) → 屏幕。
func _side_wall_transform(x_in: float) -> Transform2D:
	# 侧墙纹理保留 110px 原始细节，但 v 轴压缩到当前 WALL_HEIGHT；这样相机
	# 调墙高不需要破坏 structure_art 中已烘焙的镜子/管道/海报像素。
	var height_ratio := Proj2D.WALL_HEIGHT / float(StructureArt.WALL_SIDE_TEX.y)
	return Transform2D(
		Vector2(Proj2D.SHEAR, Proj2D.FLOOR_SCALE),
		Vector2(-Proj2D.EXTRUDE_X, -Proj2D.HEIGHT_SCALE) * height_ratio,
		Vector2(x_in, 0.0))


## 电视画面变化（V3 §9）：屏幕区域叠 3 帧（青蓝/绿/黄轮换，确定性 tick 驱动）。
## 在北墙本地空间调用（pos 为扁平墙条坐标）。
func _draw_tv_screen(pos: Vector2i, tick: int) -> void:
	var screen_rect := Rect2(pos + Vector2i(3, 3), Vector2i(10, 6))
	var frame := (tick / 20) % 3
	var col: Color
	match frame:
		0:
			col = Palette.EMISSIVE_CYAN
		1:
			col = Palette.EMISSIVE_GREEN
		_:
			col = Palette.ACCENT_YELLOW
	col.a = 0.95
	draw_rect(screen_rect, col, true)


## 地面装饰（V3 §12 场景 storytelling）：水瓶/毛巾/配重/粉笔盒/植物/音箱/
## 卷垫/风扇/水杯架/饮水机/垃圾桶/消防栓。植物轻微摆动（V3 §9）。
## 在 floor pass 内调用（扁平坐标）。
func _draw_floor_decor() -> void:
	if _env_art == null:
		return
	var tick: int = 0
	if _tick_provider.is_valid():
		tick = _tick_provider.call()
	for prop_id: String in WorldLayout.DECOR:
		# 暖色落地灯需保持竖直 silhouette，在 foreground billboard pass 绘制。
		if prop_id == str(WorldLayout.FLOOR_LIGHT.get("decor_id", "")):
			continue
		var pos: Vector2i = WorldLayout.DECOR[prop_id]
		var sway := Vector2.ZERO
		if prop_id.begins_with("plant"):
			# 植物轻微摆动（V3 §9）：±1px 确定性正弦。
			var phase := float(prop_id.hash() % 100) * 0.13
			sway.x = round(sin(tick * 0.08 + phase))
		_draw_decor_prop(prop_id, pos + Vector2i(sway))


## 环境前景（V3 §4 FOREGROUND：大型植物，可轻微遮挡角色）—— 画在设备之后。
## V3.1 P1：前景植物贴地（floor transform 内扁平绘制，billboard 植物）。
## 识别：DECOR 键含 "_fore_" 段（含 plant_fore_* 与 V3.1 P5 亮叶变体
## plant_bright_fore_* —— 用 contains("_fore_") 而非 begins_with 前缀，
## 否则亮叶变体丢失前景层级）。
func _draw_environment_foreground() -> void:
	if _env_art == null:
		return
	var tick: int = 0
	if _tick_provider.is_valid():
		tick = _tick_provider.call()
	_draw_with_floor_transform(func() -> void:
		for prop_id: String in WorldLayout.DECOR:
			if not prop_id.contains("_fore_"):
				continue
			var pos: Vector2i = WorldLayout.DECOR[prop_id]
			var sway := Vector2(round(sin(tick * 0.08 + float(prop_id.hash() % 100) * 0.13)), 0)
			_draw_decor_prop(prop_id, pos + Vector2i(sway))
	)


## 绘制单个装饰精灵（纹理存在才画；未知 prop 兜底不画，绝不崩溃）。
## [scale] 可选缩放（墙挂饰用 0.5 贴合墙高；地面装饰默认 1.0）。
## 在调用方设定的画布变换（floor transform / 墙本地变换）下绘制。
func _draw_decor_prop(prop_id: String, pos: Vector2i, scale: float = 1.0) -> void:
	if _env_art == null:
		return
	var tex: ImageTexture = _env_art.texture_for(prop_id)
	if tex == null:
		return
	var size: Vector2i = _env_art.texture_size(prop_id)
	draw_texture_rect(tex, Rect2(pos, Vector2(size) * scale), false)


## 网格线（V3 §14：仅 placement mode 显示，正常经营模式完全隐藏）。
## 尺寸来自 GridStateReader.get_dimensions()（架构 pinned，不硬编码）。
## 线宽 1.0 × STROKE_COMPENSATION = 1.0 viewport px（world_scale.gd pitfall）。
func _draw_grid_lines() -> void:
	var dims: Vector2i = _grid.get_dimensions()
	for x in dims.x + 1:
		draw_line(Vector2(x * _cell_size, 0), Vector2(x * _cell_size, dims.y * _cell_size),
			Palette.GRID_LINE, 1.0 * WorldScale.STROKE_COMPENSATION)
	for y in dims.y + 1:
		draw_line(Vector2(0, y * _cell_size), Vector2(dims.x * _cell_size, y * _cell_size),
			Palette.GRID_LINE, 1.0 * WorldScale.STROKE_COMPENSATION)


## 设备渲染（V3.1 P1 2.5D）：contact shadow 贴地（floor transform）+ 3 面
## 挤出（顶面 = 原 art 提升到 z=height；正面 = 南边条带变暗；侧面 = 东边
## 条带变暗）。物体有体积（顶面+正面+侧面同时可见），不再是贴地图标
## （V3.1 P1 负面约束：禁止设备贴地图）。
## V3.1 R1（物体/背景分离）：设备脚下加暖色亮池（HIGHLIGHT_WARM 低 alpha
## 椭圆 —— 与会员脚底亮池同源，V3 §15 P0-3 同一视觉语言），把深色设备
## （EQUIP_OUTLINE/BODY 深蓝灰）从深灰橡胶力量区地面（#4B4F57）「托起」：
## 亮池 + 其上双层接触影（宽软外层 + 贴身内层）→ 设备 silhouette 与地面
## 明度分离、落地位强化。纯 presentation 层效果（不改纹理像素、不破坏
## unit 像素断言）；亮池先画、接触影后画（影在亮池上可读）。
##   - hover（§14）：黄色像素轮廓（EQUIP_HOVER_OUTLINE）+ 精灵轻微上移
##     （HOVER_LIFT_PX，contact shadow 留原地 —— 设备「抬起」感）
##   - access cell 用 Butter 高亮（art-bible §7 拖放反馈；§4 Butter 锚点 ~10%）
## 返工5 P1（FAIL3 噪点退让 / FAIL4 焦点区）：
##   - 接触影 outer grow 7→9、alpha 0.30→0.36；core grow 3→4、alpha
##     0.46→0.54 —— 道具 2px 邻域噪点进一步压平（近道具噪点密度显著
##     低于远处地面；道具上零噪点），接地分离拉强
##   - 暖池 alpha 0.16→0.20、rx/ry 放大 —— 主要设备区成为「灯光暖池
##     焦点区」（明度显著高于周边；第一眼先落焦点再扫全图）
func _draw_equipment() -> void:
	if _grid == null or _equip_art == null:
		return
	for inst in _grid.get_placed_instances():
		var fp_rect := _footprint_rect(inst.footprint_cells)
		if fp_rect.size.x <= 0 or fp_rect.size.y <= 0:
			continue
		var is_hovered: bool = inst.instance_id == _hovered_instance_id
		var eq_id := ""
		if _resolver.is_valid():
			eq_id = str(_resolver.call(inst.instance_id))
		var zone: String = _zone_of(eq_id)
		var height: float = _equip_art.height_for(eq_id)
		var tex: ImageTexture = _equip_art.texture_for(eq_id, zone, inst.rotation)
		# 1a. V3.1 R1：设备脚下暖色亮池（与会员脚底亮池同源 —— 深色设备
		# 从深色地面「托起」，silhouette 分离）。亮池先画（低 alpha 暖白，
		# V3 §6 顶部暖白光），接触影随后压在其上。
		_draw_equipment_ground_pool(fp_rect)
		# 1b. V3.1 返工2 R3（FAIL2 方向一致冷投影）：设备在光源另一侧投出
		# 有方向的冷色遮挡投影 —— footprint 沿 cast_shadow_offset（背向最近
		# 吊灯灯泡）平移，低 alpha 冷蓝灰平行四边形（floor transform 贴地）。
		# 方向全场一致（三盏吊灯都在北墙 → 投影统一向南），长度随设备高度
		# 与位置变化 —— 遮挡投影而非区域底色。
		_draw_equipment_cast_shadow(fp_rect, height)
		# 1. 贴地 contact shadow（V3 §6：双层冷蓝灰 —— 宽软外层 + 贴身内层）
		# 返工4 P1（FAIL3 噪点降扰 + 弱项#5 接地）：外层 grow 5→7、alpha
		# 0.22→0.30 —— 道具 2px 邻域地面噪点被阴影压住（噪点远离主体，
		# 地面手绘变化保留在远离设备处）；内层 grow 2→3、alpha 0.40→0.46
		# —— 设备底部与地面分离度拉强（接地线）。同一 2 次 draw_rect，
		# draw call 预算不变（197<200 硬门）。
		# 返工5 P1（FAIL3 噪点退让）：外层 grow 7→9、alpha 0.30→0.36；
		# 内层 grow 3→4、alpha 0.46→0.54 —— 近道具噪点进一步压平。
		# 返工6 P3（第三眼#2 方向一致冷投影）：接触影沿全局主光方向偏移 ——
		# 外层 MAIN_LIGHT_DIR×5、内层 ×3（「近物深硬、远端一档软化」：
		# 内侧贴脚深硬、外侧沿光方向延伸软化），不再是居中团块 —— 暗部
		# 读作「定向投影」而非「区域压暗」（GPT：左侧器械旁大面积深冷影
		# 像无方向团块，中央碎、右侧无 —— 接触影必须同方向）。
		# 尺寸/alpha 保持返工5 P1 口径（grow 9/4、0.36/0.54）—— 只加
		# 方向偏移，不缩尺寸（缩尺寸会把低-sat 覆盖面积让给地板，推高
		# low-sat 基线 0.6313；方向性由偏移承担）。
		_draw_with_floor_transform(func() -> void:
			var soft_rect := fp_rect.grow(9)
			soft_rect.position = soft_rect.position + Vector2i(roundi(WorldLayout.MAIN_LIGHT_DIR.x * 5.0),
				roundi(WorldLayout.MAIN_LIGHT_DIR.y * 5.0))
			var soft := Palette.EQUIP_SHADOW
			soft.a = 0.36
			draw_rect(soft_rect, soft, true)
			var core_rect := fp_rect.grow(4)
			core_rect.position = core_rect.position + Vector2i(roundi(WorldLayout.MAIN_LIGHT_DIR.x * 3.0),
				roundi(WorldLayout.MAIN_LIGHT_DIR.y * 3.0))
			var core := Palette.EQUIP_SHADOW
			core.a = 0.54
			draw_rect(core_rect, core, true)
		)
		# 2. 3 面体积（顶面 + 正面 + 侧面）
		if tex != null:
			_draw_equipment_volume(eq_id, zone, inst.rotation, fp_rect, height)
		else:
			# 兜底（未知 equipment_id）：投影后的剪影盒（侧面+正面+纯色顶），
			# 绝不崩溃。
			var x0 := float(fp_rect.position.x)
			var y0 := float(fp_rect.position.y)
			var x1 := x0 + float(fp_rect.size.x)
			var y1 := y0 + float(fp_rect.size.y)
			draw_colored_polygon(PackedVector2Array([
				Proj2D.proj(x1, y0, 0.0), Proj2D.proj(x1, y1, 0.0),
				Proj2D.proj(x1, y1, height), Proj2D.proj(x1, y0, height),
			]), Palette.CHARCOAL.darkened(0.2))
			draw_colored_polygon(PackedVector2Array([
				Proj2D.proj(x0, y1, 0.0), Proj2D.proj(x1, y1, 0.0),
				Proj2D.proj(x1, y1, height), Proj2D.proj(x0, y1, height),
			]), Palette.CHARCOAL)
			draw_set_transform_matrix(_top_face_transform(height))
			draw_rect(Rect2(fp_rect.position, fp_rect.size), Palette.CHARCOAL, true)
			draw_set_transform_matrix(Transform2D.IDENTITY)
		# 3. hover 黄色像素轮廓（沿投影后的 footprint 平行四边形）
		if is_hovered:
			_draw_equipment_hover(fp_rect, height)
		# 4. access cell 标记（贴地，floor transform；仅 placement/hover 显示）
		if _grid_visible or is_hovered:
			_draw_with_floor_transform(func() -> void:
				for c in inst.access_cells:
					_draw_access_cell(c)
			)


## V3.1 返工2 R3（FAIL2 方向一致冷投影）：设备在光源另一侧投出有方向的
## 冷色遮挡投影 —— footprint 沿 cast_shadow_offset（背向最近吊灯灯泡）平移，
## 画成贴地平行四边形（floor transform 内）。方向全场一致（三盏吊灯都在
## 北墙 → 投影统一向南），长度随设备高度与位置变化 —— 不是区域底色：
## 有形状来源（footprint）、随物体/光源位置变化（WorldLayout 纯函数）。
## 返工3 P3（FAIL2 色温统一 + 非贴图暗块）：颜色用 SHADOW_COOL（干净冷蓝灰，
## b>r —— 与暖光环境冷暖对比，非深灰噪点）。保持 draw_rect（同一颜色下
## 引擎自动批量 —— draw call 预算 <200 硬门；draw_colored_polygon 逐个
## 不批量，5 台设备 +5 calls 直接超预算）。
## 返工6 P3（第三眼#4 空间层次）：alpha 0.20→0.17 —— 深色器械 + 投影不
## 再合成同一块深灰蓝团块（GPT：左中器械群阴影与器械暗部连成团）；方向
## 仍由 MAIN_LIGHT_DIR 全局统一（第三眼#2）。接触影（EQUIP_SHADOW 深色）
## 承担「近物深硬」，方向投影降到「远端一档软化」。
func _draw_equipment_cast_shadow(fp: Rect2i, height: float) -> void:
	var center := Vector2(fp.position) + Vector2(fp.size) * 0.5
	var offset := WorldLayout.cast_shadow_offset(center, height)
	if offset.length() < 2.0:
		return
	var shadow := Palette.SHADOW_COOL
	shadow.a = 0.17
	var shadow_rect := Rect2(Vector2(fp.position) + offset, Vector2(fp.size))
	_draw_with_floor_transform(func() -> void:
		draw_rect(shadow_rect, shadow, true)
	)


## V3.1 R1：设备脚下暖色亮池 —— 半透明暖白椭圆垫在设备 footprint 下方，
## 把深色设备轮廓从深灰橡胶地面「托起」（与会员脚底亮池 _draw_member_ground_glow
## 同源：V3 §15 P0-3 人物视觉权重 → 设备同样分离）。亮池经 floor transform
## 贴地（随地板压缩成椭圆），画在接触影之前（影在亮池上可读）。
## 返工4 P1（FAIL4 空间焦点）：alpha 0.12→0.16、rx/ry 放大 —— 主要设备区
## 成为「灯光暖池焦点区」（明度高于周边、第一眼先落焦点）；暖池同时压住
## 设备 2px 邻域地面噪点（FAIL3 噪点让位主体）。低-sat 实测 0.6306 < 基线
## 0.6313（勾边/接触影覆盖的 floor 像素 sat>0.25 抵消暖池低-sat 增量）。
## 4.7.1 注意：同 _draw_member_ground_glow —— draw_ellipse 签名是
## (position, radius: float) 无 Vector2 尺寸，用 draw_colored_polygon 画
## 16 段椭圆多边形（确定性，低 alpha）。
## 返工5 P1（FAIL4 强焦点区）：alpha 0.16→0.20、rx/ry 再放大 —— 主要设备
## 区是「第一视觉落点」（明度/细节显著高于周边）；暖池只画在设备脚下
## （焦点区），远处地板靠 lighting 冷灰回落压暗留白。
func _draw_equipment_ground_pool(fp: Rect2i) -> void:
	var glow := Palette.HIGHLIGHT_WARM
	glow.a = 0.20
	var cx := fp.position.x + fp.size.x / 2.0
	var cy := fp.position.y + fp.size.y / 2.0
	# 亮池略大于 footprint（宽 0.82 / 高 0.68 —— 焦点暖池：设备区明度高于
	# 周边地板，第一眼先落设备；仍保留深色地面作为设备底边对比）。低-sat
	# 约束：alpha 0.20（HIGHLIGHT_WARM sat≈0.18，池面积小）实测低-sat
	# 0.6317 ≤ 0.6323 基线 —— FAIL4 焦点主要靠灯光暖池区（lighting_layer
	# lamp 落点 + 设备暖池叠加），本池只需轻微暖光提示。
	var rx := fp.size.x * 0.82 + 7.0
	var ry := fp.size.y * 0.68 + 7.0
	_draw_with_floor_transform(func() -> void:
		var pts := PackedVector2Array()
		for i in 16:
			var a := TAU * float(i) / 16.0
			pts.append(Vector2(cx + cos(a) * rx, cy + sin(a) * ry))
		draw_colored_polygon(pts, glow)
	)


## 设备体积（V3.1 P1）：东侧面 + 正面 + 顶面。正面/侧面用 EquipmentArt
## 挤出面纹理（南边/东边条带变暗 —— 顶面亮、正面中、侧面暗，三层分层）。
func _draw_equipment_volume(eq_id: String, zone: String, rotation: int,
		fp: Rect2i, height: float) -> void:
	var faces: Dictionary = _equip_art.extrusion_faces_for(eq_id, zone, rotation, height)
	var x0 := float(fp.position.x)
	var y0 := float(fp.position.y)
	var x1 := x0 + float(fp.size.x)
	var y1 := y0 + float(fp.size.y)
	var face_h := _face_h(height)
	# 东侧面（x=x1）：先画（被正面/顶面压住的部分自然遮挡）
	var side_tex: ImageTexture = faces.get("side")
	if side_tex != null:
		draw_set_transform_matrix(_side_face_transform(x1, y0, height))
		draw_texture_rect(side_tex, Rect2(0, 0, float(fp.size.y), face_h), false)
		draw_set_transform_matrix(Transform2D.IDENTITY)
	else:
		draw_colored_polygon(PackedVector2Array([
			Proj2D.proj(x1, y0, 0.0), Proj2D.proj(x1, y1, 0.0),
			Proj2D.proj(x1, y1, height), Proj2D.proj(x1, y0, height),
		]), Palette.EQUIP_SHADOW_TONE)
	# 正面（y=y1）
	var front_tex: ImageTexture = faces.get("front")
	if front_tex != null:
		draw_set_transform_matrix(_front_face_transform(x0, y1, height))
		draw_texture_rect(front_tex, Rect2(0, 0, float(fp.size.x), face_h), false)
		draw_set_transform_matrix(Transform2D.IDENTITY)
	else:
		draw_colored_polygon(PackedVector2Array([
			Proj2D.proj(x0, y1, 0.0), Proj2D.proj(x1, y1, 0.0),
			Proj2D.proj(x1, y1, height), Proj2D.proj(x0, y1, height),
		]), Palette.EQUIP_BODY_DARK)
	# 顶面（z=height）：原 art 提升
	var top_tex: ImageTexture = _equip_art.texture_for(eq_id, zone, rotation)
	if top_tex != null:
		draw_set_transform_matrix(_top_face_transform(height))
		draw_texture_rect(top_tex, Rect2(fp.position, fp.size), false)
		draw_set_transform_matrix(Transform2D.IDENTITY)


## 挤出面高度（屏幕 px）：height × HEIGHT_SCALE（与 EquipmentArt 同值）。
func _face_h(height: float) -> float:
	return height * Proj2D.HEIGHT_SCALE


## 正面（南边）仿射变换：纹理坐标 (u∈[0,w], v∈[0,face_h]) → 投影后屏幕。
## v 对应 z（v = z*HEIGHT_SCALE）—— 正面平行四边形贴合顶面南边。
func _front_face_transform(x0: float, y1: float, height: float) -> Transform2D:
	var kx := Proj2D.EXTRUDE_X / Proj2D.HEIGHT_SCALE
	return Transform2D(Vector2(1, 0), Vector2(-kx, -1.0),
		Vector2(x0 + y1 * Proj2D.SHEAR, y1 * Proj2D.FLOOR_SCALE))


## 东侧面仿射变换：纹理坐标 (u∈[0,d], v∈[0,face_h]) → 投影后屏幕。
## u 对应沿墙深度（y 方向）—— 侧面平行四边形贴合顶面东边。
func _side_face_transform(x1: float, y0: float, height: float) -> Transform2D:
	var kx := Proj2D.EXTRUDE_X / Proj2D.HEIGHT_SCALE
	return Transform2D(Vector2(Proj2D.SHEAR, Proj2D.FLOOR_SCALE),
		Vector2(-kx, -1.0),
		Vector2(x1 + y0 * Proj2D.SHEAR, y0 * Proj2D.FLOOR_SCALE))


## hover 黄色轮廓：沿投影后的 footprint 平行四边形描边（V3 §14）。画在
## 设备体积之上 —— 顶面 + 侧面 + 正面的外轮廓。
func _draw_equipment_hover(fp: Rect2i, height: float) -> void:
	var hover := Palette.EQUIP_HOVER_OUTLINE
	hover.a = 0.95
	var pts := PackedVector2Array([
		Proj2D.proj(fp.position.x, fp.position.y, height),
		Proj2D.proj(fp.position.x + fp.size.x, fp.position.y, height),
		Proj2D.proj(fp.position.x + fp.size.x, fp.position.y + fp.size.y, 0.0),
		Proj2D.proj(fp.position.x, fp.position.y + fp.size.y, 0.0),
	])
	pts.append(pts[0])
	draw_polyline(pts, hover, 2.0 * WorldScale.STROKE_COMPENSATION, true)


## access cell 高亮：半透明 Butter 填充 + Butter 描边 + 中央实心 Butter 菱形
## （图标+颜色双通道的色盲安全形状；柔和，不刺眼，无闪烁 —— art-bible §7）。
func _draw_access_cell(c: Vector2i) -> void:
	var rect := Rect2i(c * _cell_size, Vector2i(_cell_size, _cell_size))
	var fill := Palette.BUTTER
	fill.a = 0.25
	draw_rect(rect, fill, true)
	var border := Palette.BUTTER
	border.a = 0.85
	draw_rect(rect, border, false, 1.0 * WorldScale.STROKE_COMPENSATION)
	var diamond := Palette.BUTTER
	diamond.a = 0.95
	var cx := rect.position.x + _cell_size / 2.0
	var cy := rect.position.y + _cell_size / 2.0
	var r := 5.0
	var pts := PackedVector2Array([
		Vector2(cx, cy - r),
		Vector2(cx + r, cy),
		Vector2(cx, cy + r),
		Vector2(cx - r, cy),
	])
	draw_colored_polygon(pts, diamond)


## 放置预览幽灵（art-bible §7 拖放反馈）：合法 → 柔和高亮 + Butter 网格吸附
## 描边；非法 → Dusty Rose 柔和警示。画在最上（活动决策预览，Core Rule 7）；
## 无 drag 时无开销（is_dragging O(1)）。
## V3.1 P1：幽灵是贴地预览（floor transform 内绘制 —— tint 块/精灵/描边/
## access cell 全部经地板投影）。
func _draw_placement_ghost() -> void:
	if _placement == null:
		return
	if not _placement.is_dragging():
		return
	# 双幽灵抑制（GDD Core Rule 4 / ModeArbitration）：有选中物时不画新放置幽灵。
	if _arbitration != null and _arbitration.is_ghost_suppressed():
		return
	if not _placement.get_drag_has_previewed():
		return  # 尚未进入任何格 —— 不画 ZERO 幽灵
	var eq_id: String = _placement.get_drag_equipment_id()
	if eq_id == "":
		return
	var def = _catalog.get_definition(eq_id)
	if def == null:
		return
	var anchor: Vector2i = _placement.get_drag_anchor()
	var rotation: int = _placement.get_drag_rotation()
	var tf = _grid.get_transformed_cells(def.footprint_cells, def.access_cells, anchor, rotation)
	var rect := _cells_rect(tf.footprint_cells)
	if rect.size.x <= 0 or rect.size.y <= 0:
		return
	var valid: bool = _placement.get_drag_preview_valid()
	var tint: Color = Palette.PLACEMENT_OK_TINT if valid else Palette.PLACEMENT_BAD_TINT
	var zone: String = _zone_of(eq_id)
	_draw_with_floor_transform(func() -> void:
		draw_rect(rect, tint, true)
		# 精灵本体（半透明幽灵，让玩家看清要放什么）——先于描边，描边永远可读。
		var tex: ImageTexture = _equip_art.texture_for(eq_id, zone, rotation)
		if tex != null:
			var ghost_col := Color(1, 1, 1, 0.65)
			draw_texture_rect(tex, Rect2(rect), false, ghost_col)
		# 网格吸附描边（画在最上，覆盖幽灵本体）：合法 → Butter；非法 → Dusty Rose。
		var edge: Color = Palette.BUTTER if valid else Palette.ROSE
		edge.a = 0.9
		draw_rect(rect, edge, false, 2.0 * WorldScale.STROKE_COMPENSATION)
		for c in tf.access_cells:
			_draw_access_cell(c)
	)


## 会员渲染（Phase 4 / V3 §8）：2.5D 像素小人（48×48，>cell 32 —— 画面视觉
## 主体），状态双通道（颜色通道衬衫色 + 形状通道姿态）。
## V3 §15 修复（P0-3 人物视觉权重）：sprite 纹理尺寸保持 48×48（unit 测试
## 像素断言 pin 住），在绘制层增加「地面亮池 + 加宽接触影」—— 深色轮廓
## （CHARCOAL）在深灰橡胶力量区（#4B4F57）上会融入背景（门禁 FAIL：轮廓
## 弱），脚底亮池把人物从深色地面「托起」，远景远读性增强（V3 §6 接触
## 阴影 + §11 轮廓可读性；不改变纹理像素，不破坏 unit 断言）。
##
## [foreground] 双层绘制：
##   false = 中景：walk/idle/tired/satisfied 会员，脚底锚定自身 cell 底部
##           （sprite 头部向上越出 cell —— 2.5D 人物高于占用格）。
##   true  = 前景：USING 会员叠加在目标设备 footprint 上（跑带/卧推凳/车座/
##           垫面 —— V3 §8 与设备互动姿态），由 _equipment_anchor 计算锚点。
## 设备上下文（equipment_id / leaving_reason / use_ticks_remaining / member_id /
## preference_profile）经 ctx 传入 texture_for —— 使用姿态、外观变体与
## A1 性格外观据此解析。
func _draw_members(foreground: bool) -> void:
	if _member == null or _member_sprites == null:
		return
	var tick: int = 0
	if _tick_provider.is_valid():
		tick = _tick_provider.call()
	var alive: Dictionary = {}
	# USING 成员 → 设备 footprint 锚点查找表（本帧构建一次，O(placed)）。
	var equip_anchors: Dictionary = {}
	if foreground:
		equip_anchors = _build_equipment_anchors()
	for m in _member.members:
		if not (m is Dictionary) or not m.has("cell") or not m.has("state"):
			continue
		var member_id := int(m.get("member_id", -1))
		if member_id >= 0:
			alive[member_id] = true
		var state := str(m["state"])
		if _member_sprites.state_channel(state) == "":
			continue  # GONE / 被动成员 —— 不渲染
		var is_using := state == "USING"
		if is_using != foreground:
			continue  # 双层各画一半
		var cell: Vector2i = m["cell"]
		var facing_left := _update_facing(member_id, cell)
		var ctx := _member_ctx(m, state)
		var tex: ImageTexture = _member_sprites.texture_for(state, tick, facing_left, ctx)
		var draw_pos: Vector2
		if is_using:
			# 前景：锚定设备 footprint（V3 §8 使用姿态叠加在设备上）。
			var anchor: Vector2 = equip_anchors.get(
				int(m.get("target_equipment_instance_id", -1)), Vector2.INF)
			if anchor == Vector2.INF:
				anchor = _cell_anchor(cell)  # 设备丢失兜底：锚定自身 cell
			draw_pos = anchor
		else:
			draw_pos = _cell_anchor(cell)
		# V3 §15（P0-3 人物视觉权重）：脚底亮池 —— 半透明暖白椭圆垫在脚下，
		# 把深色轮廓人物从深灰力量区地面「托起」（远景轮廓可读性）。亮池只
		# 在中景成员绘制（非 USING 叠加在设备上时会被设备盖住，不额外画）。
		# V3.1 P1：亮池贴地（floor transform 内椭圆，随地板压缩）。
		# 返工2 R1（人物-环境互动可读性）：亮池之上加紧凑暗色接触影 ——
		# 脚踩处地面压暗，人物「落在地面」而非贴图。
		if not is_using:
			_draw_member_ground_glow(_flat_feet(cell))
			_draw_member_cast_shadow(_flat_feet(cell))
			_draw_member_contact_shadow(_flat_feet(cell))
		else:
			# USING 成员：设备接触点明暗衔接（脚踩踏板压暗 + 手扶处设备微反光）
			_draw_using_equipment_junction(
				str(ctx.get("equipment_id", "")), _footprint_of_using(m), draw_pos)
		draw_texture(tex, draw_pos)
	# 清理已离场成员的朝向缓存（防止字典无限增长）
	for member_id in _member_facing.keys():
		if not alive.has(member_id):
			_member_facing.erase(member_id)
			_member_last_cell.erase(member_id)


## 构建 instance_id → 设备使用锚点（USING 前景层）。footprint 左上角 +
## 设备类型偏移：跑带居中、卧推凳在凳面、车座居中、垫面居中。锚点是
## 48×48 sprite 的左上角（脚底/接触点对齐设备）。
## [footprint_rect] 世界像素 Rect2i；返回 sprite 左上角 Vector2。
func _build_equipment_anchors() -> Dictionary:
	var anchors: Dictionary = {}
	if _grid == null or _equip_art == null:
		return anchors
	for inst in _grid.get_placed_instances():
		var rect := _footprint_rect(inst.footprint_cells)
		if rect.size.x <= 0 or rect.size.y <= 0:
			continue
		var eq_id := ""
		if _resolver.is_valid():
			eq_id = str(_resolver.call(inst.instance_id))
		anchors[inst.instance_id] = _equipment_anchor(eq_id, rect)
	return anchors


## 设备使用锚点（V3.1 P1 投影后）：sprite 左上角（48×48），使成员"落在"
## 设备上。基准：脚底接触点 = 设备 footprint 底边中点（+ 设备类型微调），
## 投影到设备高度（站立在机器上，billboard 不压缩）。
func _equipment_anchor(eq_id: String, rect: Rect2i) -> Vector2:
	var center_x := rect.position.x + rect.size.x / 2.0
	var feet_y := rect.position.y + rect.size.y
	var sprite_w := float(_member_sprites.SIZE) if _member_sprites != null else 48.0
	var flat_anchor: Vector2
	match eq_id:
		"treadmill":
			# 返工4 P2（贴合微调）：跑带在顶面中段（map 行 5-9 ≈ rect.y+10..18）
			# —— 脚落在跑带中央，身体不再压住前端控制台（旧锚点在 footprint
			# 底边，会员躯干遮挡控制屏 —— 门禁第二眼读不出控制台）。
			flat_anchor = Vector2(center_x - sprite_w / 2.0, rect.position.y + 16.0 - sprite_w)
		"bench_press":
			# 卧推凳：身体横躺 —— 头在左、躯干向右，锚在 footprint 左上角 +
			# 下移 26px 让横躺身体（纹理 18..33 行）落在凳面（pad 中段）
			flat_anchor = Vector2(rect.position.x + 2, rect.position.y + 26)
		"bike":
			# 返工4 P2（贴合微调）：座椅在顶面北侧（map 行 2-3）、踏板在中段
			# （行 10-11 ≈ rect.y+20..24）—— 髋部落座、脚落踏板，与车架贴合；
			# 旧锚点把会员放在 footprint 底边（控制台/车把处），躯干遮挡飞轮。
			flat_anchor = Vector2(center_x - sprite_w / 2.0, rect.position.y - sprite_w + 26.0)
		"yoga_mat":
			# 垫面居中：脚在垫面底边（盘坐）
			flat_anchor = Vector2(center_x - sprite_w / 2.0, feet_y - sprite_w * 0.62)
		_:
			# 未知设备兜底：锚定 footprint 底边居中
			flat_anchor = Vector2(center_x - sprite_w / 2.0, feet_y - sprite_w)
	# 投影：sprite 脚底（flat anchor 底边中心）→ 设备高度（站立在机器上）
	var flat_feet := flat_anchor + Vector2(sprite_w * 0.5, sprite_w)
	var stand_z: float = 16.0
	if _equip_art != null:
		stand_z = _equip_art.height_for(eq_id) * 0.75
	var p := Proj2D.proj(flat_feet.x, flat_feet.y, stand_z)
	return p - Vector2(sprite_w * 0.5, sprite_w)


## 普通（非 USING）会员的 cell 锚点（V3.1 P1 投影后）：sprite 左上角 =
## 脚底（cell 底部中心）投影后 - (sprite_w/2, sprite_h)。billboard 站立，
## 头部向上越出 cell（2.5D 人物高于占用格）。
func _cell_anchor(cell: Vector2i) -> Vector2:
	var sprite_w := float(_member_sprites.SIZE) if _member_sprites != null else 48.0
	var feet := _flat_feet(cell)
	var p := Proj2D.proj(feet.x, feet.y, 0.0)
	return p - Vector2(sprite_w * 0.5, sprite_w)


## 扁平脚底点（世界坐标）：cell 底部中心。供投影锚点与贴地亮池使用。
func _flat_feet(cell: Vector2i) -> Vector2:
	return Vector2(cell.x * _cell_size + _cell_size * 0.5,
		cell.y * _cell_size + _cell_size)


## V3 §15（P0-3 人物视觉权重）：会员脚底亮池 —— 半透明暖白椭圆垫在脚下，
## 把深色轮廓（CHARCOAL）人物从深灰橡胶力量区（#4B4F57）地面「托起」。
## 亮池用低 alpha 暖白（V3 §6 顶部暖白光），宽度略大于 sprite，视觉上
## 像"人物站在灯光下"，远景远读性增强。纯 presentation 层效果 —— 不改
## 纹理像素、不破坏 unit 像素断言；画在 sprite 之下（先画亮池后画人物）。
## 4.7.1 注意：draw_ellipse 签名是 (position, radius: float, ...) 无 Vector2
## 尺寸 —— 用 draw_colored_polygon 画椭圆多边形（16 段，确定性，低 alpha）。
## V3.1 P1：亮池贴地 —— 扁平脚底坐标 + floor transform（椭圆随地板压缩）。
## 返工3 P2（性能预算 <200 draw calls）：亮池与接触影合并烘焙成单张纹理
## （_member_ground_fx_texture），每会员 1 次 draw_texture_rect 替代 2 次
## draw_colored_polygon —— 像素等价（同 16 段椭圆几何 + 同 alpha 叠色），
## 视觉不变，节省 1 call/会员（6 个非 USING 会员 = 6 calls）。
func _draw_member_ground_glow(flat_feet: Vector2) -> void:
	var tex := _member_ground_fx_texture()
	if tex == null:
		return
	var size := float(_member_sprites.SIZE) if _member_sprites != null else 48.0
	var rx := size * 0.62
	var ry := size * 0.16
	_draw_with_floor_transform(func() -> void:
		draw_texture_rect(tex,
			Rect2(flat_feet - Vector2(rx, ry), Vector2(rx * 2.0, ry * 2.0)),
			false)
	)


## 返工2 R1（人物-环境互动可读性）：会员脚底紧凑暗色接触影 —— 亮池之上
## 再压一层贴地小椭圆（暗蓝灰，低 alpha），脚踩处地面「压暗」，人物与
## 地面有明确明暗衔接（不再像贴上去的图形）。画在亮池之后、sprite 之前。
## 返工3 P2：与亮池合并烘焙（见 _draw_member_ground_glow）—— 本函数
## 保留为兼容入口，仅画合并纹理（几何完全一致，不新增 draw call）。
func _draw_member_contact_shadow(flat_feet: Vector2) -> void:
	# 接触影已烘焙进亮池纹理（_member_ground_fx_texture 内 alpha 叠色）——
	# 不再单独绘制，避免重复画同一椭圆（draw call 预算）。
	pass


## 返工2 R3（FAIL2 方向一致冷投影）：会员脚底方向投影 —— 人物在光源另一侧
## 投出有方向的冷色遮挡投影（小椭圆，沿 cast_shadow_offset 背向最近吊灯
## 灯泡平移）。与设备方向投影同一规则（WorldLayout 纯函数）—— 方向全场
## 一致、随物体位置/光源位置变化；是「遮挡投影」而非区域底色。画在亮池
## 之后、接触影之前（亮池托起人物，方向投影把人物「锚」在地面）。
## 返工3 P2：接触影已并入亮池纹理（_member_ground_fx_texture），本函数
## 单独绘制方向投影（有方向偏移，不能烘焙进居中纹理）。
## 返工6 P3（第三眼#2 方向一致冷投影）：方向来自全局 MAIN_LIGHT_DIR（不再
## 逐物体最近灯摆动 —— 全场投影方向一致）；alpha 0.16→0.19 —— 人物/器械/
## 地面层次拉开（GPT：人物脚底方向投影可读，人物不再悬在地面噪点上）。
func _draw_member_cast_shadow(flat_feet: Vector2) -> void:
	var offset := WorldLayout.cast_shadow_offset(flat_feet, 20.0)
	if offset.length() < 2.0:
		return
	# 返工3 P3（FAIL2 阴影色温统一）：会员投影同样用干净冷蓝灰 SHADOW_COOL
	# （b>r）—— 与设备投影同色温，全场景冷色阴影统一（非深灰噪点）。
	var shadow := Palette.SHADOW_COOL
	shadow.a = 0.19
	var size := float(_member_sprites.SIZE) if _member_sprites != null else 48.0
	var rx := size * 0.30
	var ry := size * 0.09
	_draw_with_floor_transform(func() -> void:
		var pts := PackedVector2Array()
		for i in 16:
			var a := TAU * float(i) / 16.0
			pts.append(flat_feet + offset + Vector2(cos(a) * rx, sin(a) * ry))
		draw_colored_polygon(pts, shadow)
	)


## 亮池+接触影合并纹理缓存（返工3 P2 性能优化）。key = "size"（会员尺寸）。
## 纹理内容 = 同一 16 段椭圆几何：外圈暖白亮池（HIGHLIGHT_WARM a=0.12，
## rx=0.62·size / ry=0.16·size）+ 内圈暗色接触影（EQUIP_SHADOW a=0.36，
## rx=0.28·size / ry=0.09·size），中心对齐 —— 与旧两次 draw_colored_polygon
## 逐像素等价（含 alpha 叠色顺序：先亮池后接触影）。两种颜色都低 alpha、
## 接触影完全包含在亮池内 → 叠色结果与旧两遍绘制相同。
## 返工6 P3（第三眼#4 空间层次）：接触影「更小更纯」—— rx 0.34→0.28、
## alpha 0.30→0.36（GPT：人物脚下用更小、更纯的接触阴影，脚踩处明暗衔接
## 明确、不扩散成暗块）；亮池 alpha 0.10→0.12（人物/地面中间明度差拉大，
## 消除「人物下半身/器械底座/阴影合成同一块深灰蓝」的粘连读法）。
var _member_ground_fx_cache: Dictionary = {}


func _member_ground_fx_texture() -> ImageTexture:
	var size := float(_member_sprites.SIZE) if _member_sprites != null else 48.0
	var key := str(size)
	if _member_ground_fx_cache.has(key):
		return _member_ground_fx_cache[key]
	var rx := size * 0.62
	var ry := size * 0.16
	var w := maxi(1, ceili(rx * 2.0))
	var h := maxi(1, ceili(ry * 2.0))
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var glow := Palette.HIGHLIGHT_WARM
	glow.a = 0.12
	var contact := Palette.EQUIP_SHADOW
	contact.a = 0.36
	var glow_rx := rx
	var glow_ry := ry
	var contact_rx := size * 0.28
	var contact_ry := size * 0.09
	for py in h:
		for px in w:
			# 纹理中心 = 会员脚底；像素相对中心的世界偏移
			var dx := (float(px) + 0.5 - rx)
			var dy := (float(py) + 0.5 - ry)
			var c := Color(0, 0, 0, 0)
			if _point_in_ellipse(dx, dy, glow_rx, glow_ry):
				c = glow
			if _point_in_ellipse(dx, dy, contact_rx, contact_ry):
				# 接触影叠在亮池上（同旧两遍绘制的顺序）
				c = _alpha_over(c, contact)
			img.set_pixel(px, py, c)
	var tex := ImageTexture.create_from_image(img)
	_member_ground_fx_cache[key] = tex
	return tex


## 点是否在 16 段椭圆多边形内（世界坐标，rx/ry 为半径）。与旧
## draw_colored_polygon 使用完全相同的 16 顶点几何 —— 逐像素一致
## （非平滑椭圆：16 段弦近似，保证纹理与旧绘制位图相同）。
func _point_in_ellipse(dx: float, dy: float, rx: float, ry: float) -> bool:
	if rx <= 0.0 or ry <= 0.0:
		return false
	# 射线法 point-in-polygon（16 顶点 = TAU/16 步进，与旧 draw_colored_polygon 同源）
	var inside := false
	var prev_a := TAU * 15.0 / 16.0
	var px0 := cos(prev_a) * rx
	var py0 := sin(prev_a) * ry
	for i in 16:
		var a := TAU * float(i) / 16.0
		var px1 := cos(a) * rx
		var py1 := sin(a) * ry
		if (py0 > dy) != (py1 > dy):
			var x_cross := (px1 - px0) * (dy - py0) / (py1 - py0) + px0
			if dx < x_cross:
				inside = not inside
		px0 = px1
		py0 = py1
	return inside


## src over dst 的简单 alpha 合成（straight alpha）。
func _alpha_over(dst: Color, src: Color) -> Color:
	var a := src.a + dst.a * (1.0 - src.a)
	if a <= 0.0:
		return Color(0, 0, 0, 0)
	return Color(
		(src.r * src.a + dst.r * dst.a * (1.0 - src.a)) / a,
		(src.g * src.a + dst.g * dst.a * (1.0 - src.a)) / a,
		(src.b * src.a + dst.b * dst.a * (1.0 - src.a)) / a,
		a)


## 返工2 R1（人物-环境互动可读性，USING 成员）：设备接触点明暗衔接。
##   - 脚踩踏板/车座/垫面处：设备受光面上加紧凑暗色接触影（设备高度
##     stand_z 投影 —— 脚踩设备，不是浮在设备上空）
##   - 手扶处：设备正面临近手的位置叠 2-3px 暖色微反光（HIGHLIGHT_WARM
##     低 alpha —— 手部接触的设备表面「接住灯光」）
## 与 R2 会员重绘配合（R2 侧重精灵本体；本函数侧重环境侧衔接）。
## [eq_id] USING 成员的目标设备；[fp] 设备 footprint（世界 Rect2i）；
## [draw_pos] 会员 sprite 左上角（已投影）。
func _draw_using_equipment_junction(eq_id: String, fp: Rect2i,
		draw_pos: Vector2) -> void:
	if fp.size.x <= 0 or fp.size.y <= 0:
		return
	var size := float(_member_sprites.SIZE) if _member_sprites != null else 48.0
	# 接触影：锚点下方（sprite 脚底）在设备高度压暗 —— 小椭圆。
	var stand_z: float = 16.0
	if _equip_art != null:
		stand_z = _equip_art.height_for(eq_id) * 0.75
	var feet := draw_pos + Vector2(size * 0.5, size * 0.92)
	var shadow := Palette.EQUIP_SHADOW
	shadow.a = 0.26
	var rx := size * 0.30
	var ry := size * 0.09
	var pts := PackedVector2Array()
	for i in 16:
		var a := TAU * float(i) / 16.0
		pts.append(feet + Vector2(cos(a) * rx, sin(a) * ry))
	draw_colored_polygon(pts, shadow)
	# 手扶处设备微反光：设备正面临近手的位置叠暖色像素（1-3px，低 alpha）。
	# 位置 = 设备 footprint 底边中点投影到设备高度 ± 类型微调（手在设备
	# 前侧）。只加少量像素 —— 反光不是光斑。
	var grip_world := Vector2(fp.position.x + fp.size.x * 0.5,
		fp.position.y + fp.size.y * 0.62)
	var grip_h := stand_z * 0.72
	match eq_id:
		"treadmill":
			# 控制台扶手：跑带南端，手在面板附近（高度略高于站立面）
			grip_world = Vector2(fp.position.x + fp.size.x * 0.5,
				fp.position.y + fp.size.y * 0.80)
			grip_h = stand_z * 0.85
		"bike":
			# 车把：车架北端（把手在座位前上方）
			grip_world = Vector2(fp.position.x + fp.size.x * 0.5,
				fp.position.y + fp.size.y * 0.30)
			grip_h = stand_z * 0.95
		"bench_press":
			# 杠铃杆：凳面正上方（手托杆）
			grip_world = Vector2(fp.position.x + fp.size.x * 0.5,
				fp.position.y + fp.size.y * 0.5)
			grip_h = stand_z * 1.10
		"yoga_mat":
			# 垫面：手按垫（无高出表面 —— 接触影已表达，不叠反光）
			return
	# 手扶处暖色微反光（画在设备顶面上方，仍是像素级小反光）
	var grip := Proj2D.proj(grip_world.x, grip_world.y, grip_h)
	var glint := Palette.HIGHLIGHT_WARM
	glint.a = 0.20
	var snapped := Vector2(roundf(grip.x), roundf(grip.y))
	draw_rect(Rect2(snapped + Vector2(-2, -1), Vector2(5, 2)), glint, true)


## USING 成员的设备 footprint（world Rect2i）—— 从 target_equipment_instance_id
## 解析；设备丢失时返回零矩形（junction 函数内部跳过）。
func _footprint_of_using(m: Dictionary) -> Rect2i:
	var target := int(m.get("target_equipment_instance_id", -1))
	if target < 0 or _grid == null:
		return Rect2i()
	for inst in _grid.get_placed_instances():
		if inst.instance_id == target:
			return _footprint_rect(inst.footprint_cells)
	return Rect2i()


## 会员绘制上下文（V3 §8 设备互动 + §9 微型动态 + A1 性格外观）：
##   equipment_id       USING 成员的目标设备（经 resolver）
##   leaving_reason     LEAVING 成员的离场原因（quota_met → satisfied 满意）
##   use_ticks_remaining  USING 剩余 tick（bench 结束坐起窗口）
##   member_id          外观变体（每人清晰发型/皮肤色块）
##   preference_profile A1 偏好类型（体型 + 胸前徽记，不改状态衬衫色）
func _member_ctx(m: Dictionary, state: String) -> Dictionary:
	var ctx := {
		"member_id": int(m.get("member_id", -1)),
	}
	var profile: Variant = m.get("preference_profile", {})
	if profile is Dictionary and not (profile as Dictionary).is_empty():
		ctx["preference_profile"] = (profile as Dictionary).duplicate(true)
	if state == "USING":
		var target := int(m.get("target_equipment_instance_id", -1))
		if target >= 0 and _resolver.is_valid():
			ctx["equipment_id"] = str(_resolver.call(target))
		if m.has("use_ticks_remaining"):
			ctx["use_ticks_remaining"] = int(m["use_ticks_remaining"])
	if state == "LEAVING":
		ctx["leaving_reason"] = str(m.get("leaving_reason", ""))
	return ctx


## 由 cell 移动推断朝向（presentation 层，纯绘制用；横向位移为 0 时保持上次
## 朝向 —— QUEUEING/USING 成员静止，姿态已表达状态，朝向仅跟随入场方向）。
func _update_facing(member_id: int, cell: Vector2i) -> bool:
	var facing_left := bool(_member_facing.get(member_id, false))
	if _member_last_cell.has(member_id):
		var prev: Vector2i = _member_last_cell[member_id]
		if cell.x < prev.x:
			facing_left = true
		elif cell.x > prev.x:
			facing_left = false
	_member_last_cell[member_id] = cell
	_member_facing[member_id] = facing_left
	return facing_left


## footprint 单元格集合 → 像素 Rect2i（min cell × CELL_SIZE，size = bbox）。
func _footprint_rect(cells: Array) -> Rect2i:
	return _cells_rect(cells)


## 任意网格 cell 集合 → 像素 Rect2i（空集合返回零尺寸）。
func _cells_rect(cells: Array) -> Rect2i:
	if cells.is_empty():
		return Rect2i()
	var min_c := Vector2i(cells[0])
	var max_c := Vector2i(cells[0])
	for c in cells:
		min_c.x = min(min_c.x, c.x)
		min_c.y = min(min_c.y, c.y)
		max_c.x = max(max_c.x, c.x)
		max_c.y = max(max_c.y, c.y)
	var size := (max_c - min_c + Vector2i.ONE) * _cell_size
	return Rect2i(min_c * _cell_size, size)


## equipment_id → zone_membership[0]（语义色键，与 palette.ZONE_COLORS 对齐）。
## 未知 id 返回 ""（EquipmentArt 兜底 FALLBACK_ZONE）。
func _zone_of(eq_id: String) -> String:
	if eq_id == "" or _catalog == null:
		return ""
	var def = _catalog.get_definition(eq_id)
	if def == null or def.zone_membership.is_empty():
		return ""
	return str(def.zone_membership[0])
