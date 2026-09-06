# First-day runtime interface — GA-003 / GA-004

`src/systems/day_cycle_system.gd` is a RefCounted facade. Construct after the
existing systems are wired, then call `init(config, fixture, orchestrator)` once.
This configures MemberSim/Economy community mode, places the baseline fixtures
and attaches `orchestrator.day_cycle`. Construct SaveLoad AFTER this init.
No extra member simulator is created. Main supplies the configured existing
Navigation/MemberSim/Congestion/Satisfaction/Economy and catalog.

`command(action: String, payload: Dictionary = {}) -> Dictionary` returns
`{ok: bool, errors: Array}`. Only this API mutates session gameplay from UI.

| Action | Payload / semantics |
|---|---|
| depart | PREP → OUTING |
| return_to_gym | PREP/OUTING → SERVICE; during formal attempt requires `confirm:true` |
| start_challenge | OUTING, one formal attempt per day |
| practice | OUTING, resets practice run without changing formal result |
| finish_challenge | OUTING, submit current run, remain in OUTING |
| set_pace | `pace:"walk" / "jog" / "sprint"` |
| move | `x:float,y:float` normalized held direction; zero on key release/focus loss |
| interact | OUTING meets Aluo; SERVICE begins nearby member request; CLOSE advances closing exchange |
| choose_guidance | `choice:"maintain" / "slow" / "rest"`; active course decision has priority unless individual interaction already started |
| confirm_timing | Confirm active individual timing once |
| next_day | CLOSE → next PREP |
| restore_layout | PREP, `confirm:true`; restores loans and stores purchases |
| select_course | PREP, `course_id:"course_endurance_intro"` |

`get_view_state()` returns a deep copy, JSON-safe coordinates as `[x,y]`.

```
phase: PREP | OUTING | SERVICE | CLOSE
day: int
service_seconds: float
balance: int
build_allowed: bool
objective: String
coach: {position:[x,y], scene:"gym"|"park", direction:[x,y]}
outing: {active:bool, practice:bool, seconds:float, progress_m:float,
         position:[x,y], pace:String, stamina:float, score:int,
         result:Dictionary, target_mps:float, finished:bool}
course: {status:"scheduled"|"running"|"completed"|"canceled",
         start_seconds:float, block:int, block_seconds:float,
         training_seconds:Array[float], quality:int,
         guidance:Dictionary, devices:Array[int], members:Array[int]}
request: {} | {member_id:int, state:String, status:"waiting"|"choice"|"timing",
                seconds:float, timing_seconds:float, correct_choice:String}
story: {events:Array[String], closing_text:String, feedback:Array}
```

View `course.guidance` is `{}` or `{state:String, seconds_left:float}`. Real gym
visitors remain in `orchestrator.member_sim.members` for the existing renderer.
Coach coordinates are grid cells in gym and meters in park. Park route coordinates
and total length come from runtime config, with a corridor-constrained route.
UI must not animate timers into state or mutate returned Dictionaries.

Pause remains TimeSystem.pause/resume. Running community speed is clamped 1x.
`phase_changed(phase:String)` is emitted after command/phase completion and may
request an autosave; all activity state uses the existing SaveLoad envelope.
Main uses a separate community slot. An initial PREP starts paused; commands
that begin OUTING/SERVICE resume the simulation. Cold load always restores paused.

This is the first-day implementation contract; subsequent days replay the core
service loop and preserve Aluo flags. Full band-event chapters remain outside GA-003.
