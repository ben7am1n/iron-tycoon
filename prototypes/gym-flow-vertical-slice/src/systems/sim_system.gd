## Base class for all simulation systems.
##
## SimSystem extends RefCounted and enforces a two-phase init pattern:
##   1. [user calls] init(...)     — stores typed dependencies
##   2. [orchestrator calls] _post_init() — side effects after ALL systems exist
##
## Uses a manual _init() guard instead of @abstract because @abstract is
## non-functional on RefCounted in Godot 4.7.1 (Node/Control only).
##
## Every public method on a subclass must call _assert_initialized() before
## executing any logic. This prevents silent failures when a system is
## constructed but not wired.
class_name SimSystem extends RefCounted

var _initialized := false


## Guards against direct instantiation of SimSystem base class.
## Subclasses pass through — get_script() returns the subclass script,
## not sim_system.gd. Only a direct SimSystem.new() triggers the guard.
func _init() -> void:
	var script_path := get_script().resource_path if get_script() else ""
	if script_path.ends_with("sim_system.gd"):
		push_error("SimSystem: cannot instantiate base class directly. Subclass and call init().")
		return


## Called exactly once per system instance.
## Stores dependencies and sets _initialized = true.
## Does NOT call _post_init() — that is deferred to SimulationOrchestrator
## which calls _post_init() on all systems after every system's init()
## has completed. This guarantees cross-system dependencies are ready
## before any side effects execute.
## Calling init() on an already-initialized system is a hard error.
func init() -> void:
	if _initialized:
		push_error("%s: init() called twice — each system must be initialized exactly once." % _class_name())
		return
	_initialized = true


## Override in subclasses that need post-init side effects
## (signal connections, register_system() calls, etc.).
## Called automatically by init() after _initialized is set.
## Stateless systems (e.g., ZoneRules) may omit this override.
func _post_init() -> void:
	pass


## Asserts that init() has been called. Call this at the start of every
## public method on SimSystem subclasses to guard against use-before-init.
func _assert_initialized() -> void:
	if not _initialized:
		push_error("%s: method called before init(). Call init() first." % _class_name())


func _class_name() -> String:
	var script := get_script() as Script
	if script:
		return script.resource_path.get_file().get_basename()
	return "SimSystem"
