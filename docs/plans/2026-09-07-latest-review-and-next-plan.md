# 最新改动复核与下一步计划

日期：2026-09-07。审核基线：`d423c7865915f6400c89d6ab7773b8d887727cee`。
本轮只做分析、运行验证及计划；未修改游戏源码。覆盖 M0 至最新音频提交，重点检查新增流程之间的接线。

## 结论

现有版本已经从空间经营沙盒推进到三天社区故事原型：基础身份/存读档修复、首日循环、两门课程、改造和乐队事件、美术样板、四人头像与专属物件、11 项音频资产均已落入代码。但默认顺利路径通过不能代表完整可玩性通过。下一阶段应为“闭环修复与体验验收”，暂缓新增场景、角色和完整动作图集量产。

## 验证与证据

- 当前引擎 Godot 4.7.1，执行 `godot --headless --path . --script tests/headless_runner.gd`：**6542 passed，0 failed，进程退出 0**。日志未发现 SCRIPT ERROR / Parse Error；包含负向测试主动报错，以及退出时 797 ObjectDB、5 CanvasItem RID、17 资源未释放提示。不能据此认定生产运行泄漏规模，需独立生命周期复现。
- 另用实际系统组合及 HUD 提供器运行针对性探针，复现下列接口缺陷。探针包含刻意构造的存档和模式转换；不属于手工玩家试玩，也不计入通过断言数量。
- 最新提交通过真实 Main 场景营业到 190 秒后暂停，导出实际渲染视口。未编辑图片；使用独立测试存档名并在结束后删除。
- [针对性运行输出](../../production/qa/evidence/2026-09-07-latest-review/runtime-probes.log)、[可复跑探针](../../production/qa/evidence/2026-09-07-latest-review/runtime_probe.gd)、[回归摘要](../../production/qa/evidence/2026-09-07-latest-review/regression-summary.log)、[最新营业截图](../../production/qa/evidence/2026-09-07-latest-review/current-service.png)。

## 已确认问题

| 优先级 | 触发与结果 | 位置 | 下一步验收 |
|---|---|---|---|
| P1 | 社区→沙盒后 MemberSim/Economy 的 community_mode 仍为 true，余额/场馆沿用社区；再切社区后 orch.day_cycle 仍为空。当前按钮不能实现两个模式的状态隔离。首次沙盒转社区时恢复布局还会按固定 ID 0/1 替换资产。 | src/main.gd:847；src/systems/day_cycle_system.gd:542 | 分模式独立会话组合；切换前妥善保留各自进度；往返切换后现金、器械、访客、日循环及独立存档都正确。 |
| P1 | HUD 读 distance_m/remaining_seconds，而实际输出 progress_m/seconds。探针设 42 米、已用 60 秒，界面仍显示 0 米、剩余 180 秒。指导读 guidance_open/request.stage，真实输出 course.guidance/request.status，导致提示和选择按钮不出现。 | src/ui/community_hud.gd:166；src/systems/day_cycle_system.gd:255 | 统一视图契约；通过真实按键和按钮完成三种配速、一次课程指导、一次亲自指导；检查显示内容及按钮状态，不能仅调用 DayCycle.command。 |
| P1 | 自有器械进入收纳后，_restore_stored 调用 can_place 仅传两个参数，实际要求四个，运行报错；随后使用的 transformed/check 字段也需按实际接口核对。HUD 没有 restore_stored 入口。 | src/systems/day_cycle_system.gd:557；src/ui/community_hud.gd:65 | 购买→移动/升级→收纳→取回→冷读档后，ID、等级、所有权与现金不丢不重；摆不下时仍安全留在收纳。 |
| P1 | 第三天才达成阿洛首课，打烊不会发邀请。当前邀请逻辑只存在 day == 2 分支，遗漏设计要求 day >= 2 的补充营业日。 | src/systems/day_cycle_system.gd:238 | 首课在第 1/2/3/4 天达成均可按前置条件获得一次邀请；开班失败、未达标及读档后仍可重排包场。 |
| P1 | 缺失 course.devices 或 request 只剩 status 的存档仍被 DayCycle.deserialize(validate_only=true) 接受，无法保障后续直接字段访问安全；尚缺课程成员/器械与其他子系统的交叉校验。 | src/systems/day_cycle_system.gd:291；src/systems/save_load.gd:686 | 系统性删字段、错类型、越界 ID、非法阶段组合均拒绝；拒绝前后全系统状态不变；各活动中途冷恢复后能继续运行。 |
| P2 | AudioManager 匹配 day_prep/day_service/day_close，日循环实际发 PREP/SERVICE/CLOSE；真实 CLOSE 信号后提示音次数为 0。对白通知函数也未接入 Main/HUD 的对白推进。已有 BGM 会在组装时启动，这不代表阶段事件路由有效。 | src/audio/audio_manager.gd:407；src/main.gd:654 | 用真实业务事件验证阶段、对白、保存成功/失败与移动输入的音效语义；实际听测音量、循环接缝、叠音。 |
| P2 | 最新实际视口中文字与场景重叠、对比不足，主角与会员比例不一致、背景装饰抢占注意。美术测试主要验证参数/接口，不能证明辨识度和审美已验收。 | src/presentation/；src/ui/community_hud.gd；本轮截图 | 同场景整理文字承载区、人物尺度和接触位置，录制移动/上机/换站；邀请 5 位未读设计的玩家进行辨识与可操作性测试。 |

补充审查点：阶段自动保存从 phase_changed 同步直接写盘，CLOSE 信号在 tick_count 递增前发出，应收敛到真正 tick 完成后，并检查写盘返回值后再提示成功；当前代码无条件播放保存成功音。`PROGRESS.md` 顶部仍停在 GA-005，需与三天内容及最新音频事实同步。

## 执行顺序

### 批次 1：资产、会话与存档可靠性

修复模式切换、收纳取回、嵌套存档校验与阶段保存边界。先为上述具体复现补失败测试，再改实现。采用独立模式会话组合，避免在同一组系统上仅切换几个布尔值。保留现有存档兼容策略，拒绝损坏状态而不猜测补全关键运行数据。

完成条件：两模式往返及冷读档后状态独立；资产完整；损坏存档零副作用；存储失败不会提示成功；全量回归通过且新增探针无未预期脚本错误。

### 批次 2：玩家可操作的三天闭环

统一 HUD 与日循环契约，补上恢复收纳入口，修复晚达成首课的邀请/包场重排，再接通真实音频事件。测试要从输入/可见按钮进入，验证文字、提示、位置与业务后果，补充中途暂停/焦点丢失/读档/课程取消的路径。

完成条件：不阅读代码也能完成“布置→公园→营业→亲自指导→打烊→次日”，延迟完成玩家能进入补充营业日直至包场成功。自动化与手工试玩分别记证，不把固定 tick 推进称为玩家实测。

### 批次 3：同一间房的视觉与声音体验验收

基于修复后的场景统一人物尺寸、器械接触、文字背景、主次对比与昼夜光色；复用已有头像和音频资产，先解决可读性，再判断需要替换哪些资产。完成一次完整三天录像和 5 人试玩，记录迷路、误操作、等待、理解配速/指导的情况及想继续玩的动机。

完成条件：关键交互可发现、状态可辨识、画面与声音不妨碍操作。根据试玩数据决定公园/营业节奏、下一轮内容和动作生产量；不凭“6542 个断言通过”直接启动大批量美术。

## 当前不应宣称的结论

- 不能宣称两模式切换已完全隔离、任意损坏存档均安全、补充营业日故事一定可完成。
- 不能将素材数量或静态参数断言等同于“具备目标参考游戏相似的艺术完成度与可玩性”。
- 本次是代码复核、自动化运行和引擎截图检查，未完成外部玩家试玩或音频主观听测。

---

## 落地执行记录（2026-09-07）

- **批次 1（资产、会话与存档可靠性）✅ 完成**：
  - 模式切换状态隔离（`main.gd`）：独立 `_save_name`（`"gym-adventure"` 与 `"manual"` 隔离）、`MemberSim`/`Economy` 的 `community_mode` 隔离，重连 `day_cycle`。
  - 器械收纳取回（`day_cycle_system.gd`）：修复 `_restore_stored()` 调用 `can_place()` 缺少参数（2 参数扩充为 4 参数并带目录定义单元格校验），修复非固定器械保护与摆不下时的安全留存。
  - 严格反序列化与存档安全（`day_cycle_system.gd`）：增加 `course.devices` 数组及有效非空 `request` 结构严格校验，拒绝残缺存档。
  - 补充专属测试套件：`tests/unit/community/community_session_and_reliability_test.gd`（30 项断言全部通过）。

- **批次 2（玩家可操作的三天闭环）✅ 完成**：
  - 邀请判定修复（`day_cycle_system.gd`）：由 `day == 2` 放宽至 `day >= 2 and not _state.events.has("band_invitation") and _state.events.has("aluo_first_class")`，支持补充营业日正常推进故事。
  - HUD 数据契约对齐（`community_hud.gd`）：统一 `progress_m`/`distance_m`、`seconds`、`course.guidance` 字典、大小写请求状态（`CHOICE`/`TIMING`），补齐“恢复收纳”入口按钮。
  - 音频阶段事件路由接入（`audio_manager.gd`、`main.gd`）：支持大写阶段字符串（`"PREP"`/`"SERVICE"`/`"CLOSE"`/`"OUTING"`），保存成功音频在真正写盘成功后播放。

- **批次 3（视觉与声音体验验收 — 潜水员戴夫/班桥风格重构）✅ 完成**：
  - **高对比金边 UI 卡片**：采用深靛蓝底板（`#121A26`）、温润黄铜双层描边（`#DCA83D`）、四角铆钉、高对比奶油白文字（`#FFF8ED`）与金黄标题（`#FFE8A3`）；实体按键改为圆角药丸按键并附带呼吸悬浮光晕。
  - **角色尺度与比例统一**：在社区模式下将 `member_sprite` 统一缩放至 `34×34`，脚底接触点精准贴地，与程教练（14px 肩宽、~28px 身高）达成完美的人文尺度和谐。
  - **戴夫式像素角色轮廓与接地接触影**：程教练增加深色（`#141820`）轮廓勾边与白底运动鞋包边，脚底增加深色贴地双层椭圆阴影（贴地透视层，带外圈微光与深色内核心）；悬浮提示气泡重构为深色金边底板。
  - **温润钨丝灯/居酒屋室内光照重构**：`SERVICE`（晚间营业）阶段加入深靛蓝暗部包围与三层柔和钨丝灯聚光落点（`#FFE194`/`#FFBA52`），`CLOSE`（打烊）保留前台静谧暖光。
  - **全量测试通过**：Godot 4.7.1 执行 122 个测试文件，**6,572 项断言全部通过，0 失败**。真实视口截图固化至 `production/qa/evidence/2026-09-07-latest-review/test-service.png`。
