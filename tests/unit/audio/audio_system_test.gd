class_name AudioSystemTest
extends SceneTree

## AudioSystemTest
## Comprehensive test suite for audio asset generation, WAV loading,
## AudioManager functionality, volume/muting, voice pooling, and game event signal bindings.

const AudioManagerScript := preload("res://src/audio/audio_manager.gd")
const AudioLoaderScript := preload("res://src/audio/audio_loader.gd")
const RUNNER_META := "gym_manager_test_runner_active"

var _passed := 0
var _failed := 0

func _init() -> void:
	if Engine.has_meta(RUNNER_META):
		return
	print("\n── Running AudioSystemTest ──")
	_run_all_tests()
	print("AudioSystemTest: %d passed, %d failed" % [_passed, _failed])
	if _failed > 0:
		quit(1)
	else:
		quit(0)

func run_all() -> Dictionary:
	_passed = 0
	_failed = 0
	_run_all_tests()
	return {"pass": _passed, "fail": _failed}

func _assert_true(cond: bool, msg: String) -> void:
	if cond:
		_passed += 1
	else:
		_failed += 1
		printerr("FAIL: %s" % msg)

func _assert_false(cond: bool, msg: String) -> void:
	_assert_true(not cond, msg)

func _assert_eq(actual: Variant, expected: Variant, msg: String) -> void:
	if actual == expected:
		_passed += 1
	else:
		_failed += 1
		printerr("FAIL: %s (expected %s, got %s)" % [msg, str(expected), str(actual)])

func _run_all_tests() -> void:
	_test_asset_files_exist()
	_test_audio_loader_wav_parsing()
	_test_audio_loader_looping()
	_test_audio_manager_initialization()
	_test_volume_and_mute_controls()
	_test_sfx_playback_and_pooling()
	_test_ambient_and_bgm_playback()
	_test_system_signal_wiring()

func _test_asset_files_exist() -> void:
	for id in AudioManagerScript.SFX_PATHS:
		var path: String = AudioManagerScript.SFX_PATHS[id]
		_assert_true(FileAccess.file_exists(path), "SFX file exists: %s" % path)
		var f := FileAccess.open(path, FileAccess.READ)
		_assert_true(f != null and f.get_length() > 500, "SFX file has valid content size: %s" % path)

	for id in AudioManagerScript.AMBIENT_PATHS:
		var path: String = AudioManagerScript.AMBIENT_PATHS[id]
		_assert_true(FileAccess.file_exists(path), "Ambient file exists: %s" % path)
		var f := FileAccess.open(path, FileAccess.READ)
		_assert_true(f != null and f.get_length() > 10000, "Ambient file has valid content size: %s" % path)

	for id in AudioManagerScript.BGM_PATHS:
		var path: String = AudioManagerScript.BGM_PATHS[id]
		_assert_true(FileAccess.file_exists(path), "BGM file exists: %s" % path)
		var f := FileAccess.open(path, FileAccess.READ)
		_assert_true(f != null and f.get_length() > 10000, "BGM file has valid content size: %s" % path)

func _test_audio_loader_wav_parsing() -> void:
	var sfx_stream: AudioStreamWAV = AudioLoaderScript.load_wav_file(AudioManagerScript.SFX_PATHS["placement_snap"])
	_assert_true(sfx_stream != null, "AudioLoader loaded placement_snap WAV")
	if sfx_stream != null:
		_assert_eq(sfx_stream.mix_rate, 44100, "Placement snap sample rate is 44100 Hz")
		_assert_eq(sfx_stream.stereo, false, "Placement snap is mono")
		_assert_true(sfx_stream.data.size() > 0, "Placement snap has PCM data")

	var amb_stream: AudioStreamWAV = AudioLoaderScript.load_wav_file(AudioManagerScript.AMBIENT_PATHS["gym_ambient"])
	_assert_true(amb_stream != null, "AudioLoader loaded gym_ambient WAV")
	if amb_stream != null:
		_assert_eq(amb_stream.mix_rate, 44100, "Gym ambient sample rate is 44100 Hz")
		_assert_eq(amb_stream.stereo, true, "Gym ambient is stereo")
		_assert_true(amb_stream.data.size() > 10000, "Gym ambient has substantial PCM data")

func _test_audio_loader_looping() -> void:
	var stream: AudioStream = AudioLoaderScript.load_stream(AudioManagerScript.BGM_PATHS["cozy_gym_groove"], true)
	_assert_true(stream != null, "AudioLoader loaded cozy_gym_groove")
	if stream is AudioStreamWAV:
		var wav := stream as AudioStreamWAV
		_assert_eq(wav.loop_mode, AudioStreamWAV.LOOP_FORWARD, "BGM stream loop mode is LOOP_FORWARD")
		_assert_true(wav.loop_end > 0, "BGM loop_end is set")

func _test_audio_manager_initialization() -> void:
	var mgr = AudioManagerScript.new()
	_assert_true(mgr != null, "AudioManager instantiates cleanly")
	for id in AudioManagerScript.SFX_PATHS:
		var stream: AudioStream = mgr.get_stream(id)
		_assert_true(stream != null, "Preloaded stream exists for SFX %s" % id)
	for id in AudioManagerScript.AMBIENT_PATHS:
		var stream: AudioStream = mgr.get_stream(id)
		_assert_true(stream != null, "Preloaded stream exists for Ambient %s" % id)
	for id in AudioManagerScript.BGM_PATHS:
		var stream: AudioStream = mgr.get_stream(id)
		_assert_true(stream != null, "Preloaded stream exists for BGM %s" % id)
	mgr.free()

func _test_volume_and_mute_controls() -> void:
	var mgr = AudioManagerScript.new()
	
	_assert_eq(mgr.get_master_volume(), 1.0, "Default master volume is 1.0")
	_assert_eq(mgr.get_sfx_volume(), 1.0, "Default sfx volume is 1.0")
	_assert_eq(mgr.get_ambient_volume(), 0.6, "Default ambient volume is 0.6")
	_assert_eq(mgr.get_bgm_volume(), 0.8, "Default bgm volume is 0.8")
	_assert_false(mgr.is_muted(), "Default muted state is false")

	mgr.set_master_volume(0.5)
	_assert_eq(mgr.get_master_volume(), 0.5, "Master volume updated to 0.5")
	
	mgr.set_master_volume(1.5)
	_assert_eq(mgr.get_master_volume(), 1.0, "Master volume clamped to 1.0")
	
	mgr.set_sfx_volume(-0.2)
	_assert_eq(mgr.get_sfx_volume(), 0.0, "SFX volume clamped to 0.0")

	mgr.set_muted(true)
	_assert_true(mgr.is_muted(), "Muted state is true after set_muted(true)")
	
	mgr.set_muted(false)
	_assert_false(mgr.is_muted(), "Muted state is false after set_muted(false)")
	
	mgr.free()

func _test_sfx_playback_and_pooling() -> void:
	var mgr = AudioManagerScript.new()
	mgr.set_master_volume(1.0)
	mgr.set_sfx_volume(1.0)
	mgr.set_muted(false)

	_assert_eq(mgr.get_total_sfx_played(), 0, "Initial total played is 0")
	var p1: AudioStreamPlayer = mgr.play_sfx("placement_snap")
	_assert_true(p1 != null, "play_sfx returns player node")
	_assert_eq(mgr.get_last_played_sfx(), "placement_snap", "Last played is placement_snap")
	_assert_eq(mgr.get_play_count("placement_snap"), 1, "Play count for placement_snap is 1")
	_assert_eq(mgr.get_total_sfx_played(), 1, "Total played is 1")

	# Test multiple calls and voice pooling
	for i in range(15):
		mgr.play_sfx("ui_click")
	_assert_eq(mgr.get_play_count("ui_click"), 15, "Play count for ui_click is 15")
	_assert_eq(mgr.get_total_sfx_played(), 16, "Total played is 16")

	# Test muting disables player allocation
	mgr.set_muted(true)
	var p_muted: AudioStreamPlayer = mgr.play_sfx("income_coin")
	_assert_true(p_muted == null, "play_sfx returns null when muted")
	_assert_eq(mgr.get_play_count("income_coin"), 1, "Play count still recorded while muted")

	mgr.free()

func _test_ambient_and_bgm_playback() -> void:
	var mgr = AudioManagerScript.new()
	
	mgr.play_ambient("gym_ambient")
	_assert_true(mgr.is_ambient_playing(), "Ambient player is active")

	mgr.play_bgm("cozy_gym_groove")
	_assert_true(mgr.is_bgm_playing(), "BGM player is active")

	mgr.stop_ambient()
	_assert_false(mgr.is_ambient_playing(), "Ambient player stopped")

	mgr.stop_bgm()
	_assert_false(mgr.is_bgm_playing(), "BGM player stopped")

	mgr.free()

# Mock emitter for signal wiring tests
class MockEconomyEmitter extends Node:
	signal balance_changed(new_balance: int, delta: int)

class MockPlacementEmitter extends Node:
	signal placement_committed(instance_id: int, equipment_id: String, cells: Array[Vector2i])

class MockSelectionBridgeEmitter extends Node:
	signal sell_confirm_confirmed
	signal sell_confirm_started

func _test_system_signal_wiring() -> void:
	var mgr = AudioManagerScript.new()
	
	# Test mock economy signal
	var mock_econ := MockEconomyEmitter.new()
	mock_econ.balance_changed.connect(func(nb: int, d: int) -> void:
		if d > 0:
			mgr.play_sfx("income_coin")
		elif d < 0:
			mgr.play_sfx("purchase_confirm")
	)
	
	mock_econ.balance_changed.emit(1050, 50)
	_assert_eq(mgr.get_last_played_sfx(), "income_coin", "Positive balance delta triggers income_coin")
	
	mock_econ.balance_changed.emit(1020, -30)
	_assert_eq(mgr.get_last_played_sfx(), "purchase_confirm", "Negative balance delta triggers purchase_confirm")

	# Test mock placement signal
	var mock_placement := MockPlacementEmitter.new()
	mock_placement.placement_committed.connect(func(_id: int, _eq: String, _c: Array[Vector2i]) -> void:
		mgr.play_sfx("placement_snap")
	)
	var cells: Array[Vector2i] = [Vector2i(1, 1)]
	mock_placement.placement_committed.emit(1, "treadmill", cells)
	_assert_eq(mgr.get_last_played_sfx(), "placement_snap", "Placement commit triggers placement_snap")

	# Test mock selection bridge signals
	var mock_bridge := MockSelectionBridgeEmitter.new()
	mock_bridge.sell_confirm_confirmed.connect(func() -> void:
		mgr.play_sfx("sold_cue")
	)
	mock_bridge.sell_confirm_started.connect(func() -> void:
		mgr.play_sfx("ui_click")
	)
	mock_bridge.sell_confirm_started.emit()
	_assert_eq(mgr.get_last_played_sfx(), "ui_click", "Sell start triggers ui_click")
	mock_bridge.sell_confirm_confirmed.emit()
	_assert_eq(mgr.get_last_played_sfx(), "sold_cue", "Sell confirm triggers sold_cue")

	# Test dialogue and save notification calls
	mgr.notify_dialogue_advanced("阿洛：今天感觉非常棒！")
	_assert_eq(mgr.get_last_played_sfx(), "dialogue_blip", "Dialogue advance triggers dialogue_blip")

	mgr.notify_save_completed()
	_assert_eq(mgr.get_last_played_sfx(), "save_chime", "Save completion triggers save_chime")

	mock_econ.free()
	mock_placement.free()
	mock_bridge.free()
	mgr.free()
