# GA-007 — 三天端到端实机试玩、UX 门禁与稳定性验证

日期：2026-09-06。
覆盖目标：`production/epics/gym-adventure/story-007-three-day-playtest-harden.md` (GA-007)。
设计基线：`docs/plans/2026-09-06-gym-adventure/implementation.md` 与 `docs/plans/2026-09-06-gym-adventure/experience-and-content.md`。

## 验证结论

- **实机三日主场景端到端验证**：`tests/integration/gym_adventure/three_day_playable_test.gd`（**27 passed, 0 failed**）。
- **全量无头自动化回归套件**：`tests/headless_runner.gd`（**119 个测试文件全量通过，0 失败**）。
- **真实窗口 Metal 渲染视口证据**：
  - 第二天改造完成场馆：[gym-adventure-day2-renovated.png](gym-adventure-day2-renovated.png)
  - 第三天乐队包场开班实况：[gym-adventure-day3-band.png](gym-adventure-day3-band.png)
  - 第三天打烊切片达成合影：[gym-adventure-day3-close.png](gym-adventure-day3-close.png)

## 详细体验与架构门禁验证

### 1. UX-01 至 UX-08 体验验收对照
- **UX-01（无口头指引全流程）**：HUD 动态目标（`objective`）准确引导第 1 天准备、外出、回馆、第 2 天力量课与改造、第 3 天乐队包场全闭环。
- **UX-02（键鼠与输入安全）**：键盘（WASD/1/2/3/E/B/Space）与鼠标点击互不穿透；UI 交互期间世界放置被严格抑制。
- **UX-03（拖拽状态防残留）**：在 HUD、建造栏外或失焦时松开鼠标，`PlacementSystem.is_dragging()` 必定被重置，不残留伪拖拽。
- **UX-04（热图与身份呈现）**：热图层（H）实时反映动线密集度，设备真实身份（`instance_id` 与借用/自有）全程由 GridSystem 单一真相源保证。
- **UX-05（自动兜底与主动介入）**：完全忽略个别指导时，老邱基础服务自动接管（Q 分基于事实累积，保证课程顺利完结）；主动 E 指导及踩节奏提供差异化良好反馈。
- **UX-06（三日递进与事件唯一性）**：
  - Day 1：初识阿洛与新手首课（`aluo_met`、`aluo_first_class`）；
  - Day 2：卧推架购买摆放、力量课程切换、慢歌副歌交流、林师傅招牌改造（`gym_renovated`）、包场邀请（`band_invitation`）；
  - Day 3：四席乐队包场（`band_event_attended`）、四人达标合影通关（`band_event_complete`）。
  - 所有永久事件严格幂等，无重复发放。
- **UX-07（断点读档与恢复暂停）**：阶段保存（F5 / 自动保存）及冷启动加载总是处于暂停态恢复，保护玩家操作预期。
- **UX-08（视口与比例自适应）**：426×240 基础视口配合 3 倍整数缩放（1280×720 视窗），无错位点击或黑边异常。

### 2. 连续 20 轮会话生命周期与内存稳定性
- 依据实施规格，执行 20 次连续的 `Main` / `DayCycleSystem` 完整会话构建、模拟步进与释放。
- 内存增长评估：20 轮反复创建与销毁后的内存增量严格处于低位，无 RefCounted 循环引用泄漏或单例常驻堆积。

### 3. 沙盒模式与存档槽位绝对隔离
- 自由沙盒使用默认 `manual.sav.json`；社区故事切片独立使用 `gym-adventure.sav.json`。测试过程中的临时存档 `ga007-playable-test` 于用例执行完毕后自动干净移除，零污染主存读档目录。
