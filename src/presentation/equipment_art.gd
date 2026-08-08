## src/presentation/equipment_art.gd — 设备像素精灵程序化工厂（V3 Phase 3）
##
## 设备 = 小型场景物件（V3 §5，非图标）：3/4 top-down 可辨朝向 + 明显前后结构 +
## 3-5 个主要颜色层级 + 明确高光 + 明确阴影 + 小范围 accent color。
## 本工厂把每台设备的手工归纳像素造型（字符串 map，16×16 art px per cell）
## 放大到 CELL_SIZE 并产出 ImageTexture（ART_SCALE=2 → 每个 art px = 2 屏 px）。
##
## 风格（V3 §5/§6/§7/§11，全部可执行规范）：
##   - 机身材质 = 炭灰/深蓝灰/浅灰金属（EQUIP_BODY_DARK/BODY/BODY_LIGHT，
##     §7 器械色系）；区域语义色只做小范围 accent（§14 可购买设备饱和度高）
##   - 方向光（§6）：顶部暖白主光 → 暖黄/奶白高光（EQUIP_HIGHLIGHT，左侧），
##     冷蓝灰阴影（EQUIP_SHADOW_TONE，右侧）；contact shadow 由 WorldCanvas 画
##   - 轮廓（§11）：机器深蓝灰轮廓（EQUIP_OUTLINE）；高光侧可无完整描边
##   - 屏幕 emissive：青蓝显示灯（EQUIP_ACCENT_CYAN，§6 部分屏幕青蓝像素）
##   - 负面约束：无纯黑粗边、无照片纹理、无高饱和撞色
##
## 色值单一来源：src/palette.gd。本文件不出现任何硬编码色值。
##
## ROTATION CONVENTION（与 GridSystem 一致）：Rotation 用度数 0/90/180/270。
## R0 map 按设备 canonical footprint 绘制；R90/R180/R270 通过对 Image 做
## rotate_90(CLOCKWISE) 得到（与 GridSystem._transform_cell 的 R90 方向一致，
## 已验证：Image.rotate_90(CLOCKWISE) 把 (0,0) 移到 (W-1,0)）。
##
## headless 可靠性：class_name 仅作编辑器便利，跨脚本引用一律走 preload alias
## （项目约定，见 src/main.gd 头部注释）。
class_name EquipmentArt extends RefCounted

const Palette := preload("res://src/palette.gd")

## Art map 每个 cell 的逻辑像素数（16×16），放大到 CELL_SIZE 后每个 art px = 2 屏 px。
## V3 Phase 3：8→16 提升造型细节（同 32×32/cell 屏尺寸，4 倍 art 分辨率）。
const ART_PER_CELL := 16
const ART_SCALE := 2

## Map 图例（V3 §5/§6/§7/§11 材质语义；色值全部来自 palette.gd）：
##   . 透明
##   O 机器轮廓（EQUIP_OUTLINE 深蓝灰，§11）
##   C 软炭灰边（长凳垫/瑜伽垫边缘，非机器件）
##   1 机身材暗面（EQUIP_BODY_DARK 炭灰）   2 机身材中调（EQUIP_BODY 深蓝灰）
##   3 浅灰金属（EQUIP_BODY_LIGHT 扶手/机架/轮毂）
##   M 金属暗面（METAL_DARK）   H 金属高光（METAL_HIGHLIGHT 冷钢）
##   W 暖黄/奶白高光（EQUIP_HIGHLIGHT，§6 顶部暖白主光）
##   S 冷蓝灰阴影（EQUIP_SHADOW_TONE，§6 阴影偏冷偏蓝灰）
##   A 青蓝显示灯（EQUIP_ACCENT_CYAN，§6 emissive 屏幕）
##   Z 区域语义色（小范围 accent，§14）  D 区域暗色  L 区域亮色
##
## 每件设备 = 手工归纳的 3/4 top-down 场景物件（先剪影后补特征，§5）：
##   - treadmill 2×1：后滚轮（暗/影）→ 大型倾斜跑带（M2M 履带纹）→ 前端
##     控制面板（青蓝显示屏 + 暖高光 + 区域 accent 键）；两侧浅灰金属扶手
##   - bike 1×1：座椅（后，暗+暖顶光）→ 飞轮（M/H 金属盘 + 区域 accent）→
##     车把 + 小显示屏（前，青蓝）；机架 3/1 交替
##   - bench_press 2×2：杠铃 + 配重片（后/头端）→ 支架（浅灰金属）→
##     卧推凳（前，区域色 Sage 竖向条带，C 边 + L/D 高光阴影）
##   - yoga_mat 1×1：卷起边缘（上，L/Z/D 卷筒）→ 垫面（Z + D 细纹理）→
##     平展端（下）
const ART_MAPS := {
	"treadmill": [
		"..OOOOOOOOOOOOOOOOOOOOOOOOOOOO..",
		"..OSSSSSSSSSSSSSSSSSSSSSSSSSSO..",
		"..OS111111111111111111111111SO..",
		"..OS111111111111111111111111SO..",
		"..3W1M2M2M2M2M2M2M2M2M2M2M233O..",
		"..3W1M2M2M2M2M2M2M2M2M2M2M233O..",
		"..3W1M2M2M2M2M2M2M2M2M2M2M233O..",
		"..3W1M2M2M2M2M2M2M2M2M2M2M233O..",
		"..3W1M2M2M2M2M2M2M2M2M2M2M233O..",
		"..3W1M2M2M2M2M2M2M2M2M2M2M233O..",
		"..3W3333333333333333333333333O..",
		"..3W1111111111111111111111111O..",
		"..3O111111111111111111111111O3..",
		"..3O1WWWWAAAZZ11AAAAAWWWW11113..",
		"..O11111111111111111111111111O..",
		"..OOOOOOOOOOOOOOOOOOOOOOOOOOOO..",
	],
	"bike": [
		"..OOOOOOOOOOOO..",
		"..OSSSSSSSSSSO..",
		"..OS11111111SO..",
		"..3W11HHHH11W3..",
		"..3W1M3333M1W3..",
		"..3W1MMHHMM1W3..",
		"..3W1MHZZHM1W3..",
		"..3W1MMSSMM1W3..",
		"..3W33333333W3..",
		"..3W31313131W3..",
		"..3O31313131O3..",
		"..3O1M3131M1O3..",
		"..3O1HAAAH11O3..",
		"..3O33333333O3..",
		"..O1111111111O..",
		"..OOOOOOOOOOOO..",
	],
	"bench_press": [
		"..OOOOOOOOOOOOOOOOOOOOOOOOOOOO..",
		"..OSMMMMMMMMMMMMMMMMMMMMMMMMSO..",
		"..OMHHHHMMMMMMMMMMMMMMMMHHHHMO..",
		"..OMHHHHMMMMMMMMMMMMMMMMHHHHMO..",
		"..OMSSSSMMMMMMMMMMMMMMMMSSSSMO..",
		"..OSMMMMMMMMMMMMMMMMMMMMMMMMSO..",
		"..OSMMMMMMMMMMMMMMMMMMMMMMMMSO..",
		"..OMSSSSMMMMMMMMMMMMMMMMSSSSMO..",
		"..OMHHHHMMMMMMMMMMMMMMMMHHHHMO..",
		"..OSMMMMMMMMMMMMMMMMMMMMMMMMSO..",
		"..OWWMMMMMMMMMMMMMMMMMMMMMMWWO..",
		"..O11111133111111111133111111O..",
		"..O11111133111111111133111111O..",
		"..O11111133111111111133111111O..",
		"..O1111111111CLLLLLC111111111O..",
		"..O1111111111CZZZZZC111111111O..",
		"..O1111111111CZZZZZC111111111O..",
		"..O1111111111CZZZZZC111111111O..",
		"..O1111111111CZZZZZC111111111O..",
		"..O1111111111CZZZZZC111111111O..",
		"..O1111111111CZZZZZC111111111O..",
		"..O1111111111CZZZZZC111111111O..",
		"..O1111111111CZZZZZC111111111O..",
		"..O1111111111CZZZZZC111111111O..",
		"..O1111111111CZZZZZC111111111O..",
		"..O1111111111CZZZZZC111111111O..",
		"..O1111111111CZZZZZC111111111O..",
		"..O1111111111CZZZZZC111111111O..",
		"..O1111111111CZZZZZC111111111O..",
		"..O1111111111CDDDDDC111111111O..",
		"..O11111111111111111111111111O..",
		"..OOOOOOOOOOOOOOOOOOOOOOOOOOOO..",
	],
	"yoga_mat": [
		"..OOOOOOOOOOOO..",
		"..OLLLZZZZZLLO..",
		"..OLZZZZZZZZLO..",
		"..OZZZZZZZZZZO..",
		"..OZZZDDZZZZZO..",
		"..OZZZDDZZZZZO..",
		"..OZZZDDZZZZZO..",
		"..OZZZDDZZZZZO..",
		"..OZZZDDZZZZZO..",
		"..OZZZDDZZZZZO..",
		"..OZZZDDZZZZZO..",
		"..OZZZDDZZZZZO..",
		"..OZZZZZZZZZZO..",
		"..OZDDDDDDDDZO..",
		"..ODDDDDDDDDDO..",
		"..OOOOOOOOOOOO..",
	],
}

## 未知 equipment_id / zone 的兜底区域色（暖中性，避免与 Sage↔Rose 关键对撞色）。
const FALLBACK_ZONE := Color("C9A87C")

## 纹理缓存：key = "equipment_id|zone|rotation" -> ImageTexture。
## 每台设备按 (id, zone, rotation) 全量缓存 —— 运行时零重建（性能预算：纹理
## 建立一次，之后每帧仅 draw_texture_rect）。
var _cache: Dictionary = {}


## 取设备精灵纹理。R0 map 建立后按 rotation 旋转并缓存；zone 决定 Z/D/L 三个
## 语义色槽（art-bible §4 区域色系，单一来源 palette.ZONE_COLORS）。
## [equipment_id] 未知时返回 null（调用方兜底画剪影块，绝不崩溃）。
## [rotation] 非法时 push_error 并回退 R0。
func texture_for(equipment_id: String, zone: String, rotation: int) -> ImageTexture:
	var key := "%s|%s|%d" % [equipment_id, zone, rotation]
	if _cache.has(key):
		return _cache[key]
	if not ART_MAPS.has(equipment_id):
		push_error("EquipmentArt: no art map for '%s'" % equipment_id)
		return null
	var base := _build_r0_image(equipment_id, zone)
	var img := _rotate_to(base, rotation)
	var tex := ImageTexture.create_from_image(img)
	_cache[key] = tex
	return tex


## 返回 [equipment_id] 的 R0 map 尺寸（art px），未知返回 Vector2i.ZERO。
func art_size(equipment_id: String) -> Vector2i:
	if not ART_MAPS.has(equipment_id):
		return Vector2i.ZERO
	var rows: Array = ART_MAPS[equipment_id]
	if rows.is_empty():
		return Vector2i.ZERO
	return Vector2i(String(rows[0]).length(), rows.size())


## 返回该 map 在 CELL_SIZE 下的屏幕像素尺寸（art px × ART_SCALE）。
func texture_size(equipment_id: String) -> Vector2i:
	return art_size(equipment_id) * ART_SCALE


## 把 [base]（R0 图像）旋转到 [rotation] 度。rotate_90 会原地修改并交换宽高，
## 所以每次从 base 的 duplicate() 出发。非法 rotation push_error 后原样返回。
func _rotate_to(base: Image, rotation: int) -> Image:
	var img := base.duplicate()
	match rotation:
		0:
			pass
		90:
			img.rotate_90(0)  # CLOCKWISE
		180:
			img.rotate_90(0)
			img.rotate_90(0)
		270:
			img.rotate_90(0)
			img.rotate_90(0)
			img.rotate_90(0)
		_:
			push_error("EquipmentArt: illegal rotation %d — falling back to R0" % rotation)
	return img


## 建立 R0 图像：透明底 + 按 ART_SCALE 放大每个 art px。zone 名 → ZONE_COLORS
## 查色；未知 zone 用 FALLBACK_ZONE（兜底，不崩溃）。
func _build_r0_image(equipment_id: String, zone: String) -> Image:
	var rows: Array = ART_MAPS[equipment_id]
	var w: int = String(rows[0]).length()
	var h: int = rows.size()
	var img := Image.create(w * ART_SCALE, h * ART_SCALE, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var zone_color: Color = Palette.ZONE_COLORS.get(zone, FALLBACK_ZONE)
	var shade_dark: Color = zone_color.darkened(0.25)
	var shade_light: Color = zone_color.lightened(0.15)
	for y in h:
		var row: String = rows[y]
		for x in w:
			var ch := row[x]
			var color := _color_for(ch, zone_color, shade_dark, shade_light)
			if color.a <= 0.0:
				continue
			for py in ART_SCALE:
				for px in ART_SCALE:
					img.set_pixel(x * ART_SCALE + px, y * ART_SCALE + py, color)
	return img


## map 字符 → 实际颜色。透明 '.' 返回全透明。色值全部来自 palette.gd。
func _color_for(ch: String, zone: Color, dark: Color, light: Color) -> Color:
	match ch:
		".":
			return Color(0, 0, 0, 0)
		"O":
			return Palette.EQUIP_OUTLINE
		"C":
			return Palette.CHARCOAL
		"1":
			return Palette.EQUIP_BODY_DARK
		"2":
			return Palette.EQUIP_BODY
		"3":
			return Palette.EQUIP_BODY_LIGHT
		"M":
			return Palette.METAL_DARK
		"H":
			return Palette.METAL_HIGHLIGHT
		"W":
			return Palette.EQUIP_HIGHLIGHT
		"S":
			return Palette.EQUIP_SHADOW_TONE
		"A":
			return Palette.EQUIP_ACCENT_CYAN
		"Z":
			return zone
		"D":
			return dark
		"L":
			return light
		_:
			return Color(0, 0, 0, 0)
