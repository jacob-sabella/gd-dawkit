class_name DawKitProject
extends RefCounted

## A whole project: everything needed to put a session back exactly as it was, and nothing
## that only describes a moment (meters, the playhead, a selection).
##
## Tracks are in project order. The master is a track of its own (id "master") so it has the
## same effect chain and level as any other. `to_dict`/`from_dict` are its plain form, and
## `same_as` compares two of them field by field: a project that goes out to a file and comes
## back has to be `same_as` the one that went out.

const FORMAT_VERSION := 1
const MASTER_ID := "master"

var title := "Untitled"
var tempo := 120.0
## The tempo's changes, as DawKitTempoMap's points ([beat, bpm, shape], the first at beat 0 and at
## `tempo`); empty for a song at one tempo. Clips and markers are in seconds whatever this says:
## the map is for counting bars and beats, and for a file that counts in them.
var tempo_points: Array = []
## Beats per bar, and the note value of one beat.
var time_signature := Vector2i(4, 4)
## The time signature's changes, as DawKitMeter's points ([beat, numerator, denominator], the
## first at beat 0 and at `time_signature`); empty for a song in one signature.
var time_signature_points: Array = []
## Seconds: how far the timeline runs, which can be past the last clip.
var length := 0.0
var metronome := false
var loop_on := false
var loop_start := 0.0
var loop_end := 0.0
var markers: Array[DawKitMarker] = []
## Named spans, in order of their starts.
var regions: Array[DawKitRegion] = []
var master := DawKitTrack.new(MASTER_ID, "Master")
var tracks: Array[DawKitTrack] = []


## Where every beat falls: `tempo` held, or `tempo_points` when there are any.
func tempo_map() -> DawKitTempoMap:
	if tempo_points.is_empty():
		return DawKitTempoMap.new(tempo)
	return DawKitTempoMap.from_array(tempo_points)


## Where every bar begins: `time_signature` held, or `time_signature_points` when there are any.
func meter() -> DawKitMeter:
	if time_signature_points.is_empty():
		return DawKitMeter.new(time_signature.x, time_signature.y)
	return DawKitMeter.from_array(time_signature_points, time_signature.x, time_signature.y)


## The track with this id, the master included, or null.
func track(id: String) -> DawKitTrack:
	if id == MASTER_ID:
		return master
	for t in tracks:
		if t.id == id:
			return t
	return null


## An id no track has yet: "t1", "t2", ...
func new_track_id() -> String:
	var n := tracks.size() + 1
	while track("t%d" % n) != null:
		n += 1
	return "t%d" % n


## Adds a track at the end and returns it.
func add_track(called: String) -> DawKitTrack:
	var t := DawKitTrack.new(new_track_id(), called)
	tracks.append(t)
	return t


## The tracks inside `folder_id`, directly, in order.
func children_of(folder_id: String) -> Array[DawKitTrack]:
	var out: Array[DawKitTrack] = []
	for t in tracks:
		if t.parent == folder_id:
			out.append(t)
	return out


## Where a track's signal goes: its folder's channel, or the master.
func output_of(t: DawKitTrack) -> DawKitTrack:
	if t == master:
		return null
	var folder := track(t.parent) if not t.parent.is_empty() else null
	return folder if folder != null else master


## Everything wrong with the project's references, as sentences. Empty when it is sound: every
## send and every parent names a track that exists, no track is its own folder, and ids are
## unique. A file read from another program is checked with this before it is played.
func problems() -> PackedStringArray:
	var out := PackedStringArray()
	var last_beat := -1.0
	for point in tempo_points:
		if not (point is Array) or point.size() < 3 or float(point[0]) <= last_beat or float(point[1]) <= 0.0:
			out.append("the tempo map's points are not each a later beat at a real tempo (%s)" % [point])
			break
		last_beat = float(point[0])
	if not tempo_points.is_empty() and (float(tempo_points[0][0]) != 0.0 or not is_equal_approx(float(tempo_points[0][1]), tempo)):
		out.append("the tempo map does not start at the project's tempo")
	last_beat = -1.0
	for point in time_signature_points:
		if not (point is Array) or point.size() < 3 or float(point[0]) <= last_beat or int(point[1]) < 1 or int(point[2]) < 1:
			out.append("the time signature's changes are not each a later beat in a real signature (%s)" % [point])
			break
		last_beat = float(point[0])
	if not time_signature_points.is_empty() and (float(time_signature_points[0][0]) != 0.0
			or Vector2i(int(time_signature_points[0][1]), int(time_signature_points[0][2])) != time_signature):
		out.append("the time signature's changes do not start at the project's signature")
	var seen := {}
	for t in tracks:
		if t.id.is_empty() or t.id == MASTER_ID:
			out.append("track '%s' has no usable id" % t.name)
		elif seen.has(t.id):
			out.append("two tracks are called %s" % t.id)
		seen[t.id] = true
	for t in tracks:
		if not t.parent.is_empty() and not seen.has(t.parent):
			out.append("%s is in a folder that is not there (%s)" % [t.id, t.parent])
		var up := t.parent
		var steps := 0
		while not up.is_empty() and steps <= tracks.size():
			if up == t.id:
				out.append("%s is inside itself" % t.id)
				break
			var p := track(up)
			up = p.parent if p != null else ""
			steps += 1
		for s in t.sends:
			if s.target == t.id or (not seen.has(s.target) and s.target != MASTER_ID):
				out.append("%s sends to %s, which it cannot" % [t.id, s.target])
	for t in tracks + [master]:
		for a in t.automation:
			match DawKitAutomation.kind_of(a.target):
				"":
					out.append("%s automates %s, which is not a control" % [t.id, a.target])
				"send":
					var to: String = a.target.substr(5)
					if not t.sends.any(func(sd): return sd.target == to and not sd.key):
						out.append("%s automates a send to %s it does not have" % [t.id, to])
				"fx":
					var parts: PackedStringArray = a.target.split(":")
					if int(parts[1]) >= t.effects.size():
						out.append("%s automates effect %s, which it does not have" % [t.id, parts[1]])
	return out


func to_dict() -> Dictionary:
	return {"format_version": FORMAT_VERSION, "title": title, "tempo": tempo,
			"tempo_points": tempo_points.map(func(pt): return [float(pt[0]), float(pt[1]), DawKitTempoMap.shape_of(pt[2])]),
			"time_signature": [time_signature.x, time_signature.y],
			"time_signature_points": time_signature_points.map(func(pt): return [float(pt[0]), int(pt[1]), int(pt[2])]),
			"length": length,
			"metronome": metronome,
			"loop": {"on": loop_on, "start": loop_start, "end": loop_end},
			"markers": markers.map(func(m): return m.to_dict()),
			"regions": regions.map(func(r): return r.to_dict()),
			"master": master.to_dict(),
			"tracks": tracks.map(func(t): return t.to_dict())}


static func from_dict(d: Dictionary) -> DawKitProject:
	var p := DawKitProject.new()
	p.title = str(d.get("title", "Untitled"))
	p.tempo = float(d.get("tempo", 120.0))
	for pt in d.get("tempo_points", []):
		p.tempo_points.append([float(pt[0]), float(pt[1]), DawKitTempoMap.shape_of(pt[2])])
	var sig: Array = d.get("time_signature", [4, 4])
	p.time_signature = Vector2i(int(sig[0]), int(sig[1]))
	for pt in d.get("time_signature_points", []):
		p.time_signature_points.append([float(pt[0]), int(pt[1]), int(pt[2])])
	p.length = float(d.get("length", 0.0))
	p.metronome = bool(d.get("metronome", false))
	var loop: Dictionary = d.get("loop", {})
	p.loop_on = bool(loop.get("on", false))
	p.loop_start = float(loop.get("start", 0.0))
	p.loop_end = float(loop.get("end", 0.0))
	for m in d.get("markers", []):
		p.markers.append(DawKitMarker.from_dict(m))
	for r in d.get("regions", []):
		p.regions.append(DawKitRegion.from_dict(r))
	if d.has("master"):
		p.master = DawKitTrack.from_dict(d["master"])
		p.master.id = MASTER_ID
	for t in d.get("tracks", []):
		p.tracks.append(DawKitTrack.from_dict(t))
	return p


## A deep copy.
func duplicate() -> DawKitProject:
	return DawKitProject.from_dict(to_dict())


func same_as(other: DawKitProject) -> bool:
	return first_difference(other).is_empty()


## Where two projects first differ, as a path ("tracks[2].clips[0].fade_in: 0.1 vs 0.2"), or
## empty when they do not.
func first_difference(other: DawKitProject) -> String:
	return _diff(to_dict(), other.to_dict(), "")


static func _diff(a, b, path: String) -> String:
	if typeof(a) != typeof(b):
		return "%s: %s vs %s" % [path, a, b]
	if a is Dictionary:
		for k in a:
			if not b.has(k):
				return "%s.%s: missing" % [path, k]
			var d := _diff(a[k], b[k], "%s.%s" % [path, k] if path else str(k))
			if d != "":
				return d
		for k in b:
			if not a.has(k):
				return "%s.%s: extra" % [path, k]
		return ""
	if a is Array:
		if a.size() != b.size():
			return "%s: %d entries vs %d" % [path, a.size(), b.size()]
		for i in a.size():
			var d := _diff(a[i], b[i], "%s[%d]" % [path, i])
			if d != "":
				return d
		return ""
	# A number written to a file in beats and read back in seconds may differ in its last bits.
	if a is float and absf(a - b) <= 1e-9 * maxf(1.0, absf(a)):
		return ""
	return "" if a == b else "%s: %s vs %s" % [path, a, b]
