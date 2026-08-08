# ADR-0008: 地面材质 + 环境结构程序化渲染（V3 §1/§3/§4/§13）

## Status

Accepted（Phase 5 合并后修订 —— 与 Phase 5 FloorArt/EnvironmentArt 并存）

## Date

2026-08-08（修订：2026-08-09）

## Last Verified

2026-08-09

## Decision Makers

godot-coder（视觉重制 Phase 2 实现）+ default（规格决策人，visual-remaster-spec-v3.md 已 Approved）

## Summary

视觉重制 Phase 2 决定：地面区域用程序化像素材质表达（Phase 5 已实现 FloorArt 烘焙整张世界地板贴图），禁止纯色开发网格；环境结构按 V3 §4 三层空间补充 Phase 5 未覆盖的「结构元素」（立柱/前台/储物柜/镜子/空调/墙钟/通风口/吊灯/管道/踢脚线/电线槽/毛巾架/门/门垫），由 StructureArt 烘焙为 BACKGROUND / GAMEPLAY / FOREGROUND 三张图层贴图，与 Phase 5 的 EnvironmentArt 装饰精灵、world_layout、光照层并存。STRUCTURES 表提供 V3 §13 密度分类（large 5-10 / medium 15-30 / small 30-60，全场景口径含 Phase 5 元素）。WorldCanvas 每帧地板 1（Phase 5）+ 环境装饰精灵若干（Phase 5）+ 结构 3（Phase 2）= 合计 draw calls 120 < 200，headless 下全部像素断言可复现。

## Engine Compatibility

| Field | Value |
|-------|-------|
| **Engine** | Godot 4.7.1 |
| **Domain** | Rendering（2D CanvasItem / ImageTexture 烘焙） |
| **Knowledge Risk** | MEDIUM — Image API（create/set_pixel/get_pixel/create_from_image）自 4.0 稳定，4.7 无签名变更（已 probe/实测） |
| **References Consulted** | `docs/engine-reference/godot/VERSION.md`、`docs/engine-reference/godot/current-best-practices.md`、`src/presentation/world_scale.gd`（4.7.1 stroke pitfall）、`godot-4x-ui-pitfalls` skill（headless 渲染事实）、Phase 5 `floor_art.gd`/`environment_art.gd`/`world_layout.gd`（已合并到 main） |
| **Post-Cutoff APIs Used** | `Image.get_data()`（用于确定性 bit-compare；4.x 稳定） |
| **Verification Required** | 无 —— 已通过 `--headless --check-only` + 全量 headless 套件（5435 passed/0 failed）+ 窗口模式证据捕获验证 |

> **Note**: Knowledge Risk MEDIUM —— 若升级引擎需重验 Image 烘焙路径（set_pixel 语义、ImageTexture 生命周期）。

## ADR Dependencies

| Field | Value |
|-------|-------|
| **Depends On** | ADR-0001（DI composition root —— WorldCanvas 依赖经 main.gd 注入）、V3 §2 低分辨率管线（Phase 1，SubViewport 世界像素空间 416×320）、Phase 5 合并（FloorArt 地板 / EnvironmentArt 装饰 / world_layout / lighting_layer） |
| **Enables** | 后续视觉 Phase（设备重绘 / 人物重绘 / UI 像素化）依赖材质 + 环境层作为统一底景 |
| **Blocks** | 无 |
| **Ordering Note** | 本 ADR 与 visual-remaster-spec-v3.md §1/§3/§4/§13 绑定；QA 评审基于 main（worktree 合并且 push 后） |

## Context

### Problem Statement

V3 §1（最高优先级）：最终游戏画面禁止直接出现纯色格子 —— 区域区别必须通过材质、地板纹理、边缘压条、家具、灯光、墙面装饰表达。同时 V3 §3 要求显著增加环境资产密度：即使移除所有可购买设备，画面依然是一间完整、有生活感的健身房。Phase 5（并行卡，先于 Phase 2 合并）已实现 V3 §1 地板材质（FloorArt）与 V3 §12 场景装饰（EnvironmentArt 精灵工厂 + world_layout），但 Phase 5 的装饰是「小道具」（水瓶/毛巾/配重/植物/音箱/饮水机/垃圾桶/消防栓/海报/计时器/电视），**缺少** V3 §3 结构清单中的建筑结构：立柱、前台、储物柜、镜子、空调、墙钟、通风口、吊灯、管道、踢脚线、电线槽、毛巾架、门 —— 且没有 V3 §13 密度分类（large/medium/small 区间断言）。Phase 2 的独特价值正在于此。

### Current State

- Phase 5（main）已合并：`floor_art.gd`（FloorArt，V3 §1 四区域材质：力量橡胶/有氧暖灰/瑜伽木/通道瓷砖）+ `environment_art.gd`（EnvironmentArt 装饰精灵 ART_MAPS）+ `world_layout.gd`（墙/窗/装饰位置单一来源）+ `lighting_layer.gd`（V3 §6 光照）+ `ambient_fx.gd`（V3 §9 动态）。
- WorldCanvas._draw 顺序（Phase 5）：地板 → 环境背景（墙/窗/装饰）→ 网格（仅 placement）→ 会员 → 设备 → 环境前景（大植物）→ 幽灵。
- 画面密度不足 V3 §13：Phase 5 的 world_layout 约 26 项装饰，无 large/medium/small 分类，无 density_counts()。
- 低分辨率管线（Phase 1）已就位：世界像素空间 416×320 → WorldRoot 0.75 → SubViewport 426×240 → NEAREST 放大。

### Constraints

- 世界像素空间固定 416×320（13×10 cells × 32px，与 GridSystem/main.gd 对齐）。
- 性能预算 < 200 draw calls / 60fps（任务卡硬性要求）；Phase 5 已占约 115 calls，结构层必须只加 3 次 draw_texture_rect。
- 确定性：证据 PNG 与 headless 像素断言必须可复现（项目确定性约定）。
- 色值单一来源 `src/palette.gd`；跨脚本引用 preload alias（headless 可靠性约定，无 class_name 依赖）。
- 与 Phase 5 并存：不重画 Phase 5 已绘制的墙/窗/海报/植物/装饰（STRUCTURES 表 painted_by 字段分工），避免双画与视觉冲突。
- 4.7.1 pitfall：WorldRoot scale 0.75 下 1px 矢量描边消失（stroke 补偿）；贴图内 1px 线条不受此影响（贴图像素随 scale 采样，无亚像素线宽问题）。

### Requirements

- 地板材质（Phase 5 FloorArt 保留，本卡不重做）：力量区深灰橡胶 / 有氧区暖灰 / 瑜伽区暖木 / 通道亮瓷砖
- 环境结构密度 V3 §13：STRUCTURES 表全场景口径 large 5-10 / medium 15-30 / small 30-60（本实现 10/18/32）
- 结构元素（Phase 5 缺失，本卡补充）：立柱×2、前台、储物柜、镜子、空调、墙钟、通风口×2、吊灯×3、管道×2、踢脚线×3、电线槽×3、毛巾架、门×2、门垫×2、墙钩、喷淋头×3、壶铃、配重片×2、水瓶、纸杯×2、毛巾×2、出口标识
- 三层空间 V3 §4：BACKGROUND 降对比降饱和 / GAMEPLAY 更鲜艳 / FOREGROUND 允许遮挡
- 正常经营模式无 grid；placement mode 才显示（V3 §14，Phase 1/5 已建立，本卡保持）
- draw calls < 200（实测 120）；headless 测试不回归（5435 passed/0 failed）
- 空场验收（V3 §3）：移除全部可购买设备后结构仍完整（证据 phase2-empty-gym.png）

## Decision

### Architecture

```
WorldCanvas._draw() 绘制顺序（世界像素空间 416×320，Phase 2 合并后）:
┌─────────────────────────────────────────────┐
│ 1. FloorArt.texture()            (1 call)   │ ← Phase 5 V3 §1 材质地板
│ 2. EnvironmentArt 环境背景（墙/窗/装饰精灵）  │ ← Phase 5 V3 §3/§12
│ 3. StructureArt BACKGROUND       (1 call)   │ ← Phase 2 V3 §4 储物柜/镜/空调/墙钟/
│                                              │    通风口/门/踢脚线/电线槽/管道（降饱和）
│ 4. 网格线（仅 placement mode）               │ ← V3 §14
│ 5. StructureArt GAMEPLAY         (1 call)   │ ← 前台（主要交互对象，原色醒目）
│ 6. 会员中景 / 设备前景                        │
│ 7. StructureArt FOREGROUND       (1 call)   │ ← 立柱/吊灯（允许遮挡角色）
│ 8. EnvironmentArt 环境前景（大植物）          │ ← Phase 5 V3 §4 FOREGROUND
│ 9. 放置幽灵（Core Rule 7 最高优先级）         │
└─────────────────────────────────────────────┘
```

- **StructureArt**（RefCounted，`src/presentation/structure_art.gd`）：`STRUCTURES` 常量表驱动 —— 60 个结构（10 large / 18 medium / 32 small），每项含 id/kind/layer/size/rect/painted_by（"self"=本层烘焙绘制 / "phase5"=Phase 5 world_canvas 已绘制，仅参与密度统计不双画）。按 layer 烘焙为三张 416×320 贴图（透明底）。`density_counts()` / `structure_ids_in_layer()` / `structure_rect()` / `self_painted_count()` 供测试与证据脚本读取。BACKGROUND 层颜色经 `_col()` 降饱和降对比（lerp 中性灰 0.45 + darken 0.10），GAMEPLAY/FOREGROUND 原色。
- **WorldCanvas.init** 追加第 3 个可选注入 `structure_art`（null 时不画结构，旧测试构造兼容；`floor_art`/`env_art` 为 Phase 5 的第 1/2 个可选注入）。
- **main.gd**（composition root）装配 presentation 时 `StructureArtScript.new()` 注入 WorldCanvas（与 FloorArt/EnvironmentArt 并列）。
- 新色值追加进 `src/palette.gd`（DOOR_/DESK_/LOCKER_/MIRROR_/AC_/CLOCK_/PIPE_/CABLE_DUCT/COLUMN_/LAMP_/HYDRANT/FOUNTAIN/TRASH/TOWEL —— 与 Phase 5 的 WALL_/WINDOW_/PLANT_/FLOOR_/ACCENT_ 命名不冲突，复用 Phase 5 已有 WALL_BASE/WINDOW_GLASS/PLANT_GREEN 等）。

### Key Interfaces

```gdscript
# StructureArt
func layer_texture(layer: String) -> ImageTexture   # BACKGROUND/GAMEPLAY/FOREGROUND
func density_counts() -> Dictionary                  # {large, medium, small}（V3 §13 全场景）
func structure_ids_in_layer(layer: String) -> Array
func structure_rect(id: String) -> Rect2i
func self_painted_count() -> int                     # painted_by=="self" 数量
const LAYER_BACKGROUND / LAYER_GAMEPLAY / LAYER_FOREGROUND
const STRUCTURES: Array               # 60 项结构表（id/kind/layer/size/rect/painted_by）
```

### Implementation Guidelines

- 所有颜色引用 `src/palette.gd`，禁止在绘制文件内硬编码色值。
- 纹理变化一律用 `_hash2/_rand01(x, y, salt)` 坐标哈希 —— 禁止用 RNG（确定性）。
- 结构 rect 必须落在世界边界内（测试断言）；前台 desk 放 GAMEPLAY 层，立柱/吊灯放 FOREGROUND 层。
- BACKGROUND 层统一走 `_col()` 降饱和（V3 §4），不得个别结构手动压暗。
- painted_by=="phase5" 的条目只参与密度统计，不烘焙绘制（避免与 Phase 5 双画）。
- 新测试注册进 `tests/headless_runner.gd` TEST_FILES（否则不运行）。

## Alternatives Considered

### Alternative 1: 放弃 Phase 2 结构层，接受 Phase 5 现状

- **Description**: 认为 Phase 5 的装饰精灵已满足 V3 §3，Phase 2 卡只验收地板材质。
- **Pros**: 零合并风险。
- **Cons**: V3 §13 密度分类缺失（QA 审查要求 large 5-10 / medium 15-30 / small 30-60 断言）；结构清单（立柱/前台/储物柜/镜子/空调/墙钟/通风口/吊灯/管道/踢脚线/电线槽）全缺；「移除设备后仍像完整健身房」的证据不充分。
- **Estimated Effort**: 无。
- **Rejection Reason**: 任务卡 Exit 条件明确要求密度区间与结构清单；Phase 5 未覆盖。

### Alternative 2: 覆盖 Phase 5 的 environment_art.gd（同名文件替换）

- **Description**: 把 Phase 2 的 STRUCTURES 表写进同名 environment_art.gd，替换 Phase 5 实现。
- **Pros**: 单文件架构统一。
- **Cons**: 文件名冲突（add/add）；Phase 5 装饰精灵（水瓶/毛巾/配重/植物 storytelling）会被丢弃；合并冲突大、QA 已审查过 Phase 5 的 world_layout/装饰。
- **Estimated Effort**: 高（重写 Phase 5 合并）。
- **Rejection Reason**: 破坏已合并且已 QA 的 Phase 5 工作；新文件 StructureArt + painted_by 分工更干净。

### Alternative 3: 每结构一个 Node2D 逐帧 draw

- **Description**: 每个结构一个 Node2D + _draw。
- **Pros**: 独立控制/动画容易（后续动态元素）。
- **Cons**: 每结构 1 draw call（60 结构 → 60 calls，预算爆炸）；Phase 5 已占 ~115 calls。
- **Estimated Effort**: 相近。
- **Rejection Reason**: 整图层烘焙 3 draw calls 远优于逐结构；V3 §2 要求世界统一 pixel space，整贴图天然满足。

## Consequences

- **Positive**: 结构与 Phase 5 装饰/光照并存，画面密度达标（实测 60 结构、draw calls 120）；QA 可直接基于 main 审查；空场验收有证据。
- **Negative**: 结构层是静态烘焙贴图 —— 若要单个结构动画（如吊灯摆动）需额外机制（后续 Phase 可按需拆 Node2D）。
- **Migration**: 无（新增文件 + 注入，向后兼容 null 注入）。

## Verification

- Headless：`godot --headless --path . --script res://tests/headless_runner.gd` → **5435 passed / 0 failed**（新增 structure_art_test 21 断言 + world_canvas_structure_layer_test 18 断言）。
- 证据：`godot --path . res://tests/evidence/phase2_capture.tscn` → phase2-floor-env.png + phase2-empty-gym.png，30+ 像素断言 PASS（密度 10/18/32、前台/立柱/储物柜/镜子/墙/窗、地板材质、grid 规则、空场、draw calls 120）。
- Phase 1 回归：`godot --path . res://tests/evidence/phase1_capture.tscn` → PASS（采样点迁移至亮瓷砖窗口，见 phase1_capture.gd 注释）。
- Smoke：`godot --headless --path . res://src/main.tscn -- --smoke` → PASS（structure_art=true）。
