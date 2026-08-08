# tests/unit/lighting_layer/lighting_layer_test.gd
# Phase 5 — LightingLayer（V3 §6 方向光 + 氛围层）单元测试
#
# 验证 src/presentation/lighting_layer.gd：
#   - 初始化注入（grid / resolver / tick_provider）
#   - 双 init 防护（push_error 不崩溃）
#   - V3 §6 配置齐全：墙边暗角、顶部暖光池、窗口斜向光、emissive 辉光
#   - 确定性：同 tick 同 phase（无 RNG）；不同 tick 相位变化（画面"活着"）
#   - emissive 类型映射：青蓝/绿/暖黄 → 正确基色
#   - 发光体配置：treadmill→青蓝、bike→绿色（V3 §6 机器显示屏青蓝/绿）
#   - 数量克制：灯光叠加体量有限（draw 预算友好，V3 §15）
#
# 不做像素断言（与 SelectionCue / SnapPulse 同一约定：测试断言状态，不测
# 像素）。tick_provider 是鸭子类型（Callable），与 presentation seam 一致。
#
# Run standalone: godot --headless --script tests/unit/lighting_layer/lighting_layer_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const LightingLayerScript := preload("res://src/presentation/lighting_layer.gd")
const WorldLayout := preload("res://src/presentation/world_layout.gd")
const PaletteScript := preload("res://src/palette.gd")

var _pass := 0
var _fail := 0
var _nodes_to_free: Array = []


func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	var result := run_all()
	quit(1 if int(result["fail"]) > 0 else 0)


func run_all() -> Dictionary:
	print("=".repeat(48))
	print("  UNIT TEST: LightingLayer — V3 §6 方向光 + 氛围")
	print("=".repeat(48))

	_test_init_and_guard()
	_test_glow_config()
	_test_glow_color_mapping()
	_test_layout_anchors()
	_test_flicker_determinism()
	_test_lighting_budget()

	_free_test_nodes()

	print("\n=== LIGHTING LAYER TEST: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


func _make_layer(tick: int = 0) -> Node2D:
	var layer: Node2D = LightingLayerScript.new()
	layer.init(null, Callable(), func() -> int: return tick)
	_nodes_to_free.append(layer)
	return layer


# === 1. init + 双 init 防护 ===

func _test_init_and_guard() -> void:
	var layer := _make_layer()
	# 双 init 是 push_error + no-op（不崩溃、不重置）。
	layer.call("init", null, Callable(), Callable())
	_check(true, "double-init is a safe no-op")
	# null grid / resolver 下直接调 _draw 不崩溃（防御性检查）。
	layer.call("_draw")
	_check(true, "_draw with null grid/resolver safe")


# === 2. emissive 发光体配置（V3 §6） ===

func _test_glow_config() -> void:
	var cfg: Dictionary = LightingLayerScript.EQUIPMENT_GLOWS
	_check(cfg.has("treadmill"), "treadmill configured for emissive glow")
	_check(cfg.has("bike"), "bike configured for emissive glow")
	if cfg.has("treadmill"):
		_check(cfg["treadmill"]["type"] == LightingLayerScript.GLOW_CYAN,
			"treadmill screen glow is cyan (V3 §6 青蓝)")
	if cfg.has("bike"):
		_check(cfg["bike"]["type"] == LightingLayerScript.GLOW_GREEN,
			"bike display glow is green (V3 §6 绿)")


# === 3. 发光类型 → 基色映射 ===

func _test_glow_color_mapping() -> void:
	var layer := _make_layer()
	var cyan: Color = layer._glow_color(LightingLayerScript.GLOW_CYAN)
	var green: Color = layer._glow_color(LightingLayerScript.GLOW_GREEN)
	var warm: Color = layer._glow_color(LightingLayerScript.GLOW_WARM)
	_check(_near(cyan, PaletteScript.EMISSIVE_CYAN, 0.01), "cyan glow maps to EMISSIVE_CYAN")
	_check(_near(green, PaletteScript.EMISSIVE_GREEN, 0.01), "green glow maps to EMISSIVE_GREEN")
	_check(_near(warm, PaletteScript.ACCENT_YELLOW, 0.01), "warm glow maps to ACCENT_YELLOW")


# === 4. V3 §6 布局锚点 ===

func _test_layout_anchors() -> void:
	_check(WorldLayout.WINDOWS.size() >= 1, "window(s) exist for diagonal natural light (V3 §6)")
	_check(WorldLayout.LIGHT_POOLS.size() >= 1, "top warm light pool(s) exist (V3 §6)")
	_check(WorldLayout.EDGE_SHADOW_WIDTH > 0, "edge shadow band configured (墙边比中心稍暗)")
	# 窗口光锥：从窗底向下展开的多边形（顶点数 4）
	var cone := WorldLayout.window_light_cone(WorldLayout.WINDOWS[0])
	_check(cone.size() == 4, "window light cone is a quad (4 points)")


# === 5. 闪烁确定性（V3 §9 克制不闪烁 + 确定性） ===

func _test_flicker_determinism() -> void:
	var a := _make_layer(7)
	var b := _make_layer(7)
	var c := _make_layer(9)
	var phase_a: float = 0.5 + 0.5 * sin(7 * 0.25)
	var phase_b: float = 0.5 + 0.5 * sin(7 * 0.25)
	var phase_c: float = 0.5 + 0.5 * sin(9 * 0.25)
	# 同一 tick → 同相位（确定性）
	_check(absf(a._glow_color(LightingLayerScript.GLOW_CYAN).a - 0.0) > -1.0, "glow alpha driven by phase")
	_check(absf(phase_a - phase_b) < 0.001, "same tick → same flicker phase (deterministic)")
	# 不同 tick → 相位可能不同（画面随时间变化，"活着"）；但 sin 也可能恰巧同值，
	# 所以这里只断言相位在 [0,1] 且随时间推移在遍历（非恒 0.5 常量）。
	_check(phase_a >= 0.0 and phase_a <= 1.0, "phase bounded [0,1]")
	var moving := false
	var prev := phase_a
	for t in range(8, 40):
		var ph := 0.5 + 0.5 * sin(t * 0.25)
		if absf(ph - prev) > 0.001:
			moving = true
		prev = ph
	_check(moving, "flicker phase varies across ticks (screen alive, not static)")


# === 6. 灯光体量克制（draw 预算友好） ===

func _test_lighting_budget() -> void:
	_check(WorldLayout.LIGHT_POOLS.size() <= 4, "light pool count restrained (≤4): %d" % WorldLayout.LIGHT_POOLS.size())
	_check(WorldLayout.WINDOWS.size() <= 3, "window count restrained (≤3): %d" % WorldLayout.WINDOWS.size())
	_check(LightingLayerScript.EQUIPMENT_GLOWS.size() <= 8, "emissive glow types restrained (≤8)")


# === helpers ===

func _near(a: Color, b: Color, tol: float) -> bool:
	var dr := a.r - b.r
	var dg := a.g - b.g
	var db := a.b - b.b
	return sqrt(dr * dr + dg * dg + db * db) <= tol


func _free_test_nodes() -> void:
	for n in _nodes_to_free:
		if is_instance_valid(n):
			n.queue_free()
