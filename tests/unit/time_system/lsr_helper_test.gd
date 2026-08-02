# tests/unit/time_system/lsr_helper_test.gd
# Story 003: SeededRNG — lsr() logical right-shift helper (AC-LSR-1).
#
# Covers: AC-LSR-1 (lsr(0x8000000000000000, 30) == 0x0000000200000000),
# shift=1 high-bit, shift=63, all-zeros input, and a table of known values
# cross-checked against an independent Python reference implementation
# (ADR-0004 Validation Criteria #4).
#
# WHY THE LITERALS DIFFER FROM THE STORY SAMPLE (engine fact, verified on
# 4.7.1 before this file was written): GDScript hex literals that exceed
# INT64_MAX are REJECTED at parse time and the value silently clamps to
# INT64_MAX (0x7FFF...). So 0x8000000000000000 cannot be written as a literal
# here — it is spelled as its signed two's-complement equivalent
# -9223372036854775808 (INT64_MIN), which has the identical bit pattern.
# The AC-LSR-1 expected result 0x0000000200000000 = 8589934592 fits in int64
# and is written as a normal literal.
#
# The invalid-shift assertions (shift=0, shift=64) live in
# seeded_rng_error_probe.gd — calling lsr(_, 0) in-process would fire an
# assert, which in Godot 4.7.1 aborts the rest of the CURRENT function frame
# (see grid_rotation_assert_probe.gd header for the full empirical finding).
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"

const INT64_MIN := -9223372036854775808          # 0x8000000000000000
const INT64_MAX := 9223372036854775807           # 0x7FFFFFFFFFFFFFFF
const AC_LSR1_EXPECTED := 8589934592             # 0x0000000200000000

var _pass := 0
var _fail := 0


func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	var result := run_all()
	quit(1 if int(result["fail"]) > 0 else 0)


func run_all() -> Dictionary:
	print("=".repeat(48))
	print("  UNIT TEST: SeededRNG — lsr() logical right shift (Story 003)")
	print("=".repeat(48))

	_test_ac_lsr_1_high_bit_shift_30()
	_test_lsr_contrast_arithmetic_shift()
	_test_lsr_shift_1_high_bit()
	_test_lsr_shift_63()
	_test_lsr_all_zeros()
	_test_lsr_known_value_table()

	print("\n=== LSR HELPER TEST: %d passed, %d failed ===" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


func _lsr(value: int, shift: int) -> int:
	var SRG: Script = load("res://src/systems/seeded_rng.gd") as Script
	return SRG.lsr(value, shift)


# === AC-LSR-1: 高位 set 的 int64 逻辑右移 30 位 ===

func _test_ac_lsr_1_high_bit_shift_30() -> void:
	print("\n[AC-LSR-1] lsr(0x8000000000000000, 30) == 0x0000000200000000")
	print("  (0x8000000000000000 spelled as INT64_MIN = -9223372036854775808 — signed int64 literal)")

	var result := _lsr(INT64_MIN, 30)
	_check(
		result == AC_LSR1_EXPECTED,
		"lsr(INT64_MIN, 30) == %d (0x%x) — got %d (0x%x)" % [AC_LSR1_EXPECTED, AC_LSR1_EXPECTED, result, result]
	)
	_check(
		result == 0x200000000,
		"value also equals 0x200000000 (zero-filled, NOT sign-extended)"
	)


# === 对照：native >> 是算术移位（符号扩展），lsr 必须与其不同 ===

func _test_lsr_contrast_arithmetic_shift() -> void:
	print("\n[contrast] native >> sign-extends; lsr() zero-fills")

	# NOTE: GDScript rejects CONSTANT-FOLDED negative shifts at parse time
	# ("Only positive operands are supported") — the shift must go through a
	# runtime variable, exactly as it does inside the implementation.
	var v: int = INT64_MIN
	var native: int = v >> 30
	_check(
		native == -8589934592,
		"native INT64_MIN >> 30 == -8589934592 (0xFFFFFFFFE0000000, sign-extended) — proves >> is arithmetic"
	)
	_check(
		_lsr(INT64_MIN, 30) != native,
		"lsr(INT64_MIN, 30) != native >> 30 — the helper exists precisely because they differ"
	)
	_check(
		(_lsr(INT64_MIN, 30) & (1 << 63)) == 0,
		"lsr result has high bit clear (zero-filled), unlike sign-extended native shift"
	)


# === Edge: shift=1 on high-bit value ===

func _test_lsr_shift_1_high_bit() -> void:
	print("\n[edge] lsr(0x8000000000000000, 1) — high bit shifts into bit 62")

	var result := _lsr(INT64_MIN, 1)
	_check(
		result == 4611686018427387904,
		"lsr(INT64_MIN, 1) == 0x4000000000000000 (%d) — got %d" % [4611686018427387904, result]
	)
	var v: int = INT64_MIN
	var native: int = v >> 1
	_check(
		native == -4611686018427387904,
		"native INT64_MIN >> 1 == -4611686018427387904 (0xC000000000000000) — arithmetic keeps top two bits set"
	)


# === Edge: shift=63 — only the sign bit survives ===

func _test_lsr_shift_63() -> void:
	print("\n[edge] lsr(0x8000000000000000, 63) — maximal valid shift")

	var result := _lsr(INT64_MIN, 63)
	_check(
		result == 1,
		"lsr(INT64_MIN, 63) == 1 (0x...0001) — got %d" % result
	)
	_check(
		_lsr(INT64_MAX, 63) == 0,
		"lsr(INT64_MAX, 63) == 0 (0x7FFF... shifted 63 right = 0) — got %d" % _lsr(INT64_MAX, 63)
	)


# === Edge: all-zeros input ===

func _test_lsr_all_zeros() -> void:
	print("\n[edge] lsr(0, k) == 0 for all valid k")

	for shift in [1, 5, 30, 47, 63]:
		_check(
			_lsr(0, shift) == 0,
			"lsr(0, %d) == 0" % shift
		)


# === 已知值表：与独立 Python 参考实现交叉验证（ADR-0004 Validation #4）===

func _test_lsr_known_value_table() -> void:
	print("\n[table] lsr() vs Python reference — values with high bit, all-ones, mixed bits")

	# (value, shift, expected) — expected computed by unsigned 64-bit >> in Python
	var cases := [
		[INT64_MIN, 5, 288230376151711744],          # 0x0400000000000000
		[INT64_MIN, 47, 65536],                      # 0x00010000
		[-1, 1, INT64_MAX],                          # 0xFFFFFFFFFFFFFFFF >> 1
		[-1, 30, 17179869183],                       # 0x3FFFFFFFF
		[-1, 63, 1],
		[-1, 5, 576460752303423487],                 # 0x07FFFFFFFFFFFFFF
		[0x123456789ABCDEF0, 1, 655884233731895160],
		[0x123456789ABCDEF0, 30, 1221679586],
		[0x123456789ABCDEF0, 63, 0],
		[0x123456789ABCDEF0, 47, 9320],
		[12345, 1, 6172],
		[12345, 30, 0],
		[12345, 5, 385],
		[-123456789012345, 1, 9223310308460269635],
		[-123456789012345, 30, 17179754205],
		[-123456789012345, 47, 131071],
	]
	for c in cases:
		var got := _lsr(c[0], c[1])
		_check(
			got == c[2],
			"lsr(%d, %d) == %d — got %d" % [c[0], c[1], c[2], got]
		)
