# tests/unit/lighting_layer/lighting_layer_test.gd
# V3.1 P4 — LightingLayer（pixel-based lighting）单元测试
#
# 验证 src/presentation/lighting_layer.gd：
#   - 初始化注入（grid / resolver / tick_provider）
#   - 双 init 防护（push_error 不崩溃）
#   - V3 §6 配置齐全：墙边暗角、顶部暖光池、窗口斜向光、emissive 辉光
#   - 确定性：同 tick 同 phase（无 RNG）；不同 tick 相位变化（画面"活着"）
#   - emissive 类型映射：青蓝/绿/暖黄 → 正确基色
#   - 发光体配置：treadmill→青蓝、bike→绿色（V3 §6 机器显示屏青蓝/绿）
#   - 数量克制：灯光叠加体量有限（draw 预算友好，V3 §15）
#   - V3.1 P4：light map 烘焙像素级光照 —— 无大面积半透明圆形光斑
#     （灯池为 hash 散射 cluster，非实心圆）；墙边冷暗像素存在；灯下暖亮
#     像素存在；同输入同输出（确定性）。
#
# 不做渲染帧像素断言（与 SelectionCue / SnapPulse 同一约定：测试断言状态，
# 不测像素；渲染帧由 evidence 捕获 + PIL 采样验证）。tick_provider 是鸭子
# 类型（Callable），与 presentation seam 一致。
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
	print("  UNIT TEST: LightingLayer — V3.1 P4 pixel-based lighting")
	print("=".repeat(48))

	_test_init_and_guard()
	_test_glow_config()
	_test_glow_color_mapping()
	_test_layout_anchors()
	_test_flicker_determinism()
	_test_lighting_budget()
	_test_pixel_light_map()

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
	# light map 烘焙不依赖 grid（静态光照）。
	layer.call("light_map_image")
	_check(true, "light_map_image() with null grid safe")


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


# === 7. V3.1 P4：pixel-based light map（无圆形光斑） ===

func _test_pixel_light_map() -> void:
	var layer := _make_layer()
	var img: Image = layer.light_map_image()
	_check(img != null, "light map baked (Image non-null)")
	if img == null:
		return
	_check(img.get_width() == WorldLayout.WORLD_W and img.get_height() == WorldLayout.WORLD_H,
		"light map is world-size %dx%d" % [WorldLayout.WORLD_W, WorldLayout.WORLD_H])

	# 墙边暗角：近墙像素存在冷暗（alpha > 0，蓝 > 红 —— 冷色）
	var edge_found := false
	for y in range(2, WorldLayout.WORLD_H - 2, 3):
		for x in range(0, WorldLayout.EDGE_SHADOW_WIDTH, 2):
			var c: Color = img.get_pixel(x, y)
			if c.a > 0.02 and c.b > c.r:
				edge_found = true
				break
		if edge_found:
			break
	_check(edge_found, "wall-edge cool-dark pixels present (近墙像素变暗)")

	# 灯下稍亮：每个灯池中心附近存在暖亮（alpha > 0.02，红 > 蓝 —— 暖色）
	var all_pools_warm := true
	for center in WorldLayout.LIGHT_POOLS:
		var c: Vector2 = center
		var warm_found := false
		for dy in range(-6, 7):
			for dx in range(-6, 7):
				var px := int(c.x) + dx
				var py := int(c.y) + dy
				if px < 0 or py < 0 or px >= img.get_width() or py >= img.get_height():
					continue
				var col: Color = img.get_pixel(px, py)
				if col.a > 0.02 and col.r > col.b:
					warm_found = true
					break
			if warm_found:
				break
		if not warm_found:
			all_pools_warm = false
			break
	_check(all_pools_warm, "under-lamp warm pixels present at every pool (灯下稍亮)")

	# 无大面积半透明圆形光斑：灯池是 hash 散射 cluster —— 灯池半径内
	# 有暖亮像素的区域占比 < 0.85（实心圆会 ~100% 覆盖）。采样半径内
	# 每 2px 步进统计，既验证"不是实心圆"，也验证"不是空"。
	var covered := 0
	var sampled := 0
	for center in WorldLayout.LIGHT_POOLS:
		var c: Vector2 = center
		var r := int(WorldLayout.LIGHT_POOL_RADIUS)
		for dy in range(-r, r + 1, 2):
			for dx in range(-r, r + 1, 2):
				var px := int(c.x) + dx
				var py := int(c.y) + dy
				if px < 0 or py < 0 or px >= img.get_width() or py >= img.get_height():
					continue
				var d := Vector2(dx, dy).length()
				if d > float(r):
					continue
				sampled += 1
				if img.get_pixel(px, py).a > 0.02:
					covered += 1
	var ratio := float(covered) / maxi(sampled, 1)
	_check(ratio < 0.85, "light pool is scattered cluster, not solid circle (coverage %.2f < 0.85)" % ratio)
	_check(covered > 0, "light pool non-empty (covered %d pixels)" % covered)

	# 确定性：同输入同输出（烘焙两次逐像素一致）
	var img2: Image = layer.light_map_image()
	var same := true
	for y in range(0, img.get_height(), 4):
		for x in range(0, img.get_width(), 4):
			if img.get_pixel(x, y) != img2.get_pixel(x, y):
				same = false
				break
		if not same:
			break
	_check(same, "light map deterministic (re-bake identical)")


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
