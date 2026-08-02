# Visual Entity & Screen Inventory

> Generated: 2026-08-02
> Sources:
> - design/gdd/systems-index.md
> - design/gdd/equipment-catalog.md (6 MVP 器械)
> - design/gdd/member-sim.md (会员生命周期/状态可读性)
> - design/gdd/placement-system.md (拖放预览/反馈)
> - design/gdd/selection-system.md (选中/出售反馈)
> - design/gdd/build-shop-ui.md (商店货架)
> - design/gdd/hud.md (顶部 HUD)
> - design/gdd/shop-purchase.md (购买确认反馈)
> - design/gdd/save-load.md (存档菜单反馈)
> - design/gdd/zone-rules.md (三区域语义色)
> - design/gdd/congestion-flow-overlay.md (热力图/路障图标/tooltip)
> - design/gdd/grid-system.md (视觉边界声明)
> - design/art/art-bible.md (§5 比例 / §6 环境 / §7 UI / §8 资产标准 / §9 VFX)

> 状态约定：`Needed` = 尚未产出 spec/素材。首个视觉 story 前须先跑 `/asset-spec`
> （gate-check 首批事项 #5 排期），器械规格优先级最高——命名/尺寸/生成提示已在
> art-bible §8 就绪。全部资产命名遵循 art-bible §8：`[category]_[name]_[variant]_[state].[ext]`，
> 类别前缀 `equip_` / `member_` / `ui_` / `env_` / `vfx_`，snake_case。

## Entities

| # | Name | Type | Description | Source | Status |
|---|------|------|-------------|--------|--------|
| 1 | Member — 会员小人 | Character | 治愈 Q 版像素小人（2.5–3 头身，art-bible §5），俯视/轻等距，4/8 向 facing；动画集 `idle` / `walk` / `use_equipment` / `happy`（art-bible §8 最小集）。网格对齐 32×32 整数倍。变体：casual male / casual female（`member_casual_female_walk.png` 等） | design/gdd/member-sim.md · design/art/art-bible.md §5/§8 | Needed |
| 2 | Member state — QUEUEING 排队态（最高可读性） | Character | 概念原型 #1 摩擦（"看不清谁在排队"）证明这是承重项：排队必须是四个玩家关心状态中最 distinct 的一个——独立等待姿态 + 小"等待"字形（如 queue/pause 图标），**形状优先、色盲安全**，绝不靠颜色单通道。等待中保持平静配色，绝不红/闪（Pillar 2） | design/gdd/member-sim.md Visual/Audio | Needed |
| 3 | Member state — USING 使用中 / WALKING / LEAVING | Character | USING = 使用动画（在 access 格上）；WALKING = 行走动画 + 行进方向 facing；LEAVING = 走向出口。10Hz 格子寻路 + 60fps 位置插值（表现层职责） | design/gdd/member-sim.md Visual/Audio | Needed |
| 4 | Equipment — Treadmill 跑步机 | Item | 1×1 footprint，cost 200（有氧区 Sky 语义色）。精灵：剪影 + 履带线标志性细节（art-bible §5 LOD）。命名 `equip_treadmill_basic_idle.png`；需支持 drag ghost 半透明版 + 破旧/焕新双态（Pillar 4 蜕变） | design/gdd/equipment-catalog.md · design/art/art-bible.md §5/§8 | Needed |
| 5 | Equipment — Yoga Mat 瑜伽垫 | Item | 1×1 footprint，cost 200（团课/社交区 Peach 语义色）。平铺地垫，轮廓极简。`equip_yoga_mat_basic_idle.png` | design/gdd/equipment-catalog.md · design/art/art-bible.md §5/§8 | Needed |
| 6 | Equipment — Bench Press 卧推架 | Item | 1×2 footprint，cost 350（力量区 Sage 语义色）。`equip_bench_press_basic_idle.png`；footprint 1×2 精灵尺寸为 32×64（或 64×32，按朝向） | design/gdd/equipment-catalog.md · design/art/art-bible.md §5/§8 | Needed |
| 7 | Equipment — Rowing Machine 划船机 | Item | 1×2 footprint，cost 350（有氧区 Sky 语义色）。`equip_rowing_machine_basic_idle.png` | design/gdd/equipment-catalog.md · design/art/art-bible.md §5/§8 | Needed |
| 8 | Equipment — Squat Rack 深蹲架 | Item | 2×2 footprint，cost 650（力量区 Sage 语义色）。立柱剪影 + 标志性细节。`equip_squat_rack_basic_idle.png`；精灵尺寸 64×64 | design/gdd/equipment-catalog.md · design/art/art-bible.md §5/§8 | Needed |
| 9 | Equipment — Multi-Station 综合训练架 | Item | 2×2 footprint，cost 650（力量区 Sage 语义色）。`equip_multi_station_basic_idle.png`；精灵尺寸 64×64 | design/gdd/equipment-catalog.md · design/art/art-bible.md §5/§8 | Needed |
| 10 | Env — Floor tile 地板 | Environment | 木地板/胶地板质感，手绘像素质感（非 PBR），明度而非高饱和表现材质。TileMapLayer 可复用 tile。`env_floor_wood_a.png` 等 | design/art/art-bible.md §6 | Needed |
| 11 | Env — Zone floor 区域色块 | Environment | 力量区 Sage / 有氧区 Sky / 团课区 Peach 地板色块 + 柔和描边，"分区一眼可读"（Pillar 1/3） | design/gdd/zone-rules.md · design/art/art-bible.md §6 | Needed |
| 12 | Env — Wall / Window / Door 墙/窗/门 | Environment | 砖墙、大玻璃窗、门——现代都市小场馆，暖光社区健身房亲切感。tile 可复用 | design/art/art-bible.md §6 | Needed |
| 13 | Env — Entrance / Exit 出入口 | Environment | `entrance_cell` / `exit_cell` 是 MemberSim 状态机转移的**硬上游输入**（非装饰）：入口门 + 出口门视觉 | design/gdd/member-sim.md Interactions · design/art/art-bible.md §6 | Needed |
| 14 | Env — Props（绿植/镜子/水机/海报） | Environment | 装饰点缀而非堆砌（留白优先）；低对比、柔和，永远不与功能元素争注意力 | design/art/art-bible.md §6 | Needed |
| 15 | Env — 破旧初始态 / 焕新升级态 | Environment | 蜕变必须可见（Pillar 4）：破旧态=裂缝/褪色/闪烁灯管/生锈器械；焕新态=明亮灯/绿植/干净地面。靠环境细节讲蜕变，无需文字 | design/art/art-bible.md §6 | Needed |
| 16 | VFX — Placement 放置成功星光+吸附 | VFX / Particles | 器械放置成功 → 轻微星光/闪粉 + 吸附"咔哒"（placement-system 承重 SFX 对应）。柔和、像素化，绝不制造噪音 | design/art/art-bible.md §9 · design/gdd/placement-system.md | Needed |
| 17 | VFX — Satisfaction 满意度粒子 | VFX / Particles | 满意度上升 → 柔和上浮的 `+` 心形/笑脸像素粒子 | design/art/art-bible.md §9 | Needed |
| 18 | VFX — Money 金钱粒子 | VFX / Particles | Butter 黄硬币像素粒子轻弹跳 | design/art/art-bible.md §9 | Needed |
| 19 | VFX — Upgrade 蜕变扫光 | VFX / Particles | 升级完成 → 一次温暖的"擦亮/焕新"扫光 sweep + 饱和度回升 | design/art/art-bible.md §9 | Needed |
| 20 | VFX — Congestion 拥挤提示 | VFX / Particles | 柔和 Dusty Rose 汗滴/波纹图标，温和脉动而非闪烁；形状优先（色盲安全，Sage↔Dusty Rose 关键易混对） | design/art/art-bible.md §9 · design/gdd/congestion-flow-overlay.md | Needed |
| 21 | VFX — Drag ghost 拖放预览 | VFX / Particles | footprint = 器械精灵 65% 不透明度 + Soft Charcoal 1px 实线描边；access = 35% 对角斜纹层（绝不实心，防误读为可占用）。ColorRect/Sprite2D modulate，不用 DrawableTexture2D | design/gdd/placement-system.md Visual/Audio | Needed |
| 22 | VFX — Invalid 非法位置提示 | VFX / Particles | footprint 去饱和灰洗（**非红、非 Dusty Rose**——Dusty Rose 已留给拥挤），描边变虚线 + 小型 muted "can't-place-here" 字形。读作"还不可以"，非警报 | design/gdd/placement-system.md Visual/Audio | Needed |
| 23 | VFX — Relocate 迁移占位 | VFX / Particles | 迁移拖拽中：原 footprint 显示 40% 不透明度 Soft Charcoal 虚线框，无精灵无填充 | design/gdd/placement-system.md Visual/Audio | Needed |
| 24 | VFX — Rotation 旋转反馈 | VFX / Particles | ~90ms 缩放脉冲（1.0→1.05→1.0），非实体旋转（平铺像素精灵旋转读作伪 3D） | design/gdd/placement-system.md Visual/Audio | Needed |
| 25 | VFX — Selection 选中反馈 | VFX / Particles | Soft Charcoal 描边 + tint 辉光 + 角落"选中"图标，一次缓慢呼吸、无闪烁 | design/gdd/selection-system.md Visual/Audio | Needed |
| 26 | VFX — Sell 出售反馈 | VFX / Particles | "Confirm sell +$X" 温暖 Butter morph（绝不警报红）；确认后温和淡出，无破坏粒子 | design/gdd/selection-system.md Visual/Audio | Needed |
| 27 | Overlay — Congestion heatmap 热力图 | VFX / Particles | 13×10 ImageTexture + CanvasItem shader，**per-sampler bilinear**（全局 Nearest 的刻意孤立例外——软雾而非格子表）；低密度透明、拥挤处暖向 Dusty Rose | design/gdd/congestion-flow-overlay.md · design/gdd/congestion.md | Needed |
| 28 | Overlay — Access-blocked 路障图标 | VFX / Particles | access 受阻/零可达状态**默认可见**（GridSystem OQ#9 信任链闭合）；形状优先图标（色盲安全），常亮独立层 | design/gdd/congestion-flow-overlay.md · design/gdd/grid-system.md | Needed |
| 29 | UI — 图标库（功能区/器械/状态专属图标） | Other | 带描边填充式图标（outlined-fill），每个功能区/器械/状态都有专属图标——"图标+颜色"双通道色盲安全。含锁图标（商店 locked）、等待字形、太阳/时钟图标 | design/art/art-bible.md §7 · design/gdd/build-shop-ui.md · design/gdd/hud.md | Needed |
| 30 | UI — 像素友好字体（中文全字形） | Other | 像素/圆润无衬线，友好清晰；中文需支持完整字形；≥16px @1080p 整数缩放 | design/art/art-bible.md §7 | Needed |

## UI Screens

| # | Screen Name | Description | Source | Status |
|---|-------------|-------------|--------|--------|
| 1 | HUD 顶部栏 | 左上金钱（Butter 硬币图标）、右上满意度表（Sage→中性→柔和玫瑰，图标+%双通道）、右上日期/时间 + 暂停/速度簇（‖ 1× 2× 3×，激活=描边+实心点）。稀疏平静，无弹窗无徽章 | design/gdd/hud.md | Needed |
| 2 | Build/Shop UI 商店货架 | 器械 tile 货架（图标+名称+Butter 价格）；可负担=全 tint，不可负担=去饱和灰（绝不红），锁定=灰+锁图标（形状优先） | design/gdd/build-shop-ui.md | Needed |
| 3 | Selection 上下文工具栏 | 选中已放置器械后的 inspect/move/sell 工具栏，UI 层渲染，随 UI-scale 缩放 | design/gdd/selection-system.md | Needed |
| 4 | Equipment Info Panel（VS） | 器械详情：display_name / effects / cost（#17，VS 阶段） | design/gdd/systems-index.md · design/gdd/equipment-catalog.md | Needed |
| 5 | Pause 暂停菜单（VS） | 设置 / save-load 入口；独立 shell，非 HUD 一部分 | design/gdd/hud.md UI Requirements · design/gdd/save-load.md | Needed |
| 6 | Save/Load 菜单（VS） | "Saved" 确认；失败时优雅的 "incompatible / corrupt save" 消息 | design/gdd/save-load.md Visual/Audio | Needed |
| 7 | Settings & Accessibility（VS） | 高对比 UI 主题（加重描边、提升文字/背景对比） | design/art/art-bible.md Accessibility · design/gdd/systems-index.md | Needed |

## HUD Elements

| # | Element | Description | Source | Status |
|---|---------|-------------|--------|--------|
| 1 | Money 金钱显示 | 静态 Butter 硬币图标 + 数字；balance_changed 时数字 ~0.3s tween 计数，减少时绝无红闪（短暂去饱和即确认） | design/gdd/hud.md | Needed |
| 2 | Satisfaction 满意度表 | 短横条/弧线（**绝不用血条隐喻**）；Sage(高)→温暖中性(中)→柔和 Dusty Rose(仅低端)；~1s 缓动；图标形状变化（实心/描边）+ 数字 % 双通道 | design/gdd/hud.md | Needed |
| 3 | Time/Day 时间日期 | 当前 day 数字 + 太阳/时钟位置图标（图标非纯色） | design/gdd/hud.md | Needed |
| 4 | Speed cluster 速度簇 | ‖（暂停）、1×、2×、3× 四小按钮；激活项 = 描边 + 实心点图标（非纯色） | design/gdd/hud.md | Needed |
| 5 | Coin icon 硬币图标 | Butter 语义色，金钱专属图标（含商店价格标签复用） | design/gdd/hud.md · design/gdd/build-shop-ui.md | Needed |

## Audio

| # | Name | Type (SFX / Music / Ambient) | Description | Source | Status |
|---|------|------------------------------|-------------|--------|--------|
| 1 | Placement snap 放置吸附 | SFX | 器械放置成功的柔和"咔哒/click"——Pillar 4 每次放置的即时满足感，**MVP 最少必需 SFX**（即使整套音频系统后置也必须先做） | design/gdd/placement-system.md · design/gdd/equipment-catalog.md | Needed |
| 2 | Pick-up cue 拿起提示 | SFX | 开始拖拽时柔和"pick up"提示（nice-to-have，永不刺耳） | design/gdd/build-shop-ui.md | Needed |
| 3 | Purchase confirm 购买确认 | SFX | 购买成功的小小正面承诺提示；触发于 `placement_committed` 且 `_purchase_in_flight` 时（非 `balance_changed`——cost-0 购买也需确认感）；静默取消 → 轻量回架提示 | design/gdd/shop-purchase.md Visual/Audio | Needed |
| 4 | Sold cue 出售提示 | SFX | 出售确认的柔和 "sold" 提示（nice-to-have） | design/gdd/selection-system.md | Needed |
| 5 | Income coin 收入提示 | SFX | 完成一次 visit 的柔和硬币/铃声收入提示（nice-to-have；**必须愉悦，绝不焦虑收银机**） | design/gdd/economy.md Visual/Audio | Needed |
| 6 | Satisfaction chime 满意度提升 | SFX | 满意度表跨越上升阈值时的柔和正面 chime（nice-to-have） | design/gdd/satisfaction.md Visual/Audio | Needed |
| 7 | Save chime 存档提示 | SFX | 存档成功的柔和 chime（nice-to-have） | design/gdd/save-load.md Visual/Audio | Needed |
| 8 | Pause/speed click 暂停/速度 | SFX | 暂停/速度切换的柔和轻点击（nice-to-have） | design/gdd/hud.md Visual/Audio | Needed |
| 9 | Ambient gym 环境氛围 | Ambient | 脚步/健身房低语环境音（nice-to-have，低优先级；无 per-member SFX） | design/gdd/member-sim.md Visual/Audio | Needed |
| 10 | Cozy BGM 治愈音乐 | Music | 温暖松弛背景音乐（VS 阶段 #21） | design/gdd/systems-index.md · design/art/art-bible.md | Needed |

---

## Next Steps（排期）

1. **`/asset-spec` 排期：首个视觉 story 前**（gate-check 首批事项 #5）——以本清单为输入，
   先跑 `system:equipment-catalog` 补齐 6 件器械规格（#4–#9，命名/尺寸/生成提示已在 art-bible §8 就绪），
   再按视觉 story 依赖顺序覆盖 member / env / overlay / UI。
2. `/ux-design [screen]`：为每个 UI Screen（清单 UI Screens #1–#7）产出 UX spec。
3. 每批 spec 写入后更新 `design/assets/asset-manifest.md`（/asset-spec Phase 5 自动维护）。
4. `/asset-audit`：素材交付后对照 spec 校验缺口/失配。
