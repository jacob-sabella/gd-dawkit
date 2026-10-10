class_name DawKitSend
extends RefCounted

## Some of a track's signal sent to another track: a reverb return, a bus, a sidechain key.

## The receiving track's `id`.
var target := ""
var volume_db := 0.0
## -1 is hard left, 1 hard right.
var pan := 0.0
var enabled := true
## Taken before the sending track's fader rather than after it.
var pre_fader := false
## A sidechain key: it feeds an effect's detector on the target, not the target's mix.
var key := false


func to_dict() -> Dictionary:
	return {"target": target, "volume_db": volume_db, "pan": pan, "enabled": enabled,
			"pre_fader": pre_fader, "key": key}


static func from_dict(d: Dictionary) -> DawKitSend:
	var s := DawKitSend.new()
	s.target = str(d.get("target", ""))
	s.volume_db = float(d.get("volume_db", 0.0))
	s.pan = float(d.get("pan", 0.0))
	s.enabled = bool(d.get("enabled", true))
	s.pre_fader = bool(d.get("pre_fader", false))
	s.key = bool(d.get("key", false))
	return s
