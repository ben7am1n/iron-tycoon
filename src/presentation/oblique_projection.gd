# src/presentation/oblique_projection.gd — V3.1 P1 2.5D 斜俯视投影（单一来源）
#
# 附录 V3.1 P1：Camera 改 2.5D 斜俯视（30-45° diorama）。本文件是投影数学
# 的唯一权威来源 —— 世界绘制（WorldCanvas / LightingLayer / AmbientFx /
# 结构层）、屏幕↔世界映射（main.gd 输入桥接 + 世界锚定 UI）、证据脚本采样
# 一律引用这里，禁止各文件各写各的换算。
#
# 模型：正交斜投影（oblique orthographic），相机在房间南侧、俯角 50°。
# V3.1 camera fix：操作区以俯视可读性为主，观察方向仍略偏东南 → 地板 y 轴
# （向南）在屏幕上向右
# 倾斜（SHEAR），地板垂直方向压缩（FLOOR_SCALE = 视线俯角的正弦效果：
# 俯角 θ 越大越接近纯俯视，地板 y 轴被压缩得越少；50° 时 sin≈0.77），
# 物体高度在屏幕上向上挤出（HEIGHT_SCALE = 俯角的余弦效果：θ 越大高度
# 越不可见；50° 时 cos≈0.64）且顶面略微左移（EXTRUDE_X —— 使物体东侧面
# 可见，V3.1 P1「顶面+正面+侧面同时可见」）。较弱剪切/挤出把空间感留在
# 墙体和物体边缘，不再让整个中央地板读作强烈斜视房间盒。
#
# V3.1 R1（俯视布局图修复）：此前 FLOOR_SCALE/HEIGHT_SCALE 取反（0.78/0.62
# 相当于俯角 52° —— 超出 30-45° 区间，读作近俯视布局图）。修正为
# FLOOR_SCALE=sin38°≈0.62 / HEIGHT_SCALE=cos38°≈0.79 —— 地板更强压缩
# （纵深透视感）+ 墙体/设备更高挤出（diorama 房间盒），第一眼不再像
# 俯视布局图。
#
#   proj(x, y, z) = (x + y*SHEAR - z*EXTRUDE_X, y*FLOOR_SCALE - z*HEIGHT_SCALE)
#
# 其中 (x, y) 是扁平世界像素坐标（floor 平面，416×320，CELL_SIZE=32），
# z 是高度（世界像素，0 = 地面）。z=0 时 proj 退化为地板仿射变换：
#
#   floor_transform() = Transform2D((1,0), (SHEAR, FLOOR_SCALE), ZERO)
#
# 因此所有「贴地内容」（地板材质/网格/接触影/装饰/幽灵/光照/热力）继续用
# 扁平坐标绘制，包一层 floor_transform 即可；所有「有体积内容」（墙/设备/
# 会员/结构）用 proj(x, y, z) 手工计算三个面。
#
# 边界（bounds()）：投影后画布 = 地板平行四边形 + 墙面向上的挤出。计算
# 确定性，main.gd 的 SubViewport 尺寸/偏移与 evidence 采样都从它来。
#
# 数值选择（camera fix）：TILT 50°（sin≈0.77 / cos≈0.64）；SHEAR=0.22
# （保留朝东南的斜向边缘）；EXTRUDE_X=0.16（设备侧面仍清楚可见）；
# WALL_HEIGHT=64（2 cell）。墙/天花板退到边缘，中央地板与设备成为主视角。
#
# headless 可靠性：无 class_name 依赖（项目约定），跨脚本 preload alias。
class_name ObliqueProjection extends RefCounted

## 俯角（度）。50° 使中央地板更接近俯视，同时仍保留可见立面。
const TILT_DEG := 50.0
## 地板垂直缩放（y 轴屏幕缩放 = sin 50° ≈ 0.766）。
const FLOOR_SCALE := 0.77
## 高度挤出（z → 屏幕 y 缩放 = cos 50° ≈ 0.643）。
const HEIGHT_SCALE := 0.64
## 地板 y 轴向右倾斜量（x += y * SHEAR）—— 使侧面可见。
const SHEAR := 0.22
## 高度挤出向左偏移（x -= z * EXTRUDE_X）—— 使东侧面可见。
const EXTRUDE_X := 0.16
## 墙面高度（世界像素，2 cell）。北墙/侧墙只承担边缘空间感。
const WALL_HEIGHT := 64.0

## 扁平世界像素空间尺寸（与 main.gd / WorldLayout 对齐）。
const WORLD_W := 416
const WORLD_H := 320
## 网格 cell 尺寸（世界像素）。
const CELL := 32

## 投影 bounds 的可复用常量。main.gd 的低分辨率视口偏移直接引用，避免
## 调参后出现输入映射/渲染中心错位。
const PROJECTED_MIN := Vector2(
	SHEAR * CELL - EXTRUDE_X * WALL_HEIGHT,
	-HEIGHT_SCALE * WALL_HEIGHT)
const PROJECTED_MAX := Vector2(
	WORLD_W + WORLD_H * SHEAR,
	WORLD_H * FLOOR_SCALE)
const PROJECTED_SIZE := PROJECTED_MAX - PROJECTED_MIN

# === 世界像素空间 → 投影后画布空间 ===

## 3D 投影：(x, y) 扁平地面坐标 + z 高度 → 画布（世界）坐标。
static func proj(x: float, y: float, z: float) -> Vector2:
	return Vector2(
		x + y * SHEAR - z * EXTRUDE_X,
		y * FLOOR_SCALE - z * HEIGHT_SCALE
	)

## 地板仿射变换（z=0 时的 proj）：扁平坐标 → 投影后坐标。
## 贴地绘制用 draw_set_transform_matrix(floor_transform()) 包裹。
static func floor_transform() -> Transform2D:
	return Transform2D(Vector2(1, 0), Vector2(SHEAR, FLOOR_SCALE), Vector2.ZERO)

## 投影后画布边界（含墙面向上的挤出）。main.gd 的 SubViewport 尺寸/偏移、
## evidence 采样、canvas 背景填充都用它。精确计算（无外扩）：
## camera fix 后约为 (-3.2,-40.96)..(486.4,246.4)：地板占据主要高度，
## 64px 墙体只在投影边缘立起。
static func bounds() -> Rect2:
	return Rect2(PROJECTED_MIN, PROJECTED_SIZE)

## WorldRoot 在 SubViewport 中的偏移：把投影后画布 bounds() 在 viewport 内
## 居中（bounds 含负坐标 —— 墙顶在 y<0，偏移必须把这些部分拉回屏幕内）。
## [viewport_size] SubViewport 尺寸（如 426×240）；[world_scale] WorldRoot
## 缩放（0.75）。main.gd 用它替代旧的固定 57,0（旧偏移假设世界坐标从 0 起）。
static func viewport_offset(viewport_size: Vector2, world_scale: float) -> Vector2:
	var b := bounds()
	return (viewport_size - b.size * world_scale) * 0.5 - b.position * world_scale

## 世界像素空间地板尺寸（扁平，用于 floor_art 等）。
static func world_size() -> Vector2i:
	return Vector2i(WORLD_W, WORLD_H)

# === 投影逆变换（screen ↔ world，输入桥接） ===

## 屏幕坐标（1280×720）→ 扁平世界坐标（供 grid.world_to_grid）。
## 依赖 main.gd 的视口常量（scale / offset / 屏幕放大）—— 以参数传入，
## 避免本文件反向依赖 main.gd（证据脚本可独立复算）。
static func screen_to_world(
	screen_pos: Vector2,
	viewport_offset: Vector2,
	world_scale: float,
	screen_per_viewport: Vector2
) -> Vector2:
	var vp := Vector2(
		screen_pos.x / screen_per_viewport.x,
		screen_pos.y / screen_per_viewport.y
	)
	var projected := (vp - viewport_offset) / world_scale
	# 逆 floor_transform：y = py / FLOOR_SCALE；x = px - y * SHEAR
	var y := projected.y / FLOOR_SCALE
	var x := projected.x - y * SHEAR
	return Vector2(x, y)

## 扁平世界坐标 → 屏幕坐标（世界锚定 UI / evidence 采样）。
## 依赖 main.gd 视口常量 —— 参数传入同上。
static func world_to_screen(
	world_pos: Vector2,
	viewport_offset: Vector2,
	world_scale: float,
	screen_per_viewport: Vector2,
	height_z: float = 0.0
) -> Vector2:
	var projected := proj(world_pos.x, world_pos.y, height_z)
	return (projected * world_scale + viewport_offset) * screen_per_viewport

## 扁平世界坐标（带高度 z）→ 投影后画布坐标。绘制层直接用。
static func project_world(world_pos: Vector2, height_z: float = 0.0) -> Vector2:
	return proj(world_pos.x, world_pos.y, height_z)
