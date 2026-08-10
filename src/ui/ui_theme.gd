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
const PixelPanel := preload("res://src/ui/pixel_panel.gd")

# === 面板体系（V3.1 手绘像素面板：颜色单一来源；纹理生成见 pixel_panel.gd） ===

## 面板底色不透明度（art-bible-25d：alpha 0.7-0.85，半透明让 2.5D 场景透出）。
## V3.1 返工3 P4：0.82 → 0.76 —— HUD 视觉重量降低（半融入背景，UI 不主导
## 第一眼；门禁 FAIL：HUD 直接覆盖最终渲染并主导第一眼）。
const PANEL_ALPHA := 0.76

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

# === V3.1 返工3 P4 — diagetic 挂牌/价签/木架色（场景内物体语言，非 CSS 面板） ===

## 顶栏挂牌木色：暖中深棕（DESK_WOOD 加深派生，同一色源）。木牌读作
## 墙上物体，非近黑 charcoal 面板（门禁 FAIL：顶部状态栏=CSS 横条）。
static func wood_plaque() -> Color:
	var c := Palette.DESK_WOOD.darkened(0.22)
	c.a = PANEL_ALPHA
	return c

## 底部价目标签木色：比挂牌略浅（架上的小标签）。
static func wood_tag() -> Color:
	var c := Palette.DESK_WOOD.darkened(0.10)
	c.a = PANEL_ALPHA
	return c

## 底部展示架木色：更亮木色（前台货架/价目板）。
static func wood_shelf() -> Color:
	var c := Palette.DESK_WOOD.lightened(0.10)
	c.a = 0.92
	return c

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

# === 按钮（V3.1 返工3 P4：手绘标签语言 —— 无芯片矩形，读作木牌上的手写标签） ===

static var _button_theme: Theme = null

## 手绘标签按钮主题（V3.1 返工3 P4，门禁 FAIL：右上倍速控制=按钮）：normal
## 完全透明（无芯片、无边框 —— 按钮读作挂牌/木架上的手写标签，绝非 CSS
## 按钮），hover 仅极轻暖色底（手绘高亮感），pressed 轻微压暗。ACTIVE 状态
## 由调用方以 StyleBoxFlat override 提供（transport 测试契约：
## border_width_left > 0 的选中记号 —— 见 hud._get_active_stylebox）。
## 主题级 stylebox（非 override）保持 has_theme_stylebox_override 为 false 的
## 测试契约不变。
static func button_theme() -> Theme:
	if _button_theme == null:
		_button_theme = Theme.new()
		# normal：透明 —— 按钮不画任何芯片/边框，只剩文字（手写标签语言）。
		var plain := StyleBoxFlat.new()
		plain.bg_color = Color(0.0, 0.0, 0.0, 0.0)
		plain.border_width_left = 0
		plain.border_width_top = 0
		plain.border_width_right = 0
		plain.border_width_bottom = 0
		plain.content_margin_left = 6.0
		plain.content_margin_right = 6.0
		plain.content_margin_top = 2.0
		plain.content_margin_bottom = 2.0
		# hover：极轻暖色底（手绘高亮，非按钮高亮）
		var hover := StyleBoxFlat.new()
		hover.bg_color = Color(0.96, 0.85, 0.6, 0.10)
		hover.content_margin_left = 6.0
		hover.content_margin_right = 6.0
		hover.content_margin_top = 2.0
		hover.content_margin_bottom = 2.0
		# pressed：轻微压暗
		var pressed := StyleBoxFlat.new()
		pressed.bg_color = Color(0.0, 0.0, 0.0, 0.12)
		pressed.content_margin_left = 6.0
		pressed.content_margin_right = 6.0
		pressed.content_margin_top = 2.0
		pressed.content_margin_bottom = 2.0
		# focus：透明（键盘焦点不画矩形框 —— 无等宽边框语言）
		var focus := StyleBoxFlat.new()
		focus.bg_color = Color(0.0, 0.0, 0.0, 0.0)
		focus.content_margin_left = 6.0
		focus.content_margin_right = 6.0
		focus.content_margin_top = 2.0
		focus.content_margin_bottom = 2.0
		_button_theme.set_stylebox("normal", "Button", plain)
		_button_theme.set_stylebox("hover", "Button", hover)
		_button_theme.set_stylebox("pressed", "Button", pressed)
		_button_theme.set_stylebox("focus", "Button", focus)
		_button_theme.set_color("font_color", "Button", Palette.CREAM_BG)
		_button_theme.set_color("font_hover_color", "Button", Palette.CREAM_BG)
		_button_theme.set_color("font_pressed_color", "Button", Palette.CREAM_BG)
		_button_theme.set_font("font", "Button", bold_font())
		_button_theme.set_font_size("font_size", "Button", FONT_BODY)
	return _button_theme

## 把共享按钮皮肤挂到一个 Button 上（主题级，非 override —— 保持
## has_theme_stylebox_override 为 false 的测试契约）。NEAREST 由 Button 自身
## texture_filter 提供（4.7.1 的 StyleBoxTexture 无 texture_filter 属性，
## 过滤模式跟随 CanvasItem —— probe 验证：属性不存在，需在 Control 上设置）。
static func style_button(btn: Button) -> void:
	btn.theme = button_theme()
	btn.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

# === 动效（120-250ms 柔和过渡，克制、可读） ===

## 面板淡入时长（s）。Exit 条件 3：120-250ms。
const ANIM_PANEL_FADE := 0.18

## 图标脉冲时长（s）—— 金钱图标在余额变化时轻微放大回弹。
const ANIM_ICON_PULSE := 0.2

## 关键数字滚动时长（s）—— HUD 金钱计数（GDD 0.2-0.5 安全区间内，取 250ms
## 上限内；hud.gd DEFAULT_MONEY_COUNT_DURATION 与 tests 同步）。
const ANIM_NUMBER_ROLL := 0.25
