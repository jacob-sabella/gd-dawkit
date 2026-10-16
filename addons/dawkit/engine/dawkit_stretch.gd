class_name DawKitStretch
extends RefCounted

## Time-stretch and pitch-shift of recorded sound, offline: a new buffer out of an old.
##
## Time-stretch is WSOLA (waveform-similarity overlap-add): the sound is cut into overlapping
## Hann-windowed grains, laid down at the output's hop and picked from the input around where
## the stretch says they belong, at whichever nearby offset continues the previous grain best.
## So the pitch stays and the length changes. Pitch-shift is a stretch by the pitch ratio and a
## resample back to the original length. Good on speech, tones and most music; a very sharp
## transient can double or smear a little, as in every overlap-add stretcher.
##
## The offset is found once from the channels mixed together and used for all, so a stereo image
## is not torn. Samples are interleaved floats, as `DawKitAudioFile` hands them over.

const MIN_RATIO := 0.25
const MAX_RATIO := 4.0
## Grain length, in seconds at the sound's rate: about 43 ms.
const GRAIN_SECONDS := 0.043
## How far from its place a grain may be taken, in seconds each way.
const SEEK_SECONDS := 0.008


## `ratio` is the new length over the old: 2 is twice as long and half as fast, the pitch the same.
static func stretch(samples: PackedFloat32Array, channels: int, rate: int, ratio: float) -> PackedFloat32Array:
	channels = maxi(channels, 1)
	ratio = clampf(ratio, MIN_RATIO, MAX_RATIO)
	var frames := samples.size() / channels
	var out_frames := maxi(int(round(frames * ratio)), 1)
	if frames < 64 or is_equal_approx(ratio, 1.0):
		return samples.duplicate() if is_equal_approx(ratio, 1.0) else _resample(samples, channels, out_frames)
	var win := maxi(int(GRAIN_SECONDS * rate) & ~1, 64)
	var hop := win / 2
	var seek := maxi(int(SEEK_SECONDS * rate), 4)
	if frames < win + 2 * seek:
		return _resample(samples, channels, out_frames)
	var mono := PackedFloat32Array()
	mono.resize(frames)
	for i in frames:
		var m := 0.0
		for c in channels:
			m += samples[i * channels + c]
		mono[i] = m / channels
	var hann := PackedFloat32Array()
	hann.resize(win)
	for i in win:
		hann[i] = 0.5 - 0.5 * cos(TAU * i / win)
	var out := PackedFloat32Array()
	out.resize((out_frames + win) * channels)
	var norm := PackedFloat32Array()
	norm.resize(out_frames + win)
	var step_in := float(hop) / ratio
	var prev := 0
	var k := 0
	var out_at := 0
	while out_at < out_frames:
		var nominal := int(round(k * step_in))
		var at := clampi(nominal, 0, frames - win)
		if k > 0:
			# What would have followed the last grain, had the input just carried on.
			var want := prev + hop
			var best := -1.0e30
			var lo := maxi(nominal - seek, 0)
			var hi := mini(nominal + seek, frames - win)
			at = clampi(nominal, lo, hi)
			if want + win <= frames:
				var d := lo
				while d <= hi:
					var corr := 0.0
					var j := 0
					while j < win:
						corr += mono[d + j] * mono[want + j]
						j += 8
					if corr > best:
						best = corr
						at = d
					d += 2
		for j in win:
			var w := hann[j]
			for c in channels:
				out[(out_at + j) * channels + c] += samples[(at + j) * channels + c] * w
			norm[out_at + j] += w
		prev = at
		k += 1
		out_at += hop
	var result := PackedFloat32Array()
	result.resize(out_frames * channels)
	for i in out_frames:
		var n := maxf(norm[i], 0.001)
		for c in channels:
			result[i * channels + c] = out[i * channels + c] / n
	return result


## The same sound `semitones` higher (or lower), as long as it was.
static func pitch_shift(samples: PackedFloat32Array, channels: int, rate: int, semitones: float) -> PackedFloat32Array:
	channels = maxi(channels, 1)
	var frames := samples.size() / channels
	if is_zero_approx(semitones) or frames < 2:
		return samples.duplicate()
	var factor := pow(2.0, clampf(semitones, -24.0, 24.0) / 12.0)
	var longer := stretch(samples, channels, rate, factor)
	return _resample(longer, channels, frames)


## `samples` to exactly `frames` frames by linear interpolation: faster and higher when shorter.
static func _resample(samples: PackedFloat32Array, channels: int, frames: int) -> PackedFloat32Array:
	var have := samples.size() / channels
	var out := PackedFloat32Array()
	out.resize(frames * channels)
	if have < 1:
		return out
	var scale := float(have - 1) / maxf(frames - 1, 1)
	for i in frames:
		var pos := i * scale
		var a := int(pos)
		var b := mini(a + 1, have - 1)
		var f := pos - a
		for c in channels:
			out[i * channels + c] = lerpf(samples[a * channels + c], samples[b * channels + c], f)
	return out
