# tests/evidence/v31_p4_capture.gd — V3.1 P4 像素级光照证据捕获
#
# 渲染真实主场景（src/main.tscn，含 V3.1 P1 oblique 投影 + P3 手绘材质 +
# P4 pixel-based lighting）并保存视口快照 + 静态 light map，像素级验证：
#   - 无大面积圆形 gradient 光斑（light map 灯池为 hash 散射 cluster，
#     非实心半透明圆 —— 采样环 alpha 非均匀）
#   - 墙边像素 vs 灯下像素明暗差异（light map 直接采样：墙边冷暗 alpha、
#     灯下暖亮 alpha）
#   - 设备高光/屏幕亮色局部存在（渲染帧采样 treadmill 顶面暖高光 +
#     控制台青蓝屏幕像素）
#   - 渲染帧灯池区域比同材质远离灯区域更暖亮（受光面变暖/变亮）
#   - draw calls < 200（性能预算，V3 §15）
#
# 输出：
#   tests/evidence/v31-p4-lighting.png  —— 渲染帧（主场景视口）
#   tests/evidence/v31-p4-lightmap.png  —— LightingLayer 静态 light map
#
# 用法（窗口模式——headless 用 dummy 渲染驱动，get_image() 返回 null，
# 4.7.1 已验证；窗口捕获是项目既有证据方法，见 phase3_capture 同款注释）：
#   godot --path . res://tests/evidence/v31_p4_capture.tscn
#
# 采样换算：world_to_screen 走 src/presentation/oblique_projection.gd
# （与 main.gd 同源 —— 证据独立复算）。
extends Node

const MAIN_SCENE := preload("res://src/main.tscn")
const Main := preload("res://src/main.gd")
const Proj2D := preload("res://src/presentation/oblique_projection.gd")
const Palette := preload("res://src/palette.gd")
const WorldLayout := preload("res://src/presentation/world_layout.gd")
const OUT_PATH := "res://tests/evidence/v31-p4-lighting.png"
const LIGHTMAP_PATH := "res://tests/evidence/v31-p4-lightmap.png"
const REDRAW_FRAME := 6      # 抓帧前强制世界画布重绘（SubViewport 纹理滞后 ≥1 帧）
const CAPTURE_FRAME := 12

## 管线常量（来自 main.gd —— 证据复算与实现同源）。
const SX := Main.SCREEN_PER_VIEWPORT_X
const SY := Main.SCREEN_PER_VIEWPORT_Y
const OFF := Main.WORLD_VIEWPORT_OFFSET
const WS := Main.WORLD_SCALE

## 世界采样锚点（世界像素空间）。
## 灯池中心（WorldLayout.LIGHT_POOLS[0] = (86,170)，力量区吊灯下方）。
const LAMP_CENTER := Vector2(86, 170)
## 同材质远离灯区域候选点（strength zone 内部，远离灯池与窗光锥；用作受光
## 对比，取亮度最小者 —— 会员/装饰只会变亮，min 对动态干扰稳健）。
const FAR_SAME_ZONE_CANDIDATES := [
	Vector2(120, 90),
	Vector2(60, 130),
	Vector2(130, 140),
	Vector2(60, 200),
]
## 墙边暗角带内采样（左侧墙 x=10，strength zone 边缘 y=170）。
const WALL_EDGE_SAMPLE := Vector2(10, 170)
## treadmill(2,2) footprint = (64,64,64,32)；顶面 z=30（EQUIP_HEIGHTS）。
const TM_RECT := Rect2i(64, 64, 64, 32)
const TM_HEIGHT := 30.0

var _frame := 0
var _captured := false
var _main: Node = null
var _all_ok := true


## 世界坐标（可带高度 z）→ 屏幕坐标（V3.1 P1 oblique 投影，独立复算）。
func world_to_screen(w: Vector2, z: float = 0.0) -> Vector2i:
	var v := Proj2D.world_to_screen(w, OFF, WS, Vector2(SX, SY), z)
	return Vector2i(roundi(v.x), roundi(v.y))


func _ready() -> void:
	_main = MAIN_SCENE.instantiate()
	add_child(_main)


func _process(_delta: float) -> void:
	_frame += 1
	if _captured:
		return
	if _frame == REDRAW_FRAME:
		var canvas := _main.get_node_or_null("WorldViewport/WorldRoot/WorldCanvas")
		if canvas != null:
			canvas.queue_redraw()
		var lighting := _main.get_node_or_null("WorldViewport/WorldRoot/LightingLayer")
		if lighting != null:
			lighting.queue_redraw()
		return
	if _frame == CAPTURE_FRAME:
		_verify_light_map()
		_capture_and_report()


func _grab() -> Image:
	var img := get_viewport().get_texture().get_image()
	if img == null:
		push_error("v31_p4_capture: get_image() returned null (headless dummy driver?)")
		get_tree().quit(1)
		return null
	return img


func _save_and_report(img: Image) -> void:
	var abs_path := ProjectSettings.globalize_path(OUT_PATH)
	var err := img.save_png(abs_path)
	if err != OK:
		push_error("v31_p4_capture: save_png failed err=%d path=%s" % [err, abs_path])
		get_tree().quit(1)
		return
	print("CAPTURE saved=%s size=%dx%d" % [OUT_PATH, img.get_width(), img.get_height()])
	_verify_world_frame(img)
	_verify_perf()
	print("RESULT: %s" % ("PASS" if _all_ok else "CHECK"))
	get_tree().quit(0 if _all_ok else 1)


func _capture_and_report() -> void:
	var img := _grab()
	if img == null:
		return
	_save_and_report(img)


# === LightMap 级验证（P4 核心：pixel-based，无圆形光斑） ===

## 静态 light map 验证（导出 PNG + 像素断言）：
##   - 墙边冷暗像素存在（alpha > 0，冷色 b>r）
##   - 灯下暖亮像素存在（alpha > 0，暖色 r>b）且强于墙边（明暗差异）
##   - 灯池 = 散射 cluster：以灯池中心为圆心采样多个同心环，环上 alpha
##     非均匀（std 大）且覆盖率 < 0.95（实心半透明圆会接近 1.0 均匀覆盖）
func _verify_light_map() -> void:
	var lighting := _main.get_node_or_null("WorldViewport/WorldRoot/LightingLayer")
	_ok(lighting != null, "LIGHTMAP LightingLayer available")
	if lighting == null:
		return
	var img: Image = lighting.call("light_map_image")
	_ok(img != null, "LIGHTMAP light_map_image() available")
	if img == null:
		return
	# 导出 light map PNG（供 PIL 独立复算）
	var lm_path := ProjectSettings.globalize_path(LIGHTMAP_PATH)
	var lm_err := img.save_png(lm_path)
	_ok(lm_err == OK, "LIGHTMAP exported %s" % LIGHTMAP_PATH)

	# 墙边冷暗像素（左侧墙边带内采样）
	var edge_warm := 0
	var edge_cool := 0
	for dy in range(-6, 7):
		for dx in range(0, 8):
			var p := Vector2i(int(WALL_EDGE_SAMPLE.x) + dx, int(WALL_EDGE_SAMPLE.y) + dy)
			if p.x < 0 or p.y < 0 or p.x >= img.get_width() or p.y >= img.get_height():
				continue
			var c: Color = img.get_pixel(p.x, p.y)
			if c.a > 0.03:
				if c.b > c.r:
					edge_cool += 1
				elif c.r > c.b:
					edge_warm += 1
	_ok(edge_cool > 0, "LIGHTMAP wall-edge cool-dark pixels exist (近墙像素变暗, cool %d)" % edge_cool)

	# 灯下暖亮像素 + 明暗差异：灯池中心 12×12 窗口统计暖亮
	var lamp_warm := 0
	var lamp_alpha_sum := 0.0
	for dy in range(-6, 7):
		for dx in range(-6, 7):
			var p := Vector2i(int(LAMP_CENTER.x) + dx, int(LAMP_CENTER.y) + dy)
			var c: Color = img.get_pixel(p.x, p.y)
			if c.a > 0.03 and c.r > c.b:
				lamp_warm += 1
			lamp_alpha_sum += c.a
	var lamp_avg_a := lamp_alpha_sum / 169.0
	_ok(lamp_warm > 0, "LIGHTMAP under-lamp warm pixels exist (灯下稍亮, warm %d)" % lamp_warm)
	_ok(lamp_avg_a > 0.03, "LIGHTMAP under-lamp brighter than empty floor (avg alpha %.3f > 0.03)" % lamp_avg_a)

	# 无大面积半透明圆形光斑：灯池半径内同心环 alpha 覆盖率 < 0.95 且非均匀
	var center: Vector2 = LAMP_CENTER
	var r := int(WorldLayout.LIGHT_POOL_RADIUS)
	var ring_ratios: Array[float] = []
	for ring_r in [10, 22, 34, 44]:
		var covered := 0
		var total := 0
		var alphas: Array[float] = []
		for i in 48:
			var a := TAU * float(i) / 48.0
			var px := int(round(center.x + cos(a) * ring_r))
			var py := int(round(center.y + sin(a) * ring_r))
			if px < 0 or py < 0 or px >= img.get_width() or py >= img.get_height():
				continue
			total += 1
			var c: Color = img.get_pixel(px, py)
			alphas.append(c.a)
			if c.a > 0.02:
				covered += 1
		if total > 0:
			ring_ratios.append(float(covered) / float(total))
			# 环 alpha 非均匀（散射 cluster）：std > 0.01（实心圆会 ~0）
			var mean := 0.0
			for a2 in alphas:
				mean += a2
			mean /= float(alphas.size())
			var variance := 0.0
			for a2 in alphas:
				variance += (a2 - mean) * (a2 - mean)
			variance /= float(alphas.size())
			_ok(sqrt(variance) > 0.01,
				"LIGHTMAP ring r=%d alpha non-uniform (std %.3f > 0.01, scattered cluster)" % [ring_r, sqrt(variance)])
	_ok(ring_ratios.size() >= 3, "LIGHTMAP sampled >=3 concentric rings")
	for rr in ring_ratios:
		_ok(rr < 0.95, "LIGHTMAP ring coverage %.2f < 0.95 (not solid translucent circle)" % rr)


# === 渲染帧级验证（受光面变暖/设备高光/屏幕亮色） ===

## 渲染帧验证：
##   - 灯池区域（力量区灯下）比同材质远离灯区域更暖亮（受光面变暖/变亮）
##   - treadmill 顶面存在暖高光像素（EQUIP_HIGHLIGHT 族 —— 设备高光）
##   - treadmill 控制台存在青蓝屏幕像素（EQUIP_ACCENT_CYAN/EMISSIVE_CYAN）
func _verify_world_frame(img: Image) -> void:
	# 灯下 vs 同材质远离灯：亮度 + 暖度对比（strength zone 内部）。
	# 会员/装饰只会变亮 —— 多个候选点取最小亮度作「未受光地板」参考，
	# 对动态成员干扰稳健。
	var lamp_colors := _sample_window(img, LAMP_CENTER, 10, 3)
	var lamp_lum := _avg_luminance(lamp_colors)
	var lamp_warmness := _avg_warmness(lamp_colors)
	var far_min_lum := 1e9
	var far_min_warmness := 0.0
	for far in FAR_SAME_ZONE_CANDIDATES:
		var far_colors := _sample_window(img, far, 10, 3)
		far_min_lum = minf(far_min_lum, _avg_luminance(far_colors))
		far_min_warmness = minf(far_min_warmness, _avg_warmness(far_colors))
	_ok(lamp_lum > far_min_lum + 0.005,
		"WORLD lamp area brighter than far same-zone floor (lum %.3f > %.3f)" % [lamp_lum, far_min_lum])
	_ok(lamp_warmness > far_min_warmness + 0.002,
		"WORLD lamp area warmer than far same-zone floor (warm %.3f > %.3f, V3 §7 受光变暖)" % [lamp_warmness, far_min_warmness])

	# 设备顶面暖高光（EQUIP_HIGHLIGHT 族，#EADFB8 —— 设备边缘/顶面高光像素）。
	# 扫描整个顶面网格，取暖亮（r>b 且亮度高）像素 —— 高光像素局部存在。
	var highlight_count := 0
	for wy in range(TM_RECT.position.y, TM_RECT.position.y + TM_RECT.size.y, 2):
		for wx in range(TM_RECT.position.x, TM_RECT.position.x + TM_RECT.size.x, 2):
			var p := world_to_screen(Vector2(wx, wy), TM_HEIGHT)
			if not _in_bounds(img, p):
				continue
			var c := img.get_pixel(p.x, p.y)
			if c.r > c.b + 0.05 and _luminance(c) > 0.42:
				highlight_count += 1
	_ok(highlight_count > 0,
		"WORLD treadmill top warm highlight pixels present (设备高光, %d px)" % highlight_count)

	# 控制台青蓝屏幕像素（设备屏幕小范围亮色）
	var screen_found := false
	for dy in range(-3, 4):
		for dx in range(-3, 4):
			var p := world_to_screen(Vector2(TM_RECT.position.x + 16 + dx, TM_RECT.position.y + 28 + dy), TM_HEIGHT)
			if not _in_bounds(img, p):
				continue
			var c := img.get_pixel(p.x, p.y)
			if _near(c, Palette.EQUIP_ACCENT_CYAN, 0.16) or _near(c, Palette.EMISSIVE_CYAN, 0.16):
				screen_found = true
				break
		if screen_found:
			break
	_ok(screen_found, "WORLD treadmill console cyan screen pixels present (屏幕亮色)")


func _verify_perf() -> void:
	var draw_calls := Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	var fps := Performance.get_monitor(Performance.TIME_FPS)
	var perf_ok := draw_calls < 200
	_ok(perf_ok, "PERF draw_calls=%d fps=%.1f budget_ok=%s" % [draw_calls, fps, str(perf_ok)])


# === helpers ===

func _ok(cond: bool, msg: String) -> void:
	if not cond:
		_all_ok = false
	print("  %s %s" % ["PASS" if cond else "FAIL", msg])


func _sample_window(img: Image, world_center: Vector2, world_r: int, step: int) -> Array[Color]:
	var out: Array[Color] = []
	for dy in range(-world_r, world_r + 1, step):
		for dx in range(-world_r, world_r + 1, step):
			var p := world_to_screen(world_center + Vector2(dx, dy))
			if _in_bounds(img, p):
				out.append(img.get_pixel(p.x, p.y))
	return out


func _avg_luminance(colors: Array[Color]) -> float:
	if colors.is_empty():
		return 0.0
	var sum := 0.0
	for c in colors:
		sum += _luminance(c)
	return sum / float(colors.size())


func _luminance(c: Color) -> float:
	return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b


func _avg_warmness(colors: Array[Color]) -> float:
	if colors.is_empty():
		return 0.0
	var sum := 0.0
	for c in colors:
		sum += c.r - c.b
	return sum / float(colors.size())


func _in_bounds(img: Image, p: Vector2i) -> bool:
	return p.x >= 0 and p.y >= 0 and p.x < img.get_width() and p.y < img.get_height()


func _near(a: Color, b: Color, tol: float) -> bool:
	var dr := a.r - b.r
	var dg := a.g - b.g
	var db := a.b - b.b
	return sqrt(dr * dr + dg * dg + db * db) <= tol
