# 跨 GDD 评审报告 · 撸铁大亨 (Iron Tycoon)

> **日期**：2026-07-19
> **评审 GDD 数**：16 个系统 + game-concept + systems-index
> **基线**：`design/registry/entities.yaml`（成熟度极高，已预先化解多处对账）
> **模式**：`/review-all-gdds full`（Phase 2 一致性 + Phase 3 设计理论 + Phase 4 场景走查）
> **裁决**：🔴 **FAIL**（1 个 Blocking）

**总印象**：这是一套异常成熟、高度自洽的文档集。四大经典设计风险（推-拉平衡、满意度双重计数、反死亡螺旋、无限集群支配）都已在设计层**显式和解**并固化进注册表。大多数跨系统缺口已被各 GDD 的 Open Question / `propagate-design-change` 登记。真正阻塞架构的只有**一处**——而它恰恰是"双方都以为已解决"的隐性洞。

---

## 一、一致性问题（Phase 2）

### 🔴 Blocking

**C-B1　"移动/重定位已放置器械"（Move/relocate）流程无归属——Placement 与 Selection 互推，且用 BLOCKING 级 AC 各自钉死了相反的契约**

涉及 `placement-system.md` + `selection-system.md` + `systems-index.md`。三重矛盾叠加：

1. **依赖方向冲突（2a）**：PlacementSystem 明写 `Explicit non-dependency: SelectionSystem — does not depend on it, and it does not depend on PlacementSystem`；但 SelectionSystem 把 PlacementSystem 列为 **Hard** 上游（`relocate flow (Move handoff)`），systems-index 第 40 行也站 Selection 一边。
2. **规则互推（2b）**：PlacementSystem Core Rule 1 说"移动已放置器械是 SelectionSystem 的领域，本系统不管"；SelectionSystem Core Rule 3 说"Move 交给 PlacementSystem 的 relocate flow"。**双方都认为对方会做，实际两份文档都没定义该机制。**
3. **AC 不可同时通过（2f）**：PlacementSystem **AC20**（静态 API 检查断言"不暴露任何 relocate/remove 既有 instance_id 的方法"）与 SelectionSystem **AC4**（"按 Move → PlacementSystem 的 relocate-ghost 一帧内出现"）——两条 BLOCKING 级 AC 逻辑互斥。

**为何最危险**：SelectionSystem OQ4 把它当作"确认一下入口"的轻量待办，掩盖了 PlacementSystem *主动禁止* 该入口的事实。**必须裁决 relocate 唯一归属方，并在三处对齐**（Placement 依赖声明、Selection Move 契约、AC20/AC4）。

### ⚠️ Warning

| 编号 | 问题 | 涉及 GDD |
|---|---|---|
| **C-W1** | `GridStateReader` 缺 `get_placed_instances()`——ZoneRules 与 SelectionSystem 两个硬下游都依赖它，但 grid-system 的只读契约只声明 `is_solid/get_occupant_id/get_access_cells/get_dimensions`。附带：ZoneRules 的 `PlacedInstance.access_cell`（单数）vs GridSystem `get_access_cells`（数组）形状需对齐（`access_cell_count_max=1` 可调和）。 | grid-system, zone-rules, selection-system |
| **C-W2** | MemberSim `exercises_per_visit` 仍写 `randfn(mean × satisfaction_modifier)`，但 Satisfaction Core Rule 6 + 注册表已裁定 exercises **必须**改用阻尼版 `visit_length_modifier[0.75,1.5]`，否则占用度 ~modifier² 振荡。文本与已落地决策直接冲突，会误导实现者。 | member-sim, satisfaction |
| **C-W3** | EquipmentCatalog 缺 `use_duration_mean/stddev/min/max` 四个字段，且未列 MemberSim 为下游——而 MemberSim `use_duration` 公式硬依赖它们。 | equipment-catalog, member-sim |
| **C-W4** | Economy 对外只有 `can_afford/spend`，无 credit/earn 路径；SelectionSystem 卖回和 `refund_rate` 归属悬空（声称"Economy 拥有"但 Economy GDD 完全未提）。 | economy, selection-system |
| **C-W5** | MemberSim 未声明 `member_completed_visit(member_id)` 信号——而它是 Economy 唯一收入触发。附带语义待定：0 次锻炼"秒退"会员是否算 completed visit、是否付 `R_visit`。 | member-sim, economy |
| **C-W6** | Navigation 断言"Congestion 不调用 Navigation"，但 Congestion 把 `Navigation.get_path`（算 `access_reachable`）列为 Hard 依赖。行为无害（只读），但记述过期矛盾。 | navigation, congestion |

### ℹ️ Info
- **C-I1** equipment-catalog 用陈旧示例 `crowd_pressure` 举例 effects 词表，实际词表是 `comfort | zone_synergy | spaciousness`。
- **C-I2** congestion-flow-overlay 依赖 `congestion_updated (10 Hz)` 信号，但 congestion.md 未把该信号名列入发射接口。
- **C-I3** `TICKS_PER_DAY` 归属悬空：HUD 依赖它、称"TimeSystem 拥有"，但 TimeSystem 明确声明不持有任何日历概念。

### 各检查项结论（2a–2f）
- **2a 依赖双向性**：命中 C-B1、C-W1、C-W3、C-W4、C-W5、C-W6。TimeSystem 的 6 个下游全部双向对称；GridSystem 核心下游对称。
- **2b 规则矛盾**：核心命中 C-B1。固定 tick 顺序、一帧延迟、access 不算 solid、reservation 归 MemberSim、各 floor 值、读档恒暂停、id 序列化策略——均一致。
- **2c 陈旧引用**：C-W2、C-W6、C-I1、C-I2 为主。
- **2d 归属冲突**：无真正双重归属；唯一模糊项是 `refund_rate`（C-W4）与 `TICKS_PER_DAY`（C-I3）——属缺口非冲突。
- **2e 公式兼容性**：满意度链条量程全部对齐；唯一不兼容点是 C-W2。
- **2f AC 互斥**：命中 C-B1（AC20 vs AC4）；其余无互斥对。

---

## 二、游戏设计问题（Phase 3）

### 🔴 Blocking
**无。** 四大经典风险均已显式和解（`use_quality` w_zone=w_cong=0.5 推-拉对称；`revenue_per_visit` 无满意度乘子防收入失控；`satisfaction_modifier` 下限 0.5 抗死亡螺旋；`zone_synergy` 渐近 S_max 防无限集群）。

### ⚠️ Warning

**D-W1　推-拉平衡对"人口密度÷房间面积"的敏感度高于对权重旋钮，且"扩散"一侧被奖励两次**

`use_quality = 0.5·clamp(total/2) − 0.5·Congestion`，其中 `total = comfort + zone_synergy + spaciousness`——**集群只在 zone_synergy 一处得奖，扩散在 spaciousness（+项）和低 congestion（−项）两处得奖**。更尖锐的是：集群的拥挤惩罚只经密度项（w_dense=0.3）流动，而占用项（w_occ=0.7，主导）逐机独立、与是否集群无关。→ **房间大/会员稀疏时集群支配；会员密集时扩散占优；翻转点由 `max_concurrent_members ÷ 可建造格数` 决定，而非仅由 k_congestion。**

建议：order-8 playtest 要在**真实人口密度 × 房间尺寸**下扫描（并遵守 member-sim OQ6 的"≥2 同型器械"），AC15"无单一支配策略"应在多个密度点验证。这正是 game-concept 列为"只能靠原型验证"的最高设计风险，现收窄为可执行的"密度敏感性"检查。

**D-W2　MVP 现金在房间填满/目录买空后无 sink，会话级"攒钱做大升级"钩子无法在 MVP 内兑现**

game-concept 会话级循环写明"攒够钱做一次大升级（扩建一间房/加新区域）"，但扩建/多房间/美化全部是 Tier-2/VS。MVP 唯一现金 sink 有限（~6 目录 × ~110 格），而 `revenue_per_visit` 随时间无界累积（S 曲线只封顶速率不封顶累积）。→ 布局解好+目录买空后现金失去意义。**正确地**没有用 rent/bills 惩罚 sink（守 Pillar 2）——所以这不是要加惩罚，而是**预期对齐**：要么显式声明"会话级 sink 属 VS、MVP 会话应 time-box 到饱和前"，要么确保 VS 扩建 sink 先于任何"经济深度"评判落地。

### ℹ️ Info
- **D-I1（表扬）** 注意力预算管理是结构性优点：核心拖拽瞬间只有 **2 个主动通道**（放置合法性 + 协同预览），热力图 dim-on-drag 让位、glyph 降为次级、图例 hover-only。远在 3–4 阈值内。
- **D-I2** 满意度是唯一"因果未被直接可视化"的量，靠热力图/协同预览做代理；"我的口碑为什么卡住"在 MVP 内缺屏上分解（Info Panel #17 属 VS）。罚分背后事件本身可见（会员掉头、排队 glyph），不违反反支柱——待 playtest 验证代理是否够。
- **D-I3** 无失败态下"难度"= 解好即高原化（会员数被 `max_concurrent_members` 封顶）；对治愈游戏可接受，但与 D-W2 叠加使"后期无事可做"更明显。
- **D-I4** 反支柱"限时挑战"当前干净（"day N"仅显示、不挂 deadline，时钟由玩家掌控）；VS 设计 Milestones #18 时须确保是"达成即奖励"而非"第 X 天前达成"。

### 3a / 3f / 3g 快速通过
- **3a 进程循环竞争**：单一主导循环（布局→满意度→会员量→吞吐→现金→购械→再布局）；唯一主要资源=现金；满意度是驱动器非货币。多系统自称"heart"是同一循环内角色分工，非竞争循环。✅
- **3f 支柱对齐**：16 个系统每个都服务 ≥1 支柱，无空转系统，无反支柱违反。✅
- **3g 玩家幻想连贯性**：所有分系统统一收敛于"松弛的创意健身房建筑师"。✅

### 玩家注意力预算表（3b）
核心循环时刻 = 拖放/重排一件器械。

| 系统 / 通道 | 主动/被动 | 说明 |
|---|---|---|
| PlacementSystem 幽灵（footprint/access 合法性） | **主动（主）** | 拖拽时第一读取对象 |
| ZoneRules 协同预览 | **主动（次）** | "移到这里那块会亮" |
| Shop 面板可负担性变灰 | 主动（仅取件时） | build-shop-ui Core Rule 1 |
| Congestion 热力图 | 被动（拖拽中 dim ≤20%，默认关闭） | overlay Core Rule 7 |
| 单器械拥挤 glyph / access-blocked 图标 / HUD | 被动 | 环境一瞥 |
| 会员流动 | 被动 | 环境 |

**结论**：真正拖拽瞬间只有 **2 个主动通道**，远在 3–4 阈值内——结构性优点。

### 经济资源 source/sink 表（3d）

| 资源 | Sources | Sinks | 判断 |
|---|---|---|---|
| **现金 balance** | `revenue_per_visit`(R_visit=12/次，随吞吐累积)；卖出退款 0.5×cost | 器械购买（有限）；卖出亦为 source | ✅ 早期健康；⚠️ 中后期 source ≫ sink（D-W2） |
| **满意度 global_satisfaction** | 离场会员 S_member 慢 EMA | 低 S_member 拉低 | ✅ 有界 [0,1]，负反馈自校正，modifier 下限 0.5 抗螺旋 |
| **会员数量** | 到达（satisfaction_modifier） | 离场；`max_concurrent_members` 软封顶 | ✅ 自限 S 曲线 |
| **解锁** | MVP 内无 | — | MVP 不适用（Progression #19 属 VS） |

---

## 三、跨系统场景走查（Phase 4）

**走查场景 5 个**：购买→放置→扣款链；卖出/移动使用中器械；Congestion 一帧延迟悬垂 instance；拖拽途中存档；放置到会员所在格。**3 个完全防守通过**，2 个 Warning。

### ✅ 通过（防守扎实，值得记录）
- **卖出/移动使用中的器械**：MemberSim `USING → 器械被删 → 优雅中断 + 满意度惩罚信号`，`grid_version` 路径失效重算；SelectionSystem 明确允许。
- **Congestion 悬垂 instance**：congestion Rule 6「移除当帧删除条目」+ AC#9「查询已删 id 返回 not found」。
- **拖拽途中存档**：拖拽纯输入驱动、提交前不写状态、暂停不受影响，扣款按 commit 触发——存档不会捕获半途拖拽。

### ⚠️ Warning

**S-W1　放置器械到会员当前所在格：navigation.md:90 与 member-sim AC#16 冲突**

navigation.md:90 承认"器械可提交到会员脚下的格子，会员须下一帧 `grid_changed` 时重寻路"；但 member-sim **AC#16** 断言"WALKING/QUEUEING 会员**在任何 tick** 其占用格都不等于 solid footprint 格"。器械落到正在通行的会员脚下那一 tick，两条互斥——而 GridSystem `can_place` 看不到会员位置（归 MemberSim）。需二选一裁决：要么 AC#16 加例外（"被埋当帧、下一帧重寻路解决"），要么定义放置对会员占用格的处理。

**S-W2　存档可复现性 ↔ Navigation 决定性：一条未证明的硬门禁跨在 SaveLoad 上游**

navigation.md:35 明确标注 AStarGrid2D 在对称房间下的平局路径在进程重启/重建后是否稳定**尚未证明**，并硬门禁要求"SaveLoad 依赖前必须先有专门测试"。SaveLoad 的 bit-identical 复现承诺依赖此项。属已登记技术风险，但作为跨系统依赖应在架构/实现阶段显式排期该测试。

---

## 四、需修订的 GDD 清单

| GDD | 原因 | 类型 | 优先级 |
|---|---|---|---|
| placement-system.md | relocate 归属/依赖方向/AC20 与 Selection 冲突（C-B1）；S-W1 放置-会员边界 | 依赖/规则/AC | 🔴 Blocking |
| selection-system.md | Move 假定 Placement 有 relocate flow，AC4 与 Placement AC20 互斥（C-B1） | 依赖/规则/AC | 🔴 Blocking |
| grid-system.md | GridStateReader 需加 `get_placed_instances()`（C-W1） | 接口缺口 | ⚠️ Warning |
| member-sim.md | exercises 改用 `visit_length_modifier`（C-W2）；补 `member_completed_visit` 信号（C-W5）；AC#16 与放置边界（S-W1） | 公式/接口/规则 | ⚠️ Warning |
| satisfaction.md | 推-拉平衡密度敏感性需 playtest 多密度点验证（D-W1） | 设计/平衡 | ⚠️ Warning |
| equipment-catalog.md | 加 `use_duration_*` 字段并列 MemberSim 下游（C-W3）；修正 `crowd_pressure` 示例（C-I1） | 字段/依赖 | ⚠️ Warning |
| economy.md | 加 credit/earn 卖回接口并接管 `refund_rate`（C-W4）；MVP 现金 sink 预期对齐（D-W2） | 接口/设计 | ⚠️ Warning |
| navigation.md | 更正"Congestion 不调用我"，补列 Congestion 下游（C-W6）；平局决定性测试排期（S-W2） | 陈旧/风险 | ⚠️ Warning |
| congestion.md | 显式声明 `congestion_updated (10 Hz)` 发射接口（C-I2） | 接口命名 | ℹ️ Info |
| hud.md / time-system.md | 明确 `TICKS_PER_DAY` 归属（C-I3） | 归属缺口 | ℹ️ Info |

---

## 五、裁决：🔴 FAIL

存在 1 个 Blocking（**C-B1** relocate 归属 + Placement↔Selection 双向依赖 + AC20/AC4 互斥）。按评审规则，架构开始前必须解决。

**再跑架构前的必做项：**
1. **裁决 relocate/move 唯一归属方**，并同步改三处：Placement 依赖声明 + Core Rule 1、Selection Move 契约 + OQ4、AC20 与 AC4。这是唯一真正阻塞项。

其余 6 个一致性 Warning（C-W1~C-W6）多为已被 OQ/`propagate-design-change` 登记、但**当前文本仍实际不一致**的前向交接（缺字段/信号/接口），强烈建议在 `/create-architecture` 前一并落地对齐——否则架构会继承这些不一致。设计侧 D-W1/D-W2 与场景 S-W1/S-W2 不阻塞架构，但应进 playtest 协议与实现排期。

---

## 附：C-B1 解决记录（2026-07-19，同日）

裁决：**relocate/move 归 PlacementSystem**（方案 A）。已同步 6 处消解三点矛盾：
- **placement-system.md**：Core Rule 1 改写（放新件 + 重定位双职责）；新增 Core Rule 1a（`begin_relocate(instance_id)` 拿起清占用 / 同 id 重 commit / 取消恢复原位）；§C 依赖声明与依赖表由"non-dependency"改为"one-way caller (Selection→Placement)"；AC20 改为"恰好暴露 begin_relocate 一个入口"；新增 AC24（取消可逆）。
- **selection-system.md**：line 58 由"neither depends"改为单向 Hard 依赖（与依赖表对齐）；OQ4 标记 ✅ RESOLVED。
- AC20/AC4 互斥消解。**C-B1 不再阻塞架构。**

**这两个 GDD 仍标 Needs Revision** 的原因：Placement 尚有 S-W1（放置到会员格 vs AC#16 边界）、Selection 尚有 C-W4（Economy credit 路径）待处理。建议对这两份跑 `/design-review` 复核 relocate 细节并清掉残余 Warning 后再解除标记。

---

## 附：一致性收口记录（2026-07-19，Hermes 等效 /consistency-check）

基于本报告的 Warning/Info 清单，逐条核对当前 GDD 文本，对已解决的条目闭合登记：

| 编号 | 原判定 | 收口状态 | 说明 |
|---|---|---|---|
| C-B1 | 🔴 Blocking | ✅ 已解决（同日） | relocate 归 PlacementSystem，6 处对齐，见上方附录 |
| C-W2 | ⚠️ Warning | ✅ 已闭合 | member-sim.md exercises 公式由 `satisfaction_modifier` 改为 registry/satisfaction 已裁定的阻尼版 `visit_length_modifier[0.75,1.5]`，消除 ~modifier² 占用振荡风险 |
| C-W3 | ⚠️ Warning | ✅ 已闭合 | EquipmentCatalog #2 已加 `use_duration_mean/stddev/min/max_ticks` 四字段 + 规则7 加载期校验 + AC-U.1–4 + 列 MemberSim 下游；economy.md 旧引用 "don't exist yet" 同步为 ✅ grounded |
| C-I2 | ℹ️ Info | ✅ 已闭合 | congestion.md 下游消费者段新增 `congestion_updated (10 Hz)` 发射信号声明，与 Overlay #8 文档依赖对齐 |
| C-W1 / C-W4 / C-W5 / C-W6 / C-I1 / C-I3 | Warning/Info | ⏳ 未在本轮收口 | 多为已登记的 OQ/`propagate-design-change` 前向交接或缺口（GridStateReader 接口、Economy credit/refund 归属、member_completed_visit 信号、TICKS_PER_DAY 归属等），不阻塞架构但建议在 /create-architecture 前落地；其中 C-W6（navigation "Congestion 不调用我"）经核对 navigation.md 当前文本已无该过期断言 |

**本轮 /consistency-check 裁决：PASS（遗留项均为非阻塞前向交接，无新 🔴 CONFLICT）。** 设计层对账已收口至可进入竖切片/架构阶段。registry 新增 `equipment_use_duration` 条目（2026-07-19）。

