## GoalTracker — minimal A4 HUD surface: current goal, progress, and claim.
## Owns no gameplay state; all writes route through GoalSystem.claim_goal().
##
## V3.1 返工（t_7aae83d5 性能修复）：A4 合并后本 HUD 的 8 次 draw call 把
## 共享 draw_calls 预算从 193 推到 201（FAIL <200）。根因 = CJK 标题 Label：
## 默认主题字体对 CJK 逐字形走系统 fallback 链，每个 fallback 字体一个
## atlas → 单个 Label 5-6 次 draw call（probe 实测）。修复（probe 验证）：
##   - 全部文字（标题/进度/按钮）改用 UiTheme.cjk_bold_font() ——
##     SystemFont font_names 钉死 PingFang SC，整串同一 atlas = 1 call
##   - 面板改 PixelPanel 手绘木牌纹理（StyleBoxTexture + NEAREST，
##     同 V3.1 顶栏挂牌语言 —— 去「程序化灰面板」观感）
##   - ProgressBar 轨道/填充按 HUD meter 语言重绘（暗槽 + 暖色填充）
## 结构与 API 不变（PanelContainer + init(goals)，main.gd 零改动）。
extends PanelContainer

const STATUS_COMPLETED := "COMPLETED"
const METRIC_SATISFACTION := "SATISFACTION"

const UiTheme := preload("res://src/ui/ui_theme.gd")
const PixelPanel := preload("res://src/ui/pixel_panel.gd")
const Palette := preload("res://src/palette.gd")

## 木牌纹理 texel（与 HUD PLAQUE_TEXEL 一致 —— 高分辨率 UI 层 4px/texel）。
const PANEL_TEXEL := 4
## 木牌确定性 seed（固定 seed → 每次运行生成相同纹理，证据复算稳定）。
const PANEL_SEED := 0x604A_1E
## 面板内容边距（px）。StyleBoxTexture 无默认内边距，显式设定避免文字
## 贴边（保留默认主题 panel stylebox 的 ~8px 内边距语义）。
const PANEL_PAD := 10
## 进度条暗槽/填充（HUD meter 语言：暗槽 + 暖色填充，1px 角像素风）。
const METER_BG_ALPHA := 0.16
const METER_RADIUS := 1

var _goals: Variant = null
var _title_label: Label
var _progress_label: Label
var _progress_bar: ProgressBar
var _claim_button: Button

## 面板纹理缓存（key = texel 尺寸；尺寸变化重建）。
var _panel_tex_cache: Dictionary = {}


## Injects the read/write GoalSystem boundary and builds the compact tracker.
func init(goals: Variant) -> void:
	_goals = goals
	name = "GoalTracker"
	custom_minimum_size = Vector2(340, 92)
	# StyleBoxTexture 无 texture_filter 属性（4.7.1 probe）：过滤模式跟随
	# CanvasItem —— 在绘制 stylebox 的 Control 本身上设置 NEAREST。
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	_panel_style_for_size(custom_minimum_size)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 4)
	add_child(content)

	_title_label = Label.new()
	_title_label.text = "当前目标"
	_title_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	UiTheme.style_cjk_label(_title_label, UiTheme.FONT_BODY)
	_title_label.add_theme_color_override("font_color", UiTheme.text_light())
	content.add_child(_title_label)

	var progress_row := HBoxContainer.new()
	progress_row.add_theme_constant_override("separation", 8)
	content.add_child(progress_row)

	_progress_bar = ProgressBar.new()
	_progress_bar.min_value = 0.0
	_progress_bar.max_value = 1.0
	_progress_bar.show_percentage = false
	_progress_bar.custom_minimum_size = Vector2(220, 12)
	_progress_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var groove := StyleBoxFlat.new()
	groove.bg_color = Color(0.0, 0.0, 0.0, METER_BG_ALPHA)
	groove.set_corner_radius_all(METER_RADIUS)
	_progress_bar.add_theme_stylebox_override("background", groove)
	var fill := StyleBoxFlat.new()
	fill.bg_color = Palette.BUTTER
	fill.set_corner_radius_all(METER_RADIUS)
	_progress_bar.add_theme_stylebox_override("fill", fill)
	progress_row.add_child(_progress_bar)

	_progress_label = Label.new()
	_progress_label.custom_minimum_size = Vector2(68, 0)
	_progress_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	UiTheme.style_cjk_label(_progress_label, UiTheme.FONT_AUX)
	_progress_label.add_theme_color_override("font_color", UiTheme.text_light())
	progress_row.add_child(_progress_label)

	_claim_button = Button.new()
	_claim_button.text = "领取奖励"
	_claim_button.visible = false
	# 手绘标签按钮语言（透明芯片 + 木牌文字）；字体 override 优先级高于
	# button_theme 的主题级 font —— CJK 单 atlas 单 draw call。
	UiTheme.style_button(_claim_button)
	UiTheme.style_cjk_label(_claim_button, UiTheme.FONT_BODY)
	_claim_button.pressed.connect(_on_claim_pressed)
	content.add_child(_claim_button)

	if _goals != null and (_goals as Object).has_signal("goal_updated"):
		(_goals as Object).connect("goal_updated", Callable(self, "_on_goal_updated"))
	if _goals != null and (_goals as Object).has_signal("goal_claimed"):
		(_goals as Object).connect("goal_claimed", Callable(self, "_on_goal_claimed"))
	_refresh()


## 面板 stylebox：PixelPanel 手绘木牌纹理（StyleBoxTexture + NEAREST）。
## 纹理尺寸 = control 尺寸 / PANEL_TEXEL（texel 向上取整）。控制实际尺寸
## 与 texel 对齐（main.gd 固定 340×92 = 85×23 texel @4px）时像素完美；
## 偏差时 StyleBoxTexture 拉伸 —— NEAREST 下不可见。
func _panel_style_for_size(size: Vector2) -> void:
	var sb := StyleBoxTexture.new()
	sb.texture = _panel_texture(size)
	sb.content_margin_left = PANEL_PAD
	sb.content_margin_right = PANEL_PAD
	sb.content_margin_top = 6
	sb.content_margin_bottom = 6
	add_theme_stylebox_override("panel", sb)


## 懒生成/缓存木牌面板纹理（确定性 seed；key = texel 尺寸）。
func _panel_texture(size: Vector2) -> ImageTexture:
	var tsize := Vector2i(
		maxi(1, ceili(size.x / PANEL_TEXEL)),
		maxi(1, ceili(size.y / PANEL_TEXEL)))
	var key := "%dx%d" % [tsize.x, tsize.y]
	if _panel_tex_cache.has(key):
		return _panel_tex_cache[key]
	var tex := PixelPanel.plaque_texture(
		PANEL_SEED,
		tsize,
		UiTheme.wood_plaque(),
		Palette.BUTTER,
		1.0,
		2)  # shadow_texels —— 底部内置手绘硬阴影（挂牌语言）
	_panel_tex_cache[key] = tex
	return tex


func _on_goal_updated(_goal: Dictionary) -> void:
	_refresh()


func _on_goal_claimed(_goal_id: String, _reward: Dictionary) -> void:
	_refresh()


func _on_claim_pressed() -> void:
	if _goals == null:
		return
	var current: Dictionary = (_goals as Object).call("get_current_goal")
	if not current.is_empty():
		(_goals as Object).call("claim_goal", str(current["id"]))


func _refresh() -> void:
	if _goals == null or not (_goals as Object).has_method("get_current_goal"):
		visible = false
		return
	var current: Dictionary = (_goals as Object).call("get_current_goal")
	visible = not current.is_empty()
	if current.is_empty():
		return
	_title_label.text = "目标 · %s" % str(current["title"])
	_progress_bar.value = float(current["progress_ratio"])
	if str(current["metric"]) == METRIC_SATISFACTION:
		_progress_label.text = "%d%% / %d%%" % [
			roundi(float(current["progress"]) * 100.0),
			roundi(float(current["target"]) * 100.0),
		]
	else:
		_progress_label.text = "%d / %d" % [
			floori(float(current["progress"])),
			ceili(float(current["target"])),
		]
	_claim_button.visible = str(current["status"]) == STATUS_COMPLETED
