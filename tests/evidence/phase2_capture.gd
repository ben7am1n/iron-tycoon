# tests/evidence/phase2_capture.gd — V3 Phase 2 结构层证据捕获（Phase 5 合并后）
#
# 渲染真实主场景（src/main.tscn，含 V3 §2 低分辨率管线 + Phase 5 地板/装饰/
# 光照 + Phase 2 结构层）并保存视口快照 + 像素级验证 + 结构验证 + draw call
# 预算。输出：tests/evidence/phase2-floor-env.png（主要证据，随仓库提交）+
#       tests/evidence/phase2-empty-gym.png（V3 §3 验收：移除设备后仍完整）。
#
# 用法（窗口模式——headless 用 dummy 渲染驱动，get_image() 返回 null，
# 4.7.1 已验证；窗口捕获是项目既有证据方法，见 phase1_capture 同款注释）：
#   godot --path . res://tests/evidence/phase2_capture.tscn
#
# 采样策略：世界断言全部采样 SubViewport 贴图（426×240，世界像素空间
# 0.75 缩放 + offset）——无 UI 遮挡，且 1 viewport px ≈ 0.75 world px。
#   vp = world × 0.75 + (57, 0)，与 main.gd 管线常量一致。
#
# 验收对照（V3 §1 地面材质 + §3 环境资产 + §4 三层空间 + §13 密度标准 +
# 任务 Exit 条件）：
#   - 结构层装配：WorldCanvas._structure_art 注入（Phase 2）
#   - 密度 V3 §13：STRUCTURES 表 large 5-10 / medium 15-30 / small 30-60
#   - 结构元素可见：前台（GAMEPLAY 原色暖木）、立柱（FOREGROUND 暖灰）、
#     储物柜（BACKGROUND 蓝灰）、墙面、窗户 —— 全部采样命中（含光照叠加）
#   - 地板材质（Phase 5 FloorArt 保留）：力量区暗灰、有氧区中灰、瑜伽暖木、
#     通道亮 —— 不回归
#   - V3 §14：正常经营模式无 grid；placement mode 网格可见
#   - V3 §3 验收：sell 全部设备后结构仍完整（空场采样命中）
#   - draw calls < 200（Performance monitor，4.7.1 枚举名 RENDER_TOTAL_...）
#
# 模拟暂停（非 --smoke 默认）：会员不生成 → 采样点稳定不被遮挡。
extends Node

const MAIN_SCENE := preload("res://src/main.tscn")
const Main := preload("res://src/main.gd")  # V3 §2 管线常量（单一来源）
const StructureArtScript := preload("res://src/presentation/structure_art.gd")
const Palette := preload("res://src/palette.gd")
const OUT_FLOOR := "res://tests/evidence/phase2-floor-env.png"
const OUT_EMPTY := "res://tests/evidence/phase2-empty-gym.png"
const CAPTURE_NORMAL_FRAME := 12
const DRAG_START_FRAME := 13
const CAPTURE_PLACEMENT_FRAME := 14
const CAPTURE_EMPTY_FRAME := 20

## 管线常量（来自 main.gd —— 证据复算与实现同源）。
const Proj2D := preload("res://src/presentation/oblique_projection.gd")
const SX := Main.SCREEN_PER_VIEWPORT_X
const SY := Main.SCREEN_PER_VIEWPORT_Y
const OFF := Main.WORLD_VIEWPORT_OFFSET
const WS := Main.WORLD_SCALE

var _frame := 0
var _main: Node = null
var _all_ok := true
var _assertions := 0


## 世界坐标 → 屏幕坐标（V3 §2 管线换算，独立于 main.gd 实现复算）。
func world_to_screen(w: Vector2) -> Vector2i:
	# V3.1 P1：世界→屏幕走 oblique 投影（main.gd 同源换算，证据独立复算）。
	var v := Proj2D.world_to_screen(w, OFF, WS, Vector2(SX, SY))
	return Vector2i(roundi(v.x), roundi(v.y))


## 世界坐标 → SubViewport 坐标（oblique 投影后画布 → viewport：vp = proj × 0.75
## + offset；世界断言用）。[w] 扁平世界坐标；[z] 高度（0=地面；墙/结构挤出面
## 用对应高度）。V3.1 P1 迁移：旧 vp = w × 0.75 + offset（轴对齐）缺 SHEAR
## 剪切 —— oblique 下地板是平行四边形，采样必须走 proj(w, z)。
func world_to_vp(w: Vector2, z: float = 0.0) -> Vector2i:
	var p := Proj2D.proj(w.x, w.y, z)
	return Vector2i(roundi(p.x * WS + OFF.x), roundi(p.y * WS + OFF.y))


## 从 SubViewport 取当前渲染帧（世界像素空间；无 UI 遮挡）。
func _vp_image() -> Image:
	var vp = _main.get_node("WorldViewport")
	var img = vp.get_texture().get_image()
	if img == null:
		push_error("phase2_capture: viewport get_image() null")
		get_tree().quit(1)
		return null
	return img


## 世界坐标 → SubViewport 像素色（[z] 高度；墙/结构挤出面带高度采样）。
func _vp_px(img: Image, w: Vector2, z: float = 0.0) -> Color:
	var v := world_to_vp(w, z)
	return img.get_pixel(v.x, v.y)


func _ready() -> void:
	_main = MAIN_SCENE.instantiate()
	add_child(_main)


func _process(_delta: float) -> void:
	_frame += 1
	match _frame:
		CAPTURE_NORMAL_FRAME:
			_capture_and_verify(OUT_FLOOR, "NORMAL")
		DRAG_START_FRAME:
			# placement mode：拖 treadmill 到 (10,8)（合法格）→ 网格同框。
			var placement = _main.get("_orch").placement_system
			placement.begin_drag("treadmill")
			placement.on_mouse_moved(Vector2i(10, 8))
		CAPTURE_PLACEMENT_FRAME:
			_verify_grid_visible()
		CAPTURE_EMPTY_FRAME:
			_capture_and_verify(OUT_EMPTY, "EMPTY")


## 全屏快照（1280×720，含 UI —— 人类可读证据）。
func _grab() -> Image:
	var img := get_viewport().get_texture().get_image()
	if img == null:
		push_error("phase2_capture: get_image() returned null (headless dummy driver?)")
		get_tree().quit(1)
		return null
	return img


## 主捕获：保存 PNG + 全部采样验证。mode: NORMAL（含设备）/ EMPTY（已清场）。
func _capture_and_verify(out_path: String, mode: String) -> void:
	var img := _grab()
	if img == null:
		return
	if mode == "EMPTY":
		# V3 §3 验收：经真实选择/出售路径移除全部设备。
		_sell_all_equipment()
		# 清场后再取一帧（确保 grid_changed → 重绘已提交）
		await get_tree().process_frame
		img = _grab()
	var abs_path := ProjectSettings.globalize_path(out_path)
	var err := img.save_png(abs_path)
	if err != OK:
		push_error("phase2_capture: save_png failed err=%d path=%s" % [err, abs_path])
		get_tree().quit(1)
		return
	print("CAPTURE saved=%s size=%dx%d" % [out_path, img.get_width(), img.get_height()])
	if mode == "NORMAL":
		_verify_structure()
		_verify_density()
		_verify_environment()
		_verify_floor_materials()
		_verify_grid_hidden()
		_verify_no_dev_colors()
		_verify_perf()
	else:
		_verify_empty_gym()
		_verify_perf()
	_finish(mode)


func _finish(mode: String) -> void:
	print("ASSERTIONS=%d mode=%s" % [_assertions, mode])
	if mode == "EMPTY":
		print("RESULT: %s" % ("PASS" if _all_ok else "CHECK"))
		get_tree().quit(0 if _all_ok else 1)


# === 结构验证（Phase 2 装配） ===

func _verify_structure() -> void:
	var canvas = _main.get_node_or_null("WorldViewport/WorldRoot/WorldCanvas")
	_ok(canvas != null, "STRUCT WorldCanvas exists")
	if canvas != null:
		_ok(canvas.get("_structure_art") != null, "STRUCT StructureArt injected (Phase 2)")
		_ok(canvas.get("_floor_art") != null, "STRUCT FloorArt injected (Phase 5 保留)")
		_ok(canvas.get("_env_art") != null, "STRUCT EnvironmentArt injected (Phase 5 保留)")


# === 密度（V3 §13） ===

func _verify_density() -> void:
	var art = StructureArtScript.new()
	var counts: Dictionary = art.density_counts()
	var large := int(counts.get("large", 0))
	var medium := int(counts.get("medium", 0))
	var small := int(counts.get("small", 0))
	print("  DENSITY large=%d medium=%d small=%d (STRUCTURES %d)" % [
		large, medium, small, StructureArtScript.STRUCTURES.size()])
	_ok(large >= 5 and large <= 10, "DENSITY large 5-10 (got %d)" % large)
	_ok(medium >= 15 and medium <= 30, "DENSITY medium 15-30 (got %d)" % medium)
	_ok(small >= 30 and small <= 60, "DENSITY small 30-60 (got %d)" % small)


# === 环境结构采样（V3 §3/§4）—— SubViewport ===

## 采样点（世界坐标 → 各层结构内部；V3.1 P1/P2 迁移：墙体/结构是体积挤出面，
## 采样带高度 z 或走墙空间变换，不再用轴对齐 z=0 点）：
##   front desk (140,38)  GAMEPLAY 原色（暖木台面 DESK_WOOD）—— 顶面 z=22
##     （STRUCT_FRONT_DESK_H；z=0 会采到前台正面/墙基）
##   column (160,150)     FOREGROUND（暖灰立柱 COLUMN_COLOR）—— 正面 z=50
##     （column 挤出高 WALL_HEIGHT-10=100，正面中段采样）
##   lockers (6,230)      BACKGROUND（蓝灰柜体 LOCKER_COLOR）—— 贴地 z=0
##   mirror               西墙墙面镜像（wall-local u=100, v=50；MIRROR_COLOR）
##   north wall (144,12)  BACKGROUND 降饱和（Phase 5 WALL_BASE 暖灰）—— 墙空间
##   window glass (124,13) BACKGROUND 降饱和（Phase 5 冷蓝玻璃）—— 墙空间
func _verify_environment() -> void:
	var img := _vp_image()
	if img == null:
		return
	# 前台：暖木（r > b + 0.08，DESK_WOOD A87E4F；GAMEPLAY 层原色；顶面 z=22）
	var desk := _vp_px(img, Vector2(140, 38), 22.0)
	_ok(desk.r > desk.b + 0.08,
		"ENV front desk warm wood (r=%.2f > b=%.2f, got %s)" % [desk.r, desk.b, desk.to_html(false)])
	# 立柱：暖灰（lum 0.40..0.80，COLUMN_COLOR A59E90 ≈ 0.62；FOREGROUND 允许遮挡）
	var column := _vp_px(img, Vector2(160, 150), 50.0)
	_ok(_luminance(column) > 0.40 and _luminance(column) < 0.80,
		"ENV FOREGROUND column present (lum %.3f, got %s)" % [_luminance(column), column.to_html(false)])
	# 储物柜：蓝灰（b >= r - 0.05，LOCKER_COLOR 7C8A94；BACKGROUND 降饱和）
	var lockers := _vp_px(img, Vector2(6, 230))
	_ok(lockers.b >= lockers.r - 0.05,
		"ENV lockers blue-gray (b=%.2f >= r=%.2f, got %s)" % [lockers.b, lockers.r, lockers.to_html(false)])
	# 镜子：西墙墙面镜像（冷蓝灰 MIRROR_COLOR AFC4D2；wall-local u=100 v=50）
	var mirror := _wall_px(img, false, Vector2(100, 50))
	_ok(mirror.b > mirror.r + 0.03,
		"ENV mirror cool glass (b=%.2f > r=%.2f, got %s)" % [mirror.b, mirror.r, mirror.to_html(false)])
	# 北墙：暖灰（lum 0.35..0.75，Phase 5 WALL_BASE 8B8378 ≈ 0.51；墙空间 fy=12）
	var wall := _wall_px(img, true, Vector2(144, 12))
	_ok(_luminance(wall) > 0.35 and _luminance(wall) < 0.75,
		"ENV north wall mid warm-gray (lum %.3f, got %s)" % [_luminance(wall), wall.to_html(false)])
	# 窗玻璃：冷蓝（b > r，Phase 5 WINDOW_GLASS；墙空间 fy=13 避开 mullion）
	var glass := _wall_px(img, true, Vector2(124, 13))
	_ok(glass.b > glass.r,
		"ENV window glass blue-tinted (b=%.2f > r=%.2f, got %s)" % [glass.b, glass.r, glass.to_html(false)])


## 墙面像素：墙本地坐标 → SubViewport 像素色（与 world_canvas 墙变换同源复算）。
## [north] true=北墙（fx∈[32,416], fy∈[0,24]；fy=24 底/z=0，fy=0 顶/z=110）；
## false=西/东墙（u=沿墙世界 y, v=墙高 z）。V3.1 P1：墙上结构（镜子/窗户/
## 墙面）从贴地改成墙面挤出 —— 采样必须走墙空间变换。
func _wall_px(img: Image, north: bool, local: Vector2) -> Color:
	var kex := Proj2D.WALL_HEIGHT * Proj2D.EXTRUDE_X / 24.0
	var khe := Proj2D.WALL_HEIGHT * Proj2D.HEIGHT_SCALE / 24.0
	var p: Vector2
	if north:
		p = Vector2(
			local.x + local.y * kex + 24.0 * Proj2D.SHEAR - 24.0 * kex,
			local.y * khe + 24.0 * Proj2D.FLOOR_SCALE - 24.0 * khe)
	else:
		p = Vector2(
			14.0 + local.x * Proj2D.SHEAR - local.y * Proj2D.EXTRUDE_X,
			local.x * Proj2D.FLOOR_SCALE - local.y * Proj2D.HEIGHT_SCALE)
	var v := Vector2i(roundi(p.x * WS + OFF.x), roundi(p.y * WS + OFF.y))
	return img.get_pixel(v.x, v.y)


# === 地面材质采样（V3 §1，Phase 5 FloorArt 保留）—— SubViewport ===

## 采样点（世界坐标；避开设备 footprint+阴影与装饰精灵）：
##   strength (88,200)：力量区 cell(2,6) 中部 —— 暗灰橡胶
##   cardio (230,200)：有氧区 cell(7,6) —— 中灰
##   flex (330,50)：瑜伽区 cell(10,1) —— 暖木
##   walkway (396,184)：通道列 12 cell(12,5) —— 亮（V3.1 P1 迁移：旧 (394,120)
##     在 oblique 下落在 walkway 瓷砖暗块/plant 阴影附近，改采实测亮瓷砖）
func _verify_floor_materials() -> void:
	var img := _vp_image()
	if img == null:
		return
	# 力量区：暗灰橡胶（lum < 0.45；FLOOR_STRENGTH_BASE 4B4F57 ≈ 0.29）
	var strength := _vp_px(img, Vector2(88, 200))
	_ok(_luminance(strength) < 0.45,
		"FLOOR strength is dark rubber (lum %.3f < 0.45, got %s)" % [
			_luminance(strength), strength.to_html(false)])
	# 有氧区：中灰（0.40..0.70；FLOOR_CARDIO_BASE 7C8288 ≈ 0.49）
	var cardio := _vp_px(img, Vector2(230, 200))
	_ok(_luminance(cardio) >= 0.40 and _luminance(cardio) <= 0.70,
		"FLOOR cardio is mid warm-gray (lum %.3f, got %s)" % [
			_luminance(cardio), cardio.to_html(false)])
	# 瑜伽区：暖木（r > b + 0.08；FLOOR_FLEX_BASE A9744C）
	var flex := _vp_px(img, Vector2(330, 50))
	_ok(flex.r > flex.b + 0.08,
		"FLOOR flex is warm wood (r=%.2f > b=%.2f, got %s)" % [flex.r, flex.b, flex.to_html(false)])
	# 公共通道：比力量区亮（差 > 0.20；FLOOR_WALK_BASE D3CBB9 ≈ 0.80）
	var walk := _vp_px(img, Vector2(396, 184))
	_ok(_luminance(walk) > _luminance(strength) + 0.20,
		"FLOOR walkway brighter than strength (%.3f > %.3f + 0.20, got %s)" % [
			_luminance(walk), _luminance(strength), walk.to_html(false)])
	# 力量区非纯色：6×6 vp 窗口内不同颜色 >= 2（像素块/接缝/污渍/光照）。
	var origin := world_to_vp(Vector2(84, 196))
	var colors := {}
	for dy in 6:
		for dx in 6:
			colors[img.get_pixel(origin.x + dx, origin.y + dy).to_html(false)] = true
	_ok(colors.size() >= 2,
		"FLOOR strength zone is multi-tone (>=2 colors in 6x6 vp, got %d)" % colors.size())


# === V3 §14 grid 可见性 ===

## 正常经营模式：world (394,224)（通道列 12 亮瓷砖 + 水平网格线位置）处无
## Charcoal 网格线 → 窗口内全是亮地面（lum > 0.50，FLOOR_WALK_BASE + 光照）。
## 采样 SubViewport（vp = proj × WS + OFF —— V3.1 P1 迁移）。V3.1 P1：旧点
## world (396,160) 在 oblique 下落在 walkway 暗块（植物/阴影附近），改采
## 实测亮瓷砖 + 网格线交点 (394,224)。
func _verify_grid_hidden() -> void:
	var img := _vp_image()
	if img == null:
		return
	var base := world_to_vp(Vector2(394, 224))
	var min_lum := 1.0
	for dx in range(-2, 3):
		for dy in range(-1, 2):
			var c := img.get_pixel(base.x + dx, base.y + dy)
			min_lum = minf(min_lum, _luminance(c))
	_ok(min_lum > 0.50,
		"GRID hidden in normal mode @world(394,224) (min lum %.3f > 0.50)" % min_lum)


## placement mode：同一点出现 Charcoal 网格线（lum 显著下降）。
func _verify_grid_visible() -> void:
	var img := _vp_image()
	if img == null:
		return
	var base := world_to_vp(Vector2(394, 224))
	var min_lum := 1.0
	for dx in range(-2, 3):
		for dy in range(-1, 2):
			var c := img.get_pixel(base.x + dx, base.y + dy)
			min_lum = minf(min_lum, _luminance(c))
	_ok(min_lum < 0.40,
		"GRID visible in placement mode @world(394,224) (min lum %.3f < 0.40)" % min_lum)
	# 回到正常模式（结束拖拽），供后续清场帧使用。
	var placement = _main.get("_orch").placement_system
	placement.on_drop()


# === V3 §1 无彩色开发网格（区域中心偏离语义色） ===

func _verify_no_dev_colors() -> void:
	var img := _vp_image()
	if img == null:
		return
	var checks := {
		"strength": {"world": Vector2(88, 200), "dev": Palette.SAGE},
		"cardio": {"world": Vector2(230, 200), "dev": Palette.SKY},
		"flex": {"world": Vector2(330, 50), "dev": Palette.PEACH},
	}
	for zone in checks:
		var c := _vp_px(img, checks[zone]["world"])
		var dev: Color = checks[zone]["dev"]
		var dist := _color_dist(c, dev)
		_ok(dist > 0.18,
			"NODEV %s zone center far from dev color %s (dist %.3f > 0.18)" % [
				zone, dev.to_html(false), dist])


# === V3 §3 验收：空场仍完整 ===

## 移除全部设备后：环境结构采样点仍命中（前台/立柱/储物柜/镜子/墙/窗）。
## V3.1 P1/P2 迁移：与 _verify_environment 同款 z/墙空间采样。
func _verify_empty_gym() -> void:
	var placed = _main.get("_grid").get_placed_instances()
	_ok(placed.is_empty(), "EMPTY all equipment removed (%d left)" % placed.size())
	var img := _vp_image()
	if img == null:
		return
	var desk := _vp_px(img, Vector2(140, 38), 22.0)
	_ok(desk.r > desk.b + 0.08, "EMPTY front desk still present")
	var column := _vp_px(img, Vector2(160, 150), 50.0)
	_ok(_luminance(column) > 0.40 and _luminance(column) < 0.80,
		"EMPTY FOREGROUND column still present")
	var lockers := _vp_px(img, Vector2(6, 230))
	_ok(lockers.b >= lockers.r - 0.05, "EMPTY lockers still present")
	var mirror := _wall_px(img, false, Vector2(100, 50))
	_ok(mirror.b > mirror.r + 0.03, "EMPTY mirror still present")
	var wall := _wall_px(img, true, Vector2(144, 12))
	_ok(_luminance(wall) > 0.35 and _luminance(wall) < 0.75,
		"EMPTY north wall still present")
	var glass := _wall_px(img, true, Vector2(124, 13))
	_ok(glass.b > glass.r, "EMPTY window glass still present")
	# 地板材质保持
	var strength := _vp_px(img, Vector2(88, 200))
	_ok(_luminance(strength) < 0.45,
		"EMPTY strength rubber floor preserved (lum %.3f)" % _luminance(strength))


## 经真实选择/出售路径移除全部设备（SelectionSystem.sell_selected 全链路）。
func _sell_all_equipment() -> void:
	var grid = _main.get("_grid")
	var selection = _main.get("_orch").selection_system
	var instances = grid.get_placed_instances()
	for inst in instances:
		var anchor: Vector2i = inst.footprint_cells[0]
		selection.on_cell_clicked(anchor)
		if not selection.sell_selected():
			# 兜底：直接 clear（不应发生；真实路径失败则证据脚本明示）
			push_warning("phase2_capture: sell path failed for %s" % str(inst.instance_id))
			grid.clear(inst.instance_id)


func _verify_perf() -> void:
	var draw_calls := Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	var fps := Performance.get_monitor(Performance.TIME_FPS)
	var perf_ok := draw_calls < 200
	_ok(perf_ok, "PERF draw_calls=%d fps=%.1f budget_ok=%s" % [draw_calls, fps, str(perf_ok)])


# === helpers ===

func _ok(cond: bool, msg: String) -> void:
	_assertions += 1
	if not cond:
		_all_ok = false
	print("  %s %s" % ["PASS" if cond else "FAIL", msg])


func _color_dist(a: Color, b: Color) -> float:
	var dr := a.r - b.r
	var dg := a.g - b.g
	var db := a.b - b.b
	return sqrt(dr * dr + dg * dg + db * db)


func _luminance(c: Color) -> float:
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
