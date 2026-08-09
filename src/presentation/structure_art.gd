# src/presentation/structure_art.gd — 结构层程序化工厂（Phase 2，与 Phase 5 并存）
#
# V3 §3（环境资产密度）/ §4（三层空间）/ §13（密度标准）：
#   Phase 5 已实现地板材质（FloorArt，V3 §1）与场景装饰精灵（EnvironmentArt +
#   world_layout，V3 §12）。本工厂补充 Phase 5 未覆盖的「结构元素」—— 立柱、
#   前台、储物柜、镜子、空调、墙钟、通风口、吊灯、管道、踢脚线、电线槽、
#   毛巾架、门、门垫 —— 烘焙成三张图层贴图（BACKGROUND / GAMEPLAY /
#   FOREGROUND），WorldCanvas 每层每帧只 draw 一次（共 3 draw calls）。
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
# 确定性：结构位置全部固定（无 RNG）；纹理烘焙一次并缓存。
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
	{"id": "hanging_lamp_1", "kind": "lamp", "layer": LAYER_FOREGROUND, "size": "small", "rect": Rect2i(80, 16, 12, 14), "painted_by": "self"},
	{"id": "hanging_lamp_2", "kind": "lamp", "layer": LAYER_FOREGROUND, "size": "small", "rect": Rect2i(196, 16, 12, 14), "painted_by": "self"},
	{"id": "hanging_lamp_3", "kind": "lamp", "layer": LAYER_FOREGROUND, "size": "small", "rect": Rect2i(356, 16, 12, 14), "painted_by": "self"},
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


# === 结构绘制（每个结构 = 一个小像素画；颜色全部来自 palette.gd） ===

func _fill(img: Image, r: Rect2i, c: Color) -> void:
	for y in r.size.y:
		for x in r.size.x:
			var px := r.position.x + x
			var py := r.position.y + y
			if px >= 0 and px < WORLD_W and py >= 0 and py < WORLD_H:
				img.set_pixel(px, py, c)


## 墙体：主色填充 + 竖向面板分隔线 + 顶部受光亮线（V3 §6 顶部暖白光）。
func _paint_wall(img: Image, r: Rect2i) -> void:
	_fill(img, r, _col(Palette.WALL_BASE))
	for x in range(r.position.x + 32, r.position.x + r.size.x, 32):
		_fill(img, Rect2i(x, r.position.y, 1, r.size.y), _col(Palette.WALL_DARK))
	_fill(img, Rect2i(r.position.x, r.position.y, r.size.x, 2), _col(Palette.WALL_TRIM))
	_fill(img, Rect2i(r.position.x, r.position.y + r.size.y - 2, r.size.x, 2), _col(Palette.WALL_DARK))


## 窗户：窗框 + 冷蓝玻璃 + 斜向高光（V3 §6 冷阴影 / 高光暖白）。
func _paint_window(img: Image, r: Rect2i) -> void:
	_fill(img, r, _col(Palette.WINDOW_FRAME))
	var glass := r.grow(-2)
	_fill(img, glass, _col(Palette.WINDOW_GLASS))
	# 十字窗棂
	_fill(img, Rect2i(glass.position.x + glass.size.x / 2 - 1, glass.position.y, 2, glass.size.y), _col(Palette.WINDOW_FRAME))
	_fill(img, Rect2i(glass.position.x, glass.position.y + glass.size.y / 2 - 1, glass.size.x, 2), _col(Palette.WINDOW_FRAME))
	# 斜向高光
	for i in mini(glass.size.x, glass.size.y):
		var px := glass.position.x + i
		var py := glass.position.y + i
		if px < glass.position.x + glass.size.x and py < glass.position.y + glass.size.y:
			img.set_pixel(px, py, _col(Palette.METAL_HIGHLIGHT))


## 门：门框 + 深木门板 + 门缝高光。
func _paint_door(img: Image, r: Rect2i) -> void:
	_fill(img, r, _col(Palette.DOOR_FRAME))
	var panel := r.grow(-2)
	_fill(img, panel, _col(Palette.DOOR_COLOR))
	_fill(img, Rect2i(panel.position.x + panel.size.x / 2 - 1, panel.position.y, 2, panel.size.y), _col(Palette.DOOR_FRAME))
	_fill(img, Rect2i(panel.position.x + panel.size.x - 4, panel.position.y + panel.size.y / 2 - 1, 2, 2), _col(Palette.METAL_HIGHLIGHT))


## 门口地垫：深暖灰 + 边框。
func _paint_door_mat(img: Image, r: Rect2i) -> void:
	_fill(img, r, _col(Palette.DOOR_MAT))
	_fill(img, Rect2i(r.position.x, r.position.y, r.size.x, 1), _col(Palette.DOOR_MAT.lightened(0.12)))
	_fill(img, Rect2i(r.position.x, r.position.y + r.size.y - 1, r.size.x, 1), _col(Palette.DOOR_MAT.darkened(0.12)))


## 海报：边框 + 暖色 accent 主色（小面积高饱和，V3 §7）。
func _paint_poster(img: Image, r: Rect2i) -> void:
	_fill(img, r, _col(Palette.WALL_DARK))
	var inner := r.grow(-1)
	var accents := [Palette.ACCENT_YELLOW, Palette.ACCENT_ORANGE, Palette.ACCENT_CYAN]
	var accent: Color = accents[r.position.x % accents.size()]
	_fill(img, inner, _col(accent))
	var base := Rect2i(inner.position.x, inner.position.y + inner.size.y - inner.size.y / 3, inner.size.x, inner.size.y / 3)
	_fill(img, base, _col(accent.darkened(0.35)))


## 墙钟：表盘 + 指针。
func _paint_clock(img: Image, r: Rect2i) -> void:
	_fill(img, r, _col(Palette.CLOCK_FACE))
	var cx := r.position.x + r.size.x / 2
	var cy := r.position.y + r.size.y / 2
	for d in [Vector2(-1, -1), Vector2(1, -1), Vector2(-1, 1), Vector2(1, 1)]:
		img.set_pixel(cx + int(d.x), cy + int(d.y), _col(Palette.CLOCK_HAND))
	_fill(img, Rect2i(cx, r.position.y, 1, r.size.y / 2), _col(Palette.CLOCK_HAND))
	_fill(img, Rect2i(cx, cy, r.size.x / 2, 1), _col(Palette.CLOCK_HAND))


## 空调：暖白机身 + 出风栅 + 显示灯。
func _paint_ac(img: Image, r: Rect2i) -> void:
	_fill(img, r, _col(Palette.AC_BODY))
	for y in range(r.position.y + 4, r.position.y + r.size.y - 2, 3):
		_fill(img, Rect2i(r.position.x + 2, y, r.size.x - 4, 1), _col(Palette.AC_VENT))
	img.set_pixel(r.position.x + r.size.x - 3, r.position.y + 2, _col(Palette.ACCENT_YELLOW))


## 通风口：边框 + 栅条。
func _paint_vent(img: Image, r: Rect2i) -> void:
	_fill(img, r, _col(Palette.AC_VENT.darkened(0.2)))
	_fill(img, Rect2i(r.position.x, r.position.y, r.size.x, 1), _col(Palette.WALL_DARK))
	for x in range(r.position.x + 1, r.position.x + r.size.x, 2):
		_fill(img, Rect2i(x, r.position.y + 1, 1, r.size.y - 2), _col(Palette.AC_BODY))


## 音箱：近黑箱体 + 网孔点。
func _paint_speaker(img: Image, r: Rect2i) -> void:
	_fill(img, r, _col(Palette.CHARCOAL))
	for y in range(r.position.y + 2, r.position.y + r.size.y - 1, 2):
		for x in range(r.position.x + 2, r.position.x + r.size.x - 1, 2):
			img.set_pixel(x, y, _col(Palette.CHARCOAL.lightened(0.25)))


## 镜子：冷蓝灰镜面 + 斜向高光 + 边框（V3 §6 冷调）。
func _paint_mirror(img: Image, r: Rect2i) -> void:
	_fill(img, r, _col(Palette.WALL_DARK))
	var glass := r.grow(-2)
	_fill(img, glass, _col(Palette.MIRROR_COLOR))
	for i in mini(glass.size.x, glass.size.y):
		var px := glass.position.x + i
		var py := glass.position.y + i
		if px < glass.position.x + glass.size.x and py < glass.position.y + glass.size.y:
			img.set_pixel(px, py, _col(Palette.MIRROR_HI))


## 储物柜：蓝灰柜体 + 竖柜门缝 + 暖金把手。
func _paint_lockers(img: Image, r: Rect2i) -> void:
	_fill(img, r, _col(Palette.LOCKER_COLOR))
	var x := r.position.x
	while x < r.position.x + r.size.x:
		_fill(img, Rect2i(x, r.position.y, 1, r.size.y), _col(Palette.LOCKER_DARK))
		var handle_x := x + 5
		if handle_x < r.position.x + r.size.x:
			_fill(img, Rect2i(handle_x, r.position.y + r.size.y / 2 - 1, 2, 2), _col(Palette.LOCKER_HANDLE))
		x += 8
	_fill(img, Rect2i(r.position.x, r.position.y, r.size.x, 1), _col(Palette.LOCKER_COLOR.lightened(0.15)))


## 前台：台面 + 台沿 + 收银机（GAMEPLAY 层 —— 原色、轮廓明确）。
func _paint_desk(img: Image, r: Rect2i) -> void:
	_fill(img, r, _col(Palette.DESK_WOOD))
	_fill(img, Rect2i(r.position.x, r.position.y, r.size.x, 2), _col(Palette.DESK_TOP))
	_fill(img, Rect2i(r.position.x, r.position.y + r.size.y - 2, r.size.x, 2), _col(Palette.DESK_WOOD.darkened(0.25)))
	_fill(img, Rect2i(r.position.x + 4, r.position.y + r.size.y - 6, r.size.x - 8, 4), _col(Palette.DESK_WOOD.darkened(0.18)))
	# 收银机：机身 + Butter 屏
	_fill(img, Rect2i(r.position.x + r.size.x / 2 - 5, r.position.y + 3, 10, 8), _col(Palette.METAL_DARK))
	_fill(img, Rect2i(r.position.x + r.size.x / 2 - 3, r.position.y + 4, 6, 4), _col(Palette.ACCENT_YELLOW))


## 饮水机：暖白机身 + 出水口 + 水桶。
func _paint_fountain(img: Image, r: Rect2i) -> void:
	_fill(img, r, _col(Palette.FOUNTAIN))
	_fill(img, Rect2i(r.position.x + 1, r.position.y + r.size.y / 2, r.size.x - 2, r.size.y / 2 - 1), _col(Palette.FOUNTAIN.darkened(0.12)))
	_fill(img, Rect2i(r.position.x + 2, r.position.y + 2, 3, 4), _col(Palette.METAL_HIGHLIGHT))
	img.set_pixel(r.position.x + r.size.x / 2, r.position.y + r.size.y / 2 + 2, _col(Palette.ACCENT_CYAN))


## 垃圾桶：深暖灰 + 桶沿。
func _paint_trash(img: Image, r: Rect2i) -> void:
	_fill(img, r, _col(Palette.TRASH))
	_fill(img, Rect2i(r.position.x, r.position.y, r.size.x, 2), _col(Palette.TRASH.lightened(0.12)))
	_fill(img, Rect2i(r.position.x + 1, r.position.y + 2, r.size.x - 2, 1), _col(Palette.TRASH.darkened(0.2)))


## 毛巾架：横杆 + 两条暖橙毛巾。
func _paint_towel_rack(img: Image, r: Rect2i) -> void:
	_fill(img, Rect2i(r.position.x, r.position.y, r.size.x, 1), _col(Palette.METAL_HIGHLIGHT))
	_fill(img, Rect2i(r.position.x + 1, r.position.y + 1, 3, r.size.y - 1), _col(Palette.TOWEL))
	_fill(img, Rect2i(r.position.x + r.size.x - 4, r.position.y + 1, 3, r.size.y - 1), _col(Palette.TOWEL.darkened(0.15)))


## 消防栓：低饱和红箱 + 白色顶盖。
func _paint_hydrant(img: Image, r: Rect2i) -> void:
	_fill(img, r, _col(Palette.HYDRANT))
	_fill(img, Rect2i(r.position.x, r.position.y, r.size.x, 2), _col(Palette.HYDRANT.lightened(0.2)))
	_fill(img, Rect2i(r.position.x + 1, r.position.y + r.size.y - 3, r.size.x - 2, 1), _col(Palette.HYDRANT.darkened(0.25)))


## 储物架：隔板 + 小物件。
func _paint_shelf(img: Image, r: Rect2i) -> void:
	_fill(img, Rect2i(r.position.x, r.position.y, r.size.x, 1), _col(Palette.WALL_TRIM))
	_fill(img, Rect2i(r.position.x + 1, r.position.y + 1, 2, 4), _col(Palette.ACCENT_CYAN))
	_fill(img, Rect2i(r.position.x + 5, r.position.y + 1, 2, 3), _col(Palette.ACCENT_YELLOW))


## 立柱：暖灰柱体 + 侧影 + 顶部受光（FOREGROUND，允许遮挡角色）。
func _paint_column(img: Image, r: Rect2i) -> void:
	_fill(img, r, _col(Palette.COLUMN_COLOR))
	_fill(img, Rect2i(r.position.x, r.position.y, 2, r.size.y), _col(Palette.COLUMN_COLOR.lightened(0.18)))
	_fill(img, Rect2i(r.position.x + r.size.x - 2, r.position.y, 2, r.size.y), _col(Palette.COLUMN_DARK))
	_fill(img, Rect2i(r.position.x - 1, r.position.y, r.size.x + 2, 2), _col(Palette.COLUMN_DARK))
	_fill(img, Rect2i(r.position.x - 1, r.position.y + r.size.y - 2, r.size.x + 2, 2), _col(Palette.COLUMN_DARK))


## 植物：陶盆 + 多层绿叶（中等饱和绿，V3 §7 允许）。
func _paint_plant(img: Image, r: Rect2i) -> void:
	var pot_h := maxi(4, r.size.y / 3)
	_fill(img, Rect2i(r.position.x + 2, r.position.y + r.size.y - pot_h, r.size.x - 4, pot_h), _col(Palette.PLANT_POT))
	var leaf_top := r.position.y + maxi(0, r.size.y - pot_h - 4)
	for i in 3:
		var lw := r.size.x - 4 - i * 3
		var lx := r.position.x + 2 + i
		var ly := leaf_top + i * 2
		_fill(img, Rect2i(lx, ly, lw, 4), _col(Palette.PLANT_GREEN if i % 2 == 0 else Palette.PLANT_GREEN_DARK))
	_fill(img, Rect2i(r.position.x + r.size.x / 2 - 2, leaf_top - 2, 4, 2), _col(Palette.PLANT_GREEN_LIGHT))


## 吊灯：灯罩 + 暖光晕（FOREGROUND，悬于上方）。
func _paint_lamp(img: Image, r: Rect2i) -> void:
	_fill(img, Rect2i(r.position.x + r.size.x / 2 - 1, r.position.y - 12, 2, 6), _col(Palette.CHARCOAL))
	_fill(img, Rect2i(r.position.x + r.size.x / 2 - 2, r.position.y + 2, 4, 2), _col(Palette.CHARCOAL))
	_fill(img, Rect2i(r.position.x + 1, r.position.y + r.size.y - 3, r.size.x - 2, 3), _col(Palette.LAMP_SHADE))
	var glow := Palette.LAMP_GLOW
	for i in 3:
		glow.a = Palette.LAMP_GLOW.a * (0.8 - i * 0.25)
		var gy := r.position.y + r.size.y + 2 + i * 3
		_fill(img, Rect2i(r.position.x + 2 + i, gy, r.size.x - 4 - i * 2, 2), glow)


## 电线槽：浅暖灰细条。
func _paint_cable(img: Image, r: Rect2i) -> void:
	_fill(img, r, _col(Palette.CABLE_DUCT))
	_fill(img, Rect2i(r.position.x, r.position.y + r.size.y - 1, r.size.x, 1), _col(Palette.CABLE_DUCT.darkened(0.15)))


## 管道：中暖灰 + 法兰接头。
func _paint_pipe(img: Image, r: Rect2i) -> void:
	_fill(img, r, _col(Palette.PIPE_COLOR))
	if r.size.y > r.size.x:
		for y in range(r.position.y, r.position.y + r.size.y, 64):
			_fill(img, Rect2i(r.position.x - 1, y, r.size.x + 2, 2), _col(Palette.PIPE_DARK))
	else:
		for x in range(r.position.x, r.position.x + r.size.x, 64):
			_fill(img, Rect2i(x, r.position.y - 1, 2, r.size.y + 2), _col(Palette.PIPE_DARK))


## 踢脚线：深暖灰细条。
func _paint_baseboard(img: Image, r: Rect2i) -> void:
	_fill(img, r, _col(Palette.WALL_BASE.darkened(0.2)))


## 哑铃小道具：金属杆 + 两端配重片。
func _paint_dumbbell(img: Image, r: Rect2i) -> void:
	_fill(img, Rect2i(r.position.x + 2, r.position.y + r.size.y / 2 - 1, r.size.x - 4, 2), _col(Palette.METAL_HIGHLIGHT))
	_fill(img, Rect2i(r.position.x + 1, r.position.y + 1, 4, r.size.y - 2), _col(Palette.METAL_DARK))
	_fill(img, Rect2i(r.position.x + r.size.x - 5, r.position.y + 1, 4, r.size.y - 2), _col(Palette.METAL_DARK))


## 壶铃：金属球 + 提把。
func _paint_kettlebell(img: Image, r: Rect2i) -> void:
	_fill(img, Rect2i(r.position.x + r.size.x / 2 - 1, r.position.y, 2, 3), _col(Palette.METAL_HIGHLIGHT))
	_fill(img, Rect2i(r.position.x + 2, r.position.y + 3, r.size.x - 4, r.size.y - 3), _col(Palette.METAL_DARK))
	_fill(img, Rect2i(r.position.x + r.size.x / 2 - 1, r.position.y + 3, 2, 2), _col(Palette.CHARCOAL))


## 粉笔盒：小盒 + 粉笔点。
func _paint_chalk_box(img: Image, r: Rect2i) -> void:
	_fill(img, r, _col(Palette.ACCENT_YELLOW.darkened(0.15)))
	_fill(img, Rect2i(r.position.x, r.position.y, r.size.x, 1), _col(Palette.ACCENT_YELLOW))


## 卷起的瑜伽垫：暖色卷筒。
func _paint_rolled_mat(img: Image, r: Rect2i) -> void:
	_fill(img, r, _col(Palette.ACCENT_ORANGE.darkened(0.2)))
	_fill(img, Rect2i(r.position.x, r.position.y, r.size.x, 1), _col(Palette.ACCENT_ORANGE.darkened(0.1)))
	_fill(img, Rect2i(r.position.x + 2, r.position.y + 2, r.size.x - 4, 1), _col(Palette.ACCENT_ORANGE.darkened(0.35)))


## 水瓶：冷蓝瓶身 + 瓶盖。
func _paint_bottle(img: Image, r: Rect2i) -> void:
	_fill(img, Rect2i(r.position.x + 1, r.position.y, r.size.x - 2, 2), _col(Palette.ACCENT_CYAN.darkened(0.25)))
	_fill(img, Rect2i(r.position.x, r.position.y + 2, r.size.x, r.size.y - 2), _col(Palette.ACCENT_CYAN))
	_fill(img, Rect2i(r.position.x + 1, r.position.y + 2, 1, r.size.y - 3), _col(Palette.ACCENT_CYAN.lightened(0.3)))


## 纸杯：小灰杯。
func _paint_cup(img: Image, r: Rect2i) -> void:
	_fill(img, r, _col(Palette.CLOCK_FACE.darkened(0.25)))
	_fill(img, Rect2i(r.position.x, r.position.y, r.size.x, 1), _col(Palette.CLOCK_FACE.darkened(0.1)))


## 墙钩：小金属点。
func _paint_hooks(img: Image, r: Rect2i) -> void:
	_fill(img, r, _col(Palette.METAL_HIGHLIGHT.darkened(0.1)))


## 喷淋头：小圆点 + 中心孔。
func _paint_sprinkler(img: Image, r: Rect2i) -> void:
	_fill(img, r, _col(Palette.AC_VENT.darkened(0.3)))
	img.set_pixel(r.position.x + 1, r.position.y + 1, _col(Palette.CHARCOAL))


## 配重片：金属圆片。
func _paint_plate(img: Image, r: Rect2i) -> void:
	_fill(img, r, _col(Palette.METAL_DARK))
	_fill(img, Rect2i(r.position.x + 2, r.position.y + 2, r.size.x - 4, r.size.y - 4), _col(Palette.CHARCOAL))
	_fill(img, Rect2i(r.position.x + r.size.x / 2 - 1, r.position.y + r.size.y / 2 - 1, 2, 2), _col(Palette.METAL_HIGHLIGHT))


## 毛巾：暖橙小方。
func _paint_towel(img: Image, r: Rect2i) -> void:
	_fill(img, r, _col(Palette.TOWEL))
	_fill(img, Rect2i(r.position.x, r.position.y + 1, r.size.x, 1), _col(Palette.TOWEL.darkened(0.15)))


## 悬挂标识：深底 + 亮字点。
func _paint_sign(img: Image, r: Rect2i) -> void:
	_fill(img, r, _col(Palette.CHARCOAL))
	_fill(img, Rect2i(r.position.x + 2, r.position.y + 1, r.size.x - 4, 1), _col(Palette.ACCENT_YELLOW))


## 电视：近黑机身 + 亮屏。
func _paint_tv(img: Image, r: Rect2i) -> void:
	_fill(img, r, _col(Palette.CHARCOAL))
	_fill(img, Rect2i(r.position.x + 2, r.position.y + 2, r.size.x - 4, r.size.y - 4), _col(Palette.EMISSIVE_CYAN))
