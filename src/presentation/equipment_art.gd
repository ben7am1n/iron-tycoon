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
	"bike": [
		"..OOSSSSSSSSOO..",
		"..O2222222222O..",
		"..O22L1ZZ1L22O..",
		"..O22L1ZZ1L22O..",
		"..O2222MM2222O..",
		"..O211HHHH112O..",
		"..O211HZZH112O..",
		"..O211HZZH112O..",
		"..O211HZZH112O..",
		"..O211HHHH112O..",
		"..O2222222222O..",
		"..O2M1111M222O..",
		"..O2WWDDDDWW2O..",
		"..O2WAAA11WW2O..",
		"..O1111111111O..",
		"..O1111111111O..",
	],
	"treadmill": [
		"..OOSSSSSSSSSSSSSSSSSSSSSSSSOO..",
		"..OOSSSSSSSSSSSSSSSSSSSSSSSSOO..",
		"..OO111111111111111111111111OO..",
		"..3O222222222222222222222222O3..",
		"..3HH2222222222222222222222HH3..",
		"..3HH2M2M2M2M2M2M2M2M2M2M2MHH3..",
		"..3HH12M2M2M2M2M2M2M2M2M2M2HH3..",
		"..3HH2M2S2M2S2M2S2M2S2M2S2MHH3..",
		"..3HH2M2M2M2M2M2M2M2M2M2M2MHH3..",
		"..3HH12M2S2M2S2M2S2M2S2M2S2HH3..",
		"..3O222222222222222222222222O3..",
		"..3O222222222222222222222222O3..",
		"..3O1HWWAAA1ZZZ1ZZZAAAWW1H1WW3..",
		"..3W1HDDAAA1ZZZ111ZZZAAAD1H1W3..",
		"..3O1H11111111111111111111H1O3..",
		"..O11111111111111111111111111O..",
	],
	"bench_press": [
		"..OSSSSSSSSSSSSSSSSSSSSSSSSSSO..",
		"..OMHHHHHHMMMMMMMMMMMMHHHHHHMO..",
		"..OMHHHHHHMMMMMMMMMMMMHHHHHHMO..",
		"..OMSSSSSMMMMMMMMMMMMMMSSSSSMO..",
		"..OSMMMMMMMMMMMMMMMMMMMMMMMMSO..",
		"..OSMMMMMMMMMMMMMMMMMMMMMMMMSO..",
		"..OMSSSSSMMMMMMMMMMMMMMSSSSSMO..",
		"..OMHHHHHMMMMMMMMMMMMMMHHHHHMO..",
		"..OSMMMMMMMMMMMMMMMMMMMMMMMMSO..",
		"..O3333O1111111111111111O3333O..",
		"..O3333O1111111111111111O3333O..",
		"..O11111111111111111111111111O..",
		"..O11CLLLLLLLLLLLLLLLLLLLL11O...",
		"..O11CLZZZZZZZZZZZZZZZZZZL11O...",
		"..O11CLZZZZZZZZZZZZZZZZZZL11O...",
		"..O11CLZZZZDZZZZZZZZDZZZZL11O...",
		"..O11CLZZZZZZZZZZZZZZZZZZL11O...",
		"..O11CLZZZZDZZZZZZZZDZZZZL11O...",
		"..O11CLZZZZZZZZZZZZZZZZZZL11O...",
		"..O11CLZZZZDZZZZZZZZDZZZZL11O...",
		"..O11CLZZZZZZZZZZZZZZZZZZL11O...",
		"..O11CLZZZZDZZZZZZZZDZZZZL11O...",
		"..O11CLZZZZZZZZZZZZZZZZZZL11O...",
		"..O11CLZZZZDZZZZZZZZDZZZZL11O...",
		"..O11CLZZZZZZZZZZZZZZZZZZL11O...",
		"..O11CLZZZZDZZZZZZZZDZZZZL11O...",
		"..O11CLZZZZZZZZZZZZZZZZZZL11O...",
		"..O11CDDDDDDDDDDDDDDDDDDDD11O...",
		"..O11111111111111111111111111O..",
		"..O11111111111111111111111111O..",
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

const FACE_MAPS := {
	"bike": {
		"front": [
			"..O1111111111O..",
			"..3O11111111O3..",
			"..3O1M1111M1O3..",
			"..3O11HHHH11O3..",
			"..3O11HZZH11O3..",
			"..3O11HZZH11O3..",
			"..3O11HZZH11O3..",
			"..3O11HHHH11O3..",
			"..3O11H1111HO3..",
			"..3O1HAAWW1HO3..",
			"..3OWWDDDDWWO3..",
			"..3OWDD11DDWO3..",
		],
		"side": [
			"..O1111111111O..",
			"..O11L1ZZ1L11O..",
			"..O1111111111O..",
			"..O111HHHH111O..",
			"..O11HZZZZH11O..",
			"..O11HZZZZH11O..",
			"..O11HZZZZH11O..",
			"..O111HHHH111O..",
			"..O1MM1111MM1O..",
			"..O1111111111O..",
		],
	},
	"treadmill": {
		"front": [
			"..O11111111111111111111111111O..",
			"...33O12222222222222222221O33...",
			"....33O1M2M2M2M2M2M2M2M21O33....",
			"...33O1M2SM2SM2SM2SM2SM21O33....",
			"...33O12M2M2M2M2M2M2M2M2M1O33...",
			"...33O12222222222222222221O33...",
			"..33O1H111111111111111111H1O33..",
			"..3W1HDDAAA1ZZZ111ZZZAAAD1H1W3..",
			"..3O1HWWAAA1ZZZ1ZZZAAAWW1H1O3...",
		],
		"side": [
			"..OSSSSSSSSSSO..",
			"..O2222222222O..",
			"..3O22222222O3..",
			"..3O1M2M2M21O3..",
			"..3O12M2M2M1O3..",
			"..3O1M2S2M21O3..",
			"..3O12222222O3..",
			"..3O11H11H11O3..",
			"..3O1HAAWW11O3..",
			"..3O1HDD1111O3..",
		],
	},
	"bench_press": {
		"front": [
			"..3O111111111111111111111111O3..",
			"..33O1111111111111111111111O33..",
			"..33O11CDDDDDDDDDDDDDDDD11O33...",
			"..33O11CZZZZZZZZZZZZZZZZ11O33...",
			"..33O11CZZZZZZZZZZZZZZZZ11O33...",
			"..33O11CZZZZZZZZZZZZZZZZ11O33...",
			"..3O11CLLLLLLLLLLLLLLLLLL11O3...",
			"..3O11W11111111111111111111O3...",
		],
		"side": [
			"..O11111111111111111111111111O..",
			"....O1111O11CDDDDDDDDDDDD1O.....",
			"....O1111O11CZZZZZZZZZZZZ1O.....",
			"....O1111O11CZZZZZZZZZZZZ1O.....",
			"....O3333O1111111111111111O.....",
			"..OSMMMMMMMMMMMMMMMMMMMMMMMMSO..",
			"....OMSSSSSSMMMMMMMMMMMMMMMO....",
			"....OMHHHHHHMMMMMMMMMMMMMMMO....",
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
	# 正面：底部 face_h 行（南边条带）→ 中调变暗（返工4 P2：中性-only）
	var front := Image.create(w, face_h_use, false, Image.FORMAT_RGBA8)
	front.blit_rect(img, Rect2i(0, h - face_h_use, w, face_h_use), Vector2i.ZERO)
	_darken_neutral(front, Palette.EQUIP_SHADOW_TONE, 0.35)
	_apply_silhouette_outline(front)
	_apply_top_edge_band(front, 1)
	_apply_grounding_line(front)
	# 侧面：右侧 face_h 列（东边条带）→ 旋转 90°（沿深度铺开）→ 暗调变暗
	var side_cols := mini(face_h_use, w)
	var side := Image.create(side_cols, h, false, Image.FORMAT_RGBA8)
	side.blit_rect(img, Rect2i(w - side_cols, 0, side_cols, h), Vector2i.ZERO)
	side.rotate_90(1)  # 逆时针 → (h × side_cols) = (深度 × 面高)
	_darken_neutral(side, Palette.EQUIP_SHADOW_TONE, 0.65)
	_apply_silhouette_outline(side)
	_apply_top_edge_band(side, 1)
	_apply_grounding_line(side)
	result["front"] = ImageTexture.create_from_image(front)
	result["side"] = ImageTexture.create_from_image(side)
	_face_cache[key] = result
	return result


## V3.1 P2：从 FACE_MAPS 建立手绘 front/side 面纹理（art px → ART_SCALE）。
## front 宽 = footprint x（ART_MAPS 同宽），side 宽 = footprint y（ART_MAPS
## 行数）；高 = 面高 art px（face_h / ART_SCALE，至少 2 行）。应用与通用
## 推导一致的变暗（正面中调 / 侧面暗调），保证三面分层一致。
## 返工4 P1（FAIL1/弱项#5）：变暗后追加手绘后处理 —— 外轮廓深一档勾边 +
## 底部接地线（设备从背景中勾出 + 底部与地面分离；只作用于渲染路径，
## raw_face_images 不受污染 —— 单元测试 5 色层断言保持）。
## 返工5 P1（FAIL2 三阶手绘分色）：正面/侧面暗化拉大分离 —— 顶面受光
## （不暗化）、正面中调（0.55）、侧面暗调（0.75）：三面明度台阶清晰可辨
## （旧 0.60/0.65 差过小，正面/侧面读作同一平涂面）。仍中性-only，
## 高光/accent 保留（零部件可辨）。
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
			# 返工4 P2：中性-only 压暗（正面中调：亮顶面 vs 正面 vs 暗侧面三层
			# 分离，方向与 P3 灯光同侧 —— 顶面受光最亮，正面中，侧面最暗）
			_darken_neutral(img, Palette.EQUIP_SHADOW_TONE, 0.55)
			# 返工4 P2：zone 色 accent（Z/L/D）在正面压一档 —— 顶面受光最亮 /
			# 正面中调（凳面、飞轮毂、控制台底座在 2x 下与顶面有明度台阶，不再
			# 扁平同色）。A 屏幕与 W/H 高光保持全亮（屏幕是全场景高饱和焦点）。
			_darken_zone_accents(img, zone_color, 0.22)
			_apply_silhouette_outline(img)
			_apply_top_edge_band(img, 1)
			_apply_grounding_line(img)
			result["front"] = ImageTexture.create_from_image(img)
	if not side_rows.is_empty():
		var img := _build_face_image(side_rows, zone_color, shade_dark, shade_light)
		if img != null:
			# 返工4 P2：中性-only 压暗（侧面暗调，比正面再暗一档）+ 受光边
			# 返工5 P1：0.65→0.75 —— 侧面/正面明度台阶拉开（三阶分色）
			_darken_neutral(img, Palette.EQUIP_SHADOW_TONE, 0.75)
			# 侧面 zone 色 accent（Z/L/D）压一档 —— 三层分离中侧面最暗
			_darken_zone_accents(img, zone_color, 0.32)
			_apply_silhouette_outline(img)
			_apply_top_edge_band(img, 1)
			_apply_grounding_line(img)
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


## 返工4 P2（FAIL2 三面色阶）：只压暗「中性机身材质」，保留 accent
## （A/Z/D/L —— 控制台屏幕青蓝、区域语义色座椅/凳面）在暗面依旧鲜亮。
## 正面/侧面整面压暗会同时压暗屏幕与座椅，2x 下关键零部件读不出来；
## 中性-only 压暗让「顶面亮 / 正面中 / 侧面暗」的三层分离由材质承载，
## 而屏幕/座椅/飞轮毂的高饱和 accent 在暗面上依旧可辨（FAIL3 零部件）。
func _darken_neutral(img: Image, target: Color, amount: float) -> void:
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			# 高光（W/H）与 accent（A/Z/D/L）都不压暗：高光侧开放（V3 §11），
			# 关键零部件在 2x 保持鲜亮（返工4 P2 FAIL3）。
			if c.a <= 0.0 or not _is_neutral_tone(c) or _is_highlight_tone(c):
				continue
			img.set_pixel(x, y, c.lerp(target, amount))


## 正面 zone 色 accent 压暗（Z/D/L —— 区域语义色及其明暗面）：朝向相机的
## 大块 zone 色在正面压一档（顶面亮 / 正面中调分离）。A 屏幕、W/H 高光不
## 属于 zone 色族（距 zone 色 > 0.10），保持全亮。
func _darken_zone_accents(img: Image, zone_color: Color, amount: float) -> void:
	var variants: Array[Color] = [zone_color, zone_color.lightened(0.15), zone_color.darkened(0.25)]
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			# W/H 高光与 zone 色族在明度上接近（METAL_HIGHLIGHT B7D4EC 距
			# zone.lightened 0.10 内）—— 必须先排除高光，只压 zone 色（Z/D/L）。
			if c.a <= 0.0 or _is_highlight_tone(c):
				continue
			var is_zone := false
			for v in variants:
				if _color_distance(c, v) <= 0.10:
					is_zone = true
					break
			if is_zone:
				img.set_pixel(x, y, c.lerp(Palette.EQUIP_SHADOW_TONE, amount))


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


## 确定性 hash（同 floor_art._hash2 —— 无 RNG 状态，headless 可测、bit-identical）。
func _hash2(x: int, y: int) -> int:
	var h := x * 374761393 + y * 668265263
	h = (h ^ (h >> 13)) * 1274126177
	return h & 0x7fffffff


## 颜色距离（RGB 欧氏，同 unit test helper —— 后处理判定用）。
func _color_distance(a: Color, b: Color) -> float:
	var dr := a.r - b.r
	var dg := a.g - b.g
	var db := a.b - b.b
	return sqrt(dr * dr + dg * dg + db * db)


## 像素是否属于「中性机身材质」色族（jitter 只在这些之间混合 ——
## 不触碰 accent A/Z/D/L：区域语义色与屏幕青蓝保持清晰可辨，V3 §14）。
func _is_neutral_tone(c: Color) -> bool:
	for t in [
		Palette.EQUIP_BODY_DARK, Palette.EQUIP_BODY, Palette.EQUIP_BODY_LIGHT,
		Palette.METAL_DARK, Palette.METAL_HIGHLIGHT, Palette.EQUIP_HIGHLIGHT,
		Palette.EQUIP_SHADOW_TONE, Palette.EQUIP_OUTLINE, Palette.EQUIP_EDGE_OUTLINE,
	]:
		if _color_distance(c, t) <= 0.10:
			return true
	return false


## 像素是否高光色族（W/H —— 轮廓勾边跳过，高光侧开放，V3 §11）。
func _is_highlight_tone(c: Color) -> bool:
	return _color_distance(c, Palette.EQUIP_HIGHLIGHT) <= 0.12 \
		or _color_distance(c, Palette.METAL_HIGHLIGHT) <= 0.12


## 像素是否 accent 色族（A/Z/D/L —— 屏幕青蓝 / 区域语义色 / 语义色明暗面）。
## 返工4 P2：轮廓勾边与面压暗都跳过 accent —— 控制台屏幕、座椅、飞轮毂、
## 凳面在 2x 下保持鲜亮可辨（FAIL3 零部件；V3 §14 可购买设备饱和度高的
## 可读性要求）。判定 = 青蓝显示灯 或 高饱和（zone 色系 Sky/Peach 等
## sat>0.30；中性机身材质全系 sat≤0.22，不会误判）。
func _is_accent_tone(c: Color) -> bool:
	return _color_distance(c, Palette.EQUIP_ACCENT_CYAN) <= 0.12 or c.s > 0.30


## 像素是否与透明相邻（精灵外轮廓边界）。
func _is_silhouette_boundary(img: Image, x: int, y: int) -> bool:
	if x <= 0 or y <= 0 or x >= img.get_width() - 1 or y >= img.get_height() - 1:
		return true
	for n in [[x - 1, y], [x + 1, y], [x, y - 1], [x, y + 1]]:
		if img.get_pixel(n[0], n[1]).a <= 0.5:
			return true
	return false


## 返工4 P1（FAIL2 色阶分层 · 手绘质感核心）+ 返工5 P1（FAIL2 三阶手绘
## 分色强化）：手绘式色阶抖动 —— 在相邻「中性机身材质」色阶边界（色距
## > 0.10）撒 ~30% 像素向邻阶混合 45-75%（返工5 P1：15%→30%、30-50%→
## 45-75% —— 层间过渡读作更强的手绘抖动/笔触断裂，不再像程序色块）。
## 返工5 P1 新增：~1/5 混合像素完全切到邻阶色（hard swap，笔触断裂），
## ~1/2 混合像素带动 2×2 相邻像素一起向同目标混合（手绘笔触簇）——
## 亮/中/暗面过渡呈锯齿手绘感而非程序渐变/完美直线（V3.1 负面约束：
## 无完美直线、无程序色块）。只混合中性材质（BODY/METAL/HIGHLIGHT/
## SHADOW/OUTLINE 族），不触碰 accent（A/Z/D/L —— 区域语义色与屏幕青蓝
## 保持清晰可辨）。确定性 hash 驱动（同输入同输出）。
func _apply_hand_drawn_jitter(img: Image) -> void:
	var w := img.get_width()
	var h := img.get_height()
	for y in h:
		for x in w:
			var c := img.get_pixel(x, y)
			if c.a <= 0.5 or not _is_neutral_tone(c):
				continue
			# 找 4 邻域中色距最大的中性色（色阶边界）
			var best: Color = c
			var best_d := 0.0
			for n in [[x - 1, y], [x + 1, y], [x, y - 1], [x, y + 1]]:
				if n[0] < 0 or n[1] < 0 or n[0] >= w or n[1] >= h:
					continue
				var nc := img.get_pixel(n[0], n[1])
				if nc.a <= 0.5 or not _is_neutral_tone(nc):
					continue
				var d := _color_distance(c, nc)
				if d > best_d:
					best_d = d
					best = nc
			if best_d < 0.10:
				continue
			var hsh := _hash2(x * 7 + 3, y * 13 + 1)
			if hsh % 100 >= 30:
				continue
			if hsh % 5 == 0:
				# 笔触断裂：完全切到邻阶色（硬台阶，非平滑混合）
				img.set_pixel(x, y, best)
			else:
				var amt := 0.45 + float((hsh >> 8) % 31) / 100.0  # 45-75%
				img.set_pixel(x, y, c.lerp(best, amt))
			# 2×2 手绘笔触簇：邻像素向同目标低量混合（刷痕感）
			if hsh % 2 == 0 and x + 1 < w:
				var rc := img.get_pixel(x + 1, y)
				if rc.a > 0.5 and _is_neutral_tone(rc):
					var sub := 0.25 + float((hsh >> 12) % 26) / 100.0
					img.set_pixel(x + 1, y, rc.lerp(best, sub))


## 返工4 P1（FAIL1 轮廓勾边）+ 返工4 P2（FAIL1 轮廓连续性）+ 返工5 P1
## （FAIL1 完整深色外轮廓库）：外轮廓深一档勾边 —— 与透明相邻的「全部」
## 边界像素向 EQUIP_EDGE_OUTLINE 混合（lum≈50，比 EQUIP_OUTLINE 67.5 再暗
## 一档；vs 深灰力量区地面 78.7 明度差 ~29 ≥ 25，2x 缩放下主体从背景中
## 「剪」出）。返工5 P1 要点：
##   1. 已 outline 像素（EQUIP_OUTLINE）在边界处也继续压深一档 —— 旧实现
##      跳过 O 像素使外围 rim 停在 EQUIP_OUTLINE（Δlum≈11，主体融进地面）；
##      现在 rim 整体读 EDGE_OUTLINE（Δlum≈29）。单元测试断言的是「纹理中
##      存在 EQUIP_OUTLINE」—— 内部 O 像素（非 silhouette boundary）保留。
##   2. 手绘缺口 12% → ~2%（逐像素闭合轮廓，仅保留极少量断口 → 非等宽边框）。
##   3. 混合 65-95% → 88-100%（近全深，不再半透偏浅）。
##   4. 新增第二圈：紧贴轮廓内侧的像素 ~40% 半压深（35-55%）→ 外轮廓
##      1-2px 交替（2x 缩放下仍可辨，手绘宽度变化，非等宽边框）。
## 高光（W/H）与 accent（A/Z/D/L）像素保留 —— 高光侧开放（V3 §11）、
## 区域语义色可辨（FAIL3 零部件）。
func _apply_silhouette_outline(img: Image) -> void:
	var w := img.get_width()
	var h := img.get_height()
	# 第一圈：逐像素闭合外轮廓（silhouette boundary）
	for y in h:
		for x in w:
			var c := img.get_pixel(x, y)
			if c.a <= 0.5:
				continue
			if _is_highlight_tone(c):
				continue  # 高光侧开放，不全勾（V3 §11）
			if _is_accent_tone(c):
				continue  # 屏幕青蓝 / 区域语义色保持鲜亮（FAIL3 零部件可辨）
			if not _is_silhouette_boundary(img, x, y):
				continue
			var hsh := _hash2(x * 3 + 7, y * 5 + 9)
			if hsh % 100 < 2:
				continue  # 手绘缺口 ~2% —— 近闭合（非等宽边框）
			var amt := 0.88 + float((hsh >> 8) % 13) / 100.0  # 88-100%
			img.set_pixel(x, y, c.lerp(Palette.EQUIP_EDGE_OUTLINE, amt))
	# 第二圈：轮廓内侧 1px 半压深（宽度 1-2px 交替，2x 可辨；非等宽）
	for y in h:
		for x in w:
			var c := img.get_pixel(x, y)
			if c.a <= 0.5:
				continue
			if _is_highlight_tone(c) or _is_accent_tone(c):
				continue
			if _is_silhouette_boundary(img, x, y):
				continue  # 第一圈已处理
			if _color_distance(c, Palette.EQUIP_EDGE_OUTLINE) <= 0.06:
				continue  # 已是深轮廓
			var touching := false
			for n in [[x - 1, y], [x + 1, y], [x, y - 1], [x, y + 1]]:
				if n[0] < 0 or n[1] < 0 or n[0] >= w or n[1] >= h:
					continue
				var nc := img.get_pixel(n[0], n[1])
				if _color_distance(nc, Palette.EQUIP_EDGE_OUTLINE) <= 0.06:
					touching = true
					break
			if not touching:
				continue
			var hsh := _hash2(x * 11 + 5, y * 7 + 3)
			if hsh % 100 >= 40:
				continue  # ~40% 内圈加深 —— 宽度变化
			var amt := 0.35 + float((hsh >> 8) % 21) / 100.0  # 35-55%
			img.set_pixel(x, y, c.lerp(Palette.EQUIP_EDGE_OUTLINE, amt))


## 返工4 P1（弱项 #5 接地线）+ 返工4 P2（FAIL4 接地）：面纹理底部（z=0 接地
## 行）压深一档 —— 设备底部与地面分离度拉强（任务 4：设备底部深色接地线/
## 接触阴影）。只作用于面纹理渲染路径（_authored_faces_for / 通用挤出 ——
## 不污染 raw_face_images，单元测试 5 色层断言不受影响）。
## 返工4 P2：底行 0 压 85%（近全暗）、行 1 压 50%，缺口 ~10% —— 接地线
## 连续可见但非等宽（V3.1 负面约束）。
func _apply_grounding_line(img: Image) -> void:
	var w := img.get_width()
	var h := img.get_height()
	# 面纹理 v=0 → z=0（接地行，probe 验证：front 变换 v=z*HEIGHT_SCALE，
	# 纹理行 0 渲染在面底部）—— 接地线画在纹理首 2 行。
	for y in mini(2, h):
		for x in w:
			var c := img.get_pixel(x, y)
			if c.a <= 0.5:
				continue
			if _color_distance(c, Palette.EQUIP_OUTLINE) <= 0.05:
				continue
			var hsh := _hash2(x * 11 + 5, y * 3 + 7)
			if hsh % 10 == 0:
				continue
			var amt := 1.0 if y == 0 else 0.9
			img.set_pixel(x, y, c.lerp(Palette.EQUIP_EDGE_OUTLINE, amt))


## 返工4 P2（FAIL2 顶面/侧面色阶分离 · 受光边）：面纹理顶缘（顶面与正面/
## 侧面的交界 = 顶面受光边的投影）撒暖白/冷钢高光带 —— 顶面「亮一档」的
## 视觉从顶面延伸到面上缘，正面中调 / 侧面暗部与顶面亮缘形成明确三层分离。
## 只作用于渲染路径面纹理（不污染 raw_face_images）；hash 缺口 ~15% ——
## 手绘断续，非程序渐变（V3.1 负面约束：无圆形光斑/无程序色块）。
func _apply_top_edge_band(img: Image, rows: int) -> void:
	var w := img.get_width()
	var h := img.get_height()
	# 面纹理 v=0 → z=0（接地）；面顶部（z=height，紧贴受光顶面）= 末行。
	# 受光边高光带画在纹理末行 —— 顶面「亮一档」从顶面延伸到面上缘。
	for y in range(maxi(0, h - rows), h):
		for x in w:
			var c := img.get_pixel(x, y)
			if c.a <= 0.5:
				continue
			var hsh := _hash2(x * 7 + 1, y * 11 + 3)
			if hsh % 100 < 15:
				continue
			var target := Palette.EQUIP_HIGHLIGHT if hsh % 2 == 0 else Palette.METAL_HIGHLIGHT
			var amt := 0.45 + float((hsh >> 8) % 25) / 100.0  # 45-70%
			img.set_pixel(x, y, c.lerp(target, amt))


## 建立 R0 图像：透明底 + 按 ART_SCALE 放大每个 art px。zone 名 → ZONE_COLORS
## 查色；未知 zone 用 FALLBACK_ZONE（兜底，不崩溃）。
## 返工4 P1（FAIL1/FAIL2）：完成像素化后执行手绘后处理 ——
##   1. _apply_hand_drawn_jitter：色阶过渡手绘式抖动（相邻色阶边界混合，
##      打破「程序色块」平涂 —— FAIL2 色阶分层）
##   2. _apply_silhouette_outline：外轮廓深一档勾边（EQUIP_EDGE_OUTLINE，
##      主体从背景中「勾」出来 —— FAIL1 轮廓勾边；高光侧开放，不等宽）
## 两步都确定性（hash 驱动，无 RNG），headless 可测、bit-identical。
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
	_apply_hand_drawn_jitter(img)
	_apply_silhouette_outline(img)
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
