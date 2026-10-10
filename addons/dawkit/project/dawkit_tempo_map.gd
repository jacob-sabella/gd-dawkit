class_name DawKitTempoMap
extends RefCounted

## Where every beat falls in seconds, for a song whose tempo changes.
##
## A list of points, each a beat, a tempo there, and how the tempo goes from there to the next
## point (`HOLD`, or a ramp to the next point's tempo). Before the first point and after the last,
## the tempo is held. A map of one point is a constant tempo.
##
## Two kinds of ramp, because DAWs disagree. `RAMP_BEATS` is a straight line in tempo against
## beats, as a curve drawn on a beat timeline is (DAWproject's `linear`): the tempo at beat b is
## T0 + k*b with k = (T1 - T0) / B, the seconds to reach b are (60 / k) * ln(T(b) / T0), and the
## inverse is b = T0 * (exp(k * s / 60) - 1) / k. `RAMP_SECONDS` is a straight line against time,
## as Reaper's gradual tempo change is: over D = 120 B / (T0 + T1) seconds the tempo is T0 + a*t
## with a = (T1 - T0) / D, the beats by t are (T0 t + a t^2 / 2) / 60, and the inverse is
## t = (sqrt(T0^2 + 120 a b) - T0) / a. Both are exact, not stepped.

const MIN_BPM := 1.0
const HOLD := 0
const RAMP_BEATS := 1
const RAMP_SECONDS := 2

## [beat, bpm, shape] per point, shape one of HOLD, RAMP_BEATS, RAMP_SECONDS, in order of beat, the first at beat 0.
var points: Array = []
## The seconds at each point, kept in step with `points` by `_index`.
var _starts := PackedFloat64Array()


func _init(bpm := 120.0, changes: Array = []) -> void:
	points = [[0.0, maxf(bpm, MIN_BPM), HOLD]]
	for c in changes:
		if c is Array and c.size() >= 2:
			set_point(float(c[0]), float(c[1]), shape_of(c[2]) if c.size() > 2 else HOLD)


## A point's shape from what a file or an older map says: true is a ramp in beats.
static func shape_of(v) -> int:
	if typeof(v) == TYPE_BOOL:
		return RAMP_BEATS if v else HOLD
	return clampi(int(v), HOLD, RAMP_SECONDS)


## A point at `beat`, replacing any already there. A point at beat 0 changes the first tempo.
func set_point(beat: float, bpm: float, shape: Variant = HOLD) -> void:
	beat = maxf(beat, 0.0)
	bpm = maxf(bpm, MIN_BPM)
	var kind := shape_of(shape)
	for p in points:
		if is_equal_approx(p[0], beat):
			p[1] = bpm
			p[2] = kind
			_index()
			return
	points.append([beat, bpm, kind])
	points.sort_custom(func(a, b): return a[0] < b[0])
	_index()


func is_constant() -> bool:
	return points.size() == 1


## The tempo at `beat`.
func bpm_at(beat: float) -> float:
	var i := _segment_of_beat(beat)
	return _bpm_in(i, beat - points[i][0])


## Seconds from the start of the song to `beat`.
func seconds_at(beat: float) -> float:
	if _starts.size() != points.size():
		_index()
	if beat <= 0.0:
		return beat * 60.0 / points[0][1]
	var i := _segment_of_beat(beat)
	return _starts[i] + _seconds_in(i, beat - points[i][0])


## The beat at `seconds` from the start of the song.
func beat_at(seconds: float) -> float:
	if _starts.size() != points.size():
		_index()
	if seconds <= 0.0:
		return seconds * points[0][1] / 60.0
	var i := points.size() - 1
	while i > 0 and _starts[i] > seconds:
		i -= 1
	return points[i][0] + _beats_in(i, seconds - _starts[i])


## Beats from `beat` that `seconds` later reaches.
func beats_after(beat: float, seconds: float) -> float:
	return beat_at(seconds_at(beat) + seconds) - beat


func to_array() -> Array:
	return points.map(func(p): return [p[0], p[1], p[2]])


static func from_array(a: Array) -> DawKitTempoMap:
	var m := DawKitTempoMap.new(120.0)
	if a.is_empty():
		return m
	m.points = []
	for p in a:
		if p is Array and p.size() >= 2:
			m.points.append([maxf(float(p[0]), 0.0), maxf(float(p[1]), MIN_BPM), shape_of(p[2]) if p.size() > 2 else HOLD])
	if m.points.is_empty():
		m.points = [[0.0, 120.0, HOLD]]
	m.points.sort_custom(func(x, y): return x[0] < y[0])
	m.points[0][0] = 0.0
	m._index()
	return m


func _segment_of_beat(beat: float) -> int:
	var i := points.size() - 1
	while i > 0 and points[i][0] > beat:
		i -= 1
	return i


## The shape segment `i` really has: a ramp needs a next point, and one to a different tempo.
func _shape(i: int) -> int:
	if i + 1 >= points.size() or int(points[i][2]) == HOLD \
			or is_equal_approx(points[i + 1][1], points[i][1]) or points[i + 1][0] <= points[i][0]:
		return HOLD
	return int(points[i][2])


## How the tempo moves along a ramp in beats, per beat.
func _slope(i: int) -> float:
	return (points[i + 1][1] - points[i][1]) / (points[i + 1][0] - points[i][0])


## How the tempo moves along a ramp in seconds, per second.
func _rate(i: int) -> float:
	var t0: float = points[i][1]
	var t1: float = points[i + 1][1]
	var length: float = 120.0 * (points[i + 1][0] - points[i][0]) / (t0 + t1)
	return (t1 - t0) / length


func _bpm_in(i: int, beats: float) -> float:
	match _shape(i):
		RAMP_BEATS:
			return points[i][1] + _slope(i) * beats
		RAMP_SECONDS:
			return points[i][1] + _rate(i) * _seconds_in(i, beats)
	return points[i][1]


func _seconds_in(i: int, beats: float) -> float:
	var t0: float = points[i][1]
	match _shape(i):
		RAMP_BEATS:
			var k := _slope(i)
			return 60.0 / k * log((t0 + k * beats) / t0)
		RAMP_SECONDS:
			var a := _rate(i)
			return (sqrt(maxf(t0 * t0 + 120.0 * a * beats, 0.0)) - t0) / a
	return beats * 60.0 / t0


func _beats_in(i: int, seconds: float) -> float:
	var t0: float = points[i][1]
	match _shape(i):
		RAMP_BEATS:
			var k := _slope(i)
			return t0 * (exp(k * seconds / 60.0) - 1.0) / k
		RAMP_SECONDS:
			var a := _rate(i)
			return (t0 * seconds + a * seconds * seconds * 0.5) / 60.0
	return seconds * t0 / 60.0


func _index() -> void:
	_starts.resize(points.size())
	if points.is_empty():
		return
	points[0][0] = 0.0
	_starts[0] = 0.0
	for i in range(1, points.size()):
		_starts[i] = _starts[i - 1] + _seconds_in(i - 1, points[i][0] - points[i - 1][0])
