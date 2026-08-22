# tests/unit/structure_art/structure_art_test.gd
# Phase 2 — StructureArt（V3 §3/§4/§13 结构层工厂）单元测试
#
# 验证 src/presentation/structure_art.gd：
#   - V3 §13 密度分类：STRUCTURES 表 size 统计落在区间
#     large 5-10 / medium 12-30 / small 25-60（减饰后的全场景口径）
#   - 三层空间（V3 §4）：BACKGROUND / GAMEPLAY / FOREGROUND 均非空
#   - 必需结构元素齐全（V3 §3 清单：立柱/前台/储物柜/饮水机/吊灯/
#     植物/镜子/墙钟/入口招牌/踢脚线/电线槽/管道/门/毛巾架）
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
const WorldLayout := preload("res://src/presentation/world_layout.gd")

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
	_test_light_fixture_layout_contract()
	_test_lamp_suspension_and_glow()
	_test_rects_in_bounds()
	_test_painted_by_split()
	_test_textures_bake()
	_test_wall_asset_pipeline()
	_test_clean_ceiling()
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
	print("\n-- V3 §13 减饰密度（large 5-10 / medium 12-30 / small 25-60）--")
	var art = StructureArtScript.new()
	var counts: Dictionary = art.density_counts()
	_check(int(counts["large"]) >= 5 and int(counts["large"]) <= 10,
		"large count %d in [5,10]" % int(counts["large"]))
	_check(int(counts["medium"]) >= 12 and int(counts["medium"]) <= 30,
		"medium count %d in [12,30]" % int(counts["medium"]))
	_check(int(counts["small"]) >= 25 and int(counts["small"]) <= 60,
		"small count %d in [25,60]" % int(counts["small"]))
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
		"hanging_lamp_1", "hanging_lamp_2", "hanging_lamp_3",  # 吊灯
		"plant_large_1", "plant_large_2",  # 植物
		"mirror",                      # 镜子
		"wall_clock",                  # 墙钟
		"sign_entrance",               # 入口招牌
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
	_check(WorldLayout.WALL_DECOR.has("ad_red"), "北墙保留唯一海报主焦点 ad_red")


## V3.1 R4：光源物件 rect 与投光布局必须是同一物件，不能各自漂移。
func _test_light_fixture_layout_contract() -> void:
	var art = StructureArtScript.new()
	for light: Dictionary in WorldLayout.HANGING_LIGHTS:
		var id := str(light.get("id", ""))
		var expected: Rect2i = light.get("rect", Rect2i())
		_check(art.structure_rect(id) == expected,
			"%s structure rect matches lighting source anchor" % id)
		_check(float(light.get("height", 0.0)) > 0.0,
			"%s has explicit hanging height" % id)
	var centers: Array[float] = []
	for light: Dictionary in WorldLayout.HANGING_LIGHTS:
		var rect: Rect2i = light.get("rect", Rect2i())
		centers.append(float(rect.position.x) + float(rect.size.x) * 0.5)
		_check(rect.position.y > 0,
			"%s hangs forward of the north-wall plane" % str(light.get("id", "")))
	_check(is_equal_approx(centers[1] - centers[0], centers[2] - centers[1]),
		"three hanging lamps are evenly spaced")


## 吊灯纹理必须在低分辨率下保留连续 3px 吊线与半透明暖色边缘光。
func _test_lamp_suspension_and_glow() -> void:
	var art = StructureArtScript.new()
	var img: Image = art.structure_texture("hanging_lamp_1").get_image()
	var cable_continuous := true
	for y in range(2, 10):
		var opaque := 0
		for x in range(12, 17):
			if img.get_pixel(x, y).a > 0.95:
				opaque += 1
		if opaque < 3:
			cable_continuous = false
	_check(cable_continuous, "lamp suspension cable stays >=3px wide and continuous")
	var glow_pixels := 0
	for y in img.get_height():
		for x in img.get_width():
			var c := img.get_pixel(x, y)
			if c.a >= 0.35 and c.a < 0.75 and c.r > c.b:
				glow_pixels += 1
	_check(glow_pixels >= 12,
		"lamp shade has readable warm edge glow (%d translucent pixels)" % glow_pixels)


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


# === 墙面 asset-first ===

func _test_wall_asset_pipeline() -> void:
	print("\n-- clean wall PNG assets + horizontal tiling + fallback --")
	var art = StructureArtScript.new()
	var expected := {
		"north": "res://assets/tiles/wall_north.png",
		"west": "res://assets/tiles/wall_side.png",
		"east": "res://assets/tiles/wall_side.png",
	}
	for kind in expected:
		_check(art.wall_asset_path_for(kind) == expected[kind],
			"%s wall maps to %s" % [kind, expected[kind]])
		_check(art.is_using_wall_asset(kind), "%s wall loads authored PNG" % kind)
		_check(art.wall_asset_tile_size(kind) == Vector2i(32, 32),
			"%s wall source tile is 32x32" % kind)
	var north: Image = art.wall_face_texture("north").get_image()
	_check(north.get_pixel(5, 18) == north.get_pixel(37, 18),
		"north wall clean face repeats every 32px")
	var east: Image = art.wall_face_texture("east").get_image()
	_check(east.get_pixel(5, 50) == east.get_pixel(37, 50),
		"side wall clean face repeats every 32px")
	var expected_base_colors := {
		"res://assets/tiles/wall_north.png": Color8(181, 172, 163),
		"res://assets/tiles/wall_side.png": Color8(168, 160, 154),
	}
	for path in expected_base_colors:
		var raw := Image.new()
		_check(raw.load(path) == OK, "%s raw PNG decodes" % path)
		_check(raw.get_pixel(0, 0) == expected_base_colors[path],
			"%s uses warm light-gray base %s" % [path, expected_base_colors[path].to_html(false)])
		var counts: Dictionary = {}
		for y in raw.get_height():
			for x in raw.get_width():
				var key := raw.get_pixel(x, y).to_html(false)
				counts[key] = int(counts.get(key, 0)) + 1
		var dominant := 0
		for key in counts:
			dominant = maxi(dominant, int(counts[key]))
		var ratio := 1.0 - float(dominant) / float(raw.get_width() * raw.get_height())
		_check(ratio <= 0.15, "%s detail %.1f%% <= 15%%" % [path, ratio * 100.0])
	var missing := {
		"north": "res://assets/tiles/missing-wall-north.png",
		"side": "res://assets/tiles/missing-wall-side.png",
	}
	var fallback = StructureArtScript.new(true, missing)
	_check(not fallback.is_using_wall_asset("north"),
		"missing north wall selects clean fallback")
	_check(not fallback.is_using_wall_asset("west"),
		"missing side wall selects clean fallback")
	_check(fallback.wall_face_texture("north") != null \
		and fallback.wall_face_texture("west") != null,
		"wall fallback still bakes both wall orientations")


func _test_clean_ceiling() -> void:
	var img: Image = StructureArtScript.new().ceiling_texture().get_image()
	var first := img.get_pixel(0, 0)
	var clean := true
	for y in range(0, img.get_height(), 17):
		for x in range(0, img.get_width(), 17):
			if img.get_pixel(x, y) != first:
				clean = false
	_check(clean, "ceiling is quiet negative space with no brush field")


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
