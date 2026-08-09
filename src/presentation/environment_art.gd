# src/presentation/environment_art.gd — Phase 5 环境装饰像素精灵工厂（V3 §12）
#
# V3 §3/§12：场景 storytelling —— 水瓶、毛巾、海报、小配重、粉笔盒、植物、
# 音箱、卷垫、风扇、水杯架、饮水机、垃圾桶、消防栓、招牌。全部程序化
# 像素精灵（8×8 art px per 32px cell，与 EquipmentArt 同一套惯例），
# 色值单一来源 src/palette.gd（V3 §7）。本工厂只负责精灵纹理；位置由
# world_layout.gd 的 DECOR / WALL_DECOR 表驱动。
#
# 风格：小件装饰 —— 低对比、低饱和、不抢设备/会员主体（V3 §14 可读性：
# 可购买设备 > 环境装饰）。植物用中等饱和绿（V3 §7 植物色），高饱和
# accent 只用于设备屏幕/招牌（V3 §7）。
#
# headless 可靠性：跨脚本引用一律 preload alias（项目约定）。
class_name EnvironmentArt extends RefCounted

const Palette := preload("res://src/palette.gd")

const ART_PER_CELL := 8
const ART_SCALE := 4

## Map 图例（与 equipment_art 兼容 + 新增）：
##   . 透明 | O 描边(CHARCOAL) | W 墙色 | G 窗玻璃 | M 金属暗面 | H 金属高光
##   B Butter | P 植物绿 | p 植物深绿 | L 植物亮绿 | T 陶盆 | Y ACCENT_YELLOW
##   C ACCENT_CYAN | R ACCENT_ORANGE | K 暖黑(深棕/炭灰)
const ART_MAPS := {
	# 水瓶：小瓶身 + 瓶盖（accents 低饱和，不刺眼）
	"water_bottle": [
		"..K.....",
		".KYYK...",
		".KYYK...",
		".KYYK...",
		".KKKK...",
		".K..K...",
		"..KK....",
		"........",
	],
	# 毛巾：暖色叠巾（低饱和棕/灰）
	"towel": [
		"........",
		"..TTTT..",
		".TSSSST.",
		".TSSTST.",
		"..TTTT..",
		"........",
		"........",
		"........",
	],
	# 跑步海报（墙上）：暖底 + 简单人物剪影 —— V3.1 P3 无等宽边框（非完整
	# 外框环：左上/右下缺角，模拟手绘贴纸边缘）
	"poster_run": [
		"OOWWWWWO",
		"OWWWWWWO",
		"OWWWWWWO",
		"OWBWWWWO",
		"OWWWWWWO",
		"OWWWWBWO",
		"OWWWWWW.",
		".WWWWWO.",
	],
	# 瑜伽海报（墙上）：暖底 + 圆点（树式剪影暗示）—— P3 无等宽边框
	"poster_yoga": [
		"OOWWWWWO",
		"OWWWWWWO",
		"OWWWWWWO",
		"OWWBWWWO",
		"OWWBWWWO",
		"OWWWWWWO",
		"OWWWWW..",
		"OWWWWOO.",
	],
	# 小配重（散落杠铃片）：金属圆片
	"dumbbell": [
		"..MMM...",
		".MHHHM..",
		".MHOHM..",
		".MHHHM..",
		"..MMM...",
		"........",
		"........",
		"........",
	],
	# 粉笔盒：小方盒 —— P3 边缘不规则（非完整等宽外框）
	"chalk_box": [
		"..O.OO..",
		".OBBBBO.",
		".OBBBBO.",
		".OBBBB.O",
		"..OOOO..",
		"........",
		"........",
		"........",
	],
	# 植物（盆栽）：中等饱和绿 + 陶盆（V3 §7）
	"plant": [
		"..ppLp..",
		".pPLLPp.",
		".PLpLPP.",
		"..PPpP..",
		"..TTTT..",
		".TTTTTT.",
		"........",
		"........",
	],
	# 小音箱：暖黑 + 金属网
	"speaker": [
		"..KKKK..",
		".KHHHHK.",
		".KHHHHK.",
		".KHHHHK.",
		"..KKKK..",
		"........",
		"........",
		"........",
	],
	# 卷起的备用瑜伽垫：暖橙棕卷筒
	"mat_rolled": [
		"..OOOO..",
		".OZZZZO.",
		".OZZZZO.",
		".OZOOZO.",
		"..OOOO..",
		"........",
		"........",
		"........",
	],
	# 风扇：金属底座 + 叶片
	"fan": [
		"...H....",
		"..H H...",
		".H..H...",
		"..H H...",
		"...H....",
		"..MMM...",
		".MMOMM..",
		"........",
	],
	# 水杯架：杯 + 杯座
	"cup_holder": [
		"...C....",
		"..CC....",
		"..CC....",
		"..CC....",
		".KKKK...",
		"........",
		"........",
		"........",
	],
	# 饮水机：机身 + 出水口（少量 C accent —— V3 §6 饮水机局部辉光载体）
	"fountain": [
		"..OOOO..",
		".OMMMMO.",
		".OMMCMO.",
		".OMMMMO.",
		".OMMMMO.",
		".OMMMMO.",
		"..OOOO..",
		"........",
	],
	# 垃圾桶：暖黑桶
	"trash": [
		".KKKKKK.",
		"K......K",
		"K..KK..K",
		"K..KK..K",
		"K......K",
		".KKKKKK.",
		"........",
		"........",
	],
	# 消防栓：红色（低饱和砖红，V3 §7 高饱和仅小型装饰）
	"hydrant": [
		"...RR...",
		"..RRRR..",
		"..RRRR..",
		"..RRRR..",
		"...RR...",
		"..RRRR..",
		"........",
		"........",
	],
	# 招牌（前台方向）：暖底 + 字（视觉上像 gym 招牌）
	"sign_entrance": [
		"OOOYYOOO",
		"OYYYYYYO",
		"OYYYYYYO",
		"OYYYYYYO",
		"OYYYYYYO",
		"OOOYYOOO",
		"........",
		"........",
	],
	# 墙上计时器（自行车区）：圆盘 + 数字暗示
	"timer_bike": [
		"..OOOO..",
		".OWWWWO.",
		".OWWYWO.",
		".OWWWWO.",
		"..OOOO..",
		"........",
		"........",
		"........",
	],
	# 电视（V3 §9 电视画面变化）：机身边框 + 屏幕（屏幕内容由绘制层按 tick 切换）
	"tv": [
		"..KKKK..",
		".KGGGGK.",
		".KGGGGK.",
		".KGGGGK.",
		".KGGGGK.",
		"..KKKK..",
		"........",
		"........",
	],
	# 长椅（等待区）：深木座 + 金属腿（V3 §3 前台/入口等待区）
	"bench": [
		"........",
		".OOOOOO.",
		".OZZZZO.",
		".OZZZZO.",
		".OZZZZO.",
		".OM..MO.",
		".OM..MO.",
		"........",
	],
	# 壶铃：金属球 + 提把（力量区散落小配重，V3 §12）
	"kettlebell": [
		"...HH...",
		"..H..H..",
		"..MMMM..",
		".MMMMMM.",
		".MMMMMM.",
		".MMMMMM.",
		"..MMMM..",
		"........",
	],
	# 配重片：金属圆片（力量区散落，V3 §12）
	"plate": [
		"..MMM...",
		".MHHHM..",
		".MHOHM..",
		".MHHHM..",
		"..MMM...",
		"........",
		"........",
		"........",
	],
	# 瑜伽砖：暖橙方块（瑜伽区备用，V3 §12）
	"yoga_block": [
		"..OOOO..",
		".ORRRRO.",
		".ORRRRO.",
		".ORRRRO.",
		"..OOOO..",
		"........",
		"........",
		"........",
	],
	# 药球：深色圆球 + 高光（力量区散落，V3 §12）
	"medicine_ball": [
		"..KKKK..",
		".KHHHHK.",
		".KHHHHK.",
		".KHHHHK.",
		".KHHHHK.",
		"..KKKK..",
		"........",
		"........",
	],
}

## 兜底色（未知 prop_id / 区域）：暖中性（不与其他语义色撞）。
const FALLBACK := Color("C9A87C")

var _cache: Dictionary = {}


## 取装饰精灵纹理。未知 prop_id 返回 null（调用方兜底不画，绝不崩溃）。
## [prop_id] 支持带实例后缀的 decor 键（world_layout DECOR 表）：如
## "water_bottle_t1" → 基键 "water_bottle"（后缀 _t1/_s1/_f1/_b1/_fore_N）。
func texture_for(prop_id: String) -> ImageTexture:
	if _cache.has(prop_id):
		return _cache[prop_id]
	var base_id := _base_prop_id(prop_id)
	if not ART_MAPS.has(base_id):
		push_error("EnvironmentArt: no art map for '%s'" % prop_id)
		return null
	var tex := ImageTexture.create_from_image(_build_image(base_id))
	_cache[prop_id] = tex
	return tex


## 去除 decor 实例后缀 → 基 art 键。已存在直接返回；否则迭代去掉尾部
## 段（_t1/_s1/_f1/_b1/_fore_1）直到命中 ART_MAPS（"plant_fore_1"→
## "plant_fore"→"plant"）。后缀形态：纯数字（_1）、字母+数字（_s1）、
## "fore_" 前缀（_fore_1）。
func _base_prop_id(prop_id: String) -> String:
	if ART_MAPS.has(prop_id):
		return prop_id
	var candidate := prop_id
	while candidate.length() > 1:
		var idx := candidate.rfind("_")
		if idx <= 0:
			return prop_id
		var suffix := candidate.substr(idx + 1)
		if not _is_decor_suffix(suffix):
			return prop_id
		candidate = candidate.substr(0, idx)
		if ART_MAPS.has(candidate):
			return candidate
	return prop_id


## 判断是否是 decor 实例后缀（_1 / _s1 / _fore_1 / _fore 形态）。
func _is_decor_suffix(suffix: String) -> bool:
	if suffix.is_valid_int():
		return true
	if suffix.begins_with("fore"):
		return true
	if suffix.length() == 2 and suffix[0].is_valid_identifier() and suffix[1].is_valid_int():
		return true
	return false


## 返回 prop_id 的 art map 尺寸（art px），未知返回 ZERO。
## 与 texture_for() 同一解析路径：带实例后缀的 decor 键（"water_bottle_t1"）
## 先解析基键（"water_bottle"）再查 ART_MAPS —— 否则绘制层会拿到 (0,0)
## 尺寸画出空精灵（Phase 5 捕获实测：suffixed props 全部隐形）。
func art_size(prop_id: String) -> Vector2i:
	var base_id := _base_prop_id(prop_id)
	if not ART_MAPS.has(base_id):
		return Vector2i.ZERO
	var rows: Array = ART_MAPS[base_id]
	if rows.is_empty():
		return Vector2i.ZERO
	return Vector2i(String(rows[0]).length(), rows.size())


## 返回 prop_id 在世界像素空间的纹理尺寸（art px × ART_SCALE）。
func texture_size(prop_id: String) -> Vector2i:
	return art_size(prop_id) * ART_SCALE


## 建立 prop 图像：透明底 + 按 ART_SCALE 放大每个 art px。
func _build_image(prop_id: String) -> Image:
	var rows: Array = ART_MAPS[prop_id]
	var w: int = String(rows[0]).length()
	var h: int = rows.size()
	var img := Image.create(w * ART_SCALE, h * ART_SCALE, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for y in h:
		var row: String = rows[y]
		for x in w:
			var color := _color_for(row[x])
			if color.a <= 0.0:
				continue
			for py in ART_SCALE:
				for px in ART_SCALE:
					img.set_pixel(x * ART_SCALE + px, y * ART_SCALE + py, color)
	return img


## map 字符 → 实际颜色（色值全部来自 palette.gd）。
func _color_for(ch: String) -> Color:
	match ch:
		".":
			return Color(0, 0, 0, 0)
		"O":
			return Palette.CHARCOAL
		"W":
			return Palette.WALL_TRIM
		"G":
			return Palette.WINDOW_GLASS
		"M":
			return Palette.METAL_DARK
		"H":
			return Palette.METAL_HIGHLIGHT
		"B":
			return Palette.BUTTER
		"P":
			return Palette.PLANT_GREEN
		"p":
			return Palette.PLANT_GREEN_DARK
		"L":
			return Palette.PLANT_GREEN_LIGHT
		"T":
			return Palette.PLANT_POT
		"Y":
			return Palette.ACCENT_YELLOW
		"C":
			return Palette.ACCENT_CYAN
		"R":
			return Palette.ACCENT_ORANGE
		"K":
			return Palette.WALL_DARK
		"S":
			return Palette.FLOOR_WALK_GROUT
		"Z":
			return Palette.FLOOR_FLEX_BASE
		_:
			return Color(0, 0, 0, 0)
