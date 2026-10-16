class_name DawKitAutomation
extends RefCounted

## One automated control of a track: where it is at each moment of the song.
##
## `target` names the control:
##   "volume"          the fader, in dB
##   "pan"             -1 hard left to 1 hard right
##   "mute"            0 or 1
##   "send:<track id>" the level of the send to that track, in dB
##   "fx:<i>:<p>"      effect i's parameter p, normalised 0-1
##   "enable:<i>"      effect i on (1) or bypassed (0)
## Points are [seconds, value, shape]: from each point to the next the value holds (HOLD) or goes
## there in a straight line (LINEAR). Before the first point the first value holds, after the last
## the last. Seconds, like clips, whatever the tempo does.

const HOLD := 0
const LINEAR := 1

var target := ""
## [seconds, value, shape] in order of seconds.
var points: Array = []


func _init(what := "", at: Array = []) -> void:
	target = what
	for p in at:
		add(float(p[0]), float(p[1]), int(p[2]) if p.size() > 2 else LINEAR)


## A point at `seconds`, replacing one already there.
func add(seconds: float, value: float, shape := LINEAR) -> void:
	seconds = maxf(seconds, 0.0)
	for p in points:
		if is_equal_approx(p[0], seconds):
			p[1] = value
			p[2] = shape
			return
	points.append([seconds, value, clampi(shape, HOLD, LINEAR)])
	points.sort_custom(func(a, b): return a[0] < b[0])


## The value at `seconds`, or `fallback` when there are no points.
func value_at(seconds: float, fallback := 0.0) -> float:
	return value_in(points, seconds, fallback)


## The same, for points kept somewhere other than a DawKitAutomation.
static func value_in(points: Array, seconds: float, fallback := 0.0) -> float:
	if points.is_empty():
		return fallback
	if seconds <= points[0][0]:
		return points[0][1]
	var i := points.size() - 1
	while i > 0 and points[i][0] > seconds:
		i -= 1
	if i + 1 >= points.size() or int(points[i][2]) == HOLD:
		return points[i][1]
	var a: Array = points[i]
	var b: Array = points[i + 1]
	return lerpf(a[1], b[1], (seconds - a[0]) / maxf(b[0] - a[0], 0.000001))


## What kind of control `target` is: "volume", "pan", "mute", "send" or "fx", or "" for none.
static func kind_of(what: String) -> String:
	if what in ["volume", "pan", "mute"]:
		return what
	if what.begins_with("send:") and what.length() > 5:
		return "send"
	var parts := what.split(":")
	if parts.size() == 2 and parts[0] == "enable" and parts[1].is_valid_int():
		return "enable"
	if parts.size() == 3 and parts[0] == "fx" and parts[1].is_valid_int() and parts[2].is_valid_int():
		return "fx"
	return ""


## The value a target's points are clamped to.
static func clamp_value(what: String, v: float) -> float:
	match kind_of(what):
		"volume", "send":
			return clampf(v, -150.0, 24.0)
		"pan":
			return clampf(v, -1.0, 1.0)
		"mute", "enable":
			return 1.0 if v >= 0.5 else 0.0
		"fx":
			return clampf(v, 0.0, 1.0)
	return v


func to_dict() -> Dictionary:
	return {"target": target, "points": points.map(func(p): return [float(p[0]), float(p[1]), int(p[2])])}


static func from_dict(d: Dictionary) -> DawKitAutomation:
	return DawKitAutomation.new(str(d.get("target", "")), d.get("points", []))
