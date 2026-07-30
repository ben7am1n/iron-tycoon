# Review Log — GridSystem

> 本文件是 `design/gdd/grid-system.md` 的评审修订史。每次 `/design-review` 追加一条。
> 复审时先读最近一条：核对上轮 blocking 是否已解决，避免重复发现同一问题。

---

## Review — 2026-07-17 — Verdict: **APPROVED**（复审；4 项 blocking 当场修订后接受）

**Scope signal**: L（与上轮一致）—— 6 条公式、7 个下游消费者、59 条 BLOCKING AC、13 个测试文件、至少 1 个 ADR（OQ#11）。Producer 应在 sprint 规划前复核。

**Mode**: `/design-review` full（`--depth full`）

**Specialists**: `systems-designer` ✅、`qa-lead` ✅、`creative-director` ✅（资深综合，最终 verdict）
> ⚠️ **`game-designer` / `godot-specialist` / `performance-analyst` 未能运行** —— API session limit 硬配额中断（重置 2:20am Asia/Shanghai）。这三个域由主 session 补做**非独立** pass，creative-director 已按更低权重计入并明确判定**不实质削弱结论**：这三个域上轮已做过完整对抗式扫描，且本轮全部修订为补充文字、零设计返工；复审的真正风险是"新文字是否引入新问题"，而拥有这些新文字的两个域（systems / qa）恰好都拿到了独立对抗式 pass。

**Blocking items**: 4（全部当场解决） | **Recommended**: 6（全部当场解决） | **Nice-to-have**: 1（未处理，见下）

**Prior verdict resolved**: ✅ Yes —— 上轮 3 项 blocking（B1 union-bbox 调用约定 / B2 instance_id 生命周期 / B3 release UB）经独立复核，**修复均成立**，但两项有残余（见下）。

---

### Summary（creative-director 综合）

> "上一轮的评价仍然成立 —— 这是本项目最严谨的 GDD。本轮所有发现，无一例外，都是'**它对自己定的标准比它在这四处执行的更高**'。这是一个很好的失败模式。"

本轮 4 项 blocking 全部是**补充文字**，无设计返工。creative-director 明确判定：**修订后无需再跑一轮 5-agent 全评审** —— 残余全部是本文档已确立原则的机械应用，不是新的判断。

---

### 上轮 blocking 的复核结论（专家未采信评审记录，重新验证了修订本身）

| 上轮项 | 复核结论 | 残余处理 |
|---|---|---|
| **B1** union-bbox 调用约定 | **部分修复** [systems-designer]：API 形状挡住**外部**消费者（`declared_bounds()` 只收 `equipment_def`，无法请求 footprint-only 包围盒）—— 但挡不住 **GridSystem 内部实现者**在调用点手搓两个局部 bbox，**字面满足每一个字、实质重现同一 bug**。真正的地板是 AC-C4.3 回归测试，不是文档声称的"API 形状"。creative-director：文档原话只说"第一道防线"，没声称封死 —— **属措辞未写完，不阻塞** | R1：新增三层防护栈表（第一道防线 / 第二道 / **地板=AC-C4.3**）+ "不要把第一道防线误读成地板" |
| **B2** instance_id 生命周期 | **GridSystem 侧修复成立**（负 id 拒绝、重复 live id 拒绝、AC-C7.8 诚实记录复用不可测）。**但交接欠约束**：未钉死"必须只有一个分配器实例"——**两个分配器各自单调递增、各自都合法，合起来发重复 id** | R3：交接段新增三条具名要求（唯一实例 / undo-redo 交互 / 切档须**每次** deserialize 重设 max+1） |
| **B3** release UB | **部分修复** [qa-lead]：AC-D1.1 真正可测且正确 BLOCKING；AC-D5.4 诚实地不伪装成测试（正确）。**但升级触发条件零探测机制** —— 与 OQ#7 同类缺陷，而 OQ#7 上轮被判定必须加硬门禁 | **B7（本轮 blocking）**：新增 OQ#13 硬门禁 |

---

### Blocking items（4 —— 已全部解决）

| # | 来源 | 问题 | 修订 |
|---|---|---|---|
| **B4** | systems-designer | **`occupant_id = 0` 无 fixture。** `0` 是**整局第一台器械**的合法 id（规则7：从 0 起单调递增），但全 GDD 的 AC fixture 一律用 `id=7`/`id=9`。GDScript 里 `if occupant_id:` 中 `0` 是 **falsy** → 第一台放下的器械对 `is_solid` **完全隐形**，小人径直穿过它。且**只有第一台坏**（id≥1 truthy，行为正常）—— 这种"只有第一个坏"的形状在手动试玩中几乎无法归因。**在本条之前该 bug 对整个测试套件不可见。** | 新增 **AC-D3.4 [BLOCKING]**（`commit(0,...)` → `is_solid` 必须 `true`、`get_occupant_id` 必须返回 `0`）+ 正误代码对照 + "新增测试应优先用 id=0 作 fixture" |
| **B5** | qa-lead + 主 session（**独立同源**） | **AC-PERF.3 fixture 未要求真实稀疏度。** 选 `Dictionary` 存 `access_ids` 的**全部理由**是稀疏（规则2）；若冒烟测试用稠密 fixture，它**在原理上无法失败于它被创造出来要抓的那个缺陷** —— 一条测不到自己目标的 AC 不是宽松，是**缺陷 AC**。这正是"快照语义"⚠️ 注批评的"测错数据形状"在 AC 层的对偶：同一个错误又犯一遍。另：300 次重复同一 delta 是分支预测/缓存最优情况，测的不是拖拽 | GIVEN 改为**三条 fixture 约束表**：器械数 5–6 / **10–20 稀疏 access 格散布于 130 格** / **anchor 逐次沿真实轨迹变化**。首次调用可排除出"单次最大"断言（冷启动）但仍计入总耗时。CI 为基准环境，**不得因本地机器慢而放宽** |
| **B6** | qa-lead | **assert 类 AC 未规定捕获机制。** AC-D5.2 / AC-D5.3 / AC-D1.1 三条 BLOCKING 都要求断言"`assert()` 触发"，但 Godot 的 `assert()` 失败**中止脚本执行** —— 朴素 GUT 写法会让整个测试进程崩溃。文档从未说测试框架该**如何观测到它** → 三个实现者造三套不兼容 harness | H.12 顶部新增共用前提段 + **新增 OQ#14（硬门禁，须早于第一个 GridSystem 测试）**，列三条候选路径（GUT 错误捕获辅助 / 子进程隔离断言退出码 / 兜底降级 ADVISORY）。明令**实现者不得自行发明 harness** |
| **B7** | qa-lead + creative-director | **AC-D5.4 升级触发条件无探测机制。** "若 EquipmentCatalog 校验被削弱则升级为 BLOCKING"是纯散文 —— 无 AC ID、无 CI 检查、无对**尚不存在的** EquipmentCatalog GDD 的交叉引用。把本 AC 的有效性完全押在一个未写的 GDD 会做某事上，而**没有任何机制**会在它没做时通知任何人。**与 OQ#7 同类，而 OQ#7 已被判定必须加硬门禁 —— 文档不能对自己的两个同类缺口给两个标准** | **新增 OQ#13（硬门禁）**：EquipmentCatalog GDD（#2）必须逐条接住三条加载期校验（footprint 非空 / 锚点 min==(0,0) / access 不与自身 footprint 重叠），`/create-architecture` 阶段核对。**未接住则 AC-D5.4 即刻升级 BLOCKING** —— 因为"热路径成本不划算"的论证前提（"有 EquipmentCatalog 这道门"）届时已不成立 |

---

### Recommended（6 —— 本轮一并解决）

| 来源 | 问题 | 修订 |
|---|---|---|
| systems-designer | **B1 残余**：API 形状是"第一道防线"而非"封死"（见上表 B1） | R1：三层防护栈表 —— 第一道防线=API 形状（结构性封死外部）/ 第二道=调用约定（软，代码审查）/ **地板=AC-C4.3**（漏了一定会响）。呼应 `GridStateReader` 一节"软兜底必须站在硬地板上"的同一原则 |
| systems-designer | **`declared_bounds()` 措辞错误**：签名只收 `equipment_def`，"每 `(def, rotation)` 只算一次"暗示按 rotation 缓存 | R2：加措辞注 —— `(W,H)` 是 canonical(0°) 包围盒、**与 rotation 无关**（旋转后 W/H 对调由 D.1 内部处理）；本条约束的是"**成对变换必须收到同一个 `(W,H)` 值**" |
| systems-designer | **B2 残余**：分配器唯一性 / undo-redo / 切档续号（见上表 B2） | R3：交接 PlacementSystem GDD（#4）三条具名要求。点名"本 GDD 对自己施加 DI-only、严禁 Autoload、建议 CI grep，却没对分配器提同等要求 —— 这是一处不对称，此条即为补齐"。undo/redo：redo 复用原 id（违契约）vs 分配新 id（跨 undo 引用失效）—— **两条路都有代价，必须选一条并写下来** |
| qa-lead | **AC-C8.1 范畴错配**：反向索引按 `instance_id` 索引，"**逐格**相等"无意义；且无独立于 `serialize()` 的公开访问器 → 两个实现者会写出两种测试（其一与 AC-C8.3b 完全重复 = 这条 AC 白写） | R4：拆成**两条独立断言** —— (a) 逐格状态相等（按格遍历）；(b) 反向索引相等（**按 `instance_id`** 遍历，用 `get_access_cells(id)`）。说明 `rotation` 往返由 AC-C8.2 单独覆盖，本条不重复 |
| systems-designer | **`world_to_grid` 越界输出未规定** —— D.2 的安全默认值契约只覆盖 `is_solid`/`get_occupant_id`，未覆盖 `world_to_grid` 自己的坐标输出 | R5：新增契约 —— **如实返回、不 clamp、不报错、不返回哨兵**。**与 D.2 相反是有意的**：D.2 是查询（越界=正要读不存在的内存，必须响亮拦下）；`world_to_grid` 是换算，**界外输入完全正常**（鼠标拖出房间每帧都产生）—— 若每次都 `push_error()` 日志会被刷爆；若 clamp 则调用方**无法区分"贴边"与"已拖出去"**，房间外沿会产生诡异吸附假象（教科书级"咦？"）。契约的另一半：**调用方必须自行判界**。点明它是 D.2 的**对偶**而非延伸 |
| systems-designer | **`rotation=360` 非法但无调用方归一化指引** —— "每按 R 键 `rotation += 90`" 第四次按键就产生 `360`，直接命中 UB 表。**这不是牵强边界，是任何人都会先写出来的那版代码** | R6：D.5 新增交接段 —— 归一化归 PlacementSystem（`(rotation+90) % 360`）。**GridSystem 不做 `%360` 的理由**：它能把 `360` 修成 `0`，但同样会把一个**真 bug**（如把角度和格数搞混传进 `1080`）悄悄修成看起来合理的 `0` —— 那正是本 GDD 反复拒绝的"静默修正"。**归一化是调用方对自己旋转状态的责任，不是 GridSystem 的容错义务** |
| systems-designer | **`declared_bounds` 无强制上界**，access 数量 `N` 至今"待 EquipmentCatalog GDD 确认" | R7：新增 ⚠️ 段 —— `footprint=[(0,0)]` + `access=[(5,5)]` 算出 `W=6,H=6`，公式不退化、**会老老实实给出正确答案**。点明 `~3×3` 是**假设而非被强制的约束**，且 **D.6 房间尺寸论证与 G 节调参范围隐含建立在它之上** —— 一个未被任何机制强制的假设正在支撑若干看起来已定的结论。归入 OQ#13 附带项；**在此之前所有引用"~3×3"的推论都是条件性的** |

---

### 未处理

| findings | 处置 |
|---|---|
| qa-lead：AC-NEG.2 第 6 行把 `get_snapshot()` 与 `get_speculative_snapshot()` 打包进一条断言（实为 8 行 9 调用） | **未处理** —— qa-lead 自评"trivial，不影响修复有效性"。可在实现时顺手拆开 |

---

### ⚠️ 一项非 GDD 缺陷的排期风险（交 producer / qa-plan，不在本 GDD 内解决）

**OQ#9（"access 受阻/零可达"呈现）目前是信任链而非门禁。** 该需求**只记录在本 GDD 与本记录里** —— 用户上轮明确选择不写进 systems-index 的 Congestion 行。没有任何机制强制 #7/#8 的作者回读。

**且实现顺序会制造一段真实的"零信号窗口"**：GridSystem 是 #1，Congestion/Overlay 是 #7/#8。Navigation(#5) / MemberSim(#6) 完成后即可内部试玩，而此时零可达器械按 AC-NEG.2 被**刻意零信号**放置 —— 这段窗口里 B 节"沉默可信度"是实质失效的。**这不是 GDD 缺陷（设计如此），是排期风险。**

> creative-director 补充：**OQ#9 与新增的 OQ#13 是同一个形状的东西，值得一起读** —— 两者都是"本 GDD 的某个设计选择制造了一个空洞，并把填补它的责任交给了一个尚不存在的下游 GDD"。#9 交出去的是**玩家可见性**，#13 交出去的是**数据合法性**。共同风险相同：**交接只是一段文字**。这已写入 Open Questions 尾部。

---

### 变更规模

- 文档：**1097 行 → 1183 行**
- BLOCKING AC：**57 → 59**（新增 AC-D3.4；AC-PERF.3 加严）| ADVISORY AC：**5**（不变）
- 必需章节：**8/8**（修订前后均完整）
- Open Questions：**12 → 14**（新增 #13 EquipmentCatalog 对偶校验 / #14 assert 捕获机制，**两者均为硬门禁**）
- 硬门禁清单：**#3 / #7 / #9** → **#3 / #7 / #9 / #13 / #14**
- 测试文件：12 → 13（新增 `grid_perf_drag_smoke_test.gd`）
- **无设计返工** —— 全部修订均为补充文字

---

### 后续注意事项

1. **本轮无 blocking 遗留** —— 4 项全部当场解决。creative-director 明确判定**不需要再跑一轮全评审**。
2. **三项用户裁决（警告通道 / 存档全失败 / 当场修订）本轮未被任何专家触碰，也不应被触碰。**
3. **三个域（game-designer / godot-specialist / performance-analyst）本轮只有非独立 pass。** 若未来对以下三点有疑虑，值得补一次独立扫描：（a）OQ#9 的信任链是否可接受；（b）C 节记录的 `AStarGrid2D` 实测数字（`RefCounted`、0.14μs、1815μs 等）—— **这些数字任何文档层 pass 都无法复验**，只能靠 OQ#7 的 headless 基准（已硬门禁到 Vertical Slice 前）；（c）AC-PERF.3 加严后是否仍有工况缺口。
4. **OQ#13 / #14 是本轮新增的硬门禁，`/create-architecture` 必须逐条核对** —— #14 还须**早于第一个 GridSystem 测试**解决。

---

## Review — 2026-07-16 — Verdict: NEEDS REVISION（当场修订，待复审）

**Scope signal**: L —— 5 条公式、7 个下游消费者、~40 条 BLOCKING AC（修订后 57 条）、12 个测试文件、至少 1 个 ADR。单点都不难，面很宽且正确性门槛异常高。Producer 应在 sprint 规划前复核。

**Mode**: `/design-review` full（`--depth full`，与 `production/review-mode.txt` 的 lean 无关 —— 后者只控制 director 门禁）

**Specialists**: `game-designer`, `systems-designer`, `qa-lead`, `godot-specialist`, `performance-analyst`, `creative-director`（资深综合，最终 verdict）

**Blocking items**: 3（全部当场解决） | **Recommended**: 9 | **Nice-to-have**: 7（大部分一并解决）

**Prior verdict resolved**: First review

---

### Summary（creative-director 综合）

> "本项目迄今最严谨的 GDD。专家未发现公式错误、依赖图断裂或支柱违反。5 位中有 2 位在其最高危探针上明确报告 NONE FOUND。分歧全在**边缘**，不在**主干**。"

三项 blocking 全部是**补充文字**，无设计返工。文档边界被评为"本项目见过的防守最好的"。

---

### Blocking items（3 —— 已全部解决）

| # | 来源 | 问题 | 修订 |
|---|---|---|---|
| **B1** | systems-designer（原标 LOW，**creative-director 提升为全场最重要**） | **union-bbox 调用约定未写明。** 文档把"footprint 与 access 必须共用并集包围盒"标为 🔴 最高危并作了代数证明 —— 但没规定**调用方式**。实现者写两次独立的 `_transform()` 调用、各自内部推导局部 `(W,H)`，就能**在不违反任何已写规则的前提下**重现同一个 bug。每次调用**单独看都对**，错的是"两次"本身。 | 规则4 新增 🔴 调用约定段：`declared_bounds()` 每 `(equipment_def, rotation)` 只算一次，同一 `(W,H)` 必须**作为显式入参**传给两个变换；附正误代码对照；点明 `get_transformed_cells()` 返回复合 `TransformedFootprint`（而非提供通用格集合变换工具）**本身就是第一道防线**。 |
| **B2** | systems-designer | **`instance_id` 生命周期无归属。** GridSystem 拒绝重复的 live id，但从未规定谁分配、`clear()` 后是否复用。SelectionSystem 自建 `id → EquipmentInstance` 缓存 —— 复用的 id 会让陈旧缓存**静默解析到错误的器械**。这是 B 节点名的"沉默的坏读取"，且是本文档所有防御**唯一漏掉的一类**：其余防御都在问"数据合法吗"，而复用 id 的每一步**都合法**。 | 规则7 新增生命周期契约表：分配器归属、取值域 `>= 0`（`-1` 是保留哨兵）、**单调递增会话内永不复用**、读档后从 `max(已加载 id)+1` 续。新增 AC-C7.7（负 id 被拒）、AC-C7.8（**复用不可测** —— 显式记录为能力边界，防止未来有人提议给 GridSystem 加复用检测）。交接 PlacementSystem GDD（#4）。 |
| **B3** | qa-lead | **release 构建下空 footprint / 非法 rotation 行为未定义且未测。** AC-D5.3 只覆盖 debug 的 `assert()`，而 `assert()` 在 release 被编译期剔除 + 文档明确不做运行时防御 → release 行为是**未指定**，而非**指定为信任**。`rotation` 名义枚举但 GDScript 不强制。 | D.5 新增未定义行为表（每个非法输入的 debug/release 行为 + 真正的门是谁）+ 为何接受该缺口（热路径成本 vs. 只能由内部 bug 触发且必被 CI assert 抓到；**与 D.2 越界处理不同是有意的** —— 越界来自不可信的存档，非法 def 来自可信的内部数据 + EquipmentCatalog 加载期门）。`rotation` 是表中**唯一没有上游门的一行** → 强制用 GDScript `enum` + 穷举 4 分支 + `_:` 兜底 `assert(false)`。新增 AC-D5.4（UB 显式记录为 accepted risk，**若 EquipmentCatalog 校验被削弱则自动升级为 BLOCKING**）、AC-D1.1（非法 rotation 不得静默回退 0°）。 |

---

### 用户裁决（3 项 —— 不得由 agent 静默决定）

| 议题 | 分歧 | **用户决定** |
|---|---|---|
| **放置时的警告通道** | `game-designer`：文档把"不阻塞"和"不提示"混为一谈了 —— 规则6 步骤3c 让 `can_place` **连查都不查** access 格的占用，因此连 `{valid:true, warnings:[...]}` 都返回不了。延迟发现（十分钟后才从 overlay 看出来）比当场提示更违反"空间会诚实地回应我"，它破坏了 B 节锚定的即时反馈闭环。<br><br>`creative-director` **判文档胜诉**：GridSystem 已提供 `get_occupant_id()` / `get_access_cells()` / 推测快照 —— 上层三行代码就能自己算出"使用位被挡"。加 `warnings` 会让 GridSystem 对**好不好用**有意见，违反规则5 分工原则，且是依赖根边界纯度的第一道裂缝。修复归 PlacementSystem/Overlay。 | **维持原设计：GridSystem 不出警告。**（采纳 creative-director）<br>未加 `warnings` 字段，规则5 分工原则原样保留。 |
| **存档全失败策略** | `systems-designer`：数百条 record 时一个 bit 翻转丢掉整个布局、无挽救路径；文档只论证了它防住的一侧，从未权衡反向失败（存档损坏抹掉玩家真实成果本身就是更严重的"沉默可信度"违反）。<br><br>`creative-director` **支持文档**：在"沉默可信度"框架下**响亮的错严格优于静默的错**。 | **维持"全失败" + 补 accepted-risk 说明。**<br>规则8 新增双向失败模式表 + 决策理由（与 D.2 选 `push_error`、AC-D1.1 拒绝静默回退**同一原则的第三次应用**）+ **复审触发条件：records > ~200**（交接 SaveLoad GDD #14）。 |
| **何时修订** | — | **当场修订**（本 session 完成） |

---

### Recommended（9 —— 本轮一并解决）

| 来源 | 问题 | 修订 |
|---|---|---|
| game-designer #2/#3（**creative-director 提升**） | **可达性闭环无人负责，且"靠 overlay 呈现"假设了 overlay 是环境性的。** 一台器械可以**永远无人可用**而**没有任何系统有义务让玩家发现** —— B 节意义上最纯粹的"咦？"：不是延迟发现，是**永不发现**。若 overlay 做成默认关闭的开关（本品类常见，Two Point Hospital 即如此），"不警告、稍后可见"这套策略**根本没有第二步**。 | E 节划界处新增 🔴 交接段 + **OQ#9**：两条具名需求给 Congestion/Overlay GDD（#7/#8）——（1）必须有系统负责呈现"access 受阻/零可达"，这是 GridSystem 允许该状态静默存在的**前提条件**，非可选打磨项；（2）**呈现必须默认可见，不能只藏在开关后**。写明"这个空洞是本 GDD 的设计选择造成的，所以确保有人接住是我们责任的一部分"。 |
| qa-lead #1（HIGH） | **AC-C8.3 只证明了 record 顺序，没证明字节级确定性。** 若 record 内的 cells 数组在写出前经过 `Dictionary`/`Set`，其元素顺序可能**独立于** record 顺序变化 —— 同一 bug 的下一层。 | AC-C8.3 改为**全量深相等** `A.serialize() == B.serialize()` + 要求 record 内 cells 也确定性排序（按 `(y,x)`）；新增 **AC-C8.3b**（往返后 `S_A == S_B` 逐字节相同 —— 这才是"确定性存档"的真正保证；AC-C8.1 只验了状态等价，没验序列化输出本身稳定）。 |
| godot-specialist #1 | **`@abstract` 兜底没有地板。** "退化为命名约定+代码审查"与设计所依赖的保证**不等价** —— 没有强制时 `GridStateReader` 退化成普通基类，漏覆写会调用**没有方法体**的基类实现 → 静默返回默认值或在远离 bug 的地方抛错。 | 新增三步验证与兜底协议：架构阶段跑 headless 复现（故意漏覆写的子类）→ 记录**确切行为**到 D.7 → **若非硬报错，基类必须带 `push_error()` + 安全默认值的实体桩**，不得只留裸声明。原则："软兜底可以接受，但必须站在一个硬地板上 —— 地板是漏覆写一定会响。" OQ#3 升级为 `/create-architecture` 硬门禁。 |
| godot-specialist #3 | **D.7 的 ✅ 比 OQ#6 承认的测试范围更自信。** 实测的是"相同顺序→相同路径"；实际需要的是**顺序无关性**（`deserialize()` 按 `instance_id` 升序重放，与玩家原始放置顺序**无关**）。skimming 的实现者会误以为 ✅ 覆盖了后者。 | D.7 该条 ✅ → ⚠️ 并精确限定范围（"只覆盖了相同顺序这一半"）+ 内联交叉引用 OQ#6 + 拆出一条独立的 ✅（`AStarGrid2D` 不参与序列化 —— 该结论**不依赖**顺序无关性）。OQ#6 补充说明为何 D.7 不覆盖它。 |
| performance-analyst #1/#2/#5 | **微基准测错了工况和数据形状。** （1）"0.07% 帧预算"是**单次**成本，而拖拽是**连续上百帧**每帧调 —— 持续构造/丢弃快照对象是**分配器压力模式**，单次微基准**原理上无法**反映（碎片化、方差）。（2）`Dictionary` 的 141.71μs 很可能测的是**稠密**字典（3600 条目），而稀疏正是选 `Dictionary` 的**全部理由** —— 按格数线性缩放假设了 `Dictionary` 不保证的线性。（3）`get_snapshot()` 是全文档最贴近玩家感知的性能路径，却只挂在一个无强制机制的 OQ 上。 | "快照语义"一节新增 ⚠️ 双缺陷说明（结论不变 —— 130 格仍有 ~3 个数量级余量 —— 但验证要求据此加严）；新增 **AC-PERF.3 [BLOCKING]** 拖拽工况冒烟测试（连续 300 次 ≈5 秒@60fps，总 < 50ms 且**单次最大 < 5ms**）。门槛**刻意定得很松**："这不是性能预算，是回归警报 —— 作用不是证明快，而是保证'慢了 1000 倍'在 CI 里会响"；"单次最大"专抓方差（平均值会把一帧 5ms 的卡顿藏起来）。 |
| qa-lead #7 | OQ#7（性能回填）"首次实现者 / 实现该 story 时"**不是一个门**，无强制机制 → 可能无限期静默不测。 | OQ#7 加**硬截止：Vertical Slice 门禁之前** + 基准脚本必测项清单（含**真实稀疏度**下的 `access_ids` 字典开销，而非稠密缩放）。 |
| game-designer #4 | **D.6 房间尺寸表过度自信。** 散文诚实（"假设非结论"），但 B 行标 ✅、A/C 标 ❌ 会**锚定**原型设计者去**确认** 130 而非**测试**它 —— 而这是项目自评的**最高设计风险**。且 B 的论证与它要验证的命题**是同一个命题**（循环）。 | 剥掉 ✅/❌ → "起点，待验证"；新增说明"上表全部是推理，没有一格是玩出来的"+ 点破循环论证 + 🔴 对 `/prototype` 的明确要求：**必须探到 A(10×8) 和 C(16×12) 的边界**，任务不是"验证 13×10 好不好玩"而是"找到拥堵感消失的上界与松弛感消失的下界"——"只测 B 得到的是一个'还行'，那既不能证明 B 最优，也发现不了边界"。 |
| godot-specialist #2 | **RefCounted 生命周期契约缺失。** 不在树里 → 没有 `tree_exited`、没有任何引擎级"我要没了"信号。换关卡时若 UI 缓存了旧引用，旧实例因引用计数不归零**继续存活并老老实实回答上一个关卡的问题** —— 生命周期维度的"沉默的坏读取"。 | 新增持有契约表（Orchestrator 是唯一长生命周期强引用；UI/表现层**不得跨关卡缓存**，须每次取或持 `WeakRef`，**严禁 `@onready var grid`**）+ 说明 MVP 内为纯文档性但**必须现在写**（VS 引入多房间时相关 UI 早已写完）+ 建议架构阶段考虑 generation-id。 |
| godot-specialist #4 | DI 只有编码标准背书，**无机器强制** —— 没有任何机制阻止未来加 Autoload 包住 GridSystem。 | 新增 ⚠️ 建议架构阶段加 CI 检查（grep `project.godot` 的 `[autoload]` 段）—— "零成本，防的是一类几乎必然会在某个赶工的下午发生的事"。 |

---

### Nice-to-have（本轮一并解决）

- **AC-NEG.2 不可测**（qa-lead #4）："查询**任意**公开接口"无法穷举 → 收敛为 **8 行穷举 API 表**（`can_place` / `commit` / `is_solid` / `get_occupant_id` / `get_access_cells` / 快照 / `serialize` / `clear`），逐个断言。点明本条真正作用是**护栏**：锁死的不是某个 bug，而是未来有人"顺手"加可达性判断的冲动。
- **"0 个 access cells 合法"无 AC**（qa-lead #5）→ 新增 **AC-C5.5**，并与 AC-D5.3（空 footprint 非法）对照，把这个刻意的不对称钉死。
- **`clear()` 复杂度声明不精确**（performance-analyst #3）：从 `access_ids: Array[int]` 移除 id 是 O(k) 线性扫描+移位，而 access 重叠**无上限** → 规则5 新增复杂度尾巴说明 + 复审信号（单格 `access_ids` 经常 > 10）+ 明确"**不要现在优化**"（k 极小时 `Array` 比 `Dictionary` 快）。
- **`grid_changed` 消费者无增量期望**（performance-analyst #4）→ 信号设计一节新增 advisory（✅ 只重画 payload 里的格 / ❌ `TileMapLayer.clear()` 全房间重画），并说明这不违反"本 GDD 不管视觉"的边界 —— 它不规定画成什么样，只说明**信号契约的意图**（payload 拆两个精确数组是有成本的选择，全量重建会让这个成本白付）。
- **负 id / 复用 id 的 E 节条目** → 与 AC-C7.7 / AC-C7.8 对齐补齐。
- **矩形 AABB footprint 是永久约束**（game-designer #5）→ 记为 **OQ#11**：作为依赖图的根，这实际为整个项目排除了 L 形器械。MVP 够用，**但应是被选择的约束而非被发现的约束** → 建议立 ADR。

---

### 未采纳 / 明确拒绝

| findings | 处置 |
|---|---|
| game-designer #1（`can_place` 加 `warnings` 字段） | **拒绝** —— creative-director 判文档胜诉，用户裁决确认。修复归 PlacementSystem/Overlay，非本层。 |
| systems-designer #2（存档改为部分恢复） | **拒绝** —— 维持全失败，补 accepted-risk 说明。用户裁决确认。 |
| qa-lead #6（"无并发防护"零覆盖） | **未处理** —— 低优先级。SimulationOrchestrator 单线程固定顺序 + 存档只在 tick 边界，前提成立时该断言无意义；前提若被打破，问题也不在 GridSystem 这一层。 |
| godot-specialist #5（`Array[Vector2i]` vs `PackedVector2Array`） | **未处理** —— 风格一致性问题，风险低（信号频率是"每次放置一次"）。可在架构阶段顺手决定。 |
| qa-lead #8（AC-D4.1 `cell_size`） | **无需处理** —— qa-lead 自己复核后确认：AC 参数化在显式占位值上，公式不依赖 `cell_size` 终值，不会被后续架构决策失效。**非缺口**。 |

---

### 变更规模

- 文档：**872 行 → 1094 行**
- BLOCKING AC：**~40 → 57** | ADVISORY AC：**2 → 5**
- 必需章节：**8/8**（修订前后均完整）
- Open Questions：**8 → 12**（新增 #9 可达性呈现 / #10 id 分配器 / #11 矩形 ADR / #12 存档规模复审；#3/#7 加硬门禁）
- 无设计返工 —— 全部修订均为**补充文字**

---

### 复审注意事项

1. **本轮无 blocking 遗留** —— 三项全部当场解决。复审应验证修订**本身**是否充分，而非重新发现原问题。
2. **三项用户裁决不得被复审推翻**（警告通道 / 存档全失败 / 当场修订）—— 若复审 agent 重新提出这些，说明它没读本记录。
3. **B1 是全场最重要的发现且被原作者低估**（标 LOW，creative-director 提升）—— 复审应重点验证规则4 的调用约定是否真的封死了那条路。
4. **OQ#9 是本 GDD 的设计选择造成的空洞**，其闭合归 Congestion/Overlay GDD（#7/#8）。**用户明确选择不把它写进 systems-index 的 Congestion 行** —— 该需求目前**只记录在本 GDD 与本记录里**，设计 #7 时须主动回读。
