## src/presentation/equipment_art.gd — 设备像素精灵程序化工厂（Phase B v2）
##
## 设备 = 2.5D 场景的「前景像素主体」：粗颗粒 2D 像素 sprite（32×32/cell 整数倍，
## Nearest filter，art-bible-25d-style §1/§2）。本工厂把每台设备的手工归纳像素
## 造型（字符串 map，8×8 art px per cell）放大到 CELL_SIZE 并产出 ImageTexture。
##
## 风格（art-bible-25d-style §2，全部可执行规范）：
##   - 像素主体：大色块 + 剪影识别第一优先级；轮廓略夸张；像素阶梯清晰，无抗锯齿
##   - 色彩：ZONE_COLORS 语义色（cardio→Sky / strength→Sage / flex→Peach）为主色，
##     Butter 只做 ~10% 锚点；金属 = 少量冷色高光（METAL_HIGHLIGHT，非纯白大面积）
##   - 描边：Soft Charcoal #3C3A42（§3 禁纯黑粗边）；阴影：脚下大暗面（EQUIP_SHADOW）
##   - 负面约束：无纯黑粗边、无照片纹理、无高饱和撞色、无插画式平滑
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

## Art map 每个 cell 的逻辑像素数（8×8），放大到 CELL_SIZE 后每个 art px = 4 屏 px。
const ART_PER_CELL := 8
const ART_SCALE := 4

## Map 图例：
##   . 透明 | O 描边(CHARCOAL) | Z 区域主色 | D 区域暗色 | L 区域亮色
##   M 金属暗面 | H 金属高光 | B Butter 锚点
##   C 青蓝 emissive 屏幕（V3 §6）| G 绿 emissive 屏幕（V3 §6）
##
## 造型 = 手工归纳的顶视角剪影（先剪影后补关键特征，§2）：
##   - treadmill 2×1：左侧 console（屏幕 H + 金属机身）+ 右侧立柱；履带两端滚轮
##   - bike 1×1：车把(H) + 飞轮(M) + 座椅(B)
##   - bench_press 2×2：杠铃片(M) 两端 + 杠 + 立柱 + 卧推凳(Z)
##   - yoga_mat 1×1：垫子卷边(L/D) + 垫面(Z)
const ART_MAPS := {
	# 跑步机（V3 §6：控制台青蓝 emissive 屏幕）：左侧 console（屏幕 C +
	# 金属机身）+ 右侧立柱；履带两端滚轮。
	"treadmill": [
		"OOOO..........OO",
		"OZCCHZO......OZHO",
		"OZCCZO.......OZZO",
		"OZMMZOO....OZZZO",
		"OOZZZZZZZZZZZZZO",
		".OZDDMMDDDDMMDZO",
		".OZDDDDDDDDDDDZO",
		"..OZZZZZZZZZZZZO",
	],
	# 自行车（V3 §6：显示屏绿色 emissive）：车把(H) + 飞轮(M) + 座椅(B)
	"bike": [
		"..OOOO..",
		".OZGGZO.",
		".OZMMZO.",
		"OZMMMMZO",
		"OZMMMMZO",
		"OZMMMMZO",
		".OZZZZO.",
		"..OBBO..",
	],
	"bench_press": [
		"OOOOO......OOOOO",
		"OMMMO......OMMMO",
		"OMMMO......OMMMO",
		"OMMMO......OMMMO",
		"OMMMOOOOOOOOMMMO",
		"OOOOOOOOOOOOOOOO",
		"..OO........OO..",
		"..OZ........ZO..",
		"..OZ........ZO..",
		"..OZOOOOOOOOZO..",
		"..OZOZZZZZZOZO..",
		"..OZOZZZZZZOZO..",
		"..OZOZZZZZZOZO..",
		"..OZOOOOOOOOZO..",
		"..OZ........ZO..",
		"..OOOO....OOOO..",
	],
	"yoga_mat": [
		"..OOOO..",
		".OZLLZO.",
		".OZDDZO.",
		"OZZZZZZO",
		"OZZZZZZO",
		"OZZZZZZO",
		"OZZZZZZO",
		".OOOOOO.",
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
			return Palette.CHARCOAL
		"Z":
			return zone
		"D":
			return dark
		"L":
			return light
		"M":
			return Palette.METAL_DARK
		"H":
			return Palette.METAL_HIGHLIGHT
		"B":
			return Palette.BUTTER
		"C":
			return Palette.EMISSIVE_CYAN
		"G":
			return Palette.EMISSIVE_GREEN
		_:
			return Color(0, 0, 0, 0)
