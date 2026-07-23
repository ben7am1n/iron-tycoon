## Base class for all simulation systems.
##
## Enforces a two-phase init pattern:
##   1. init(...)       — stores typed dependencies
##   2. _post_init()    — side effects, called by orchestrator after all systems exist
##
## Every public method on a subclass must call _assert_initialized() before
## executing any logic.
extends RefCounted

var _initialized: bool = false


func init() -> void:
	if _initialized:
		push_error("SimSystem: init() called twice.")
		return
	_initialized = true


func _post_init() -> void:
	pass


func _assert_initialized() -> void:
	if not _initialized:
		push_error("SimSystem: method called before init().")
