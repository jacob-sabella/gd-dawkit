class_name DawKitMetronome
extends RefCounted

## The click: one bar of it as a sound that loops, so a player started at the right place in the
## bar keeps time on its own and only has to be checked now and then.
##
## Each click is a short tone that starts at its full level and dies away, so its
## first sample is where the beat is: what a player times against, and what a measurement finds.
## The bar's first beat is higher and louder.

const ACCENT_HZ := 1600.0
const BEAT_HZ := 1000.0
const ACCENT_LEVEL := 0.6
const BEAT_LEVEL := 0.45
## How long a click rings, and how fast it dies within that.
const CLICK_SECONDS := 0.03
const DECAY_PER_SECOND := 160.0


static func bar_seconds(tempo: float, beats: int) -> float:
	return float(maxi(beats, 1)) * 60.0 / maxf(tempo, 1.0)


## Where in the bar each click starts, in seconds.
static func click_times(tempo: float, beats: int) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	for b in maxi(beats, 1):
		out.append(b * 60.0 / maxf(tempo, 1.0))
	return out


## One bar of clicks at `rate`, 16-bit stereo, looping from its start to its end.
static func bar(tempo: float, beats: int, rate := 48000) -> AudioStreamWAV:
	var frames := int(round(bar_seconds(tempo, beats) * rate))
	var data := PackedByteArray()
	data.resize(frames * 4)
	var ring := int(CLICK_SECONDS * rate)
	var times := click_times(tempo, beats)
	for b in times.size():
		var start := int(round(times[b] * rate))
		var hz := ACCENT_HZ if b == 0 else BEAT_HZ
		var level := ACCENT_LEVEL if b == 0 else BEAT_LEVEL
		for k in mini(ring, frames - start):
			var t := float(k) / rate
			var v := int(level * exp(-DECAY_PER_SECOND * t) * sin(TAU * hz * t + PI * 0.5) * 32767.0)
			data.encode_s16((start + k) * 4, v)
			data.encode_s16((start + k) * 4 + 2, v)
	var wav := AudioStreamWAV.new()
	wav.format = AudioStreamWAV.FORMAT_16_BITS
	wav.stereo = true
	wav.mix_rate = rate
	wav.data = data
	wav.loop_mode = AudioStreamWAV.LOOP_FORWARD
	wav.loop_begin = 0
	wav.loop_end = frames
	return wav
