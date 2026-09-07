## First-day community session. MemberSim owns visitors; Economy owns receipts.
## ADR-0011; all UI writes enter through command(), all state is JSON-safe.
extends RefCounted
signal phase_changed(phase: String)
var _config: Dictionary
var _fixture: Dictionary
var _orch: SimulationOrchestrator
var _state: Dictionary = {}
var _initialized := false
var phase: String:
	get: return str(_state.get("phase", "PREP"))

## Attaches the scoped session after the sandbox composition is initialized.
func init(config: Dictionary, fixture: Dictionary, orchestrator: SimulationOrchestrator) -> void:
	if _initialized:
		push_error("DayCycle already initialized")
		return
	_config = config.duplicate(true)
	_fixture = fixture.duplicate(true)
	_orch = orchestrator
	_state = {"phase": "PREP", "day": 1, "service_tick": 0, "move": [0.0, 0.0],
		"coach": fixture.coach_spawn.duplicate(), "outing": {}, "formal_result": {},
		"course": {}, "request": {}, "events": [], "feedback": [], "stored": [],
		"ordinary_index": 0, "request_index": 0, "class_spawned": false,
		"closing_text": "林师傅：灯能亮。先给大家留一条舒服的路。",
		"selected_course_id": "course_endurance_intro", "last_course_arrivals": -1}
	_initialized = true
	_orch.day_cycle = self
	_orch.member_sim.configure_community(float(config.gym.member_walk_cells_per_second))
	_orch.economy.configure_community(int(config.economy.starting_cash), int(config.economy.walk_in_fee))
	_restore_layout()
	_new_course()
	_reset_outing(false)
	_orch.time_system.pause()

## Returns a read copy; all simulation mutation is guarded by phase/action checks.
func command(action: String, payload: Dictionary = {}) -> Dictionary:
	if not _initialized:
		return _error("社区故事尚未初始化")
	match action:
		"move":
			var v := Vector2(float(payload.get("x", 0)), float(payload.get("y", 0))).limit_length(1.0)
			_state.move = [v.x, v.y]
		"depart":
			if phase != "PREP": return _error("请在开店准备时出发")
			var issues := _opening_errors()
			if not issues.is_empty(): return {"ok": false, "errors": issues}
			_change_phase("OUTING")
			_orch.time_system.resume()
		"return_to_gym", "open_service":
			if not phase in ["PREP", "OUTING"]: return _error("现在不能开始营业")
			if phase == "OUTING" and _state.outing.active:
				if not payload.get("confirm", false): return _error("先结束挑战，再返回健身房")
				_finish_run()
			var issues := _opening_errors()
			if not issues.is_empty(): return {"ok": false, "errors": issues}
			_state.coach = _fixture.coach_spawn.duplicate()
			_state.service_tick = 0
			_change_phase("SERVICE")
			_orch.time_system.resume()
		"start_challenge", "practice":
			if phase != "OUTING" or _state.outing.active: return _error("请先结束当前挑战")
			if action == "start_challenge" and not _state.formal_result.is_empty(): return _error("今日正式成绩已提交，可以自由练习")
			_reset_outing(action == "practice")
			_state.outing.active = true
			_orch.time_system.resume()
		"finish_challenge":
			if phase != "OUTING" or not _state.outing.active: return _error("没有进行中的挑战")
			_finish_run()
		"set_pace":
			var pace := str(payload.get("pace", ""))
			if phase != "OUTING" or not _config.outing.speed_mps.has(pace): return _error("配速只用于公园活动")
			if pace == "sprint" and _state.outing.sprint_locked: return _error("先恢复体力到20再冲刺")
			_state.outing.pace = pace
		"interact":
			if phase == "OUTING":
				_event("aluo_met")
				if int(_state.day) == 2:
					_feedback("阿洛：今天我换了段慢歌的副歌，感觉能跟上呼吸了。")
				elif int(_state.day) >= 3:
					_feedback("阿洛：今晚我们乐队四个人来包场，我都跟他们交代好了！")
				else:
					_feedback("阿洛：唱副歌时，我总比鼓手先结束。今晚我来试试！")
			elif phase == "SERVICE":
				var request: Dictionary = _state.request
				if request.is_empty(): return _error("目前没有需要指导的会员")
				var member: Dictionary = _orch.member_sim.visit_snapshot(int(request.member_id))
				if member.is_empty(): return _error("会员已离开")
				var pos := _vec(member.get("position_xy", member.cell))
				if pos.distance_to(_vec(_state.coach)) > float(_config.coaching.interaction_radius_cells): return _error("先走到会员身边再按 E")
				if request.status == "waiting":
					request.status = "choice"
					request.seconds = 0.0
				elif request.status == "timing":
					_confirm_timing()
			elif phase == "CLOSE":
				_event("aluo_met")
				_feedback(str(_state.closing_text))
			else:
				_feedback("老邱：先留条路，再开始今晚的新手耐力课。")
		"choose_guidance":
			var choice := str(payload.get("choice", ""))
			if phase != "SERVICE" or not choice in ["maintain", "slow", "rest"]: return _error("现在没有这项指导")
			if not _state.request.is_empty() and _state.request.status == "choice":
				_state.request.correct = choice == _state.request.correct_choice
				_state.request.status = "timing"
				_state.request.timing_seconds = 0.0
			elif not _state.course.guidance.is_empty():
				var guidance: Dictionary = _state.course.guidance
				_state.course.guidance_scores[int(guidance.index)] = 1.0 if choice == guidance.answer else 0.0
				_feedback("节奏配合上了！" if choice == guidance.answer else "换一个提示试试，训练会继续。")
				_state.course.guidance = {}
			else: return _error("指导窗口已经结束")
		"confirm_timing":
			if _state.request.is_empty() or _state.request.status != "timing": return _error("先选择指导方式")
			_confirm_timing()
		"next_day":
			if phase != "CLOSE": return _error("打烊后才能进入下一天")
			_orch.member_sim.clear_community_visits()
			_state.day += 1
			_state.service_tick = 0
			_state.ordinary_index = 0
			_state.request_index = 0
			_state.class_spawned = false
			_state.formal_result = {}
			_state.request = {}
			_state.coach = _fixture.coach_spawn.duplicate()
			_new_course()
			_reset_outing(false)
			_change_phase("PREP")
			_orch.time_system.pause()
		"restore_layout":
			if phase != "PREP": return _error("营业期间不能调整场馆")
			if not payload.get("confirm", false): return _error("恢复会把购买的设备放入收纳，确认后再执行")
			_restore_layout()
		"restore_stored":
			if phase != "PREP": return _error("请在准备时取回收纳")
			_restore_stored()
		"select_course":
			if phase != "PREP": return _error("请在开店准备时选择课程")
			var course_id := str(payload.get("course_id", "course_endurance_intro"))
			if not course_id in ["course_endurance_intro", "course_strength_intro"]:
				return _error("未知课程：" + course_id)
			var devs := _find_course_devices(course_id)
			if devs.size() < 2:
				if course_id == "course_strength_intro":
					return _error("需要先购买并摆放卧推架")
				else:
					return _error("需要先摆放跑步机或单车")
			_state.selected_course_id = course_id
			_state.course.devices = devs
			_state.course.course_id = course_id
			_feedback("已选择课程：" + ("基础力量循环" if course_id == "course_strength_intro" else "新手耐力循环"))
		"renovate_gym":
			if not phase in ["PREP", "CLOSE"]: return _error("请在开店准备或打烊时进行场馆改造")
			if _state.events.has("gym_renovated"): return _error("场馆已经改造过了")
			var cost := int(_config.economy.get("renovation_cost", 120))
			if _orch.economy.balance < cost: return _error("现金不足 %d 元，暂时无法改造" % cost)
			if not _orch.economy.spend(cost): return _error("扣除改造费用失败")
			_event("gym_renovated")
			_feedback("林师傅：招牌和前台修好了！整条街都能看到我们的新光彩。")
		_:
			return _error("未知操作：" + action)
	return {"ok": true, "errors": []}

## First part of the orchestrator's fixed tick, before MemberSim.
func tick_begin() -> void:
	if not _initialized: return
	if phase == "OUTING":
		_tick_outing()
	else:
		_move_coach()
	if phase != "SERVICE": return
	var tick: int = _state.service_tick
	var schedule: Array = _config.day.walk_in_schedule_seconds
	if _state.ordinary_index < schedule.size() and tick >= roundi(float(schedule[_state.ordinary_index]) / _dt()):
		_orch.member_sim.spawn_visit("D%d:V%d" % [_state.day, _state.ordinary_index], "ordinary")
		_state.ordinary_index += 1
	if not _state.class_spawned and tick >= _ticks(_config.day.course_arrival_seconds):
		_state.class_spawned = true
		var is_band: bool = bool(_state.course.get("is_band_event", false))
		var band_roster := ["singer_aluo", "band_bass_aming", "band_guitar_dawei", "band_drum_xiaokai"]
		for i in int(_config.day.course_seats):
			var npc: String = band_roster[i] if is_band else ("singer_aluo" if i == 0 and _state.events.has("aluo_met") else "")
			var id: int = _orch.member_sim.spawn_visit("D%d:C%d" % [_state.day, i], "course", npc)
			_state.course.members.append(id)
			_orch.member_sim.set_course_task(id, _cell(_fixture.waiting_cells[i]), -1, 0, 0)
	if tick >= _ticks(_config.day.course_reservation_seconds) and _state.course.status == "scheduled":
		_orch.member_sim.hold_class_devices(_state.course.devices)
	if _state.course.status == "scheduled" and tick >= _ticks(_config.day.course_start_seconds):
		if _class_ready():
			_state.course.status = "running"
			_state.course.start_tick = tick
			if bool(_state.course.get("is_band_event", false)):
				_event("band_event_attended")
			_open_block(0)
		elif tick >= _ticks(_config.day.course_latest_start_seconds):
			_state.course.status = "canceled"
			_orch.member_sim.finish_course_visits(_state.course.members)
			_feedback("课程未能准时开班，明天调整布局再试。")
	if _state.course.status == "running":
		var relative: int = tick - int(_state.course.start_tick)
		var block_ticks := _ticks(_config.day.course_block_seconds)
		if relative >= block_ticks * 4:
			_finish_course()
		elif relative > 0 and relative % block_ticks == 0:
			_open_block(int(relative / block_ticks))
	_tick_guidance()

## Reads actual member facts after movement/usage and before cash settlement.
func after_members() -> void:
	if not _initialized or phase != "SERVICE": return
	var course: Dictionary = _state.course
	if course.status == "running":
		for i in course.members.size():
			var member: Dictionary = _orch.member_sim.visit_snapshot(int(course.members[i]))
			course.training_seconds[i] = float(member.get("trained_ticks", 0)) * _dt()
		var local: int = int(_state.service_tick) - int(course.start_tick) - int(course.block) * _ticks(_config.day.course_block_seconds)
		if local == _ticks(_config.day.course_setup_seconds):
			for i in 2:
				var seat: int = (int(course.block) % 2) * 2 + i
				var member: Dictionary = _orch.member_sim.visit_snapshot(int(course.members[seat]))
				var target: int = course.devices[i if int(course.block) < 2 else 1 - i]
				var access: Array = _orch.grid_system.get_access_cells(target)
				if not member.is_empty() and not access.is_empty() and _cell(member.cell) == access[0]:
					course.arrivals += 1

## Runs after Economy, so closing observes already committed receipts.
func tick_end() -> void:
	if not _initialized or phase != "SERVICE": return
	_state.service_tick += 1
	if int(_state.service_tick) >= _ticks(_config.day.service_seconds):
		_state.request = {}
		_event("aluo_met")
		var day: int = int(_state.day)
		if day == 1:
			_state.closing_text = "阿洛：原来坚持到最后，不一定要一直拼命。明天还想来。" if _state.events.has("aluo_first_class") else "阿洛：今天认识了这家小馆。明天给我留一席吧。"
		elif day >= 2 and not _state.events.has("band_invitation") and _state.events.has("aluo_first_class"):
			_event("band_invitation")
			_state.closing_text = "阿洛：他们说想来试试。四个人，不带音箱……先不带。\n林师傅：我修好了招牌，它现在认识晚上了。"
			_feedback("阿洛发出了乐队包场邀请！林师傅也提出了场馆改造建议。")
		elif day == 2 and not _state.events.has("aluo_first_class"):
			_state.closing_text = "老邱：每个人有自己的节奏。明天继续找感觉。"
		else:
			if _state.events.has("band_event_complete"):
				_state.closing_text = "程教练：明天还来？\n阿洛：我把鼓手也带上。\n老邱：他不是今天来了吗？\n阿洛：今天来的是吉他手。鼓手还在找停车位。"
				_feedback("三天故事切片圆满达成！")
			else:
				_state.closing_text = "老邱：明天再约一次。乐队的配合会越来越好。"
		_change_phase("CLOSE")
		_orch.time_system.pause()

## JSON-safe view; billable cash is always read from the sole Economy owner.
func get_view_state() -> Dictionary:
	var course: Dictionary = _state.course.duplicate(true)
	course["start_seconds"] = float(course.get("start_tick", -1)) * _dt()
	course["block_seconds"] = maxf(0, (float(_state.service_tick) - float(course.get("start_tick", 0))) * _dt() - int(course.get("block", 0)) * float(_config.day.course_block_seconds))
	course["block"] = int(course.get("block", -1)) + 1 if course.status in ["running", "completed"] else 0
	var outing: Dictionary = _state.outing.duplicate(true)
	outing["result"] = _state.formal_result.duplicate(true)
	outing["position"] = _route_position(float(outing.progress_m))
	outing["target_mps"] = _target_speed(float(outing.progress_m))
	var day: int = int(_state.day)
	var objectives := {
		"PREP": "准备两件器械与一条通道，然后去公园认识阿洛。" if day == 1 else ("今晚是乐队包场！检查器械通道，准备迎接四位乐手伙伴。" if (day >= 3 and _state.events.has("band_invitation") and not _state.events.has("band_event_complete")) else ("昨天换站动线稍显仓促。今天可调整布局，或购买卧推架开启力量课。" if int(_state.get("last_course_arrivals", 8)) < 8 else "昨天换站节奏很棒！今天可购买卧推架开启力量课，或继续耐力循环。")),
		"OUTING": "沿步道走、慢跑与冲刺，找到呼吸的节奏。" if day == 1 else ("在公园与阿洛交流新歌，或继续配速练习。" if day == 2 else "阿洛在公园热身，去和他聊聊今晚的包场。"),
		"SERVICE": "乐队包场进行中！确保四位乐手顺利换站完成训练。" if bool(_state.course.get("is_band_event", false)) else "给四位会员留出换站通道，靠近需要帮助的人。",
		"CLOSE": "今天的训练结束了，听听阿洛怎么说。" if day == 1 else ("阿洛提出了乐队包场！也可以向林师傅咨询场馆改造。" if day == 2 and _state.events.has("band_invitation") else ("三天体验切片达成！听听大家的合影与告别感言。" if _state.events.has("band_event_complete") else "今天的训练结束了，听听大家的反馈。"))
	}
	return {"phase": phase, "day": _state.day, "service_seconds": float(_state.service_tick) * _dt(),
		"balance": _orch.economy.balance, "build_allowed": phase == "PREP", "paused": _orch.time_system.is_paused(),
		"objective": objectives.get(phase, ""), "coach": {"position": _state.coach.duplicate(), "scene": "park" if phase == "OUTING" else "gym", "direction": _state.move.duplicate()},
		"outing": outing, "course": course, "request": _state.request.duplicate(true),
		"stored_count": _state.stored.size(),
		"selected_course_id": _state.get("selected_course_id", "course_endurance_intro"),
		"gym_renovated": _state.events.has("gym_renovated"),
		"is_band_event": bool(_state.course.get("is_band_event", false)),
		"story": {"events": _state.events.duplicate(), "closing_text": _state.closing_text, "feedback": _state.feedback.duplicate()}}

## Complete session payload, independent of frame/UI state. Held keys never restore.
func serialize() -> Dictionary:
	var copy := _state.duplicate(true)
	copy.move = [0.0, 0.0]
	copy["mode_id"] = str(_config.mode_id)
	return copy

## Validates shape and mode before applying any state; no rewards fire on commit.
func deserialize(data: Dictionary, validate_only: bool = false) -> Dictionary:
	if not _initialized: return _error("DayCycle not initialized")
	if data.get("mode_id") != _config.mode_id or not data.get("phase", "") in ["PREP", "OUTING", "SERVICE", "CLOSE"]: return _error("存档模式或阶段不匹配")
	if not data.has("selected_course_id"):
		data["selected_course_id"] = "course_endurance_intro"
	if not data.has("last_course_arrivals"):
		data["last_course_arrivals"] = -1
	for key in _state.keys():
		if not data.has(key):
			return _error("社区存档缺少或损坏字段：" + key)
		var match_type := typeof(data[key]) == typeof(_state[key])
		if not match_type:
			var int_like: bool = key in ["day", "service_tick", "ordinary_index", "request_index", "last_course_arrivals"] and (data.get(key) is int or (data.get(key) is float and is_finite(float(data[key])) and floorf(float(data[key])) == float(data[key])))
			if not int_like:
				return _error("社区存档缺少或损坏字段：" + key)
	if int(data.day) < 1 or int(data.service_tick) < 0 or int(data.service_tick) > _ticks(_config.day.service_seconds): return _error("社区时间无效")
	if not _pair(data.coach) or not _pair(data.move): return _error("主角位置无效")
	var outing: Dictionary = data.outing
	for key in ["seconds", "progress_m", "stamina", "bin_start", "score", "bin_index"]:
		if not _number(outing.get(key)): return _error("公园状态无效：" + key)
	if float(outing.seconds) < 0 or float(outing.seconds) > float(_config.outing.duration_seconds) + _dt() or float(outing.progress_m) < 0 or float(outing.progress_m) > _route_length() or float(outing.stamina) < 0 or float(outing.stamina) > 100: return _error("公园状态超出范围")
	if not outing.get("pace", "") in ["walk", "jog", "sprint"] or not outing.get("scores") is Array: return _error("配速记录无效")
	if not data.course.get("status", "") in ["scheduled", "running", "completed", "canceled"] or not data.course.get("members") is Array or not data.course.get("training_seconds") is Array or not data.course.get("devices") is Array: return _error("课程状态无效")
	if data.course.training_seconds.size() != 4: return _error("课程席位无效")
	for trained in data.course.training_seconds:
		if not _number(trained) or float(trained) < 0 or float(trained) > 40: return _error("课程训练量无效")
	if not data.get("request") is Dictionary: return _error("指导请求无效")
	if not data.request.is_empty():
		for req_key: String in ["member_id", "state", "status", "seconds", "timing_seconds", "correct_choice", "correct"]:
			if not data.request.has(req_key):
				return _error("指导请求字段缺失或损坏：" + req_key)
		if not data.request.status in ["waiting", "choice", "timing"]:
			return _error("指导请求状态无效")
	if not validate_only:
		_state = data.duplicate(true)
		_state.erase("mode_id")
		_state.move = [0.0, 0.0]
		_state.day = int(_state.day)
		_state.service_tick = int(_state.service_tick)
		_state.ordinary_index = int(_state.ordinary_index)
		_state.request_index = int(_state.request_index)
		_state.last_course_arrivals = int(_state.get("last_course_arrivals", -1))
		_state.selected_course_id = str(_state.get("selected_course_id", "course_endurance_intro"))
		if _state.has("outing") and _state.outing is Dictionary:
			_state.outing.seconds = float(_state.outing.get("seconds", 0.0))
			_state.outing.progress_m = float(_state.outing.get("progress_m", 0.0))
			_state.outing.stamina = float(_state.outing.get("stamina", 0.0))
			_state.outing.bin_start = float(_state.outing.get("bin_start", 0.0))
		if _state.has("course") and _state.course is Dictionary and _state.course.has("training_seconds"):
			var typed_training: Array = []
			for t in _state.course.training_seconds:
				typed_training.append(float(t))
			_state.course.training_seconds = typed_training
		if _state.has("coach") and _state.coach is Array and _state.coach.size() >= 2:
			_state.coach = [float(_state.coach[0]), float(_state.coach[1])]
		_apply_protection()
	return {"ok": true, "errors": []}

func _new_course() -> void:
	var course_id: String = str(_state.get("selected_course_id", "course_endurance_intro"))
	var devs := _find_course_devices(course_id)
	if devs.size() < 2:
		course_id = "course_endurance_intro"
		devs = _find_course_devices(course_id)
		if devs.size() < 2:
			devs = [0, 1]
	_state.selected_course_id = course_id
	var is_band: bool = _state.events.has("band_invitation") and not _state.events.has("band_event_complete")
	_state.course = {"status": "scheduled", "start_tick": -1, "block": -1, "members": [],
		"devices": devs, "training_seconds": [0.0, 0.0, 0.0, 0.0], "arrivals": 0,
		"guidance": {}, "guidance_scores": [0.5, 0.5], "quality": 0,
		"course_id": course_id, "is_band_event": is_band}

func _find_course_devices(course_id: String) -> Array:
	var primary_types: Array = []
	var secondary_type := "yoga_mat"
	if course_id == "course_strength_intro":
		primary_types = ["bench_press"]
	else:
		primary_types = ["treadmill", "bike"]
	var primary_id := -1
	var secondary_id := -1
	for placed in _orch.grid_system.get_placed_instances():
		if primary_id == -1 and primary_types.has(placed.equipment_id):
			primary_id = placed.instance_id
		elif secondary_id == -1 and placed.equipment_id == secondary_type:
			secondary_id = placed.instance_id
	if primary_id != -1 and secondary_id != -1:
		return [primary_id, secondary_id]
	return []

func _opening_errors() -> Array:
	var errors: Array = []
	var course_id: String = str(_state.get("selected_course_id", "course_endurance_intro"))
	var devs := _find_course_devices(course_id)
	if devs.size() < 2:
		if course_id == "course_strength_intro":
			errors.append("力量课程需要摆放卧推架与瑜伽垫")
		else:
			errors.append("请恢复借用器械并保持入口到器械可达")
		return errors
	_state.course.devices = devs
	for id in _state.course.devices:
		var cells: Array = _orch.grid_system.get_access_cells(int(id))
		if cells.is_empty() or _orch.navigation.get_path(_cell(_fixture.entrance), cells[0]).is_empty(): errors.append("请恢复借用器械并保持入口到器械可达")
	for cell in _fixture.waiting_cells:
		if _orch.navigation.get_path(_cell(_fixture.entrance), _cell(cell)).is_empty(): errors.append("候课位置被挡住了")
	return errors

func _class_ready() -> bool:
	if _state.course.members.size() != 4 or not _orch.member_sim.class_devices_ready(_state.course.devices): return false
	for i in 4:
		var member: Dictionary = _orch.member_sim.visit_snapshot(int(_state.course.members[i]))
		if member.is_empty() or _cell(member.cell) != _cell(_fixture.waiting_cells[i]): return false
	return true

func _open_block(block: int) -> void:
	var course: Dictionary = _state.course
	course.block = block
	var now: int = _orch.get_tick_count()
	for seat in 4:
		var equipment := -1
		var destination := _cell(_fixture.waiting_cells[seat])
		if int(seat / 2) == block % 2:
			equipment = int(course.devices[seat % 2 if block < 2 else 1 - seat % 2])
			destination = _orch.grid_system.get_access_cells(equipment)[0]
		_orch.member_sim.set_course_task(int(course.members[seat]), destination, equipment, now + _ticks(_config.day.course_setup_seconds), now + _ticks(_config.day.course_block_seconds))
	if block in [1, 3]:
		var answer := "rest"
		var state := "动作犹豫：休息一下，找回信心。"
		if block == 1:
			var stable: bool = bool(_state.formal_result.get("finished", false)) and int(_state.formal_result.get("score", 0)) >= int(_config.outing.stable_rhythm_threshold)
			answer = "maintain" if stable else "slow"
			state = "节奏稳定：保持就很好。" if stable else "呼吸急促：放缓一点。"
		course.guidance = {"state": state, "answer": answer, "seconds_left": float(_config.day.course_guidance_window_seconds), "index": int(block / 2)}

func _finish_course() -> void:
	var course: Dictionary = _state.course
	course.status = "completed"
	course.guidance = {}
	var completed := 0.0
	var min_fraction: float = float(_config.economy.course_fee_min_training_fraction)
	var threshold: float = float(_config.day.course_training_seconds_per_person) * min_fraction
	var band_complete := true
	for i in 4:
		var trained: float = course.training_seconds[i]
		completed += trained / float(_config.day.course_training_seconds_per_person)
		if trained >= threshold:
			_orch.economy.queue_community_revenue("course:D%d:C%d" % [_state.day, i], int(_config.economy.course_fee))
			var member: Dictionary = _orch.member_sim.visit_snapshot(int(course.members[i]))
			if member.get("persistent_npc_id", "") == "singer_aluo": _event("aluo_first_class")
		else:
			band_complete = false
	course.quality = roundi(float(_config.quality.completion_weight) * completed / 4.0 + float(_config.quality.layout_weight) * int(course.arrivals) / 8.0 + float(_config.quality.guidance_weight) * (float(course.guidance_scores[0]) + float(course.guidance_scores[1])) / 2.0)
	_state.last_course_arrivals = int(course.arrivals)
	if bool(course.get("is_band_event", false)) and band_complete:
		_event("band_event_complete")
		_feedback("乐队包场大成功！四人全部达标，阿洛在器械旁唱出完整的高音。")
	else:
		_feedback("新手课程完成 · 质量 %d · 看看大家的进步" % course.quality)
	_orch.member_sim.finish_course_visits(course.members)

func _tick_guidance() -> void:
	var course: Dictionary = _state.course
	if not course.guidance.is_empty():
		course.guidance.seconds_left -= _dt()
		if course.guidance.seconds_left <= 0:
			course.guidance = {}
			_feedback("老邱接过节奏，训练继续。")
	var schedule: Array = _config.coaching.request_schedule_seconds
	if int(_state.request_index) < schedule.size() and int(_state.service_tick) >= _ticks(schedule[int(_state.request_index)]):
		var index: int = _state.request_index
		_state.request_index += 1
		for member in _orch.member_sim.members:
			if member.get("billing_type", "") == "ordinary" and member.state == "USING":
				var state: String = _config.coaching.priority_states[index]
				_state.request = {"member_id": member.member_id, "state": state, "status": "waiting", "seconds": 0.0, "timing_seconds": 0.0, "correct_choice": _config.coaching.state_answers[state], "correct": false}
				break
	var request: Dictionary = _state.request
	var member_id_val := int(request.get("member_id", -1))
	if member_id_val < 0:
		_state.request = {}
		return
	var member: Dictionary = _orch.member_sim.visit_snapshot(member_id_val)

	if member.is_empty() or member.state != "USING":
		_state.request = {}
		return
	request.seconds += _dt()
	if request.status == "timing": request.timing_seconds += _dt()
	var timeout := float(_config.coaching.request_lifetime_seconds) if request.status == "waiting" else float(_config.coaching.choice_max_seconds)
	if (request.status != "timing" and request.seconds >= timeout) or (request.status == "timing" and request.timing_seconds >= float(_config.coaching.timing_seconds)):
		_state.request = {}
		_feedback("基础指导已完成，会员继续锻炼。")

func _confirm_timing() -> void:
	var request: Dictionary = _state.request
	var distance := INF
	for center in _config.coaching.timing_centers_seconds:
		distance = minf(distance, absf(float(request.timing_seconds) - float(center)))
	var timing := clampf(1.0 - distance / float(_config.coaching.timing_half_window_seconds), 0, 1)
	var score := roundi(float(_config.coaching.choice_weight) * float(request.correct) + float(_config.coaching.timing_weight) * timing)
	_feedback("亲自指导 · %d 分：会员向你点点头。" % score)
	_state.request = {}

func _reset_outing(practice: bool) -> void:
	_state.outing = {"active": false, "practice": practice, "seconds": 0.0, "progress_m": 0.0, "pace": "walk", "stamina": float(_config.outing.stamina_initial), "sprint_locked": false, "bin_start": 0.0, "bin_index": 0, "scores": [], "score": 0, "finished": false}

func _tick_outing() -> void:
	var outing: Dictionary = _state.outing
	if not outing.active: return
	var direction := _vec(_state.move)
	var moving := direction.length() > 0.001
	var rate_key: String = outing.pace if moving else "idle"
	outing.stamina = snappedf(clampf(float(outing.stamina) + float(_config.outing.stamina_rate_per_second[rate_key]) * _dt(), 0.0, float(_config.outing.stamina_max)), 0.0001)
	if outing.stamina <= 0:
		outing.pace = "walk"
		outing.sprint_locked = true
	elif outing.stamina >= float(_config.outing.sprint_restart_stamina):
		outing.sprint_locked = false
	var old_time: float = outing.seconds
	outing.seconds = snappedf(outing.seconds + _dt(), 0.0001)
	var old_distance: float = outing.progress_m
	var segment := _route_segment(old_distance)
	var points: Array = _config.outing.route_points
	var forward := (_vec(points[segment + 1]) - _vec(points[segment])).normalized()
	var speed: float = _config.outing.speed_mps[outing.pace]
	outing.progress_m = snappedf(clampf(old_distance + direction.dot(forward) * speed * _dt(), 0, _route_length()), 0.0001)
	var bin_length: float = _config.outing.scoring_bin_meters
	while int(outing.bin_index) < int(_config.outing.scoring_bin_count) and float(outing.progress_m) >= (int(outing.bin_index) + 1) * bin_length:
		var gate: float = (int(outing.bin_index) + 1) * bin_length
		var crossing: float = old_time + _dt() * clampf((gate - old_distance) / maxf(0.000001, float(outing.progress_m) - old_distance), 0, 1)
		var velocity: float = bin_length / maxf(0.000001, crossing - float(outing.bin_start))
		var target := _target_speed(gate - 0.001)
		outing.scores.append(clampf(1.0 - absf(velocity - target) / target, 0, 1))
		outing.bin_start = crossing
		outing.bin_index += 1
	outing.score = _pace_score()
	if outing.progress_m >= _route_length() or outing.seconds >= float(_config.outing.duration_seconds): _finish_run()

func _finish_run() -> void:
	_state.outing.active = false
	_state.outing.finished = float(_state.outing.progress_m) >= _route_length()
	if not _state.outing.practice:
		_state.formal_result = {"score": _pace_score(), "finished": _state.outing.finished, "seconds": _state.outing.seconds}
	_state.move = [0.0, 0.0]
	_feedback("本次配速 %d 分。你可以继续聊天，或回馆营业。" % _pace_score())

func _pace_score() -> int:
	var total := 0.0
	for score in _state.outing.scores: total += float(score)
	return roundi(100.0 * total / float(_config.outing.scoring_bin_count))

func _move_coach() -> void:
	var pos := _vec(_state.coach)
	var next := pos + _vec(_state.move) * float(_config.gym.coach_walk_cells_per_second) * _dt()
	var grid = _orch.grid_system
	var cell := Vector2i(floori(next.x), floori(next.y))
	if grid.is_in_bounds(cell) and not grid.is_solid(cell):
		_state.coach = [next.x, next.y]

func _restore_layout() -> void:
	_orch.placement_system.on_cancel()
	for placed in _orch.grid_system.get_placed_instances():
		var is_fixture := false
		for fixture in _fixture.equipment:
			if placed.instance_id == int(fixture.instance_id) and placed.equipment_id == str(fixture.equipment_id):
				is_fixture = true
				break
		if not is_fixture:
			_state.stored.append({"id": placed.instance_id, "equipment_id": placed.equipment_id, "anchor": [placed.anchor.x, placed.anchor.y], "rotation": placed.rotation, "level": _orch.grid_system.get_equipment_level(placed.instance_id)})
		_orch.grid_system.clear(placed.instance_id)
	for fixture in _fixture.equipment:
		_place_record(int(fixture.instance_id), str(fixture.equipment_id), _cell(fixture.anchor), int(fixture.rotation), 1)
	_orch.placement_system.rederive_counter()
	_reserve_stored_ids()
	_orch.selection_system.rebuild_mapping()
	_state.coach = _fixture.coach_spawn.duplicate()
	_state.selected_course_id = "course_endurance_intro"
	if _state.has("course") and _state.course is Dictionary:
		_state.course.devices = [0, 1]
		_state.course.course_id = "course_endurance_intro"
	_apply_protection()

func _restore_stored() -> void:
	var remaining: Array = []
	for stored in _state.stored:
		var definition = _orch.equipment_catalog.get_definition(str(stored.equipment_id))
		var check = _orch.grid_system.can_place(definition.footprint_cells, definition.access_cells, _cell(stored.anchor), int(stored.rotation))
		if check.valid:
			_place_record(int(stored.id), str(stored.equipment_id), _cell(stored.anchor), int(stored.rotation), int(stored.level))
		else:
			remaining.append(stored)
	_state.stored = remaining
	_orch.placement_system.rederive_counter()
	_reserve_stored_ids()
	_orch.selection_system.rebuild_mapping()

func _place_record(id: int, equipment: String, anchor: Vector2i, rotation: int, level: int) -> void:
	var definition = _orch.equipment_catalog.get_definition(equipment)
	var shape = _orch.grid_system.get_transformed_cells(definition.footprint_cells, definition.access_cells, anchor, rotation)
	_orch.grid_system.commit(id, shape.footprint_cells, shape.access_cells, rotation, equipment)
	_orch.grid_system.set_equipment_level(id, level)

func _reserve_stored_ids() -> void:
	var ids: Array = []
	for stored in _state.stored: ids.append(int(stored.id))
	_orch.placement_system.reserve_instance_ids(ids)

func _apply_protection() -> void:
	_orch.selection_system.protected_instances = [0, 1]
	_reserve_stored_ids()

func _change_phase(next: String) -> void:
	_state.phase = next
	_state.move = [0.0, 0.0]
	phase_changed.emit(next)

func _event(id: String) -> void:
	if not _state.events.has(id): _state.events.append(id)

func _feedback(message: String) -> void:
	_state.feedback.append(message)
	if _state.feedback.size() > 5: _state.feedback.pop_front()

func _route_segment(distance: float) -> int:
	var total := 0.0
	for i in _config.outing.segment_length_meters.size():
		total += float(_config.outing.segment_length_meters[i])
		if distance < total or i == _config.outing.segment_length_meters.size() - 1: return i
	return 0

func _route_position(distance: float) -> Array:
	var index := _route_segment(distance)
	var before := 0.0
	for i in index: before += float(_config.outing.segment_length_meters[i])
	var point := _vec(_config.outing.route_points[index]).lerp(_vec(_config.outing.route_points[index + 1]), clampf((distance - before) / float(_config.outing.segment_length_meters[index]), 0, 1))
	return [point.x, point.y]

func _target_speed(distance: float) -> float:
	return float(_config.outing.segment_target_mps[_route_segment(distance)])

func _route_length() -> float:
	var total := 0.0
	for length in _config.outing.segment_length_meters: total += float(length)
	return total

func _dt() -> float: return float(_config.day.tick_seconds)
func _ticks(seconds: Variant) -> int: return roundi(float(seconds) / _dt())
func _vec(pair: Array) -> Vector2: return Vector2(float(pair[0]), float(pair[1]))
func _cell(pair: Array) -> Vector2i: return Vector2i(int(pair[0]), int(pair[1]))
func _number(value: Variant) -> bool: return (value is int or value is float) and is_finite(float(value))
func _pair(value: Variant) -> bool: return value is Array and value.size() == 2 and _number(value[0]) and _number(value[1])
func _error(message: String) -> Dictionary: return {"ok": false, "errors": [message]}
