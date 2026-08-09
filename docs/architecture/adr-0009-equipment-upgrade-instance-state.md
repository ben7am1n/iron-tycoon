# ADR-0009: Equipment Upgrade Instance State

## Status

Accepted

## Date

2026-08-10

## Context

A2 adds mutable levels to placed equipment while `EquipmentCatalog` must stay
immutable. Levels must survive save/load, relocation, and equipment removal,
and must feed both MemberSim target weights and Economy visit revenue without
adding RNG or a second save-state owner.

## Decision

- `PlacementRecord.level` is the single persistent source of truth. Level 1 is
  implicit in serialized grid records; levels above 1 write a `level` field.
  Missing fields therefore load as L1 and old save blobs remain compatible.
- `EquipmentUpgradeSystem` owns formulas and the paid upgrade transaction, but
  owns no serialized state. It reads/writes levels only through GridSystem and
  spends only through Economy's public API.
- MemberSim multiplies target weights by the current instance attraction
  multiplier. When a use finishes it snapshots that equipment level on the
  member; Economy reads the snapshot on quota-met departure. This preserves
  deterministic revenue even if the machine is moved or sold while the member
  walks to the exit.
- Upgrade tuning is externalized in `data/equipment_upgrades.json`.

## Consequences

- SaveLoad's fixed eight-key envelope and version remain unchanged because the
  level travels inside the existing `grid_system` contribution.
- Relocation must preserve the level across its temporary clear/recommit.
- Grid occupancy/path signals do not fire for level-only changes.
- The catalog remains a read-only definition source; no instance state leaks
  into `EquipmentDef`.
