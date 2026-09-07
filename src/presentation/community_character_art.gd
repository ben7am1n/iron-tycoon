# src/presentation/community_character_art.gd
# Manages native 32x40 pixel art sprite sheets and animations for Coach Cheng,
# Singer Aluo, and Community Members.
class_name CommunityCharacterArt extends RefCounted

const FRAME_W := 32
const FRAME_H := 40
const FEET_ANCHOR := Vector2(16.0, 38.0)
const CHEST_ANCHOR := Vector2(16.0, 20.0)

const PATH_COACH_SHEET := "res://assets/sprites/characters/coach_cheng_sheet.png"
const PATH_ALUO_SHEET := "res://assets/sprites/characters/member_aluo_sheet.png"
const PATH_GENERIC_SHEET := "res://assets/sprites/characters/member_generic_sheet.png"
const PATH_EQUIP_WORKOUT_SHEET := "res://assets/sprites/characters/member_equipment_workout_sheet.png"

var _coach_tex: Texture2D = null
var _aluo_tex: Texture2D = null
var _generic_tex: Texture2D = null
var _equip_workout_tex: Texture2D = null

var _frame_cache: Dictionary = {}

func _init() -> void:
	_load_sheets()

func _load_sheets() -> void:
	if ResourceLoader.exists(PATH_COACH_SHEET):
		_coach_tex = load(PATH_COACH_SHEET)
	elif FileAccess.file_exists(PATH_COACH_SHEET):
		var img := Image.new()
		if img.load(PATH_COACH_SHEET) == OK:
			_coach_tex = ImageTexture.create_from_image(img)

	if ResourceLoader.exists(PATH_ALUO_SHEET):
		_aluo_tex = load(PATH_ALUO_SHEET)
	elif FileAccess.file_exists(PATH_ALUO_SHEET):
		var img := Image.new()
		if img.load(PATH_ALUO_SHEET) == OK:
			_aluo_tex = ImageTexture.create_from_image(img)

	if ResourceLoader.exists(PATH_GENERIC_SHEET):
		_generic_tex = load(PATH_GENERIC_SHEET)
	elif FileAccess.file_exists(PATH_GENERIC_SHEET):
		var img := Image.new()
		if img.load(PATH_GENERIC_SHEET) == OK:
			_generic_tex = ImageTexture.create_from_image(img)

	if ResourceLoader.exists(PATH_EQUIP_WORKOUT_SHEET):
		_equip_workout_tex = load(PATH_EQUIP_WORKOUT_SHEET)
	elif FileAccess.file_exists(PATH_EQUIP_WORKOUT_SHEET):
		var img := Image.new()
		if img.load(PATH_EQUIP_WORKOUT_SHEET) == OK:
			_equip_workout_tex = ImageTexture.create_from_image(img)

func get_frame_size() -> Vector2i:
	return Vector2i(FRAME_W, FRAME_H)

func get_feet_anchor() -> Vector2:
	return FEET_ANCHOR

func get_chest_anchor() -> Vector2:
	return CHEST_ANCHOR

func _get_atlas_subtexture(source: Texture2D, col: int, row: int, flip_h: bool = false) -> Texture2D:
	if source == null:
		return null
	var key := "%s|%d|%d|%s" % [source.resource_path if source.resource_path != "" else str(source.get_instance_id()), col, row, str(flip_h)]
	if _frame_cache.has(key):
		return _frame_cache[key]
	
	var atlas := AtlasTexture.new()
	atlas.atlas = source
	atlas.region = Rect2(col * FRAME_W, row * FRAME_H, FRAME_W, FRAME_H)
	
	if flip_h:
		# If flipped, we convert to image and mirror to ensure clean rendering without texture transform quirks
		var img := atlas.get_image()
		if img != null:
			img.flip_x()
			var flipped_tex := ImageTexture.create_from_image(img)
			_frame_cache[key] = flipped_tex
			return flipped_tex

	_frame_cache[key] = atlas
	return atlas

## Returns 32x40 pixel sprite for Coach Cheng
## Sheet layout (Cols: 6, Rows: 3):
## Row 0: Idle 0..1, Walk Down 0..3
## Row 1: Walk Up 0..3, Walk Left 0..1
## Row 2: Walk Right 0..1, Guidance 0..1, Success 0..1
func get_coach_texture(pose: String, phase: int, direction: String) -> Texture2D:
	if _coach_tex == null:
		_load_sheets()
	if _coach_tex == null:
		return null

	var col := 0
	var row := 0

	match pose:
		"walk":
			match direction:
				"down":
					col = 2 + (phase % 4)
					row = 0
				"up":
					col = phase % 4
					row = 1
				"left":
					col = 4 + (phase % 2)
					row = 1
				"right":
					col = phase % 2
					row = 2
				_:
					col = 2 + (phase % 4)
					row = 0
		"guidance":
			col = 2 + (phase % 2)
			row = 2
		"success":
			col = 4 + (phase % 2)
			row = 2
		_: # "idle"
			col = phase % 2
			row = 0

	return _get_atlas_subtexture(_coach_tex, col, row, false)

## Returns 32x40 pixel sprite for Member (Aluo or Generic)
## Aluo Sheet (Cols: 6, Rows: 3):
## Row 0: Idle 0..1, Walk 0..3
## Row 1: Treadmill Run 0..3, Yoga 0..1
## Row 2: Tired 0..1, Success 0..1, Idle Side 0..1
func get_member_texture(npc_id: String, state: String, tick: int, facing_left: bool, ctx: Dictionary = {}) -> Texture2D:
	if npc_id == "singer_aluo":
		if _aluo_tex == null:
			_load_sheets()
		if _aluo_tex == null:
			return null

		var col := 0
		var row := 0
		var equip_id: String = str(ctx.get("equipment_id", ""))

		var is_fb: bool = bool(ctx.get("feedback_sequence_active", false))
		var fb_elapsed: float = float(ctx.get("feedback_sequence_elapsed", 0.0))

		if is_fb:
			if fb_elapsed < 1.0:
				# Panting / tired recovery pose (row 2, col 0..1)
				col = (tick / 3) % 2
				row = 2
			else:
				# Relieved, beaming happy smile (row 2, col 2..3)
				col = 2 + ((tick / 3) % 2)
				row = 2
		elif state == "USING":
			if equip_id == "treadmill":
				# Running on treadmill (4 phases @ 10Hz)
				col = tick % 4
				row = 1
			elif equip_id == "bike":
				if _equip_workout_tex == null:
					_load_sheets()
				if _equip_workout_tex != null:
					return _get_atlas_subtexture(_equip_workout_tex, (tick / 2) % 2, 0, facing_left)
				col = tick % 4
				row = 1
			elif equip_id == "bench_press":
				if _equip_workout_tex == null:
					_load_sheets()
				if _equip_workout_tex != null:
					return _get_atlas_subtexture(_equip_workout_tex, 2 + ((tick / 4) % 2), 0, false)
				col = tick % 4
				row = 1
			elif equip_id == "yoga_mat":
				if _equip_workout_tex == null:
					_load_sheets()
				if _equip_workout_tex != null:
					return _get_atlas_subtexture(_equip_workout_tex, 4 + ((tick / 4) % 2), 0, facing_left)
				# Fallback to Aluo sheet yoga (row 1, col 4..5)
				col = 4 + ((tick / 4) % 2)
				row = 1
			else:
				# Generic workout -> running or tired
				col = tick % 4
				row = 1
		elif state == "LEAVING" and str(ctx.get("leaving_reason", "")) == "quota_met":
			# Success / happy completion
			col = 2 + ((tick / 3) % 2)
			row = 2
		elif state in ["WALKING_TO", "ENTERING", "LEAVING"]:
			# Walk 4 phases
			col = 2 + (tick % 4)
			row = 0
		elif state == "QUEUEING":
			# Tired waiting or breathing
			col = (tick / 3) % 2
			row = 2
		else: # "SELECTING_TARGET" or idle
			col = (tick / 3) % 2
			row = 0

		return _get_atlas_subtexture(_aluo_tex, col, row, facing_left)

	# Generic Member
	if _generic_tex == null:
		_load_sheets()
	if _generic_tex == null:
		return null

	var member_id: int = int(ctx.get("member_id", 0))
	var variant: int = posmod(member_id, 4)
	var equip_id: String = str(ctx.get("equipment_id", ""))
	var col := 0
	var row := variant # 4 rows, one per variant

	if state == "USING":
		if equip_id == "bike":
			if _equip_workout_tex == null:
				_load_sheets()
			if _equip_workout_tex != null:
				return _get_atlas_subtexture(_equip_workout_tex, (tick / 2) % 2, 1 + variant, facing_left)
			col = 4 + (tick % 2)
		elif equip_id == "bench_press":
			if _equip_workout_tex == null:
				_load_sheets()
			if _equip_workout_tex != null:
				return _get_atlas_subtexture(_equip_workout_tex, 2 + ((tick / 4) % 2), 1 + variant, false)
			col = 4 + (tick % 2)
		elif equip_id == "yoga_mat":
			if _equip_workout_tex == null:
				_load_sheets()
			if _equip_workout_tex != null:
				return _get_atlas_subtexture(_equip_workout_tex, 4 + ((tick / 4) % 2), 1 + variant, facing_left)
			col = 4 + (tick % 2)
		elif equip_id == "treadmill":
			col = 4 + (tick % 2)
		else:
			col = 4 + (tick % 2)
	elif state in ["WALKING_TO", "ENTERING", "LEAVING"]:
		col = 2 + (tick % 2)
	else:
		col = (tick / 3) % 2

	return _get_atlas_subtexture(_generic_tex, col, row, facing_left)
