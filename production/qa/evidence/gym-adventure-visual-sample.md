# GA-005 — 一房、一教练、两器械美术样板验证

日期：2026-09-06。
覆盖目标：`production/epics/gym-adventure/story-005-visual-sample.md` (GA-005)。
设计基线：`docs/plans/2026-09-06-gym-adventure/art-direction.md`。

## 验证结论

- **自动化与契约验证**：`tests/integration/gym_adventure/visual_sample_test.gd`（**25 passed, 0 failed**）。
- **真实窗口视口渲染**：通过 Godot 4.7.1 Metal Forward+ 窗口生成真实渲染视口截图（非画板拼接）：
  - 白昼准备（Daylight）：[gym-visual-daylight.png](gym-visual-daylight.png)
  - 傍晚外出（Dusk）：[gym-visual-dusk.png](gym-visual-dusk.png)
  - 夜间营业（Night）：[gym-visual-night.png](gym-visual-night.png)
  - 打烊结算（Close）：[gym-visual-close.png](gym-visual-close.png)

## 详细验收项对照

### 1. 程教练角色身份与辨识度 (AC1 / AC2)
- **宽肩体型**：程教练肩宽 14px，明显宽于普通会员（10px），呈现退役拳击手/资深教练的硬朗体态。
- **青绿外套与银白挑染**：外套使用统一青绿（`#2e7d6b`）配合中心拉链高光（`#5ec4a8`）与侧缝暗部（`#225f52`）；黑发（`#221a18`）侧边/额前带有明显的银白挑染发丝（`#e2e8f0`），在 4 名上课会员中一眼可辨。
- **动态姿态分化（Pose）**：
  - `idle`（待机）：双脚与肩同宽稳固立地，呼吸微动（1px 肩膀轻微起伏），手臂自然下垂。
  - `walk`（行走）：2 阶段迈步循环，随 tick 步态交替迈腿与摆臂，脚底严格扣紧地面基准线。
  - `guidance`（指导）：微向前倾关注学员，扬起右臂与拳头指示节奏，头顶浮动像素边框 `[E 指导]` / `[1/2/3 选择]` / `[E 踩节奏]` 提示。
- **四方向轴测（无 2D 屏幕旋转）**：正面（DOWN）、背面（UP）、左侧（LEFT）、右侧（RIGHT）均以 2.5D 正确结构绘制，严禁直接在屏幕空间旋转精灵图（`is_screen_rotated() == false`）。

### 2. 双器械接触锚点与课中状态 (AC3)
- **跑步机（Treadmill）**：计算落脚中心位于跑带顶面中段（`rect.position.y + 16.0 - sprite_w`），双手握持控制台扶手处呈现暖白微反光，脚下在机器表面形成贴合阴影；会员处于 `USING` 时呈现高抬腿与跑带互动姿态。
- **瑜伽垫（Yoga Mat）**：计算身体落在垫面底边上方（`feet_y - sprite_w * 0.62`），呈现贴地跪姿/盘坐姿态，不穿出垫子边缘或遮挡通行过道。
- **课堂状态可见性**：4 名会员从入场（WALKING_TO）、候位（QUEUEING，直立待机）、上机训练（USING，跑带奔跑/垫面拉伸）、课间换机（交替课表）到离开，状态分明。

### 3. 昼 / 暮 / 夜 / 烊四时段光照三联画 (AC4)
- **白昼准备（PREP）**：北向窗户投射浅暖天光（`Color(1.0, 0.98, 0.92, 0.07)`），室内干净通透，无眩光噪声，便于空间布局调整。
- **傍晚外出（OUTING）**：低饱和琥珀色窗光与街景过渡（`Color(0.98, 0.74, 0.44, 0.09)`），烘托营业前期待感。
- **夜间营业（SERVICE）**：顶部暖白吊灯（`#f5d97b`）核心强化，外侧四周靛蓝暗角（`Color(0.08, 0.12, 0.22, 0.08)`），人物面部、服饰与器械高反差清晰可辨，无面部被光冲淡（wash out）现象。
- **打烊结算（CLOSE）**：柔和暗部整体覆盖（`Color(0.06, 0.08, 0.15, 0.14)`），前台区域保留一抹暖白微光，呈现打烊复盘的静谧感。
- **沙盒模式零污染**：当处于自由沙盒模式（无 phase 注入）时，`LightingLayer` 保持原版确定性烘焙光照，全量既有测试不受任何影响。

### 4. 背景与对比度控制 (AC5)
- 墙面装饰、瓷砖缝隙与固定背景的色彩饱和度与明度对比严格压低在人物与器械之下，中央主要动线与等候格位一眼清晰。

### 5. 局限与后续说明 (AC6)
- 本样板验证了一间房、程教练核心三姿态与跑步机/瑜伽垫的接触真实度。
- 全量 880 帧完整动作图集（含阿洛等专属体型全套动作）及外部 5 名玩家黑剪影盲测（ART-01）列为后续内容量产阶段任务。

## 视口截图证据索引

- 白昼准备：[gym-visual-daylight.png](gym-visual-daylight.png)
- 傍晚外出：[gym-visual-dusk.png](gym-visual-dusk.png)
- 夜间营业：[gym-visual-night.png](gym-visual-night.png)
- 打烊结算：[gym-visual-close.png](gym-visual-close.png)
