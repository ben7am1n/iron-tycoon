# Review Log — SelectionSystem

## Review — 2026-07-19 — Verdict: NEEDS REVISION (full-mode adversarial, joint with placement-system.md)
Scope signal: M
Specialists: game-designer, systems-designer, qa-lead, godot-specialist, economy-designer + creative-director (senior synthesis)
Blocking items: 7 (shared across both GDDs) | Recommended: 11
Prior verdict resolved: First review.

### Blocking items found & fixed in-session
| # | Issue | Fix applied |
|---|---|---|
| B1 | Dependencies listed `get_placed_instances()`/`get_snapshot()` — GridSystem only grants `get_occupant_id(cell)` per AC-X.4 | Rewrote to use only `get_occupant_id(cell)` + self-maintained `instance_id → data` mapping via signal subscription |
| B2 | RefCounted system with no input/timer bridge — `get_tree()` unavailable | Added "Input routing (architecture contract)" section; timer ownership assigned to bridge Node |
| B5 | Economy bidirectional dependency missing — economy.md doesn't list SelectionSystem | Bidirectional notes explicitly flag violation + path to fix via `/propagate-design-change` |
| B6 | Sell-credit tick-order/determinism unspecified | Economy dependency annotated: "synchronous and immediate, mirrors spend()" |

(B3, B4, B7 were fixed in placement-system.md — they originated from the relocate flow which PlacementSystem owns.)

### Outstanding recommended items (not fixed this session)
- R1: `refund_rate` 0.5 not grounded against economy.md's pacing table — $325 loss on $650 item = ~7 min earn time
- R2: 2s sell-confirm auto-revert is structurally a timer countdown (anti-pillar: "NOT 紧张的限时挑战")
- R8: 6 AC gaps — no AC for: direct-swap, re-click no-op, external invalidation, drag suppression, cost-0 boundary, retired-id non-reissuance
- R9: `sell_back_refund` formula — GDScript `round()` returns float, needs `int()` cast; no AC at .5 boundary with odd cost
- R4: Member displacement on relocate handled identically to sell — but player intent differs (transient vs permanent)

### Verified correct by specialists
- Sell-back formula cannot generate arbitrage (refund_rate always < 1.0)
- Move/relocate handoff boundary is one-way (Selection → Placement); no cycle
- `instance_id` composition with relocate re-commit verified safe against GridSystem contract

Status: blocking resolved → **awaiting independent re-review** (run `/design-review` in a fresh session after `/clear`)
