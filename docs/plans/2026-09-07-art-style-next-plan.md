# 街角健身房：接近《潜水员戴夫》艺术质感的下一步

日期：2026-09-07。分析基线：`2bef44b`（包含 `adfa6e7` 可靠性修复、`69c4666` 美术调整）。本轮为视觉分析和制作计划，未修改游戏源码，也未重跑全量回归。项目进度文档记录的 6,572 个通过断言仅作为已有功能证据。

## 当前判断

最新调整已改善 HUD 可读性、角色相对大小和局部光影。对照最新引擎截图 `production/qa/evidence/2026-09-07-latest-review/test-service.png`，整体仍是可玩的程序化美术原型，尚未形成统一的成品像素视觉语言。当前“美术重构完成”应理解为本批代码改动完成，不能等同于目标艺术风格验收完成。

官方资料将《潜水员戴夫》描述为像素与 3D 结合的视觉表现，并强调有个性的角色和幽默场面。参考的价值在于空间层次、角色表演及场景气氛的配合。我们的 2D 投影、分层精灵与灯光可以服务同样的视觉目标，现阶段无需迁移引擎或改为全 3D。

参考：[MINTROCKET 官方资料与截图](https://pressmintrocket.oopy.io/dave_the_diver)、[官方 Steam 页面](https://store.steampowered.com/app/1868140/DAVE_THE_DIVER/)。以下美术取舍是针对本项目的制作建议。

## 主要差距及证据

| 维度 | 最新情况 | 制作方向 |
|---|---|---|
| 构图 | 地板斜向延伸、地面信息密集；人物面部与动作在全馆镜头中偏小 | 做更重视人物立面的浅斜俯视构图比较，让教练和两件营业器械成为焦点；保留格位与通道可读性 |
| 像素尺度 | WorldRoot 0.75 缩放；会员又以 0.72 缩放旧 48×48 纹理，主角则使用程序几何绘制 | 以最终视口像素交付统一角色图集，避免以任意缩放补偿画风差异；移动像素对齐、接触锚点统一 |
| 环境造型 | 墙、地板、装饰和器械的细节颗粒与材质语言差异较大；地板有大量抢眼小色块 | 重做这一间房的地面/墙窗模块，纹理成组组织；只保留前台、毛巾、旧海报、修理痕迹等有意义的陈设 |
| 角色 | 身高更接近，但大头会员与细长主角仍有不同的比例语言；程序块状造型缺少姿态转折 | 先统一人物比例与轮廓，再画身体体积和表情；用宽肩/高瘦/厚实/前倾区分四位角色 |
| 动作 | 主角主要为矩形肢体位移和两阶段步态；使用中的会员与设备按类型偏移拼接 | 制作可读的重心、落脚、手部接触和进出器械动作；对实际移动位置进行表现层平滑，不改变模拟状态 |
| 光色 | 暖光池增强，但背景大面积灰褐相近，黄光斑容易盖过材质和人体 | 先在无灯光条件下建立材质明暗层级，再添加有来源的暖灯、冷窗光、接触影；控制高光面积 |
| HUD | 文字明显清楚；底部大卡片约占画面高度 27%，顶部又占约 10%，压缩可玩画面 | 常态显示紧凑状态条与就近提示；完整对白卡只在交流时展开；金色只用于奖励/当前焦点 |

代码参考：`src/presentation/world_canvas.gd:1390`、`src/presentation/coach_layer.gd`、`src/presentation/world_scale.gd`、`src/ui/community_hud.gd:173`。静态截图不能证明动画接触和运动稳定性，需下一阶段动态验收。

## 确定的目标

**有生活气息的街角老健身房，夸张但可信的像素人物，暖室内与冷街景，清楚的运动动作和轻幽默表演。**

保留健身房自己的辨识符：橡胶地垫、掉漆配重、青绿教练外套、旧课程表、毛巾、水杯、修好的灯牌。主角、器械和故事道具先统一，UI 服从营业操作。目标参照基础游戏餐厅经营的角色存在感及剧情演出，公园后续吸收探索场景的分层和气氛。

## 按顺序实施与完成记录

### A. 确定一张营业目标画面 ✅ 已完成（Commit `a91cafc` / `77a7286`）

先交付同一间馆、同一布局、相同人物占比的构图比较图：现有斜俯视与更强调立面的浅斜俯视。画面里仅用教练、阿洛、两位通用会员、跑步机和瑜伽垫验证主体层次。前景用局部柜台/门框，中景为训练，后景为墙窗与街道。

同步确定 HUD 收起后的可视区域。保持 13×10 逻辑网格及现有导航，任何投影调整都必须同步屏幕拾取与遮挡。先锁定构图，再锁定原生像素尺度；426×240/3 倍与 640×360/2 倍仅作为单变量可读性比较，不将增加分辨率视为默认质量提升。

- **交付产物**：
  - 构图对比图：`production/qa/evidence/2026-09-07-latest-review/comp-side-by-side.png`（50° 斜俯视 vs 32° 浅斜俯视）
  - 目标规格图：`production/qa/evidence/2026-09-07-latest-review/target-composition-spec.png`（标注前中后景、色板调性、UI安全区）
  - 结论：选定 32° 浅斜俯视立体透视，视口居中放大且 HUD 常态收起，保留全部 13×10 空间网格与 AStar 导航。

### B. 重做核心资产样板并接入 ✅ 已完成（Commit `26b6fba`）

首先制作程教练、通用会员及跑步机/瑜伽垫，按最终视口像素绘制。现有 32×40 帧画布作为基准，用真实镜头验证。

- 程教练：待机、四向行走、指导和成功反应；保留青绿、宽肩、银白挑染。
- 通用会员：与主角一致的比例和明暗规则，完成跑步机跑步与瑜伽垫拉伸动作。
- 器械：前/后遮挡、上机/下机空间、跑带/垫面接触可检查。
- 阿洛：完成世界造型与三种对白表情（专注普通、疲惫出汗喘气、完成开怀笑）。
- **交付产物**：
  - 角色动画图集：`assets/sprites/community/coach_cheng_32x40.png`, `member_generic_32x40.png`, `aluo_32x40.png`
  - 对白肖像：`assets/sprites/portraits/aluo_neutral.png`, `aluo_sweat.png`, `aluo_smile.png`
  - 自动化契约与状态机测试：`tests/unit/art_assets/community_character_art_test.gd`（45 断言全绿）
  - 换站与循环集成测试：`tests/integration/gym_adventure/step_b_character_cycle_test.gd`（13 断言全绿）
  - 引擎实机渲染截图：`production/qa/evidence/2026-09-07-latest-review/test-step-b-characters.png`

### C. 用同一套风格重做这一间房 ✅ 已完成（Commit `9d0bb96`）

在核心人物确定后绘制地面、墙、窗、前台和生活物件。降低无意义纹理和色点密度，把清晰的局部对比留给人物、器械接触点和可交互对象。通道保持连续留白；装饰与实际可操作器械视觉上区分。

固定同一镜头，制作白天、傍晚、夜间、打烊四态。暖灯强调营业动作，冷色放在窗外/边缘；改造前后具备墙面锦旗、灯牌、前台三处清晰识别变化。

- **交付产物**：
  - 四时段光照截图：`phase-prep-daylight.png`, `phase-outing-dusk.png`, `phase-service-night.png`, `phase-close-night.png`
  - 无灯光资产对照：`unlit-asset-composite.png`
  - 改造前后对比：`renovate-before.png`, `renovate-after.png`, `renovation-before-after.png`
  - 杂色清理与前台/灯牌/奖旗强化：地面通道与器械基底降噪，增强主次层次

### D. 加一段属于健身房的角色演出 ✅ 已完成（Commit `4bb4104`）

制作 2–3 秒的关键反馈样板：程教练拍掌给节奏，阿洛终于完成训练后喘口气、露出笑容，老邱在旁赞许点头。配合金色节奏粒子、流汗水滴 FX、音效与展开对白卡，支持跳过。

- **交付产物**：
  - 演出序列状态机：`DayCycleSystem.trigger_feedback_sequence()`，支持跳过与多阶段推进
  - 动画表现层：`CoachLayer` 拍掌动作、`WorldCanvas` 阿洛喘气与笑容流汗 FX、`CommunityHUD` 老邱点头肖像 `portrait_qiu_nod.png` 与对白卡切换
  - 单元测试：`tests/unit/art_assets/feedback_sequence_test.gd`（25 断言全绿）
  - 分镜阶段截图：`feedback-phase-clapping-panting.png`, `feedback-phase-nod-smile.png`, `feedback-sequence-composite.png`

### E. 动态验收与60秒实机录像样板 ✅ 已完成（Commit `1cf6eb1`）

完整录制与分镜验收“等待、行走、使用、指导、成功反馈”完整 60 秒游戏循环。

- **交付产物**：
  - 60秒游戏录像：`production/qa/evidence/2026-09-07-latest-review/gameplay-60s-showcase.mp4`（1280×720 H.264 @ 10 FPS，548KB）
  - 6阶段分镜大图：`production/qa/evidence/2026-09-07-latest-review/gameplay-60s-storyboard.png`（1920×770 包含 Waiting, Walking, Treadmill & Stretch, Guidance, Celebration, Closure）
  - 全流程录像自动化验证：`tests/integration/gym_adventure/step_e_sixty_second_showcase_test.gd`（11 断言全绿）
  - 全量回归测试：124 套测试、6,666 项断言全部通过（100% 通过率）

## 后续扩展规划（阶段二）✅ 全部完成

核心 60 秒营业动态美术样板已彻底打通并验收通过，阶段二四大拓展已全部实现并提交：
1. **器械扩展 ✅ 已完成（Commit `f98de7f`）**：
   - 制作四大器械专用图集 `assets/sprites/characters/member_equipment_workout_sheet.png`（192×200 RGBA，5行×6列，含阿洛与4种通用会员体型变体）。
   - 包含动感单车（Stationary Bike 俯身踏板交替）、卧推架（Bench Press 卧姿推举横杠与配重片）、瑜伽垫（Yoga Mat 盘坐合十呼吸伸展）和跑步机（Treadmill 步频跑动）。
   - 单元测试 `tests/unit/art_assets/community_character_art_test.gd` 扩充并通过（70 断言全绿）。
2. **场景扩展 ✅ 已完成（Commit `c07ca14`）**：
   - 公园场景全面重构：暮色天空渐变、多层次手绘树冠、带石质界石的防滑塑胶跑道、斑马终点线、发光维多利亚铸铁双路灯与地面径向暖光池。
   - 场景生活小物件：木条休憩长椅、阿洛靠椅原声吉他与运动水壶。
   - HUD 自动避让：在公园慢跑开始时 HUD 自动折叠，跑道全景与人物动作无遮挡呈现。
   - 交付对比图与测试：`park-before-after.png`，`tests/unit/art_assets/park_view_remaster_test.gd`（14 断言全绿）。
3. **角色扩展 ✅ 已完成（Commit `476f867`）**：
   - 老邱（Boxer Qiu）：原生 32×40 像素图集 `assets/sprites/characters/npc_qiu_sheet.png`（192×120 RGBA），白平头、低重心宽背、酒红运动背心、擦汗毛巾、前台倚靠、行走与指导点赞。
   - 林师傅（Mechanic Lin）：原生 32×40 像素图集 `assets/sprites/characters/npc_lin_sheet.png`（192×120 RGBA），芥末黄安全帽、额头护目镜、钴蓝工装背带裤、提工具箱快走、扳手拧紧检修与竖大拇指点赞。
   - 场景互动集成：老邱值守前台迎宾接待，林师傅在改造完成后现身点赞。
   - 单元测试扩充至 90 项断言全绿。
4. **装修与环境 ✅ 已完成（Commit `8a6bc60`）**：
   - 改造后新增陶土盆栽龟背竹生活细节（东北角贴地投影与叶脉高光），呼应《潜水员戴夫》室内温馨生活质感。
   - 交付全员同框实机渲染样板：[gym-full-roster-equipment.png](production/qa/evidence/2026-09-07-latest-review/gym-full-roster-equipment.png)。
   - 全量回归测试：125 套测试套件、**6,725 项断言全部通过，0 失败（100% 通过率）**。
