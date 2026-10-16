class_name DawKitTrack
extends RefCounted

## A track: a mixer channel with an effect chain and sends, and a lane of clips.
##
## A folder is a track other tracks name as their `parent`: its channel is the submix their
## signal passes through, the way a group bus works on a desk and a folder works in Reaper.

enum Monitor { OFF, ON, AUTO }

## Stable for the life of the project, and what sends and children refer to it by.
var id := ""
var name := ""
var colour := Color(0.55, 0.57, 0.6)
## The folder this track is in, by id, or empty for the top level.
var parent := ""
var volume_db := 0.0
## -1 is hard left, 1 hard right.
var pan := 0.0
var mute := false
var solo := false
var armed := false
var monitor := Monitor.OFF
## What it records from, as the program recording names it: an input device, a channel, keys.
## Empty for whatever is chosen when recording. Kept as it is, not read: a project carries it
## from one session to the next.
var input := ""
## The group it is in, 1 and up, or 0 for none: tracks of one group move together -- their
## faders by the same decibels, their mutes and solos as one -- the way Reaper's track groups and
## a desk's linked channels do. Kept, not acted on here: a front end does the linking.
var group := 0
var effects: Array[DawKitEffect] = []
var sends: Array[DawKitSend] = []
var clips: Array[DawKitClip] = []
## Which take lane sounds where: [start, end, lane] stretches of the song, in seconds, in order and
## not overlapping. Empty means no comp, and every lane sounds as stacked clips do. Outside every
## stretch of a comp that has any, nothing sounds.
var comp: Array = []
## Its automated controls, one lane per control (see DawKitAutomation).
var automation: Array[DawKitAutomation] = []


func _init(with_id := "", called := "") -> void:
	id = with_id
	name = called


func to_dict() -> Dictionary:
	return {"id": id, "name": name, "colour": colour.to_html(true), "parent": parent,
			"volume_db": volume_db, "pan": pan, "mute": mute, "solo": solo, "armed": armed,
			"monitor": monitor, "input": input, "group": group, "effects": effects.map(func(e): return e.to_dict()),
			"sends": sends.map(func(s): return s.to_dict()),
			"clips": clips.map(func(c): return c.to_dict()),
			"comp": comp.map(func(c): return c.duplicate()),
			"automation": automation.map(func(a): return a.to_dict())}


static func from_dict(d: Dictionary) -> DawKitTrack:
	var t := DawKitTrack.new(str(d.get("id", "")), str(d.get("name", "")))
	t.colour = Color.from_string(str(d.get("colour", "8c919aff")), Color(0.55, 0.57, 0.6))
	t.parent = str(d.get("parent", ""))
	t.volume_db = float(d.get("volume_db", 0.0))
	t.pan = float(d.get("pan", 0.0))
	t.mute = bool(d.get("mute", false))
	t.solo = bool(d.get("solo", false))
	t.armed = bool(d.get("armed", false))
	t.monitor = clampi(int(d.get("monitor", 0)), 0, 2) as Monitor
	t.input = str(d.get("input", ""))
	t.group = maxi(int(d.get("group", 0)), 0)
	for e in d.get("effects", []):
		t.effects.append(DawKitEffect.from_dict(e))
	for s in d.get("sends", []):
		t.sends.append(DawKitSend.from_dict(s))
	for c in d.get("clips", []):
		t.clips.append(DawKitClip.from_dict(c))
	for a in d.get("automation", []):
		t.automation.append(DawKitAutomation.from_dict(a))
	for c in d.get("comp", []):
		if c is Array and c.size() == 3 and float(c[1]) > float(c[0]):
			t.comp.append([float(c[0]), float(c[1]), maxi(int(c[2]), 0)])
	t.comp.sort_custom(func(a, b): return a[0] < b[0])
	return t


## The lane for `target`, or null.
func automation_of(target: String) -> DawKitAutomation:
	for a in automation:
		if a.target == target:
			return a
	return null


## How many take lanes the clips use: one more than the highest.
func lane_count() -> int:
	var n := 1
	for c in clips:
		n = maxi(n, c.lane + 1)
	return n


## Make `lane` the one that sounds from `from` to `to`, replacing whatever the comp said there and
## joining onto a neighbour of the same lane. The comp starts out as lane 0 throughout, over the
## span the clips cover, so choosing a stretch leaves the rest as it was heard.
func set_comp(from: float, to: float, lane: int) -> void:
	if to <= from:
		return
	if comp.is_empty() and not clips.is_empty():
		var lo := INF
		var hi := -INF
		for c in clips:
			lo = minf(lo, c.start)
			hi = maxf(hi, c.end())
		comp = [[lo, hi, 0]]
	var next: Array = []
	for s in comp:
		if s[1] <= from or s[0] >= to:
			next.append(s)
			continue
		if s[0] < from:
			next.append([s[0], from, s[2]])
		if s[1] > to:
			next.append([to, s[1], s[2]])
	next.append([from, to, maxi(lane, 0)])
	next.sort_custom(func(a, b): return a[0] < b[0])
	var joined: Array = []
	for s in next:
		if not joined.is_empty() and joined[-1][2] == s[2] and absf(joined[-1][1] - s[0]) < 1e-9:
			joined[-1][1] = s[1]
		else:
			joined.append(s)
	comp = joined


## The clips as they sound: all of them with no comp, otherwise each cut to the stretches of the
## comp that name its lane.
func playing_clips() -> Array[DawKitClip]:
	if comp.is_empty():
		return clips.duplicate()
	var out: Array[DawKitClip] = []
	for c in clips:
		for s in comp:
			if s[2] != c.lane:
				continue
			var from := maxf(c.start, s[0])
			var to := minf(c.end(), s[1])
			if to > from:
				out.append(c.slice(from, to))
	out.sort_custom(func(a, b): return a.start < b.start)
	return out


## The comp made plain: the clips as they sound, every one on the first lane, and no comp.
func flatten_comp() -> void:
	if comp.is_empty():
		return
	var flat := playing_clips()
	for c in flat:
		c.lane = 0
	clips.assign(flat)
	comp = []
