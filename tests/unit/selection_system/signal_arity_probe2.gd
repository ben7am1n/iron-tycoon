# tests/unit/selection_system/signal_arity_probe2.gd
# Standalone headless probe #2 — NOT a registered test.
# Verifies how TYPED receiving callables behave when the signal emits null
# (the deselect case of selection_changed). Determines whether the signal
# declaration can be typed (per Control Manifest preference) while still
# supporting selection_changed(null).
# Run: godot --headless --script tests/unit/selection_system/signal_arity_probe2.gd
extends SceneTree

class Emitter:
	extends RefCounted
	signal typed_four(a: int, b: EquipmentDef, c: Vector2i, d: int)
	signal untyped_four(a, b, c, d)


class TypedHandler:
	extends RefCounted
	var count := 0
	var first: Variant = "<unset>"
	func on_signal(a: int, b: EquipmentDef, c: Vector2i, d: int) -> void:
		count += 1
		first = a


class VariantHandler:
	extends RefCounted
	var count := 0
	var first: Variant = "<unset>"
	func on_signal(a, b, c, d) -> void:
		count += 1
		first = a


func _init() -> void:
	print("=== Signal Arity Probe 2 (receiver typing vs null) ===")
	var emitter := Emitter.new()

	# A) typed signal -> typed handler, emit 4 real args
	var h_a := TypedHandler.new()
	emitter.typed_four.connect(h_a.on_signal)
	emitter.typed_four.emit(7, null, Vector2i(1, 2), 90)
	print("[A] typed signal -> typed handler, emit(7, null, (1,2), 90): count=%d first=%s" % [h_a.count, str(h_a.first)])

	# B) typed signal -> typed handler, emit 1 arg null (deselect shape)
	var h_b := TypedHandler.new()
	emitter.typed_four.connect(h_b.on_signal)
	emitter.typed_four.emit(null)
	print("[B] typed signal -> typed handler, emit(null): count=%d first=%s" % [h_b.count, str(h_b.first)])

	# C) typed signal -> Variant handler, emit 1 arg null
	var h_c := VariantHandler.new()
	emitter.typed_four.connect(h_c.on_signal)
	emitter.typed_four.emit(null)
	print("[C] typed signal -> variant handler, emit(null): count=%d first=%s" % [h_c.count, str(h_c.first)])

	# D) untyped signal -> typed handler, emit 1 arg null
	var h_d := TypedHandler.new()
	emitter.untyped_four.connect(h_d.on_signal)
	emitter.untyped_four.emit(null)
	print("[D] untyped signal -> typed handler, emit(null): count=%d first=%s" % [h_d.count, str(h_d.first)])

	# E) typed signal -> typed handler whose params have defaults, emit(null)
	var h_e := TypedHandlerDefaults.new()
	var bound := Callable(h_e, "on_signal_defaults")
	emitter.typed_four.connect(bound)
	emitter.typed_four.emit(null)
	print("[E] typed signal -> typed-with-defaults handler, emit(null): count=%d first=%s" % [h_e.count, str(h_e.first)])

	print("=== Probe 2 complete ===")
	quit(0)


class TypedHandlerDefaults:
	extends RefCounted
	var count := 0
	var first: Variant = "<unset>"
	func on_signal_defaults(a: int = -1, b: EquipmentDef = null, c: Vector2i = Vector2i.ZERO, d: int = 0) -> void:
		count += 1
		first = a
