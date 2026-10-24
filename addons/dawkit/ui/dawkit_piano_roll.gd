class_name DawKitPianoRoll
extends Control

## One MIDI clip's notes on a keyboard, in place of the arrangement: opened by double-clicking the
## clip, closed by its back button or Esc.
##
## Drag on an empty row to draw a note (it snaps to the grid, Alt lets it go anywhere); drag a note
## to move it in time and pitch, or its right end to make it longer or shorter; right-click a note
## to delete it, or click it and press Delete. Under the notes, a bar per note is its velocity: drag
## it up or down. Q, or the button, pulls every note onto the grid. The wheel scrolls the keys,
## Shift and the wheel scrolls in time, Ctrl and the wheel zooms.

## Closed, by its button or Esc.
signal closed
## The pointer is over something, said in words for a status line.
signal hovered(text: String)

const BAR_HEIGHT := 32.0
const RULER_HEIGHT := 22.0
const KEYS_WIDTH := 64.0
const VELOCITY_HEIGHT := 86.0
const KEY_HEIGHT := 14.0
## How near a note's right end takes the end rather than the note.
const END := 6.0
const MIN_PIXELS_PER_SECOND := 8.0
const MAX_PIXELS_PER_SECOND := 2400.0
## The grids to draw and snap to, in beats, and what they are called.
const GRIDS: Array[float] = [1.0, 0.5, 0.25, 0.125]
const GRID_NAMES: Array[String] = ["1/4", "1/8", "1/16", "1/32"]
const NOTE_NAMES: Array[String] = ["C", "C#", "D", "D#", "E", "F", "F#", "G", "G#", "A", "A#", "B"]
const BLACK := [1, 3, 6, 8, 10]

var host: DawKitHost
## The clip shown: its track and its place on it. "" when none.
var id := ""
var index := -1
## The song second at the left edge of the notes, and how many pixels a second is.
var view_start := 0.0
var pixels_per_second := 160.0
## The pitch of the top row.
var pitch_top := 84
var grid := 0.25
## The note picked by a click, by its place in the clip's notes; -1 for none.
var selected := -1

var title: Label
var grid_button: OptionButton
var quantize_button: Button
## A note being drawn, moved or stretched: {what ("draw", "move", "end" or "velocity"), note,
## on, off, pitch (as it would be if let go now, seconds from the clip's start), grab}.
var _drag: Dictionary = {}
## Whether the view is still as it was framed: until it is zoomed or scrolled, it frames the clip
## again whenever it changes size (and it is opened before it is laid out).
var _framed := false


func _init(with_host: DawKitHost) -> void:
	host = with_host
	name = "PianoRoll"
	clip_contents = true
	custom_minimum_size = Vector2(400, 260)
	focus_mode = Control.FOCUS_ALL
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	visible = false
	var bar := HBoxContainer.new()
	bar.name = "Bar"
	bar.position = Vector2(6, 4)
	bar.add_theme_constant_override("separation", 6)
	add_child(bar)
	var back := Button.new()
	back.name = "Back"
	back.text = "< ARRANGE"
	back.focus_mode = Control.FOCUS_NONE
	back.tooltip_text = "Back to the arrangement (Esc)"
	back.pressed.connect(close)
	bar.add_child(back)
	title = Label.new()
	title.name = "Title"
	title.custom_minimum_size = Vector2(220, 0)
	title.clip_text = true
	title.add_theme_color_override("font_color", DawKitLook.ACCENT)
	bar.add_child(title)
	var grid_name := Label.new()
	grid_name.text = "GRID"
	grid_name.add_theme_color_override("font_color", DawKitLook.TEXT_DIM)
	bar.add_child(grid_name)
	grid_button = OptionButton.new()
	grid_button.name = "Grid"
	grid_button.focus_mode = Control.FOCUS_NONE
	for g in GRID_NAMES:
		grid_button.add_item(g)
	grid_button.select(GRIDS.find(grid))
	grid_button.item_selected.connect(func(i: int):
		grid = GRIDS[i]
		queue_redraw())
	bar.add_child(grid_button)
	quantize_button = Button.new()
	quantize_button.name = "Quantize"
	quantize_button.text = "QUANTIZE"
	quantize_button.focus_mode = Control.FOCUS_NONE
	quantize_button.tooltip_text = "Every note onto the grid (Q)"
	quantize_button.pressed.connect(quantize)
	bar.add_child(quantize_button)


## Shows clip `at` of track `track_id`, framed to fit, or closes for "".
func show_clip(track_id: String, at: int) -> void:
	id = track_id
	index = at
	selected = -1
	_drag = {}
	var c := clip()
	if c == null:
		id = ""
		index = -1
		if visible:
			visible = false
			closed.emit()
		return
	visible = true
	_frame(c)
	refresh()
	grab_focus()


func close() -> void:
	show_clip("", -1)


func is_open() -> bool:
	return not id.is_empty()


## The clip shown, or null.
func clip() -> DawKitClip:
	var p := host.project()
	var t := p.track(id) if p != null and not id.is_empty() else null
	if t == null or index < 0 or index >= t.clips.size() or not t.clips[index].source.is_empty():
		return null
	return t.clips[index]


## Shows the clip as the host says it is now. Closes when it is not there any more.
func refresh() -> void:
	if id.is_empty():
		return
	var c := clip()
	if c == null:
		close()
		return
	var t := host.project().track(id)
	title.text = "%s  >  %s" % [t.name if not t.name.is_empty() else t.id, c.name if not c.name.is_empty() else "clip %d" % (index + 1)]
	title.tooltip_text = title.text
	quantize_button.disabled = not editable()
	if selected >= c.note_count():
		selected = -1
	queue_redraw()


func editable() -> bool:
	var c := clip()
	return c != null and not c.locked and host.can(DawKitHost.NOTES)


func notes_top() -> float:
	return BAR_HEIGHT + RULER_HEIGHT


func notes_bottom() -> float:
	return size.y - VELOCITY_HEIGHT


func time_at(x: float) -> float:
	return view_start + (x - KEYS_WIDTH) / pixels_per_second


func x_of(seconds: float) -> float:
	return KEYS_WIDTH + (seconds - view_start) * pixels_per_second


func y_of(pitch: int) -> float:
	return notes_top() + (pitch_top - pitch) * KEY_HEIGHT


func pitch_at(y: float) -> int:
	return clampi(pitch_top - floori((y - notes_top()) / KEY_HEIGHT), 0, 127)


## The song second nearest `seconds` on the grid.
func snap(seconds: float) -> float:
	var map := host.project().tempo_map()
	return map.seconds_at(roundf(map.beat_at(seconds) / grid) * grid)


## The grid's step at `seconds`, in seconds.
func step_at(seconds: float) -> float:
	var map := host.project().tempo_map()
	var beat := map.beat_at(seconds)
	return map.seconds_at(beat + grid) - map.seconds_at(beat)


## The note under a point and the part of it there, {note, zone ("move" or "end")}; empty off
## every note.
func note_at(at: Vector2) -> Dictionary:
	var c := clip()
	if c == null or at.x < KEYS_WIDTH or at.y < notes_top() or at.y >= notes_bottom():
		return {}
	var pitch := pitch_at(at.y)
	for n in range(c.note_count() - 1, -1, -1):
		var o := n * DawKitClip.NOTE_WIDTH
		if int(c.notes[o + 2]) != pitch:
			continue
		var x0 := x_of(c.start + c.notes[o])
		var x1 := maxf(x_of(c.start + c.notes[o + 1]), x0 + 3.0)
		if at.x >= x0 and at.x <= x1 + 1.0:
			return {"note": n, "zone": "end" if x1 - at.x <= END and x1 - x0 > END * 2.0 else "move"}
	return {}


## What is under a point, in words: a note, or the pitch and the time.
func describe_at(at: Vector2) -> String:
	var c := clip()
	if c == null or at.x < KEYS_WIDTH or at.y < notes_top():
		return ""
	var p := host.project()
	if at.y >= notes_bottom():
		var v := velocity_note_at(at.x)
		return "Velocity %d  (drag up or down)" % int(c.notes[v * DawKitClip.NOTE_WIDTH + 3]) if v >= 0 else ""
	var hit := note_at(at)
	if not hit.is_empty():
		var o: int = hit["note"] * DawKitClip.NOTE_WIDTH
		return "%s, velocity %d, %s to %s  (drag to move, its end to stretch, right-click to delete)" % [pitch_name(int(c.notes[o + 2])),
				int(c.notes[o + 3]), DawKitLook.bars_text(p, c.start + c.notes[o]), DawKitLook.bars_text(p, c.start + c.notes[o + 1])]
	return "%s at %s  (drag to draw a note)" % [pitch_name(pitch_at(at.y)), DawKitLook.bars_text(p, time_at(at.x))]


## The note whose velocity bar is nearest `x`, in the velocity lane; -1 for none near.
func velocity_note_at(x: float) -> int:
	var c := clip()
	if c == null:
		return -1
	var best := -1
	var nearest := 8.0
	for n in c.note_count():
		var d := absf(x_of(c.start + c.notes[n * DawKitClip.NOTE_WIDTH]) - x)
		# The picked note wins among bars on the same spot.
		if d < nearest or (d <= nearest and n == selected):
			nearest = d
			best = n
	return best


## Every note onto the grid.
func quantize() -> void:
	if editable():
		host.quantize_clip(id, index, grid)


## The clip's place in its notes of the note at `on` sounding `pitch`, as it is after an edit
## that may have put it elsewhere in the list; -1 if it is not there.
func find_note(on: float, pitch: int) -> int:
	var c := clip()
	if c == null:
		return -1
	var best := -1
	var nearest := 0.002
	for n in c.note_count():
		var o := n * DawKitClip.NOTE_WIDTH
		if int(c.notes[o + 2]) == pitch and absf(c.notes[o] - on) <= nearest:
			nearest = absf(c.notes[o] - on)
			best = n
	return best


## Does what a key asks while it is open, and says whether it asked for anything.
func key(k: InputEventKey) -> bool:
	match k.keycode:
		KEY_ESCAPE:
			if not _drag.is_empty():
				_drag = {}
				queue_redraw()
			else:
				close()
			return true
		KEY_DELETE, KEY_BACKSPACE:
			if selected >= 0 and editable():
				host.delete_note(id, index, selected)
				selected = -1
			return true
		KEY_Q when not k.ctrl_pressed:
			quantize()
			return true
		KEY_UP, KEY_DOWN:
			var c := clip()
			if selected >= 0 and editable() and c != null:
				var o := selected * DawKitClip.NOTE_WIDTH
				var by := (12 if k.shift_pressed else 1) * (1 if k.keycode == KEY_UP else -1)
				var on := c.notes[o]
				var pitch := clampi(int(c.notes[o + 2]) + by, 0, 127)
				host.move_note(id, index, selected, on, pitch)
				selected = find_note(on, pitch)
			return true
	return false


func _gui_input(event: InputEvent) -> void:
	if not is_open():
		return
	if event is InputEventMouseButton:
		_on_button(event)
	elif event is InputEventMouseMotion:
		_on_motion(event)
	elif event is InputEventKey and event.pressed and not event.echo and key(event):
		accept_event()


func _on_button(e: InputEventMouseButton) -> void:
	if e.pressed and e.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN, MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT]:
		var notch := -1.0 if e.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_LEFT] else 1.0
		_framed = false
		if e.ctrl_pressed:
			var x := maxf(e.position.x, KEYS_WIDTH)
			var anchor := time_at(x)
			pixels_per_second = clampf(pixels_per_second * (1.25 if notch < 0.0 else 0.8), MIN_PIXELS_PER_SECOND, MAX_PIXELS_PER_SECOND)
			view_start = anchor - (x - KEYS_WIDTH) / pixels_per_second
		elif e.shift_pressed or e.button_index in [MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT]:
			view_start += notch * 80.0 / pixels_per_second
		else:
			_scroll_to(pitch_top - int(notch) * 3)
		queue_redraw()
		accept_event()
		return
	if not e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
		_release(e)
		accept_event()
		return
	if not e.pressed:
		return
	grab_focus()
	if e.position.y < BAR_HEIGHT:
		return
	var c := clip()
	if c == null:
		return
	if e.button_index == MOUSE_BUTTON_RIGHT:
		var hit := note_at(e.position)
		if not hit.is_empty() and editable():
			host.delete_note(id, index, hit["note"])
			selected = -1
		accept_event()
		return
	if e.button_index != MOUSE_BUTTON_LEFT:
		return
	accept_event()
	if e.position.y < notes_top():
		if host.can(DawKitHost.SEEK):
			host.seek(maxf(time_at(maxf(e.position.x, KEYS_WIDTH)), 0.0))
		return
	if e.position.x < KEYS_WIDTH:
		return
	if e.position.y >= notes_bottom():
		var v := velocity_note_at(e.position.x)
		if v >= 0:
			selected = v
			if editable():
				_drag = {"what": "velocity", "note": v}
				_set_velocity(e.position.y)
		queue_redraw()
		return
	var hit := note_at(e.position)
	if hit.is_empty():
		selected = -1
		if editable():
			var at := time_at(e.position.x)
			var on := (at if e.alt_pressed else snap(at)) - c.start
			if on >= 0.0 and on < c.length:
				_drag = {"what": "draw", "note": -1, "on": on, "off": minf(on + step_at(c.start + on), c.length),
						"pitch": pitch_at(e.position.y), "grab": 0.0}
		queue_redraw()
		return
	var n: int = hit["note"]
	selected = n
	if editable():
		var o := n * DawKitClip.NOTE_WIDTH
		_drag = {"what": hit["zone"], "note": n, "on": c.notes[o], "off": c.notes[o + 1],
				"pitch": int(c.notes[o + 2]), "grab": time_at(e.position.x) - c.start - c.notes[o],
				"from": [c.notes[o], c.notes[o + 1], int(c.notes[o + 2])]}
	queue_redraw()


func _on_motion(e: InputEventMouseMotion) -> void:
	if _drag.is_empty():
		var hit := note_at(e.position)
		mouse_default_cursor_shape = Control.CURSOR_HSIZE if not hit.is_empty() and hit["zone"] == "end" else Control.CURSOR_ARROW
		hovered.emit(describe_at(e.position))
		return
	var c := clip()
	if c == null:
		_drag = {}
		return
	var at := time_at(e.position.x)
	var free := e.alt_pressed
	match _drag["what"]:
		"velocity":
			_set_velocity(e.position.y)
		"move":
			var length: float = _drag["off"] - _drag["on"]
			var want := at - float(_drag["grab"])
			var on := (want if free else snap(want)) - c.start
			on = clampf(on, 0.0, maxf(c.length - length, 0.0))
			_drag["on"] = on
			_drag["off"] = on + length
			_drag["pitch"] = pitch_at(e.position.y)
		"end", "draw":
			var off := (at if free else snap(at)) - c.start
			var least: float = _drag["on"] + (0.01 if free else minf(step_at(c.start + _drag["on"]), c.length - _drag["on"]))
			_drag["off"] = clampf(off, least, c.length)
	queue_redraw()


func _release(_e: InputEventMouseButton) -> void:
	if _drag.is_empty():
		return
	var d := _drag
	_drag = {}
	queue_redraw()
	if clip() == null:
		return
	var on: float = d.get("on", 0.0)
	var pitch: int = d.get("pitch", 0)
	match d["what"]:
		"draw":
			host.insert_note(id, index, on, d["off"], pitch)
			selected = find_note(on, pitch)
		"move":
			var from: Array = d["from"]
			if not is_equal_approx(on, from[0]) or pitch != from[2]:
				host.move_note(id, index, d["note"], on, pitch)
			selected = find_note(on, pitch)
		"end":
			if not is_equal_approx(d["off"], d["from"][1]):
				host.set_note_end(id, index, d["note"], d["off"])
			selected = find_note(on, pitch)


func _set_velocity(y: float) -> void:
	var top := notes_bottom() + 6.0
	var room := VELOCITY_HEIGHT - 10.0
	var v := clampi(roundi((1.0 - (y - top) / room) * 127.0), 1, 127)
	host.set_note_velocity(id, index, _drag["note"], v)


## Frames the clip: all of it across, and its notes' pitches in the middle.
func _frame(c: DawKitClip) -> void:
	_framed = true
	var width := maxf(size.x - KEYS_WIDTH, 200.0)
	pixels_per_second = clampf(width * 0.9 / maxf(c.length, 0.1), MIN_PIXELS_PER_SECOND, MAX_PIXELS_PER_SECOND)
	view_start = c.start - width * 0.05 / pixels_per_second
	var low := 127
	var high := 0
	for n in c.note_count():
		var pitch := int(c.notes[n * DawKitClip.NOTE_WIDTH + 2])
		low = mini(low, pitch)
		high = maxi(high, pitch)
	if c.note_count() == 0:
		low = 60
		high = 72
	var rows := maxi(int((notes_bottom() - notes_top()) / KEY_HEIGHT), 12)
	_scroll_to(int((low + high) * 0.5 + rows * 0.5))


func _scroll_to(top: int) -> void:
	var rows := maxi(int((notes_bottom() - notes_top()) / KEY_HEIGHT), 1)
	pitch_top = clampi(top, mini(rows - 1, 127), 127)


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and is_open():
		if _framed and clip() != null:
			_frame(clip())
		else:
			_scroll_to(pitch_top)


static func pitch_name(pitch: int) -> String:
	return "%s%d" % [NOTE_NAMES[pitch % 12], pitch / 12 - 1]


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), DawKitLook.BACKGROUND)
	draw_rect(Rect2(0, 0, size.x, BAR_HEIGHT), DawKitLook.PANEL)
	var c := clip()
	if c == null:
		return
	var p := host.project()
	var font := get_theme_default_font()
	var top := notes_top()
	var bottom := notes_bottom()
	var right := size.x
	var t := p.track(id)
	var tint := t.colour if t.colour.a > 0.0 else DawKitLook.ACCENT
	# Rows: the black keys' rows a shade darker, a line under every B.
	for pitch in range(pitch_top, -1, -1):
		var y := y_of(pitch)
		if y >= bottom:
			break
		if pitch % 12 in BLACK:
			draw_rect(Rect2(KEYS_WIDTH, y, right - KEYS_WIDTH, KEY_HEIGHT), DawKitLook.BACKGROUND.darkened(0.25))
		if pitch % 12 == 0:
			draw_line(Vector2(KEYS_WIDTH, y + KEY_HEIGHT - 0.5), Vector2(right, y + KEY_HEIGHT - 0.5), DawKitLook.LINE, 1.0)
	# Outside the clip, dimmer.
	var cx0 := clampf(x_of(c.start), KEYS_WIDTH, right)
	var cx1 := clampf(x_of(c.end()), KEYS_WIDTH, right)
	draw_rect(Rect2(KEYS_WIDTH, top, cx0 - KEYS_WIDTH, bottom - top), Color(0, 0, 0, 0.35))
	draw_rect(Rect2(cx1, top, right - cx1, bottom - top), Color(0, 0, 0, 0.35))
	# The grid, the ruler's bars and beats.
	var map := p.tempo_map()
	var meter := p.meter()
	var from := time_at(KEYS_WIDTH)
	var to := time_at(right)
	var beat_px := pixels_per_second * 60.0 / maxf(map.bpm_at(map.beat_at(maxf(from, 0.0))), 1.0)
	draw_rect(Rect2(KEYS_WIDTH, BAR_HEIGHT, right - KEYS_WIDTH, RULER_HEIGHT), DawKitLook.PANEL.darkened(0.1))
	if beat_px * grid >= 6.0:
		var b := ceilf(map.beat_at(maxf(from, 0.0)) / grid) * grid
		var last := map.beat_at(maxf(to, 0.0))
		while b <= last:
			var x := x_of(map.seconds_at(b))
			if x >= KEYS_WIDTH and not is_equal_approx(fmod(b, 1.0), 0.0):
				draw_line(Vector2(x, top), Vector2(x, bottom), DawKitLook.LINE.darkened(0.6), 1.0)
			b += grid
	for count in meter.counts(map.beat_at(maxf(from, 0.0)), map.beat_at(maxf(to, 0.0)) + 1.0):
		var x := x_of(map.seconds_at(count[0]))
		if x < KEYS_WIDTH or x > right:
			continue
		if count[1]:
			draw_line(Vector2(x, BAR_HEIGHT + 8.0), Vector2(x, size.y), DawKitLook.LINE.lightened(0.15), 1.0)
			var where: Array = meter.position(count[0])
			draw_string(font, Vector2(x + 3.0, BAR_HEIGHT + 16.0), str(where[0]), HORIZONTAL_ALIGNMENT_LEFT, -1,
					DawKitLook.SMALL_FONT_SIZE, DawKitLook.TEXT_DIM)
		elif beat_px >= 12.0:
			draw_line(Vector2(x, BAR_HEIGHT + 14.0), Vector2(x, bottom), DawKitLook.LINE.darkened(0.25), 1.0)
	# The notes.
	for n in c.note_count():
		if not _drag.is_empty() and _drag["note"] == n and _drag["what"] in ["move", "end"]:
			continue
		var o := n * DawKitClip.NOTE_WIDTH
		_draw_note(c, c.notes[o], c.notes[o + 1], int(c.notes[o + 2]), int(c.notes[o + 3]), tint, n == selected, false)
	if not _drag.is_empty() and _drag["what"] in ["move", "end", "draw"]:
		_draw_note(c, _drag["on"], _drag["off"], _drag["pitch"], 100, tint, true, true)
		var ghost_y := y_of(_drag["pitch"])
		_say(Vector2(x_of(c.start + _drag["on"]), ghost_y - 2.0), "%s  %s" % [pitch_name(_drag["pitch"]),
				DawKitLook.bars_text(p, c.start + _drag["on"])])
	# The playhead.
	var px := x_of(host.position())
	if px >= KEYS_WIDTH and px <= right:
		draw_line(Vector2(px, BAR_HEIGHT), Vector2(px, size.y), DawKitLook.PLAYHEAD, 1.0)
	# The keys, over the rows' left ends.
	draw_rect(Rect2(0, top, KEYS_WIDTH, bottom - top), Color(0.92, 0.92, 0.9))
	for pitch in range(pitch_top, -1, -1):
		var y := y_of(pitch)
		if y >= bottom:
			break
		if pitch % 12 in BLACK:
			draw_rect(Rect2(0, y, KEYS_WIDTH * 0.62, KEY_HEIGHT), Color(0.1, 0.1, 0.11))
		else:
			draw_line(Vector2(0, y + KEY_HEIGHT - 0.5), Vector2(KEYS_WIDTH, y + KEY_HEIGHT - 0.5), Color(0.7, 0.7, 0.7), 1.0)
		if pitch % 12 == 0:
			draw_string(font, Vector2(KEYS_WIDTH - 26.0, y + KEY_HEIGHT - 3.0), pitch_name(pitch), HORIZONTAL_ALIGNMENT_LEFT, -1,
					DawKitLook.SMALL_FONT_SIZE - 1, Color(0.25, 0.25, 0.28))
	draw_line(Vector2(KEYS_WIDTH, top), Vector2(KEYS_WIDTH, bottom), DawKitLook.LINE, 1.0)
	draw_rect(Rect2(0, BAR_HEIGHT, KEYS_WIDTH, RULER_HEIGHT), DawKitLook.PANEL.darkened(0.1))
	# Velocity, a bar a note.
	draw_rect(Rect2(0, bottom, right, VELOCITY_HEIGHT), DawKitLook.PANEL)
	draw_line(Vector2(0, bottom), Vector2(right, bottom), DawKitLook.LINE, 1.0)
	draw_string(font, Vector2(6, bottom + 16.0), "VELOCITY", HORIZONTAL_ALIGNMENT_LEFT, -1, DawKitLook.SMALL_FONT_SIZE, DawKitLook.TEXT_DIM)
	var room := VELOCITY_HEIGHT - 10.0
	for n in c.note_count():
		var o := n * DawKitClip.NOTE_WIDTH
		var x := x_of(c.start + c.notes[o])
		if x < KEYS_WIDTH or x > right:
			continue
		var h := room * c.notes[o + 3] / 127.0
		var colour := DawKitLook.ACCENT if n == selected else tint.lightened(0.15)
		draw_line(Vector2(x + 1.5, bottom + 6.0 + room), Vector2(x + 1.5, bottom + 6.0 + room - h), colour, 3.0)
		draw_circle(Vector2(x + 1.5, bottom + 6.0 + room - h), 3.0, colour)
	if selected >= 0 and selected < c.note_count():
		var o := selected * DawKitClip.NOTE_WIDTH
		_say(Vector2(maxf(x_of(c.start + c.notes[o]), KEYS_WIDTH + 70.0), bottom + 16.0), "%s  vel %d" % [pitch_name(int(c.notes[o + 2])), int(c.notes[o + 3])])
	if not editable():
		draw_string(font, Vector2(right - 120.0, BAR_HEIGHT + 16.0), "read only", HORIZONTAL_ALIGNMENT_LEFT, -1,
				DawKitLook.SMALL_FONT_SIZE, DawKitLook.TEXT_DIM)


func _draw_note(c: DawKitClip, on: float, off: float, pitch: int, velocity: int, tint: Color, picked: bool, ghost: bool) -> void:
	var y := y_of(pitch)
	if y < notes_top() - KEY_HEIGHT or y >= notes_bottom():
		return
	var x0 := x_of(c.start + on)
	var x1 := maxf(x_of(c.start + off), x0 + 3.0)
	if x1 < KEYS_WIDTH or x0 > size.x:
		return
	x0 = maxf(x0, KEYS_WIDTH)
	var r := Rect2(x0, maxf(y, notes_top()) + 1.0, x1 - x0, KEY_HEIGHT - 2.0)
	var fill := tint.lerp(Color.WHITE, 0.15).darkened(0.45 * (1.0 - velocity / 127.0))
	if ghost:
		fill.a = 0.6
	draw_rect(r, fill)
	draw_rect(r, DawKitLook.ACCENT if picked else fill.darkened(0.5), false, 1.5 if picked else 1.0)


func _say(at: Vector2, text: String) -> void:
	var font := get_theme_default_font()
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, DawKitLook.SMALL_FONT_SIZE).x
	var r := Rect2(at + Vector2(0, -16), Vector2(w + 10.0, 16))
	draw_rect(r, Color(0, 0, 0, 0.75))
	draw_string(font, r.position + Vector2(5, 12), text, HORIZONTAL_ALIGNMENT_LEFT, -1, DawKitLook.SMALL_FONT_SIZE, DawKitLook.TEXT)
