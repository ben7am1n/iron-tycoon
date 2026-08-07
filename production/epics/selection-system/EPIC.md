# Epic: SelectionSystem

> **Layer**: Presentation
> **GDD**: design/gdd/selection-system.md
> **UX Spec**: design/ux/selection-ui.md
> **Architecture Module**: SelectionSystem — `instance_id → data` mapping, current selection state; exposes `selection_changed(instance_id | null)` signal
> **Status**: Ready
> **Stories**: 5 stories created — see below

## Stories

| # | Story | Type | Status | ADR |
|---|-------|------|--------|-----|
| 001 | Selection Logic Core + Instance Mapping | Logic | Complete — 2026-08-07 (QA 终审 PASS, t_bcc85025) | ADR-0005, ADR-0006 |
| 002 | Input Bridge Node + Keyboard Handling | Integration | Complete — 2026-08-07 (QA 终审 PASS, t_ff6dffa5) | ADR-0005 |
| 003 | Sell Flow (Soft-Confirm + Refund) | Logic | Complete — 2026-08-07 (QA 终审 PASS, t_619fb7d1) | ADR-0005, ADR-0006 |
| 004 | Contextual Toolbar + Selection Cue + Move Handoff | UI | Complete — 2026-08-07 (QA 终审 PASS, t_8ea90d8d) | ADR-0005 |
| 005 | Load-Time Mapping Rebuild | Integration | Complete — 2026-08-07 (QA 终审 PASS, t_72129a26) | ADR-0005 |

## Overview

SelectionSystem lets the player inspect, move, and sell equipment that is already placed on the grid — the counterpart to PlacementSystem, which places new pieces from the shop. It reads GridSystem to resolve "what's at this cell" (`get_occupant_id`), maintains a single current selection, and offers Inspect / Move / Sell. It is an independent consumer of GridSystem (sibling of PlacementSystem), and owns no spatial state beyond "which instance is selected." Its `selection_changed` signal drives the Info Panel and lets other UI suppress conflicting modes. Per ADR-0005's bridge pattern it is a **RefCounted** logic object with a thin presentation-layer **bridge Node** (owned by the orchestrator) that forwards clicks/keys and owns the 2s sell-confirm timer. Economy's `credit()` path (ADR-0006, implemented as ECON-003 in Sprint 4) is the sell-back interface.

**⚠️ Engine note**: RefCounted logic system + bridge Node (no scene-tree presence in the logic object); keyboard via `_unhandled_key_input` on the bridge (focus-independent per Godot 4.6's dual-focus system); bridge owns timer creation (2s sell-confirm). `class_name` must follow `extends` immediately; under headless load use `preload` const aliases for cross-script references.

## Governing ADRs

| ADR | Decision Summary | Engine Risk |
|-----|-----------------|-------------|
| ADR-0005: Signal Bus & Event Routing | Input Bridge Pattern (§5): thin bridge Node owned by SimulationOrchestrator forwards `_unhandled_input` (mouse, screen→cell conversion) and `_unhandled_key_input` (keys, focus-independent); bridge owns timer creation (2s sell-confirm); typed signal connections only. | MEDIUM |
| ADR-0006: Economy Credit Interface | `Economy.credit(amount: int, reason: String) -> bool` — synchronous, mirrors `spend()`, rejects `amount <= 0`, emits `balance_changed` on success. Implemented in Sprint 4 (`src/systems/economy.gd`). | LOW |

## GDD Requirements

| TR-ID | Requirement | ADR Coverage |
|-------|-------------|--------------|
| TR-SEL-001 | Single-select (MVP); click placed=select, empty=deselect, different=direct swap; click selected=no-op | ADR-0005 ✅ |
| TR-SEL-002 | Three actions: Inspect (Info Panel), Move (hand off to PlacementSystem relocate), Sell (soft inline confirm) | ADR-0005 ✅ |
| TR-SEL-003 | Sell requires Economy credit path (synchronous, immediate); refund = int(round(0.5 * cost)) | ADR-0006 ✅ |
| TR-SEL-004 | Signal: selection_changed(instance_id, equipment_def, cell, rotation) or selection_changed(null) on deselect | ADR-0005 ✅ |
| TR-SEL-005 | Self-maintains instance_id -> {equipment_id, anchor, rotation} mapping via signals | ADR-0005 ✅ |
| TR-SEL-006 | Load-time mapping rebuild: after GridSystem.deserialize, iterate occupied cells, rebuild mapping | ADR-0005 ✅ |
| TR-SEL-007 | Sells contribute nothing to save file; mapping rebuilt from GridSystem on load | ADR-0005 ✅ |
| TR-SEL-008 | RefCounted; no scene-tree; bridge Node forwards clicks/key events and owns 2s sell-confirm timer | ADR-0005 ✅ |
| TR-SEL-009 | Keyboard: Esc=deselect/cancel sell-confirm; Del=triggers Sell soft-confirm (no instant destructive sell) | ADR-0005 ✅ |
| TR-SEL-010 | Selection cue: Soft Charcoal outline + tint glow + corner icon; slow ~1.5s breathe, no flash; colorblind-safe | ADR-0005 ✅ |

## Definition of Done

This epic is complete when:
- All stories are implemented, reviewed, and closed via `/story-done`
- All acceptance criteria from `design/gdd/selection-system.md` (AC1–AC15) are verified
- `src/systems/selection_system.gd` (RefCounted) + bridge Node exist; `selection_changed` fires with correct arity
- Sell flow credits Economy exactly `int(round(refund_rate × cost))` once, via `Economy.credit()`
- Load-time mapping rebuild wired into SaveLoad Phase B load order (after GridSystem deserialize, before session unpause)
- Logic stories have automated coverage in `tests/`; UI stories have evidence docs in `production/qa/evidence/`

## Next Step

Work through stories in order — each story's `Depends on:` field tells what must be DONE before it can start.
