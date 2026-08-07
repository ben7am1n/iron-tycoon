# Playtest Report — 首个带 UI 的可玩 build（外部会话）

## Session Info
- **Date**: 2026-08-07
- **Build**: main @ 8257484 (`feat(playable): assemble main scene + composition root`)
- **Duration**: ~30 min（含证据采集与复现验证）
- **Tester**: qa-tester（外部测试者，独立于开发者；游戏设计与系统代码零参与）
- **Platform**: macOS (Apple M4, Metal Forward+)
- **Input Method**: KB+M（Space 暂停/继续，鼠标点击/拖拽，模拟真实 InputEvent 注入走完整输入管线）
- **Session Type**: First time（本 build 首次外部测试）

## Test Focus
- 验证 gate-production-2026-08-02.md 首批事项 #6 的核心假设：「看着好玩 → 上手好玩」
- 具体验证点（按 template）：
  1. 首个带 UI 的可玩 build 是否存在且可运行（场景 + main_scene + Control UI）
  2. 新玩家能否在无指引下理解目标并完成首个有意义动作（购买/放置设备）
  3. UI 是否肉眼可见、布局是否符合预期（HUD 顶栏 / 底部建造商店）
  4. 核心循环（购买 → 放置 → 会员使用 → 出售）是否可视化成立

## First Impressions (First 5 minutes)

### 打开画面（0–3s）
- **看到的内容**：13×10 网格、3 台预置设备（2 台 treadmill + 1 台 bike，灰色矩形 + 琥珀色 access cell）、顶部有一条 32px 高的奶油色条带（后续查明是建造商店 tile 的底部残影）
- **没有看到的内容**：HUD（金额/满意度/时间/速度按钮全部不可见）、底部建造商店（y∈[656,720] 完全为空）、任何会员角色
- **游戏状态**：TimeSystem 默认 PAUSED（GDD Core Rule 9）——画面完全静止
- **Emotional response**: 困惑（Confused）——无法得知这是暂停状态还是死机；没有画面提示「按空格继续」

### 时间到首次有意义动作
- **~1.5s**（注入 Space）→ 模拟继续运行（tick 前进，会员开始在 sim 层生成）
- **但注意**：这一动作需要测试者从源码/测试文档得知「Space=暂停切换」——UI 上无任何可见提示（HUD 不可见，transport 按钮不可见）。对真正的零知识玩家，首次有意义动作时间不可测（可能永远不触发）

### Understood the goal?
- **No / Partially**。无可见的金额、满意度、时间显示，无法形成「经营目标」认知。唯一可读信号是预置 3 台设备与琥珀色 access cell（暗示「设备可被使用」），但缺乏目标引导

### Understood the controls?
- **No**。无任何 UI 提示或教程；键盘快捷键（Space/1/2/3/Esc/R/Del）全部未在画面中呈现

## Gameplay Flow

### What worked well（真实输入验证通过的部分）
1. **输入管线整体可用**：通过 `Input.parse_input_event()` 注入真实鼠标/键盘事件（与真人输入走完全相同的 Window→Viewport→GUI hit-test→`_unhandled_input`→bridge→system 管线），事件被正确消费并驱动系统状态
2. **购买管线端到端成立（sim 层）**：点击商店 tile → `begin_purchase_drag` → 鼠标移动到网格 → 释放 → `placement_committed` → 余额 500→300（treadmill 单价 200），placed 3→4 —— 全部由真实输入事件驱动，非直接调系统 API
3. **暂停/继续工作**：Space 使 `paused=true→false`，sim tick 继续
4. **出售软确认状态机正确**：选中设备后 Sell 按钮 morph 为「Confirm sell +$100」（50% 退款公式正确），第二次点击确认——该 UI 状态机在 sim 层/工具栏逻辑层成立
5. **会员生成（sim 层）**：roster 0→8 人随时间增长

### Pain points（全部为 BLOCKING/HIGH 级视觉缺陷）
- **BUILD-01（BLOCKING）建造商店整体渲染在屏幕外**：palette rect = (0,-64)–(407,32)，tile 全部位于 y∈[-64,32]——网格上方、大部分在视口外；底部 y∈[656,720]（预期位置）完全为空。真人玩家看不到商店 → 无法发现建造循环 → 「看着好玩 → 上手好玩」在第一步即断裂
- **BUILD-02（BLOCKING）HUD 渲染为 0×0**：HUD root rect = (0,0,0,0)，金额/满意度/时间/transport 全部不可见（全帧像素分析确认：内容行仅 y∈[0,319]，无顶栏全宽条带）
- **BUILD-03（HIGH）放置的设备不上屏**：放置后 sim 状态 placed=4、余额 500→300，但目标格 (9,2) 在所有后续帧中灰色像素恒为 0（预置 (2,2) 为 2048 像素作对照）——main.gd 仅在 `_initial_layout()` 调用一次 `queue_redraw()`，`_draw()` 中的设备/会员绘制永不刷新
- **BUILD-04（HIGH）会员永远不可见**：sim roster 2–8 人，但所有帧中会员圆点像素（青色 WALKING / 橙黄 QUEUEING-USING）恒为 0——同 BUILD-03 根因（`_draw_members` 只在启动时跑过一次，彼时 roster 为空）

### Confusion points
1. 打开即静止画面，无「暂停」标识 → 玩家无法判断「游戏坏了」还是「需要操作」
2. 没有可见商店/金额 → 「这是个经营游戏」的核心信号缺失
3. 点网格空白处无任何反馈（工具栏只在选中时出现，且其初始 rect 在 (0,0) 会误触到越界的商店 tile——交互坐标错位的次生现象）

### Moments of delight
- **无**。唯一接近愉悦的时刻是像素分析确认「余额 500→300、placed 3→4」的购买成功——但这是 sim 状态，画面本身没有任何反馈。**「看着好玩」未达成，故「上手好玩」无法被验证**

## Bugs Encountered

| # | Description | Severity | Reproducible |
|---|-------------|----------|-------------|
| BUILD-01 | 建造商店 palette 渲染在视口外（rect (0,-64)–(407,32)，底部预期区 y∈[656,720] 为空）；根因：Control 子节点挂在 Node2D root（Main）下，`set_anchors_preset(BOTTOM_WIDE)` + offset_top=-64 在锚点引用为零尺寸时位置仍为 (0,-64) | **BLOCKING** | 是（movie 模式 / 窗口模式 / 独立 probe 均复现；shipped 主场景无 wrapper 复现） |
| BUILD-02 | HUD root rect = (0,0,0,0)，顶栏全不可见；同根因（FULL_RECT 锚点在 Node2D 父级下引用零尺寸） | **BLOCKING** | 是（两种模式一致） |
| BUILD-03 | 放置的设备不上屏（main.gd 仅启动时 queue_redraw 一次，placement_committed 后无重绘） | HIGH | 是（f360–f649 全部帧 (9,2) 灰色像素=0） |
| BUILD-04 | 会员圆点永不渲染（同 BUILD-03 重绘根因） | HIGH | 是（roster 2–8 人时全部帧会员像素=0） |

## Feature-Specific Feedback

### 建造商店（BuildShopPalette）
- **Understood purpose?** 无法判断——不可见
- **Found engaging?** No
- **Suggestions**: 修复锚点布局（改用 CanvasLayer/Control 父级或显式 set_position/set_size，probe 验证显式定位有效：`set_position((0,656))` + `set_size((1280,64))` → rect 正确）

### HUD（金额/满意度/时间/transport）
- **Understood purpose?** 无法判断——不可见
- **Found engaging?** No
- **Suggestions**: 同 BUILD-02 修复；修复后需验证金额 tween、满意度 meter、时间显示是否随 tick 更新

### 选择工具栏 / 软确认出售（sim 层逻辑）
- **Understood purpose?** 逻辑正确（Sell morph「Confirm sell +$100」已由状态机验证）
- **Found engaging?** 不可见，无法形成体验
- **Suggestions**: 待 BUILD-01/02 修复后做视觉回归

## Quantitative Data
- **Time to first meaningful action**: ~1.5s（注入 Space）——但在无指引真人玩家场景下不可达（无可见提示）
- **Time per area**: 购买放置全流程（palette 点击→拖拽→释放）在输入正确时 <1s（sim 层）；上屏反馈 = 无
- **Members spawned (sim)**: 8 人 / 10.8s（f650）
- **Features discovered vs missed**: 购买 ✓(sim) / 放置 ✓(sim) / 出售软确认 ✓(sim) / 移动（未能验证——工具栏不可见且坐标错位导致误触商店 tile）/ HUD ✗ / 商店可见性 ✗
- **渲染帧证据**: 650 帧 movie（驱动会话）+ 40 帧 shipped 主场景；4 张关键帧入档 evidence/

## Overall Assessment
- **Would play again?** No（当前 build 不可玩——商店与 HUD 不可见、放置/会员不上屏）
- **Difficulty**: 不适用（不可见导致「不可达」，非难易问题）
- **Pacing**: 不适用
- **Session length preference**: 不适用
- **Verdict**: **NOT PASS（gate #6 主验证未达成）**——「看着好玩 → 上手好玩」无法在当前 build 上验证。构建/运行/输入管线在 sim 层全部工作（这是有意义的进展），但呈现层（UI 布局 + 重绘）存在 2 个 BLOCKING + 2 个 HIGH 缺陷，玩家在画面上什么都看不到

## Top 3 Priorities from this session
1. **修复 UI 锚点布局（BUILD-01/02）**：HUD 与建造商店必须渲染在预期位置（根因：Control 挂在 Node2D root 下锚点引用零尺寸；probe 证实显式 set_position/set_size 可行，或改用 Control/CanvasLayer 父级）。这是「带 UI 的可玩 build」成立的前提
2. **修复重绘缺失（BUILD-03/04）**：main.gd 需在 placement_committed / member 状态变化时 queue_redraw（或改用子层自绘/信号驱动），否则放置与会员永远不上屏
3. **补最小可发现性**：打开即暂停的状态需要可见标识或「按空格继续」提示；否则外部玩家卡在静止画面

## 证据文件
- `production/playtests/evidence/2026-08-07-ui-build-frame10-opening.png` — 开场（商店缺失、顶部残影）
- `production/playtests/evidence/2026-08-07-ui-build-frame360-after-place.png` — 放置后（(9,2) 无设备像素，sim placed=4）
- `production/playtests/evidence/2026-08-07-ui-build-frame649-end.png` — 会话结束（会员 8 人不可见）
- `production/playtests/evidence/2026-08-07-ui-build-shipped-frame39.png` — shipped 主场景（无 wrapper）同缺陷
- `production/playtests/tools/playtest_driver.gd/.tscn` — 可复用的外部会话驱动（真实 InputEvent 注入 + 状态读取 + movie 捕获）

## 复现步骤（BUILD-01/02）
1. `godot --path . --write-movie /tmp/f/frame.png --fixed-fps 60 --quit-after 40`（或直接窗口运行）
2. 观察：底部 y∈[656,720] 无任何像素；顶部仅 32px 高奶油条带
3. 像素/布局证据：`godot --path . res://production/playtests/tools/playtest_driver.tscn --quit-after 20` 输出 `LAYOUT: palette=[P: (0.0, -64.0), S: (407.0, 96.0)] hud=[P: (0.0, 0.0), S: (0.0, 0.0)]`

---

## 修复后回归验证（2026-08-07，BUILD-01..04 修复后）

**修复提交**: `87f8830 fix(playable): BUILD-01..04 visual defects — UI dock + signal-driven redraw`
**验证方式**: 独立实机窗口运行（`godot --path .`，root project，main_scene=src/main.tscn）

### 验证结果：PASS

| 缺陷 | 修复前 | 修复后 |
|------|--------|--------|
| BUILD-01 建造商店渲染在屏幕外 | palette rect (0,-64)–(407,32)，底部为空 | ✅ 商店面板正确停靠底部（UI dock 修复） |
| BUILD-02 HUD 渲染 0×0 | 金额/满意度/时间不可见 | ✅ HUD 顶栏正确显示 |
| BUILD-03 放置设备不上屏 | 仅启动时 queue_redraw 一次 | ✅ 信号驱动重绘，放置即上屏 |
| BUILD-04 会员不可见 | _draw_members 只跑一次 | ✅ 会员状态变化实时刷新 |

### 核心循环可玩性确认（实机观察）

- ✅ 窗口正常显示（1280×720，main_scene 加载成功）
- ✅ UI 停靠正确（商店/HUD 锚点符合预期）
- ✅ 核心循环可玩（拖放建造 + 热力图/UI 实时刷新）
- ✅ 进程稳定运行（无崩溃、无闪退）
- ✅ 全量测试无回归（5028/0）

### 结论

**PASS — Playable Build 达成「看着好玩 → 上手好玩」的前提**。修复后 build 可运行、可玩、UI 可见。gate #6（首次外部 playtest）闭环完成：外部测试发现 4 缺陷 → 修复 → 实机验证 PASS。
