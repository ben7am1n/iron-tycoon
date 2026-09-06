## Read-only first-day UI and input bridge. Commands are interpreted only by DayCycle.
extends Control

signal action_requested(action: String, payload: Dictionary)
const UiTheme := preload("res://src/ui/ui_theme.gd")
const Palette := preload("res://src/palette.gd")

const PORTRAIT_PATHS := {
	"coach": "res://assets/sprites/portraits/portrait_cheng.png",
	"aluo": "res://assets/sprites/portraits/portrait_aluo.png",
	"qiu": "res://assets/sprites/portraits/portrait_qiu.png",
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

## Injects a deep read-view provider. No simulation state is retained as mutable UI data.
func init(provider: Callable) -> void:
	_provider = provider

func _ready() -> void:
	name = "CommunityHud"
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	theme = UiTheme.button_theme()
	_title = _label("PhaseTitle", Vector2(26, 14), Vector2(920, 32), 25)
	_objective = _label("Objective", Vector2(26, 49), Vector2(850, 28), 18)
	_details = _label("Context", Vector2(26, 542), Vector2(1228, 42), 18)
	_feedback = _label("Feedback", Vector2(26, 584), Vector2(1228, 28), 16)
	_portrait = TextureRect.new()
	_portrait.name = "SpeakerPortrait"
	_portrait.position = Vector2(26, 524)
	_portrait.size = Vector2(52, 52)
	_portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_portrait.texture_filter = Control.TEXTURE_FILTER_NEAREST
	_portrait.visible = false
	_portrait.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_portrait)

	_speaker_label = _label("SpeakerName", Vector2(88, 524), Vector2(300, 22), 16)
	_speaker_label.visible = false
	_speaker_label.add_theme_color_override("font_color", Palette.CHARCOAL)

	_actions = HBoxContainer.new()
	_actions.name = "Actions"
	_actions.position = Vector2(26, 621)
	_actions.add_theme_constant_override("separation", 8)
	add_child(_actions)
	for item: Array in [
		["depart", "去公园"], ["open_service", "开始营业"], ["start_challenge", "正式挑战"],
		["practice", "练习跑步"], ["finish_challenge", "结束挑战"], ["return_to_gym", "回馆营业"],
		["interact", "交流 / 指导 · E"], ["confirm_timing", "踩准节奏 · E"],
		["next_day", "保存并迎接明天"], ["toggle_build", "布置 · B"],
		["restore_layout", "恢复基础布局"], ["toggle_pause", "暂停 · Space"],
		["select_course", "课程选择"], ["renovate_gym", "场馆改造 · ¥120"]]:
		var action: String = item[0]
		var button := Button.new()
		button.name = action
		button.text = tr(item[1])
		button.custom_minimum_size = Vector2(112, 38)
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
		button.custom_minimum_size = Vector2(105, 38)
		button.pressed.connect(func() -> void: action_requested.emit("choose_guidance", {"choice": choice}))
		_actions.add_child(button)
		_buttons[choice] = button
	_refresh()

func get_active_portrait_character() -> String:
	return _active_speaker_id

func is_portrait_visible() -> bool:
	return _portrait != null and _portrait.visible

func get_speaker_name() -> String:
	return _speaker_label.text if _speaker_label != null else ""

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
	label.add_theme_color_override("font_color", Palette.CHARCOAL)
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
	var guidance: bool = bool(course.get("guidance_open", false)) or str(request.get("stage", "")) == "CHOICE"
	var timing: bool = str(request.get("stage", "")) == "TIMING"
	var details := "WASD / 方向键移动 · E 交流 · F5 保存 · F9 读档"
	var speaker_id := ""
	var speaker_name := ""
	if phase == "OUTING":
		details = "1 走路 / 2 慢跑 / 3 冲刺 · 体力 %.0f · 路程 %.1f 米 · 剩余 %.0f 秒" % [float(outing.get("stamina", 100)), float(outing.get("distance_m", 0)), float(outing.get("remaining_seconds", 180))]
		if not active_run:
			speaker_id = "aluo"
			speaker_name = "阿洛 · 公园"
	elif phase == "SERVICE":
		details = "营业剩余 %d 秒 · %s · E 指导会员 · H 热图" % [maxi(0, 360 - int(_view.get("service_seconds", 0))), str(course.get("label", course.get("status", "等待课程")))]
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
	if guidance:
		details = str(request.get("prompt", course.get("guidance_prompt", "保持 / 放缓 / 休息，选一个节奏。")))
		speaker_id = "coach"
		speaker_name = "程教练 · 指导"
	elif timing:
		details = "按 E 或点击踩准节奏 · 观察会员呼吸"
		speaker_id = "coach"
		speaker_name = "程教练 · 节奏"

	_active_speaker_id = speaker_id
	var tex: Texture2D = _get_portrait_texture(speaker_id) if speaker_id != "" else null
	var show_portrait: bool = tex != null and (phase in ["CLOSE", "OUTING"] or guidance or timing or (phase == "PREP" and int(_view.get("day", 1)) >= 2 and not bool(_view.get("gym_renovated", false))))
	if show_portrait:
		_portrait.texture = tex
		_portrait.visible = true
		_speaker_label.text = speaker_name
		_speaker_label.visible = true
		var py: float = 486.0 if _building else 524.0
		_portrait.position = Vector2(26, py)
		_speaker_label.position = Vector2(88, py)
		_details.position = Vector2(88, py + 22.0)
		_details.size = Vector2(1166, 36)
	else:
		_portrait.visible = false
		_speaker_label.visible = false
		_details.position = Vector2(26, 503 if _building else 542)
		_details.size = Vector2(1228, 42)
	_details.text = details
	for button: Button in _buttons.values():
		button.visible = false
	for action: String in ["toggle_pause"]:
		_buttons[action].visible = true
	_buttons.toggle_pause.text = tr("继续 · Space") if bool(_view.get("paused", false)) else tr("暂停 · Space")
	if guidance:
		for choice: String in ["maintain", "slow", "rest"]:
			_buttons[choice].visible = true
	elif timing:
		_buttons.confirm_timing.visible = true
	elif phase == "PREP":
		for action: String in ["depart", "open_service", "toggle_build", "restore_layout", "select_course"]:
			_buttons[action].visible = true
		var cur_course: String = str(_view.get("selected_course_id", "course_endurance_intro"))
		_buttons.select_course.text = tr("选力量课" if cur_course == "course_endurance_intro" else "选耐力课")
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
		if not bool(_view.get("gym_renovated", false)) and int(_view.get("day", 1)) >= 2:
			_buttons.renovate_gym.visible = true
	if _building:
		_actions.position.y = 574
		_details.position.y = 503
		_feedback.position.y = 544
	else:
		_actions.position.y = 621
		_details.position.y = 542
		_feedback.position.y = 584

func _input(event: InputEvent) -> void:
	if event is InputEventKey and not event.pressed and _held.has(event.keycode):
		_held.erase(event.keycode)
		_send_movement()

func _unhandled_key_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed or event.echo:
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
