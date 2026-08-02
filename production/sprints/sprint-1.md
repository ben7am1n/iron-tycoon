# Sprint 1 — 2026-07-31 to 2026-08-13

## Sprint Goal
吃完 GridSystem 剩余 7 个 story（002–008），让空间真相的唯一所有者——GridSystem——完整收尾，解锁 can_place/commit/序列化/信号全链路，为后续 Navigation、PlacementSystem 及测试解隔离打底。

> **2026-08-02 范围变更（已记录）**：mid-sprint 追加 equipment-catalog epic 全部 7 个 story（EC-001..007）进入本 sprint 范围。最终交付 14 story（GRID-002..008 + EC-001..007），全部 Complete。详见下方 [Scope Change Record](#scope-change-record-2026-08-02)。

## Capacity
- Total days: 10（2 周，单人 Claude Code 开发节奏）
- Buffer (20%): 2 days
- Available: 8 days
- **实际执行**：原计划 Must Have 6.0 days；mid-sprint 追加 EC 4.5 days → 计划总量 10.5 days（超出可用 8 days）。实际于 2026-08-02 全部完成（sprint 第 3 天），节奏吸收超配，未延期。

## Tasks

### Must Have (Critical Path)
| ID | Task | Agent/Owner | Est. Days | Dependencies | Acceptance Criteria |
|----|------|-------------|-----------|-------------|-------------------|
| GRID-002 | Solidity Formula and Coordinate Conversion | Sisyphus (/dev-story) | 0.5 | Story 001 (Complete) | 8 AC — is_solid 公式、access_ids 不参与、越界=solid、坐标往返一致 |
| GRID-003 | Rotation Transform and Declared Bounds | Sisyphus (/dev-story) | 1.0 | Story 001 | 旋转变换正确性、TransformedFootprint 复合体、declared_bounds |
| GRID-004 | Placement Validation — can_place | Sisyphus (/dev-story) | 0.5 | Story 002, 003 | can_place 校验管线，含越界/重叠/access 冲突 |
| GRID-005 | Commit, Clear, and Reverse Index | Sisyphus (/dev-story) | 1.0 | Story 002, 003, 004 | commit/clear 写入、reverse index、grid_changed 信号 |
| GRID-006 | GridStateReader and GridSnapshot | Sisyphus (/dev-story) | 1.0 | Story 002, 005 | 投机快照隔离；顺带解决 tech-debt #1（GridSystem 应继承 GridStateReader） |
| GRID-007 | Serialization and Deserialization | Sisyphus (/dev-story) | 1.0 | Story 005, 006 | serialize/deserialize 往返一致，为 SaveLoad epic 打底 |
| GRID-008 | Signals, Integration, and Performance | Sisyphus (/dev-story) | 1.0 | Story 002, 005, 006, 007 | 信号 arity/次数正确；Tick dispatch ≤0.1ms guardrail |

**Must Have 合计（原计划）：6.0 days**（8 天可用，留 2 天余量给 code-review 返工）

#### Mid-Sprint Added (2026-08-02) — equipment-catalog EC-001..007
| ID | Task | Agent/Owner | Est. Days | Dependencies | Acceptance Criteria |
|----|------|-------------|-----------|-------------|-------------------|
| EC-001 | EquipmentDef Data Model and Catalog Container | Sisyphus (/dev-story) | 0.5 | — | EquipmentDef 不可变 record、catalog 容器、冻结语义 |
| EC-002 | JSON Loading and Anchor Normalization | Sisyphus (/dev-story) | 0.5 | EC-001 | .catalog.json 加载、anchor 归一到 min==(0,0) |
| EC-003 | Footprint Shape and Access Cell Validation | Sisyphus (/dev-story) | 0.5 | EC-001 | footprint 非空、access∩footprint 空、access 数==1 |
| EC-004 | Validation Pipeline, strict_mode, and Duplicate ID Detection | Sisyphus (/dev-story) | 1.0 | EC-002, 003 | strict_mode 注入、重复 ID 检测、LoadError |
| EC-005 | Use-Duration Field Validation | Sisyphus (/dev-story) | 0.5 | EC-004 | use_duration_mean/stddev/min/max 范围校验 |
| EC-006 | Provisional Cost Formula | Sisyphus (/dev-story) | 0.5 | EC-004 | base_cost + tier_step×(area−1)；MVP 200/350/650 |
| EC-007 | Edge Cases — Empty Catalog, Unlock Requirements, and Cost Boundary | Sisyphus (/dev-story) | 1.0 | EC-004, 005, 006 | 空 catalog、解锁需求、成本边界 |

**追加合计：4.5 days** — 全部于 2026-08-02 完成（见 [Scope Change Record](#scope-change-record-2026-08-02)）

### Should Have
原计划：本 sprint 无 — 范围决策为「仅 GridSystem，不并行 equipment-catalog」。

**2026-08-02 范围变更后**：该决策被推翻 — equipment-catalog 7 个 story 以 Must Have 身份 mid-sprint 追加（见上方表格与下方 Scope Change Record）。sprint 结束时无遗留 Should Have 项。

### Nice to Have
（无）

## Scope Change Record (2026-08-02)

| 字段 | 内容 |
|------|------|
| **变更日期** | 2026-08-02（sprint 第 3 天，mid-sprint） |
| **决策人** | 用户（producer 认可，无阻塞项） |
| **变更内容** | 追加 equipment-catalog epic 全部 7 个 story（EC-001..007，Foundation 层、与 GridSystem 无耦合）进入 Sprint 1 范围 |
| **原范围** | 仅 GridSystem 002–008（7 story，6.0 days） |
| **新范围** | GridSystem 002–008 + EC-001..007（14 story，10.5 days 计划量） |
| **决策理由** | GridSystem 收尾节奏超前（002–008 于 07-31→08-02 完成），提前释放容量；equipment-catalog 是下一个无耦合的 Foundation epic，提前完成可解锁 Shop/Placement 下游 |
| **容量影响** | 计划总量 6.0 → 10.5 days（+75%），超出 8 days 可用量；实际 08-02 全部完成，节奏吸收超配，sprint 窗口（至 08-13）远未用尽 |
| **QA 影响** | QA 计划扩展覆盖 14 story（`production/qa/qa-plan-sprint-1-2026-08-02.md`）；smoke 1040/1040 PASS |
| **完成状态** | 14/14 story Complete（`production/sprint-status.yaml` 属实）；equipment-catalog epic → Complete；QA 签核 APPROVED |

**教训（producer 关注点）**：mid-sprint 追加应在决策当日同步更新 sprint-1.md 与 sprint-status.yaml。本次已事后补记（本文件 + sprint-status.yaml 均已同步至 14/14 done），后续 sprint 以此为纪律基线。

## Carryover from Previous Sprint
（无 — Sprint 1 是本项目第一个正式 sprint；Story 001 已在 sprint 追踪建立前完成，不计入本表）

## Risks
| Risk | Probability | Impact | Mitigation |
|------|------------|--------|------------|
| Story 003/005/006/007/008 均为 MEDIUM 风险（旋转数学、reverse index、快照隔离、序列化、信号/性能） | Medium | Medium | 每个 story 已嵌入 ADR 指导 + QA 用例；严格走 /dev-story → /code-review → /story-done 闭环 |
| Story 006 触碰 Story 001 遗留技术债（GridSystem 应继承 GridStateReader 而非 SimSystem） | Medium | Low | story-006 文件已把此项列为可顺带解决的目标，非意外范围蔓延 |
| 线性依赖链（002→003→004→005→006→007→008）—— 任一环节卡住会连锁阻塞后续全部 story | Low | High | 按序实现，不并行开工多个 story；LOW 风险的 002/004 先行验证节奏 |
| `core_smoke_test.gd` 本 sprint 结束后仍无法解隔离（还差 time-system story-003 的 SeededRNG） | High（已知） | Low | 已在 tech-debt-register 记录为预期状态，不是本 sprint 缺陷 |
| **（新增）mid-sprint 追加 EC 4.5 days 使计划量超可用容量** | Medium | Medium | 依赖 GridSystem 超前完成释放的容量吸收；未吸收则 EC 降级为下一 sprint |

## Dependencies on External Factors
- 无外部依赖（单人开发，无跨团队阻塞）
- CI 已在 `ben7am1n/iron-tycoon` 验证可用（run 30552386098），本 sprint 的每次提交都会真实跑测试门禁

## Definition of Done for this Sprint
- [x] All Must Have tasks completed — **14/14**（GRID-002..008 + EC-001..007，`production/sprint-status.yaml`）
- [x] All tasks pass acceptance criteria — QA 签核 14/14 PASS，100% test-traceable
- [x] QA plan exists (`production/qa/qa-plan-sprint-1.md`) — 07-31 初版 + 08-02 扩展至 14 story 版
- [x] All Logic/Integration stories have passing unit/integration tests — smoke 14/14 COVERED，0 missing
- [x] Smoke check passed (`/smoke-check sprint`) — `production/qa/smoke-2026-08-02.md`：1040/1040 PASS
- [x] QA sign-off report: APPROVED or APPROVED WITH CONDITIONS (`/team-qa sprint`) — `production/qa/qa-signoff-sprint-1-2026-08-02.md`：**APPROVED**
- [x] No S1 or S2 bugs in delivered features — 0 bugs 登记（`production/qa/bugs/` 为空）
- [x] Design documents updated for any deviations — EC epic → Complete；sprint-1.md 本文件补记范围变更；sprint-status.yaml 同步 14/14 done
- [x] Code reviewed and merged — 全部 14 story 经 /dev-story → /code-review → /story-done 闭环，合并入 integration 分支

## Gate Log
- **PR-SPRINT (producer feasibility)**: skipped — review mode `lean` (not a phase gate)
- **QA Plan Gate**: no QA plan found at sprint creation time — user chose to run `/qa-plan sprint` next, before implementation begins → **已解决**：`production/qa/qa-plan-sprint-1-2026-07-31.md` 同日创建；08-02 扩展为 14 story 版（`qa-plan-sprint-1-2026-08-02.md`）
- **Mid-Sprint Scope Change (2026-08-02)**: equipment-catalog EC-001..007 追加进 Sprint 1 范围 — 用户决策，producer 认可，已记录于本文件 [Scope Change Record](#scope-change-record-2026-08-02)；QA 计划同步扩展
- **Smoke Check (2026-08-02)**: PASS — 1040/1040（`production/qa/smoke-2026-08-02.md`）
- **QA Sign-Off (2026-08-02)**: APPROVED（`production/qa/qa-signoff-sprint-1-2026-08-02.md`）；附带 1 项非阻塞跟踪（sprint-status.yaml 同步）— 已于本文件更新时一并落实

> **Scope check:** 本 sprint 包含超出原 epic 范围的 mid-sprint 追加（equipment-catalog 7 story），变更已由用户决策并记录于上方 Scope Change Record。按 `/scope-check` 度量：原 7 → 新 14 items（+100%），属超阈值变更；因决策明确、容量被超前节奏吸收、QA 全绿，判定为**已记录的有意识扩展（非失控 creep）**。
