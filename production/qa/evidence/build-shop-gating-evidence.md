# QA Evidence — BSUI-002: Purchase Gating & One-drag Invariant

> **Story**: production/epics/build-shop-ui/story-002-purchase-gating-one-drag-invariant.md
> **Epic**: build-shop-ui (Presentation layer)
> **Date**: 2026-08-06
> **Engine**: Godot 4.7.1 (headless-verified)
> **Story Type**: Logic — evidence BLOCKING (automated coverage required)

## Summary

The real Shop query surface lands here as presentation-layer integration glue
(`src/ui/shop.gd`, `class_name Shop extends PaletteAvailability`), replacing
Story 001's placeholder with ZERO palette changes. The palette gains the
mouse-down drag gate (AC4), the one-drag invariant (AC5), and hover
"Save $X more" tooltips (AC9). Money is spent exactly once on
`placement_committed` for purchase-initiated drags (Core Rule 2), skipped for
cost-0 items (Core Rule 2b), and never for relocate commits (Core Rule 2a).

| File | Class | Role |
|------|-------|------|
| `src/ui/shop.gd` | `Shop extends PaletteAvailability` | Real query surface: `can_purchase` (Core Rule 1 + cost-0 short-circuit), `is_unlocked` (Core Rule 5 fail-closed), `begin_purchase_drag` (drag-start gate incl. `is_dragging()` structural backstop), `notify_silent_cancel`, `get_save_more_amount` (Core Rule 4 derivation), `_purchase_in_flight` + spend-on-commit listener |
| `src/ui/palette_availability.gd` | `PaletteAvailability` | Contract grows with the Story 002 surface (guarded stubs: `begin_purchase_drag` / `notify_silent_cancel` / `get_save_more_amount`) |
| `src/ui/build_shop_palette.gd` | `BuildShopPalette` | Optional 4th init param `placement` (backward-compatible); `_input` hit-test → `on_tile_mouse_down` gate; `_drag_in_flight` one-drag invariant + dim; per-tile `tooltip_text` refresh |

Automated coverage: `tests/unit/build_shop_ui/purchase_gate_test.gd` — **86
asserts, 0 failed** (registered in `tests/headless_runner.gd` TEST_FILES).

Full suite: **3702 passed, 0 failed** (3616 pre-existing + 86 new).

## Blocking AC Verification

### AC4 — 可负担启动拖拽 (affordable, unlocked → drag begins)

- ✅ Automated: `palette.on_tile_mouse_down("treadmill_01")` on an affordable
  unlocked item returns true; `PlacementSystem.is_dragging()` true; Shop's
  `_purchase_in_flight` set with `{equipment_id, cost}` captured at gate-time.
- ✅ Automated edge: `PlacementSystem.is_dragging()` already true (relocate in
  flight, constructed via the white-box seam) → `begin_purchase_drag` false,
  NO flag set, palette mouse-down inert — the swallowed attempt never poisons
  `_purchase_in_flight` (Core Rule 2 step 1 structural backstop).
- ✅ Automated edge: locked item → `can_purchase` false → no drag; unaffordable
  item → `can_purchase` false → no drag, no flag.

### AC5 — 单拖拽不变量 (one-drag invariant)

- ✅ Automated: treadmill drag in flight → second mouse-down on bench_press
  returns false (palette disabled via `_drag_in_flight`), the in-flight drag is
  undisturbed, and the flag is NOT overwritten (still treadmill_01/cost 350).
  Even the same item's mouse-down is blocked while dragging.
- ✅ Automated edge: second `can_purchase` pass during a drag is a true no-op
  query; `begin_purchase_drag` still returns false (structural gate) — flag
  unchanged.
- ✅ Automated: drag resolution (silent cancel) re-enables the palette and
  clears the Shop flag via `notify_silent_cancel` with money untouched.

### AC9 — Save-$X 提示 (hover tooltip)

- ✅ Automated: treadmill ($350) at balance 100 → `get_hover_tooltip` returns
  "Save $250 more" (X = cost − balance, sourced from EquipmentCatalog +
  Economy); the rendered tile's `tooltip_text` is wired to the same string.
- ✅ Automated edge: balance == cost (X = 0) → no tooltip, tile AFFORDABLE
  full-tint — "just affordable" reads as available, not "save more".
- ✅ Automated edge: locked item → "Locked" tooltip, NOT Save-$X (Core Rule 5:
  locked must never read as "just save up").

### Shop Core Rule 1 — 解锁优先 (unlock checked first)

- ✅ Automated: a locked item that is ALSO cost-0 → `can_purchase` false — the
  unlock gate runs BEFORE the cost-0 affordability short-circuit.
- ✅ Automated: cost-0 unlocked item → `can_purchase` true with
  `Economy.can_afford` called ZERO times (spy economy proves the short-circuit
  at the call site — Economy rejects `can_afford(0)` by contract, AC5).

### Shop Core Rule 2b — 免费件不 spend (cost-0 skip)

- ✅ Automated: full drag lifecycle on a $0 item → commit fires
  `placement_committed` → `Economy.spend` called ZERO times (spy economy),
  balance untouched (500), `_purchase_in_flight` cleared, and the placement
  COMPLETES (grid holds the piece at the drop cell).
- ✅ Automated edge: relocate commit (flag null) → zero spend, no flag change;
  a fresh purchase gate works afterward with no residue.

### Shop Core Rule 2 — deduct-on-commit (spend exactly once)

- ✅ Automated: full purchase drag ($350 treadmill) → commit → balance
  500→150, `balance_changed` fired exactly once (spy), flag cleared, grid
  holds the placed piece.
- ✅ Automated: equipment_id mismatch branch (flag for A, commit arrives for
  B) → zero spend, flag UNTOUCHED (defensive, expected unreachable).
- ✅ Automated: `placement_rejected` → flag cleared, zero spend.
- ✅ Automated: `notify_silent_cancel` → flag cleared, zero spend.

### Story-001 compatibility

- ✅ Automated: palette without placement injection (story-001 render-only
  rig) → mouse-down inert, no crash; `_refresh_all` still sets states and now
  also tooltips via the placeholder's `get_save_more_amount` (implemented to
  keep story-001 rigs clean).
- ✅ Palette init signature is backward-compatible (optional 4th param);
  story-001's `palette_state_test.gd` (72 asserts) still passes unchanged.

## Guardrails

- ✅ Control Manifest: typed signal connections only (Shop connects
  `placement_committed` / `placement_rejected` via `.connect(callable)`); no
  string-based connects.
- ✅ Use-before-init guard on Shop public methods (push_error + safe default,
  never assert).
- ✅ `init()` twice on Shop → logged error, no crash, still functional.

## Files Changed

- `src/ui/shop.gd` (new — `Shop extends PaletteAvailability`)
- `src/ui/palette_availability.gd` (contract + Story 002 surface stubs)
- `src/ui/placeholder_palette_availability.gd` (implement `get_save_more_amount`)
- `src/ui/build_shop_palette.gd` (placement injection, `_input` gate,
  one-drag state, hover tooltips)
- `tests/unit/build_shop_ui/purchase_gate_test.gd` (new, 86 asserts)
- `tests/headless_runner.gd` (register new test)
- `.godot/global_script_class_cache.cfg` (register `Shop` class_name)

## Known Gaps / Future Work

- The palette's `_input` hit-test uses Control `_input` + `get_global_rect()`
  — the dual-focus (4.6+) keyboard path (Tab/Enter to start a keyboard drag)
  is the UX spec's keyboard story, deferred per story scope.
- Silent-cancel return cue (visual/audio) is Story 004's deliverable — this
  story supplies the `notify_silent_cancel` logic path.
- Build/select mode arbitration (ghost suppression, selection clearing) is
  Story 003.
- The palette dim during drag is a flat modulate (0.6) — story 004's visual
  polish may layer the 4.7 Control offset-transform tween.
