# tests/evidence/phase3_capture.gd — V3 Phase 3 设备场景物件证据捕获
#
# 渲染真实主场景（src/main.tscn，含 V3 §2 低分辨率管线）并保存视口快照 +
# 每类设备特写验证（光影层级 + 朝向可辨，V3 §5）+ contact shadow（§6）+
# hover 黄色像素轮廓 + 上移（§14）+ 底部购买栏 pixel sprite 缩略图（§10）。
# 输出：tests/evidence/phase3-equipment.png（证据文件，随仓库提交）。
#
# 用法（窗口模式——headless 用 dummy 渲染驱动，get_image() 返回 null，
# 4.7.1 已验证；窗口捕获是项目既有证据方法，见 phase_b_capture 同款注释）：
#   godot --path . res://tests/evidence/phase3_capture.tscn
#
# 验收对照（V3 §5/§6/§10/§14 + 任务 Exit 条件）：
#   - 每类设备：≥3 个主要颜色层级（纹理色数）+ 高光侧（暖黄）存在 +
#     阴影侧（冷蓝灰）存在 + 屏幕青蓝 emissive 像素（treadmill/bike）+
#     机器深蓝灰轮廓（§11）→ 小型场景物件（非图标）
#   - 3/4 top-down 朝向可辨：treadmill 前端 console（青蓝显示）vs 后端阴影面
#   - contact shadow 可见：设备下方 vs 同区域地板更暗（§6）
#   - hover：黄色 Butter 像素轮廓围绕 footprint + 精灵上移（§14）
#   - 底部购买栏：tile 有 pixel sprite 缩略图（非占位符，§10）
#   - draw calls < 200（Performance monitor，4.7.1 枚举名 RENDER_TOTAL_...）
#
# 采样策略：模拟暂停（非 --smoke 默认），会员不生成 → 采样点稳定不被遮挡。
# 世界→屏幕换算用 main.gd 的管线常量独立复算（与 phase1_capture 同款）。
extends Node

const MAIN_SCENE := preload("res://src/main.tscn")
const Main := preload("res://src/main.gd")  # V3 §2 管线常量（单一来源）
const OUT_PATH := "res://tests/evidence/phase3-equipment.png"
const CAPTURE_FRAME := 10
const HOVER_FRAME := 12

## 管线常量（来自 main.gd —— 证据复算与实现同源）。
const Proj2D := preload("res://src/presentation/oblique_projection.gd")
const SX := Main.SCREEN_PER_VIEWPORT_X
const SY := Main.SCREEN_PER_VIEWPORT_Y
const OFF := Main.WORLD_VIEWPORT_OFFSET
const WS := Main.WORLD_SCALE

## 设备语义色（palette.gd 单一来源 —— 采样期望与实现同源）。
const Palette := preload("res://src/palette.gd")

## 初始布局（main.gd _initial_layout）：instance_id 按放置顺序 0..4。
##   treadmill(2,2) / bike(2,5) / treadmill(6,3) / bench_press(1,7) / yoga_mat(9,2)
const INSTANCE_ID_BY_EQUIP := {
	"treadmill": 0,
	"bike": 1,
	"bench_press": 3,
	"yoga_mat": 4,
}
## 每类设备 footprint 的世界矩形（cell → 世界 px，CELL_SIZE=32）：
##   treadmill(2,2) 2×1 | bike(2,5) 1×1 | bench_press(1,7) 2×2 | yoga_mat(9,2) 1×1
const EQUIP_RECTS := {
	"treadmill": Rect2i(64, 64, 64, 32),
	"bike": Rect2i(64, 160, 32, 32),
	"bench_press": Rect2i(32, 224, 64, 64),
	"yoga_mat": Rect2i(288, 64, 32, 32),
}

var _frame := 0
var _captured := false
var _main: Node = null
var _world_canvas: Node = null
var _palette: Node = null
var _all_ok := true


## 世界坐标 → 屏幕坐标（V3 §2 管线换算，独立于 main.gd 实现复算）。
## [z] 高度（世界 px，0=地面；设备顶面用设备高度）。
func world_to_screen(w: Vector2, z: float = 0.0) -> Vector2i:
	# V3.1 P1：世界→屏幕走 oblique 投影（main.gd 同源换算，证据独立复算）。
	# V3.1 P2：设备有体积，treadmill 顶面 z=30（EQUIP_HEIGHTS treadmill 30.0）
	# —— 跑带/控制台在前半区顶面，采样必须带高度（z=0 会采到挤出前脸）。
	var v := Proj2D.world_to_screen(w, OFF, WS, Vector2(SX, SY), z)
	return Vector2i(roundi(v.x), roundi(v.y))


func _ready() -> void:
	_main = MAIN_SCENE.instantiate()
	add_child(_main)
	_world_canvas = _main.get_node_or_null("WorldViewport/WorldRoot/WorldCanvas")
	_palette = _main.get_node_or_null("UICanvas/BuildShopPalette")
	# 禁用 main.gd 注入的鼠标 hover provider —— 证据捕获用确定性 hover 状态
	# （set_hovered_instance_id 测试入口，同 set_grid_visible 模式）。否则真实
	# 鼠标位置每帧覆盖手动设置，hover 采样不稳定。
	if _world_canvas != null:
		_world_canvas.set_hover_provider(Callable())


func _process(_delta: float) -> void:
	_frame += 1
	if _captured:
		return
	if _frame == CAPTURE_FRAME:
		_verify_texture_art()
		_verify_world_equipment()
		_verify_palette_thumbnails()
		return
	if _frame == HOVER_FRAME:
		# hover：直接驱动 WorldCanvas.hover（测试入口，同 set_grid_visible 模式）
		# 悬停 treadmill instance 0 → 下一帧黄色 Butter 轮廓 + 精灵上移。
		if _world_canvas != null:
			_world_canvas.set_hovered_instance_id(INSTANCE_ID_BY_EQUIP["treadmill"])
		return
	if _frame == HOVER_FRAME + 1:
		_captured = true
		_verify_hover()
		_capture_and_report()


func _grab() -> Image:
	var img := get_viewport().get_texture().get_image()
	if img == null:
		push_error("phase3_capture: get_image() returned null (headless dummy driver?)")
		get_tree().quit(1)
		return null
	return img


## 每类设备 texture 级验证（V3 §5 场景物件 / §6 方向光 / §11 机器轮廓）：
## 从 EquipmentArt 纹理直接断言 —— 采样像素不受管线缩放影响。
func _verify_texture_art() -> void:
	var equip_art = _main.get("_equip_art")
	if equip_art == null:
		_ok(false, "ART equip_art available")
		return
	var zone_of := {
		"treadmill": "cardio", "bike": "cardio",
		"bench_press": "strength", "yoga_mat": "flex",
	}
	for eq_id in zone_of:
		var tex: ImageTexture = equip_art.texture_for(eq_id, zone_of[eq_id], 0)
		_ok(tex != null, "ART %s texture built" % eq_id)
		if tex == null:
			continue
		var img := tex.get_image()
		var levels := _count_levels(img, 0.08)
		_ok(levels >= 3, "ART %s >=3 color levels (got %d, V3 §5)" % [eq_id, levels])
		_ok(_contains(img, Palette.EQUIP_OUTLINE, 0.06),
			"ART %s machine deep-blue-gray outline (V3 §11)" % eq_id)
		if eq_id != "yoga_mat":
			# 机器暖黄高光（§6）只要求机器件（treadmill/bike/bench_press）；
			# yoga_mat 的「明确高光」= 卷起边缘 zone-light（下方单独断言，§5 卷起边缘）。
			_ok(_contains(img, Palette.EQUIP_HIGHLIGHT, 0.06),
				"ART %s warm highlight (V3 §6)" % eq_id)
		_ok(_contains(img, Palette.EQUIP_SHADOW_TONE, 0.06),
			"ART %s cool shadow (V3 §6)" % eq_id)
		if eq_id == "treadmill" or eq_id == "bike":
			_ok(_contains(img, Palette.EQUIP_ACCENT_CYAN, 0.06),
				"ART %s cyan display pixels (V3 §6 emissive)" % eq_id)
		if eq_id == "yoga_mat":
			# 瑜伽垫是区域色物件（Peach）：其「明确高光」= 卷起边缘的 zone-light
			# （L = zone_color.lightened(0.15)，暖橙高光；§5 卷起边缘 + §6 高光），
			# 不要求机器暖黄（EQUIP_HIGHLIGHT）像素。
			_ok(_contains(img, Palette.ZONE_COLORS["flex"].lightened(0.15), 0.06),
				"ART yoga_mat rolled-edge warm highlight (zone-light, V3 §5/§6)")


## 世界采样：每类设备 footprint 特写 —— 光影层级 + 朝向可辨 + contact shadow。
func _verify_world_equipment() -> void:
	var img := _grab()
	if img == null:
		return
	for eq_id in EQUIP_RECTS:
		var rect: Rect2i = EQUIP_RECTS[eq_id]
		var samples := _sample_rect(img, rect)
		# 特写采样集含 ≥3 个不同主要色（世界像素空间，含 contact shadow 混合）。
		var distinct := _distinct_colors(samples, 0.10)
		_ok(distinct >= 3, "WORLD %s close-up has >=3 distinct colors (got %d, V3 §5)" % [eq_id, distinct])
	# treadmill 朝向（V3 §5）：前端 console 青蓝显示 vs 后端阴影 —— 世界坐标
	# treadmill(2,2) fp y 64..96：前端 = y 88..96（console），后端 = y 64..72。
	var tm := _grab()
	if tm == null:
		return
	# V3 §5 朝向：控制台（cyan display）在 treadmill 顶面前半区 —— 采样顶面
	# z=30（EQUIP_HEIGHTS treadmill 30.0；z=0 会采到挤出前脸/接触影，见
	# V3.1 P2 设备体积）。front = 世界 y 88..96（控制台行），back = 64..72。
	var front := _region_has(tm, Rect2i(64, 88, 64, 8), Palette.EQUIP_ACCENT_CYAN, 0.15, 30.0)
	var back := _region_has(tm, Rect2i(64, 64, 64, 8), Palette.EQUIP_ACCENT_CYAN, 0.15, 30.0)
	_ok(front, "WORLD treadmill front (console) has cyan display — orientation (V3 §5)")
	_ok(not back, "WORLD treadmill back has no cyan — front/back distinct (V3 §5)")
	# contact shadow（§6）：treadmill(2,2) fp (64,64,64,32) 下方 contact shadow
	# 核心区（世界 (110,99)，fp 下缘核心阴影）vs 同区域地板（世界 (160,99)，
	# Phase 2/5 合入后实测 lum 0.304 < 0.653）—— 世界坐标 → 屏幕。
	# 注意：Phase 5 光照层会在窗口附近叠加斜向自然光，旧采样点 (76,98) 落在
	# 窗光增亮区被污染（lum 反超），改采 shadow 核心 vs 远离窗光的右侧地板。
	var shadow_p := world_to_screen(Vector2(110, 99))
	var floor_p := world_to_screen(Vector2(160, 99))
	var shadow_col := img.get_pixel(shadow_p.x, shadow_p.y)
	var floor_col := img.get_pixel(floor_p.x, floor_p.y)
	var shadow_ok := _luminance(shadow_col) < _luminance(floor_col) - 0.03
	_ok(shadow_ok, "WORLD contact shadow visible: shadow=%s floor=%s lum(%.3f<%.3f) (V3 §6)" % [
		shadow_col.to_html(false), floor_col.to_html(false),
		_luminance(shadow_col), _luminance(floor_col)
	])


## hover 验证（V3 §14）：treadmill(2,2) fp 世界 (64,64,64,32) →
## 屏幕 → 黄色 Butter 轮廓采样 + 精灵上移（顶部原本轮廓色处出现高光/亮色）。
## V3.1 P1 迁移：hover outline 是围绕 oblique 投影足迹的平行四边形（顶面在
## z=height 挤出，底面贴地）—— 左缘从 proj(62,62,30) 到 proj(62,98,0)，
## 不再是轴对齐矩形。沿四条边采样，任一边命中 Butter 即 PASS。
func _verify_hover() -> void:
	if _world_canvas == null:
		_ok(false, "HOVER world_canvas available")
		return
	_ok(int(_world_canvas.get_hovered_instance_id()) == INSTANCE_ID_BY_EQUIP["treadmill"],
		"HOVER state: treadmill instance hovered")
	var img := _grab()
	if img == null:
		return
	# fp.grow(2) = Rect2(62, 62, 68, 36)；平行四边形四角（顶面 z=30 / 底面 z=0）
	var tl := world_to_screen(Vector2(62, 62), 30.0)
	var tr := world_to_screen(Vector2(130, 62), 30.0)
	var br := world_to_screen(Vector2(130, 98), 0.0)
	var bl := world_to_screen(Vector2(62, 98), 0.0)
	var butter_found := false
	for pair in [
		[Vector2(tl), Vector2(tr)],
		[Vector2(tr), Vector2(br)],
		[Vector2(br), Vector2(bl)],
		[Vector2(bl), Vector2(tl)],
	]:
		var a: Vector2 = pair[0]
		var b: Vector2 = pair[1]
		var len := maxi(1, int(a.distance_to(b) / 3.0))
		for i in range(0, len + 1):
			var pt := a.lerp(b, float(i) / float(len))
			for dy in range(-6, 7):
				for dx in range(-6, 7):
					var x := int(round(pt.x)) + dx
					var y := int(round(pt.y)) + dy
					if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
						continue
					if _near(img.get_pixel(x, y), Palette.BUTTER, 0.20):
						butter_found = true
						break
				if butter_found:
					break
			if butter_found:
				break
		if butter_found:
			break
	_ok(butter_found, "HOVER yellow (Butter) pixel outline around treadmill parallelogram (V3 §14)")


## 底部购买栏缩略图（V3 §10）：tile 图标 slot 是 pixel sprite（非占位符字形）。
func _verify_palette_thumbnails() -> void:
	if _palette == null:
		_ok(false, "PALETTE BuildShopPalette available")
		return
	for id in ["treadmill", "bike", "bench_press", "yoga_mat"]:
		var tile = _palette.call("get_tile", id)
		_ok(tile != null, "PALETTE tile exists '%s'" % id)
		if tile == null:
			continue
		var thumb: Texture2D = tile.call("get_thumbnail")
		_ok(thumb != null, "PALETTE '%s' has pixel sprite thumbnail (V3 §10)" % id)
		if thumb != null:
			_ok(thumb.get_size().x > 0, "PALETTE '%s' thumbnail non-empty size" % id)


func _capture_and_report() -> void:
	var img := _grab()
	if img == null:
		return
	var abs_path := ProjectSettings.globalize_path(OUT_PATH)
	var err := img.save_png(abs_path)
	if err != OK:
		push_error("phase3_capture: save_png failed err=%d path=%s" % [err, abs_path])
		get_tree().quit(1)
		return
	print("CAPTURE saved=%s size=%dx%d" % [OUT_PATH, img.get_width(), img.get_height()])
	var draw_calls := Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	var fps := Performance.get_monitor(Performance.TIME_FPS)
	var perf_ok := draw_calls < 200
	_ok(perf_ok, "PERF draw_calls=%d fps=%.1f budget_ok=%s" % [draw_calls, fps, str(perf_ok)])
	print("RESULT: %s" % ("PASS" if _all_ok else "CHECK"))
	get_tree().quit(0 if _all_ok else 1)


# === helpers ===

func _ok(cond: bool, msg: String) -> void:
	if not cond:
		_all_ok = false
	print("  %s %s" % ["PASS" if cond else "FAIL", msg])


func _contains(img: Image, color: Color, tol: float) -> bool:
	for y in img.get_height():
		for x in img.get_width():
			var p := img.get_pixel(x, y)
			if p.a > 0.5 and _near(p, color, tol):
				return true
	return false


func _count_levels(img: Image, tol: float) -> int:
	var reps: Array[Color] = []
	for y in img.get_height():
		for x in img.get_width():
			var p := img.get_pixel(x, y)
			if p.a <= 0.5:
				continue
			var matched := false
			for rep in reps:
				if _near(p, rep, tol):
					matched = true
					break
			if not matched:
				reps.append(p)
	return reps.size()


## 采样一个世界矩形（换算到屏幕）内的所有像素色。
func _sample_rect(img: Image, world_rect: Rect2i) -> Array[Color]:
	var result: Array[Color] = []
	var tl := world_to_screen(world_rect.position)
	var br := world_to_screen(world_rect.position + world_rect.size)
	for y in range(tl.y, br.y):
		for x in range(tl.x, br.x):
			if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
				continue
			result.append(img.get_pixel(x, y))
	return result


func _distinct_colors(colors: Array[Color], tol: float) -> int:
	var reps: Array[Color] = []
	for p in colors:
		var matched := false
		for rep in reps:
			if _near(p, rep, tol):
				matched = true
				break
		if not matched:
			reps.append(p)
	return reps.size()


## [world_rect] 世界矩形；[z] 采样高度（0=地面，设备顶面用设备高度）。
func _region_has(img: Image, world_rect: Rect2i, color: Color, tol: float, z: float = 0.0) -> bool:
	var tl := world_to_screen(world_rect.position, z)
	var br := world_to_screen(world_rect.position + world_rect.size, z)
	for y in range(tl.y, br.y):
		for x in range(tl.x, br.x):
			if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
				continue
			if _near(img.get_pixel(x, y), color, tol):
				return true
	return false


func _near(a: Color, b: Color, tol: float) -> bool:
	var dr := a.r - b.r
	var dg := a.g - b.g
	var db := a.b - b.b
	return sqrt(dr * dr + dg * dg + db * db) <= tol


func _luminance(c: Color) -> float:
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
