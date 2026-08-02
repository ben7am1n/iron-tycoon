# tests/unit/time_system/seeded_rng_substream_test.gd
# Story 003: SeededRNG and Sub-Stream Derivation
# Covers: AC6 (get_rng idempotent), AC7 (sub-stream independence, 1000 draws),
# AC13 (golden vector), AC15 (duplicate register asserts, get_rng repeated ok)
# + FNV-1a64 / SplitMix64 derivation pins and edge cases.
#
# GOLDEN-VECTOR FIRST per story: AC13 is the CANARY — if it fails on 4.7.1,
# the entire derivation formula needs re-evaluation before any other RNG test
# can be meaningful. It was computed by running this exact pipeline on
# Godot 4.7.1 (see the int64 probe) and cross-verified against an independent
# Python reference implementation (ADR-0004 Validation Criteria #1):
#   fnv1a64("Economy") = -4068960047718556969
#   derive_sub_seed(12345, "Economy") = -2878674041662682638
#
# ENGINE FACT (verified before writing): GDScript hex literals > INT64_MAX are
# REJECTED at parse time and silently clamp to INT64_MAX. All bit-pattern
# constants in the implementation use signed two's-complement spellings (e.g.
# 0xCBF29CE484222325 == -3750763034362895579). The golden vectors below pin
# the pipeline against those spellings — a regression to the naive unsigned
# literal would change every value and fail here immediately.
extends SceneTree

const RUNNER_META := "gym_manager_test_runner_active"
const PROBE_SCRIPT_PATH := "res://tests/unit/time_system/seeded_rng_error_probe.gd"
const PROBE_QUIT_CODE_TIMEOUT := 66  # keep in sync with seeded_rng_error_probe.gd

# === AC13 golden vector (master_seed=12345, system_name="Economy") ===
# Pinned on Godot 4.7.1, cross-checked against independent Python reference.
const GOLDEN_ECONOMY_SUBSEED := -2878674041662682638

var _pass := 0
var _fail := 0


func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	var result := run_all()
	quit(1 if int(result["fail"]) > 0 else 0)


func run_all() -> Dictionary:
	print("=".repeat(48))
	print("  UNIT TEST: SeededRNG — Sub-Stream Derivation (Story 003)")
	print("=".repeat(48))

	# AC13 first — the canary (story mandates this order).
	_test_ac13_golden_vector()
	_test_derive_golden_vectors_extra()
	_test_fnv1a64_golden_vectors()
	_test_ac6_get_rng_idempotent()
	_test_ac6_get_rng_before_register()
	_test_ac7_substream_independence()
	_test_ac7_different_master_seed()
	_test_ac15_duplicate_register_asserts()
	_test_ac15_get_rng_repeated_ok()
	_test_edge_empty_name()
	_test_edge_subseed_collision_check()
	_test_edge_registration_order_independent()
	_test_edge_extreme_master_seeds()

	print("\n=== SEEDED RNG SUBSTREAM TEST: %d passed, %d failed ===" % [_pass, _fail])
	return {"pass": _pass, "fail": _fail}


func _check(cond: bool, msg: String) -> void:
	if cond:
		_pass += 1
		print("  PASS: " + msg)
	else:
		_fail += 1
		print("  FAIL: " + msg)


func _SRG() -> Script:
	return load("res://src/systems/seeded_rng.gd") as Script


func _make_srg(master_seed: int) -> RefCounted:
	var srg: RefCounted = _SRG().new()
	srg.call("init", master_seed)
	return srg


## Subprocess probe — see seeded_rng_error_probe.gd header. Returns
## {"asserted": bool, "errored": bool, "output": String, "exit_code": int}.
## "asserted" = merged output contains "Assertion failed"; "errored" = merged
## output contains "ERROR: SeededRNG:" (push_error).
func _run_probe(mode: String) -> Dictionary:
	var exe := OS.get_executable_path()
	var project_root := ProjectSettings.globalize_path("res://")
	var probe_path := ProjectSettings.globalize_path(PROBE_SCRIPT_PATH)

	var args: Array[String] = ["--headless", "--path", project_root, "--script", probe_path, "--", mode]
	var output: Array = []
	var exit_code := OS.execute(exe, args, output, true)
	var output_text: String = "".join(output)

	return {
		"asserted": output_text.find("Assertion failed") != -1,
		"errored": output_text.find("ERROR: SeededRNG:") != -1,
		"output": output_text,
		"exit_code": exit_code,
	}


# === AC13: 金向量测试（MUST be the first test — canary for the whole pipeline）===

func _test_ac13_golden_vector() -> void:
	print("\n[AC13] golden vector — derive_sub_seed(12345, \"Economy\")")
	print("  CANARY: if this fails on 4.7.1, the whole derivation formula needs re-evaluation")

	var result: int = _SRG().derive_sub_seed(12345, "Economy")
	_check(
		result == GOLDEN_ECONOMY_SUBSEED,
		"derive_sub_seed(12345, \"Economy\") == %d (got %d)" % [GOLDEN_ECONOMY_SUBSEED, result]
	)
	# Determinism: pure function, repeatable within a run.
	var again: int = _SRG().derive_sub_seed(12345, "Economy")
	_check(
		again == GOLDEN_ECONOMY_SUBSEED,
		"calling the same derivation twice yields the same value (pure function)"
	)


# === 额外派生金向量：钉死 MemberSim/Congestion/Satisfaction 与其他 master_seed ===

func _test_derive_golden_vectors_extra() -> void:
	print("\n[derive] additional pinned vectors — cross-checked with Python reference")

	var vectors := [
		[12345, "MemberSim", -3280094271212432137],
		[12345, "Congestion", -1364857181615096062],
		[12345, "Satisfaction", 8664795350959167511],
		[999, "MemberSim", 5073362836286810986],
		[-42, "Economy", -484285609656708724],
		[12345, "", 8372304914271757474],
		[12345, "MemberSim2", -6673359091990662316],
	]
	for v in vectors:
		var got: int = _SRG().derive_sub_seed(v[0], v[1])
		_check(
			got == v[2],
			"derive_sub_seed(%d, \"%s\") == %d (got %d)" % [v[0], v[1], v[2], got]
		)


# === FNV-1a64 金向量：钉死 FNV 常数与 UTF-8 字节语义 ===

func _test_fnv1a64_golden_vectors() -> void:
	print("\n[fnv1a64] pinned vectors — FNV constants + UTF-8 byte semantics")

	var vectors := [
		["", -3750763034362895579],          # empty string == offset basis
		["Economy", -4068960047718556969],
		["MemberSim", 917754147125689410],
		["Congestion", 1657308366248904746],
		["Satisfaction", 2115486851916901005],
		["a", -5808556873153909620],
		["A", -5808521688781806868],         # case-sensitive (different byte)
		["gym", -3080099198994291712],
		["Economy ", -8722288556752154187],  # trailing space changes hash
	]
	for v in vectors:
		var got: int = _SRG().fnv1a64(v[0])
		_check(
			got == v[1],
			"fnv1a64(\"%s\") == %d (got %d)" % [v[0], v[1], got]
		)


# === AC6: get_rng 幂等 — 返回同一实例（携带已推进状态），绝不创建/重播种 ===

func _test_ac6_get_rng_idempotent() -> void:
	print("\n[AC6] get_rng(\"MemberSim\") twice, no draws between — same instance, same state")

	var srg := _make_srg(12345)
	srg.call("register_system", "MemberSim")

	var first = srg.call("get_rng", "MemberSim")
	var second = srg.call("get_rng", "MemberSim")

	_check(first != null and second != null, "both get_rng calls return a generator")
	_check(first == second, "both calls return the SAME instance (identity)")
	_check(first.state == second.state, "both calls expose the SAME state (no re-seed)")

	# After draws: still the same instance, state advanced — not reset to seed.
	var state_before_draw: int = first.state
	var drawn: float = first.randf()
	var state_after_draw: int = first.state
	_check(state_after_draw != state_before_draw, "draw advances the generator state")
	var third = srg.call("get_rng", "MemberSim")
	_check(third == first, "get_rng after a draw still returns the SAME instance")
	_check(third.state == state_after_draw, "returned instance carries the ADVANCED state — no re-seeding")
	_check(drawn >= 0.0 and drawn < 1.0, "sanity: randf() value in [0,1)")

	# Continuation correctness: a fresh RNG restored to the advanced state
	# produces the same next draw (proves state, not seed, is what's returned).
	var rng2 := RandomNumberGenerator.new()
	rng2.state = third.state
	_check(rng2.randf() == third.randf(), "continuation from restored state matches (draw-count-agnostic)")


# === AC6 edge: get_rng before register_system -> push_error + null ===

func _test_ac6_get_rng_before_register() -> void:
	print("\n[AC6 edge] get_rng before register_system — push_error + null (subprocess)")

	var srg := _make_srg(12345)
	var missing = srg.call("get_rng", "Ghost")
	_check(missing == null, "in-process: get_rng(\"Ghost\") returns null (never creates)")

	var probe := _run_probe("get_rng_unregistered")
	_check(
		probe["errored"],
		"subprocess: get_rng on unregistered name fires push_error (\"ERROR: SeededRNG:\") — exit_code=%d" % probe["exit_code"]
	)
	_check(
		probe["output"].find("PROBE_OPERATION_COMPLETED") != -1,
		"subprocess: probe completed normally despite push_error"
	)


# === AC7: 子流独立 — 1000 draws 互不重复、非固定偏移 ===

func _test_ac7_substream_independence() -> void:
	print("\n[AC7] 1000 draws from \"MemberSim\" and \"Congestion\" — neither identical nor fixed offset")

	var srg := _make_srg(12345)
	srg.call("register_system", "MemberSim")
	srg.call("register_system", "Congestion")

	var rng_a = srg.call("get_rng", "MemberSim")
	var rng_b = srg.call("get_rng", "Congestion")

	var seq_a: Array[float] = []
	var seq_b: Array[float] = []
	for i in 1000:
		seq_a.append(rng_a.randf())
		seq_b.append(rng_b.randf())

	_check(seq_a[0] != seq_b[0], "first draw differs between streams (got %f vs %f)" % [seq_a[0], seq_b[0]])
	_check(not _sequences_identical(seq_a, seq_b), "1000-draw sequences are NOT identical")
	_check(not _is_cyclic_offset(seq_a, seq_b), "seq B is NOT a cyclic/fixed offset of seq A")
	_check(not _is_cyclic_offset(seq_b, seq_a), "seq A is NOT a cyclic/fixed offset of seq B (reverse)")
	_check(not _is_linear_shift(seq_a, seq_b), "seq B is NOT a linear shift of seq A")
	_check(_all_unique(seq_a, 1000), "seq A has no repeat within itself (sanity)")
	_check(_all_unique(seq_b, 1000), "seq B has no repeat within itself (sanity)")


# === AC7 edge: 不同 master_seed 产生不同序列 ===

func _test_ac7_different_master_seed() -> void:
	print("\n[AC7 edge] same system name, different master_seed — different sequences")

	var srg1 := _make_srg(12345)
	var srg2 := _make_srg(999)
	srg1.call("register_system", "MemberSim")
	srg2.call("register_system", "MemberSim")

	var r1 = srg1.call("get_rng", "MemberSim")
	var r2 = srg2.call("get_rng", "MemberSim")

	var seq1: Array[float] = []
	var seq2: Array[float] = []
	for i in 100:
		seq1.append(r1.randf())
		seq2.append(r2.randf())

	_check(seq1[0] != seq2[0], "master_seed 12345 vs 999: first MemberSim draw differs")
	_check(not _sequences_identical(seq1, seq2), "master_seed 12345 vs 999: 100-draw sequences differ")

	# Multi-name independence: MemberSim and Satisfaction also independent
	srg1.call("register_system", "Satisfaction")
	var r_sat = srg1.call("get_rng", "Satisfaction")
	var r_mem_again = srg1.call("get_rng", "MemberSim")
	_check(r_sat != r_mem_again, "different systems hold different generator instances")
	_check(r_sat.seed != r_mem_again.seed, "different systems have different seeds (no collision)")


# === AC15: 重复 register_system -> assert（硬错误）===

func _test_ac15_duplicate_register_asserts() -> void:
	print("\n[AC15] register_system(\"Economy\") twice — assert fires (subprocess)")

	var probe := _run_probe("register_twice")
	_check(
		probe["asserted"],
		"duplicate register_system fires assert(\"Assertion failed\") — exit_code=%d" % probe["exit_code"]
	)
	_check(
		probe["output"].find("already registered") != -1,
		"assert message identifies the colliding system name"
	)

	# Clean control: single registration + repeated get_rng produces no error.
	var ok := _run_probe("register_ok")
	_check(not ok["asserted"], "control: single registration fires NO assert")
	_check(not ok["errored"], "control: repeated get_rng fires NO push_error")
	_check(ok["exit_code"] == 0, "control: probe exits 0")


# === AC15 edge: get_rng repeated 不失败（与 register_system 的重复检查相反）===

func _test_ac15_get_rng_repeated_ok() -> void:
	print("\n[AC15 edge] repeated get_rng(\"Economy\") does NOT fail — only register_system checks duplicates")

	var srg := _make_srg(12345)
	srg.call("register_system", "Economy")
	var a = srg.call("get_rng", "Economy")
	var b = srg.call("get_rng", "Economy")
	var c = srg.call("get_rng", "Economy")
	_check(a == b and b == c, "three repeated get_rng calls all return the same instance")
	_check(a.state == b.state and b.state == c.state, "repeated get_rng never re-seeds (state constant between calls)")


# === Edge: 空名注册 ===

func _test_edge_empty_name() -> void:
	print("\n[edge] empty-name registration")

	var srg := _make_srg(12345)
	srg.call("register_system", "")
	var rng = srg.call("get_rng", "")
	_check(rng != null, "register_system(\"\") then get_rng(\"\") returns a generator")
	_check(rng.seed == 8372304914271757474, "empty-name sub-seed matches pinned vector (master_seed=12345)")


# === Edge: 子流种子碰撞验证 ===

func _test_edge_subseed_collision_check() -> void:
	print("\n[edge] sub-seed collision check across the five canonical names")

	var names := ["MemberSim", "Congestion", "Satisfaction", "Economy", "MemberSim2"]
	var seen: Dictionary = {}
	var collision := false
	for name in names:
		var seed: int = _SRG().derive_sub_seed(12345, name)
		if seen.has(seed):
			collision = true
			break
		seen[seed] = name
	_check(not collision, "no two canonical system names produce the same sub-seed (master_seed=12345)")


# === Edge: 注册顺序不影响子流（与调用顺序无关）===

func _test_edge_registration_order_independent() -> void:
	print("\n[edge] registration order does not change a system's sub-stream")

	var srg_ab := _make_srg(777)
	srg_ab.call("register_system", "MemberSim")
	srg_ab.call("register_system", "Congestion")
	var rng_a_ab = srg_ab.call("get_rng", "MemberSim")
	var rng_b_ab = srg_ab.call("get_rng", "Congestion")

	var srg_ba := _make_srg(777)
	srg_ba.call("register_system", "Congestion")   # reversed order
	srg_ba.call("register_system", "MemberSim")
	var rng_a_ba = srg_ba.call("get_rng", "MemberSim")
	var rng_b_ba = srg_ba.call("get_rng", "Congestion")

	_check(rng_a_ab.seed == rng_a_ba.seed, "MemberSim seed identical regardless of registration order")
	_check(rng_b_ab.seed == rng_b_ba.seed, "Congestion seed identical regardless of registration order")
	# And draws are identical too (not just the seed).
	_check(rng_a_ab.randf() == rng_a_ba.randf(), "MemberSim first draw identical across orders")
	_check(rng_b_ab.randf() == rng_b_ba.randf(), "Congestion first draw identical across orders")


# === Edge: 极端 master_seed（高位 set / INT64_MIN / INT64_MAX / 负值）===

func _test_edge_extreme_master_seeds() -> void:
	print("\n[edge] extreme master seeds — high-bit set, INT64_MIN, INT64_MAX, negative")

	var vectors := [
		[-9223372036854775808, "Economy", 8027621057250395300],   # INT64_MIN (0x8000000000000000)
		[-9223372036854775808, "MemberSim", 2573648204469616329],
		[-1, "Economy", -375008432402856601],
		[-2, "Congestion", 3032950314860731219],
		[9223372036854775807, "MemberSim", 3077728595316564789],  # INT64_MAX
	]
	for v in vectors:
		var got: int = _SRG().derive_sub_seed(v[0], v[1])
		_check(
			got == v[2],
			"derive_sub_seed(%d, \"%s\") == %d (got %d)" % [v[0], v[1], v[2], got]
		)

	# And these extreme sub-seeds actually drive a working RNG (full range incl. negative).
	var srg := _make_srg(-9223372036854775808)
	srg.call("register_system", "Economy")
	var rng = srg.call("get_rng", "Economy")
	var d: float = rng.randf()
	_check(d >= 0.0 and d < 1.0, "RNG seeded from an INT64_MIN-derived sub-seed draws in [0,1) (got %f)" % d)


# === Sequence helpers ===

func _sequences_identical(a: Array[float], b: Array[float]) -> bool:
	if a.size() != b.size():
		return false
	for i in a.size():
		if a[i] != b[i]:
			return false
	return true


## True if b equals a rotated by some fixed offset k in [1, size-1]:
## b[i] == a[(i + k) % size] for all i. Used for AC7's "fixed offset" clause.
func _is_cyclic_offset(a: Array[float], b: Array[float]) -> bool:
	var n := a.size()
	if b.size() != n or n == 0:
		return false
	for k in range(1, n):
		var matched := true
		for i in n:
			if b[i] != a[(i + k) % n]:
				matched = false
				break
		if matched:
			return true
	return false


## True if b equals a shifted linearly (non-wrapping) by k in [1, size-1]:
## b[i] == a[i + k] for i in [0, n-1-k], and the remaining tail matches too.
func _is_linear_shift(a: Array[float], b: Array[float]) -> bool:
	var n := a.size()
	if b.size() != n or n == 0:
		return false
	for k in range(1, n):
		var matched := true
		for i in n - k:
			if b[i] != a[i + k]:
				matched = false
				break
		if matched:
			return true
	return false


## True if every element in seq is distinct from all others (sanity for PRNG quality).
func _all_unique(seq: Array[float], sample: int) -> bool:
	var seen: Dictionary = {}
	for i in sample:
		var v := seq[i]
		if seen.has(v):
			return false
		seen[v] = true
	return true
