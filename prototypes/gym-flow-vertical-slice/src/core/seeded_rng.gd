# VERTICAL SLICE - NOT FOR PRODUCTION
# Validation Question: core loop buildable at quality — deterministic per-system RNG subseed derivation
# Date: 2026-07-19
#
# Faithful to time-system.md: master_seed -> FNV-1a64(name) XOR master -> SplitMix64.
# Logical right-shift (lsr) is REQUIRED — GDScript's native >> is arithmetic (sign-extending)
# and would corrupt SplitMix64's avalanche. GDScript int is 64-bit two's-complement wraparound
# (OQ4: verified against 4.7.1 runtime by this slice's smoke test).

class_name SeededRNG
extends RefCounted

const FNV_OFFSET: int = -3750746330894850579
const FNV_PRIME: int = 1099511628211

var _master_seed: int
var _sub_seeds: Dictionary = {}  # name -> int

func _init(master_seed: int) -> void:
	_master_seed = _wrap64(master_seed)

func register_system(name: String) -> void:
	if _sub_seeds.has(name):
		return
	var name_hash: int = _fnv1a64(name)
	var combined: int = _wrap64(_master_seed ^ name_hash)
	var sub: int = _splitmix64(combined)
	_sub_seeds[name] = sub

# Idempotent. Each consuming system registers once, then fetches its own RNG.
func get_rng(name: String) -> RandomNumberGenerator:
	if not _sub_seeds.has(name):
		register_system(name)
	var rng := RandomNumberGenerator.new()
	rng.seed = _sub_seeds[name]
	return rng

func get_sub_seed(name: String) -> int:
	if not _sub_seeds.has(name):
		register_system(name)
	return _sub_seeds[name]

func _fnv1a64(s: String) -> int:
	var h: int = FNV_OFFSET
	for i in s.length():
		h = _wrap64(h ^ s.unicode_at(i))
		h = _wrap64(h * FNV_PRIME)
	return h

func _splitmix64(z_in: int) -> int:
	var z: int = _wrap64(z_in + -7051201746140092187)
	var x: int = _wrap64(z ^ _lsr(z, 30))
	x = _wrap64(x * -4007124803642189515)
	x = _wrap64(x ^ _lsr(x, 27))
	x = _wrap64(x * -7194782910287113907)
	x = _wrap64(x ^ _lsr(x, 31))
	return x

# Logical (unsigned) right shift on a 64-bit signed int.
func _lsr(v: int, k: int) -> int:
	var u: int = _wrap64(v) & -1
	return u >> k

func _wrap64(v: int) -> int:
	return v & -1
