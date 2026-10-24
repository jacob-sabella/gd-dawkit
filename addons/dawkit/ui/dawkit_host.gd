class_name DawKitHost
extends RefCounted

## What dawkit's 2D interface (DawKitStudio) reads and asks for, and nothing else.
##
## The interface never edits a project itself. It draws `project()` and asks the host for every
## change, by track id, in the project's own units (decibels, pan -1..1, seconds). A host is
## whatever owns the project: DawKitProjectHost keeps one in memory; an application with its
## own engine, a session or a network in between implements this over that, and the interface
## follows whatever the host says happened, which may not be what it asked for.
##
## Every edit here does nothing by default, and `can` says which ones a host answers, so the
## interface leaves out what a host cannot do rather than offering it and ignoring it.

## The project was replaced, or its tracks added, removed or reordered: draw it again whole.
signal project_changed()
## One track's fields, clips or effects changed. The master's id is DawKitProject.MASTER_ID.
signal track_changed(id: String)
## Clips were added, moved, cut or removed, on any track: draw the lanes again.
signal clips_changed()
## Playing, stopping, recording, looping, the click or the tempo changed. The playhead moving is
## not a change: it is read every frame from `position()`.
signal transport_changed()

## Something for the status line: an edit refused, a project saved, a render done.
signal said(text: String)

## The edits a host can say it answers, for `can`.
const VOLUME := &"volume"
const PAN := &"pan"
const MUTE := &"mute"
## Mute the master as well as the tracks.
const MASTER_MUTE := &"master_mute"
const SOLO := &"solo"
const ARM := &"arm"
const TRANSPORT := &"transport"
const RECORD := &"record"
const SEEK := &"seek"
const LOOP := &"loop"
const METRONOME := &"metronome"
const TEMPO := &"tempo"
const MOVE_CLIP := &"move_clip"
const UNDO := &"undo"
## Add, remove, duplicate, rename and colour tracks; move them and put them in folders.
const TRACKS := &"tracks"
const TRACK_ORDER := &"track_order"
## Add, remove and bypass effects and set their controls; move them along a chain or to another
## track; add and remove sends and set them.
const EFFECTS := &"effects"
const EFFECT_ORDER := &"effect_order"
const SENDS := &"sends"
## Edit a MIDI clip's notes.
const NOTES := &"notes"
## Make, name, move and remove markers and regions.
const MARKERS := &"markers"
## Set the loop's range (LOOP is switching it on and off).
const LOOP_RANGE := &"loop_range"
## Tempo and time signature changes along the song.
const TEMPO_MAP := &"tempo_map"
## A count-in before recording.
const COUNT_IN := &"count_in"
## Draw a track's controls' automation.
const AUTOMATION := &"automation"
## Start, open and save projects as files (FILES), save where it is (SAVE), render it (RENDER).
const FILES := &"files"
const SAVE := &"save"
const RENDER := &"render"
## Select clips; and edit them: split, delete, duplicate, trim, fade, gain, mute.
const SELECT := &"select"
const EDIT_CLIPS := &"edit_clips"


## The project as it is now. The interface reads it and never writes to it.
func project() -> DawKitProject:
	return null


## Whether the host answers an edit (one of the consts above).
func can(_edit: StringName) -> bool:
	return false


## Seconds into the song the playhead is at.
func position() -> float:
	return 0.0


func is_playing() -> bool:
	return false


func is_recording() -> bool:
	return false


## A track's level now, each channel's peak 0..1. Read every frame while it is drawn.
func meter(_id: String) -> Vector2:
	return Vector2.ZERO


## An audio clip's file as it is drawn: the loudest sample of every 1/DawKitAudioFile.PEAKS_PER_SECOND
## of the file, 0..255 (DawKitAudioFile.peaks). Empty when the host has none, and the clip is drawn
## without a wave.
func clip_peaks(_id: String, _clip_index: int) -> PackedByteArray:
	return PackedByteArray()


## A one-line name for what the project would undo, or "" for nothing to undo.
func undo_name() -> String:
	return ""


func set_volume(_id: String, _db: float) -> void:
	pass


func set_pan(_id: String, _pan: float) -> void:
	pass


func set_mute(_id: String, _on: bool) -> void:
	pass


func set_solo(_id: String, _on: bool) -> void:
	pass


func set_armed(_id: String, _on: bool) -> void:
	pass


func play() -> void:
	pass


func stop() -> void:
	pass


func record() -> void:
	pass


func seek(_seconds: float) -> void:
	pass


func set_looping(_on: bool) -> void:
	pass


func set_metronome(_on: bool) -> void:
	pass


func set_tempo(_bpm: float) -> void:
	pass


## The file the project was opened from or last saved to, "" for none yet.
func project_file() -> String:
	return ""


## Whether the project has changes no save has kept.
func is_dirty() -> bool:
	return false


## Files opened and saved lately, the latest first.
func recent_files() -> PackedStringArray:
	return PackedStringArray()


## Where a file dialog starts.
func project_folder() -> String:
	return ""


## The extension a project file has, without its dot.
func file_extension() -> String:
	return "dawproject"


## A new, empty project in this one's place. Each of these says, through `said`, what went wrong.
func new_project() -> void:
	pass


func open_project(_path: String) -> void:
	pass


## Saves where it was opened from or last saved; "" asks for somewhere first.
func save_project() -> void:
	pass


func save_project_as(_path: String) -> void:
	pass


## The song written out to audio files: the mix, or a file a track (`stems`).
func render(_stems: bool) -> void:
	pass


## A track's automation of one control (DawKitAutomation.target), whole: [seconds, value, shape]
## points in order. Empty takes the lane away.
func set_automation(_id: String, _target: String, _points: Array) -> void:
	pass


## The loop's range, in seconds; its start the earlier of the two.
func set_loop_range(_start: float, _end: float) -> void:
	pass


## Bars counted in before recording starts: 0 for none.
func count_in() -> int:
	return 0


func set_count_in(_bars: int) -> void:
	pass


## Markers and regions are named by their place in DawKitProject.markers and .regions, which
## are in time order.
func add_marker(_seconds: float, _name := "") -> void:
	pass


## The marker at `index` moved to `seconds` and named `name`.
func edit_marker(_index: int, _seconds: float, _name: String) -> void:
	pass


func remove_marker(_index: int) -> void:
	pass


func add_region(_start: float, _end: float, _name := "") -> void:
	pass


func edit_region(_index: int, _start: float, _end: float, _name: String) -> void:
	pass


func remove_region(_index: int) -> void:
	pass


## The tempo's changes, whole, as DawKitProject.tempo_points ([beat, bpm, shape], the first at
## beat 0); one point is a song at one tempo.
func set_tempo_points(_points: Array) -> void:
	pass


## The time signature's changes, whole, as DawKitProject.time_signature_points ([beat,
## numerator, denominator], the first at beat 0).
func set_meter_points(_points: Array) -> void:
	pass


## Moves the clip at `clip_index` on `id` to start at `start`, on `to_id` (the same track when
## empty).
func move_clip(_id: String, _clip_index: int, _start: float, _to_id := "") -> void:
	pass


## A new empty track just after `after_id`, or at the end for "".
func add_track(_after_id := "", _name := "") -> void:
	pass


func remove_track(_id: String) -> void:
	pass


## A copy of a track, its clips and settings, just after it.
func duplicate_track(_id: String) -> void:
	pass


func rename_track(_id: String, _name: String) -> void:
	pass


func set_track_colour(_id: String, _colour: Color) -> void:
	pass


## A track, with what is in it, moved to `position` in the order after the move (0 the first),
## inside folder `parent_id` ("" for none). See DawKitProject.move_track for what is refused.
func move_track(_id: String, _position: int, _parent_id: String) -> void:
	pass


## The effects a track's chain can be given here, [id, name] each.
func effect_choices() -> Array:
	return []


## Effect `choice` (an id from effect_choices) into a track's chain before `at`, or at the end.
func add_effect(_id: String, _choice: String, _at := -1) -> void:
	pass


## Effects are named by their track and their place in its chain (DawKitTrack.effects).
func remove_effect(_id: String, _index: int) -> void:
	pass


## An effect moved to place `to_index` in `to_id`'s chain (its own track's when that is "").
func move_effect(_id: String, _index: int, _to_id: String, _to_index: int) -> void:
	pass


func set_effect_enabled(_id: String, _index: int, _on: bool) -> void:
	pass


## How much of the track's sound goes through the effect, 0..1.
func set_effect_wet(_id: String, _index: int, _wet: float) -> void:
	pass


## A control of an effect, 0..1 (DawKitEffect.values).
func set_effect_value(_id: String, _index: int, _param: int, _value: float) -> void:
	pass


## A control's value as the effect itself says it ("-12.0 dB", "250 ms"), or "" when the host does
## not know, and the interface writes a percentage.
func effect_value_text(_id: String, _index: int, _param: int) -> String:
	return ""


## The interface is showing an effect's controls: a host that has to ask its engine for them, or
## for their words, can ask now.
func watch_effect(_id: String, _index: int) -> void:
	pass


## A send from a track to `to_id`. Sends are named by their track and their place in its sends
## (DawKitTrack.sends).
func add_send(_id: String, _to_id: String) -> void:
	pass


func remove_send(_id: String, _send_index: int) -> void:
	pass


func set_send_level(_id: String, _send_index: int, _db: float) -> void:
	pass


func set_send_pan(_id: String, _send_index: int, _pan: float) -> void:
	pass


## Before the track's fader and pan, or after them.
func set_send_pre_fader(_id: String, _send_index: int, _pre: bool) -> void:
	pass


## Notes are named by their clip and their place in its notes (DawKitClip.notes, NOTE_WIDTH
## apart). Times are seconds from the clip's start.
func insert_note(_id: String, _clip_index: int, _on: float, _off: float, _pitch: int) -> void:
	pass


func delete_note(_id: String, _clip_index: int, _note: int) -> void:
	pass


## A note moved to start at `on` and sound `pitch`, keeping its length.
func move_note(_id: String, _clip_index: int, _note: int, _on: float, _pitch: int) -> void:
	pass


func set_note_end(_id: String, _clip_index: int, _note: int, _off: float) -> void:
	pass


func set_note_velocity(_id: String, _clip_index: int, _note: int, _velocity: int) -> void:
	pass


## Every note of a clip pulled onto a grid of `grid_beats` beats.
func quantize_clip(_id: String, _clip_index: int, _grid_beats: float) -> void:
	pass


## Whether a clip is selected. A selection is the host's, so another view of the same project
## (a desk, another player's) can share it.
func is_selected(_id: String, _clip_index: int) -> bool:
	return false


## Selects a clip, alone or, `additive`, as well as what is selected; additive on a selected clip
## takes it out of the selection.
func select_clip(_id: String, _clip_index: int, _additive := false) -> void:
	pass


func clear_selection() -> void:
	pass


## Every selected clip cut in two at `seconds`, both halves selected.
func split_selection(_seconds: float) -> void:
	pass


func delete_selection() -> void:
	pass


## Every selected clip copied to just after the selection, and the copies selected.
func duplicate_selection() -> void:
	pass


## A clip's edges moved to `start` and `end` (song seconds), its sound or notes left where they
## sound: trimming the front of a clip does not slide what it plays.
func trim_clip(_id: String, _clip_index: int, _start: float, _end: float) -> void:
	pass


## A clip's fade in and fade out, in seconds.
func set_clip_fades(_id: String, _clip_index: int, _fade_in: float, _fade_out: float) -> void:
	pass


func set_clip_gain(_id: String, _clip_index: int, _db: float) -> void:
	pass


func set_clip_muted(_id: String, _clip_index: int, _muted: bool) -> void:
	pass


func undo() -> void:
	pass


func redo() -> void:
	pass
