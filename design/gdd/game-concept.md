# Game Concept: 撸铁大亨 (Iron Tycoon)

*Created: 2026-07-15*
*Status: Draft*

---

## Elevator Pitch

> 这是一款治愈系的桌面经营游戏——你在一个网格上拖放器械，规划一间破旧健身房的空间布局，让像素小人顺畅地锻炼，把它从街角破馆改造成人人想来的旗舰场馆（并最终开成连锁帝国）。
>
> *It's a cozy management game where you drag-and-drop equipment on a grid to lay out a rundown gym, keeping pixel members flowing smoothly, transforming it from a shabby corner shop into a flagship everyone wants to visit — and eventually a franchise empire.*

---

## Core Identity

| Aspect | Detail |
| ---- | ---- |
| **Genre** | 治愈经营模拟 + 空间优化（Cozy management sim + spatial optimization / light puzzle） |
| **Platform** | PC 桌面（含 macOS，主攻；顺便 Windows）。Steam / 直接发布 |
| **Target Audience** | 见下方 Player Profile —— 探索者/创造者型休闲玩家 |
| **Player Count** | 单人 |
| **Session Length** | 30–120 分钟，可短可长，随时可停 |
| **Monetization** | 买断制（Premium）。明确无内购/抽卡 |
| **Estimated Scope** | Large（完整愿景约 18–30 个月，单人/小团队；MVP 约 4–8 周） |
| **Comparable Titles** | 开罗系列（如《健身房物语》）、Two Point Hospital、Tiny Tower、轻量自动化/工厂类 |

---

## Core Fantasy

从一家漏水的破旧小健身房起步，凭借你的空间设计巧思，把它一步步养成一个连锁健身帝国。

玩家得到的不是紧张的商战，而是**"化腐朽为神奇"的掌控感与治愈感**：看着自己精心布置的空间让像素小人们行云流水地锻炼，满意度和收入稳步上涨，破馆逐渐蜕变成漂亮、高效、值得截图的旗舰店。这是一种"当家作主、从无到有"的白手起家幻想，但节奏松弛、没有失败的焦虑。

---

## Unique Hook

像开罗的经营养成，**而且**——布局本身就是核心玩法：器械摆在哪是一个真正的空间优化谜题（拥挤度、会员动线、区域协同都由摆放决定），但这一切以完全治愈、无惩罚的方式呈现。

"温柔版的空间优化"——把类工厂/自动化游戏的"排布最优解"乐趣，装进一个零压力、可挂机的治愈外壳里。

---

## Player Experience Analysis (MDA Framework)

### Target Aesthetics (What the player FEELS)

| Aesthetic | Priority | How We Deliver It |
| ---- | ---- | ---- |
| **Sensation** (sensory pleasure) | 3 | 拖放吸附的手感、像素动画、场馆蜕变的视觉满足 |
| **Fantasy** (make-believe, role-playing) | 4 | 白手起家的健身房大亨身份，破馆→帝国的想象 |
| **Narrative** (drama, story arc) | N/A（MVP）| 后续可选深化：会员微型故事线 |
| **Challenge** (obstacle course, mastery) | 2 | 空间优化的深度——从手忙脚乱到行云流水 |
| **Fellowship** (social connection) | N/A | 单人游戏，不做社交 |
| **Discovery** (exploration, secrets) | 3 | 探索器械/区域组合的最优解与协同 |
| **Expression** (self-expression, creativity) | 1 | 每家店的布局都是玩家自己的解法与作品 |
| **Submission** (relaxation, comfort zone) | 1 | 低压力、可挂机、无失败的松弛循环 |

**主导情感**：Expression（表达）+ Submission（松弛/心流）。Challenge 作为让表达"有嚼头"的支撑。

### Key Dynamics (Emergent player behaviors)

- 玩家会不断"再挪一下试试"，微调器械位置以消除排队和拥挤。
- 玩家会自然地形成个人化的布局风格与偏好解法。
- 玩家会攒钱期待下一次"大升级"（扩建/新区域），并规划如何重排空间。

### Core Mechanics (Systems we build)

1. **网格 + 拖放布置**：在房间网格上拖放、旋转、吸附器械，即时预览区域效果。
2. **会员模拟与寻路**：像素小人进场、寻路走向器械、排队/使用/离开；动线与拥挤度实时计算。
3. **满意度 → 经济循环**：布局质量 → 会员满意度 → 收入 → 购买更多器械/升级 → 再优化。

---

## Player Motivation Profile

### Primary Psychological Needs Served

| Need | How This Game Satisfies It | Strength |
| ---- | ---- | ---- |
| **Autonomy** | 布局自由度极高，每家店都是玩家自己的解法，没有唯一正解 | Core |
| **Competence** | 从"拥挤混乱的破馆"到"顺滑高效的旗舰店"，能力成长肉眼可见 | Core |
| **Relatedness** | 像素小人在你设计的空间里满足地锻炼——轻度情感联结（后续可深化） | Supporting |

### Player Type Appeal (Bartle Taxonomy)

- [x] **Achievers** — 里程碑、金牌场馆、解锁新器械与新店面
- [x] **Explorers** — 探索器械组合、区域协同、寻找布局最优解（**主要受众**）
- [ ] **Socializers** — 不服务（单人）
- [ ] **Killers/Competitors** — 明确不服务（无竞技、无紧张对抗）

*补充*：Quantic Foundry 模型中 **Design / Discovery** 动机高分人群是核心受众。

### Flow State Design

- **Onboarding curve**：前 10 分钟通过一间小房间、两三种器械教会"拖放 → 看反馈 → 微调"。
- **Difficulty scaling**：随会员数增长、房间扩大、器械种类增多，优化复杂度自然上升。
- **Feedback clarity**：拥挤度、动线、区域效果全部即时可视化（符合支柱3）。
- **Recovery from failure**：**没有失败**。永远可以重排布局；坏决策只是"错过一个机会"，不是惩罚（符合支柱2）。

---

## Core Loop

### Moment-to-Moment (30 seconds)
拖动一台器械 → 即时反馈（吸附到位的手感 + 区域效果预览，如"力量区+3拥挤""靠窗+舒适度"）→ 小人流动路线随之改变 → 微调位置。核心心理钩子：**"再挪一下试试"**。

### Short-Term (5-15 minutes)
接待一波新会员 → 发现瓶颈（跑步机排长队 / 深蹲架旁太挤）→ 买新器械或重排布局解决它 → 满意度上升 → 收入上升 → 解锁下一件器械。**"再优化一处"**。

### Session-Level (30-120 minutes)
把当前场馆从"勉强运转"调到"顺滑高效" → 攒够钱做一次大升级（扩建一间房 / 加一个新区域如团课室、蛋白吧）→ 达到一个满意度里程碑。天然停手点：一次成功的扩建/升级之后。

### Long-Term Progression
单店做到"金牌场馆" → 解锁地图上的新店面（不同城区、不同人群、不同空间形状与挑战）→ 半挂机：老店持续产出，玩家专注设计新店 → 长期目标：从一间破馆到一座连锁帝国。*（连锁/挂机为 Tier 2 愿景，MVP 不含。）*

### Retention Hooks
- **Curiosity**：下一件待解锁的器械、下一个待攻克的空间难题、下一家店面。
- **Investment**：亲手打磨的场馆布局、逐步上涨的帝国规模。
- **Social**：不适用。
- **Mastery**：追求更优的动线与区域协同，把场馆调到极致。

---

## Game Pillars

### Pillar 1: 空间即玩法 (Space is the Game)
一切决策最终都落到"东西摆在哪"。

*Design test*: 在"加一套新数值系统"和"让布局本身更有意义"之间，永远选后者。

### Pillar 2: 松弛不紧绷 (Calm, Never Stressful)
玩家永远不会因为手慢、摆错而受惩罚。没有倒计时、没有破产、没有失败结算。

*Design test*: 若某机制会制造焦虑（限时/惩罚/突发危机），把它改写成"错过一个机会"，而不是"受到一次惩罚"。

### Pillar 3: 一眼看懂，越品越深 (Easy to Read, Deep to Master)
拥挤度、动线、区域效果都即时可视；但底下的优化空间可以很深。

*Design test*: 在"隐藏的复杂数值"和"可视化的因果关系"之间，永远选可视化。

### Pillar 4: 看得见的蜕变 (Visible Transformation)
从破旧到漂亮/顺滑的转变必须强烈可感、值得截图。

*Design test*: 每次升级都要带来肉眼可见的场馆变化，而不只是数字变大。

### Anti-Pillars (What This Game Is NOT)

- **NOT 失败/破产/倒闭**：会摧毁"松弛不紧绷"这一核心情感承诺。
- **NOT 付费抽卡 / 逼氪机制**：违背治愈基调，破坏买断制的纯粹体验。
- **NOT 紧张的限时挑战 / 突发危机管理**：制造焦虑，违背支柱2。
- **NOT 深到要查外部维基才懂的隐藏数值**：违背支柱3"一眼看懂"。

---

## Inspiration and References

| Reference | What We Take From It | What We Do Differently | Why It Matters |
| ---- | ---- | ---- | ---- |
| 开罗《健身房物语》等 | 像素风、时间推进、数值养成的经营循环、治愈基调 | 把"布局"从装饰提升为核心优化玩法 | 验证"健身房经营 + 治愈"有稳定受众 |
| Two Point Hospital | 空间布置 + 会员/顾客流动的可视化经营 | 更松弛、无失败、无危机管理 | 验证"布置+流动"玩法的乐趣 |
| 轻量自动化/工厂类（如 Mini Motorways） | "排布求最优解"的空间谜题乐趣、极简可视化 | 治愈外壳、无时间压力、经营外皮 | 验证"温柔版空间优化"可以很上瘾 |

**Non-game inspirations**：真实健身房的动线设计、宜家式的空间规划快感、整理收纳类内容的治愈感。

---

## Target Player Profile

| Attribute | Detail |
| ---- | ---- |
| **Age range** | 20–40 |
| **Gaming experience** | Casual ~ Mid-core |
| **Time availability** | 平日晚间 30–60 分钟，周末更长；也接受碎片化挂机 |
| **Platform preference** | PC 桌面（Mac/Windows），Steam |
| **Current games they play** | 开罗系列、Stardew Valley、Two Point 系列、Mini Motorways |
| **What they're looking for** | 零压力、能"摆弄系统找最优解"、看着自己作品成长的治愈经营体验 |
| **What would turn them away** | 时间压力、失败惩罚、逼氪、看不懂的隐藏数值 |

---

## Technical Considerations

| Consideration | Assessment |
| ---- | ---- |
| **Recommended Engine** | Godot 4.x —— 轻量、开源、原生导出 macOS/Windows；TileMap、导航（NavigationServer）、信号系统天然契合网格布局与小人寻路；自带 Godot 专家 agents 支持 |
| **Key Technical Challenges** | 会员寻路与动线/拥挤度实时计算；区域效果（邻接/协同）的规则系统；流畅的拖放-吸附交互 |
| **Art Style** | 像素风（俯视 / 轻等距 top-down / light-iso），tile 可复用 |
| **Art Pipeline Complexity** | Medium（自定义 2D 像素；MVP 可用占位素材） |
| **Audio Needs** | Moderate —— 轻松环境音乐 + 令人满足的交互音效 |
| **Networking** | None（单人） |
| **Content Volume** | MVP：1 房间 + ~5–6 种器械。完整愿景：多城区多店面、数十种器械与区域类型 |
| **Procedural Systems** | 无强制程序生成；店面/空间形状可为手工设计或半程序 |

---

## Risks and Open Questions

### Design Risks
- **（最高）空间优化的深度 vs 松弛感的平衡**：布局要有嚼头，又不能烧脑到破坏治愈感。这个平衡只能靠原型验证。
- 核心 30 秒循环（拖放+反馈）是否本身就足够满足、耐玩。

### Technical Risks
- 会员寻路 + 拥挤度/动线的实时计算在会员数增长时的性能与可读性。
- 区域协同规则系统若做得过于复杂，会同时威胁性能与"一眼看懂"。

### Market Risks
- 治愈经营品类有成熟竞品；需靠"布局=核心玩法"这一独特钩子做出差异化。

### Scope Risks
- 连锁/挂机（Tier 2）诱人但易过早铺开——支柱与范围分层已用于圈住范围。
- 像素美术量在 Tier 1+ 上升，需要复用策略。

### Open Questions
- 布局对模拟的影响强度到什么程度，既有深度又不焦虑？→ 用 `/prototype` 原型验证。
- 会员动线/拥挤度用什么可视化方式最"一眼看懂"？→ 原型阶段试几种。

---

## MVP Definition

**Core hypothesis**：玩家会觉得"在网格上拖放器械、看即时反馈、微调布局以让像素小人顺畅锻炼"这个核心循环，本身就足够有趣、令人放松、想一直优化下去。

**Required for MVP**：
1. 一间房 + 一个网格；可拖放、吸附、旋转约 5–6 种器械。
2. 像素小人进场 → 寻路走向器械 → 排队/使用/离开；拥挤度与动线**可视化**。
3. 满意度 → 收入 → 购买更多器械/微调布局的经济闭环。

**Explicitly NOT in MVP**（后延）：
- 多店连锁、地图、不同城区人群
- 半挂机产出系统
- 会员故事线/叙事
- 场馆美化"出片"系统、成就系统
- 任何失败/破产机制（永久排除）

### Scope Tiers

| Tier | Content | Features | Timeline |
| ---- | ---- | ---- | ---- |
| **MVP** | 单房间 + 5–6 种器械 | 核心循环：拖放布局 / 寻路 / 满意度→经济 | ~4–8 周 |
| **Vertical Slice** | 一家可扩建的完整店面 | 核心 + 多房间扩建 + 多器械/区域类型 + 里程碑 | ~2–3 个月 |
| **Alpha** | 多店面框架（占位内容） | 全部特性粗略可用：连锁 + 半挂机 + 城区人群差异 | ~6–9 个月 |
| **Full Vision** | 完整内容与打磨 | 连锁帝国 + 挂机 + 美化系统 + 成就，全面抛光 | ~18–30 个月 |

---

## Visual Identity Anchor

*(在 Lean 评审模式下由头脑风暴直接确立；后续由 `/art-bible` 正式展开。)*

- **视觉方向**：治愈像素风（Cozy Pixel）——温暖、清爽、干净可读的俯视/轻等距场馆。
- **一句话视觉规则**：**"破旧到漂亮的蜕变必须一眼可见、值得截图。"**（呼应支柱4）
- **支撑视觉原则**：
  1. *可读优先*——器械、区域、拥挤度、动线在任何缩放下都清晰可辨。*测试：新玩家不看教程也能一眼认出每个区域在干什么。*
  2. *温暖治愈的色调*——柔和明亮、低对比压力，传达零焦虑。*测试：任何画面截图都让人感到放松而非紧张。*
  3. *蜕变可感*——升级/整理后场馆外观有明显正向变化。*测试：升级前后并排对比，肉眼立刻能看出"变好了"。*
- **色彩哲学**：以温暖中性 + 柔和点缀色区分功能区；避免高饱和警示色（红/闪烁）用于常态，以维持松弛感。

---

## Next Steps

- [ ] 用 `/setup-engine` 配置引擎（Godot 4.x）并生成版本感知的参考文档
- [ ] （推荐 Prototype-First）用 `/prototype 网格拖放布局+会员寻路` 先验证核心循环好不好玩（1–3 天一次性代码）
- [ ] 若原型 PROCEED：用 `/art-bible` 建立视觉标准
- [ ] 用 `/map-systems` 把概念拆解成系统并建立系统索引
- [ ] 用 `/design-system [system]` 逐系统撰写 GDD（把原型经验写进调参与公式）
- [ ] 用 `/create-architecture` 制定技术架构蓝图
- [ ] 用 `/architecture-review` 建立 TR 追溯矩阵
- [ ] 用 `/gate-check pre-production` 验证进入生产的就绪度
