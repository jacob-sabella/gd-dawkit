class_name DawKitTine
extends RefCounted

## The built-in instrument: a small electric piano, the classic two-operator tine. A sine carrier
## phase-modulated by a sine at the same frequency, its index falling from bright to mellow over
## a quarter second, plus a short high partial for the strike. Soft at low velocity and barking a
## little when hit hard. Sixteen voices; the oldest is taken when they run out. A damper takes a
## let-go note down 60dB in about 150ms; the sustain pedal holds it.
##
## Played two ways: live, a note at a time (`note_on`, `note_off`, `render`), and a whole clip at
## once (`render_notes`), where each note starts on its own sample.

const VOICES := 16
const TABLE := 4096
## Rendered past a clip's end, for the last notes to ring out.
const TAIL_SECONDS := 1.5
const SILENT := 0.0005

var rate := 48000.0

var _sine := PackedFloat32Array()
var _sustain := false
var _held := PackedByteArray()
var _pitch := PackedInt32Array()
var _phase := PackedFloat32Array()
var _tine := PackedFloat32Array()
var _inc := PackedFloat32Array()
var _amp := PackedFloat32Array()
var _index := PackedFloat32Array()
var _decay := PackedFloat32Array()
var _release := PackedFloat32Array()
var _attack := PackedFloat32Array()
var _pan := PackedFloat32Array()
var _strike := PackedFloat32Array()
var _born := PackedInt64Array()
var _clock := 0


func _init(sample_rate := 48000.0) -> void:
	rate = sample_rate
	_sine.resize(TABLE)
	for i in TABLE:
		_sine[i] = sin(TAU * i / TABLE)
	_pitch.resize(VOICES)
	_phase.resize(VOICES)
	_tine.resize(VOICES)
	_inc.resize(VOICES)
	_amp.resize(VOICES)
	_index.resize(VOICES)
	_decay.resize(VOICES)
	_release.resize(VOICES)
	_attack.resize(VOICES)
	_pan.resize(VOICES)
	_strike.resize(VOICES)
	_born.resize(VOICES)
	_held.resize(VOICES)
	_pitch.fill(-1)
	_amp.fill(0.0)


## A clip's notes -- flat [on, off, pitch, velocity, channel] repeating, seconds from the clip's
## start -- as `seconds` of stereo sound plus the tail, each note on its own sample.
static func render_notes(notes: PackedFloat64Array, seconds: float, sample_rate := 48000.0) -> PackedVector2Array:
	var synth := DawKitTine.new(sample_rate)
	# Every note's on and off as [frame, on?, pitch, velocity], in time order (offs first at a tie,
	# so a note repeated back to back is struck again rather than cut).
	var events: Array = []
	for i in range(0, notes.size() - 4, 5):
		var on := notes[i]
		if on >= seconds:
			continue
		var off := minf(notes[i + 1], seconds)
		events.append([int(round(maxf(on, 0.0) * sample_rate)), 1, int(notes[i + 2]), int(notes[i + 3])])
		events.append([int(round(off * sample_rate)), 0, int(notes[i + 2]), 0])
	events.sort_custom(func(a, b): return a[0] < b[0] or (a[0] == b[0] and a[1] < b[1]))
	var total := int(ceil((seconds + TAIL_SECONDS) * sample_rate))
	var out := PackedVector2Array()
	var at := 0
	for e in events:
		var frame := mini(int(e[0]), total)
		if frame > at:
			out.append_array(synth.render(frame - at))
			at = frame
		if e[1] == 1:
			synth.note_on(e[2], e[3])
		else:
			synth.note_off(e[2])
	if total > at:
		out.append_array(synth.render(total - at))
	return out


func note_on(pitch: int, velocity: int) -> void:
	var v := -1
	var oldest := 0
	for i in VOICES:
		if _amp[i] < SILENT:
			v = i
			break
		if _born[i] < _born[oldest]:
			oldest = i
	if v < 0:
		v = oldest
	var hz := 440.0 * pow(2.0, (pitch - 69) / 12.0)
	var vel := clampf(velocity / 127.0, 0.0, 1.0)
	_pitch[v] = pitch
	_inc[v] = hz * TABLE / rate
	_phase[v] = 0.0
	_tine[v] = 0.0
	# Louder and brighter together, on a curve: a light touch should be properly quiet.
	_amp[v] = 0.05 + 0.22 * vel * vel
	_index[v] = 0.6 + 2.2 * vel
	_attack[v] = 0.0
	# Low notes ring on, high ones die quickly: seconds to fall by 60dB, from 6s down to 1.5s.
	var ring := clampf(6.0 * pow(0.5, (pitch - 40) / 24.0), 1.5, 6.0)
	_decay[v] = pow(0.001, 1.0 / (ring * rate))
	_release[v] = 1.0
	_held[v] = 1
	_pan[v] = clampf((pitch - 64) / 90.0, -0.35, 0.35)
	# The strike partial sits fourteen times up; above the top of hearing it would only alias.
	_strike[v] = _amp[v] * 0.35 if hz * 14.0 < 16000.0 else 0.0
	_clock += 1
	_born[v] = _clock


func note_off(pitch: int) -> void:
	for v in VOICES:
		if _pitch[v] == pitch and _held[v] == 1:
			_held[v] = 0
			if not _sustain:
				_damp(v)


func sustain(down: bool) -> void:
	_sustain = down
	if not down:
		for v in VOICES:
			if _pitch[v] >= 0 and _held[v] == 0:
				_damp(v)


func all_off() -> void:
	for v in VOICES:
		_amp[v] = 0.0
		_pitch[v] = -1
		_held[v] = 0


func sounding() -> int:
	var n := 0
	for v in VOICES:
		if _amp[v] >= SILENT:
			n += 1
	return n


## `count` frames of every sounding voice, mixed and gently saturated, so a fistful of keys gets
## fuller rather than clipping.
func render(count: int) -> PackedVector2Array:
	var out := PackedVector2Array()
	out.resize(count)
	var index_fall := pow(0.12, 1.0 / (0.25 * rate))
	var attack_step := 1.0 / (0.002 * rate)
	for v in VOICES:
		var amp := _amp[v]
		if amp < SILENT:
			continue
		var phase := _phase[v]
		var tine := _tine[v]
		var inc := _inc[v]
		var index := _index[v]
		var decay := _decay[v] * _release[v]
		var attack := _attack[v]
		var left := 0.5 - _pan[v]
		var right := 0.5 + _pan[v]
		var tine_amp := _strike[v]
		for i in count:
			var m := _sine[int(phase) & (TABLE - 1)] * index * (TABLE * 0.159)
			var strike := _sine[int(tine) & (TABLE - 1)] * tine_amp
			var s := (_sine[int(phase + m) & (TABLE - 1)] * amp + strike) * attack
			out[i] += Vector2(s * left, s * right) * 2.0
			phase += inc
			if phase >= TABLE:
				phase -= TABLE
			tine += inc * 14.0
			if tine >= TABLE:
				tine -= TABLE * floorf(tine / TABLE)
			amp *= decay
			tine_amp *= 0.9993
			index = index * index_fall + 0.12 * (1.0 - index_fall)
			attack = minf(1.0, attack + attack_step)
		_amp[v] = amp
		_strike[v] = tine_amp
		_phase[v] = phase
		_tine[v] = tine
		_index[v] = index
		_attack[v] = attack
		if amp < SILENT:
			_pitch[v] = -1
	for i in count:
		var f := out[i]
		out[i] = Vector2(f.x / (1.0 + absf(f.x)), f.y / (1.0 + absf(f.y)))
	return out


## Damper down: 60dB in about 150ms, quick enough to stop, slow enough not to click.
func _damp(v: int) -> void:
	if _release[v] == 1.0:
		_release[v] = pow(0.001, 1.0 / (0.15 * rate))
