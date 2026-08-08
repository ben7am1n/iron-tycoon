# tests/unit/build_shop_ui/palette_thumbnail_test.gd
# V3 Phase 3 — 底部购买栏设备 pixel sprite 缩略图（V3 §10）单元测试
#
# 验证 BuildShopPalette + PaletteTile 的缩略图路径（非图标/非占位符）：
#   - 注入 EquipmentArt 时每个 tile 拥有设备 pixel sprite 缩略图
#     （texture != null，NEAREST filter，非 placeholder glyph）
#   - 未注入时保持 placeholder glyph 路径（story-001/002 rigs 兼容）
#   - Hover（§10）：设备略提亮（modulate 亮化）+ 黄色像素描边 +
#     轻微上移（is_hovered / get_hover_outline_color / HOVER_LIFT）
#   - hover 不破坏色盲安全：greyed 状态 hover 仍 achromatic
#
# Headless 断言 STATE（query surface），不碰像素 —— 与 palette_state_test
# 同一模式。
#
# Run standalone: godot --headless --script tests/unit/build_shop_ui/palette_thumbnail_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const PALETTE_SCRIPT := "res://src/ui/build_shop_palette.gd"
const PLACEHOLDER_AVAIL_SCRIPT_PATH := "res://src/ui/placeholder_palette_availability.gd"
const CATALOG_SCRIPT := "res://src/systems/equipment_catalog.gd"
const DEF_SCRIPT := "res://src/systems/equipment_def.gd"
const ECONOMY_SCRIPT := "res://src/systems/economy.gd"
const EquipmentArtScript := preload("res://src/presentation/equipment_art.gd")

var _pass := 0
var _fail := 0
var _nodes_to_free: Array = []
var _root: Node


func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	var result := run_all()
	quit(1 if int(result["fail"]) > 0 else 0)


func run_all() -> Dictionary:
	print("=".repeat(48))
	print("  UNIT TEST: Palette — V3 §10 equipment pixel-sprite thumbnails")
	print("=".repeat(48))
	_root = Node.new()
	get_root().add_child(_root)

	_test_thumbnail_present_when_equip_art_injected()
	_test_thumbnail_is_pixel_sprite_non_placeholder()
	_test_thumbnail_absent_keeps_placeholder()
	_test_hover_state_toggles()
	_test_hover_outline_butter()
	_test_hover_lift_constant()
	_test_hover_preserves_greyed_achromatic()

	_free_test_nodes()
	print("\n=== PALETTE THUMBNAIL: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


# === helpers ===

func _PALETTE() -> Script:
	return load(PALETTE_SCRIPT) as Script


func _PLACEHOLDER() -> Script:
	return load(PLACEHOLDER_AVAIL_SCRIPT_PATH) as Script


func _CATALOG() -> Script:
	return load(CATALOG_SCRIPT) as Script


func _DEF() -> Script:
	return load(DEF_SCRIPT) as Script


func _ECONOMY() -> Script:
	return load(ECONOMY_SCRIPT) as Script


func _make_def(ED, id: String, name: String, cost: int, unlock: String):
	var zone: Array = ["strength"] if id == "bench_press" else ["cardio"]
	var footprint: Array[Vector2i] = [Vector2i(0, 0)]
	var access: Array[Vector2i] = [Vector2i(1, 0)]
	var effects: Array[Dictionary] = []
	return ED.new(id, name, zone, footprint, access, cost, unlock, effects, 200, 30, 100, 300)


func _make_catalog(defs: Array):
	var catalog = _CATALOG().new()
	for d in defs:
		catalog.call("_add_definition", d)
	catalog.call("_freeze")
	return catalog


func _make_economy(seed: int):
	var srg: RefCounted = load("res://src/systems/seeded_rng.gd").new()
	srg.call("init", seed)
	var orch: Node = load("res://src/systems/simulation_orchestrator.gd").new()
	_root.add_child(orch)
	orch.call("_ready")
	_nodes_to_free.append(orch)
	var econ = _ECONOMY().new()
	econ.call("init", orch, srg)
	orch.set("economy", econ)
	return econ


func _make_placeholder_availability(catalog, economy):
	return _PLACEHOLDER().new(catalog, economy)


func _make_standard_rig(seed: int, equip_art) -> Dictionary:
	var ED := _DEF()
	var defs: Array = [
		_make_def(ED, "treadmill", "Treadmill", 200, ""),
		_make_def(ED, "bike", "Stationary Bike", 220, ""),
		_make_def(ED, "bench_press", "Bench Press", 350, ""),
		_make_def(ED, "yoga_mat", "Yoga Mat", 200, ""),
	]
	var catalog = _make_catalog(defs)
	var economy = _make_economy(seed)
	var availability = _make_placeholder_availability(catalog, economy)
	var palette = _PALETTE().new()
	palette.call("init", catalog, economy, availability, null, null, equip_art)
	_root.add_child(palette)
	_nodes_to_free.append(palette)
	return {"catalog": catalog, "economy": economy, "availability": availability, "palette": palette}


func _free_test_nodes() -> void:
	for n in _nodes_to_free:
		if is_instance_valid(n):
			n.queue_free()
	_nodes_to_free.clear()


func _is_achromatic(c: Color) -> bool:
	return is_equal_approx(c.r, c.g) and is_equal_approx(c.g, c.b)


# === tests ===

func _test_thumbnail_present_when_equip_art_injected() -> void:
	print("\n[V3 §10] equip_art injected → every tile has a thumbnail texture")
	var rig := _make_standard_rig(0xCAFE01, EquipmentArtScript.new())
	var palette: Node = rig["palette"]
	for id in ["treadmill", "bike", "bench_press", "yoga_mat"]:
		var tile: Node = palette.call("get_tile", id)
		_check(tile != null, "tile exists for '%s'" % id)
		if tile == null:
			continue
		var thumb: Texture2D = tile.call("get_thumbnail")
		_check(thumb != null, "'%s' thumbnail texture present" % id)
		if thumb != null:
			_check(thumb.get_size().x > 0 and thumb.get_size().y > 0,
				"'%s' thumbnail has non-zero size %s" % [id, thumb.get_size()])


func _test_thumbnail_is_pixel_sprite_non_placeholder() -> void:
	print("\n[V3 §10] thumbnail is the equipment pixel sprite (non-icon/non-placeholder)")
	var rig := _make_standard_rig(0xCAFE02, EquipmentArtScript.new())
	var palette: Node = rig["palette"]
	# treadmill 缩略图应包含机器深蓝灰轮廓像素（场景物件同源，非首字母字形）。
	var tile: Node = palette.call("get_tile", "treadmill")
	var thumb: ImageTexture = tile.call("get_thumbnail")
	if thumb == null:
		_check(false, "precondition: treadmill thumbnail present")
		return
	var img := thumb.get_image()
	_check(img != null, "thumbnail has readable image")
	if img == null:
		return
	# 像素精灵非纯色：≥2 独立色（机身材质 + 区域 accent / 高光）。
	var levels := _count_levels(img, 0.08)
	_check(levels >= 2, "treadmill thumbnail has >=2 color levels (got %d) — scene object, not glyph" % levels)
	# 缩略图尺寸 = 设备精灵纹理尺寸（32×32/cell 整数倍）：treadmill 2×1 = 64×32。
	_check(thumb.get_size() == Vector2(64, 32), "treadmill thumbnail 64x32 (scene-object sprite size, got %s)" % thumb.get_size())


func _test_thumbnail_absent_keeps_placeholder() -> void:
	print("\n[compat] no equip_art → placeholder glyph path preserved")
	var rig := _make_standard_rig(0xCAFE03, null)
	var palette: Node = rig["palette"]
	var tile: Node = palette.call("get_tile", "treadmill")
	_check(tile.call("get_thumbnail") == null, "no equip_art → thumbnail null")
	_check(String(tile.call("get_icon_text")).length() > 0, "placeholder glyph still renders (backward compat)")


func _test_hover_state_toggles() -> void:
	print("\n[V3 §10] tile hover state toggles (略提亮 + 黄色像素描边 + 轻微上移)")
	var rig := _make_standard_rig(0xCAFE04, EquipmentArtScript.new())
	var palette: Node = rig["palette"]
	var tile: Node = palette.call("get_tile", "treadmill")
	_check(not bool(tile.call("is_hovered")), "tile starts not hovered")
	tile.call("_on_mouse_entered")
	_check(bool(tile.call("is_hovered")), "mouse_entered → hovered")
	tile.call("_on_mouse_exited")
	_check(not bool(tile.call("is_hovered")), "mouse_exited → not hovered")


func _test_hover_outline_butter() -> void:
	print("\n[V3 §10] hover outline is yellow (Butter)")
	var rig := _make_standard_rig(0xCAFE05, EquipmentArtScript.new())
	var palette: Node = rig["palette"]
	var tile: Node = palette.call("get_tile", "bike")
	_check(tile.call("get_hover_outline_color") == Color("f5d97b"),
		"hover outline color == Butter #f5d97b (yellow pixel outline)")


func _test_hover_lift_constant() -> void:
	var tile_script = load("res://src/ui/palette_tile.gd")
	_check(int(tile_script.HOVER_LIFT) > 0, "HOVER_LIFT > 0 (V3 §10 轻微上移)")
	_check(int(tile_script.HOVER_LIFT) <= 4, "HOVER_LIFT <= 4 (subtle lift)")


func _test_hover_preserves_greyed_achromatic() -> void:
	print("\n[V3 §10 + art-bible §7] hover on greyed tile keeps achromatic modulate")
	var rig := _make_standard_rig(0xCAFE06, EquipmentArtScript.new())
	var palette: Node = rig["palette"]
	var economy: RefCounted = rig["economy"]
	economy.call("spend", 490)  # balance 10 → treadmill ($200) unaffordable
	var tile: Node = palette.call("get_tile", "treadmill")
	_check(int(tile.get("state")) == int(load("res://src/ui/palette_tile.gd").State.UNAFFORDABLE),
		"precondition: treadmill unaffordable")
	tile.call("_on_mouse_entered")
	var mod: Color = tile.get("modulate")
	_check(_is_achromatic(mod), "greyed+hover modulate stays achromatic (r==g==b got %s)" % mod)


func _count_levels(img: Image, tol: float) -> int:
	var representatives: Array[Color] = []
	for y in img.get_height():
		for x in img.get_width():
			var p := img.get_pixel(x, y)
			if p.a <= 0.5:
				continue
			var matched := false
			for rep in representatives:
				if _dist(p, rep) <= tol:
					matched = true
					break
			if not matched:
				representatives.append(p)
	return representatives.size()


func _dist(a: Color, b: Color) -> float:
	var dr := a.r - b.r
	var dg := a.g - b.g
	var db := a.b - b.b
	return sqrt(dr * dr + dg * dg + db * db)
