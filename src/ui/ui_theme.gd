## UiTheme — Phase D v2 现代 UI 皮肤单一来源（modern game info design）
##
## 设计来源：design/art/art-bible-25d-style.md（§1 UI 行「现代深色半透明面板 /
## 亮色描边 / 粗字体 / 图标」；§2「面板半透明让场景透出，纵深延续到 UI」；
## §2 色彩 70/20/10：亮色描边与 Butter 高光属 ~10% 锚点，克制使用）+
## design/art/art-bible.md §7 UI 语言（语义色 / 图标 / 信息层级）。
##
## 本模块是 UI 皮层的唯一常量来源：所有面板样式、图标语义色、字号层级、
## 动效时长都在这里定义；各 UI 节点 preload 本文件（无 class_name —— 项目
## headless 约定，见 src/main.gd 头部注释），禁止各文件各写各的色值。
##
## 色值来源：全部派生自 src/palette.gd（art-bible §4 单一色源）。面板底色 =
## CHARCOAL 加深（同色系深灰，非新色）；描边 = BUTTER；文字 = CREAM_BG。
##
## 风格禁区（art-bible-25d §3）：无黑色粗描边覆盖、无古老 RPG 像素木框、
## 无赛博霓虹、无刺眼红。面板圆角轻微、描边 1-2px、半透明 0.7-0.85。
##
## 4.7.1 引擎注意（probe 验证）：Control 上不存在 add_theme_stylebox()——
## 「主题级 stylebox（非 override）」通过 Theme.set_stylebox() + control.theme
## 实现，has_theme_stylebox_override() 保持 false（transport 测试依赖此行为）。
## 图标描边填充式：Label 的 font_outline_color + outline_size（headless 安全）。
## 粗字体：SystemFont font_weight=700（4.7.1 支持，headless 创建安全）。
## V3.1 返工 UI：面板/按钮语言已从 StyleBoxFlat 完美矩形+等宽边框迁移到
## PixelPanel 手绘像素纹理（不规则边缘 + 材质 cluster + 非等宽描边）；文字
## 渲染关闭抗锯齿/hinting（像素化硬边字形）。见 src/ui/pixel_panel.gd。
const Palette := preload("res://src/palette.gd")

# === 面板体系（V3.1 手绘像素面板：颜色单一来源；纹理生成见 pixel_panel.gd） ===

## 面板底色不透明度（art-bible-25d：alpha 0.7-0.85，半透明让 2.5D 场景透出）。
const PANEL_ALPHA := 0.82

## 面板底色：CHARCOAL 加深后的深灰（同色系派生，非新色）。alpha 由
## PANEL_ALPHA 控制。返回新 Color（每次调用独立实例）。
## V3.1 返工 UI：本函数供 PixelPanel 纹理生成作底色（HUD 条带 / 建造条
## 条带 / tile 平板 / 工具栏平板）；面板形状由像素纹理承担，不再有
## StyleBoxFlat 完美矩形面板（去 CSS 仪表盘化，V3 §15 / 附录 V3.1）。
static func panel_bg() -> Color:
	var c := Palette.CHARCOAL.darkened(0.35)
	c.a = PANEL_ALPHA
	return c

## 面板亮色描边：Butter（art-bible-25d「亮色描边 ≈ Butter 或区域亮色」）。
## V3.1 返工 UI：作为 PixelPanel 纹理的 accent（断续像素线）与按钮描边色。
static func panel_border() -> Color:
	return Palette.BUTTER

# === 文字（浅色 Cream 系，深色面板上可读） ===

## 主文字色：Warm Cream（art-bible §4 单一色源）。
static func text_light() -> Color:
	return Palette.CREAM_BG

## 三级字号层级（标题 / 正文 / 辅助说明，比例清晰）：
##   FONT_TITLE — HUD 金钱计数（最醒目数字）
##   FONT_BODY  — HUD 标签 / 按钮 / 面板价格
##   FONT_AUX   — 次要说明（tile 名称 / 提示）
## 图标槽字号（PHASED-F：palette_tile icon 28px 硬编码收敛到本常量）：
##   FONT_ICON  — 描边填充式图标字形（商店 tile 首字母）
const FONT_TITLE := 20
const FONT_BODY := 16
const FONT_AUX := 14
const FONT_ICON := 28

# === 粗字体（Godot 默认粗体 / 系统粗字体，4.7.1 SystemFont） ===

static var _bold_font: SystemFont = null

## 共享粗体 SystemFont（weight 700）。headless 创建安全（probe 验证），
## 窗口模式由系统字体渲染。懒加载单例，全 UI 共用同一资源。
## V3.1 返工 UI：文字像素化渲染 —— 关闭抗锯齿/hinting/subpixel（硬边
## chunky 字形，非细线现代 UI 字体；V3 §15 绝对避免 thin modern UI
## typography）。4.7.1 probe 验证：SystemFont 默认 antialiasing=1 /
## hinting=1 / subpixel=1 / weight=400；置 0/0/0/700 生效且 headless 安全。
## TextServer.FONT_ANTIALIASING_NONE 常量存在（probe）；hinting/subpixel
## 的 FONT_* 常量名在 4.7.1 未暴露于类常量表（probe），用数值 0（= NONE /
## DISABLED，probe 确认可赋值）。
static func bold_font() -> SystemFont:
	if _bold_font == null:
		_bold_font = SystemFont.new()
		_bold_font.font_weight = 700
		_bold_font.antialiasing = TextServer.FONT_ANTIALIASING_NONE
		_bold_font.hinting = 0
		_bold_font.subpixel_positioning = 0
	return _bold_font

## 给 Label 应用粗字体 + 字号（字号覆盖走 theme override，测试可读）。
static func style_label(label: Label, font_size: int = FONT_BODY) -> void:
	label.add_theme_font_override("font", bold_font())
	label.add_theme_font_size_override("font_size", font_size)

# === 图标（带描边填充式：语义色填充 + 亮色描边） ===

## 图标语义色（art-bible-25d 任务映射）：金钱→Butter / 满意度→Sage /
## 时间→Sky / 商店→Peach。
static func icon_money() -> Color:
	return Palette.BUTTER

static func icon_satisfaction() -> Color:
	return Palette.SAGE

static func icon_time() -> Color:
	return Palette.SKY

static func icon_shop() -> Color:
	return Palette.PEACH

## 描边填充式图标处理：Label 的 font_color = [fill]（填充）+ font_outline_color
## = [outline] + outline_size = [outline_px]。probe 验证：headless 安全，
## 窗口模式在文字/表情符号字形上渲染描边（art-bible §7 图标风格）。
static func apply_outlined_fill(
	label: Label,
	fill: Color,
	outline: Color = Palette.BUTTER,
	outline_px: int = 2
) -> void:
	label.add_theme_color_override("font_color", fill)
	label.add_theme_color_override("font_outline_color", outline)
	label.add_theme_constant_override("outline_size", outline_px)

# === 按钮（深色半透明 + 亮色细描边，主题级 stylebox） ===

static var _button_theme: Theme = null

## 像素芯片按钮 stylebox：非对称描边（顶/左 2px、右/底 1px）+ 非对称圆角
## （仅左上/右下 1px，切掉另外两角）—— 手绘像素按钮语言，非 macOS 圆角
## 芯片、非等宽边框（V3.1 负面约束）。[bg_boost] 额外提高底色不透明度
## （hover 提亮用）。
static func make_pixel_chip_style(border_color: Color, bg_boost: float = 0.0) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	var bg := Palette.CHARCOAL.darkened(0.45)
	bg.a = clampf(PANEL_ALPHA + bg_boost, 0.0, 1.0)
	sb.bg_color = bg
	sb.border_color = border_color
	sb.border_width_left = 2
	sb.border_width_top = 2
	sb.border_width_right = 1
	sb.border_width_bottom = 1
	sb.corner_radius_top_left = 1
	sb.corner_radius_bottom_right = 1
	sb.corner_radius_top_right = 0
	sb.corner_radius_bottom_left = 0
	sb.content_margin_left = 8.0
	sb.content_margin_right = 8.0
	sb.content_margin_top = 4.0
	sb.content_margin_bottom = 4.0
	return sb

## 共享 Button Theme：normal/hover/pressed/focus 全为像素芯片（非对称
## 描边/圆角 —— V3.1 返工 UI，替代旧 rounded chip）。通过
## `btn.theme = button_theme()` 挂到按钮上 —— 这是 4.7.1 的「主题级
## stylebox」路径（probe 验证：Control 无 add_theme_stylebox()；
## Theme.set_stylebox() + control.theme 后 has_theme_stylebox_override() 保持
## false，transport 测试的「inactive 无 override」断言依赖此行为）。
## 按钮文字用 theme color override（浅 Cream）+ 粗字体，见
## UiTheme.style_button()。
static func button_theme() -> Theme:
	if _button_theme == null:
		_button_theme = Theme.new()
		var normal := make_pixel_chip_style(Palette.BUTTER, 0.0)
		var hover := make_pixel_chip_style(Palette.BUTTER, 0.06)
		hover.border_width_left = 3
		hover.border_width_top = 3
		var pressed := make_pixel_chip_style(Palette.BUTTER, 0.0)
		pressed.bg_color = Palette.BUTTER.darkened(0.55)
		pressed.bg_color.a = 0.9
		pressed.border_width_left = 1  # 按下：上/左描边内陷（物理按压感）
		pressed.border_width_top = 1
		pressed.border_width_right = 2
		pressed.border_width_bottom = 2
		_button_theme.set_stylebox("normal", "Button", normal)
		_button_theme.set_stylebox("hover", "Button", hover)
		_button_theme.set_stylebox("pressed", "Button", pressed)
		_button_theme.set_stylebox("focus", "Button", make_pixel_chip_style(Palette.BUTTER, 0.0))
		_button_theme.set_color("font_color", "Button", Palette.CREAM_BG)
		_button_theme.set_color("font_hover_color", "Button", Palette.CREAM_BG)
		_button_theme.set_color("font_pressed_color", "Button", Palette.CREAM_BG)
		_button_theme.set_font("font", "Button", bold_font())
		_button_theme.set_font_size("font_size", "Button", FONT_BODY)
	return _button_theme

## 把共享按钮皮肤挂到一个 Button 上（主题级，非 override —— 保持
## has_theme_stylebox_override 为 false 的测试契约）。
static func style_button(btn: Button) -> void:
	btn.theme = button_theme()

# === 动效（120-250ms 柔和过渡，克制、可读） ===

## 面板淡入时长（s）。Exit 条件 3：120-250ms。
const ANIM_PANEL_FADE := 0.18

## 图标脉冲时长（s）—— 金钱图标在余额变化时轻微放大回弹。
const ANIM_ICON_PULSE := 0.2

## 关键数字滚动时长（s）—— HUD 金钱计数（GDD 0.2-0.5 安全区间内，取 250ms
## 上限内；hud.gd DEFAULT_MONEY_COUNT_DURATION 与 tests 同步）。
const ANIM_NUMBER_ROLL := 0.25
