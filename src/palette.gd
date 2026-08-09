# src/palette.gd — art-bible §4 Color Palette（全项目单一色彩数据源）
#
# 后续所有视觉阶段（Phase B 设备 / Phase C 会员 / UI 迁移）一律引用本文件，
# 不得各写各的色值。访问方式：
#   const Palette := preload("res://src/palette.gd")
#   draw_rect(rect, Palette.SAGE)
#
# 无 class_name：headless 下 class_name 不保证全局注册（项目约定，
# 见 src/main.gd 头部注释），跨脚本一律 preload const alias。
#
# 色值来源：design/art/art-bible.md §4（Warm Cream 暖底 + 柔和功能点缀色），
# 风格禁区：无高饱和撞色、无刺眼红、无快速闪烁。

# === art-bible §4 Primary Palette（7 色全量） ===

## Warm Cream #F4E9D8 — 地板/背景底色，营造温暖留白。
const CREAM_BG := Color("F4E9D8")
## Soft Charcoal #3C3A42 — 描边/文字/像素轮廓（非纯黑，降低对比压力）。
const CHARCOAL := Color("3C3A42")
## Sage #8FBF9F — 力量区 / 正向满意度 / “好”的语义。
const SAGE := Color("8FBF9F")
## Sky #8EC5E8 — 有氧区 / 平静 / 信息类语义。
const SKY := Color("8EC5E8")
## Peach #F2B486 — 团课/社交区 / 温暖强调。
const PEACH := Color("F2B486")
## Butter #F5D97B — 金钱/奖励/里程碑高光。
const BUTTER := Color("F5D97B")
## Dusty Rose #E0A0A0 — 拥挤/需注意（柔和版“警示”，绝不刺眼）。
const ROSE := Color("E0A0A0")

# === 工具色（art-bible 派生，供绘制层使用） ===

## 网格线：Soft Charcoal（非纯黑，1px，替代旧灰 Color(0.25,0.25,0.3)）。
const GRID_LINE := CHARCOAL
## 区域色块描边：Soft Charcoal，1px（art-bible §6 “地板色块 + 柔和描边”）。
const ZONE_BORDER := CHARCOAL

# === 地板区域划分（art-bible §6：功能区用色块 + 柔和描边区分，分区一眼可读） ===
#
# 单元：网格 cell 坐标（13×10，CELL_SIZE=32，见 src/main.gd）。
# 划分：左力量 / 中有氧 / 右团课 —— 按任务建议 + ENTRANCE(0,0) 左上、
# EXIT(12,9) 右下的动线排布。色块内缩 1 cell 形成奶油色环场走道
# （art-bible 留白优先；走道连通入口→出口），区域边界与网格线对齐。
# 单一来源，main.gd _draw_floor_zones() 与后续阶段均读取这里，不得在绘制处硬编码。
const ZONE_RECTS := {
	"strength": Rect2i(1, 1, 4, 8),
	"cardio": Rect2i(5, 1, 4, 8),
	"flex": Rect2i(9, 1, 3, 8),
}
## 区域语义色（与 equipment_catalog.json 的 zone_membership 标签一致：
## strength→Sage、cardio→Sky、flex→Peach）。
const ZONE_COLORS := {
	"strength": SAGE,
	"cardio": SKY,
	"flex": PEACH,
}

# === 会员角色工具色（Phase C v2 派生：2.5D 像素小人，art-bible-25d §2） ===
#
# 供 src/presentation/member_sprite.gd 使用。全部从 art-bible §4 主色域
# 派生（暖调、低饱和），状态双通道的“颜色通道”直接引用 SKY / PEACH /
# MEMBER_LEAVE_GRAY —— 绘制处不得另写色值。

## 肤色：暖调浅肤色（Warm Cream 亮化暖化，不抢状态色）。
const MEMBER_SKIN := Color("EACBA6")
## 发色：暖深棕（Charcoal 暖化，非纯黑 —— art-bible §3 禁纯黑描边）。
const MEMBER_HAIR := Color("5E4638")
## 裤色：暖灰褐（Charcoal 暖化中调，腿/裤块面）。
const MEMBER_PANTS := Color("6E5F53")
## 鞋色：暖深灰（Charcoal 暖化，鞋底块面）。
const MEMBER_SHOE := Color("4A413B")
## 离场灰：低饱和暖灰（LEAVING 状态通道 —— 脱出饱和区，与
## walking≈Sky / queue≈Peach 三态区分；非 art-bible 主色，状态专用）。
const MEMBER_LEAVE_GRAY := Color("9A948C")
## 脚底阴影：Soft Charcoal 低透明（art-bible-25d §2 “大块阴影”）。
const MEMBER_SHADOW := Color(0.235, 0.227, 0.259, 0.28)

## Phase 4（V3 §8）：会员外观变体色（每人：清晰发型/皮肤色块/裤子/鞋）。
## 变体 0 = 上述默认色（既有测试的像素断言保持有效）；变体 1-3 从同色域
## 派生（暖调、低饱和，art-bible §4 —— 不引入刺眼高饱和撞色）。由
## member_sprite.gd 的 MEMBER_VARIANTS 表引用，绘制处不得另写色值。
## 发型变体：更深棕 / 红棕。
const MEMBER_HAIR_ALT1 := Color("4A3A2E")
const MEMBER_HAIR_ALT2 := Color("6B4E3B")
const MEMBER_HAIR_ALT3 := Color("3B3129")
## 皮肤变体：偏 tan / 偏深 tan / 偏暖浅。
const MEMBER_SKIN_ALT1 := Color("E0B98F")
const MEMBER_SKIN_ALT2 := Color("C9A284")
const MEMBER_SKIN_ALT3 := Color("F0D3B0")
## 裤子变体：蓝灰（冷阴影系）/ 卡其 / 深暖灰。
const MEMBER_PANTS_ALT1 := Color("5E6B70")
const MEMBER_PANTS_ALT2 := Color("7A6A55")
const MEMBER_PANTS_ALT3 := Color("56504A")
## 鞋变体：近炭 / 深棕 / 深蓝灰。
const MEMBER_SHOE_ALT1 := Color("3F3733")
const MEMBER_SHOE_ALT2 := Color("44342C")
const MEMBER_SHOE_ALT3 := Color("414B56")

# === Phase B v2 设备像素美术（art-bible-25d-style §2 材质概括 + art-bible §7 拖放反馈） ===
# 设备 = 2.5D 场景的「前景像素主体」：粗颗粒 2D 像素 sprite（32×32 整数倍，Nearest）。
# 色值仍以本文件为单一来源；设备精灵程序化绘制（src/presentation/equipment_art.gd）只引用这里。

## 金属暗面（器械金属框架/滚轮/杠铃片主体色）：冷灰，非纯黑（25d §3 禁纯黑粗边）。
const METAL_DARK := Color("5B6470")
## 金属冷色高光（25d §2 材质概括：金属 = 少量冷色高光）：Sky 系提亮，非纯白大面积。
const METAL_HIGHLIGHT := Color("B7D4EC")
## 设备脚下 contact shadow（V3 §6 设备下方明显但柔和的 contact shadow）：
## 冷蓝灰半透明（V3 §7 阴影：深蓝灰、青灰；Phase 5 定值 0.05,0.09,0.14）。
## WorldCanvas 绘制为双层（宽软外层 + 贴身内层），alpha 在绘制处细分。
const EQUIP_SHADOW := Color(0.05, 0.09, 0.14, 0.38)
## 放置预览合法：柔和高亮（art-bible §7）—— 半透明白/Sage tint，绝不刺眼。
const PLACEMENT_OK_TINT := Color(0.96, 0.98, 0.94, 0.30)
## 放置预览非法：Dusty Rose #E0A0A0 柔和警示（art-bible §7，绝不刺眼红）——复用 ROSE 但显式声明 alpha。
const PLACEMENT_BAD_TINT := Color("E0A0A0", 0.35)
## 吸附「咔哒」视觉反馈（art-bible §7 动效手感）：Butter 脉冲环。
const SNAP_PULSE_COLOR := BUTTER

# === V3 §7 / V3.1 R5 色彩体系（暖环境 + 冷阴影 + 高饱和重点色） ===
# 背景基底：暖灰/奶油灰/低饱和棕；阴影：深蓝灰/青灰；器械：炭灰/深蓝灰/浅灰
# 金属；木材：暖橙棕；植物：中等饱和绿；Accent：黄/橙/青蓝（小范围）。R5 只把
# 墙体、通道、有氧区与少量力量区 cluster 推向暖相；力量区橡胶主体、金属、
# 器械暗面与 LIGHT_*_SHADOW 保持冷灰，作为冷暖对比锚点。
# 色值单一来源（项目约定）：绘制层一律引用本文件，禁止硬编码。

## 顶墙基底：暖灰奶油灰（V3 §3 墙壁）。
const WALL_BASE := Color("9D8B7C")
## 顶墙踢脚/明暗块：低饱和棕（比墙基底深一档）。
const WALL_DARK := Color("736557")
## 墙裙线：暖灰更亮一档（装饰压条）。
const WALL_TRIM := Color("B09A82")
## 窗玻璃：冷青灰蓝（V3 §7 阴影系青灰；窗户斜向自然光的载体）。
const WINDOW_GLASS := Color("9FB4C8")
## 窗框：炭灰暖调（非纯黑，25d §3）。
const WINDOW_FRAME := Color("57534A")

## 地板材质 —— 力量区深灰橡胶地垫（V3 §1/§7 炭灰深蓝灰系）。
const FLOOR_STRENGTH_BASE := Color("4B4F57")
const FLOOR_STRENGTH_BLOCK := Color("454952")   # 略有色差的橡胶块
const FLOOR_STRENGTH_SEAM := Color("3C4047")    # 接缝
const FLOOR_STRENGTH_WEAR := Color("5A5F68")    # 磨损/高光
const FLOOR_STRENGTH_STAIN := Color("383C44")   # 汗渍
## V3.1 P3：力量区手绘 cluster 色（深灰/灰蓝/暖灰 —— 非纯色大块填充）。
const FLOOR_STRENGTH_CL_GRAYBLUE := Color("4E5663")   # 灰蓝 cluster
const FLOOR_STRENGTH_CL_WARMGRAY := Color("5A5049")   # 暖灰 cluster
## 地板材质 —— 有氧区偏暖灰/蓝灰地面。
const FLOOR_CARDIO_BASE := Color("8B7764")
const FLOOR_CARDIO_DOT := Color("796552")       # 细小重复纹理
const FLOOR_CARDIO_EDGE := Color("666C72")      # 边缘压条
## V3.1 P3：有氧区手绘 cluster 色（暖灰/蓝灰 —— 无 4px 规则点阵）。
const FLOOR_CARDIO_CL_GRAYBLUE := Color("747D87")
const FLOOR_CARDIO_CL_WARMGRAY := Color("95806D")
## 地板材质 —— 瑜伽区暖色木地板（V3 §7 木材暖橙棕）。
const FLOOR_FLEX_BASE := Color("A9744C")
const FLOOR_FLEX_PLANK := Color("96653F")       # 木板分隔
const FLOOR_FLEX_GRAIN := Color("8F5F3B")       # 像素化木纹
## V3.1 P3：瑜伽区手绘 cluster 色（亮/暗木板 —— 木纹不规则）。
const FLOOR_FLEX_CL_LIGHT := Color("B58055")
const FLOOR_FLEX_CL_DARK := Color("96633C")
## 地板材质 —— 公共通道浅灰/暖灰瓷砖（比训练区亮，有砖缝）。
const FLOOR_WALK_BASE := Color("DFCFB6")
const FLOOR_WALK_GROUT := Color("C9B18F")
## V3.1 P3：通道手绘 cluster 色（亮/暗瓷砖 —— 砖缝不规则）。
const FLOOR_WALK_CL_LIGHT := Color("E6D9C1")
const FLOOR_WALK_CL_DARK := Color("CCB99B")

## 植物叶色：中等饱和绿（V3 §7；比旧 Sage 更深更实，脱离 pastel）。
const PLANT_GREEN := Color("4E8A5A")
const PLANT_GREEN_DARK := Color("3E7048")
## 植物亮叶（普通植物）：低饱和亮绿（V3 §7 植物色 —— 环境低饱和）。
## V3.1 P5 的「绿色植物」焦点由 plant_bright 变体（FOCAL_GREEN_LIGHT
## 亮叶）承担，避免 9 盆植物全部成为高饱和簇（P5 精选 10-15 焦点）。
const PLANT_GREEN_LIGHT := Color("6BA575")
## 陶盆：低饱和暖棕。
const PLANT_POT := Color("9C5A3C")

## Accent 高饱和色（V3 §7 —— 只用于设备屏幕/小型装饰/UI 提示）。
## 注意：环境装饰（水瓶/招牌/饮水机/瑜伽砖/消防栓）用这些色时保持
## 低-中饱和（V3.1 P5「保持 70% 环境低饱和」）—— 高饱和焦点由
## FOCAL_* 色族 + 设备屏幕 + 植物亮叶承担（P5 精选 10-15 个焦点，
## 不把整个环境提饱和）。
const ACCENT_YELLOW := Color("F2C94C")
const ACCENT_ORANGE := Color("E07A3F")
const ACCENT_CYAN := Color("45C4D8")
## 设备屏幕 emissive（V3 §6：青蓝/绿局部 emissive pixels）。
const EMISSIVE_CYAN := Color("4FD8E8")
const EMISSIVE_GREEN := Color("58E08A")
## 高光：暖黄/奶白（V3 §6 高光暖黄色/奶白色；金属高光仍用 METAL_HIGHLIGHT）。
const HIGHLIGHT_WARM := Color("F5E6C8")

# === V3.1 P5 高饱和焦点色（附录 V3.1 P5：10-15 个高饱和视觉焦点） ===
## 新增焦点色：红广告牌 / 亮绿植物叶 / 彩色瑜伽用品（粉/紫/青）。HSV
## 饱和度均 ≥ 0.73 —— 在 70% 低饱和环境中构成局部高饱和焦点。只用于
## 小型装饰/广告牌/瑜伽用品（V3 §7 高饱和仅小型装饰，禁止大面积）。
## 红色广告牌（P5 例子「红色广告牌」）：暖调高饱和红，非刺眼荧光红。
const FOCAL_RED := Color("D8382E")
## 黄色水杯（P5 例子「黄色水杯」）：高饱和暖黄（s≈0.76，比环境
## ACCENT_YELLOW 更饱和 —— 焦点与环境分离）。
const FOCAL_YELLOW := Color("FFCB3D")
## 植物亮叶高饱和绿（P5 例子「绿色植物」）：植物主体保持中等饱和绿
## （V3 §7），亮叶像素用本色形成绿色焦点簇。
const FOCAL_GREEN_LIGHT := Color("3AD860")
## 彩色瑜伽用品（P5 例子「彩色瑜伽用品」）：粉/紫/青三色。
const FOCAL_PINK := Color("F23E9E")
const FOCAL_PURPLE := Color("8E3FF0")
const FOCAL_TEAL := Color("2FC9B8")
## 会员运动短裤高饱和色（P5 例子「橙色健身服」）：变体 1-3 短裤色。
const FOCAL_GYM_ORANGE := Color("FF8A2A")
const FOCAL_GYM_BLUE := Color("2F9BE8")
const FOCAL_GYM_YELLOW := Color("FFCB3D")

## 顶部暖白主光（V3 §6 统一室内主光）：暖白，低 alpha 叠加在世界上层。
const LIGHT_TOP_WARM := Color("FFD99A")
## 灯池中层：暖蜜色受光材质，与热核/外缘构成离散三档衰减。
const LIGHT_POOL_MID := Color("E9AD63")
## 灯池外缘：低明度暖砂，只用稀疏阶梯像素收边。
const LIGHT_POOL_EDGE := Color("B97A4C")
## 窗口斜向自然光（V3 §6）：暖白偏暖，比顶部主光略强。
const LIGHT_WINDOW := Color(1.0, 0.92, 0.75, 0.10)
## 墙边暗角（V3 §6 墙边比中心区域稍暗）：冷蓝灰，低 alpha。
const LIGHT_EDGE_SHADOW := Color("121B32")
## 中心暗角加强（空间纵深：中心比墙边略亮 → 墙边深、中心亮）。
const LIGHT_CORNER_SHADOW := Color(0.10, 0.14, 0.22, 0.10)

# === Phase 2 结构层色域（V3 §3/§4 —— 立柱/前台/储物柜/镜子/空调/墙钟/
# 通风口/吊灯/管道/踢脚线/电线槽/毛巾架/门/门垫） ===
# 供 src/presentation/structure_art.gd 使用。BACKGROUND 层绘制时统一
# 降对比降饱和（V3 §4），色值仍是本文件单一来源。

## 门：深木色（入口/出口门板）。
const DOOR_COLOR := Color("7E6F5A")
## 门框：深暖灰。
const DOOR_FRAME := Color("5C5447")
## 门口地垫：深暖灰。
const DOOR_MAT := Color("6B655A")
## 前台台面：暖木色（GAMEPLAY 层，V3 §4 原色）。
const DESK_WOOD := Color("A87E4F")
## 前台台面亮部。
const DESK_TOP := Color("C09A66")
## 储物柜：蓝灰柜体（BACKGROUND 层，降饱和后仍冷调）。
const LOCKER_COLOR := Color("7C8A94")
## 储物柜暗部/柜门缝。
const LOCKER_DARK := Color("64707A")
## 储物柜把手：暖金（小面积 accent，V3 §7）。
const LOCKER_HANDLE := Color("C9A24B")
## 镜子：冷蓝灰镜面（BACKGROUND，V3 §6 冷调）。
const MIRROR_COLOR := Color("AFC4D2")
## 镜子高光：斜向亮线。
const MIRROR_HI := Color("D6E4EC")
## 空调机身：暖白（BACKGROUND）。
const AC_BODY := Color("E4E0D6")
## 空调出风口：中灰（V3 §9 出风细节）。
const AC_VENT := Color("B4AFA2")
## 墙钟表盘：暖米白。
const CLOCK_FACE := Color("E8E2D4")
## 墙钟指针/刻度：深暖灰。
const CLOCK_HAND := Color("4A443C")
## 管道：中暖灰（BACKGROUND）。
const PIPE_COLOR := Color("9B806B")
## 管道法兰/接头：深一档。
const PIPE_DARK := Color("777267")
## 电线槽：浅暖灰细条（V3 §3）。
const CABLE_DUCT := Color("B0AA9C")
## 立柱：暖灰（FOREGROUND，允许遮挡）。
const COLUMN_COLOR := Color("B09A7F")
## 立柱暗部。
const COLUMN_DARK := Color("877F70")
## 吊灯灯罩：深暖灰（FOREGROUND，悬于上方）。
const LAMP_SHADE := Color("4A443C")
## 吊灯灯罩受光体（V3.1 R4 光源可辨识）：灯罩本体暖橙金 —— 吊灯是「发光体」，
## 不再是暗色剪影。暖橙（r>b）—— 光影响材质颜色（V3.1 P4 非透明白圆）。
## 饱和度 < 0.72（P5 高饱和焦点阈值 —— 灯具是环境光源，不抢焦点簇计数）。
const LAMP_SHADE_LIT := Color("E8A84D")
## 吊灯灯泡核心（V3.1 R4）：近白暖亮点 —— 灯罩底部小范围亮色（1-2px 核心）。
const LAMP_BULB := Color("FFF3C4")
## 吊灯暖光晕：半透明暖黄（V3 §6 顶部暖白灯）。
const LAMP_GLOW := Color(1.0, 0.92, 0.68, 0.30)
## 冷光渗透（V3.1 R4 窗边/门口冷光）：窗光冷蓝灰 —— 与室内暖光形成冷暖对比
## （V3 §15 warm indoor lighting / cool colored shadows）。
const LIGHT_WINDOW_COOL := Color(0.72, 0.82, 0.98, 0.12)
## 消防栓：低饱和红（小面积 accent，V3 §7 高饱和仅小范围）。
const HYDRANT := Color("B0483C")
## 饮水机：暖白机身。
const FOUNTAIN := Color("D8D4C8")
## 垃圾桶：深暖灰。
const TRASH := Color("5E5A52")
## 毛巾：暖橙（小面积 accent）。
const TOWEL := Color("C98E6E")

# === Phase 3 设备场景物件材质（V3 §5/§6/§7/§11：机器灰阶 + 方向光 + 冷阴影） ===
# V3 §7 器械色系：炭灰、深蓝灰、浅灰金属。设备本体用机器灰阶（非区域语义色 —
# 区域色只做小范围 accent，§14 可购买设备饱和度高、轮廓更清楚）。
# 方向光（§6）：顶部暖白主光 → 高光暖黄/奶白；阴影偏冷偏蓝灰。
# 轮廓（§11）：机器部分深蓝灰轮廓，高光侧可无完整描边。

## 机器轮廓：深蓝灰（§11 机器部分深蓝灰轮廓；非纯黑，§3 禁纯黑粗边）。
const EQUIP_OUTLINE := Color("3B4552")
## 机身材质暗面：炭灰（机器主体/背面/受光少的区域）。
const EQUIP_BODY_DARK := Color("49525F")
## 机身材质中调：深蓝灰（机器主体正面，方向光主受光面）。
const EQUIP_BODY := Color("5D6673")
## 浅灰金属：扶手/机架/轮毂（§5 浅灰金属扶手；§11 高光侧可无完整描边）。
const EQUIP_BODY_LIGHT := Color("8E99A6")
## 暖黄/奶白高光（§6 高光：暖黄色/奶白色 —— 顶部暖白主光的关键高光像素）。
const EQUIP_HIGHLIGHT := Color("EADFB8")
## 冷蓝灰阴影面（§6 阴影：偏冷、偏蓝灰 —— 设备自身受光面的暗侧）。
const EQUIP_SHADOW_TONE := Color("3A4350")
## 青蓝显示灯（§6 部分机器显示屏：青蓝/绿色局部 emissive pixels）。
## V3.1 P5：提高饱和 —— 设备屏幕是全场景高饱和焦点之一（P5 例子「蓝色
## 设备屏幕」），在低饱和环境中跳出来。
const EQUIP_ACCENT_CYAN := Color("2FC4E8")
## Hover 黄色像素轮廓（§14 可读性 + §10 购买栏 Hover）：复用 Butter（暖黄 accent）。
const EQUIP_HOVER_OUTLINE := BUTTER
