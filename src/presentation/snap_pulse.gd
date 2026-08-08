## src/presentation/snap_pulse.gd — 吸附「咔哒」视觉反馈（Phase B v2）
##
## art-bible §7 动效手感：拖放器械时有吸附「咔哒」反馈。本节点在合法格触发一次
## 短暂的 Butter 脉冲环（视觉脉冲，不依赖音频资源 —— 无音频依赖是显式约束）。
##
## 风格（art-bible §9 正反馈）：一次、柔和、像素化；禁止闪烁/刺眼。脉冲环
## 从目标格中心向外扩展，alpha 同步衰减，~0.22s 内完成并自隐藏。Butter 是
## ~10% 高饱和锚点色（70/20/10 法则），脉冲体量小、只做锚点不抢戏。
##
## PRESENTATION LAYER ONLY：纯 Node2D，不持有任何 gameplay 状态。main.gd 在
## preview_validity_changed(valid=true) 且 anchor 变化时调用 pulse_at()。
##
## HEADLESS TESTABILITY：pulse_at() 只写状态（_active/_pos/_elapsed），
## _draw() 是状态的纯渲染。测试驱动 _advance() 推进时间并断言状态机
## （触发 → 进行中 → 自动结束），不做像素断言（与 SelectionCue 同一约定）。
class_name SnapPulse extends Node2D

const Palette := preload("res://src/palette.gd")

## 脉冲总时长（秒）。~0.22s 一次软反馈：足够明显但不过度（§9 无闪烁）。
const DURATION := 0.22
## 脉冲环起始半径（px，相对 cell 中心）。
const START_RADIUS := 6.0
## 脉冲环终止半径（px）。
const END_RADIUS := 18.0
## 环线宽（px）。3.0 world px → 2.25 viewport px：WorldRoot scale 0.75 下
## 亚像素描边消失（4.7.1 pitfall，world_scale.gd），2.0 的旧值（1.5 vp）处于
## 消失临界；3.0 稳定渲染且符合粗颗粒像素风。
const RING_WIDTH := 3.0

var _active: bool = false
var _elapsed: float = 0.0
var _pos: Vector2 = Vector2.ZERO

## 在 [world_pos]（grid cell 中心的世界坐标）触发一次 Butter 脉冲环。
## 幂等：重复调用只是重置计时（最后一次触发为准）。可随时调用。
func pulse_at(world_pos: Vector2) -> void:
	_active = true
	_elapsed = 0.0
	_pos = world_pos
	queue_redraw()


## 推进脉冲计时（headless 测试直接驱动；在树内由 _process 驱动）。
## 返回是否仍在脉冲中。
func _advance(delta: float) -> bool:
	if not _active:
		return false
	_elapsed += delta
	if _elapsed >= DURATION:
		_active = false
	queue_redraw()
	return _active


func _process(delta: float) -> void:
	_advance(delta)


## 脉冲是否正在进行（headless 状态断言用）。
func is_pulsing() -> bool:
	return _active


## 当前脉冲进度 0..1（clamped）。测试可用它断言时间轴推进。
func progress() -> float:
	return clampf(_elapsed / DURATION, 0.0, 1.0)


## 渲染脉冲环：半径线性扩展，alpha 线性衰减（一次，柔和，无闪烁）。
func _draw() -> void:
	if not _active:
		return
	var t: float = progress()
	var radius: float = lerpf(START_RADIUS, END_RADIUS, t)
	var alpha: float = 1.0 - t
	var col := Palette.SNAP_PULSE_COLOR
	col.a = alpha
	draw_arc(_pos, radius, 0.0, TAU, 24, col, RING_WIDTH, true)
	# 中心小亮点：锚点更清晰（Butter，低 alpha，非纯白）
	var core := Palette.SNAP_PULSE_COLOR
	core.a = alpha * 0.6
	draw_circle(_pos, 2.5, core)
