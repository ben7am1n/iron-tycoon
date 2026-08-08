# src/presentation/member_sprite.gd — Phase C v2: 2.5D 像素会员小人图集
#
# Story: visual-polish-v2 / phase-c-member-characters
# Docs:  design/art/art-bible-25d-style.md §1 角色比例（2.5-3 头身敦实卡通风）、
#        §2 像素主体（大色块 + 剪影第一优先、低细节高表达）、
#        §3 负面约束（无黑色粗描边全覆盖、无柔滑轮廓）、
#        §4 判断标准第 2 条（粗颗粒手工归纳 2D sprite）
#        design/art/art-bible.md §4 语义色彩（正向=绿色系…）、§7 交互反馈
#
# 程序化生成 32×32 会员小人（CELL_SIZE=32，1:1 绘制，无缩放 → 像素阶梯
# 天然清晰；若未来放大渲染需设 CanvasItem.TEXTURE_FILTER_NEAREST）。
# 全部颜色引用 src/palette.gd（单一色源，项目约定 —— 本文件不写色值字面量）。
#
# 状态双通道（色盲安全）：
#   - 颜色通道（衬衫色）：WALKING_TO/ENTERING/SELECTING_TARGET → Sky 系
#                          QUEUEING/USING → Peach 系
#                          LEAVING → 低饱和灰（MEMBER_LEAVE_GRAY）
#   - 形状/姿态通道：walk（摆臂迈步 + 专注眼）/ idle（站立微晃 + 半闭眼）/
#                    use（器械动作幅度明显 + 用力眉/张嘴）
#
# 帧：每姿态 2 帧（A/B）。walk/use 按 tick 奇偶交替（10Hz 观感），
# idle 每 2 tick 交替（5Hz 微晃）。游戏逻辑 60fps 不变 —— 仅渲染帧选择。
# 朝向：facing_left 时水平镜像生成，不依赖渲染期变换。
extends RefCounted

const Palette := preload("res://src/palette.gd")

const SIZE := 32

# === 颜色通道（状态 → 衬衫色） ===
const CH_SKY := "sky"
const CH_PEACH := "peach"
const CH_GRAY := "gray"

# === 姿态 ===
const POSE_IDLE := "idle"
const POSE_WALK := "walk"
const POSE_USE := "use"

# === 脸部变体 ===
const FACE_BORED := "bored"    # idle：半闭眼（1px 高）+ 小嘴
const FACE_FOCUS := "focus"    # walk：2×2 眼 + 小嘴
const FACE_EFFORT := "effort"  # use：用力眉 + 2×2 眼 + 张嘴

# === 纹理缓存：key = "channel|pose|frame_bit|facing_left" → ImageTexture ===
var _cache: Dictionary = {}


# === 状态映射（member_sim.gd 状态枚举名，已核实） ===

## 状态 → 颜色通道。GONE / 被动成员（无 state 键）/ 未知 → ""（不渲染）。
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


## 状态 → 姿态（形状通道）。
func state_pose(state: String) -> String:
	match state:
		"WALKING_TO", "ENTERING", "LEAVING":
			return POSE_WALK
		"QUEUEING", "SELECTING_TARGET":
			return POSE_IDLE
		"USING":
			return POSE_USE
		_:
			return POSE_IDLE


## 帧位（0/1）：walk/use 按 tick 奇偶交替（10Hz 观感），idle 每 2 tick
## 交替（5Hz 微晃）。游戏逻辑 60fps 不变 —— 这只是渲染帧选择。
func frame_bit(state: String, tick: int) -> int:
	if state_pose(state) == POSE_IDLE:
		return (tick / 2) % 2
	return tick % 2


## 取纹理（缓存命中或生成）。facing_left=true 时返回水平镜像。
func texture_for(state: String, tick: int, facing_left: bool) -> ImageTexture:
	var channel := state_channel(state)
	var pose := state_pose(state)
	var key := "%s|%s|%d|%s" % [channel, pose, frame_bit(state, tick), str(facing_left)]
	if _cache.has(key):
		return _cache[key]
	var img := _build_frame(channel, pose, frame_bit(state, tick))
	if facing_left:
		img = _mirror(img)
	var tex := ImageTexture.create_from_image(img)
	_cache[key] = tex
	return tex


# === 帧构建 ===

func _build_frame(channel: String, pose: String, frame: int) -> Image:
	var rows := _frame_rows(pose, frame)
	var shirt := _shirt_color(channel)
	var img := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	for y in rows.size():
		var row: String = rows[y]
		for x in row.length():
			var ch := row[x]
			if ch == ".":
				continue
			img.set_pixel(x, y, _char_color(ch, shirt))
	return img


## 32 行 × 32 字符的帧数据（"手工归纳"像素图 —— 逐行定义，无抗锯齿）。
func _frame_rows(pose: String, frame: int) -> PackedStringArray:
	match pose:
		POSE_WALK:
			return _walk_rows(frame)
		POSE_USE:
			return _use_rows(frame)
		_:
			return _idle_rows(frame)


## idle：无聊脸（半闭眼），站立微晃（B 帧 1px 上浮）。
func _idle_rows(frame: int) -> PackedStringArray:
	var rows := _base_rows(FACE_BORED)
	if frame == 1:
		rows = _bob_up(rows, 1)
	return rows


## walk：专注脸 + 摆臂迈步。A=左臂前摆/左脚迈出；B=镜像（+1px 弹跳）。
func _walk_rows(frame: int) -> PackedStringArray:
	var rows := _walk_frame_rows(frame == 1)
	if frame == 1:
		rows = _bob_up(rows, 1)
	return rows


## use：用力脸。A=双手举到肩高（泵）；B=臂下垂 + 1px 下蹲弹跳。
func _use_rows(frame: int) -> PackedStringArray:
	if frame == 0:
		return _use_arms_up_rows()
	var rows := _base_rows(FACE_EFFORT)
	return _bob_up(rows, 1)


# === 行常量（手工归纳像素图 —— 大色块 + 剪影第一优先） ===

const R_HAIR_TUFT := "hhhhhh"
const R_HAIR_12 := "hhhhhhhhhhhh"
const R_HAIR_14 := "hhhhhhhhhhhhhh"
const R_HAIR_16 := "hhhhhhhhhhhhhhhh"
const R_FACE_16 := "hssssssssssssssh"     # 发两侧 + 脸
const R_FACE_CHIN := "hsssssssssssh"      # 下巴收窄（12 宽）
const R_EYES_16 := "hssseessseessssh"     # 2×2 眼
const R_BROW_16 := "hsssbbsssbbssssh"     # 用力眉
const R_MOUTH_SMALL := "hssssssmmssssssh" # 小嘴
const R_MOUTH_OPEN := "hsssssmmmmsssssh"  # 张嘴（用力）
const R_SHIRT_16 := "cccccccccccccccc"
const R_SHIRT_12 := "cccccccccccc"
const R_SHADE_12 := "dddddddddddd"
const R_PANTS_12 := "pppppppppppp"
const R_LEG := "ppp" + "...." + "ppp"
const R_SHOES := "kkkkk" + ".." + "kkkkk"
const R_SHADOW := "yyyyyyyyyyyyyyyyyy"


## 基础帧：头（12 行：发顶圆顶 5 + 脸 7，下巴收窄）+ 躯干（9 行：
## 肩 1 + 臂 4 + 手 2 + 躯干 1 + 下摆 1）+ 腰 1 + 腿 6 + 鞋 2 + 影 2 = 32 行。
## 头宽 16px、躯干 12px（臂在外侧）→ 头大身小敦实比例；发顶圆顶 + 一撮
## 呆毛；脸低细节高表达（眼/嘴变体）。
func _base_rows(face: String) -> PackedStringArray:
	var r := PackedStringArray()
	# 头 —— 发顶圆顶（下宽上窄，切出圆润头型），顶上一撮呆毛（2px 高，
	# 保证 bob 上浮 1px 时仍有残留，不闪烁）
	r.append(_r(13, R_HAIR_TUFT))
	r.append(_r(13, R_HAIR_TUFT))
	r.append(_r(10, R_HAIR_12))
	r.append(_r(9, R_HAIR_14))
	r.append(_r(8, R_HAIR_16))
	# 脸 7 行（发两侧 H 延伸至下巴，形成圆脸；半闭眼/用力眉变体）
	r.append(_r(8, R_FACE_16))
	match face:
		FACE_EFFORT:
			r.append(_r(8, R_BROW_16))       # 用力眉
		_:
			r.append(_r(8, R_FACE_16))
	if face == FACE_BORED:
		r.append(_r(8, R_FACE_16))           # 半闭眼：上排无眼
		r.append(_r(8, R_EYES_16))           # 下排 1px 眼
	else:
		r.append(_r(8, R_EYES_16))
		r.append(_r(8, R_EYES_16))
	r.append(_r(8, R_FACE_16))
	r.append(_r(8, R_MOUTH_OPEN if face == FACE_EFFORT else R_MOUTH_SMALL))
	r.append(_r(10, R_FACE_CHIN))            # 下巴收窄（12 宽）
	# 躯干（12 宽）+ 臂下垂（臂在 x8-9 / x22-23）
	r.append(_r(10, R_SHIRT_12))             # 肩
	r.append(_r(8, "cc" + R_SHIRT_12 + "cc"))    # 臂
	r.append(_r(8, "cc" + R_SHIRT_12 + "cc"))
	r.append(_r(8, "cc" + R_SHIRT_12 + "cc"))
	r.append(_r(8, "cc" + R_SHIRT_12 + "cc"))
	r.append(_r(8, "ss" + R_SHIRT_12 + "ss"))    # 手（肤色）
	r.append(_r(8, "ss" + R_SHIRT_12 + "ss"))
	r.append(_r(10, R_SHIRT_12))             # 躯干
	r.append(_r(10, R_SHADE_12))             # 衬衫下摆阴影
	# 腰 + 腿 6 行（裤）
	r.append(_r(10, R_PANTS_12))
	for _i in 6:
		r.append(_r(11, R_LEG))
	# 鞋 2 行
	r.append(_r(10, R_SHOES))
	r.append(_r(10, R_SHOES))
	# 脚底阴影（大块暗面，art-bible-25d §2）
	r.append(_r(7, R_SHADOW))
	r.append(_r(7, R_SHADOW))
	return r


## 走路帧：摆臂迈步（A：左臂前摆+左脚迈出；B：镜像）。
## 前摆臂手部上移 1 行、后摆臂手部下移 1 行；前脚鞋伸宽着地、后脚鞋抬高。
func _walk_frame_rows(mirror: bool) -> PackedStringArray:
	var r := PackedStringArray()
	# 头（专注脸）
	r.append(_r(13, R_HAIR_TUFT))
	r.append(_r(13, R_HAIR_TUFT))
	r.append(_r(10, R_HAIR_12))
	r.append(_r(9, R_HAIR_14))
	r.append(_r(8, R_HAIR_16))
	r.append(_r(8, R_FACE_16))
	r.append(_r(8, R_FACE_16))
	r.append(_r(8, R_EYES_16))
	r.append(_r(8, R_EYES_16))
	r.append(_r(8, R_FACE_16))
	r.append(_r(8, R_MOUTH_SMALL))
	r.append(_r(10, R_FACE_CHIN))
	# 躯干 + 摆臂
	if not mirror:
		# 左臂前摆（手在 r16-17，抬 1 行）；右臂后摆（手在 r17-18）
		r.append(_r(10, R_SHIRT_12))                    # 肩
		r.append(_r(8, "cc" + R_SHIRT_12 + "cc"))       # 双袖
		r.append(_r(8, "cc" + R_SHIRT_12 + "cc"))
		r.append(_r(8, "cc" + R_SHIRT_12 + "cc"))
		r.append(_r(8, "ss" + R_SHIRT_12 + "cc"))       # 左手 + 右袖
		r.append(_r(8, "ss" + R_SHIRT_12 + "ss"))       # 双手
		r.append(_r(10, R_SHIRT_12 + "ss"))             # 躯干 + 右手（降 1 行）
		r.append(_r(10, R_SHIRT_12))
		r.append(_r(10, R_SHADE_12))
	else:
		r.append(_r(10, R_SHIRT_12))
		r.append(_r(8, "cc" + R_SHIRT_12 + "cc"))
		r.append(_r(8, "cc" + R_SHIRT_12 + "cc"))
		r.append(_r(8, "cc" + R_SHIRT_12 + "cc"))
		r.append(_r(8, "cc" + R_SHIRT_12 + "ss"))       # 左袖 + 右手
		r.append(_r(8, "ss" + R_SHIRT_12 + "ss"))       # 双手
		r.append(_r(8, "ss" + R_SHIRT_12))              # 左手 + 躯干（降 1 行）
		r.append(_r(10, R_SHIRT_12))
		r.append(_r(10, R_SHADE_12))
	# 腰 + 腿 + 鞋（迈步：前脚鞋伸宽/着地，后脚鞋抬高 1 行）
	r.append(_r(10, R_PANTS_12))
	for _i in 5:
		r.append(_r(11, R_LEG))
	if not mirror:
		r.append(_r(11, "ppp" + "..." + "kkkkk"))       # 左腿 + 右鞋（抬）
		r.append(_r(9, "kkkkkk" + ".." + "kkkkk"))      # 左脚（伸宽）+ 右鞋
		r.append(_r(9, "kkkkkk"))                        # 左脚继续着地
	else:
		r.append(_r(10, "kkkkk" + "..." + "ppp"))       # 左鞋（抬）+ 右腿
		r.append(_r(10, "kkkkk" + "." + "kkkkkk"))      # 左鞋 + 右脚（伸宽）
		r.append(_r(16, "kkkkkk"))                       # 右脚继续着地
	# 影
	r.append(_r(7, R_SHADOW))
	r.append(_r(7, R_SHADOW))
	return r


## 使用帧 A：双手举到肩高（器械用力泵），用力脸。
## 手（肤色）在肩部高度两侧，袖在下方 —— 动作幅度明显且不遮脸。
func _use_arms_up_rows() -> PackedStringArray:
	var r := PackedStringArray()
	r.append(_r(13, R_HAIR_TUFT))
	r.append(_r(13, R_HAIR_TUFT))
	r.append(_r(10, R_HAIR_12))
	r.append(_r(9, R_HAIR_14))
	r.append(_r(8, R_HAIR_16))
	r.append(_r(8, R_FACE_16))
	r.append(_r(8, R_BROW_16))                           # 用力眉
	r.append(_r(8, R_EYES_16))
	r.append(_r(8, R_EYES_16))
	r.append(_r(8, R_FACE_16))
	r.append(_r(8, R_MOUTH_OPEN))                        # 张嘴
	r.append(_r(10, R_FACE_CHIN))
	# 双手上举（在肩部高度）→ 袖 → 躯干
	r.append(_r(8, "ss" + R_SHIRT_12 + "ss"))            # 双手（举到肩高）
	r.append(_r(8, "ss" + R_SHIRT_12 + "ss"))
	r.append(_r(8, "cc" + R_SHIRT_12 + "cc"))            # 袖下落
	r.append(_r(8, "cc" + R_SHIRT_12 + "cc"))
	r.append(_r(8, "cc" + R_SHIRT_12 + "cc"))
	r.append(_r(8, "cc" + R_SHIRT_12 + "cc"))
	r.append(_r(8, "cc" + R_SHIRT_12 + "cc"))
	r.append(_r(10, R_SHIRT_12))
	r.append(_r(10, R_SHADE_12))
	r.append(_r(10, R_PANTS_12))
	for _i in 6:
		r.append(_r(11, R_LEG))
	r.append(_r(10, R_SHOES))
	r.append(_r(10, R_SHOES))
	r.append(_r(7, R_SHADOW))
	r.append(_r(7, R_SHADOW))
	return r


## 整身（头→鞋，行 0..29）上移 n px；阴影行（30..31）不动 —— 脚底阴影
## 固定在地面，身体做 1px 弹跳/下蹲，避免阴影跟着角色浮动。
func _bob_up(rows: PackedStringArray, n: int) -> PackedStringArray:
	var out := PackedStringArray()
	for i in rows.size():
		if i < 30 - n:
			out.append(rows[i + n])
		elif i < 30:
			out.append(".".repeat(SIZE))
		else:
			out.append(rows[i])  # 阴影行固定
	return out


## 生成左对齐 32 字符行（content 放 left 偏移处，右侧补透明）。
func _r(left: int, content: String) -> String:
	var s := ".".repeat(left) + content
	return s.rpad(SIZE, ".")


# === 颜色 ===

## 颜色通道 → 衬衫色（全部来自 palette.gd 单一色源）。
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


func _char_color(ch: String, shirt: Color) -> Color:
	match ch:
		"h":
			return Palette.MEMBER_HAIR
		"s":
			return Palette.MEMBER_SKIN
		"e", "m", "b":
			return Palette.CHARCOAL
		"c":
			return shirt
		"d":
			return shirt.darkened(0.15)
		"p":
			return Palette.MEMBER_PANTS
		"k":
			return Palette.MEMBER_SHOE
		"y":
			return Palette.MEMBER_SHADOW
		_:
			return Color(0, 0, 0, 0)


## 水平镜像（供 facing_left）。
func _mirror(src: Image) -> Image:
	var out := Image.create(SIZE, SIZE, false, Image.FORMAT_RGBA8)
	for y in SIZE:
		for x in SIZE:
			out.set_pixel(x, y, src.get_pixel(SIZE - 1 - x, y))
	return out
