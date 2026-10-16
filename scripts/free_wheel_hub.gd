class_name FreeWheelHub
extends AudioStreamPlayer3D

## Freewheel clicks in wheel order. Spoke count, and the click rate, come from this list's length.
@export var click_samples: Array[AudioStream] = []:
	set(value):
		click_samples = value
		_dirty = true
## Hub clicks played while the crank is driving. Cycled on a separate index.
@export var pedal_samples: Array[AudioStream] = []:
	set(value):
		pedal_samples = value
		_dirty = true
		

## Click rate = `speed / circumference * _spoke_count()`.
@export var wheel_circumference: float = 2.105
@export var min_speed: float = 0.05
@export var click_gain: float = 1.0
## Seconds of audio queued ahead of the speakers. Shorter starts the first clicks sooner.
@export_range(0.01, 0.2, 0.005) var buffer_length: float = 0.03
## Write each buffer pushed to the generator into a 32-bit float stereo WAV.
@export var capture_wav: bool = false
@export var capture_path: String = "res://captures/hub_capture.wav"

## Forward speed in meters per second. The vehicle writes this.
var speed: float = 0.0
## True while the crank is turning. The vehicle writes this.
var is_pedaling: bool = false
## Which freewheel click plays next, in [0, tooth_count).
var tooth_index: int = 0
## Number of loaded freewheel clicks. Matches click_samples when every file decodes.
var tooth_count: int = 0
## Which pedaling click plays next, in [0, pedal_count).
var pedal_index: int = 0
## Number of loaded pedaling clicks. Matches pedal_samples when every file decodes.
var pedal_count: int = 0
## Clicks per second being written into the buffer.
var click_rate_hz: float = 0.0
## True while new clicks are taken from [member pedal_samples].
var using_pedal_bank: bool = false

var _mix_rate: float = 44100.0
var _dirty: bool = true
var _teeth: Array[PackedFloat32Array] = []
var _pedal_teeth: Array[PackedFloat32Array] = []
var _voices: Array[ClickVoice] = []
var _out: PackedVector2Array = PackedVector2Array()
## Fraction of the way to the next tooth. Advanced by the current click rate, so acceleration shortens the gap.
var _tooth_phase: float = 0.0
var _render_speed: float = 0.0
var _capture: FileAccess
var _capture_frames: int = 0
var _capture_failed: bool = false

class ClickVoice:
	var samples: PackedFloat32Array
	var pos: int = 0


func _ready() -> void:
	add_to_group(&"freewheel_hub")
	_mix_rate = AudioServer.get_mix_rate()
	if _mix_rate <= 0.0:
		_mix_rate = 44100.0
	var generator := AudioStreamGenerator.new()
	generator.mix_rate = _mix_rate
	generator.buffer_length = buffer_length
	stream = generator
	_rebuild_wheel()
	_dirty = false


func _process(_delta: float) -> void:
	if _dirty:
		_rebuild_wheel()
		_dirty = false
	if not capture_wav:
		_capture_failed = false
		if _capture != null:
			_close_capture()
	_fill_available()


func _exit_tree() -> void:
	_close_capture()


func _rebuild_wheel() -> void:
	_voices.clear()
	_teeth = _decode_bank(click_samples)
	_pedal_teeth = _decode_bank(pedal_samples)
	tooth_count = _teeth.size()
	pedal_count = _pedal_teeth.size()
	tooth_index = 0 if tooth_count == 0 else posmod(tooth_index, tooth_count)
	pedal_index = 0 if pedal_count == 0 else posmod(pedal_index, pedal_count)
	_report_bank("freewheel", _teeth, click_samples)
	_report_bank("pedaling", _pedal_teeth, pedal_samples)


func _decode_bank(samples: Array[AudioStream]) -> Array[PackedFloat32Array]:
	var bank: Array[PackedFloat32Array] = []
	for sample in samples:
		if sample == null:
			continue
		var pcm := _load_pcm(sample)
		if pcm.is_empty():
			push_warning("FreeWheelHub: could not read '%s'." % sample.resource_path)
			continue
		bank.append(pcm)
	return bank


func _report_bank(label: String, bank: Array[PackedFloat32Array], samples: Array[AudioStream]) -> void:
	if bank.is_empty():
		push_warning("FreeWheelHub: no %s clicks loaded." % label)
		return
	var path := ""
	for sample in samples:
		if sample != null and not sample.resource_path.is_empty():
			path = sample.resource_path
			break
	print("FreeWheelHub: loaded %d %s clicks, first is %d frames (%s)." % [
		bank.size(), label, bank[0].size(), path
	])


func _load_pcm(sample: AudioStream) -> PackedFloat32Array:
	var path := sample.resource_path
	if path.is_empty() or not FileAccess.file_exists(path):
		push_warning("FreeWheelHub: missing file for '%s'." % path)
		return PackedFloat32Array()
	return _pcm_from_riff(FileAccess.get_file_as_bytes(path), path)


func _pcm_from_riff(raw: PackedByteArray, label: String) -> PackedFloat32Array:
	if raw.size() < 44 or raw.slice(0, 4).get_string_from_ascii() != "RIFF":
		push_warning("FreeWheelHub: '%s' did not decode to a WAV." % label)
		return PackedFloat32Array()
	var channels := 1
	var sample_rate := 44100
	var bits := 16
	var audio_format := 1
	var data_offset := -1
	var data_size := 0
	var pos := 12
	while pos + 8 <= raw.size():
		var chunk_id := raw.slice(pos, pos + 4).get_string_from_ascii()
		var chunk_size := raw.decode_u32(pos + 4)
		var body := pos + 8
		if chunk_id == "fmt " and chunk_size >= 16 and body + 16 <= raw.size():
			audio_format = raw.decode_u16(body)
			channels = raw.decode_u16(body + 2)
			sample_rate = raw.decode_u32(body + 4)
			bits = raw.decode_u16(body + 14)
		elif chunk_id == "data":
			data_offset = body
			data_size = mini(chunk_size, raw.size() - body)
		var advance := chunk_size + (chunk_size & 1)
		if advance <= 0:
			break
		pos = body + advance
	var bytes_per_sample := int(float(bits) / 8.0)
	if data_offset < 0 or audio_format != 1 or channels < 1 or (bits != 16 and bits != 24):
		push_warning("FreeWheelHub: '%s' needs to be 16- or 24-bit PCM." % label)
		return PackedFloat32Array()
	var frame_bytes := channels * bytes_per_sample
	var frame_count := int(float(data_size) / float(frame_bytes))
	var pcm := PackedFloat32Array()
	pcm.resize(frame_count)
	var full_scale := 32768.0 if bits == 16 else 8388608.0
	for i in frame_count:
		var acc := 0.0
		for c in channels:
			var at := data_offset + (i * channels + c) * bytes_per_sample
			if bits == 16:
				acc += float(raw.decode_s16(at)) / full_scale
			else:
				var v := raw[at] | (raw[at + 1] << 8) | (raw[at + 2] << 16)
				if v >= 0x800000:
					v -= 0x1000000
				acc += float(v) / full_scale
		pcm[i] = acc / float(channels)
	if sample_rate > 0 and not is_equal_approx(float(sample_rate), _mix_rate):
		pcm = _resample(pcm, float(sample_rate) / _mix_rate)
	return pcm


func _resample(src: PackedFloat32Array, step: float) -> PackedFloat32Array:
	if src.is_empty() or step <= 0.001:
		return PackedFloat32Array()
	var out_len := maxi(int(float(src.size()) / step), 1)
	var out := PackedFloat32Array()
	out.resize(out_len)
	var last := src.size() - 1
	for i in out_len:
		var read_at := float(i) * step
		var i0 := mini(int(read_at), last)
		var i1 := mini(i0 + 1, last)
		out[i] = lerpf(src[i0], src[i1], read_at - float(i0))
	return out


func _fill_available() -> void:
	# Crank driving selects the bank for every click spawned in this buffer.
	# The tooth clock keeps running, so the switch is the next due click.
	var pedaling := is_pedaling
	using_pedal_bank = pedaling
	var speed_end := speed
	var spokes := _spoke_count()
	var rolling := speed_end >= min_speed and spokes > 0
	if rolling and not playing:
		_render_speed = speed_end
		play()
	if not playing:
		click_rate_hz = 0.0
		return
	var playback := get_stream_playback() as AudioStreamGeneratorPlayback
	if playback == null:
		return
	var count := playback.get_frames_available()
	if count <= 0:
		return
	if _out.size() != count:
		_out.resize(count)
	var speed_start := _render_speed
	_render_speed = speed_end
	var denom := maxf(float(count - 1), 1.0)
	var last_rate := 0.0
	for i in count:
		var speed_here := lerpf(speed_start, speed_end, float(i) / denom)
		var rate := _rate_at(speed_here)
		last_rate = rate
		if rate > 0.0:
			_tooth_phase += rate / _mix_rate
			while _tooth_phase >= 1.0:
				_spawn(pedaling)
				_tooth_phase -= 1.0
		var s := _mix_voices() * click_gain
		_out[i] = Vector2(s, s)
	click_rate_hz = last_rate
	playback.push_buffer(_out)
	_append_capture(_out)


func _spoke_count() -> int:
	if tooth_count > 0:
		return tooth_count
	return pedal_count


func _rate_at(meters_per_second: float) -> float:
	var spokes := _spoke_count()
	if meters_per_second < min_speed or spokes < 1 or wheel_circumference <= 0.001:
		return 0.0
	return meters_per_second / wheel_circumference * float(spokes)


func _spawn(pedaling: bool) -> void:
	var bank := _pedal_teeth if pedaling else _teeth
	if bank.is_empty():
		return
	var voice := ClickVoice.new()
	if pedaling:
		voice.samples = bank[pedal_index]
		pedal_index = (pedal_index + 1) % bank.size()
	else:
		voice.samples = bank[tooth_index]
		tooth_index = (tooth_index + 1) % bank.size()
	_voices.append(voice)


func _append_capture(frames: PackedVector2Array) -> void:
	if not capture_wav or frames.is_empty():
		return
	if _capture == null:
		if _capture_failed:
			return
		_open_capture()
		if _capture == null:
			_capture_failed = true
			return
	var byte_count := frames.size() * 8
	var bytes := PackedByteArray()
	bytes.resize(byte_count)
	for i in frames.size():
		var sample := frames[i]
		bytes.encode_float(i * 8, sample.x)
		bytes.encode_float(i * 8 + 4, sample.y)
	_capture.seek_end(0)
	_capture.store_buffer(bytes)
	_capture_frames += frames.size()
	_patch_capture_sizes()


func _open_capture() -> void:
	var folder := capture_path.get_base_dir()
	if not folder.is_empty() and not DirAccess.dir_exists_absolute(folder):
		var err := DirAccess.make_dir_recursive_absolute(folder)
		if err != OK and err != ERR_ALREADY_EXISTS:
			push_warning("FreeWheelHub: could not create '%s' (%s)." % [folder, error_string(err)])
			return
	# Keep Godot from importing the dump while it is still being written.
	var ignore_path := folder.path_join(".gdignore")
	if not folder.is_empty() and not FileAccess.file_exists(ignore_path):
		var ignore := FileAccess.open(ignore_path, FileAccess.WRITE)
		if ignore != null:
			ignore.store_line("Hub mix dumps. Left unimported so the capture can stay open.")
			ignore.close()
	_capture = FileAccess.open(capture_path, FileAccess.WRITE)
	if _capture == null:
		push_warning("FreeWheelHub: could not open '%s' (%s)." % [
			capture_path, error_string(FileAccess.get_open_error())
		])
		return
	_capture_frames = 0
	_write_capture_header(0)
	print("FreeWheelHub: capturing mix to %s" % ProjectSettings.globalize_path(capture_path))


func _write_capture_header(data_bytes: int) -> void:
	var channels := 2
	var bits := 32
	var rate := int(_mix_rate)
	var block := channels * (bits >> 3)
	_capture.seek(0)
	_capture.store_buffer("RIFF".to_ascii_buffer())
	_capture.store_32(36 + data_bytes)
	_capture.store_buffer("WAVE".to_ascii_buffer())
	_capture.store_buffer("fmt ".to_ascii_buffer())
	_capture.store_32(16)
	_capture.store_16(3)
	_capture.store_16(channels)
	_capture.store_32(rate)
	_capture.store_32(rate * block)
	_capture.store_16(block)
	_capture.store_16(bits)
	_capture.store_buffer("data".to_ascii_buffer())
	_capture.store_32(data_bytes)


func _patch_capture_sizes() -> void:
	var data_bytes := _capture_frames * 8
	_capture.seek(4)
	_capture.store_32(36 + data_bytes)
	_capture.seek(40)
	_capture.store_32(data_bytes)


func _close_capture() -> void:
	if _capture == null:
		return
	_patch_capture_sizes()
	var seconds := float(_capture_frames) / _mix_rate
	var path := ProjectSettings.globalize_path(capture_path)
	_capture.close()
	_capture = null
	_capture_failed = false
	print("FreeWheelHub: wrote %.2fs to %s" % [seconds, path])


func _mix_voices() -> float:
	var sum := 0.0
	var i := 0
	while i < _voices.size():
		var voice := _voices[i]
		if voice.pos >= voice.samples.size():
			_voices.remove_at(i)
			continue
		sum += voice.samples[voice.pos]
		voice.pos += 1
		i += 1
	return sum
