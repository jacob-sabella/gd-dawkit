class_name DawKitRuler
extends Control

## The ruler over the arrangement's lanes, in three rows: markers and regions along the top, the
## tempo's and time signature's changes under them, and the bars, with the loop's range.
##
## Bars: click to put the playhead there (pulled onto the arrangement's grid when it is near a
## line, unless Alt is held), drag to set the loop's range, drag either end of the range to move
## it; every time here is pulled onto the grid the same way. Markers and regions: double-click the top row
## for a marker, drag one to move it (a region by its middle or either end), double-click one to
## rename it. Changes: double-click a change to set it, or the row for a tempo change there; drag a
## change along the song. Right-click anywhere on it for the rest: a region from the loop's range,
## a time signature change, the loop set to a region, delete.

const HEIGHT := 56.0
## Where the markers' row ends, and the changes' row.
const MARK_ROW := 18.0
const CHANGE_ROW := 35.0
## How near a marker, a region's end, a change or the loop's end takes it.
const GRAB := 6.0
## How far a press on the bars moves before it is a loop being drawn and not a seek.
const DRAG_START := 4.0
const REGION := Color(0.55, 0.45, 0.88)
const TEMPO := Color(0.45, 0.78, 0.86)
const METER := Color(0.82, 0.6, 0.9)
enum { MENU_ADD_MARKER, MENU_ADD_REGION, MENU_TEMPO, MENU_METER, MENU_RENAME, MENU_DELETE, MENU_LOOP, MENU_EDIT }

var arrange: DawKitArrange
var host: DawKitHost
## Whether a press on the bars is moving the playhead.
var scrubbing := false
## What is being dragged: {kind (see hit_at), index, grab (seconds from where it was taken to its
## start), from, to (seconds, as it would be if let go now), x (where the press was)}.
var _drag: Dictionary = {}
var _menu: PopupMenu
var _menu_hit: Dictionary = {}
var _menu_time := 0.0
## A marker's or region's name being typed: {kind, index}.
var editor: LineEdit
var _editing: Dictionary = {}
## The tempo or signature change being set: {kind ("tempo" or "meter"), index (-1 for a new one),
## beat}.
var change_editor: PopupPanel
var _change: Dictionary = {}
var _bpm: SpinBox
var _numerator: SpinBox
var _denominator: OptionButton


func _init(of: DawKitArrange) -> void:
	arrange = of
	host = of.host
	name = "Ruler"
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP


func time_at(x: float) -> float:
	return arrange.time_at(x + DawKitArrange.HEADER_WIDTH)


func x_of(seconds: float) -> float:
	return arrange.x_of(seconds) - DawKitArrange.HEADER_WIDTH


## What is under a point: {kind, index, ...}. Kinds: "marker", "region", "region_start" and
## "region_end" (its ends), "marks" (the top row, empty there); "tempo" and "meter" (a change),
## "changes" (the row, empty there); "loop_start", "loop_end", and "bars".
func hit_at(at: Vector2) -> Dictionary:
	var p := host.project()
	if p == null:
		return {}
	var font := get_theme_default_font()
	if at.y < MARK_ROW:
		for i in range(p.markers.size() - 1, -1, -1):
			var x := x_of(p.markers[i].time)
			var w := font.get_string_size(_marker_name(i), HORIZONTAL_ALIGNMENT_LEFT, -1, DawKitLook.SMALL_FONT_SIZE - 1).x
			if at.x >= x - GRAB * 0.5 and at.x <= x + 10.0 + w:
				return {"kind": "marker", "index": i}
		for i in range(p.regions.size() - 1, -1, -1):
			var r := p.regions[i]
			var x0 := x_of(r.start)
			var x1 := x_of(r.end)
			if absf(at.x - x0) <= GRAB and x1 - x0 > GRAB * 3.0:
				return {"kind": "region_start", "index": i}
			if absf(at.x - x1) <= GRAB and x1 - x0 > GRAB * 3.0:
				return {"kind": "region_end", "index": i}
			if at.x >= x0 and at.x <= x1:
				return {"kind": "region", "index": i}
		return {"kind": "marks"}
	if at.y < CHANGE_ROW:
		var map := p.tempo_map()
		var meters := _meter_points(p)
		for i in range(meters.size() - 1, -1, -1):
			var x := x_of(map.seconds_at(meters[i][0])) + _meter_offset(p, meters[i][0])
			if at.x >= x - 2.0 and at.x <= x + 30.0:
				return {"kind": "meter", "index": i}
		var tempos := _tempo_points(p)
		for i in range(tempos.size() - 1, -1, -1):
			var x := x_of(map.seconds_at(tempos[i][0]))
			if at.x >= x - GRAB and at.x <= x + 56.0:
				return {"kind": "tempo", "index": i}
		return {"kind": "changes"}
	if p.loop_end > p.loop_start:
		if absf(at.x - x_of(p.loop_start)) <= GRAB:
			return {"kind": "loop_start"}
		if absf(at.x - x_of(p.loop_end)) <= GRAB:
			return {"kind": "loop_end"}
	return {"kind": "bars"}


## What is under a point of the ruler, in words.
func describe_at(at: Vector2) -> String:
	var p := host.project()
	if p == null:
		return ""
	var hit := hit_at(at)
	var where := DawKitLook.bars_text(p, maxf(time_at(at.x), 0.0))
	match hit.get("kind", ""):
		"marker":
			var m := p.markers[hit["index"]]
			return "Marker %s at %s  (drag to move, double-click to rename, right-click for more)" % [_marker_name(hit["index"]), DawKitLook.bars_text(p, m.time)]
		"region", "region_start", "region_end":
			var r := p.regions[hit["index"]]
			return "Region %s, %s to %s  (drag it or its ends, double-click to rename)" % [r.name if not r.name.is_empty() else str(hit["index"] + 1),
					DawKitLook.bars_text(p, r.start), DawKitLook.bars_text(p, r.end)]
		"tempo":
			var pt: Array = _tempo_points(p)[hit["index"]]
			return "Tempo %s bpm from %s  (double-click to set, drag to move)" % [_bpm_text(pt[1]), DawKitLook.bars_text(p, p.tempo_map().seconds_at(pt[0]))]
		"meter":
			var pt: Array = _meter_points(p)[hit["index"]]
			return "Time signature %d/%d from %s  (double-click to set, drag to move)" % [pt[1], pt[2], DawKitLook.bars_text(p, p.tempo_map().seconds_at(pt[0]))]
		"marks":
			return "%s  (double-click for a marker)" % where
		"changes":
			return "%s  (double-click for a tempo change, right-click for a time signature)" % where
		"loop_start", "loop_end":
			return "The loop, %s to %s  (drag to move this end)" % [DawKitLook.bars_text(p, p.loop_start), DawKitLook.bars_text(p, p.loop_end)]
	return "%s  (click to go there, drag for the loop)" % where


## `seconds` pulled onto the arrangement's grid when a line is near it (DawKitArrange.magnet), or
## `seconds` itself when free.
func snap(seconds: float, free := false) -> float:
	return maxf(seconds if free else arrange.magnet(seconds), 0.0)


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var b := event as InputEventMouseButton
		if b.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN, MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT, MOUSE_BUTTON_MIDDLE]:
			# The wheel and the middle button do what they do over the lanes.
			var passed := b.duplicate() as InputEventMouseButton
			passed.position = b.position + position
			passed.shift_pressed = b.shift_pressed or not (b.ctrl_pressed or b.alt_pressed)
			arrange._gui_input(passed)
			accept_event()
			return
		if b.pressed and b.button_index == MOUSE_BUTTON_RIGHT:
			open_menu(b.position, b.global_position)
		elif b.button_index == MOUSE_BUTTON_LEFT and b.pressed:
			_press(b)
		elif b.button_index == MOUSE_BUTTON_LEFT:
			_release(b)
		accept_event()
	elif event is InputEventMouseMotion:
		var m := event as InputEventMouseMotion
		if arrange._panning:
			var passed := m.duplicate() as InputEventMouseMotion
			passed.position = m.position + position
			arrange._gui_input(passed)
		elif not _drag.is_empty():
			_drag_to(m.position, m.alt_pressed)
		else:
			var hit := hit_at(m.position)
			var kind: String = hit.get("kind", "")
			arrange.hovered.emit(describe_at(m.position))
			mouse_default_cursor_shape = Control.CURSOR_HSIZE if kind in ["loop_start", "loop_end", "region_start", "region_end"] \
					else (Control.CURSOR_POINTING_HAND if kind in ["marker", "region", "tempo", "meter"] else Control.CURSOR_ARROW)
		accept_event()


func _press(e: InputEventMouseButton) -> void:
	var p := host.project()
	if p == null:
		return
	arrange.grab_focus()
	var hit := hit_at(e.position)
	var kind: String = hit.get("kind", "")
	var t := time_at(e.position.x)
	if e.double_click:
		_drag = {}
		scrubbing = false
		match kind:
			"marker", "region", "region_start", "region_end":
				start_rename("marker" if kind == "marker" else "region", hit["index"])
			"marks":
				if host.can(DawKitHost.MARKERS):
					host.add_marker(snap(t, e.alt_pressed))
			"tempo", "meter":
				open_change(kind, hit["index"], 0.0)
			"changes":
				open_change("tempo", -1, p.tempo_map().beat_at(snap(t, e.alt_pressed)))
		return
	match kind:
		"marker":
			if host.can(DawKitHost.MARKERS):
				var m := p.markers[hit["index"]]
				_drag = {"kind": kind, "index": hit["index"], "grab": t - m.time, "from": m.time, "to": m.time, "x": e.position.x}
		"region", "region_start", "region_end":
			if host.can(DawKitHost.MARKERS):
				var r := p.regions[hit["index"]]
				_drag = {"kind": kind, "index": hit["index"], "grab": t - r.start, "from": r.start, "to": r.end, "x": e.position.x}
		"tempo", "meter":
			if hit["index"] > 0 and host.can(DawKitHost.TEMPO_MAP):
				var at := p.tempo_map().seconds_at(_points(kind, p)[hit["index"]][0])
				_drag = {"kind": kind, "index": hit["index"], "grab": t - at, "from": at, "to": at, "x": e.position.x}
		"loop_start", "loop_end":
			if host.can(DawKitHost.LOOP_RANGE):
				_drag = {"kind": kind, "from": p.loop_start, "to": p.loop_end, "x": e.position.x}
		"bars":
			scrubbing = host.can(DawKitHost.SEEK)
			if scrubbing:
				host.seek(snap(t, e.alt_pressed))
			_drag = {"kind": "bars", "from": snap(t, e.alt_pressed), "to": snap(t, e.alt_pressed), "x": e.position.x}
	queue_redraw()


func _drag_to(at: Vector2, free: bool) -> void:
	var t := time_at(at.x)
	var kind: String = _drag["kind"]
	match kind:
		"bars", "loop_new":
			if kind == "bars" and absf(at.x - _drag["x"]) >= DRAG_START and host.can(DawKitHost.LOOP_RANGE):
				_drag["kind"] = "loop_new"
				scrubbing = false
			if _drag["kind"] == "loop_new":
				_drag["to"] = snap(t, free)
			elif scrubbing:
				host.seek(snap(t, free))
		"marker", "tempo", "meter":
			_drag["to"] = snap(t - float(_drag["grab"]), free)
		"region":
			var length: float = _drag["to"] - _drag["from"]
			var start := snap(t - float(_drag["grab"]), free)
			_drag["from"] = start
			_drag["to"] = start + length
		"region_start", "loop_start":
			_drag["from"] = minf(snap(t, free), _drag["to"] - 0.01)
		"region_end", "loop_end":
			_drag["to"] = maxf(snap(t, free), _drag["from"] + 0.01)
	queue_redraw()


func _release(e: InputEventMouseButton) -> void:
	scrubbing = false
	if _drag.is_empty():
		return
	var d := _drag
	_drag = {}
	queue_redraw()
	var p := host.project()
	if p == null:
		return
	var moved := absf(e.position.x - float(d["x"])) >= 1.0
	match d["kind"]:
		"loop_new", "loop_start", "loop_end":
			host.set_loop_range(d["from"], d["to"])
		"marker":
			if moved and d["index"] < p.markers.size():
				host.edit_marker(d["index"], d["to"], p.markers[d["index"]].name)
		"region", "region_start", "region_end":
			if moved and d["index"] < p.regions.size():
				host.edit_region(d["index"], d["from"], d["to"], p.regions[d["index"]].name)
		"tempo":
			if moved:
				var points := _tempo_points(p)
				var map := p.tempo_map()
				var beat := roundf(map.beat_at(d["to"]))
				var point: Array = points.pop_at(d["index"])
				var tempo := DawKitTempoMap.from_array(points)
				tempo.set_point(maxf(beat, 1.0), point[1], point[2])
				host.set_tempo_points(tempo.to_array())
		"meter":
			if moved:
				var points := _meter_points(p)
				var point: Array = points.pop_at(d["index"])
				var meter := DawKitMeter.from_array(points, p.time_signature.x, p.time_signature.y)
				var beat := _bar_beat(p, p.tempo_map().beat_at(d["to"]))
				meter.set_point(maxf(beat, 0.0), point[1], point[2])
				host.set_meter_points(meter.to_array())


## The beat of the bar line nearest `beat`.
func _bar_beat(p: DawKitProject, beat: float) -> float:
	var meter := p.meter()
	return meter.beat_of_bar(roundf(meter.bar_at(beat)))


## The tempo's points, at least the one at the start.
static func _tempo_points(p: DawKitProject) -> Array:
	return p.tempo_points.duplicate(true) if not p.tempo_points.is_empty() else [[0.0, p.tempo, DawKitTempoMap.HOLD]]


static func _meter_points(p: DawKitProject) -> Array:
	return p.time_signature_points.duplicate(true) if not p.time_signature_points.is_empty() \
			else [[0.0, p.time_signature.x, p.time_signature.y]]


static func _points(kind: String, p: DawKitProject) -> Array:
	return _tempo_points(p) if kind == "tempo" else _meter_points(p)


## How far right of its place a time signature's label is drawn: past a tempo's label at the
## same beat, so both can be read and taken.
func _meter_offset(p: DawKitProject, beat: float) -> float:
	for pt in _tempo_points(p):
		if absf(float(pt[0]) - beat) < 0.01:
			return 7.0 + get_theme_default_font().get_string_size(_bpm_text(pt[1]) + " bpm", HORIZONTAL_ALIGNMENT_LEFT, -1,
					DawKitLook.SMALL_FONT_SIZE - 1).x + 8.0
	return 3.0


func _marker_name(index: int) -> String:
	var m := host.project().markers[index]
	return m.name if not m.name.is_empty() else str(index + 1)


func open_menu(at: Vector2, global_at: Vector2) -> void:
	var p := host.project()
	if p == null:
		return
	if _menu == null:
		_menu = PopupMenu.new()
		_menu.name = "SongMenu"
		add_child(_menu)
		_menu.id_pressed.connect(_on_menu)
	_menu.clear()
	_menu_hit = hit_at(at)
	_menu_time = time_at(at.x)
	var kind: String = _menu_hit.get("kind", "")
	var marks := host.can(DawKitHost.MARKERS)
	var changes := host.can(DawKitHost.TEMPO_MAP)
	if kind == "marker" and marks:
		_menu.add_item("Rename marker", MENU_RENAME)
		_menu.add_item("Delete marker", MENU_DELETE)
		_menu.add_separator()
	elif kind.begins_with("region") and marks:
		_menu.add_item("Rename region", MENU_RENAME)
		if host.can(DawKitHost.LOOP_RANGE):
			_menu.add_item("Loop this region", MENU_LOOP)
		_menu.add_item("Delete region", MENU_DELETE)
		_menu.add_separator()
	elif kind in ["tempo", "meter"] and changes:
		_menu.add_item("Set this change...", MENU_EDIT)
		if _menu_hit["index"] > 0:
			_menu.add_item("Delete this change", MENU_DELETE)
		_menu.add_separator()
	if marks:
		_menu.add_item("Add marker here", MENU_ADD_MARKER)
		_menu.add_item("Add region over the loop", MENU_ADD_REGION)
		_menu.set_item_disabled(_menu.get_item_index(MENU_ADD_REGION), p.loop_end <= p.loop_start)
	if changes:
		_menu.add_item("Tempo change here...", MENU_TEMPO)
		_menu.add_item("Time signature change here...", MENU_METER)
	if _menu.item_count == 0:
		return
	_menu.position = Vector2i(global_at)
	_menu.reset_size()
	_menu.popup()


func _on_menu(item: int) -> void:
	var p := host.project()
	if p == null:
		return
	var kind: String = _menu_hit.get("kind", "")
	var index: int = _menu_hit.get("index", -1)
	match item:
		MENU_ADD_MARKER:
			host.add_marker(snap(_menu_time))
		MENU_ADD_REGION:
			host.add_region(p.loop_start, p.loop_end)
		MENU_TEMPO:
			open_change("tempo", -1, roundf(p.tempo_map().beat_at(_menu_time)))
		MENU_METER:
			open_change("meter", -1, _bar_beat(p, p.tempo_map().beat_at(_menu_time)))
		MENU_EDIT:
			open_change(kind, index, 0.0)
		MENU_RENAME:
			start_rename("marker" if kind == "marker" else "region", index)
		MENU_LOOP:
			if index < p.regions.size():
				host.set_loop_range(p.regions[index].start, p.regions[index].end)
		MENU_DELETE:
			if kind == "marker":
				host.remove_marker(index)
			elif kind.begins_with("region"):
				host.remove_region(index)
			elif kind in ["tempo", "meter"]:
				remove_change(kind, index)


## The change `index` of the tempo's ("tempo") or the time signature's ("meter") taken out; the
## first stays.
func remove_change(kind: String, index: int) -> void:
	var p := host.project()
	var points := _points(kind, p)
	if index <= 0 or index >= points.size():
		return
	points.remove_at(index)
	if kind == "tempo":
		host.set_tempo_points(points)
	else:
		host.set_meter_points(points)


## A box over a marker's or region's name to type a new one in. Enter keeps it; Esc or clicking
## away does not.
func start_rename(kind: String, index: int) -> void:
	var p := host.project()
	if not host.can(DawKitHost.MARKERS) or p == null:
		return
	var list: Array = p.markers if kind == "marker" else p.regions
	if index < 0 or index >= list.size():
		return
	finish_rename(null)
	_editing = {"kind": kind, "index": index}
	editor = LineEdit.new()
	editor.name = "Rename"
	editor.text = list[index].name
	editor.placeholder_text = "Name"
	editor.select_all_on_focus = true
	add_child(editor)
	var x := x_of(list[index].time if kind == "marker" else list[index].start)
	editor.position = Vector2(clampf(x + 6.0, 0.0, maxf(size.x - 160.0, 0.0)), 0.0)
	editor.size = Vector2(160, MARK_ROW + 4.0)
	editor.text_submitted.connect(func(text: String): finish_rename(text))
	editor.focus_exited.connect(func(): finish_rename(null))
	editor.gui_input.connect(func(e: InputEvent):
		if e is InputEventKey and e.pressed and e.keycode == KEY_ESCAPE:
			finish_rename(null)
			accept_event())
	editor.grab_focus()
	editor.select_all()


## Ends a rename, naming it `text` unless that is null (given up).
func finish_rename(text: Variant) -> void:
	if editor == null:
		return
	var e := editor
	editor = null
	e.queue_free()
	var editing := _editing
	_editing = {}
	var p := host.project()
	if text == null or p == null:
		return
	var called := str(text).strip_edges()
	var index: int = editing["index"]
	if editing["kind"] == "marker" and index < p.markers.size():
		host.edit_marker(index, p.markers[index].time, called)
	elif editing["kind"] == "region" and index < p.regions.size():
		host.edit_region(index, p.regions[index].start, p.regions[index].end, called)


## A small box to set a tempo ("tempo") or time signature ("meter") change: change `index`, or a
## new one at `beat` for -1.
func open_change(kind: String, index: int, beat: float) -> void:
	var p := host.project()
	if p == null or not host.can(DawKitHost.TEMPO_MAP):
		return
	var points := _points(kind, p)
	if index >= points.size():
		return
	if change_editor == null:
		_build_change_editor()
	_change = {"kind": kind, "index": index, "beat": float(points[index][0]) if index >= 0 else beat}
	var at: Array = points[index] if index >= 0 else []
	var map := p.tempo_map()
	(change_editor.get_node("Box/Title") as Label).text = "%s at %s" % ["Tempo" if kind == "tempo" else "Time signature",
			DawKitLook.bars_text(p, map.seconds_at(_change["beat"]))]
	_bpm.get_parent().visible = kind == "tempo"
	_numerator.get_parent().visible = kind == "meter"
	if kind == "tempo":
		_bpm.value = float(at[1]) if index >= 0 else map.bpm_at(beat)
	else:
		var sig := p.meter().signature_at(_change["beat"])
		_numerator.value = int(at[1]) if index >= 0 else sig.x
		var den := int(at[2]) if index >= 0 else sig.y
		_denominator.select(maxi([1, 2, 4, 8, 16, 32, 64].find(den), 0))
	(change_editor.get_node("Box/Buttons/Delete") as Button).visible = index > 0
	change_editor.reset_size()
	var x := x_of(map.seconds_at(_change["beat"]))
	change_editor.position = Vector2i(get_screen_position() + Vector2(clampf(x, 0.0, maxf(size.x - 220.0, 0.0)), HEIGHT))
	change_editor.popup()


## Sets the change being edited as the box says.
func apply_change() -> void:
	var p := host.project()
	if p == null or _change.is_empty():
		return
	var kind: String = _change["kind"]
	var points := _points(kind, p)
	var index: int = _change["index"]
	if kind == "tempo":
		var map := DawKitTempoMap.from_array(points)
		var shape: Variant = points[index][2] if index >= 0 else DawKitTempoMap.HOLD
		map.set_point(_change["beat"], _bpm.value, shape)
		host.set_tempo_points(map.to_array())
	else:
		var meter := DawKitMeter.from_array(points, p.time_signature.x, p.time_signature.y)
		meter.set_point(_change["beat"], int(_numerator.value), [1, 2, 4, 8, 16, 32, 64][_denominator.selected])
		host.set_meter_points(meter.to_array())
	change_editor.hide()


func _build_change_editor() -> void:
	change_editor = PopupPanel.new()
	change_editor.name = "ChangeEditor"
	change_editor.add_theme_stylebox_override("panel", DawKitLook.box(DawKitLook.PANEL_LIGHT, 4, DawKitLook.LINE))
	add_child(change_editor)
	var box := VBoxContainer.new()
	box.name = "Box"
	box.add_theme_constant_override("separation", 6)
	change_editor.add_child(box)
	var title := Label.new()
	title.name = "Title"
	title.add_theme_color_override("font_color", DawKitLook.ACCENT)
	box.add_child(title)
	var tempo_row := HBoxContainer.new()
	tempo_row.name = "Tempo"
	box.add_child(tempo_row)
	var bpm := Label.new()
	bpm.text = "BPM"
	tempo_row.add_child(bpm)
	_bpm = SpinBox.new()
	_bpm.min_value = 1.0
	_bpm.max_value = 960.0
	_bpm.step = 0.1
	_bpm.custom_minimum_size = Vector2(100, 0)
	tempo_row.add_child(_bpm)
	var meter_row := HBoxContainer.new()
	meter_row.name = "Meter"
	box.add_child(meter_row)
	_numerator = SpinBox.new()
	_numerator.min_value = 1
	_numerator.max_value = 64
	_numerator.step = 1
	meter_row.add_child(_numerator)
	var over := Label.new()
	over.text = " / "
	meter_row.add_child(over)
	_denominator = OptionButton.new()
	for d in [1, 2, 4, 8, 16, 32, 64]:
		_denominator.add_item(str(d))
	meter_row.add_child(_denominator)
	var buttons := HBoxContainer.new()
	buttons.name = "Buttons"
	box.add_child(buttons)
	var ok := Button.new()
	ok.name = "Set"
	ok.text = "SET"
	ok.pressed.connect(apply_change)
	buttons.add_child(ok)
	var delete := Button.new()
	delete.name = "Delete"
	delete.text = "DELETE"
	delete.pressed.connect(func():
		remove_change(_change["kind"], _change["index"])
		change_editor.hide())
	buttons.add_child(delete)
	var cancel := Button.new()
	cancel.text = "CANCEL"
	cancel.pressed.connect(func(): change_editor.hide())
	buttons.add_child(cancel)


func _draw() -> void:
	var p := host.project()
	draw_rect(Rect2(Vector2.ZERO, size), DawKitLook.PANEL)
	if p == null:
		return
	var font := get_theme_default_font()
	var small := DawKitLook.SMALL_FONT_SIZE
	var right := size.x
	var map := p.tempo_map()
	var meter := p.meter()
	var from := maxf(time_at(0.0), 0.0)
	var to := time_at(right)
	draw_rect(Rect2(0, MARK_ROW, right, CHANGE_ROW - MARK_ROW), DawKitLook.PANEL.darkened(0.12))
	draw_line(Vector2(0, MARK_ROW - 0.5), Vector2(right, MARK_ROW - 0.5), DawKitLook.LINE.darkened(0.3))
	draw_line(Vector2(0, CHANGE_ROW - 0.5), Vector2(right, CHANGE_ROW - 0.5), DawKitLook.LINE.darkened(0.3))
	draw_line(Vector2(0, size.y - 0.5), Vector2(right, size.y - 0.5), DawKitLook.LINE)
	# Bars.
	var beat_px := arrange.pixels_per_second * 60.0 / maxf(map.bpm_at(map.beat_at(from)), 1.0)
	var bar_every := 1
	while beat_px * 4.0 * bar_every < 48.0 and bar_every < 256:
		bar_every *= 2
	for count in meter.counts(map.beat_at(from), map.beat_at(to) + 1.0):
		var x := x_of(map.seconds_at(count[0]))
		if x < 0.0 or x > right:
			continue
		if count[1]:
			var bar: int = meter.position(count[0])[0]
			if (bar - 1) % bar_every != 0:
				continue
			draw_line(Vector2(x, CHANGE_ROW + 3.0), Vector2(x, size.y), DawKitLook.TEXT_DIM, 1.0)
			draw_string(font, Vector2(x + 3.0, CHANGE_ROW + 14.0), str(bar), HORIZONTAL_ALIGNMENT_LEFT, -1, small, DawKitLook.TEXT)
		elif beat_px >= 10.0 and bar_every == 1:
			draw_line(Vector2(x, size.y - 6.0), Vector2(x, size.y), DawKitLook.TEXT_DIM.darkened(0.3), 1.0)
	# The loop's range, or the one being drawn.
	var loop := Vector2(p.loop_start, p.loop_end)
	if not _drag.is_empty() and _drag["kind"] in ["loop_new", "loop_start", "loop_end"]:
		loop = Vector2(minf(_drag["from"], _drag["to"]), maxf(_drag["from"], _drag["to"]))
	if loop.y > loop.x:
		var lx := x_of(loop.x)
		var rx := x_of(loop.y)
		var lit := DawKitLook.LOOP if p.loop_on else DawKitLook.LOOP.darkened(0.45)
		draw_rect(Rect2(lx, CHANGE_ROW, rx - lx, size.y - CHANGE_ROW), Color(lit, 0.14))
		draw_rect(Rect2(lx, size.y - 6.0, rx - lx, 5.0), lit)
		for x in [lx, rx]:
			draw_line(Vector2(x, CHANGE_ROW), Vector2(x, size.y), lit, 2.0)
	# Regions, then markers over them.
	for i in p.regions.size():
		var r := p.regions[i]
		var a := r.start
		var b := r.end
		if not _drag.is_empty() and _drag["kind"].begins_with("region") and _drag["index"] == i:
			a = _drag["from"]
			b = _drag["to"]
		var x0 := x_of(a)
		var x1 := x_of(b)
		if x1 < 0.0 or x0 > right:
			continue
		draw_rect(Rect2(x0, 2.0, x1 - x0, MARK_ROW - 4.0), Color(REGION, 0.35))
		draw_rect(Rect2(x0, 2.0, x1 - x0, MARK_ROW - 4.0), REGION, false, 1.0)
		if not r.name.is_empty():
			draw_string(font, Vector2(maxf(x0, 0.0) + 4.0, MARK_ROW - 5.0), r.name, HORIZONTAL_ALIGNMENT_LEFT,
					maxf(x1 - maxf(x0, 0.0) - 8.0, 1.0), small - 1, DawKitLook.TEXT)
	for i in p.markers.size():
		var at := p.markers[i].time
		if not _drag.is_empty() and _drag["kind"] == "marker" and _drag["index"] == i:
			at = _drag["to"]
		var x := x_of(at)
		if x < -120.0 or x > right:
			continue
		draw_rect(Rect2(x, 2, 4, MARK_ROW - 4.0), DawKitLook.ACCENT)
		draw_string(font, Vector2(x + 7.0, MARK_ROW - 5.0), _marker_name(i), HORIZONTAL_ALIGNMENT_LEFT, 120, small - 1, DawKitLook.ACCENT)
	# Changes: the tempo's on the left of the row, the time signature's under it on the right.
	var tempos := _tempo_points(p)
	for i in tempos.size():
		var at := map.seconds_at(tempos[i][0])
		if not _drag.is_empty() and _drag["kind"] == "tempo" and _drag["index"] == i:
			at = _drag["to"]
		var x := x_of(at)
		if x < -60.0 or x > right:
			continue
		draw_colored_polygon(PackedVector2Array([Vector2(x, MARK_ROW + 2.0), Vector2(x + 5.0, MARK_ROW + 2.0), Vector2(x, MARK_ROW + 8.0)]), TEMPO)
		draw_string(font, Vector2(x + 7.0, MARK_ROW + 12.0), _bpm_text(tempos[i][1]) + " bpm", HORIZONTAL_ALIGNMENT_LEFT, -1, small - 1, TEMPO)
	var meters := _meter_points(p)
	for i in meters.size():
		var at := map.seconds_at(meters[i][0])
		if not _drag.is_empty() and _drag["kind"] == "meter" and _drag["index"] == i:
			at = _drag["to"]
		var x := x_of(at) + _meter_offset(p, meters[i][0])
		if x < -40.0 or x > right:
			continue
		draw_string(font, Vector2(x, MARK_ROW + 12.0), "%d/%d" % [meters[i][1], meters[i][2]], HORIZONTAL_ALIGNMENT_LEFT, -1, small - 1, METER)
	# What a drag would make it, said.
	if not _drag.is_empty() and _drag["kind"] not in ["bars"]:
		var at: float = _drag["to"] if _drag["kind"] in ["marker", "tempo", "meter", "region_end", "loop_end"] else _drag["from"]
		var text := DawKitLook.bars_text(p, at)
		var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, small).x
		var box := Rect2(clampf(x_of(at) + 6.0, 0.0, maxf(right - w - 10.0, 0.0)), CHANGE_ROW + 2.0, w + 10.0, 16.0)
		draw_rect(box, Color(0, 0, 0, 0.8))
		draw_string(font, box.position + Vector2(5, 12), text, HORIZONTAL_ALIGNMENT_LEFT, -1, small, DawKitLook.TEXT)
	# The playhead.
	var px := x_of(host.position())
	if px >= 0.0 and px <= right:
		draw_line(Vector2(px, 0), Vector2(px, size.y), DawKitLook.PLAYHEAD, 1.0)
		draw_colored_polygon(PackedVector2Array([Vector2(px - 5, CHANGE_ROW), Vector2(px + 5, CHANGE_ROW), Vector2(px, CHANGE_ROW + 7.0)]), DawKitLook.PLAYHEAD)


static func _bpm_text(bpm: float) -> String:
	return str(roundi(bpm)) if is_equal_approx(bpm, roundf(bpm)) else "%.1f" % bpm
