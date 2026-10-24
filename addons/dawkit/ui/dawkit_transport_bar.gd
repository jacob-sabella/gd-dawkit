class_name DawKitTransportBar
extends PanelContainer

## Along the top: back to the start, play, stop, record, loop and the click; where the song is,
## in bars and in time; the tempo; undo and redo; and which view is showing.

signal view_asked(view: int)

var host: DawKitHost
var start_button: Button
var play_button: Button
var stop_button: Button
var record_button: Button
var loop_button: Button
var click_button: Button
var file_menu: MenuButton
## Bars counted in before recording: off, 1 or 2.
var count_in: OptionButton
var bars_label: Label
var clock_label: Label
var tempo: SpinBox
var undo_button: Button
var redo_button: Button
var view_buttons: Array[Button] = []
var title_label: Label


## What the FILE menu holds. A recent file is FILE_RECENT plus its place in host.recent_files().
enum { FILE_NEW, FILE_OPEN, FILE_SAVE, FILE_SAVE_AS, FILE_RENDER, FILE_RENDER_STEMS, FILE_RECENT = 100 }

## An item of the FILE menu picked: one of FILE_*.
signal file_asked(item: int)


func _init(with_host: DawKitHost) -> void:
	host = with_host
	name = "TransportBar"
	add_theme_stylebox_override("panel", DawKitLook.box(DawKitLook.PANEL, 0))
	# Too wide for the window (big text, a narrow window), it scrolls rather than pushing the
	# whole interface wider than the screen.
	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_SHOW_NEVER
	add_child(scroll)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(row)

	file_menu = MenuButton.new()
	file_menu.name = "File"
	file_menu.text = "FILE"
	file_menu.flat = false
	file_menu.focus_mode = Control.FOCUS_NONE
	file_menu.about_to_popup.connect(_fill_file_menu)
	file_menu.get_popup().id_pressed.connect(func(item: int): file_asked.emit(item))
	row.add_child(file_menu)

	title_label = Label.new()
	title_label.custom_minimum_size = Vector2(150, 0)
	title_label.clip_text = true
	title_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title_label.add_theme_color_override("font_color", DawKitLook.TEXT_DIM)
	row.add_child(title_label)

	start_button = _button("|<", "Back to the start (Home)", DawKitHost.SEEK)
	start_button.pressed.connect(func(): host.seek(0.0))
	play_button = _button("PLAY", "Play (Space)", DawKitHost.TRANSPORT, true, DawKitLook.PLAY)
	play_button.toggled.connect(func(on: bool): host.play() if on else host.stop())
	stop_button = _button("STOP", "Stop (Space)", DawKitHost.TRANSPORT)
	stop_button.pressed.connect(func(): host.stop())
	record_button = _button("REC", "Record (Ctrl+R)", DawKitHost.RECORD, true, DawKitLook.ARM)
	record_button.toggled.connect(func(on: bool): host.record() if on else host.stop())
	loop_button = _button("LOOP", "Loop (L)", DawKitHost.LOOP, true, DawKitLook.LOOP)
	loop_button.toggled.connect(func(on: bool): host.set_looping(on))
	click_button = _button("CLICK", "Metronome (C)", DawKitHost.METRONOME, true, DawKitLook.ACCENT)
	click_button.toggled.connect(func(on: bool): host.set_metronome(on))
	for b in [start_button, play_button, stop_button, record_button, loop_button, click_button]:
		row.add_child(b)
	count_in = OptionButton.new()
	count_in.name = "CountIn"
	count_in.focus_mode = Control.FOCUS_NONE
	count_in.tooltip_text = "Bars counted in before recording"
	for text in ["NO COUNT", "COUNT 1", "COUNT 2"]:
		count_in.add_item(text)
	count_in.disabled = not host.can(DawKitHost.COUNT_IN)
	count_in.item_selected.connect(func(i: int): host.set_count_in(i))
	row.add_child(count_in)

	row.add_child(_gap())
	var readout := PanelContainer.new()
	readout.add_theme_stylebox_override("panel", DawKitLook.box(DawKitLook.BACKGROUND, 3, DawKitLook.LINE))
	var clocks := HBoxContainer.new()
	clocks.add_theme_constant_override("separation", 14)
	readout.add_child(clocks)
	bars_label = Label.new()
	bars_label.custom_minimum_size = Vector2(86 * DawKitLook.text_scale, 0)
	bars_label.add_theme_font_size_override("font_size", roundi(17 * DawKitLook.text_scale))
	bars_label.add_theme_color_override("font_color", DawKitLook.ACCENT)
	clocks.add_child(bars_label)
	clock_label = Label.new()
	clock_label.custom_minimum_size = Vector2(86 * DawKitLook.text_scale, 0)
	clock_label.add_theme_font_size_override("font_size", roundi(17 * DawKitLook.text_scale))
	clocks.add_child(clock_label)
	row.add_child(readout)

	var bpm := Label.new()
	bpm.text = "BPM"
	bpm.add_theme_color_override("font_color", DawKitLook.TEXT_DIM)
	row.add_child(bpm)
	tempo = SpinBox.new()
	tempo.min_value = 1.0
	tempo.max_value = 960.0
	tempo.step = 0.1
	tempo.custom_minimum_size = Vector2(84, 0)
	tempo.editable = host.can(DawKitHost.TEMPO)
	tempo.value_changed.connect(func(v: float): host.set_tempo(v))
	row.add_child(tempo)

	row.add_child(_gap())
	undo_button = _button("UNDO", "Undo (Ctrl+Z)", DawKitHost.UNDO)
	undo_button.pressed.connect(func(): host.undo())
	redo_button = _button("REDO", "Redo (Ctrl+Shift+Z)", DawKitHost.UNDO)
	redo_button.pressed.connect(func(): host.redo())
	row.add_child(undo_button)
	row.add_child(redo_button)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(spacer)
	var group := ButtonGroup.new()
	for view in DawKitStudio.VIEW_NAMES.size():
		var b := Button.new()
		b.text = DawKitStudio.VIEW_NAMES[view]
		b.toggle_mode = true
		b.button_group = group
		b.focus_mode = Control.FOCUS_NONE
		b.tooltip_text = "%s (F%d)" % [DawKitStudio.VIEW_NAMES[view].capitalize(), view + 5]
		var v := view
		b.pressed.connect(func(): view_asked.emit(v))
		row.add_child(b)
		view_buttons.append(b)


func _fill_file_menu() -> void:
	var menu := file_menu.get_popup()
	for child in menu.get_children():
		menu.remove_child(child)
		child.queue_free()
	menu.clear()
	var files := host.can(DawKitHost.FILES)
	menu.add_item("New project", FILE_NEW, KEY_MASK_CTRL | KEY_N)
	menu.add_item("Open...", FILE_OPEN, KEY_MASK_CTRL | KEY_O)
	var recent := PopupMenu.new()
	recent.name = "Recent"
	var paths := host.recent_files()
	for i in paths.size():
		recent.add_item(paths[i].get_file(), FILE_RECENT + i)
		recent.set_item_tooltip(i, paths[i])
	recent.id_pressed.connect(func(item: int): file_asked.emit(item))
	menu.add_child(recent)
	menu.add_submenu_node_item("Open recent", recent)
	menu.set_item_disabled(menu.item_count - 1, paths.is_empty() or not files)
	menu.add_separator()
	menu.add_item("Save", FILE_SAVE, KEY_MASK_CTRL | KEY_S)
	menu.add_item("Save as...", FILE_SAVE_AS, KEY_MASK_CTRL | KEY_MASK_SHIFT | KEY_S)
	menu.add_separator()
	menu.add_item("Render the mix", FILE_RENDER)
	menu.add_item("Render a file a track", FILE_RENDER_STEMS)
	for item in [FILE_NEW, FILE_OPEN, FILE_SAVE_AS]:
		menu.set_item_disabled(menu.get_item_index(item), not files)
	menu.set_item_disabled(menu.get_item_index(FILE_SAVE), not host.can(DawKitHost.SAVE))
	for item in [FILE_RENDER, FILE_RENDER_STEMS]:
		menu.set_item_disabled(menu.get_item_index(item), not host.can(DawKitHost.RENDER))


## Shows the transport as the host says it is.
func show_transport() -> void:
	var p := host.project()
	play_button.set_pressed_no_signal(host.is_playing())
	record_button.set_pressed_no_signal(host.is_recording())
	if p != null:
		loop_button.set_pressed_no_signal(p.loop_on)
		click_button.set_pressed_no_signal(p.metronome)
		count_in.select(clampi(host.count_in(), 0, count_in.item_count - 1))
		if not tempo.get_line_edit().has_focus():
			tempo.set_value_no_signal(p.tempo)
		title_label.text = ("* " if host.is_dirty() else "") + p.title
		title_label.tooltip_text = p.title + ("\n" + host.project_file() if not host.project_file().is_empty() else "") \
				+ ("\nUnsaved changes" if host.is_dirty() else "")
	var undo := host.undo_name()
	undo_button.tooltip_text = "Undo %s (Ctrl+Z)" % undo if not undo.is_empty() else "Nothing to undo"


func show_position() -> void:
	var p := host.project()
	var at := host.position()
	bars_label.text = DawKitLook.bars_text(p, at) if p != null else ""
	clock_label.text = DawKitLook.clock_text(at)


func show_view(view: int) -> void:
	for i in view_buttons.size():
		view_buttons[i].set_pressed_no_signal(i == view)


func _button(text: String, tip: String, edit: StringName, toggle := false, lit := DawKitLook.ACCENT) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	b.toggle_mode = toggle
	b.custom_minimum_size = Vector2(44, 28)
	b.disabled = not host.can(edit)
	if toggle:
		b.add_theme_stylebox_override("pressed", DawKitLook.box(lit, 3))
		b.add_theme_stylebox_override("hover_pressed", DawKitLook.box(lit.lightened(0.1), 3))
		b.add_theme_color_override("font_pressed_color", Color(0.08, 0.08, 0.09))
		b.add_theme_color_override("font_hover_pressed_color", Color(0.08, 0.08, 0.09))
	return b


func _gap() -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(10, 0)
	return c
