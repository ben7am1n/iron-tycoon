# tests/unit/member_sprite/sprite_bank_test.gd
# Story: visual-polish-v2 / phase-c-member-characters
# (design/art/art-bible-25d-style.md §1/§2/§3/§4 + art-bible.md §4/§7)
#
# BLOCKING assertions (Phase C v2 exit conditions 1/2/3 的 headless 侧验证):
#   - 状态双通道映射：walking 状态群 → Sky 通道 / queue·using → Peach 通道 /
#     leaving → 低饱和灰通道 / GONE·被动 → 不渲染（""）
#   - 姿态通道：walk / idle / use 按状态映射，帧位按 tick 交替
#     （walk·use 10Hz 观感 / idle 5Hz 微晃 —— 游戏逻辑 60fps 不变）
#   - 颜色通道像素正确：衬衫像素 == palette 对应色（单一色源，非硬编码）
#   - 朝向镜像：facing_left 纹理 == facing_right 的水平镜像（逐像素）
#   - 确定性：同一状态/帧两次生成像素一致
#   - 像素阶梯：轮廓边缘硬切换（透明 → 不透明之间无中间色），
#     无抗锯齿柔滑（art-bible-25d §3 负面约束）
#   - 帧动画差异：walk A/B 迈步帧像素不同（摆臂/迈腿真实存在）
#
# Run standalone: godot --headless --script tests/unit/member_sprite/sprite_bank_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const MemberSpriteScript := preload("res://src/presentation/member_sprite.gd")
const Palette := preload("res://src/palette.gd")

const SIZE := 32
const EPS := 1.0 / 255.0  # RGBA8 量化容差

var _pass := 0
var _fail := 0


func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	var result := run_all()
	quit(1 if int(result["fail"]) > 0 else 0)


func run_all() -> Dictionary:
	print("=".repeat(48))
	print("  UNIT TEST: Member Sprite Bank (Phase C v2 — 2.5D 像素小人)")
	print("=".repeat(48))

	_test_state_channel_mapping()
	_test_state_pose_mapping()
	_test_frame_bit_cadence()
	_test_shirt_color_channel_pixels()
	_test_facing_mirror()
	_test_determinism()
	_test_pixel_staircase_no_smoothing()
	_test_walk_frames_differ()
	_test_leave_gray_desaturated()
	_test_texture_size_and_format()

	print("-".repeat(48))
	print("  RESULT: %d passed, %d failed" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
	else:
		_fail += 1
		printerr("  FAIL: %s" % msg)


func _near(a: Color, b: Color) -> bool:
	return absf(a.r - b.r) < EPS and absf(a.g - b.g) < EPS \
		and absf(a.b - b.b) < EPS and absf(a.a - b.a) < EPS


# === 用例 ===

func _test_state_channel_mapping() -> void:
	var s := MemberSpriteScript.new()
	_check(s.state_channel("WALKING_TO") == "sky", "WALKING_TO → sky")
	_check(s.state_channel("ENTERING") == "sky", "ENTERING → sky")
	_check(s.state_channel("SELECTING_TARGET") == "sky", "SELECTING_TARGET → sky")
	_check(s.state_channel("QUEUEING") == "peach", "QUEUEING → peach")
	_check(s.state_channel("USING") == "peach", "USING → peach")
	_check(s.state_channel("LEAVING") == "gray", "LEAVING → gray")
	_check(s.state_channel("GONE") == "", "GONE → 不渲染")
	_check(s.state_channel("") == "", "被动成员（无 state）→ 不渲染")
	_check(s.state_channel("BOGUS") == "", "未知状态 → 不渲染")


func _test_state_pose_mapping() -> void:
	var s := MemberSpriteScript.new()
	_check(s.state_pose("WALKING_TO") == "walk", "WALKING_TO → walk 姿态")
	_check(s.state_pose("ENTERING") == "walk", "ENTERING → walk 姿态")
	_check(s.state_pose("LEAVING") == "walk", "LEAVING → walk 姿态（离场步伐）")
	_check(s.state_pose("QUEUEING") == "idle", "QUEUEING → idle 姿态")
	_check(s.state_pose("SELECTING_TARGET") == "idle", "SELECTING_TARGET → idle 姿态")
	_check(s.state_pose("USING") == "use", "USING → use 姿态（动作幅度明显）")


func _test_frame_bit_cadence() -> void:
	var s := MemberSpriteScript.new()
	# walk：tick 奇偶交替（10Hz 观感）
	_check(s.frame_bit("WALKING_TO", 0) == 0, "walk tick0 → frame A")
	_check(s.frame_bit("WALKING_TO", 1) == 1, "walk tick1 → frame B")
	_check(s.frame_bit("WALKING_TO", 2) == 0, "walk tick2 → frame A")
	# use：同样 10Hz 交替
	_check(s.frame_bit("USING", 3) == 1, "use tick3 → frame B")
	# idle：每 2 tick 交替（5Hz 微晃）
	_check(s.frame_bit("QUEUEING", 0) == 0, "idle tick0 → A")
	_check(s.frame_bit("QUEUEING", 1) == 0, "idle tick1 → A（慢）")
	_check(s.frame_bit("QUEUEING", 2) == 1, "idle tick2 → B")
	_check(s.frame_bit("QUEUEING", 3) == 1, "idle tick3 → B（慢）")


func _test_shirt_color_channel_pixels() -> void:
	var s := MemberSpriteScript.new()
	# 衬衫采样点：躯干行内、不在手臂/手上（本地坐标 (16, 15) 是衬衫块）
	var p := Vector2i(16, 15)
	_check(_near(_tex_pixel(s, "WALKING_TO", 0, false, p), Palette.SKY),
		"walking 衬衫像素 == SKY（实际 %s）" % _tex_pixel(s, "WALKING_TO", 0, false, p))
	_check(_near(_tex_pixel(s, "QUEUEING", 0, false, p), Palette.PEACH),
		"queue 衬衫像素 == PEACH")
	_check(_near(_tex_pixel(s, "USING", 0, false, p), Palette.PEACH),
		"using 衬衫像素 == PEACH")
	_check(_near(_tex_pixel(s, "LEAVING", 0, false, p), Palette.MEMBER_LEAVE_GRAY),
		"leaving 衬衫像素 == MEMBER_LEAVE_GRAY（低饱和灰）")
	# 衬衫下摆阴影 = 衬衫色 darkened（非硬编码新色）
	_check(_near(_tex_pixel(s, "WALKING_TO", 0, false, Vector2i(16, 20)),
		Palette.SKY.darkened(0.15)), "walking 下摆 == SKY.darkened(0.15)")
	# 头发 / 皮肤 / 裤 / 鞋 均来自 palette（非黑描边 —— CHARCOAL 仅用于五官）
	_check(_near(_tex_pixel(s, "WALKING_TO", 0, false, Vector2i(16, 2)), Palette.MEMBER_HAIR),
		"发 == MEMBER_HAIR")
	_check(_near(_tex_pixel(s, "WALKING_TO", 0, false, Vector2i(16, 6)), Palette.MEMBER_SKIN),
		"脸 == MEMBER_SKIN")
	_check(_near(_tex_pixel(s, "WALKING_TO", 0, false, Vector2i(12, 22)), Palette.MEMBER_PANTS),
		"裤 == MEMBER_PANTS")
	_check(_near(_tex_pixel(s, "WALKING_TO", 0, false, Vector2i(12, 28)), Palette.MEMBER_SHOE),
		"鞋 == MEMBER_SHOE")
	_check(_near(_tex_pixel(s, "WALKING_TO", 0, false, Vector2i(12, 8)), Palette.CHARCOAL),
		"眼 == CHARCOAL（软炭，非纯黑）")
	# 阴影行存在（低透明暗块）
	var shadow := _tex_pixel(s, "WALKING_TO", 0, false, Vector2i(16, 31))
	_check(shadow.a > 0.0 and shadow.a < 0.5 and shadow.r < 0.5,
		"脚底阴影 == 低透明暗块（实际 %s）" % shadow)


func _test_facing_mirror() -> void:
	var s := MemberSpriteScript.new()
	var right := s.texture_for("WALKING_TO", 3, false).get_image()
	var left := s.texture_for("WALKING_TO", 3, true).get_image()
	var mismatches := 0
	for y in SIZE:
		for x in SIZE:
			if not _near(left.get_pixel(x, y), right.get_pixel(SIZE - 1 - x, y)):
				mismatches += 1
	_check(mismatches == 0, "facing_left == facing_right 水平镜像（mismatch=%d）" % mismatches)
	# 镜像不是原图（确实有翻转差异，防退化实现）
	var identical := true
	for y in SIZE:
		for x in SIZE:
			if not _near(left.get_pixel(x, y), right.get_pixel(x, y)):
				identical = false
				break
		if not identical:
			break
	_check(not identical, "左/右朝向纹理确实不同（非退化）")


func _test_determinism() -> void:
	var s := MemberSpriteScript.new()
	var a := s.texture_for("QUEUEING", 4, false).get_image()
	var b := s.texture_for("QUEUEING", 4, false).get_image()
	var mismatches := 0
	for y in SIZE:
		for x in SIZE:
			if not _near(a.get_pixel(x, y), b.get_pixel(x, y)):
				mismatches += 1
	_check(mismatches == 0, "同状态/帧两次生成像素一致（确定性）")


func _test_pixel_staircase_no_smoothing() -> void:
	# art-bible-25d §3：禁止柔滑无像素感的角色轮廓 —— 轮廓边缘必须是
	# 硬切换（透明 ↔ 不透明之间无中间 alpha）。检查发际线/肩膀边缘。
	var s := MemberSpriteScript.new()
	var img := s.texture_for("WALKING_TO", 0, false).get_image()
	# 发际线左侧：行 4 发16宽（x8..23），x7 透明、x8 发色（硬边）
	var a := img.get_pixel(7, 4)
	var b := img.get_pixel(8, 4)
	_check(a.a == 0.0 and b.a > 0.9,
		"发际线硬边：x7 alpha=%.2f（透明）, x8 alpha=%.2f（发色）" % [a.a, b.a])
	# 肩膀右侧：臂行内 x23 为臂色、x24 透明（硬边；躯干行 x8..23）
	var c := img.get_pixel(23, 14)
	var d := img.get_pixel(24, 14)
	_check(c.a > 0.9 and d.a == 0.0,
		"肩膀硬边：x23 alpha=%.2f（臂色）, x24 alpha=%.2f（透明）" % [c.a, d.a])


func _test_walk_frames_differ() -> void:
	# 摆臂迈步真实存在：walk A 与 walk B 必须像素不同（腿/臂位置互换）
	var s := MemberSpriteScript.new()
	var a := s.texture_for("WALKING_TO", 0, false).get_image()
	var b := s.texture_for("WALKING_TO", 1, false).get_image()
	var diff := 0
	for y in SIZE:
		for x in SIZE:
			if not _near(a.get_pixel(x, y), b.get_pixel(x, y)):
				diff += 1
	_check(diff > 4, "walk A/B 迈步帧存在像素差异（diff=%d）" % diff)
	# use A/B 同样不同（上举 vs 下垂）
	var ua := s.texture_for("USING", 0, false).get_image()
	var ub := s.texture_for("USING", 1, false).get_image()
	var udiff := 0
	for y in SIZE:
		for x in SIZE:
			if not _near(ua.get_pixel(x, y), ub.get_pixel(x, y)):
				udiff += 1
	_check(udiff > 4, "use A/B 泵帧存在像素差异（diff=%d）" % udiff)


func _test_leave_gray_desaturated() -> void:
	# leaving 通道必须是低饱和灰（脱出饱和区，与 Sky/Peach 明显区分）
	var gray := Palette.MEMBER_LEAVE_GRAY
	var max_channel := maxf(gray.r, maxf(gray.g, gray.b))
	var min_channel := minf(gray.r, minf(gray.g, gray.b))
	var sat := max_channel - min_channel
	_check(sat < 0.08, "LEAVE_GRAY 饱和度 < 0.08（实际 %.3f）" % sat)
	_check(gray.r > 0.5, "LEAVE_GRAY 明度中调（非纯黑）")
	# 与 Sky / Peach 的 RGB 距离均足够大（色盲安全：不只靠色相）
	var d_sky := sqrt(pow(gray.r - Palette.SKY.r, 2) + pow(gray.g - Palette.SKY.g, 2) \
		+ pow(gray.b - Palette.SKY.b, 2))
	var d_peach := sqrt(pow(gray.r - Palette.PEACH.r, 2) + pow(gray.g - Palette.PEACH.g, 2) \
		+ pow(gray.b - Palette.PEACH.b, 2))
	_check(d_sky > 0.15, "灰 vs Sky 距离 > 0.15（实际 %.3f）" % d_sky)
	_check(d_peach > 0.15, "灰 vs Peach 距离 > 0.15（实际 %.3f）" % d_peach)


func _test_texture_size_and_format() -> void:
	var s := MemberSpriteScript.new()
	var tex := s.texture_for("USING", 0, true)
	_check(tex.get_size() == Vector2(SIZE, SIZE), "纹理尺寸 32×32")
	_check(tex.get_image().get_format() == Image.FORMAT_RGBA8, "纹理格式 RGBA8")


func _tex_pixel(s, state: String, tick: int, left: bool, p: Vector2i) -> Color:
	return s.texture_for(state, tick, left).get_image().get_pixel(p.x, p.y)
