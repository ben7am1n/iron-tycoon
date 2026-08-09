# tests/unit/structure_art/structure_art_test.gd
# Phase 2 — StructureArt（V3 §3/§4/§13 结构层工厂）单元测试
#
# 验证 src/presentation/structure_art.gd：
#   - V3 §13 密度分类：STRUCTURES 表 size 统计落在区间
#     large 5-10 / medium 15-30 / small 30-60（全场景口径）
#   - 三层空间（V3 §4）：BACKGROUND / GAMEPLAY / FOREGROUND 均非空
#   - 必需结构元素齐全（V3 §3 清单：立柱/前台/储物柜/饮水机/吊灯/海报/
#     植物/镜子/通风口/空调/墙钟/踢脚线/电线槽/管道/门/毛巾架）
#   - 结构矩形全部在世界像素空间内（0..416 × 0..320）
#   - painted_by 分工：self 元素非空，且与 phase5 元素不冲突（同 id 不重复）
#   - 纹理可烘焙：三图层尺寸 = 世界尺寸，无崩溃；BACKGROUND 层降对比
#     （GAMEPLAY 前台色 vs BACKGROUND 同结构色：BACKGROUND 更接近中性灰）
#   - 确定性：两次烘焙结果一致（bit-identical）
#
# Run standalone: godot --headless --script tests/unit/structure_art/structure_art_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const StructureArtScript := preload("res://src/presentation/structure_art.gd")
const PaletteScript := preload("res://src/palette.gd")

var _pass := 0
var _fail := 0


func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	var result := run_all()
	quit(1 if int(result["fail"]) > 0 else 0)


func run_all() -> Dictionary:
	print("=".repeat(48))
	print("  UNIT TEST: StructureArt — V3 §3/§4/§13 结构层")
	print("=".repeat(48))

	_test_density_ranges()
	_test_three_layers_present()
	_test_required_structures()
	_test_rects_in_bounds()
	_test_painted_by_split()
	_test_textures_bake()
	_test_background_dimmed()
	_test_determinism()

	print("\n=== STRUCTURE ART TEST: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


# === V3 §13 密度分类 ===

func _test_density_ranges() -> void:
	print("\n-- V3 §13 密度分类（large 5-10 / medium 15-30 / small 30-60）--")
	var art = StructureArtScript.new()
	var counts: Dictionary = art.density_counts()
	_check(int(counts["large"]) >= 5 and int(counts["large"]) <= 10,
		"large count %d in [5,10]" % int(counts["large"]))
	_check(int(counts["medium"]) >= 15 and int(counts["medium"]) <= 30,
		"medium count %d in [15,30]" % int(counts["medium"]))
	_check(int(counts["small"]) >= 30 and int(counts["small"]) <= 60,
		"small count %d in [30,60]" % int(counts["small"]))
	var total := int(counts["large"]) + int(counts["medium"]) + int(counts["small"])
	_check(total >= 50, "total structures %d >= 50（画面丰富）" % total)


# === V3 §4 三层空间 ===

func _test_three_layers_present() -> void:
	print("\n-- V3 §4 三层空间（BACKGROUND / GAMEPLAY / FOREGROUND）--")
	var art = StructureArtScript.new()
	_check(art.structure_ids_in_layer(StructureArtScript.LAYER_BACKGROUND).size() > 0,
		"BACKGROUND 层非空（%d 个结构）" % art.structure_ids_in_layer(StructureArtScript.LAYER_BACKGROUND).size())
	_check(art.structure_ids_in_layer(StructureArtScript.LAYER_GAMEPLAY).size() > 0,
		"GAMEPLAY 层非空（%d 个结构）" % art.structure_ids_in_layer(StructureArtScript.LAYER_GAMEPLAY).size())
	_check(art.structure_ids_in_layer(StructureArtScript.LAYER_FOREGROUND).size() > 0,
		"FOREGROUND 层非空（%d 个结构）" % art.structure_ids_in_layer(StructureArtScript.LAYER_FOREGROUND).size())
	# 前台（主要交互对象）在 GAMEPLAY 层 —— 更清楚、更鲜艳（V3 §4）
	_check(art.structure_rect("front_desk") != Rect2i(),
		"前台 front_desk 存在于 GAMEPLAY 层")


# === V3 §3 必需结构清单 ===

func _test_required_structures() -> void:
	print("\n-- V3 §3 必需结构元素（即使无设备也像完整健身房）--")
	var art = StructureArtScript.new()
	var ids: Array = []
	for s in StructureArtScript.STRUCTURES:
		ids.append(str(s.get("id", "")))
	var required := [
		"column_1", "column_2",       # 立柱
		"front_desk",                  # 前台
		"lockers",                     # 储物柜
		"water_fountain",              # 饮水机
		"trash_can",                   # 垃圾桶
		"towel_rack",                  # 毛巾架
		"fire_hydrant",                # 消防栓
		"vent_1", "vent_2",            # 通风口
		"hanging_lamp_1", "hanging_lamp_2", "hanging_lamp_3",  # 吊灯
		"poster_1", "poster_2",        # 海报
		"plant_large_1", "plant_large_2",  # 植物
		"mirror",                      # 镜子
		"ac_unit",                     # 空调
		"wall_clock",                  # 墙钟
		"cable_duct_north", "cable_duct_west", "cable_duct_east",  # 电线槽
		"baseboard_north", "baseboard_west", "baseboard_east",  # 踢脚线
		"pipe_vertical", "pipe_horizontal",  # 管道
		"door_entrance", "door_exit",  # 门
		"wall_north", "wall_west", "wall_east",  # 墙壁
		"window_1", "window_2",        # 窗户
	]
	var missing: Array = []
	for id in required:
		if not ids.has(id):
			missing.append(id)
	_check(missing.is_empty(), "必需结构齐全（缺 %s）" % str(missing))


# === 结构矩形边界 ===

func _test_rects_in_bounds() -> void:
	print("\n-- 结构矩形边界（世界像素空间 416×320）--")
	var art = StructureArtScript.new()
	var out: Array = []
	for s in StructureArtScript.STRUCTURES:
		var r: Rect2i = s.get("rect", Rect2i())
		var id := str(s.get("id", ""))
		if r.position.x < 0 or r.position.y < 0:
			out.append(id + ":pos<0")
		if r.position.x + r.size.x > StructureArtScript.WORLD_W:
			out.append(id + ":right")
		if r.position.y + r.size.y > StructureArtScript.WORLD_H:
			out.append(id + ":bottom")
		if r.size.x <= 0 or r.size.y <= 0:
			out.append(id + ":zero-size")
	_check(out.is_empty(), "全部结构矩形在界内（越界 %s）" % str(out))


# === painted_by 分工 ===

func _test_painted_by_split() -> void:
	print("\n-- painted_by 分工（self=本层绘制 / phase5=Phase 5 绘制）--")
	var art = StructureArtScript.new()
	_check(art.self_painted_count() >= 20,
		"self 绘制结构 %d 个 >= 20（本层有实质内容）" % art.self_painted_count())
	# id 唯一性
	var ids: Array = []
	var dup: Array = []
	for s in StructureArtScript.STRUCTURES:
		var id := str(s.get("id", ""))
		if ids.has(id):
			dup.append(id)
		ids.append(id)
	_check(dup.is_empty(), "结构 id 无重复（重复 %s）" % str(dup))


# === 纹理烘焙 ===

func _test_textures_bake() -> void:
	print("\n-- 三图层纹理可烘焙（尺寸 = 世界尺寸）--")
	var art = StructureArtScript.new()
	for layer in [StructureArtScript.LAYER_BACKGROUND, StructureArtScript.LAYER_GAMEPLAY, StructureArtScript.LAYER_FOREGROUND]:
		var tex = art.layer_texture(layer)
		_check(tex != null, "%s 层纹理生成" % layer)
		if tex != null:
			_check(tex.get_width() == StructureArtScript.WORLD_W and tex.get_height() == StructureArtScript.WORLD_H,
				"%s 层尺寸 %dx%d = 世界尺寸" % [layer, tex.get_width(), tex.get_height()])


# === BACKGROUND 降对比降饱和（V3 §4） ===

func _test_background_dimmed() -> void:
	print("\n-- V3 §4 BACKGROUND 降对比（GAMEPLAY 前台 vs BACKGROUND 同色）--")
	var art = StructureArtScript.new()
	# 前台在 GAMEPLAY 层 —— 原色鲜艳；同结构若出现在 BACKGROUND 层应降饱和。
	# V3.1 P3：结构表面有手工小色块/jagged 边缘 —— 改用区域内搜索主色
	# （base 填充占绝对多数），不再 pin 单个像素。
	var desk_rect: Rect2i = art.structure_rect("front_desk")
	var gp_img := art.layer_texture(StructureArtScript.LAYER_GAMEPLAY).get_image()
	var expected: Color = PaletteScript.DESK_WOOD
	var desk_found := _rect_contains_color(gp_img, desk_rect, expected, 0.02)
	_check(desk_found, "GAMEPLAY 前台 desk 原色（区域内找到 DESK_WOOD）")
	# BACKGROUND 层 lockers 色 = _col(LOCKER_COLOR) 应比原色更接近中性灰。
	var locker_rect: Rect2i = art.structure_rect("lockers")
	var bg_img := art.layer_texture(StructureArtScript.LAYER_BACKGROUND).get_image()
	var raw: Color = PaletteScript.LOCKER_COLOR
	var neutral := Color(raw.get_luminance(), raw.get_luminance(), raw.get_luminance())
	var dimmed := raw.lerp(neutral, 0.45).darkened(0.10)
	var locker_found := _rect_contains_color(bg_img, locker_rect, dimmed, 0.02)
	_check(locker_found, "BACKGROUND lockers 降对比降饱和（区域内找到 dimmed LOCKER_COLOR）")


## 矩形区域内是否含目标色（容差 tol）—— P3 表面不规则后不再 pin 单像素。
func _rect_contains_color(img: Image, rect: Rect2i, color: Color, tol: float) -> bool:
	for y in range(rect.position.y, rect.position.y + rect.size.y):
		for x in range(rect.position.x, rect.position.x + rect.size.x):
			if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
				continue
			var p := img.get_pixel(x, y)
			if absf(p.r - color.r) < tol and absf(p.g - color.g) < tol and absf(p.b - color.b) < tol:
				return true
	return false


# === 确定性 ===

func _test_determinism() -> void:
	print("\n-- 确定性（两次烘焙 bit-identical）--")
	var art = StructureArtScript.new()
	var tex_a = art.layer_texture(StructureArtScript.LAYER_BACKGROUND)
	var tex_b = art.layer_texture(StructureArtScript.LAYER_BACKGROUND)
	_check(tex_a.get_image().get_data() == tex_b.get_image().get_data(),
		"BACKGROUND 层两次烘焙一致")
