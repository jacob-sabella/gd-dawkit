class_name DawKitRegion
extends RefCounted

## A named span of the timeline: a song's verse, chorus, bridge. Seconds, as markers are.

var start := 0.0
var end := 0.0
var name := ""


func _init(from := 0.0, to := 0.0, called := "") -> void:
	start = from
	end = to
	name = called


func to_dict() -> Dictionary:
	return {"start": start, "end": end, "name": name}


static func from_dict(d: Dictionary) -> DawKitRegion:
	return DawKitRegion.new(float(d.get("start", 0.0)), float(d.get("end", 0.0)), str(d.get("name", "")))
