## GoalTracker — minimal A4 HUD surface: current goal, progress, and claim.
## Owns no gameplay state; all writes route through GoalSystem.claim_goal().
extends PanelContainer

const STATUS_COMPLETED := "COMPLETED"
const METRIC_SATISFACTION := "SATISFACTION"

var _goals: Variant = null
var _title_label: Label
var _progress_label: Label
var _progress_bar: ProgressBar
var _claim_button: Button


## Injects the read/write GoalSystem boundary and builds the compact tracker.
func init(goals: Variant) -> void:
	_goals = goals
	name = "GoalTracker"
	custom_minimum_size = Vector2(340, 92)

	var content := VBoxContainer.new()
	content.add_theme_constant_override("separation", 4)
	add_child(content)

	_title_label = Label.new()
	_title_label.text = "当前目标"
	_title_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
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
	progress_row.add_child(_progress_bar)

	_progress_label = Label.new()
	_progress_label.custom_minimum_size = Vector2(68, 0)
	_progress_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	progress_row.add_child(_progress_label)

	_claim_button = Button.new()
	_claim_button.text = "领取奖励"
	_claim_button.visible = false
	_claim_button.pressed.connect(_on_claim_pressed)
	content.add_child(_claim_button)

	if _goals != null and (_goals as Object).has_signal("goal_updated"):
		(_goals as Object).connect("goal_updated", Callable(self, "_on_goal_updated"))
	if _goals != null and (_goals as Object).has_signal("goal_claimed"):
		(_goals as Object).connect("goal_claimed", Callable(self, "_on_goal_claimed"))
	_refresh()


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
