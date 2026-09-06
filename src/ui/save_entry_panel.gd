## Chinese save/load entry, with identical mouse and keyboard command paths (GA-002).
extends VBoxContainer

signal save_requested
signal load_requested

const UiTheme := preload("res://src/ui/ui_theme.gd")
var _feedback: Label

func _ready() -> void:
	name = "SaveEntryPanel"
	theme = UiTheme.button_theme()
	var row := HBoxContainer.new()
	row.name = "Actions"
	add_child(row)
	var save_button := Button.new()
	save_button.name = "SaveButton"
	save_button.text = tr("保存 · F5")
	save_button.custom_minimum_size = Vector2(126, 34)
	save_button.pressed.connect(func() -> void: save_requested.emit())
	row.add_child(save_button)
	var load_button := Button.new()
	load_button.name = "LoadButton"
	load_button.text = tr("读档 · F9")
	load_button.custom_minimum_size = Vector2(126, 34)
	load_button.pressed.connect(func() -> void: load_requested.emit())
	row.add_child(load_button)
	_feedback = Label.new()
	_feedback.name = "SaveFeedback"
	_feedback.text = tr("手动存档 · 读档后暂停")
	_feedback.add_theme_font_override("font", UiTheme.cjk_bold_font())
	_feedback.add_theme_font_size_override("font_size", 14)
	_feedback.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_feedback.custom_minimum_size = Vector2(340, 42)
	add_child(_feedback)

## Displays the last operation result; failures remain visible until the next operation.
func show_result(message: String, success: bool) -> void:
	_feedback.text = message
	_feedback.add_theme_color_override("font_color", Color("265f50") if success else Color("a33030"))

## Returns player-visible operation feedback for main-scene integration checks.
func get_feedback() -> String:
	return _feedback.text

func _unhandled_key_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		if event.keycode == KEY_F5:
			save_requested.emit()
			get_viewport().set_input_as_handled()
		elif event.keycode == KEY_F9:
			load_requested.emit()
			get_viewport().set_input_as_handled()
