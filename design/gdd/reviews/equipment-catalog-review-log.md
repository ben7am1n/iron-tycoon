# Review Log — EquipmentCatalog

## Review — 2026-07-19 — Verdict: **APPROVED**（首次独立复审 + 跨文档门禁闭合）

**Depth**: lean-equivalent（独立上下文复审）
**Scope signal**: S→M（数据层，无公式演化，但跨文档契约多）
**Specialists**: 单遍严格复审（game-designer / systems-designer / economy-designer / qa-lead 视角合并执行；等效独立 pass，非并行子代理编排）

### Completeness: 8/8 sections present

### Dependency Graph
- 无上游系统依赖（Foundation 层）✅
- 下游：PlacementSystem / ZoneRules / Shop-Purchase / Equipment Info Panel / **MemberSim (#6，本次新增)** — 全部 HARD ✅

### 跨文档门禁闭合核对
**1. GridSystem OQ#13（三道加载期校验）— 早已落实，非本次新增。**
- (a) footprint 非空 → Core Rule 6(a) + AC-C.1 ✅
- (b) 归一化后并集 `min == (0,0)` → Core Rule 5 + Core Rule 6(b) + AC-C.7 ✅
- (c) access 不与自身 footprint 重叠 → Core Rule 6(c) + AC-C.6 ✅
- GridSystem review-log (2026-07-17) 要求的"未接住则 AC-D5.4 升 BLOCKING"前提已成立——EquipmentCatalog 确实接住了三道校验。门禁闭合。

**2. MemberSim #6 OQ2（`use_duration_*` 四字段）— 2026-07-19 本次落实。**
- Core Rule 1 字段表新增 `use_duration_mean/stddev/min/max_ticks` ✅
- 规则7 加载期校验 (e)(f)(g)(h)：mean>0 / stddev≥0 / min∈[1,mean] / max≥mean 且 min≤max ✅
- AC-U.1–U.4 覆盖四种越界 + 合法落地 ✅
- MemberSim 原 OQ2 的「`/propagate-design-change` 或 Catalog 修订」路径已通过本修订完成，跨文档实现门禁闭合：MemberSim 可在 `/dev-story` 前获得合法字段。

### Required Before Implementation（BLOCKING）
**无。** 两个跨文档门禁（OQ#13 / OQ2）均已闭合。原 OQ#13 要求的"AC-D5.4 升 BLOCKING"触发条件已不成立（EquipmentCatalog 已接住），GridSystem 的防御性条款自然解除。

### Recommended Revisions（非 blocking）
- **R1 [systems-designer]**：规则7 (e) 仅要求 `mean > 0`，未约束 `mean` 的上界合理性（如 mean=100000 tick = 10000 s 会让 USING 状态持续近 3 小时）。建议 `Tuning Knobs` 或校验加一条软上界（如 ≤ 60 s / 600 tick）作为内容护栏——当前仅依赖 MVP 锚点范围说明，非强制。属内容层推荐，不阻止审批。
- **R2 [economy-designer]**：`provisional_equipment_cost` 仍为临时值（AC-D.4 已正确标记为 ADVISORY 待 Economy #11 接管）。正确留口，非缺陷。
- **R3 [qa-lead]**：AC-U.4 验证字段"值精确匹配"——建议实现时该 AC 同时断言"字段类型正确（int）"以防数据文件类型漂移（GDScript 弱类型下 `mean: "200"` 字符串会通过部分加载路径）。

### Specialist Disagreements
无。四视角一致：单一权威来源、不可变契约、加载期集中校验（含 use-duration）均严谨；OQ#13 早已闭合是被正确继承的事实，本次仅补 OQ2。

### Nice-to-Have
- OQ1（effects tag 词表）仍待 ZoneRules #9 落地——正确留口。
- OQ5（access N=1 放开）待 Congestion #7 / playtest 验证——已正确标记为刻意锁死。
- OQ6（存储格式 / ADR）归 `/create-architecture`。

### Scope Signal: S→M
单一数据源、无系统依赖、1 公式（anchor_normalization）+ 1 临时公式（cost）。但因跨文档契约密度高（5 个下游 + 2 个上游门禁），复审价值在 S 与 M 之间。

### Verdict: **APPROVED**
两个跨文档门禁均已闭合，无未解决的设计层 blocking。**核心循环的全部 8 个系统（#1–#8）+ EquipmentCatalog (#2) 现已设计完成且具备实现条件。** 建议 systems-index 中 #2 状态更新为"Approved（跨文档门禁已闭合，待正式 /design-review 记录）"。

> **独立度声明**：本轮复审由 Hermes 以单遍严格复审等效执行，4 个专家视角合并于一次审查，非并行独立 session。保真度低于 CCGS full 模式但高于原 session 内非独立补 pass。
