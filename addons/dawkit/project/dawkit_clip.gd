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
## Played backwards. `source_offset` is then seconds into the reversed sound, so a clip's offset
## and length mean the same whichever way it plays.
var reversed := false
var colour := Color(0, 0, 0, 0)
## Fade lengths at each end, in seconds, both in `fade_shape`.
var fade_in := 0.0
var fade_out := 0.0
## How both fades run: FADE_LINEAR, straight in amplitude, or FADE_EQUAL_POWER, a quarter sine,
## so two crossfading clips of unrelated sound keep their loudness through the middle.
var fade_shape := FADE_LINEAR
const FADE_LINEAR := 0
const FADE_EQUAL_POWER := 1
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


func to_dict() -> Dictionary:
	return {"start": start, "length": length, "name": name, "muted": muted, "locked": locked, "reversed": reversed,
			"colour": colour.to_html(true), "fade_in": fade_in, "fade_out": fade_out,
			"fade_shape": fade_shape, "gain_db": gain_db, "source": source, "source_offset": source_offset,
			"loop_start": loop_start, "loop_end": loop_end,
			"notes": Array(notes)}


static func from_dict(d: Dictionary) -> DawKitClip:
	var c := DawKitClip.new()
	c.start = float(d.get("start", 0.0))
	c.length = float(d.get("length", 0.0))
	c.name = str(d.get("name", ""))
	c.muted = bool(d.get("muted", false))
	c.locked = bool(d.get("locked", false))
	c.reversed = bool(d.get("reversed", false))
	c.colour = Color.from_string(str(d.get("colour", "00000000")), Color(0, 0, 0, 0))
	c.fade_in = float(d.get("fade_in", 0.0))
	c.fade_out = float(d.get("fade_out", 0.0))
	c.fade_shape = FADE_EQUAL_POWER if int(d.get("fade_shape", FADE_LINEAR)) == FADE_EQUAL_POWER else FADE_LINEAR
	c.gain_db = float(d.get("gain_db", 0.0))
	c.source = str(d.get("source", ""))
	c.source_offset = float(d.get("source_offset", 0.0))
	c.loop_start = float(d.get("loop_start", 0.0))
	c.loop_end = float(d.get("loop_end", 0.0))
	c.notes = PackedFloat64Array(d.get("notes", []))
	return c
