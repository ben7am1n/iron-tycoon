# tests/evidence/v31_r4_capture.gd — V3.1 R4 暖色灯光源可辨识 + 投光关系证据
#
# 渲染真实主场景（src/main.tscn，含 V3.1 P1 oblique 投影 + P4 pixel-based
# lighting）并保存：
#   1. tests/evidence/v31-r4-lighting.png —— 渲染帧（光源物件 + 灯下投光关系，
#      冷色阴影）
#   2. tests/evidence/v31-r4-lightmap.png —— LightingLayer 静态 light map
#   3. tests/evidence/v31-r4-projected-lightmap.png —— 投影空间灯泡→落点光束
#
# 验收对照（附录 V3.1 P4 灯光 / R4 门禁「无辨识暖色室内灯光源/投光关系」）：
#   - 光源可辨识：吊灯灯罩受光体（LAMP_SHADE_LIT 暖橙金）在渲染帧中可见
#     （灯罩本体亮起 —— 不再暗色剪影）；落地灯（warm_lamp）灯下暖池可见
#   - 投光关系：灯下（LIGHT_POOLS 中心）light map 暖亮 alpha > 远处地板；
#     渲染帧灯下区域色温/亮度 > 同材质远离灯区域（灯下亮、远处暗）
#   - 冷色阴影：墙边暗角冷蓝灰（b > r）像素存在（V3 §15 cool colored
#     shadows）；窗边冷光渗透（LIGHT_WINDOW_COOL）存在
#   - 负约束：灯池 = hash 散射 cluster（同心环 alpha 非均匀 + 覆盖率
#     < 0.95 —— 无大面积半透明圆形光斑）；无 draw_circle
#   - 性能：draw calls < 200（V3 §15）
#
# 用法（窗口模式——headless dummy 驱动下 get_image() 返回 null，项目既有
# 证据方法，见 v31_p4_capture.gd 同款注释）：
#   godot --path . res://tests/evidence/v31_r4_capture.tscn
#
# 采样换算：world_to_screen 走 src/presentation/oblique_projection.gd
# （与 main.gd 同源 —— 证据独立复算）。
extends Node

const MAIN_SCENE := preload("res://src/main.tscn")
const Main := preload("res://src/main.gd")
const Proj2D := preload("res://src/presentation/oblique_projection.gd")
const Palette := preload("res://src/palette.gd")
const WorldLayout := preload("res://src/presentation/world_layout.gd")
const OUT_PATH := "res://tests/evidence/v31-r4-lighting.png"
const LIGHTMAP_PATH := "res://tests/evidence/v31-r4-lightmap.png"
const PROJECTED_LIGHTMAP_PATH := "res://tests/evidence/v31-r4-projected-lightmap.png"
const REDRAW_FRAME := 6      # 抓帧前强制世界画布重绘（SubViewport 纹理滞后 ≥1 帧）
const CAPTURE_FRAME := 120   # 给 FPS monitor 约 2 秒稳定窗口，避免启动期虚假 1-2fps

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
## 落地灯短斜投光落点（WorldLayout.FLOOR_LIGHT.landing）。
const WARM_LAMP_CENTER := Vector2(330, 242)
## 窗光锥内采样点（window_1 下方，冷光渗透）：window_1 (96,4,56,18) 底部 y=22，
## 光锥向下展开 —— 取 (120, 60)。
const WINDOW_SEEP_SAMPLE := Vector2(120, 60)

var _frame := 0
var _captured := false
var _main: Node = null
var _all_ok := true


## 世界坐标（可带高度 z）→ 屏幕坐标（V3.1 P1 oblique 投影，独立复算）。
func world_to_screen(w: Vector2, z: float = 0.0) -> Vector2i:
	var v := Proj2D.world_to_screen(w, OFF, WS, Vector2(SX, SY), z)
	return Vector2i(roundi(v.x), roundi(v.y))


## 投影后 canvas 坐标 → 最终屏幕坐标（billboard 灯泡局部点不能用 world_to_screen）。
func canvas_to_screen(p: Vector2) -> Vector2i:
	var v := (p * WS + OFF) * Vector2(SX, SY)
	return Vector2i(roundi(v.x), roundi(v.y))


func hanging_light_canvas(index: int, local_key: String = "bulb_local") -> Vector2:
	var light: Dictionary = WorldLayout.HANGING_LIGHTS[index]
	var rect: Rect2i = light.get("rect", Rect2i())
	var local: Vector2 = light.get(local_key, Vector2.ZERO)
	return Proj2D.proj(rect.position.x, rect.position.y,
		float(light.get("height", 0.0))) + local


func _ready() -> void:
	_main = MAIN_SCENE.instantiate()
	add_child(_main)
	# 冻结模拟 tick：截图/呼吸光相位与帧等待时长无关，同输入输出稳定。
	var orch = _main.get("_orch")
	if orch != null and orch.time_system != null:
		orch.time_system.pause()


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
		push_error("v31_r4_capture: get_image() returned null (headless dummy driver?)")
		get_tree().quit(1)
		return null
	return img


func _save_and_report(img: Image) -> void:
	var abs_path := ProjectSettings.globalize_path(OUT_PATH)
	var err := img.save_png(abs_path)
	if err != OK:
		push_error("v31_r4_capture: save_png failed err=%d path=%s" % [err, abs_path])
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


# === LightMap 级验证（P4 核心：pixel-based，无圆形光斑 + R4 投光关系） ===

## 静态 light map 验证（导出 PNG + 像素断言）：
##   - 灯下暖亮 > 墙边冷暗（明暗差异：灯下亮、远处暗）
##   - 窗边冷光渗透（冷蓝灰 b>r）
##   - 灯池 = 散射 cluster：同心环 alpha 非均匀（std 大）且覆盖率 < 0.95
func _verify_light_map() -> void:
	var lighting := _main.get_node_or_null("WorldViewport/WorldRoot/LightingLayer")
	_ok(lighting != null, "LIGHTMAP LightingLayer available")
	if lighting == null:
		return
	var img: Image = lighting.call("light_map_image")
	_ok(img != null, "LIGHTMAP light_map_image() available")
	if img == null:
		return
	var lm_path := ProjectSettings.globalize_path(LIGHTMAP_PATH)
	var lm_err := img.save_png(lm_path)
	_ok(lm_err == OK, "LIGHTMAP exported %s" % LIGHTMAP_PATH)

	# 投影空间光束单独导出：证明高处灯泡→中段→地面落点连续，而不是 light map
	# 中有锥但最终帧与灯具断开。
	var projected: Image = lighting.call("projected_light_map_image")
	var projected_origin: Vector2 = lighting.call("projected_light_map_origin")
	_ok(projected != null, "PROJECTED light map available")
	if projected != null:
		var projected_path := ProjectSettings.globalize_path(PROJECTED_LIGHTMAP_PATH)
		_ok(projected.save_png(projected_path) == OK,
			"PROJECTED exported %s" % PROJECTED_LIGHTMAP_PATH)
		for i in WorldLayout.HANGING_LIGHTS.size():
			var source := hanging_light_canvas(i)
			var landing_world: Vector2 = WorldLayout.HANGING_LIGHTS[i].get("landing", Vector2.ZERO)
			var landing := Proj2D.project_world(landing_world)
			_ok(_count_warm_projected(projected, source - projected_origin, 5) > 0,
				"PROJECTED lamp %d source core warm" % i)
			_ok(_count_warm_projected(projected,
				source.lerp(landing, 0.50) - projected_origin, 8) > 0,
				"PROJECTED lamp %d shaft middle warm" % i)
			_ok(_count_warm_projected(projected,
				source.lerp(landing, 0.88) - projected_origin, 10) > 0,
				"PROJECTED lamp %d shaft reaches landing" % i)

	# 灯下暖亮像素存在（热核 + 光晕）：灯池中心 12×12 窗口
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
	_ok(lamp_avg_a > 0.06, "LIGHTMAP under-lamp stronger than old 0.03 (avg alpha %.3f)" % lamp_avg_a)

	# 墙边冷暗（冷色阴影）：左墙边带冷蓝灰像素
	var edge_cool := 0
	for dy in range(-6, 7):
		for dx in range(0, 8):
			var p := Vector2i(int(WALL_EDGE_SAMPLE.x) + dx, int(WALL_EDGE_SAMPLE.y) + dy)
			if p.x < 0 or p.y < 0 or p.x >= img.get_width() or p.y >= img.get_height():
				continue
			var c: Color = img.get_pixel(p.x, p.y)
			if c.a > 0.03 and c.b > c.r:
				edge_cool += 1
	_ok(edge_cool > 0, "LIGHTMAP wall-edge cool-dark pixels exist (近墙冷色阴影, cool %d)" % edge_cool)

	# 明暗差异：灯下平均 alpha > 墙边平均 alpha（灯下亮、远处暗）
	var edge_sum := 0.0
	var edge_n := 0
	for dy in range(-6, 7):
		for dx in range(0, 8):
			var p := Vector2i(int(WALL_EDGE_SAMPLE.x) + dx, int(WALL_EDGE_SAMPLE.y) + dy)
			if p.x < 0 or p.y < 0 or p.x >= img.get_width() or p.y >= img.get_height():
				continue
			edge_sum += img.get_pixel(p.x, p.y).a
			edge_n += 1
	var edge_avg_a := edge_sum / maxf(edge_n, 1)
	_ok(lamp_avg_a > edge_avg_a,
		"LIGHTMAP lamp avg alpha %.3f > wall-edge avg alpha %.3f (灯下亮于墙边)" % [lamp_avg_a, edge_avg_a])

	# 窗边冷光渗透（R4 冷暖对比）：window_1 光锥内冷蓝灰像素存在
	var window_cool := 0
	for dy in range(-5, 6):
		for dx in range(-5, 6):
			var p := Vector2i(int(WINDOW_SEEP_SAMPLE.x) + dx, int(WINDOW_SEEP_SAMPLE.y) + dy)
			if p.x < 0 or p.y < 0 or p.x >= img.get_width() or p.y >= img.get_height():
				continue
			var c: Color = img.get_pixel(p.x, p.y)
			if c.a > 0.02 and c.b > c.r:
				window_cool += 1
	_ok(window_cool > 0, "LIGHTMAP window cool seepage pixels exist (窗边冷光渗透, cool %d)" % window_cool)

	# 落地灯暖池（R4 光源可辨识 —— 落地灯灯下暖色提亮）
	var floor_lamp_warm := 0
	for dy in range(-8, 9):
		for dx in range(-8, 9):
			var p := Vector2i(int(WARM_LAMP_CENTER.x) + dx, int(WARM_LAMP_CENTER.y) + dy)
			if p.x < 0 or p.y < 0 or p.x >= img.get_width() or p.y >= img.get_height():
				continue
			var c: Color = img.get_pixel(p.x, p.y)
			if c.a > 0.03 and c.r > c.b:
				floor_lamp_warm += 1
	_ok(floor_lamp_warm > 0, "LIGHTMAP floor-lamp warm pool present (落地灯灯下暖池, warm %d)" % floor_lamp_warm)

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


# === 渲染帧级验证（光源可辨识 + 投光关系 + 冷暖对比） ===

## 渲染帧验证：
##   - 吊灯灯罩受光体在帧中可见（暖橙金 LAMP_SHADE_LIT 附近色命中）——
##     光源物件可辨识（第三眼 #1 直接修复）
##   - 灯池区域比同材质远离灯区域更暖亮（受光面变暖/变亮 —— 投光关系）
##   - 落地灯灯下暖色提亮（暖池经 floor transform 投影到屏幕）
func _verify_world_frame(img: Image) -> void:
	# 吊灯完整 fixture：以真实 billboard 灯泡点为中心扫描暖橙灯罩/暖白核心。
	var fixture_found := false
	var source_canvas := hanging_light_canvas(0)
	var fscreen := canvas_to_screen(source_canvas)
	for dy in range(-24, 25):
		for dx in range(-24, 25):
			var sx := fscreen.x + dx
			var sy := fscreen.y + dy
			if sx < 0 or sy < 0 or sx >= img.get_width() or sy >= img.get_height():
				continue
			var c := img.get_pixel(sx, sy)
			if _near(c, Palette.LAMP_SHADE_LIT, 0.22):
				fixture_found = true
				break
		if fixture_found:
			break
	_ok(fixture_found, "WORLD hanging lamp shade lit body visible @screen(%d,%d) (光源物件可辨识)" % [fscreen.x, fscreen.y])

	# 最终帧中的方向关系：从灯泡到地面落点沿线三段都有暖亮像素。
	var landing_canvas := Proj2D.project_world(LAMP_CENTER)
	for t in [0.28, 0.52, 0.78]:
		var beam_screen := canvas_to_screen(source_canvas.lerp(landing_canvas, t))
		_ok(_count_warm_frame(img, beam_screen, 12) > 0,
			"WORLD source-to-landing shaft warm at t=%.2f @screen(%d,%d)" %
			[t, beam_screen.x, beam_screen.y])

	# 灯下 vs 同材质远离灯：亮度 + 暖度对比（strength zone 内部）。
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

	# 落地灯灯体：竖直 billboard 的灯泡/暖橙灯罩在最终帧可辨识。
	var floor_cfg: Dictionary = WorldLayout.FLOOR_LIGHT
	var floor_base: Vector2 = floor_cfg.get("base", Vector2.ZERO)
	var floor_source_canvas := Proj2D.proj(floor_base.x, floor_base.y,
		float(floor_cfg.get("height", 0.0))) + (floor_cfg.get("bulb_local", Vector2.ZERO) as Vector2)
	var floor_source_screen := canvas_to_screen(floor_source_canvas)
	_ok(_count_warm_frame(img, floor_source_screen, 18) > 4,
		"WORLD floor-lamp glowing shade/body visible @screen(%d,%d)" %
		[floor_source_screen.x, floor_source_screen.y])

	# 落地灯短斜投光落点窗口内暖色（r>b）像素存在。
	var floor_lamp_found := false
	var fp := world_to_screen(WARM_LAMP_CENTER)
	for dy in range(-6, 7):
		for dx in range(-6, 7):
			var sx := fp.x + dx
			var sy := fp.y + dy
			if sx < 0 or sy < 0 or sx >= img.get_width() or sy >= img.get_height():
				continue
			var c := img.get_pixel(sx, sy)
			if c.r > c.b + 0.02 and _luminance(c) > 0.30:
				floor_lamp_found = true
				break
		if floor_lamp_found:
			break
	_ok(floor_lamp_found, "WORLD floor-lamp warm pool visible @screen(%d,%d) (落地灯投光)" % [fp.x, fp.y])


func _verify_perf() -> void:
	var draw_calls := Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	var fps := Performance.get_monitor(Performance.TIME_FPS)
	var perf_ok := draw_calls < 200 and fps >= 55.0
	_ok(perf_ok, "PERF draw_calls=%d (<200) fps=%.1f (60fps target, >=55 stable) budget_ok=%s" %
		[draw_calls, fps, str(perf_ok)])


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


func _count_warm_projected(img: Image, p: Vector2, radius: int) -> int:
	var found := 0
	for y in range(maxi(int(p.y) - radius, 0), mini(int(p.y) + radius + 1, img.get_height())):
		for x in range(maxi(int(p.x) - radius, 0), mini(int(p.x) + radius + 1, img.get_width())):
			var c := img.get_pixel(x, y)
			if c.a > 0.04 and c.r > c.b:
				found += 1
	return found


func _count_warm_frame(img: Image, p: Vector2i, radius: int) -> int:
	var found := 0
	for y in range(maxi(p.y - radius, 0), mini(p.y + radius + 1, img.get_height())):
		for x in range(maxi(p.x - radius, 0), mini(p.x + radius + 1, img.get_width())):
			var c := img.get_pixel(x, y)
			if c.r > c.b + 0.045 and _luminance(c) > 0.24:
				found += 1
	return found


func _in_bounds(img: Image, p: Vector2i) -> bool:
	return p.x >= 0 and p.y >= 0 and p.x < img.get_width() and p.y < img.get_height()


func _near(a: Color, b: Color, tol: float) -> bool:
	var dr := a.r - b.r
	var dg := a.g - b.g
	var db := a.b - b.b
	return sqrt(dr * dr + dg * dg + db * db) <= tol
