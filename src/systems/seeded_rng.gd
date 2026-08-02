## SeededRNG — per-system deterministic RNG sub-streams (TS-003).
##
## ADR-0004: each consuming system registers exactly once with a stable name
## ("MemberSim", "Economy", ...); its private RandomNumberGenerator is seeded
## from (master_seed, system_name) via the pinned derivation pipeline:
##
##     FNV-1a64(system_name)  ->  XOR master_seed  ->  SplitMix64 finalizer
##
## Registering the same name twice is a HARD ERROR (assert). get_rng() is
## idempotent: it returns the already-registered instance (carrying its
## advanced state) and never creates or re-seeds anything. A get_rng() for an
## unregistered name returns null after push_error — never a fresh RNG.
##
## GODOT 4.7.1 ENGINE FACTS (verified empirically before this file was written
## — see tests/unit/time_system/int64_probe.gd run log and ADR-0004 §Engine
## Compatibility):
##   * GDScript int is 64-bit two's-complement; multiply wraps on overflow.
##   * Hex literals that exceed INT64_MAX do NOT wrap — they are REJECTED at
##     parse time and the value silently clamps to INT64_MAX (0x7FFF...). The
##     constants below therefore use the signed two's-complement spelling of
##     each bit pattern (e.g. FNV_OFFSET_BASIS = 0xCBF29CE484222325 as unsigned
##     == -3750763034362895579 as signed int64). This is the same bit pattern
##     the formula requires; only the literal spelling differs.
##   * Native >> is ARITHMETIC (sign-extending) — lsr() is mandatory.
##   * Godot's built-in hash() is NOT contractually stable — never used.
class_name SeededRNG extends RefCounted

# FNV-1a 64-bit constants. Unsigned spelling in comment; signed spelling in
# code (see engine facts above).
const FNV_OFFSET_BASIS := -3750763034362895579  # 0xCBF29CE484222325
const FNV_PRIME := 1099511628211                # 0x100000001B3 (fits in int64)
# SplitMix64 finalizer constants, same signed-spelling treatment:
const SPLITMIX_M1 := -4658895280553007687       # 0xBF58476D1CE4E5B9
const SPLITMIX_M2 := -7723592293110705685       # 0x94D049BB133111EB

## Global run seed (new-game or restored). Full int64 range accepted.
var master_seed: int = 0
## String system_name -> RandomNumberGenerator
var _streams: Dictionary = {}


## Logical (zero-filling) right shift. GDScript's native >> is arithmetic
## (sign-extending); SplitMix64's avalanche math REQUIRES logical shift, so
## every right shift inside the derivation pipeline goes through this helper.
## shift must be in [1, 63] — shift=0 would be a no-op identity and shift>=64
## would be undefined for a 64-bit value, so both are asserted against.
static func lsr(value: int, shift: int) -> int:
	assert(shift > 0 and shift < 64, "lsr: shift %d out of range (1-63)" % shift)
	return (value >> shift) & ((1 << (64 - shift)) - 1)


## FNV-1a 64-bit hash over the UTF-8 bytes of `data`. Published constants,
## language-agnostic, deterministic across engines/versions (unlike Godot
## hash()). Multiplies wrap at 64 bits via GDScript's int64 semantics; the
## final `& -1` is an explicit 64-bit mask (0xFFFFFFFFFFFFFFFF) for clarity.
static func fnv1a64(data: String) -> int:
	var hash := FNV_OFFSET_BASIS
	for byte in data.to_utf8_buffer():
		hash = hash ^ byte
		hash = (hash * FNV_PRIME) & -1
	return hash


## rng_subseed_derivation_formula (time-system.md Formulas + ADR-0004):
## FNV-1a64(system_name) -> XOR master_seed -> SplitMix64 finalizer.
## Pure function; called only by register_system(). The SplitMix64 constants
## and lsr() semantics are pinned by the AC13 golden-vector test.
static func derive_sub_seed(master_seed: int, system_name: String) -> int:
	var name_hash := fnv1a64(system_name)
	var combined := master_seed ^ name_hash
	var z := combined
	z = (z ^ lsr(z, 30)) * SPLITMIX_M1
	z = (z ^ lsr(z, 27)) * SPLITMIX_M2
	return z ^ lsr(z, 31)


## Sets the global run seed. Must be called before any register_system().
func init(p_master_seed: int) -> void:
	master_seed = p_master_seed


## Registers a consuming system's sub-stream. Called EXACTLY ONCE per system
## during _post_init(). Derives the sub-seed from (master_seed, system_name),
## constructs that system's own RandomNumberGenerator, stores it.
##
## A duplicate name is a HARD ERROR (assert) — it signals two systems
## colliding on one stream, which would silently corrupt both sequences.
func register_system(system_name: String) -> void:
	if _streams.has(system_name):
		assert(false, "SeededRNG: system '%s' already registered" % system_name)
		return

	var sub_seed := derive_sub_seed(master_seed, system_name)
	var rng := RandomNumberGenerator.new()
	rng.seed = sub_seed
	_streams[system_name] = rng


## Idempotent accessor: returns the SAME already-registered generator
## (carrying its current advanced state) on every call. Never creates, never
## re-seeds, never registers. Returns null (after push_error) for a name that
## was never registered — a calling system gets an immediate null-reference
## error rather than a silently independent unseeded stream.
func get_rng(system_name: String) -> RandomNumberGenerator:
	if not _streams.has(system_name):
		push_error("SeededRNG: system '%s' not registered — call register_system() first" % system_name)
		return null
	return _streams[system_name]
