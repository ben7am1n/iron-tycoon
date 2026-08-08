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
#   - 图标 4 个可辨（金钱 Butter / 满意度 Sage / 时间 Sky / 商店 Peach）
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

	var all_ok: bool = dark_ok and translucent_ok and butter_ok and icons_ok and fonts_ok and draw_calls < 200
	print("RESULT: %s" % ("PASS" if all_ok else "CHECK"))
	get_tree().quit(0 if all_ok else 1)


## 从 UI 树收集 4 个语义图标：[name, glyph, fill_color_str, outline_size]。
## 结构化（非像素）验证 —— 图标字形渲染依赖系统字体，headless/窗口行为
## 不同；字形 + 语义色 + 描边三通道存在即可辨（art-bible §7 双通道）。
func _collect_icons() -> Array:
	var out: Array = []
	var hud := get_tree().root.find_child("Hud", true, false)
	if hud != null:
		var coin := hud.get_node_or_null("TopBar/MoneyGroup/CoinIcon")
		if coin != null and coin is Label:
			out.append(["CoinIcon", (coin as Label).text, str((coin as Label).get_theme_color("font_color")), (coin as Label).get_theme_constant("outline_size")])
		var face := hud.get_node_or_null("TopBar/SatisfactionGroup/FaceIcon")
		if face != null and face is Label:
			out.append(["FaceIcon", (face as Label).text, str((face as Label).get_theme_color("font_color")), (face as Label).get_theme_constant("outline_size")])
		var tod := hud.get_node_or_null("TopBar/TimeGroup/TimeOfDayLabel")
		if tod != null and tod is Label:
			out.append(["TimeOfDayLabel", (tod as Label).text, str((tod as Label).get_theme_color("font_color")), (tod as Label).get_theme_constant("outline_size")])
	var palette := get_tree().root.find_child("BuildShopPalette", true, false)
	if palette != null and palette.get_child_count() > 0:
		# 商店图标 = 建造面板第一个 tile 的 icon（Peach 描边填充式，商店→Peach）。
		# icon 在 tile 的 VBox 内，需递归 find_children。
		var tile := palette.get_child(0)
		var icon_label: Label = null
		for label in tile.find_children("*", "Label", true, false):
			var l := label as Label
			if l != null and l.get_theme_constant("outline_size") > 0:
				icon_label = l
				break
		if icon_label != null:
			out.append(["ShopTileIcon", icon_label.text, str(icon_label.get_theme_color("font_color")), icon_label.get_theme_constant("outline_size")])
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
