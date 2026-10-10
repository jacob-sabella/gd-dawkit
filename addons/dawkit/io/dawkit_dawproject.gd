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
	var extras := {"format": 1, "exact": {}, "tracks": {}, "effects": {}}
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
				var sid := _id()
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
		extras["tracks"][t.id] = {"armed": t.armed, "monitor": t.monitor,
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
		for t in p.tracks:
			var lane := lanes.add("Lanes", {"track": t.id, "id": t.id + "-lane"})
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
	var states: Array[Dictionary] = []
	var tempo := 120.0
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
		tempo = _p.tempo
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
			var pan := ch.first("Pan")
			if pan != null:
				t.pan = _pick(t.id + "-pan", _pan(pan))
			var vol := ch.first("Volume")
			if vol != null:
				t.volume_db = _pick(t.id + "-vol", _db(vol))
			var devices := ch.first("Devices")
			if devices != null:
				for dx in devices.children:
					if dx.tag in DEVICE_TAGS:
						t.effects.append(_effect(dx, "%s-fx%d" % [t.id, t.effects.size()]))
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
					pending_sends.append([t, sx.get_attr("destination"), s])
		var tex: Dictionary = extras.get("tracks", {}).get(t.id, {})
		t.armed = bool(tex.get("armed", false))
		t.monitor = clampi(int(tex.get("monitor", 0)), 0, 2) as DawKitTrack.Monitor
		for k in tex.get("keys", []):
			t.sends.append(DawKitSend.from_dict(k))
		for child in tx.all("Track"):
			_track(child, t.id if not is_master else "", pending_sends)

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

	func _arrangement(arr: DawKitXml) -> void:
		var top := arr.first("Lanes")
		if top != null:
			var unit := top.get_attr("timeUnit", "beats")
			for lane in top.all("Lanes"):
				var t := _p.track(lane.get_attr("track"))
				if t == null or t == _p.master:
					continue
				for clips in lane.all("Clips"):
					var lane_unit := clips.get_attr("timeUnit", lane.get_attr("timeUnit", unit))
					for cx in clips.all("Clip"):
						_clip(t, cx, lane_unit, 0.0)
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
				var marker := DawKitMarker.new(_seconds(m.get_float("time"), unit), m.get_attr("name"))
				if not m.get_attr("color").is_empty():
					marker.colour = Color.from_string(m.get_attr("color"), Color(0, 0, 0, 0))
				if i < exact_markers.size():
					var ex := DawKitMarker.from_dict(exact_markers[i])
					if absf(ex.time - marker.time) < AGREE and ex.name == marker.name:
						marker = ex
				_p.markers.append(marker)
				i += 1

	## A clip, and any clips inside it (Bitwig nests an audio clip's events in a clip of their
	## own), flattened onto the track. `offset` is where the containing clip starts, in seconds.
	func _clip(t: DawKitTrack, cx: DawKitXml, unit: String, offset: float) -> void:
		var c := DawKitClip.new()
		c.start = offset + _seconds(cx.get_float("time"), unit)
		c.length = _seconds(cx.get_float("duration"), unit)
		c.name = cx.get_attr("name")
		c.muted = not cx.get_bool("enable", true)
		var content_unit := cx.get_attr("contentTimeUnit", unit)
		c.source_offset = _seconds(cx.get_float("playStart"), content_unit)
		if cx.attrs.has("loopStart") and cx.attrs.has("loopEnd"):
			c.loop_start = _seconds(cx.get_float("loopStart"), content_unit)
			c.loop_end = _seconds(cx.get_float("loopEnd"), content_unit)
		var fade_unit := cx.get_attr("fadeTimeUnit", unit)
		c.fade_in = _seconds(cx.get_float("fadeInTime"), fade_unit)
		c.fade_out = _seconds(cx.get_float("fadeOutTime"), fade_unit)
		if not cx.get_attr("color").is_empty():
			c.colour = Color.from_string(cx.get_attr("color"), Color(0, 0, 0, 0))
		var inner := cx.first("Clips")
		if inner != null:
			for ix in inner.all("Clip"):
				_clip(t, ix, inner.get_attr("timeUnit", content_unit), c.start)
			return
		var notes := cx.first("Notes")
		var audio := cx.first("Audio")
		var warps := cx.first("Warps")
		if warps != null and audio == null:
			audio = warps.first("Audio")
		if notes != null:
			var note_unit := notes.get_attr("timeUnit", content_unit)
			var flat := PackedFloat64Array()
			for n in notes.all("Note"):
				var on := _seconds(n.get_float("time"), note_unit)
				flat.append_array([on, on + _seconds(n.get_float("duration"), note_unit),
						n.get_float("key"), roundf(clampf(n.get_float("vel", 0.8), 0.0, 1.0) * 127.0),
						n.get_float("channel")])
			c.notes = flat
		elif audio != null and audio.first("File") != null:
			c.source = audio.first("File").get_attr("path")
			if not audio.first("File").get_bool("external") and not c.source in wanted_files:
				wanted_files.append(c.source)
		t.clips.append(c)

	func _seconds(v: float, unit: String) -> float:
		return v * 60.0 / maxf(tempo, 1.0) if unit == "beats" else v

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
