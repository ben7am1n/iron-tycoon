## Hud — the always-on top bar (Story HUD-001 layout + state binding; Story
## HUD-002 money count tween; Story HUD-003 calm satisfaction meter; Story
## HUD-004 pause/speed transport + day/time display).
##
## Story: production/epics/hud/story-001-top-bar-layout-state-binding.md,
##        production/epics/hud/story-002-money-count-tween.md,
##        production/epics/hud/story-003-satisfaction-meter.md,
##        production/epics/hud/story-004-pause-speed-transport-day-time.md
## Req:   TR-HUD-001 (minimal top bar: money / satisfaction / day+time+transport),
##        TR-HUD-004 (money count: tween digits old->new over ~0.25s on
##        balance_changed; never red flash on spend),
##        TR-HUD-002 (satisfaction meter: Sage -> warm neutral -> soft muted
##        Dusty Rose only at the very low end; NEVER saturated red, NEVER pulse),
##        TR-HUD-003 (meter paired with numeric % AND shape-changing face icon —
##        filled vs outline — so state is readable without color),
##        TR-HUD-005 (hotkeys Space/1/2/3 via _unhandled_key_input, focus-independent),
##        TR-HUD-006 (read-only + transport only — no popups/toasts/badges),
##        TR-HUD-007 (on load renders paused state + loaded values immediately)
## ADR:   ADR-0001 (UI systems are scene-tree Nodes, not RefCounted sim systems;
##        they receive dependencies via typed init parameters from the
##        composition root), ADR-0005 (typed signal connections only;
##        balance_changed S6 subscription; tick_completed S2 refresh hook;
##        §5 Input Bridge — keyboard via _unhandled_key_input for dual-focus)
##
## This is a scene-tree Control hierarchy (NOT a SimSystem). It is the quiet
## frame around the gym: it owns NO simulation state, only DISPLAYS what
## Economy / Satisfaction / TimeSystem expose and FORWARDS pause/speed input
## back to TimeSystem (Story 004 — the ONLY simulation mutation the HUD makes,
## TR-HUD-006). Story 001 scope is layout + read-only state binding; Story 002
## adds the money count-up/down tween. Story 003 adds the calm satisfaction
## meter: the fill RAMP (Sage high -> warm neutral mid -> muted Dusty Rose very
## low end, never saturated red), the shape-changing face icon (filled vs
## outline — colorblind-safe), the ~1 s ease on global_satisfaction change
## (re-targets mid-tween, no queue backlog — same posture as the money tween),
## and the reduced-motion static fill.
## STATE BINDING (event-driven, never poll):
##   - balance_changed(new_balance, delta)   -> money count tween (S6)
##   - global_satisfaction (plain var)       -> % label + meter fill + icon
##                                              (read on init + each tick_completed)
##   - get_tick_count()                      -> day + time_of_day derivation
##                                              (day = 1 + floor(tc/TICKS_PER_DAY);
##                                              time_of_day = (tc mod TICKS_PER_DAY)/TICKS_PER_DAY)
##   - is_paused()/get_speed_multiplier()    -> transport button active cues
##                                              (Story 004: PauseButton + 1×/2×/3×)
##   - tick_completed (S2, orchestrator)     -> refresh cadence (10 Hz)
##
## MONEY COUNT TWEEN (Story 002 / TR-HUD-004, GDD Core Rule 3):
##   - On balance_changed(new, delta): tween the DISPLAYED number from its
##     current value -> new over ~0.25s (data-driven knob "money_count_duration",
##     GDD safe range 0.2-0.5s), TRANS_QUAD EASE_OUT throughout (calm "Butter"
##     motion — never a red flash; the easing is monotonic so the count never
##     overshoots past the target).
##   - Re-target mid-tween (rapid changes, e.g. multiple departures one tick):
##     the in-flight tween is killed and a NEW one starts from the CURRENT
##     displayed value toward the LATEST target — no queue backlog (Edge
##     Cases). The count visually continues from where it was, not from the
##     stale target.
##   - Render-time, independent of sim ticks: the tween is a plain
##     create_tween() bound to the SceneTree. TimeSystem pause is a SIM flag,
##     NOT SceneTree.paused — so a sell refund during pause still animates
##     (Edge Cases; render-time state, not tick-gated).
##   - Spend acknowledgment (Pillar 2 absolute — never red): on delta < 0 the
##     Butter coin icon is set to a DESATURATED Butter synchronously
##     (hue-preserving lerp toward gray — the "brief desaturation" half), then
##     a settle tween restores full Butter over the same duration. The number
##     never changes color; nothing ever reads red.
##   - Reduced-motion: snap to the final value, no tween, no desaturation
##     (UX spec: "snap under reduced-motion"). Data-driven "reduced_motion".
##
## SATISFACTION METER (Story 003) — calm, never an alarm (TR-HUD-002/003):
##   - Short horizontal ProgressBar (NOT a "health bar" metaphor — 8px tall,
##     rounded fill, calm colors). Fill ramps:
##       sat >= 0.66                 -> Sage (#8FBF9F, art bible)
##       0.33 <= sat < 0.66          -> warm neutral -> Sage lerp
##       sat < 0.33                  -> Dusty Rose (#E0A0A0) -> warm neutral lerp
##     Every ramp color is muted (saturation < 0.4) — never saturated red.
##   - Colorblind-safe: the % label ALWAYS shows the value, and the face icon
##     SHAPE carries state (filled = sat >= 0.33, outline = sat < 0.33) — the
##     glyphs are :) (high), :| (mid), :( (very low) (monochrome ASCII —
##     PHASED-F: macOS 彩色 emoji 忽略 font_color，见 ICON_HIGH 注释)。
##   - Ease: global_satisfaction change -> tween_method drives meter.value +
##     % label + icon + fill color from the current displayed value to the new
##     target over `satisfaction_ease_duration` (GDD knob 1.0 s, safe range
##     0.5–1.5 s). Re-targets mid-tween (kill + new tween from the current
##     displayed value) — no queue backlog. A tick that re-reads the SAME
##     target does NOT restart the tween (10 Hz cadence no-op).
##   - Reduced-motion (`config["reduced_motion"]` or the OS accessibility
##     setting when available): STATIC fill — value, % and icon snap, no tween.
##   - Load path (refresh_all / init) always SNAPS (AC8 — loaded values render
##     immediately, no stale pre-load values); only live tick changes ease.
##
## TICKS_PER_DAY is NOT defined by TimeSystem (HUD GDD OQ1 — a game-designer
## decision). Data-driven provisional default 1800 (~3 real minutes at 1×,
## 10 ticks/s); config override key "ticks_per_day".
##
## READ-ONLY DISCIPLINE (Core Rule 5 / TR-HUD-006): no popups, toasts, or
## badges anywhere in this tree. The HUD never mutates sim state EXCEPT the
## transport forward (Story 004): Space/1/2/3 and the transport buttons call
## TimeSystem.pause()/resume()/set_speed() — the only simulation mutation the
## HUD makes.
##
## 4.7.1 NOTES: class_name immediately follows extends; typed fields use the
## project's global class cache (headless-safe — cache is committed);
## locals reading system state use explicit `: Type` (never `:=` on Variant).
## Tween: 4.7.1 has NO `loops` property and NO `get_total_duration()`; the
## meter tween is created with the default loop count (plays once — no pulse)
## and the configured duration is tracked on the HUD for tests. `custom_step()`
## does not advance a scene-tree-bound running tween, so headless tests verify
## the tween's target/duration via getters and drive the display callback
## directly (see satisfaction_meter_test.gd).
## dual-focus (4.6+): hotkeys arrive via _unhandled_key_input (focus-independent);
## transport Buttons use focus_mode = FOCUS_NONE so a focused Button never
## swallows Space/1/2/3 (a focused Button consumes ui_accept — Space would
## activate the button instead of reaching the hotkey handler).
class_name Hud extends Control

## Phase D v2 现代 UI 皮肤（art-bible-25d-style §1/§2）—— 深色半透明面板 +
## 亮色 Butter 描边 + 粗字体 + 描边填充式图标。面板背景在 _draw() 里用
## draw_style_box 绘制（不新增子节点 —— hud_layout_test 固定 HUD root
## child-count == 1 / MoneyGroup == 2 children，技能 pitfall 已验证）。
const UiTheme := preload("res://src/ui/ui_theme.gd")

## Data-driven config seams (coding standard: gameplay values never hardcoded).
const CONFIG_TICKS_PER_DAY := "ticks_per_day"
const CONFIG_UI_SCALE := "ui_scale"
const CONFIG_MONEY_COUNT_DURATION := "money_count_duration"
const CONFIG_SATISFACTION_EASE_DURATION := "satisfaction_ease_duration"
const CONFIG_REDUCED_MOTION := "reduced_motion"

## Provisional day length (HUD GDD OQ1 — game-designer owns the final value).
const DEFAULT_TICKS_PER_DAY := 1800

## UI scale (UX spec: 0.8×–1.5× integer multipliers; 1.0 = art-bible anchor).
const DEFAULT_UI_SCALE := 1.0

## Money count tween duration (GDD Core Rule 3 / TR-HUD-004): ~0.25s default
## (Phase D v2 动效带 120-250ms —— 取上限 250ms，EASE_OUT 仍从容不迫；
## GDD 安全区间 0.2–0.5s 保持不变）。Data-driven via config
## config["money_count_duration"], clamped to the GDD safe range.
const DEFAULT_MONEY_COUNT_DURATION := 0.25
const MONEY_COUNT_DURATION_MIN := 0.2
const MONEY_COUNT_DURATION_MAX := 0.5

## Reduced-motion: snap to the final value, no tween, no desaturation (UX
## spec "snap under reduced-motion"). Data-driven via config["reduced_motion"];
## default OFF until the global reduced-motion setting (accessibility #22)
## lands — the config seam is where that setting will write.
const DEFAULT_REDUCED_MOTION := false

## How far the Butter coin desaturates on spend (0..1; 1 = full gray). 0.35 is
## a visible-but-calm "brief desaturation" — Pillar 2: acknowledgment, never a
## red flash. Hue is preserved by the lerp-toward-gray (see spend_ack_color()).
const SPEND_DESATURATE_AMOUNT := 0.35

## Tween easing for the money count (GDD "in Butter throughout"): a calm
## ease-out that decelerates into the target. TRANS_QUAD/EASE_OUT is monotonic
## — the count never overshoots past the target (a count that briefly showed
## MORE money than the player has would read as a bug; EASE_OUT guarantees
## from <= displayed <= to along the whole curve).
const MONEY_TWEEN_TRANS := Tween.TRANS_QUAD
const MONEY_TWEEN_EASE := Tween.EASE_OUT

## Satisfaction ease duration (GDD tuning knob: default 1.0 s, safe range
## 0.5–1.5 s — reinforces "this moves slowly, don't panic").
const DEFAULT_SATISFACTION_EASE_DURATION := 1.0
const SATISFACTION_EASE_MIN := 0.5
const SATISFACTION_EASE_MAX := 1.5

## Ramp zone thresholds on the [0,1] satisfaction scale (Story 003).
## sat >= HIGH_ZONE -> Sage; MID_ZONE..HIGH_ZONE -> warm-neutral->Sage lerp;
## < MID_ZONE -> Dusty-Rose->warm-neutral lerp (Dusty Rose only at the very
## low end — Pillar 2 absolute: never saturated red).
const SAT_HIGH_ZONE := 0.66
const SAT_MID_ZONE := 0.33

## Meter palette (Story 003 ramp anchors; art-bible palette throughout).
const COLOR_SAGE := Color("8fbf9f")
const COLOR_WARM_NEUTRAL := Color("c9a87c")   ## warm sand — the "mid" anchor
const COLOR_DUSTY_ROSE := Color("e0a0a0")     ## art-bible Dusty Rose (muted)

## Face icon glyphs — SHAPE carries state (colorblind-safe, TR-HUD-003).
## PHASED-F 修复（qa t_3f33ed6e attempt 3 复验）：macOS 彩色 emoji
## （☺/🙂/☹）忽略 font_color、以系统 emoji 固有颜色渲染，语义色通道失效。
## 改为受 font_color 控制的 ASCII 单色表情（:)/:|/:( —— 纯文本呈现，
## 渲染颜色 = font_color = Sage，色盲双通道恢复；字形仍有表情形状差异）。
const ICON_HIGH := ":)"      ## filled, high satisfaction
const ICON_MID := ":|"       ## filled, mid satisfaction
const ICON_LOW := ":("       ## outline, very low satisfaction
const SHAPE_FILLED := "filled"
const SHAPE_OUTLINE := "outline"

## Layout anchors (art-bible / UX spec): text ≥ 16px @1080p; safe margin
## ≥ 16px from screen edges at 1.0× UI scale, scaled with UI scale; top bar
## ≤ ~8% of vertical screen height at 1080p (48px + 16px margin = 64px strip).
const SAFE_MARGIN_PX := 16
const TOP_BAR_HEIGHT_PX := 48
const MIN_FONT_SIZE_PX := 16
const METER_WIDTH_PX := 80
const METER_HEIGHT_PX := 8
const METER_CORNER_RADIUS_PX := 2  ## rounded fill — reads as a gauge, not a bar

## Art-bible palette (design/art/art-bible.md §4).
const COLOR_BUTTER := Color("f5d97b")
const COLOR_CHARCOAL := Color("3c3a42")
const COLOR_SKY := Color("8ec5e8")

## Phase D v2: 深色面板上的浅色正文（Warm Cream 系，art-bible §4 单一色源
## CREAM_BG #F4E9D8）。深色半透明面板 + 浅色文字保证可读（Exit 条件 1/3）。
const COLOR_TEXT_LIGHT := Color("f4e9d8")

# === Phase D v2 面板状态（_draw() 绘制，不新增子节点） ===
## 顶栏面板 stylebox：深色半透明 + Butter 亮色描边（UiTheme.make_panel_style）。
var _panel_style: StyleBoxFlat = null
## 面板淡入 alpha（0→PANEL_ALPHA，ANIM_PANEL_FADE）。_draw() 每帧读取；
## 测试断言结构/颜色，不读本字段。
var _panel_alpha: float = UiTheme.PANEL_ALPHA
## 金钱图标脉冲 tween（余额变化时 offset_transform_scale 1→1.15→1，
## ANIM_ICON_PULSE）。与 _money_tween/_ack_tween 相互独立。
var _pulse_tween: Tween = null

## Transport cluster (UX spec §4): four small buttons ‖ (pause), 1×, 2×, 3×.
const PAUSE_BUTTON_LABEL := "‖"
const SPEED_BUTTON_LABELS: Array[String] = ["1×", "2×", "3×"]
## Active-cue prefix: filled-dot icon. Paired with the outline stylebox so
## the active button reads via icon+shape — NEVER color alone (colorblind-safe,
## UX spec §4 / GDD Core Rule 4).
const ACTIVE_DOT := "• "
## Sun/clock-position icon for time-of-day (GDD Core Rule 4 / UX spec §3):
## a 12-hour clock face whose position reflects the [0,1) day fraction.
## Icon/shape carries the state — never color alone.
## PHASED-F 注意：这些是彩色 emoji 码点 —— macOS 上 Label 渲染会忽略
## font_color、以系统 emoji 固有颜色绘制（语义色通道失效，qa 复验确认）。
## 实时标签改走 format_time_of_day() 的 HH:MM 文本（单色、受 font_color
## 控制 = Sky）；本数组保留为 12 时钟位形通道的文档化映射，禁止直接渲染。
const TIME_OF_DAY_ICONS: Array[String] = [
	"🕛", "🕐", "🕑", "🕒", "🕓", "🕔",
	"🕕", "🕖", "🕗", "🕘", "🕙", "🕚",
]

# === Injected systems (composition root wires these via init()) ===
var _economy: Economy
var _satisfaction: Satisfaction
var _time_system: TimeSystem
var _orchestrator: SimulationOrchestrator

# === Configuration ===
var _ticks_per_day: int = DEFAULT_TICKS_PER_DAY
var _ui_scale: float = DEFAULT_UI_SCALE
var _satisfaction_ease_duration: float = DEFAULT_SATISFACTION_EASE_DURATION

# === Derived display state (testable surface) ===
var _displayed_day: int = 1
var _time_of_day: float = 0.0

# === Money count tween state (Story 002) ===
## The value the money label is CURRENTLY showing (mid-tween = the animated
## value). float so the tween can interpolate smoothly; label rounds to int.
var _displayed_balance: float = 0.0
## Target of the current/last money tween — the latest balance_changed value.
## Tests assert re-target lands on the latest value (no queue backlog).
var _money_tween_target: int = 0
## The in-flight count tween (null when none). Killed on every re-target.
var _money_tween: Tween = null
## The spend-ack settle tween (restores Butter after the desaturation half).
var _ack_tween: Tween = null
## Data-driven count duration (GDD knob, clamped to safe range).
var _money_count_duration: float = DEFAULT_MONEY_COUNT_DURATION
## Data-driven reduced-motion flag: true = snap, no tween.
var _reduced_motion: bool = DEFAULT_REDUCED_MOTION

# === Story 003 meter animation state ===
## The [0,1] satisfaction value currently rendered (during an ease this lags
## the target; after completion it equals the target). Drives the meter fill,
## % label, icon glyph and fill color in lockstep via _apply_satisfaction_display.
var _displayed_satisfaction: float = 0.0
## The fill fraction (0..100) the active ease is heading toward — the HUD's
## own record of the tween target (4.7.1 Tween exposes no target getter).
var _meter_tween_target: float = 0.0
## The active meter ease (null when static: reduced-motion, load snap, or idle).
var _meter_tween: Tween = null
## StyleBoxFlat overriding the ProgressBar "fill" — recolored per ramp value
## so the meter fill itself carries the calm Sage->neutral->Dusty Rose ramp.
var _meter_fill_style: StyleBoxFlat = null

# === Child Controls (built in _init(), named for tests + Story 004) ===
var _top_bar: HBoxContainer
var _money_group: HBoxContainer
var _coin_icon: Label
var _money_label: Label
var _left_spacer: Control
var _satisfaction_group: HBoxContainer
var _face_icon: Label
var _meter: ProgressBar
var _satisfaction_label: Label
var _right_spacer: Control
var _time_group: HBoxContainer
var _day_label: Label
var _time_of_day_label: Label
var _transport_cluster: HBoxContainer
var _pause_button: Button
var _speed_buttons: Array[Button] = []

## Cached outline stylebox for the active transport button (created lazily).
var _active_stylebox: StyleBoxFlat = null

var _initialized: bool = false


## Engine constructor: builds the default (1.0×) layout immediately so the
## tree exists headless right after new(). init() rebuilds after applying a
## data-driven ui_scale config (see _build_ui).
func _init() -> void:
	_build_ui()


## Builds the full Control tree (headless-safe — the tree exists immediately
## and no _ready() dependency). Called from _init() with the default 1.0×
## scale AND again from init() after _apply_config() so a data-driven
## ui_scale override re-lays-out the bar at the configured size. Rebuilding
## is cheap (a dozen nodes) and keeps the layout deterministic. The HUD root
## is full-rect and input-transparent so it never blocks the play area; only
## Story 004's buttons will opt back into input.
func _build_ui() -> void:
	for child in get_children():
		remove_child(child)
		child.queue_free()
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_anchors_preset(Control.PRESET_FULL_RECT)
	name = "Hud"

	_top_bar = HBoxContainer.new()
	_top_bar.name = "TopBar"
	_top_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_top_bar.anchor_left = 0.0
	_top_bar.anchor_right = 1.0
	_top_bar.anchor_top = 0.0
	_top_bar.anchor_bottom = 0.0
	_top_bar.offset_left = _scaled(SAFE_MARGIN_PX)
	_top_bar.offset_right = -_scaled(SAFE_MARGIN_PX)
	_top_bar.offset_top = 0
	_top_bar.offset_bottom = _scaled(TOP_BAR_HEIGHT_PX)
	add_child(_top_bar)

	_money_group = _make_group("MoneyGroup")
	_top_bar.add_child(_money_group)

	_coin_icon = _make_label("CoinIcon", "●", COLOR_BUTTER, UiTheme.FONT_TITLE)
	# Phase D v2: 描边填充式图标（art-bible §7）—— 金钱→Butter，亮色描边。
	# PHASED-F: 字形从彩色 emoji 🪙 改为单色 ●（U+25CF，文本呈现，渲染颜色
	# = font_color = Butter；macOS 彩色 emoji 忽略 font_color，qa 复验确认）。
	UiTheme.apply_outlined_fill(_coin_icon, COLOR_BUTTER, COLOR_BUTTER, 1)
	_money_group.add_child(_coin_icon)
	# Phase D v2: 金钱数字 = 标题级（最大数字）+ 浅 Cream 正文，深色面板可读。
	_money_label = _make_label("MoneyLabel", "$0", COLOR_TEXT_LIGHT, UiTheme.FONT_TITLE)
	_money_group.add_child(_money_label)

	_left_spacer = _make_spacer("LeftSpacer")
	_top_bar.add_child(_left_spacer)

	_satisfaction_group = _make_group("SatisfactionGroup")
	_top_bar.add_child(_satisfaction_group)

	# Phase D v2: 满意度图标 → Sage 语义色 + 描边（satisfaction→Sage）。
	# PHASED-F: 字形为单色 ASCII 表情（:)/:|/:(，受 font_color 控制 = Sage）。
	_face_icon = _make_label("FaceIcon", ICON_MID, UiTheme.icon_satisfaction(), UiTheme.FONT_BODY)
	UiTheme.apply_outlined_fill(_face_icon, UiTheme.icon_satisfaction(), UiTheme.icon_satisfaction(), 1)
	_satisfaction_group.add_child(_face_icon)
	_meter = ProgressBar.new()
	_meter.name = "Meter"
	_meter.min_value = 0.0
	_meter.max_value = 100.0
	_meter.value = 0.0
	_meter.show_percentage = false
	_meter.mouse_filter = Control.MOUSE_FILTER_IGNORE  # display-only in Story 001
	_meter.custom_minimum_size = Vector2(_scaled(METER_WIDTH_PX), _scaled(METER_HEIGHT_PX))
	_meter.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	# Story 003: rounded fill stylebox — the calm gauge fill. Recolored per ramp
	# value in _apply_satisfaction_display (Sage high -> warm neutral mid ->
	# muted Dusty Rose very low end; never saturated red — TR-HUD-002).
	_meter_fill_style = StyleBoxFlat.new()
	_meter_fill_style.bg_color = satisfaction_fill_color(0.5)
	_meter_fill_style.set_corner_radius_all(_scaled(METER_CORNER_RADIUS_PX))
	_meter.add_theme_stylebox_override("fill", _meter_fill_style)
	# Phase D v2: 轨道（background）深色半透明，配合深色面板（fill 的 ramp
	# 颜色不变 —— satisfaction_meter_test 固定 fill 样式）。
	var meter_bg := StyleBoxFlat.new()
	meter_bg.bg_color = Color(0.0, 0.0, 0.0, 0.28)
	meter_bg.set_corner_radius_all(_scaled(METER_CORNER_RADIUS_PX))
	_meter.add_theme_stylebox_override("background", meter_bg)
	_satisfaction_group.add_child(_meter)
	_satisfaction_label = _make_label("SatisfactionLabel", "0%", COLOR_TEXT_LIGHT, UiTheme.FONT_BODY)
	_satisfaction_group.add_child(_satisfaction_label)

	_right_spacer = _make_spacer("RightSpacer")
	_top_bar.add_child(_right_spacer)

	_time_group = _make_group("TimeGroup")
	_top_bar.add_child(_time_group)

	_day_label = _make_label("DayLabel", "Day 1", COLOR_TEXT_LIGHT, UiTheme.FONT_BODY)
	_time_group.add_child(_day_label)
	# Phase D v2: 时间图标 → Sky 语义色 + 描边（time→Sky，保持 art-bible 原色）。
	# PHASED-F: 实时显示 HH:MM 文本（format_time_of_day，单色、受 font_color
	# 控制 = Sky；macOS 彩色时钟 emoji 忽略 font_color，见 time_of_day_icon）。
	_time_of_day_label = _make_label("TimeOfDayLabel", "00:00", COLOR_SKY, UiTheme.FONT_BODY)
	UiTheme.apply_outlined_fill(_time_of_day_label, COLOR_SKY, COLOR_SKY, 1)
	_time_group.add_child(_time_of_day_label)

	_transport_cluster = HBoxContainer.new()
	_transport_cluster.name = "TransportCluster"
	_transport_cluster.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_transport_cluster.add_theme_constant_override("separation", _scaled(6))
	_time_group.add_child(_transport_cluster)
	_pause_button = _make_transport_button("PauseButton", PAUSE_BUTTON_LABEL)
	_pause_button.pressed.connect(_on_pause_button_pressed)
	_transport_cluster.add_child(_pause_button)
	_speed_buttons.clear()
	for i in SPEED_BUTTON_LABELS.size():
		var btn := _make_transport_button("SpeedButton%d" % (i + 1), SPEED_BUTTON_LABELS[i])
		btn.pressed.connect(_on_speed_button_pressed.bind(i + 1))
		_speed_buttons.append(btn)
		_transport_cluster.add_child(btn)

	# Phase D v2: 顶栏深色半透明面板（_draw() 绘制；UiTheme 单一来源）。
	_panel_style = UiTheme.make_panel_style(UiTheme.panel_border(), 10, 2)
	queue_redraw()


## Phase D v2: 顶栏面板背景 —— 深色半透明 + Butter 亮色描边。在 HUD root
## 的 _draw() 里绘制（不新增子节点：hud_layout_test 固定 root child-count
## == 1 / TopBar 结构）。面板紧贴顶栏条带，四边留 2px 呼吸边距；描边颜色
## 与圆角来自 UiTheme（单一来源）。_panel_alpha 由面板淡入动效驱动。
func _draw() -> void:
	if _panel_style == null:
		return
	var margin := _scaled(SAFE_MARGIN_PX)
	var strip_rect := Rect2(
		margin - _scaled(4),
		_scaled(2),
		size.x - (margin - _scaled(4)) * 2.0,
		_scaled(TOP_BAR_HEIGHT_PX) + _scaled(4)
	)
	_panel_style.bg_color.a = _panel_alpha
	draw_style_box(_panel_style, strip_rect)


## Two-phase init (ADR-0001 for UI Nodes): stores the injected systems,
## applies the data-driven config, subscribes to the balance_changed signal
## (S6) and — when an orchestrator is supplied — the tick_completed signal
## (S2, the 10 Hz refresh cadence), then renders the CURRENT state
## immediately (AC8: paused state + loaded values, no stale pre-load values).
## Safe to call once; a second call pushes an error and is ignored.
func init(
	economy: Economy,
	satisfaction: Satisfaction,
	time_system: TimeSystem,
	orchestrator: SimulationOrchestrator = null,
	config: Dictionary = {}
) -> void:
	if _initialized:
		push_error("Hud.init() called twice.")
		return
	_initialized = true
	_economy = economy
	_satisfaction = satisfaction
	_time_system = time_system
	_orchestrator = orchestrator
	_apply_config(config)
	_build_ui()  # re-layout at the configured ui_scale (rebuild frees old children)
	_economy.balance_changed.connect(_on_balance_changed)
	if _orchestrator != null:
		_orchestrator.tick_completed.connect(_on_tick_completed)
	refresh_all()
	# Phase D v2: 面板淡入（120-250ms 柔和过渡，Exit 条件 3）。reduced-motion
	# 下 _panel_alpha 保持 PANEL_ALPHA（无动画，见 _start_panel_fade）。
	_start_panel_fade()


## Reads [config] into the tuning fields. Missing keys keep the GDD anchors.
## money_count_duration is clamped to the GDD safe range (0.2–0.5s) so a bad
## config value can never produce a snap-fast or laggy count.
func _apply_config(config: Dictionary) -> void:
	if config.has(CONFIG_TICKS_PER_DAY):
		_ticks_per_day = int(config[CONFIG_TICKS_PER_DAY])
	if _ticks_per_day <= 0:
		_ticks_per_day = DEFAULT_TICKS_PER_DAY
	if config.has(CONFIG_UI_SCALE):
		_ui_scale = float(config[CONFIG_UI_SCALE])
	if _ui_scale <= 0.0:
		_ui_scale = DEFAULT_UI_SCALE
	if config.has(CONFIG_MONEY_COUNT_DURATION):
		_money_count_duration = clampf(
			float(config[CONFIG_MONEY_COUNT_DURATION]),
			MONEY_COUNT_DURATION_MIN,
			MONEY_COUNT_DURATION_MAX
		)
	if config.has(CONFIG_SATISFACTION_EASE_DURATION):
		_satisfaction_ease_duration = clampf(
			float(config[CONFIG_SATISFACTION_EASE_DURATION]),
			SATISFACTION_EASE_MIN,
			SATISFACTION_EASE_MAX
		)
	if config.has(CONFIG_REDUCED_MOTION):
		_reduced_motion = bool(config[CONFIG_REDUCED_MOTION])
	else:
		_reduced_motion = _detect_reduced_motion()


## Event-driven refresh on balance mutation (S6). Money is the ONLY label
## driven by a signal — it can change on any tick (income) or between ticks
## (spend/credit), so it must never wait for the next tick_completed.
##
## Story 002 (TR-HUD-004): the count tween. The displayed number animates
## current -> new over _money_count_duration (~0.25s), TRANS_QUAD EASE_OUT
## throughout. Re-targets mid-tween on rapid changes (kill + restart from the
## CURRENT displayed value toward the LATEST target — no queue backlog).
## delta < 0 (spend) triggers the desaturation acknowledgment — NEVER red.
## Reduced-motion snaps directly (no tween, no desaturation).
func _on_balance_changed(new_balance: int, delta: int) -> void:
	if not _initialized:
		return
	_money_tween_target = new_balance
	if _reduced_motion:
		_snap_money(new_balance)
		return
	_start_money_tween(new_balance)
	if delta < 0:
		_acknowledge_spend()
	# Phase D v2: 图标脉冲 —— 余额变化时金钱图标轻微放大回弹（120-250ms，
	# Exit 条件 3）。reduced-motion 下跳过。
	_pulse_coin_icon()


## Phase D v2: 金钱图标脉冲 —— offset_transform_scale 1 → 1.15 → 1，
## 总时长 ANIM_ICON_PULSE（200ms，120-250ms 区间内）。用 4.7 的
## offset_transform_scale（不被容器布局重置，技能 pitfall 已验证），
## 与金钱计数 tween / spend-ack tween 相互独立（不同属性、不同 tween）。
## reduced-motion：跳过。
func _pulse_coin_icon() -> void:
	if _reduced_motion:
		return
	if _pulse_tween != null and _pulse_tween.is_valid():
		_pulse_tween.kill()
	_coin_icon.offset_transform_scale = Vector2.ONE
	var half := UiTheme.ANIM_ICON_PULSE * 0.5
	_pulse_tween = create_tween()
	_pulse_tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_pulse_tween.tween_property(
		_coin_icon, "offset_transform_scale", Vector2(1.15, 1.15), half
	)
	_pulse_tween.tween_property(
		_coin_icon, "offset_transform_scale", Vector2.ONE, half
	)


## Phase D v2: 顶栏面板淡入 —— _panel_alpha 从 0 缓入到 PANEL_ALPHA，
## 时长 ANIM_PANEL_FADE（180ms）。_draw() 每帧读取 alpha 绘制面板。
## reduced-motion：保持 PANEL_ALPHA（无动画）。
func _start_panel_fade() -> void:
	if _reduced_motion:
		_panel_alpha = UiTheme.PANEL_ALPHA
		queue_redraw()
		return
	_panel_alpha = 0.0
	var fade := create_tween()
	fade.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	fade.tween_method(_set_panel_alpha, 0.0, UiTheme.PANEL_ALPHA, UiTheme.ANIM_PANEL_FADE)


## Panel fade tween callback：写 _panel_alpha 并请求重绘（_draw 读取）。
func _set_panel_alpha(value: float) -> void:
	_panel_alpha = value
	queue_redraw()


## Starts a fresh count tween from the CURRENT displayed value toward [target].
## The in-flight tween (if any) is killed FIRST — this is the re-target
## contract: rapid balance changes (multiple departures one tick) cancel the
## old tween and re-anchor at the latest value, with zero queue backlog (GDD
## Edge Cases). The new tween eases from _displayed_balance (the value the
## label currently shows, mid-tween = wherever the killed tween had reached),
## so the count visibly continues from where it was — never snaps back.
## NOTE: create_tween() works on any Node in 4.7.1 (probe-verified even for
## nodes never added to a tree), so no in-tree guard is needed — the tween
## exists and reports is_running() == true immediately, which is what the
## headless re-target assertions rely on.
func _start_money_tween(target: int) -> void:
	_kill_money_tween()
	var from: float = _displayed_balance
	_money_tween = create_tween()
	_money_tween.set_trans(MONEY_TWEEN_TRANS)
	_money_tween.set_ease(MONEY_TWEEN_EASE)
	_money_tween.tween_method(_apply_money_display, from, float(target), _money_count_duration)


## Tween callback: writes the interpolated value into _displayed_balance and
## re-renders the label. roundi() keeps the display in whole currency units
## (GDD Core Rule 1 — int balance) while the underlying float interpolates
## smoothly. format_money() applies thousands separators, so a mid-count value
## like 1,234.7 renders as "$1,235" with no separator/icon collision (the coin
## icon is a separate Label).
func _apply_money_display(value: float) -> void:
	_displayed_balance = value
	_money_label.text = format_money(roundi(value))


## Spend acknowledgment (Pillar 2 absolute — NEVER a red flash, GDD Core
## Rule 3 / TR-HUD-004): the Butter coin icon desaturates briefly then
## settles back. Desaturation is a hue-preserving lerp toward gray
## (spend_ack_color()) — the coin reads as muted Butter, never red. The money
## NUMBER label never changes color on spend. Under reduced-motion the whole
## acknowledgment is skipped (snap only).
func _acknowledge_spend() -> void:
	if _ack_tween != null and _ack_tween.is_valid():
		_ack_tween.kill()
	_coin_icon.add_theme_color_override("font_color", spend_ack_color())
	_ack_tween = create_tween()
	_ack_tween.set_trans(MONEY_TWEEN_TRANS)
	_ack_tween.set_ease(MONEY_TWEEN_EASE)
	_ack_tween.tween_property(_coin_icon, "theme_override_colors/font_color", COLOR_BUTTER, _money_count_duration)


## Snaps the money display to [balance] with NO tween and NO desaturation
## (reduced-motion path). Kills any in-flight tween so a reduced-motion toggle
## mid-count cannot leave a stale tween animating toward an old target.
func _snap_money(balance: int) -> void:
	_kill_money_tween()
	if _ack_tween != null and _ack_tween.is_valid():
		_ack_tween.kill()
	_displayed_balance = float(balance)
	_money_label.text = format_money(balance)
	_coin_icon.add_theme_color_override("font_color", COLOR_BUTTER)


## Kills the in-flight money tween, if any (safe to call when none exists).
## The re-target contract depends on this being idempotent.
func _kill_money_tween() -> void:
	if _money_tween != null and _money_tween.is_valid():
		_money_tween.kill()
	_money_tween = null


## Tick refresh hook (S2 — 10 Hz cadence). Satisfaction folds on member
## departures during ticks and day/time advances with tick_count, so both
## re-read here. Money does NOT re-read here — balance_changed is its only
## source of truth (ADR-0005 S6).
func _on_tick_completed(_tick_count: int) -> void:
	if not _initialized:
		return
	_refresh_satisfaction()
	_refresh_time()


## Renders the ENTIRE current state — money, satisfaction, day/time,
## transport — by direct read. Called by init() so a freshly-loaded game
## shows its loaded values on the first frame with no stale pre-load values
## (AC8). Also callable by the composition root after a load. Money snaps to
## the loaded balance (no tween — a load is not an animation; Story 002's
## tween only fires on balance_changed). The satisfaction portion SNAPS (load
## path — no ease); only live tick changes ease (Story 003).
func refresh_all() -> void:
	if not _initialized:
		return
	var balance: int = _economy.balance
	_displayed_balance = float(balance)
	_money_tween_target = balance
	_kill_money_tween()
	if _ack_tween != null and _ack_tween.is_valid():
		_ack_tween.kill()
	_money_label.text = format_money(balance)
	_coin_icon.add_theme_color_override("font_color", COLOR_BUTTER)
	_snap_satisfaction()
	_refresh_time()


## Load-path satisfaction render: read global_satisfaction (a plain var — no
## signal exists) and apply it IMMEDIATELY — meter fill, % label, icon shape
## and fill color all snap to the loaded value (AC8: no stale pre-load values,
## no ease on load). Kills any in-flight tween so a refresh_all during an
## ease settles at the loaded value.
func _snap_satisfaction() -> void:
	if not _initialized:
		return
	var sat: float = clampf(float(_satisfaction.global_satisfaction), 0.0, 1.0)
	_kill_meter_tween()
	_meter_tween_target = sat * 100.0
	_apply_satisfaction_display(sat)


## Tick-path satisfaction render (S2, 10 Hz cadence). On a target change the
## meter EASES to the new fill over `_satisfaction_ease_duration` (~1 s),
## with the % label + icon + fill color driven in lockstep by the tween.
## Re-targets mid-tween (kill + new tween from the CURRENT displayed value —
## no queue backlog, GDD Edge Cases). A tick that re-reads the SAME target is
## a no-op (does NOT restart the tween). Reduced-motion: static fill (no ease).
func _refresh_satisfaction() -> void:
	if not _initialized:
		return
	var sat: float = clampf(float(_satisfaction.global_satisfaction), 0.0, 1.0)
	var target: float = sat * 100.0
	if _reduced_motion:
		_snap_satisfaction()
		return
	# 10 Hz no-op: same target already applied or already being eased to.
	if is_equal_approx(target, _meter_tween_target):
		return
	_kill_meter_tween()
	_meter_tween_target = target
	_meter_tween = create_tween()
	_meter_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_meter_tween.tween_method(
		_apply_satisfaction_display,
		_displayed_satisfaction,
		sat,
		_satisfaction_ease_duration
	)


## Single choke point for rendering ONE satisfaction value: meter fill (0..100),
## % label, face icon shape, and fill color all derive from [value] ∈ [0,1].
## The meter tween calls this every step, so the icon + % update WITH the fill
## (AC3) and no element can drift from the others. Also called by the snap path.
func _apply_satisfaction_display(value: float) -> void:
	var v: float = clampf(value, 0.0, 1.0)
	_displayed_satisfaction = v
	_meter.value = v * 100.0
	_satisfaction_label.text = "%d%%" % roundi(v * 100.0)
	_face_icon.text = satisfaction_icon(v)
	_meter_fill_style.bg_color = satisfaction_fill_color(v)


## Kills and clears the active meter tween, if any.
func _kill_meter_tween() -> void:
	if _meter_tween != null and _meter_tween.is_valid():
		_meter_tween.kill()
	_meter_tween = null


## Reduced-motion detection: the OS accessibility preference when the engine
## exposes it (4.7.1: DisplayServer.accessibility_should_reduce_animation(),
## 1 = yes), else false. Config `reduced_motion` overrides this in _apply_config.
func _detect_reduced_motion() -> bool:
	if not DisplayServer.has_method("accessibility_should_reduce_animation"):
		return false
	return int(DisplayServer.accessibility_should_reduce_animation()) == 1


## Reads tick_count and derives day + time_of_day (GDD Formulas), then
## re-binds the transport cluster active cues from TimeSystem state
## (is_paused() / get_speed_multiplier() — buttons read state, never track it).
func _refresh_time() -> void:
	var tick_count: int = _time_system.get_tick_count()
	_displayed_day = derive_day(tick_count, _ticks_per_day)
	_time_of_day = derive_time_of_day(tick_count, _ticks_per_day)
	_day_label.text = "Day %d" % _displayed_day
	# PHASED-F: HH:MM 文本（format_time_of_day）—— 单色字形受 font_color
	# 控制（= Sky）；彩色时钟 emoji 在 macOS 忽略 font_color，见 time_of_day_icon。
	_time_of_day_label.text = format_time_of_day(_time_of_day)
	_refresh_transport()


## Re-derives the transport cluster active cues from TimeSystem state (the
## single source of truth — the HUD never tracks pause/speed itself, GDD
## States table: "button reflects new state" after every forward). Exactly
## one speed button is active when running; none when paused; the pause
## button is active when paused (AC1/AC5). The cue is outline + filled-dot
## icon — never color alone.
func _refresh_transport() -> void:
	var paused: bool = _time_system.is_paused()
	var speed: int = _time_system.get_speed_multiplier()
	_set_button_active(_pause_button, PAUSE_BUTTON_LABEL, paused)
	for i in _speed_buttons.size():
		var active: bool = (not paused) and speed == i + 1
		_set_button_active(_speed_buttons[i], SPEED_BUTTON_LABELS[i], active)


## Applies/removes the active cue on one transport button: filled-dot text
## prefix + outline stylebox. Removing restores the plain label and the
## theme default — the cue is fully re-derived, so a stale cue can never
## survive a state change (deterministic, no flicker on same-speed no-op).
func _set_button_active(button: Button, base_label: String, active: bool) -> void:
	button.text = (ACTIVE_DOT + base_label) if active else base_label
	if active:
		button.add_theme_stylebox_override("normal", _get_active_stylebox())
	else:
		button.remove_theme_stylebox_override("normal")


# === Pure derivation functions (public + statically testable) ===

## The spend-acknowledgment color: Butter lerped toward neutral gray by
## SPEND_DESATURATE_AMOUNT. Lerping toward gray PRESERVES hue (probe-verified
## on 4.7.1: h stays 0.128 = yellow family, saturation drops) — so the coin
## reads as muted Butter during a spend, NEVER red (Pillar 2 absolute).
static func spend_ack_color() -> Color:
	return COLOR_BUTTER.lerp(Color(0.5, 0.5, 0.5), SPEND_DESATURATE_AMOUNT)

## GDD Formulas: day = 1 + floor(tick_count / TICKS_PER_DAY). day >= 1.
## Defensive: a non-positive ticks_per_day (bad config) yields day 1 rather
## than a division-by-zero crash. The config layer separately resets a bad
## value to DEFAULT_TICKS_PER_DAY; this guard is the pure-function safety net.
static func derive_day(tick_count: int, ticks_per_day: int) -> int:
	if ticks_per_day <= 0:
		return 1
	return 1 + floori(float(tick_count) / float(ticks_per_day))


## GDD Formulas: time_of_day = (tick_count mod TICKS_PER_DAY) / TICKS_PER_DAY
## -> [0, 1). Defensive: a non-positive ticks_per_day yields 0.0 (daybreak
## sentinel — same no-crash posture as derive_day). posmod keeps the modulo
## non-negative even for a corrupt negative tick_count.
static func derive_time_of_day(tick_count: int, ticks_per_day: int) -> float:
	if ticks_per_day <= 0:
		return 0.0
	return float(posmod(tick_count, ticks_per_day)) / float(ticks_per_day)


## Formats a whole-currency balance with thousands separators, "$" prefix.
## e.g. 0 -> "$0", 1240 -> "$1,240". Balance is never negative (Economy
## floor 0) but the formatter handles negatives defensively.
static func format_money(balance: int) -> String:
	var neg := balance < 0
	var digits := str(absi(balance))
	var out := ""
	var count := 0
	for i in range(digits.length() - 1, -1, -1):
		out = digits[i] + out
		count += 1
		if count % 3 == 0 and i > 0:
			out = "," + out
	return ("-$" if neg else "$") + out


## Formats the [0,1) day fraction as a 24h clock, e.g. 0.5 -> "12:00".
## PHASED-F: 这是 TimeOfDayLabel 的实时文本源（单色 ASCII，受 font_color
## 控制 = Sky）。Story-001 tests pin the mapping; Story 004 的 12 时钟位形
## 图标映射见 time_of_day_icon()（emoji 码点，禁止直接渲染 —— macOS 彩色
## emoji 忽略 font_color，qa 复验确认）。
static func format_time_of_day(time_of_day: float) -> String:
	var fraction: float = clampf(time_of_day, 0.0, 0.999999)
	var total_minutes: int = floori(fraction * 24.0 * 60.0)
	var hour: int = total_minutes / 60
	var minute: int = total_minutes % 60
	return "%02d:%02d" % [hour, minute]


# === Story 003: satisfaction meter pure derivation functions ===

## TR-HUD-002 fill ramp: Sage (high) -> warm neutral (mid) -> soft muted
## Dusty Rose ONLY at the very low end. Piecewise-linear between three anchors
## on the [0,1] satisfaction scale:
##   sat >= SAT_HIGH_ZONE (0.66)          -> Sage (#8FBF9F)
##   SAT_MID_ZONE..SAT_HIGH_ZONE (0.33-0.66) -> lerp(warm neutral -> Sage)
##   sat < SAT_MID_ZONE (0.33)            -> lerp(Dusty Rose -> warm neutral)
## Every ramp color is muted by construction (all three anchors have
## saturation < 0.4) — NEVER saturated red, NEVER reads as an alarm (Pillar 2
## absolute). Pure static — no state, no animation, no pulse.
static func satisfaction_fill_color(sat: float) -> Color:
	var s := clampf(sat, 0.0, 1.0)
	if s >= SAT_HIGH_ZONE:
		return COLOR_SAGE
	if s >= SAT_MID_ZONE:
		var t: float = (s - SAT_MID_ZONE) / (SAT_HIGH_ZONE - SAT_MID_ZONE)
		return COLOR_WARM_NEUTRAL.lerp(COLOR_SAGE, t)
	var t_low: float = s / SAT_MID_ZONE
	return COLOR_DUSTY_ROSE.lerp(COLOR_WARM_NEUTRAL, t_low)


## TR-HUD-003 face icon GLYPH: ":)" (high), ":|" (mid), ":(" (very low).
## Zone boundaries match the fill ramp so the icon changes exactly when the
## color ramp changes zone. Glyphs are monochrome ASCII (PHASED-F: macOS
## 彩色 emoji 忽略 font_color，语义色通道失效 —— 见 ICON_HIGH 注释)。
static func satisfaction_icon(sat: float) -> String:
	var s := clampf(sat, 0.0, 1.0)
	if s >= SAT_HIGH_ZONE:
		return ICON_HIGH
	if s >= SAT_MID_ZONE:
		return ICON_MID
	return ICON_LOW


## TR-HUD-003 icon SHAPE state: "filled" for sat >= SAT_MID_ZONE, "outline"
## below. This is the colorblind-safe channel — the state is readable from
## shape alone (a filled face vs an outline face), independent of the ramp
## color. The % label + the glyph carry the exact zone.
static func satisfaction_icon_shape(sat: float) -> String:
	var s := clampf(sat, 0.0, 1.0)
	return SHAPE_FILLED if s >= SAT_MID_ZONE else SHAPE_OUTLINE

## Sun/clock-position icon for time-of-day (GDD Core Rule 4 / UX spec §3):
## maps the [0,1) day fraction to a 12-hour clock face, e.g. 0.0 -> "🕛",
## 0.25 -> "🕕", 0.5 -> "🕛" (noon), 0.75 -> "🕕" (18:00). The icon SHAPE
## carries the time — never color alone (colorblind-safe). Defensive: a
## fraction outside [0,1) clamps to the nearest valid band.
## PHASED-F 注意：返回的是彩色 emoji 码点。实时标签**禁止**直接渲染本函数
## 结果 —— macOS 上 Label 渲染彩色 emoji 会忽略 font_color（语义色通道失效，
## qa t_3f33ed6e attempt 3 复验确认）；实时路径用 format_time_of_day() 的
## HH:MM 文本（单色、= Sky）。本函数保留为 12 时钟位形通道的文档化映射。
static func time_of_day_icon(time_of_day: float) -> String:
	var fraction: float = clampf(time_of_day, 0.0, 0.999999)
	var hour_24: int = floori(fraction * 24.0)
	var hour_12: int = hour_24 % 12
	return TIME_OF_DAY_ICONS[hour_12]


# === Node-building helpers ===

func _make_group(group_name: String) -> HBoxContainer:
	var group := HBoxContainer.new()
	group.name = group_name
	group.mouse_filter = Control.MOUSE_FILTER_IGNORE
	group.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	group.add_theme_constant_override("separation", _scaled(6))
	return group


func _make_spacer(spacer_name: String) -> Control:
	var spacer := Control.new()
	spacer.name = spacer_name
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return spacer


func _make_label(label_name: String, text: String, color: Color, font_size: int = UiTheme.FONT_BODY) -> Label:
	var label := Label.new()
	label.name = label_name
	label.text = text
	label.add_theme_font_override("font", UiTheme.bold_font())
	label.add_theme_font_size_override("font_size", _scaled(font_size))
	label.add_theme_color_override("font_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


## Builds one transport-cluster Button (Story 004). focus_mode = FOCUS_NONE
## is deliberate: under Godot 4.6+ dual-focus a focused Button consumes
## Space (ui_accept) and would never reach _unhandled_key_input — breaking
## "Space toggles pause regardless of focus". The hotkeys are the keyboard
## path; the buttons are the mouse path. MOUSE_FILTER_STOP opts the button
## back into mouse input (the rest of the HUD stays IGNORE — TR-HUD-006).
## Phase D v2: 主题级按钮皮肤（UiTheme.button_theme —— 深色半透明芯片 +
## 亮色细描边 + 粗字体 + 浅 Cream 文字）。主题级 stylebox 而非 override：
## 4.7.1 的 Control 无 add_theme_stylebox()，主题级走 Theme.set_stylebox +
## control.theme（probe 验证），has_theme_stylebox_override() 保持 false ——
## transport 测试「inactive 无 override」断言依赖此行为。
func _make_transport_button(button_name: String, label: String) -> Button:
	var btn := Button.new()
	btn.name = button_name
	btn.text = label
	btn.focus_mode = Control.FOCUS_NONE
	btn.mouse_filter = Control.MOUSE_FILTER_STOP
	btn.add_theme_font_size_override("font_size", _scaled(UiTheme.FONT_BODY))
	UiTheme.style_button(btn)
	return btn


## Lazily builds the shared active-cue stylebox: a Butter bright outline
## (never color alone — paired with the filled-dot text prefix in
## _set_button_active). Phase D v2: 亮色描边 = Butter（art-bible-25d §2
## 10% 锚点）；transport 测试只断言 border_width > 0，颜色换新皮安全。
func _get_active_stylebox() -> StyleBoxFlat:
	if _active_stylebox == null:
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(1.0, 1.0, 1.0, 0.0)
		sb.border_color = UiTheme.panel_border()
		sb.set_border_width_all(2)
		sb.set_corner_radius_all(3)
		_active_stylebox = sb
	return _active_stylebox


## Scales a design pixel value by the UI scale (UX spec: scales with the
## UI-scale setting; text stays >= 16px @1080p at 1.0×).
func _scaled(px: int) -> int:
	return maxi(roundi(float(px) * _ui_scale), 1)


# === Transport forwarding (Story 004 — the ONLY simulation mutation the HUD makes) ===

## Pause button click → toggle pause. The pause button shows the active cue
## while paused (AC1); clicking it resumes at the last-used speed (AC4).
func _on_pause_button_pressed() -> void:
	if not _initialized:
		return
	if _time_system.is_paused():
		_time_system.resume()
	else:
		_time_system.pause()
	_refresh_transport()


## Speed button click (1×/2×/3×) → set speed directly + implicit unpause
## (one action — AC5). Same-speed while running is a no-op (Core Rule 4).
func _on_speed_button_pressed(speed: int) -> void:
	set_speed(speed)


## Public transport forward (TR-HUD-005): sets the sim speed. Explicitly
## unpauses when paused — GDD: "1/2/3 = set speed directly (and implicitly
## unpause — pressing 2 while paused resumes at 2×, one action not two)".
## TimeSystem.set_speed() itself does NOT unpause while paused (it only
## records _last_speed); the resume here is what makes the one-action
## contract true. Same-speed while running: TimeSystem re-sets the identical
## multiplier — no state change, no flicker (Core Rule 4 no-op).
func set_speed(speed: int) -> void:
	if not _initialized:
		return
	assert(speed in [1, 2, 3], "Invalid speed: %d" % speed)
	_time_system.set_speed(speed)
	if _time_system.is_paused():
		_time_system.resume()
	_refresh_transport()


## Public transport forward (TR-HUD-005): pause()/resume() straight to
## TimeSystem. This is the ONLY pause mutation the HUD makes (TR-HUD-006).
func set_paused(paused: bool) -> void:
	if not _initialized:
		return
	if paused:
		_time_system.pause()
	else:
		_time_system.resume()
	_refresh_transport()


## Space hotkey: toggle pause. Focus-independent by construction — arrives
## via _unhandled_key_input (ADR-0005 §5), and the transport buttons are
## FOCUS_NONE so a focused Button can never swallow it (dual-focus 4.6+).
func toggle_pause() -> void:
	set_paused(not _time_system.is_paused())


## Keyboard hotkeys (TR-HUD-005): Space = toggle pause; 1/2/3 = set speed
## directly (implicitly unpausing). Echo repeats are ignored (a held key
## must not re-fire every frame — same discipline as the input bridges).
## _unhandled_key_input is focus-independent: it runs after GUI/focusable
## controls decline the event, so the hotkeys work regardless of which
## Control has focus (dual-focus 4.6+, ADR-0005 §5).
func _unhandled_key_input(event: InputEvent) -> void:
	if not _initialized:
		return
	if event is InputEventKey:
		var key := event as InputEventKey
		if not key.pressed or key.echo:
			return
		match key.keycode:
			KEY_SPACE:
				toggle_pause()
			KEY_1:
				set_speed(1)
			KEY_2:
				set_speed(2)
			KEY_3:
				set_speed(3)


# === Public getters (test surface) ===

func get_money_label() -> Label:
	return _money_label

func get_satisfaction_label() -> Label:
	return _satisfaction_label

func get_day_label() -> Label:
	return _day_label

func get_time_of_day_label() -> Label:
	return _time_of_day_label

func get_pause_button() -> Button:
	return _pause_button

## Returns the speed Button for [speed] (1..3), or null for an invalid index.
func get_speed_button(speed: int) -> Button:
	if speed < 1 or speed > _speed_buttons.size():
		return null
	return _speed_buttons[speed - 1]

func get_meter() -> ProgressBar:
	return _meter

func get_top_bar() -> HBoxContainer:
	return _top_bar

func get_transport_cluster() -> HBoxContainer:
	return _transport_cluster

func get_ticks_per_day() -> int:
	return _ticks_per_day

func get_ui_scale() -> float:
	return _ui_scale

func get_displayed_day() -> int:
	return _displayed_day

func get_time_of_day() -> float:
	return _time_of_day

# === Story 002 test surface ===

## The value the money label currently shows (mid-tween = the animated value,
## rounded to whole currency units for display). Tests use this to verify a
## tween is actually in flight (displayed != target) vs settled (== target).
func get_displayed_balance() -> int:
	return roundi(_displayed_balance)

## The latest balance_changed target — what the count is animating TOWARD.
func get_money_tween_target() -> int:
	return _money_tween_target

## True when a money count tween is currently in flight. A killed/finished
## tween reports is_valid() == false; a fresh one is_running() == true.
func is_money_tween_active() -> bool:
	return _money_tween != null and _money_tween.is_valid() and _money_tween.is_running()

## The in-flight money tween object (null when none). Tests capture the
## reference BEFORE a re-target and assert the old one is killed
## (is_valid() == false) — the "no queue backlog" proof.
func get_money_tween() -> Tween:
	return _money_tween

## True when the spend-ack settle tween is currently in flight.
func is_ack_tween_active() -> bool:
	return _ack_tween != null and _ack_tween.is_valid() and _ack_tween.is_running()

## Data-driven count duration (GDD knob, clamped 0.2–0.5s).
func get_money_count_duration() -> float:
	return _money_count_duration

## Data-driven reduced-motion flag.
func is_reduced_motion() -> bool:
	return _reduced_motion

## The coin icon's CURRENT font color (theme override — Butter normally, muted
## Butter mid-spend-ack). Tests assert the ack color is never red.
func get_coin_icon_color() -> Color:
	return _coin_icon.get_theme_color("font_color")

# === Story 003 meter getters (test surface) ===

## True while the satisfaction meter is easing (a live tween exists and is
## valid). False under reduced-motion / load snap / idle.
func is_meter_animating() -> bool:
	return _meter_tween != null and _meter_tween.is_valid()

## The active meter tween (null when static). Exposed so tests can assert the
## tween plays ONCE (loops_left == 1 — no pulse) and stays a single tween.
func get_meter_tween() -> Tween:
	return _meter_tween

## The fill fraction (0..100) the active ease is heading toward.
func get_meter_tween_target() -> float:
	return _meter_tween_target

## The configured ease duration in seconds (GDD knob, default 1.0).
func get_satisfaction_ease_duration() -> float:
	return _satisfaction_ease_duration

## The [0,1] satisfaction value currently rendered (lags target mid-ease).
func get_displayed_satisfaction() -> float:
	return _displayed_satisfaction

## True when the static-fill (no ease) accessibility mode is active.
func get_reduced_motion() -> bool:
	return _reduced_motion

## Story 003 test seam: applies one satisfaction display value directly —
## the same callback the meter tween drives every step. Lets headless tests
## verify the AC3 lockstep contract (meter value + % + icon + fill color all
## derive from the same value) without advancing a scene-tree tween.
func apply_satisfaction_display(value: float) -> void:
	_apply_satisfaction_display(value)

## Story 003 test seam: force reduced-motion on/off at runtime (config
## `reduced_motion` sets it at init; this lets tests flip it live).
func set_reduced_motion(enabled: bool) -> void:
	_reduced_motion = enabled

## True when the pause button shows the active cue (TimeSystem paused).
func is_pause_active() -> bool:
	return _time_system.is_paused()

## The currently active speed (1..3), or 0 when paused / no speed active.
func get_active_speed() -> int:
	if _time_system.is_paused():
		return 0
	return _time_system.get_speed_multiplier()
