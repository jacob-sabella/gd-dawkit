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
	return c


func to_dict() -> Dictionary:
	return {"start": start, "length": length, "name": name, "muted": muted, "locked": locked, "lane": lane, "reversed": reversed,
			"colour": colour.to_html(true), "fade_in": fade_in, "fade_out": fade_out,
			"fade_shape": fade_shape, "fade_out_shape": fade_out_shape, "gain_db": gain_db, "source": source, "source_offset": source_offset,
			"loop_start": loop_start, "loop_end": loop_end,
			"notes": Array(notes)}


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
	return c
