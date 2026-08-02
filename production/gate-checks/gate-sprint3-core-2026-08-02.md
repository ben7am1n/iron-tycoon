# Gate Check: Sprint 3 门禁 — Core 层收官（placement-system + navigation）

**Date**: 2026-08-02
**Checked by**: gate-check skill（Kanban 门禁卡 t_fd3c84bc，default profile，run 99）
**Review mode**: lean（13/13 审查卡已完成，门禁做集成验证与收官核对）
**Target**: Sprint 3 Core 层收官 → 解锁 Feature 层（MemberSim 等）

---

## 一、13 张实现卡 + 13 张审查卡状态

| Story | 实现卡 | 审查卡 | 审查结论 | 审查提交 |
|-------|--------|--------|---------|---------|
| PL-001 | t_839a2497 | t_4eee0eb2 | PASS（91/0 standalone；全量 1880/0 ×2） | f87b051 |
| PL-002 | t_cd774c85 | t_b607aed0 | PASS（36/0 standalone；全量 1916/0 ×2） | 96d64f3 |
| PL-003 | t_b2d569e2 | t_5e677e22 | PASS（97/0 standalone；全量 1886/0；QA probe 33/0） | c27c37b |
| PL-004 | t_0325bcd0 | t_b4079d26 | PASS（20/0 standalone；全量 1809/0；QA probe 14/0） | 780324a |
| PL-005 | t_da82e5fc | t_ba89615d | PASS（88/0 standalone；全量 2121/0；probe 27/0） | 0f5235f |
| PL-006 | t_bc13525d | t_64b0bc8c | PASS（30/0 standalone；全量 1819/0；probe 27/0） | 53379c7 |
| PL-007 | t_b0807d3e | t_66d79824 | PASS（46/0 standalone；全量 2197/0；0 leak ×2） | d1e5250 |
| NV-001 | t_bc54d55e | t_4edd70c5 | PASS（14/0 standalone；全量 1803/0 ×2；probe 16/0） | 58f5e41 |
| NV-002 | t_09f3bc9a | t_9803c0fc | PASS（17/0 standalone；全量 1820/0；probe 19/0） | be3c05d |
| NV-003 | t_667873a9 | t_d6d21328 | PASS（78/0 standalone；全量 1867/0；probe 4/0） | 039aea3 |
| NV-004 | t_c79f6b8b | t_b7a30b63 | PASS（27/0 standalone；全量 1859/0 ×2；probe 27/0） | 1232df4+171dd5f |
| NV-005 | t_3cc35539 | t_fc2475d7 | PASS（19/0+13/0 standalone；全量 1821/0；24/24 子进程门禁） | 2b0ea50 |
| NV-006 | t_6877dd6c | t_e8d03231 | PASS（29/0 standalone；全量 1818/0；probe 33/0） | fe0ba3c |

**13/13 审查卡全部 done + PASS**（kanban.db task_runs 逐张核对；每张均独立 ff-only 合并后直接运行被审代码 + 独立 QA probe，非交接自报）。

## 二、集成树验证（main @ a181af3，门禁本人复跑）

```
TOTAL: 2394 passed, 0 failed
RESULT: PASSED
```

- `godot --headless --script tests/headless_runner.gd` → **2394 passed / 0 failed**，exit 0，**0 SCRIPT ERROR**
- 增长：Sprint 2 基线 1789 → 2394（**+605**），超过预期 2200+
- 13 个审查提交全部为 main 祖先（逐一 merge-base --is-ancestor 核对）
- 合并拓扑：
  - `804d0fb` merge PL-001..007 链（union 合并 placement_system.gd，PL-003 merge_note 已执行）
  - `c494268` merge Navigation union（NV-001/004/006 base）
  - `a20912e` / `877302e` / `a181af3` 分别 merge NV-002 / NV-003 / NV-005
- `tests/headless_runner.gd` TEST_FILES union 注册全部 14 个新测试文件（13 story + NV-005 tiebreak 子进程辅助），registry coverage 检查通过

## 三、story 状态核对

| Epic | Story | 文件 Status | QA Test Cases | Test Evidence |
|------|-------|-------------|--------------|---------------|
| placement-system | PL-001..007（7 张） | 全部 Complete | 全部已回填 | 全部已回填（drag_lifecycle 91 等，见 smoke 报告） |
| navigation | NV-001..006（6 张） | 全部 Complete | 全部已回填 | 全部已回填（path_query_edge_cases 78 等，见 smoke 报告） |

13/13 story 文件 `**Status**: Complete` + `Status: [x] Created and passing` 测试证据回填（git diff 逐文件核对，本门禁提交 45a18aa 落库）。

## 四、文档同步（提交 45a18aa）

- `production/sprint-status.yaml` — 13/13 done，completed 2026-08-02
- `production/epics/placement-system/EPIC.md` + `navigation/EPIC.md` — Status Complete，story 表 13/13 Complete
- `production/epics/index.md` — Core 层 2 epic 全绿（Complete）
- `production/sprints/sprint-3.md` — DoD 勾选（core_loop_test 记条件解锁）
- `production/qa/smoke-sprint-3-2026-08-02.md` — 新建，2394/0 PASS

## 五、core_loop_test 解锁判定：**条件解锁**

- Core 层 2 epic（PlacementSystem + Navigation）**已落地**，sprint-3.md DoD「Core 层 2 epic 全绿 → 解锁 Feature 层」达成
- `tests/integration/core_loop/core_loop_test.gd` **仍留在 PENDING_FILES**，原因：
  1. preload 仍指向 `res://../../prototypes/...`（res:// 无法向上跳，脚本从未加载成功）
  2. 依赖 MemberSim + Congestion **真实实现**（当前 src/systems/ 下为 SL-002 阶段标记的 Core-layer integration **stub**，非 Feature 层真实系统）
  3. 需按真实 API 重写断言（决定性、布局影响人流、access 阻塞规格保留自垂直切片）
- **解锁动作**：Feature 层落地（MemberSim/Congestion 真实实现）后，将 preload 指向 src/、重写断言、移入 TEST_FILES —— 与 sprint-3.md DoD 一致，记条件解锁而非阻塞项

## 六、非阻塞观察（转 Feature 层）

1. **SL-003 F1 待办**（转 Core→Feature）：save blob 存两份 RNG 状态，生效副本为 per-system rng_state；建议 MemberSim 真实落地时统一单一来源
2. **MemberSim/Congestion/Satisfaction/Economy 为 stub**（SL-002/SL-003 集成点），真实实现落在 Feature 层 epic —— 下一 sprint 范围
3. Sprint 3 编排未单独产出 `qa-plan-sprint-3.md` 文件；QA 用例内嵌于各 story 文件 QA Test Cases 节，13 张 review 卡承担逐 story QA sign-off（全 PASS）—— DoD 对应项按此口径勾选

## 七、Verdict

**PASS** — Sprint 3 Core 层收官通过。13/13 story 实现并独立审查 PASS，集成树全量测试 2394/0 全绿（1789 → +605），实现全部在 main，文档全部同步。core_loop_test 记**条件解锁**（Feature 层落地后启用）。Core 层 2 epic 全绿 → 解锁 Feature 层（MemberSim 等）。

Chain-of-Verification：① 全量测试为本门禁独立复跑（非合并方自报），2394/0 实测；② 13 个审查提交逐一 merge-base 核对在 main；③ story 状态 13/13 逐文件 grep 复核 Complete；④ TEST_FILES union 逐一核对 14 个新测试文件；⑤ 审查卡 PASS 从 kanban.db task_runs 逐张核对 summary。verdict 不变。
