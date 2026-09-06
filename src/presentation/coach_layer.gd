# src/presentation/coach_layer.gd — 社区故事主角（程教练）渲染层
#
# Story: GA-004
# ADR:   ADR-0011 §8（WorldCanvas 保持画健身房，独立 CoachLayer 画主角）
#
# 职责：
#   1. 读取 DayCycleSystem 视口状态（coach.position / coach.direction）
#   2. 在低分辨率世界画布（SubViewport 426×240）中，使用统一 oblique 投影
#      绘制程教练（青绿外套、脚底暗色接触影、朝向与动作指示）
#   3. 在 SERVICE 阶段当附近会员有指导请求时绘制「E 指导」提示气泡
#
extends Node2D

const Proj2D := preload("res://src/presentation/oblique_projection.gd")
const UiTheme := preload("res://src/ui/ui_theme.gd")

var _view_provider: Callable
var _cell_size: int = 32
var _font: Font


func init(view_provider: Callable, cell_size: int = 32) -> void:
	_view_provider = view_provider
	_cell_size = cell_size
	_font = UiTheme.cjk_bold_font()


func _draw() -> void:
	if not _view_provider.is_valid():
		return
	var view: Dictionary = _view_provider.call()
	if view.is_empty() or str(view.get("phase", "")) == "OUTING":
		return

	var coach: Dictionary = view.get("coach", {})
	var pos: Array = coach.get("position", [5.0, 5.0])
	var dir: Array = coach.get("direction", [0.0, 0.0])
	var flat_pos := Vector2(
		float(pos[0]) * _cell_size + _cell_size * 0.5,
		float(pos[1]) * _cell_size + _cell_size * 0.5
	)

	# 1. 脚底贴地接触影与微光池（贴地 Transform）
	draw_set_transform_matrix(Proj2D.floor_transform())
	draw_ellipse(flat_pos, 7.0, 4.0, Color(1.0, 0.95, 0.8, 0.16))
	draw_ellipse(flat_pos, 5.5, 3.2, Color(0.08, 0.1, 0.12, 0.55))
	draw_set_transform_matrix(Transform2D.IDENTITY)

	# 2. 2.5D 角色形态（程教练：青绿外套、深色运动裤、发型）
	var base_p := Proj2D.proj(flat_pos.x, flat_pos.y, 0.0)
	var head_p := Proj2D.proj(flat_pos.x, flat_pos.y, 25.0)
	var torso_p := Proj2D.proj(flat_pos.x, flat_pos.y, 11.0)
	var facing_left := float(dir[0]) < -0.01

	# 鞋子
	draw_rect(Rect2(base_p.x - 3.5, base_p.y - 2, 3, 2), Color("26282e"))
	draw_rect(Rect2(base_p.x + 0.5, base_p.y - 2, 3, 2), Color("26282e"))

	# 运动长裤
	draw_rect(Rect2(base_p.x - 3.5, base_p.y - 10, 3, 8), Color("1e2229"))
	draw_rect(Rect2(base_p.x + 0.5, base_p.y - 10, 3, 8), Color("1e2229"))

	# 青绿外套躯干（V3 美术规格：主角青绿外套 Color("2e7d6b")）
	draw_rect(Rect2(torso_p.x - 5, torso_p.y - 10, 10, 10), Color("2e7d6b"))
	# 拉链线条 / 衣领
	draw_rect(Rect2(torso_p.x - 0.5, torso_p.y - 9, 1, 9), Color("5ec4a8"))
	draw_rect(Rect2(torso_p.x - 3, torso_p.y - 11, 6, 2), Color("245e50"))

	# 手臂 / 袖子
	var arm_x := (torso_p.x - 6.5) if facing_left else (torso_p.x + 4.5)
	draw_rect(Rect2(arm_x, torso_p.y - 8, 2, 8), Color("245e50"))

	# 面部与发型
	draw_rect(Rect2(head_p.x - 3.5, head_p.y - 7, 7, 7), Color("dfa77e"))
	# 眼睛
	var eye_x := (head_p.x - 1.5) if facing_left else (head_p.x + 0.5)
	draw_rect(Rect2(eye_x, head_p.y - 4, 1, 1), Color("1a1818"))
	# 头发
	draw_rect(Rect2(head_p.x - 4, head_p.y - 9, 8, 4), Color("221a18"))
	draw_rect(Rect2(head_p.x - 4, head_p.y - 8, 2, 4), Color("221a18"))

	# 3. SERVICE 阶段会员指导请求提示
	var req: Dictionary = view.get("request", {})
	if not req.is_empty():
		var stage: String = str(req.get("status", ""))
		if stage in ["waiting", "choice", "timing"]:
			var tip := "E 指导" if stage == "waiting" else ("1/2/3 选择" if stage == "choice" else "E 踩节奏")
			var bubble_w := 38.0
			var bubble_rect := Rect2(head_p.x - bubble_w * 0.5, head_p.y - 19, bubble_w, 11)
			draw_rect(bubble_rect, Color(0.1, 0.14, 0.18, 0.88), true)
			draw_rect(bubble_rect, Color("5ec4a8"), false, 1.0)
			if _font != null:
				draw_string(_font, Vector2(bubble_rect.position.x + 2, bubble_rect.position.y + 8), tip, HORIZONTAL_ALIGNMENT_CENTER, -1, 8, Color("ffffff"))
