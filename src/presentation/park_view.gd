# src/presentation/park_view.gd — 公园挑战与探索渲染层（OUTING 阶段）
#
# Story: GA-004 / Art Style Remaster (Dave the Diver Quality)
# ADR:   ADR-0011 §8（独立 park view 渲染路线、主角移动、配速反馈与阿洛）
#
# 职责：
#   1. 读取 DayCycleSystem 视口状态（outing.position / progress_m / pace / stamina / score）
#   2. 在低分辨率世界画布（SubViewport 426×240）中绘制具有《潜水员戴夫》质感暮色公园：
#      - 暮色渐变天空、远景林冠与微光街景
#      - 质感塑胶跑道（Tartan 纹理、石质路沿、刻度里程线、棋盘格终点）
#      - 复古公园路灯（黄铜铸铁灯柱、暖光照射光池）
#      - 木质长椅、吉他琴盒与水壶休息角
#   3. 使用原生 32×40 像素图集绘制阿洛与程教练，支持跑道四向行走、慢跑与冲刺拖影
#   4. 高对比度黄铜金边体力条、配速标识与交互气泡
#
extends Node2D

const UiTheme := preload("res://src/ui/ui_theme.gd")
const CommunityCharacterArt := preload("res://src/presentation/community_character_art.gd")

var _view_provider: Callable
var _config: Dictionary
var _font: Font
var _char_art: CommunityCharacterArt = null

const SCALE_M := 2.2
const ORIGIN := Vector2(44.0, 56.0)

# 调色盘（《潜水员戴夫》暮色户外风格）
const C_SKY_TOP := Color("#141829")       # 深暮色夜幕蓝
const C_SKY_HORIZON := Color("#7c3a27")   # 晚霞暮光橙褐
const C_HAZE := Color("#b45309", 0.18)     # 暖霞雾气
const C_GRASS_BASE := Color("#1c3b24")    # 草坪深基色
const C_GRASS_MID := Color("#234a2d")     # 草坪中调
const C_GRASS_LIGHT := Color("#2c5936")   # 草坪受光面
const C_TREE_BACK := Color("#132719")     # 远景树木剪影
const C_TREE_MID := Color("#1c3824")      # 中景树冠
const C_TREE_FRONT := Color("#254c31")    # 近景树枝高光

const C_TRACK_SURFACE := Color("#8c3b2d") # 塑胶跑道砖红面
const C_TRACK_SHADOW := Color("#69291e")  # 跑道暗部
const C_TRACK_HIGHLIGHT := Color("#a84938")# 跑道受光微纹理
const C_STONE_CURB := Color("#475569")    # 石材路沿
const C_STONE_LIGHT := Color("#64748b")   # 石材高光
const C_LINE_WHITE := Color("#f1f5f9")    # 跑道标线暖白

const C_LAMP_IRON := Color("#1e2430")     # 路灯铸铁
const C_LAMP_GLOW := Color("#fbbf24")     # 暖黄灯芯
const C_LIGHT_POOL := Color("#f59e0b", 0.15) # 地面微暖光池

const C_CARD_BG := Color("#121a26", 0.92) # 戴夫风格深靛蓝底板
const C_BRASS_BORDER := Color("#dca83d")  # 黄铜金边
const C_BRASS_DARK := Color("#85581a")    # 暗黄铜边框底


func init(view_provider: Callable, config: Dictionary = {}) -> void:
	_view_provider = view_provider
	_config = config
	_font = UiTheme.cjk_bold_font()
	if _char_art == null:
		_char_art = CommunityCharacterArt.new()


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
	var day: int = int(view.get("day", 1))

	# 跑道关键点 (0,0) → (36,0) → (36,60) → (108,60)
	var p0 := _m_to_p(Vector2(0, 0))
	var p1 := _m_to_p(Vector2(36, 0))
	var p2 := _m_to_p(Vector2(36, 60))
	var p3 := _m_to_p(Vector2(108, 60))

	# 1. 绘制暮色背景与自然环境
	_draw_dusk_atmosphere()
	_draw_park_terrain()

	# 2. 绘制路灯光池（在跑道与草坪上）
	_draw_lamp_light_pools([p0 + Vector2(-16, -14), p1 + Vector2(14, -14), p2 + Vector2(-16, 14), p3 + Vector2(16, -14)])

	# 3. 绘制质感 Tartan 塑胶跑道
	_draw_tartan_track(p0, p1, p2, p3)

	# 4. 绘制检查点门禁牌坊与里程标
	_draw_checkpoints(p0, p1, p2, p3)

	# 5. 绘制公园陈设（长椅、吉他盒、水站、路灯实体）
	var aluo_pos := p1 + Vector2(36, 18)
	_draw_park_props(aluo_pos, [p0 + Vector2(-16, -14), p1 + Vector2(14, -14), p2 + Vector2(-16, 14), p3 + Vector2(16, -14)])

	# 6. 绘制阿洛（原生 32x40 精灵 + 交流状态）
	_draw_aluo(aluo_pos, events)

	# 7. 绘制程教练（原生 32x40 精灵 + 跑步姿态 + 体力/配速卡片）
	_draw_coach(outing)


## 绘制暮色天空渐变与天际线树影
func _draw_dusk_atmosphere() -> void:
	# 视口顶端暮色天际（y: -20 .. 42）
	var sky_h := 62.0
	for y in range(-20, int(sky_h)):
		var t := clampf((float(y) + 20.0) / (sky_h + 20.0), 0.0, 1.0)
		var c := C_SKY_TOP.lerp(C_SKY_HORIZON, t)
		draw_line(Vector2(-20, y), Vector2(460, y), c, 1.0)

	# 远景地平线柔和晚霞光雾
	draw_rect(Rect2(-20, 28, 480, 20), C_HAZE)

	# 远景深色树冠剪影（波浪形轮廓）
	var tree_xs := [-10, 25, 65, 105, 150, 195, 240, 285, 330, 375, 420, 455]
	for tx in tree_xs:
		draw_circle(Vector2(tx, 34), 22, C_TREE_BACK)
		draw_circle(Vector2(tx + 8, 38), 18, C_TREE_MID)
		draw_circle(Vector2(tx + 4, 39), 12, C_TREE_FRONT)


## 绘制分层草坪与地面质感
func _draw_park_terrain() -> void:
	# 草坪基底
	draw_rect(Rect2(-20, 42, 480, 300), C_GRASS_BASE)

	# 自然草皮斑块与深浅条带（破除单调纯色）
	var patches := [
		Rect2(0, 48, 120, 32), Rect2(180, 46, 160, 40), Rect2(360, 52, 90, 35),
		Rect2(15, 105, 100, 55), Rect2(170, 95, 130, 80), Rect2(330, 110, 110, 65),
		Rect2(-10, 180, 130, 90), Rect2(150, 220, 180, 60), Rect2(350, 225, 95, 55)
	]
	for r in patches:
		draw_rect(r, C_GRASS_MID)
		# 内部微高光草丛点缀
		draw_rect(Rect2(r.position.x + 8, r.position.y + 6, r.size.x - 16, r.size.y - 12), C_GRASS_LIGHT)

	# 草坪细碎自然纹理点
	var dots := [
		Vector2(20, 75), Vector2(85, 90), Vector2(210, 85), Vector2(380, 95),
		Vector2(25, 150), Vector2(70, 165), Vector2(250, 175), Vector2(300, 160),
		Vector2(40, 220), Vector2(100, 235), Vector2(270, 240), Vector2(390, 215)
	]
	for pt in dots:
		draw_rect(Rect2(pt.x, pt.y, 3, 2), Color("#386b43"))
		draw_rect(Rect2(pt.x + 4, pt.y + 1, 2, 2), Color("#fef08a", 0.65)) # 微小野花点缀

	# 右侧与下边缘树木景深
	for ty in [95, 165, 235]:
		draw_circle(Vector2(6, ty), 16, C_TREE_BACK)
		draw_circle(Vector2(10, ty + 2), 12, C_TREE_MID)
		draw_circle(Vector2(420, ty), 18, C_TREE_BACK)
		draw_circle(Vector2(414, ty + 2), 14, C_TREE_MID)


## 绘制路灯地面暖光池
func _draw_lamp_light_pools(lamps: Array) -> void:
	for lamp_pos in lamps:
		# 椭圆受光面
		var pool_center: Vector2 = lamp_pos + Vector2(0, 22)
		draw_ellipse(pool_center, 30, 16, C_LIGHT_POOL)
		draw_ellipse(pool_center, 18, 9, Color("#fde68a", 0.22))
		draw_ellipse(pool_center, 8, 4, Color("#ffffff", 0.30))


## 绘制质感 Tartan 塑胶跑道
func _draw_tartan_track(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2) -> void:
	var track_w := 24.0
	var half_w := track_w * 0.5
	var curb_w := 2.0

	# 1. 石材路沿底层（比跑道稍宽，形成外包边）
	var total_w := track_w + curb_w * 2.0
	draw_line(p0, p1, C_STONE_CURB, total_w)
	draw_line(p1, p2, C_STONE_CURB, total_w)
	draw_line(p2, p3, C_STONE_CURB, total_w)
	draw_circle(p1, total_w * 0.5, C_STONE_CURB)
	draw_circle(p2, total_w * 0.5, C_STONE_CURB)

	# 2. 跑道塑胶底层暗面
	draw_line(p0, p1, C_TRACK_SHADOW, track_w)
	draw_line(p1, p2, C_TRACK_SHADOW, track_w)
	draw_line(p2, p3, C_TRACK_SHADOW, track_w)
	draw_circle(p1, half_w, C_TRACK_SHADOW)
	draw_circle(p2, half_w, C_TRACK_SHADOW)

	# 3. 跑道塑胶主体红面（内缩 1px，露出立体下边缘）
	var inner_w := track_w - 2.0
	draw_line(p0 + Vector2(0, -1), p1 + Vector2(0, -1), C_TRACK_SURFACE, inner_w)
	draw_line(p1 + Vector2(-1, 0), p2 + Vector2(-1, 0), C_TRACK_SURFACE, inner_w)
	draw_line(p2 + Vector2(0, -1), p3 + Vector2(0, -1), C_TRACK_SURFACE, inner_w)
	draw_circle(p1 + Vector2(-0.5, -0.5), inner_w * 0.5, C_TRACK_SURFACE)
	draw_circle(p2 + Vector2(-0.5, -0.5), inner_w * 0.5, C_TRACK_SURFACE)

	# 4. 石材路沿受光高光线（北面与西面高光）
	draw_line(p0 + Vector2(0, -half_w - 1.5), p1 + Vector2(0, -half_w - 1.5), C_STONE_LIGHT, 1.2)
	draw_line(p1 + Vector2(-half_w - 1.5, 0), p2 + Vector2(-half_w - 1.5, 0), C_STONE_LIGHT, 1.2)
	draw_line(p2 + Vector2(0, -half_w - 1.5), p3 + Vector2(0, -half_w - 1.5), C_STONE_LIGHT, 1.2)

	# 5. 跑道白色边线
	draw_line(p0 + Vector2(0, -half_w + 1), p1 + Vector2(0, -half_w + 1), C_LINE_WHITE, 1.0)
	draw_line(p0 + Vector2(0, half_w - 1), p1 + Vector2(-half_w, half_w - 1), C_LINE_WHITE, 1.0)
	draw_line(p1 + Vector2(half_w - 1, 0), p2 + Vector2(half_w - 1, 0), C_LINE_WHITE, 1.0)
	draw_line(p1 + Vector2(-half_w + 1, 0), p2 + Vector2(-half_w + 1, 0), C_LINE_WHITE, 1.0)
	draw_line(p2 + Vector2(0, half_w - 1), p3 + Vector2(0, half_w - 1), C_LINE_WHITE, 1.0)
	draw_line(p2 + Vector2(0, -half_w + 1), p3 + Vector2(0, -half_w + 1), C_LINE_WHITE, 1.0)

	# 6. 中间虚线车道线（更具跑道专业感）
	_draw_dashed_line(p0 + Vector2(10, 0), p1 + Vector2(-10, 0), C_LINE_WHITE, 1.0, 6.0, 6.0)
	_draw_dashed_line(p1 + Vector2(0, 10), p2 + Vector2(0, -10), C_LINE_WHITE, 1.0, 6.0, 6.0)
	_draw_dashed_line(p2 + Vector2(10, 0), p3 + Vector2(-14, 0), C_LINE_WHITE, 1.0, 6.0, 6.0)

	# 7. 终点棋盘格线 (p3)
	for i in 6:
		var cy := p3.y - half_w + 2.0 + float(i) * 3.4
		var color := Color("#f8fafc") if i % 2 == 0 else Color("#1e293b")
		draw_rect(Rect2(p3.x - 4, cy, 4, 3.4), color)
		color = Color("#1e293b") if i % 2 == 0 else Color("#f8fafc")
		draw_rect(Rect2(p3.x, cy, 4, 3.4), color)


func _draw_dashed_line(from: Vector2, to: Vector2, color: Color, width: float, dash: float, gap: float) -> void:
	var dir := (to - from).normalized()
	var dist := from.distance_to(to)
	var curr := 0.0
	while curr < dist:
		var p_start := from + dir * curr
		var seg_len := minf(dash, dist - curr)
		var p_end := p_start + dir * seg_len
		draw_line(p_start, p_end, color, width)
		curr += dash + gap


## 绘制各里程检查点标示牌
func _draw_checkpoints(p0: Vector2, p1: Vector2, p2: Vector2, p3: Vector2) -> void:
	_draw_checkpoint_gate(p0 + Vector2(0, -18), "0m 起点", Color("#ffffff"), 46.0)
	_draw_checkpoint_gate(p1 + Vector2(-46, 32), "36m · 慢跑 2.0m/s", Color("#f2cb55"), 62.0)
	_draw_checkpoint_gate(p2 + Vector2(-46, -20), "96m · 冲刺 2.4m/s", Color("#e87a54"), 62.0)
	_draw_checkpoint_gate(p3 + Vector2(0, -18), "168m · 终点", Color("#48c78e"), 50.0)


func _draw_checkpoint_gate(pos: Vector2, label: String, accent_col: Color, txt_w: float = 56.0) -> void:
	# 立地标桩
	var gate_h := 16.0
	draw_line(pos + Vector2(0, 0), pos + Vector2(0, gate_h), Color("#1e2430"), 2.5)
	draw_line(pos, pos + Vector2(0, gate_h), accent_col, 1.2)

	# 顶部标示卡（深蓝底金边，戴夫风格）
	var card_rect := Rect2(pos.x - txt_w * 0.5, pos.y - 10.0, txt_w, 10.0)
	draw_rect(card_rect, C_CARD_BG)
	draw_rect(card_rect, C_BRASS_BORDER, false, 1.0)
	# 四角铜铆钉
	draw_rect(Rect2(card_rect.position.x, card_rect.position.y, 1, 1), Color("#ffffff"))
	draw_rect(Rect2(card_rect.position.x + card_rect.size.x - 1, card_rect.position.y, 1, 1), Color("#ffffff"))

	if _font != null:
		draw_string(_font, Vector2(card_rect.position.x, card_rect.position.y + 7.5), label, HORIZONTAL_ALIGNMENT_CENTER, txt_w, 6.0, accent_col)


## 绘制公园陈设（复古路灯、长椅、水壶）
func _draw_park_props(aluo_pos: Vector2, lamp_positions: Array) -> void:
	# 1. 复古路灯
	for lp in lamp_positions:
		# 灯柱
		draw_line(lp + Vector2(0, 18), lp + Vector2(0, 0), C_LAMP_IRON, 2.5)
		draw_line(lp + Vector2(0, 18), lp + Vector2(0, 0), Color("#475569"), 1.0)
		# 柱底基座
		draw_rect(Rect2(lp.x - 3, lp.y + 17, 7, 3), C_LAMP_IRON)
		# 顶部灯笼架
		draw_rect(Rect2(lp.x - 4, lp.y - 4, 9, 5), C_LAMP_IRON)
		# 发光灯胆
		draw_rect(Rect2(lp.x - 2, lp.y - 3, 5, 4), C_LAMP_GLOW)
		draw_rect(Rect2(lp.x - 1, lp.y - 2, 3, 2), Color("#ffffff"))
		# 尖顶盖
		draw_line(lp + Vector2(-5, -4), lp + Vector2(5, -4), C_LAMP_IRON, 1.5)
		draw_line(lp + Vector2(0, -7), lp + Vector2(0, -4), C_LAMP_IRON, 1.5)

	# 2. 阿洛旁边的木质长椅
	var bench_x := aluo_pos.x - 28.0
	var bench_y := aluo_pos.y - 4.0
	# 铁质椅脚
	draw_rect(Rect2(bench_x, bench_y + 10, 3, 8), Color("#2d3748"))
	draw_rect(Rect2(bench_x + 18, bench_y + 10, 3, 8), Color("#2d3748"))
	# 木质椅面
	draw_rect(Rect2(bench_x - 2, bench_y + 8, 25, 4), Color("#9a3412"))
	draw_rect(Rect2(bench_x - 2, bench_y + 9, 25, 1), Color("#ea580c"))
	# 木质靠背
	draw_rect(Rect2(bench_x - 2, bench_y + 2, 25, 4), Color("#9a3412"))
	draw_rect(Rect2(bench_x - 2, bench_y + 3, 25, 1), Color("#ea580c"))

	# 3. 靠在长椅旁的民谣吉他琴盒
	draw_rect(Rect2(bench_x + 22, bench_y + 1, 6, 17), Color("#1e2026"))
	draw_rect(Rect2(bench_x + 23, bench_y + 2, 4, 15), Color("#5c3a21"))
	draw_rect(Rect2(bench_x + 24, bench_y + 5, 2, 4), Color("#dca83d")) # 铜搭扣

	# 4. 运动水杯
	draw_rect(Rect2(bench_x + 12, bench_y + 4, 3, 5), Color("#0284c7"))
	draw_rect(Rect2(bench_x + 12, bench_y + 3, 3, 1), Color("#e2e8f0"))


## 绘制阿洛（32x40 原生像素精灵 + 戴夫风格交互气泡）
func _draw_aluo(aluo_pos: Vector2, events: Array) -> void:
	# 双层柔和接地阴影
	draw_ellipse(aluo_pos + Vector2(0, 1), 9.0, 4.0, Color(0, 0, 0, 0.35))
	draw_ellipse(aluo_pos + Vector2(0, 1), 5.0, 2.5, Color(0, 0, 0, 0.50))

	# 原生精灵
	if _char_art != null:
		var tex: Texture2D = _char_art.get_member_texture("singer_aluo", "idle", 0, false)
		if tex != null:
			# 32x40 锚点在脚底中心 (16, 38)
			var sprite_pos := aluo_pos - Vector2(16.0, 38.0)
			draw_texture(tex, sprite_pos)

	# 怀抱木吉他（演出与驻唱辨识物）
	var g_pos := aluo_pos + Vector2(-6, -18)
	draw_rect(Rect2(g_pos.x - 4, g_pos.y - 1, 7, 10), Color("#1a1514"))
	draw_rect(Rect2(g_pos.x - 3, g_pos.y, 5, 8), Color("#c27838"))
	draw_rect(Rect2(g_pos.x - 2, g_pos.y + 2, 3, 4), Color("#7c4217"))
	draw_line(g_pos + Vector2(0, -6), g_pos + Vector2(0, 0), Color("#92400e"), 1.5)

	# 阿洛姓名与互动提示气泡（深蓝底金边，戴夫风格）
	var aluo_met: bool = events.has("aluo_met")
	var tip_text := "阿洛 ♪" if aluo_met else "阿洛 · E 交流"
	var tip_w := 64.0 if not aluo_met else 40.0
	var tip_rect := Rect2(aluo_pos.x - tip_w * 0.5, aluo_pos.y - 43.0, tip_w, 10.0)

	# 气泡阴影与底板
	draw_rect(Rect2(tip_rect.position.x + 1, tip_rect.position.y + 1, tip_w, 10), Color(0, 0, 0, 0.45))
	draw_rect(tip_rect, C_CARD_BG)
	var border_col := Color("#38bdf8") if aluo_met else C_BRASS_BORDER
	draw_rect(tip_rect, border_col, false, 1.0)

	# 底部向下小三角形指示箭头
	var arrow_pts := PackedVector2Array([
		Vector2(aluo_pos.x - 3, tip_rect.position.y + 10),
		Vector2(aluo_pos.x + 3, tip_rect.position.y + 10),
		Vector2(aluo_pos.x, tip_rect.position.y + 13)
	])
	draw_colored_polygon(arrow_pts, border_col)

	if _font != null:
		var text_col := Color("#e0f2fe") if aluo_met else Color("#fff8ed")
		draw_string(_font, Vector2(tip_rect.position.x, tip_rect.position.y + 7.5), tip_text, HORIZONTAL_ALIGNMENT_CENTER, tip_w, 6.5, text_col)


## 绘制程教练（原生 32x40 精灵 + 动态朝向步态 + 冲刺拖影 + 体力/配速金边卡）
func _draw_coach(outing: Dictionary) -> void:
	var coach_m: Array = outing.get("position", [0.0, 0.0])
	var mx: float = float(coach_m[0])
	var my: float = float(coach_m[1])
	var coach_p := _m_to_p(Vector2(mx, my))

	var pace: String = str(outing.get("pace", "walk"))
	var active_run: bool = bool(outing.get("active", false))
	var progress_m := float(outing.get("progress_m", 0.0))

	# 动态方向与步态计算
	var direction := "right"
	if mx < 36.0:
		direction = "right"
	elif my < 60.0:
		direction = "down"
	else:
		direction = "right"

	var pose := "idle"
	var phase_idx := 0
	if active_run:
		pose = "walk"
		match pace:
			"sprint":
				phase_idx = int(progress_m * 4.0) % 4
			"jog":
				phase_idx = int(progress_m * 2.5) % 4
			_: # "walk"
				phase_idx = int(progress_m * 1.5) % 4

	# 冲刺动感残影与青绿风阻线
	if pace == "sprint" and active_run:
		var trail_offset := Vector2(-8, 0) if direction == "right" else Vector2(0, -8)
		draw_ellipse(coach_p + trail_offset + Vector2(0, 1), 10, 4, Color("#38bdf8", 0.35))
		draw_ellipse(coach_p + trail_offset * 1.8 + Vector2(0, 1), 8, 3, Color("#38bdf8", 0.18))
		# 速度线
		draw_line(coach_p + Vector2(-14, -10), coach_p + Vector2(-4, -10), Color("#ffffff", 0.6), 1.0)
		draw_line(coach_p + Vector2(-18, -18), coach_p + Vector2(-6, -18), Color("#ffffff", 0.5), 1.0)

	# 双层柔和接地阴影
	draw_ellipse(coach_p + Vector2(0, 1), 10.0, 4.5, Color(0, 0, 0, 0.35))
	draw_ellipse(coach_p + Vector2(0, 1), 6.0, 3.0, Color(0, 0, 0, 0.50))

	# 绘制 32x40 原生程教练精灵
	if _char_art != null:
		var coach_tex := _char_art.get_coach_texture(pose, phase_idx, direction)
		if coach_tex != null:
			var sprite_pos := coach_p - Vector2(16.0, 38.0)
			draw_texture(coach_tex, sprite_pos)

	# 浮动配速胶囊与体力条（戴夫风格双层金边）
	_draw_coach_hud(coach_p, outing)


func _draw_coach_hud(coach_p: Vector2, outing: Dictionary) -> void:
	var stamina := float(outing.get("stamina", 100.0))
	var stamina_pct := clampf(stamina / 100.0, 0.0, 1.0)
	var pace: String = str(outing.get("pace", "walk"))

	# 1. 紧凑体力条
	var bar_w := 26.0
	var bar_h := 3.5
	var bar_rect := Rect2(coach_p.x - bar_w * 0.5, coach_p.y - 30.0, bar_w, bar_h)

	# 阴影与底座
	draw_rect(Rect2(bar_rect.position.x + 1, bar_rect.position.y + 1, bar_w, bar_h), Color(0, 0, 0, 0.5))
	draw_rect(bar_rect, Color("#121a26"))
	draw_rect(bar_rect, Color("#475569"), false, 1.0)

	# 充能色
	var fill_color := Color("#10b981") if stamina > 40.0 else (Color("#f59e0b") if stamina > 20.0 else Color("#ef4444"))
	if stamina_pct > 0.0:
		draw_rect(Rect2(bar_rect.position.x + 0.5, bar_rect.position.y + 0.5, (bar_w - 1.0) * stamina_pct, bar_h - 1.0), fill_color)

	# 2. 配速指示胶囊
	var pace_name: String = str({"walk": "走 1.2m/s", "jog": "慢跑 2.0m/s", "sprint": "冲刺 2.4m/s"}.get(pace, "走"))
	var badge_w := 44.0
	var badge_h := 9.0
	var badge_rect := Rect2(coach_p.x - badge_w * 0.5, coach_p.y - 41.0, badge_w, badge_h)

	draw_rect(Rect2(badge_rect.position.x + 1, badge_rect.position.y + 1, badge_w, badge_h), Color(0, 0, 0, 0.4))
	draw_rect(badge_rect, C_CARD_BG)
	var pace_border := Color("#38bdf8") if pace == "sprint" else (Color("#f59e0b") if pace == "jog" else C_BRASS_BORDER)
	draw_rect(badge_rect, pace_border, false, 1.0)

	if _font != null:
		draw_string(_font, Vector2(badge_rect.position.x, badge_rect.position.y + 6.8), pace_name, HORIZONTAL_ALIGNMENT_CENTER, badge_w, 6.0, Color("#ffffff"))
