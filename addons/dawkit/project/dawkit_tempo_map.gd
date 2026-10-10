class_name DawKitTempoMap
extends RefCounted

## Where every beat falls in seconds, for a song whose tempo changes.
##
## A list of points, each a beat, a tempo there, and how the tempo goes from there to the next
## point: held until the next point, or ramped there in a straight line in tempo against beats,
## as DAWproject's `hold` and `linear` say. Before the first point and after the last, the tempo
## is held. A map of one point is a constant tempo.
##
## Ramps are exact, not stepped: over a ramp from T0 to T1 across B beats the tempo at beat b is
## T0 + k*b with k = (T1 - T0) / B, so the seconds to reach b are (60 / k) * ln(T(b) / T0), and
## the inverse is b = T0 * (exp(k * s / 60) - 1) / k.

const MIN_BPM := 1.0

## [beat, bpm, ramps] per point, in order of beat, the first at beat 0.
var points: Array = []
## The seconds at each point, kept in step with `points` by `_index`.
var _starts := PackedFloat64Array()


func _init(bpm := 120.0, changes: Array = []) -> void:
	points = [[0.0, maxf(bpm, MIN_BPM), false]]
	for c in changes:
		if c is Array and c.size() >= 2:
			set_point(float(c[0]), float(c[1]), bool(c[2]) if c.size() > 2 else false)


## A point at `beat`, replacing any already there. A point at beat 0 changes the first tempo.
func set_point(beat: float, bpm: float, ramps := false) -> void:
	beat = maxf(beat, 0.0)
	bpm = maxf(bpm, MIN_BPM)
	for p in points:
		if is_equal_approx(p[0], beat):
			p[1] = bpm
			p[2] = ramps
			_index()
			return
	points.append([beat, bpm, ramps])
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
			m.points.append([maxf(float(p[0]), 0.0), maxf(float(p[1]), MIN_BPM), bool(p[2]) if p.size() > 2 else false])
	if m.points.is_empty():
		m.points = [[0.0, 120.0, false]]
	m.points.sort_custom(func(x, y): return x[0] < y[0])
	m.points[0][0] = 0.0
	m._index()
	return m


func _segment_of_beat(beat: float) -> int:
	var i := points.size() - 1
	while i > 0 and points[i][0] > beat:
		i -= 1
	return i


## How the tempo moves along segment `i` per beat: 0 when held, and after the last point.
func _slope(i: int) -> float:
	if not points[i][2] or i + 1 >= points.size():
		return 0.0
	var span: float = points[i + 1][0] - points[i][0]
	return (points[i + 1][1] - points[i][1]) / span if span > 0.0 else 0.0


func _bpm_in(i: int, beats: float) -> float:
	return points[i][1] + _slope(i) * beats


func _seconds_in(i: int, beats: float) -> float:
	var k := _slope(i)
	var t0: float = points[i][1]
	if absf(k) < 1e-12:
		return beats * 60.0 / t0
	return 60.0 / k * log((t0 + k * beats) / t0)


func _beats_in(i: int, seconds: float) -> float:
	var k := _slope(i)
	var t0: float = points[i][1]
	if absf(k) < 1e-12:
		return seconds * t0 / 60.0
	return t0 * (exp(k * seconds / 60.0) - 1.0) / k


func _index() -> void:
	_starts.resize(points.size())
	if points.is_empty():
		return
	points[0][0] = 0.0
	_starts[0] = 0.0
	for i in range(1, points.size()):
		_starts[i] = _starts[i - 1] + _seconds_in(i - 1, points[i][0] - points[i - 1][0])
