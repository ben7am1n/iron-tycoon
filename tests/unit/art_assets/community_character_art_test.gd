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
	_test_qiu_and_lin_npc_textures()
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
		{"path": "res://assets/sprites/characters/member_equipment_workout_sheet.png", "w": 192, "h": 200, "name": "Equipment Workouts"},
		{"path": "res://assets/sprites/characters/npc_qiu_sheet.png", "w": 192, "h": 120, "name": "Boxer Qiu (老邱)"},
		{"path": "res://assets/sprites/characters/npc_lin_sheet.png", "w": 192, "h": 120, "name": "Mechanic Lin (林师傅)"},
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

	# Aluo cycling on stationary bike
	var tex_bike := art.get_member_texture("singer_aluo", "USING", 0, false, {"equipment_id": "bike"})
	_check(tex_bike != null, "Aluo stationary bike cycling frame returned")
	_check(tex_bike.get_width() == 32 and tex_bike.get_height() == 40, "Aluo bike frame is 32x40")

	# Aluo bench press
	var tex_bench := art.get_member_texture("singer_aluo", "USING", 0, false, {"equipment_id": "bench_press"})
	_check(tex_bench != null, "Aluo bench press workout frame returned")
	_check(tex_bench.get_width() == 32 and tex_bench.get_height() == 40, "Aluo bench frame is 32x40")

	# Aluo seated yoga
	var tex_yoga := art.get_member_texture("singer_aluo", "USING", 0, false, {"equipment_id": "yoga_mat"})
	_check(tex_yoga != null, "Aluo yoga seated stretch frame returned")
	_check(tex_yoga.get_width() == 32 and tex_yoga.get_height() == 40, "Aluo yoga frame is 32x40")

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
		
		# Test all 4 equipment types for generic member
		var g_treadmill := art.get_member_texture("", "USING", 0, false, {"member_id": var_id, "equipment_id": "treadmill"})
		_check(g_treadmill != null, "Generic member variant %d treadmill workout frame returned" % var_id)
		
		var g_bike := art.get_member_texture("", "USING", 0, false, {"member_id": var_id, "equipment_id": "bike"})
		_check(g_bike != null, "Generic member variant %d bike workout frame returned" % var_id)
		
		var g_bench := art.get_member_texture("", "USING", 0, false, {"member_id": var_id, "equipment_id": "bench_press"})
		_check(g_bench != null, "Generic member variant %d bench press frame returned" % var_id)
		
		var g_yoga := art.get_member_texture("", "USING", 0, false, {"member_id": var_id, "equipment_id": "yoga_mat"})
		_check(g_yoga != null, "Generic member variant %d yoga frame returned" % var_id)

func _test_qiu_and_lin_npc_textures() -> void:
	print("\n[NPCs] Boxer Qiu and Mechanic Lin animations")
	var art = CommunityCharacterArtScript.new()

	# Boxer Qiu (老邱)
	var qiu_idle := art.get_qiu_texture("idle", 0)
	_check(qiu_idle != null, "Boxer Qiu idle frame returned")
	_check(qiu_idle.get_width() == 32 and qiu_idle.get_height() == 40, "Boxer Qiu idle frame is 32x40")

	var qiu_walk := art.get_qiu_texture("walk", 0)
	_check(qiu_walk != null, "Boxer Qiu walk frame returned")

	var qiu_counter := art.get_qiu_texture("front_desk", 0)
	_check(qiu_counter != null, "Boxer Qiu front desk counter lean frame returned")

	var qiu_nod := art.get_qiu_texture("nod", 0)
	_check(qiu_nod != null, "Boxer Qiu nod/thumbs up frame returned")

	# Boxer Qiu via get_member_texture
	var qiu_member_tex := art.get_member_texture("boxer_qiu", "FRONT_DESK", 0, false)
	_check(qiu_member_tex != null, "Boxer Qiu dispatched via get_member_texture")

	# Mechanic Lin (林师傅)
	var lin_idle := art.get_lin_texture("idle", 0)
	_check(lin_idle != null, "Mechanic Lin idle frame returned")
	_check(lin_idle.get_width() == 32 and lin_idle.get_height() == 40, "Mechanic Lin idle frame is 32x40")

	var lin_walk := art.get_lin_texture("walk", 0)
	_check(lin_walk != null, "Mechanic Lin walk frame returned")

	var lin_repair := art.get_lin_texture("repair", 0)
	_check(lin_repair != null, "Mechanic Lin wrench repair frame returned")

	var lin_thumbs := art.get_lin_texture("thumbs_up", 0)
	_check(lin_thumbs != null, "Mechanic Lin thumbs up frame returned")

	# Mechanic Lin via get_member_texture
	var lin_member_tex := art.get_member_texture("mechanic_lin", "RENOVATING", 0, false)
	_check(lin_member_tex != null, "Mechanic Lin dispatched via get_member_texture")

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
