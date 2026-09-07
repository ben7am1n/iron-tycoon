class_name AudioManager
extends Node

## AudioManager
## Centralized audio manager and event sound router for Iron Tycoon.
## Implements voice pooling for SFX, looping ambient audio, looping cozy BGM,
## volume attenuation, muting, and automated signal bindings to core game systems
## according to design/assets/entity-inventory.md §Audio.

const AudioLoaderScript := preload("res://src/audio/audio_loader.gd")

# Asset path mappings
const SFX_PATHS := {
	"placement_snap": "res://assets/audio/sfx/placement_snap.wav",
	"pickup": "res://assets/audio/sfx/pickup.wav",
	"purchase_confirm": "res://assets/audio/sfx/purchase_confirm.wav",
	"sold_cue": "res://assets/audio/sfx/sold_cue.wav",
	"income_coin": "res://assets/audio/sfx/income_coin.wav",
	"satisfaction_chime": "res://assets/audio/sfx/satisfaction_chime.wav",
	"save_chime": "res://assets/audio/sfx/save_chime.wav",
	"ui_click": "res://assets/audio/sfx/ui_click.wav",
	"dialogue_blip": "res://assets/audio/sfx/dialogue_blip.wav",
}

const AMBIENT_PATHS := {
	"gym_ambient": "res://assets/audio/ambient/gym_ambient.wav",
}

const BGM_PATHS := {
	"cozy_gym_groove": "res://assets/audio/bgm/cozy_gym_groove.wav",
}

const SFX_POOL_SIZE := 12

# Volume levels (0.0 to 1.0)
var _master_volume: float = 1.0
var _sfx_volume: float = 1.0
var _ambient_volume: float = 0.6
var _bgm_volume: float = 0.8
var _is_muted: bool = false

# Preloaded AudioStream resources
var _streams: Dictionary = {}

# Node players
var _sfx_players: Array[AudioStreamPlayer] = []
var _ambient_player: AudioStreamPlayer = null
var _bgm_player: AudioStreamPlayer = null

# Diagnostics & statistics
var _last_played_sfx: String = ""
var _sfx_play_counts: Dictionary = {}
var _total_sfx_played: int = 0
var _active_bgm_id: String = ""
var _active_ambient_id: String = ""

# Track last dialogue text to detect advances
var _last_dialogue_text: String = ""


func _init() -> void:
	_init_players()
	_preload_assets()


func _init_players() -> void:
	for i in range(SFX_POOL_SIZE):
		var player := AudioStreamPlayer.new()
		player.name = "SFXPlayer_%d" % i
		_sfx_players.append(player)
		add_child(player)
	
	_ambient_player = AudioStreamPlayer.new()
	_ambient_player.name = "AmbientPlayer"
	add_child(_ambient_player)
	
	_bgm_player = AudioStreamPlayer.new()
	_bgm_player.name = "BGMPlayer"
	add_child(_bgm_player)


func _preload_assets() -> void:
	for id in SFX_PATHS:
		var stream := AudioLoaderScript.load_stream(SFX_PATHS[id], false)
		if stream != null:
			_streams[id] = stream
		_sfx_play_counts[id] = 0
		
	for id in AMBIENT_PATHS:
		var stream := AudioLoaderScript.load_stream(AMBIENT_PATHS[id], true)
		if stream != null:
			_streams[id] = stream
			
	for id in BGM_PATHS:
		var stream := AudioLoaderScript.load_stream(BGM_PATHS[id], true)
		if stream != null:
			_streams[id] = stream


# =========================================================================
# Playback API
# =========================================================================

## Plays a sound effect by ID with optional volume offset and pitch modulation.
func play_sfx(sfx_id: String, volume_db_offset: float = 0.0, pitch_scale: float = 1.0) -> AudioStreamPlayer:
	if _is_muted or _master_volume <= 0.0 or _sfx_volume <= 0.0:
		_record_sfx_play(sfx_id)
		return null
		
	var stream: AudioStream = _streams.get(sfx_id)
	if stream == null:
		var path: String = SFX_PATHS.get(sfx_id, "")
		if path != "":
			stream = AudioLoaderScript.load_stream(path, false)
			if stream != null:
				_streams[sfx_id] = stream
				
	if stream == null:
		push_warning("AudioManager: SFX stream not found: %s" % sfx_id)
		return null
		
	var player := _acquire_sfx_player()
	if player == null:
		return null
		
	var final_db := _calculate_db(_sfx_volume * _master_volume) + volume_db_offset
	player.stream = stream
	player.volume_db = final_db
	player.pitch_scale = clampf(pitch_scale, 0.5, 2.0)
	if is_inside_tree():
		player.play()
	
	_record_sfx_play(sfx_id)
	return player


## Plays looping ambient sound.
func play_ambient(ambient_id: String = "gym_ambient", _fade_in_sec: float = 0.5) -> void:
	_active_ambient_id = ambient_id
	if _ambient_player == null:
		return
		
	if _is_muted or _master_volume <= 0.0 or _ambient_volume <= 0.0:
		_ambient_player.stop()
		return
		
	var stream: AudioStream = _streams.get(ambient_id)
	if stream == null:
		var path: String = AMBIENT_PATHS.get(ambient_id, "")
		if path != "":
			stream = AudioLoaderScript.load_stream(path, true)
			if stream != null:
				_streams[ambient_id] = stream
				
	if stream == null:
		return
		
	if _ambient_player.stream != stream:
		_ambient_player.stream = stream
		
	_ambient_player.volume_db = _calculate_db(_ambient_volume * _master_volume)
	if not _ambient_player.playing and is_inside_tree():
		_ambient_player.play()


## Stops ambient sound.
func stop_ambient(_fade_out_sec: float = 0.5) -> void:
	_active_ambient_id = ""
	if _ambient_player != null:
		_ambient_player.stop()


## Plays looping background music.
func play_bgm(bgm_id: String = "cozy_gym_groove", _fade_in_sec: float = 0.5) -> void:
	_active_bgm_id = bgm_id
	if _bgm_player == null:
		return
		
	if _is_muted or _master_volume <= 0.0 or _bgm_volume <= 0.0:
		_bgm_player.stop()
		return
		
	var stream: AudioStream = _streams.get(bgm_id)
	if stream == null:
		var path: String = BGM_PATHS.get(bgm_id, "")
		if path != "":
			stream = AudioLoaderScript.load_stream(path, true)
			if stream != null:
				_streams[bgm_id] = stream
				
	if stream == null:
		return
		
	if _bgm_player.stream != stream:
		_bgm_player.stream = stream
		
	_bgm_player.volume_db = _calculate_db(_bgm_volume * _master_volume)
	if not _bgm_player.playing and is_inside_tree():
		_bgm_player.play()


## Stops background music.
func stop_bgm(_fade_out_sec: float = 0.5) -> void:
	_active_bgm_id = ""
	if _bgm_player != null:
		_bgm_player.stop()


# =========================================================================
# Volume & Mute Controls
# =========================================================================

func set_master_volume(vol: float) -> void:
	_master_volume = clampf(vol, 0.0, 1.0)
	_apply_volumes()


func get_master_volume() -> float:
	return _master_volume


func set_sfx_volume(vol: float) -> void:
	_sfx_volume = clampf(vol, 0.0, 1.0)
	_apply_volumes()


func get_sfx_volume() -> float:
	return _sfx_volume


func set_ambient_volume(vol: float) -> void:
	_ambient_volume = clampf(vol, 0.0, 1.0)
	_apply_volumes()


func get_ambient_volume() -> float:
	return _ambient_volume


func set_bgm_volume(vol: float) -> void:
	_bgm_volume = clampf(vol, 0.0, 1.0)
	_apply_volumes()


func get_bgm_volume() -> float:
	return _bgm_volume


func set_muted(muted: bool) -> void:
	_is_muted = muted
	if _is_muted:
		for p in _sfx_players:
			p.stop()
		if _ambient_player != null:
			_ambient_player.stop()
		if _bgm_player != null:
			_bgm_player.stop()
	else:
		if _active_ambient_id != "":
			play_ambient(_active_ambient_id)
		if _active_bgm_id != "":
			play_bgm(_active_bgm_id)


func is_muted() -> bool:
	return _is_muted


func _apply_volumes() -> void:
	if _is_muted:
		return
	if _ambient_player != null and _ambient_player.playing:
		_ambient_player.volume_db = _calculate_db(_ambient_volume * _master_volume)
	if _bgm_player != null and _bgm_player.playing:
		_bgm_player.volume_db = _calculate_db(_bgm_volume * _master_volume)


func _calculate_db(linear: float) -> float:
	if linear <= 0.0001:
		return -80.0
	return linear_to_db(linear)


# =========================================================================
# Voice Pooling & Diagnostics
# =========================================================================

func _acquire_sfx_player() -> AudioStreamPlayer:
	for player in _sfx_players:
		if not player.playing:
			return player
	# If all busy, steal the first player
	if not _sfx_players.is_empty():
		return _sfx_players[0]
	return null


func _record_sfx_play(sfx_id: String) -> void:
	_last_played_sfx = sfx_id
	_total_sfx_played += 1
	_sfx_play_counts[sfx_id] = _sfx_play_counts.get(sfx_id, 0) + 1


func get_last_played_sfx() -> String:
	return _last_played_sfx


func get_play_count(sfx_id: String) -> int:
	return _sfx_play_counts.get(sfx_id, 0)


func get_total_sfx_played() -> int:
	return _total_sfx_played


func get_stream(asset_id: String) -> AudioStream:
	return _streams.get(asset_id)


func is_bgm_playing() -> bool:
	if _bgm_player == null:
		return false
	if is_inside_tree():
		return _bgm_player.playing
	return _active_bgm_id != "" and not _is_muted


func is_ambient_playing() -> bool:
	if _ambient_player == null:
		return false
	if is_inside_tree():
		return _ambient_player.playing
	return _active_ambient_id != "" and not _is_muted


# =========================================================================
# Game System Wiring Integration
# =========================================================================

## Connects PlacementSystem events:
## - placement_committed -> plays "placement_snap"
func connect_placement_system(placement_system: Object) -> void:
	if placement_system == null:
		return
	if placement_system.has_signal("placement_committed"):
		if not placement_system.is_connected("placement_committed", _on_placement_committed):
			placement_system.connect("placement_committed", _on_placement_committed)


func _on_placement_committed(_instance_id: int, _equipment_id: String, _cells: Array[Vector2i]) -> void:
	play_sfx("placement_snap")


## Connects SelectionInputBridge events:
## - sell_confirm_confirmed -> plays "sold_cue"
## - sell_confirm_started -> plays "ui_click"
func connect_selection_bridge(bridge: Object) -> void:
	if bridge == null:
		return
	if bridge.has_signal("sell_confirm_confirmed"):
		if not bridge.is_connected("sell_confirm_confirmed", _on_sell_confirm_confirmed):
			bridge.connect("sell_confirm_confirmed", _on_sell_confirm_confirmed)
	if bridge.has_signal("sell_confirm_started"):
		if not bridge.is_connected("sell_confirm_started", _on_sell_confirm_started):
			bridge.connect("sell_confirm_started", _on_sell_confirm_started)


func _on_sell_confirm_confirmed() -> void:
	play_sfx("sold_cue")


func _on_sell_confirm_started() -> void:
	play_sfx("ui_click")


## Connects Economy events:
## - balance_changed:
##   * delta > 0 (member finish / revenue) -> "income_coin"
##   * delta < 0 (purchase cost) -> "purchase_confirm"
func connect_economy(economy: Object) -> void:
	if economy == null:
		return
	if economy.has_signal("balance_changed"):
		if not economy.is_connected("balance_changed", _on_economy_balance_changed):
			economy.connect("balance_changed", _on_economy_balance_changed)


func _on_economy_balance_changed(_new_balance: int, delta: int) -> void:
	if delta > 0:
		play_sfx("income_coin")
	elif delta < 0:
		play_sfx("purchase_confirm")


## Connects DayCycleSystem events:
## - phase_changed:
##   * "day_service": start ambient hum + cozy BGM
##   * "day_close": play satisfaction chime or calm close
func connect_day_cycle(day_cycle: Object) -> void:
	if day_cycle == null:
		return
	if day_cycle.has_signal("phase_changed"):
		if not day_cycle.is_connected("phase_changed", _on_phase_changed):
			day_cycle.connect("phase_changed", _on_phase_changed)


func _on_phase_changed(phase: String) -> void:
	match phase:
		"day_prep", "PREP":
			play_ambient("gym_ambient")
			play_bgm("cozy_gym_groove")
		"day_service", "SERVICE":
			play_ambient("gym_ambient")
			play_bgm("cozy_gym_groove")
		"OUTING":
			stop_ambient()
		"day_close", "CLOSE":
			play_sfx("satisfaction_chime")
		_:
			pass


## Connects CommunityHud events:
## - action_requested -> plays "ui_click"
func connect_community_hud(community_hud: Object) -> void:
	if community_hud == null:
		return
	if community_hud.has_signal("action_requested"):
		if not community_hud.is_connected("action_requested", _on_community_action_requested):
			community_hud.connect("action_requested", _on_community_action_requested)


func _on_community_action_requested(_action: String, _payload: Dictionary) -> void:
	play_sfx("ui_click")


## Triggers text blip on dialogue updates
func notify_dialogue_advanced(new_text: String) -> void:
	if new_text != "" and new_text != _last_dialogue_text:
		_last_dialogue_text = new_text
		play_sfx("dialogue_blip", -4.0)


## Triggers save chime
func notify_save_completed() -> void:
	play_sfx("save_chime")
