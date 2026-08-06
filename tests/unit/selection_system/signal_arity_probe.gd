# tests/unit/selection_system/signal_arity_probe.gd
# Standalone headless probe — NOT a registered test.
# Verifies Godot 4.7.1 signal emit arity behavior for the selection_changed
# contract (TR-SEL-004): "selection_changed(instance_id, equipment_def, cell,
# rotation) or selection_changed(null) on deselect" — one signal, two arities.
# Run: godot --headless --script tests/unit/selection_system/signal_arity_probe.gd
extends SceneTree

## A probe object with a 4-arg signal and a 1-arg signal.
class Emitter:
	extends RefCounted
	signal four_arg(a, b, c, d)
	signal one_arg(a)
	signal typed_four_arg(a: int, b: int, c: int, d: int)


## Spy that accepts 4 args.
class Spy4:
	extends RefCounted
	var count := 0
	var args: Array = []
	func on_signal(a = null, b = null, c = null, d = null) -> void:
		count += 1
		args = [a, b, c, d]


## Spy that accepts 1 arg.
class Spy1:
	extends RefCounted
	var count := 0
	var args: Array = []
	func on_signal(a = null) -> void:
		count += 1
		args = [a]


func _init() -> void:
	print("=== Signal Arity Probe (4.7.1) ===")
	var emitter := Emitter.new()

	# 1) 4-arg signal, emit with 4 args
	var spy4 := Spy4.new()
	emitter.four_arg.connect(spy4.on_signal)
	emitter.four_arg.emit(7, "def", Vector2i(3, 4), 90)
	print("[1] emit 4 args -> spy4.count=%d args=%s" % [spy4.count, str(spy4.args)])

	# 2) 4-arg signal, emit with 1 arg (null) — TR-SEL-004 deselect shape
	var spy4b := Spy4.new()
	emitter.four_arg.connect(spy4b.on_signal)
	emitter.four_arg.emit(null)
	print("[2] emit 1 arg (null) -> spy4b.count=%d args=%s" % [spy4b.count, str(spy4b.args)])

	# 3) 4-arg signal, emit with 0 args
	var spy4c := Spy4.new()
	emitter.four_arg.connect(spy4c.on_signal)
	emitter.four_arg.emit()
	print("[3] emit 0 args -> spy4c.count=%d args=%s" % [spy4c.count, str(spy4c.args)])

	# 4) 1-arg signal, emit with 1 arg
	var spy1 := Spy1.new()
	emitter.one_arg.connect(spy1.on_signal)
	emitter.one_arg.emit(null)
	print("[4] emit 1 arg -> spy1.count=%d args=%s" % [spy1.count, str(spy1.args)])

	# 5) 4-arg signal connected to a 1-arg callable, emit 4 args
	var spy1b := Spy1.new()
	emitter.four_arg.connect(spy1b.on_signal)
	emitter.four_arg.emit(7, "def", Vector2i(3, 4), 90)
	print("[5] emit 4 args into 1-arg callable -> spy1b.count=%d args=%s" % [spy1b.count, str(spy1b.args)])

	# 6) typed 4-arg signal, emit with 1 arg (null) — does the type declaration matter?
	var spy4d := Spy4.new()
	emitter.typed_four_arg.connect(spy4d.on_signal)
	emitter.typed_four_arg.emit(null)
	print("[6] typed 4-arg signal, emit 1 arg -> spy4d.count=%d args=%s" % [spy4d.count, str(spy4d.args)])

	# 7) emit too MANY args — what error?
	var spy4e := Spy4.new()
	emitter.four_arg.connect(spy4e.on_signal)
	emitter.four_arg.emit(1, 2, 3, 4, 5)
	print("[7] emit 5 args into 4-arg signal -> spy4e.count=%d" % spy4e.count)

	print("=== Probe complete (errors above, if any, are expected for [7]) ===")
	quit(0)
