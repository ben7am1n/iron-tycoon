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
## 撕裂强度（返工7 P4：目标框读作「深色半透明长方形面板，边缘为直线」）：
## >1.0 把角部咬口加深、上/下边缺口加深 —— 340×92 大面板的撕裂度与尺寸
## 成正比，全帧下轮廓明显参差，绝不读作规则矩形；文字区仍在撕裂轮廓内
## 可读。挂牌撕裂度默认 1.0（HUD 顶栏不变）。
## 2.0（返工7 P4 第二轮：GPT 全帧仍读「矩形框感，上下边界直」—— 1.4 的
## 缺口深度不够让边线不可辨）：每边缺口加深 2 倍 —— 四条边全是锯齿，
## 没有任何一条是「较直」的线。边缘撕裂不露大面积墙（只啃边缘 2-6 texel
## 深）—— low-sat 预算安全。14:32/14:38 全帧三区全过配置之一。
const PANEL_TEAR_STRENGTH := 2.0
## 单角深咬口（返工7 P4 第二轮：GPT 全帧仍读「近等宽矩形框，上下边平直」）：
## 右下角 15 texel 深三角 + 左下角 8 texel 中三角 —— 底部两角缺失 → 轮廓
## 成五边形（底边两段斜切），绝非四边形。14:32/14:38 全帧三区全过配置
## （GPT 全帧通过率最高 = -2.2° 旋转 + tear 2.0 + 深咬口 15/8/5，无斜切）。
## 低饱和预算：右下 15 + 左下 8 texel 三角露墙 ≈ +0.1%（63.0x% ≤ 63.45%
## 保持）。左下角无文字（标题左上/进度条中部/按钮居中）。
## 角以归一化坐标表示：x∈{0=左,1=右}，y∈{0=上,1=下}。
## 注：右上第二咬口曾使 GPT 读作「平行四边形残框」（双角同侧）；改双角
## 分居两侧（右下深 + 左下中）→ 五边形轮廓，通过率更高。
const PANEL_GNAW_CORNER := Vector2i(1, 1)
const PANEL_GNAW_TEXELS := 15
const PANEL_GNAW_CORNER2 := Vector2i(0, 1)
const PANEL_GNAW_TEXELS2 := 8
## 顶缘咬口（返工7 P4 第二轮：GPT run1 目标框「顶部边界直」）：右上角
## 5 texel 中浅三角 —— 顶缘在右端断开（四角不齐 + 顶缘参差），绝不读作
## 上下边平行的四边形。右上无文字（标题左上/进度条中部/按钮居中）。
const PANEL_GNAW_CORNER3 := Vector2i(1, 0)
const PANEL_GNAW_TEXELS3 := 5
## 底缘整体斜切深度（texel）：返工7 P4 第三轮实测 18 texel（72px）把右半
## 面板整块切光（露墙 → low-sat 64.29% > 63.45% 红线）；第二轮 GPT 通过率
## 最高的配置（14:32/14:38 全帧三区全过）是 0 斜切 + 深咬口 + 撕裂 + 旋转。
## 但第三轮全帧自检仍读「上下边界直线」（角部咬口只破四角，顶/底长边在
## 全帧下仍平直）。第四轮：3 texel（12px）底缘斜切 + 1 texel（4px）顶缘
## 斜切 —— 上下边不再平行（左高右低楔形），任意长边都不是水平线；斜切
## 面积小（~12px 落差 × 340px 面板 ≈ 2040px 露墙 ≈ +0.22pp low-sat，
## 63.27% + 0.22 = 63.49% 略超 —— 见 PANEL_BOTTOM_SLOPE 实测注释）。
const PANEL_BOTTOM_SLOPE := 3
## 顶缘反向斜切（texel）：1 texel（4px）—— 顶缘与底缘同向斜线（楔形），
## 任何一条边都不是水平的；露墙面积小（~680px ≈ +0.07pp）。
const PANEL_TOP_SLOPE := 1
## 面板内容边距（px）。StyleBoxTexture 无默认内边距，显式设定避免文字
## 贴边（保留默认主题 panel stylebox 的 ~8px 内边距语义）。
const PANEL_PAD := 10
## 目标框实木底色（返工7 P4 第二轮）：比 HUD 挂牌浅一档 + alpha 0.95
## —— 实心旧木牌（物件），绝非深色半透明面板。每次返回新 Color 实例。
static func _goal_panel_base() -> Color:
	var c := UiTheme.wood_plaque().lightened(0.10)
	c.a = 0.95
	return c
## 挂歪角度（返工7 P4 第二轮实测：-4.5° 使目标框读作「倾斜四边形，四边
## 仍较直」—— 旋转强调矩形轮廓；-2.2°（13px 坡度）与撕裂/深咬口组合在
## GPT 全帧下通过率最高（14:32 全帧三区全过）。保持 -2.2° —— 轮廓参差
## 由深咬口 + 撕裂承担，旋转只作轻微挂歪暗示。
const PANEL_ROTATION_DEG := -2.2
## 进度条暗槽/填充（HUD meter 语言：暗槽 + 暖色填充，1px 角像素风）。
## 返工7 P4 第三轮：StyleBoxFlat 圆角矩形 → 撕裂手绘纹理（StyleBoxTexture）：
## GPT 全帧读「计数 0/1 周围小型矩形/直角轮廓」—— 进度条轨道/填充本身是
## 完美圆角矩形。改用撕裂 Butter 条（上/下边参差缺口 + 端部咬口）—— 读作
## 手绘粉笔 meter，绝无矩形轮廓。StyleBoxTexture 保留 ProgressBar 语义
## （value 更新不变）；GoalTracker root 已设 TEXTURE_FILTER_NEAREST，
## 子 ProgressBar 继承该过滤 —— 像素风保持。
const METER_BG_ALPHA := 0.16
const METER_SEED := 0x51ED_B17E
var _meter_groove_tex: ImageTexture = null
var _meter_fill_tex: ImageTexture = null

## 懒生成撕裂 meter 纹理（[is_fill] true=Butter 填充 / false=暗槽）。
## 尺寸 32×6 texel（texel 2px → 64×12px，ProgressBar 220px 宽拉伸 ——
## StyleBoxTexture 拉伸保持撕裂边缘；fill 只显示已填充部分）。
## 撕裂：上/下边 ~40% 列 1-2 texel 缺口 + 端部 2-3 texel 咬口 + 内部
## 1-2px 亮度抖动 —— 手绘粉笔 meter，绝无矩形轮廓。确定性 seed。
func _meter_texture(is_fill: bool) -> ImageTexture:
	if is_fill and _meter_fill_tex != null:
		return _meter_fill_tex
	if not is_fill and _meter_groove_tex != null:
		return _meter_groove_tex
	var w := 32
	var h := 6
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.0, 0.0, 0.0, 0.0))
	var rng := RandomNumberGenerator.new()
	rng.seed = METER_SEED + (0x77 if is_fill else 0)
	var base := Palette.BUTTER if is_fill else Color(0.0, 0.0, 0.0, METER_BG_ALPHA * 2.2)
	for y in h:
		for x in w:
			# 逐 texel 亮度抖动（手绘粉笔）
			var j := (rng.randf() - 0.5) * 0.10
			var c := Color(
				clampf(base.r + j, 0.0, 1.0),
				clampf(base.g + j, 0.0, 1.0),
				clampf(base.b + j, 0.0, 1.0),
				base.a)
			img.set_pixel(x, y, c)
	# 上/下边参差缺口（~40% 列 1-2 texel）—— 无平直上下边界
	for x in w:
		var r := rng.randf()
		if r < 0.40:
			img.set_pixel(x, 0, Color(0.0, 0.0, 0.0, 0.0))
			if r < 0.16 and h > 1:
				img.set_pixel(x, 1, Color(0.0, 0.0, 0.0, 0.0))
		var r2 := rng.randf()
		if r2 < 0.40:
			img.set_pixel(x, h - 1, Color(0.0, 0.0, 0.0, 0.0))
			if r2 < 0.16 and h > 2:
				img.set_pixel(x, h - 2, Color(0.0, 0.0, 0.0, 0.0))
	# 端部咬口（左/右 2-3 texel 三角 —— 无规整端面）
	var end_bite := 3
	for dy in end_bite:
		for dx in end_bite:
			if dx + dy < end_bite + rng.randi_range(0, 1):
				if dx < w:
					img.set_pixel(dx, dy, Color(0.0, 0.0, 0.0, 0.0))
				if w - 1 - dx >= 0:
					img.set_pixel(w - 1 - dx, h - 1 - dy, Color(0.0, 0.0, 0.0, 0.0))
	var tex := ImageTexture.create_from_image(img)
	if is_fill:
		_meter_fill_tex = tex
	else:
		_meter_groove_tex = tex
	return tex

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
	# 返工7 P4（目标框读作「深色半透明长方形面板」）：轻微挂歪（手挂木牌
	# 语言 —— 一块牌挂歪了）。-4.5° 旋转绕中心 —— 视觉上四边不再互相
	# 平行/垂直（27px 坡度，全帧明显可辨），配合撕裂轮廓彻底消除「完美
	# 矩形」读法；无输入/布局依赖（纯展示 Control，tests 无结构断言）。
	rotation_degrees = PANEL_ROTATION_DEG
	pivot_offset = custom_minimum_size * 0.5
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
	var groove := StyleBoxTexture.new()
	groove.texture = _meter_texture(false)
	groove.set_expand_margin_all(2.0)
	_progress_bar.add_theme_stylebox_override("background", groove)
	var fill := StyleBoxTexture.new()
	fill.texture = _meter_texture(true)
	fill.set_expand_margin_all(2.0)
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
		# 返工7 P4 第二轮（GPT run1：目标框读作「半透明深色面板」）：改
		# 用更浅、更不透明的实木色（DESK_WOOD 原色 + alpha 0.95）——
		# 读作一块实心旧木牌（物件），绝非深色半透明 UI 面板。文字仍
		# 可读（暖木 vs 奶油文字对比足够）。low-sat：面板本身中饱和，
		# alpha 提高反而减少露墙 —— 预算安全。
		_goal_panel_base(),
		Palette.BUTTER,
		1.0,
		2,  # shadow_texels —— 底部内置手绘硬阴影（挂牌语言）
		PANEL_TEAR_STRENGTH,
		PANEL_GNAW_CORNER,
		PANEL_GNAW_TEXELS,
		PANEL_GNAW_CORNER2,
		PANEL_GNAW_TEXELS2,
		PANEL_GNAW_CORNER3,
		PANEL_GNAW_TEXELS3,
		PANEL_BOTTOM_SLOPE,
		PANEL_TOP_SLOPE)
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
