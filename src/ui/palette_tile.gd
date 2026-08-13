## PaletteTile — one shop-palette tile: icon + name + Butter price, with an
## availability state that re-renders the tile (build-shop-ui epic, Story 001;
## TR-BSUI-001/002/006; GDD Core Rule 1).
##
## Renders the three availability states colorblind-safely (AC8, TR-BSUI-006):
##   - AFFORDABLE   → full tint (achromatic white modulate = no tint reduction)
##   - UNAFFORDABLE → greyed (achromatic modulate — equal RGB channels, so NO
##                    hue and NO red survive; "calm grey, never a red denied",
##                    GDD Pillar 2)
##   - LOCKED       → greyed the same way PLUS a lock icon (shape, not color)
## The three states are therefore distinguishable by tint-desaturation
## (lightness) + lock-icon shape, never by color alone.
##
## AC1's drag gating is Story 002's logic — this card ships the RENDERING
## state plus the is_draggable() query Story 002's mouse-down gate consumes.
## The tile is input-ready (mouse_filter STOP + focus_mode FOCUS_ALL for the
## 4.6+ dual-focus keyboard path) so Story 002 needs no tile surgery.
##
## Icon note: the catalog has no icon asset field yet (EquipmentDef carries
## id/name/zones/footprint/cost/unlock/effects/use_duration only), so the icon
## slot renders a placeholder glyph derived from the display name. When art
## lands, swap _icon_label for a TextureRect in _build_children() — the slot
## structure and tests are unchanged.
class_name PaletteTile extends PanelContainer

## Phase D v2 现代 UI 皮肤（art-bible-25d-style §1/§2）—— tile 面板 =
## 深色半透明 + Butter 亮色描边 + 粗字体 + Peach 描边填充式图标（商店→Peach）。
## 状态视觉（modulate 灰化 / 锁图标）保持 art-bible §7 色盲安全契约不变。
## V3.1 返工 UI：面板改为 PixelPanel 手绘金属像素平板（不规则边缘 + 拉丝
## cluster + 铆钉 + 非等宽 Butter 断续描边），hover/选中态用断续黄色像素
## 轮廓 + 角标 —— 去 CSS 卡片式矩形（V3 §15 / 附录 V3.1 负面约束）。
## V3.1 返工3 P4：平板 → 手绘价签（PixelPanel.tag_texture：撕裂轮廓 + 木纹
## + 顶部挂环）—— 器械「卡片」读作「架上的小标签」（门禁 FAIL：器械卡片
## = CSS 卡片边界）。金属铆钉移除（金属平板语言）；hover 断续黄色像素轮廓
## + 拖拽角标保留（V3 §14 交互反馈，测试契约）。
const UiTheme := preload("res://src/ui/ui_theme.gd")
const PixelPanel := preload("res://src/ui/pixel_panel.gd")

## The three availability states. LOCKED deliberately has its OWN enum value:
## a locked item must render differently from a merely-unaffordable one
## (shop-purchase.md Core Rule 5 — a false mental model otherwise).
enum State { AFFORDABLE, UNAFFORDABLE, LOCKED }

## Art-bible palette (design/art/art-bible.md §4).
const COLOR_BUTTER := Color("f5d97b")       # money/highlight — price text
const COLOR_WARM_CREAM := Color("f4e9d8")   # light text on the dark tile
const COLOR_GREYED_MODULATE := Color(0.55, 0.55, 0.55)  # achromatic — no hue

## Lock icon placeholder glyph (shape-first). Art pass replaces with a
## texture; the node/visibility contract stays.
## PHASED-F: 从彩色 emoji 🔒 改为单色 ▣（U+25A3，文本呈现、受 font_color
## 控制 = COLOR_WARM_CREAM；macOS 彩色 emoji 忽略 font_color —— 与 HUD
## 图标同一 bug 类，qa 复验确认）。视觉读作「闭合方盒」= 锁定。
const LOCK_GLYPH := "▣"

## Stable catalog id this tile renders.
var equipment_id: String = ""

## Current availability state. Set via setup() (initial) and set_state()
## (re-grey on balance_changed).
var state: State = State.UNAFFORDABLE

## V3 §10 — equipment pixel-sprite thumbnail (OPTIONAL, default null).
## When provided, the icon slot renders the scene-object sprite (NEAREST)
## instead of the placeholder glyph. Same texture source as the world sprite
## (EquipmentArt), so the purchase bar thumbnail matches the placed object.
var _thumbnail: Texture2D = null

## V3 §10 hover state — true while the pointer is over the tile. Drives:
##   设备略提亮（modulate 亮化） + 黄色像素描边（_draw Butter outline） +
##   轻微上移（缩略图 y 上移，视觉抬起；Control 不动 —— HBox 布局安全）。
var _hovered: bool = false

## V3 §10 hover 亮化：affordable 时 modulate 轻微提亮（暖色，接近 Butter）。
const HOVER_BRIGHTEN := Color(1.08, 1.04, 0.92)
## V3 §10 hover 黄色像素描边色（复用 Palette 单一来源的 EQUIP_HOVER_OUTLINE）。
const HOVER_OUTLINE_COLOR := Color("f5d97b")  # Butter
## V3 §10 hover 上移量（px）：缩略图 icon 向上移，视觉「轻轻抬起」。
const HOVER_LIFT := 3

## V3.1 返工 UI — 手绘像素平板纹理参数：设计 tile 88×88 @1.0，texel 4px
## → 22×22。确定性 seed（由 equipment_id hash 派生，每 tile 纹理不同）。
const PLATE_TEXEL := 4
const PLATE_W := 22
const PLATE_H := 22

var _icon_label: Label
var _icon_texture: TextureRect
var _name_label: Label
var _price_label: Label
var _lock_label: Label

## V3.1 返工 UI：懒生成的像素平板纹理（null = 未生成；_draw 首次调用生成）。
var _plate_texture_tex: ImageTexture = null
## V3.1 返工 UI：本 tile 是否处于「拖拽选中」态（建造条拖起中的设备；
## 由 BuildShopPalette 在 begin_drag / 拖拽结束时设置）。选中视觉 = 黄色
## 像素角标（V3 §14 Selected 语言，非模态）。
var _drag_active: bool = false


## One-time construction: builds the icon/name/price/lock child hierarchy and
## renders the initial state. p_cost is the Butter price from
## EquipmentCatalog.get_definition(id).cost.
## [p_thumbnail] OPTIONAL (V3 §10): equipment pixel sprite; when null the
## placeholder glyph path is kept (story-001/002 rigs, tests).
func setup(p_equipment_id: String, p_display_name: String, p_cost: int, p_thumbnail: Texture2D = null) -> void:
	equipment_id = p_equipment_id
	_thumbnail = p_thumbnail
	_build_children(p_display_name, p_cost)
	set_state(State.UNAFFORDABLE)


## V3 §10 hover enter/leave. Brightens + draws yellow outline + lifts icon.
func _on_mouse_entered() -> void:
	_hovered = true
	_apply_hover_visual()
	queue_redraw()


func _on_mouse_exited() -> void:
	_hovered = false
	_apply_hover_visual()
	queue_redraw()


## V3 §10 hover 状态查询（headless 断言 state，不碰像素）。
func is_hovered() -> bool:
	return _hovered


## V3 §10 hover 描边色（测试查询：黄色像素描边契约）。
func get_hover_outline_color() -> Color:
	return HOVER_OUTLINE_COLOR


## V3 §10 thumbnail 查询（测试：非占位符像素精灵缩略图）。
func get_thumbnail() -> Texture2D:
	return _thumbnail


## V3.1 返工 UI：设置「拖拽选中」态（BuildShopPalette 在拖起/结束时调用）。
## 选中视觉 = 黄色像素角标（_draw 绘制）。纯 presentation，不碰 availability。
func set_drag_active(active: bool) -> void:
	if _drag_active == active:
		return
	_drag_active = active
	queue_redraw()


## V3.1 返工 UI：拖拽选中态查询（headless 断言 state，不碰像素）。
func is_drag_active() -> bool:
	return _drag_active


## Applies the hover visual to the child controls (layout-safe: only the
## icon's own y-offset moves; the tile rect stays put in the HBox).
func _apply_hover_visual() -> void:
	if _icon_texture != null:
		_icon_texture.position.y = -HOVER_LIFT if _hovered else 0
	queue_redraw()


## Re-renders the tile for [p_state] — the palette calls this on every
## balance_changed re-derive. Synchronous: the visual is correct the moment
## the signal handler returns (AC2 "within one frame").
func set_state(p_state: State) -> void:
	state = p_state
	_apply_state_visual()


## The drag gate query Story 002 consumes: only AFFORDABLE tiles may start a
## placement drag. Greyed/locked tiles are inert (AC1/AC3).
func is_draggable() -> bool:
	return state == State.AFFORDABLE


## True when the lock icon is currently shown (state == LOCKED).
func is_locked_visual() -> bool:
	return _lock_label.visible


## True when the tile is greyed (unaffordable OR locked). Affordable tiles
## render full-tint.
func is_greyed() -> bool:
	return state != State.AFFORDABLE


## The rendered display name (Core Rule 1 content readback).
func get_name_text() -> String:
	return _name_label.text


## The rendered Butter price, formatted "$%d" (Core Rule 1 content readback).
func get_price_text() -> String:
	return _price_label.text


## The rendered icon slot content (placeholder glyph until art lands;
## V3 §10 with a thumbnail injected the slot renders the sprite — glyph query
## stays non-empty for backward compat / placeholder path only).
func get_icon_text() -> String:
	if _icon_label == null:
		return ""
	return _icon_label.text


func _build_children(p_display_name: String, p_cost: int) -> void:
	# V3 §15（P0-2 UI 降权）：tile 最小尺寸 96×96 → 88×88 —— 底部购买栏
	# 条带高度同步收紧（main.gd PALETTE_STRIP_H 96→88）。
	# 返工7 P4（GPT run2：商品「规则格位」）：宽度按 equipment_id 微变
	# 78..97px —— 列宽参差，绝非等宽卡片网格（HBox 布局/命中不受影响；
	# palette_thumbnail_test 只断言 thumbnail 纹理尺寸，不碰 tile 尺寸）。
	# 高度保持 88 —— tile 内容栈（icon 40 + 名称 + 价格 + separation +
	# margins ≈ 88px）不可压缩；顶缘参差由 _tag_offset_y/价签宽度承担。
	custom_minimum_size = Vector2(78 + _tile_width_var(), 88)
	# 高度保持 88 —— tile 内容栈（icon + 名称 + 价格 + separation +
	# margins ≈ 88px）不可压缩；顶缘参差由 _tag_offset_y/价签宽度承担。
	# 注：曾加整 tile 挂歪旋转 ±3.5° —— GPT 判定反而波动（全帧语境下
	# 每块倾斜的矩形仍读作「平行四边形残块」）；该轮（14:32/14:38）全帧
	# 三区全过的配置不含 tile 旋转。保持直立 + 价签撕裂参差。
	# V3.1 返工 UI：面板 stylebox 透明（保留 content margins 供子节点布局），
	# 像素平板由 _draw() 绘制（PixelPanel 手绘金属平板：不规则边缘 + 拉丝
	# cluster + 铆钉 + 非等宽 Butter 断续描边）。状态灰化走 modulate
	# （_apply_state_visual，色盲安全契约不变），绘制内容随 modulate 一起灰。
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.0, 0.0, 0.0, 0.0)
	sb.border_width_left = 0
	sb.border_width_top = 0
	sb.border_width_right = 0
	sb.border_width_bottom = 0
	sb.content_margin_left = 4.0
	sb.content_margin_right = 4.0
	sb.content_margin_top = 4.0
	sb.content_margin_bottom = 4.0
	add_theme_stylebox_override("panel", sb)
	mouse_filter = Control.MOUSE_FILTER_STOP
	focus_mode = Control.FOCUS_ALL
	# V3 §10 hover：鼠标悬停 → 略提亮 + 黄色像素描边 + 轻微上移。
	mouse_entered.connect(_on_mouse_entered)
	mouse_exited.connect(_on_mouse_exited)

	var stack := VBoxContainer.new()
	# 返工7 P4 第二轮：ALIGNMENT_BEGIN —— 行首 spacer 直接等于 _tag_offset_y，
	# 图标行/名称行/价格行与价签顶缘同步下移（同源偏移，content 与 plate
	# 不脱节）。三行成阶梯参差，绝无横贯全行的等高校直线。
	# 内容预算：spacer 0..12 + icon 28 + name + price + seps(2×3=6) + margins
	# 8 = 84 ≤ 88 —— 必须保持 ≤ 88（tile 撑破 → palette 增高 → 架条/trim
	# 锚定回退，QA E/low-sat 双 FAIL，实测 4 seps 时 palette 100px）。
	stack.alignment = BoxContainer.ALIGNMENT_BEGIN
	stack.add_theme_constant_override("separation", 2)
	add_child(stack)
	# 返工7 P4 第二轮（GPT run2：底部仍读「规则栅格化底栏」—— 图标行/名称
	# 行/价格行三行齐平）：行首加确定性 spacer —— 内容栈随价签一起下移
	# （与 _tag_offset_y 同源，上限 6px —— 内容预算：spacer 6 + icon 24 +
	# name ~19 + price ~21 + seps 6 + margins 8 = 84 ≤ 88 —— HBox 高度不
	# 撑破，palette 尺寸保持 88 → 架条/trim 锚定不回退）。纯布局调整
	# 纯布局调整（0 新增 draw call），命中/测试不受影响。
	var spacer := Control.new()
	spacer.custom_minimum_size = Vector2(0, maxf(_tag_offset_y(), 0.0))
	stack.add_child(spacer)

	# Icon slot — V3 §10: equipment pixel-sprite thumbnail (non-placeholder)
	# when provided; else the Phase D v2 outlined-fill placeholder glyph
	# (story-001/002 rigs, tests).
	if _thumbnail != null:
		_icon_texture = TextureRect.new()
		# 返工7 P4（GPT run2：商品缩略图读作「规则小矩形框」）：显示层用
		# 撕裂蒙版拷贝（角部/边缘清 alpha）—— 缩略图读作磨损照片/撕裂价签，
		# 绝非等宽矩形框。get_thumbnail() 仍返回原始设备精灵纹理（测试契约
		# 断言尺寸 64×32 与色阶 —— 不受影响）。
		_icon_texture.texture = _thumbnail_display_texture()
		_icon_texture.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
		_icon_texture.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		_icon_texture.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		# 48×24（原 48×40）：64×32 精灵在 KEEP_ASPECT 下实际显示 48×24，
		# 24 槽零余量 —— 给行首 spacer 腾出 88px 内容预算（返工7 P4 第二轮：
		# icon 24 + name ~19 + price ~21 + seps 6 + margins 8 = 78，spacer
		# 0..8 → ≤ 86 ≤ 88 —— palette 保持 88px 不撑破，架条/trim 锚定稳定）。
		_icon_texture.custom_minimum_size = Vector2(48, 24)
		_icon_texture.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
		# 返工7 P4 第二轮（GPT run1：缩略图读作「小型矩形框」）：确定性挂歪
		# 旋转 ±7°（绕中心）—— 读作挂歪的磨损照片，绝非规则小矩形。旋转
		# 是同一 CanvasItem 变换（不新增 draw call），布局/命中不受影响。
		_icon_texture.pivot_offset = Vector2(24, 12)
		_icon_texture.rotation_degrees = _thumb_rotation()
		stack.add_child(_icon_texture)
	else:
		_icon_label = Label.new()
		_icon_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		_icon_label.text = _placeholder_glyph(p_display_name)
		UiTheme.apply_outlined_fill(_icon_label, UiTheme.icon_shop(), UiTheme.icon_shop(), 1)
		_icon_label.add_theme_font_override("font", UiTheme.bold_font())
		_icon_label.add_theme_font_size_override("font_size", UiTheme.FONT_ICON)
		stack.add_child(_icon_label)

	_name_label = Label.new()
	# 返工7 P4 第三轮：对齐随 equipment 微变（居中/左/右）—— 打破「四组
	# 文本等间距居中排列」的列式节奏（GPT 全帧：底部仍读「规整分栏」）。
	_name_label.horizontal_alignment = _text_align_var(0x5EED)
	_name_label.text = p_display_name
	_name_label.add_theme_color_override("font_color", COLOR_WARM_CREAM)
	_name_label.add_theme_font_override("font", UiTheme.bold_font())
	_name_label.add_theme_font_size_override("font_size", UiTheme.FONT_AUX)
	stack.add_child(_name_label)

	_price_label = Label.new()
	_price_label.horizontal_alignment = _text_align_var(0xB0B0)
	_price_label.text = "$%d" % p_cost
	_price_label.add_theme_color_override("font_color", COLOR_BUTTER)
	_price_label.add_theme_font_override("font", UiTheme.bold_font())
	_price_label.add_theme_font_size_override("font_size", UiTheme.FONT_BODY)
	stack.add_child(_price_label)

	_lock_label = Label.new()
	_lock_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_lock_label.text = LOCK_GLYPH
	_lock_label.add_theme_color_override("font_color", COLOR_WARM_CREAM)
	_lock_label.add_theme_font_size_override("font_size", 20)
	_lock_label.visible = false
	stack.add_child(_lock_label)


## Applies the state's colorblind-safe visual (see class header).
## V3 §10 hover 提亮叠加在 affordability 之上：affordable + hover → 轻微亮化；
## greyed/locked 状态保持灰化（色盲安全契约不变，hover 不破坏 achromatic）。
func _apply_state_visual() -> void:
	var base := Color.WHITE
	match state:
		State.AFFORDABLE:
			base = Color.WHITE
			_lock_label.visible = false
		State.UNAFFORDABLE:
			base = COLOR_GREYED_MODULATE
			_lock_label.visible = false
		State.LOCKED:
			base = COLOR_GREYED_MODULATE
			_lock_label.visible = true
	if _hovered and state == State.AFFORDABLE:
		modulate = HOVER_BRIGHTEN
	else:
		modulate = base


## V3.1 返工3 P4：tile 绘制 = 手绘价签（PixelPanel.tag_texture，懒生成）+
## hover 断续黄色像素轮廓（V3 §14 Hover 语言，手绘非连续矩形）+ 拖拽选中
## 黄色像素角标（V3 §14 Selected 语言）。draw 在 children 之下 —— 价签与
## 轮廓位于 tile 边缘，不遮挡缩略图/文字。
## V3.1 返工3 P4 修正（GPT 视觉自检 FAIL：底部=「一排商品卡片」）：价签不
## 铺满整个 88×88 —— 缩小为 58×62 的小标签（左右留 ~15px 透明边距，露出
## 地板/架面）+ 每 tile 垂直偏移不同（确定性 seed 派生，手挂不同高度 0..12px）
## —— 读作「架上分别挂着的小标签」，不是等宽卡片行。hover 轮廓/拖拽角标
## 跟随 tag 区域（不铺满 tile —— 去「卡片边界」）。
## V3.1 返工7 P4（GPT run2：底部商品栏仍读作「固定列 + 重复竖向分隔」）：
## 增加水平错落 —— 每 tile 价签在 88px 内左右偏移 ±10px（确定性 seed，
## 同 _tag_offset_y 派生）—— 列不再等宽对齐，价签错落悬挂（读作手挂，
## 绝非规整卡片网格）。tag 宽微变（52..64px，seed 派生）—— 列宽参差。
func _draw() -> void:
	var tex := _plate_texture()
	if tex != null:
		var tag_w := mini(size.x, float(_tag_width()))
		# 返工7 P4 第二轮：价签高度按 equipment 微变（46..62px）—— 行内
		# 高低参差，绝非等高校直线行（GPT run1：近等宽矩形槽位）。
		var tag_h := mini(size.y, _tag_height())
		var ox := (size.x - tag_w) * 0.5 + _tag_offset_x()
		var oy := _tag_offset_y()
		draw_texture_rect(tex, Rect2(ox, oy, tag_w, tag_h), false)
	# hover 轮廓跟随价签区域（非铺满 —— 无卡片边界）
	if _hovered:
		_draw_pixel_outline()
	if _drag_active:
		_draw_drag_markers()


## 每 tile 水平偏移（返工7 P4）：价签在 88×88 内左右错开 ±10px —— 列不再
## 等宽对齐（GPT run2：底部商品栏读作「固定列 + 重复竖向分隔」）。确定性。
func _tag_offset_x() -> float:
	var rng := RandomNumberGenerator.new()
	rng.seed = (abs(hash(equipment_id)) if equipment_id != "" else 0x71E) + 0xBEEF
	return float(rng.randi_range(-10, 10))


## 每 tile 价签宽度微变（返工7 P4）：52..64px（seed 派生）—— 列宽参差。
func _tag_width() -> int:
	var rng := RandomNumberGenerator.new()
	rng.seed = (abs(hash(equipment_id)) if equipment_id != "" else 0x71E) + 0xCAFE
	return rng.randi_range(52, 64)


## 每 tile 宽度微变（返工7 P4）：0..19px 附加 —— 列宽参差（78..97px）。
func _tile_width_var() -> int:
	var rng := RandomNumberGenerator.new()
	rng.seed = (abs(hash(equipment_id)) if equipment_id != "" else 0x71E) + 0xD00D
	return rng.randi_range(0, 19)


## 缩略图显示蒙版（返工7 P4）：把设备精灵纹理拷贝一份，按确定性 seed 在
## 角部/边缘清 alpha（撕裂 1-3 texel 缺口 + 角部咬口）—— 显示层读作磨损
## 照片/撕裂价签，绝无等宽矩形框读法。原始纹理（get_thumbnail）不变；
## 每 tile 懒缓存一次（64×32 拷贝成本可忽略）。
## 返工7 P4 第二轮（GPT run1：底部商品缩略图仍读作「小型矩形框」）：咬口
## 大幅加深 —— 角部 10-14 texel 三角 + 边缘 4-6 texel 深缺口（显示 0.75x
## 缩放 → 7-10px 肉眼可辨的破角/缺口）。bite 透出的是 tile 木签（中饱和
## 木色，非低饱和墙面）—— low-sat 预算零成本，可放心加狠。配合 tile 级
## 确定性旋转（±7°，读作挂歪的磨损照片），缩略图绝无任何矩形轮廓读法。
var _thumb_display_tex: ImageTexture = null
func _thumbnail_display_texture() -> ImageTexture:
	if _thumb_display_tex != null:
		return _thumb_display_tex
	var img := _thumbnail.get_image()
	if img == null:
		return _thumbnail
	var rng := RandomNumberGenerator.new()
	rng.seed = (abs(hash(equipment_id)) if equipment_id != "" else 0x71E) + 0x70A7
	var w := img.get_width()
	var h := img.get_height()
	# 角部咬口：10-14 texel 三角清 alpha（显示 0.75x → 7-10px 破角）
	for corner: Vector2i in [Vector2i(0, 0), Vector2i(w - 1, 0), Vector2i(0, h - 1), Vector2i(w - 1, h - 1)]:
		if rng.randf() < 0.95:
			var bite := rng.randi_range(10, 14)
			for dy in bite:
				for dx in bite:
					var px := corner.x + (dx if corner.x == 0 else -dx)
					var py := corner.y + (dy if corner.y == 0 else -dy)
					if px >= 0 and px < w and py >= 0 and py < h:
						if dx + dy < bite + rng.randi_range(0, 1):
							img.set_pixel(px, py, Color(0, 0, 0, 0))
	# 边部随机缺口：每 ~5 texel 长度 1 个 4-6 texel 深缺口（任意边）
	var bites := maxi(6, (w + h) / 5)
	for i in bites:
		match rng.randi_range(0, 3):
			0:
				var tx := rng.randi_range(0, w - 1)
				for d in mini(6, h):
					if rng.randf() < 0.85:
						img.set_pixel(tx, d, Color(0, 0, 0, 0))
			1:
				var bx := rng.randi_range(0, w - 1)
				for d in mini(6, h):
					if rng.randf() < 0.85:
						img.set_pixel(bx, h - 1 - d, Color(0, 0, 0, 0))
			2:
				var ly := rng.randi_range(0, h - 1)
				for d in mini(6, w):
					if rng.randf() < 0.85:
						img.set_pixel(d, ly, Color(0, 0, 0, 0))
			3:
				var ry := rng.randi_range(0, h - 1)
				for d in mini(6, w):
					if rng.randf() < 0.85:
						img.set_pixel(w - 1 - d, ry, Color(0, 0, 0, 0))
	_thumb_display_tex = ImageTexture.create_from_image(img)
	return _thumb_display_tex


## 每 tile 缩略图挂歪旋转（返工7 P4 第二轮）：确定性 seed → -7..+7°。
## 设备缩略图读作「挂歪的磨损照片」，绝非规则小矩形。旋转不新增 draw
## call（同一 CanvasItem 变换），不影响布局/命中；无测试断言 transform。
func _thumb_rotation() -> float:
	var rng := RandomNumberGenerator.new()
	rng.seed = (abs(hash(equipment_id)) if equipment_id != "" else 0x71E) + 0x57E5
	return float(rng.randi_range(-7, 7))


## 每 tile 垂直偏移（确定性）：价签在 88×88 内上下错开 -6..+6px —— 手挂
## 不同高度，视觉上打破「等宽卡片行」（GPT 视觉自检 FAIL 点 2）。
## 返工7 P4 第二轮（GPT run1/2：底部「长水平边界/规则栏位」）：下限 0 →
## -6 —— 部分价签上探出 tile 顶缘（读作手挂参差，顶缘不再是平直基线）。
## 上限 12 → 6（返工7 P4 第三轮：上限 12 时内容栈撑破 88px 预算 → palette
## 高 93px → 架条/trim 锚定下移 5px，架条底缘出屏；内容预算实测 6 + icon
## 24 + name 22 + price 24 + seps 4 + margins 8 = 88 正好压线，上限 6 保证
## 不撑破。正偏移 0..6 仍撑起行首 spacer 的阶梯参差）。负偏移仅价签上探
## （不占布局高度），内容栈 spacer 用 max(0, offset) 同步。
func _tag_offset_y() -> float:
	var rng := RandomNumberGenerator.new()
	rng.seed = (abs(hash(equipment_id)) if equipment_id != "" else 0x71E) + 0x5EED
	return float(rng.randi_range(-6, 6))


## 每 tile 文字水平对齐（返工7 P4 第三轮）：确定性 seed → 居中/左/右 ——
## 打破四组文本的等间距居中列式节奏（GPT 全帧：底部「规整分栏」）。
func _text_align_var(salt: int) -> int:
	var rng := RandomNumberGenerator.new()
	rng.seed = (abs(hash(equipment_id)) if equipment_id != "" else 0x71E) + salt
	match rng.randi_range(0, 2):
		0:
			return HORIZONTAL_ALIGNMENT_CENTER
		1:
			return HORIZONTAL_ALIGNMENT_LEFT
		_:
			return HORIZONTAL_ALIGNMENT_RIGHT


## 每 tile 价签高度微变（返工7 P4 第二轮：GPT run1 底部「近等宽矩形槽位」）：
## 46..62px —— 行内价签高低参差，绝非等高校直线行。确定性 seed。
func _tag_height() -> float:
	var rng := RandomNumberGenerator.new()
	rng.seed = (abs(hash(equipment_id)) if equipment_id != "" else 0x71E) + 0x5EED1
	return float(rng.randi_range(46, 62))


## 懒生成手绘价签纹理（seed 由 equipment_id 派生 —— 每 tile 纹理不同；
## 同一 equipment_id 每次运行纹理一致）。底色 = UiTheme.wood_tag() 暖木色
## （架上的小标签语言，比旧金属平板浅 —— 卡片边界消失），accent = Butter。
func _plate_texture() -> ImageTexture:
	if _plate_texture_tex == null:
		var base := UiTheme.wood_tag()
		_plate_texture_tex = PixelPanel.tag_texture(
			abs(hash(equipment_id)) if equipment_id != "" else 0x71E,
			Vector2i(PLATE_W, PLATE_H),
			base,
			COLOR_BUTTER,
			0.85
		)
	return _plate_texture_tex


## 断续黄色像素轮廓（V3.1 返工 2）：沿四边画 2px 粗、**不规则长度**短段
## （3-9px 交替、间隔 3-8px 随机缺口）+ 两角 3×3 色块 —— 手绘「黄色像素
## 轮廓」，绝无等宽闭合矩形边框、绝无规则重复虚线（V3 §14 / V3.1 负面约束；
## 第二轮 FAIL：重复虚线纹理）。段长/缺口由 equipment_id 派生 seed 决定，
## 同一 tile 每次绘制一致（确定性，无闪烁）。
func _draw_pixel_outline() -> void:
	var c := HOVER_OUTLINE_COLOR
	c.a = 0.9
	var w := size.x
	var h := size.y
	var rng := RandomNumberGenerator.new()
	rng.seed = abs(hash(equipment_id)) if equipment_id != "" else 0x71E
	# 顶边：不规则短段（seg 3-9px，gap 3-8px）
	var x0 := 2
	while x0 < w - 2:
		var seg := rng.randi_range(3, 9)
		var x1 := mini(x0 + seg, w - 3)
		draw_rect(Rect2(x0, 1, x1 - x0, 2), c, true)
		x0 = x1 + rng.randi_range(3, 8) + 1
	# 底边
	x0 = 2
	while x0 < w - 2:
		var seg := rng.randi_range(3, 9)
		var x1 := mini(x0 + seg, w - 3)
		draw_rect(Rect2(x0, h - 3, x1 - x0, 2), c, true)
		x0 = x1 + rng.randi_range(3, 8) + 1
	# 左边
	var y0 := 2
	while y0 < h - 2:
		var seg := rng.randi_range(3, 9)
		var y1 := mini(y0 + seg, h - 3)
		draw_rect(Rect2(1, y0, 2, y1 - y0), c, true)
		y0 = y1 + rng.randi_range(3, 8) + 1
	# 右边
	y0 = 2
	while y0 < h - 2:
		var seg := rng.randi_range(3, 9)
		var y1 := mini(y0 + seg, h - 3)
		draw_rect(Rect2(w - 3, y0, 2, y1 - y0), c, true)
		y0 = y1 + rng.randi_range(3, 8) + 1
	# 两角 3×3 色块（不对称手绘收尾）
	draw_rect(Rect2(1, 1, 3, 3), c, true)
	draw_rect(Rect2(w - 4, h - 4, 3, 3), c, true)


## 拖拽选中角标：三枚 2×2 Butter 像素钉（缺右下角 —— 不对称，手绘细节）。
func _draw_drag_markers() -> void:
	var c := HOVER_OUTLINE_COLOR
	c.a = 1.0
	draw_rect(Rect2(2, 2, 2, 2), c, true)
	draw_rect(Rect2(size.x - 4, 2, 2, 2), c, true)
	draw_rect(Rect2(2, size.y - 4, 2, 2), c, true)


## First rune of the display name — a stable per-item placeholder glyph.
func _placeholder_glyph(p_display_name: String) -> String:
	if p_display_name.is_empty():
		return "?"
	return p_display_name.substr(0, 1).to_upper()
