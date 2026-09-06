# src/presentation/coach_layer.gd — 社区故事主角（程教练）2.5D 美术与动作渲染层
#
# Story: GA-004 / GA-005 (One room, one coach, two-device visual sample)
# Docs:  docs/plans/2026-09-06-gym-adventure/art-direction.md §3 人物造型与规格
#
# 视觉特征：
#   1. 身份辨识：青绿外套（#2e7d6b）、宽肩体型（肩宽14px，明显宽于普通会员10px）、
#      黑发边缘带清晰银白挑染发丝（#e2e8f0）、深色运动裤与训练鞋。
#   2. 姿态分化（Pose）：
#      - idle（待机）：双脚稳固立地，肩膀微弱呼吸起伏，手臂自然垂于身侧。
#      - walk（行走）：2 阶段迈步动画（前后迈腿、手臂交替摆动），脚底严格贴地对齐。
#      - guidance（指导）：身体微向前倾关注学员，抬手指示节奏或做出握拳手势。
#   3. 朝向切换：四方向正面（DOWN）、背面（UP）、左侧（LEFT）、右侧（RIGHT），
#      绝不使用屏幕空间 2D 旋转，始终保持 2.5D 轴测直立。
#   4. 脚底接触：贴地椭圆阴影与微光池，经 Proj2D.floor_transform() 真实贴地。
#   5. 指导气泡：服务阶段冒出像素边框的 [E 指导] / [1/2/3 选择] / [E 踩节奏]。
#
extends Node2D

const Proj2D := preload("res://src/presentation/oblique_projection.gd")
const UiTheme := preload("res://src/ui/ui_theme.gd")

const POSE_IDLE := "idle"
const POSE_WALK := "walk"
const POSE_GUIDANCE := "guidance"

const DIR_DOWN := "down"
const DIR_UP := "up"
const DIR_LEFT := "left"
const DIR_RIGHT := "right"

const COLOR_JACKET_MAIN := Color("2e7d6b")     # 青绿主色
const COLOR_JACKET_DARK := Color("225f52")     # 外套暗面/侧缝
const COLOR_JACKET_LIGHT := Color("5ec4a8")    # 拉链/反光包边
const COLOR_PANTS := Color("1c2026")           # 深色运动裤
const COLOR_SHOES := Color("26282e")           # 运动鞋
const COLOR_SHOE_TRIM := Color("e2e8f0")       # 鞋底白色包边
const COLOR_SKIN := Color("dfa77e")            # 健康暖肤色
const COLOR_HAIR := Color("221a18")            # 深黑发
const COLOR_SILVER_STREAK := Color("e2e8f0")   # 标志性银白挑染发丝

var _view_provider: Callable
var _cell_size: int = 32
var _tick_provider: Callable
var _font: Font

var _last_dir: String = DIR_DOWN
var _current_pose: String = POSE_IDLE


func init(view_provider: Callable, cell_size: int = 32, tick_provider: Callable = Callable()) -> void:
	_view_provider = view_provider
	_cell_size = cell_size
	_tick_provider = tick_provider
	_font = UiTheme.cjk_bold_font()


func get_current_pose() -> String:
	return _current_pose


func get_current_direction() -> String:
	return _last_dir


func has_silver_streak() -> bool:
	return true


func get_shoulder_width() -> float:
	return 14.0


func is_screen_rotated() -> bool:
	return false


func _draw_ellipse_pts(center: Vector2, rx: float, ry: float, color: Color) -> void:
	var pts := PackedVector2Array()
	for i in 16:
		var a := TAU * float(i) / 16.0
		pts.append(center + Vector2(cos(a) * rx, sin(a) * ry))
	draw_colored_polygon(pts, color)


func update_state() -> void:
	if not _view_provider.is_valid():
		return
	var view: Dictionary = _view_provider.call()
	if view.is_empty():
		return
	var coach: Dictionary = view.get("coach", {})
	var dir: Array = coach.get("direction", [0.0, 0.0])
	var dx: float = float(dir[0])
	var dy: float = float(dir[1])
	var is_moving: bool = (absf(dx) > 0.05 or absf(dy) > 0.05)
	if is_moving:
		if absf(dy) > absf(dx):
			_last_dir = DIR_UP if dy < 0.0 else DIR_DOWN
		else:
			_last_dir = DIR_LEFT if dx < 0.0 else DIR_RIGHT

	var req: Dictionary = view.get("request", {})
	var is_guiding: bool = (not req.is_empty() and str(req.get("status", "")) in ["waiting", "choice", "timing"])
	if is_guiding:
		_current_pose = POSE_GUIDANCE
	elif is_moving:
		_current_pose = POSE_WALK
	else:
		_current_pose = POSE_IDLE


func _draw() -> void:
	if not _view_provider.is_valid():
		return
	var view: Dictionary = _view_provider.call()
	if view.is_empty() or str(view.get("phase", "")) == "OUTING":
		return

	update_state()
	var coach: Dictionary = view.get("coach", {})
	var pos: Array = coach.get("position", [5.0, 5.0])
	var flat_pos := Vector2(
		float(pos[0]) * _cell_size + _cell_size * 0.5,
		float(pos[1]) * _cell_size + _cell_size * 0.5
	)

	var tick: int = 0
	if _tick_provider.is_valid():
		tick = _tick_provider.call()

	# 3. 脚底贴地接触影与微光池（贴地 Transform，确保锚点对齐）
	draw_set_transform_matrix(Proj2D.floor_transform())
	_draw_ellipse_pts(flat_pos, 7.5, 4.2, Color(1.0, 0.95, 0.8, 0.18))
	_draw_ellipse_pts(flat_pos, 5.5, 3.2, Color(0.08, 0.1, 0.12, 0.55))
	draw_set_transform_matrix(Transform2D.IDENTITY)

	# 4. 角色基准高度与投影锚点
	var base_p := Proj2D.proj(flat_pos.x, flat_pos.y, 0.0)
	var breath_offset: float = (sin(float(tick) * 0.2) * 0.6) if _current_pose == POSE_IDLE else 0.0
	var torso_p := Proj2D.proj(flat_pos.x, flat_pos.y, 11.0 + breath_offset)
	var head_p := Proj2D.proj(flat_pos.x, flat_pos.y, 25.0 + breath_offset)

	# 5. 姿态与步态参数
	var walk_phase: int = (tick / 3) % 2 if _current_pose == POSE_WALK else 0
	var step_offset: float = 2.0 if (walk_phase == 1) else -2.0

	# 6. 腿与鞋子（宽站位，宽肩体型）
	if _current_pose == POSE_WALK:
		# 行走：两腿前后迈动，底部紧扣地面基准
		draw_rect(Rect2(base_p.x - 5.0, base_p.y - 11.0, 4.0, 9.0), COLOR_PANTS)
		draw_rect(Rect2(base_p.x + 1.0, base_p.y - 11.0, 4.0, 9.0), COLOR_PANTS)
		draw_rect(Rect2(base_p.x - 5.0 + step_offset, base_p.y - 2.0, 4.0, 2.0), COLOR_SHOES)
		draw_rect(Rect2(base_p.x + 1.0 - step_offset, base_p.y - 2.0, 4.0, 2.0), COLOR_SHOES)
		draw_rect(Rect2(base_p.x - 5.0 + step_offset, base_p.y - 1.0, 4.0, 1.0), COLOR_SHOE_TRIM)
		draw_rect(Rect2(base_p.x + 1.0 - step_offset, base_p.y - 1.0, 4.0, 1.0), COLOR_SHOE_TRIM)
	else:
		# 待机与指导：稳固肩宽立地
		draw_rect(Rect2(base_p.x - 5.0, base_p.y - 11.0, 4.0, 9.0), COLOR_PANTS)
		draw_rect(Rect2(base_p.x + 1.0, base_p.y - 11.0, 4.0, 9.0), COLOR_PANTS)
		draw_rect(Rect2(base_p.x - 5.5, base_p.y - 2.0, 4.5, 2.0), COLOR_SHOES)
		draw_rect(Rect2(base_p.x + 1.0, base_p.y - 2.0, 4.5, 2.0), COLOR_SHOES)
		draw_rect(Rect2(base_p.x - 5.5, base_p.y - 1.0, 4.5, 1.0), COLOR_SHOE_TRIM)
		draw_rect(Rect2(base_p.x + 1.0, base_p.y - 1.0, 4.5, 1.0), COLOR_SHOE_TRIM)

	# 7. 宽肩青绿外套（宽14px，普通会员仅10px）
	var sw: float = get_shoulder_width()
	var sh_rect := Rect2(torso_p.x - sw * 0.5, torso_p.y - 11.0, sw, 11.0)
	draw_rect(sh_rect, COLOR_JACKET_MAIN)

	# 外套侧缝暗影与领口拉链细节
	match _last_dir:
		DIR_DOWN:
			# 正面视角：中间明亮青绿拉链，两侧微深，内搭深色领口
			draw_rect(Rect2(torso_p.x - 1.0, torso_p.y - 10.0, 2.0, 10.0), COLOR_JACKET_LIGHT)
			draw_rect(Rect2(torso_p.x - 2.5, torso_p.y - 11.0, 5.0, 2.0), COLOR_JACKET_DARK)
		DIR_UP:
			# 背面视角：背部倒三角肌肉结构线，无前拉链
			draw_rect(Rect2(torso_p.x - 1.0, torso_p.y - 9.0, 2.0, 8.0), COLOR_JACKET_DARK)
			draw_rect(Rect2(torso_p.x - sw * 0.5, torso_p.y - 2.0, sw, 2.0), COLOR_JACKET_DARK)
		DIR_LEFT:
			# 左侧视角：前胸在左侧突出，后背在右
			draw_rect(Rect2(torso_p.x + 3.0, torso_p.y - 10.0, 3.0, 10.0), COLOR_JACKET_DARK)
			draw_rect(Rect2(torso_p.x - sw * 0.5, torso_p.y - 8.0, 2.0, 7.0), COLOR_JACKET_LIGHT)
		DIR_RIGHT:
			# 右侧视角：前胸在右侧突出，后背在左
			draw_rect(Rect2(torso_p.x - 6.0, torso_p.y - 10.0, 3.0, 10.0), COLOR_JACKET_DARK)
			draw_rect(Rect2(torso_p.x + sw * 0.5 - 2.0, torso_p.y - 8.0, 2.0, 7.0), COLOR_JACKET_LIGHT)

	# 8. 手臂与姿态手势
	if _current_pose == POSE_GUIDANCE:
		# 指导手势：前手臂扬起指示节奏或握拳鼓励
		draw_rect(Rect2(torso_p.x - sw * 0.5 - 2.0, torso_p.y - 8.0, 2.5, 7.0), COLOR_JACKET_DARK)
		# 扬起的右手手臂与拳头
		draw_rect(Rect2(torso_p.x + sw * 0.5 - 1.0, torso_p.y - 13.0, 3.0, 7.0), COLOR_JACKET_MAIN)
		draw_rect(Rect2(torso_p.x + sw * 0.5 - 0.5, torso_p.y - 15.0, 2.5, 3.0), COLOR_SKIN)
	elif _current_pose == POSE_WALK:
		# 行走摆臂
		var arm_l := -step_offset * 1.5
		var arm_r := step_offset * 1.5
		draw_rect(Rect2(torso_p.x - sw * 0.5 - 1.5, torso_p.y - 8.0 + arm_l, 2.0, 7.0), COLOR_JACKET_DARK)
		draw_rect(Rect2(torso_p.x + sw * 0.5 - 0.5, torso_p.y - 8.0 + arm_r, 2.0, 7.0), COLOR_JACKET_DARK)
	else:
		# 待机手臂自然下垂
		draw_rect(Rect2(torso_p.x - sw * 0.5 - 1.5, torso_p.y - 8.0, 2.0, 7.5), COLOR_JACKET_DARK)
		draw_rect(Rect2(torso_p.x + sw * 0.5 - 0.5, torso_p.y - 8.0, 2.0, 7.5), COLOR_JACKET_DARK)
		draw_rect(Rect2(torso_p.x - sw * 0.5 - 1.5, torso_p.y - 0.5, 2.0, 2.0), COLOR_SKIN)
		draw_rect(Rect2(torso_p.x + sw * 0.5 - 0.5, torso_p.y - 0.5, 2.0, 2.0), COLOR_SKIN)

	# 9. 头部、面部与标志性银白挑染发
	var head_w: float = 8.0
	var head_h: float = 8.0
	var head_rect := Rect2(head_p.x - head_w * 0.5, head_p.y - head_h, head_w, head_h)

	if _last_dir == DIR_UP:
		# 背面：全黑后脑勺发型 + 侧边挑染
		draw_rect(head_rect, COLOR_HAIR)
		draw_rect(Rect2(head_p.x + 2.0, head_p.y - 8.0, 2.0, 3.0), COLOR_SILVER_STREAK)
	else:
		# 正面与侧面：面部皮肤 + 眼睛 + 发型
		draw_rect(Rect2(head_p.x - 3.5, head_p.y - 6.5, 7.0, 6.5), COLOR_SKIN)
		# 眼睛与神态
		if _last_dir == DIR_DOWN:
			draw_rect(Rect2(head_p.x - 2.5, head_p.y - 3.5, 1.5, 1.5), Color("1a1818"))
			draw_rect(Rect2(head_p.x + 1.0, head_p.y - 3.5, 1.5, 1.5), Color("1a1818"))
		elif _last_dir == DIR_LEFT:
			draw_rect(Rect2(head_p.x - 2.5, head_p.y - 3.5, 1.5, 1.5), Color("1a1818"))
		elif _last_dir == DIR_RIGHT:
			draw_rect(Rect2(head_p.x + 1.0, head_p.y - 3.5, 1.5, 1.5), Color("1a1818"))

		# 顶部头发
		draw_rect(Rect2(head_p.x - 4.5, head_p.y - 8.5, 9.0, 3.5), COLOR_HAIR)
		draw_rect(Rect2(head_p.x - 4.5, head_p.y - 7.5, 1.5, 3.0), COLOR_HAIR)
		draw_rect(Rect2(head_p.x + 3.0, head_p.y - 7.5, 1.5, 3.0), COLOR_HAIR)

		# 标志性银白挑染发丝（Silver Streak）位于右额/鬓角
		draw_rect(Rect2(head_p.x + 1.5, head_p.y - 8.5, 2.5, 2.0), COLOR_SILVER_STREAK)
		draw_rect(Rect2(head_p.x + 3.0, head_p.y - 6.5, 1.5, 2.0), COLOR_SILVER_STREAK)

	# 10. 指导阶段悬浮提示气泡
	var req: Dictionary = view.get("request", {})
	if _current_pose == POSE_GUIDANCE and not req.is_empty():
		var stage: String = str(req.get("status", ""))
		var tip := "E 指导" if stage == "waiting" else ("1/2/3 选择" if stage == "choice" else "E 踩节奏")
		var bubble_w := 42.0
		var bubble_rect := Rect2(head_p.x - bubble_w * 0.5, head_p.y - 21.0, bubble_w, 11.0)
		draw_rect(bubble_rect, Color(0.1, 0.14, 0.18, 0.90), true)
		draw_rect(bubble_rect, COLOR_JACKET_LIGHT, false, 1.0)
		if _font != null:
			draw_string(_font, Vector2(bubble_rect.position.x + 2, bubble_rect.position.y + 8), tip, HORIZONTAL_ALIGNMENT_CENTER, -1, 8, Color("ffffff"))
