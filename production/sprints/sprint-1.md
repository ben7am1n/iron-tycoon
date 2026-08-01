# Sprint 1 — 2026-07-31 to 2026-08-13

## Sprint Goal
吃完 GridSystem 剩余 7 个 story（002–008），让空间真相的唯一所有者——GridSystem——完整收尾，解锁 can_place/commit/序列化/信号全链路，为后续 Navigation、PlacementSystem 及测试解隔离打底。

## Capacity
- Total days: 10（2 周，单人 Claude Code 开发节奏）
- Buffer (20%): 2 days
- Available: 8 days

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

**Must Have 合计：6.0 days**（8 天可用，留 2 天余量给 code-review 返工）

### Should Have
（本 sprint 无 — 范围决策为"仅 GridSystem"，不并行 equipment-catalog）

### Nice to Have
（无）

## Carryover from Previous Sprint
（无 — Sprint 1 是本项目第一个正式 sprint；Story 001 已在 sprint 追踪建立前完成，不计入本表）

## Risks
| Risk | Probability | Impact | Mitigation |
|------|------------|--------|------------|
| Story 003/005/006/007/008 均为 MEDIUM 风险（旋转数学、reverse index、快照隔离、序列化、信号/性能） | Medium | Medium | 每个 story 已嵌入 ADR 指导 + QA 用例；严格走 /dev-story → /code-review → /story-done 闭环 |
| Story 006 触碰 Story 001 遗留技术债（GridSystem 应继承 GridStateReader 而非 SimSystem） | Medium | Low | story-006 文件已把此项列为可顺带解决的目标，非意外范围蔓延 |
| 线性依赖链（002→003→004→005→006→007→008）—— 任一环节卡住会连锁阻塞后续全部 story | Low | High | 按序实现，不并行开工多个 story；LOW 风险的 002/004 先行验证节奏 |
| `core_smoke_test.gd` 本 sprint 结束后仍无法解隔离（还差 time-system story-003 的 SeededRNG） | High（已知） | Low | 已在 tech-debt-register 记录为预期状态，不是本 sprint 缺陷 |

## Dependencies on External Factors
- 无外部依赖（单人开发，无跨团队阻塞）
- CI 已在 `ben7am1n/iron-tycoon` 验证可用（run 30552386098），本 sprint 的每次提交都会真实跑测试门禁

## Definition of Done for this Sprint
- [ ] All Must Have tasks completed
- [ ] All tasks pass acceptance criteria
- [ ] QA plan exists (`production/qa/qa-plan-sprint-1.md`)
- [ ] All Logic/Integration stories have passing unit/integration tests
- [ ] Smoke check passed (`/smoke-check sprint`)
- [ ] QA sign-off report: APPROVED or APPROVED WITH CONDITIONS (`/team-qa sprint`)
- [ ] No S1 or S2 bugs in delivered features
- [ ] Design documents updated for any deviations
- [ ] Code reviewed and merged

## Gate Log
- **PR-SPRINT (producer feasibility)**: skipped — review mode `lean` (not a phase gate)
- **QA Plan Gate**: no QA plan found at sprint creation time — user chose to run `/qa-plan sprint` next, before implementation begins

> **Scope check:** If this sprint includes stories added beyond the original epic scope, run `/scope-check grid-system` to detect scope creep before implementation begins.
