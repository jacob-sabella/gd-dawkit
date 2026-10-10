class_name DawKitEffect
extends RefCounted

## One effect in a track's chain.
##
## `kind` names one of the engine's own effects when it is one. An effect the engine cannot run
## (a third-party plugin read from another DAW's file) keeps its name, its parameters and its
## saved state, so a project passes through the engine without losing it.

var kind := ""
var name := ""
var enabled := true
## 0 is all dry, 1 all effect.
var wet := 1.0
var preset := ""
## Normalised 0..1, by parameter index, with each parameter's name alongside.
var values: Array[float] = []
var names: Array[String] = []
## Opaque saved state from another DAW's plugin, kept so it can be written back unchanged.
var state := PackedByteArray()
## The plugin format and id another DAW knows it by (e.g. "VST3", "CLAP"), if it came from one.
var plugin_format := ""
var plugin_id := ""
## Makes sound from notes rather than changing sound: an instrument, first in a MIDI track's chain
## (DAWproject's deviceRole "instrument"). The engine's own is "tine" (DawKitTine).
var instrument := false


func to_dict() -> Dictionary:
	return {"kind": kind, "name": name, "enabled": enabled, "wet": wet, "preset": preset,
			"values": Array(values), "names": Array(names),
			"state": Marshalls.raw_to_base64(state), "plugin_format": plugin_format,
			"plugin_id": plugin_id, "instrument": instrument}


static func from_dict(d: Dictionary) -> DawKitEffect:
	var e := DawKitEffect.new()
	e.kind = str(d.get("kind", ""))
	e.name = str(d.get("name", ""))
	e.enabled = bool(d.get("enabled", true))
	e.wet = float(d.get("wet", 1.0))
	e.preset = str(d.get("preset", ""))
	for v in d.get("values", []):
		e.values.append(float(v))
	for n in d.get("names", []):
		e.names.append(str(n))
	e.state = Marshalls.base64_to_raw(str(d.get("state", "")))
	e.plugin_format = str(d.get("plugin_format", ""))
	e.plugin_id = str(d.get("plugin_id", ""))
	e.instrument = bool(d.get("instrument", false))
	return e
