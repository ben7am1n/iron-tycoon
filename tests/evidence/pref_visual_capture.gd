# A1 会员偏好视觉证据：生成四类性格同屏阵列与状态通道对照。
# Run: godot --headless --script tests/evidence/pref_visual_capture.gd
extends SceneTree

const MemberSpriteScript := preload("res://src/presentation/member_sprite.gd")
const Palette := preload("res://src/palette.gd")

const OUT_LINEUP := "res://tests/evidence/pref-visual-lineup.png"
const OUT_STATES := "res://tests/evidence/pref-visual-state-channel.png"
const SCALE := 3
const CARD_W := 176
const CARD_H := 208
const MARGIN := 20

const FONT := {
	"A": ["010", "101", "111", "101", "101"],
	"B": ["110", "101", "110", "101", "110"],
	"C": ["011", "100", "100", "100", "011"],
	"D": ["110", "101", "101", "101", "110"],
	"E": ["111", "100", "110", "100", "111"],
	"F": ["111", "100", "110", "100", "100"],
	"G": ["011", "100", "101", "101", "011"],
	"H": ["101", "101", "111", "101", "101"],
	"I": ["111", "010", "010", "010", "111"],
	"K": ["101", "101", "110", "101", "101"],
	"L": ["100", "100", "100", "100", "111"],
	"N": ["101", "111", "111", "111", "101"],
	"O": ["010", "101", "101", "101", "010"],
	"P": ["110", "101", "110", "100", "100"],
	"Q": ["010", "101", "101", "111", "011"],
	"R": ["110", "101", "110", "101", "101"],
	"S": ["011", "100", "010", "001", "110"],
	"T": ["111", "010", "010", "010", "010"],
	"U": ["101", "101", "101", "101", "111"],
	"V": ["101", "101", "101", "101", "010"],
	"W": ["101", "101", "111", "111", "101"],
	"X": ["101", "101", "010", "101", "101"],
	"Y": ["101", "101", "010", "010", "010"],
	"1": ["010", "110", "010", "010", "111"],
	"-": ["000", "000", "111", "000", "000"],
	" ": ["000", "000", "000", "000", "000"],
}


func _init() -> void:
	var sprites := MemberSpriteScript.new()
	var lineup := _render_strip(sprites, [
		{"label": "STRENGTH", "state": "WALKING_TO", "pref": "STRENGTH", "member_id": 0},
		{"label": "CARDIO", "state": "WALKING_TO", "pref": "CARDIO", "member_id": 0},
		{"label": "FLEX", "state": "WALKING_TO", "pref": "FLEX", "member_id": 0},
		{"label": "BALANCED", "state": "WALKING_TO", "pref": "BALANCED", "member_id": 0},
	], "A1 PREFERENCE VISUAL IDENTITY")
	var states := _render_strip(sprites, [
		{"label": "WALKING", "state": "WALKING_TO", "pref": "STRENGTH", "member_id": 0},
		{"label": "QUEUEING", "state": "QUEUEING", "pref": "STRENGTH", "member_id": 0},
		{"label": "USING", "state": "USING", "pref": "STRENGTH", "member_id": 0,
			"equipment_id": ""},
		{"label": "LEAVING", "state": "LEAVING", "pref": "STRENGTH", "member_id": 0},
	], "STATE COLOR + STRENGTH IDENTITY")
	var lineup_error := lineup.save_png(ProjectSettings.globalize_path(OUT_LINEUP))
	var states_error := states.save_png(ProjectSettings.globalize_path(OUT_STATES))
	if lineup_error != OK or states_error != OK:
		printerr("pref visual evidence save failed: %s / %s" % [lineup_error, states_error])
		quit(1)
		return
	print("saved %s" % OUT_LINEUP)
	print("saved %s" % OUT_STATES)
	quit(0)


func _render_strip(sprites, entries: Array, title: String) -> Image:
	var width := MARGIN * 2 + CARD_W * entries.size()
	var height := MARGIN * 2 + CARD_H
	var image := Image.create(width, height, false, Image.FORMAT_RGBA8)
	image.fill(Palette.CREAM_BG)
	_draw_text(image, title, Vector2i(MARGIN, 6), 2, Palette.CHARCOAL)
	for i in entries.size():
		var entry: Dictionary = entries[i]
		var card_x := MARGIN + i * CARD_W
		var card := Rect2i(card_x + 4, 30, CARD_W - 8, CARD_H - 12)
		image.fill_rect(card, Palette.HIGHLIGHT_WARM)
		var accent: Color = sprites.preference_accent(str(entry["pref"]))
		image.fill_rect(Rect2i(card_x + 4, 30, CARD_W - 8, 6), accent)
		_draw_text(image, str(entry["label"]), Vector2i(card_x + 14, 43), 2, Palette.CHARCOAL)
		var ctx := {
			"member_id": int(entry["member_id"]),
			"preference_profile": {"type": str(entry["pref"])},
		}
		if entry.has("equipment_id"):
			ctx["equipment_id"] = str(entry["equipment_id"])
		var sprite: Image = sprites.texture_for(str(entry["state"]), 0, false, ctx).get_image()
		sprite.resize(MemberSpriteScript.SIZE * SCALE, MemberSpriteScript.SIZE * SCALE,
			Image.INTERPOLATE_NEAREST)
		image.blend_rect(sprite, Rect2i(Vector2i.ZERO, sprite.get_size()),
			Vector2i(card_x + (CARD_W - sprite.get_width()) / 2, 65))
	return image


func _draw_text(image: Image, value: String, origin: Vector2i, scale: int, color: Color) -> void:
	var cursor_x := origin.x
	for character in value.to_upper():
		var rows: Array = FONT.get(character, FONT[" "])
		for y in rows.size():
			var row: String = rows[y]
			for x in row.length():
				if row[x] != "1":
					continue
				image.fill_rect(Rect2i(cursor_x + x * scale, origin.y + y * scale,
					scale, scale), color)
		cursor_x += 4 * scale
