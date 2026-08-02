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
## SERIALIZATION (Story TS-004) — int64 hex encoding. ADR-0002 mandates every
## 64-bit value in a save blob be a hex string ("0x" prefix). Two engine facts
## verified empirically on 4.7.1 (see tests/unit/time_system/hex_int64_probe
## run log) force the implementation below:
##   * String formatting "%x" % negative_int produces "0x-405f..." — a minus
##     sign AFTER the "0x" prefix. hex_to_int() rejects that string outright
##     ("Invalid hexadecimal notation character '-'"), so the story sketch's
##     "0x%x" % state would CORRUPT any save whose RNG state has the high bit
##     set (common — SplitMix64 state is arbitrary 64-bit). We therefore
##     serialize via String.num_uint64(value, 16).lpad(16, "0"): the UNSIGNED
##     bit pattern, always 16 hex digits, no sign character.
##   * hex_to_int() on 4.7.1 does NOT wrap values with the high bit set — it
##     prints an error and clamps to INT64_MAX. ADR-0002's table claims
##     "bits preserved; values >= 2^63 display as negative int" — empirically
##     FALSE on 4.7.1. We therefore parse in two halves (hi = bits 63..32,
##     lo = bits 31..0) and recombine with (hi << 32) | lo, which reconstructs
##     the exact two's-complement int64 for ANY bit pattern.
##   * The full pipeline is pinned by the hex boundary test in
##     tests/unit/time_system/time_serialization_test.gd (round-trips
##     0, ±1, ±(2^62), ±(2^63-1), INT64_MIN, and arbitrary negative RNG
##     states, both directly and through JSON.stringify/parse_string with
##     full_precision=true + sort_keys=true).
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


## Serializes a signed int64 as a JSON-safe hex string with "0x" prefix.
##
## ADR-0002: 64-bit values must never appear as bare JSON numbers (53-bit
## mantissa would truncate them). Story sketch wrote `"0x%x" % value`; that is
## VERIFIED BROKEN on 4.7.1 for negative values — "%x" formats the sign
## AFTER the prefix ("0x-405f..."), which hex_to_int() rejects on parse. The
## robust spelling is the UNSIGNED bit pattern via String.num_uint64(),
## zero-padded to exactly 16 hex digits: "0x" + 16 chars, no sign character,
## round-trips every int64 bit pattern (see class header + hex boundary test).
static func int64_to_hex(value: int) -> String:
	return "0x%s" % String.num_uint64(value, 16).lpad(16, "0")


## Deserializes a "0x"-prefixed hex string back to a signed int64.
##
## hex_to_int() on 4.7.1 does NOT wrap high-bit values — it errors and clamps
## to INT64_MAX (ADR-0002's "bits preserved" claim is empirically false).
## Reconstruct in two halves instead: hi = bits 63..32, lo = bits 31..0,
## recombined as (hi << 32) | lo. Verified bit-exact for the full int64 range.
## Body is left-padded to 16 digits so short hand-written hex ("0x3039")
## parses correctly; values LONGER than 16 hex digits exceed int64 and are
## rejected by the caller's validation (is_valid_hex_number does NOT check
## length — see deserialize()).
static func hex_to_int64(hex_str: String) -> int:
	var body := hex_str.trim_prefix("0x").lpad(16, "0")
	var hi: int = body.substr(0, 8).hex_to_int()
	var lo: int = body.substr(8, 8).hex_to_int()
	return (hi << 32) | lo


## Composite return value for SeededRNG.deserialize(). Carries the verdict
## and every collected validation error (Phase A failures do not short-circuit
## — the caller sees all problems at once). Plain data-transfer object.
class SeededRNGDeserializeResult extends RefCounted:
	var ok: bool = false
	var errors: Array[String] = []

	func add_error(msg: String) -> void:
		errors.append(msg)


## Returns this RNG registry's full serializable state:
##   { master_seed: "0x…", per_system_rng_states: { system_name: "0x…", … } }
## Pure read — no side effects, no draws. The exact internal state of each
## sub-stream is captured (rng.state), NOT its derived seed — restoring state
## is draw-count-agnostic (ADR-0004 §3): it does not matter how many draws a
## system consumed pre-save; the restored generator resumes exactly there.
func serialize() -> Dictionary:
	var states := {}
	for system_name in _streams:
		states[system_name] = int64_to_hex(_streams[system_name].state)
	return {
		"master_seed": int64_to_hex(master_seed),
		"per_system_rng_states": states,
	}


## Two-phase deserialize: Phase A validates EVERYTHING with zero mutation;
## Phase B commits only if Phase A passed. Failures are returned (never
## push_error'd — corrupt save data is a normal outcome, per the repo's
## DeserializeResult convention).
##
## Required fields (hard failure, no invented defaults — TR-TS-009, AC16/17):
##   - master_seed: "0x"-prefixed hex string
##   - per_system_rng_states: Dictionary with an entry for EVERY registered
##     system. Extra unknown keys are ignored (we validate the registered
##     set, not the dictionary's keys — QA AC16 edge case).
##
## RNG state is restored directly via rng.state = hex_to_int64() — NEVER
## re-derived from master_seed (re-deriving would discard the draws the system
## already consumed pre-save, silently breaking determinism — GDD Edge Cases).
func deserialize(data: Dictionary) -> SeededRNGDeserializeResult:
	var result := SeededRNGDeserializeResult.new()

	# --- Phase A: validate (zero mutation) ---
	# Collect ALL errors (story design note: "the first error does not
	# short-circuit, so the caller sees all problems at once"). Structural
	# dependencies are guarded so a missing parent key never crashes the
	# collector (e.g. per-system checks require the states dict to exist).

	var master_seed_str := ""
	if not data.has("master_seed"):
		result.add_error("SeededRNG: missing 'master_seed' in save data")
	elif not data["master_seed"] is String:
		result.add_error("SeededRNG: master_seed must be a hex string (0x prefix)")
	elif not str(data["master_seed"]).begins_with("0x") or not str(data["master_seed"]).is_valid_hex_number(true):
		result.add_error("SeededRNG: master_seed must be hex string (0x prefix)")
	elif str(data["master_seed"]).trim_prefix("0x").length() > 16:
		result.add_error("SeededRNG: master_seed exceeds 64-bit range (max 16 hex digits)")
	else:
		master_seed_str = str(data["master_seed"])

	var states: Dictionary = {}
	var states_ok := false
	if not data.has("per_system_rng_states"):
		result.add_error("SeededRNG: missing 'per_system_rng_states' in save data")
	elif not data["per_system_rng_states"] is Dictionary:
		result.add_error("SeededRNG: per_system_rng_states must be a Dictionary")
	else:
		states = data["per_system_rng_states"]
		states_ok = true

	# Every REGISTERED system must have an entry — the registered set is the
	# contract. Collect ALL missing names at once (no per-name short-circuit).
	# An EMPTY states dict with registered systems reports every system as
	# missing (QA AC16 edge case). Only a structurally-invalid/missing states
	# dict skips this (already reported above).
	var missing: Array[String] = []
	if states_ok:
		for system_name in _streams:
			if not states.has(system_name):
				missing.append(system_name)
	for system_name in missing:
		result.add_error("SeededRNG: missing RNG state for system '%s'" % system_name)

	# Validate ALL hex strings parse before committing ANY state (parse into
	# a staging dict — Phase B consumes it only if nothing failed).
	var parsed_states: Dictionary = {}
	for system_name in _streams:
		if missing.has(system_name):
			continue
		if not states_ok or not states.has(system_name):
			continue  # already reported — do not double-report
		var state_hex: Variant = states[system_name]
		if not state_hex is String:
			result.add_error("SeededRNG: RNG state for '%s' must be a hex string (0x prefix)" % system_name)
			continue
		var state_hex_str: String = state_hex
		# hex_to_int returns garbage on invalid input — validate prefix + hex
		# digits instead of trusting the parse (story engine note). Also cap
		# length: >16 hex digits cannot fit in int64 (is_valid_hex_number
		# accepts arbitrarily long strings — it only checks character class).
		if not state_hex_str.begins_with("0x") or not state_hex_str.is_valid_hex_number(true):
			result.add_error("SeededRNG: RNG state for '%s' must be hex string (0x prefix)" % system_name)
			continue
		if state_hex_str.trim_prefix("0x").length() > 16:
			result.add_error("SeededRNG: RNG state for '%s' exceeds 64-bit range (max 16 hex digits)" % system_name)
			continue
		parsed_states[system_name] = hex_to_int64(state_hex_str)

	if not result.errors.is_empty():
		return result  # Phase A failed — NOTHING was mutated

	# --- Phase B: commit (only if all valid) ---
	master_seed = hex_to_int64(master_seed_str)
	for system_name in parsed_states:
		_streams[system_name].state = parsed_states[system_name]

	result.ok = true
	return result
