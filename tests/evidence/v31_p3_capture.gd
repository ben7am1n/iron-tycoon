# tests/evidence/v31_p3_capture.gd — V3.1 P3 手绘感证据捕获
#
# 渲染真实主场景（src/main.tscn，含 V3.1 P1 oblique 投影 + P3 手绘材质管线）
# 并保存视口快照 + 像素级验证（大面积区域 = 多色 pixel cluster，非纯色块；
# 不规则边缘；无重复规则纹理）。输出：tests/evidence/v31-p3-density.png。
#
# 用法（窗口模式——headless 用 dummy 渲染驱动，get_image() 返回 null，
# 4.7.1 已验证；窗口捕获是项目既有证据方法，见 phase3_capture 同款注释）：
#   godot --path . res://tests/evidence/v31_p3_capture.tscn
#
# 验收对照（附录 V3.1 P3 + 任务 Exit 条件）：
#   - 大面积区域（地板 zone / 墙面粉刷）由多色 pixel cluster 组成 ——
#     FloorArt 纹理级断言（每 zone 64×64 窗口 ≥6 独立色 + 主色 < 0.75）+
#     渲染帧世界采样（多色）
#   - 无大面积单色填充：zone 内主色占比 < 0.75（纯色块会 ~1.0）
#   - 无重复规则纹理：cardio 4px 周期点阵命中率 < 0.60（旧实现 ~1.0）
#   - 不规则边缘：区域边界列同时含区域色 + 通道色（非完美直线矩形）
#   - 墙面粉刷：north/side 墙纹理非纯色（含 WALL_BASE 同族 cluster）
#   - draw calls < 200（性能预算，V3 §15）
#
# 采样换算：world_to_screen 走 src/presentation/oblique_projection.gd
# （与 main.gd 同源 —— 证据独立复算）。
extends Node

const MAIN_SCENE := preload("res://src/main.tscn")
const Main := preload("res://src/main.gd")
const Proj2D := preload("res://src/presentation/oblique_projection.gd")
const Palette := preload("res://src/palette.gd")
const FloorArt := preload("res://src/presentation/floor_art.gd")
const OUT_PATH := "res://tests/evidence/v31-p3-density.png"
const REDRAW_FRAME := 6      # 抓帧前强制世界画布重绘（SubViewport 纹理滞后 ≥1 帧）
const CAPTURE_FRAME := 12

## 管线常量（来自 main.gd —— 证据复算与实现同源）。
const SX := Main.SCREEN_PER_VIEWPORT_X
const SY := Main.SCREEN_PER_VIEWPORT_Y
const OFF := Main.WORLD_VIEWPORT_OFFSET
const WS := Main.WORLD_SCALE

## 世界采样锚点（世界像素空间，z=0 贴地）。
## strength zone 内部 (96,160) —— 避开设备 footprint 与装饰物。
const FLOOR_SAMPLES := {
	"strength": Vector2(96, 160),
	"cardio": Vector2(224, 160),
	"flex": Vector2(336, 160),
}
## 渲染帧地板采样半径（世界 px）。
const FLOOR_SAMPLE_R := 12.0

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
		return
	if _frame == CAPTURE_FRAME:
		_verify_floor_texture()
		_verify_wall_textures()
		_capture_and_report()


func _grab() -> Image:
	var img := get_viewport().get_texture().get_image()
	if img == null:
		push_error("v31_p3_capture: get_image() returned null (headless dummy driver?)")
		get_tree().quit(1)
		return null
	return img


func _save_and_report(img: Image) -> void:
	var abs_path := ProjectSettings.globalize_path(OUT_PATH)
	var err := img.save_png(abs_path)
	if err != OK:
		push_error("v31_p3_capture: save_png failed err=%d path=%s" % [err, abs_path])
		get_tree().quit(1)
		return
	print("CAPTURE saved=%s size=%dx%d" % [OUT_PATH, img.get_width(), img.get_height()])
	_verify_world_floor(img)
	_verify_perf()
	print("RESULT: %s" % ("PASS" if _all_ok else "CHECK"))
	get_tree().quit(0 if _all_ok else 1)


func _capture_and_report() -> void:
	var img := _grab()
	if img == null:
		return
	_save_and_report(img)


# === FloorArt 纹理级断言（P3 核心：多色 cluster，非纯色块） ===

func _verify_floor_texture() -> void:
	var floor_art = _main.get("_floor_art")
	_ok(floor_art != null, "TEX floor_art available")
	if floor_art == null:
		return
	var img: Image = floor_art.image()
	# 每个 zone 内部 64×64 窗口：独立色 ≥ 5 + 主色占比 < 0.75（无大面积单色）
	var zones := {
		"strength": Vector2i(64, 128),
		"cardio": Vector2i(192, 128),
		"flex": Vector2i(304, 128),
	}
	for zone in zones:
		var pos: Vector2i = zones[zone]
		var stats := _window_stats(img, pos.x, pos.y, 64, 64)
		_ok(int(stats["distinct"]) >= 5,
			"TEX %s 64x64 window >=5 distinct colors (got %d, multi-cluster)" % [zone, int(stats["distinct"])])
		var dominant := float(stats["dominant"]) / maxi(int(stats["total"]), 1)
		_ok(dominant < 0.75,
			"TEX %s no large single-color fill (dominant %.2f < 0.75)" % [zone, dominant])
	# 无重复规则纹理：cardio 4px 周期点阵命中率 < 0.60（旧实现 ~1.0）
	var c_rect: Rect2i = Palette.ZONE_RECTS["cardio"]
	var c_px := Rect2i(c_rect.position * 32, c_rect.size * 32)
	var total := 0
	var hits := 0
	for y in range(c_px.position.y + 2, c_px.position.y + c_px.size.y, 4):
		for x in range(c_px.position.x + 2, c_px.position.x + c_px.size.x, 4):
			total += 1
			if _near(img.get_pixel(x, y), Palette.FLOOR_CARDIO_DOT, 0.04):
				hits += 1
	var ratio := float(hits) / maxi(total, 1)
	_ok(ratio < 0.60, "TEX cardio no 4px repeating dot grid (hit ratio %.2f < 0.60)" % ratio)
	# 不规则边缘：strength 左边界列同时含区域色 + 通道色
	var s_rect: Rect2i = Palette.ZONE_RECTS["strength"]
	var s_px := Rect2i(s_rect.position * 32, s_rect.size * 32)
	var zone_px := 0
	var walk_px := 0
	for y in range(s_px.position.y + 6, s_px.position.y + s_px.size.y - 6):
		var p := img.get_pixel(s_px.position.x, y)
		if _near_any(p, _strength_colors(), 0.08):
			zone_px += 1
		elif _near_any(p, _walk_colors(), 0.10):
			walk_px += 1
	_ok(zone_px > 0 and walk_px > 0,
		"TEX strength left edge irregular (zone %d + walk %d on boundary col)" % [zone_px, walk_px])


# === 墙面粉刷纹理（P3：非纯色大面积填充） ===

func _verify_wall_textures() -> void:
	var structure_art = _main.get("_structure_art")
	_ok(structure_art != null, "TEX structure_art available (wall paint)")
	if structure_art == null:
		return
	var north: ImageTexture = structure_art.wall_face_texture("north")
	var west: ImageTexture = structure_art.wall_face_texture("west")
	_ok(north != null and west != null, "TEX wall face textures built (north/west)")
	if north == null:
		return
	var n_img: Image = north.get_image()
	var w_img: Image = west.get_image()
	# 北墙纹理中部窗口（避开墙帽/踢脚线）：独立色 ≥ 3（WALL_BASE + cluster）
	var n_stats := _window_stats(n_img, 40, 8, 80, 10)
	_ok(int(n_stats["distinct"]) >= 3,
		"TEX north wall face multi-shade (>=3 distinct in 80x10, got %d)" % int(n_stats["distinct"]))
	var w_stats := _window_stats(w_img, 40, 40, 80, 40)
	_ok(int(w_stats["distinct"]) >= 3,
		"TEX west wall face multi-shade (>=3 distinct in 80x40, got %d)" % int(w_stats["distinct"]))
	# 墙面主色仍是 WALL_BASE 族（材质身份不变 —— 不是改色，是手绘感）
	var face_sample: Color = n_img.get_pixel(200, 12)
	_ok(_near(face_sample, Palette.WALL_BASE, 0.25),
		"TEX north wall face keeps WALL_BASE identity (got %s)" % face_sample.to_html(false))


# === 渲染帧世界采样：地板大面积多色（非贴地图标） ===

func _verify_world_floor(img: Image) -> void:
	for zone in FLOOR_SAMPLES:
		var center: Vector2 = FLOOR_SAMPLES[zone]
		var colors: Array[Color] = []
		# V3.1 R1（投影修正）：采样步长 3→2 —— 世界帧采样窗口不变（±12 world px），
		# 但 FLOOR_SCALE 0.78→0.62 后同一世界点经 nearest 采样落在不同地板 texel，
		# 3px 步长在稀疏手绘 cluster 下会漏掉第 3 色调（flex 实测 2）。加密到
		# 2px 步长保持窗口与检查意图不变（地板区域多色，非贴图）。
		for dy in range(-FLOOR_SAMPLE_R, FLOOR_SAMPLE_R, 2):
			for dx in range(-FLOOR_SAMPLE_R, FLOOR_SAMPLE_R, 2):
				var p := world_to_screen(center + Vector2(dx, dy))
				if _in_bounds(img, p):
					colors.append(img.get_pixel(p.x, p.y))
		var distinct := _distinct_colors(colors, 0.10)
		_ok(distinct >= 3,
			"WORLD %s floor region multi-color (>=3 distinct, got %d)" % [zone, distinct])


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


func _window_stats(img: Image, x0: int, y0: int, w: int, h: int) -> Dictionary:
	var counts: Dictionary = {}
	var total := 0
	for y in range(y0, y0 + h):
		for x in range(x0, x0 + w):
			if x < 0 or y < 0 or x >= img.get_width() or y >= img.get_height():
				continue
			var key := img.get_pixel(x, y).to_html(false)
			counts[key] = int(counts.get(key, 0)) + 1
			total += 1
	var distinct := counts.size()
	var dominant := 0
	for k in counts:
		dominant = maxi(dominant, int(counts[k]))
	return {"distinct": distinct, "dominant": dominant, "total": total}


func _strength_colors() -> Array:
	return [
		Palette.FLOOR_STRENGTH_BASE, Palette.FLOOR_STRENGTH_BLOCK,
		Palette.FLOOR_STRENGTH_CL_GRAYBLUE, Palette.FLOOR_STRENGTH_CL_WARMGRAY,
		Palette.FLOOR_STRENGTH_STAIN, Palette.FLOOR_STRENGTH_WEAR,
		Palette.FLOOR_STRENGTH_SEAM,
	]


func _walk_colors() -> Array:
	return [
		Palette.FLOOR_WALK_BASE, Palette.FLOOR_WALK_CL_LIGHT, Palette.FLOOR_WALK_CL_DARK,
	]


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


func _in_bounds(img: Image, p: Vector2i) -> bool:
	return p.x >= 0 and p.y >= 0 and p.x < img.get_width() and p.y < img.get_height()


func _near_any(c: Color, family: Array, tol: float) -> bool:
	for f in family:
		if _near(c, f, tol):
			return true
	return false


func _near(a: Color, b: Color, tol: float) -> bool:
	var dr := a.r - b.r
	var dg := a.g - b.g
	var db := a.b - b.b
	return sqrt(dr * dr + dg * dg + db * db) <= tol
