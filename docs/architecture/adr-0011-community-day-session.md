# ADR-0011 — Community day session and presentation boundary

## Status

Accepted for the authorized first-day prototype, 2026-09-06. This is an implementation decision under the user's instruction to execute M0, first-day gameplay, then the visual sample. It does not claim player acceptance of the completed game.

## Context

[Gym Adventure](../../design/gdd/gym-adventure.md) adds a controllable coach, a park activity, a scheduled four-person course and a closing conversation to the existing sandbox. MemberSim, Navigation, GridSystem, Economy and the existing world renderer must remain useful; a disconnected demonstration UI would not validate the designed loop. M0 restoration fixes must pass before this new mode is integrated.

## Decision

1. `SimulationOrchestrator` owns an optional `day_cycle` reference. When absent, the sandbox retains its current dispatch and configuration. When present, it explicitly runs the community session stages. TimeSystem remains the only fixed 0.1-second clock; PREP/CLOSE suppress service simulation while allowing coach commands, whereas user pause/focus loss freezes all simulation. New-mode running speed is always 1x.
2. `DayCycleSystem` is the command/read facade and owns day/phase, story events, roster schedule, course/outing/coach state (small composed helpers may own their respective serialized subobjects). It receives existing systems through `init(config, fixture, orchestrator)` and never exposes mutable state to UI. Its API is `command(action: String, payload: Dictionary = {}) -> Dictionary` (`ok`, `errors`) and `get_view_state() -> Dictionary` (deep read copy). It has JSON-safe `serialize` and zero-mutation `deserialize(..., validate_only)`.
3. The public view contains `phase`, `day`, `service_seconds`, `balance`, `build_allowed`, `coach`, `outing`, `course`, `request`, `story`, and a player-facing `objective`. The command vocabulary covers `depart`, `return_to_gym`, `start_challenge`, `practice`, `finish_challenge`, `set_pace`, `move`, `interact`, `choose_guidance`, `confirm_timing`, `next_day`, `restore_layout`, and `select_course`. Invalid phase/action combinations return errors and do not mutate state. Implementer and UI owner must record exact payload fields together before integration.
4. MemberSim remains the sole owner of gym member positions and equipment occupancy/queue claims. Its new-mode API accepts scheduled visitors and course tasks; Course never edits member dictionaries from outside. Course-level device holds supplement individual reservations and block new ordinary claims while allowing old claims to drain. Members move at the data-defined rate, accumulating distance rather than taking a whole grid step every tick. Existing members remain visible through WorldCanvas.
5. The new-mode tick order is commands/DayCycle preparation, MemberSim, Congestion, course facts/Satisfaction, Economy, then relationship/closing and `tick_completed`. Outside SERVICE only coach/outing/session timers advance. Course fees and ordinary fees are exclusive; Economy is the sole balance and transaction-key owner, consumes completion facts in its tick, and serializes deduplication state. Sandbox synchronous S5 behavior remains unchanged.
6. SaveLoad adds a mode-scoped optional community payload, requiring it when loading into community mode and rejecting cross-mode loads before mutation. Complete new state is validated with existing payloads before any commit. Main's existing save controls use separate sandbox/community names; manual and phase saves share the same complete serializer. Restore paused; input-held flags are cleared, while unfinished challenge/interaction progress is preserved.
7. The first playable target uses a data-defined 13×10 room and two borrowed fixtures (treadmill and yoga mat), one endurance course, one park route and the first-day Aluo conversation. Purchases/placement reuse existing systems during PREP. Borrowed ownership/restore rules and stored purchased items are persistent, with no duplicated active grid state. Additional course/story content remains M3 work. The fixture must actually finish a four-member AUTO class with zero purchases.
8. Main and a dedicated community HUD/input controller only send commands and render views. `WorldCanvas` continues to render the real gym, an additional coach layer renders the protagonist, and a park view renders the route with live movement and pacing. No engine Node or renderer owns billing, course scores or story flags. Key release/focus loss must clear movement even when GUI consumes input.

## Engine Compatibility

Use the local Godot 4.7.1 reference and installed engine to verify existing Node, Control, FileAccess, JSON and drawing APIs. No new plugin or engine migration. Headless tests verify state boundaries; actual-window evidence verifies controls and art. Prototype visuals reuse current pixel rendering before new asset work.

## Dependencies and scope

Depends on ADR-0001/0002/0003/0004/0005/0006/0009. Extends ADR-0005 only for the optional community branch. Governs GA-003 (logic), GA-004 (playable presentation) and GA-005 (two-device visual sample). Existing sandbox tests remain mandatory. No production-quality art or external five-player study is implied by prototype completion.

## Verification

Exercise real scheduled members through four alternating blocks, class hold/release and late arrival; first-day flow and skipping park; monetary thresholds and duplicate events; paused and cold disk restoration during park/course/coaching; a no-purchase fixture baseline; actual keyboard/mouse controls and scene screenshots. Failure of the no-purchase baseline requires fixing fixture/timing, not replacing member movement with scripted progress bars.
