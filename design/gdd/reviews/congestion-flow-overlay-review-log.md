# Review Log — Congestion/Flow Overlay + Placement Feedback

## Review — 2026-07-19 — Verdict: **APPROVED**（首次独立复审，含 1 个跨文档 BLOCKING 已当场修订）

**Depth**: lean-equivalent（独立上下文复审）
**Scope signal**: M
**Specialists**: 单遍严格复审（game-designer / ux-designer / technical-artist / qa-lead 视角合并执行；等效独立 pass，非并行子代理编排）

### Completeness: 8/8 sections present

### Dependency Graph
- ✓ Congestion (#7) — exists, Approved（同日复审）；三输出 + `congestion_updated` 信号已对齐 ✅
- ✓ PlacementSystem (#4) — exists, Approved（同日复审）；`placement_rejected` 信号 + ghost tint 已对齐 ✅
- ✓ GridSystem (#1) — exists, Approved；cell→world 映射（via `grid_world_conversion`/`world_to_grid`）
- ⚠ HUD (#16) / Settings & Accessibility (#22) — soft deps，尚未设计；不影响本 GDD 审批

### Required Before Implementation（BLOCKING）
**B1 [Overlay ↔ GridSystem OQ#9 + Congestion OQ1，跨文档] — 已当场修订**。GridSystem 故意在放置时不警告"器械被围死"，把"让玩家看见为何机器闲置"的责任交给本 overlay（OQ#9）。原文档 Core Rule 5 + 状态表描述的是"access_reachable → false 时 fade-in"，存在可读歧义：若玩家在上一 session 围死了一台机器，新 scene 进入时若无 intervening `grid_changed`，图标可能不立即出现——这会让 OQ#9 的"默认可见"承诺出现一个真实信任缺口（与 GridSystem review-log 指出的同一类风险同形）。已修订：Core Rule 5 显式写死"**scene load / save load 即读取当前 `access_reachable` 集合，对所有 `false` 项立即显示 barricade icon，无事件门**"；状态表新增对应行；明确该规则不被"后续编辑 fade-in"行放宽。**修订后 OQ#9 信任链闭合。**

### Recommended Revisions（非 blocking）
- **R1 [technical-artist]**：`ImageTexture` + `CanvasItem` shader 的 bilinear 采样（Core Rule 2）是 4.7.1 下未验证项，但已正确降级为 OQ1（`DrawableTexture2D` 明确不用，MVP 用 ImageTexture+shader）。建议在 `/create-architecture` 立 ADR（OQ2 已登记）。
- **R2 [ux-designer]**：heatmap 默认 OFF（Tuning Knobs）正确——ON at boot 会读成"出事了"违背 Pillar 2。但首次 toggle 的 one-time tip（OQ4 文案待定）与 hover legend 应走 `/ux-design`（UX Flag 已正确标注）。
- **R3 [qa-lead]**：AC9–AC12 数据绑定项可自动化，但 AC9 的"texels match field per-cell"需白盒访问 heatmap Image——实现时该 AC 应置于 unit/integration 层，非纯 manual。AC1/2/6/8（无 flash / 默认不可达可见 / tooltip 文案）仍为 ADVISORY manual walkthrough，符合 Visual/UI story 标准。

### Specialist Disagreements
无。四视角一致：三层可见性优先级（access-blocked 永远最上 > ghost > glyph > heatmap 最软）正确体现 Pillar 2/3；heatmap 为主、glyph 为次（playtest 证据已落地）；shape-first 满足 colorblind。唯一实质问题为 B1（已修）。

### Nice-to-Have
- OQ3（smoothstep cutoffs 调参）与 Congestion 的 α/w_occ/w_dense 同为 fun-validation 视觉旋钮，建议原型阶段联合调。
- 多机器同时围死时无聚合"N blocked"警报（Edge Case）——正确符合 Pillar 2，保留。

### Scope Signal: M
3 hard 上游 + 2 soft，2 公式（color mapping），无新 ADR（复用 OQ2 待立）。

### Verdict: **APPROVED**
B1 已当场修订，OQ#9 信任链闭合。无未解决的设计层 blocking。建议 systems-index 中 #8 状态更新为"Approved（独立复审通过）"，并标注其为 fun-validation 里程碑的终点系统——#3–#8 全部 Approved 后，核心循环已具备端到端可原型条件。

> **独立度声明**：本轮复审由 Hermes 以单遍严格复审等效执行，4 个专家视角合并于一次审查，非并行独立 session。保真度低于 CCGS full 模式但高于原 session 内非独立补 pass。
