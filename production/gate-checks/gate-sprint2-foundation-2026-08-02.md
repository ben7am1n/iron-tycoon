# Gate Check: Sprint 2 门禁 — Foundation 收官（time-system + save-load）

**Date**: 2026-08-02
**Checked by**: gate-check skill（Kanban 门禁卡 t_e320fc1e，default profile）
**Review mode**: lean（8/8 审查卡已完成，门禁做集成验证与收官核对）
**Target**: Sprint 2 Foundation 收官 → 解锁 Core 层（placement-system + navigation）

---

## 一、8 张实现卡 + 8 张审查卡状态

| 卡 | 实现卡 | 审查卡 | 审查结论 | 审查提交 |
|----|--------|--------|---------|---------|
| TS-001 | t_2738fa27 | t_ae5180db | PASS（1090/0，独立 probe 50/0） | e982354 |
| TS-002 | t_8eaf3b04 | t_4fd67170 | PASS（1154/0，独立 probe 29/0） | 2228742 |
| TS-003 | t_82f6ed2a | t_abd7e6d2 | PASS（1130/0，Python 参考交叉验证） | 179746b |
| TS-004 | t_2be5eb79 | t_90823b5c | PASS（1373/0，独立 probe 109/0） | a718604 |
| SL-001 | t_298de70c | t_69c22cbe | PASS（1481/0，独立 probe 51/0） | ce4712e |
| SL-002 | t_0d268e62 | t_95f04da3 | PASS（1568/0，独立 probe 46/0） | 9a5d90e |
| SL-003 | t_dda0ee12 | t_6f596902 | PASS（1720/0，独立 probe 77/0） | 3912f53 |
| SL-004 | t_1bc9daa9 + t_fc9c20ca(修复) | t_d897f1ac | PASS（1550/0，独立 probe 47/0，false-green 已修复） | aeeb830 + fdc8355 |

**8/8 审查卡全部 PASS**，全部采用「ff-only 合并进审查 worktree → 直接运行被审代码 + 独立编写 QA probe」模式，非自报。

## 二、集成验证（本门禁核心工作）

**拓扑**：主链 e982354→179746b→2228742→a9b67ba→a718604→ce4712e（TS-001..SL-001），随后分叉为两个兄弟分支：SL-002/003（9a5d90e→3912f53）与 SL-004（aeeb830→fdc8355）。两分支均独立审查通过，但**各自验证的是未合并的树**——门禁负责把两兄弟合回 main 并验证集成结果。

**合并**：
- `02bd970` merge mainline（3912f53，TS-001..SL-003）— 干净
- `04eba3c` merge SL-004（fdc8355）— 2 处冲突全部为**加性合并**：
  - `src/systems/save_load.gd`：保留 Story 002 两阶段 load（load/_validate_all）+ Story 004 文件 I/O（save_to_file/load_from_file/load_save）；SL-004 的 `has_method("load")` 守卫动态分发现在正确解析到真实 load()（设计意图）
  - `tests/headless_runner.gd`：TEST_FILES 并集 — load_orchestration + roundtrip（mainline）与 file_io_version（SL-004）全部注册
- 附带：tick_accumulator_test.gd SPEED_OPTIONS `str()` 修复（SL-004F 审查修复）

**全量测试（集成树 main@04eba3c）**：**1789 passed / 0 failed**，exit 0，0 SCRIPT ERROR。
139 条 ERROR 输出全部为有意触发的负向守卫探针（GridSystem 冻结、SimSystem 二次 init/before-init），是断言的一部分。
Sprint 1 基线 1040 → 1789（+749），超过门禁预期 1500+。

**门禁外提交**：`7a69b8f`（TS-004 impl worktree 上的 AC10 QA-literal blob 测试钉，+5 断言）未在审查线上，未并入 main——非阻塞观察项，记录待后续决定是否 cherry-pick。

## 三、story 状态核对

| Story | 文件 | 状态 | 测试证据 |
|-------|------|------|---------|
| TS-001 | time-system/story-001 | Complete | orchestrator_tick_dispatch_test.gd — 50 |
| TS-002 | time-system/story-002 | Complete | tick_accumulator_test.gd — 65 |
| TS-003 | time-system/story-003 | Complete | seeded_rng_substream_test.gd (60) + lsr_helper_test.gd (30) |
| TS-004 | time-system/story-004 | Complete | time_serialization_test.gd — 129 |
| SL-001 | save-load/story-001 | Complete | saveblob_composition_test.gd — 108 |
| SL-002 | save-load/story-002 | Complete | load_orchestration_test.gd — 87 |
| SL-003 | save-load/story-003 | Complete | roundtrip_determinism_test.gd — 152 |
| SL-004 | save-load/story-004 | Complete | file_io_version_test.gd — 68 |

8/8 story 文件已更新为 **Status: Complete** + 测试证据回填（本门禁负责收官核对，与各审查卡观察一致）。

## 四、文档同步

- `production/sprint-status.yaml` — 8/8 done，completed 2026-08-02
- `production/epics/time-system/EPIC.md` + `save-load/EPIC.md` — Status Complete，story 表 4/4 Complete
- `production/epics/index.md` — Foundation 层 4 epic 全绿（grid-system、equipment-catalog、time-system、save-load）
- `production/sprints/sprint-2.md` — DoD 10/10 勾选
- `production/qa/smoke-sprint-2-2026-08-02.md` — 新建，1789/0 PASS

## 五、非阻塞观察（转 Core 层）

1. **SL-003 发现 F1**：save blob 存两份 RNG 状态（time_system.per_system_rng_states + 各系统自身 rng_state），生效副本为后者。合法存档一致，AC2 确定性不受影响；建议 Core 层 MemberSim 真实落地时统一单一来源。
2. **stub 集成点**：MemberSim/Congestion/Satisfaction/Economy 的 serialize/deserialize 为 stub（SL-003/004 测试使用），真实实现落在 Core 层 epic。
3. **7a69b8f**：TS-004 的 AC10 测试钉未并入 main（非审查线提交），可后续 cherry-pick。
4. 全量 ERROR 输出 139 条为负向守卫探针，属预期（与各审查卡口径一致：0 SCRIPT ERROR 即干净）。

## 六、Verdict

**PASS** — Sprint 2 Foundation 收官通过。8/8 story 实现并独立审查，集成树全量测试 1789/0 全绿，文档全部同步。Foundation 层 4 epic 全绿 → 解锁 Core 层（placement-system + navigation，epic 已就绪、状态 Ready）。

Chain-of-Verification: 4 项挑战核查 —— ① 集成树测试为实测（非合并方自报），1789/0；② 冲突 2 处逐一审查确认加性（load 侧 + file I/O 侧功能均在），无丢失；③ story 状态 8/8 逐文件 grep 复核 Complete；④ ERROR 输出 139 条逐条归类为守卫探针，0 SCRIPT ERROR。verdict 不变。
