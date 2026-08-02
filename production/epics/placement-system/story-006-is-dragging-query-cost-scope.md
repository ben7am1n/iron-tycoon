# Story 006: is_dragging Query and Cost Scope

> **Epic**: placement-system
> **Status**: Complete
> **Layer**: Core
> **Type**: Logic
> **Estimate**: S — 1 session (≤2h)
> **Manifest Version**: 2026-07-23
> **Last Updated**: 2026-08-02

## Context

**GDD**: `design/gdd/placement-system.md`
**Requirements**: `TR-PS-009`, `TR-PS-010`
*(Requirement text lives in `docs/architecture/tr-registry.yaml` — read fresh at review time)*

**ADR Governing Implementation**: ADR-0001: DI Container & Scene Bootstrap
**ADR Decision Summary**: `is_dragging() -> bool` is a public, synchronous, side-effect-free state query on the RefCounted system, required by Shop/Purchase (#12) before it starts a purchase drag — it lets callers detect the silent no-op behavior of a second mouse-down while DRAGGING. Cost/affordability is explicitly out of PlacementSystem's scope: the constructor/DI signature must accept no currency/wallet dependency of any kind; any drag received is assumed pre-cleared by Shop/Build-UI.

**Engine**: Godot 4.7.1 | **Risk**: LOW
**Engine Notes**: Static API-surface assertions are implemented as code-inspection tests in GUT (parse the script's methods), not runtime behavior tests. RefCounted systems are constructed directly in tests with mocked dependencies.

**Control Manifest Rules (Core layer)**:
- Required: Every public method on a SimSystem subclass must guard against use-before-init
- Forbidden: Never use Autoload singletons for system access — dependencies arrive via typed `init()` parameters

---

## Acceptance Criteria

*From GDD `design/gdd/placement-system.md`, scoped to this story:*

- [ ] AC14 GIVEN PlacementSystem's constructor/DI signature, WHEN inspected, THEN it accepts no currency/wallet dependency of any kind (static/API-surface check — not a per-drag behavioral test)
- [ ] AC28 GIVEN state is `IDLE`, WHEN `is_dragging()` is called, THEN it returns `false` with no state change and no side effects
- [ ] AC29 GIVEN state is `DRAGGING` (either a new-placement drag or a relocate), WHEN `is_dragging()` is called at any point mid-drag, THEN it returns `true` with no state change and no side effects

---

## Implementation Notes

*Derived from ADR-0001 Implementation Guidelines:*

**is_dragging (Core Rule 10):**
- Pure, synchronous, side-effect-free read — never mutates state, callable at any time including mid-drag
- Returns `true` whenever internal state is DRAGGING (new-placement or relocate, any source); `false` when IDLE
- Exists because the second-mouse-down no-op (Core Rule 11) is silent — callers must check *before* attempting, not rely on a rejection signal that will never come

**Cost scope (Core Rule 9):**
- No currency/wallet dependency in the `init()` signature — verified statically
- PlacementSystem performs no currency check and deducts no cost; affordability-clearing is Shop/Build-UI's domain
- The `init()` signature carries exactly: GridSystem + EquipmentCatalog (and the bridge is owned by the composition root, not injected here)

**Use-before-init guard:**
- `is_dragging()` is a public method — it must guard against use-before-init like every public method on a SimSystem subclass (per control manifest)

---

## Out of Scope

*Handled by neighbouring stories — do not implement here:*

- [Story 001–005]: the drag state machine this query reflects
- [Shop/Purchase epic]: `can_purchase` / `is_unlocked` / `_purchase_in_flight` — the caller that consumes `is_dragging()`
- [Build/Shop UI epic]: palette affordability check before drag initiation

---

## QA Test Cases

*Written by qa-lead at story creation. The developer implements against these — do not invent new test cases during implementation.*

- **AC14**: 无货币依赖
  - Given: PlacementSystem init() signature
  - When: statically inspected
  - Then: no currency/wallet/economy parameter appears in the signature
  - Edge cases: verify no hidden Economy/balance field either (full API surface scan)

- **AC28**: IDLE 时 is_dragging 为 false
  - Given: state IDLE
  - When: is_dragging() called
  - Then: returns false; no state change; no signals emitted
  - Edge cases: call twice (idempotent); call after a completed drag (back to IDLE → false)

- **AC29**: DRAGGING 时 is_dragging 为 true
  - Given: state DRAGGING (new-placement drag)
  - When: is_dragging() called at any point mid-drag
  - Then: returns true; no state change; no side effects
  - Edge cases: relocate drag also returns true; call between preview and commit; call during rotate

---

## Test Evidence

**Story Type**: Logic
**Required evidence**:
- `tests/unit/placement_system/is_dragging_cost_scope_test.gd` — must exist and pass

**Status**: [x] Created and passing — tests/unit/placement_system/is_dragging_cost_scope_test.gd — 30 assertions, 0 failures; full suite 2394/0, exit 0 (2026-08-02)

---

## Dependencies

- Depends on: Story 001 (DRAGGING state enters/exits)
- Unlocks: Shop/Purchase integration (the `is_dragging()` consumer), Story 007 (bridge integration)
