# Critical Paths — Smoke Test Checklist
# 15 分钟内手动跑完，每次 QA 交接前执行
# 执行方式：godot --headless --script tests/headless_runner.gd

## Core Stability
1. Godot headless 启动不崩溃
2. GridSystem + SeededRNG smoke test 全部通过

## Core Mechanic
3. 确定性：相同 seed+layout → 300 tick 后 member state bit-identical
4. 布局影响：密集布局的平均拥挤度 > 分散布局（核心游戏性验证）
5. 路径可达性：器械被围堵后 access_reachable 正确变为 false

## Data Integrity
6. EquipmentCatalog 字段校验（mean<=0 拒绝、use_duration 正确返回）
7. PlacementSystem 放置/旋转/移动 全路径通过

## Visual Readability
8. shape-first overlay：密集布局峰值拥挤 > 分散布局
9. 热点格返回非空 glyph + queue_len

## Performance
10. 13×10 grid 上 300 tick × 8 member simulation < 5 秒 wall-clock
