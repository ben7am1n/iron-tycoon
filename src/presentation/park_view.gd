# src/presentation/park_view.gd — 公园挑战与探索渲染层（OUTING 阶段）
#
# Story: GA-004
# ADR:   ADR-0011 §8（独立 park view 渲染路线、主角移动、配速反馈与阿洛）
#
# 职责：
#   1. 读取 DayCycleSystem 视口状态（outing.position / progress_m / pace / stamina / score）
#   2. 在低分辨率世界画布（SubViewport 426×240）中绘制公园草坪、跑道与检查点
#   3. 绘制阿洛（砖红服装、民谣吉他）并显示交流状态
#   4. 绘制程教练在跑道上的位置、体力条与配速标识
#
extends Node2D

const UiTheme := preload("res://src/ui/ui_theme.gd")

var _view_provider: Callable
var _config: Dictionary
var _font: Font

const SCALE_M := 2.6
const ORIGIN := Vector2(48.0, 48.0)


func init(view_provider: Callable, config: Dictionary = {}) -> void:
	_view_provider = view_provider
	_config = config
	_font = UiTheme.cjk_bold_font()


func _m_to_p(meter_pos: Vector2) -> Vector2:
	return ORIGIN + meter_pos * SCALE_M


func _draw() -> void:
	if not _view_provider.is_valid():
		return
	var view: Dictionary = _view_provider.call()
	if view.is_empty() or str(view.get("phase", "")) != "OUTING":
		return

	var outing: Dictionary = view.get("outing", {})
	var story: Dictionary = view.get("story", {})
	var events: Array = story.get("events", [])

	# 1. 公园草坪底色与边缘灌木环境
	draw_rect(Rect2(-20, -20, 460, 360), Color("2b4e33"))
	# 装饰性微色差草丛斑块
	draw_rect(Rect2(10, 10, 80, 24), Color("345c3c"))
	draw_rect(Rect2(200, 20, 120, 30), Color("345c3c"))
	draw_rect(Rect2(20, 140, 90, 40), Color("345c3c"))
	draw_rect(Rect2(220, 140, 100, 40), Color("345c3c"))
	draw_rect(Rect2(50, 240, 280, 50), Color("24432c"))

	# 边缘树冠剪影（低分辨率色块）
	for tree_x in [30, 80, 200, 260, 320, 370]:
		draw_circle(Vector2(tree_x, 12), 16, Color("1f3b25"))
	for tree_y in [90, 160, 230]:
		draw_circle(Vector2(12, tree_y), 14, Color("1f3b25"))
		draw_circle(Vector2(398, tree_y), 14, Color("1f3b25"))

	# 2. 跑道（三段折线路径：(0,0) → (36,0) → (36,60) → (108,60)）
	var p0 := _m_to_p(Vector2(0, 0))       # (48, 48)
	var p1 := _m_to_p(Vector2(36, 0))      # (141.6, 48)
	var p2 := _m_to_p(Vector2(36, 60))     # (141.6, 204)
	var p3 := _m_to_p(Vector2(108, 60))    # (328.8, 204)

	var track_w := 22.0
	var track_color := Color("964e3c")     # 砖红塑胶跑道
	var border_color := Color("dedede")    # 白色跑道边线

	# 绘制三段跑道主体
	draw_line(p0, p1, track_color, track_w)
	draw_line(p1, p2, track_color, track_w)
	draw_line(p2, p3, track_color, track_w)
	# 拐角平滑连接
	draw_circle(p1, track_w * 0.5, track_color)
	draw_circle(p2, track_w * 0.5, track_color)

	# 跑道边线（两侧白色标线）
	var half_w := track_w * 0.5
	draw_line(p0 + Vector2(0, -half_w), p1 + Vector2(0, -half_w), border_color, 1.2)
	draw_line(p0 + Vector2(0, half_w), p1 + Vector2(-half_w, half_w), border_color, 1.2)
	draw_line(p1 + Vector2(half_w, -half_w), p2 + Vector2(half_w, half_w), border_color, 1.2)
	draw_line(p1 + Vector2(-half_w, half_w), p2 + Vector2(-half_w, -half_w), border_color, 1.2)
	draw_line(p2 + Vector2(-half_w, -half_w), p3 + Vector2(0, -half_w), border_color, 1.2)
	draw_line(p2 + Vector2(half_w, half_w), p3 + Vector2(0, half_w), border_color, 1.2)

	# 3. 检查点与路段门禁标示
	_draw_gate(p0, Vector2(0, 1), "起点 0m", Color("ffffff"))
	_draw_gate(p1, Vector2(1, 0), "36m · 慢跑 (2.0m/s)", Color("f2cb55"))
	_draw_gate(p2, Vector2(0, 1), "96m · 冲刺 (2.4m/s)", Color("e87a54"))
	_draw_gate(p3, Vector2(0, 1), "终点 168m", Color("48c78e"))

	# 4. 阿洛（砖红服装、吉他、路边观察）
	var aluo_pos := p1 + Vector2(24, 18)
	draw_ellipse(aluo_pos + Vector2(0, 4), 6.5, 3.5, Color(0, 0, 0, 0.45))
	# 身体（砖红上衣 Color("a64336")、深色裤子）
	draw_rect(Rect2(aluo_pos.x - 3, aluo_pos.y - 12, 3, 9), Color("1e2026"))
	draw_rect(Rect2(aluo_pos.x + 0.5, aluo_pos.y - 12, 3, 9), Color("1e2026"))
	draw_rect(Rect2(aluo_pos.x - 4.5, aluo_pos.y - 20, 9, 9), Color("a64336"))
	# 木吉他
	draw_rect(Rect2(aluo_pos.x - 8, aluo_pos.y - 17, 4, 7), Color("c78248"))
	draw_rect(Rect2(aluo_pos.x - 7, aluo_pos.y - 21, 2, 4), Color("8f562b"))
	# 头与微卷发
	draw_rect(Rect2(aluo_pos.x - 3.5, aluo_pos.y - 26, 7, 6), Color("e2b08b"))
	draw_rect(Rect2(aluo_pos.x - 4, aluo_pos.y - 29, 8, 4), Color("3d2c29"))
	# 阿洛姓名与互动状态
	var aluo_met: bool = events.has("aluo_met")
	var aluo_tip := "阿洛" if aluo_met else "阿洛 · E 交流"
	var aluo_rect := Rect2(aluo_pos.x - 30, aluo_pos.y - 39, 60, 10)
	draw_rect(aluo_rect, Color(0.12, 0.16, 0.2, 0.82))
	if not aluo_met:
		draw_rect(aluo_rect, Color("e87a54"), false, 1.0)
	if _font != null:
		draw_string(_font, Vector2(aluo_rect.position.x, aluo_rect.position.y + 7.5), aluo_tip, HORIZONTAL_ALIGNMENT_CENTER, 60, 7, Color("ffffff"))

	# 5. 程教练在跑道上的位置（依据 outing.position 逻辑位置绘制）
	var coach_m: Array = outing.get("position", [0.0, 0.0])
	var coach_p := _m_to_p(Vector2(float(coach_m[0]), float(coach_m[1])))
	var pace: String = str(outing.get("pace", "walk"))
	var active_run: bool = bool(outing.get("active", false))

	# 冲刺拖影
	if pace == "sprint" and active_run:
		draw_ellipse(coach_p + Vector2(-6, 3), 6, 3, Color("5ec4a8", 0.35))
		draw_ellipse(coach_p + Vector2(-12, 3), 5, 2.5, Color("5ec4a8", 0.18))

	# 阴影
	draw_ellipse(coach_p + Vector2(0, 3), 6.5, 3.5, Color(0, 0, 0, 0.45))
	# 双腿与鞋
	draw_rect(Rect2(coach_p.x - 3, coach_p.y - 11, 3, 8), Color("1e2229"))
	draw_rect(Rect2(coach_p.x + 0.5, coach_p.y - 11, 3, 8), Color("1e2229"))
	# 青绿外套躯干
	draw_rect(Rect2(coach_p.x - 4.5, coach_p.y - 19, 9, 9), Color("2e7d6b"))
	draw_rect(Rect2(coach_p.x - 0.5, coach_p.y - 18, 1, 8), Color("5ec4a8"))
	# 头与发
	draw_rect(Rect2(coach_p.x - 3.5, coach_p.y - 25, 7, 6), Color("dfa77e"))
	draw_rect(Rect2(coach_p.x - 4, coach_p.y - 28, 8, 4), Color("221a18"))

	# 体力条
	var stamina := float(outing.get("stamina", 100.0))
	var stamina_pct := clampf(stamina / 100.0, 0.0, 1.0)
	var bar_w := 26.0
	var bar_rect := Rect2(coach_p.x - bar_w * 0.5, coach_p.y - 32, bar_w, 3.5)
	draw_rect(bar_rect, Color(0.1, 0.1, 0.12, 0.75))
	var fill_color := Color("48c78e") if stamina > 40 else (Color("f2cb55") if stamina > 20 else Color("e04b4b"))
	draw_rect(Rect2(bar_rect.position.x + 0.5, bar_rect.position.y + 0.5, (bar_w - 1.0) * stamina_pct, 2.5), fill_color)

	# 配速标签
	var pace_name: String = str({"walk": "走", "jog": "慢跑", "sprint": "冲刺"}.get(pace, "走"))
	var badge_w := 24.0
	var badge_rect := Rect2(coach_p.x - badge_w * 0.5, coach_p.y - 42, badge_w, 8.5)
	draw_rect(badge_rect, Color(0.1, 0.15, 0.22, 0.85))
	if _font != null:
		draw_string(_font, Vector2(badge_rect.position.x, badge_rect.position.y + 6.5), pace_name, HORIZONTAL_ALIGNMENT_CENTER, badge_w, 6.5, Color("ffffff"))


func _draw_gate(pos: Vector2, _dir: Vector2, label: String, color: Color) -> void:
	var gate_line_h := 24.0
	draw_line(pos + Vector2(0, -gate_line_h * 0.5), pos + Vector2(0, gate_line_h * 0.5), color, 2.0)
	if _font != null:
		draw_string(_font, pos + Vector2(-30, -gate_line_h * 0.5 - 2), label, HORIZONTAL_ALIGNMENT_CENTER, 60, 7, color)
