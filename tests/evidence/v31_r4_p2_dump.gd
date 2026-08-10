# tests/evidence/v31_r4_p2_dump.gd — V3.1 返工4 P2 隔离子图 dump（设备纹理自检）
#
# 不渲染场景：直接调用 EquipmentArt 工厂，把每台设备的
#   top（texture_for R0）/ front / side（extrusion_faces_for 渲染路径产物）
# 放大 4x（最近邻）保存为 PNG —— 供 PIL QA 量化轮廓连续性 / 三面色阶 /
# 关键零部件 2x 可读性，与 GPT 视觉自检共用同一隔离子图。
#
# 输出：tests/evidence/v31-r4-p2-sprite-<equipment_id>.png（每台一张，
# top | front | side 竖排拼接，4x 放大）。
#
# 用法（headless 即可 —— 不抓视口）：
#   godot --headless --script tests/evidence/v31_r4_p2_dump.gd
extends SceneTree

const EquipmentArt := preload("res://src/presentation/equipment_art.gd")
const Palette := preload("res://src/palette.gd")

const ZONE_OF := {"treadmill": "cardio", "bike": "cardio", "bench_press": "strength", "yoga_mat": "flex"}
const MAG := 4  # 放大倍数（最近邻）—— 隔离子图便于肉眼/PIL 判定

var _fail := 0


func _init() -> void:
	_run()
	quit(0 if _fail == 0 else 1)


func _run() -> void:
	var art := EquipmentArt.new()
	for eq_id in ZONE_OF:
		var zone: String = ZONE_OF[eq_id]
		var top: Image = art.texture_for(eq_id, zone, 0).get_image()
		var height: float = art.height_for(eq_id)
		var faces: Dictionary = art.extrusion_faces_for(eq_id, zone, 0, height)
		var front: Image = null
		var side: Image = null
		if faces.get("front") != null:
			front = (faces["front"] as ImageTexture).get_image()
		if faces.get("side") != null:
			side = (faces["side"] as ImageTexture).get_image()
		if top == null or front == null or side == null:
			push_error("v31_r4_p2_dump: %s missing textures" % eq_id)
			_fail += 1
			continue
		# 竖排拼接：top | front | side（4px 间隙），4x 放大
		var gap := 4 * MAG
		var w := maxi(maxi(top.get_width(), front.get_width()), side.get_width()) * MAG
		var h := (top.get_height() + front.get_height() + side.get_height()) * MAG + gap * 2
		var sheet := Image.create(w, h, false, Image.FORMAT_RGBA8)
		sheet.fill(Color(0, 0, 0, 0))
		var y := 0
		_blit_scaled(sheet, top, MAG, 0, y)
		y += top.get_height() * MAG + gap
		_blit_scaled(sheet, front, MAG, 0, y)
		y += front.get_height() * MAG + gap
		_blit_scaled(sheet, side, MAG, 0, y)
		var out := ProjectSettings.globalize_path("res://tests/evidence/v31-r4-p2-sprite-%s.png" % eq_id)
		var err := sheet.save_png(out)
		if err != OK:
			push_error("v31_r4_p2_dump: save failed %s err=%d" % [out, err])
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
