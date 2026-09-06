# tests/unit/art_assets/character_portraits_and_props_test.gd
# Validates pixel art assets (48x48 character portraits, gym props & neon sign)
# and their integration into CommunityHud and WorldCanvas.
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"
const CommunityHudScript := preload("res://src/ui/community_hud.gd")
const WorldCanvasScript := preload("res://src/presentation/world_canvas.gd")

var _pass := 0
var _fail := 0
var _nodes_to_free: Array = []


func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	var result := run_all()
	quit(1 if int(result["fail"]) > 0 else 0)


func run_all() -> Dictionary:
	print("=".repeat(56))
	print("  UNIT TEST: Character Portraits & Gym Props Art Assets")
	print("=".repeat(56))
	_test_portrait_files_exist_and_format()
	_test_portrait_distinctive_colors()
	_test_prop_files_exist_and_format()
	_test_community_hud_portrait_binding()
	_test_world_canvas_prop_integration()
	_free_test_nodes()
	print("\n=== ART ASSETS TEST: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(condition: bool, message: String) -> void:
	if condition:
		_pass += 1
		print("  PASS: %s" % message)
	else:
		_fail += 1
		print("  FAIL: %s" % message)


func _free_test_nodes() -> void:
	for node in _nodes_to_free:
		if is_instance_valid(node):
			node.free()
	_nodes_to_free.clear()


func _test_portrait_files_exist_and_format() -> void:
	print("\n[Portraits] file existence and 48x48 RGBA format")
	var characters := ["portrait_cheng", "portrait_aluo", "portrait_qiu", "portrait_lin"]
	for id in characters:
		var path := "res://assets/sprites/portraits/%s.png" % id
		_check(FileAccess.file_exists(path), "%s.png exists on disk" % id)
		var img := Image.new()
		var err := img.load(path)
		_check(err == OK, "%s.png loads cleanly as valid PNG image" % id)
		_check(img.get_width() == 48 and img.get_height() == 48, "%s.png size is strictly 48x48 pixels (got %dx%d)" % [id, img.get_width(), img.get_height()])
		_check(img.get_format() == Image.FORMAT_RGBA8, "%s.png is 32-bit RGBA8 format" % id)
		_check(not img.is_empty(), "%s.png image data is not empty" % id)


func _test_portrait_distinctive_colors() -> void:
	print("\n[Portraits] character distinctive identity colors")
	# 1. Cheng (Teal jacket #2E7D6B & Silver streak #F1F5F9)
	var cheng := Image.new()
	cheng.load("res://assets/sprites/portraits/portrait_cheng.png")
	_check(_image_contains_color(cheng, Color("2e7d6b"), 0.05), "Coach Cheng has signature teal jacket color (#2e7d6b)")
	_check(_image_contains_color(cheng, Color("f1f5f9"), 0.05), "Coach Cheng has signature silver streak highlight (#f1f5f9)")

	# 2. Aluo (Brick-red hoodie #B84A39 & Cyan earpiece LED #38BDF8)
	var aluo := Image.new()
	aluo.load("res://assets/sprites/portraits/portrait_aluo.png")
	_check(_image_contains_color(aluo, Color("b84a39"), 0.05), "Singer Aluo has signature brick-red hoodie (#b84a39)")
	_check(_image_contains_color(aluo, Color("38bdf8"), 0.05), "Singer Aluo has ear-hook headphone cyan indicator (#38bdf8)")

	# 3. Qiu (Wine tank top #7A2E38 & Tan skin #DFAB8B)
	var qiu := Image.new()
	qiu.load("res://assets/sprites/portraits/portrait_qiu.png")
	_check(_image_contains_color(qiu, Color("7a2e38"), 0.05), "Boxer Qiu has signature burgundy/wine tank top (#7a2e38)")
	_check(_image_contains_color(qiu, Color("dfab8b"), 0.05), "Boxer Qiu has veteran weathered skin tone (#dfab8b)")

	# 4. Lin (Yellow hardhat #F2C94C & Cobalt blue overalls #2D4F8A)
	var lin := Image.new()
	lin.load("res://assets/sprites/portraits/portrait_lin.png")
	_check(_image_contains_color(lin, Color("f2c94c"), 0.05), "Mechanic Lin has yellow hardhat (#f2c94c)")
	_check(_image_contains_color(lin, Color("2d4f8a"), 0.05), "Mechanic Lin has cobalt blue overalls (#2d4f8a)")


func _test_prop_files_exist_and_format() -> void:
	print("\n[Props] gym environment sprites existence and dimensions")
	var props := [
		{"file": "sign_neon_lin.png", "w": 48, "h": 20},
		{"file": "front_desk.png", "w": 48, "h": 24},
		{"file": "water_towel_station.png", "w": 24, "h": 32},
		{"file": "dumbbell_rack.png", "w": 32, "h": 24},
	]
	for p in props:
		var path := "res://assets/sprites/props/%s" % p.file
		_check(FileAccess.file_exists(path), "%s exists on disk" % p.file)
		var img := Image.new()
		var err := img.load(path)
		_check(err == OK, "%s loads cleanly" % p.file)
		_check(img.get_width() == p.w and img.get_height() == p.h, "%s size matches spec %dx%d (got %dx%d)" % [p.file, p.w, p.h, img.get_width(), img.get_height()])


func _test_community_hud_portrait_binding() -> void:
	print("\n[CommunityHud] dialogue portrait avatar binding")
	var hud = CommunityHudScript.new()
	_nodes_to_free.append(hud)

	var mock_view := {
		"phase": "CLOSE",
		"day": 1,
		"balance": 280,
		"story": {"closing_text": "阿洛：原来坚持到最后，不一定要一直拼命。明天还想来。"}
	}
	hud.init(func() -> Dictionary: return mock_view)
	root.add_child(hud)
	hud._ready()
	hud._process(0.016)

	_check(hud.is_portrait_visible(), "Portrait avatar is visible in CLOSE dialogue phase")
	_check(hud.get_active_portrait_character() == "aluo", "Aluo portrait resolved when Aluo is speaking (got %s)" % hud.get_active_portrait_character())
	_check(hud.get_speaker_name() == "阿洛", "Speaker label correctly displays '阿洛'")

	# Test Lao Qiu
	mock_view["story"] = {"closing_text": "老邱：每个人有自己的节奏。明天继续找感觉。"}
	hud._process(0.016)
	_check(hud.get_active_portrait_character() == "qiu", "Qiu portrait resolved when Lao Qiu is speaking")

	# Test Master Lin
	mock_view["story"] = {"closing_text": "林师傅：我修好了招牌，它现在认识晚上了。"}
	hud._process(0.016)
	_check(hud.get_active_portrait_character() == "lin", "Lin portrait resolved when Master Lin is speaking")

	# Test Coach Cheng
	mock_view["story"] = {"closing_text": "程教练：明天还来？"}
	hud._process(0.016)
	_check(hud.get_active_portrait_character() == "coach", "Cheng portrait resolved when Coach Cheng is speaking")

	# Test Guidance in SERVICE
	mock_view["phase"] = "SERVICE"
	mock_view["course"] = {"guidance_open": true, "guidance_prompt": "保持 / 放缓 / 休息，选一个节奏。"}
	hud._process(0.016)
	_check(hud.is_portrait_visible(), "Portrait avatar is visible during Coach guidance prompt")
	_check(hud.get_active_portrait_character() == "coach", "Coach Cheng portrait active during in-class guidance")


func _test_world_canvas_prop_integration() -> void:
	print("\n[WorldCanvas] prop texture loading and renovation neon sign")
	var canvas = WorldCanvasScript.new()
	_nodes_to_free.append(canvas)

	# Verify prop_texture returns valid textures
	for prop in ["sign_neon_lin", "front_desk", "water_towel_station", "dumbbell_rack"]:
		var tex: Texture2D = canvas.prop_texture(prop)
		_check(tex != null, "WorldCanvas loads prop texture '%s' successfully" % prop)
		_check(tex.get_width() > 0 and tex.get_height() > 0, "Prop texture '%s' has valid dimensions (%dx%d)" % [prop, tex.get_width(), tex.get_height()])

	# Verify renovation provider
	var box := [false]
	canvas.set_renovation_provider(func() -> bool: return box[0])
	_check(not canvas.is_renovated(), "WorldCanvas is_renovated() is initially false")
	box[0] = true
	_check(canvas.is_renovated(), "WorldCanvas is_renovated() switches to true when renovated")



func _image_contains_color(img: Image, target: Color, tol: float) -> bool:
	for y in img.get_height():
		for x in img.get_width():
			var p := img.get_pixel(x, y)
			if p.a > 0.5 and absf(p.r - target.r) < tol and absf(p.g - target.g) < tol and absf(p.b - target.b) < tol:
				return true
	return false
