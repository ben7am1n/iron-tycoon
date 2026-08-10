# tests/evidence/dump_sprites_for_analysis.gd — dump member/equipment textures to PNG for PIL analysis
extends SceneTree

const MemberSpriteScript := preload("res://src/presentation/member_sprite.gd")
const EquipmentArtScript := preload("res://src/presentation/equipment_art.gd")
const OUT_DIR := "/tmp/sprite_dump"

func _init() -> void:
	DirAccess.make_dir_recursive_absolute(OUT_DIR)
	var ms := MemberSpriteScript.new()
	var poses := [
		["idle", "SELECTING_TARGET", {}],
		["walkA", "WALKING_TO", {"tick": 0}],
		["walkB", "WALKING_TO", {"tick": 1}],
		["tiredA", "QUEUEING", {"tick": 0}],
		["tiredB", "QUEUEING", {"tick": 1}],
		["satA", "LEAVING", {"tick": 0, "leaving_reason": "quota_met"}],
		["satB", "LEAVING", {"tick": 1, "leaving_reason": "quota_met"}],
		["tmA", "USING", {"tick": 0, "equipment_id": "treadmill"}],
		["tmB", "USING", {"tick": 1, "equipment_id": "treadmill"}],
		["bikeA", "USING", {"tick": 0, "equipment_id": "bike"}],
		["bikeB", "USING", {"tick": 1, "equipment_id": "bike"}],
		["benchA", "USING", {"tick": 0, "equipment_id": "bench_press"}],
		["benchB", "USING", {"tick": 1, "equipment_id": "bench_press"}],
		["yogaA", "USING", {"tick": 0, "equipment_id": "yoga_mat"}],
		["yogaB", "USING", {"tick": 1, "equipment_id": "yoga_mat"}],
		["genericA", "USING", {"tick": 0, "equipment_id": ""}],
		["genericB", "USING", {"tick": 1, "equipment_id": ""}],
	]
	for p in poses:
		var name: String = p[0]
		var state: String = p[1]
		var ctx: Dictionary = p[2]
		var tex := ms.texture_for(state, int(ctx.get("tick", 0)), false, ctx)
		var img := tex.get_image()
		# raw 1x for pin-checking
		img.save_png("%s/raw_%s.png" % [OUT_DIR, name])
		# upscale 3x for ASCII viewing
		var big := Image.create(img.get_width() * 3, img.get_height() * 3, false, Image.FORMAT_RGBA8)
		for y in img.get_height():
			for x in img.get_width():
				for dy in 3:
					for dx in 3:
						big.set_pixel(x * 3 + dx, y * 3 + dy, img.get_pixel(x, y))
		big.save_png("%s/member_%s.png" % [OUT_DIR, name])
	var eq := EquipmentArtScript.new()
	for eid in ["treadmill", "bike", "bench_press", "yoga_mat"]:
		var tex := eq.texture_for(eid, "cardio", 0)
		var img := tex.get_image()
		img.save_png("%s/raw_equip_%s_top.png" % [OUT_DIR, eid])
		var big := Image.create(img.get_width() * 3, img.get_height() * 3, false, Image.FORMAT_RGBA8)
		for y in img.get_height():
			for x in img.get_width():
				for dy in 3:
					for dx in 3:
						big.set_pixel(x * 3 + dx, y * 3 + dy, img.get_pixel(x, y))
		big.save_png("%s/equip_%s_top.png" % [OUT_DIR, eid])
		var faces := eq.raw_face_images(eid, "cardio")
		for fname in ["front", "side"]:
			var fimg: Image = faces.get(fname)
			if fimg == null:
				continue
			fimg.save_png("%s/raw_equip_%s_%s.png" % [OUT_DIR, eid, fname])
			var fbig := Image.create(fimg.get_width() * 3, fimg.get_height() * 3, false, Image.FORMAT_RGBA8)
			for y in fimg.get_height():
				for x in fimg.get_width():
					for dy in 3:
						for dx in 3:
							fbig.set_pixel(x * 3 + dx, y * 3 + dy, fimg.get_pixel(x, y))
			fbig.save_png("%s/equip_%s_%s.png" % [OUT_DIR, eid, fname])
	quit(0)
