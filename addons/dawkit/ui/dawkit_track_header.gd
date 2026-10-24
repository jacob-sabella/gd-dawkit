class_name DawKitTrackHeader
extends Panel

## A track's header, to the left of its lane: its colour, a fold for a folder, its name, mute,
## solo and arm, its automation lanes (A), and how many clips it has. Double-click the name to rename it; drag the header
## to move the track; right-click for the track's menu. The arrangement does the moving and the
## menu (DawKitArrange); this says what was asked.

## Taken hold of and dragged, and let go: `at` in the arrangement's own pixels.
signal dragged(id: String, at: Vector2)
signal dropped(id: String, at: Vector2)
signal menu_asked(id: String, at: Vector2)
signal fold_toggled(id: String)
signal automation_asked(id: String, at: Vector2)

const INDENT := 12.0
## How far the pointer goes before a press is a drag.
const DRAG_START := 5.0

var host: DawKitHost
var id := ""
var depth := 0
var swatch: ColorRect
var fold: Button
var name_label: Label
var mute: Button
var solo: Button
var arm: Button
var lanes: Button
var clips_label: Label
var editor: LineEdit

var _pressed_at := Vector2.INF
var _dragging := false


func _init(with_host: DawKitHost, t: DawKitTrack, at_depth: int, is_folder: bool) -> void:
	host = with_host
	id = t.id
	depth = at_depth
	name = "Header_" + t.id
	add_theme_stylebox_override("panel", DawKitLook.box(DawKitLook.PANEL, 0))
	mouse_filter = Control.MOUSE_FILTER_STOP
	swatch = ColorRect.new()
	swatch.name = "Swatch"
	swatch.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(swatch)
	var row := HBoxContainer.new()
	row.name = "Row"
	row.add_theme_constant_override("separation", 2)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(row)
	fold = Button.new()
	fold.name = "Fold"
	fold.flat = true
	fold.focus_mode = Control.FOCUS_NONE
	fold.custom_minimum_size = Vector2(16, 22)
	fold.tooltip_text = "Show or hide what is in this folder"
	fold.visible = is_folder
	fold.pressed.connect(func(): fold_toggled.emit(id))
	row.add_child(fold)
	name_label = Label.new()
	name_label.name = "Name"
	name_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_label.clip_text = true
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	name_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(name_label)
	mute = DawKitStrip.toggle(host, "M", "Mute", DawKitLook.MUTE, DawKitHost.MUTE, func(on: bool): host.set_mute(id, on))
	mute.name = "Mute"
	solo = DawKitStrip.toggle(host, "S", "Solo", DawKitLook.SOLO, DawKitHost.SOLO, func(on: bool): host.set_solo(id, on))
	solo.name = "Solo"
	arm = DawKitStrip.toggle(host, "R", "Arm to record", DawKitLook.ARM, DawKitHost.ARM, func(on: bool): host.set_armed(id, on))
	arm.name = "Arm"
	lanes = Button.new()
	lanes.name = "Lanes"
	lanes.text = "A"
	lanes.toggle_mode = true
	lanes.focus_mode = Control.FOCUS_NONE
	lanes.custom_minimum_size = Vector2(22, 22)
	lanes.tooltip_text = "Automation lanes"
	lanes.pressed.connect(func(): automation_asked.emit(id, lanes.global_position + Vector2(0, lanes.size.y)))
	for b in [mute, solo, arm, lanes]:
		row.add_child(b)
	clips_label = Label.new()
	clips_label.name = "Clips"
	clips_label.add_theme_font_size_override("font_size", DawKitLook.SMALL_FONT_SIZE)
	clips_label.add_theme_color_override("font_color", DawKitLook.TEXT_DIM)
	clips_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(clips_label)
	show_track(t)


func show_track(t: DawKitTrack) -> void:
	swatch.color = t.colour
	name_label.text = t.name if not t.name.is_empty() else t.id
	name_label.tooltip_text = name_label.text
	mute.set_pressed_no_signal(t.mute)
	solo.set_pressed_no_signal(t.solo)
	arm.set_pressed_no_signal(t.armed)
	var n := t.clips.size()
	clips_label.text = "no clips" if n == 0 else ("1 clip" if n == 1 else "%d clips" % n)


func show_fold(open: bool) -> void:
	fold.text = "-" if open else "+"


## Lays its parts out for a lane `height` tall and `width` wide.
func lay_out(width: float, height: float) -> void:
	size = Vector2(width, height)
	var left := depth * INDENT
	swatch.position = Vector2(left, 0)
	swatch.size = Vector2(5, height)
	var row := get_node("Row") as Control
	row.position = Vector2(left + 10.0, minf(8.0, (height - 24.0) * 0.5))
	row.size = Vector2(width - left - 16.0, 24.0)
	clips_label.position = Vector2(left + 12.0, 34.0)
	clips_label.visible = height >= 52.0
	if editor != null:
		editor.position = name_label.global_position - global_position
		editor.size = Vector2(name_label.size.x + 4.0, 24.0)


## A box over the name to type a new one in. Enter keeps it, Esc or clicking away does not.
func start_rename() -> void:
	if not host.can(DawKitHost.TRACKS) or editor != null:
		return
	editor = LineEdit.new()
	editor.name = "Rename"
	editor.text = name_label.text
	editor.select_all_on_focus = true
	add_child(editor)
	editor.position = name_label.global_position - global_position
	editor.size = Vector2(maxf(name_label.size.x, 80.0), 24.0)
	editor.text_submitted.connect(func(text: String): finish_rename(text))
	editor.focus_exited.connect(func(): finish_rename(""))
	editor.gui_input.connect(func(e: InputEvent):
		if e is InputEventKey and e.pressed and e.keycode == KEY_ESCAPE:
			finish_rename("")
			accept_event())
	editor.grab_focus()
	editor.select_all()


## Ends a rename, asking for `text` as the name unless it is empty or unchanged.
func finish_rename(text: String) -> void:
	if editor == null:
		return
	var e := editor
	editor = null
	e.queue_free()
	text = text.strip_edges()
	if not text.is_empty() and text != name_label.text:
		host.rename_track(id, text)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var b := event as InputEventMouseButton
		if b.button_index == MOUSE_BUTTON_LEFT and b.pressed and b.double_click:
			start_rename()
			accept_event()
		elif b.button_index == MOUSE_BUTTON_LEFT and b.pressed:
			_pressed_at = b.position
			_dragging = false
			accept_event()
		elif b.button_index == MOUSE_BUTTON_LEFT and not b.pressed:
			if _dragging:
				dropped.emit(id, position + b.position)
			_pressed_at = Vector2.INF
			_dragging = false
			accept_event()
		elif b.button_index == MOUSE_BUTTON_RIGHT and b.pressed:
			menu_asked.emit(id, b.global_position)
			accept_event()
	elif event is InputEventMouseMotion and _pressed_at != Vector2.INF:
		var m := event as InputEventMouseMotion
		if not _dragging and m.position.distance_to(_pressed_at) >= DRAG_START and host.can(DawKitHost.TRACK_ORDER):
			_dragging = true
		if _dragging:
			dragged.emit(id, position + m.position)
			accept_event()
