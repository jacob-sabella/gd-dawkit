class_name DawKitMarker
extends RefCounted

## A named point on the timeline.

var time := 0.0
var name := ""
var colour := Color(0, 0, 0, 0)


func _init(at := 0.0, called := "") -> void:
	time = at
	name = called


func to_dict() -> Dictionary:
	return {"time": time, "name": name, "colour": colour.to_html(true)}


static func from_dict(d: Dictionary) -> DawKitMarker:
	var m := DawKitMarker.new(float(d.get("time", 0.0)), str(d.get("name", "")))
	m.colour = Color.from_string(str(d.get("colour", "00000000")), Color(0, 0, 0, 0))
	return m
