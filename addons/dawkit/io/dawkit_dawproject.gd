class_name DawKitDawproject
extends RefCounted

## DAWproject files (github.com/bitwig/dawproject, format 1.0): a zip of project.xml,
## metadata.xml and the media and plug-in states they refer to.
##
## Written so another DAW reads as much of a project as the format can say, and read so a file
## another DAW wrote opens here. What the format cannot say -- the loop, the metronome, a clip's
## gain, which tracks are armed and how they monitor, an effect's wet/dry and preset, a sidechain
## key -- goes in `dawkit/extras.json` inside the same zip. Other programs ignore an entry they
## do not know, and this one reads it back, so a project saved and opened here comes back
## exactly as it went out.
##
## Numbers that change form on the way in (decibels become a linear gain, pan -1..1 becomes
## 0..1, colours become 8-bit hex) are also kept exactly in the extras, keyed by where they
## are, and used only while they still agree with what the XML says. A file another DAW has
## re-saved keeps no extras at all; one edited by hand keeps only the ones that still agree.

const APPLICATION := "dawkit"
const VERSION := "0.1.0"
const FORMAT := "1.0"
const EXTRAS := "dawkit/extras.json"
const BUILTIN_PREFIX := "dawkit:"
## How close an exact value has to be to the file's own for the file to still mean it.
const AGREE := 0.0001
## How far from the file's own speed a warp may play it before it is said to be stretched.
const WARP_TOLERANCE := 0.01

const PLUGIN_TAGS := {"VST3": "Vst3Plugin", "VST2": "Vst2Plugin", "CLAP": "ClapPlugin", "AU": "AuPlugin"}
const PLUGIN_EXT := {"VST3": "vstpreset", "VST2": "fxp", "CLAP": "clap-preset", "AU": "aupreset"}
const DEVICE_TAGS := ["Device", "Vst2Plugin", "Vst3Plugin", "ClapPlugin", "BuiltinDevice",
		"Equalizer", "Compressor", "NoiseGate", "Limiter", "AuPlugin"]


# --- writing ------------------------------------------------------------------------------

## Writes `project` to `path`. Audio clips' files are read from `media_root` (clip.source is
## relative to it) and stored in the zip under the same relative path. Returns what could not be
## written, as sentences; the file is written regardless, minus those.
static func save(project: DawKitProject, path: String, media_root := "") -> PackedStringArray:
	var w := _Writer.new(project, media_root)
	var xml := w.project_xml()
	var zip := ZIPPacker.new()
	if zip.open(path) != OK:
		return PackedStringArray(["could not open %s for writing" % path])
	_store(zip, "project.xml", xml.to_text().to_utf8_buffer())
	_store(zip, "metadata.xml", _metadata(project).to_text().to_utf8_buffer())
	for entry in w.files:
		_store(zip, entry, w.files[entry])
	_store(zip, EXTRAS, JSON.stringify(w.extras, "  ").to_utf8_buffer())
	zip.close()
	return w.warnings


static func _store(zip: ZIPPacker, name: String, bytes: PackedByteArray) -> void:
	zip.start_file(name)
	zip.write_file(bytes)
	zip.close_file()


static func _metadata(project: DawKitProject) -> DawKitXml:
	var m := DawKitXml.new("MetaData")
	m.add("Title").text = project.title
	return m


class _Writer:
	var p: DawKitProject
	var media_root: String
	var extras := {"format": 1, "exact": {}, "tracks": {}, "effects": {}, "automation": {}}
	var files := {}
	var warnings := PackedStringArray()
	var _next := 0

	func _init(project: DawKitProject, root: String) -> void:
		p = project
		media_root = root

	func _id() -> String:
		_next += 1
		return "id%d" % _next

	func project_xml() -> DawKitXml:
		var root := DawKitXml.new("Project", {"version": FORMAT})
		root.add("Application", {"name": APPLICATION, "version": VERSION})
		var transport := root.add("Transport")
		transport.add("Tempo", {"unit": "bpm", "value": DawKitXml.num(p.tempo), "min": "20",
				"max": "960", "id": "tempo", "name": "Tempo"})
		transport.add("TimeSignature", {"numerator": str(p.time_signature.x),
				"denominator": str(p.time_signature.y), "id": "timesig"})
		var structure := root.add("Structure")
		for t in p.tracks:
			if t.parent.is_empty() or p.track(t.parent) == null:
				_track(structure, t)
		_track(structure, p.master)
		_arrangement(root)
		extras["project"] = {"loop_on": p.loop_on, "loop_start": p.loop_start,
				"loop_end": p.loop_end, "metronome": p.metronome, "length": p.length}
		return root

	func _track(parent: DawKitXml, t: DawKitTrack) -> void:
		var is_master := t == p.master
		var kids: Array[DawKitTrack] = []
		if not is_master:
			kids = p.children_of(t.id)
		var content := "audio notes" if is_master else ("tracks" if not kids.is_empty() else "audio notes")
		var x := parent.add("Track", {"contentType": content, "loaded": "true", "id": t.id,
				"name": t.name, "color": "#" + t.colour.to_html(false)})
		_exact(t.id + ".colour", [t.colour.r, t.colour.g, t.colour.b, t.colour.a])
		var ch := x.add("Channel", {"audioChannels": "2",
				"role": "master" if is_master else ("submix" if not kids.is_empty() else "regular"),
				"solo": DawKitXml.flag(t.solo), "id": _channel(t.id)})
		if not is_master:
			ch.attrs["destination"] = _channel(p.output_of(t).id)
		if not t.effects.is_empty():
			var devices := ch.add("Devices")
			for i in t.effects.size():
				_device(devices, t, i)
		ch.add("Mute", {"value": DawKitXml.flag(t.mute), "id": t.id + "-mute", "name": "Mute"})
		ch.add("Pan", {"unit": "normalized", "min": "0", "max": "1",
				"value": DawKitXml.num((t.pan + 1.0) * 0.5), "id": t.id + "-pan", "name": "Pan"})
		_exact(t.id + "-pan", t.pan)
		var audible := t.sends.filter(func(s): return not s.key)
		if not audible.is_empty():
			var sends := ch.add("Sends")
			for s in audible:
				var sid := "%s-send-%s" % [t.id, s.target]
				var sx := sends.add("Send", {"destination": _channel(s.target),
						"type": "pre" if s.pre_fader else "post", "id": sid})
				sx.add("Enable", {"value": DawKitXml.flag(s.enabled), "id": sid + "-on"})
				sx.add("Pan", {"unit": "normalized", "min": "0", "max": "1",
						"value": DawKitXml.num((s.pan + 1.0) * 0.5), "id": sid + "-pan"})
				_exact(sid + "-pan", s.pan)
				sx.add("Volume", {"unit": "linear", "min": "0", "max": "2",
						"value": DawKitXml.num(db_to_linear(s.volume_db)), "id": sid + "-vol"})
				_exact(sid + "-vol", s.volume_db)
		ch.add("Volume", {"unit": "linear", "min": "0", "max": "2",
				"value": DawKitXml.num(db_to_linear(t.volume_db)), "id": t.id + "-vol", "name": "Volume"})
		_exact(t.id + "-vol", t.volume_db)
		extras["tracks"][t.id] = {"armed": t.armed, "monitor": t.monitor, "input": t.input,
				"keys": t.sends.filter(func(s): return s.key).map(func(s): return s.to_dict())}
		for k in kids:
			_track(x, k)

	func _device(devices: DawKitXml, t: DawKitTrack, i: int) -> void:
		var e := t.effects[i]
		var did := "%s-fx%d" % [t.id, i]
		var tag := "BuiltinDevice" if not e.kind.is_empty() else PLUGIN_TAGS.get(e.plugin_format, "Device")
		var d := devices.add(tag, {"deviceName": e.name, "deviceRole": "instrument" if e.instrument else "audioFX", "loaded": "true",
				"id": did, "name": e.name})
		d.attrs["deviceID"] = BUILTIN_PREFIX + e.kind if not e.kind.is_empty() else e.plugin_id
		if not e.values.is_empty():
			var params := d.add("Parameters")
			for pi in e.values.size():
				params.add("RealParameter", {"parameterID": str(pi), "unit": "normalized",
						"min": "0", "max": "1", "value": DawKitXml.num(e.values[pi]),
						"id": "%s-p%d" % [did, pi],
						"name": e.names[pi] if pi < e.names.size() else ""})
		d.add("Enabled", {"value": DawKitXml.flag(e.enabled), "id": did + "-on", "name": "On/Off"})
		if not e.state.is_empty():
			var file := "plugins/%s.%s" % [did, PLUGIN_EXT.get(e.plugin_format, "state")]
			files[file] = e.state
			d.add("State", {"path": file})
		extras["effects"][did] = {"wet": e.wet, "preset": e.preset, "format": e.plugin_format}

	func _arrangement(root: DawKitXml) -> void:
		var arr := root.add("Arrangement", {"id": "arrangement"})
		var lanes := arr.add("Lanes", {"timeUnit": "seconds", "id": "lanes"})
		for t in p.tracks + [p.master]:
			if t == p.master and t.automation.is_empty():
				continue
			var lane := lanes.add("Lanes", {"track": t.id, "id": t.id + "-lane"})
			_automation(lane, t)
			if t == p.master:
				continue
			var clips := lane.add("Clips", {"id": t.id + "-clips"})
			var shapes: Array = []
			for c in t.clips:
				_clip(clips, t, c)
				shapes.append({"gain_db": c.gain_db, "colour": [c.colour.r, c.colour.g, c.colour.b, c.colour.a],
						"start": c.start, "length": c.length, "notes": Array(c.notes)})
			extras["tracks"][t.id]["clips"] = shapes
		if not p.markers.is_empty():
			var markers := arr.add("Markers", {"timeUnit": "seconds", "id": "markers"})
			for m in p.markers:
				var mx := markers.add("Marker", {"time": DawKitXml.num(m.time), "name": m.name})
				if m.colour.a > 0.0:
					mx.attrs["color"] = "#" + m.colour.to_html(false)
			extras["markers"] = p.markers.map(func(m): return m.to_dict())
		if not p.tempo_points.is_empty():
			var tempo := arr.add("TempoAutomation", {"timeUnit": "beats", "unit": "bpm", "id": "tempo-map"})
			tempo.add("Target", {"parameter": "tempo"})
			for pt in p.tempo_points:
				tempo.add("RealPoint", {"time": DawKitXml.num(pt[0]), "value": DawKitXml.num(pt[1]),
						"interpolation": "linear" if DawKitTempoMap.shape_of(pt[2]) != DawKitTempoMap.HOLD else "hold"})
			# DAWproject has one kind of ramp; which kind each one is, is ours.
			extras["tempo_points"] = p.tempo_points.map(func(pt): return [float(pt[0]), float(pt[1]), DawKitTempoMap.shape_of(pt[2])])

	## A track's automation, a Points lane per control, aimed at the parameter it moves by the id
	## the channel gave it, in that parameter's own unit.
	func _automation(lane: DawKitXml, t: DawKitTrack) -> void:
		for a in t.automation:
			var kind := DawKitAutomation.kind_of(a.target)
			var param := ""
			var unit := "normalized"
			match kind:
				"volume":
					param = t.id + "-vol"
					unit = "linear"
				"pan":
					param = t.id + "-pan"
				"mute":
					param = t.id + "-mute"
				"send":
					param = "%s-send-%s" % [t.id, a.target.substr(5)]
					unit = "linear"
					param += "-vol"
				"fx":
					var parts := a.target.split(":")
					param = "%s-fx%d-p%d" % [t.id, int(parts[1]), int(parts[2])]
			if param.is_empty():
				continue
			var points := lane.add("Points", {"id": "%s-auto-%s" % [t.id, a.target.replace(":", "-")]})
			if kind != "mute":
				points.attrs["unit"] = unit
			points.add("Target", {"parameter": param})
			for pt in a.points:
				var v: float = pt[1]
				match kind:
					"volume", "send":
						v = db_to_linear(v)
					"pan":
						v = (v + 1.0) * 0.5
				if kind == "mute":
					points.add("BoolPoint", {"time": DawKitXml.num(pt[0]), "value": DawKitXml.flag(v >= 0.5)})
				else:
					points.add("RealPoint", {"time": DawKitXml.num(pt[0]), "value": DawKitXml.num(v),
							"interpolation": "linear" if int(pt[2]) == DawKitAutomation.LINEAR else "hold"})
			extras["automation"][param] = a.points.map(func(pt): return [float(pt[0]), float(pt[1]), int(pt[2])])

	func _clip(clips: DawKitXml, t: DawKitTrack, c: DawKitClip) -> void:
		var x := clips.add("Clip", {"time": DawKitXml.num(c.start), "duration": DawKitXml.num(c.length),
				"playStart": DawKitXml.num(c.source_offset), "fadeTimeUnit": "seconds",
				"fadeInTime": DawKitXml.num(c.fade_in), "fadeOutTime": DawKitXml.num(c.fade_out),
				"enable": DawKitXml.flag(not c.muted), "name": c.name})
		if c.colour.a > 0.0:
			x.attrs["color"] = "#" + c.colour.to_html(false)
		if c.is_looped():
			x.attrs["loopStart"] = DawKitXml.num(c.loop_start)
			x.attrs["loopEnd"] = DawKitXml.num(c.loop_end)
		if not c.source.is_empty():
			var info := _media(c.source)
			var audio := x.add("Audio", {"channels": str(info.get("channels", 2)),
					"sampleRate": str(info.get("rate", 48000)),
					"duration": DawKitXml.num(info.get("seconds", c.source_offset + c.length))})
			audio.add("File", {"path": c.source})
		elif not c.notes.is_empty():
			x.attrs["contentTimeUnit"] = "seconds"
			var notes := x.add("Notes", {"timeUnit": "seconds"})
			for n in range(0, c.notes.size() - DawKitClip.NOTE_WIDTH + 1, DawKitClip.NOTE_WIDTH):
				var vel: float = clampf(c.notes[n + 3] / 127.0, 0.0, 1.0)
				notes.add("Note", {"time": DawKitXml.num(c.notes[n]),
						"duration": DawKitXml.num(c.notes[n + 1] - c.notes[n]),
						"channel": str(int(c.notes[n + 4])), "key": str(int(c.notes[n + 2])),
						"vel": DawKitXml.num(vel), "rel": DawKitXml.num(vel)})

	## The file, stored once in the zip, and what it is: channels, rate and length, read from a
	## WAV header when it is one.
	func _media(source: String) -> Dictionary:
		var from := media_root.path_join(source) if not media_root.is_empty() else source
		if not FileAccess.file_exists(from):
			warnings.append("%s is not in %s, so the file has no audio for it" % [source, media_root])
			return {}
		var bytes := FileAccess.get_file_as_bytes(from)
		files[source] = bytes
		return DawKitDawproject.wav_info(bytes)

	func _exact(key: String, value) -> void:
		extras["exact"][key] = value

	static func _channel(track_id: String) -> String:
		return track_id + "-ch"


## channels, rate, frames and seconds from a RIFF/WAVE header; empty when it is not one.
static func wav_info(bytes: PackedByteArray) -> Dictionary:
	if bytes.size() < 44 or bytes.slice(0, 4).get_string_from_ascii() != "RIFF" \
			or bytes.slice(8, 12).get_string_from_ascii() != "WAVE":
		return {}
	var at := 12
	var out := {}
	while at + 8 <= bytes.size():
		var id := bytes.slice(at, at + 4).get_string_from_ascii()
		var size := bytes.decode_u32(at + 4)
		if id == "fmt ":
			out["channels"] = bytes.decode_u16(at + 10)
			out["rate"] = bytes.decode_u32(at + 12)
			out["bits"] = bytes.decode_u16(at + 22)
		elif id == "data" and out.has("rate"):
			var frame := int(out["channels"]) * int(out["bits"]) / 8
			out["frames"] = size / maxi(frame, 1)
			out["seconds"] = float(out["frames"]) / float(out["rate"])
			return out
		at += 8 + size + (size & 1)
	return out


# --- reading ------------------------------------------------------------------------------

## Opens a .dawproject. Media and plug-in states are unpacked under `media_dir`, at the paths the
## file gives them, and clips refer to them relative to it. Returns {"project": DawKitProject or
## null, "warnings": PackedStringArray, "error": String}.
static func open(path: String, media_dir := "") -> Dictionary:
	var zip := ZIPReader.new()
	if zip.open(path) != OK:
		return {"project": null, "warnings": PackedStringArray(), "error": "%s is not a zip" % path}
	var names := zip.get_files()
	if not "project.xml" in names:
		zip.close()
		return {"project": null, "warnings": PackedStringArray(), "error": "%s has no project.xml" % path}
	var root := DawKitXml.parse(zip.read_file("project.xml"))
	if root == null or root.tag != "Project":
		zip.close()
		return {"project": null, "warnings": PackedStringArray(), "error": "project.xml is not a DAWproject"}
	var extras := {}
	if EXTRAS in names:
		var parsed = JSON.parse_string(zip.read_file(EXTRAS).get_string_from_utf8())
		extras = parsed if parsed is Dictionary else {}
	var r := _Reader.new(root, extras)
	var project := r.project()
	if "metadata.xml" in names:
		var meta := DawKitXml.parse(zip.read_file("metadata.xml"))
		if meta != null and meta.first("Title") != null and not meta.first("Title").text.is_empty():
			project.title = meta.first("Title").text
	if not media_dir.is_empty():
		for entry in r.wanted_files:
			if entry in names:
				var to := media_dir.path_join(entry)
				DirAccess.make_dir_recursive_absolute(to.get_base_dir())
				var f := FileAccess.open(to, FileAccess.WRITE)
				if f != null:
					f.store_buffer(zip.read_file(entry))
			else:
				r.warnings.append("the file names %s, which is not in it" % entry)
	for e in r.states:
		if e["path"] in names:
			(e["effect"] as DawKitEffect).state = zip.read_file(e["path"])
		else:
			r.warnings.append("the state of %s is not in the file; it opens as it starts" % (e["effect"] as DawKitEffect).name)
	# A file outside the project, by its path from where the project file is. One not on this
	# machine is said; one that is is played from where it is.
	for c in r.external_files:
		var where := c.source if c.source.is_absolute_path() else path.get_base_dir().path_join(c.source).simplify_path()
		if FileAccess.file_exists(where):
			c.source = where
		else:
			r.warnings.append("%s, which a clip plays from outside the project, is not on this machine" % c.source.get_file())
	zip.close()
	var problems := project.problems()
	if not problems.is_empty():
		return {"project": null, "warnings": r.warnings, "error": "; ".join(problems)}
	return {"project": project, "warnings": r.warnings, "error": ""}


class _Reader:
	var root: DawKitXml
	var extras: Dictionary
	var exact: Dictionary
	var warnings := PackedStringArray()
	var wanted_files: Array[String] = []
	## Clips playing a file outside the project, by its path as the file gives it.
	var external_files: Array[DawKitClip] = []
	var states: Array[Dictionary] = []
	## Where beats fall, for times a file gives in beats.
	var _map := DawKitTempoMap.new(120.0)
	## Parameter id -> [track, target, the parameter's element], for automation to find what it moves.
	var _params := {}
	## Channel id -> track id, for sends and destinations.
	var _channel_of := {}
	var _destinations := {}
	var _p: DawKitProject

	func _init(r: DawKitXml, x: Dictionary) -> void:
		root = r
		extras = x
		exact = x.get("exact", {})

	func project() -> DawKitProject:
		_p = DawKitProject.new()
		var transport := root.first("Transport")
		if transport != null:
			var t := transport.first("Tempo")
			if t != null:
				_p.tempo = t.get_float("value", 120.0)
			var sig := transport.first("TimeSignature")
			if sig != null:
				_p.time_signature = Vector2i(int(sig.get_float("numerator", 4)), int(sig.get_float("denominator", 4)))
		_map = DawKitTempoMap.new(_p.tempo)
		var structure := root.first("Structure")
		var pending_sends: Array = []
		if structure != null:
			for tx in structure.all("Track"):
				_track(tx, "", pending_sends)
		# Sends and destinations name channels, which may come later in the file than the
		# track that names them.
		for ps in pending_sends:
			var target: String = _channel_of.get(ps[1], "")
			if target.is_empty():
				warnings.append("a send on %s goes to a channel that is not there" % (ps[0] as DawKitTrack).name)
				continue
			(ps[2] as DawKitSend).target = target
			(ps[0] as DawKitTrack).sends.append(ps[2])
		for t in _p.tracks:
			var dest: String = _channel_of.get(_destinations.get(t.id, ""), "")
			# A destination that is not the folder it sits in is a routing this model cannot
			# hold (it routes by folder): said, and played through its folder or the master.
			if not dest.is_empty() and dest != DawKitProject.MASTER_ID and dest != t.parent:
				warnings.append("%s plays into %s, not its folder; it plays into its folder here"
						% [t.name, _p.track(dest).name if _p.track(dest) != null else dest])
		var arr := root.first("Arrangement")
		if arr != null:
			_tempo_map(arr)
			_arrangement(arr)
		var px: Dictionary = extras.get("project", {})
		_p.loop_on = bool(px.get("loop_on", false))
		_p.loop_start = float(px.get("loop_start", 0.0))
		_p.loop_end = float(px.get("loop_end", 0.0))
		_p.metronome = bool(px.get("metronome", false))
		_p.length = float(px.get("length", _last_clip_end()))
		return _p

	func _last_clip_end() -> float:
		var end := 0.0
		for t in _p.tracks:
			for c in t.clips:
				end = maxf(end, c.end())
		return end

	func _track(tx: DawKitXml, parent: String, pending_sends: Array) -> void:
		var ch := tx.first("Channel")
		var is_master := ch != null and ch.get_attr("role") == "master"
		var t: DawKitTrack
		if is_master:
			t = _p.master
		else:
			t = DawKitTrack.new(tx.get_attr("id", _p.new_track_id()), tx.get_attr("name"))
			t.parent = parent
			_p.tracks.append(t)
		t.colour = _colour(tx.get_attr("color"), t.id + ".colour", t.colour)
		if ch != null:
			_channel_of[ch.get_attr("id")] = t.id
			if not is_master:
				_destinations[t.id] = ch.get_attr("destination")
			t.solo = ch.get_bool("solo")
			var mute := ch.first("Mute")
			t.mute = mute != null and mute.get_bool("value")
			_param(mute, t, "mute")
			var pan := ch.first("Pan")
			if pan != null:
				t.pan = _pick(t.id + "-pan", _pan(pan))
			_param(pan, t, "pan")
			var vol := ch.first("Volume")
			if vol != null:
				t.volume_db = _pick(t.id + "-vol", _db(vol))
			_param(vol, t, "volume")
			var devices := ch.first("Devices")
			if devices != null:
				for dx in devices.children:
					if dx.tag in DEVICE_TAGS:
						var e := _effect(dx, "%s-fx%d" % [t.id, t.effects.size()])
						var params := dx.first("Parameters")
						if params != null:
							var n := 0
							for px in params.children:
								_param(px, t, "fx:%d:%d" % [t.effects.size(), int(px.get_float("parameterID", n))])
								n += 1
						t.effects.append(e)
			var sends := ch.first("Sends")
			if sends != null:
				for sx in sends.all("Send"):
					var s := DawKitSend.new()
					s.pre_fader = sx.get_attr("type") == "pre"
					var on := sx.first("Enable")
					s.enabled = on == null or on.get_bool("value", true)
					var sid := sx.get_attr("id")
					if sx.first("Pan") != null:
						s.pan = _pick(sid + "-pan", _pan(sx.first("Pan")))
					if sx.first("Volume") != null:
						s.volume_db = _pick(sid + "-vol", _db(sx.first("Volume")))
						# Its target is a track not known until every channel is.
						_param(sx.first("Volume"), t, "send:" + sx.get_attr("destination"))
					pending_sends.append([t, sx.get_attr("destination"), s])
		var tex: Dictionary = extras.get("tracks", {}).get(t.id, {})
		t.armed = bool(tex.get("armed", false))
		t.monitor = clampi(int(tex.get("monitor", 0)), 0, 2) as DawKitTrack.Monitor
		t.input = str(tex.get("input", ""))
		for k in tex.get("keys", []):
			t.sends.append(DawKitSend.from_dict(k))
		for child in tx.all("Track"):
			_track(child, t.id if not is_master else "", pending_sends)

	func _param(px: DawKitXml, t: DawKitTrack, target: String) -> void:
		if px != null and not px.get_attr("id").is_empty():
			_params[px.get_attr("id")] = [t, target, px]

	## A lane's Points: each aimed at a parameter this file gave an id, its values put into the
	## model's units through what that parameter says its own are.
	func _points(lane: DawKitXml, unit: String) -> void:
		for px in lane.all("Points"):
			var tgt := px.first("Target")
			if tgt == null or not _params.has(tgt.get_attr("parameter")):
				continue
			var param_id := tgt.get_attr("parameter")
			var entry: Array = _params[param_id]
			var t: DawKitTrack = entry[0]
			var target: String = entry[1]
			if target.begins_with("send:"):
				target = "send:" + str(_channel_of.get(target.substr(5), ""))
			var kind := DawKitAutomation.kind_of(target)
			if kind.is_empty() or target == "send:":
				continue
			var a := DawKitAutomation.new(target)
			var time_unit := px.get_attr("timeUnit", unit)
			for pt in px.children:
				if not pt.tag.ends_with("Point"):
					continue
				var shape := DawKitAutomation.LINEAR if pt.get_attr("interpolation", "hold") == "linear" else DawKitAutomation.HOLD
				var v := 0.0
				if kind == "mute":
					v = 1.0 if pt.get_bool("value") else 0.0
					shape = DawKitAutomation.HOLD
				else:
					var as_param := DawKitXml.new("Point", (entry[2] as DawKitXml).attrs.duplicate())
					as_param.attrs["value"] = pt.get_attr("value", "0")
					if not px.get_attr("unit").is_empty():
						as_param.attrs["unit"] = px.get_attr("unit")
					match kind:
						"volume", "send":
							v = _db(as_param)
						"pan":
							v = _pan(as_param)
						"fx":
							v = _normalised(as_param)
				a.add(_span(0.0, pt.get_float("time"), time_unit), DawKitAutomation.clamp_value(target, v), shape)
			# The exact points, while the file still says the same thing.
			var kept: Array = extras.get("automation", {}).get(param_id, [])
			if kept.size() == a.points.size():
				var agree := true
				for i in kept.size():
					agree = agree and absf(float(kept[i][0]) - a.points[i][0]) < AGREE \
							and absf(float(kept[i][1]) - a.points[i][1]) < AGREE * maxf(1.0, absf(a.points[i][1]))
				if agree:
					a = DawKitAutomation.new(target, kept)
			if not a.points.is_empty() and t.automation_of(target) == null:
				t.automation.append(a)

	func _effect(dx: DawKitXml, did: String) -> DawKitEffect:
		var e := DawKitEffect.new()
		e.name = dx.get_attr("deviceName", dx.get_attr("name"))
		e.instrument = dx.get_attr("deviceRole") == "instrument"
		var device_id := dx.get_attr("deviceID")
		if dx.tag == "BuiltinDevice" and device_id.begins_with(BUILTIN_PREFIX):
			e.kind = device_id.substr(BUILTIN_PREFIX.length())
		else:
			e.plugin_id = device_id
			for f in PLUGIN_TAGS:
				if PLUGIN_TAGS[f] == dx.tag:
					e.plugin_format = f
			if e.plugin_format.is_empty() and dx.tag != "Device":
				# A generic EQ, compressor, gate or limiter: kept by name, its settings by name.
				e.plugin_format = dx.tag
		var on := dx.first("Enabled")
		e.enabled = on == null or on.get_bool("value", true)
		var params := dx.first("Parameters")
		if params != null:
			for px in params.children:
				var at := int(px.get_float("parameterID", e.values.size()))
				while e.values.size() <= at:
					e.values.append(0.0)
					e.names.append("")
				e.values[at] = _normalised(px)
				e.names[at] = px.get_attr("name")
		var state := dx.first("State")
		if state != null and not state.get_attr("path").is_empty():
			states.append({"effect": e, "path": state.get_attr("path")})
		var ex: Dictionary = extras.get("effects", {}).get(did, {})
		e.wet = float(ex.get("wet", 1.0))
		e.preset = str(ex.get("preset", ""))
		if ex.has("format") and not str(ex["format"]).is_empty():
			e.plugin_format = str(ex["format"])
		return e

	## The arrangement's tempo changes, before anything in it is put into seconds. Points given in
	## seconds are placed in order, each by the map the points before it make.
	func _tempo_map(arr: DawKitXml) -> void:
		var tx := arr.first("TempoAutomation")
		if tx == null:
			return
		var unit := tx.get_attr("timeUnit", "beats")
		var m := DawKitTempoMap.new(_p.tempo)
		var first := true
		for px in tx.all(["RealPoint", "Point"]):
			var at := px.get_float("time")
			var beat := m.beat_at(at) if unit == "seconds" else at
			var bpm := px.get_float("value", _p.tempo)
			var ramps := DawKitTempoMap.RAMP_BEATS if px.get_attr("interpolation", "hold") == "linear" else DawKitTempoMap.HOLD
			if first and beat > 0.0:
				# The transport's tempo holds until the first point.
				m.set_point(0.0, _p.tempo, false)
			m.set_point(beat, bpm, ramps)
			first = false
		# Our own ramps in seconds, while the XML still says the same points.
		var exact: Array = extras.get("tempo_points", [])
		if exact.size() == m.points.size():
			var agree := true
			for i in exact.size():
				agree = agree and absf(float(exact[i][0]) - m.points[i][0]) < AGREE \
						and absf(float(exact[i][1]) - m.points[i][1]) < AGREE \
						and (DawKitTempoMap.shape_of(exact[i][2]) == DawKitTempoMap.HOLD) == (m.points[i][2] == DawKitTempoMap.HOLD)
			if agree:
				m = DawKitTempoMap.from_array(exact)
		_map = m
		_p.tempo = m.points[0][1]
		_p.tempo_points = [] if m.is_constant() and not m.points[0][2] else m.to_array()

	## `v` in `unit`, measured on from `origin` seconds into the song, as seconds.
	func _span(origin: float, v: float, unit: String) -> float:
		if unit != "beats":
			return v
		return _map.seconds_at(_map.beat_at(origin) + v) - origin

	## `v` in `unit`, measured back from `end` seconds into the song, as seconds.
	func _back(end: float, v: float, unit: String) -> float:
		if unit != "beats":
			return v
		return end - _map.seconds_at(_map.beat_at(end) - v)

	func _arrangement(arr: DawKitXml) -> void:
		_index(root)
		var top := arr.first("Lanes")
		if top != null:
			_lanes(top, top.get_attr("track"), top.get_attr("timeUnit", "beats"))
		for t in _p.tracks:
			var shapes: Array = extras.get("tracks", {}).get(t.id, {}).get("clips", [])
			for i in mini(shapes.size(), t.clips.size()):
				var c := t.clips[i]
				var sh: Dictionary = shapes[i]
				# Only for the clip it was written for: a re-saved file with clips moved or
				# added says nothing here about any of them.
				if absf(float(sh.get("start", -1)) - c.start) < AGREE and absf(float(sh.get("length", -1)) - c.length) < AGREE:
					c.gain_db = float(sh.get("gain_db", 0.0))
					var col: Array = sh.get("colour", [])
					if col.size() == 4 and (c.colour.a == 0.0 or _close_colour(c.colour, col)):
						c.colour = Color(col[0], col[1], col[2], col[3])
					# A note's end is written as its start plus a duration, which is not
					# always the same number again; the exact notes stand in while they agree.
					var exact_notes: Array = sh.get("notes", [])
					if exact_notes.size() == c.notes.size() and _close_notes(c.notes, exact_notes):
						c.notes = PackedFloat64Array(exact_notes)
		var mx := arr.first("Markers")
		if mx != null:
			var exact_markers: Array = extras.get("markers", [])
			var unit := mx.get_attr("timeUnit", top.get_attr("timeUnit", "beats") if top != null else "beats")
			var i := 0
			for m in mx.all("Marker"):
				var marker := DawKitMarker.new(_span(0.0, m.get_float("time"), unit), m.get_attr("name"))
				if not m.get_attr("color").is_empty():
					marker.colour = Color.from_string(m.get_attr("color"), Color(0, 0, 0, 0))
				if i < exact_markers.size():
					var ex := DawKitMarker.from_dict(exact_markers[i])
					if absf(ex.time - marker.time) < AGREE and ex.name == marker.name:
						marker = ex
				_p.markers.append(marker)
				i += 1
		var scenes := root.first("Scenes")
		if scenes != null and not scenes.children.is_empty():
			warnings.append("its %d scene(s) were left out: scenes and clip launchers are not kept" % scenes.all("Scene").size())

	## Every element by its id: a clip may play another's content by `reference`.
	var _by_id := {}

	func _index(x: DawKitXml) -> void:
		if x.attrs.has("id"):
			_by_id[x.get_attr("id")] = x
		for c in x.children:
			_index(c)

	## A lane and everything in it. The format nests lanes as deep as it likes, and any of them,
	## or a Clips or Points in them, may say whose track it is; what it does not say it has from
	## the lane around it. Bitwig nests a lane per track; others put `Clips track=` straight
	## under the arrangement's lanes.
	func _lanes(lane: DawKitXml, track_id: String, unit: String) -> void:
		for x in lane.children:
			var tid := x.get_attr("track", track_id)
			var u := x.get_attr("timeUnit", unit)
			match x.tag:
				"Lanes":
					_lanes(x, tid, u)
				"Clips":
					var t := _p.track(tid)
					if t == null or t == _p.master:
						if not x.all("Clip").is_empty():
							warnings.append("%d clip(s) on %s were left out: clips play on a track, not there"
									% [x.all("Clip").size(), "the master" if t == _p.master else "no track"])
						continue
					for cx in x.all("Clip"):
						_clip(t, cx, u, 0.0)
				"Points":
					_point_lane(x, u, tid)
				"Markers":
					pass
				"Notes", "Audio", "Warps", "Video":
					warnings.append("%s straight on a lane, not in a clip, was left out" % x.tag.to_lower())

	## Automation: of a parameter dawkit has a lane for, or said to be left out.
	func _point_lane(px: DawKitXml, unit: String, track_id: String) -> void:
		var tgt := px.first("Target")
		var whose := _p.track(track_id).name if _p.track(track_id) != null else "the project"
		if tgt != null and not tgt.get_attr("expression").is_empty():
			warnings.append("the MIDI %s automation on %s was left out: there is no lane for MIDI expression"
					% [tgt.get_attr("expression"), whose])
			return
		if tgt == null or not _params.has(tgt.get_attr("parameter")):
			warnings.append("automation on %s of a parameter it does not have, or does not say, was left out" % whose)
			return
		var holder := DawKitXml.new("Lanes", {"timeUnit": unit})
		holder.children.append(px)
		_points(holder, unit)


	## A clip, and any clips inside it (Bitwig nests an audio clip's events in a clip of their
	## own), flattened onto the track. `offset` is where the containing clip's content starts, in
	## seconds. Every time in beats is put into seconds through the tempo map from where it is
	## measured from, so a clip across a tempo change is as long as it sounds.
	func _clip(t: DawKitTrack, cx: DawKitXml, unit: String, offset: float) -> void:
		var c := DawKitClip.new()
		c.start = offset + _span(offset, cx.get_float("time"), unit)
		c.length = _span(c.start, cx.get_float("duration"), unit)
		c.name = cx.get_attr("name")
		c.muted = not cx.get_bool("enable", true)
		var content_unit := cx.get_attr("contentTimeUnit", unit)
		c.source_offset = _back(c.start, cx.get_float("playStart"), content_unit)
		# Where the clip's own time 0 is in the song: its start, less how far into its content it
		# starts playing.
		var origin := c.start - c.source_offset
		if cx.attrs.has("loopStart") and cx.attrs.has("loopEnd"):
			c.loop_start = _span(origin, cx.get_float("loopStart"), content_unit)
			c.loop_end = _span(origin, cx.get_float("loopEnd"), content_unit)
		var fade_unit := cx.get_attr("fadeTimeUnit", unit)
		c.fade_in = _span(c.start, cx.get_float("fadeInTime"), fade_unit)
		c.fade_out = _back(c.end(), cx.get_float("fadeOutTime"), fade_unit)
		if not cx.get_attr("color").is_empty():
			c.colour = Color.from_string(cx.get_attr("color"), Color(0, 0, 0, 0))
		# An alias plays another clip's content, named by its id.
		var content := cx
		if cx.attrs.has("reference"):
			var ref: DawKitXml = _by_id.get(cx.get_attr("reference"))
			if ref == null:
				warnings.append("the clip %s plays content that is not in the file; it is empty here" % c.name)
				t.clips.append(c)
				return
			content = DawKitXml.new("Clip")
			content.children.append(ref)
		var inner := content.first("Clips")
		if inner != null:
			for ix in inner.all("Clip"):
				_clip(t, ix, inner.get_attr("timeUnit", content_unit), origin)
			return
		var notes := content.first("Notes")
		var audio := content.first("Audio")
		var warps := content.first("Warps")
		if warps != null and audio == null:
			audio = warps.first("Audio")
			c.source_offset = _unwarp(warps, cx, c, content_unit)
		if content.first("Points") != null:
			warnings.append("the automation in the clip %s on %s was left out: automation is kept on tracks, not in clips"
					% [c.name if not c.name.is_empty() else "at %.2fs" % c.start, t.name])
		if content.first("Video") != null:
			warnings.append("the video in a clip on %s was left out" % t.name)
		if notes != null:
			var note_unit := notes.get_attr("timeUnit", content_unit)
			var flat := PackedFloat64Array()
			for n in notes.all("Note"):
				var on := _span(origin, n.get_float("time"), note_unit)
				var off := _span(origin, n.get_float("time") + n.get_float("duration"), note_unit) if note_unit == "beats" \
						else on + n.get_float("duration")
				flat.append_array([on, off,
						n.get_float("key"), roundf(clampf(n.get_float("vel", 0.8), 0.0, 1.0) * 127.0),
						n.get_float("channel")])
			c.notes = flat
		elif audio != null and audio.first("File") != null:
			c.source = audio.first("File").get_attr("path")
			if audio.first("File").get_bool("external"):
				external_files.append(c)
			elif not c.source in wanted_files:
				wanted_files.append(c.source)
		t.clips.append(c)

	## Where in its file a warped clip starts, in seconds of the file. dawkit plays a file at its own
	## speed, so a warp that is the tempo's own (the file's seconds go by as the song's do) is no
	## change at all; one that stretches the file is said, and played unstretched.
	func _unwarp(warps: DawKitXml, cx: DawKitXml, c: DawKitClip, clip_unit: String) -> float:
		var file_unit := warps.get_attr("contentTimeUnit", "seconds")
		var w := warps.all("Warp")
		if w.size() < 2 or file_unit != "seconds":
			warnings.append("a warped clip on the timeline could not be read; it plays from its start")
			return 0.0
		# The clip's time (in its content unit) against the file's seconds, as pairs.
		var song := func(x: float) -> float: return _span(c.start - c.source_offset, x, clip_unit)
		var at := cx.get_float("playStart")
		var from := 0.0
		var stretched := false
		for k in w.size() - 1:
			var a: DawKitXml = w[k]
			var b: DawKitXml = w[k + 1]
			var t0 := a.get_float("time")
			var t1 := b.get_float("time")
			var f0 := a.get_float("contentTime")
			var f1 := b.get_float("contentTime")
			var speed := (f1 - f0) / maxf(song.call(t1) - song.call(t0), 0.000001)
			if absf(speed - 1.0) > WARP_TOLERANCE and not stretched:
				stretched = true
				warnings.append("a clip is stretched to %.0f%% of its file's speed; it plays at the file's own speed here" % (speed * 100.0))
			if at >= t0 and at <= t1:
				from = f0 + (at - t0) / maxf(t1 - t0, 0.000001) * (f1 - f0)
		return from

	func _pan(px: DawKitXml) -> float:
		var v := px.get_float("value", 0.5)
		if px.get_attr("unit") == "normalized" or px.get_attr("unit").is_empty():
			var lo := px.get_float("min", 0.0)
			var hi := px.get_float("max", 1.0)
			return clampf((v - lo) / maxf(hi - lo, 0.000001) * 2.0 - 1.0, -1.0, 1.0)
		return clampf(v, -1.0, 1.0)

	func _db(vx: DawKitXml) -> float:
		var v := vx.get_float("value", 1.0)
		match vx.get_attr("unit"):
			"decibel":
				return v
			"normalized":
				return linear_to_db(maxf(v * vx.get_float("max", 1.0), 0.0))
			_:
				return linear_to_db(maxf(v, 0.0))

	func _normalised(px: DawKitXml) -> float:
		var v := px.get_float("value")
		if px.get_attr("unit") == "normalized" and not px.attrs.has("min"):
			return v
		var lo := px.get_float("min", 0.0)
		var hi := px.get_float("max", 1.0)
		return clampf((v - lo) / maxf(hi - lo, 0.000001), 0.0, 1.0) if hi > lo else v

	## The exact value kept for `key`, while it still agrees with the file's own.
	func _pick(key: String, from_file: float) -> float:
		if exact.has(key) and absf(float(exact[key]) - from_file) < AGREE * maxf(1.0, absf(from_file)):
			return float(exact[key])
		return from_file

	func _colour(html: String, key: String, fallback: Color) -> Color:
		if html.is_empty():
			return fallback
		var c := Color.from_string(html, fallback)
		var ex: Array = exact.get(key, [])
		if ex.size() == 4 and _close_colour(c, ex):
			return Color(ex[0], ex[1], ex[2], ex[3])
		return c

	static func _close_notes(a: PackedFloat64Array, b: Array) -> bool:
		for i in a.size():
			if absf(a[i] - float(b[i])) > AGREE:
				return false
		return true

	static func _close_colour(c: Color, ex: Array) -> bool:
		return absf(c.r - ex[0]) < 0.003 and absf(c.g - ex[1]) < 0.003 and absf(c.b - ex[2]) < 0.003
