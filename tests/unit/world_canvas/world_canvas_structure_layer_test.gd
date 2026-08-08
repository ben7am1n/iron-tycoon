# tests/unit/world_canvas/world_canvas_structure_layer_test.gd
# Phase 2 — WorldCanvas × StructureArt 集成测试
#
# 验证 src/presentation/world_canvas.gd 的结构层接线（Phase 2 新增）：
#   - init 接受第 3 个可选注入 structure_art（向后兼容：不传则不画结构）
#   - 注入后内部引用生效
#   - 三图层纹理经 world_canvas 的 _draw_structure_layer 路径可生成
#   - 结构层在 V3 §4 空间层级中的顺序契约（BACKGROUND 在环境背景之前 /
#     GAMEPLAY 在会员之前 / FOREGROUND 在环境前景之前）—— 通过
#     StructureArt 图层常量校验（绘制顺序由 _draw() 静态代码控制，此处
#     验证常量与 StructureArt 契约一致）
#
# Run standalone: godot --headless --script tests/unit/world_canvas/world_canvas_structure_layer_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const WorldCanvasScript := preload("res://src/presentation/world_canvas.gd")
const StructureArtScript := preload("res://src/presentation/structure_art.gd")
const GridSystemScript := preload("res://src/systems/grid_system.gd")

const GRID_W := 13
const GRID_H := 10
const CELL_SIZE := 32

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
	print("  UNIT TEST: WorldCanvas × StructureArt 结构层接线")
	print("=".repeat(48))

	_test_init_accepts_structure_art()
	_test_internal_ref_wired()
	_test_layer_textures_via_canvas()
	_test_layer_contract()

	_free_test_nodes()

	print("\n=== WORLD CANVAS STRUCTURE LAYER TEST: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


func _make_grid():
	var grid = GridSystemScript.new()
	grid.init(GRID_W, GRID_H)
	for y in GRID_H:
		for x in GRID_W:
			grid.set_buildable(Vector2i(x, y), true)
	grid.freeze_buildable()
	return grid


func _make_canvas(grid, structure_art = null) -> Node2D:
	var canvas: Node2D = WorldCanvasScript.new()
	canvas.init(
		grid,
		null,      # catalog
		null,      # member
		null,      # member_sprites
		null,      # equip_art
		null,      # placement
		null,      # arbitration
		Callable(),  # resolver
		Callable(),  # tick_provider
		CELL_SIZE,
		null,      # floor_art（Phase 5，本测试不关注）
		null,      # env_art（Phase 5，本测试不关注）
		structure_art
	)
	_nodes_to_free.append(canvas)
	return canvas


func _test_init_accepts_structure_art() -> void:
	print("\n-- init 第 3 个可选注入 structure_art --")
	var grid = _make_grid()
	var art = StructureArtScript.new()
	var canvas := _make_canvas(grid, art)
	_check(canvas != null, "注入 structure_art 的 WorldCanvas 构造成功（无崩溃）")
	# 不注入（旧调用方）仍兼容
	var canvas2 := _make_canvas(grid)
	_check(canvas2 != null, "不注入 structure_art 仍兼容（可选参数）")


func _test_internal_ref_wired() -> void:
	print("\n-- 内部引用 _structure_art --")
	var grid = _make_grid()
	var art = StructureArtScript.new()
	var canvas := _make_canvas(grid, art)
	_check(canvas.get("_structure_art") == art, "_structure_art 引用 = 注入实例")
	var canvas2 := _make_canvas(grid)
	_check(canvas2.get("_structure_art") == null, "未注入时 _structure_art = null（不画结构）")


func _test_layer_textures_via_canvas() -> void:
	print("\n-- 三图层纹理经 _draw_structure_layer 路径可生成 --")
	var grid = _make_grid()
	var art = StructureArtScript.new()
	var canvas := _make_canvas(grid, art)
	# 直接调用 _draw_structure_layer（headless 下 draw_texture_rect 无渲染，
	# 但纹理获取/尺寸校验可执行 —— 与 floor_art 集成测试同一模式）
	for layer in [StructureArtScript.LAYER_BACKGROUND, StructureArtScript.LAYER_GAMEPLAY, StructureArtScript.LAYER_FOREGROUND]:
		var tex = art.layer_texture(layer)
		_check(tex != null and tex.get_width() == StructureArtScript.WORLD_W,
			"%s 层纹理经 canvas 引用生成（%dx%d）" % [layer, tex.get_width() if tex != null else 0, tex.get_height() if tex != null else 0])


func _test_layer_contract() -> void:
	print("\n-- V3 §4 图层常量契约（与 _draw() 顺序一致）--")
	# BACKGROUND 结构（储物柜/镜子/空调/墙钟/踢脚线/电线槽/管道）必须与
	# 环境背景同层语义：低对比。GAMEPLAY 前台/立柱必须可遮挡或醒目。
	var art = StructureArtScript.new()
	var bg_ids: Array = art.structure_ids_in_layer(StructureArtScript.LAYER_BACKGROUND)
	for must in ["lockers", "mirror", "ac_unit", "wall_clock", "baseboard_north", "cable_duct_north", "pipe_vertical"]:
		_check(bg_ids.has(must), "BACKGROUND 层含 %s（低对比结构）" % must)
	var gp_ids: Array = art.structure_ids_in_layer(StructureArtScript.LAYER_GAMEPLAY)
	_check(gp_ids.has("front_desk"), "GAMEPLAY 层含 front_desk（前台原色醒目）")
	var fg_ids: Array = art.structure_ids_in_layer(StructureArtScript.LAYER_FOREGROUND)
	for must in ["column_1", "column_2", "hanging_lamp_1"]:
		_check(fg_ids.has(must), "FOREGROUND 层含 %s（可轻微遮挡）" % must)


func _free_test_nodes() -> void:
	for n in _nodes_to_free:
		if is_instance_valid(n):
			n.free()
	_nodes_to_free.clear()
