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
##   F FOCAL_RED（红色广告牌） | X FOCAL_PINK | V FOCAL_PURPLE | Q FOCAL_TEAL
##   D FOCAL_YELLOW | N FOCAL_GREEN_LIGHT
##   （V3.1 P5 高饱和焦点色：红广告牌/彩色瑜伽用品 —— 只用于小型装饰）
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
	# V3.1 P5 植物亮叶变体（绿色植物焦点）：同 plant 造型，但亮叶（L）
	# 换用 FOCAL_GREEN_LIGHT 高饱和绿（N 字符）—— 只在精选 3 盆上使用
	# （DECOR 表 plant_bright_*），让「绿色植物」成为少数跳出的焦点，
	# 其余植物保持低饱和（V3.1 P5 精选 10-15 焦点，不整环境提饱和）。
	"plant_bright": [
		"..NNNN..",
		".pNNNNp.",
		".NNpNNN.",
		"..PNNP..",
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
		"OOODDOOO",
		"ODDDYDDO",
		"ODDDDDDO",
		"ODDDDDDO",
		"ODDDDDDO",
		"OOODDOOO",
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
	# V3.1 R4/R5 精修：红广告改为墙面主视觉横幅。大轮廓仍是手绘像素
	# 缺角/断边，暖白字形和黄色价签切开红底；它代替原来的 1-2px 点缀，
	# 成为局部视线统领块，但不扩散到地板/墙面基底。
	"ad_red": [
		"..FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF.",
		".FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF",
		"FFFFFWWWFFWFFWWWFFFFFWWWFWWWFFFFDDDDFFFF",
		"FFFFFWFFFFWFFWFFFFFFWFFFFFWFFFFDDDDFFFFF",
		"FFFFFWWWFFWFFWWWFFFFFWWWFWWWFFFFDDDDFFFF",
		"FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF",
		".FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF.",
		"...FFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF...",
	],
	# V3.1 P5 黄色水杯（地面，等待区/前台）：高饱和黄杯身 + 吸管。
	# P5 例子「黄色水杯」—— 高饱和焦点。杯身用 FOCAL_YELLOW（D 字符，
	# s≈0.76）而非 ACCENT_YELLOW（s≈0.69，环境装饰低饱和 —— 焦点与
	# 环境分离：只杯身跳出来）。
	"cup_yellow": [
		"........",
		"..DD....",
		".DDDDD..",
		".DDDDD..",
		".DDDDD..",
		".DDDDD..",
		"..DDD...",
		"........",
	],
	# V3.1 P5 彩色瑜伽球（瑜伽区）：粉/紫高饱和小球 + 高光。
	# P5 例子「彩色瑜伽用品」—— 高饱和焦点。小面积（非整块填充，
	# V3.1 P3 负面约束；P5 焦点是小装饰，不铺满 8×8）。
	"yoga_ball": [
		"........",
		"..VVVV..",
		".VVXXVV.",
		".VXXXXV.",
		".VVXXVV.",
		"..VVVV..",
		"........",
		"........",
	],
	# V3.1 P5 彩色瑜伽带（瑜伽区）：青/紫条纹卷带。小面积高饱和焦点。
	"yoga_strap": [
		"........",
		"..QQVV..",
		".QQVVQQ.",
		".QQVVQQ.",
		".VVQQVV.",
		"....QQ..",
		"........",
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
	# 杠铃架（力量区，V3 §12「杠铃架」）：A 型金属架 + 横杆 + 两侧配重。
	# 低饱和金属（M/H）+ 暖黑底座 —— 纯装饰不交互，饱和度低于可购买设备。
	"barbell_rack": [
		"...MM...",
		"..MHHM..",
		"..MHHM..",
		".MHHHHM.",
		".MHHHHM.",
		".MMMMMM.",
		"..MMMM..",
		"........",
	],
	# 暖色落地灯（瑜伽区，V3 §12「暖色灯」）：完整竖直 silhouette；由
	# WorldCanvas 作为 billboard 绘制，不能再随地板 transform 压成橙色块。
	"warm_lamp": [
		"...KK...",
		"..KRRK..",
		".KRRRRK.",
		"KRRBBRRK",
		"..KBBK..",
		"...KH...",
		"...KH...",
		"...KH...",
		"..KKHH..",
		".KKKKKK.",
	],
	# 计时器（跑步机区叙事道具组，返工2 R1「毛巾+水杯+计时器」）：深色
	# 计时器机身 + 青蓝显示屏 + 小按钮。低饱和（METAL_DARK/CHARCOAL），
	# 不抢设备焦点。
	"timer_treadmill": [
		".KKKKKK.",
		"KHHHHHHK",
		"KHHHHHHK",
		"KHCCCCHK",
		"KHCCCCHK",
		"KHHHHHHK",
		".KKKKKK.",
		"........",
	],
	# 力量区海报（返工2 R1「杠铃片+粉笔盒+海报」叙事道具组）：手绘海报板
	# —— 暖白板面 + 简单力量剪影 + 暗色边框（无等宽外框，缺角手绘感）。
	"poster_strength": [
		"..OOOO..",
		".OWWWWO.",
		"OWWWWWWO",
		"OWBBWWWO",
		"OWWWWWWO",
		"OWWWWWWO",
		".OWWWWO.",
		"..OOOO..",
	],
	# 单车区水瓶架（返工2 R1「水瓶架+毛巾」叙事道具组）：金属架 + 水瓶。
	"bottle_rack": [
		"..HH....",
		".HHHH...",
		".HMMH...",
		".HYYH...",
		".HYYH...",
		".HMMH...",
		"..HH....",
		"........",
	],
	# 清洁桶（返工3 P1 跑步机区/力量区「小储物/清洁桶」叙事道具）：
	# 低饱和蓝灰桶身 + 暖木提手 + 桶沿高光。非高饱和 —— 不新增 P5 焦点簇。
	"clean_bucket": [
		"..HH....",
		"..HH....",
		"..KK....",
		".KEEEEK.",
		".KeeeeK.",
		".KeeeeK.",
		".KeeeeK.",
		"..KKKK..",
	],
	# 储物架（返工3 P1 走廊/力量区储物）：暖木层板 + 深色框架 + 小件。
	# 与前台 DESK_WOOD 同族暖木 —— 任务 6 暖木焦点色。
	"storage_shelf": [
		"..KKKK..",
		".KUUUUK.",
		".KYYCYK.",
		".KUUUUK.",
		"..KKKK..",
		"...K....",
		"...K....",
		"...K....",
	],
	# 走廊地垫（返工3 P1 中央通道「地垫」）：暖木橡胶地垫 + 磨损。
	# 地垫是地面物件 —— 低对比、不抢设备主体。
	"corridor_mat": [
		"KWWWWWWK",
		"WMMMMMMW",
		"WMMMMMMW",
		"WMMMMMMW",
		"WMMMMMMW",
		"WMMMMMMW",
		"WMMMMMMW",
		"KWWWWWWK",
	],
	# 单车水壶（返工3 P1 单车区「单车水壶在位」）：小水壶在车架位。
	"bike_bottle": [
		"..KK....",
		".KYYK...",
		".KYYK...",
		".KYYK...",
		".KKKK...",
		"........",
		"........",
		"........",
	],
	# 海报墙（返工3 P1 中央通道「海报墙」）：多张小海报拼贴 ——
	# 暖色 accent 小面积（任务 6 焦点色分布），贴墙挂饰。
	"poster_wall": [
		"OOWWWWWW",
		"OWWYYWWW",
		"OWWYYWWW",
		"OWWWWWWO",
		"OWWRRWWW",
		"OWWRRWWW",
		"OWWWWWW.",
		"WWWWWW..",
	],
	# 瑜伽巾（返工3 P1 瑜伽区「卷垫旁成组」）：叠放的暖橙毛巾 ——
	# 与 TOWEL 同族色，卷垫旁生活痕迹。
	"yoga_towel": [
		"........",
		"..TTTT..",
		".TTTTTT.",
		".TSSSST.",
		".TSSTST.",
		"..TTTT..",
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
## 返工6 P1（FAIL3 道具轮廓/色阶稳定一致 + FAIL4 道具受光关系）：装饰
## 道具不再是「单色平涂贴片」—— 追加手绘后处理（确定性 hash，同输入
## 同输出）：
##   1. _apply_prop_outline：外轮廓深一档勾边（CHARCOAL 混合 55-75%，
##      与设备 EQUIP_EDGE_OUTLINE 同一视觉语言 —— 道具从背景勾出，
##      Δlum≥25 全帧一致；高光侧开放 + 手绘缺口 ~12%，非等宽边框）
##   2. _apply_prop_levels：受光面/主体/暗面三阶 —— 顶部 1-2 行向
##      HIGHLIGHT_WARM 混合（受光边），底部 1-2 行向 EQUIP_SHADOW_TONE
##      混合（暗面接地）—— 每件主要道具 ≥3 层色阶清晰可辨
##   3. 色阶边界手绘抖动：只混合邻近色阶（hash 缺口，笔触断裂，
##      禁止平滑渐变）
## 只作用于中性/语义色道具（FOCAL_* 高饱和焦点与设备 sprite 同源跳过，
## gate A 簇结构不动 —— cup_yellow/yoga_ball 等 P5 焦点保持原样）。
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
	_apply_prop_levels(img)
	_apply_prop_outline(img)
	return img


## 三阶手绘色阶（FAIL3 每件主要道具 ≥3 层色阶）：受光边（顶行）向
## HIGHLIGHT_WARM 混合、暗面（底行）向 EQUIP_SHADOW_TONE 混合。hash
## 缺口 ~25%（笔触断裂，非平滑渐变/非等宽描边）。跳过 FOCAL_* 高饱和
## 道具（gate A 簇结构不动）。
func _apply_prop_levels(img: Image) -> void:
	var w := img.get_width()
	var h := img.get_height()
	for x in w:
		# 找该列最顶/最底不透明行（受光边 = 顶行，暗面 = 底行）
		var top := -1
		var bottom := -1
		for y in h:
			if img.get_pixel(x, y).a > 0.5:
				if top < 0:
					top = y
				bottom = y
		if top < 0:
			continue
		_apply_level_row(img, x, top, Palette.HIGHLIGHT_WARM, 0.30)
		if bottom > top:
			_apply_level_row(img, x, bottom, Palette.EQUIP_SHADOW_TONE, 0.38)


## 单行色阶混合：hash 缺口 ~25%，混合量固定（受光边/暗面各有 ±10% 抖动）。
func _apply_level_row(img: Image, x: int, y: int, target: Color, amt: float) -> void:
	var c := img.get_pixel(x, y)
	if c.a <= 0.5:
		return
	if _is_focal_tone(c):
		return
	var hsh := _hash2(x * 5 + 3, y * 7 + 11)
	if hsh % 100 < 25:
		return
	var mix := amt + float((hsh >> 8) % 21) / 100.0 * 0.2  # amt ± 0.10
	img.set_pixel(x, y, c.lerp(target, mix))


## 外轮廓勾边（FAIL3 道具从背景勾出）：与透明相邻的边界像素向 CHARCOAL
## 混合 55-75%（Δlum≥25 全帧一致；高光侧开放 + 手绘缺口 ~12% —— 非等宽
## 边框，V3.1 负面约束）。跳过 FOCAL_* 高饱和道具（gate A 簇结构不动）。
func _apply_prop_outline(img: Image) -> void:
	var w := img.get_width()
	var h := img.get_height()
	for y in h:
		for x in w:
			var c := img.get_pixel(x, y)
			if c.a <= 0.5:
				continue
			if _is_focal_tone(c):
				continue
			if not _is_boundary(img, x, y):
				continue
			var hsh := _hash2(x * 3 + 7, y * 5 + 9)
			if hsh % 100 < 12:
				continue
			var amt := 0.55 + float((hsh >> 8) % 21) / 100.0  # 55-75%
			img.set_pixel(x, y, c.lerp(Palette.CHARCOAL, amt))


## 像素是否与透明相邻（精灵外轮廓边界）。
func _is_boundary(img: Image, x: int, y: int) -> bool:
	if x <= 0 or y <= 0 or x >= img.get_width() - 1 or y >= img.get_height() - 1:
		return true
	for n in [[x - 1, y], [x + 1, y], [x, y - 1], [x, y + 1]]:
		if img.get_pixel(n[0], n[1]).a <= 0.5:
			return true
	return false


## 高饱和焦点色（P5 FOCAL_* / ACCENT / EMISSIVE 族）：跳过轮廓/色阶混合，
## 保持 P5 高饱和焦点簇结构（gate A 计数 ≤18 硬门，返工5 P1 教训：
## 改设备/道具 sprite 会影响全帧簇数）。判定 = HSV sat > 0.55（中性/
## 语义色全系 sat≤0.45，不会误判；ACCENT_YELLOW 0.63 / FOCAL_* 0.56-0.80
## 全被跳过）。
func _is_focal_tone(c: Color) -> bool:
	var mx := maxf(c.r, maxf(c.g, c.b))
	var mn := minf(c.r, minf(c.g, c.b))
	if mx <= 0.0:
		return false
	return (mx - mn) / mx > 0.55


## 确定性 hash（同 floor_art._hash2 —— 无 RNG 状态，headless 可测）。
func _hash2(x: int, y: int) -> int:
	var h := x * 374761393 + y * 668265263
	h = (h ^ (h >> 13)) * 1274126177
	return h & 0x7fffffff


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
		"E":
			return Palette.CLEAN_BUCKET
		"e":
			return Palette.CLEAN_BUCKET_DARK
		"U":
			return Palette.SHELF_WOOD
		"u":
			return Palette.SHELF_FRAME
		"F":
			return Palette.FOCAL_RED
		"X":
			return Palette.FOCAL_PINK
		"V":
			return Palette.FOCAL_PURPLE
		"Q":
			return Palette.FOCAL_TEAL
		"N":
			return Palette.FOCAL_GREEN_LIGHT
		"D":
			return Palette.FOCAL_YELLOW
		_:
			return Color(0, 0, 0, 0)
