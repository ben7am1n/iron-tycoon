## Read-only first-day UI and input bridge. Commands are interpreted only by DayCycle.
extends Control

signal action_requested(action: String, payload: Dictionary)
const UiTheme := preload("res://src/ui/ui_theme.gd")
const Palette := preload("res://src/palette.gd")

const PORTRAIT_PATHS := {
	"coach": "res://assets/sprites/portraits/portrait_cheng.png",
	"aluo": "res://assets/sprites/portraits/portrait_aluo.png",
	"aluo_smile": "res://assets/sprites/portraits/portrait_aluo_smile.png",
	"aluo_tired": "res://assets/sprites/portraits/portrait_aluo_tired.png",
	"qiu": "res://assets/sprites/portraits/portrait_qiu.png",
	"qiu_nod": "res://assets/sprites/portraits/portrait_qiu_nod.png",
	"lin": "res://assets/sprites/portraits/portrait_lin.png",
}

var _provider: Callable
var _title: Label
var _objective: Label
var _details: Label
var _feedback: Label
var _portrait: TextureRect
var _speaker_label: Label
var _actions: HBoxContainer
var _buttons: Dictionary = {}
var _held: Dictionary = {}
var _view: Dictionary = {}
var _building := false
var _last_phase := ""
var _portrait_textures: Dictionary = {}
var _active_speaker_id: String = ""
var _is_collapsed: bool = false

var _card_sb: StyleBoxFlat
var _shadow_sb: StyleBoxFlat
var _portrait_sb: StyleBoxFlat
var _dave_btn_theme: Theme

## Injects a deep read-view provider. No simulation state is retained as mutable UI data.
func init(provider: Callable) -> void:
	_provider = provider

func _ready() -> void:
	name = "CommunityHud"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	_init_dave_styles()
	theme = _dave_btn_theme

	_title = _label("PhaseTitle", Vector2(36, 16), Vector2(920, 30), 22)
	_title.add_theme_color_override("font_color", Color(1.0, 0.88, 0.48))

	_objective = _label("Objective", Vector2(36, 48), Vector2(850, 26), 15)
	_objective.add_theme_color_override("font_color", Color(0.92, 0.90, 0.84))

	_details = _label("Context", Vector2(106, 548), Vector2(1130, 36), 16)
	_details.add_theme_color_override("font_color", Color(0.98, 0.96, 0.92))

	_feedback = _label("Feedback", Vector2(106, 584), Vector2(1130, 24), 14)
	_feedback.add_theme_color_override("font_color", Color(0.98, 0.78, 0.40))

	_portrait = TextureRect.new()
	_portrait.name = "SpeakerPortrait"
	_portrait.position = Vector2(38, 526)
	_portrait.size = Vector2(56, 56)
	_portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_portrait.texture_filter = Control.TEXTURE_FILTER_NEAREST
	_portrait.visible = false
	_portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_portrait)

	_speaker_label = _label("SpeakerName", Vector2(106, 524), Vector2(300, 22), 16)
	_speaker_label.visible = false
	_speaker_label.add_theme_color_override("font_color", Color(1.0, 0.84, 0.36))

	_actions = HBoxContainer.new()
	_actions.name = "Actions"
	_actions.position = Vector2(38, 622)
	_actions.add_theme_constant_override("separation", 10)
	add_child(_actions)
	for item: Array in [
		["depart", "去公园"], ["open_service", "开始营业"], ["start_challenge", "正式挑战"],
		["practice", "练习跑步"], ["finish_challenge", "结束挑战"], ["return_to_gym", "回馆营业"],
		["interact", "交流 / 指导 · E"], ["confirm_timing", "踩准节奏 · E"],
		["next_day", "保存并迎接明天"], ["toggle_build", "布置 · B"],
		["restore_layout", "恢复基础布局"], ["toggle_pause", "暂停 · Space"],
		["select_course", "课程选择"], ["renovate_gym", "场馆改造 · ¥120"],
		["restore_stored", "取回库存设备"], ["skip_feedback", "跳过演出 · Space"]]:
		var action: String = item[0]
		var button := Button.new()
		button.name = action
		button.text = tr(item[1])
		button.custom_minimum_size = Vector2(116, 38)
		button.theme = _dave_btn_theme
		if action == "select_course":
			button.pressed.connect(func() -> void:
				var cur: String = str(_view.get("selected_course_id", "course_endurance_intro"))
				var next: String = "course_strength_intro" if cur == "course_endurance_intro" else "course_endurance_intro"
				action_requested.emit("select_course", {"course_id": next})
			)
		else:
			button.pressed.connect(func() -> void: action_requested.emit(action, {}))
		_actions.add_child(button)
		_buttons[action] = button
	for choice: String in ["maintain", "slow", "rest"]:
		var button := Button.new()
		button.name = choice
		button.text = tr({"maintain": "1 保持", "slow": "2 放缓", "rest": "3 休息"}[choice])
		button.custom_minimum_size = Vector2(108, 38)
		button.theme = _dave_btn_theme
		button.pressed.connect(func() -> void: action_requested.emit("choose_guidance", {"choice": choice}))
		_actions.add_child(button)
		_buttons[choice] = button
	_refresh()

func _init_dave_styles() -> void:
	_card_sb = StyleBoxFlat.new()
	_card_sb.bg_color = Color(0.07, 0.10, 0.16, 0.95)
	_card_sb.border_color = Color(0.86, 0.66, 0.24, 1.0)
	_card_sb.set_border_width_all(2)
	_card_sb.set_corner_radius_all(8)

	_shadow_sb = StyleBoxFlat.new()
	_shadow_sb.bg_color = Color(0.02, 0.03, 0.06, 0.50)
	_shadow_sb.set_corner_radius_all(10)

	_portrait_sb = StyleBoxFlat.new()
	_portrait_sb.bg_color = Color(0.12, 0.16, 0.24, 1.0)
	_portrait_sb.border_color = Color(0.86, 0.66, 0.24, 1.0)
	_portrait_sb.set_border_width_all(2)
	_portrait_sb.set_corner_radius_all(6)

	_dave_btn_theme = Theme.new()
	var normal_sb := StyleBoxFlat.new()
	normal_sb.bg_color = Color(0.13, 0.18, 0.28, 0.96)
	normal_sb.border_color = Color(0.82, 0.62, 0.22, 1.0)
	normal_sb.set_border_width_all(2)
	normal_sb.set_corner_radius_all(6)
	normal_sb.content_margin_left = 12.0
	normal_sb.content_margin_right = 12.0
	normal_sb.content_margin_top = 6.0
	normal_sb.content_margin_bottom = 6.0

	var hover_sb := StyleBoxFlat.new()
	hover_sb.bg_color = Color(0.19, 0.26, 0.40, 1.0)
	hover_sb.border_color = Color(1.0, 0.86, 0.38, 1.0)
	hover_sb.set_border_width_all(2)
	hover_sb.set_corner_radius_all(6)
	hover_sb.content_margin_left = 12.0
	hover_sb.content_margin_right = 12.0
	hover_sb.content_margin_top = 6.0
	hover_sb.content_margin_bottom = 6.0

	var pressed_sb := StyleBoxFlat.new()
	pressed_sb.bg_color = Color(0.08, 0.11, 0.18, 1.0)
	pressed_sb.border_color = Color(0.68, 0.50, 0.16, 1.0)
	pressed_sb.set_border_width_all(2)
	pressed_sb.set_corner_radius_all(6)
	pressed_sb.content_margin_left = 12.0
	pressed_sb.content_margin_right = 12.0
	pressed_sb.content_margin_top = 6.0
	pressed_sb.content_margin_bottom = 6.0

	_dave_btn_theme.set_stylebox("normal", "Button", normal_sb)
	_dave_btn_theme.set_stylebox("hover", "Button", hover_sb)
	_dave_btn_theme.set_stylebox("pressed", "Button", pressed_sb)
	_dave_btn_theme.set_stylebox("focus", "Button", hover_sb)
	_dave_btn_theme.set_color("font_color", "Button", Color(0.96, 0.94, 0.88))
	_dave_btn_theme.set_color("font_hover_color", "Button", Color(1.0, 1.0, 1.0))
	_dave_btn_theme.set_color("font_pressed_color", "Button", Color(0.85, 0.83, 0.78))
	_dave_btn_theme.set_font("font", "Button", UiTheme.cjk_bold_font())
	_dave_btn_theme.set_font_size("font_size", "Button", 15)

func _draw() -> void:
	# 1. Top status banner card (Dave the Diver diegetic card)
	var top_rect := Rect2(20, 10, 1240, 72)
	_draw_dave_card(top_rect)

	# 2. Bottom dialogue and action deck card
	var py: float = 658.0 if _is_collapsed else (480.0 if _building else 514.0)
	var ph: float = 50.0 if _is_collapsed else (230.0 if _building else 196.0)
	var bottom_rect := Rect2(20, py, 1240, ph)
	_draw_dave_card(bottom_rect)

	# 3. Speaker portrait frame
	if _portrait != null and _portrait.visible:
		var pf := Rect2(_portrait.position - Vector2(4, 4), _portrait.size + Vector2(8, 8))
		if _portrait_sb != null:
			draw_style_box(_portrait_sb, pf)

func _draw_dave_card(rect: Rect2) -> void:
	if _shadow_sb != null:
		draw_style_box(_shadow_sb, Rect2(rect.position + Vector2(0, 4), rect.size))
	if _card_sb != null:
		draw_style_box(_card_sb, rect)
	# 4 Corner brass rivets
	_draw_brass_rivet(rect.position + Vector2(8, 8))
	_draw_brass_rivet(Vector2(rect.end.x - 8, rect.position.y + 8))
	_draw_brass_rivet(Vector2(rect.position.x + 8, rect.end.y - 8))
	_draw_brass_rivet(rect.end - Vector2(8, 8))

func _draw_brass_rivet(pos: Vector2) -> void:
	draw_circle(pos, 2.5, Color(1.0, 0.86, 0.40))
	draw_circle(pos + Vector2(-0.5, -0.5), 1.2, Color(1.0, 0.96, 0.72))

func get_active_portrait_character() -> String:
	return _active_speaker_id

func is_portrait_visible() -> bool:
	return _portrait != null and _portrait.visible

func get_speaker_name() -> String:
	return _speaker_label.text if _speaker_label != null else ""

func is_button_visible(action: String) -> bool:
	return _buttons.has(action) and bool(_buttons[action].visible)

func _get_portrait_texture(character_id: String) -> Texture2D:
	if _portrait_textures.has(character_id):
		return _portrait_textures[character_id]
	var path: String = str(PORTRAIT_PATHS.get(character_id, ""))
	if path == "":
		return null
	var tex: Texture2D = null
	if ResourceLoader.exists(path, "Texture2D"):
		var res = ResourceLoader.load(path, "Texture2D")
		if res is Texture2D:
			tex = res
	if tex == null and FileAccess.file_exists(path):
		var img := Image.new()
		if img.load(path) == OK:
			tex = ImageTexture.create_from_image(img)
	_portrait_textures[character_id] = tex
	return tex

func _label(node_name: String, pos: Vector2, extent: Vector2, font_size: int) -> Label:
	var label := Label.new()
	label.name = node_name
	label.position = pos
	label.size = extent
	label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	UiTheme.style_cjk_label(label, font_size)
	label.add_theme_color_override("font_color", Color(0.96, 0.94, 0.88))
	add_child(label)
	return label

## Reports command errors and story feedback without changing gameplay state.
func show_feedback(message: String) -> void:
	_feedback.text = message

## UI-only build mode; phase permissions are additionally enforced by the controller.
func set_building(value: bool) -> void:
	_building = value
	clear_held_input()

## Clears pressed keys across load, focus loss and mode transitions, even if GUI eats release.
func clear_held_input() -> void:
	_held.clear()
	action_requested.emit("move", {"x": 0.0, "y": 0.0})

## Returns true if bottom dialog card is collapsed into a compact bottom bar.
func is_hud_collapsed() -> bool:
	return _is_collapsed

func _process(_delta: float) -> void:
	_refresh()

func _refresh() -> void:
	if not _provider.is_valid() or _title == null:
		return
	_view = _provider.call()
	var phase := str(_view.get("phase", "PREP"))
	if phase != _last_phase:
		clear_held_input()
		_last_phase = phase
	var phase_title: String = {"PREP": "开店准备", "OUTING": "公园 · 找到自己的节奏", "SERVICE": "晚间营业", "CLOSE": "打烊"}.get(phase, phase)
	_title.text = tr("第 %d 天 · %s    ¥%d") % [int(_view.get("day", 1)), phase_title, int(_view.get("balance", 0))]
	_objective.text = str(_view.get("objective", ""))
	var course: Dictionary = _view.get("course", {})
	var outing: Dictionary = _view.get("outing", {})
	var request: Dictionary = _view.get("request", {})
	var active_run: bool = bool(outing.get("active", false))
	var req_stage: String = str(request.get("status", request.get("stage", ""))).to_upper()
	var has_guidance_dict: bool = course.has("guidance") and course.guidance is Dictionary and not course.guidance.is_empty()
	var guidance: bool = bool(course.get("guidance_open", false)) or has_guidance_dict or req_stage == "CHOICE"
	var timing: bool = req_stage == "TIMING"
	var details := "WASD / 方向键移动 · E 交流 · F5 保存 · F9 读档"
	var speaker_id := ""
	var speaker_name := ""
	if phase == "OUTING":
		var progress: float = float(outing.get("progress_m", outing.get("distance_m", 0.0)))
		var used_sec: float = float(outing.get("seconds", 0.0))
		var rem_sec: float = float(outing.get("remaining_seconds", maxf(0.0, 180.0 - used_sec)))
		details = "1 走路 / 2 慢跑 / 3 冲刺 · 体力 %.0f · 路程 %.1f 米 · 剩余 %.0f 秒" % [float(outing.get("stamina", 100)), progress, rem_sec]
	elif phase == "SERVICE":
		speaker_id = "coach"
		speaker_name = "程教练 · 晚间营业"
		var course_status_label := "等待课程"
		var raw_status := str(course.get("label", course.get("status", "")))
		match raw_status:
			"scheduled":
				course_status_label = "学员候课准备"
			"running":
				course_status_label = "团体课授课中"
			"completed":
				course_status_label = "课程圆满结课"
			"canceled":
				course_status_label = "课程取消"
			_:
				course_status_label = raw_status if not raw_status.is_empty() else "等待课程"
		details = "营业剩余 %d 秒 · %s · E 指导会员 · H 热图" % [maxi(0, 360 - int(_view.get("service_seconds", 0))), course_status_label]
		if int(course.get("block", 0)) > 0:
			details += " · 第 %d / 4 段" % int(course.block)
	elif phase == "CLOSE":
		var story: Dictionary = _view.get("story", {})
		var close_dlg: String = str(story.get("dialogue", story.get("closing_text", "今天辛苦了。明天继续。")))
		details = close_dlg
		if close_dlg.begins_with("阿洛：") or close_dlg.contains("阿洛："):
			speaker_id = "aluo"
			speaker_name = "阿洛"
		elif close_dlg.begins_with("老邱：") or close_dlg.contains("老邱："):
			speaker_id = "qiu"
			speaker_name = "老邱"
		elif close_dlg.begins_with("林师傅：") or close_dlg.contains("林师傅："):
			speaker_id = "lin"
			speaker_name = "林师傅"
		elif close_dlg.begins_with("程教练：") or close_dlg.contains("程教练："):
			speaker_id = "coach"
			speaker_name = "程教练"
	elif phase == "PREP":
		if int(_view.get("day", 1)) >= 2 and not bool(_view.get("gym_renovated", false)):
			speaker_id = "lin"
			speaker_name = "林师傅 · 改造建议"
		else:
			speaker_id = "coach"
			speaker_name = "程教练"
	var fb_seq: Dictionary = _view.get("feedback_sequence", {})
	var is_fb_active: bool = bool(fb_seq.get("active", false))
	if is_fb_active:
		var fb_elapsed: float = float(fb_seq.get("elapsed", 0.0))
		if fb_elapsed < 1.0:
			speaker_id = "coach"
			speaker_name = "程教练 · 节奏指导"
			details = "程教练：跟上拍子！核心收紧，保持呼吸稳住！"
		else:
			speaker_id = "qiu_nod"
			speaker_name = "老邱 · 赞许"
			details = "老邱：好节奏！动作稳住了，配合得越来越有默契。"
	elif guidance:
		details = str(request.get("prompt", course.get("guidance_prompt", "保持 / 放缓 / 休息，选一个节奏。")))
		speaker_id = "coach"
		speaker_name = "程教练 · 指导"
	elif timing:
		details = "按 E 或点击踩准节奏 · 观察会员呼吸"
		speaker_id = "coach"
		speaker_name = "程教练 · 节奏"

	_active_speaker_id = speaker_id
	var tex: Texture2D = _get_portrait_texture(speaker_id) if speaker_id != "" else null
	var show_portrait: bool = tex != null

	var needs_expanded: bool = (
		(phase != "SERVICE" and not (phase == "OUTING" and active_run))
		or guidance
		or timing
		or is_fb_active
		or _building
		or bool(_view.get("paused", false))
		or (_active_speaker_id != "" and _active_speaker_id != "coach")
	)
	_is_collapsed = not needs_expanded

	var base_py: float
	if _is_collapsed:
		base_py = 658.0
		_portrait.visible = false
		_speaker_label.visible = false
		_details.position = Vector2(36, base_py + 12.0)
		_details.size = Vector2(820, 26)
		_details.visible = true
		_feedback.visible = false
		_actions.position = Vector2(880, base_py + 6.0)
	else:
		base_py = 480.0 if _building else 514.0
		_details.visible = true
		if show_portrait:
			_portrait.texture = tex
			_portrait.visible = true
			_speaker_label.text = speaker_name
			_speaker_label.visible = true
			_portrait.position = Vector2(38, base_py + 12.0)
			_portrait.size = Vector2(56, 56)
			_speaker_label.position = Vector2(108, base_py + 10.0)
			_details.position = Vector2(108, base_py + 34.0)
			_details.size = Vector2(1130, 36)
			_feedback.position = Vector2(108, base_py + 70.0)
			_feedback.visible = not _feedback.text.is_empty() and _feedback.text != details
		else:
			_portrait.visible = false
			_speaker_label.visible = false
			_details.position = Vector2(38, base_py + 18.0)
			_details.size = Vector2(1200, 42)
			_feedback.position = Vector2(38, base_py + 64.0)
			_feedback.visible = not _feedback.text.is_empty() and _feedback.text != details
		_actions.position = Vector2(38, base_py + 104.0)
	_details.text = details
	for button: Button in _buttons.values():
		button.visible = false
	for action: String in ["toggle_pause"]:
		_buttons[action].visible = true
	_buttons.toggle_pause.text = tr("继续 · Space") if bool(_view.get("paused", false)) else tr("暂停 · Space")
	if is_fb_active:
		_buttons.skip_feedback.visible = true
	elif guidance:
		for choice: String in ["maintain", "slow", "rest"]:
			_buttons[choice].visible = true
	elif timing:
		_buttons.confirm_timing.visible = true
	elif phase == "PREP":
		for action: String in ["depart", "open_service", "toggle_build", "restore_layout", "select_course"]:
			_buttons[action].visible = true
		var cur_course: String = str(_view.get("selected_course_id", "course_endurance_intro"))
		_buttons.select_course.text = tr("选力量课" if cur_course == "course_endurance_intro" else "选耐力课")
		if int(_view.get("stored_count", 0)) > 0:
			_buttons.restore_stored.visible = true
			_buttons.restore_stored.text = tr("取回库存(%d)") % int(_view.get("stored_count", 0))
		if not bool(_view.get("gym_renovated", false)) and int(_view.get("day", 1)) >= 2:
			_buttons.renovate_gym.visible = true
		_buttons.toggle_build.text = tr("结束布置 · B") if _building else tr("布置 · B")
	elif phase == "OUTING":
		for action: String in (["finish_challenge"] if active_run else ["start_challenge", "practice", "interact", "return_to_gym"]):
			_buttons[action].visible = true
	elif phase == "SERVICE":
		_buttons.interact.visible = true
	elif phase == "CLOSE":
		_buttons.interact.visible = true
		_buttons.next_day.visible = true
		if int(_view.get("stored_count", 0)) > 0:
			_buttons.restore_stored.visible = true
			_buttons.restore_stored.text = tr("取回库存(%d)") % int(_view.get("stored_count", 0))
		if not bool(_view.get("gym_renovated", false)) and int(_view.get("day", 1)) >= 2:
			_buttons.renovate_gym.visible = true
	queue_redraw()

func _input(event: InputEvent) -> void:
	if event is InputEventKey and not event.pressed and _held.has(event.keycode):
		_held.erase(event.keycode)
		_send_movement()

func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
		return
	var fb_seq: Dictionary = _view.get("feedback_sequence", {})
	if bool(fb_seq.get("active", false)) and event.keycode in [KEY_SPACE, KEY_E]:
		action_requested.emit("skip_feedback", {})
		get_viewport().set_input_as_handled()
		return
	if event.keycode in [KEY_W, KEY_A, KEY_S, KEY_D, KEY_UP, KEY_DOWN, KEY_LEFT, KEY_RIGHT] and not _building:
		_held[event.keycode] = true
		_send_movement()
	elif event.keycode in [KEY_SPACE, KEY_ESCAPE]:
		action_requested.emit("toggle_build" if _building and event.keycode == KEY_ESCAPE else "toggle_pause", {})
	elif event.keycode == KEY_B:
		action_requested.emit("toggle_build", {})
	elif event.keycode == KEY_H:
		action_requested.emit("toggle_heatmap", {})
	elif event.keycode == KEY_E:
		action_requested.emit("confirm_timing" if str(_view.get("request", {}).get("stage", "")) == "TIMING" else "interact", {})
	elif event.keycode in [KEY_1, KEY_2, KEY_3]:
		var index: int = event.keycode - KEY_1
		if str(_view.get("phase", "")) == "OUTING":
			action_requested.emit("set_pace", {"pace": ["walk", "jog", "sprint"][index]})
		else:
			action_requested.emit("choose_guidance", {"choice": ["maintain", "slow", "rest"][index]})
	else:
		return
	get_viewport().set_input_as_handled()

func _send_movement() -> void:
	var x := int(_held.has(KEY_D) or _held.has(KEY_RIGHT)) - int(_held.has(KEY_A) or _held.has(KEY_LEFT))
	var y := int(_held.has(KEY_S) or _held.has(KEY_DOWN)) - int(_held.has(KEY_W) or _held.has(KEY_UP))
	action_requested.emit("move", {"x": float(x), "y": float(y)})

func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_WINDOW_FOCUS_OUT and is_inside_tree():
		clear_held_input()
		action_requested.emit("pause", {})
