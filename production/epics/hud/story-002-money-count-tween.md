# Story 002: Money Count Tween

> **Epic**: hud
> **Status**: Ready
> **Layer**: Presentation
> **Type**: Visual/Feel
> **Estimate**: S — 1 session (≤2h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-06

## Context

**GDD**: `design/gdd/hud.md`
**Requirement**: `TR-HUD-004`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0005 (Signal Bus & Event Routing)
**ADR Decision Summary**: The HUD subscribes to `Economy.balance_changed(new_balance, delta)` and animates the money display. Tween is render-time state, independent of sim ticks (a sell refund during pause still animates).

**Engine**: Godot 4.7.1 | **Risk**: MEDIUM
**Engine Notes**: `tween_await()` (4.7 NEW) is the intended sequencing API — but it is post-cutoff; VERIFY the exact signature against the local 4.7.1 engine before use (fallback: classic `create_tween()` + `tween_property()` chains work in all 4.x). Control offset transforms (4.7 NEW) optional for juice.

**Control Manifest Rules (Presentation layer)**:
- Required: Use `tween_await()` for UI/feedback sequencing (verify first)
- Required: typed signal connections only
- Forbidden: string-based signal connections

---

## Acceptance Criteria

*From GDD `design/gdd/hud.md`, scoped to this story:*

- [ ] AC2 GIVEN Economy emits `balance_changed`, WHEN the value changes, THEN the money number animates old→new within ~0.3 s in Butter throughout (no red/error flash on decrease)
- [ ] Edge Case GIVEN rapid balance changes (multiple departures one tick), WHEN `balance_changed` fires repeatedly, THEN the money tween targets the latest value (re-targets mid-tween, no queue backlog)
- [ ] Edge Case GIVEN money changes while paused, WHEN a sell refund during pause changes balance, THEN the count tween still animates (render-time, independent of sim ticks)

---

## Implementation Notes

*Derived from ADR-0005 Implementation Guidelines:*

**Count-up/down tween (Core Rule 3, TR-HUD-004):**
- On `balance_changed(new, delta)`: tween the displayed number from current → `new` over ~0.3 s (knob: 0.2–0.5 s)
- Butter color throughout — including on spend (decrease); a brief desaturation-then-settle is acknowledgment enough, NEVER a red flash (Pillar 2 absolute)
- Re-target mid-tween: if another `balance_changed` arrives while animating, cancel/re-target to the latest value — no queue backlog (Edge Cases)
- Render-time independent of sim ticks: the tween runs on `_process`/Tween, not gated by sim tick advance (money can change while paused via sell refund)

**Reduced-motion**: snap to the final value (no tween) when reduced-motion is on (UX spec: "snap under reduced-motion").

**Formatting**: coin icon (Butter) + number; locale-formattable currency display (thousands separators must not collide with the icon).

**4.7.1 pitfalls**:
- If using `tween_await()`, verify exact signature first (post-cutoff). Classic `create_tween()` is the verified fallback.
- `class_name` follows `extends` immediately; headless cross-script refs via `preload` aliases

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 001]: top-bar layout, money Label initial binding, load-state rendering
- [Story 003]: satisfaction meter ease (~1s) — different tween, different element
- [Story 004]: transport buttons, day/time display

---

## QA Test Cases

*Derived from GDD acceptance criteria. Visual/Feel story — manual verification plus automated tween-target logic where practical.*

- **AC2**: 金额滚动
  - Setup: game running, watch money Label; emit balance_changed (+100)
  - Verify: number counts old→new over ~0.3s, Butter throughout; a decrease (spend) never flashes red
  - Pass condition: smooth ~0.3s count in Butter; no red/error flash on any change

- **Edge (rapid)**: 快速连续变化
  - Setup: fire several balance_changed in quick succession (e.g. +50, +30, +80 within one tick)
  - Verify: display targets the latest value; no backlog queue
  - Pass condition: final display equals the last value; animation doesn't linger through intermediate values

- **Edge (paused)**: 暂停中变化
  - Setup: pause the sim; trigger a sell refund (Economy.credit → balance_changed)
  - Verify: count tween still animates while paused
  - Pass condition: tween runs on render time; no dependency on tick advance

---

## Test Evidence

**Story Type**: Visual/Feel
**Required evidence**:
- `production/qa/evidence/hud-money-tween-evidence.md` — manual walkthrough / sign-off
- Automated coverage of the re-target logic where practical (e.g. `tests/unit/hud/money_tween_test.gd`)

**Status**: [ ] Not yet created

---

## Dependencies

- Depends on: Story 001 (top-bar layout + money Label binding to `balance_changed`)
- Unlocks: None directly (Story 003/004 parallel branches off Story 001)
