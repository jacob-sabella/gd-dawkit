class_name DawKitProjectHost
extends DawKitHost

## A host that is just a project in memory: every edit is made to it at once, with an undo step
## each, and the transport is a clock that `advance` moves on. It plays no sound -- that is
## the host application's mixer -- so it is what dawkit's own tests and a project opened only to
## be looked at and edited use.

const UNDO_DEPTH := 100

var _project: DawKitProject
var _position := 0.0
var _count_in := 0
var _file := ""
var _recent := PackedStringArray()
## Whether anything has changed since the project was opened, started or saved.
var _dirty := false
## Where audio clips' files are, for saving and opening.
var media_root := ""
var _playing := false
var _recording := false
## The project's plain form before each edit, and the name of the edit, newest last.
var _undo: Array = []
var _redo: Array = []
## The selected clips, the clips themselves as keys, so an index moving does not lose one.
var _selected: Dictionary = {}

const MIN_CLIP_SECONDS := 0.01
const MIN_NOTE_SECONDS := 0.01
const MAX_COUNT_IN := 4
const RECENT_FILES := 8
const INSERT_VELOCITY := 100

## What a chain can be given, [id, name, [control names]] each: kinds a host's mixer would know.
## A project only in memory makes no sound, so these are names and controls, nothing more.
var choices: Array = [
	["eq", "EQ", ["Low", "Mid", "High"]],
	["compressor", "Compressor", ["Threshold", "Ratio", "Attack", "Release"]],
	["reverb", "Reverb", ["Room size", "Damping"]],
	["delay", "Delay", ["Time", "Feedback"]],
	["chorus", "Chorus", ["Rate", "Depth"]],
	["distortion", "Distortion", ["Drive", "Tone"]],
]


func _init(p: DawKitProject = null) -> void:
	_project = p if p != null else DawKitProject.new()


func project() -> DawKitProject:
	return _project


## Replaces the project, forgetting the undo history with the old one.
func use(p: DawKitProject) -> void:
	_project = p
	_selected.clear()
	_undo.clear()
	_redo.clear()
	_position = 0.0
	project_changed.emit()


func can(edit: StringName) -> bool:
	return edit in [VOLUME, PAN, MUTE, MASTER_MUTE, SOLO, ARM, TRANSPORT, RECORD, SEEK, LOOP, METRONOME, TEMPO,
			MOVE_CLIP, UNDO, SELECT, EDIT_CLIPS, TRACKS, TRACK_ORDER, EFFECTS, EFFECT_ORDER, SENDS, NOTES,
			MARKERS, LOOP_RANGE, TEMPO_MAP, COUNT_IN, AUTOMATION, FILES, SAVE]


func position() -> float:
	return _position


func is_playing() -> bool:
	return _playing


func is_recording() -> bool:
	return _recording


## Moves the clock on while playing, round the loop when it is on.
func advance(seconds: float) -> void:
	if not _playing:
		return
	_position += seconds
	if _project.loop_on and _project.loop_end > _project.loop_start and _position >= _project.loop_end:
		_position = _project.loop_start + fmod(_position - _project.loop_start, _project.loop_end - _project.loop_start)


func undo_name() -> String:
	return _undo.back()[1] if not _undo.is_empty() else ""


func set_volume(id: String, db: float) -> void:
	_track_edit(id, "volume", func(t: DawKitTrack): t.volume_db = clampf(db, -150.0, 12.0))


func set_pan(id: String, pan: float) -> void:
	_track_edit(id, "pan", func(t: DawKitTrack): t.pan = clampf(pan, -1.0, 1.0))


func set_mute(id: String, on: bool) -> void:
	_track_edit(id, "mute", func(t: DawKitTrack): t.mute = on)


func set_solo(id: String, on: bool) -> void:
	_track_edit(id, "solo", func(t: DawKitTrack): t.solo = on)


func set_armed(id: String, on: bool) -> void:
	_track_edit(id, "arm", func(t: DawKitTrack): t.armed = on)


func play() -> void:
	_playing = true
	transport_changed.emit()


func stop() -> void:
	_playing = false
	_recording = false
	transport_changed.emit()


func record() -> void:
	_playing = true
	_recording = true
	transport_changed.emit()


func seek(seconds: float) -> void:
	_position = maxf(seconds, 0.0)
	transport_changed.emit()


func set_looping(on: bool) -> void:
	_step("loop")
	_project.loop_on = on
	transport_changed.emit()


func set_metronome(on: bool) -> void:
	_step("click")
	_project.metronome = on
	transport_changed.emit()


func set_tempo(bpm: float) -> void:
	_step("tempo")
	_project.tempo = clampf(bpm, 1.0, 960.0)
	if not _project.tempo_points.is_empty():
		_project.tempo_points[0][1] = _project.tempo
	transport_changed.emit()


func project_file() -> String:
	return _file


func is_dirty() -> bool:
	return _dirty


func recent_files() -> PackedStringArray:
	return _recent


func new_project() -> void:
	_replace(DawKitProject.new(), "")
	said.emit("New project.")


func open_project(path: String) -> void:
	var opened := DawKitDawproject.open(path, media_root)
	if opened["project"] == null:
		said.emit("Could not open %s: %s" % [path.get_file(), opened["error"]])
		return
	_replace(opened["project"], path)
	said.emit("Opened %s." % path.get_file())


func save_project() -> void:
	if _file.is_empty():
		said.emit("Save as, to say where.")
		return
	save_project_as(_file)


func save_project_as(path: String) -> void:
	if not path.get_extension().to_lower() == file_extension():
		path += "." + file_extension()
	var missed := DawKitDawproject.save(_project, path, media_root)
	if not FileAccess.file_exists(path):
		said.emit("Could not save %s." % path.get_file())
		return
	_file = path
	_dirty = false
	_remember(path)
	if _project.title == "Untitled" or _project.title.is_empty():
		_project.title = path.get_file().get_basename()
	said.emit("Saved %s." % path.get_file() + ("" if missed.is_empty() else " Not kept: " + "; ".join(missed)))
	transport_changed.emit()


func _replace(p: DawKitProject, path: String) -> void:
	_project = p
	_undo.clear()
	_redo.clear()
	_dirty = false
	_selected.clear()
	_position = 0.0
	_file = path
	if not path.is_empty():
		_remember(path)
	project_changed.emit()
	transport_changed.emit()


func _remember(path: String) -> void:
	var at := _recent.find(path)
	if at >= 0:
		_recent.remove_at(at)
	_recent.insert(0, path)
	if _recent.size() > RECENT_FILES:
		_recent.resize(RECENT_FILES)


func set_automation(id: String, target: String, points: Array) -> void:
	var t := _project.track(id)
	if t == null or DawKitAutomation.kind_of(target).is_empty():
		return
	_step("automation")
	var lane := t.automation_of(target)
	if lane != null:
		t.automation.erase(lane)
	if not points.is_empty():
		lane = DawKitAutomation.new(target)
		for pt in points:
			lane.add(float(pt[0]), DawKitAutomation.clamp_value(target, float(pt[1])), int(pt[2]) if pt.size() > 2 else DawKitAutomation.LINEAR)
		t.automation.append(lane)
	track_changed.emit(id)


func set_loop_range(start: float, end: float) -> void:
	var from := maxf(minf(start, end), 0.0)
	var to := maxf(maxf(start, end), 0.0)
	if is_equal_approx(from, _project.loop_start) and is_equal_approx(to, _project.loop_end):
		return
	_step("loop range")
	_project.loop_start = from
	_project.loop_end = to
	transport_changed.emit()


func count_in() -> int:
	return _count_in


func set_count_in(bars: int) -> void:
	_count_in = clampi(bars, 0, MAX_COUNT_IN)
	transport_changed.emit()


func add_marker(seconds: float, called := "") -> void:
	_step("add marker")
	_project.markers.append(DawKitMarker.new(maxf(seconds, 0.0), called))
	_sort_song()


func edit_marker(index: int, seconds: float, called: String) -> void:
	if index < 0 or index >= _project.markers.size():
		return
	var m := _project.markers[index]
	if is_equal_approx(m.time, maxf(seconds, 0.0)) and m.name == called:
		return
	_step("edit marker")
	m.time = maxf(seconds, 0.0)
	m.name = called
	_sort_song()


func remove_marker(index: int) -> void:
	if index < 0 or index >= _project.markers.size():
		return
	_step("remove marker")
	_project.markers.remove_at(index)
	_sort_song()


func add_region(start: float, end: float, called := "") -> void:
	if absf(end - start) < MIN_CLIP_SECONDS:
		return
	_step("add region")
	_project.regions.append(DawKitRegion.new(maxf(minf(start, end), 0.0), maxf(start, end), called))
	_sort_song()


func edit_region(index: int, start: float, end: float, called: String) -> void:
	if index < 0 or index >= _project.regions.size() or absf(end - start) < MIN_CLIP_SECONDS:
		return
	var r := _project.regions[index]
	var from := maxf(minf(start, end), 0.0)
	var to := maxf(start, end)
	if is_equal_approx(r.start, from) and is_equal_approx(r.end, to) and r.name == called:
		return
	_step("edit region")
	r.start = from
	r.end = to
	r.name = called
	_sort_song()


func remove_region(index: int) -> void:
	if index < 0 or index >= _project.regions.size():
		return
	_step("remove region")
	_project.regions.remove_at(index)
	_sort_song()


func set_tempo_points(points: Array) -> void:
	var map := DawKitTempoMap.from_array(points)
	_step("tempo map")
	_project.tempo = map.points[0][1]
	_project.tempo_points = [] if map.points.size() == 1 and map.points[0][2] == DawKitTempoMap.HOLD else map.to_array()
	project_changed.emit()


func set_meter_points(points: Array) -> void:
	var meter := DawKitMeter.from_array(points, _project.time_signature.x, _project.time_signature.y)
	_step("time signature")
	_project.time_signature = Vector2i(meter.points[0][1], meter.points[0][2])
	_project.time_signature_points = [] if meter.points.size() == 1 else meter.to_array()
	project_changed.emit()


## Markers and regions back in time order, and told.
func _sort_song() -> void:
	_project.markers.sort_custom(func(a: DawKitMarker, b: DawKitMarker): return a.time < b.time)
	_project.regions.sort_custom(func(a: DawKitRegion, b: DawKitRegion): return a.start < b.start)
	transport_changed.emit()


func move_clip(id: String, clip_index: int, start: float, to_id := "") -> void:
	var from := _project.track(id)
	var to := _project.track(to_id) if not to_id.is_empty() else from
	if from == null or to == null or clip_index < 0 or clip_index >= from.clips.size():
		return
	var clip := from.clips[clip_index]
	if clip.locked:
		return
	_step("move clip")
	from.clips.remove_at(clip_index)
	clip.start = maxf(start, 0.0)
	to.clips.append(clip)
	to.clips.sort_custom(func(a: DawKitClip, b: DawKitClip): return a.start < b.start)
	track_changed.emit(from.id)
	if to != from:
		track_changed.emit(to.id)


func add_track(after_id := "", name := "") -> void:
	var after := _project.track(after_id) if not after_id.is_empty() else null
	_step("add track")
	var t := DawKitTrack.new(_project.new_track_id(), name if not name.is_empty() else "Track %d" % (_project.tracks.size() + 1))
	if after == null:
		_project.tracks.append(t)
	else:
		# Inside the folder the track before it is in, or at the top of its own when it is one.
		var block := _project.block_of(after)
		t.parent = after.id if block.size() > 1 else after.parent
		_project.tracks.insert(_project.tracks.find(after) + 1, t)
	project_changed.emit()


func remove_track(id: String) -> void:
	var t := _project.track(id)
	if t == null or t == _project.master:
		return
	_step("remove track")
	for c in t.clips:
		_selected.erase(c)
	_project.remove_track(id)
	project_changed.emit()


func duplicate_track(id: String) -> void:
	var t := _project.track(id)
	if t == null or t == _project.master:
		return
	_step("duplicate track")
	var copy := DawKitTrack.from_dict(t.to_dict())
	copy.id = _project.new_track_id()
	copy.armed = false
	var block := _project.block_of(t)
	_project.tracks.insert(_project.tracks.find(block.back()) + 1, copy)
	project_changed.emit()


func rename_track(id: String, name: String) -> void:
	var t := _project.track(id)
	if t == null or t.name == name:
		return
	_track_edit(id, "rename", func(x: DawKitTrack): x.name = name)


func set_track_colour(id: String, colour: Color) -> void:
	var t := _project.track(id)
	if t == null or t.colour.is_equal_approx(colour):
		return
	_track_edit(id, "colour", func(x: DawKitTrack): x.colour = colour)


func move_track(id: String, position: int, parent_id: String) -> void:
	var before := _project.to_dict()
	var order := _project.tracks.map(func(t): return t.id)
	var t := _project.track(id)
	var was := t.parent if t != null else ""
	if not _project.move_track(id, position, parent_id):
		return
	if _project.tracks.map(func(x): return x.id) == order and was == parent_id:
		return
	_undo.append([before, "move track", ""])
	_redo.clear()
	project_changed.emit()


func effect_choices() -> Array:
	return choices.map(func(c: Array): return [c[0], c[1]])


func add_effect(id: String, choice: String, at := -1) -> void:
	var t := _project.track(id)
	var found: Array = choices.filter(func(c: Array): return c[0] == choice)
	if t == null or found.is_empty():
		return
	_step("add effect")
	var e := DawKitEffect.new()
	e.kind = choice
	e.name = found[0][1]
	for n in found[0][2]:
		e.names.append(n)
		e.values.append(0.5)
	t.effects.insert(clampi(at, 0, t.effects.size()) if at >= 0 else t.effects.size(), e)
	track_changed.emit(id)


func remove_effect(id: String, index: int) -> void:
	var t := _project.track(id)
	if t == null or index < 0 or index >= t.effects.size():
		return
	_step("remove effect")
	t.effects.remove_at(index)
	track_changed.emit(id)


func move_effect(id: String, index: int, to_id: String, to_index: int) -> void:
	var t := _project.track(id)
	var to := _project.track(to_id) if not to_id.is_empty() else t
	if t == null or to == null or index < 0 or index >= t.effects.size():
		return
	to_index = clampi(to_index, 0, to.effects.size() - (1 if to == t else 0))
	if to == t and to_index == index:
		return
	_step("move effect")
	var e := t.effects[index]
	t.effects.remove_at(index)
	to.effects.insert(to_index, e)
	track_changed.emit(t.id)
	if to != t:
		track_changed.emit(to.id)


func set_effect_enabled(id: String, index: int, on: bool) -> void:
	_effect_edit(id, index, "bypass", func(e: DawKitEffect): e.enabled = on)


func set_effect_wet(id: String, index: int, wet: float) -> void:
	_effect_edit(id, index, "wet", func(e: DawKitEffect): e.wet = clampf(wet, 0.0, 1.0))


func set_effect_value(id: String, index: int, param: int, value: float) -> void:
	if param < 0:
		return
	var t := _project.track(id)
	if t == null or index < 0 or index >= t.effects.size():
		return
	_step("effect control", "control:%s:%d:%d" % [id, index, param])
	_apply_value(t.effects[index], param, value)
	track_changed.emit(id)


static func _apply_value(e: DawKitEffect, param: int, value: float) -> void:
	while e.values.size() <= param:
		e.values.append(0.0)
	while e.names.size() < e.values.size():
		e.names.append("")
	e.values[param] = clampf(value, 0.0, 1.0)


func add_send(id: String, to_id: String) -> void:
	var t := _project.track(id)
	if t == null or _project.track(to_id) == null or to_id == id or t == _project.master:
		return
	_step("add send")
	var sd := DawKitSend.new()
	sd.target = to_id
	t.sends.append(sd)
	track_changed.emit(id)


func remove_send(id: String, send_index: int) -> void:
	var t := _project.track(id)
	if t == null or send_index < 0 or send_index >= t.sends.size():
		return
	_step("remove send")
	var gone := t.sends[send_index]
	t.sends.remove_at(send_index)
	for a in t.automation.duplicate():
		if a.target == "send:" + gone.target and not t.sends.any(func(sd): return sd.target == gone.target):
			t.automation.erase(a)
	track_changed.emit(id)


func set_send_level(id: String, send_index: int, db: float) -> void:
	_send_edit(id, send_index, "send level", func(sd: DawKitSend): sd.volume_db = clampf(db, DawKitLook.SILENT_DB, DawKitLook.FADER_MAX_DB))


func set_send_pan(id: String, send_index: int, pan: float) -> void:
	_send_edit(id, send_index, "send pan", func(sd: DawKitSend): sd.pan = clampf(pan, -1.0, 1.0))


func set_send_pre_fader(id: String, send_index: int, pre: bool) -> void:
	_send_edit(id, send_index, "send pre/post", func(sd: DawKitSend): sd.pre_fader = pre)


func _effect_edit(id: String, index: int, what: String, edit: Callable) -> void:
	var t := _project.track(id)
	if t == null or index < 0 or index >= t.effects.size():
		return
	_step(what, "%s:%s:%d" % [what, id, index] if what == "wet" else "")
	edit.call(t.effects[index])
	track_changed.emit(id)


func _send_edit(id: String, send_index: int, what: String, edit: Callable) -> void:
	var t := _project.track(id)
	if t == null or send_index < 0 or send_index >= t.sends.size():
		return
	_step(what, "%s:%s:%d" % [what, id, send_index] if what in ["send level", "send pan"] else "")
	edit.call(t.sends[send_index])
	track_changed.emit(id)


func insert_note(id: String, clip_index: int, on: float, off: float, pitch: int) -> void:
	var c := _clip(id, clip_index)
	if c == null or not c.source.is_empty() or c.locked or on >= c.length - MIN_NOTE_SECONDS:
		return
	_step("insert note")
	on = maxf(on, 0.0)
	off = clampf(off, on + MIN_NOTE_SECONDS, maxf(c.length, on + MIN_NOTE_SECONDS))
	var at := c.note_count()
	for n in c.note_count():
		if c.notes[n * DawKitClip.NOTE_WIDTH] > on:
			at = n
			break
	var notes := c.notes
	var fresh := [on, off, clampi(pitch, 0, 127), INSERT_VELOCITY, 0]
	for k in fresh.size():
		notes.insert(at * DawKitClip.NOTE_WIDTH + k, fresh[k])
	c.notes = notes
	clips_changed.emit()


func delete_note(id: String, clip_index: int, note: int) -> void:
	var c := _note_clip(id, clip_index, note)
	if c == null:
		return
	_step("delete note")
	var notes := c.notes
	for _k in DawKitClip.NOTE_WIDTH:
		notes.remove_at(note * DawKitClip.NOTE_WIDTH)
	c.notes = notes
	clips_changed.emit()


func move_note(id: String, clip_index: int, note: int, on: float, pitch: int) -> void:
	var c := _note_clip(id, clip_index, note)
	if c == null:
		return
	var at := note * DawKitClip.NOTE_WIDTH
	var length := c.notes[at + 1] - c.notes[at]
	on = clampf(on, 0.0, maxf(c.length - length, 0.0))
	pitch = clampi(pitch, 0, 127)
	if is_equal_approx(on, c.notes[at]) and pitch == int(c.notes[at + 2]):
		return
	_step("move note")
	var notes := c.notes
	notes[at] = on
	notes[at + 1] = on + length
	notes[at + 2] = pitch
	c.notes = notes
	clips_changed.emit()


func set_note_end(id: String, clip_index: int, note: int, off: float) -> void:
	var c := _note_clip(id, clip_index, note)
	if c == null:
		return
	var at := note * DawKitClip.NOTE_WIDTH
	off = clampf(off, c.notes[at] + MIN_NOTE_SECONDS, maxf(c.length, c.notes[at] + MIN_NOTE_SECONDS))
	if is_equal_approx(off, c.notes[at + 1]):
		return
	_step("note length")
	var notes := c.notes
	notes[at + 1] = off
	c.notes = notes
	clips_changed.emit()


func set_note_velocity(id: String, clip_index: int, note: int, velocity: int) -> void:
	var c := _note_clip(id, clip_index, note)
	velocity = clampi(velocity, 1, 127)
	if c == null or int(c.notes[note * DawKitClip.NOTE_WIDTH + 3]) == velocity:
		return
	_step("velocity", "velocity:%s:%d:%d" % [id, clip_index, note])
	var notes := c.notes
	notes[note * DawKitClip.NOTE_WIDTH + 3] = velocity
	c.notes = notes
	clips_changed.emit()


func quantize_clip(id: String, clip_index: int, grid_beats: float) -> void:
	var c := _clip(id, clip_index)
	if c == null or c.locked or c.note_count() == 0 or grid_beats <= 0.0:
		return
	_step("quantize")
	var map := _project.tempo_map()
	var notes := c.notes
	for n in c.note_count():
		var at := n * DawKitClip.NOTE_WIDTH
		var length := notes[at + 1] - notes[at]
		var beat := map.beat_at(c.start + notes[at])
		var on := clampf(map.seconds_at(roundf(beat / grid_beats) * grid_beats) - c.start, 0.0, maxf(c.length - length, 0.0))
		notes[at] = on
		notes[at + 1] = on + length
	c.notes = notes
	clips_changed.emit()


## A MIDI clip that can be edited and has note `note`, or null.
func _note_clip(id: String, clip_index: int, note: int) -> DawKitClip:
	var c := _clip(id, clip_index)
	if c == null or c.locked or note < 0 or note >= c.note_count():
		return null
	return c


func is_selected(id: String, clip_index: int) -> bool:
	var c := _clip(id, clip_index)
	return c != null and _selected.has(c)


func select_clip(id: String, clip_index: int, additive := false) -> void:
	var c := _clip(id, clip_index)
	if c == null:
		return
	if not additive:
		_selected.clear()
		_selected[c] = true
	elif _selected.has(c):
		_selected.erase(c)
	else:
		_selected[c] = true
	clips_changed.emit()


func clear_selection() -> void:
	if _selected.is_empty():
		return
	_selected.clear()
	clips_changed.emit()


## Every selected clip as [track, clip], in project order.
func selection() -> Array:
	var out: Array = []
	for t in _project.tracks:
		for c in t.clips:
			if _selected.has(c):
				out.append([t, c])
	return out


func split_selection(seconds: float) -> void:
	var cut := selection().filter(func(pair: Array) -> bool:
			return seconds > pair[1].start + MIN_CLIP_SECONDS and seconds < pair[1].end() - MIN_CLIP_SECONDS)
	if cut.is_empty():
		return
	_step("split")
	for pair in cut:
		var t: DawKitTrack = pair[0]
		var c: DawKitClip = pair[1]
		var at := t.clips.find(c)
		var left := c.slice(c.start, seconds)
		var right := c.slice(seconds, c.end())
		t.clips[at] = left
		t.clips.insert(at + 1, right)
		_selected.erase(c)
		_selected[left] = true
		_selected[right] = true
	clips_changed.emit()


func delete_selection() -> void:
	var gone := selection()
	if gone.is_empty():
		return
	_step("delete")
	for pair in gone:
		(pair[0] as DawKitTrack).clips.erase(pair[1])
	_selected.clear()
	clips_changed.emit()


func duplicate_selection() -> void:
	var picked := selection()
	if picked.is_empty():
		return
	_step("duplicate")
	var first := INF
	var last := -INF
	for pair in picked:
		first = minf(first, pair[1].start)
		last = maxf(last, pair[1].end())
	_selected.clear()
	for pair in picked:
		var copy := DawKitClip.from_dict((pair[1] as DawKitClip).to_dict())
		copy.start += last - first
		var t: DawKitTrack = pair[0]
		t.clips.append(copy)
		t.clips.sort_custom(func(a: DawKitClip, b: DawKitClip): return a.start < b.start)
		_selected[copy] = true
	clips_changed.emit()


func trim_clip(id: String, clip_index: int, start: float, end: float) -> void:
	var c := _clip(id, clip_index)
	if c == null or c.locked:
		return
	start = maxf(minf(start, end - MIN_CLIP_SECONDS), 0.0)
	end = maxf(end, start + MIN_CLIP_SECONDS)
	var shift := start - c.start
	if not c.source.is_empty() and not c.is_looped():
		# Not before the file's own start.
		shift = maxf(shift, -c.source_offset)
		start = c.start + shift
	if is_equal_approx(start, c.start) and is_equal_approx(end, c.end()):
		return
	_step("trim")
	if c.source.is_empty():
		var kept := PackedFloat64Array()
		for n in c.note_count():
			var at := n * DawKitClip.NOTE_WIDTH
			var on := c.notes[at] - shift
			var off := c.notes[at + 1] - shift
			if off <= 0.0 or on >= end - start:
				continue
			kept.append_array([maxf(on, 0.0), minf(off, end - start), c.notes[at + 2], c.notes[at + 3], c.notes[at + 4]])
		c.notes = kept
	else:
		c.source_offset += shift
	c.start = start
	c.length = end - start
	c.fade_in = minf(c.fade_in, c.length)
	c.fade_out = minf(c.fade_out, c.length - c.fade_in)
	track_changed.emit(id)
	clips_changed.emit()


func set_clip_fades(id: String, clip_index: int, fade_in: float, fade_out: float) -> void:
	var c := _clip(id, clip_index)
	if c == null:
		return
	fade_in = clampf(fade_in, 0.0, c.length)
	fade_out = clampf(fade_out, 0.0, c.length - fade_in)
	if is_equal_approx(fade_in, c.fade_in) and is_equal_approx(fade_out, c.fade_out):
		return
	_step("fades")
	c.fade_in = fade_in
	c.fade_out = fade_out
	clips_changed.emit()


func set_clip_gain(id: String, clip_index: int, db: float) -> void:
	var c := _clip(id, clip_index)
	if c == null:
		return
	_step("clip gain")
	c.gain_db = clampf(db, -60.0, 24.0)
	clips_changed.emit()


func set_clip_muted(id: String, clip_index: int, muted: bool) -> void:
	var c := _clip(id, clip_index)
	if c == null or c.muted == muted:
		return
	_step("mute clip")
	c.muted = muted
	clips_changed.emit()


func undo() -> void:
	if _undo.is_empty():
		return
	var last: Array = _undo.pop_back()
	_dirty = true
	_redo.append([_project.to_dict(), last[1], ""])
	_project = DawKitProject.from_dict(last[0])
	_selected.clear()
	project_changed.emit()


func redo() -> void:
	if _redo.is_empty():
		return
	var next: Array = _redo.pop_back()
	_dirty = true
	_undo.append([_project.to_dict(), next[1], ""])
	_project = DawKitProject.from_dict(next[0])
	_selected.clear()
	project_changed.emit()


func _clip(id: String, clip_index: int) -> DawKitClip:
	var t := _project.track(id)
	if t == null or clip_index < 0 or clip_index >= t.clips.size():
		return null
	return t.clips[clip_index]


func _track_edit(id: String, what: String, edit: Callable) -> void:
	var t := _project.track(id)
	if t == null:
		return
	_step(what, what + ":" + id if what in ["volume", "pan"] else "")
	edit.call(t)
	track_changed.emit(id)


## Before an edit: the project kept to undo back to. A run of edits to the same control (`key`,
## a fader dragged) is one step, as it is one gesture.
func _step(what: String, key := "") -> void:
	_dirty = true
	if not key.is_empty() and not _undo.is_empty() and _undo.back().size() > 2 and _undo.back()[2] == key and _redo.is_empty():
		return
	_undo.append([_project.to_dict(), what, key])
	if _undo.size() > UNDO_DEPTH:
		_undo.pop_front()
	_redo.clear()
