## Base class for all simulation systems.
##
## Enforces a two-phase init pattern:
##   1. init(...)       — stores typed dependencies (declared per-subclass,
##                         NOT on this base class — see note below)
##   2. _post_init()    — side effects, called by orchestrator after all systems exist
##
## Every public method on a subclass must call _assert_initialized() before
## executing any logic, and return its documented safe default immediately
## if it returns false — the guard only logs, it does not halt execution.
##
## Why this base class does not declare a shared init(...) method: each
## concrete system needs its own typed init(...) signature (per ADR-0001,
## e.g. PlacementSystem.init(grid, catalog)). Godot 4.7.1's GDScript static
## type checker rejects a subclass override whose parameter list differs
## from a same-named parent method ("The function signature doesn't match
## the parent") — a parse-time error, not a warning — so a base-class
## init(...) would break any subclass needing different parameters.
## Subclasses instead define their own init(...) with whatever signature
## they need and call _mark_initialized() internally as the first step.
## This is a separate concern from the _init() guard below: _init() is
## GDScript's real constructor (never overridden by subclasses here, so no
## signature conflict), used only to block direct SimSystem instantiation.
class_name SimSystem extends RefCounted

var _initialized: bool = false


## Manual guard: prevents direct instantiation of the base class.
## @abstract is NOT used — verified non-functional on RefCounted in Godot
## 4.7.1 (see ADR-0001 §2). Subclasses never override _init(), so this
## always runs on construction; get_script() returns the base class only
## when SimSystem itself is instantiated directly.
func _init() -> void:
	if get_script() == SimSystem:
		push_error("SimSystem is abstract — do not instantiate directly")


## Marks the system as initialized. Returns true if this call took effect,
## false if the system was already initialized (in which case a push_error
## was already logged — the caller must not proceed to set up state).
## Call this as the first step of every subclass's init(...) override.
func _mark_initialized() -> bool:
	if _initialized:
		push_error("SimSystem: init() called twice.")
		return false
	_initialized = true
	return true


func _post_init() -> void:
	pass


## Guards every public method against use-before-init.
## Returns true if the system is initialized (caller should proceed);
## false if not (caller must return its documented safe default immediately
## without executing further logic — this only logs, it does not throw).
func _assert_initialized() -> bool:
	if not _initialized:
		push_error("SimSystem: method called before init().")
		return false
	return true


## Returns a short name for logging/debug (e.g. "GridSystem").
## Override in subclasses.
func system_name() -> String:
	return "SimSystem"
