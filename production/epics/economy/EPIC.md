# Epic: Economy

> **Layer**: Feature
> **GDD**: design/gdd/economy.md
> **Architecture Module**: Economy — owns `balance: int`; exposes `can_afford(amount)`, `spend(amount)`, `credit(amount, reason)`, `balance_changed(new, delta)` signal
> **Status**: Ready
> **Stories**: 4 stories created — see below

## Stories

| # | Story | Type | Status | ADR |
|---|-------|------|--------|-----|
| 001 | Balance and Flat-Fee Revenue | Logic | Complete — 2026-08-02 | ADR-0005, ADR-0006 |
| 002 | spend() and can_afford Triple-Gating | Logic | Complete — 2026-08-03 | ADR-0006 |
| 003 | credit() Interface and No-Satisfaction Structure | Logic | Ready | ADR-0006 |
| 004 | Serialization, Determinism and No-Decay | Integration | Ready | ADR-0002, ADR-0005, ADR-0006 |

## Overview

Economy is the money resource and revenue engine that closes the MVP loop: a good layout raises satisfaction, satisfaction brings more members, more members completing visits earns more cash, and cash buys more/better equipment to improve the layout again. It owns exactly one piece of state — the player's cash `balance` (an integer) — and one job: accrue income when members complete their visits, and let Shop/Purchase spend it. Pillar 2 constraint: money is a purely additive, positive resource — no rent, no upkeep, no bankruptcy, no lose condition. Revenue is a flat fee per completed visit (quota-met departures only) with **zero** reference to satisfaction — satisfaction's only economic lever is throughput, keeping the loop auditable and non-runaway.

**⚠️ Serialization schema note**: `src/systems/economy.gd` (real ledger, landed story 001) keeps the stub-era payload `{counter, balance, rng_state}` because the save-load AC7 tests require the "Economy" RNG sub-stream state to round-trip exactly. The GDD's "serialize ONLY `balance: int`" schema change is owned by story 004 (Serialization, Determinism and No-Decay) — coordinate with SaveLoad (`tests/integration/save_load/`) when it lands.

## Governing ADRs

| ADR | Decision Summary | Engine Risk |
|-----|-----------------|-------------|
| ADR-0002: Storage Format | Serialize ONLY `balance: int` — trivial exact round-trip, no derived state. Integer money never float. | LOW |
| ADR-0005: Signal Bus & Event Routing | Economy is the fourth (last) system in the hardcoded tick dispatch. Subscribes to `member_completed_visit(member_id)` (S5) — sole revenue trigger. Emits `balance_changed(new_balance, delta)` (S6) after every balance mutation with a signed delta. | LOW |
| ADR-0006: Economy Credit Interface | `credit(amount: int, reason: String) -> bool` — symmetric counterpart to `spend()`. Rejects `amount <= 0`, adds to balance, emits `balance_changed` with positive delta, `reason` audit-only. Refund formula (`floor(0.5 × cost)`) owned by SelectionSystem, never Economy. Never call `spend(-refund)` as a credit workaround. | LOW |

## GDD Requirements

| TR-ID | Requirement | ADR Coverage |
|-------|-------------|--------------|
| TR-ECON-001 | Tick-driven, runs after Satisfaction; deterministic, no RNG | ADR-0005 ✅ |
| TR-ECON-002 | balance: int (never float); revenue = flat fee R_visit ($12) per quota-met completed visit | ADR-0005, ADR-0006 ✅ |
| TR-ECON-003 | Only quota-met departures earn revenue; walk-failure/patience-exhausted earn $0 | ADR-0005 ✅ |
| TR-ECON-004 | Revenue contains zero reference to satisfaction -- single-channel throughput decoupling | ADR-0005 ✅ |
| TR-ECON-005 | starting_capital = $500; balance floor = 0 (defensive max(0, balance)); no upkeep (MVP) | ADR-0006 ✅ |
| TR-ECON-006 | spend(amount) triple-gated: amount > 0, amount <= balance, Shop pre-checks can_afford; rejects amount <= 0 | ADR-0006 ✅ |
| TR-ECON-007 | emit balance_changed(new_balance, delta) on income and spend | ADR-0005, ADR-0006 ✅ |
| TR-ECON-008 | credit(amount, reason) method for sell-back refunds (SelectionSystem consumer) | ADR-0006 ✅ |
| TR-ECON-009 | Serialize ONLY balance: int -- trivial exact round-trip | ADR-0002 ✅ |

## Definition of Done

This epic is complete when:
- All stories are implemented, reviewed, and closed via `/story-done`
- All unit acceptance criteria from `design/gdd/economy.md` are verified (AC1–AC14); integration AC15 advisory
- `src/systems/economy.gd` stub is fully replaced by the real ledger, preserving the SaveLoad contract surface (schema change to `{balance}` coordinated with save-load)
- All Logic stories have passing test files in `tests/unit/economy/`
- Signal emit arity verified for `balance_changed` (2 args) via GUT spy test; `member_completed_visit` subscription wired
- AC12 serialization round-trip and AC6 determinism pass

## Next Step

Work through stories in order — each story's `Depends on:` field tells what must be DONE before it can start.
