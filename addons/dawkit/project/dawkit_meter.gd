class_name DawKitMeter
extends RefCounted

## Where every bar begins, for a song whose time signature changes.
##
## A list of points, each a beat (a quarter note from the song's start, as the tempo map counts)
## and the signature from there, numerator and denominator. A bar of n/d is n counts of a 4/d
## beat: 4 beats in 4/4, 3 in 6/8, 3.5 in 7/8. A change starts a new bar, as one does in every
## DAW: the bar before it is cut short if the change falls inside it, and the change's bar is
## numbered on from that one. Before the first point, and after the last, the signature holds.

## [beat, numerator, denominator] per point, the first at beat 0, in order of beat.
var points: Array = []
## The bar each point's bar begins, 0 for the first, kept in step with `points` by `_index`.
var _bars := PackedFloat64Array()


func _init(numerator := 4, denominator := 4, changes: Array = []) -> void:
	points = [[0.0, _num(numerator), _den(denominator)]]
	for c in changes:
		if c is Array and c.size() >= 3:
			set_point(float(c[0]), int(c[1]), int(c[2]))
	_index()


static func _num(n: int) -> int:
	return clampi(n, 1, 64)


## A denominator is a power of two from 1 to 64, the nearest one when it is not.
static func _den(d: int) -> int:
	var best := 1
	for p in [1, 2, 4, 8, 16, 32, 64]:
		if absi(p - d) < absi(best - d):
			best = p
	return best


## A point at `beat`, replacing any already there. A point at beat 0 is the song's own signature.
func set_point(beat: float, numerator: int, denominator: int) -> void:
	beat = maxf(beat, 0.0)
	for p in points:
		if is_equal_approx(float(p[0]), beat):
			p[1] = _num(numerator)
			p[2] = _den(denominator)
			_index()
			return
	points.append([beat, _num(numerator), _den(denominator)])
	points.sort_custom(func(a, b): return a[0] < b[0])
	_index()


func is_constant() -> bool:
	return points.size() == 1


## The signature at `beat`, numerator and denominator.
func signature_at(beat: float) -> Vector2i:
	var i := _segment_of_beat(beat)
	return Vector2i(points[i][1], points[i][2])


## Beats (quarter notes) in a bar of segment `i`.
func _bar_beats(i: int) -> float:
	return float(points[i][1]) * 4.0 / float(points[i][2])


## Beats in one count of the signature at `beat`: 1 in x/4, 0.5 in x/8.
func count_beats(beat: float) -> float:
	return 4.0 / float(points[_segment_of_beat(beat)][2])


## Bars from the song's start to `beat`, 0 at the start, with the fraction of the bar it is in.
## Before the start, bars of the first signature, below 0.
func bar_at(beat: float) -> float:
	if _bars.size() != points.size():
		_index()
	var i := _segment_of_beat(beat)
	return _bars[i] + (beat - float(points[i][0])) / _bar_beats(i)


## The beat bar `bar` (0 the first, fractions within it) is at: `bar_at`'s inverse, where a bar cut
## short by a change has its length up to the change.
func beat_of_bar(bar: float) -> float:
	if _bars.size() != points.size():
		_index()
	var i := points.size() - 1
	while i > 0 and _bars[i] > bar:
		i -= 1
	var beat := float(points[i][0]) + (bar - _bars[i]) * _bar_beats(i)
	if i + 1 < points.size():
		beat = minf(beat, float(points[i + 1][0]))
	return beat


## Where `beat` is as a musician counts it: [bar, count, fraction of the count], the bar and count
## from 1.
func position(beat: float) -> Array:
	var bar := floori(bar_at(beat) + 0.000001)
	var into := maxf(beat - beat_of_bar(float(bar)), 0.0)
	var unit := count_beats(beat)
	var count := floori(into / unit + 0.000001)
	return [bar + 1, count + 1, maxf(into / unit - count, 0.0)]


## Every count from `from_beat` up to `to_beat`: [beat, whether it begins a bar].
func counts(from_beat: float, to_beat: float) -> Array:
	var out: Array = []
	var bar := floori(bar_at(from_beat) + 0.000001)
	while true:
		var start := beat_of_bar(float(bar))
		var end := beat_of_bar(float(bar + 1))
		if start >= to_beat:
			break
		var unit := count_beats(start)
		var b := start
		var first := true
		while b < end - 0.000001 and b < to_beat:
			if b >= from_beat - 0.000001:
				out.append([b, first])
			first = false
			b += unit
		bar += 1
	return out


func to_array() -> Array:
	return points.map(func(p): return [float(p[0]), int(p[1]), int(p[2])])


## A meter from points as a file or the wire has them; `numerator`/`denominator` when there are none.
static func from_array(a: Array, numerator := 4, denominator := 4) -> DawKitMeter:
	var m := DawKitMeter.new(numerator, denominator)
	var given: Array = []
	for p in a:
		if p is Array and p.size() >= 3:
			given.append([maxf(float(p[0]), 0.0), _num(int(p[1])), _den(int(p[2]))])
	if given.is_empty():
		return m
	given.sort_custom(func(x, y): return x[0] < y[0])
	given[0][0] = 0.0
	m.points = given
	m._index()
	return m


func _segment_of_beat(beat: float) -> int:
	var i := points.size() - 1
	while i > 0 and float(points[i][0]) > beat + 0.000001:
		i -= 1
	return i


func _index() -> void:
	_bars.resize(points.size())
	if points.is_empty():
		return
	points[0][0] = 0.0
	_bars[0] = 0.0
	for i in range(1, points.size()):
		# A change starts a bar: one cut short before it still counts as a bar.
		_bars[i] = _bars[i - 1] + ceilf((float(points[i][0]) - float(points[i - 1][0])) / _bar_beats(i - 1) - 0.000001)
