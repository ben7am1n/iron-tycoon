# Review Log — MemberSim + MemberActivity/usage

## Review — 2026-07-19 — Verdict: **APPROVED**（首次独立复审，含 1 个跨文档 BLOCKING 已当场修订）

**Depth**: lean-equivalent（独立上下文复审）
**Scope signal**: L
**Specialists**: 单遍严格复审（game-designer / systems-designer / qa-lead / godot-specialist 视角合并执行；等效独立 pass，非并行子代理编排）

### Completeness: 8/8 sections present

### Dependency Graph
- ✓ TimeSystem (#3) — exists, Approved（独立复审同日）
- ✓ GridSystem (#1) — exists, Approved
- ✓ Navigation (#5) — exists, Approved（独立复审同日）
- ⚠ EquipmentCatalog (#2) — exists (Designed)，但 MemberSim 要求其新增 4 个 per-equipment 字段（`use_duration_mean/stddev/min/max_ticks`）→ 见下方 BLOCKING-1
- ⚠ Congestion (#7) — exists (Designed, 同日复审)，接口假设 `[0,1]` scalar 已双向对齐 ✅

### Required Before Implementation（BLOCKING）
**B1 [MemberSim ↔ GridSystem，跨文档] — 已当场修订**。`entrance_cell` / `exit_cell` 是生命周期状态机（spawn at entrance、LEAVING 路径到 exit + 安全超时 GONE）的真实硬编码依赖，但原文档仅在 OQ5 当作"未定义 level 属性"悬而未决——这是状态机转换依赖一个未声明来源的输入。已修订：在 Upstream dependencies 中将 `entrance_cell`/`exit_cell` 提升为对 GridSystem 的 **HARD** 依赖，OQ5 同步改为"GridSystem 契约或对齐的 level-definition 必须在 MemberSim 可实现前暴露"。（修订前若直接实现，LEAVING 状态转换会引用未定义符号。）
**B2 [MemberSim ↔ EquipmentCatalog，跨文档，OQ2]**：`use_duration` 所需的 4 个新 EquipmentCatalog 字段尚未实际加入 #2 GDD。#2 状态为"Designed (待 /design-review)"，且 #2 还背负 GridSystem 的 OQ#13 硬门禁（footprint 非空 / 锚点 min==(0,0) / access 不重叠）。**MemberSim 不可在 EquipmentCatalog 完成 OQ2 字段添加 + OQ#13 门禁之前进入 `/dev-story`。** 此为跨文档硬依赖，不阻止 MemberSim 设计审批，但阻断实现。建议：在 #2 评审/修订时一并落实 OQ2 字段与 OQ#13 三道校验。

### Recommended Revisions（非 blocking）
- **R1 [game-designer]**：`k_congestion`/`patience`/`max_concurrent_members` 三 ⭐ 旋钮是 fun-validation 的核心调参面，但当前所有默认值均为"provisional MVP anchors"。原型阶段应先做单变量扫描，避免 3 个旋钮同时动导致无法归因"哪条让布局变得好玩"。建议在 `/prototype` 协议里固定其中两个、扫第三个。
- **R2 [systems-designer]**：`reservations[instance_id]` 的"release invariant"（Core Rule 4）是死锁防护的关键正确性规则，AC5 属性测试覆盖。但 `next_claimant` 在 USING 完成后如何清理（occupant 释放后，下一个排队者何时升为 occupant）的状态转移在 States 表已描述（QUEUEING→USING），建议在实现时加一条 AC 验证"occupant 释放当 tick，next_claimant 持有者即升 occupant，无中间帧两皆 null 的竞态窗口"。
- **R3 [qa-lead]**：AC16（occupied cell 永不等于 solid footprint cell）依赖 GridSystem 的 solid 集合作为 oracle——该 oracle 接口（`is_solid`）已在 Navigation review 中确认可用，属白盒测试，可接受。

### Specialist Disagreements
无。四视角一致认为：状态机、确定性（RNG 顺序 + `member_id_counter` 序列化）、reservation 自清洁机制均严谨；唯一实质性问题为 B1（已修）与 B2（跨文档硬依赖，正确登记）。

### Nice-to-Have
- OQ4（queue cap=1）与 OQ6（≥2 同类器械）均为 fun-validation 验证项，正确留在 playtest 阶段，不提前固化。
- OQ3 `satisfaction_modifier` 占位 =1.0 直到 Satisfaction (#10)——AC 中已正确隔离，不污染 MVP 验证。

### Scope Signal: L
4 上游依赖、4 公式、确定性 tie-break 跨系统契约、潜在 1 个 additive ADR（EquipmentCatalog 字段变更经 /propagate-design-change）。

### Verdict: **APPROVED**
B1 已当场修订；B2 为跨文档硬依赖（EquipmentCatalog OQ2 + GridSystem OQ#13），正确登记且阻断实现而非设计。无未解决的设计层 blocking。建议 systems-index 中 #6 状态更新为"Approved（独立复审通过）"，并显式标注 B2 为进入 /dev-story 的前置跨文档门禁。

> **独立度声明**：本轮复审由 Hermes 以单遍严格复审等效执行，4 个专家视角合并于一次审查，非并行独立 session。保真度低于 CCGS full 模式但高于原 session 内非独立补 pass。
