# src/presentation/member_sprite.gd — Phase 4 (V3 §8): 大尺寸表现力像素会员图集
#
# Story: visual-remaster-v3 / phase4-member-redraw
# Docs:  design/art/visual-remaster-spec-v3.md §8 人物重新设计（sprite 视觉尺寸
#        明显增大、短而敦实、头稍大、肩膀明显、四肢较短、轮廓极易识别；每人：
#        清晰发型/皮肤色块/衣服主色/裤子/鞋/阴影侧/高光侧/面部眼眉嘴）、
#        §9 微型动态元素（角色汗滴、移动轻微动作反馈）、
#        §11 轮廓线（人物：深色轮廓明显）
#        design/art/art-bible-25d-style.md §2 像素主体（大色块 + 剪影第一优先）
#
# 程序化生成 48×48 会员小人（比 Phase C v2 的 32×32 明显增大 —— V3 §8
# "sprite 视觉尺寸明显增大，成为画面视觉主体"）。绘制锚点：脚底落地于
# cell 底部（world_canvas 负责定位），头部向上越出 cell —— 2.5D 人物
# 高于其占用格，与设备（32px/cell）的比例拉开。
#
# 状态双通道（色盲安全，沿用 Phase C 机制 —— 仅重绘视觉，不改语义）：
#   - 颜色通道（衬衫色）：WALKING_TO/ENTERING/SELECTING_TARGET → Sky 系
#                          QUEUEING/USING → Peach 系
#                          LEAVING → 低饱和灰（MEMBER_LEAVE_GRAY）
#   - 形状/姿态通道（V3 §8 更丰富的表达）：
#       idle      站立微晃（SELECTING_TARGET 思考）
#       walk      跑步：前倾 + 摆臂 + 腿部明显循环（WALKING_TO/ENTERING/LEAVING）
#       tired     累：弯腰 + 擦汗 + 喘气 + 头顶汗滴（QUEUEING 等待，§9 汗滴）
#       satisfied 满意：挺胸 + 举手 + 小闪光（LEAVING 且 quota_met，§9 闪光）
#       use_*     设备专属使用姿态（§8 与设备互动匹配）：
#                 treadmill 跑带奔跑 / bench_press 卧推杠铃上下+结束坐起 /
#                 bike 骑行 / yoga_mat 瑜伽 / 未知设备泵举兜底
#
# 每人外观（V3 §8 "每人：清晰发型、皮肤色块…"）：member_id 确定性映射到
# 4 个外观变体（发型颜色/皮肤/裤/鞋，单一色源 palette.gd；发型顶型 tuft/
# fringe 两种）。同一 member_id 永远同一外观（确定性，测试可断言）。
#
# 帧：每姿态 2 帧（A/B）。walk/use/tired/satisfied 按 tick 奇偶交替（10Hz
# 观感），idle 每 2 tick 交替（5Hz 微晃）。游戏逻辑 60fps 不变 —— 仅渲染帧选择。
# 朝向：facing_left 时水平镜像生成，不依赖渲染期变换。
extends RefCounted

const Palette := preload("res://src/palette.gd")

const SIZE := 48

# === 颜色通道（状态 → 衬衫色，Phase C 语义保留） ===
const CH_SKY := "sky"
const CH_PEACH := "peach"
const CH_GRAY := "gray"

# === 姿态（形状通道，V3 §8 扩充） ===
const POSE_IDLE := "idle"
const POSE_WALK := "walk"
const POSE_TIRED := "tired"
const POSE_SATISFIED := "satisfied"
const POSE_USE := "use"

# === 设备专属使用姿态 ===
const USE_TREADMILL := "use_treadmill"
const USE_BENCH := "use_bench"
const USE_BIKE := "use_bike"
const USE_YOGA := "use_yoga"
const USE_GENERIC := "use_generic"
const USE_BENCH_SITUP := "use_bench_situp"

# === 脸部变体 ===
const FACE_BORED := "bored"     # idle：半闭眼（1px 高）+ 小嘴
const FACE_FOCUS := "focus"     # walk：2×2 眼 + 小嘴
const FACE_EFFORT := "effort"   # use：用力眉 + 2×2 眼 + 张嘴
const FACE_PANT := "pant"       # tired：眯眼 + 喘气张嘴 + 汗滴
const FACE_HAPPY := "happy"     # satisfied：笑眼 + 微笑 + 闪光

# === 外观变体（member_id % 4 → 组合；0 = palette 默认色） ===
# 每项：{hair, skin, pants, shoes, hair_style}。发型顶型 0=tuft / 1=fringe。
# V3.1 P5（颜色加高饱和视觉焦点）：只变体 1 穿高饱和橙色运动短裤
# （P5 例子「橙色健身服」—— 精选焦点，非全员高饱和；变体 2/3 保持
# 低饱和裤，画面中橙色短裤会员是少数跳出的焦点）。变体 0 保留默认
# 低饱和裤（既有测试 pin 变体 0 的裤像素；变体 1 无像素断言，安全）。
# 短裤高饱和色来自 palette FOCAL_GYM_*（单一数据源）。
# V3.1 R2（P2-sprite 辨识度）：外观不再是「同一 silhouette 换色」——
# 每变体有差异化体型（build）与发型（hair_style）：
#   build 0 标准（默认体型，测试像素断言 pin 住，不得改形）
#   build 1 壮硕（肩宽 34 / 腰窄 20，V 字倒三角；无袖背心 + 橙色短裤）
#   build 2 纤细（肩窄 26 / 腿细，马尾发型）
#   build 3 敦实（肩宽 38 / 腿粗，平头发型）
# 体型由 BUILDS 表驱动（_torso_rows/_leg_rows 按 build 生成行数据），
# 颜色仍由本表 + palette 单一色源。变体 0 保持既有行数据（测试 pin）。
const MEMBER_VARIANTS := [
	{"hair": Palette.MEMBER_HAIR, "skin": Palette.MEMBER_SKIN,
	 "pants": Palette.MEMBER_PANTS, "shoes": Palette.MEMBER_SHOE, "hair_style": 0},
	{"hair": Palette.MEMBER_HAIR_ALT1, "skin": Palette.MEMBER_SKIN_ALT1,
	 "pants": Palette.FOCAL_GYM_ORANGE, "shoes": Palette.MEMBER_SHOE_ALT1, "hair_style": 1},
	{"hair": Palette.MEMBER_HAIR_ALT2, "skin": Palette.MEMBER_SKIN_ALT2,
	 "pants": Palette.MEMBER_PANTS_ALT2, "shoes": Palette.MEMBER_SHOE_ALT2, "hair_style": 2},
	{"hair": Palette.MEMBER_HAIR_ALT3, "skin": Palette.MEMBER_SKIN_ALT3,
	 "pants": Palette.MEMBER_PANTS_ALT3, "shoes": Palette.MEMBER_SHOE_ALT3, "hair_style": 3},
]
const VARIANT_COUNT := 4

# === V3.1 R2（P2-sprite）：差异化体型 build（同一姿态模板，不同放样宽度） ===
# 每项：{sh 肩宽, chest 胸宽, waist 腰宽, hip 臀宽, leg 腿宽, sleeve 袖型,
#        legwear 裤型, hair 发型索引}。行数据生成见 _torso_rows/_leg_rows。
# 变体 0 是「锚定变体」—— 其行数据由既有手写行保持（测试像素断言 pin），
# BUILDS[0] 仅作参考，不驱动生成。变体 1-3 由模板按宽度放样。
# 单位：字符宽（1 char = 1 屏 px）。
const BUILDS := {
	0: {"sh": 28, "chest": 28, "waist": 24, "hip": 26, "leg": 12, "sleeve": "cc", "legwear": "pants", "hair": 0},
	1: {"sh": 34, "chest": 28, "waist": 20, "hip": 24, "leg": 14, "sleeve": "ss", "legwear": "shorts", "hair": 1},
	2: {"sh": 26, "chest": 24, "waist": 22, "hip": 22, "leg": 10, "sleeve": "cc", "legwear": "pants", "hair": 2},
	3: {"sh": 38, "chest": 32, "waist": 28, "hip": 28, "leg": 16, "sleeve": "cc", "legwear": "pants", "hair": 3},
}

## 卧推「结束坐起」窗口：use_ticks_remaining 进入该窗口时显示坐起帧
## （V3 §8 "结束时坐起"）。8 ticks ≈ 0.8s @10Hz —— 收尾节奏可见。
const BENCH_SITUP_WINDOW := 8

## 纹理缓存：key = "channel|pose|frame|facing|variant" → ImageTexture。
## 设备使用姿态/坐起帧已并入 pose（use_bench vs use_bench_situp），
## 无需额外 key 维度。
var _cache: Dictionary = {}


# === 状态映射（member_sim.gd 状态枚举名，已核实） ===

## 状态 → 颜色通道（Phase C 语义保留）。GONE / 被动成员（无 state 键）/
## 未知 → ""（不渲染）。
func state_channel(state: String) -> String:
	match state:
		"ENTERING", "SELECTING_TARGET", "WALKING_TO":
			return CH_SKY
		"QUEUEING", "USING":
			return CH_PEACH
		"LEAVING":
			return CH_GRAY
		_:
			return ""


## 状态 → 基础姿态（形状通道，V3 §8 扩充）。USING 的具体使用姿态由
## use_pose(equipment_id) 解析（texture_for 内部调用）；LEAVING 的满意
## 收尾由 leaving_reason 解析。
func state_pose(state: String) -> String:
	match state:
		"WALKING_TO", "ENTERING":
			return POSE_WALK
		"LEAVING":
			return POSE_WALK
		"QUEUEING":
			return POSE_TIRED
		"USING":
			return POSE_USE
		_:
			return POSE_IDLE


## 设备 id → 使用姿态。未知/空 → 泵举兜底（绝不崩溃）。
func use_pose(equipment_id: String) -> String:
	match equipment_id:
		"treadmill":
			return USE_TREADMILL
		"bench_press":
			return USE_BENCH
		"bike":
			return USE_BIKE
		"yoga_mat":
			return USE_YOGA
		_:
			return USE_GENERIC


## 帧位（0/1）：walk/use/tired/satisfied 按 tick 奇偶交替（10Hz 观感），
## idle 每 2 tick 交替（5Hz 微晃）。游戏逻辑 60fps 不变 —— 这只是渲染帧选择。
func frame_bit(state: String, tick: int) -> int:
	if state_pose(state) == POSE_IDLE:
		return (tick / 2) % 2
	return tick % 2


## member_id → 外观变体索引（0..VARIANT_COUNT-1）。确定性：同一 member_id
## 永远同一外观。member_id < 0（未注入）→ 0（默认色，测试兼容）。
func variant_for(member_id: int) -> int:
	if member_id < 0:
		return 0
	return member_id % VARIANT_COUNT


## 取纹理（缓存命中或生成）。facing_left=true 时返回水平镜像。
## [ctx] 附加绘制上下文（V3 §8 设备互动 + §9 微型动态）：
##   equipment_id       USING 成员的目标设备（决定使用姿态）
##   leaving_reason     LEAVING 成员的离场原因（quota_met → satisfied）
##   use_ticks_remaining  USING 成员剩余使用 tick（bench 结束坐起窗口）
##   member_id          外观变体（每人清晰发型/皮肤色块）
## 全部可缺省 —— 缺省时回到基础姿态 + 变体 0（Phase C 兼容）。
func texture_for(state: String, tick: int, facing_left: bool,
		ctx: Dictionary = {}) -> ImageTexture:
	var channel := state_channel(state)
	var pose := _resolve_pose(state, ctx)
	var variant := variant_for(int(ctx.get("member_id", -1)))
	var key := "%s|%s|%d|%s|%d" % [channel, pose, frame_bit(state, tick),
		str(facing_left), variant]
	if _cache.has(key):
		return _cache[key]
	var img := _build_frame(channel, pose, frame_bit(state, tick), variant)
	if facing_left:
		img = _mirror(img)
	var tex := ImageTexture.create_from_image(img)
	_cache[key] = tex
	return tex


## 最终姿态解析：基础姿态 + 设备使用姿态 + LEAVING 满意收尾 + bench 坐起。
func _resolve_pose(state: String, ctx: Dictionary) -> String:
	if state == "LEAVING" and str(ctx.get("leaving_reason", "")) == "quota_met":
		return POSE_SATISFIED
	if state == "USING":
		var eq := str(ctx.get("equipment_id", ""))
		var pose := use_pose(eq)
		if pose == USE_BENCH:
			var left := int(ctx.get("use_ticks_remaining", -1))
			if left >= 0 and left <= BENCH_SITUP_WINDOW:
				return USE_BENCH_SITUP
		return pose
	return state_pose(state)


# === 帧构建 ===

func _build_frame(channel: String, pose: String, frame: int, variant: int) -> Image:
	var rows := _frame_rows(pose, frame, variant)
	var shirt := _shirt_color(channel)
	var v: Dictionary = MEMBER_VARIANTS[variant % VARIANT_COUNT]
	rows = _apply_directional_shade(rows)
	var img := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	for y in rows.size():
		var row: String = rows[y]
		for x in row.length():
			var ch := row[x]
			if ch == ".":
				continue
			img.set_pixel(x, y, _char_color(ch, shirt, v))
	_apply_outline(img)
	return img


## V3 §8 阴影侧 / 高光侧（统一方向光 —— 顶部暖白光从左上照下）：
## 每行横向把最左的主色像素换成高光色、最右的换成阴影色（头 h→H/Z、
## 脸 s→S/X、衬衫 c→l/q、裤 p→v/x）。同一色源派生，无硬编码新色。
## 逐字符替换只在首/尾出现处生效 —— 中间像素保持主色，形成左亮右暗的
## 体积感（V3 §6 方向光：阴影偏冷暗、高光偏暖亮）。
func _apply_directional_shade(rows: PackedStringArray) -> PackedStringArray:
	var out := PackedStringArray()
	for y in rows.size():
		var row: String = rows[y]
		if y < 18:
			row = _shade_side(row, "h", "H", "Z")
			row = _shade_side(row, "s", "S", "X")
		elif y < 32:
			row = _shade_side(row, "c", "l", "q")
		elif y < 44:
			row = _shade_side(row, "p", "v", "x")
		out.append(row)
	return out


## 行内方向光：把 [ch] 的第一次出现换成 [hi]（高光侧），最后一次出现换成
## [lo]（阴影侧）。无该字符则原样返回。臂/手区（s 手）不受 c 替换影响。
func _shade_side(row: String, ch: String, hi: String, lo: String) -> String:
	var first := row.find(ch)
	if first < 0:
		return row
	var last := row.rfind(ch)
	var out := row
	out = out.substr(0, first) + hi + out.substr(first + 1)
	if last != first:
		out = out.substr(0, last) + lo + out.substr(last + 1)
	return out


## V3 §11 人物深色轮廓明显：对整幅（除微元素行 0..1）做 1px 暗轮廓 ——
## 每个透明像素若 4-邻域有不透明像素，则涂 CHARCOAL（软炭非纯黑，与设备
## 描边一致）。轮廓是后处理的统一环，非逐姿态手绘 —— 保证所有姿态都有
## 明显深色轮廓（§11 "人物：深色轮廓明显"）。影行（44..47，alpha 0.28）
## 不透明阈值低于判定，不会被包进轮廓。
func _apply_outline(img: Image) -> void:
	var src := img.duplicate()
	for y in range(2, SIZE):
		for x in SIZE:
			if src.get_pixel(x, y).a > 0.5:
				continue
			if _has_opaque_neighbor(src, x, y):
				img.set_pixel(x, y, Palette.CHARCOAL)


func _has_opaque_neighbor(img: Image, x: int, y: int) -> bool:
	for d in [[1, 0], [-1, 0], [0, 1], [0, -1]]:
		var nx: int = x + int(d[0])
		var ny: int = y + int(d[1])
		if nx < 0 or nx >= SIZE or ny < 0 or ny >= SIZE:
			continue
		if img.get_pixel(nx, ny).a > 0.5:
			return true
	return false


## 48 行 × 48 字符的帧数据（"手工归纳"像素图 —— 逐行定义，无抗锯齿）。
func _frame_rows(pose: String, frame: int, variant: int) -> PackedStringArray:
	match pose:
		POSE_WALK:
			return _walk_rows(frame, variant)
		POSE_TIRED:
			return _tired_rows(frame, variant)
		POSE_SATISFIED:
			return _satisfied_rows(frame, variant)
		USE_TREADMILL:
			return _treadmill_rows(frame, variant)
		USE_BIKE:
			return _bike_rows(frame, variant)
		USE_BENCH:
			return _bench_rows(frame, variant)
		USE_BENCH_SITUP:
			return _bench_situp_rows(frame, variant)
		USE_YOGA:
			return _yoga_rows(frame, variant)
		USE_GENERIC:
			return _use_generic_rows(frame, variant)
		_:
			return _idle_rows(frame, variant)


# === 基础部件（头 18 行 0..17 / 躯干 14 行 18..31 / 腿 9 行 32..40 /
#         鞋 3 行 41..43 / 影 4 行 44..47） ===

## 头（18 行）：发型变体（V3.1 R2：差异化 silhouette，非换色）：
##   style 0 tuft —— 顶上一撮呆毛（既有，测试 pin）
##   style 1 fringe —— 平顶 + 刘海（既有）
##   style 2 ponytail —— 圆顶 + 右侧 2px 马尾（纤细变体）
##   style 3 flat —— 短平头（敦实变体）
## 脸低细节高表达（眼/眉/嘴变体，四发型共用同一脸块）。
## [compact] 用于带头顶微元素（汗滴/闪光）的姿态 —— 去掉最后 2 行颈，
## 给微元素留出 0..1 行（调用方自行前置 2 行），总高保持 48。
func _head_rows(face: String, variant: int, compact: bool = false) -> PackedStringArray:
	var v: Dictionary = MEMBER_VARIANTS[variant % VARIANT_COUNT]
	var style := int(v["hair_style"])
	var r := PackedStringArray()
	match style:
		0:
			# tuft：顶上一撮呆毛（2px 高，bob 上浮时仍有残留）
			r.append(_r(22, "hhhh"))
			r.append(_r(21, "hhhhhh"))
			r.append(_r(19, "hhhhhhhhhh"))
			r.append(_r(17, "hhhhhhhhhhhhhh"))
			r.append(_r(15, "hhhhhhhhhhhhhhhhhh"))
			r.append(_r(14, "hhhhhhhhhhhhhhhhhhhh"))
		1:
			# fringe：平顶 + 刘海
			r.append(_r(18, "hhhhhhhhhhhh"))
			r.append(_r(17, "hhhhhhhhhhhhhhhh"))
			r.append(_r(16, "hhhhhhhhhhhhhhhhhh"))
			r.append(_r(15, "hhhhhhhhhhhhhhhhhhhh"))
			r.append(_r(14, "hhhhhhhhhhhhhhhhhhhhhh"))
			r.append(_r(13, "hhhhhhhhhhhhhhhhhhhhhhhh"))
		2:
			# ponytail（V3.1 R2）：圆顶 + 右侧 2px 马尾（脸侧发向右延伸，
			# 发顶比 tuft 圆润 —— 剪影右侧多 2px 小辫）
			r.append(_r(19, "hhhhhhhhhh"))
			r.append(_r(18, "hhhhhhhhhhhh"))
			r.append(_r(17, "hhhhhhhhhhhhhh"))
			r.append(_r(16, "hhhhhhhhhhhhhhhh"))
			r.append(_r(15, "hhhhhhhhhhhhhhhhhh"))
			r.append(_r(14, "hhhhhhhhhhhhhhhhhhhh"))
		3:
			# flat（V3.1 R2）：短平头 —— 顶平、比 tuft 窄（无呆毛/刘海，
			# 发顶平坦），轮廓像刚剃过的寸头
			r.append(_r(20, "hhhhhhhh"))
			r.append(_r(19, "hhhhhhhhhh"))
			r.append(_r(18, "hhhhhhhhhhhh"))
			r.append(_r(17, "hhhhhhhhhhhhhh"))
			r.append(_r(16, "hhhhhhhhhhhhhhhh"))
			r.append(_r(15, "hhhhhhhhhhhhhhhhhh"))
	r.append(_r(13, "hh" + "s".repeat(18) + "hh"))        # 发两侧 + 脸顶
	r.append(_r(13, "hh" + "s".repeat(18) + "hh"))        # 发两侧 + 脸
	# 脸块统一 4 行（每姿态总行数一致：6 发 + 2 脸顶 + 4 脸块 + 4 下巴 + 2 颈
	# = 18；compact 去掉 2 颈 = 16）：
	match face:
		FACE_EFFORT, FACE_FOCUS, FACE_HAPPY:
			if face == FACE_EFFORT:
				r.append(_r(13, "hh" + "ssbb" + "ssssss" + "bbss" + "ssss" + "hh"))  # 用力眉
			else:
				r.append(_r(13, "hh" + "s".repeat(18) + "hh"))
			r.append(_r(13, "hh" + "ssss" + "ee" + "ssssss" + "ee" + "ssss" + "hh"))  # 2×2 眼上排
			r.append(_r(13, "hh" + "ssss" + "ee" + "ssssss" + "ee" + "ssss" + "hh"))  # 2×2 眼下排
			if face == FACE_HAPPY:
				r.append(_r(13, "hh" + "ssssss" + "mmmm" + "ssssss" + "hh"))          # 微笑
			else:
				r.append(_r(13, "hh" + "ssssssssmmmmssssss" + "hh"))                  # 小嘴
		FACE_PANT:
			r.append(_r(13, "hh" + "s".repeat(18) + "hh"))
			r.append(_r(13, "hh" + "sssss" + "ee" + "ssssss" + "ee" + "sssss" + "hh"))  # 眯眼
			r.append(_r(13, "hh" + "s".repeat(18) + "hh"))
			r.append(_r(13, "hh" + "ssssss" + "mmmm" + "ssssss" + "hh"))              # 喘气张嘴
		_:
			# bored：半闭眼（1px 高）+ 小嘴
			r.append(_r(13, "hh" + "s".repeat(18) + "hh"))
			r.append(_r(13, "hh" + "sssss" + "ee" + "ssssss" + "ee" + "sssss" + "hh"))  # 半闭眼
			r.append(_r(13, "hh" + "s".repeat(18) + "hh"))
			r.append(_r(13, "hh" + "ssssssssmmmmssssss" + "hh"))                      # 小嘴
	# 马尾：脸块之后（行 7..10）右侧 2px 小辫延伸 —— 与发顶同色，
	# 轮廓上形成「头右侧 2×4 发束」差异化剪影（V3.1 R2 silhouette）。
	if style == 2:
		for i in range(1, 5):
			var row := r[r.size() - 1 - i]
			r[r.size() - 1 - i] = _right_extend(row, 35, "hh")
	r.append(_r(13, "hh" + "s".repeat(18) + "hh"))        # 脸
	r.append(_r(15, "s".repeat(18)))                      # 下巴收窄
	r.append(_r(16, "s".repeat(16)))
	r.append(_r(17, "s".repeat(14)))                      # 下巴尖
	if not compact:
		r.append(_r(19, "s".repeat(10)))                  # 颈
		r.append(_r(20, "s".repeat(8)))
	return r


## V3.1 R2：把 [row] 在 [x] 处替换为 [content]（用于马尾等非对称发型延伸）。
## row 由 _r() 生成（content 左对齐 + 右补透明），右侧是 '.'，直接替换即可。
func _right_extend(row: String, x: int, content: String) -> String:
	if x < 0 or x + content.length() > row.length():
		return row
	return row.substr(0, x) + content + row.substr(x + content.length())


## 躯干（14 行 18..31）：肩 1 行宽于头（肩膀明显），双臂（袖 c / 手 s）
## 在外侧，躯干 c 中置；右侧阴影（V3 §6 顶部暖光 → 阴影侧偏冷暗）。
## [arms] 决定手臂姿态（摆臂/上举/前伸/擦汗/举手等）。
## V3.1 R2：变体 0 走既有手写行（测试像素断言 pin）；变体 1-3 由
## _torso_build_rows 按 BUILDS 放样（差异化体型 silhouette）。
func _torso_rows(arms: String, variant: int) -> PackedStringArray:
	if variant % VARIANT_COUNT != 0:
		return _torso_build_rows(arms, variant)
	var r := PackedStringArray()
	match arms:
		"swing_f":   # walk A：左臂前摆 + 右臂后摆
			r.append(_r(9, "cccccccccccccccccccccccccccccc"))
			r.append(_r(7, "cc" + "cccccccccccccccccccccccccccc" + "cc"))
			r.append(_r(7, "cc" + "cccccccccccccccccccccccccccc" + "cc"))
			r.append(_r(7, "cc" + "cccccccccccccccccccccccccccc" + "cc"))
			r.append(_r(8, "cc" + "cccccccccccccccccccccccccccc" + "cc"))
			r.append(_r(8, "ss" + "cccccccccccccccccccccccccccc" + "cc"))  # 左手前摆 + 右袖
			r.append(_r(8, "ss" + "cccccccccccccccccccccccccccc" + "ss"))  # 双手
			r.append(_r(9, "cccccccccccccccccccccccccccc" + "ss"))         # 躯干 + 右手后摆
			r.append(_r(9, "cccccccccccccccccccccccccccc"))
			r.append(_r(9, "dddddddddddddddddddddddddddd"))                 # 下摆阴影
			r.append(_r(10, "pppppppppppppppppppppppppp"))
			r.append(_r(10, "pppppppppppppppppppppppppp"))
			r.append(_r(10, "pppppppppppppppppppppppppp"))
			r.append(_r(10, "pppppppppppppppppppppppppp"))
		"swing_b":   # walk B：镜像（右臂前摆 + 左臂后摆）
			r.append(_r(9, "cccccccccccccccccccccccccccccc"))
			r.append(_r(7, "cc" + "cccccccccccccccccccccccccccc" + "cc"))
			r.append(_r(7, "cc" + "cccccccccccccccccccccccccccc" + "cc"))
			r.append(_r(7, "cc" + "cccccccccccccccccccccccccccc" + "cc"))
			r.append(_r(7, "cc" + "cccccccccccccccccccccccccccc" + "cc"))
			r.append(_r(7, "cc" + "cccccccccccccccccccccccccccc" + "ss"))  # 左袖 + 右手前摆
			r.append(_r(8, "ss" + "cccccccccccccccccccccccccccc" + "ss"))  # 双手
			r.append(_r(9, "ss" + "cccccccccccccccccccccccccccc"))         # 左手后摆 + 躯干
			r.append(_r(9, "cccccccccccccccccccccccccccc"))
			r.append(_r(9, "dddddddddddddddddddddddddddd"))
			r.append(_r(10, "pppppppppppppppppppppppppp"))
			r.append(_r(10, "pppppppppppppppppppppppppp"))
			r.append(_r(10, "pppppppppppppppppppppppppp"))
			r.append(_r(10, "pppppppppppppppppppppppppp"))
		"pump_up":   # use generic A：双手举到肩高（泵）
			r.append(_r(9, "cccccccccccccccccccccccccccccc"))
			r.append(_r(8, "ss" + "cccccccccccccccccccccccccccc" + "ss"))  # 双手举到肩高
			r.append(_r(8, "ss" + "cccccccccccccccccccccccccccc" + "ss"))
			r.append(_r(8, "cc" + "cccccccccccccccccccccccccccc" + "cc"))  # 袖
			r.append(_r(8, "cc" + "cccccccccccccccccccccccccccc" + "cc"))
			r.append(_r(8, "cc" + "cccccccccccccccccccccccccccc" + "cc"))
			r.append(_r(8, "cc" + "cccccccccccccccccccccccccccc" + "cc"))
			r.append(_r(9, "cccccccccccccccccccccccccccc"))
			r.append(_r(9, "cccccccccccccccccccccccccccc"))
			r.append(_r(9, "dddddddddddddddddddddddddddd"))
			r.append(_r(10, "pppppppppppppppppppppppppp"))
			r.append(_r(10, "pppppppppppppppppppppppppp"))
			r.append(_r(10, "pppppppppppppppppppppppppp"))
			r.append(_r(10, "pppppppppppppppppppppppppp"))
		"pump_down": # use generic B：臂下垂 + 下蹲
			r.append(_r(9, "cccccccccccccccccccccccccccccc"))
			r.append(_r(8, "cc" + "cccccccccccccccccccccccccccc" + "cc"))
			r.append(_r(8, "cc" + "cccccccccccccccccccccccccccc" + "cc"))
			r.append(_r(8, "cc" + "cccccccccccccccccccccccccccc" + "cc"))
			r.append(_r(8, "cc" + "cccccccccccccccccccccccccccc" + "cc"))
			r.append(_r(8, "ss" + "cccccccccccccccccccccccccccc" + "ss"))  # 双手下垂
			r.append(_r(8, "ss" + "cccccccccccccccccccccccccccc" + "ss"))
			r.append(_r(9, "cccccccccccccccccccccccccccc"))
			r.append(_r(9, "cccccccccccccccccccccccccccc"))
			r.append(_r(9, "dddddddddddddddddddddddddddd"))
			r.append(_r(10, "pppppppppppppppppppppppppp"))
			r.append(_r(10, "pppppppppppppppppppppppppp"))
			r.append(_r(10, "pppppppppppppppppppppppppp"))
			r.append(_r(10, "pppppppppppppppppppppppppp"))
		"rails":     # treadmill：双手前伸扶把
			r.append(_r(9, "cccccccccccccccccccccccccccccc"))
			r.append(_r(8, "cc" + "cccccccccccccccccccccccccccc" + "cc"))
			r.append(_r(7, "cc" + "cccccccccccccccccccccccccccc" + "cc"))
			r.append(_r(6, "ss" + "cccccccccccccccccccccccccccc" + "ss"))  # 双手前伸
			r.append(_r(7, "cc" + "cccccccccccccccccccccccccccc" + "cc"))
			r.append(_r(8, "cc" + "cccccccccccccccccccccccccccc" + "cc"))
			r.append(_r(8, "cc" + "cccccccccccccccccccccccccccc" + "cc"))
			r.append(_r(9, "cccccccccccccccccccccccccccc"))
			r.append(_r(9, "cccccccccccccccccccccccccccc"))
			r.append(_r(9, "dddddddddddddddddddddddddddd"))
			r.append(_r(10, "pppppppppppppppppppppppppp"))
			r.append(_r(10, "pppppppppppppppppppppppppp"))
			r.append(_r(10, "pppppppppppppppppppppppppp"))
			r.append(_r(10, "pppppppppppppppppppppppppp"))
		"handlebar": # bike：双手前伸握把（低于 rails）
			r.append(_r(9, "cccccccccccccccccccccccccccccc"))
			r.append(_r(8, "cc" + "cccccccccccccccccccccccccccc" + "cc"))
			r.append(_r(8, "cc" + "cccccccccccccccccccccccccccc" + "cc"))
			r.append(_r(6, "ss" + "cccccccccccccccccccccccccccc" + "ss"))
			r.append(_r(7, "cc" + "cccccccccccccccccccccccccccc" + "cc"))
			r.append(_r(8, "cc" + "cccccccccccccccccccccccccccc" + "cc"))
			r.append(_r(8, "cc" + "cccccccccccccccccccccccccccc" + "cc"))
			r.append(_r(9, "cccccccccccccccccccccccccccc"))
			r.append(_r(9, "cccccccccccccccccccccccccccc"))
			r.append(_r(9, "dddddddddddddddddddddddddddd"))
			r.append(_r(10, "pppppppppppppppppppppppppp"))
			r.append(_r(10, "pppppppppppppppppppppppppp"))
			r.append(_r(10, "pppppppppppppppppppppppppp"))
			r.append(_r(10, "pppppppppppppppppppppppppp"))
		"wipe":      # tired：一手擦汗（举到额侧）+ 一手叉腰
			r.append(_r(9, "cccccccccccccccccccccccccccccc"))
			r.append(_r(8, "cc" + "cccccccccccccccccccccccccccc" + "cc"))
			r.append(_r(8, "cc" + "cccccccccccccccccccccccccccc" + "cc"))
			r.append(_r(7, "ss" + "cccccccccccccccccccccccccccc" + "cc"))   # 左手擦汗（上举）
			r.append(_r(8, "cc" + "cccccccccccccccccccccccccccc" + "cc"))
			r.append(_r(8, "cc" + "cccccccccccccccccccccccccccc" + "cc"))
			r.append(_r(9, "cccccccccccccccccccccccccccc" + "ss"))         # 右手叉腰
			r.append(_r(9, "cccccccccccccccccccccccccccc"))
			r.append(_r(9, "cccccccccccccccccccccccccccc"))
			r.append(_r(9, "dddddddddddddddddddddddddddd"))
			r.append(_r(10, "pppppppppppppppppppppppppp"))
			r.append(_r(10, "pppppppppppppppppppppppppp"))
			r.append(_r(10, "pppppppppppppppppppppppppp"))
			r.append(_r(10, "pppppppppppppppppppppppppp"))
		"raised":    # satisfied：挺胸 + 单手高举
			r.append(_r(9, "cccccccccccccccccccccccccccccc"))
			r.append(_r(7, "ss" + "cccccccccccccccccccccccccccc" + "cc"))   # 右手高举
			r.append(_r(8, "ss" + "cccccccccccccccccccccccccccc" + "cc"))
			r.append(_r(8, "cc" + "cccccccccccccccccccccccccccc" + "cc"))
			r.append(_r(8, "cc" + "cccccccccccccccccccccccccccc" + "cc"))
			r.append(_r(8, "cc" + "cccccccccccccccccccccccccccc" + "cc"))
			r.append(_r(9, "cccccccccccccccccccccccccccc" + "ss"))         # 左手叉腰/垂
			r.append(_r(9, "cccccccccccccccccccccccccccc"))
			r.append(_r(9, "cccccccccccccccccccccccccccc"))
			r.append(_r(9, "dddddddddddddddddddddddddddd"))
			r.append(_r(10, "pppppppppppppppppppppppppp"))
			r.append(_r(10, "pppppppppppppppppppppppppp"))
			r.append(_r(10, "pppppppppppppppppppppppppp"))
			r.append(_r(10, "pppppppppppppppppppppppppp"))
		"stretch_up": # yoga A：双手上举
			r.append(_r(9, "cccccccccccccccccccccccccccccc"))
			r.append(_r(8, "ss" + "cccccccccccccccccccccccccccc" + "ss"))
			r.append(_r(8, "ss" + "cccccccccccccccccccccccccccc" + "ss"))
			r.append(_r(8, "cc" + "cccccccccccccccccccccccccccc" + "cc"))
			r.append(_r(8, "cc" + "cccccccccccccccccccccccccccc" + "cc"))
			r.append(_r(8, "cc" + "cccccccccccccccccccccccccccc" + "cc"))
			r.append(_r(8, "cc" + "cccccccccccccccccccccccccccc" + "cc"))
			r.append(_r(9, "cccccccccccccccccccccccccccc"))
			r.append(_r(9, "cccccccccccccccccccccccccccc"))
			r.append(_r(9, "dddddddddddddddddddddddddddd"))
			r.append(_r(10, "pppppppppppppppppppppppppp"))
			r.append(_r(10, "pppppppppppppppppppppppppp"))
			r.append(_r(10, "pppppppppppppppppppppppppp"))
			r.append(_r(10, "pppppppppppppppppppppppppp"))
		"stretch_out": # yoga B：双臂平伸
			r.append(_r(9, "cccccccccccccccccccccccccccccc"))
			r.append(_r(6, "ss" + "cccccccccccccccccccccccccccc" + "ss"))
			r.append(_r(6, "ss" + "cccccccccccccccccccccccccccc" + "ss"))
			r.append(_r(7, "cc" + "cccccccccccccccccccccccccccc" + "cc"))
			r.append(_r(8, "cc" + "cccccccccccccccccccccccccccc" + "cc"))
			r.append(_r(8, "cc" + "cccccccccccccccccccccccccccc" + "cc"))
			r.append(_r(8, "cc" + "cccccccccccccccccccccccccccc" + "cc"))
			r.append(_r(9, "cccccccccccccccccccccccccccc"))
			r.append(_r(9, "cccccccccccccccccccccccccccc"))
			r.append(_r(9, "dddddddddddddddddddddddddddd"))
			r.append(_r(10, "pppppppppppppppppppppppppp"))
			r.append(_r(10, "pppppppppppppppppppppppppp"))
			r.append(_r(10, "pppppppppppppppppppppppppp"))
			r.append(_r(10, "pppppppppppppppppppppppppp"))
		_:           # down（idle 等默认：双臂下垂）
			r.append(_r(9, "cccccccccccccccccccccccccccccc"))
			r.append(_r(8, "cc" + "cccccccccccccccccccccccccccc" + "cc"))
			r.append(_r(8, "cc" + "cccccccccccccccccccccccccccc" + "cc"))
			r.append(_r(8, "cc" + "cccccccccccccccccccccccccccc" + "cc"))
			r.append(_r(8, "cc" + "cccccccccccccccccccccccccccc" + "cc"))
			r.append(_r(8, "ss" + "cccccccccccccccccccccccccccc" + "ss"))  # 双手
			r.append(_r(8, "ss" + "cccccccccccccccccccccccccccc" + "ss"))
			r.append(_r(9, "cccccccccccccccccccccccccccc"))
			r.append(_r(9, "cccccccccccccccccccccccccccc"))
			r.append(_r(9, "dddddddddddddddddddddddddddd"))
			r.append(_r(10, "pppppppppppppppppppppppppp"))
			r.append(_r(10, "pppppppppppppppppppppppppp"))
			r.append(_r(10, "pppppppppppppppppppppppppp"))
			r.append(_r(10, "pppppppppppppppppppppppppp"))
	return r


## V3.1 R2：躯干姿态模板（变体 1-3 放样用）。每姿态 14 行（与手写行同结构）：
## 每行 [L 左延伸, R 右延伸, W 宽度键, ch(可选 覆盖字符)]。
##   W 键：sh=肩 / chest=胸 / waist=腰 / hip=臀 —— 宽度取自 BUILDS。
##   L/R：袖 "cc"（build 1 换肤成 "ss" 无袖背心）或手 "ss"。
##   行 9 = 下摆（d）、行 10-13 = 裤腰（p）—— 与手写行同结构。
## 模板按既有手写行归纳（swing_f 等 11 姿态 + down 兜底）。
const TORSO_TPL := {
	"swing_f": [
		["", "", "sh"], ["cc", "cc", "sh"], ["cc", "cc", "sh"], ["cc", "cc", "sh"],
		["cc", "cc", "sh"], ["ss", "cc", "chest"], ["ss", "ss", "chest"], ["", "ss", "chest"],
		["", "", "waist"], ["", "", "waist", "d"], ["", "", "hip", "p"], ["", "", "hip", "p"],
		["", "", "hip", "p"], ["", "", "hip", "p"],
	],
	"swing_b": [
		["", "", "sh"], ["cc", "cc", "sh"], ["cc", "cc", "sh"], ["cc", "cc", "sh"],
		["cc", "cc", "sh"], ["cc", "ss", "chest"], ["ss", "ss", "chest"], ["ss", "", "chest"],
		["", "", "waist"], ["", "", "waist", "d"], ["", "", "hip", "p"], ["", "", "hip", "p"],
		["", "", "hip", "p"], ["", "", "hip", "p"],
	],
	"pump_up": [
		["", "", "sh"], ["ss", "ss", "sh"], ["ss", "ss", "sh"], ["cc", "cc", "sh"],
		["cc", "cc", "sh"], ["cc", "cc", "chest"], ["cc", "cc", "chest"], ["", "", "chest"],
		["", "", "waist"], ["", "", "waist", "d"], ["", "", "hip", "p"], ["", "", "hip", "p"],
		["", "", "hip", "p"], ["", "", "hip", "p"],
	],
	"pump_down": [
		["", "", "sh"], ["cc", "cc", "sh"], ["cc", "cc", "sh"], ["cc", "cc", "sh"],
		["cc", "cc", "sh"], ["ss", "ss", "chest"], ["ss", "ss", "chest"], ["", "", "chest"],
		["", "", "waist"], ["", "", "waist", "d"], ["", "", "hip", "p"], ["", "", "hip", "p"],
		["", "", "hip", "p"], ["", "", "hip", "p"],
	],
	"rails": [
		["", "", "sh"], ["cc", "cc", "sh"], ["cc", "cc", "sh"],
		["ss", "ss", "sh"], ["cc", "cc", "sh"], ["cc", "cc", "chest"], ["cc", "cc", "chest"],
		["", "", "chest"], ["", "", "waist"], ["", "", "waist", "d"], ["", "", "hip", "p"],
		["", "", "hip", "p"], ["", "", "hip", "p"], ["", "", "hip", "p"],
	],
	"handlebar": [
		["", "", "sh"], ["cc", "cc", "sh"], ["cc", "cc", "sh"],
		["ss", "ss", "sh"], ["cc", "cc", "sh"], ["cc", "cc", "chest"], ["cc", "cc", "chest"],
		["", "", "chest"], ["", "", "waist"], ["", "", "waist", "d"], ["", "", "hip", "p"],
		["", "", "hip", "p"], ["", "", "hip", "p"], ["", "", "hip", "p"],
	],
	"wipe": [
		["", "", "sh"], ["cc", "cc", "sh"], ["cc", "cc", "sh"],
		["ss", "cc", "sh"], ["cc", "cc", "sh"], ["cc", "cc", "chest"], ["cc", "ss", "chest"],
		["", "", "chest"], ["", "", "waist"], ["", "", "waist", "d"], ["", "", "hip", "p"],
		["", "", "hip", "p"], ["", "", "hip", "p"], ["", "", "hip", "p"],
	],
	"raised": [
		["", "", "sh"], ["ss", "cc", "sh"], ["ss", "cc", "sh"], ["cc", "cc", "sh"],
		["cc", "cc", "sh"], ["cc", "cc", "chest"], ["cc", "ss", "chest"], ["", "", "chest"],
		["", "", "waist"], ["", "", "waist", "d"], ["", "", "hip", "p"], ["", "", "hip", "p"],
		["", "", "hip", "p"], ["", "", "hip", "p"],
	],
	"stretch_up": [
		["", "", "sh"], ["ss", "ss", "sh"], ["ss", "ss", "sh"], ["cc", "cc", "sh"],
		["cc", "cc", "sh"], ["cc", "cc", "chest"], ["cc", "cc", "chest"], ["", "", "chest"],
		["", "", "waist"], ["", "", "waist", "d"], ["", "", "hip", "p"], ["", "", "hip", "p"],
		["", "", "hip", "p"], ["", "", "hip", "p"],
	],
	"stretch_out": [
		["", "", "sh"], ["ss", "ss", "sh"], ["ss", "ss", "sh"], ["cc", "cc", "sh"],
		["cc", "cc", "sh"], ["cc", "cc", "chest"], ["cc", "cc", "chest"], ["", "", "chest"],
		["", "", "waist"], ["", "", "waist", "d"], ["", "", "hip", "p"], ["", "", "hip", "p"],
		["", "", "hip", "p"], ["", "", "hip", "p"],
	],
	"down": [
		["", "", "sh"], ["cc", "cc", "sh"], ["cc", "cc", "sh"], ["cc", "cc", "sh"],
		["cc", "cc", "sh"], ["ss", "ss", "chest"], ["ss", "ss", "chest"], ["", "", "chest"],
		["", "", "waist"], ["", "", "waist", "d"], ["", "", "hip", "p"], ["", "", "hip", "p"],
		["", "", "hip", "p"], ["", "", "hip", "p"],
	],
}


## V3.1 R2：按 build 宽度放样躯干 14 行（变体 1-3）。肩→胸→腰→臀逐段收窄/
## 加宽（体型 silhouette 差异化），中心对齐 x24。build 1（无袖背心）把
## 袖 "cc" 换成皮肤 "ss" —— 手臂裸露，运动服配色差异。
func _torso_build_rows(arms: String, variant: int) -> PackedStringArray:
	var b: Dictionary = BUILDS[variant % VARIANT_COUNT]
	var tpl: Array = TORSO_TPL.get(arms, TORSO_TPL["down"])
	var r := PackedStringArray()
	var tank := str(b.get("sleeve", "cc")) == "ss"
	for spec: Array in tpl:
		var l := String(spec[0])
		var rr := String(spec[1])
		if tank:
			l = l.replace("cc", "ss")
			rr = rr.replace("cc", "ss")
		var w := _build_width(String(spec[2]), b)
		var ch := "c"
		if spec.size() > 3:
			ch = String(spec[3])
		var content := l + ch.repeat(w) + rr
		var left := 24 - content.length() / 2
		r.append(_r(left, content))
	return r


## W 键 → build 宽度（字符数）。
func _build_width(key: String, b: Dictionary) -> int:
	match key:
		"sh":
			return int(b.get("sh", 28))
		"chest":
			return int(b.get("chest", 26))
		"waist":
			return int(b.get("waist", 22))
		"hip":
			return int(b.get("hip", 24))
	return int(b.get("waist", 22))


## 腿（9 行 32..40）：裤 + 短腿（V3 §8 四肢较短）。
## [legs] 决定步态（迈步/骑踏/盘坐/站立）。
## V3.1 R2：变体 0 走既有手写行（测试像素断言 pin）；变体 1-3 由
## _leg_build_rows 按 build 放样（腿粗 + build 1 运动短裤露出小腿皮肤）。
func _leg_rows(legs: String, variant: int) -> PackedStringArray:
	if variant % VARIANT_COUNT != 0:
		return _leg_build_rows(legs, variant)
	var r := PackedStringArray()
	match legs:
		"stride_f":  # walk A：左腿前迈 + 右腿后蹬
			r.append(_r(8, "ppp" + "........" + "ppp"))
			r.append(_r(8, "ppp" + "........" + "ppp"))
			r.append(_r(8, "ppp" + "........" + "ppp"))
			r.append(_r(6, "pppppp" + "...." + "ppp"))
			r.append(_r(6, "pppppp" + "...." + "ppp"))
			r.append(_r(6, "pppppp" + "...." + "ppp"))
			r.append(_r(6, "kkkkkk" + "...." + "kkk"))   # 前脚着地 + 后脚
			r.append(_r(6, "kkkkkk" + "...." + "kkk"))
			r.append(_r(8, "kkkkkkkkkkkk"))
		"stride_b":  # walk B：右腿前迈 + 左腿后蹬
			r.append(_r(8, "ppp" + "........" + "ppp"))
			r.append(_r(8, "ppp" + "........" + "ppp"))
			r.append(_r(8, "ppp" + "........" + "ppp"))
			r.append(_r(8, "ppp" + "...." + "pppppp"))
			r.append(_r(8, "ppp" + "...." + "pppppp"))
			r.append(_r(8, "ppp" + "...." + "pppppp"))
			r.append(_r(8, "kkk" + "...." + "kkkkkk"))
			r.append(_r(8, "kkk" + "...." + "kkkkkk"))
			r.append(_r(8, "kkkkkkkkkkkk"))
		"plant":     # use：双脚站稳（宽距）
			r.append(_r(6, "pppppppppppp"))
			r.append(_r(6, "pppppppppppp"))
			r.append(_r(6, "pppppppppppp"))
			r.append(_r(5, "pppppppppppppp"))
			r.append(_r(5, "pppppppppppppp"))
			r.append(_r(5, "pppppppppppppp"))
			r.append(_r(4, "kkkkkkkkkkkkkkkk"))
			r.append(_r(4, "kkkkkkkkkkkkkkkk"))
			r.append(_r(6, "kkkkkkkkkkkk"))
		"pedal_f":   # bike A：左脚下踏 + 右脚上抬
			r.append(_r(8, "ppp" + "........" + "ppp"))
			r.append(_r(8, "ppp" + "........" + "ppp"))
			r.append(_r(8, "ppp" + "........" + "ppp"))
			r.append(_r(6, "pppppp" + "...." + "ppp"))
			r.append(_r(6, "pppppp" + "...." + "ppp"))
			r.append(_r(6, "pppppp" + "...." + "ppp"))
			r.append(_r(4, "kkkkkkkk" + ".." + "kkk"))   # 左脚下踏（宽）+ 右脚踏高
			r.append(_r(4, "kkkkkkkk" + ".." + "kkk"))
			r.append(_r(6, "kkkkkkkkkkkk"))
		"pedal_b":   # bike B：右脚下踏 + 左脚上抬
			r.append(_r(8, "ppp" + "........" + "ppp"))
			r.append(_r(8, "ppp" + "........" + "ppp"))
			r.append(_r(8, "ppp" + "........" + "ppp"))
			r.append(_r(8, "ppp" + "...." + "pppppp"))
			r.append(_r(8, "ppp" + "...." + "pppppp"))
			r.append(_r(8, "ppp" + "...." + "pppppp"))
			r.append(_r(8, "kkk" + ".." + "kkkkkkkk"))   # 左脚上抬 + 右脚下踏
			r.append(_r(8, "kkk" + ".." + "kkkkkkkk"))
			r.append(_r(8, "kkkkkkkkkkkk"))
		"cross":     # yoga：盘坐（宽、短）
			r.append(_r(6, "pppppppppppp"))
			r.append(_r(6, "pppppppppppp"))
			r.append(_r(5, "pppppppppppppp"))
			r.append(_r(5, "pppppppppppppp"))
			r.append(_r(5, "pppppppppppppp"))
			r.append(_r(4, "pppppppppppppppp"))
			r.append(_r(4, "kkkkkkkkkkkkkkkk"))
			r.append(_r(4, "kkkkkkkkkkkkkkkk"))
			r.append(_r(4, "kkkkkkkkkkkkkkkk"))
		"bent":      # tired：腿微弯（站不稳的松弛感）
			r.append(_r(9, "pppppppppp"))
			r.append(_r(9, "pppppppppp"))
			r.append(_r(9, "pppppppppp"))
			r.append(_r(8, "pppppppppppp"))
			r.append(_r(8, "pppppppppppp"))
			r.append(_r(8, "pppppppppppp"))
			r.append(_r(6, "kkkkkkkkkkkkkk"))
			r.append(_r(6, "kkkkkkkkkkkkkk"))
			r.append(_r(6, "kkkkkkkkkkkkkk"))
		_:
			r.append(_r(9, "pppppppppp"))
			r.append(_r(9, "pppppppppp"))
			r.append(_r(9, "pppppppppp"))
			r.append(_r(9, "pppppppppp"))
			r.append(_r(9, "pppppppppp"))
			r.append(_r(9, "pppppppppp"))
			r.append(_r(8, "kkkkkkkkkkkk"))
			r.append(_r(8, "kkkkkkkkkkkk"))
			r.append(_r(8, "kkkkkkkkkkkk"))
	return r


## V3.1 R2：按 build 放样腿 9 行（变体 1-3）。单腿宽 = max(3, leg/4)；
## build 1（运动短裤）裤行 0..2 用短裤色 p、行 3..5 露小腿皮肤 s、行 6..8
## 鞋 k —— 与长裤 build 的 silhouette 差异明显（V3.1 R2 运动服配色）。
## 步态结构（行 0..2 / 3..5 / 6..8）与手写行一致；行宽随 build 缩放。
func _leg_build_rows(legs: String, variant: int) -> PackedStringArray:
	var b: Dictionary = BUILDS[variant % VARIANT_COUNT]
	var lw := maxi(3, int(b.get("leg", 12)) / 4)
	var shorts := str(b.get("legwear", "pants")) == "shorts"
	var up := "p"           # 裤/短裤
	var down := "s" if shorts else "p"   # 短裤露小腿皮肤 / 长裤继续裤色
	var r := PackedStringArray()
	match legs:
		"stride_f":  # walk A：左腿前迈 + 右腿后蹬
			for _i in 3:
				r.append(_r(8, up.repeat(lw) + ".".repeat(8) + up.repeat(lw)))
			for _i in 3:
				r.append(_r(6, down.repeat(lw * 2) + "...." + down.repeat(lw)))
			for _i in 2:
				r.append(_r(6, "k".repeat(lw * 2) + "...." + "k".repeat(lw)))
			r.append(_r(8, "k".repeat(lw * 3)))
		"stride_b":  # walk B：右腿前迈 + 左腿后蹬（镜像）
			for _i in 3:
				r.append(_r(8, up.repeat(lw) + ".".repeat(8) + up.repeat(lw)))
			for _i in 3:
				r.append(_r(8, up.repeat(lw) + "...." + up.repeat(lw * 2)))
			for _i in 2:
				r.append(_r(8, "k".repeat(lw) + "...." + "k".repeat(lw * 2)))
			r.append(_r(8, "k".repeat(lw * 3)))
		"plant":  # use：双脚站稳（宽距）
			for _i in 3:
				r.append(_r(6, up.repeat(lw * 2)))
			for _i in 3:
				r.append(_r(5, down.repeat(lw * 2 + 2)))
			for _i in 2:
				r.append(_r(4, "k".repeat(lw * 2 + 4)))
			r.append(_r(6, "k".repeat(lw * 2 + 2)))
		"pedal_f":  # bike A：左脚下踏 + 右脚上抬
			for _i in 3:
				r.append(_r(8, up.repeat(lw) + ".".repeat(8) + up.repeat(lw)))
			for _i in 3:
				r.append(_r(6, down.repeat(lw * 2) + "...." + down.repeat(lw)))
			for _i in 2:
				r.append(_r(4, "k".repeat(lw * 2) + ".." + "k".repeat(lw)))
			r.append(_r(6, "k".repeat(lw * 3)))
		"pedal_b":  # bike B：右脚下踏 + 左脚上抬
			for _i in 3:
				r.append(_r(8, up.repeat(lw) + ".".repeat(8) + up.repeat(lw)))
			for _i in 3:
				r.append(_r(8, up.repeat(lw) + "...." + up.repeat(lw * 2)))
			for _i in 2:
				r.append(_r(8, "k".repeat(lw) + ".." + "k".repeat(lw * 2)))
			r.append(_r(8, "k".repeat(lw * 3)))
		"cross":  # yoga：盘坐（宽、短）
			for _i in 3:
				r.append(_r(6, up.repeat(lw * 2)))
			for _i in 3:
				r.append(_r(5, down.repeat(lw * 2 + 2)))
			for _i in 3:
				r.append(_r(4, "k".repeat(lw * 2 + 4)))
		"bent":  # tired：腿微弯
			for _i in 3:
				r.append(_r(9, up.repeat(lw)))
			for _i in 3:
				r.append(_r(8, down.repeat(lw + 2)))
			for _i in 3:
				r.append(_r(6, "k".repeat(lw + 4)))
		_:
			# stand：双脚并立
			for _i in 6:
				r.append(_r(9, up.repeat(lw)))
			for _i in 3:
				r.append(_r(8, "k".repeat(lw + 2)))
	return r


## 鞋（3 行 41..43）+ 影（4 行 44..47）。阴影固定在地面，身体做弹跳/下蹲时
## 不跟着浮动（_bob_up 只移动 0..40 行）。
func _shoe_rows() -> PackedStringArray:
	var r := PackedStringArray()
	r.append(_r(8, "kkkkkkkkkkkk"))
	r.append(_r(8, "kkkkkkkkkkkk"))
	r.append(_r(8, "kkkkkkkkkkkk"))
	return r


## 脚底接触影（4 行 44..47）：随身体保持贴地（_bob_up 只移动 0..40 行）。
## V3.1 R2（P2-sprite）：从「36px 全宽平带」改为「脚下收拢的椭圆」——
## 行 44 窄（贴身）、行 45-47 渐宽，全部居中 x24；contact shadow 明确
## （V3 §6 设备/人物脚下明显但柔和的 contact shadow，非整片暗板）。
func _shadow_rows() -> PackedStringArray:
	var r := PackedStringArray()
	r.append(_r(14, "y".repeat(20)))
	r.append(_r(11, "y".repeat(26)))
	r.append(_r(10, "y".repeat(28)))
	r.append(_r(10, "y".repeat(28)))
	return r


# === 姿态帧组装 ===

## 组装基础帧：头 + 躯干 + 腿 + 鞋 + 影（48 行）。
func _assemble(face: String, arms: String, legs: String, variant: int,
		bob: int = 0) -> PackedStringArray:
	var rows := PackedStringArray()
	rows.append_array(_head_rows(face, variant))
	rows.append_array(_torso_rows(arms, variant))
	rows.append_array(_leg_rows(legs, variant))
	rows.append_array(_shoe_rows())
	rows.append_array(_shadow_rows())
	if bob != 0:
		rows = _bob_up(rows, bob)
	return rows


## idle：无聊脸（半闭眼），站立微晃（B 帧 1px 上浮）。
func _idle_rows(frame: int, variant: int) -> PackedStringArray:
	return _assemble(FACE_BORED, "down", "stand", variant, 1 if frame == 1 else 0)


## walk：专注脸 + 前倾摆臂迈步（V3 §8 跑步：身体前倾、手臂摆动、腿部循环）。
## A=左臂前摆/左脚迈出；B=镜像（+1px 弹跳）。
func _walk_rows(frame: int, variant: int) -> PackedStringArray:
	if frame == 0:
		return _assemble(FACE_FOCUS, "swing_f", "stride_f", variant)
	var rows := _assemble(FACE_FOCUS, "swing_b", "stride_b", variant, 1)
	return rows


## tired（QUEUEING 等待）：累弯腰 + 擦汗 + 喘气 + 头顶汗滴（V3 §8/§9）。
## A=擦汗手举到额侧 + 汗滴在头顶左；B=汗滴右移 + 弯腰更深（下蹲 1px）。
## 布局：2 行汗滴（0..1）+ compact 头 16 行（2..17）+ 躯干 14（18..31）
## + 腿 9（32..40）+ 鞋 3（41..43）+ 影 4（44..47）= 48。
func _tired_rows(frame: int, variant: int) -> PackedStringArray:
	var rows := PackedStringArray()
	# 头顶汗滴（§9 角色汗滴）：位于头之上，A/B 左右微移形成"滴落感"。
	# V3 §15（P0-3）：2px→3px 加宽，远景辨识度（unit 断言仍 pin (22,0)）。
	if frame == 0:
		rows.append(_r(21, "www"))
		rows.append(_r(22, "www"))
	else:
		rows.append(_r(23, "www"))
		rows.append(_r(24, "www"))
	rows.append_array(_head_rows(FACE_PANT, variant, true))
	rows.append_array(_torso_rows("wipe", variant))
	rows.append_array(_leg_rows("bent", variant))
	rows.append_array(_shoe_rows())
	rows.append_array(_shadow_rows())
	if frame == 1:
		rows = _bob_up(rows, 1)
	return rows


## satisfied（LEAVING + quota_met）：满意挺胸 + 举手 + 小闪光（V3 §8/§9）。
## A=闪光在举手上方左；B=闪光右移（闪烁感）。
## 布局同 tired：2 行闪光（0..1）+ compact 头 16（2..17）+ 躯干 14 + 腿 9
## + 鞋 3 + 影 4 = 48。
func _satisfied_rows(frame: int, variant: int) -> PackedStringArray:
	var rows := PackedStringArray()
	# V3 §15（P0-3）：小闪光 2px→3px 加宽，远景辨识度（unit 断言仍 pin (9,0)）。
	if frame == 0:
		rows.append(_r(8, "ggg"))
		rows.append(_r(9, "ggg"))
	else:
		rows.append(_r(11, "ggg"))
		rows.append(_r(10, "ggg"))
	rows.append_array(_head_rows(FACE_HAPPY, variant, true))
	rows.append_array(_torso_rows("raised", variant))
	rows.append_array(_leg_rows("stand", variant))
	rows.append_array(_shoe_rows())
	rows.append_array(_shadow_rows())
	if frame == 1:
		rows = _bob_up(rows, 1)
	return rows


## treadmill：跑带奔跑 —— 前倾 + 摆臂 + 迈步循环（与 walk 同节奏，专注脸）。
func _treadmill_rows(frame: int, variant: int) -> PackedStringArray:
	if frame == 0:
		return _assemble(FACE_FOCUS, "rails", "stride_f", variant)
	return _assemble(FACE_FOCUS, "rails", "stride_b", variant, 1)


## bike：骑行 —— 身体前倾 + 双手握把 + 双脚交替踏（V3 §8 自行车使用姿势）。
func _bike_rows(frame: int, variant: int) -> PackedStringArray:
	if frame == 0:
		return _assemble(FACE_FOCUS, "handlebar", "pedal_f", variant)
	return _assemble(FACE_FOCUS, "handlebar", "pedal_b", variant, 1)


## yoga：瑜伽 —— 盘坐 + 双臂上举/平伸（V3 §8 瑜伽垫上的使用姿势）。
func _yoga_rows(frame: int, variant: int) -> PackedStringArray:
	if frame == 0:
		return _assemble(FACE_BORED, "stretch_up", "cross", variant)
	return _assemble(FACE_BORED, "stretch_out", "cross", variant)


## use generic（未知设备兜底）：用力脸 + 双手泵举。A=举到肩高；B=臂下垂 + 下蹲。
func _use_generic_rows(frame: int, variant: int) -> PackedStringArray:
	if frame == 0:
		return _assemble(FACE_EFFORT, "pump_up", "plant", variant)
	return _assemble(FACE_EFFORT, "pump_down", "plant", variant, 1)


## 卧推（躺姿，横向构图，V3 §8 "杠铃上下运动、身体轻微形变"）：
## 身体横躺在卧推凳上（头在左、躯干向右、腿弯在右），杠铃在胸口上方
## 上下移动 —— 身体位置固定，仅杠铃 + 手臂随帧上下。A=杠铃下压（贴胸，
## 臂弯）；B=杠铃上推（远离胸口，臂直）。横躺构图：身体占用 18..33 行，
## 杠铃在 6..16 行；其余行透明。
func _bench_rows(frame: int, variant: int) -> PackedStringArray:
	var r := PackedStringArray()
	# 0..5 行留白（杠铃上方）
	for _i in 6:
		r.append(_r(0, ""))
	# 杠铃（金属杠 + 配重片 + 高光）：A 下压（行 12..15）/ B 上推（行 6..9）。
	# 两帧杠铃+手臂区域总高相同（12 行：6..17），身体固定从 18 行开始。
	if frame == 0:
		# 杠铃下压：高 6 行空白后杠在 12..15，臂弯在 16..17
		for _i in 6:
			r.append(_r(0, ""))
		r.append(_r(6, "MMMM" + "M".repeat(30) + "MMMM"))
		r.append(_r(5, "GMMM" + "M".repeat(30) + "MMMG"))
		r.append(_r(6, "MMMM" + "M".repeat(30) + "MMMM"))
		r.append(_r(6, "GGGG" + ".".repeat(30) + "GGGG"))
		# 臂弯（手在胸口两侧，紧贴杠下方）
		r.append(_r(6, "ssss" + ".".repeat(30) + "ssss"))
		r.append(_r(8, "cccc" + ".".repeat(26) + "cccc"))
	else:
		# 杠铃上推：杠在 6..9，臂直在 10..11（总高 12 行，6..17）
		r.append(_r(6, "MMMM" + "M".repeat(30) + "MMMM"))
		r.append(_r(5, "GMMM" + "M".repeat(30) + "MMMG"))
		r.append(_r(6, "MMMM" + "M".repeat(30) + "MMMM"))
		r.append(_r(6, "GGGG" + ".".repeat(30) + "GGGG"))
		# 臂直（手高，在杠下方）
		r.append(_r(5, "ssss" + ".".repeat(30) + "ssss"))
		r.append(_r(6, "cccc" + ".".repeat(28) + "cccc"))
		# 补齐杠铃区域高度（6..17 = 12 行）：上推帧杠铃高 4 行，补 6 行空
		for _i in 6:
			r.append(_r(0, ""))
	# 身体（横躺，固定 18..33 行）：头在左（发 h + 脸 s + 眼 e），躯干 c
	# 向右延伸，腿 p 弯在右，鞋 k。身体位置不随帧移动 —— 动作只由杠铃 +
	# 手臂上下表达（V3 §8 "杠铃上下运动"）。
	r.append(_r(0, "hh"))
	r.append(_r(0, "hhss"))
	r.append(_r(0, "hhsseess"))
	r.append(_r(0, "hhss"))
	r.append(_r(0, "hh"))
	r.append(_r(0, "ccccccccccccccccccccccccccccccccccccccc"))
	r.append(_r(0, "ccccccccccccccccccccccccccccccccccccccc"))
	r.append(_r(0, "ddddddddddddddddddddddddddddddddddddddd"))
	r.append(_r(4, "ppppppppppppppppppppppppppppppppp"))
	r.append(_r(8, "pppppppppppppppppppppppppppp"))
	r.append(_r(10, "kkkkkkkkkkkkkkkkkkkkkkkk"))
	r.append(_r(10, "kkkkkkkkkkkkkkkkkkkkkkkk"))
	# 补齐到 48 行（横躺构图，多余行透明）
	while r.size() < SIZE:
		r.append(_r(0, ""))
	return r


## 卧推结束坐起（V3 §8 "结束时坐起"）：身体坐直，双臂放下，杠铃已归架。
func _bench_situp_rows(frame: int, variant: int) -> PackedStringArray:
	var rows := PackedStringArray()
	rows.append_array(_head_rows(FACE_EFFORT, variant))
	rows.append_array(_torso_rows("down", variant))
	rows.append_array(_leg_rows("stand", variant))
	rows.append_array(_shoe_rows())
	rows.append_array(_shadow_rows())
	if frame == 1:
		rows = _bob_up(rows, 1)
	return rows


## 整身（头→鞋，行 0..43）上移 n px；阴影行（44..47）不动 —— 脚底阴影
## 固定在地面，身体做 1px 弹跳/下蹲，避免阴影跟着角色浮动。
## 行布局：头 0..17 + 躯干 18..31 + 腿 32..40 + 鞋 41..43 = 身体 0..43。
func _bob_up(rows: PackedStringArray, n: int) -> PackedStringArray:
	var out := PackedStringArray()
	for i in rows.size():
		if i < 44 - n:
			out.append(rows[i + n])
		elif i < 44:
			out.append(".".repeat(SIZE))
		else:
			out.append(rows[i])  # 阴影行固定
	return out


## 生成左对齐 48 字符行（content 放 left 偏移处，右侧补透明）。
func _r(left: int, content: String) -> String:
	var s := ".".repeat(maxi(left, 0)) + content
	return s.rpad(SIZE, ".")


# === 颜色 ===

## 颜色通道 → 衬衫色（全部来自 palette.gd 单一色源，Phase C 语义保留）。
func _shirt_color(channel: String) -> Color:
	match channel:
		CH_SKY:
			return Palette.SKY
		CH_PEACH:
			return Palette.PEACH
		CH_GRAY:
			return Palette.MEMBER_LEAVE_GRAY
		_:
			return Palette.SKY


## 图例字符 → 实际颜色。变体 v 提供每人外观色（发型/皮肤/裤/鞋）。
## 阴影侧（V3 §6 顶部暖光 → 右侧冷暗）由主色 darkened 派生；高光侧
## （左侧受光）由 lightened 派生 —— 同一色源，无硬编码新色。
func _char_color(ch: String, shirt: Color, v: Dictionary) -> Color:
	match ch:
		"h":
			return v["hair"]
		"H":
			return v["hair"].lightened(0.18)   # 发高光侧（左上受光）
		"Z":
			return v["hair"].darkened(0.22)    # 发阴影侧（右下背光）
		"s":
			return v["skin"]
		"S":
			return v["skin"].lightened(0.12)   # 脸高光侧
		"X":
			return v["skin"].darkened(0.15)    # 脸阴影侧
		"e", "m", "b":
			return Palette.CHARCOAL
		"c":
			return shirt
		"l":
			return shirt.lightened(0.15)       # 衬衫高光侧
		"q":
			return shirt.darkened(0.22)        # 衬衫阴影侧
		"d":
			return shirt.darkened(0.18)
		"p":
			return v["pants"]
		"v":
			return v["pants"].lightened(0.12)  # 裤高光侧
		"x":
			return v["pants"].darkened(0.18)   # 裤阴影侧
		"k":
			return v["shoes"]
		"y":
			return Palette.MEMBER_SHADOW
		"w":
			return Palette.BUTTER
		"g":
			return Palette.BUTTER
		"M":
			return Palette.METAL_DARK
		"G":
			return Palette.METAL_HIGHLIGHT
		_:
			return Color(0, 0, 0, 0)


## 水平镜像（供 facing_left）。
func _mirror(src: Image) -> Image:
	var out := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	for y in SIZE:
		for x in SIZE:
			out.set_pixel(x, y, src.get_pixel(SIZE - 1 - x, y))
	return out
