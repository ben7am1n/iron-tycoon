## Hud — the always-on top bar (Story HUD-001: layout + read-only state binding).
##
## Story: production/epics/hud/story-001-top-bar-layout-state-binding.md
## Req:   TR-HUD-001 (minimal top bar: money / satisfaction / day+time+transport),
##        TR-HUD-006 (read-only + transport only — no popups/toasts/badges),
##        TR-HUD-007 (on load renders paused state + loaded values immediately)
## ADR:   ADR-0001 (UI systems are scene-tree Nodes, not RefCounted sim systems;
##        they receive dependencies via typed init parameters from the
##        composition root), ADR-0005 (typed signal connections only;
##        balance_changed S6 subscription; tick_completed S2 refresh hook)
##
## This is a scene-tree Control hierarchy (NOT a SimSystem). It is the quiet
## frame around the gym: it owns NO simulation state, only DISPLAYS what
## Economy / Satisfaction / TimeSystem expose and (from Story 004) forwards
## pause/speed input. Story 001 scope is layout + read-only state binding —
## money tween (Story 002), meter ramp (Story 003), and transport buttons +
## day/time icon (Story 004) are deliberately NOT implemented here.
##
## STATE BINDING (event-driven, never poll):
##   - balance_changed(new_balance, delta)   -> money label (S6)
##   - global_satisfaction (plain var)       -> % label + meter fill (read on
##                                              init + each tick_completed)
##   - get_tick_count()                      -> day + time_of_day derivation
##                                              (day = 1 + floor(tc/TICKS_PER_DAY);
##                                              time_of_day = (tc mod TICKS_PER_DAY)/TICKS_PER_DAY)
##   - is_paused()/get_speed_multiplier()    -> transport cluster state labels
##                                              (buttons are Story 004's scope)
##   - tick_completed (S2, orchestrator)     -> refresh cadence (10 Hz)
##
## TICKS_PER_DAY is NOT defined by TimeSystem (HUD GDD OQ1 — a game-designer
## decision). Data-driven provisional default 1800 (~3 real minutes at 1×,
## 10 ticks/s); config override key "ticks_per_day".
##
## READ-ONLY DISCIPLINE (Core Rule 5 / TR-HUD-006): no popups, toasts, or
## badges anywhere in this tree; the HUD never mutates sim state. Story 001
## has NO input handling at all (Space/1/2/3 and buttons land in Story 004).
##
## 4.7.1 NOTES: class_name immediately follows extends; typed fields use the
## project's global class cache (headless-safe — cache is committed);
## locals reading system state use explicit `: Type` (never `:=` on Variant).
class_name Hud extends Control

## Data-driven config seams (coding standard: gameplay values never hardcoded).
const CONFIG_TICKS_PER_DAY := "ticks_per_day"
const CONFIG_UI_SCALE := "ui_scale"

## Provisional day length (HUD GDD OQ1 — game-designer owns the final value).
const DEFAULT_TICKS_PER_DAY := 1800

## UI scale (UX spec: 0.8×–1.5× integer multipliers; 1.0 = art-bible anchor).
const DEFAULT_UI_SCALE := 1.0

## Layout anchors (art-bible / UX spec): text ≥ 16px @1080p; safe margin
## ≥ 16px from screen edges at 1.0× UI scale, scaled with UI scale; top bar
## ≤ ~8% of vertical screen height at 1080p (48px + 16px margin = 64px strip).
const SAFE_MARGIN_PX := 16
const TOP_BAR_HEIGHT_PX := 48
const MIN_FONT_SIZE_PX := 16
const METER_WIDTH_PX := 80
const METER_HEIGHT_PX := 8

## Art-bible palette (design/art/art-bible.md §4).
const COLOR_BUTTER := Color("f5d97b")
const COLOR_CHARCOAL := Color("3c3a42")
const COLOR_SAGE := Color("8fbf9f")
const COLOR_SKY := Color("8ec5e8")

# === Injected systems (composition root wires these via init()) ===
var _economy: Economy
var _satisfaction: Satisfaction
var _time_system: TimeSystem
var _orchestrator: SimulationOrchestrator

# === Configuration ===
var _ticks_per_day: int = DEFAULT_TICKS_PER_DAY
var _ui_scale: float = DEFAULT_UI_SCALE

# === Derived display state (testable surface) ===
var _displayed_day: int = 1
var _time_of_day: float = 0.0

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
var _pause_state_label: Label
var _speed_state_label: Label

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

	_coin_icon = _make_label("CoinIcon", "🪙", COLOR_BUTTER)
	_money_group.add_child(_coin_icon)
	_money_label = _make_label("MoneyLabel", "$0", COLOR_CHARCOAL)
	_money_group.add_child(_money_label)

	_left_spacer = _make_spacer("LeftSpacer")
	_top_bar.add_child(_left_spacer)

	_satisfaction_group = _make_group("SatisfactionGroup")
	_top_bar.add_child(_satisfaction_group)

	_face_icon = _make_label("FaceIcon", "🙂", COLOR_CHARCOAL)
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
	_satisfaction_group.add_child(_meter)
	_satisfaction_label = _make_label("SatisfactionLabel", "0%", COLOR_CHARCOAL)
	_satisfaction_group.add_child(_satisfaction_label)

	_right_spacer = _make_spacer("RightSpacer")
	_top_bar.add_child(_right_spacer)

	_time_group = _make_group("TimeGroup")
	_top_bar.add_child(_time_group)

	_day_label = _make_label("DayLabel", "Day 1", COLOR_CHARCOAL)
	_time_group.add_child(_day_label)
	_time_of_day_label = _make_label("TimeOfDayLabel", "00:00", COLOR_SKY)
	_time_group.add_child(_time_of_day_label)

	_transport_cluster = HBoxContainer.new()
	_transport_cluster.name = "TransportCluster"
	_transport_cluster.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_transport_cluster.add_theme_constant_override("separation", _scaled(6))
	_time_group.add_child(_transport_cluster)
	_pause_state_label = _make_label("PauseStateLabel", "PAUSED", COLOR_CHARCOAL)
	_transport_cluster.add_child(_pause_state_label)
	_speed_state_label = _make_label("SpeedStateLabel", "—", COLOR_CHARCOAL)
	_transport_cluster.add_child(_speed_state_label)


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


## Reads [config] into the tuning fields. Missing keys keep the GDD anchors.
func _apply_config(config: Dictionary) -> void:
	if config.has(CONFIG_TICKS_PER_DAY):
		_ticks_per_day = int(config[CONFIG_TICKS_PER_DAY])
	if _ticks_per_day <= 0:
		_ticks_per_day = DEFAULT_TICKS_PER_DAY
	if config.has(CONFIG_UI_SCALE):
		_ui_scale = float(config[CONFIG_UI_SCALE])
	if _ui_scale <= 0.0:
		_ui_scale = DEFAULT_UI_SCALE


## Event-driven refresh on balance mutation (S6). Money is the ONLY label
## driven by a signal — it can change on any tick (income) or between ticks
## (spend/credit), so it must never wait for the next tick_completed.
## Story 002 replaces this with the count-up tween; here we set the value.
func _on_balance_changed(new_balance: int, _delta: int) -> void:
	if not _initialized:
		return
	_money_label.text = format_money(new_balance)


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
## (AC8). Also callable by the composition root after a load.
func refresh_all() -> void:
	if not _initialized:
		return
	var balance: int = _economy.balance
	_money_label.text = format_money(balance)
	_refresh_satisfaction()
	_refresh_time()


## Reads global_satisfaction (a plain var — no signal exists) into the %
## label and the meter fill. Meter ramp + icon shape + ~1s ease are Story
## 003's scope; Story 001 binds the raw value.
func _refresh_satisfaction() -> void:
	var sat: float = _satisfaction.global_satisfaction
	_meter.value = clampf(sat, 0.0, 1.0) * 100.0
	_satisfaction_label.text = "%d%%" % roundi(clampf(sat, 0.0, 1.0) * 100.0)


## Reads tick_count and derives day + time_of_day (GDD Formulas), then
## re-binds the transport cluster state (pause/speed are read-only here —
## buttons land in Story 004).
func _refresh_time() -> void:
	var tick_count: int = _time_system.get_tick_count()
	_displayed_day = derive_day(tick_count, _ticks_per_day)
	_time_of_day = derive_time_of_day(tick_count, _ticks_per_day)
	_day_label.text = "Day %d" % _displayed_day
	_time_of_day_label.text = format_time_of_day(_time_of_day)
	var paused: bool = _time_system.is_paused()
	var speed: int = _time_system.get_speed_multiplier()
	if paused:
		_pause_state_label.text = "PAUSED"
		_speed_state_label.text = "—"
	else:
		_pause_state_label.text = "RUNNING"
		_speed_state_label.text = "%d×" % speed


# === Pure derivation functions (public + statically testable) ===

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
## Story 004 replaces this text with the sun/clock icon; the mapping stays.
static func format_time_of_day(time_of_day: float) -> String:
	var fraction: float = clampf(time_of_day, 0.0, 0.999999)
	var total_minutes: int = floori(fraction * 24.0 * 60.0)
	var hour: int = total_minutes / 60
	var minute: int = total_minutes % 60
	return "%02d:%02d" % [hour, minute]


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


func _make_label(label_name: String, text: String, color: Color) -> Label:
	var label := Label.new()
	label.name = label_name
	label.text = text
	label.add_theme_font_size_override("font_size", _scaled(MIN_FONT_SIZE_PX))
	label.add_theme_color_override("font_color", color)
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return label


## Scales a design pixel value by the UI scale (UX spec: scales with the
## UI-scale setting; text stays >= 16px @1080p at 1.0×).
func _scaled(px: int) -> int:
	return maxi(roundi(float(px) * _ui_scale), 1)


# === Public getters (test surface + Story 004 upgrade path) ===

func get_money_label() -> Label:
	return _money_label

func get_satisfaction_label() -> Label:
	return _satisfaction_label

func get_day_label() -> Label:
	return _day_label

func get_time_of_day_label() -> Label:
	return _time_of_day_label

func get_pause_state_label() -> Label:
	return _pause_state_label

func get_speed_state_label() -> Label:
	return _speed_state_label

func get_meter() -> ProgressBar:
	return _meter

func get_top_bar() -> HBoxContainer:
	return _top_bar

func get_ticks_per_day() -> int:
	return _ticks_per_day

func get_ui_scale() -> float:
	return _ui_scale

func get_displayed_day() -> int:
	return _displayed_day

func get_time_of_day() -> float:
	return _time_of_day
