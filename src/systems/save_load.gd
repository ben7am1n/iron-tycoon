## SaveLoad — the tick-boundary save coordinator (pure coordinator, owns no state).
##
## Story: save-load / story-001-saveblob-tick-boundary.md
## Req:   TR-SL-001 (coordinator, not state owner; tick-boundary saves),
##        TR-SL-002 (blob = {version, master_seed, time_system, grid_system,
##                  member_sim, congestion, satisfaction, economy}),
##        TR-SL-008 (ZoneRules/Navigation/PlacementSystem/SelectionSystem
##                  contribute NOTHING to the blob)
## ADR:   ADR-0002 (Storage Format — save blob is JSON at rest, composed here
##        as a flat Dictionary), ADR-0005 (Signal Bus — S2 tick_completed)
##
## SaveLoad holds no game state of its own: its whole job is to collect each
## coordinated system's serialize() output into ONE flat save blob, and to
## guarantee that collection happens only at a tick boundary (never mid-tick).
## The tick-boundary guarantee is STRUCTURAL, not polled: request_save() only
## sets the _save_pending flag; the actual serialize() calls fire from the
## tick_completed handler, which TimeSystem/Orchestrator emits at the end of
## every tick sequence (S2). Because the tick loop forbids mid-tick yielding,
## every moment external code can run is already a consistent snapshot.
##
## DEVIATION FROM STORY SKETCH (documented, not silent):
## The sketch connects `_time_system.tick_completed`. Story TS-001 locked
## tick_count ownership on SimulationOrchestrator, so the S2 signal is
## DECLARED ON THE ORCHESTRATOR (see simulation_orchestrator.gd header), not
## on TimeSystem. SaveLoad therefore subscribes to _orchestrator.tick_completed
## — same signal, same arity (tick_count: int), different host. The GDD's
## "TimeSystem's tick_completed hook" is satisfied via the orchestrator's
## signal, which TimeSystem's tick dispatch drives.
##
## DEVIATION #2 (serialize-once): the sketch builds the blob by calling
## _time_system.serialize() twice (once for the redundant top-level
## master_seed, once for the time_system payload). AC1 requires serialize() to
## be called exactly once per save request per system, so _perform_save()
## calls each system's serialize() exactly once and reuses the dict.
##
## BLOB SHAPE (TR-SL-002): exactly 8 flat keys, no more, no less.
##   {version, master_seed, time_system, grid_system, member_sim, congestion,
##    satisfaction, economy}
## The top-level master_seed is a READ-ONLY redundancy for save-file
## introspection — TimeSystem's copy is authoritative on load. Systems whose
## orchestrator field is null (stories not yet landed) contribute an empty {}
## so the key set is stable from the first save; load-time validation (Story
## 002) decides whether an empty payload is a valid empty state.
##
## ADR-0002 §3 note: the on-disk envelope ({format_version, payload}) is
## Story 004's concern (file I/O). This story produces the flat Dictionary.
##
## STORY 004 (file I/O, JSON encoding, version checking) additions:
##   - save_to_file()/save(): JSON.stringify with indent="  ", sort_keys=true,
##     full_precision=true (ADR-0002 §6 + Control Manifest: sort_keys must be
##     true — the story sketch's literal `false` for sort_keys is a typo, its
##     own comment says true); every FileAccess.store_*() return checked
##     (AC-FILE-1); flush() called before close() (AC-FILE-2); saves dir
##     auto-created via DirAccess.make_dir_recursive(); file path is
##     user_data_dir/saves/<name>.sav.json (AC-FILE-4).
##   - load_from_file(): JSON.new().parse() (line numbers), type-safe version
##     exact-match gate BEFORE any system is touched (AC6). JSON parses
##     integer literals as FLOAT in 4.7.1 (verified empirically), so the
##     version check accepts int|float and rejects everything else — a string
##     version would crash the `!=` comparison (GDScript runtime error).
##   - load_save(): file-level gate then delegates to Story 002's load() via
##     guarded dynamic dispatch (has_method("load") + call) — SL-002 lands in
##     parallel; until then a valid file returns an honest "not wired" error
##     instead of crashing. Return type is Variant: Story 002 defines the
##     typed load result (the global class_name `LoadResult` is taken by the
##     equipment-catalog epic, so SL-002 must choose a distinct name).
##
## DEVIATION #3 (flush return): the story sketch says "call flush first, check
## its return" — FileAccess.flush() returns void in Godot 4.7.1 (empirically
## verified), so there is no return to check. The guarantee that IS enforced:
## flush() is called before close() on every path (AC-FILE-2), and the mock
## test verifies the ordering. Similarly close() returns void — the sketch's
## `close_error := f.get_open_error()` would read the OPEN error, not a close
## error, so it is omitted (get_open_error() is only meaningful for open
## failures, which ARE checked).
class_name SaveLoad extends RefCounted

## Save blob format version (GDD Core Rule 6 — exact-match on load).
const SAVE_FORMAT_VERSION := 1

## Save directory name under the user data dir (ADR-0002: user://saves/...).
const SAVE_DIR := "saves"

## Save file extension (ADR-0002 §1: JSON, `.sav.json`).
const SAVE_EXTENSION := ".sav.json"

## The fixed blob key set — the textual source of truth for TR-SL-002.
## Missing key = load error; key outside this set (e.g. a future system that
## forgot to be added here) = load error (forward-compat gate, guardrail).
const CONTRIBUTING_KEYS := [
	"version", "master_seed",
	"time_system", "grid_system",
	"member_sim", "congestion", "satisfaction", "economy",
]

## Systems that deliberately contribute NOTHING (TR-SL-008): ZoneRules is a
## stateless pure function; Navigation/PlacementSystem/SelectionSystem are
## derived/rebuilt from GridSystem on load. Verified at blob-validation time,
## not just by convention (AC-BLOB-3).
const EXCLUDED_SYSTEMS := [
	"navigation", "placement_system", "selection_system", "zone_rules",
]

# === Coordinated system references — captured at init() from the orchestrator ===
# (the orchestrator's fields ARE the composition-root contract; see
# simulation_orchestrator.gd. Untyped deliberately — MemberSim/Congestion/
# Satisfaction/Economy classes do not exist in src/ yet.)
var _orchestrator: SimulationOrchestrator
var _time_system       # TimeSystem — also the tick_completed boundary source
var _grid_system       # GridSystem
var _member_sim        # MemberSim — null until its story lands
var _congestion        # Congestion — null until its story lands
var _satisfaction      # Satisfaction — null until its story lands
var _economy           # Economy — null until its story lands
# Systems that do NOT serialize but must be rebuilt on load (Story 002) —
# captured now per the story skeleton; Story 002's load orchestration uses
# them: PlacementSystem.rederive_counter(), SelectionSystem.rebuild_mapping(),
# Navigation.rebuild(occupancy).
var _placement_system  # PlacementSystem — null until its story lands
var _selection_system  # SelectionSystem — null until its story lands
var _navigation        # Navigation — null until its story lands

var _save_pending: bool = false
var _initialized: bool = false

## Test seam (AC-FILE-1/AC-FILE-2): when set, save_to_file() obtains the
## write handle from this factory instead of FileAccess.open(). The factory
## must return an Object exposing store_string(s)->bool, flush(), close()
## (duck-typed — verified works through an Object var in 4.7.1). Production
## wiring leaves it empty (real FileAccess). The mock test injects a
## MockHandle whose store_string() returns false (AC-FILE-1) and whose call
## order is recorded (AC-FILE-2 flush-before-close).
var _file_access_factory: Callable = Callable()


## Two-phase init (ADR-0001). Captures the coordinated systems from the
## orchestrator. Safe to call once; a second call fires assert(false)
## (AC-INIT-1 pattern — init() returns void, so the assert is safe: it aborts
## only this frame, matching SimulationOrchestrator.init()).
func init(orchestrator: SimulationOrchestrator) -> void:
	if _initialized:
		assert(false, "SaveLoad.init() called twice")
		return
	_orchestrator = orchestrator
	_time_system = orchestrator.time_system
	_grid_system = orchestrator.grid_system
	_member_sim = orchestrator.member_sim
	_congestion = orchestrator.congestion
	_satisfaction = orchestrator.satisfaction
	_economy = orchestrator.economy
	_placement_system = orchestrator.placement_system
	_selection_system = orchestrator.selection_system
	_navigation = orchestrator.navigation
	_initialized = true


## Phase 2 wiring — subscribes to the tick_completed signal (S2) for the
## boundary-save guarantee. Must be called after init() and after all systems
## exist (the orchestrator calls this when it constructs SaveLoad in a later
## story; tests call it explicitly).
func _post_init() -> void:
	assert(_initialized, "SaveLoad._post_init() called before init()")
	# Subscribe to tick_completed for boundary-save guarantee. Host is the
	# orchestrator (see class header DEVIATION) — signal arity: 1 int.
	if not _orchestrator.tick_completed.is_connected(_on_tick_completed):
		_orchestrator.tick_completed.connect(_on_tick_completed)


## Tick-boundary save hook — connected to the S2 tick_completed signal, which
## fires at the END of each tick sequence (after every on_tick() call and
## after tick_count incremented). Never called directly by UI or _process;
## the only path into _perform_save() while the sim is running.
func _on_tick_completed(tick_count: int) -> void:
	if _save_pending:
		_save_pending = false
		_perform_save()


## THE ONLY public save entry point (called by UI / autosave triggers).
## Deferred save: sets a flag; the actual serialize() calls fire at the next
## tick boundary via _on_tick_completed. While paused no ticks fire, so the
## sim is already frozen at a boundary — save immediately (still structurally
## at a boundary, no mid-tick risk).
func request_save() -> void:
	if not _initialized:
		push_error("SaveLoad.request_save() called before init().")
		return
	_save_pending = true
	if _time_system != null and _time_system.is_paused():
		_save_pending = false
		_perform_save()


## Composes the save blob: exactly the 8 CONTRIBUTING_KEYS, each coordinated
## system's serialize() output collected exactly once. A null system (story
## not yet landed / genuinely empty state) contributes {} — the key is ALWAYS
## present so the blob shape is stable (AC-BLOB-1).
func _perform_save() -> Dictionary:
	if not _initialized:
		push_error("SaveLoad: _perform_save() called before init().")
		return {}
	if _time_system == null:
		push_error("SaveLoad: time_system not wired — cannot compose save blob.")
		return {}
	# Serialize TimeSystem exactly ONCE (AC1: one serialize() call per system
	# per save request) and reuse the dict for the redundant top-level seed.
	var time_data: Dictionary = _time_system.serialize()
	return {
		"version": SAVE_FORMAT_VERSION,
		"master_seed": time_data.get("master_seed", ""),
		"time_system": time_data,
		"grid_system": _serialize_or_empty(_grid_system),
		"member_sim": _serialize_or_empty(_member_sim),
		"congestion": _serialize_or_empty(_congestion),
		"satisfaction": _serialize_or_empty(_satisfaction),
		"economy": _serialize_or_empty(_economy),
	}


## Serializes one coordinated system, treating a not-yet-landed (null) system
## as an empty-state {} contribution. Every coordinated system's serialize()
## returns a Dictionary (their individual contracts, tested in their stories).
func _serialize_or_empty(system) -> Dictionary:
	if system == null:
		return {}
	return system.serialize()


## Validates the blob key contract (TR-SL-002 / guardrail: fixed key set).
## Returns every violation found:
##   - missing required key            -> error
##   - key outside CONTRIBUTING_KEYS   -> error (extra-key forward-compat gate;
##                                        EXCLUDED_SYSTEMS get a specific message)
##   - top-level master_seed diverging from TimeSystem's copy -> error
## Story 002's load path uses this as the first gate; the QA test also asserts
## the freshly composed blob passes with zero errors.
func _validate_blob_keys(blob: Dictionary) -> Array[String]:
	var errors: Array[String] = []

	# Required keys present
	for key in CONTRIBUTING_KEYS:
		if not blob.has(key):
			errors.append("SaveLoad: missing required key '%s' in save blob" % key)

	# No extra keys — the set is fixed (guardrail: extra key = load error).
	# EXCLUDED_SYSTEMS get the specific "should not serialize" message.
	for key in blob.keys():
		if key in CONTRIBUTING_KEYS:
			continue
		if key in EXCLUDED_SYSTEMS:
			errors.append("SaveLoad: unexpected key '%s' in save blob — this system should not serialize" % key)
		else:
			errors.append("SaveLoad: unexpected key '%s' in save blob — the blob key set is fixed" % key)

	# Master seed redundancy check (AC-BLOB-2 — redundancy, not divergence)
	if blob.has("master_seed") and blob.get("time_system") is Dictionary:
		var ts: Dictionary = blob["time_system"]
		if ts.get("master_seed", null) != blob["master_seed"]:
			errors.append("SaveLoad: top-level master_seed diverges from TimeSystem's copy")

	return errors


# ================= Story 004 — File I/O, JSON Encoding, Version Checking =================


## Public: save to disk using save_name as the slot identifier.
## The caller (UI) is responsible for the save_name — e.g., "autosave",
## "slot_1", etc. Returns error string (empty on success).
## The caller should call this from within the tick_completed handler (the
## save is synchronous at the boundary — Story 001's deferral is request_save()).
func save(save_name: String) -> String:
	return save_to_file(save_name)


## Write save blob to disk. Returns error string if failed, empty string on success.
## Resolves `user_data_dir/saves/<save_name>.sav.json` (AC-FILE-4), creates the
## saves dir via DirAccess.make_dir_recursive() when missing, JSON-encodes with
## full_precision=true + sort_keys=true, checks EVERY FileAccess.store_*()
## return value (AC-FILE-1), and calls flush() before close() (AC-FILE-2).
func save_to_file(save_name: String) -> String:
	assert(_initialized, "SaveLoad: not initialized")

	# Reject unsafe save names (Control Manifest: never write to
	# user-controlled paths — path traversal). Story QA edge case: special
	# characters are REJECTED (rejection chosen over sanitization — safer).
	var name_error := _validate_save_name(save_name)
	if not name_error.is_empty():
		return name_error

	# Produce the blob (delegates to save-blob composition from Story 001)
	var blob := _perform_save()
	if blob.is_empty():
		return "SaveLoad: failed to compose save blob"

	# JSON encode with deterministic options
	var json_string := JSON.stringify(blob, "  ", true, true)
	#                                   indent, sort_keys, full_precision
	# indent="  " for human-readability; sort_keys=true for deterministic
	# output (Control Manifest FORBIDS sort_keys=false — the story sketch's
	# literal `false` is a typo, its own comment says true); full_precision=true
	# for int64/float safety.

	# Guardrail (Control Manifest): log a warning if > 1 MB (MVP est. < 50 KB).
	if json_string.length() > 1_000_000:
		push_warning("SaveLoad: save '%s' is %d bytes — exceeds 1 MB guardrail" % [save_name, json_string.length()])

	# Resolve save path
	var user_dir := OS.get_user_data_dir()
	var save_dir := user_dir.path_join(SAVE_DIR)

	# Ensure directory exists (AC-FILE-4 edge: save_dir doesn't exist yet)
	var dir := DirAccess.open("user://")
	if dir == null:
		return "SaveLoad: failed to open user data dir (error %d)" % DirAccess.get_open_error()
	if not dir.dir_exists(save_dir):
		var mkdir_result := dir.make_dir_recursive(save_dir)
		if mkdir_result != OK:
			return "SaveLoad: failed to create save directory '%s' (error %d)" % [save_dir, mkdir_result]

	var file_path := save_dir.path_join(save_name + SAVE_EXTENSION)

	# Write to file — via the factory seam when a mock is injected, else the
	# real FileAccess (AC-FILE-1/2 mock tests).
	var f: Object = _open_write(file_path)
	if f == null:
		if _file_access_factory.is_valid():
			return "SaveLoad: failed to open '%s' for writing (factory returned null)" % file_path
		return "SaveLoad: failed to open '%s' for writing (error %d)" % [file_path, FileAccess.get_open_error()]

	# Every store_*() call's return value MUST be checked (AC-FILE-1): a false
	# return means the write failed silently in older versions, now it's explicit.
	if not f.store_string(json_string):
		f.close()
		return "SaveLoad: failed to write save data to '%s'" % file_path

	# flush() before close() — ensures OS-level write buffers are committed
	# (AC-FILE-2). flush() returns void in 4.7.1 (deviation #3).
	f.flush()
	f.close()

	return ""  # success


## Read save blob from disk. Returns [blob: Dictionary, error: String].
## error is empty on success.
## The version exact-match gate lives HERE, before any Dictionary is passed to
## load() — no system is touched when the version mismatches (AC6, "no Phase A
## even starts"). Parsing uses JSON.new().parse() (line-numbered errors), not
## parse_string() — self-written JSON may be corrupted by disk error, and the
## line number is required by AC-FILE-3.
func load_from_file(save_name: String) -> Array:  # [Dictionary, String]
	assert(_initialized, "SaveLoad: not initialized")

	var file_path := _save_path(save_name)

	if not FileAccess.file_exists(file_path):
		return [{}, "Save file '%s' not found" % file_path]

	var f := FileAccess.open(file_path, FileAccess.READ)
	if f == null:
		return [{}, "Failed to open save file '%s' (error %d)" % [file_path, FileAccess.get_open_error()]]

	var json_string := f.get_as_text()
	f.close()

	if json_string.is_empty():
		return [{}, "Save file '%s' is empty" % file_path]

	# Parse JSON (line-numbered errors for corruption diagnosis — AC-FILE-3)
	var json := JSON.new()
	var parse_error := json.parse(json_string)
	if parse_error != OK:
		return [{}, "Save file '%s' is corrupted or truncated (JSON parse error at line %d: %s)" % \
			[file_path, json.get_error_line(), json.get_error_message()]]

	var blob = json.get_data()
	if not blob is Dictionary:
		return [{}, "Save file '%s' has unexpected structure (not a JSON object)" % file_path]

	# Version check — BEFORE any system is touched (AC6)
	if not blob.has("version"):
		return [{}, "Save file '%s' is missing version field — possibly from an older format" % file_path]

	var file_version: Variant = blob["version"]
	# Type-safe exact-match: JSON parses integer literals as FLOAT in 4.7.1
	# (verified), and comparing a String to an int CRASHES at runtime in
	# GDScript. Accept int|float (1.0 == 1 numerically), reject everything else
	# as a version mismatch — never crash, always reject gracefully.
	if typeof(file_version) != TYPE_INT and typeof(file_version) != TYPE_FLOAT:
		return [{}, "Save file '%s' version mismatch: file version is %s (type %s), game expects v%d — incompatible save" % \
			[file_path, str(file_version), type_string(typeof(file_version)), SAVE_FORMAT_VERSION]]

	if file_version != SAVE_FORMAT_VERSION:
		return [{}, "Save file '%s' version mismatch: file is v%s, game expects v%d — incompatible save" % \
			[file_path, _version_label(file_version), SAVE_FORMAT_VERSION]]

	return [blob, ""]


## Public: load from disk. The caller must provide buildable_snapshot (level
## geometry from the level loader — never from the save). Delegates to Story
## 002's load() once the file-level gate passes. Returns Story 002's load
## result shape: {ok: bool, errors: Array[String]} (duck-typed Dictionary for
## now — SL-002 owns the typed result class; the global `LoadResult` name is
## taken by the equipment-catalog epic, so SL-002 must choose a distinct name).
func load_save(save_name: String, buildable_snapshot: PackedByteArray) -> Variant:
	var arr := load_from_file(save_name)
	var blob: Dictionary = arr[0]
	var error: String = arr[1]

	# File-level errors (not found, corrupt/truncated, version mismatch) return
	# ok=false with the error collected. AC6: a version mismatch rejects BEFORE
	# load() is ever called — load_from_file() gates it — so no system is
	# touched (no Phase A even starts).
	if not error.is_empty():
		return {"ok": false, "errors": [error]}

	# Delegate to Story 002's load(). SL-002 is a parallel story — until it
	# lands, load() does not exist. Guarded dynamic dispatch (has_method +
	# call): a valid file yields an honest "not wired" error, never a crash.
	# When SL-002 merges, this returns its typed result unchanged.
	if not has_method("load"):
		return {"ok": false, "errors": ["SaveLoad: load pipeline not yet wired (Story 002)"]}
	return call("load", blob, buildable_snapshot)


## Opens the write handle for a save path. Test seam: when
## _file_access_factory is set, delegates to it (mock Object with
## store_string/flush/close); otherwise the real FileAccess. Returns null on
## failure. Split from save_to_file() so AC-FILE-1/2 can inject a mock.
func _open_write(file_path: String) -> Object:
	if _file_access_factory.is_valid():
		return _file_access_factory.call(file_path)
	return FileAccess.open(file_path, FileAccess.WRITE)


## Rejects save names that could escape the saves directory (Control Manifest:
## never write to user-controlled paths — path traversal). Rejection (not
## sanitization) per the story QA edge case. Returns error string or "".
static func _validate_save_name(save_name: String) -> String:
	if save_name.is_empty():
		return "SaveLoad: save name must not be empty"
	if save_name.contains("/") or save_name.contains("\\") or save_name.contains(".."):
		return "SaveLoad: invalid save name '%s' — must not contain path separators or '..'" % save_name
	return ""


## Resolves the on-disk path for a save slot: user_data_dir/saves/<name>.sav.json.
func _save_path(save_name: String) -> String:
	return OS.get_user_data_dir().path_join(SAVE_DIR).path_join(save_name + SAVE_EXTENSION)


## Formats a version value for user-facing messages. JSON parses integer
## literals as FLOAT in 4.7.1 (e.g. 99.0), and `%d` with a float CRASHES in
## GDScript 4.7.1 ("a number is required") — so integral floats render as
## integers ("v99" not "v99.0"), everything else renders via str().
static func _version_label(v: Variant) -> String:
	if typeof(v) == TYPE_FLOAT and is_equal_approx(v, round(v)):
		return str(int(v))
	return str(v)
