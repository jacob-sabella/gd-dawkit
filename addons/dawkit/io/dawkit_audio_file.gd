class_name DawKitAudioFile
extends RefCounted

## The audio files people bring to a project: WAV (8/16/24/32-bit integer, 32/64-bit float,
## plain or WAVE_FORMAT_EXTENSIBLE), AIFF and AIFF-C, FLAC (DawKitFlac), Ogg Vorbis and MP3.
##
## `read` gives the sound as samples, mono or stereo (more channels are folded down to two).
## `bring_in` puts a file where a project keeps its media, in a form the engine plays: a WAV the
## engine already reads is copied untouched, byte for byte, and anything else is written as a
## 32-bit float WAV, which loses nothing from a 24-bit or 32-bit source.
##
## Ogg and MP3 are decoded by Godot, which hands back the sound at the audio server's mix rate,
## so that is the rate their WAV is written at. FLAC is decoded here, at its own rate.

const PEAKS_PER_SECOND := 50

const _FORMAT_PCM := 1
const _FORMAT_FLOAT := 3
const _FORMAT_EXTENSIBLE := 0xFFFE


## {"samples": PackedFloat32Array (interleaved), "channels": 1 or 2, "rate": int,
## "frames": int, "error": String}. On an error, the rest is empty.
static func read(path: String) -> Dictionary:
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.is_empty():
		return _fail("%s could not be read" % path.get_file())
	var magic := bytes.slice(0, 4).get_string_from_ascii()
	if magic == "RIFF" and bytes.slice(8, 12).get_string_from_ascii() == "WAVE":
		return _read_wav(bytes, path)
	if magic == "FORM" and bytes.slice(8, 12).get_string_from_ascii() in ["AIFF", "AIFC"]:
		return _read_aiff(bytes, path)
	if magic == "fLaC":
		var flac := DawKitFlac.decode_ints(bytes)
		if not str(flac["error"]).is_empty():
			return _fail("%s: %s" % [path.get_file(), flac["error"]])
		var ints: PackedInt64Array = flac["samples"]
		var raw := PackedFloat32Array()
		raw.resize(ints.size())
		var scale := 1.0 / float(1 << (int(flac["bits"]) - 1))
		for i in ints.size():
			raw[i] = ints[i] * scale
		return _samples(raw, flac["channels"], flac["rate"])
	if magic == "OggS":
		return _decode(AudioStreamOggVorbis.load_from_file(path), path)
	if magic.begins_with("ID3") or (bytes.size() > 1 and bytes[0] == 0xFF and (bytes[1] & 0xE0) == 0xE0):
		return _decode(AudioStreamMP3.load_from_file(path), path)
	return _fail("%s is not a sound file this can read (WAV, AIFF, FLAC, Ogg or MP3)" % path.get_file())


## Puts `source` at `dest` as a file the engine plays. {"seconds", "peaks", "rate", "channels",
## "copied": whether the original went over untouched, "error"}.
static func bring_in(source: String, dest: String) -> Dictionary:
	var sound := read(source)
	if not str(sound["error"]).is_empty():
		return {"error": sound["error"]}
	if int(sound["frames"]) == 0:
		return {"error": "%s has no sound in it" % source.get_file()}
	DirAccess.make_dir_recursive_absolute(dest.get_base_dir())
	var copied := _plays_as_is(source)
	var err := DirAccess.copy_absolute(source, dest) if copied \
			else write_wav(dest, sound["samples"], int(sound["channels"]), int(sound["rate"]))
	if err != OK:
		return {"error": "%s could not be written (%s)" % [dest.get_file(), error_string(err)]}
	return {
		"seconds": float(sound["frames"]) / float(sound["rate"]),
		"peaks": peaks(sound["samples"], int(sound["channels"]), int(sound["rate"])),
		"rate": sound["rate"], "channels": sound["channels"], "copied": copied, "error": "",
	}


## The bit depths `write_wav` writes: 16- and 24-bit integer, and 32-bit float.
const WRITE_BITS: Array[int] = [16, 24, 32]


## A WAV of `bits`: 32 is float, with the 18-byte format chunk and the fact chunk that float WAVs
## carry; 16 and 24 are integer, dithered -- triangular noise of one step either way added before
## rounding, so a fade's last bits fall into a little hiss rather than a buzz of rounding steps.
## Its own seeded noise, so the same sound writes the same file. Anything else is written as 32.
static func write_wav(path: String, samples: PackedFloat32Array, channels: int, rate: int,
		bits := 32) -> Error:
	if bits == 16 or bits == 24:
		return _write_pcm(path, samples, channels, rate, bits)
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	var data := samples.to_byte_array()
	var frames := samples.size() / maxi(channels, 1)
	f.store_buffer("RIFF".to_ascii_buffer())
	f.store_32(4 + (8 + 18) + (8 + 4) + 8 + data.size())
	f.store_buffer("WAVEfmt ".to_ascii_buffer())
	f.store_32(18)
	f.store_16(_FORMAT_FLOAT)
	f.store_16(channels)
	f.store_32(rate)
	f.store_32(rate * channels * 4)
	f.store_16(channels * 4)
	f.store_16(32)
	f.store_16(0)
	f.store_buffer("fact".to_ascii_buffer())
	f.store_32(4)
	f.store_32(frames)
	f.store_buffer("data".to_ascii_buffer())
	f.store_32(data.size())
	f.store_buffer(data)
	f.close()
	return OK


static func _write_pcm(path: String, samples: PackedFloat32Array, channels: int, rate: int,
		bits: int) -> Error:
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		return FileAccess.get_open_error()
	var width := bits / 8
	var top := float((1 << (bits - 1)) - 1)
	var low := -(1 << (bits - 1))
	var noise := RandomNumberGenerator.new()
	noise.seed = 0x5EED
	var data := PackedByteArray()
	data.resize(samples.size() * width)
	for i in samples.size():
		var v := clampi(int(roundf(clampf(samples[i], -1.0, 1.0) * top + noise.randf() - noise.randf())),
				low, int(top))
		if width == 2:
			data.encode_s16(i * 2, v)
		else:
			data[i * 3] = v & 0xFF
			data[i * 3 + 1] = (v >> 8) & 0xFF
			data[i * 3 + 2] = (v >> 16) & 0xFF
	f.store_buffer("RIFF".to_ascii_buffer())
	f.store_32(4 + (8 + 16) + 8 + data.size())
	f.store_buffer("WAVEfmt ".to_ascii_buffer())
	f.store_32(16)
	f.store_16(_FORMAT_PCM)
	f.store_16(channels)
	f.store_32(rate)
	f.store_32(rate * channels * width)
	f.store_16(channels * width)
	f.store_16(bits)
	f.store_buffer("data".to_ascii_buffer())
	f.store_32(data.size())
	f.store_buffer(data)
	f.close()
	return OK


## The loudest sample of every 1/50 s, 0..255 for silence to full scale: what a timeline draws.
static func peaks(samples: PackedFloat32Array, channels: int, rate: int,
		per_second := PEAKS_PER_SECOND) -> PackedByteArray:
	var out := PackedByteArray()
	var step := maxi(rate / per_second, 1) * channels
	var at := 0
	var n := samples.size()
	while at < n:
		var end := mini(at + step, n)
		var loudest := 0.0
		for i in range(at, end):
			var v := absf(samples[i])
			if v > loudest:
				loudest = v
		out.append(clampi(int(loudest * 255.0), 0, 255))
		at = end
	return out


# --- WAV ----------------------------------------------------------------------------------

## The chunks of a RIFF file: {id: [offset of the body, size]}, first of each kind.
static func _chunks(bytes: PackedByteArray, from: int, big_endian := false) -> Dictionary:
	var out := {}
	var at := from
	while at + 8 <= bytes.size():
		var id := bytes.slice(at, at + 4).get_string_from_ascii()
		var size := _u32be(bytes, at + 4) if big_endian else bytes.decode_u32(at + 4)
		if not out.has(id):
			out[id] = [at + 8, mini(size, bytes.size() - at - 8)]
		at += 8 + size + (size & 1)
	return out


static func _wav_format(bytes: PackedByteArray) -> Dictionary:
	var chunks := _chunks(bytes, 12)
	if not chunks.has("fmt ") or not chunks.has("data"):
		return {}
	var at: int = chunks["fmt "][0]
	var tag := bytes.decode_u16(at)
	if tag == _FORMAT_EXTENSIBLE and chunks["fmt "][1] >= 40:
		tag = bytes.decode_u16(at + 24)
	return {"tag": tag, "channels": bytes.decode_u16(at + 2), "rate": bytes.decode_u32(at + 4),
			"bits": bytes.decode_u16(at + 14), "plain": bytes.decode_u16(at) != _FORMAT_EXTENSIBLE,
			"data": chunks["data"]}


static func _read_wav(bytes: PackedByteArray, path: String) -> Dictionary:
	var fmt := _wav_format(bytes)
	if fmt.is_empty():
		return _fail("%s is a WAV with no sound in it" % path.get_file())
	var tag: int = fmt["tag"]
	var bits: int = fmt["bits"]
	if not ((tag == _FORMAT_PCM and bits in [8, 16, 24, 32]) or (tag == _FORMAT_FLOAT and bits in [32, 64])):
		return _fail("%s is a compressed WAV (format %d, %d-bit); save it as PCM" % [path.get_file(), tag, bits])
	var data: Array = fmt["data"]
	var body := bytes.slice(data[0], data[0] + data[1])
	return _samples(_decode_pcm(body, bits, tag == _FORMAT_FLOAT, false), fmt["channels"], fmt["rate"])


## Whether the engine plays the file as it is: plain PCM 8/16-bit or float, one or two channels.
static func _plays_as_is(path: String) -> bool:
	var bytes := FileAccess.get_file_as_bytes(path)
	if bytes.slice(0, 4).get_string_from_ascii() != "RIFF" or bytes.slice(8, 12).get_string_from_ascii() != "WAVE":
		return false
	var fmt := _wav_format(bytes)
	if fmt.is_empty() or not fmt["plain"] or int(fmt["channels"]) > 2:
		return false
	return (fmt["tag"] == _FORMAT_PCM and int(fmt["bits"]) in [8, 16]) \
			or (fmt["tag"] == _FORMAT_FLOAT and int(fmt["bits"]) in [32, 64])


# --- AIFF ---------------------------------------------------------------------------------

static func _read_aiff(bytes: PackedByteArray, path: String) -> Dictionary:
	var chunks := _chunks(bytes, 12, true)
	if not chunks.has("COMM") or not chunks.has("SSND"):
		return _fail("%s is an AIFF with no sound in it" % path.get_file())
	var at: int = chunks["COMM"][0]
	var channels := _u16be(bytes, at)
	var bits := _u16be(bytes, at + 6)
	var rate := int(round(_extended(bytes, at + 8)))
	var floating := false
	var little := false
	if bytes.slice(8, 12).get_string_from_ascii() == "AIFC":
		var kind := bytes.slice(at + 18, at + 22).get_string_from_ascii()
		match kind:
			"NONE", "twos": pass
			"sowt": little = true
			"fl32", "FL32": floating = true; bits = 32
			"fl64", "FL64": floating = true; bits = 64
			_: return _fail("%s is a compressed AIFF (%s); save it as PCM" % [path.get_file(), kind])
	if not (bits in [8, 16, 24, 32] or (floating and bits == 64)):
		return _fail("%s is a %d-bit AIFF, which cannot be read" % [path.get_file(), bits])
	var sound: Array = chunks["SSND"]
	var start: int = sound[0] + 8 + _u32be(bytes, sound[0])
	var body := bytes.slice(start, sound[0] + sound[1])
	return _samples(_decode_pcm(body, bits, floating, not little, true), channels, rate)


static func _u16be(b: PackedByteArray, at: int) -> int:
	return (b[at] << 8) | b[at + 1]


static func _u32be(b: PackedByteArray, at: int) -> int:
	return (b[at] << 24) | (b[at + 1] << 16) | (b[at + 2] << 8) | b[at + 3]


## The 80-bit IEEE extended float AIFF gives its sample rate in.
static func _extended(b: PackedByteArray, at: int) -> float:
	var exponent := (_u16be(b, at) & 0x7FFF) - 16383
	var mantissa := 0.0
	for i in 8:
		mantissa = mantissa * 256.0 + b[at + 2 + i]
	return mantissa * pow(2.0, exponent - 63)


# --- samples ------------------------------------------------------------------------------

## Raw sample bytes to floats in -1..1, interleaved as they were. WAV 8-bit is unsigned;
## AIFF 8-bit is signed.
static func _decode_pcm(body: PackedByteArray, bits: int, floating: bool, big_endian: bool,
		signed_8 := false) -> PackedFloat32Array:
	var width := bits / 8
	if big_endian and width > 1:
		body = _swapped(body, width)
	if floating:
		return body.to_float32_array() if bits == 32 else PackedFloat32Array(Array(body.to_float64_array()))
	var count := body.size() / width
	var out := PackedFloat32Array()
	out.resize(count)
	match bits:
		8:
			for i in count:
				out[i] = (float(body.decode_s8(i)) if signed_8 else float(body[i]) - 128.0) / 128.0
		16:
			for i in count:
				out[i] = body.decode_s16(i * 2) / 32768.0
		24:
			for i in count:
				var at := i * 3
				var v := body[at] | (body[at + 1] << 8) | (body[at + 2] << 16)
				out[i] = float(v - 0x1000000 if v >= 0x800000 else v) / 8388608.0
		32:
			var ints := body.to_int32_array()
			for i in count:
				out[i] = ints[i] / 2147483648.0
	return out


static func _swapped(body: PackedByteArray, width: int) -> PackedByteArray:
	var out := body.duplicate()
	var n := body.size() - body.size() % width
	for at in range(0, n, width):
		for k in width:
			out[at + k] = body[at + width - 1 - k]
	return out


## Folds more than two channels down to stereo (odd channels left, even right, each side
## scaled by how many went into it) and reports the frame count.
static func _samples(raw: PackedFloat32Array, channels: int, rate: int) -> Dictionary:
	if channels <= 0 or rate <= 0:
		return _fail("the file gives no channels or no rate")
	var frames := raw.size() / channels
	if channels <= 2:
		raw.resize(frames * channels)
		return {"samples": raw, "channels": channels, "rate": rate, "frames": frames, "error": ""}
	var out := PackedFloat32Array()
	out.resize(frames * 2)
	var left := ceili(channels / 2.0)
	var right := channels / 2
	for f in frames:
		var l := 0.0
		var r := 0.0
		for c in channels:
			if c % 2 == 0:
				l += raw[f * channels + c]
			else:
				r += raw[f * channels + c]
		out[f * 2] = l / left
		out[f * 2 + 1] = r / right
	return {"samples": out, "channels": 2, "rate": rate, "frames": frames, "error": ""}


## A compressed stream, played through to the end into samples at the mix rate.
static func _decode(stream: AudioStream, path: String) -> Dictionary:
	if stream == null:
		return _fail("%s could not be decoded" % path.get_file())
	var rate := int(AudioServer.get_mix_rate())
	var playback := stream.instantiate_playback()
	playback.start(0.0)
	var want := int(ceil(stream.get_length() * rate))
	var got := PackedVector2Array()
	while playback.is_playing() and got.size() < want + rate:
		got.append_array(playback.mix_audio(1.0, 4096))
	if want > 0 and got.size() > want:
		got.resize(want)
	return _samples(got.to_byte_array().to_float32_array(), 2, rate)


static func _fail(why: String) -> Dictionary:
	return {"samples": PackedFloat32Array(), "channels": 0, "rate": 0, "frames": 0, "error": why}
