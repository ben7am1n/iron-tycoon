# tests/unit/member_sprite/sprite_bank_test.gd
# Story: visual-remaster-v3 / phase4-member-redraw
# (design/art/visual-remaster-spec-v3.md §8/§9/§11 + art-bible.md §4/§7)
#
# BLOCKING assertions (Phase 4 exit conditions 1/2 的 headless 侧验证):
#   - 状态双通道映射：walking 状态群 → Sky 通道 / queue·using → Peach 通道 /
#     leaving → 低饱和灰通道 / GONE·被动 → 不渲染（""）
#   - 姿态通道（V3 §8 更丰富）：walk / idle / tired / satisfied / use_*
#     按状态 + 上下文映射；QUEUEING → tired（累弯腰擦汗喘气 + 汗滴）、
#     LEAVING+quota_met → satisfied（挺胸举手 + 闪光）
#   - 设备专属使用姿态（V3 §8 与设备互动匹配）：treadmill / bench_press /
#     bike / yoga_mat → 各不相同；bench 结束坐起窗口（use_ticks_remaining）
#   - 颜色通道像素正确：衬衫像素 == palette 对应色（单一色源，非硬编码）
#   - V3 §8 阴影侧/高光侧：左高光右阴影（同色源 lightened/darkened 派生）
#   - V3 §11 深色轮廓：剪影边缘存在 CHARCOAL 轮廓环（非透明直跳主体色）
#   - 微元素（V3 §9）：tired 头顶 BUTTER 汗滴、satisfied 闪光 BUTTER 像素
#   - 外观变体（V3 §8 每人清晰发型/皮肤色块）：member_id → 不同发色/肤色
#   - 朝向镜像：facing_left 纹理 == facing_right 的水平镜像（逐像素）
#   - 确定性：同一状态/帧两次生成像素一致
#   - 像素阶梯：轮廓边缘硬切换（透明 → 不透明之间无中间色），无抗锯齿
#   - 帧动画差异：walk A/B 迈步帧像素不同（摆臂/迈腿真实存在）
#
# Run standalone: godot --headless --script tests/unit/member_sprite/sprite_bank_test.gd
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const MemberSpriteScript := preload("res://src/presentation/member_sprite.gd")
const Palette := preload("res://src/palette.gd")

const SIZE := 48
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
	print("  UNIT TEST: Member Sprite Bank (Phase 4 — V3 §8 大尺寸表现力小人)")
	print("=".repeat(48))

	_test_state_channel_mapping()
	_test_state_pose_mapping()
	_test_use_pose_mapping()
	_test_frame_bit_cadence()
	_test_shirt_color_channel_pixels()
	_test_directional_shade()
	_test_dark_outline()
	_test_micro_elements()
	_test_appearance_variants()
	_test_bench_situp_window()
	_test_satisfied_vs_walk()
	_test_tired_vs_idle()
	_test_equipment_poses_differ()
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
	_check(s.state_pose("LEAVING") == "walk", "LEAVING → walk 姿态（基础；quota_met 由 ctx 升级为 satisfied）")
	_check(s.state_pose("QUEUEING") == "tired", "QUEUEING → tired 姿态（V3 §8 累弯腰擦汗）")
	_check(s.state_pose("SELECTING_TARGET") == "idle", "SELECTING_TARGET → idle 姿态")
	_check(s.state_pose("USING") == "use", "USING → use 姿态（设备专属由 ctx 解析）")


func _test_use_pose_mapping() -> void:
	var s := MemberSpriteScript.new()
	_check(s.use_pose("treadmill") == "use_treadmill", "treadmill → 跑带奔跑姿态")
	_check(s.use_pose("bench_press") == "use_bench", "bench_press → 卧推姿态")
	_check(s.use_pose("bike") == "use_bike", "bike → 骑行姿态")
	_check(s.use_pose("yoga_mat") == "use_yoga", "yoga_mat → 瑜伽姿态")
	_check(s.use_pose("") == "use_generic", "未知设备 → 泵举兜底")
	_check(s.use_pose("nonexistent") == "use_generic", "不存在设备 → 泵举兜底（不崩溃）")


func _test_frame_bit_cadence() -> void:
	var s := MemberSpriteScript.new()
	# walk：tick 奇偶交替（10Hz 观感）
	_check(s.frame_bit("WALKING_TO", 0) == 0, "walk tick0 → frame A")
	_check(s.frame_bit("WALKING_TO", 1) == 1, "walk tick1 → frame B")
	_check(s.frame_bit("WALKING_TO", 2) == 0, "walk tick2 → frame A")
	# use：同样 10Hz 交替
	_check(s.frame_bit("USING", 3) == 1, "use tick3 → frame B")
	# tired / satisfied：10Hz 交替（擦汗/闪光节奏）
	_check(s.frame_bit("QUEUEING", 4) == 0, "tired tick4 → A")
	_check(s.frame_bit("QUEUEING", 5) == 1, "tired tick5 → B")
	_check(s.frame_bit("LEAVING", 5) == 1, "satisfied base tick5 → B")
	# idle：每 2 tick 交替（5Hz 微晃）
	_check(s.frame_bit("SELECTING_TARGET", 0) == 0, "idle tick0 → A")
	_check(s.frame_bit("SELECTING_TARGET", 1) == 0, "idle tick1 → A（慢）")
	_check(s.frame_bit("SELECTING_TARGET", 2) == 1, "idle tick2 → B")
	_check(s.frame_bit("SELECTING_TARGET", 3) == 1, "idle tick3 → B（慢）")


func _test_shirt_color_channel_pixels() -> void:
	var s := MemberSpriteScript.new()
	# 衬衫采样点：躯干行内、不在手臂/手上（本地坐标 (24, 19) 是衬衫块）
	var p := Vector2i(24, 19)
	_check(_near(_tex_pixel(s, "WALKING_TO", 0, false, p), Palette.SKY),
		"walking 衬衫像素 == SKY（实际 %s）" % _tex_pixel(s, "WALKING_TO", 0, false, p))
	_check(_near(_tex_pixel(s, "QUEUEING", 0, false, p), Palette.PEACH),
		"queue 衬衫像素 == PEACH（实际 %s）" % _tex_pixel(s, "QUEUEING", 0, false, p))
	_check(_near(_tex_pixel(s, "USING", 0, false, p), Palette.PEACH),
		"using 衬衫像素 == PEACH")
	_check(_near(_tex_pixel(s, "LEAVING", 0, false, p), Palette.MEMBER_LEAVE_GRAY),
		"leaving 衬衫像素 == MEMBER_LEAVE_GRAY（低饱和灰）")
	# 衬衫下摆阴影 = 衬衫色 darkened（非硬编码新色）
	_check(_near(_tex_pixel(s, "WALKING_TO", 0, false, Vector2i(24, 27)),
		Palette.SKY.darkened(0.18)), "walking 下摆 == SKY.darkened(0.18)")
	# 头发 / 皮肤 / 裤 / 鞋 均来自 palette（变体 0 = 默认色）
	_check(_near(_tex_pixel(s, "WALKING_TO", 0, false, Vector2i(24, 4)), Palette.MEMBER_HAIR),
		"发 == MEMBER_HAIR")
	_check(_near(_tex_pixel(s, "WALKING_TO", 0, false, Vector2i(24, 6)), Palette.MEMBER_SKIN),
		"脸 == MEMBER_SKIN")
	_check(_near(_tex_pixel(s, "WALKING_TO", 0, false, Vector2i(9, 33)), Palette.MEMBER_PANTS),
		"裤 == MEMBER_PANTS")
	_check(_near(_tex_pixel(s, "WALKING_TO", 0, false, Vector2i(12, 42)), Palette.MEMBER_SHOE),
		"鞋 == MEMBER_SHOE")
	_check(_near(_tex_pixel(s, "WALKING_TO", 0, false, Vector2i(19, 9)), Palette.CHARCOAL),
		"眼 == CHARCOAL（软炭，非纯黑）")
	# 阴影行存在（低透明暗块）
	var shadow := _tex_pixel(s, "WALKING_TO", 0, false, Vector2i(24, 45))
	_check(shadow.a > 0.0 and shadow.a < 0.5 and shadow.r < 0.5,
		"脚底阴影 == 低透明暗块（实际 %s）" % shadow)


func _test_directional_shade() -> void:
	# V3 §8 阴影侧/高光侧：同一行内左高光（lightened）右阴影（darkened）。
	# 躯干行 (24,19) 是衬衫主色；x7 是左高光、x38 是右阴影。
	var s := MemberSpriteScript.new()
	var img := s.texture_for("WALKING_TO", 0, false, {"member_id": 0}).get_image()
	var base := img.get_pixel(24, 19)
	var hl := img.get_pixel(7, 19)
	var sh := img.get_pixel(38, 19)
	_check(_near(hl, Palette.SKY.lightened(0.15)), "左高光 == SKY.lightened(0.15)（实际 %s）" % hl)
	_check(_near(sh, Palette.SKY.darkened(0.22)), "右阴影 == SKY.darkened(0.22)（实际 %s）" % sh)
	_check(_near(base, Palette.SKY), "躯干主色仍为 SKY（高光/阴影只在两侧）")
	# 亮度关系：高光 > 主色 > 阴影（方向光可验证）
	_check(_lum(hl) > _lum(base) and _lum(base) > _lum(sh),
		"方向光亮度：高光(%.3f) > 主色(%.3f) > 阴影(%.3f)" % [_lum(hl), _lum(base), _lum(sh)])


func _test_dark_outline() -> void:
	# V3 §11 人物深色轮廓明显：剪影边缘存在 CHARCOAL 轮廓环。
	# 发际线左侧 x14 是轮廓、x15 是发色；x13 透明（硬切）。
	var s := MemberSpriteScript.new()
	var img := s.texture_for("WALKING_TO", 0, false, {"member_id": 0}).get_image()
	_check(_near(img.get_pixel(14, 4), Palette.CHARCOAL),
		"发际线轮廓 x14 == CHARCOAL（实际 %s）" % img.get_pixel(14, 4))
	_check(img.get_pixel(13, 4).a == 0.0, "轮廓外 x13 透明（硬切）")
	# 肩膀右缘：x39 轮廓、x40 透明
	_check(_near(img.get_pixel(39, 19), Palette.CHARCOAL),
		"肩右缘轮廓 x39 == CHARCOAL（实际 %s）" % img.get_pixel(39, 19))
	_check(img.get_pixel(40, 19).a == 0.0, "肩右缘外 x40 透明")
	# 轮廓存在量：整幅有相当数量的 CHARCOAL 轮廓像素（非零散点缀）
	var outline_count := 0
	for y in SIZE:
		for x in SIZE:
			if _near(img.get_pixel(x, y), Palette.CHARCOAL):
				outline_count += 1
	_check(outline_count > 100, "深色轮廓像素数量充足（%d > 100）" % outline_count)


func _test_micro_elements() -> void:
	# V3 §9 微型动态元素：tired 头顶汗滴（BUTTER）、satisfied 闪光（BUTTER）。
	var s := MemberSpriteScript.new()
	var tired := s.texture_for("QUEUEING", 0, false, {"member_id": 0}).get_image()
	var sweat := tired.get_pixel(22, 0)
	_check(_near(sweat, Palette.BUTTER), "tired 头顶汗滴 == BUTTER（实际 %s）" % sweat)
	var sat := s.texture_for("LEAVING", 0, false, {"leaving_reason": "quota_met", "member_id": 0}).get_image()
	var sparkle := sat.get_pixel(9, 0)
	_check(_near(sparkle, Palette.BUTTER), "satisfied 闪光 == BUTTER（实际 %s）" % sparkle)


func _test_appearance_variants() -> void:
	# V3 §8 每人清晰发型/皮肤色块：member_id 确定性映射到不同外观。
	var s := MemberSpriteScript.new()
	_check(s.variant_for(0) == 0, "member_id 0 → 变体 0（默认色）")
	_check(s.variant_for(1) == 1, "member_id 1 → 变体 1")
	_check(s.variant_for(9) == 1, "member_id 9 → 变体 1（取模）")
	_check(s.variant_for(-1) == 0, "member_id -1（未注入）→ 变体 0")
	var v0 := s.texture_for("WALKING_TO", 0, false, {"member_id": 0}).get_image()
	var v1 := s.texture_for("WALKING_TO", 0, false, {"member_id": 1}).get_image()
	_check(not _near(v0.get_pixel(24, 4), v1.get_pixel(24, 4)),
		"变体 0/1 发色不同（每人清晰发型）")
	_check(not _near(v0.get_pixel(24, 6), v1.get_pixel(24, 6)),
		"变体 0/1 肤色不同（每人皮肤色块）")
	# 同一 member_id 永远同一外观（确定性）
	var v0b := s.texture_for("WALKING_TO", 0, false, {"member_id": 0}).get_image()
	_check(_near(v0.get_pixel(24, 4), v0b.get_pixel(24, 4)), "同一 member_id 外观稳定")


func _test_bench_situp_window() -> void:
	# V3 §8 卧推"结束时坐起"：use_ticks_remaining 进入窗口 → 坐起帧。
	var s := MemberSpriteScript.new()
	var work := s.texture_for("USING", 0, false,
		{"equipment_id": "bench_press", "use_ticks_remaining": 50, "member_id": 0})
	var situp := s.texture_for("USING", 0, false,
		{"equipment_id": "bench_press", "use_ticks_remaining": 3, "member_id": 0})
	var diff := 0
	for y in SIZE:
		for x in SIZE:
			if not _near(work.get_image().get_pixel(x, y), situp.get_image().get_pixel(x, y)):
				diff += 1
	_check(diff > 20, "bench 坐起帧与工作帧像素不同（diff=%d）" % diff)
	# 窗口外长时间剩余不触发坐起
	var outside := s.texture_for("USING", 0, false,
		{"equipment_id": "bench_press", "use_ticks_remaining": 100, "member_id": 0})
	var work_diff := 0
	for y in SIZE:
		for x in SIZE:
			if not _near(work.get_image().get_pixel(x, y), outside.get_image().get_pixel(x, y)):
				work_diff += 1
	_check(work_diff == 0, "窗口外（50/100）同一工作帧（缓存一致）")


func _test_satisfied_vs_walk() -> void:
	# LEAVING + quota_met → satisfied（挺胸举手闪光）；其他原因 → walk。
	var s := MemberSpriteScript.new()
	var sat := s.texture_for("LEAVING", 0, false, {"leaving_reason": "quota_met", "member_id": 0}).get_image()
	var walk := s.texture_for("LEAVING", 0, false, {"leaving_reason": "no_candidates", "member_id": 0}).get_image()
	var diff := 0
	for y in SIZE:
		for x in SIZE:
			if not _near(sat.get_pixel(x, y), walk.get_pixel(x, y)):
				diff += 1
	_check(diff > 20, "satisfied 与普通离场 walk 像素不同（diff=%d）" % diff)


func _test_tired_vs_idle() -> void:
	# QUEUEING → tired（弯腰擦汗喘气 + 汗滴）≠ SELECTING_TARGET → idle。
	var s := MemberSpriteScript.new()
	var tired := s.texture_for("QUEUEING", 0, false, {"member_id": 0}).get_image()
	var idle := s.texture_for("SELECTING_TARGET", 0, false, {"member_id": 0}).get_image()
	var diff := 0
	for y in SIZE:
		for x in SIZE:
			if not _near(tired.get_pixel(x, y), idle.get_pixel(x, y)):
				diff += 1
	_check(diff > 20, "tired 与 idle 像素不同（diff=%d）" % diff)


func _test_equipment_poses_differ() -> void:
	# V3 §8 设备互动姿态：四种设备的使用帧各不相同。
	var s := MemberSpriteScript.new()
	var ids := ["treadmill", "bench_press", "bike", "yoga_mat", ""]
	var imgs: Dictionary = {}
	for id in ids:
		var tex := s.texture_for("USING", 0, false, {"equipment_id": id, "member_id": 0})
		imgs[id] = tex.get_image()
	for i in ids.size():
		for j in range(i + 1, ids.size()):
			var a: Image = imgs[ids[i]]
			var b: Image = imgs[ids[j]]
			var diff := 0
			for y in SIZE:
				for x in SIZE:
					if not _near(a.get_pixel(x, y), b.get_pixel(x, y)):
						diff += 1
			_check(diff > 20, "use(%s) vs use(%s) 像素不同（diff=%d）" % [ids[i], ids[j], diff])


func _test_facing_mirror() -> void:
	var s := MemberSpriteScript.new()
	var right := s.texture_for("WALKING_TO", 3, false, {"member_id": 0}).get_image()
	var left := s.texture_for("WALKING_TO", 3, true, {"member_id": 0}).get_image()
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
	var a := s.texture_for("QUEUEING", 4, false, {"member_id": 0}).get_image()
	var b := s.texture_for("QUEUEING", 4, false, {"member_id": 0}).get_image()
	var mismatches := 0
	for y in SIZE:
		for x in SIZE:
			if not _near(a.get_pixel(x, y), b.get_pixel(x, y)):
				mismatches += 1
	_check(mismatches == 0, "同状态/帧两次生成像素一致（确定性）")


func _test_pixel_staircase_no_smoothing() -> void:
	# art-bible-25d §3 + V3 §2：禁止柔滑轮廓 —— 轮廓边缘硬切换
	# （透明 ↔ 不透明之间无中间 alpha）。检查发际线/肩膀边缘。
	var s := MemberSpriteScript.new()
	var img := s.texture_for("WALKING_TO", 0, false, {"member_id": 0}).get_image()
	# 发际线左侧：行 4 x14 轮廓、x15 发色；x13 透明（硬边，无中间色）
	var a := img.get_pixel(13, 4)
	var b := img.get_pixel(14, 4)
	var c := img.get_pixel(15, 4)
	_check(a.a == 0.0 and b.a > 0.9 and c.a > 0.9,
		"发际线硬边：x13 alpha=%.2f（透明）, x14=%.2f（轮廓）, x15=%.2f（发色）" % [a.a, b.a, c.a])
	# 肩膀右侧：行 19 x39 轮廓、x40 透明（硬边）
	var d := img.get_pixel(39, 19)
	var e := img.get_pixel(40, 19)
	_check(d.a > 0.9 and e.a == 0.0,
		"肩膀硬边：x39 alpha=%.2f（轮廓）, x40 alpha=%.2f（透明）" % [d.a, e.a])


func _test_walk_frames_differ() -> void:
	# 摆臂迈步真实存在：walk A 与 walk B 必须像素不同（腿/臂位置互换）
	var s := MemberSpriteScript.new()
	var a := s.texture_for("WALKING_TO", 0, false, {"member_id": 0}).get_image()
	var b := s.texture_for("WALKING_TO", 1, false, {"member_id": 0}).get_image()
	var diff := 0
	for y in SIZE:
		for x in SIZE:
			if not _near(a.get_pixel(x, y), b.get_pixel(x, y)):
				diff += 1
	_check(diff > 4, "walk A/B 迈步帧存在像素差异（diff=%d）" % diff)
	# use A/B 同样不同（上举 vs 下垂）
	var ua := s.texture_for("USING", 0, false, {"equipment_id": "", "member_id": 0}).get_image()
	var ub := s.texture_for("USING", 1, false, {"equipment_id": "", "member_id": 0}).get_image()
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
	var tex := s.texture_for("USING", 0, true, {"equipment_id": "treadmill", "member_id": 0})
	_check(tex.get_size() == Vector2(SIZE, SIZE), "纹理尺寸 48×48（Phase 4 明显增大）")
	_check(tex.get_image().get_format() == Image.FORMAT_RGBA8, "纹理格式 RGBA8")


func _lum(c: Color) -> float:
	return 0.2126 * c.r + 0.7152 * c.g + 0.0722 * c.b


func _tex_pixel(s, state: String, tick: int, left: bool, p: Vector2i, ctx: Dictionary = {}) -> Color:
	return s.texture_for(state, tick, left, ctx).get_image().get_pixel(p.x, p.y)
