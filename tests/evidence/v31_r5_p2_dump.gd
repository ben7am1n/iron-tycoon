# tests/evidence/v31_r5_p2_dump.gd — V3.1 返工5 P2 隔离子图 dump（会员 sprite 自检）
#
# 不渲染场景：直接调用 MemberSprite 工厂，把关键姿态的 48×48 纹理放大 4x
# （最近邻）保存为 PNG —— 供 PIL QA 量化肢体结构 / 深色外轮廓 / 三阶色阶 /
# 关键零部件 2x 可读性，与 GPT 视觉自检共用同一隔离子图。
#
# 输出：tests/evidence/v31-r5-p2-member-<pose>.png（每姿态一张，4x 放大）。
#
# 用法（headless 即可 —— 不抓视口）：
#   godot --headless --script tests/evidence/v31_r5_p2_dump.gd
extends SceneTree

const MemberSprite := preload("res://src/presentation/member_sprite.gd")
const Palette := preload("res://src/palette.gd")

const MAG := 4  # 放大倍数（最近邻）—— 隔离子图便于肉眼/PIL 判定

## 姿态清单：state 通道 + 设备 ctx（与 capture 注入同源）。
## 每人：pose_key / state / tick / ctx（member_id 变体）。
const SAMPLES := [
	{"key": "walk_v0", "state": "WALKING_TO", "tick": 0, "ctx": {"member_id": 0}},
	{"key": "walk_v1", "state": "WALKING_TO", "tick": 0, "ctx": {"member_id": 1}},
	{"key": "walk_v2", "state": "WALKING_TO", "tick": 0, "ctx": {"member_id": 2}},
	{"key": "walk_v3", "state": "WALKING_TO", "tick": 0, "ctx": {"member_id": 3}},
	{"key": "wait", "state": "QUEUEING", "tick": 0, "ctx": {"member_id": 0}},
	{"key": "satisfied", "state": "LEAVING", "tick": 0, "ctx": {"member_id": 0, "leaving_reason": "quota_met"}},
	{"key": "treadmill", "state": "USING", "tick": 0, "ctx": {"member_id": 0, "equipment_id": "treadmill"}},
	{"key": "bike", "state": "USING", "tick": 0, "ctx": {"member_id": 0, "equipment_id": "bike"}},
	{"key": "bench", "state": "USING", "tick": 0, "ctx": {"member_id": 0, "equipment_id": "bench_press"}},
	{"key": "yoga", "state": "USING", "tick": 0, "ctx": {"member_id": 0, "equipment_id": "yoga_mat"}},
]

var _fail := 0


func _init() -> void:
	_run()
	quit(0 if _fail == 0 else 1)


func _run() -> void:
	var art := MemberSprite.new()
	for sample in SAMPLES:
		var tex: ImageTexture = art.texture_for(sample["state"], sample["tick"], false, sample["ctx"])
		var img := tex.get_image()
		if img == null:
			push_error("v31_r5_p2_dump: %s missing texture" % sample["key"])
			_fail += 1
			continue
		var w := img.get_width() * MAG
		var h := img.get_height() * MAG
		var sheet := Image.create(w, h, false, Image.FORMAT_RGBA8)
		sheet.fill(Color(0, 0, 0, 0))
		_blit_scaled(sheet, img, MAG, 0, 0)
		var out := ProjectSettings.globalize_path("res://tests/evidence/v31-r5-p2-member-%s.png" % sample["key"])
		var err := sheet.save_png(out)
		if err != OK:
			push_error("v31_r5_p2_dump: save failed %s err=%d" % [out, err])
			_fail += 1
		else:
			print("DUMP saved=%s %dx%d" % [out, sheet.get_width(), sheet.get_height()])


func _blit_scaled(dst: Image, src: Image, mag: int, ox: int, oy: int) -> void:
	for sy in src.get_height():
		for sx in src.get_width():
			var c := src.get_pixel(sx, sy)
			for dy in mag:
				for dx in mag:
					dst.set_pixel(ox + sx * mag + dx, oy + sy * mag + dy, c)
