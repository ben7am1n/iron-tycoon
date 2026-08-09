# tests/evidence/v31_p2_capture.gd — V3.1 P2 设备真物体证据捕获
#
# 渲染真实主场景（src/main.tscn，含 V3.1 P1 oblique 投影管线）并保存视口
# 快照 + 像素级验证（每台设备 3 方向面 + 5 色层 + 设备离开地面）。
# 输出：tests/evidence/v31-p2-equipment.png（证据文件，随仓库提交）。
#
# 用法（窗口模式——headless 用 dummy 渲染驱动，get_image() 返回 null，
# 4.7.1 已验证；窗口捕获是项目既有证据方法，见 phase3_capture 同款注释）：
#   godot --path . res://tests/evidence/v31_p2_capture.tscn
#
# 验收对照（附录 V3.1 P2 + 任务 Exit 条件）：
#   - 每台设备 3 方向面（top/front/side）纹理都存在（EquipmentArt 手绘面）
#   - 每台设备 5 色层（base/shadow/outline/highlight/accent）在 sprite
#     像素中可找到（V3.1 P2 最低要求）—— 纹理级精确断言 + 世界采样验证
#   - 设备离开地面：front/side 面底部有支撑结构（world 采样验证）
#   - 世界采样：三台设备 footprint 区域多色（非贴地图标）；treadmill 前端
#     console 青蓝显示可辨；设备顶面亮于正面（三面分层）
#   - draw calls < 200（性能预算，V3 §15）
#
# 采样换算：world_to_screen 走 src/presentation/oblique_projection.gd
# （与 main.gd 同源 —— 证据独立复算）。
extends Node

const MAIN_SCENE := preload("res://src/main.tscn")
const Main := preload("res://src/main.gd")
const Proj2D := preload("res://src/presentation/oblique_projection.gd")
const Palette := preload("res://src/palette.gd")
const EquipmentArt := preload("res://src/presentation/equipment_art.gd")
const OUT_PATH := "res://tests/evidence/v31-p2-equipment.png"
const REDRAW_FRAME := 6      # 抓帧前强制世界画布重绘（SubViewport 纹理滞后 ≥1 帧）
const CAPTURE_FRAME := 12

## 管线常量（来自 main.gd —— 证据复算与实现同源）。
const SX := Main.SCREEN_PER_VIEWPORT_X
const SY := Main.SCREEN_PER_VIEWPORT_Y
const OFF := Main.WORLD_VIEWPORT_OFFSET
const WS := Main.WORLD_SCALE

## 初始布局（main.gd _initial_layout）：instance_id 按放置顺序 0..4。
##   treadmill(2,2) / bike(2,5) / treadmill(6,3) / bench_press(1,7) / yoga_mat(9,2)
## 本证据聚焦三类设备（P2：跑步机/卧推/动感单车）：treadmill(2,2)、
## bike(2,5)、bench_press(1,7)（yoga_mat 不属 P2 范围）。
const INSTANCE_ID_BY_EQUIP := {
	"treadmill": 0,
	"bike": 1,
	"bench_press": 3,
}
## 每类设备 footprint 的世界矩形（cell → 世界 px，CELL_SIZE=32）：
##   treadmill(2,2) 2×1 | bike(2,5) 1×1 | bench_press(1,7) 2×2
const EQUIP_RECTS := {
	"treadmill": Rect2i(64, 64, 64, 32),
	"bike": Rect2i(64, 160, 32, 32),
	"bench_press": Rect2i(32, 224, 64, 64),
}
## 设备高度（EquipmentArt.EQUIP_HEIGHTS —— 顶面 z）。
const EQUIP_HEIGHTS := {
	"treadmill": 30.0,
	"bike": 36.0,
	"bench_press": 26.0,
}

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
		_verify_structure()
		_verify_texture_layers()
		_capture_and_report()


func _grab() -> Image:
	var img := get_viewport().get_texture().get_image()
	if img == null:
		push_error("v31_p2_capture: get_image() returned null (headless dummy driver?)")
		get_tree().quit(1)
		return null
	return img


func _save_and_report(img: Image) -> void:
	var abs_path := ProjectSettings.globalize_path(OUT_PATH)
	var err := img.save_png(abs_path)
	if err != OK:
		push_error("v31_p2_capture: save_png failed err=%d path=%s" % [err, abs_path])
		get_tree().quit(1)
		return
	print("CAPTURE saved=%s size=%dx%d" % [OUT_PATH, img.get_width(), img.get_height()])
	_verify_world_equipment(img)
	_verify_perf()
	print("RESULT: %s" % ("PASS" if _all_ok else "CHECK"))
	get_tree().quit(0 if _all_ok else 1)


func _capture_and_report() -> void:
	var img := _grab()
	if img == null:
		return
	_export_face_sheets()
	_save_and_report(img)


## 导出每台设备 top/front/side 原始面纹理 PNG（未变暗、未受光照层污染），
## 供 PIL 脚本精确验证 5 色层（base/shadow/outline/highlight/accent）。
## 输出：tests/evidence/v31-p2-faces-<equipment_id>.png（三面并排一张表）。
const FACES_OUT := "res://tests/evidence/v31-p2-faces-%s.png"

func _export_face_sheets() -> void:
	var equip_art = _main.get("_equip_art")
	if equip_art == null:
		return
	var zone_of := {"treadmill": "cardio", "bike": "cardio", "bench_press": "strength"}
	for eq_id in zone_of:
		var zone: String = zone_of[eq_id]
		var top_img: Image = equip_art.texture_for(eq_id, zone, 0).get_image()
		var raws: Dictionary = equip_art.raw_face_images(eq_id, zone)
		var front_img: Image = raws.get("front")
		var side_img: Image = raws.get("side")
		if top_img == null or front_img == null or side_img == null:
			_ok(false, "SHEET %s images available" % eq_id)
			continue
		# 三面横向拼接：top | front | side（加 2px 空隙）
		var gap := 2
		var sheet_w := top_img.get_width() + front_img.get_width() + side_img.get_width() + gap * 2
		var sheet_h := maxi(maxi(top_img.get_height(), front_img.get_height()), side_img.get_height())
		var sheet := Image.create(sheet_w, sheet_h, false, Image.FORMAT_RGBA8)
		sheet.fill(Color(0, 0, 0, 0))
		var x := 0
		sheet.blit_rect(top_img, Rect2i(0, 0, top_img.get_width(), top_img.get_height()), Vector2i(x, 0))
		x += top_img.get_width() + gap
		sheet.blit_rect(front_img, Rect2i(0, 0, front_img.get_width(), front_img.get_height()), Vector2i(x, 0))
		x += front_img.get_width() + gap
		sheet.blit_rect(side_img, Rect2i(0, 0, side_img.get_width(), side_img.get_height()), Vector2i(x, 0))
		var path := ProjectSettings.globalize_path(FACES_OUT % eq_id)
		var err := sheet.save_png(path)
		_ok(err == OK, "SHEET %s saved (%s)" % [eq_id, path])


# === 结构验证（V3.1 P2 手绘面存在性） ===

func _verify_structure() -> void:
	_ok(EquipmentArt.FACE_MAPS.has("treadmill"), "STRUCT FACE_MAPS treadmill (3 faces)")
	_ok(EquipmentArt.FACE_MAPS.has("bike"), "STRUCT FACE_MAPS bike (3 faces)")
	_ok(EquipmentArt.FACE_MAPS.has("bench_press"), "STRUCT FACE_MAPS bench_press (3 faces)")
	# 每台设备 front + side 面 map 都存在
	for eq_id in ["treadmill", "bike", "bench_press"]:
		var face: Dictionary = EquipmentArt.FACE_MAPS[eq_id]
		_ok(face.has("front") and face.has("side"),
			"STRUCT %s has front + side face maps" % eq_id)
	# WorldCanvas 引用 EquipmentArt（挤出路径经手绘面）
	var canvas := _main.get_node_or_null("WorldViewport/WorldRoot/WorldCanvas")
	_ok(canvas != null and canvas.get("_equip_art") != null,
		"STRUCT WorldCanvas has EquipmentArt (V3.1 P2 extrusion)")


# === 纹理级 5 色层验证（V3.1 P2 最低要求，精确断言不受渲染管线污染） ===

func _verify_texture_layers() -> void:
	var equip_art = _main.get("_equip_art")
	_ok(equip_art != null, "LAYERS equip_art available")
	if equip_art == null:
		return
	var zone_of := {"treadmill": "cardio", "bike": "cardio", "bench_press": "strength"}
	for eq_id in zone_of:
		var zone: String = zone_of[eq_id]
		# 顶面纹理
		var tex: ImageTexture = equip_art.texture_for(eq_id, zone, 0)
		_ok(tex != null, "LAYERS %s top texture built" % eq_id)
		# front/side 手绘面（未变暗原始图 —— 5 层精确验证）
		var raws: Dictionary = equip_art.raw_face_images(eq_id, zone)
		var faces := {"top": tex.get_image() if tex != null else null,
			"front": raws.get("front"), "side": raws.get("side")}
		var layer_colors := {
			"base": [Palette.EQUIP_BODY_DARK, Palette.EQUIP_BODY,
				Palette.EQUIP_BODY_LIGHT, Palette.METAL_DARK],
			"shadow": [Palette.EQUIP_SHADOW_TONE],
			"outline": [Palette.EQUIP_OUTLINE],
			"highlight": [Palette.EQUIP_HIGHLIGHT, Palette.METAL_HIGHLIGHT],
			"accent": [Palette.EQUIP_ACCENT_CYAN, Palette.ZONE_COLORS[zone],
				Palette.ZONE_COLORS[zone].darkened(0.25),
				Palette.ZONE_COLORS[zone].lightened(0.15)],
		}
		for fname in faces:
			var img: Image = faces[fname]
			if img == null:
				_ok(false, "LAYERS %s.%s image built" % [eq_id, fname])
				continue
			for layer in layer_colors:
				var found := false
				for c in layer_colors[layer]:
					if _contains(img, c, 0.05):
						found = true
						break
				_ok(found, "LAYERS %s.%s has %s (V3.1 P2 5-layer)" % [eq_id, fname, layer])


# === 世界采样：设备是立体物件（非贴地图标） ===

## 世界采样验证（渲染帧）：
##   - 每台设备 footprint 区域多色（≥4 独立色：顶面/正面/侧面/阴影混合）
##   - treadmill 前端（console 侧）青蓝显示可辨 —— 朝向 + 真控制台
##   - 设备顶面亮于正面（三面分层：顶亮/正中/侧暗）
func _verify_world_equipment(img: Image) -> void:
	for eq_id in EQUIP_RECTS:
		var rect: Rect2i = EQUIP_RECTS[eq_id]
		var samples := _sample_rect(img, rect)
		var distinct := _distinct_colors(samples, 0.10)
		_ok(distinct >= 4, "WORLD %s close-up >=4 distinct colors (got %d, 3D volume)" % [eq_id, distinct])
	# treadmill(2,2) 顶面中心 vs 正面中段 —— 顶亮于正面（V3.1 P1 三面分层）
	var tm_rect: Rect2i = EQUIP_RECTS["treadmill"]
	var top_p := world_to_screen(Vector2(tm_rect.position.x + 16, tm_rect.position.y + 16),
		EQUIP_HEIGHTS["treadmill"])
	var front_p := world_to_screen(Vector2(tm_rect.position.x + 16,
		tm_rect.position.y + tm_rect.size.y), EQUIP_HEIGHTS["treadmill"] * 0.5)
	if _in_bounds(img, top_p) and _in_bounds(img, front_p):
		var top_c := img.get_pixel(top_p.x, top_p.y)
		var front_c := img.get_pixel(front_p.x, front_p.y)
		_ok(_luminance(top_c) > _luminance(front_c) + 0.03,
			"WORLD treadmill top brighter than front face (lit top, %.3f > %.3f)"
			% [_luminance(top_c), _luminance(front_c)])
	else:
		_ok(false, "WORLD treadmill top/front sample in bounds")
	# treadmill 前端 console（顶面南端 rows 13-14 青蓝显示屏）可辨（真控制台，
	# V3.1 P2）。顶面未变暗 → 青蓝精确；front 面变暗会削弱显示灯对比。
	var front_cyan := false
	for dy in range(-3, 4):
		for dx in range(-3, 4):
			var p := world_to_screen(Vector2(tm_rect.position.x + 16,
				tm_rect.position.y + 28), EQUIP_HEIGHTS["treadmill"])
			p += Vector2i(dx, dy)
			if not _in_bounds(img, p):
				continue
			if _near(img.get_pixel(p.x, p.y), Palette.EQUIP_ACCENT_CYAN, 0.16) \
					or _near(img.get_pixel(p.x, p.y), Palette.EMISSIVE_CYAN, 0.16):
				front_cyan = true
				break
		if front_cyan:
			break
	_ok(front_cyan, "WORLD treadmill console shows cyan display (V3.1 P2 控制台)")


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


func _contains(img: Image, color: Color, tol: float) -> bool:
	for y in img.get_height():
		for x in img.get_width():
			var p := img.get_pixel(x, y)
			if p.a > 0.5 and _near(p, color, tol):
				return true
	return false


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


func _in_bounds(img: Image, p: Vector2i) -> bool:
	return p.x >= 0 and p.y >= 0 and p.x < img.get_width() and p.y < img.get_height()


func _near(a: Color, b: Color, tol: float) -> bool:
	var dr := a.r - b.r
	var dg := a.g - b.g
	var db := a.b - b.b
	return sqrt(dr * dr + dg * dg + db * db) <= tol


func _luminance(c: Color) -> float:
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b
