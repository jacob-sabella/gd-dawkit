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
var effects: Array[DawKitEffect] = []
var sends: Array[DawKitSend] = []
var clips: Array[DawKitClip] = []
## Its automated controls, one lane per control (see DawKitAutomation).
var automation: Array[DawKitAutomation] = []


func _init(with_id := "", called := "") -> void:
	id = with_id
	name = called


func to_dict() -> Dictionary:
	return {"id": id, "name": name, "colour": colour.to_html(true), "parent": parent,
			"volume_db": volume_db, "pan": pan, "mute": mute, "solo": solo, "armed": armed,
			"monitor": monitor, "input": input, "effects": effects.map(func(e): return e.to_dict()),
			"sends": sends.map(func(s): return s.to_dict()),
			"clips": clips.map(func(c): return c.to_dict()),
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
	for e in d.get("effects", []):
		t.effects.append(DawKitEffect.from_dict(e))
	for s in d.get("sends", []):
		t.sends.append(DawKitSend.from_dict(s))
	for c in d.get("clips", []):
		t.clips.append(DawKitClip.from_dict(c))
	for a in d.get("automation", []):
		t.automation.append(DawKitAutomation.from_dict(a))
	return t


## The lane for `target`, or null.
func automation_of(target: String) -> DawKitAutomation:
	for a in automation:
		if a.target == target:
			return a
	return null
