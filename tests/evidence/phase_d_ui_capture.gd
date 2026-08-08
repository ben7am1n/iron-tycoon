# tests/evidence/phase_d_ui_capture.gd — Phase D v2 视觉冒烟证据捕获
#
# 渲染真实主场景（src/main.tscn）并保存视口快照 + 采样验证 + draw call 预算。
# 输出：tests/evidence/phase-d-v2-ui.png（证据文件，随仓库提交）。
#
# 用法（窗口模式 —— headless 用 dummy 渲染驱动，get_image() 返回 null，
# 4.7.1 已验证；窗口捕获是项目既有证据方法，见 phase_a_capture.gd）：
#   godot --path . res://tests/evidence/phase_d_ui_capture.tscn
#
# 验收对照（art-bible-25d-style §1/§2 + 任务 Exit 条件 6）：
#   - 面板 ≈ 深色半透明（HUD 顶栏 / 建造商店条带内部）
#   - 描边 ≈ Butter #F5D97B 亮色（面板边缘）
#   - 图标 4 个可辨 + 像素级语义色（PHASED-F Exit 1）：直接对渲染截图采样
#     每个图标的实际主色，断言 CoinIcon≈BUTTER / FaceIcon≈SAGE /
#     TimeOfDay≈SKY / Shop≈PEACH —— 结构性 theme 值断言存在自报 PASS 盲区
#     （macOS 彩色 emoji 忽略 font_color，以系统固有颜色渲染）。
#   - 字体三级（标题 20 / 正文 16 / 辅助 14）
#   - draw calls < 200（Performance monitor，4.7.1 枚举名
#     RENDER_TOTAL_DRAW_CALLS_IN_FRAME —— 见 deprecated-apis.md）
extends Node

const MAIN_SCENE := preload("res://src/main.tscn")
const OUT_PATH := "res://tests/evidence/phase-d-v2-ui.png"
## 捕获帧：面板淡入 180ms（~11 帧 @60fps），30 帧后已完全稳定。
const CAPTURE_FRAME := 30

var _frame := 0
var _captured := false

## 图标语义色期望值（art-bible §4 / UiTheme 单一来源；Exit 条件 1）。
## PHASED-F：断言渲染后像素 ≈ 期望色 —— theme 值本身可被彩色 emoji 绕过。
const SEMANTIC_ICONS := {
	"CoinIcon": Color("f5d97b"),       # BUTTER（金钱）
	"FaceIcon": Color("8fbf9f"),       # SAGE（满意度）
	"TimeOfDayLabel": Color("8ec5e8"), # SKY（时间）
	"ShopTileIcon": Color("f2b486"),   # PEACH（商店）
}
## 主色与期望色的最大欧氏距离（RGBA 空间，max ≈ 1.73）。实心字形主色距
## 期望 < 0.05；bug 场景（emoji 灰/黄/白）距期望 > 0.3，取 0.25 稳判。
const ICON_COLOR_TOLERANCE := 0.25

# 采样点（像素坐标，1280×720 视口）：
#   hud_panel   (640, 24) — HUD 顶栏面板内部（左右 spacer 区，无文字遮挡）
#   hud_border  (640, 3)  — 顶栏面板上边缘 Butter 描边
#   palette     (640, 672)— 底部建造商店条带面板内部
#   cream_floor (300, 700)— 条带下方环场走道奶油底（透出证据参照）
const SAMPLE_POINTS := {
	"hud_panel": Vector2i(640, 24),
	"hud_border": Vector2i(640, 3),
	"palette": Vector2i(640, 672),
	"cream_floor": Vector2i(300, 700),
}


func _ready() -> void:
	add_child(MAIN_SCENE.instantiate())


func _process(_delta: float) -> void:
	_frame += 1
	if _frame >= CAPTURE_FRAME and not _captured:
		_captured = true
		_capture_and_report()


func _capture_and_report() -> void:
	var img := get_viewport().get_texture().get_image()
	if img == null:
		push_error("phase_d_ui_capture: get_image() returned null (headless dummy driver?)")
		get_tree().quit(1)
		return
	var abs_path := ProjectSettings.globalize_path(OUT_PATH)
	var err := img.save_png(abs_path)
	if err != OK:
		push_error("phase_d_ui_capture: save_png failed err=%d path=%s" % [err, abs_path])
		get_tree().quit(1)
		return
	print("CAPTURE saved=%s size=%dx%d" % [OUT_PATH, img.get_width(), img.get_height()])
	for label in SAMPLE_POINTS:
		var p: Vector2i = SAMPLE_POINTS[label]
		print("SAMPLE %-12s @(%3d,%3d) = %s" % [label, p.x, p.y, img.get_pixel(p.x, p.y)])

	# === 面板 ≈ 深色半透明（Exit 6）===
	# HUD 面板内部：CHARCOAL.darkened(0.35) @ alpha 0.82 叠在奶油底上 →
	# 预期深灰 (≈0.30, ≈0.29, ≈0.29)。判据：亮度明显低于 0.5（深色）且
	# 高于纯黑（半透明让场景透出）。
	var hud_panel: Color = img.get_pixel(640, 24)
	var dark_ok: bool = hud_panel.r < 0.5 and hud_panel.g < 0.5 and hud_panel.b < 0.5
	var translucent_ok: bool = hud_panel.r > 0.15 and hud_panel.g > 0.15
	print("CHECK panel_dark=%s translucent=%s (%s)" % [dark_ok, translucent_ok, hud_panel])

	# === 描边 ≈ Butter 亮色（Exit 6）===
	var border: Color = img.get_pixel(640, 3)
	var butter_ok: bool = border.r > 0.7 and border.g > 0.6 and border.b > 0.3 and border.b < 0.7
	print("CHECK border_butter=%s (%s)" % [butter_ok, border])

	# === 图标 4 个可辨（Exit 6 / 任务 2）===
	# 结构化验证：从 UI 树中收集 4 个语义图标（字形 + 语义色 + 描边）。
	var icons := _collect_icons()
	print("ICONS found=%d" % icons.size())
	for ic in icons:
		print("  ICON %s glyph='%s' fill=%s outline_size=%d" % [ic[0], ic[1], ic[2], ic[3]])
	var money_icon: bool = _has_icon(icons, "CoinIcon")
	var sat_icon: bool = _has_icon(icons, "FaceIcon")
	var time_icon: bool = _has_icon(icons, "TimeOfDayLabel")
	var shop_icon: bool = _has_icon(icons, "ShopTileIcon")
	var icons_ok: bool = money_icon and sat_icon and time_icon and shop_icon
	print("CHECK icons_4=%s (money=%s sat=%s time=%s shop=%s)" % [icons_ok, money_icon, sat_icon, time_icon, shop_icon])

	# === 图标像素级语义色（PHASED-F Exit 1 / qa 复验判据）===
	# 结构性 theme 值断言有自报 PASS 盲区（macOS 彩色 emoji 忽略
	# font_color）；这里对渲染截图直接采样每个图标的实际主色，断言 ≈ 语义色。
	var icon_labels := _icon_labels()
	var icons_pixel_ok: bool = true
	for icon_name in SEMANTIC_ICONS:
		var want: Color = SEMANTIC_ICONS[icon_name]
		if not icon_labels.has(icon_name):
			print("ICONPIX %-12s MISSING label node" % icon_name)
			icons_pixel_ok = false
			continue
		var label := icon_labels[icon_name] as Label
		var res := _dominant_icon_color(img, label)
		var got: Color = res[0]
		var px: int = res[1]
		# 4.7.1 无 Color.distance_to() —— 手算 RGBA 欧氏距离（max ≈ 1.73）。
		var d_r: float = got.r - want.r
		var d_g: float = got.g - want.g
		var d_b: float = got.b - want.b
		var dist: float = sqrt(d_r * d_r + d_g * d_g + d_b * d_b)
		var ok: bool = px > 0 and dist <= ICON_COLOR_TOLERANCE
		print("ICONPIX %-12s rect=%s dominant=#%s want=#%s dist=%.3f px=%d %s" % [
			icon_name, label.get_global_rect(), got.to_html(false),
			want.to_html(false), dist, px, "OK" if ok else "FAIL",
		])
		icons_pixel_ok = icons_pixel_ok and ok
	print("CHECK icons_pixel_semantic=%s" % str(icons_pixel_ok))

	# === 字体三级（Exit 6 / 任务 3）===
	var sizes := _collect_font_sizes()
	sizes.sort()
	print("FONTS sizes=%s" % str(sizes))
	var has_title: bool = 20 in sizes
	var has_body: bool = 16 in sizes
	var has_aux: bool = 14 in sizes
	var fonts_ok: bool = has_title and has_body and has_aux
	print("CHECK fonts_3=%s (title20=%s body16=%s aux14=%s)" % [fonts_ok, has_title, has_body, has_aux])

	var draw_calls := Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME)
	var fps := Performance.get_monitor(Performance.TIME_FPS)
	print("PERF draw_calls=%d fps=%.1f budget_ok=%s" % [draw_calls, fps, str(draw_calls < 200)])

	var all_ok: bool = dark_ok and translucent_ok and butter_ok and icons_ok and icons_pixel_ok and fonts_ok and draw_calls < 200
	print("RESULT: %s" % ("PASS" if all_ok else "CHECK"))
	get_tree().quit(0 if all_ok else 1)


## 收集 4 个语义图标的 Label 节点：name -> Label（找不到则不包含）。
## CoinIcon/FaceIcon/TimeOfDayLabel 在 HUD 顶栏固定路径；ShopTileIcon =
## 建造面板第一个 tile 的描边 icon（Peach 首字母，递归 find_children）。
func _icon_labels() -> Dictionary:
	var out := {}
	var hud := get_tree().root.find_child("Hud", true, false)
	if hud != null:
		var coin := hud.get_node_or_null("TopBar/MoneyGroup/CoinIcon")
		if coin != null and coin is Label:
			out["CoinIcon"] = coin
		var face := hud.get_node_or_null("TopBar/SatisfactionGroup/FaceIcon")
		if face != null and face is Label:
			out["FaceIcon"] = face
		var tod := hud.get_node_or_null("TopBar/TimeGroup/TimeOfDayLabel")
		if tod != null and tod is Label:
			out["TimeOfDayLabel"] = tod
	var palette := get_tree().root.find_child("BuildShopPalette", true, false)
	if palette != null and palette.get_child_count() > 0:
		var tile := palette.get_child(0)
		var icon_label: Label = null
		for label in tile.find_children("*", "Label", true, false):
			var l := label as Label
			if l != null and l.get_theme_constant("outline_size") > 0:
				icon_label = l
				break
		if icon_label != null:
			out["ShopTileIcon"] = icon_label
	return out


## 在 [label] 的全局矩形内统计字形主色：跳过面板深色底（亮度 < 0.45），
## 剩余像素按 16 级量化桶计数，返回最高频桶的均值颜色 + 桶内像素数。
## 实心字形（● / 首字母 / 文本）主色 ≈ 其 font_color；macOS 彩色 emoji
## 渲染的是系统固有颜色，会落在完全不同的桶（自报 PASS 盲区由此被戳穿）。
func _dominant_icon_color(img: Image, label: Label) -> Array:
	var rect: Rect2 = label.get_global_rect()
	var counts := {}
	var sums := {}
	var x0 := maxi(0, int(floor(rect.position.x)))
	var y0 := maxi(0, int(floor(rect.position.y)))
	var x1 := mini(img.get_width() - 1, int(ceil(rect.end.x)) - 1)
	var y1 := mini(img.get_height() - 1, int(ceil(rect.end.y)) - 1)
	for y in range(y0, y1 + 1):
		for x in range(x0, x1 + 1):
			var c: Color = img.get_pixel(x, y)
			if c.r + c.g + c.b < 0.45 * 3.0:
				continue
			var key := "%d_%d_%d" % [int(c.r * 15.999), int(c.g * 15.999), int(c.b * 15.999)]
			counts[key] = int(counts.get(key, 0)) + 1
			if not sums.has(key):
				sums[key] = Vector3.ZERO
			sums[key] += Vector3(c.r, c.g, c.b)
	var best_key := ""
	var best_count := 0
	for key in counts:
		if int(counts[key]) > best_count:
			best_count = int(counts[key])
			best_key = key
	if best_key == "":
		return [Color.BLACK, 0]
	var sumv: Vector3 = sums[best_key]
	return [Color(sumv.x / float(best_count), sumv.y / float(best_count), sumv.z / float(best_count)), best_count]


## 从 UI 树收集 4 个语义图标：[name, glyph, fill_color_str, outline_size]。
## 结构化（非像素）验证 —— 图标字形渲染依赖系统字体，headless/窗口行为
## 不同；字形 + 语义色 + 描边三通道存在即可辨（art-bible §7 双通道）。
## 像素级语义色断言见 _capture_and_report 的 ICONPIX 段（PHASED-F Exit 1）。
func _collect_icons() -> Array:
	var out: Array = []
	var labels := _icon_labels()
	for name in labels:
		var label := labels[name] as Label
		out.append([name, label.text, str(label.get_theme_color("font_color")), label.get_theme_constant("outline_size")])
	return out


func _has_icon(icons: Array, name: String) -> bool:
	for ic in icons:
		if ic[0] == name:
			return true
	return false


## 从 UI 树收集全部 Label 字号（主题 override 值）。三级字体验证用。
func _collect_font_sizes() -> Array[int]:
	var sizes: Array[int] = []
	var nodes := get_tree().root.find_children("*", "Label", true, false)
	for node in nodes:
		var label := node as Label
		if label != null:
			sizes.append(int(label.get_theme_font_size("font_size")))
	return sizes
