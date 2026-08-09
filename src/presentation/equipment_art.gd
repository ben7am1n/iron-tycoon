## src/presentation/equipment_art.gd — 设备像素精灵程序化工厂（V3 Phase 3 + V3.1 P2 真物体）
##
## 设备 = 小型场景物件（V3 §5，非图标）：V3.1 P2 起，每台设备是「真物体」——
## 3 个方向面（top/front/side）各自由手工归纳的像素造型（ASCII map）定义，
## 5 层颜色（base/shadow/outline/highlight/accent）+ contact shadow（由
## WorldCanvas 画贴地影）。跑步机有跑带/扶手/控制台/支撑柱；卧推有长凳厚度/
## 杠铃/杠铃片/架子；动感单车有飞轮/座椅/脚踏/把手 —— 部件可辨认，有体积感
## （V3.1 P2：设备离开地面，不贴地图）。
##
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
##   - V3.1 负面约束：无等宽边框（高光侧开放）、无重复规则纹理（履带 M2M 间隔、
##     框架 1313 错位）、设备不贴地图（有支撑柱/腿/架）
##
## 色值单一来源：src/palette.gd。本文件不出现任何硬编码色值。
##
## ROTATION CONVENTION（与 GridSystem 一致）：Rotation 用度数 0/90/180/270。
## R0 map 按设备 canonical footprint 绘制；R90/R180/R270 通过对 Image 做
## rotate_90(CLOCKWISE) 得到（与 GridSystem._transform_cell 的 R90 方向一致，
## 已验证：Image.rotate_90(CLOCKWISE) 把 (0,0) 移到 (W-1,0)）。
## V3.1 P2：front/side 面 map 按 R0 手工绘制；R90/R180/R270 走「从旋转后
## 顶面 art 切条带」的通用推导（与 P1 行为一致，保证任意朝向都有体积）。
##
## headless 可靠性：class_name 仅作编辑器便利，跨脚本引用一律走 preload alias
## （项目约定，见 src/main.gd 头部注释）。
class_name EquipmentArt extends RefCounted

const Palette := preload("res://src/palette.gd")
const Proj2D := preload("res://src/presentation/oblique_projection.gd")

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
## V3.1 P2：每台设备 = 手工归纳的 3 面场景物件（top = 顶面，front = 南面
## 面向相机，side = 东面）。部件在顶面/正面/侧面分别可辨：
##   - treadmill：顶面跑带 M2M 履带纹 + 两侧浅灰金属扶手（3）→ 前端控制台
##     （青蓝显示屏 A + 暖高光 W + 区域 accent 键 Z）；正面支撑柱/跑带前缘/
##     控制台显示屏；侧面滚轮/履带剖面/控制台立柱
##   - bike：顶面座椅（LLLZZLLL）→ 飞轮（M/H 金属盘 + 区域 accent 毂）→
##     车把 + 小显示屏（前，青蓝）；正面把手/立柱/飞轮前缘；侧面飞轮圆盘剖面
##   - bench_press：顶面杠铃 + 配重片（后/头端）→ 支架（浅灰金属）→
##     卧推凳（区域色 Sage 竖向条带，C 边 + L/D 高光阴影）；正面凳端厚度 +
##     凳腿；侧面杠铃片 + 支架 + 长凳厚度剖面
## 每面至少 5 色层：base(1/2/3/M)、shadow(S)、outline(O)、highlight(W/H)、
## accent(A/Z/D/L)。无等宽边框（V3.1 负面约束）—— 顶面高光侧（南/东）开放。
const ART_MAPS := {
	"treadmill": [
		"..OSSSSSSSSSSSSSSSSSSSSSSSSSSO..",
		"..O11111111111111111111111111O..",
		"..3O313131313131313131313131O3..",
		"..3O313131313131313131313131O3..",
		"..3O313131313131313131313131O3..",
		"..3O313131313131313131313131O3..",
		"..3O313131313131313131313131O3..",
		"..3O313131313131313131313131O3..",
		"..3O313131313131313131313131O3..",
		"..3O313131313131313131313131O3..",
		"..3O313131313131313131313131O3..",
		"..3O313131313131313131313131O3..",
		"..3O111111111111111111111111O3..",
		"..3W1WWWAAAZZZ1ZZZAAAAWWWW11O3..",
		"..3W1WWWAAAZZZ111ZZZAAAWWW11O3..",
		"..3O1111111111111111111111111O..",
	],
	"bike": [
		"..OSSSSSSSSSSO..",
		"..O1LLLZZLLL1O..",
		"..O1111111111O..",
		"..3W1MHHHHM1W3..",
		"..3W1MHZZZM1W3..",
		"..3W1MMHHMM1W3..",
		"..3W1MMSSMM1W3..",
		"..3W1MSSSSM1W3..",
		"..3O11111111O3..",
		"..3O13131313O3..",
		"..3O1M3131M1O3..",
		"..3O1H1M31M1H3..",
		"..3O1HAAAWW1H3..",
		"..3O11111111O3..",
		"..O1111111111O..",
		"..3O11111111O3..",
	],
	"bench_press": [
		"..OSSSSSSSSSSSSSSSSSSSSSSSSSSO..",
		"..OMHHHHMMMMMMMMMMMMMMMMHHHHMO..",
		"..OMHHHHMMMMMMMMMMMMMMMMHHHHMO..",
		"..OMSSSSMMMMMMMMMMMMMMMMSSSSMO..",
		"..OSMMMMMMMMMMMMMMMMMMMMMMMMSO..",
		"..OSMMMMMMMMMMMMMMMMMMMMMMMMSO..",
		"..OMSSSSMMMMMMMMMMMMMMMMSSSSMO..",
		"..OMHHHHMMMMMMMMMMMMMMMMHHHHMO..",
		"..OSMMMMMMMMMMMMMMMMMMMMMMMMSO..",
		"..O3333O1111111111111111O3333O..",
		"..O3333O1111111111111111O3333O..",
		"..O11111111111111111111111111O..",
		"..O11CWLLLLLLLLLLLLLLLLLLLL11O..",
		"..O11CZZZZZZZZZZZZZZZZZZZZZ11O..",
		"..O11CZZZZZZZZZZZZZZZZZZZZZ11O..",
		"..O11CZZZZZZZZZZZZZZZZZZZZZ11O..",
		"..O11CZZZZDZZZZZZZZZZZZZZZZ11O..",
		"..O11CZZZZZZZZZZZZZZZZZZZZZ11O..",
		"..O11CZZZZZZZZZZZZZZZZZZZZZ11O..",
		"..O11CZZZZZZZZZZZZZZZZZZZZZ11O..",
		"..O11CZZZZDZZZZZZZZZZZZZZZZ11O..",
		"..O11CZZZZZZZZZZZZZZZZZZZZZ11O..",
		"..O11CZZZZZZZZZZZZZZZZZZZZZ11O..",
		"..O11CZZZZZZZZZZZZZZZZZZZZZ11O..",
		"..O11CZZZZDZZZZZZZZZZZZZZZZ11O..",
		"..O11CZZZZZZZZZZZZZZZZZZZZZ11O..",
		"..O11CZZZZZZZZZZZZZZZZZZZZZ11O..",
		"..O11CZZZZZZZZZZZZZZZZZZZZZ11O..",
		"..O11CZZZZZZZZZZZZZZZZZZZZZ11O..",
		"..O11CDDDDDDDDDDDDDDDDDDDDD11O..",
		"..O11111111111111111111111111O..",
		"..O11111111111111111111111111O..",
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

## V3.1 P2：手绘 front/side 面 map（art px）。front 宽 = footprint x 尺寸，
## side 宽 = footprint y 尺寸；行序 = 地面（row 0）→ 机器顶部（最后一行）。
## 与顶面（ART_MAPS）一起构成 3 方向面（top/front/side）+ 5 色层。
## 只有 R0 使用手绘面；非 R0 旋转走通用条带推导（见 extrusion_faces_for）。
const FACE_MAPS := {
	"treadmill": {
		"front": [
			"..3O1SSSSSSSSSSSSSSSSSSSSSS1O3..",
			"..3O1SSSSSSSSSSSSSSSSSSSSSS1O3..",
			"..3O111111111111111111111111O3..",
			"..33O1111111111111111111111O33..",
			"..33O1M2M2M2M2M2M2M2M2M2M2MO33..",
			"..33O1M2M2M2M2M2M2M2M2M2M2MO33..",
			"..33O1111111111111111111111O33..",
			"..33O1WWWAAAASSSSSAAAAWWW11O33..",
			"..33O1WWWAAASSSSSSAAAWWW111O33..",
		],
		"side": [
			"..OSSSSSSSSSSO..",
			"..O1111111111O..",
			"..O1M2M2M2M21O..",
			"..O1M2M2M2M21O..",
			"..O1111111111O..",
			"..3O111111111O..",
			"..3O1WWWAWWW1O..",
			"..3O1SSSSSSSSO..",
			"..3O1SSSSSSSSO..",
		],
	},
	"bike": {
		"front": [
			"..3O1HAAAWW1H3..",
			"..3O11111111O3..",
			"..3O1SSSSSSSO3..",
			"..3O1SSSSSSSO3..",
			"..3O11111111O3..",
			"..3O1MHHHHM1O3..",
			"..3O1MHZZZM1O3..",
			"..3O1MMSSMM1O3..",
			"..3O11111111O3..",
			"..3OSSSSSSSSO3..",
			"..3O11111111O3..",
		],
		"side": [
			"..OSSSSSSSSSSO..",
			"..O1LLLZZLLL1O..",
			"..O1111111111O..",
			"..3O1MHHHHM1O3..",
			"..3O1MHZZZM1O3..",
			"..3O1MHHHHM1O3..",
			"..3O1MMSSMM1O3..",
			"..3O11111111O3..",
			"..3O1SSSSSSSO3..",
			"..3O1SSSSSSSO3..",
			"..3O11111111O3..",
		],
	},
	"bench_press": {
		"front": [
			"..3O11W111111111111111111111O3..",
			"..3O11CDDDDDDDDDDDDDDDDDDD11O3..",
			"..33O11CZZZZZZZZZZZZZZZZZ11O33..",
			"..33O11CZZZZZZZZZZZZZZZZZ11O33..",
			"..33O1111111111111111111111O33..",
			"..33O1SSSSSSSSSSSSSSSSSSSSSO33..",
			"..3O1SSSSSSSSSSSSSSSSSSSSSS1O3..",
			"..3O1SSSSSSSSSSSSSSSSSSSSSS1O3..",
		],
		"side": [
			"..OMHHHHMMMMMMMMMMMMMMMMMMMMMO..",
			"..OMSSSSMMMMMMMMMMMMMMMMMMMMMO..",
			"..OSMMMMMMMMMMMMMMMMMMMMMMMMMO..",
			"..O3333O111111111111111111111O..",
			"..O1111O11CZZZZZZZZZZZZZZZZZ1O..",
			"..O1111O11CZZZZZZZZZZZZZZZZZ1O..",
			"..O1111O11CDDDDDDDDDDDDDDDDD1O..",
			"..O11111111111111111111111111O..",
		],
	},
}

## 未知 equipment_id / zone 的兜底区域色（暖中性，避免与 Sage↔Rose 关键对撞色）。
const FALLBACK_ZONE := Color("C9A87C")

## 纹理缓存：key = "equipment_id|zone|rotation" -> ImageTexture。
## 每台设备按 (id, zone, rotation) 全量缓存 —— 运行时零重建（性能预算：纹理
## 建立一次，之后每帧仅 draw_texture_rect）。
var _cache: Dictionary = {}


## 取设备精灵纹理（顶面）。R0 map 建立后按 rotation 旋转并缓存；zone 决定
## Z/D/L 三个语义色槽（art-bible §4 区域色系，单一来源 palette.ZONE_COLORS）。
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


# === V3.1 P1/P2：体积挤出（顶面 + 正面 + 侧面） ===

## 设备挤出高度（世界 px，V3.1 P1 斜俯视的体积表达）。数据驱动常量，
## 绘制层与 USING 会员站立高度共用。
const EQUIP_HEIGHTS := {
	"treadmill": 30.0,
	"bike": 36.0,
	"bench_press": 26.0,
	"yoga_mat": 6.0,
}
const DEFAULT_EQUIP_HEIGHT := 24.0

## 挤出面高度系数（与 oblique_projection.HEIGHT_SCALE 同值 —— 纹理裁剪
## 高度 = height × 系数，WorldCanvas 用同一系数绘制面四边形）。
## V3.1 R1：改为引用 Proj2D.HEIGHT_SCALE（单一来源，随投影修正 0.62→0.79）。
const FACE_HEIGHT_SCALE := Proj2D.HEIGHT_SCALE

## 挤出面纹理缓存：key = "eq|zone|rot|face_h" → {"front": tex, "side": tex}。
var _face_cache: Dictionary = {}

## 设备挤出高度（世界 px）。未知 id 用默认（绝不崩溃）。
func height_for(equipment_id: String) -> float:
	return float(EQUIP_HEIGHTS.get(equipment_id, DEFAULT_EQUIP_HEIGHT))


## V3.1 P2：挤出面纹理（缓存）。返回 {"front": ImageTexture, "side":
## ImageTexture}：
##   - R0 且 FACE_MAPS 有该设备 → 手绘 front/side 面（真物体部件可辨，
##     V3.1 P2 最低要求：3 方向面 + 5 色层）
##   - 其他情况 → 从旋转后顶面 art 切条带（南边条带变暗 = 正面、东边条带
##     变暗旋转 90° = 侧面；与 P1 行为一致，保证任意朝向都有体积）
## 变暗方向：正面中调（EQUIP_BODY 混合）、侧面暗调（EQUIP_SHADOW_TONE 混合）
## —— 顶面亮、正面中、侧面暗，三面分层（V3.1 P1 证据：多层高度色）。
## 未知设备返回空字典（调用方画实色面兜底，绝不崩溃）。
func extrusion_faces_for(equipment_id: String, zone: String, rotation: int,
		height: float) -> Dictionary:
	var face_h := maxi(2, int(round(height * FACE_HEIGHT_SCALE)))
	var key := "%s|%s|%d|%d" % [equipment_id, zone, rotation, face_h]
	if _face_cache.has(key):
		return _face_cache[key]
	var result := {"front": null, "side": null}
	# V3.1 P2：R0 手绘面优先（真物体部件）
	if rotation == 0 and FACE_MAPS.has(equipment_id):
		result = _authored_faces_for(equipment_id, zone, height, face_h)
		if result["front"] != null:
			_face_cache[key] = result
			return result
	# 通用条带推导（非 R0 旋转 / 无手绘面的设备 / 兜底）
	var tex := texture_for(equipment_id, zone, rotation)
	if tex == null:
		return result
	var img := tex.get_image()
	var w := img.get_width()
	var h := img.get_height()
	if w <= 0 or h <= 0:
		return result
	var face_h_use := mini(face_h, h)
	# 正面：底部 face_h 行（南边条带）→ 中调变暗
	var front := Image.create(w, face_h_use, false, Image.FORMAT_RGBA8)
	front.blit_rect(img, Rect2i(0, h - face_h_use, w, face_h_use), Vector2i.ZERO)
	_darken_image(front, Palette.EQUIP_BODY.darkened(0.2), 0.5)
	# 侧面：右侧 face_h 列（东边条带）→ 旋转 90°（沿深度铺开）→ 暗调变暗
	var side_cols := mini(face_h_use, w)
	var side := Image.create(side_cols, h, false, Image.FORMAT_RGBA8)
	side.blit_rect(img, Rect2i(w - side_cols, 0, side_cols, h), Vector2i.ZERO)
	side.rotate_90(1)  # 逆时针 → (h × side_cols) = (深度 × 面高)
	_darken_image(side, Palette.EQUIP_SHADOW_TONE, 0.6)
	result["front"] = ImageTexture.create_from_image(front)
	result["side"] = ImageTexture.create_from_image(side)
	_face_cache[key] = result
	return result


## V3.1 P2：从 FACE_MAPS 建立手绘 front/side 面纹理（art px → ART_SCALE）。
## front 宽 = footprint x（ART_MAPS 同宽），side 宽 = footprint y（ART_MAPS
## 行数）；高 = 面高 art px（face_h / ART_SCALE，至少 2 行）。应用与通用
## 推导一致的变暗（正面中调 / 侧面暗调），保证三面分层一致。
func _authored_faces_for(equipment_id: String, zone: String, height: float,
		face_h: int) -> Dictionary:
	var result := {"front": null, "side": null}
	var face: Dictionary = FACE_MAPS[equipment_id]
	var front_rows: Array = face.get("front", [])
	var side_rows: Array = face.get("side", [])
	var zone_color: Color = Palette.ZONE_COLORS.get(zone, FALLBACK_ZONE)
	var shade_dark: Color = zone_color.darkened(0.25)
	var shade_light: Color = zone_color.lightened(0.15)
	if not front_rows.is_empty():
		var img := _build_face_image(front_rows, zone_color, shade_dark, shade_light)
		if img != null:
			_darken_image(img, Palette.EQUIP_BODY.darkened(0.2), 0.35)
			result["front"] = ImageTexture.create_from_image(img)
	if not side_rows.is_empty():
		var img := _build_face_image(side_rows, zone_color, shade_dark, shade_light)
		if img != null:
			_darken_image(img, Palette.EQUIP_SHADOW_TONE, 0.5)
			result["side"] = ImageTexture.create_from_image(img)
	return result


## V3.1 P2：取手绘面 map（未变暗）原始图像。返回 {"front": Image, "side":
## Image}；无手绘面/未知设备返回空字典（不崩溃）。证据脚本/单元测试用它
## 精确验证 5 色层（base/shadow/outline/highlight/accent 不受变暗混合污染）。
func raw_face_images(equipment_id: String, zone: String) -> Dictionary:
	var result := {"front": null, "side": null}
	if not FACE_MAPS.has(equipment_id):
		return result
	var face: Dictionary = FACE_MAPS[equipment_id]
	var zone_color: Color = Palette.ZONE_COLORS.get(zone, FALLBACK_ZONE)
	var shade_dark: Color = zone_color.darkened(0.25)
	var shade_light: Color = zone_color.lightened(0.15)
	if face.has("front") and not (face["front"] as Array).is_empty():
		result["front"] = _build_face_image(face["front"], zone_color, shade_dark, shade_light)
	if face.has("side") and not (face["side"] as Array).is_empty():
		result["side"] = _build_face_image(face["side"], zone_color, shade_dark, shade_light)
	return result


## 从字符串行建立面图像（ART_SCALE 放大，透明底）。行宽不齐时按最长行
## 右补透明（防御性，不崩溃）。zone 语义色槽与顶面共用。
func _build_face_image(rows: Array, zone: Color, dark: Color, light: Color) -> Image:
	var w: int = 0
	for r in rows:
		w = maxi(w, String(r).length())
	if w <= 0 or rows.is_empty():
		return null
	var h: int = rows.size()
	var img := Image.create(w * ART_SCALE, h * ART_SCALE, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	for y in h:
		var row: String = String(rows[y])
		for x in w:
			var ch := row[x] if x < row.length() else "."
			var color := _color_for(ch, zone, dark, light)
			if color.a <= 0.0:
				continue
			for py in ART_SCALE:
				for px in ART_SCALE:
					img.set_pixel(x * ART_SCALE + px, y * ART_SCALE + py, color)
	return img


## 整图向 [target] 混合 [amount]（保留 alpha；透明像素跳过）。
func _darken_image(img: Image, target: Color, amount: float) -> void:
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			if c.a <= 0.0:
				continue
			img.set_pixel(x, y, c.lerp(target, amount))


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
