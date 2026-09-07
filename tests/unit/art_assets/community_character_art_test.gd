# tests/unit/art_assets/community_character_art_test.gd
# Validates native 32x40 pixel character art sheets, anchor points,
# animation frames, and Aluo dialogue portraits.
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"
const CommunityCharacterArtScript := preload("res://src/presentation/community_character_art.gd")

var _pass := 0
var _fail := 0

func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	var result := run_all()
	quit(1 if int(result["fail"]) > 0 else 0)

func run_all() -> Dictionary:
	print("=".repeat(56))
	print("  UNIT TEST: Community Character Art (32x40 Native Pixels)")
	print("=".repeat(56))
	_test_sheet_files_exist_and_format()
	_test_art_api_contracts()
	_test_coach_cheng_textures()
	_test_aluo_and_member_textures()
	_test_aluo_dialogue_portraits()
	print("\n=== COMMUNITY CHARACTER ART TEST: %d passed, %d failed ===\n" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}

func _check(condition: bool, message: String) -> void:
	if condition:
		_pass += 1
		print("  PASS: %s" % message)
	else:
		_fail += 1
		print("  FAIL: %s" % message)

func _test_sheet_files_exist_and_format() -> void:
	print("\n[Sprite Sheets] existence and dimensions")
	var sheets := [
		{"path": "res://assets/sprites/characters/coach_cheng_sheet.png", "w": 192, "h": 120, "name": "Coach Cheng"},
		{"path": "res://assets/sprites/characters/member_aluo_sheet.png", "w": 192, "h": 120, "name": "Singer Aluo"},
		{"path": "res://assets/sprites/characters/member_generic_sheet.png", "w": 192, "h": 160, "name": "Generic Members"},
	]
	for s in sheets:
		_check(FileAccess.file_exists(s.path), "%s sheet exists on disk" % s.name)
		var img := Image.new()
		var err := img.load(s.path)
		_check(err == OK, "%s sheet loads cleanly" % s.name)
		_check(img.get_width() == s.w and img.get_height() == s.h, "%s sheet size is %dx%d (got %dx%d)" % [s.name, s.w, s.h, img.get_width(), img.get_height()])
		_check(img.get_format() == Image.FORMAT_RGBA8, "%s sheet is RGBA8 format" % s.name)

func _test_art_api_contracts() -> void:
	print("\n[API Contracts] dimensions and anchors")
	var art = CommunityCharacterArtScript.new()
	_check(art.get_frame_size() == Vector2i(32, 40), "Native frame size is strictly 32x40 pixels")
	_check(art.get_feet_anchor() == Vector2(16.0, 38.0), "Feet anchor point is (16.0, 38.0)")
	_check(art.get_chest_anchor() == Vector2(16.0, 20.0), "Chest/grip contact anchor point is (16.0, 20.0)")

func _test_coach_cheng_textures() -> void:
	print("\n[Coach Cheng] animation poses and directions")
	var art = CommunityCharacterArtScript.new()
	var poses := ["idle", "walk", "guidance", "success"]
	for p in poses:
		var tex := art.get_coach_texture(p, 0, "down")
		_check(tex != null, "Coach Cheng has valid texture for pose '%s'" % p)
		_check(tex.get_width() == 32 and tex.get_height() == 40, "Coach texture for pose '%s' is 32x40" % p)

	# 4 directions for walk
	for dir in ["down", "up", "left", "right"]:
		var tex := art.get_coach_texture("walk", 1, dir)
		_check(tex != null, "Coach Cheng walk supports direction '%s'" % dir)

func _test_aluo_and_member_textures() -> void:
	print("\n[Members] Aluo and Generic Member animations")
	var art = CommunityCharacterArtScript.new()
	
	# Aluo running on treadmill
	var tex_run := art.get_member_texture("singer_aluo", "USING", 0, false, {"equipment_id": "treadmill"})
	_check(tex_run != null, "Aluo treadmill running frame returned")
	_check(tex_run.get_width() == 32 and tex_run.get_height() == 40, "Aluo treadmill running frame is 32x40")

	# Aluo seated yoga
	var tex_yoga := art.get_member_texture("singer_aluo", "USING", 0, false, {"equipment_id": "yoga_mat"})
	_check(tex_yoga != null, "Aluo yoga seated stretch frame returned")

	# Aluo tired
	var tex_tired := art.get_member_texture("singer_aluo", "QUEUEING", 0, false)
	_check(tex_tired != null, "Aluo tired/panting frame returned")

	# Aluo success / leaving satisfied
	var tex_succ := art.get_member_texture("singer_aluo", "LEAVING", 0, false, {"leaving_reason": "quota_met"})
	_check(tex_succ != null, "Aluo success feedback frame returned")

	# Generic member variants
	for var_id in 4:
		var g_tex := art.get_member_texture("", "WALKING_TO", 0, false, {"member_id": var_id})
		_check(g_tex != null, "Generic member variant %d returned" % var_id)

func _test_aluo_dialogue_portraits() -> void:
	print("\n[Aluo Dialogue Portraits] 3 emotional expressions")
	var expressions := ["portrait_aluo", "portrait_aluo_tired", "portrait_aluo_smile"]
	for exp in expressions:
		var path := "res://assets/sprites/portraits/%s.png" % exp
		_check(FileAccess.file_exists(path), "Aluo expression %s exists on disk" % exp)
		var img := Image.new()
		var err := img.load(path)
		_check(err == OK, "Aluo expression %s loads cleanly" % exp)
		_check(img.get_width() == 48 and img.get_height() == 48, "Aluo expression %s is 48x48 RGBA" % exp)
