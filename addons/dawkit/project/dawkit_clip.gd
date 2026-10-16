class_name DawKitClip
extends RefCounted

## A region on a track's timeline: a window onto an audio file, or a set of MIDI notes.
##
## Times are seconds. Seconds and not beats, because a recorded take is where it was played
## whatever the tempo does afterwards; a clip that should follow the tempo is the host's choice
## to make by moving it.

var start := 0.0
var length := 0.0
var name := ""
var muted := false
## Pinned against edits: a host refuses to move, trim or reshape it until it is unlocked.
var locked := false
## Which take lane of its track it is on: 0 is the first. A track with a comp plays the lane each
## stretch of the comp names (see DawKitTrack.comp); without one every lane sounds.
var lane := 0
## Played backwards. `source_offset` is then seconds into the reversed sound, so a clip's offset
## and length mean the same whichever way it plays.
var reversed := false
var colour := Color(0, 0, 0, 0)
## Fade lengths at each end, in seconds: the fade in in `fade_shape`, the fade out in
## `fade_out_shape`.
var fade_in := 0.0
var fade_out := 0.0
## How the fade in runs, one of the FADE_ shapes below (see fade_gain).
var fade_shape := FADE_LINEAR
## How the fade out runs: the same shapes, mirrored, so a shape sounds the same from either end.
var fade_out_shape := FADE_LINEAR
## Straight in amplitude.
const FADE_LINEAR := 0
## A quarter sine: two crossfading clips of unrelated sound keep their loudness through the middle.
const FADE_EQUAL_POWER := 1
## Slow to start and quick to finish (a square): a fade in that stays low, a fade out that
## lets go late.
const FADE_SLOW := 2
## Quick to start and slow to finish (an upturned square).
const FADE_FAST := 3
## Slow at both ends and quick through the middle (half a cosine).
const FADE_S_CURVE := 4
const FADE_SHAPES := 5
var gain_db := 0.0
## An audio clip's file, as a path relative to the project's media folder. Empty for MIDI.
var source := ""
## Seconds into the file at the clip's left edge: not zero once a clip has been split or trimmed.
var source_offset := 0.0
## A looped clip plays the file between these two points over and over, for as long as the clip
## lasts; seconds into the file. Not looped when loop_end is not after loop_start.
var loop_start := 0.0
var loop_end := 0.0
## A MIDI clip's notes, flat: [on, off, pitch, velocity, channel] repeating, seconds from the
## clip's left edge, so moving the clip moves its notes.
var notes := PackedFloat64Array()

const NOTE_WIDTH := 5

## A MIDI clip's controller events, flat: [time, kind, value, channel] repeating, in time order,
## seconds from the clip's left edge. `kind` is a controller number 0-127 (value 0-127), PITCH_BEND
## (value -8192 to 8191, centre 0) or AFTERTOUCH (channel pressure, value 0-127).
var controls := PackedFloat64Array()

const CONTROL_WIDTH := 4
const PITCH_BEND := 128
const AFTERTOUCH := 129
const BEND_MIN := -8192.0
const BEND_MAX := 8191.0


func end() -> float:
	return start + length


func is_looped() -> bool:
	return loop_end > loop_start


## Seconds into the file that sound `t` seconds after the clip's start.
func file_time(t: float) -> float:
	var at := source_offset + t
	if is_looped() and at >= loop_end:
		at = loop_start + fposmod(at - loop_start, loop_end - loop_start)
	return at


func is_midi() -> bool:
	return source.is_empty() and not notes.is_empty()


func note_count() -> int:
	return notes.size() / NOTE_WIDTH


## The level, 0-1, `t` of the way through a fade in of `shape` (a fade out is the same curve
## run backwards: `t` is how much of it is still to go).
static func fade_gain(t: float, shape: int) -> float:
	t = clampf(t, 0.0, 1.0)
	match shape:
		FADE_EQUAL_POWER:
			return sin(t * PI * 0.5)
		FADE_SLOW:
			return t * t
		FADE_FAST:
			return 1.0 - (1.0 - t) * (1.0 - t)
		FADE_S_CURVE:
			return 0.5 - 0.5 * cos(t * PI)
	return t


## A shape from a file or a peer: one of the FADE_ shapes, straight for anything else.
static func clean_shape(v: Variant) -> int:
	if typeof(v) not in [TYPE_INT, TYPE_FLOAT] or not is_finite(float(v)):
		return FADE_LINEAR
	var shape := int(v)
	return shape if shape >= 0 and shape < FADE_SHAPES else FADE_LINEAR


## The part of this clip between `from` and `to` (song seconds, inside the clip) as a clip of its
## own, sounding the same: its file offset moved on by what was cut off the front, its notes
## trimmed to the window and counted from the new start. A fade stays only at an end that is
## still the clip's own.
func slice(from: float, to: float) -> DawKitClip:
	var c := DawKitClip.from_dict(to_dict())
	from = clampf(from, start, end())
	to = clampf(to, from, end())
	c.start = from
	c.length = to - from
	c.source_offset = source_offset + (from - start)
	if from > start:
		c.fade_in = 0.0
	if to < end():
		c.fade_out = 0.0
	c.fade_in = minf(c.fade_in, c.length)
	c.fade_out = minf(c.fade_out, c.length)
	if not notes.is_empty():
		var shift := from - start
		var kept := PackedFloat64Array()
		for i in note_count():
			var o := i * NOTE_WIDTH
			var on := notes[o] - shift
			var off := notes[o + 1] - shift
			if off <= 0.0 or on >= c.length:
				continue
			kept.append_array(PackedFloat64Array([maxf(on, 0.0), minf(off, c.length), notes[o + 2], notes[o + 3], notes[o + 4]]))
		c.notes = kept
	if not controls.is_empty():
		var events := PackedFloat64Array()
		var moved := from - start
		for i in control_count():
			var o := i * CONTROL_WIDTH
			var at := controls[o] - moved
			if at < 0.0 or at >= c.length:
				continue
			events.append_array(PackedFloat64Array([at, controls[o + 1], controls[o + 2], controls[o + 3]]))
		c.controls = events
	return c


func to_dict() -> Dictionary:
	return {"start": start, "length": length, "name": name, "muted": muted, "locked": locked, "lane": lane, "reversed": reversed,
			"colour": colour.to_html(true), "fade_in": fade_in, "fade_out": fade_out,
			"fade_shape": fade_shape, "fade_out_shape": fade_out_shape, "gain_db": gain_db, "source": source, "source_offset": source_offset,
			"loop_start": loop_start, "loop_end": loop_end,
			"notes": Array(notes), "controls": Array(controls)}


static func from_dict(d: Dictionary) -> DawKitClip:
	var c := DawKitClip.new()
	c.start = float(d.get("start", 0.0))
	c.length = float(d.get("length", 0.0))
	c.name = str(d.get("name", ""))
	c.muted = bool(d.get("muted", false))
	c.locked = bool(d.get("locked", false))
	c.lane = maxi(int(d.get("lane", 0)), 0)
	c.reversed = bool(d.get("reversed", false))
	c.colour = Color.from_string(str(d.get("colour", "00000000")), Color(0, 0, 0, 0))
	c.fade_in = float(d.get("fade_in", 0.0))
	c.fade_out = float(d.get("fade_out", 0.0))
	c.fade_shape = clean_shape(d.get("fade_shape", FADE_LINEAR))
	# Written before each end had its own, the one shape was both.
	c.fade_out_shape = clean_shape(d.get("fade_out_shape", c.fade_shape))
	c.gain_db = float(d.get("gain_db", 0.0))
	c.source = str(d.get("source", ""))
	c.source_offset = float(d.get("source_offset", 0.0))
	c.loop_start = float(d.get("loop_start", 0.0))
	c.loop_end = float(d.get("loop_end", 0.0))
	c.notes = PackedFloat64Array(d.get("notes", []))
	c.controls = clean_controls(d.get("controls", []))
	return c


func control_count() -> int:
	return controls.size() / CONTROL_WIDTH


## The events of `kind` (a controller number, PITCH_BEND or AFTERTOUCH) on `channel`, as
## [time, value] pairs in time order.
func control_lane(kind: int, channel := 0) -> Array:
	var out: Array = []
	for i in control_count():
		var o := i * CONTROL_WIDTH
		if int(controls[o + 1]) == kind and int(controls[o + 3]) == channel:
			out.append([controls[o], controls[o + 2]])
	return out


## The value of the lane `kind` on `channel` at `t` seconds into the clip: the last event at or
## before it, or `default` before the first.
func control_at(kind: int, t: float, channel := 0, default := 0.0) -> float:
	var v := default
	for e in control_lane(kind, channel):
		if e[0] > t:
			break
		v = e[1]
	return v


## The lane `kind` on `channel` made `points` ([time, value] pairs): the lane's old events go, the
## other lanes stay. Empty points take the lane away.
func set_control_lane(kind: int, points: Array, channel := 0) -> void:
	var out := PackedFloat64Array()
	for i in control_count():
		var o := i * CONTROL_WIDTH
		if not (int(controls[o + 1]) == kind and int(controls[o + 3]) == channel):
			out.append_array(controls.slice(o, o + CONTROL_WIDTH))
	var arr := Array(out)
	for p in points:
		arr.append_array([float(p[0]), float(kind), float(p[1]), float(channel)])
	controls = clean_controls(arr)


## Controller events from loose data (a file, a peer), made safe: finite, a known kind, the value
## in its range, a channel 0-15, in time order (events at one time keep their order).
static func clean_controls(v: Variant) -> PackedFloat64Array:
	var rows: Array = []
	if not (v is Array or v is PackedFloat64Array or v is PackedFloat32Array):
		return PackedFloat64Array()
	for i in range(0, v.size() - CONTROL_WIDTH + 1, CONTROL_WIDTH):
		var t := float(v[i])
		var kind := int(v[i + 1])
		var value := float(v[i + 2])
		if not is_finite(t) or not is_finite(value) or t < 0.0 or kind < 0 or kind > AFTERTOUCH:
			continue
		value = clampf(value, BEND_MIN, BEND_MAX) if kind == PITCH_BEND else clampf(value, 0.0, 127.0)
		rows.append([t, float(kind), value, float(clampi(int(v[i + 3]), 0, 15)), rows.size()])
	rows.sort_custom(func(a, b): return a[0] < b[0] or (a[0] == b[0] and a[4] < b[4]))
	var out := PackedFloat64Array()
	for r in rows:
		out.append_array(PackedFloat64Array([r[0], r[1], r[2], r[3]]))
	return out
