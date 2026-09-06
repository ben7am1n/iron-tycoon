class_name AudioLoader
extends RefCounted

## AudioLoader
## Resilient audio resource loader for Iron Tycoon.
## Supports loading imported Godot AudioStream resources, and provides
## a deterministic raw WAV fallback parser for headless environments.

static func load_stream(res_path: String, loop: bool = false) -> AudioStream:
	var stream: AudioStream = null
	if ResourceLoader.exists(res_path):
		var res := ResourceLoader.load(res_path)
		if res is AudioStream:
			stream = res
	
	if stream == null:
		stream = load_wav_file(res_path)

	if stream is AudioStreamWAV and loop:
		var wav_stream := stream as AudioStreamWAV
		wav_stream.loop_mode = AudioStreamWAV.LOOP_FORWARD
		if wav_stream.loop_end == 0 and wav_stream.data.size() > 0:
			var bytes_per_sample := 2 if wav_stream.format == AudioStreamWAV.FORMAT_16_BITS else 1
			var channels := 2 if wav_stream.stereo else 1
			wav_stream.loop_end = wav_stream.data.size() / (bytes_per_sample * channels)

	return stream

static func load_wav_file(file_path: String) -> AudioStreamWAV:
	if not FileAccess.file_exists(file_path):
		push_warning("AudioLoader: File does not exist: %s" % file_path)
		return null
	
	var file := FileAccess.open(file_path, FileAccess.READ)
	if file == null:
		push_warning("AudioLoader: Failed to open file: %s" % file_path)
		return null
	
	# Validate RIFF header
	var riff_tag := file.get_buffer(4).get_string_from_ascii()
	if riff_tag != "RIFF":
		push_warning("AudioLoader: Not a RIFF file: %s" % file_path)
		return null
	
	file.get_32() # File size minus 8
	var wave_tag := file.get_buffer(4).get_string_from_ascii()
	if wave_tag != "WAVE":
		push_warning("AudioLoader: Not a WAVE file: %s" % file_path)
		return null
	
	var format := AudioStreamWAV.FORMAT_16_BITS
	var channels := 1
	var sample_rate := 44100
	var audio_data := PackedByteArray()
	
	while file.get_position() < file.get_length():
		var chunk_id := file.get_buffer(4).get_string_from_ascii()
		var chunk_size := file.get_32()
		var next_chunk_pos := file.get_position() + chunk_size
		
		if chunk_id == "fmt ":
			var audio_format := file.get_16() # 1 = PCM
			channels = file.get_16()
			sample_rate = file.get_32()
			file.get_32() # Byte rate
			file.get_16() # Block align
			var bits_per_sample := file.get_16()
			if bits_per_sample == 8:
				format = AudioStreamWAV.FORMAT_8_BITS
			elif bits_per_sample == 16:
				format = AudioStreamWAV.FORMAT_16_BITS
		elif chunk_id == "data":
			audio_data = file.get_buffer(chunk_size)
		
		file.seek(next_chunk_pos)
	
	if audio_data.is_empty():
		push_warning("AudioLoader: No audio data found in WAV: %s" % file_path)
		return null
	
	var wav := AudioStreamWAV.new()
	wav.format = format
	wav.stereo = (channels >= 2)
	wav.mix_rate = sample_rate
	wav.data = audio_data
	return wav
