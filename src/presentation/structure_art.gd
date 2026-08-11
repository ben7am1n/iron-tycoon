# src/presentation/structure_art.gd — 结构层程序化工厂（Phase 2，与 Phase 5 并存）
#
# V3 §3（环境资产密度）/ §4（三层空间）/ §13（密度标准）：
#   Phase 5 已实现地板材质（FloorArt，V3 §1）与场景装饰精灵（EnvironmentArt +
#   world_layout，V3 §12）。本工厂补充 Phase 5 未覆盖的「结构元素」—— 立柱、
#   前台、储物柜、镜子、空调、墙钟、通风口、吊灯、管道、踢脚线、电线槽、
#   毛巾架、门、门垫 —— 烘焙成三张图层贴图（BACKGROUND / GAMEPLAY /
#   FOREGROUND），WorldCanvas 每层每帧只 draw 一次（共 3 draw calls）。
#
# V3.1 P3（Pixel density 改手绘感）：
#   - 大型结构由多个 pixel cluster 组成，非完整矩形填充（lockers/mirror/
#     desk/column 表面叠同族色块 + 磨损细节）
#   - 不规则像素边缘：_fill_irregular 逐行抖动边界 ±2 —— 无完美矩形
#   - 减少完美直线/重复规则纹理：储物柜门缝错位、通风口栅条间距抖动、
#     空调出风栅抖动、音箱网孔不规则、门垫/海报/板片边缘 jagged
#   - 局部磨损/随机细节：hash 驱动的小色块与磨损像素（确定性，无 RNG）
#
# 空间层级（V3 §4）：
#   - BACKGROUND：储物柜/镜子/空调/墙钟/通风口/管道/踢脚线/电线槽/毛巾架/
#     门/门垫 —— 降对比降饱和（_col 烘焙）
#   - GAMEPLAY：前台（主要交互对象）—— 更清楚、更鲜艳、轮廓更明确
#   - FOREGROUND：近景立柱/吊灯 —— 允许轻微遮挡角色
#
# 密度标准（V3 §13）：STRUCTURES 表 = 全场景结构清单（含 Phase 5 已绘制的
# 墙/窗/海报/植物/装饰，painted_by 标记）。density_counts() 统计整表 →
# large 5-10 / medium 15-30 / small 30-60（测试断言区间）。本层只烘焙
# painted_by == "self" 的元素（Phase 5 的元素由 Phase 5 world_canvas 绘制，
# 本层不重复画墙/窗/装饰，避免双画）。
#
# 确定性：结构位置全部固定（无 RNG）；纹理烘焙一次并缓存。V3.1 P3 的
# 不规则细节全部由确定性 hash 驱动（同输入同输出，headless 可测）。
# headless 可靠性：无 class_name（项目约定），跨脚本 preload alias。
class_name StructureArt extends RefCounted

const Palette := preload("res://src/palette.gd")

## 世界像素尺寸（与 main.gd / WorldLayout 对齐）。
const WORLD_W := 416
const WORLD_H := 320

## 图层名常量。
const LAYER_BACKGROUND := "BACKGROUND"
const LAYER_GAMEPLAY := "GAMEPLAY"
const LAYER_FOREGROUND := "FOREGROUND"

## 结构表（V3 §13 密度数据源；测试直接断言 size 分类区间）。
## 字段：id / kind（绘制分派）/ layer（空间层级）/ size（large|medium|small）/
##       rect（世界像素矩形）/ painted_by（self=本层绘制 | phase5=Phase 5 绘制）。
## 说明：painted_by=="phase5" 的条目（墙/窗/海报/植物/装饰精灵）由 Phase 5 的
## world_canvas + world_layout 绘制 —— 本表保留它们仅为密度统计（V3 §13 是
## 全场景口径），烘焙时跳过。painted_by=="self" 的条目是本层的结构元素。
const STRUCTURES := [
	# === 大型结构（large：5-10）===
	{"id": "wall_north", "kind": "wall", "layer": LAYER_BACKGROUND, "size": "large", "rect": Rect2i(32, 0, 384, 24), "painted_by": "phase5"},
	{"id": "wall_west", "kind": "wall", "layer": LAYER_BACKGROUND, "size": "large", "rect": Rect2i(0, 32, 14, 288), "painted_by": "phase5"},
	{"id": "wall_east", "kind": "wall", "layer": LAYER_BACKGROUND, "size": "large", "rect": Rect2i(402, 0, 14, 288), "painted_by": "phase5"},
	{"id": "lockers", "kind": "lockers", "layer": LAYER_BACKGROUND, "size": "large", "rect": Rect2i(2, 170, 8, 120), "painted_by": "self"},
	{"id": "front_desk", "kind": "desk", "layer": LAYER_GAMEPLAY, "size": "large", "rect": Rect2i(56, 24, 104, 24), "painted_by": "self"},
	{"id": "mirror", "kind": "mirror", "layer": LAYER_BACKGROUND, "size": "large", "rect": Rect2i(2, 32, 8, 104), "painted_by": "self"},
	{"id": "column_1", "kind": "column", "layer": LAYER_FOREGROUND, "size": "large", "rect": Rect2i(156, 16, 8, 288), "painted_by": "self"},
	{"id": "column_2", "kind": "column", "layer": LAYER_FOREGROUND, "size": "large", "rect": Rect2i(276, 16, 8, 288), "painted_by": "self"},
	{"id": "plant_large_1", "kind": "plant", "layer": LAYER_FOREGROUND, "size": "large", "rect": Rect2i(0, 244, 32, 32), "painted_by": "phase5"},
	{"id": "plant_large_2", "kind": "plant", "layer": LAYER_FOREGROUND, "size": "large", "rect": Rect2i(384, 244, 32, 32), "painted_by": "phase5"},
	# === 中型结构（medium：15-30）===
	{"id": "window_1", "kind": "window", "layer": LAYER_BACKGROUND, "size": "medium", "rect": Rect2i(96, 4, 56, 18), "painted_by": "phase5"},
	{"id": "window_2", "kind": "window", "layer": LAYER_BACKGROUND, "size": "medium", "rect": Rect2i(272, 4, 56, 18), "painted_by": "phase5"},
	{"id": "door_entrance", "kind": "door", "layer": LAYER_BACKGROUND, "size": "medium", "rect": Rect2i(8, 0, 24, 24), "painted_by": "self"},
	{"id": "door_exit", "kind": "door", "layer": LAYER_BACKGROUND, "size": "medium", "rect": Rect2i(402, 288, 14, 32), "painted_by": "self"},
	{"id": "poster_1", "kind": "poster", "layer": LAYER_BACKGROUND, "size": "medium", "rect": Rect2i(168, 1, 24, 24), "painted_by": "phase5"},
	{"id": "poster_2", "kind": "poster", "layer": LAYER_BACKGROUND, "size": "medium", "rect": Rect2i(220, 1, 24, 24), "painted_by": "phase5"},
	{"id": "wall_clock", "kind": "wall_clock", "layer": LAYER_BACKGROUND, "size": "medium", "rect": Rect2i(200, 3, 12, 10), "painted_by": "self"},
	{"id": "ac_unit", "kind": "ac", "layer": LAYER_BACKGROUND, "size": "medium", "rect": Rect2i(244, 2, 28, 12), "painted_by": "self"},
	{"id": "vent_1", "kind": "vent", "layer": LAYER_BACKGROUND, "size": "medium", "rect": Rect2i(156, 4, 12, 8), "painted_by": "self"},
	{"id": "vent_2", "kind": "vent", "layer": LAYER_BACKGROUND, "size": "medium", "rect": Rect2i(248, 4, 12, 8), "painted_by": "self"},
	{"id": "water_fountain", "kind": "fountain", "layer": LAYER_BACKGROUND, "size": "medium", "rect": Rect2i(20, 40, 32, 32), "painted_by": "phase5"},
	{"id": "trash_can", "kind": "trash", "layer": LAYER_BACKGROUND, "size": "medium", "rect": Rect2i(384, 30, 32, 32), "painted_by": "phase5"},
	{"id": "towel_rack", "kind": "towel_rack", "layer": LAYER_BACKGROUND, "size": "medium", "rect": Rect2i(2, 296, 8, 6), "painted_by": "self"},
	{"id": "fire_hydrant", "kind": "hydrant", "layer": LAYER_BACKGROUND, "size": "medium", "rect": Rect2i(12, 120, 32, 32), "painted_by": "phase5"},
	{"id": "shelf", "kind": "shelf", "layer": LAYER_BACKGROUND, "size": "medium", "rect": Rect2i(2, 142, 8, 8), "painted_by": "self"},
	{"id": "speaker_1", "kind": "speaker", "layer": LAYER_BACKGROUND, "size": "medium", "rect": Rect2i(336, 96, 32, 32), "painted_by": "phase5"},
	{"id": "timer_bike", "kind": "wall_clock", "layer": LAYER_BACKGROUND, "size": "medium", "rect": Rect2i(52, 1, 24, 24), "painted_by": "phase5"},
	{"id": "tv", "kind": "tv", "layer": LAYER_BACKGROUND, "size": "medium", "rect": Rect2i(320, 1, 24, 24), "painted_by": "phase5"},
	# === 小型结构（small：30-60）===
	{"id": "cable_duct_north", "kind": "cable", "layer": LAYER_BACKGROUND, "size": "small", "rect": Rect2i(32, 26, 384, 2), "painted_by": "self"},
	{"id": "cable_duct_west", "kind": "cable", "layer": LAYER_BACKGROUND, "size": "small", "rect": Rect2i(10, 32, 2, 288), "painted_by": "self"},
	{"id": "cable_duct_east", "kind": "cable", "layer": LAYER_BACKGROUND, "size": "small", "rect": Rect2i(404, 24, 2, 264), "painted_by": "self"},
	{"id": "baseboard_north", "kind": "baseboard", "layer": LAYER_BACKGROUND, "size": "small", "rect": Rect2i(32, 24, 384, 2), "painted_by": "self"},
	{"id": "baseboard_west", "kind": "baseboard", "layer": LAYER_BACKGROUND, "size": "small", "rect": Rect2i(12, 32, 2, 288), "painted_by": "self"},
	{"id": "baseboard_east", "kind": "baseboard", "layer": LAYER_BACKGROUND, "size": "small", "rect": Rect2i(402, 24, 2, 264), "painted_by": "self"},
	{"id": "pipe_vertical", "kind": "pipe", "layer": LAYER_BACKGROUND, "size": "small", "rect": Rect2i(410, 64, 4, 224), "painted_by": "self"},
	{"id": "pipe_horizontal", "kind": "pipe", "layer": LAYER_BACKGROUND, "size": "small", "rect": Rect2i(0, 296, 400, 2), "painted_by": "self"},
	{"id": "hanging_lamp_1", "kind": "lamp", "layer": LAYER_FOREGROUND, "size": "small", "rect": Rect2i(72, 18, 28, 36), "painted_by": "self"},
	{"id": "hanging_lamp_2", "kind": "lamp", "layer": LAYER_FOREGROUND, "size": "small", "rect": Rect2i(210, 18, 28, 36), "painted_by": "self"},
	{"id": "hanging_lamp_3", "kind": "lamp", "layer": LAYER_FOREGROUND, "size": "small", "rect": Rect2i(348, 18, 28, 36), "painted_by": "self"},
	{"id": "door_mat_entrance", "kind": "door_mat", "layer": LAYER_BACKGROUND, "size": "small", "rect": Rect2i(10, 16, 24, 8), "painted_by": "self"},
	{"id": "door_mat_exit", "kind": "door_mat", "layer": LAYER_BACKGROUND, "size": "small", "rect": Rect2i(360, 300, 28, 8), "painted_by": "self"},
	{"id": "wall_hooks_1", "kind": "hooks", "layer": LAYER_BACKGROUND, "size": "small", "rect": Rect2i(2, 140, 8, 2), "painted_by": "self"},
	{"id": "wall_hooks_2", "kind": "hooks", "layer": LAYER_BACKGROUND, "size": "small", "rect": Rect2i(2, 168, 8, 2), "painted_by": "self"},
	{"id": "sprinkler_1", "kind": "sprinkler", "layer": LAYER_BACKGROUND, "size": "small", "rect": Rect2i(80, 2, 4, 4), "painted_by": "self"},
	{"id": "sprinkler_2", "kind": "sprinkler", "layer": LAYER_BACKGROUND, "size": "small", "rect": Rect2i(194, 2, 4, 4), "painted_by": "self"},
	{"id": "sprinkler_3", "kind": "sprinkler", "layer": LAYER_BACKGROUND, "size": "small", "rect": Rect2i(348, 2, 4, 4), "painted_by": "self"},
	{"id": "dumbbell_prop", "kind": "dumbbell", "layer": LAYER_FOREGROUND, "size": "small", "rect": Rect2i(128, 232, 32, 32), "painted_by": "phase5"},
	{"id": "kettlebell_prop", "kind": "kettlebell", "layer": LAYER_FOREGROUND, "size": "small", "rect": Rect2i(96, 252, 12, 10), "painted_by": "self"},
	{"id": "chalk_box", "kind": "chalk_box", "layer": LAYER_FOREGROUND, "size": "small", "rect": Rect2i(118, 262, 32, 32), "painted_by": "phase5"},
	{"id": "plate_prop_1", "kind": "plate", "layer": LAYER_FOREGROUND, "size": "small", "rect": Rect2i(164, 250, 8, 8), "painted_by": "self"},
	{"id": "plate_prop_2", "kind": "plate", "layer": LAYER_FOREGROUND, "size": "small", "rect": Rect2i(176, 252, 8, 8), "painted_by": "self"},
	{"id": "yoga_mat_rolled", "kind": "rolled_mat", "layer": LAYER_FOREGROUND, "size": "small", "rect": Rect2i(348, 268, 32, 32), "painted_by": "phase5"},
	{"id": "water_bottle_1", "kind": "bottle", "layer": LAYER_FOREGROUND, "size": "small", "rect": Rect2i(132, 70, 32, 32), "painted_by": "phase5"},
	{"id": "water_bottle_2", "kind": "bottle", "layer": LAYER_FOREGROUND, "size": "small", "rect": Rect2i(200, 140, 6, 10), "painted_by": "self"},
	{"id": "paper_cup_1", "kind": "cup", "layer": LAYER_FOREGROUND, "size": "small", "rect": Rect2i(180, 180, 5, 6), "painted_by": "self"},
	{"id": "paper_cup_2", "kind": "cup", "layer": LAYER_FOREGROUND, "size": "small", "rect": Rect2i(320, 280, 5, 6), "painted_by": "self"},
	{"id": "towels_1", "kind": "towel", "layer": LAYER_FOREGROUND, "size": "small", "rect": Rect2i(148, 76, 8, 6), "painted_by": "self"},
	{"id": "towels_2", "kind": "towel", "layer": LAYER_FOREGROUND, "size": "small", "rect": Rect2i(260, 140, 8, 6), "painted_by": "self"},
	{"id": "sign_entrance", "kind": "sign", "layer": LAYER_BACKGROUND, "size": "small", "rect": Rect2i(36, 1, 24, 24), "painted_by": "phase5"},
	{"id": "sign_exit", "kind": "sign", "layer": LAYER_BACKGROUND, "size": "small", "rect": Rect2i(370, 316, 16, 4), "painted_by": "self"},
]

## 纹理缓存：layer -> ImageTexture。
var _layer_textures: Dictionary = {}

## V3.1 P1：单个结构纹理缓存（id -> ImageTexture，从所在图层裁剪）。
var _structure_textures: Dictionary = {}

## 烘焙中的当前图层（_col() 据此决定是否降对比降饱和）。
var _current_layer: String = LAYER_BACKGROUND


# === 公共 API ===

## 取指定图层的烘焙贴图（懒加载 + 缓存）。
func layer_texture(layer: String) -> ImageTexture:
	if not _layer_textures.has(layer):
		_layer_textures[layer] = ImageTexture.create_from_image(_bake_layer(layer))
	return _layer_textures[layer]


## 密度统计（V3 §13）：{"large": N, "medium": N, "small": N}，从 STRUCTURES 表
## 按 size 分类计数（全场景口径，含 Phase 5 已绘制条目）—— 测试断言区间
## large 5-10 / medium 15-30 / small 30-60。
func density_counts() -> Dictionary:
	var counts := {"large": 0, "medium": 0, "small": 0}
	for s in STRUCTURES:
		var size := str(s.get("size", ""))
		if counts.has(size):
			counts[size] = int(counts[size]) + 1
	return counts


## 返回指定图层的结构 id 列表（测试验证图层非空 / 结构完整性）。
func structure_ids_in_layer(layer: String) -> Array:
	var ids: Array = []
	for s in STRUCTURES:
		if str(s.get("layer", "")) == layer:
			ids.append(str(s.get("id", "")))
	return ids


## 返回指定结构 id 的矩形（证据脚本取采样锚点；未知 id 返回零矩形）。
func structure_rect(id: String) -> Rect2i:
	for s in STRUCTURES:
		if str(s.get("id", "")) == id:
			return s.get("rect", Rect2i())
	return Rect2i()


## V3.1 P1：返回单个结构的裁剪纹理（只含该结构，透明底；从所在图层烘焙
## 图像裁剪 rect）。供绘制层做体积挤出（前台/立柱/吊灯）。未知 id 返回 null。
func structure_texture(id: String) -> ImageTexture:
	if _structure_textures.has(id):
		return _structure_textures[id]
	var rect := structure_rect(id)
	if rect.size.x <= 0 or rect.size.y <= 0:
		return null
	var layer := ""
	for s in STRUCTURES:
		if str(s.get("id", "")) == id:
			layer = str(s.get("layer", ""))
			break
	if layer == "":
		return null
	var layer_img := layer_texture(layer).get_image()
	var crop := Image.create(rect.size.x, rect.size.y, false, Image.FORMAT_RGBA8)
	crop.blit_rect(layer_img, rect, Vector2i.ZERO)
	var tex := ImageTexture.create_from_image(crop)
	_structure_textures[id] = tex
	return tex


## 返回本层实际绘制（painted_by == "self"）的元素数量 —— 测试验证结构层
## 非空、且与 Phase 5 元素不重复。
func self_painted_count() -> int:
	var n := 0
	for s in STRUCTURES:
		if str(s.get("painted_by", "")) == "self":
			n += 1
	return n


# === V3.1 P3：墙面粉刷纹理（手绘 cluster + jagged 边缘，替代纯色多边形） ===

## 墙面纹理缓存：kind -> ImageTexture。
var _wall_face_textures: Dictionary = {}
## 天花板纹理缓存。
var _ceiling_texture: ImageTexture = null

## 北墙纹理尺寸（墙本地空间：fx∈[32..416] × fy∈[0..24]；fy=0 顶/z=110，
## fy=24 底/z=0 —— 与 _north_wall_transform 一致）。
const WALL_NORTH_TEX := Vector2i(384, 24)
## 侧墙纹理尺寸（墙本地空间：u=沿墙世界 y × v=墙高 z，v=0 底/z=0）。
const WALL_SIDE_TEX := Vector2i(288, 110)
## 天花板纹理尺寸（画布背景 —— 投影边界外扩 8px，见 world_canvas
## _draw_canvas_background()）。bounds() ≈ (-10.8,-86.9,538.8,285.3) +
## 16px 外扩 → ceil 556×334。V3.1 P3：天花板也是大面积区域 —— 需多色
## cluster（非纯色填充，V3.1 负面约束「纯色大面积填充」）。
const CEILING_TEX := Vector2i(556, 334)

## 取天花板纹理（V3.1 P3 手绘感：WALL_BASE.darkened(0.28) 底 + 密集同族
## cluster，非纯色大面积填充）。懒烘焙 + 缓存。
func ceiling_texture() -> ImageTexture:
	if _ceiling_texture != null:
		return _ceiling_texture
	var img := Image.create(CEILING_TEX.x, CEILING_TEX.y, false, Image.FORMAT_RGBA8)
	img.fill(Palette.WALL_BASE.darkened(0.28))
	# 大色块 cluster：~8px 间距，半径 3-6 —— 覆盖率 ~55%，任何扫描线都
	# 不会出现长纯色段（V3.1 负面约束「纯色大面积填充」）。
	var colors := [
		Palette.WALL_BASE.darkened(0.24),
		Palette.WALL_BASE.darkened(0.32),
		Palette.WALL_BASE.darkened(0.20),
		Palette.WALL_BASE.darkened(0.26),
	]
	var seed := 4081
	for gy in range(0, CEILING_TEX.y + 8, 8):
		for gx in range(0, CEILING_TEX.x + 8, 8):
			var h := _hash2(gx * 31 + seed, gy * 17 + seed * 7)
			var cx := gx + (h % 7) - 3
			var cy := gy + ((h >> 4) % 7) - 3
			var c: Color = colors[(h >> 12) % colors.size()]
			# 返工2 R1：天花板也用手绘短笔触（粉刷纹理），非规则圆点。
			_paint_wall_stroke(img, cx, cy, 5 + (h >> 8) % 5, c, h ^ seed)
	var tex := ImageTexture.create_from_image(img)
	_ceiling_texture = tex
	return tex

## 取墙面粉刷纹理（V3.1 P3 手绘感：不规则 cluster + jagged 墙帽/踢脚线，
## 非纯色大面积填充）。kind: "north" | "west" | "east"。懒烘焙 + 缓存。
## WorldCanvas 在墙变换下 draw_texture_rect 一次，替代旧的 3 个纯色多边形
## （面 + 墙帽 + 踢脚线）—— draw call 减少（3→1）。
## 返工3 P1：侧墙装饰（西墙镜/毛巾架、东墙管道/海报/置物架/挂钟）一并
## 烘焙进侧墙纹理 —— 每帧 ~13 个 draw_rect → 0（draw call 预算让给叙事
## 道具）。纹理 u 轴 = 沿墙世界 y（西墙从 y0=32 起，纹理像素 u 对应
## 墙 u = 32 + u；东墙从 y0=0 起）。
func wall_face_texture(kind: String) -> ImageTexture:
	if _wall_face_textures.has(kind):
		return _wall_face_textures[kind]
	var img: Image
	if kind == "north":
		img = _bake_north_wall()
	elif kind == "west" or kind == "east":
		img = _bake_side_wall(kind)
	else:
		return null
	var tex := ImageTexture.create_from_image(img)
	_wall_face_textures[kind] = tex
	return tex


## 北墙：WALL_BASE 面 + 稀疏同族 cluster + jagged 墙帽（WALL_TRIM）/踢脚线
## （WALL_DARK）。行结构（24 行）：fy 0..2 墙帽、3..21 墙面、22..23 踢脚线。
## 返工2 R1：墙面 cluster 改为手绘短笔触（_paint_wall_stroke）—— 不规则
## 短线 + 端点抖动 + 色相微差（WALL 族亮/暗变体），像粉刷/手绘石膏纹理，
## 而非规则噪点圆点。
func _bake_north_wall() -> Image:
	var img := Image.create(WALL_NORTH_TEX.x, WALL_NORTH_TEX.y, false, Image.FORMAT_RGBA8)
	# V3.1 返工2 R3（三层景深）：墙面基底用 WALL_BASE_FAR（暗一档、偏冷）——
	# 背景墙面明度低/偏冷（FAIL3 前中后景分离；P1/P3 采样容差内仍属 WALL 族）。
	img.fill(Palette.WALL_BASE_FAR)
	# 墙面 cluster：深/浅色块（±0.10 内，保持 WALL_BASE_FAR 可读 —— P1 证据
	# 采样容差 0.25 兼容）。密度：~8px 间距 —— 任何 80×10 窗口都有 ≥3 色，
	# 无长纯色段（V3.1「纯色大面积填充」约束）。全部派生自 WALL_BASE_FAR
	# （返工2 R3：不用亮 WALL_TRIM 打碎远景暗墙 —— 背景保持低明度）。
	var colors := [
		Palette.WALL_BASE_FAR.darkened(0.08),
		Palette.WALL_BASE_FAR.lightened(0.06),
		Palette.WALL_BASE_FAR.lightened(0.12),
	]
	for gy in range(3, 22, 8):
		for gx in range(0, WALL_NORTH_TEX.x, 8):
			var h := _hash2(gx * 31 + 4001, gy * 17 + 4001 * 7)
			var cx := gx + (h % 5) - 2
			var cy := gy + ((h >> 4) % 5) - 2
			_paint_wall_stroke(img, cx, cy, 4 + (h >> 8) % 4,
				colors[(h >> 12) % colors.size()], h ^ 4001)
	# 墙面磨损：近踢脚线少量暗点（局部磨损，P3）。
	for i in 10:
		var h := _hash2(4007 + i * 7, i * 13)
		var px := int(h % WALL_NORTH_TEX.x)
		var py := 20 + int((h >> 6) % 3)
		img.set_pixel(px, py, Palette.WALL_BASE.darkened(0.12))
	# 墙帽（fy 0..2）—— R3 手绘抖动：顶缘起伏 + 多色 cluster（无 200px+ 直线）。
	#   顶缘：cap 顶行逐列在 fy=0..2 间变化（hash 驱动，~1/3 列从 fy=1/2 起
	#   —— 顶缘非完美直线）
	#   颜色：WALL_BASE_FAR 亮变体混合（返工2 R3：墙帽与墙面同一暗色族 ——
	#   P1「wall face z=55 ≈ z=100 连续墙面」约束：z=100 采到墙帽，若墙帽仍
	#   用亮 WALL_TRIM 会与暗墙面拉开 >30 色差，破坏墙面连续断言）
	#   底缘：fy=3 处 ~1/3 列延伸 cap 色（保留既有 jagged，颜色跟随 cap 色）
	var cap_colors := [
		Palette.WALL_BASE_FAR.lightened(0.10),
		Palette.WALL_BASE_FAR.lightened(0.14),
		Palette.WALL_BASE_FAR.lightened(0.04),
	]
	# 返工6 P4（N1 顶部条带）：顶缘抖动加强 —— 顶行在 fy=0..4 间变化
	# （原 0..2），且台阶段更长（8px 步进）—— 墙帽顶/天花板交界读作
	# 手绘参差，不是一条笔直水平带（GPT：y≈54-75 深灰带上下边界笔直）。
	var cap_x := 0
	while cap_x < WALL_NORTH_TEX.x:
		var h := _hash2(cap_x, 4021)
		var run := 6 + (h % 9)  # 6..14px 台阶段
		var top := 0
		if h % 3 == 0:
			top = 1
		if h % 5 == 0:
			top = 2
		if h % 7 == 0:
			top = 3
		if h % 11 == 0:
			top = 4
		for x in range(cap_x, mini(cap_x + run, WALL_NORTH_TEX.x)):
			for fy in range(top, 3):
				img.set_pixel(x, fy, cap_colors[(h >> (4 + fy)) % cap_colors.size()])
			if h % 3 == 0:
				img.set_pixel(x, 3, cap_colors[(h >> 8) % cap_colors.size()])
			if top >= 3:
				img.set_pixel(x, 4, cap_colors[(h >> 9) % cap_colors.size()])
		cap_x += run
	# 踢脚线（fy 22..23）—— R3 手绘抖动：底缘起伏 + 多色 cluster。
	#   底缘：踢脚线底行逐列在 fy=22..23 间变化（~1/3 列只到 fy=22 ——
	#   底缘非完美直线，墙地交界断开）
	#   颜色：WALL_DARK 与亮/暗变体混合
	#   顶缘：fy=21 处 ~1/3 列延伸 WALL_DARK（保留既有 jagged）
	var base_colors := [
		Palette.WALL_DARK,
		Palette.WALL_DARK.lightened(0.05),
		Palette.WALL_DARK.darkened(0.08),
	]
	# 返工6 P4（N1）：踢脚线底缘抖动加强（0..1 → 0..2 + 台阶段）——
	# 墙地交界同样不读作一条笔直水平线。
	var base_x := 0
	while base_x < WALL_NORTH_TEX.x:
		var h := _hash2(base_x, 4031)
		var run := 6 + (h % 9)
		var bot := 23
		if h % 3 == 0:
			bot = 22
		if h % 7 == 0:
			bot = 21
		for x in range(base_x, mini(base_x + run, WALL_NORTH_TEX.x)):
			for fy in range(22, bot + 1):
				img.set_pixel(x, fy, base_colors[(h >> (4 + fy)) % base_colors.size()])
			if h % 3 == 0:
				img.set_pixel(x, 21, base_colors[(h >> 8) % base_colors.size()])
		base_x += run
	# 返工3 P1（墙面结构装饰烘焙）：挂钟/空调/通风口/喷淋头从 runtime
	# draw_rect 迁入墙面纹理 —— 一次烘焙替代每帧 ~25 个 draw_rect，
	# draw call 预算让给新增叙事道具（任务 2/3/4 道具组密度）。
	# 纹理坐标 = wall-local x - 32（纹理 Rect2(32,0,WALL_NORTH_TEX.x,24)）。
	# 位置避开 WALL_DECOR 海报（sign 36..52 / timer 52..68 / poster_run
	# 140..156 / ad_red 164..246 / poster_yoga 260..276 / tv 320..336）
	# —— 挂钟/空调/通风口/喷淋落在墙面空闲区，不被海报盖住。
	_bake_north_wall_structure_decor(img)
	return img


## 北墙结构装饰烘焙（返工3 P1）：挂钟/空调/通风口/喷淋头直接写入墙面
## 纹理（纹理坐标 = wall-local x - 32；y 与 wall-local 一致）。替代
## world_canvas._draw_north_wall_structure_decor 的逐帧 draw_rect ——
## 视觉像素一致（同色值），draw call 从 ~25 → 0。
## 空闲墙带（wall-local）：68..140（挂钟 284? 不 —— 276..320 留给
## 挂钟/空调；340..416 留给通风口/喷淋）。布局：
##   挂钟  284..296（空闲带 276..320 东端）
##   空调  276..304（空闲带 276..320 西端，挂钟东侧）
##   通风口 100..112 / 340..352
##   喷淋  124..128 / 360..364 / 380..384
func _bake_north_wall_structure_decor(img: Image) -> void:
	# 挂钟（wall-local 284..296，高挂 fy≈3 → 纹理 252..264）
	for y in 10:
		for x in 12:
			var tx := 252 + x
			var ty := 3 + y
			if tx >= img.get_width() or ty >= img.get_height():
				continue
			if x == 0 or x == 11 or y == 0 or y == 9:
				img.set_pixel(tx, ty, Palette.WALL_DARK)
			else:
				img.set_pixel(tx, ty, Palette.CLOCK_FACE)
	# 指针（偏心 —— 不完全对称）
	for i in 5:
		img.set_pixel(257, 5 + i, Palette.CLOCK_HAND)
	for i in 4:
		img.set_pixel(257 + i, 8, Palette.CLOCK_HAND)
	# 空调（wall-local 276..304 → 纹理 244..272）
	for y in 12:
		for x in 28:
			var tx := 244 + x
			var ty := 2 + y
			if tx >= img.get_width() or ty >= img.get_height():
				continue
			var c := Palette.AC_BODY
			if y >= 2 and y <= 4 and x >= 2 and x <= 25:
				c = Palette.AC_VENT
			img.set_pixel(tx, ty, c)
	for i in 3:
		for x in 24:
			var tx := 246 + x
			var ty := 4 + i * 3
			if tx < img.get_width() and ty < img.get_height():
				img.set_pixel(tx, ty, Palette.AC_VENT)
	img.set_pixel(266, 3, Palette.ACCENT_YELLOW)
	# 通风口（wall-local 100..112 → 纹理 68..80；340..352 → 308..320）
	for vx: int in [68, 308]:
		for y in 8:
			for x in 12:
				var tx: int = vx + x
				var ty := 4 + y
				if tx >= img.get_width() or ty >= img.get_height():
					continue
				img.set_pixel(tx, ty, Palette.AC_VENT.darkened(0.2))
		for i in 5:
			for y in 4:
				var tx: int = vx + 2 + i * 2
				var ty := 6 + y
				if tx < img.get_width() and ty < img.get_height():
					img.set_pixel(tx, ty, Palette.AC_BODY)
	# 喷淋头（wall-local 124/360/380 → 纹理 92/328/348）
	for sx: int in [92, 328, 348]:
		for y in 4:
			for x in 4:
				var tx: int = sx + x
				var ty := 2 + y
				if tx >= img.get_width() or ty >= img.get_height():
					continue
				img.set_pixel(tx, ty, Palette.AC_VENT.darkened(0.3))
		img.set_pixel(sx + 1, 3, Palette.CHARCOAL)


## 侧墙（西/东共用底纹，装饰分侧烘焙）：u=沿墙世界 y（288 宽）v=墙高 z
## （110 行）；行结构：v 0..5 踢脚线、6..103 墙面、104..109 墙帽 —— 与
## _side_wall_transform 一致。返工2 R1：墙面手绘短笔触（同北墙）。
## 返工3 P1：kind 区分西/东，装饰（镜/毛巾架/管道/海报/置物架/挂钟）
## 直接烘焙进对应侧墙纹理 —— 替代 world_canvas 逐帧 draw_rect（每帧
## ~13 个 draw_rect → 0，draw call 预算让给叙事道具）。纹理 u 轴 =
## 沿墙世界 y（西墙 y0=32 → 纹理 u = 墙 y - 32；东墙 y0=0 → u = 墙 y）。
func _bake_side_wall(kind: String) -> Image:
	var img := Image.create(WALL_SIDE_TEX.x, WALL_SIDE_TEX.y, false, Image.FORMAT_RGBA8)
	# V3.1 返工2 R3（三层景深）：侧墙同北墙 —— 背景墙面明度低/偏冷。
	img.fill(Palette.WALL_BASE_FAR)
	var colors := [
		Palette.WALL_BASE_FAR.darkened(0.08),
		Palette.WALL_BASE_FAR.lightened(0.06),
		Palette.WALL_BASE_FAR.lightened(0.12),
	]
	for gy in range(6, 104, 8):
		for gx in range(0, WALL_SIDE_TEX.x, 8):
			var h := _hash2(gx * 31 + 4041, gy * 17 + 4041 * 7)
			var cx := gx + (h % 5) - 2
			var cy := gy + ((h >> 4) % 5) - 2
			_paint_wall_stroke(img, cx, cy, 4 + (h >> 8) % 4,
				colors[(h >> 12) % colors.size()], h ^ 4041)
	for i in 16:
		var h := _hash2(4047 + i * 7, i * 13)
		var px := int(h % WALL_SIDE_TEX.x)
		var py := 96 + int((h >> 6) % 8)
		img.set_pixel(px, py, Palette.WALL_BASE.darkened(0.12))
	# 墙帽（v 104..109）—— R3 手绘抖动：顶缘起伏 + 多色 cluster。
	#   顶缘：cap 顶行逐列在 v=104..106 间变化（非完美直线）
	#   底缘：v=103 处 ~1/3 列延伸 cap 色（jagged）
	#   颜色：WALL_BASE_FAR 亮变体（返工2 R3：墙帽与墙面同族，P1 连续墙面）
	var cap_colors := [
		Palette.WALL_BASE_FAR.lightened(0.10),
		Palette.WALL_BASE_FAR.lightened(0.14),
		Palette.WALL_BASE_FAR.lightened(0.04),
	]
	for u in WALL_SIDE_TEX.x:
		var h := _hash2(u, 4051)
		var top := 104
		if h % 3 == 0:
			top = 105
		if h % 5 == 0:
			top = 106
		for v in range(top, 110):
			img.set_pixel(u, v, cap_colors[(h >> (4 + v)) % cap_colors.size()])
		if h % 3 == 0:
			img.set_pixel(u, 103, cap_colors[(h >> 8) % cap_colors.size()])
	# 踢脚线（v 0..5）—— R3 手绘抖动：底缘起伏 + 多色 cluster。
	#   底缘：踢脚线底行逐列在 v=0..1 间变化（非完美直线）
	#   顶缘：v=6 处 ~1/3 列延伸 WALL_DARK（jagged）
	var base_colors := [
		Palette.WALL_DARK,
		Palette.WALL_DARK.lightened(0.05),
		Palette.WALL_DARK.darkened(0.08),
	]
	for u in WALL_SIDE_TEX.x:
		var h := _hash2(u, 4061)
		var bot := 0
		if h % 3 == 0:
			bot = 1
		for v in range(bot, 6):
			img.set_pixel(u, v, base_colors[(h >> (4 + v)) % base_colors.size()])
		if h % 3 == 0:
			img.set_pixel(u, 6, base_colors[(h >> 8) % base_colors.size()])
	# 返工3 P1：装饰烘焙（分侧）。纹理 u = 墙 y - y0（西 y0=32 / 东 y0=0）。
	var offset := 0
	if kind == "west":
		offset = 32
		_bake_west_wall_decor(img, offset)
	else:
		_bake_east_wall_decor(img, offset)
	return img


## 西墙装饰烘焙（返工3 P1）：长镜 + 毛巾架（与旧 runtime 同坐标，纹理
## u = 墙 y - 32）。
func _bake_west_wall_decor(img: Image, offset: int) -> void:
	# 长镜（冷蓝灰，V3 §6 冷调）：墙 y 40..160，高 v 18..92
	var u0 := 40 - offset
	_fill_irregular(img, Rect2i(u0, 18, 120, 74), Palette.MIRROR_COLOR, 471)
	for i in 8:
		var u := u0 + i * 2
		var v := 20 + i * 2
		if u < img.get_width() and v < img.get_height():
			img.set_pixel(u, v, Palette.MIRROR_HI)
	# 毛巾架 + 暖橙毛巾：横杆（墙 y 180..210，v 40）+ 两条垂巾
	var rod_u := 180 - offset
	img.set_pixel(rod_u, 40, Palette.METAL_HIGHLIGHT)
	img.set_pixel(rod_u + 1, 40, Palette.METAL_HIGHLIGHT)
	img.set_pixel(rod_u + 2, 40, Palette.METAL_HIGHLIGHT)
	_fill_irregular(img, Rect2i(rod_u + 4, 42, 6, 12), Palette.TOWEL, 481)
	_fill_irregular(img, Rect2i(rod_u + 16, 42, 6, 12), Palette.TOWEL.darkened(0.15), 483)


## 东墙装饰烘焙（返工3 P1）：管道 + 海报 + 置物架 + 挂钟 + 毛巾架 +
## 第二海报（与旧 runtime + 返工3 新增同坐标，纹理 u = 墙 y）。
func _bake_east_wall_decor(img: Image, offset: int) -> void:
	# 竖向管道（中暖灰 + 法兰）：墙 y 60..63，v 20..320（贴图内 20..109）
	var u0 := 60 - offset
	for v in range(20, 110):
		if u0 >= img.get_width() or v >= img.get_height():
			continue
		img.set_pixel(u0, v, Palette.PIPE_COLOR)
		img.set_pixel(u0 + 1, v, Palette.PIPE_COLOR)
		img.set_pixel(u0 + 2, v, Palette.PIPE_COLOR)
	# 法兰（墙 y 60..64，v 90..93 / 200..203）
	for v in range(90, 94):
		for u in range(u0 - 1, u0 + 4):
			if u >= 0 and u < img.get_width() and v < img.get_height():
				img.set_pixel(u, v, Palette.PIPE_DARK)
	# 海报（暖色 accent 小面积）：墙 y 180..194，v 30..48
	var pu := 180 - offset
	_fill_irregular(img, Rect2i(pu, 30, 14, 18), Palette.WALL_DARK, 491)
	_fill_irregular(img, Rect2i(pu + 2, 32, 10, 14), Palette.ACCENT_ORANGE, 493)
	_fill_irregular(img, Rect2i(pu + 2, 41, 10, 5), Palette.ACCENT_ORANGE.darkened(0.35), 495)
	# 置物架（墙 y 120..146，v 60..74）：层板 + 小件
	var su := 120 - offset
	_fill_irregular(img, Rect2i(su, 60, 26, 2), Palette.SHELF_WOOD, 501)
	_fill_irregular(img, Rect2i(su + 2, 62, 4, 12), Palette.ACCENT_CYAN.darkened(0.15), 503)
	_fill_irregular(img, Rect2i(su + 10, 62, 4, 12), Palette.ACCENT_YELLOW.darkened(0.1), 505)
	_fill_irregular(img, Rect2i(su + 18, 62, 4, 12), Palette.ACCENT_ORANGE.darkened(0.2), 507)
	# 挂钟（墙 y 124..138，v 88..104）
	var cu := 124 - offset
	_fill_irregular(img, Rect2i(cu, 88, 14, 16), Palette.CLOCK_FACE, 511)
	img.set_pixel(cu + 6, 90, Palette.CLOCK_HAND)
	img.set_pixel(cu + 6, 91, Palette.CLOCK_HAND)
	img.set_pixel(cu + 6, 92, Palette.CLOCK_HAND)
	img.set_pixel(cu + 6, 93, Palette.CLOCK_HAND)
	img.set_pixel(cu + 6, 94, Palette.CLOCK_HAND)
	img.set_pixel(cu + 6, 96, Palette.CLOCK_HAND)
	img.set_pixel(cu + 7, 96, Palette.CLOCK_HAND)
	img.set_pixel(cu + 8, 96, Palette.CLOCK_HAND)
	img.set_pixel(cu + 9, 96, Palette.CLOCK_HAND)
	img.set_pixel(cu + 10, 96, Palette.CLOCK_HAND)
	# 毛巾架 + 毛巾（墙 y 170..196，v 100..102 横杆 + 垂巾）
	var ru := 170 - offset
	img.set_pixel(ru, 100, Palette.METAL_HIGHLIGHT)
	img.set_pixel(ru + 1, 100, Palette.METAL_HIGHLIGHT)
	_fill_irregular(img, Rect2i(ru + 6, 102, 6, 12), Palette.TOWEL, 521)
	_fill_irregular(img, Rect2i(ru + 16, 102, 6, 12), Palette.TOWEL.darkened(0.15), 523)
	# 第二海报（墙 y 220..234，v 30..48 —— 暖黄 accent）
	var qu := 220 - offset
	_fill_irregular(img, Rect2i(qu, 30, 14, 18), Palette.WALL_DARK, 531)
	_fill_irregular(img, Rect2i(qu + 2, 32, 10, 14), Palette.ACCENT_YELLOW.darkened(0.05), 533)
	_fill_irregular(img, Rect2i(qu + 2, 41, 10, 5), Palette.ACCENT_YELLOW.darkened(0.4), 535)


# === 烘焙 ===

func _bake_layer(layer: String) -> Image:
	var img := Image.create(WORLD_W, WORLD_H, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	_current_layer = layer
	for s in STRUCTURES:
		if str(s.get("layer", "")) != layer:
			continue
		if str(s.get("painted_by", "")) != "self":
			continue
		_paint_structure(img, s)
	return img


func _paint_structure(img: Image, s: Dictionary) -> void:
	var kind := str(s.get("kind", ""))
	var rect: Rect2i = s.get("rect", Rect2i())
	match kind:
		"wall":
			_paint_wall(img, rect)
		"window":
			_paint_window(img, rect)
		"door":
			_paint_door(img, rect)
		"door_mat":
			_paint_door_mat(img, rect)
		"poster":
			_paint_poster(img, rect)
		"wall_clock":
			_paint_clock(img, rect)
		"ac":
			_paint_ac(img, rect)
		"vent":
			_paint_vent(img, rect)
		"speaker":
			_paint_speaker(img, rect)
		"mirror":
			_paint_mirror(img, rect)
		"lockers":
			_paint_lockers(img, rect)
		"desk":
			_paint_desk(img, rect)
		"fountain":
			_paint_fountain(img, rect)
		"trash":
			_paint_trash(img, rect)
		"towel_rack":
			_paint_towel_rack(img, rect)
		"hydrant":
			_paint_hydrant(img, rect)
		"shelf":
			_paint_shelf(img, rect)
		"column":
			_paint_column(img, rect)
		"plant":
			_paint_plant(img, rect)
		"lamp":
			_paint_lamp(img, rect)
		"cable":
			_paint_cable(img, rect)
		"pipe":
			_paint_pipe(img, rect)
		"baseboard":
			_paint_baseboard(img, rect)
		"dumbbell":
			_paint_dumbbell(img, rect)
		"kettlebell":
			_paint_kettlebell(img, rect)
		"chalk_box":
			_paint_chalk_box(img, rect)
		"rolled_mat":
			_paint_rolled_mat(img, rect)
		"bottle":
			_paint_bottle(img, rect)
		"cup":
			_paint_cup(img, rect)
		"hooks":
			_paint_hooks(img, rect)
		"sprinkler":
			_paint_sprinkler(img, rect)
		"plate":
			_paint_plate(img, rect)
		"towel":
			_paint_towel(img, rect)
		"sign":
			_paint_sign(img, rect)
		"tv":
			_paint_tv(img, rect)
		_:
			push_warning("StructureArt: unknown kind '%s'" % kind)


# === 颜色助手：BACKGROUND 层统一降对比降饱和（V3 §4） ===

## 图层色取用：BACKGROUND 层把颜色压向中性灰并略降亮度（降饱和降对比），
## GAMEPLAY / FOREGROUND 层原色（更清楚、更鲜艳）。
func _col(c: Color) -> Color:
	if _current_layer == LAYER_BACKGROUND:
		var lum := c.get_luminance()
		var neutral := Color(lum, lum, lum)
		return c.lerp(neutral, 0.45).darkened(0.10)
	return c


# === V3.1 P3 手绘原语（全部确定性，无 RNG 状态） ===

## 不规则矩形填充（P3 无完美矩形）：逐行左右边界抖动 ±2，少量磨损缺口。
func _fill_irregular(img: Image, r: Rect2i, c: Color, seed: int) -> void:
	for y in range(r.position.y, r.position.y + r.size.y):
		if y < 0 or y >= img.get_height():
			continue
		var lj := (_hash2(seed + y, y * 3 + seed) % 5) - 2
		var rj := (_hash2(seed * 7 + y, y * 11 + seed) % 5) - 2
		for x in range(r.position.x + lj, r.position.x + r.size.x + rj):
			if x < 0 or x >= img.get_width():
				continue
			img.set_pixel(x, y, c)


## 表面小色块（P3 手工色块 / 局部磨损）：在矩形内撒 count 个同族色 blob。
## [colors] 叠色表（与原底色同族 —— 打破纯色填充，不改变材质身份）。
func _add_clusters(img: Image, r: Rect2i, colors: Array, count: int, seed: int) -> void:
	for i in count:
		var h := _hash2(seed + i * 13, i * 7 + seed * 3)
		var cx := r.position.x + int(h % maxi(r.size.x, 1))
		var cy := r.position.y + int((h >> 5) % maxi(r.size.y, 1))
		var c: Color = colors[(h >> 10) % colors.size()]
		_paint_blob(img, cx, cy, 1 + (h >> 13) % 2, c, h ^ seed)


## 不规则 blob（P3 手工小色块）：8 角度桶半径抖动 → 边缘不规则、非完美圆。
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


## 手绘短笔触（返工2 R1）：墙面/天花板用 —— 短线段 + 端点抖动 + 笔触宽
## 2px。方向 8 桶 hash 抖动（多为斜/竖 —— 粉刷/石膏笔触）。确定性：
## 同输入永远同形状。与 floor_art._paint_stroke 独立实现（各自本地空间
## 与调用约定，避免跨脚本依赖）。
func _paint_wall_stroke(img: Image, x: int, y: int, length: int, color: Color,
		seed: int) -> void:
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
	# 笔触宽 2px：垂直方向微移（刷毛宽度）
	var steps := maxi(1, length)
	for i in steps + 1:
		var t := float(i) / float(steps)
		var px := int(round(lerpf(x0, x1, t)))
		var py := int(round(lerpf(y0, y1, t)))
		px += (_hash2(seed + i * 7, x + y) % 3) - 1
		py += (_hash2(seed + i * 13, y - x) % 3) - 1
		for w in 2:
			var ox := (_hash2(seed + i * 17 + w, px + py) % 3) - 1
			var oy := (_hash2(seed + i * 19 + w, py - px) % 3) - 1
			var wx := px + ox
			var wy := py + oy
			if wx >= 0 and wy >= 0 and wx < img.get_width() and wy < img.get_height():
				img.set_pixel(wx, wy, color)


## 断裂 jagged 水平缝（P3 无完美直线）：分段 + 垂直偏移 + 随机跳过。
func _jagged_hline(img: Image, x0: int, x1: int, y: int, color: Color, seed: int) -> void:
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
					if x + i < img.get_width():
						img.set_pixel(x + i, py, color)
		x += seg


## 断裂 jagged 垂直缝。
func _jagged_vline(img: Image, x: int, y0: int, y1: int, color: Color, seed: int) -> void:
	var y := y0
	while y < y1:
		if y < 0 or y >= img.get_height():
			break
		var seg := 3 + (_hash2(seed + y, x * 5) % 5)
		var off := (_hash2(x * 7 + seed, y * 3) % 5) - 2
		var px := x + off
		if px >= 0 and px < img.get_width():
			if _hash2(x, y + seed * 9) % 3 != 0:
				var seg_n := mini(seg, y1 - y)
				for i in seg_n:
					if y + i < img.get_height():
						img.set_pixel(px, y + i, color)
		y += seg


# === 结构绘制（每个结构 = 一个小像素画；颜色全部来自 palette.gd） ===

## 墙体：主色填充（不规则边缘）+ 竖向面板分隔线（间距抖动）+ 顶部受光亮线。
func _paint_wall(img: Image, r: Rect2i) -> void:
	_fill_irregular(img, r, _col(Palette.WALL_BASE), 11)
	var x := r.position.x + 24 + (_hash2(r.position.x, r.position.y) % 13)
	while x < r.position.x + r.size.x:
		_jagged_vline(img, x, r.position.y, r.position.y + r.size.y, _col(Palette.WALL_DARK), x * 3)
		x += 28 + (_hash2(x, r.position.y) % 12)
	_jagged_hline(img, r.position.x, r.position.x + r.size.x, r.position.y, _col(Palette.WALL_TRIM), 5)
	_jagged_hline(img, r.position.x, r.position.x + r.size.x, r.position.y + r.size.y - 1, _col(Palette.WALL_DARK), 7)


## 窗户：窗框（不规则边缘）+ 冷蓝玻璃 + 斜向高光（保留，Phase 5 实际绘制）。
func _paint_window(img: Image, r: Rect2i) -> void:
	_fill_irregular(img, r, _col(Palette.WINDOW_FRAME), 21)
	var glass := r.grow(-2)
	_fill_irregular(img, glass, _col(Palette.WINDOW_GLASS), 22)
	_jagged_vline(img, glass.position.x + glass.size.x / 2 - 1, glass.position.y, glass.position.y + glass.size.y, _col(Palette.WINDOW_FRAME), 31)
	_jagged_hline(img, glass.position.x, glass.position.x + glass.size.x, glass.position.y + glass.size.y / 2 - 1, _col(Palette.WINDOW_FRAME), 32)
	for i in mini(glass.size.x, glass.size.y):
		var px := glass.position.x + i
		var py := glass.position.y + i
		if px < glass.position.x + glass.size.x and py < glass.position.y + glass.size.y:
			img.set_pixel(px, py, _col(Palette.METAL_HIGHLIGHT))


## 门：门框（不规则）+ 深木门板 + 门缝高光（竖缝偏移 —— 不完全对称）。
func _paint_door(img: Image, r: Rect2i) -> void:
	_fill_irregular(img, r, _col(Palette.DOOR_FRAME), 41)
	var panel := r.grow(-2)
	_fill_irregular(img, panel, _col(Palette.DOOR_COLOR), 42)
	var split := panel.position.x + panel.size.x / 2 + (_hash2(r.position.x, r.position.y) % 3) - 1
	_jagged_vline(img, split, panel.position.y, panel.position.y + panel.size.y, _col(Palette.DOOR_FRAME), 43)
	img.set_pixel(panel.position.x + panel.size.x - 3, panel.position.y + panel.size.y / 2, _col(Palette.METAL_HIGHLIGHT))


## 门口地垫：深暖灰 + jagged 边缘（无等宽上下压条）。
func _paint_door_mat(img: Image, r: Rect2i) -> void:
	_fill_irregular(img, r, _col(Palette.DOOR_MAT), 51)
	_jagged_hline(img, r.position.x, r.position.x + r.size.x, r.position.y, _col(Palette.DOOR_MAT.lightened(0.12)), 52)
	_jagged_hline(img, r.position.x, r.position.x + r.size.x, r.position.y + r.size.y - 1, _col(Palette.DOOR_MAT.darkened(0.12)), 53)


## 海报：不规则边框（非等宽）+ 暖色 accent 主色 + 底部暗区。
func _paint_poster(img: Image, r: Rect2i) -> void:
	_fill_irregular(img, r, _col(Palette.WALL_DARK), 61)
	var accents := [Palette.ACCENT_YELLOW, Palette.ACCENT_ORANGE, Palette.ACCENT_CYAN]
	var accent: Color = accents[r.position.x % accents.size()]
	_fill_irregular(img, Rect2i(r.position.x + 1, r.position.y + 1, r.size.x - 2, r.size.y - 2), _col(accent), 62)
	var base_h := maxi(1, r.size.y / 3)
	var base_y := r.position.y + r.size.y - base_h
	_fill_irregular(img, Rect2i(r.position.x + 1, base_y, r.size.x - 2, base_h), _col(accent.darkened(0.35)), 63)


## 墙钟：表盘（不规则）+ 指针（偏心 —— 不完全对称）。
func _paint_clock(img: Image, r: Rect2i) -> void:
	_fill_irregular(img, r, _col(Palette.CLOCK_FACE), 71)
	var cx := r.position.x + r.size.x / 2 + (_hash2(r.position.x, r.position.y) % 3) - 1
	var cy := r.position.y + r.size.y / 2 + (_hash2(r.position.y, r.position.x) % 3) - 1
	for d in [Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1)]:
		img.set_pixel(cx + int(d.x), cy + int(d.y), _col(Palette.CLOCK_HAND))
	_jagged_vline(img, cx, r.position.y + 1, cy, _col(Palette.CLOCK_HAND), 72)
	_jagged_hline(img, cx, cx + r.size.x / 2, cy, _col(Palette.CLOCK_HAND), 73)


## 空调：暖白机身（不规则）+ 出风栅（间距抖动）+ 显示灯。
func _paint_ac(img: Image, r: Rect2i) -> void:
	_fill_irregular(img, r, _col(Palette.AC_BODY), 81)
	var y := r.position.y + 3
	while y < r.position.y + r.size.y - 2:
		_jagged_hline(img, r.position.x + 1, r.position.x + r.size.x - 1, y, _col(Palette.AC_VENT), y * 5)
		y += 2 + (_hash2(r.position.x, y) % 3)
	img.set_pixel(r.position.x + r.size.x - 3, r.position.y + 2, _col(Palette.ACCENT_YELLOW))


## 通风口：边框（不规则）+ 栅条（间距抖动）。
func _paint_vent(img: Image, r: Rect2i) -> void:
	_fill_irregular(img, r, _col(Palette.AC_VENT.darkened(0.2)), 91)
	_jagged_hline(img, r.position.x, r.position.x + r.size.x, r.position.y, _col(Palette.WALL_DARK), 92)
	var x := r.position.x + 1
	while x < r.position.x + r.size.x:
		_jagged_vline(img, x, r.position.y + 1, r.position.y + r.size.y - 1, _col(Palette.AC_BODY), x * 7)
		x += 1 + (_hash2(x, r.position.y) % 3)


## 音箱：近黑箱体（不规则）+ 网孔点（不规则散布，非规则网格）。
func _paint_speaker(img: Image, r: Rect2i) -> void:
	_fill_irregular(img, r, _col(Palette.CHARCOAL), 101)
	for i in 8:
		var h := _hash2(r.position.x * 7 + i * 5, r.position.y * 11 + i * 3)
		var px := r.position.x + 1 + int(h % maxi(r.size.x - 2, 1))
		var py := r.position.y + 1 + int((h >> 5) % maxi(r.size.y - 2, 1))
		img.set_pixel(px, py, _col(Palette.CHARCOAL.lightened(0.25)))


## 镜子：冷蓝灰镜面（不规则边缘）+ 斜向高光 + 边框（jagged）。
func _paint_mirror(img: Image, r: Rect2i) -> void:
	_fill_irregular(img, r, _col(Palette.WALL_DARK), 111)
	var glass := r.grow(-2)
	_fill_irregular(img, glass, _col(Palette.MIRROR_COLOR), 112)
	for i in mini(glass.size.x, glass.size.y):
		var px := glass.position.x + i
		var py := glass.position.y + i
		if px < glass.position.x + glass.size.x and py < glass.position.y + glass.size.y:
			img.set_pixel(px, py, _col(Palette.MIRROR_HI))
	_add_clusters(img, glass, [_col(Palette.MIRROR_HI), _col(Palette.MIRROR_COLOR.darkened(0.12))], 6, 113)


## 储物柜：蓝灰柜体（不规则）+ 竖柜门缝（间距抖动）+ 暖金把手（错位）。
func _paint_lockers(img: Image, r: Rect2i) -> void:
	_fill_irregular(img, r, _col(Palette.LOCKER_COLOR), 121)
	var x := r.position.x + 1
	var i := 0
	while x < r.position.x + r.size.x - 2:
		_jagged_vline(img, x, r.position.y, r.position.y + r.size.y, _col(Palette.LOCKER_DARK), x * 3 + i)
		var handle_x := x + 2 + (_hash2(x, i) % 2)
		if handle_x < r.position.x + r.size.x - 1:
			var hy := r.position.y + r.size.y / 2 + ((_hash2(x, i * 7) % 5) - 2)
			_fill_irregular(img, Rect2i(handle_x, hy, 2, 2), _col(Palette.LOCKER_HANDLE), 122 + i)
		x += 6 + (_hash2(x, i * 5) % 4)
		i += 1
	_jagged_hline(img, r.position.x, r.position.x + r.size.x, r.position.y, _col(Palette.LOCKER_COLOR.lightened(0.15)), 123)


## 前台：台面（不规则）+ 台沿 + 收银机（GAMEPLAY 层 —— 原色、轮廓明确）。
func _paint_desk(img: Image, r: Rect2i) -> void:
	_fill_irregular(img, r, _col(Palette.DESK_WOOD), 131)
	_jagged_hline(img, r.position.x, r.position.x + r.size.x, r.position.y, _col(Palette.DESK_TOP), 132)
	_jagged_hline(img, r.position.x, r.position.x + r.size.x, r.position.y + r.size.y - 1, _col(Palette.DESK_WOOD.darkened(0.25)), 133)
	_fill_irregular(img, Rect2i(r.position.x + 4, r.position.y + r.size.y - 6, r.size.x - 8, 4), _col(Palette.DESK_WOOD.darkened(0.18)), 134)
	# 木纹小色块（P3 手工细节）
	_add_clusters(img, r, [_col(Palette.DESK_TOP), _col(Palette.DESK_WOOD.darkened(0.10))], 8, 135)
	# 收银机：机身 + Butter 屏（jagged 边缘）
	_fill_irregular(img, Rect2i(r.position.x + r.size.x / 2 - 5, r.position.y + 3, 10, 8), _col(Palette.METAL_DARK), 136)
	_fill_irregular(img, Rect2i(r.position.x + r.size.x / 2 - 3, r.position.y + 4, 6, 4), _col(Palette.ACCENT_YELLOW), 137)


## 饮水机：暖白机身（不规则）+ 出水口 + 水桶。
func _paint_fountain(img: Image, r: Rect2i) -> void:
	_fill_irregular(img, r, _col(Palette.FOUNTAIN), 141)
	_fill_irregular(img, Rect2i(r.position.x + 1, r.position.y + r.size.y / 2, r.size.x - 2, r.size.y / 2 - 1), _col(Palette.FOUNTAIN.darkened(0.12)), 142)
	_fill_irregular(img, Rect2i(r.position.x + 2, r.position.y + 2, 3, 4), _col(Palette.METAL_HIGHLIGHT), 143)
	img.set_pixel(r.position.x + r.size.x / 2, r.position.y + r.size.y / 2 + 2, _col(Palette.ACCENT_CYAN))


## 垃圾桶：深暖灰（不规则）+ 桶沿。
func _paint_trash(img: Image, r: Rect2i) -> void:
	_fill_irregular(img, r, _col(Palette.TRASH), 151)
	_jagged_hline(img, r.position.x, r.position.x + r.size.x, r.position.y, _col(Palette.TRASH.lightened(0.12)), 152)
	_jagged_hline(img, r.position.x + 1, r.position.x + r.size.x - 1, r.position.y + 2, _col(Palette.TRASH.darkened(0.2)), 153)


## 毛巾架：横杆 + 两条暖橙毛巾（错位）。
func _paint_towel_rack(img: Image, r: Rect2i) -> void:
	_jagged_hline(img, r.position.x, r.position.x + r.size.x, r.position.y, _col(Palette.METAL_HIGHLIGHT), 161)
	_fill_irregular(img, Rect2i(r.position.x + 1, r.position.y + 1, 3, r.size.y - 1), _col(Palette.TOWEL), 162)
	_fill_irregular(img, Rect2i(r.position.x + r.size.x - 4, r.position.y + 1, 3, r.size.y - 1), _col(Palette.TOWEL.darkened(0.15)), 163)


## 消防栓：低饱和红箱（不规则）+ 白色顶盖。
func _paint_hydrant(img: Image, r: Rect2i) -> void:
	_fill_irregular(img, r, _col(Palette.HYDRANT), 171)
	_jagged_hline(img, r.position.x, r.position.x + r.size.x, r.position.y, _col(Palette.HYDRANT.lightened(0.2)), 172)
	_jagged_hline(img, r.position.x + 1, r.position.x + r.size.x - 1, r.position.y + r.size.y - 3, _col(Palette.HYDRANT.darkened(0.25)), 173)


## 储物架：隔板 + 小物件。
func _paint_shelf(img: Image, r: Rect2i) -> void:
	_jagged_hline(img, r.position.x, r.position.x + r.size.x, r.position.y, _col(Palette.WALL_TRIM), 181)
	_fill_irregular(img, Rect2i(r.position.x + 1, r.position.y + 1, 2, 4), _col(Palette.ACCENT_CYAN), 182)
	_fill_irregular(img, Rect2i(r.position.x + 5, r.position.y + 1, 2, 3), _col(Palette.ACCENT_YELLOW), 183)


## 立柱：暖灰柱体（不规则边缘）+ 侧影 + 顶部受光（FOREGROUND，允许遮挡角色）。
func _paint_column(img: Image, r: Rect2i) -> void:
	_fill_irregular(img, r, _col(Palette.COLUMN_COLOR), 191)
	_jagged_vline(img, r.position.x, r.position.y, r.position.y + r.size.y, _col(Palette.COLUMN_COLOR.lightened(0.18)), 192)
	_jagged_vline(img, r.position.x + r.size.x - 1, r.position.y, r.position.y + r.size.y, _col(Palette.COLUMN_DARK), 193)
	_add_clusters(img, r, [_col(Palette.COLUMN_COLOR.lightened(0.12)), _col(Palette.COLUMN_DARK)], 6, 194)


## 植物：陶盆 + 多层绿叶（中等饱和绿，V3 §7 允许；叶层边缘 jagged）。
func _paint_plant(img: Image, r: Rect2i) -> void:
	var pot_h := maxi(4, r.size.y / 3)
	_fill_irregular(img, Rect2i(r.position.x + 2, r.position.y + r.size.y - pot_h, r.size.x - 4, pot_h), _col(Palette.PLANT_POT), 201)
	var leaf_top := r.position.y + maxi(0, r.size.y - pot_h - 4)
	for i in 3:
		var lw := r.size.x - 4 - i * 3
		var lx := r.position.x + 2 + i
		var ly := leaf_top + i * 2
		_fill_irregular(img, Rect2i(lx, ly, lw, 4), _col(Palette.PLANT_GREEN if i % 2 == 0 else Palette.PLANT_GREEN_DARK), 202 + i)
	_fill_irregular(img, Rect2i(r.position.x + r.size.x / 2 - 2, leaf_top - 2, 4, 2), _col(Palette.PLANT_GREEN_LIGHT), 205)


## 吊灯（V3.1 R4 光源可辨识）：固定座 + 有体积的吊线 + 顶盖 + 发光灯罩 + 灯泡核心。
## 整个轮廓都画在结构 rect 内，避免旧实现把 rect 上方吊线裁掉后只剩「黄块」。
## 28×36 世界像素经低分辨率 nearest 管线仍保留明确的悬吊/罩体/开口语义。
func _paint_lamp(img: Image, r: Rect2i) -> void:
	var cx := r.position.x + r.size.x / 2
	# 天花固定座 + 3px 吊线。深色双边保证线在暖灰墙/光束上都有对比，左侧
	# 1px 暖灰高光让它读作细金属杆，而不是贴墙的单像素划痕。
	_fill_irregular(img, Rect2i(cx - 4, r.position.y, 9, 2),
		_col(Palette.CHARCOAL.darkened(0.22)), 210)
	for y in range(r.position.y + 2, r.position.y + 10):
		img.set_pixel(cx - 1, y, _col(Palette.CHARCOAL.lightened(0.18)))
		img.set_pixel(cx, y, _col(Palette.CHARCOAL.darkened(0.08)))
		img.set_pixel(cx + 1, y, _col(Palette.CHARCOAL.darkened(0.28)))
	_fill_irregular(img, Rect2i(cx - 4, r.position.y + 10, 9, 3),
		_col(Palette.LAMP_SHADE), 212)
	# 灯罩受光体：顶窄底宽的手绘梯形，暗边包住暖橙金内胆。
	var top_y := r.position.y + 13
	var bottom_y := r.position.y + 27
	var half_top := 4
	var half_bottom := 11
	# 灯罩边缘先铺一圈稀疏暖光，随后由不透明罩体覆盖内侧。40% alpha 在
	# nearest 放大后仍能看见，但不形成圆形 Photoshop halo。
	var edge_glow := Palette.LAMP_GLOW
	edge_glow.a = 0.40
	for y in range(top_y - 1, bottom_y + 2):
		var t := clampf(float(y - top_y) / float(maxi(1, bottom_y - top_y)), 0.0, 1.0)
		var half_w := int(lerpf(float(half_top), float(half_bottom), t)) + 2
		if (y - top_y) % 2 == 0:
			for x in [cx - half_w, cx + half_w]:
				if x >= 0 and y >= 0 and x < img.get_width() and y < img.get_height():
					img.set_pixel(x, y, edge_glow)
	for y in range(top_y, bottom_y):
		var t := float(y - top_y) / float(maxi(1, bottom_y - top_y))
		var half_w := int(lerpf(float(half_top), float(half_bottom), t))
		var x0 := cx - half_w
		var x1 := cx + half_w
		for x in range(x0, x1 + 1):
			var jitter := (_hash2(x, y) % 3) - 1
			if y == bottom_y - 1 and jitter < 0:
				continue
			if y == top_y and jitter > 0:
				continue
			var edge := mini(absf(x - cx), half_w)
			var c := Palette.LAMP_SHADE_LIT
			if edge >= half_w - 1 or y == top_y:
				c = Palette.LAMP_SHADE
			if x >= 0 and y >= 0 and x < img.get_width() and y < img.get_height():
				img.set_pixel(x, y, _col(c))
	# 灯罩开口 + 4×3 灯泡核心：白暖核心被深色开口托住，光源一眼可读。
	_fill_irregular(img, Rect2i(cx - 10, bottom_y, 20, 2),
		_col(Palette.LAMP_SHADE), 213)
	_fill_irregular(img, Rect2i(cx - 5, bottom_y, 10, 2),
		_col(Palette.LAMP_SHADE_LIT), 214)
	_fill_irregular(img, Rect2i(cx - 2, bottom_y + 2, 4, 3),
		_col(Palette.LAMP_BULB), 215)
	# 向下出光的断续像素行；真正的方向光束由 LightingLayer 投影图连接落点。
	var glow := Palette.LAMP_GLOW
	for i in 2:
		glow.a = 0.40 - i * 0.16
		_fill_irregular(img, Rect2i(cx - 3 + i, bottom_y + 5 + i * 2,
			6 - i * 2, 1), glow, 216 + i)


## 电线槽：浅暖灰细条（jagged）。
## 返工6 P4（N1）：电线槽从「整条 384px 长条」改为「分段错落短条」——
## 每 24-56px 一段、段间 8-24px 缺口、每段垂直偏移 ±1（手走线），
## 不再读作一条贯穿的室内横梁/分区线（GPT：y≈171-181 水平分隔线）。
func _paint_cable(img: Image, r: Rect2i) -> void:
	var x := r.position.x
	var seg := 0
	while x < r.position.x + r.size.x:
		var h := _hash2(r.position.x + seg * 31, r.position.y + seg * 17)
		var seg_w := 24 + (h % 33)          # 24..56px 段宽
		var gap := 8 + ((h >> 4) % 17)      # 8..24px 缺口
		var off := ((h >> 9) % 3) - 1       # ±1px 垂直偏移
		var x0 := x
		var x1 := mini(x + seg_w, r.position.x + r.size.x)
		if x1 > x0:
			_fill_irregular(img, Rect2i(x0, r.position.y + off, x1 - x0, r.size.y),
				_col(Palette.CABLE_DUCT), 221 + seg)
			_jagged_hline(img, x0, x1, r.position.y + r.size.y - 1 + off,
				_col(Palette.CABLE_DUCT.darkened(0.15)), 222 + seg)
		x += seg_w + gap
		seg += 1


## 管道：中暖灰 + 法兰接头（间距抖动）。
func _paint_pipe(img: Image, r: Rect2i) -> void:
	_fill_irregular(img, r, _col(Palette.PIPE_COLOR), 231)
	if r.size.y > r.size.x:
		var y := r.position.y + 24
		while y < r.position.y + r.size.y:
			_fill_irregular(img, Rect2i(r.position.x - 1, y, r.size.x + 2, 2), _col(Palette.PIPE_DARK), y)
			y += 56 + (_hash2(r.position.x, y) % 24)
	else:
		var x := r.position.x + 24
		while x < r.position.x + r.size.x:
			_fill_irregular(img, Rect2i(x, r.position.y - 1, 2, r.size.y + 2), _col(Palette.PIPE_DARK), x)
			x += 56 + (_hash2(x, r.position.y) % 24)


## 踢脚线：深暖灰细条（jagged）。
func _paint_baseboard(img: Image, r: Rect2i) -> void:
	_fill_irregular(img, r, _col(Palette.WALL_BASE.darkened(0.2)), 241)


## 哑铃小道具：金属杆 + 两端配重片。
func _paint_dumbbell(img: Image, r: Rect2i) -> void:
	_jagged_hline(img, r.position.x + 2, r.position.x + r.size.x - 2, r.position.y + r.size.y / 2, _col(Palette.METAL_HIGHLIGHT), 251)
	_fill_irregular(img, Rect2i(r.position.x + 1, r.position.y + 1, 4, r.size.y - 2), _col(Palette.METAL_DARK), 252)
	_fill_irregular(img, Rect2i(r.position.x + r.size.x - 5, r.position.y + 1, 4, r.size.y - 2), _col(Palette.METAL_DARK), 253)


## 壶铃：金属球 + 提把。
func _paint_kettlebell(img: Image, r: Rect2i) -> void:
	_jagged_vline(img, r.position.x + r.size.x / 2, r.position.y, r.position.y + 3, _col(Palette.METAL_HIGHLIGHT), 261)
	_fill_irregular(img, Rect2i(r.position.x + 2, r.position.y + 3, r.size.x - 4, r.size.y - 3), _col(Palette.METAL_DARK), 262)
	_fill_irregular(img, Rect2i(r.position.x + r.size.x / 2 - 1, r.position.y + 3, 2, 2), _col(Palette.CHARCOAL), 263)


## 粉笔盒：小盒 + 粉笔点。
func _paint_chalk_box(img: Image, r: Rect2i) -> void:
	_fill_irregular(img, r, _col(Palette.ACCENT_YELLOW.darkened(0.15)), 271)
	_jagged_hline(img, r.position.x, r.position.x + r.size.x, r.position.y, _col(Palette.ACCENT_YELLOW), 272)


## 卷起的瑜伽垫：暖色卷筒（不规则）。
func _paint_rolled_mat(img: Image, r: Rect2i) -> void:
	_fill_irregular(img, r, _col(Palette.ACCENT_ORANGE.darkened(0.2)), 281)
	_jagged_hline(img, r.position.x, r.position.x + r.size.x, r.position.y, _col(Palette.ACCENT_ORANGE.darkened(0.1)), 282)
	_jagged_hline(img, r.position.x + 2, r.position.x + r.size.x - 2, r.position.y + 2, _col(Palette.ACCENT_ORANGE.darkened(0.35)), 283)


## 水瓶：冷蓝瓶身 + 瓶盖。
func _paint_bottle(img: Image, r: Rect2i) -> void:
	_fill_irregular(img, Rect2i(r.position.x + 1, r.position.y, r.size.x - 2, 2), _col(Palette.ACCENT_CYAN.darkened(0.25)), 291)
	_fill_irregular(img, Rect2i(r.position.x, r.position.y + 2, r.size.x, r.size.y - 2), _col(Palette.ACCENT_CYAN), 292)
	_jagged_vline(img, r.position.x + 1, r.position.y + 2, r.position.y + r.size.y - 1, _col(Palette.ACCENT_CYAN.lightened(0.3)), 293)


## 纸杯：小灰杯。
func _paint_cup(img: Image, r: Rect2i) -> void:
	_fill_irregular(img, r, _col(Palette.CLOCK_FACE.darkened(0.25)), 301)
	_jagged_hline(img, r.position.x, r.position.x + r.size.x, r.position.y, _col(Palette.CLOCK_FACE.darkened(0.1)), 302)


## 墙钩：小金属点。
func _paint_hooks(img: Image, r: Rect2i) -> void:
	_fill_irregular(img, r, _col(Palette.METAL_HIGHLIGHT.darkened(0.1)), 311)


## 喷淋头：小圆点 + 中心孔。
func _paint_sprinkler(img: Image, r: Rect2i) -> void:
	_fill_irregular(img, r, _col(Palette.AC_VENT.darkened(0.3)), 321)
	img.set_pixel(r.position.x + 1, r.position.y + 1, _col(Palette.CHARCOAL))


## 配重片：金属圆片（不规则 blob，非同心矩形）。
func _paint_plate(img: Image, r: Rect2i) -> void:
	_paint_blob(img, r.position.x + r.size.x / 2, r.position.y + r.size.y / 2,
		mini(r.size.x, r.size.y) / 2, _col(Palette.METAL_DARK), 331)
	_paint_blob(img, r.position.x + r.size.x / 2, r.position.y + r.size.y / 2,
		maxi(1, mini(r.size.x, r.size.y) / 4), _col(Palette.CHARCOAL), 332)
	img.set_pixel(r.position.x + r.size.x / 2, r.position.y + r.size.y / 2, _col(Palette.METAL_HIGHLIGHT))


## 毛巾：暖橙小方（不规则）。
func _paint_towel(img: Image, r: Rect2i) -> void:
	_fill_irregular(img, r, _col(Palette.TOWEL), 341)
	_jagged_hline(img, r.position.x, r.position.x + r.size.x, r.position.y + 1, _col(Palette.TOWEL.darkened(0.15)), 342)


## 悬挂标识：深底 + 亮字点。
func _paint_sign(img: Image, r: Rect2i) -> void:
	_fill_irregular(img, r, _col(Palette.CHARCOAL), 351)
	_jagged_hline(img, r.position.x + 2, r.position.x + r.size.x - 2, r.position.y + 1, _col(Palette.ACCENT_YELLOW), 352)


## 电视：近黑机身（不规则）+ 亮屏。
func _paint_tv(img: Image, r: Rect2i) -> void:
	_fill_irregular(img, r, _col(Palette.CHARCOAL), 361)
	_fill_irregular(img, Rect2i(r.position.x + 2, r.position.y + 2, r.size.x - 4, r.size.y - 4), _col(Palette.EMISSIVE_CYAN), 362)


## 确定性 2D hash（无 RNG 状态 —— 同输入永远同输出）。
func _hash2(x: int, y: int) -> int:
	var h := x * 374761393 + y * 668265263
	h = (h ^ (h >> 13)) * 1274126177
	return h & 0x7fffffff
