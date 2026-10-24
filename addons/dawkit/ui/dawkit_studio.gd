class_name DawKitStudio
extends PanelContainer

## dawkit's 2D interface, whole: the transport along the top, the arrangement, and the mixer.
##
## It is drawn from a DawKitHost and asks it for every change, so it knows nothing of who owns
## the project; `DawKitStudio.new(DawKitProjectHost.new(project))` is a working one on its own.
## Changes the host reports are gathered and shown once a frame, however many arrive.
##
## Keys, while it is showing: Space plays and stops, Ctrl+R records, Home goes back to the
## start, L loops, C clicks, Ctrl+Z undoes and Ctrl+Shift+Z (or Ctrl+Y) redoes, and F5, F6 and F7
## show the arrangement, the mixer, or both. For the selected clips: S splits them at the playhead,
## Delete deletes them, Ctrl+D duplicates them, Ctrl+A selects every clip and Esc none. Ctrl+T adds a track.
## Ctrl+N starts a project, Ctrl+O opens one, Ctrl+S saves and Ctrl+Shift+S saves as (FILE has
## them, recent files and rendering); the status line along the bottom says what the host said.
## Double-clicking a MIDI clip puts its notes in a piano roll where the arrangement was, until Esc.

## The window's title as it should read now: the project's name, a * for unsaved changes.
signal title_changed(text: String)

## Every key, as the key list (F1) shows them: Reaper's where Reaper has one.
const KEY_LIST := [
	["Space", "Play and stop"], ["Ctrl+R", "Record"], ["R  or  L", "Loop on and off"], ["C", "Metronome"],
	["Home  /  End", "To the start, to the end"], ["=  /  -", "Zoom in, out"],
	["M", "A marker at the playhead"], ["Ctrl+Z", "Undo"], ["Ctrl+Shift+Z  or  Ctrl+Y", "Redo"],
	["S", "Split the selected clips at the playhead"], ["Delete", "Delete the selected clips (or the picked note)"],
	["Ctrl+D", "Duplicate the selected clips"], ["Ctrl+A", "Select every clip"], ["Esc", "Select nothing; out of the piano roll"],
	["Ctrl+T", "A new track"], ["Ctrl+N  /  Ctrl+O", "A new project, open one"], ["Ctrl+S  /  Ctrl+Shift+S", "Save, save as"],
	["F5  /  F6  /  F7", "The arrangement, the mixer, both"], ["Q", "Quantize (in the piano roll)"],
	["Up  /  Down", "Transpose the picked note (Shift: an octave)"], ["F1", "This list"],
]

enum View { ARRANGE, MIXER, BOTH }
## How long the status line keeps something said before going back to the project's state.
const SAID_SECONDS := 6.0
const VIEW_NAMES: Array[String] = ["ARRANGE", "MIXER", "BOTH"]
const VIEW_KEYS := [KEY_F5, KEY_F6, KEY_F7]

var host: DawKitHost
var transport: DawKitTransportBar
var arrange: DawKitArrange
var piano_roll: DawKitPianoRoll
var mixer: DawKitMixer
var effect_panel: DawKitEffectPanel
var view := View.BOTH
var status: Label
var status_file: Label
## The file dialog and the "discard unsaved changes?" box, made when first wanted.
var file_dialog: FileDialog
var confirm: ConfirmationDialog
var key_list: AcceptDialog
var _said_until := 0.0
var _title := ""
## What was asked of the FILE menu and is waiting for an answer from a dialog.
var _pending: Callable

var _split: VSplitContainer
var _mixer_panel: PanelContainer
## The view the piano roll took over from, to go back to when it closes; -1 when it is not open.
var _view_before_notes := -1
var _rebuild := true
var _transport_dirty := true
var _clips_dirty := false
var _dirty: Dictionary = {}


func _init(with_host: DawKitHost) -> void:
	host = with_host
	name = "DawKitStudio"
	theme = DawKitLook.theme()
	add_theme_stylebox_override("panel", DawKitLook.box(DawKitLook.BACKGROUND, 0))
	set_anchors_preset(Control.PRESET_FULL_RECT)
	focus_mode = Control.FOCUS_ALL

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 0)
	add_child(column)
	transport = DawKitTransportBar.new(host)
	transport.view_asked.connect(show_view)
	transport.file_asked.connect(file_item)
	column.add_child(transport)
	var body := HBoxContainer.new()
	body.name = "Body"
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 0)
	column.add_child(body)
	_split = VSplitContainer.new()
	_split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_split.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(_split)
	effect_panel = DawKitEffectPanel.new(host)
	body.add_child(effect_panel)
	var top := VBoxContainer.new()
	top.name = "Top"
	top.size_flags_vertical = Control.SIZE_EXPAND_FILL
	top.add_theme_constant_override("separation", 0)
	_split.add_child(top)
	arrange = DawKitArrange.new(host)
	arrange.size_flags_vertical = Control.SIZE_EXPAND_FILL
	top.add_child(arrange)
	piano_roll = DawKitPianoRoll.new(host)
	top.add_child(piano_roll)
	arrange.clip_opened.connect(open_clip)
	piano_roll.closed.connect(func():
		arrange.visible = true
		if _view_before_notes >= 0:
			show_view(_view_before_notes)
			_view_before_notes = -1
		arrange.grab_focus())
	var bottom := PanelContainer.new()
	bottom.name = "MixerPanel"
	bottom.add_theme_stylebox_override("panel", DawKitLook.box(DawKitLook.PANEL.darkened(0.15), 0))
	bottom.custom_minimum_size = Vector2(0, 330)
	mixer = DawKitMixer.new(host)
	mixer.effect_opened.connect(effect_panel.show_effect)
	# Strips taller than the room for them (big text) scroll, rather than pushing the status line
	# off the bottom of the window.
	var tall := ScrollContainer.new()
	tall.name = "Tall"
	tall.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	mixer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	mixer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	tall.add_child(mixer)
	bottom.add_child(tall)
	_mixer_panel = bottom
	_split.add_child(bottom)
	var line := PanelContainer.new()
	line.name = "StatusLine"
	line.add_theme_stylebox_override("panel", DawKitLook.box(DawKitLook.PANEL, 0))
	column.add_child(line)
	var status_row := HBoxContainer.new()
	line.add_child(status_row)
	status = Label.new()
	status.name = "Said"
	status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status.clip_text = true
	status.add_theme_font_size_override("font_size", DawKitLook.SMALL_FONT_SIZE)
	status_row.add_child(status)
	status_file = Label.new()
	status_file.name = "File"
	status_file.add_theme_font_size_override("font_size", DawKitLook.SMALL_FONT_SIZE)
	status_file.add_theme_color_override("font_color", DawKitLook.TEXT_DIM)
	status_row.add_child(status_file)
	host.said.connect(say)
	arrange.hovered.connect(show_hover)
	piano_roll.hovered.connect(show_hover)

	host.project_changed.connect(func(): _rebuild = true)
	host.track_changed.connect(func(id: String):
		_dirty[id] = true
		_transport_dirty = true)
	host.transport_changed.connect(func(): _transport_dirty = true)
	host.clips_changed.connect(func():
		_clips_dirty = true
		_transport_dirty = true)
	show_view(view)


## Shows the arrangement, the mixer, or both, one above the other.
func show_view(which: int) -> void:
	view = which as View
	arrange.get_parent().visible = view != View.MIXER
	_mixer_panel.visible = view != View.ARRANGE
	transport.show_view(view)


## Edits clip `index` of track `id`'s notes in the piano roll, in place of the arrangement.
## The piano roll has the height to itself, the mixer coming back when it closes.
func open_clip(id: String, index: int) -> void:
	var was := view
	piano_roll.show_clip(id, index)
	arrange.visible = not piano_roll.is_open()
	if piano_roll.is_open():
		if _view_before_notes < 0:
			_view_before_notes = was
		show_view(View.ARRANGE)


## Brings everything up to what the host says now, at once rather than at the next frame.
func refresh() -> void:
	if _rebuild:
		_rebuild = false
		_dirty.clear()
		_transport_dirty = true
		arrange.rebuild()
		mixer.rebuild()
		effect_panel.refresh()
		piano_roll.refresh()
	if _dirty.has(effect_panel.id):
		effect_panel.refresh()
	for id in _dirty:
		arrange.show_track(id)
		mixer.show_track(id)
	_dirty.clear()
	if _clips_dirty:
		_clips_dirty = false
		arrange.show_clips()
		piano_roll.refresh()
	if _transport_dirty:
		_transport_dirty = false
		transport.show_transport()
		arrange.queue_redraw()
		_show_state()
	if piano_roll.is_open() and host.is_playing():
		piano_roll.queue_redraw()


## The key list: every key and what it does.
func show_keys() -> void:
	if key_list == null:
		key_list = AcceptDialog.new()
		key_list.name = "Keys"
		key_list.title = "Keys"
		var grid := GridContainer.new()
		grid.name = "Grid"
		grid.columns = 2
		grid.add_theme_constant_override("h_separation", 24)
		for pair in KEY_LIST:
			var keys := Label.new()
			keys.text = pair[0]
			keys.add_theme_color_override("font_color", DawKitLook.ACCENT)
			grid.add_child(keys)
			var does := Label.new()
			does.text = pair[1]
			grid.add_child(does)
		key_list.add_child(grid)
		add_child(key_list)
	key_list.popup_centered()


## What the pointer is over, on the status line while nothing has just been said.
func show_hover(text: String) -> void:
	if _said_until > 0.0:
		return
	status.text = text
	status.add_theme_color_override("font_color", DawKitLook.TEXT_DIM)


## Puts `text` on the status line for a while.
func say(text: String) -> void:
	status.text = text
	status.add_theme_color_override("font_color", DawKitLook.TEXT)
	_said_until = Time.get_ticks_msec() / 1000.0 + SAID_SECONDS


## The window's title for the project as it is: "* Song - file.dawproject".
func title_text() -> String:
	var p := host.project()
	var named := p.title if p != null and not p.title.is_empty() else "Untitled"
	var file := host.project_file().get_file()
	return ("* " if host.is_dirty() else "") + named + (" - " + file if not file.is_empty() and file.get_basename() != named else "")


func _show_state() -> void:
	var file := host.project_file()
	if file.is_empty():
		status_file.text = "not saved to a file yet"
	else:
		status_file.text = "%s  %s" % [file.get_file(), "unsaved changes" if host.is_dirty() else "saved"]
	status_file.tooltip_text = file
	var t := title_text()
	if t != _title:
		_title = t
		title_changed.emit(t)


## Does what the FILE menu asked (DawKitTransportBar.FILE_*).
func file_item(item: int) -> void:
	match item:
		DawKitTransportBar.FILE_NEW:
			_unless_unsaved(func(): host.new_project())
		DawKitTransportBar.FILE_OPEN:
			_unless_unsaved(func(): _ask_file(FileDialog.FILE_MODE_OPEN_FILE, func(path: String): host.open_project(path)))
		DawKitTransportBar.FILE_SAVE:
			if host.project_file().is_empty():
				file_item(DawKitTransportBar.FILE_SAVE_AS)
			else:
				host.save_project()
		DawKitTransportBar.FILE_SAVE_AS:
			_ask_file(FileDialog.FILE_MODE_SAVE_FILE, func(path: String): host.save_project_as(path))
		DawKitTransportBar.FILE_RENDER:
			host.render(false)
		DawKitTransportBar.FILE_RENDER_STEMS:
			host.render(true)
		_:
			var recent := host.recent_files()
			var i := item - DawKitTransportBar.FILE_RECENT
			if i >= 0 and i < recent.size():
				var path := recent[i]
				_unless_unsaved(func(): host.open_project(path))


## Does `then`, after asking whether to throw away unsaved changes if there are any.
func _unless_unsaved(then: Callable) -> void:
	if not host.is_dirty():
		then.call()
		return
	if confirm == null:
		confirm = ConfirmationDialog.new()
		confirm.name = "Discard"
		confirm.title = "Unsaved changes"
		confirm.dialog_text = "This project has changes that are not saved. Throw them away?"
		confirm.ok_button_text = "Throw them away"
		confirm.confirmed.connect(func():
			if _pending.is_valid():
				_pending.call())
		add_child(confirm)
	_pending = then
	confirm.popup_centered()


## A file dialog for a project file, opening or saving; `then` is given the path picked.
func _ask_file(mode: FileDialog.FileMode, then: Callable) -> void:
	if file_dialog == null:
		file_dialog = FileDialog.new()
		file_dialog.name = "Files"
		file_dialog.access = FileDialog.ACCESS_FILESYSTEM
		file_dialog.use_native_dialog = false
		file_dialog.size = Vector2i(760, 480)
		file_dialog.file_selected.connect(func(path: String):
			if _pending.is_valid():
				_pending.call(path))
		add_child(file_dialog)
	file_dialog.file_mode = mode
	file_dialog.title = "Open a project" if mode == FileDialog.FILE_MODE_OPEN_FILE else "Save the project as"
	file_dialog.filters = PackedStringArray(["*.%s ; Projects" % host.file_extension()])
	var folder := host.project_file().get_base_dir() if not host.project_file().is_empty() else host.project_folder()
	if not folder.is_empty():
		file_dialog.current_dir = folder
	if mode == FileDialog.FILE_MODE_SAVE_FILE and host.project() != null:
		file_dialog.current_file = host.project().title.validate_filename() + "." + host.file_extension()
	_pending = then
	file_dialog.popup_centered()


func _process(_delta: float) -> void:
	if not is_visible_in_tree():
		return
	refresh()
	if _said_until > 0.0 and Time.get_ticks_msec() / 1000.0 > _said_until:
		_said_until = 0.0
		status.add_theme_color_override("font_color", DawKitLook.TEXT_DIM)
	transport.show_position()
	if mixer.is_visible_in_tree():
		mixer.show_levels()


func _unhandled_key_input(event: InputEvent) -> void:
	if not is_visible_in_tree() or not (event is InputEventKey) or not event.pressed or event.echo:
		return
	if get_viewport().gui_get_focus_owner() is LineEdit:
		return
	if _key(event as InputEventKey):
		get_viewport().set_input_as_handled()


## Selects every clip in the project.
func select_all() -> void:
	var p := host.project()
	if p == null:
		return
	var first := true
	for t in p.tracks:
		for i in t.clips.size():
			host.select_clip(t.id, i, not first)
			first = false


## Does what a key asks, and says whether it asked for anything.
func _key(k: InputEventKey) -> bool:
	if piano_roll.is_open() and piano_roll.key(k):
		return true
	match k.keycode:
		KEY_N when k.ctrl_pressed:
			file_item(DawKitTransportBar.FILE_NEW)
			return true
		KEY_O when k.ctrl_pressed:
			file_item(DawKitTransportBar.FILE_OPEN)
			return true
		KEY_S when k.ctrl_pressed:
			file_item(DawKitTransportBar.FILE_SAVE_AS if k.shift_pressed else DawKitTransportBar.FILE_SAVE)
			return true
		KEY_SPACE:
			if host.can(DawKitHost.TRANSPORT):
				host.stop() if host.is_playing() else host.play()
			return true
		KEY_R when k.ctrl_pressed:
			if host.can(DawKitHost.RECORD):
				host.stop() if host.is_recording() else host.record()
			return true
		KEY_HOME:
			if host.can(DawKitHost.SEEK):
				host.seek(0.0)
			return true
		KEY_F1:
			show_keys()
			return true
		KEY_END:
			var p := host.project()
			if host.can(DawKitHost.SEEK) and p != null:
				var last := p.length
				for t in p.tracks:
					for c in t.clips:
						last = maxf(last, c.end())
				host.seek(last)
			return true
		KEY_EQUAL, KEY_KP_ADD, KEY_MINUS, KEY_KP_SUBTRACT:
			var into := k.keycode in [KEY_EQUAL, KEY_KP_ADD]
			var w := arrange.size.x - DawKitArrange.HEADER_WIDTH
			var centre := arrange.view_start + w * 0.5 / arrange.pixels_per_second
			var pps := clampf(arrange.pixels_per_second * (1.25 if into else 0.8), DawKitArrange.MIN_PIXELS_PER_SECOND, DawKitArrange.MAX_PIXELS_PER_SECOND)
			arrange.set_view(centre - w * 0.5 / pps, pps)
			return true
		KEY_M when not k.ctrl_pressed:
			if host.can(DawKitHost.MARKERS):
				host.add_marker(host.position())
			return true
		KEY_L, KEY_R when not k.ctrl_pressed:
			if host.can(DawKitHost.LOOP) and host.project() != null:
				host.set_looping(not host.project().loop_on)
			return true
		KEY_C when not k.ctrl_pressed:
			if host.can(DawKitHost.METRONOME) and host.project() != null:
				host.set_metronome(not host.project().metronome)
			return true
		KEY_Z when k.ctrl_pressed:
			if host.can(DawKitHost.UNDO):
				host.redo() if k.shift_pressed else host.undo()
			return true
		KEY_Y when k.ctrl_pressed:
			if host.can(DawKitHost.UNDO):
				host.redo()
			return true
		KEY_S when not k.ctrl_pressed:
			if host.can(DawKitHost.EDIT_CLIPS):
				host.split_selection(host.position())
			return true
		KEY_DELETE, KEY_BACKSPACE:
			if host.can(DawKitHost.EDIT_CLIPS):
				host.delete_selection()
			return true
		KEY_D when k.ctrl_pressed:
			if host.can(DawKitHost.EDIT_CLIPS):
				host.duplicate_selection()
			return true
		KEY_A when k.ctrl_pressed:
			if host.can(DawKitHost.SELECT):
				select_all()
			return true
		KEY_T when k.ctrl_pressed:
			if host.can(DawKitHost.TRACKS):
				host.add_track("")
			return true
		KEY_ESCAPE:
			if host.can(DawKitHost.SELECT):
				host.clear_selection()
			return true
	var v := VIEW_KEYS.find(k.keycode)
	if v >= 0:
		show_view(v)
		return true
	return false
