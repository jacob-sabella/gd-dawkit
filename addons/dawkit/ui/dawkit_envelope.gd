class_name DawKitEnvelope
extends RefCounted

## What an automation lane (an envelope) shows of its control (DawKitAutomation.target): the height a value is
## drawn at, the value a height is, the words for it, and the lane's name.
##
## Heights are 0 at the bottom of the lane to 1 at the top. A level (the fader, a send) is drawn
## on the fader's own law, so the lane looks like the fader moving; pan has left at the top, as
## Reaper draws it; a switch (mute, an effect on) is up for on.


## The height `value` is drawn at.
static func level_of(target: String, value: float) -> float:
	match DawKitAutomation.kind_of(target):
		"volume", "send":
			return DawKitLook.fader_of(value)
		"pan":
			return clampf((1.0 - value) * 0.5, 0.0, 1.0)
		"mute", "enable":
			return 1.0 if value >= 0.5 else 0.0
	return clampf(value, 0.0, 1.0)


## The value drawn at height `level`.
static func value_of(target: String, level: float) -> float:
	level = clampf(level, 0.0, 1.0)
	match DawKitAutomation.kind_of(target):
		"volume", "send":
			return DawKitLook.db_of(level)
		"pan":
			return 1.0 - level * 2.0
		"mute", "enable":
			return 1.0 if level >= 0.5 else 0.0
	return level


## Whether the control is a switch: its points hold, never ramp.
static func is_switch(target: String) -> bool:
	return DawKitAutomation.kind_of(target) in ["mute", "enable"]


static func text_of(target: String, value: float) -> String:
	match DawKitAutomation.kind_of(target):
		"volume", "send":
			return DawKitLook.db_text(value) + " dB"
		"pan":
			return DawKitLook.pan_text(value)
		"mute":
			return "muted" if value >= 0.5 else "on"
		"enable":
			return "on" if value >= 0.5 else "bypassed"
	return "%d%%" % roundi(value * 100.0)


## The lane's name: "Volume", "Send > Bass", "ReaEQ > Gain".
static func label_of(p: DawKitProject, t: DawKitTrack, target: String) -> String:
	match DawKitAutomation.kind_of(target):
		"volume":
			return "Volume"
		"pan":
			return "Pan"
		"mute":
			return "Mute"
		"send":
			var to := p.track(target.substr(5)) if p != null else null
			return "Send > " + (to.name if to != null and not to.name.is_empty() else target.substr(5))
		"enable", "fx":
			var parts := target.split(":")
			var i := int(parts[1])
			var e := t.effects[i] if i >= 0 and i < t.effects.size() else null
			var effect := (e.name if not e.name.is_empty() else e.kind) if e != null else "Effect %d" % (i + 1)
			if parts[0] == "enable":
				return effect + " > On"
			var param := int(parts[2])
			var called := e.names[param] if e != null and param < e.names.size() and not e.names[param].is_empty() else "Control %d" % (param + 1)
			return effect + " > " + called
	return target


## The control's value now, without automation: where a lane's first point starts.
static func current_of(t: DawKitTrack, target: String) -> float:
	match DawKitAutomation.kind_of(target):
		"volume":
			return t.volume_db
		"pan":
			return t.pan
		"mute":
			return 1.0 if t.mute else 0.0
		"send":
			for s in t.sends:
				if s.target == target.substr(5):
					return s.volume_db
			return 0.0
		"enable":
			var i := int(target.split(":")[1])
			return 1.0 if i < t.effects.size() and t.effects[i].enabled else 0.0
		"fx":
			var parts := target.split(":")
			var i := int(parts[1])
			var param := int(parts[2])
			return t.effects[i].values[param] if i < t.effects.size() and param < t.effects[i].values.size() else 0.0
	return 0.0


## What a track has to automate, [target, name] each: the fader, pan and mute, its sends, and its
## effects' switches and controls.
static func targets_of(p: DawKitProject, t: DawKitTrack) -> Array:
	var out := [["volume", "Volume"], ["pan", "Pan"], ["mute", "Mute"]]
	for s in t.sends:
		out.append(["send:" + s.target, label_of(p, t, "send:" + s.target)])
	for i in t.effects.size():
		out.append(["enable:%d" % i, label_of(p, t, "enable:%d" % i)])
		for param in t.effects[i].values.size():
			var target := "fx:%d:%d" % [i, param]
			out.append([target, label_of(p, t, target)])
	return out
