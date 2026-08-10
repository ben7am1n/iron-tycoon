# ADR-0010: Goal State and Reward Routing

## Status

Accepted

## Date

2026-08-10

## Context

A4 introduces short- and medium-term objectives without adding nondeterminism
or a second owner for economy, equipment, satisfaction, or expansion state.
Goals must survive old/new save round-trips, while claimed rewards must not be
duplicated or bypass existing transaction boundaries.

## Decision

- Goal definitions are ordered external data in `data/goals.json`. GoalSystem
  persists only mutable status/progress plus cumulative positive cash flow.
- Equipment count and satisfaction are read at the end of each fixed tick.
  Positive Economy cash flow and ExpansionSystem unlocks update synchronously
  through their typed signals. Goal rewards are excluded from cumulative income.
- Completion and claiming are separate states: `ACTIVE → COMPLETED → CLAIMED`.
  Money rewards call `Economy.credit()`; region rewards call the idempotent,
  prefix-preserving `ExpansionSystem.grant_unlock()` API.
- SaveLoad adds an optional `goals` contribution. Missing/empty data is the
  unambiguous pre-A4 state (all configured goals active, zero cumulative income).
- The minimal UI is a standalone read-only tracker plus claim button. It owns no
  progression data and calls only `GoalSystem.claim_goal()`.

## Consequences

- Goal progression consumes no RNG stream and is reproducible from identical
  inputs and signal order.
- A purchased region and a goal-granted region share the same expansion source
  of truth and geometry signal.
- Adding future definitions does not invalidate old saves: absent goal ids begin
  active, while unknown ids in a save are rejected as corrupt data.
