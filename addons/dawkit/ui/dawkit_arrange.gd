class_name DawKitArrange
extends Control

## The arrangement: a ruler of bars along the top, a lane per track with its clips, the track's
## header to the left of its lane, and the playhead.
##
## Click the ruler or an empty stretch of lane to put the playhead there. Drag a clip to move it,
## to another track too; it snaps to the beat, and Alt lets it go anywhere. The wheel scrolls the
## tracks, Shift and the wheel scrolls the song, Ctrl and the wheel zooms about the pointer, and
## the middle button drags the view. Double-click a MIDI clip to edit its notes (clip_opened). While the song plays the view turns the page to keep the
## playhead in it.

## The pointer is over something, said in words for a status line ("" over nothing).
signal hovered(text: String)
## A MIDI clip double-clicked, to have its notes edited.
signal clip_opened(id: String, index: int)

## The ruler (DawKitRuler.HEIGHT): markers and regions, the tempo's changes, and the bars.
const RULER_HEIGHT := 56.0
const HEADER_WIDTH := 210.0
const LANE_HEIGHT := 62.0
const MIN_LANE_HEIGHT := 30.0
const MAX_LANE_HEIGHT := 200.0
const MIN_PIXELS_PER_SECOND := 2.0
const MAX_PIXELS_PER_SECOND := 1200.0
## Indent per folder level in a track's header.
const INDENT := 12.0
## A clip's name bar, where its fade and gain handles are; how near an edge trims it; how near a
## handle takes it.
const BAND := 14.0
const EDGE := 6.0
const HANDLE := 6.0
const MIN_CLIP_SECONDS := 0.01
## An automation lane's height, under its track's clips; how near a point takes it.
const AUTO_HEIGHT := 54.0
const POINT := 6.0
const CURSORS := {"trim_left": Control.CURSOR_HSIZE, "trim_right": Control.CURSOR_HSIZE,
		"fade_in": Control.CURSOR_POINTING_HAND, "fade_out": Control.CURSOR_POINTING_HAND, "gain": Control.CURSOR_VSIZE}
enum { MENU_SPLIT, MENU_DUPLICATE, MENU_DELETE, MENU_MUTE, MENU_GAIN, MENU_FADES }
enum { TRACK_NEW, TRACK_DUPLICATE, TRACK_RENAME, TRACK_INTO, TRACK_OUT, TRACK_DELETE }
## The colours a track can be given from its menu.
const PALETTE: Array[Color] = [Color(0.86, 0.3, 0.3), Color(0.93, 0.55, 0.25), Color(0.9, 0.78, 0.3),
		Color(0.55, 0.78, 0.3), Color(0.3, 0.72, 0.5), Color(0.28, 0.7, 0.75), Color(0.32, 0.55, 0.88),
		Color(0.5, 0.42, 0.88), Color(0.75, 0.4, 0.85), Color(0.88, 0.4, 0.62), Color(0.62, 0.52, 0.42),
		Color(0.55, 0.57, 0.6)]

var host: DawKitHost
## The song second at the left edge of the lanes, and how many pixels a second is.
var view_start := 0.0
var pixels_per_second := 48.0
## How tall every track's lane is.
var lane_height := LANE_HEIGHT
## Folders shown shut, by id: what is in them is not shown.
var collapsed: Dictionary = {}
## The automation lanes shown under each track: id -> [target, ...] (DawKitAutomation.target).
var lanes_shown: Dictionary = {}
## Pixels the tracks are scrolled down by.
var scroll_y := 0.0
## Whether the view turns the page to keep a playing song's playhead in sight.
var follow := true

var headers: Dictionary = {}  # id -> Control
var _order: Array[String] = []
## Where each row starts below the ruler, unscrolled, and one past the last: the end of them all.
var _tops := PackedFloat64Array([0.0])
## An automation point being drawn or dragged: {id, target, points (the lane as it would be if let
## go now), index (the point), top (the lane's)}.
var _auto: Dictionary = {}
var _auto_menu: PopupMenu
## A clip being dragged: {zone (see zone_at), id, index, clip, ghost (the clip as it would be
## if let go now), grab (seconds into the clip it was taken at), y, to (the track it is over)}.
var _drag: Dictionary = {}
## A box being drawn to select with: {from, to, additive}.
var _box: Dictionary = {}
var ruler: DawKitRuler
var _menu: PopupMenu
var _track_menu: PopupMenu
var _colours: PopupMenu
var _add_button: Button
## A track being dragged by its header: {id, gap (the row it would land before)}.
var _track_drag: Dictionary = {}
var _panning := false
var _scrubbing := false
var _drawn_position := -1.0


func _init(with_host: DawKitHost) -> void:
	host = with_host
	name = "Arrange"
	clip_contents = true
	focus_mode = Control.FOCUS_CLICK
	mouse_filter = Control.MOUSE_FILTER_STOP
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	custom_minimum_size = Vector2(400, 160)
	_add_button = Button.new()
	_add_button.name = "AddTrack"
	_add_button.text = "+"
	_add_button.tooltip_text = "A new track at the end (Ctrl+T)"
	_add_button.focus_mode = Control.FOCUS_NONE
	_add_button.size = Vector2(26, 24)
	_add_button.disabled = not host.can(DawKitHost.TRACKS)
	_add_button.pressed.connect(func(): host.add_track(""))
	add_child(_add_button)
	ruler = DawKitRuler.new(self)
	ruler.position = Vector2(HEADER_WIDTH, 0)
	add_child(ruler)


## Lays out a header per track again, for a project whose tracks changed.
func rebuild() -> void:
	for id in headers:
		headers[id].queue_free()
		remove_child(headers[id])
	headers.clear()
	_order.clear()
	var p := host.project()
	if p != null:
		for t in p.tracks:
			if collapsed.has(t.id) and p.children_of(t.id).is_empty():
				collapsed.erase(t.id)
		for t in p.tracks:
			if _hidden(p, t):
				continue
			_order.append(t.id)
			var h := DawKitTrackHeader.new(host, t, p.depth_of(t), not p.children_of(t.id).is_empty())
			h.show_fold(not collapsed.has(t.id))
			h.dragged.connect(_on_header_dragged)
			h.dropped.connect(_on_header_dropped)
			h.menu_asked.connect(open_track_menu)
			h.fold_toggled.connect(toggle_fold)
			h.automation_asked.connect(open_automation_menu)
			headers[t.id] = h
			add_child(h)
	if _add_button != null:
		move_child(_add_button, -1)
	move_child(ruler, -1)
	_lay_rows()
	_clamp_scroll()
	_place_headers()
	queue_redraw()


## Works out where every row starts, for the lanes shown under each.
func _lay_rows() -> void:
	_tops.resize(_order.size() + 1)
	var at := 0.0
	for row in _order.size():
		_tops[row] = at
		at += row_height(row)
	_tops[_order.size()] = at


## A row's whole height: its clips' lane and the automation lanes under it.
func row_height(row: int) -> float:
	if row < 0 or row >= _order.size():
		return lane_height
	return lane_height + lanes_of(_order[row]).size() * AUTO_HEIGHT


func lanes_of(id: String) -> Array:
	return lanes_shown.get(id, [])


## Shows or hides the automation lane of `target` under track `id`.
func show_lane(id: String, target: String, on := true) -> void:
	var shown: Array = lanes_shown.get(id, []).duplicate()
	if on and not shown.has(target):
		shown.append(target)
	elif not on:
		shown.erase(target)
	if shown.is_empty():
		lanes_shown.erase(id)
	else:
		lanes_shown[id] = shown
	_lay_rows()
	_clamp_scroll()
	_place_headers()
	queue_redraw()


## Whether a track is inside a folder that is shut.
func _hidden(p: DawKitProject, t: DawKitTrack) -> bool:
	var up := t.parent
	var steps := 0
	while not up.is_empty() and steps <= p.tracks.size():
		if collapsed.has(up):
			return true
		var f := p.track(up)
		up = f.parent if f != null else ""
		steps += 1
	return false


## Shows or hides what is in a folder.
func toggle_fold(id: String) -> void:
	if collapsed.has(id):
		collapsed.erase(id)
	else:
		collapsed[id] = true
	rebuild()


func show_track(id: String) -> void:
	var p := host.project()
	var t := p.track(id) if p != null else null
	var h: DawKitTrackHeader = headers.get(id)
	if t == null or h == null:
		return
	h.show_track(t)
	queue_redraw()


## Draws the clips again, wherever they changed.
func show_clips() -> void:
	var p := host.project()
	if p == null:
		return
	for id in headers:
		var t := p.track(id)
		if t != null:
			headers[id].show_track(t)
	queue_redraw()


## The song second at x (in this control's own pixels), and the x of a song second.
func time_at(x: float) -> float:
	return view_start + (x - HEADER_WIDTH) / pixels_per_second


func x_of(seconds: float) -> float:
	return HEADER_WIDTH + (seconds - view_start) * pixels_per_second


## The top of track `row`'s lane, and the row at y (-1 above the lanes, `_order.size()` below).
func lane_top(row: int) -> float:
	if _tops.size() != _order.size() + 1:
		_lay_rows()
	return RULER_HEIGHT + _tops[clampi(row, 0, _order.size())] - scroll_y


func row_at(y: float) -> int:
	if y < RULER_HEIGHT:
		return -1
	if _tops.size() != _order.size() + 1:
		_lay_rows()
	var at := y - RULER_HEIGHT + scroll_y
	for row in _order.size():
		if at < _tops[row + 1]:
			return row
	return _order.size()


## What is under a point, in words: a clip, a point of automation or a lane's value, or where
## on a track the pointer is.
func describe_at(at: Vector2) -> String:
	var p := host.project()
	if p == null or at.x < HEADER_WIDTH or at.y < RULER_HEIGHT:
		return ""
	var seconds := maxf(time_at(at.x), 0.0)
	var lane := lane_at(at)
	if not lane.is_empty():
		var t := p.track(lane["id"])
		var target: String = lane["target"]
		var points := lane_points(t, target)
		var i := point_at(t, target, lane["top"], at)
		var named := DawKitEnvelope.label_of(p, t, target)
		if i >= 0:
			return "%s point at %s: %s  (drag to move, right-click to delete)" % [named, DawKitLook.bars_text(p, points[i][0]),
					DawKitEnvelope.text_of(target, points[i][1])]
		return "%s at %s: %s  (click to add a point)" % [named, DawKitLook.bars_text(p, seconds),
				DawKitEnvelope.text_of(target, DawKitAutomation.value_in(points, seconds, DawKitEnvelope.current_of(t, target)))]
	var hit := clip_at(at)
	if not hit.is_empty():
		var t := p.track(hit[0])
		var c := t.clips[hit[1]]
		var what := "%d notes" % c.note_count() if c.source.is_empty() else c.source.get_file()
		var also := ""
		if not is_zero_approx(c.gain_db):
			also += "  %s dB" % DawKitLook.db_text(c.gain_db)
		if c.muted:
			also += "  muted"
		if c.locked:
			also += "  locked"
		return "%s: %s, %s to %s (%.2f s), %s%s" % [t.name, c.name if not c.name.is_empty() else "clip %d" % (hit[1] + 1),
				DawKitLook.bars_text(p, c.start), DawKitLook.bars_text(p, c.end()), c.length, what, also]
	var row := row_at(at.y)
	if row >= 0 and row < _order.size():
		return "%s at %s" % [p.track(_order[row]).name, DawKitLook.bars_text(p, seconds)]
	return ""


## The automation lane under a point: {id, target, top (of the lane), row}; empty off them.
func lane_at(at: Vector2) -> Dictionary:
	var row := row_at(at.y)
	if row < 0 or row >= _order.size():
		return {}
	var into := at.y - lane_top(row) - lane_height
	var shown := lanes_of(_order[row])
	if into < 0.0 or shown.is_empty():
		return {}
	var n := mini(floori(into / AUTO_HEIGHT), shown.size() - 1)
	return {"id": _order[row], "target": shown[n], "top": lane_top(row) + lane_height + n * AUTO_HEIGHT, "row": row}


## The track and clip under a point, as [id, clip index], or [] for none.
func clip_at(at: Vector2) -> Array:
	var row := row_at(at.y)
	var p := host.project()
	if p == null or at.x < HEADER_WIDTH or row < 0 or row >= _order.size():
		return []
	if at.y - lane_top(row) >= lane_height:
		return []
	var t := p.track(_order[row])
	var seconds := time_at(at.x)
	for i in range(t.clips.size() - 1, -1, -1):
		var c := t.clips[i]
		if seconds >= c.start and seconds <= c.end():
			return [t.id, i]
	return []


## Shows the song from `start` seconds with `pps` pixels a second.
func set_view(start: float, pps: float) -> void:
	view_start = maxf(start, 0.0)
	pixels_per_second = clampf(pps, MIN_PIXELS_PER_SECOND, MAX_PIXELS_PER_SECOND)
	queue_redraw()


## The nearest beat to `seconds`, on the project's own tempo map.
func snap(seconds: float) -> float:
	var p := host.project()
	if p == null:
		return seconds
	var map := p.tempo_map()
	return map.seconds_at(roundf(map.beat_at(seconds)))


func _process(_delta: float) -> void:
	var at := host.position()
	if follow and host.is_playing() and not _drag and not _scrubbing and not ruler.scrubbing:
		var width := size.x - HEADER_WIDTH
		if at < view_start or x_of(at) > size.x - 8.0:
			view_start = maxf(at - width * 0.05 / pixels_per_second, 0.0)
			queue_redraw()
	if not is_equal_approx(at, _drawn_position):
		queue_redraw()


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		ruler.size = Vector2(maxf(size.x - HEADER_WIDTH, 0.0), RULER_HEIGHT)
		_clamp_scroll()
		_place_headers()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		_on_button(event)
	elif event is InputEventMouseMotion:
		_on_motion(event)


func _on_button(e: InputEventMouseButton) -> void:
	if e.pressed and e.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_DOWN, MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT]:
		var notch := -1.0 if e.button_index in [MOUSE_BUTTON_WHEEL_UP, MOUSE_BUTTON_WHEEL_LEFT] else 1.0
		if e.alt_pressed:
			set_lane_height(lane_height * (1.15 if notch < 0.0 else 1.0 / 1.15))
		elif e.ctrl_pressed:
			var anchor := time_at(maxf(e.position.x, HEADER_WIDTH))
			var pps := clampf(pixels_per_second * (1.25 if notch < 0.0 else 0.8), MIN_PIXELS_PER_SECOND, MAX_PIXELS_PER_SECOND)
			set_view(anchor - (maxf(e.position.x, HEADER_WIDTH) - HEADER_WIDTH) / pps, pps)
		elif e.shift_pressed or e.button_index in [MOUSE_BUTTON_WHEEL_LEFT, MOUSE_BUTTON_WHEEL_RIGHT]:
			set_view(view_start + notch * 80.0 / pixels_per_second, pixels_per_second)
		else:
			scroll_y += notch * lane_height * 0.5
			_clamp_scroll()
			_place_headers()
			queue_redraw()
		accept_event()
		return
	if e.button_index == MOUSE_BUTTON_MIDDLE:
		_panning = e.pressed
		accept_event()
		return
	var lane := lane_at(e.position) if e.position.y >= RULER_HEIGHT else {}
	if not lane.is_empty() and e.position.x < HEADER_WIDTH:
		# The lane's name: X hides it, and the rest keeps the press from going any further.
		if e.pressed and e.button_index == MOUSE_BUTTON_LEFT and e.position.x >= HEADER_WIDTH - 30.0 and e.position.y - lane["top"] < 24.0:
			show_lane(lane["id"], lane["target"], false)
		accept_event()
		return
	if not lane.is_empty() and e.button_index == MOUSE_BUTTON_RIGHT:
		if e.pressed:
			_delete_point(lane, e.position)
		accept_event()
		return
	if e.button_index == MOUSE_BUTTON_LEFT and not e.pressed and not _auto.is_empty():
		_release_lane()
		accept_event()
		return
	if not lane.is_empty() and e.button_index == MOUSE_BUTTON_LEFT and e.pressed:
		grab_focus()
		_press_lane(lane, e)
		accept_event()
		return
	if e.button_index == MOUSE_BUTTON_RIGHT and e.pressed and e.position.x >= HEADER_WIDTH:
		var hit := zone_at(e.position)
		if not hit.is_empty():
			if host.can(DawKitHost.SELECT) and not host.is_selected(hit["id"], hit["index"]):
				host.select_clip(hit["id"], hit["index"])
			open_clip_menu(hit["id"], hit["index"], e.global_position)
		accept_event()
		return
	if e.button_index != MOUSE_BUTTON_LEFT:
		return
	if e.pressed:
		grab_focus()
		if e.position.x < HEADER_WIDTH:
			return
		_press(e)
		accept_event()
	else:
		_release(e)
		accept_event()


## The clip under a point and the part of it there, {id, index, zone}: "move" in its body,
## "trim_left" and "trim_right" at its edges, and in its name bar "fade_in" and "fade_out" at the
## fades' handles and "gain" at the middle. Empty off every clip.
func zone_at(at: Vector2) -> Dictionary:
	var hit := clip_at(at)
	if hit.is_empty():
		return {}
	var c := host.project().track(hit[0]).clips[hit[1]]
	var top := lane_top(_order.find(hit[0])) + 3.0
	var x0 := x_of(c.start)
	var x1 := x_of(c.end())
	var zone := "move"
	if at.y < top + BAND:
		var fade_in_x := x0 + c.fade_in * pixels_per_second
		var fade_out_x := x1 - c.fade_out * pixels_per_second
		if absf(at.x - fade_in_x) <= HANDLE and at.x - x0 < (x1 - x0) * 0.5:
			zone = "fade_in"
		elif absf(at.x - fade_out_x) <= HANDLE:
			zone = "fade_out"
		elif absf(at.x - (x0 + x1) * 0.5) <= HANDLE * 1.5:
			zone = "gain"
	elif at.x - x0 <= EDGE and x1 - x0 > EDGE * 3.0:
		zone = "trim_left"
	elif x1 - at.x <= EDGE and x1 - x0 > EDGE * 3.0:
		zone = "trim_right"
	return {"id": hit[0], "index": hit[1], "zone": zone}


func _press(e: InputEventMouseButton) -> void:
	var hit := zone_at(e.position) if e.position.y >= RULER_HEIGHT else {}
	if hit.is_empty():
		if e.position.y < RULER_HEIGHT:
			_scrubbing = host.can(DawKitHost.SEEK)
			if _scrubbing:
				host.seek(_seek_time(e.position.x, e.alt_pressed))
		else:
			_box = {"from": e.position, "to": e.position, "additive": e.shift_pressed or e.ctrl_pressed}
		return
	var id: String = hit["id"]
	var index: int = hit["index"]
	if e.double_click and host.project().track(id).clips[index].source.is_empty():
		_drag = {}
		clip_opened.emit(id, index)
		return
	var additive := e.shift_pressed or e.ctrl_pressed
	if host.can(DawKitHost.SELECT) and (additive or not host.is_selected(id, index)):
		host.select_clip(id, index, additive)
	if additive:
		return
	var c := host.project().track(id).clips[index]
	var zone: String = hit["zone"]
	var editing := host.can(DawKitHost.EDIT_CLIPS) if zone != "move" else host.can(DawKitHost.MOVE_CLIP)
	if c.locked or not editing:
		return
	_drag = {"zone": zone, "id": id, "index": index, "grab": time_at(e.position.x) - c.start,
			"y": e.position.y, "to": id, "ghost": DawKitClip.from_dict(c.to_dict()), "clip": c}


func _release(e: InputEventMouseButton) -> void:
	_scrubbing = false
	if not _box.is_empty():
		var box := _box
		_box = {}
		queue_redraw()
		var from: Vector2 = box["from"]
		if from.distance_to(e.position) < 4.0:
			if host.can(DawKitHost.SELECT):
				host.clear_selection()
			if host.can(DawKitHost.SEEK):
				host.seek(_seek_time(e.position.x, e.alt_pressed))
		elif host.can(DawKitHost.SELECT):
			select_in(Rect2(from, Vector2.ZERO).expand(e.position), box["additive"])
		return
	if _drag.is_empty():
		return
	var d := _drag
	_drag = {}
	queue_redraw()
	var c: DawKitClip = d["clip"]
	var g: DawKitClip = d["ghost"]
	match d["zone"]:
		"move":
			if not is_equal_approx(g.start, c.start) or d["to"] != d["id"]:
				host.move_clip(d["id"], d["index"], g.start, d["to"] if d["to"] != d["id"] else "")
		"trim_left", "trim_right":
			if not is_equal_approx(g.start, c.start) or not is_equal_approx(g.end(), c.end()):
				host.trim_clip(d["id"], d["index"], g.start, g.end())
		"fade_in", "fade_out":
			if not is_equal_approx(g.fade_in, c.fade_in) or not is_equal_approx(g.fade_out, c.fade_out):
				host.set_clip_fades(d["id"], d["index"], g.fade_in, g.fade_out)
		"gain":
			if not is_equal_approx(g.gain_db, c.gain_db):
				host.set_clip_gain(d["id"], d["index"], g.gain_db)


## Selects every clip that a rectangle (in this control's pixels) touches, as well as what was
## selected when `additive`.
func select_in(rect: Rect2, additive := false) -> void:
	var p := host.project()
	if p == null:
		return
	var first := true
	for row in _order.size():
		var top := lane_top(row)
		if top + lane_height < rect.position.y or top > rect.end.y:
			continue
		var t := p.track(_order[row])
		for i in t.clips.size():
			var c := t.clips[i]
			if x_of(c.end()) < rect.position.x or x_of(c.start) > rect.end.x:
				continue
			if first and not additive:
				host.select_clip(t.id, i)
			elif not host.is_selected(t.id, i):
				host.select_clip(t.id, i, true)
			first = false
	if first and not additive:
		host.clear_selection()


## The right button's menu for a clip.
func open_clip_menu(id: String, index: int, at: Vector2) -> void:
	var c := host.project().track(id).clips[index]
	if _menu == null:
		_menu = PopupMenu.new()
		_menu.name = "ClipMenu"
		add_child(_menu)
		_menu.id_pressed.connect(_on_menu)
	_menu.clear()
	var editing := host.can(DawKitHost.EDIT_CLIPS)
	_menu.add_item("Split at the playhead  (S)", MENU_SPLIT)
	_menu.add_item("Duplicate  (Ctrl+D)", MENU_DUPLICATE)
	_menu.add_item("Delete  (Del)", MENU_DELETE)
	_menu.add_separator()
	_menu.add_item("Unmute" if c.muted else "Mute", MENU_MUTE)
	_menu.add_item("Gain back to 0 dB", MENU_GAIN)
	_menu.add_item("No fades", MENU_FADES)
	for i in _menu.item_count:
		if _menu.get_item_id(i) >= 0:
			_menu.set_item_disabled(i, not editing)
	_menu.set_meta(&"clip", [id, index])
	_menu.position = Vector2i(at)
	_menu.reset_size()
	_menu.popup()


func _on_menu(item: int) -> void:
	var at: Array = _menu.get_meta(&"clip")
	var t := host.project().track(at[0])
	if t == null or at[1] >= t.clips.size():
		return
	var c := t.clips[at[1]]
	match item:
		MENU_SPLIT:
			host.split_selection(host.position())
		MENU_DUPLICATE:
			host.duplicate_selection()
		MENU_DELETE:
			host.delete_selection()
		MENU_MUTE:
			host.set_clip_muted(at[0], at[1], not c.muted)
		MENU_GAIN:
			host.set_clip_gain(at[0], at[1], 0.0)
		MENU_FADES:
			host.set_clip_fades(at[0], at[1], 0.0, 0.0)


## The row a track dropped at `y` lands before (0 to the number of rows).
func gap_at(y: float) -> int:
	if _tops.size() != _order.size() + 1:
		_lay_rows()
	var at := y - RULER_HEIGHT + scroll_y
	var best := 0
	for gap in _order.size() + 1:
		if absf(_tops[gap] - at) < absf(_tops[best] - at):
			best = gap
	return best


## Where a track lands if dropped before row `gap`: [position in the order after the move, the
## folder it is in]. The folder is the one the track it lands before is in, or, dropped just after
## the last track in a folder, that folder. Empty for no move: dropped on itself or at its own
## edges.
func drop_plan(id: String, gap: int) -> Array:
	var p := host.project()
	var t := p.track(id) if p != null else null
	if t == null:
		return []
	var block := p.block_of(t)
	var rows: Array[int] = []
	for row in _order.size():
		if block.has(p.track(_order[row])):
			rows.append(row)
	if not rows.is_empty() and gap >= rows[0] and gap <= rows.back() + 1:
		return []
	var rest: Array = p.tracks.filter(func(x: DawKitTrack) -> bool: return not block.has(x))
	var prev: DawKitTrack = null
	for row in range(gap - 1, -1, -1):
		var x := p.track(_order[row])
		if not block.has(x):
			prev = x
			break
	var next: DawKitTrack = null
	for row in range(gap, _order.size()):
		var x := p.track(_order[row])
		if not block.has(x):
			next = x
			break
	var parent := next.parent if next != null else ""
	if prev != null and not prev.parent.is_empty() and (next == null or p.depth_of(prev) > p.depth_of(next)):
		parent = prev.parent
	var position := rest.find(next) if next != null else rest.size()
	if prev != null and next != null and next.parent != parent:
		# After the folder's last track, which may be shut away under it.
		position = rest.find(p.block_of(prev).filter(func(x: DawKitTrack) -> bool: return not block.has(x)).back()) + 1
	return [position, parent]


func _on_header_dragged(id: String, at: Vector2) -> void:
	_track_drag = {"id": id, "gap": gap_at(at.y)}
	queue_redraw()


func _on_header_dropped(id: String, at: Vector2) -> void:
	_track_drag = {}
	queue_redraw()
	var plan := drop_plan(id, gap_at(at.y))
	if not plan.is_empty():
		host.move_track(id, plan[0], plan[1])


## Into the folder of the track just above it at its own level (that track becoming a folder),
## as that folder's last track. False when there is no such track.
func move_into_folder_above(id: String) -> bool:
	var p := host.project()
	var t := p.track(id)
	var at := p.tracks.find(t)
	var above: DawKitTrack = null
	for i in range(at - 1, -1, -1):
		if p.tracks[i].parent == t.parent:
			above = p.tracks[i]
			break
	if above == null:
		return false
	var block := p.block_of(t)
	var rest: Array = p.tracks.filter(func(x: DawKitTrack) -> bool: return not block.has(x))
	host.move_track(id, rest.find(p.block_of(above).back()) + 1, above.id)
	return true


## Out of its folder, to just after it, in the folder that one is in. False when in none.
func move_out_of_folder(id: String) -> bool:
	var p := host.project()
	var t := p.track(id)
	var folder := p.track(t.parent) if not t.parent.is_empty() else null
	if folder == null:
		return false
	var block := p.block_of(t)
	var rest: Array = p.tracks.filter(func(x: DawKitTrack) -> bool: return not block.has(x))
	var last: DawKitTrack = p.block_of(folder).filter(func(x: DawKitTrack) -> bool: return not block.has(x)).back()
	host.move_track(id, rest.find(last) + 1, folder.parent)
	return true


## The right button's menu for a track.
func open_track_menu(id: String, at: Vector2) -> void:
	if _track_menu == null:
		_track_menu = PopupMenu.new()
		_track_menu.name = "TrackMenu"
		add_child(_track_menu)
		_track_menu.id_pressed.connect(_on_track_menu)
		_colours = PopupMenu.new()
		_colours.name = "Colours"
		for i in PALETTE.size():
			var img := Image.create(14, 14, false, Image.FORMAT_RGBA8)
			img.fill(PALETTE[i])
			_colours.add_icon_item(ImageTexture.create_from_image(img), "", i)
		_colours.id_pressed.connect(func(i: int): host.set_track_colour(_track_menu.get_meta(&"track"), PALETTE[i]))
		_track_menu.add_child(_colours)
	var p := host.project()
	var t := p.track(id)
	var tracks := host.can(DawKitHost.TRACKS)
	var order := host.can(DawKitHost.TRACK_ORDER)
	_track_menu.clear()
	_track_menu.add_item("New track below  (Ctrl+T)", TRACK_NEW)
	_track_menu.add_item("Duplicate", TRACK_DUPLICATE)
	_track_menu.add_item("Rename  (double-click)", TRACK_RENAME)
	_track_menu.add_submenu_node_item("Colour", _colours)
	_track_menu.add_separator()
	_track_menu.add_item("Into the folder above", TRACK_INTO)
	_track_menu.add_item("Out of its folder", TRACK_OUT)
	_track_menu.add_separator()
	_track_menu.add_item("Delete track", TRACK_DELETE)
	for i in _track_menu.item_count:
		var item := _track_menu.get_item_id(i)
		if item in [TRACK_INTO, TRACK_OUT]:
			_track_menu.set_item_disabled(i, not order or (item == TRACK_OUT and t.parent.is_empty()))
		elif not _track_menu.is_item_separator(i):
			_track_menu.set_item_disabled(i, not tracks)
	_track_menu.set_meta(&"track", id)
	_track_menu.position = Vector2i(at)
	_track_menu.reset_size()
	_track_menu.popup()


func _on_track_menu(item: int) -> void:
	var id: String = _track_menu.get_meta(&"track")
	match item:
		TRACK_NEW:
			host.add_track(id)
		TRACK_DUPLICATE:
			host.duplicate_track(id)
		TRACK_RENAME:
			var h: DawKitTrackHeader = headers.get(id)
			if h != null:
				h.start_rename()
		TRACK_INTO:
			move_into_folder_above(id)
		TRACK_OUT:
			move_out_of_folder(id)
		TRACK_DELETE:
			host.remove_track(id)


func _on_motion(e: InputEventMouseMotion) -> void:
	if _panning:
		set_view(view_start - e.relative.x / pixels_per_second, pixels_per_second)
		scroll_y -= e.relative.y
		_clamp_scroll()
		_place_headers()
		accept_event()
	elif _scrubbing:
		host.seek(_seek_time(e.position.x, e.alt_pressed))
		accept_event()
	elif not _auto.is_empty():
		_drag_lane(e.position, e.alt_pressed)
		accept_event()
	elif not _box.is_empty():
		_box["to"] = e.position
		queue_redraw()
		accept_event()
	elif not _drag.is_empty():
		_drag_to(e.position, e.alt_pressed)
		queue_redraw()
		accept_event()
	else:
		var hit := zone_at(e.position) if e.position.x >= HEADER_WIDTH and e.position.y >= RULER_HEIGHT else {}
		mouse_default_cursor_shape = CURSORS.get(hit.get("zone", ""), Control.CURSOR_ARROW)
		hovered.emit(describe_at(e.position))


## The dragged clip's ghost, where the pointer has taken it. Times snap to the beat unless `free`.
func _drag_to(at: Vector2, free: bool) -> void:
	var c: DawKitClip = _drag["clip"]
	var g: DawKitClip = _drag["ghost"]
	var t := time_at(at.x)
	var snapped := t if free else snap(t)
	match _drag["zone"]:
		"move":
			var start := maxf(t - float(_drag["grab"]), 0.0)
			g.start = start if free else maxf(snap(start), 0.0)
			_drag["to"] = _order[clampi(row_at(at.y), 0, _order.size() - 1)]
		"trim_left":
			var start := clampf(snapped, 0.0, c.end() - MIN_CLIP_SECONDS)
			if not c.source.is_empty() and not c.is_looped():
				start = maxf(start, c.start - c.source_offset)
			g.start = start
			g.length = c.end() - start
			g.source_offset = c.source_offset + (start - c.start)
			g.notes = _shifted_notes(c, start - c.start, g.length)
		"trim_right":
			g.length = maxf(snapped, c.start + MIN_CLIP_SECONDS) - c.start
			g.notes = _shifted_notes(c, 0.0, g.length)
		"fade_in":
			g.fade_in = clampf(t - c.start, 0.0, c.length - c.fade_out)
		"fade_out":
			g.fade_out = clampf(c.end() - t, 0.0, c.length - c.fade_in)
		"gain":
			g.gain_db = clampf(c.gain_db - (at.y - float(_drag["y"])) * 0.25, -60.0, 24.0)


## A clip's notes as they would sound with its front moved on by `shift` and `length` long.
static func _shifted_notes(c: DawKitClip, shift: float, length: float) -> PackedFloat64Array:
	var out := PackedFloat64Array()
	for n in c.note_count():
		var at := n * DawKitClip.NOTE_WIDTH
		var on := c.notes[at] - shift
		var off := c.notes[at + 1] - shift
		if off > 0.0 and on < length:
			out.append_array([maxf(on, 0.0), minf(off, length), c.notes[at + 2], c.notes[at + 3], c.notes[at + 4]])
	return out


func _seek_time(x: float, free: bool) -> float:
	var at := maxf(time_at(maxf(x, HEADER_WIDTH)), 0.0)
	return at if free else maxf(snap(at), 0.0)


func _clamp_scroll() -> void:
	if _tops.size() != _order.size() + 1:
		_lay_rows()
	var most := maxf(_tops[_order.size()] - (size.y - RULER_HEIGHT) + lane_height * 0.5, 0.0)
	scroll_y = clampf(scroll_y, 0.0, most)


func _place_headers() -> void:
	for row in _order.size():
		var h: DawKitTrackHeader = headers[_order[row]]
		var top := lane_top(row)
		h.position = Vector2(0, top)
		h.lay_out(HEADER_WIDTH - 1.0, lane_height - 1.0)
		h.visible = top + lane_height > RULER_HEIGHT and top < size.y
		h.lanes.set_pressed_no_signal(not lanes_of(_order[row]).is_empty())
	if _add_button != null:
		_add_button.position = Vector2(HEADER_WIDTH - 34.0, 6.0)


## Every track's lane `height` tall.
func set_lane_height(height: float) -> void:
	lane_height = clampf(height, MIN_LANE_HEIGHT, MAX_LANE_HEIGHT)
	_lay_rows()
	_clamp_scroll()
	_place_headers()
	queue_redraw()


func _draw() -> void:
	var p := host.project()
	draw_rect(Rect2(Vector2.ZERO, size), DawKitLook.BACKGROUND)
	if p == null:
		return
	var font := get_theme_default_font()
	var right := size.x
	var from := maxf(view_start, 0.0)
	var to := time_at(right)
	# Lanes, every other one a shade lighter.
	for row in _order.size():
		var top := lane_top(row)
		if top + lane_height < RULER_HEIGHT or top > size.y:
			continue
		if row % 2 == 1:
			draw_rect(Rect2(HEADER_WIDTH, top, right - HEADER_WIDTH, lane_height), DawKitLook.BACKGROUND.lightened(0.025))
		draw_line(Vector2(HEADER_WIDTH, top + lane_height - 0.5), Vector2(right, top + lane_height - 0.5), DawKitLook.LINE.darkened(0.3))
		var shown := lanes_of(_order[row])
		for n in shown.size():
			var lane_y := top + lane_height + n * AUTO_HEIGHT
			draw_rect(Rect2(0, lane_y, right, AUTO_HEIGHT), DawKitLook.BACKGROUND.darkened(0.2))
			draw_line(Vector2(0, lane_y + AUTO_HEIGHT - 0.5), Vector2(right, lane_y + AUTO_HEIGHT - 0.5), DawKitLook.LINE.darkened(0.3))
	# The loop's range, behind everything.
	if p.loop_end > p.loop_start:
		var lx := maxf(x_of(p.loop_start), HEADER_WIDTH)
		var rx := minf(x_of(p.loop_end), right)
		if rx > lx:
			var tint := DawKitLook.LOOP
			tint.a = 0.08 if p.loop_on else 0.03
			draw_rect(Rect2(lx, RULER_HEIGHT, rx - lx, size.y - RULER_HEIGHT), tint)
	# The grid: bars strong, beats faint when there is room for them.
	var map := p.tempo_map()
	var meter := p.meter()
	var beat_px := pixels_per_second * 60.0 / maxf(map.bpm_at(map.beat_at(from)), 1.0)
	var bar_every := 1
	while beat_px * 4.0 * bar_every < 48.0 and bar_every < 256:
		bar_every *= 2
	for count in meter.counts(map.beat_at(from), map.beat_at(to) + 1.0):
		var beat: float = count[0]
		var x := x_of(map.seconds_at(beat))
		if x < HEADER_WIDTH or x > right:
			continue
		if count[1]:
			var bar: int = meter.position(beat)[0]
			if (bar - 1) % bar_every != 0:
				continue
			draw_line(Vector2(x, RULER_HEIGHT * 0.55), Vector2(x, size.y), DawKitLook.LINE, 1.0)
			draw_string(font, Vector2(x + 3.0, 30.0), str(bar), HORIZONTAL_ALIGNMENT_LEFT, -1,
					DawKitLook.SMALL_FONT_SIZE, DawKitLook.TEXT_DIM)
		elif beat_px >= 10.0 and bar_every == 1:
			draw_line(Vector2(x, RULER_HEIGHT * 0.75), Vector2(x, size.y), DawKitLook.LINE.darkened(0.45), 1.0)
	# Clips.
	for row in _order.size():
		var top := lane_top(row)
		if top + lane_height < RULER_HEIGHT or top > size.y:
			continue
		var t := p.track(_order[row])
		for i in t.clips.size():
			if not _drag.is_empty() and _drag["id"] == t.id and _drag["index"] == i:
				continue
			_draw_clip(t, i, t.clips[i], t.clips[i].start, top, false)
	if not _drag.is_empty():
		var t := p.track(_drag["id"])
		var g: DawKitClip = _drag["ghost"]
		_draw_clip(t, _drag["index"], g, g.start, lane_top(_order.find(_drag["to"])), true)
		if _drag["zone"] == "gain":
			_say_at(Vector2(x_of(g.start + g.length * 0.5), lane_top(_order.find(_drag["to"])) - 2.0), DawKitLook.db_text(g.gain_db) + " dB")
		elif _drag["zone"] in ["fade_in", "fade_out"]:
			var fade := g.fade_in if _drag["zone"] == "fade_in" else g.fade_out
			_say_at(Vector2(x_of(g.start + (fade if _drag["zone"] == "fade_in" else g.length - fade)), lane_top(_order.find(_drag["to"])) - 2.0), "%.2f s" % fade)
	if not _box.is_empty():
		var r := Rect2(_box["from"], Vector2.ZERO).expand(_box["to"])
		draw_rect(r, Color(DawKitLook.LOOP, 0.12))
		draw_rect(r, Color(DawKitLook.LOOP, 0.7), false, 1.0)
	# Automation, in the lanes under the tracks.
	for row in _order.size():
		var shown := lanes_of(_order[row])
		for n in shown.size():
			var lane_y := lane_top(row) + lane_height + n * AUTO_HEIGHT
			if lane_y + AUTO_HEIGHT < RULER_HEIGHT or lane_y > size.y:
				continue
			_draw_lane(p, p.track(_order[row]), shown[n], lane_y)
	# Regions and markers down the lanes; the ruler (a child) draws their heads, and itself.
	for r in p.regions:
		var rx0 := maxf(x_of(r.start), HEADER_WIDTH)
		var rx1 := minf(x_of(r.end), right)
		if rx1 > rx0:
			draw_rect(Rect2(rx0, RULER_HEIGHT, rx1 - rx0, size.y - RULER_HEIGHT), Color(DawKitRuler.REGION, 0.04))
	for m in p.markers:
		var x := x_of(m.time)
		if x >= HEADER_WIDTH and x <= right:
			draw_line(Vector2(x, RULER_HEIGHT), Vector2(x, size.y), Color(DawKitLook.ACCENT, 0.35), 1.0)
	ruler.queue_redraw()
	draw_rect(Rect2(0, 0, HEADER_WIDTH, RULER_HEIGHT), DawKitLook.PANEL)
	draw_string(font, Vector2(10, 24), "%d tracks" % p.tracks.size(), HORIZONTAL_ALIGNMENT_LEFT, -1,
			DawKitLook.SMALL_FONT_SIZE, DawKitLook.TEXT_DIM)
	draw_line(Vector2(HEADER_WIDTH - 0.5, 0), Vector2(HEADER_WIDTH - 0.5, size.y), DawKitLook.LINE)
	if not _track_drag.is_empty():
		var y := lane_top(_track_drag["gap"])
		draw_rect(Rect2(0, y - 1.5, size.x, 3.0), DawKitLook.ACCENT)
	# The playhead.
	_drawn_position = host.position()
	var px := x_of(_drawn_position)
	if px >= HEADER_WIDTH and px <= right:
		draw_line(Vector2(px, RULER_HEIGHT), Vector2(px, size.y), DawKitLook.PLAYHEAD, 1.0)


## The y of height `level` (0 to 1) in a lane whose top is `top`, and the height at y.
static func lane_y(top: float, level: float) -> float:
	return top + 5.0 + (1.0 - level) * (AUTO_HEIGHT - 10.0)


static func lane_level(top: float, y: float) -> float:
	return clampf(1.0 - (y - top - 5.0) / (AUTO_HEIGHT - 10.0), 0.0, 1.0)


## A lane's points: the ones being dragged, or the track's.
func lane_points(t: DawKitTrack, target: String) -> Array:
	if not _auto.is_empty() and _auto["id"] == t.id and _auto["target"] == target:
		return _auto["points"]
	var lane := t.automation_of(target)
	return lane.points if lane != null else []


## The point of a lane near `at`, or -1.
func point_at(t: DawKitTrack, target: String, top: float, at: Vector2) -> int:
	var points := lane_points(t, target)
	for i in range(points.size() - 1, -1, -1):
		var pt := Vector2(x_of(points[i][0]), lane_y(top, DawKitEnvelope.level_of(target, points[i][1])))
		if pt.distance_to(at) <= POINT + 1.0:
			return i
	return -1


func _draw_lane(p: DawKitProject, t: DawKitTrack, target: String, top: float) -> void:
	var font := get_theme_default_font()
	var right := size.x
	var tint := t.colour if t.colour.a > 0.0 else DawKitLook.ACCENT
	# Its name and what it says now, in the header's column; X hides it.
	var points := lane_points(t, target)
	draw_rect(Rect2(0, top, HEADER_WIDTH - 1.0, AUTO_HEIGHT - 1.0), DawKitLook.PANEL.darkened(0.1))
	draw_rect(Rect2(p.depth_of(t) * DawKitTrackHeader.INDENT, top, 3, AUTO_HEIGHT - 1.0), Color(tint, 0.6))
	draw_string(font, Vector2(16.0 + p.depth_of(t) * DawKitTrackHeader.INDENT, top + 17.0), DawKitEnvelope.label_of(p, t, target),
			HORIZONTAL_ALIGNMENT_LEFT, HEADER_WIDTH - 50.0 - p.depth_of(t) * DawKitTrackHeader.INDENT, DawKitLook.SMALL_FONT_SIZE, DawKitLook.TEXT)
	var now := DawKitAutomation.value_in(points, host.position(), DawKitEnvelope.current_of(t, target))
	draw_string(font, Vector2(16.0 + p.depth_of(t) * DawKitTrackHeader.INDENT, top + 34.0), DawKitEnvelope.text_of(target, now),
			HORIZONTAL_ALIGNMENT_LEFT, -1, DawKitLook.SMALL_FONT_SIZE - 1, DawKitLook.TEXT_DIM)
	draw_string(font, Vector2(HEADER_WIDTH - 22.0, top + 17.0), "X", HORIZONTAL_ALIGNMENT_LEFT, -1, DawKitLook.SMALL_FONT_SIZE, DawKitLook.TEXT_DIM)
	# The line: flat before the first point and after the last, held or ramped between.
	var line := Color(tint.lightened(0.3), 0.95)
	if points.is_empty():
		var y := lane_y(top, DawKitEnvelope.level_of(target, DawKitEnvelope.current_of(t, target)))
		for x in range(int(HEADER_WIDTH), int(right), 8):
			draw_line(Vector2(x, y), Vector2(minf(x + 4.0, right), y), Color(line, 0.45), 1.0)
		draw_string(font, Vector2(HEADER_WIDTH + 8.0, top + AUTO_HEIGHT - 6.0), "Click to add a point", HORIZONTAL_ALIGNMENT_LEFT, -1,
				DawKitLook.SMALL_FONT_SIZE - 1, DawKitLook.TEXT_DIM)
		return
	var path := PackedVector2Array()
	path.append(Vector2(HEADER_WIDTH, lane_y(top, DawKitEnvelope.level_of(target, points[0][1]))))
	for i in points.size():
		var pt := Vector2(x_of(points[i][0]), lane_y(top, DawKitEnvelope.level_of(target, points[i][1])))
		if i > 0 and (int(points[i - 1][2]) == DawKitAutomation.HOLD or DawKitEnvelope.is_switch(target)):
			path.append(Vector2(pt.x, path[path.size() - 1].y))
		path.append(pt)
	path.append(Vector2(right, path[path.size() - 1].y))
	for i in path.size():
		path[i] = Vector2(clampf(path[i].x, HEADER_WIDTH, right), path[i].y)
	draw_polyline(path, line, 1.5, true)
	for i in points.size():
		var x := x_of(points[i][0])
		if x < HEADER_WIDTH - POINT or x > right + POINT:
			continue
		var pt := Vector2(x, lane_y(top, DawKitEnvelope.level_of(target, points[i][1])))
		var held: bool = not _auto.is_empty() and _auto["id"] == t.id and _auto["target"] == target and _auto["index"] == i
		draw_rect(Rect2(pt - Vector2(3.5, 3.5), Vector2(7, 7)), DawKitLook.ACCENT if held else line)
		if held:
			_say_at(pt + Vector2(0, -4.0), DawKitEnvelope.text_of(target, points[i][1]))


## The automation menu of a track: every control it has, those shown ticked, those automated
## marked. Picking one shows or hides its lane.
func open_automation_menu(id: String, at: Vector2) -> void:
	var p := host.project()
	var t := p.track(id) if p != null else null
	if t == null:
		return
	if _auto_menu == null:
		_auto_menu = PopupMenu.new()
		_auto_menu.name = "AutomationMenu"
		_auto_menu.hide_on_checkable_item_selection = false
		add_child(_auto_menu)
		_auto_menu.index_pressed.connect(_on_automation_menu.bind(_auto_menu))
	for child in _auto_menu.get_children():
		_auto_menu.remove_child(child)
		child.queue_free()
	_auto_menu.clear()
	_auto_menu.set_meta(&"id", id)
	_auto_menu.add_item("Show every automated lane")
	_auto_menu.set_item_metadata(0, "*")
	_auto_menu.add_item("Hide every lane")
	_auto_menu.set_item_metadata(1, "")
	_auto_menu.add_separator()
	var shown := lanes_of(id)
	var effects: Dictionary = {}
	for pair in DawKitEnvelope.targets_of(p, t):
		var target: String = pair[0]
		var kind := DawKitAutomation.kind_of(target)
		var menu := _auto_menu
		var label: String = pair[1]
		if kind in ["enable", "fx"]:
			var i := int(target.split(":")[1])
			if not effects.has(i):
				var sub := PopupMenu.new()
				sub.name = "Effect%d" % i
				sub.hide_on_checkable_item_selection = false
				sub.index_pressed.connect(_on_automation_menu.bind(sub))
				sub.set_meta(&"id", id)
				_auto_menu.add_child(sub)
				var e := t.effects[i]
				_auto_menu.add_submenu_node_item(e.name if not e.name.is_empty() else e.kind, sub)
				effects[i] = sub
			menu = effects[i]
			label = label.get_slice(" > ", 1)
		if t.automation_of(target) != null and not t.automation_of(target).points.is_empty():
			label += "  *"
		menu.add_check_item(label)
		menu.set_item_checked(menu.item_count - 1, shown.has(target))
		menu.set_item_metadata(menu.item_count - 1, target)
	_auto_menu.position = Vector2i(at)
	_auto_menu.reset_size()
	_auto_menu.popup()


func _on_automation_menu(index: int, menu: PopupMenu) -> void:
	var id: String = menu.get_meta(&"id")
	var target: String = menu.get_item_metadata(index)
	var p := host.project()
	var t := p.track(id) if p != null else null
	if t == null:
		return
	if target == "*":
		for lane in t.automation:
			if not lane.points.is_empty() and not DawKitAutomation.kind_of(lane.target).is_empty():
				show_lane(id, lane.target)
		menu.hide()
		return
	if target.is_empty():
		lanes_shown.erase(id)
		show_lane(id, "", false)
		menu.hide()
		return
	var on := not lanes_of(id).has(target)
	show_lane(id, target, on)
	menu.set_item_checked(index, on)


## A press in an automation lane: a point taken to drag, or a new one put there to drag.
func _press_lane(lane: Dictionary, e: InputEventMouseButton) -> void:
	var p := host.project()
	var t := p.track(lane["id"])
	var target: String = lane["target"]
	if not host.can(DawKitHost.AUTOMATION) or t == null:
		return
	var points := lane_points(t, target).duplicate(true)
	var i := point_at(t, target, lane["top"], e.position)
	var added := i < 0
	if added:
		var at := maxf(time_at(e.position.x) if e.alt_pressed else snap(time_at(e.position.x)), 0.0)
		var shape := DawKitAutomation.HOLD if DawKitEnvelope.is_switch(target) else DawKitAutomation.LINEAR
		points.append([at, DawKitAutomation.clamp_value(target, DawKitEnvelope.value_of(target, lane_level(lane["top"], e.position.y))), shape])
		points.sort_custom(func(a, b): return a[0] < b[0])
		for k in points.size():
			if is_equal_approx(points[k][0], at):
				i = k
	# A new point is an edit even if it is not dragged; one taken hold of only once it moves.
	_auto = {"id": t.id, "target": target, "points": points, "index": i, "top": lane["top"], "moved": added}
	queue_redraw()


func _drag_lane(at: Vector2, free: bool) -> void:
	var points: Array = _auto["points"]
	var i: int = _auto["index"]
	if i < 0 or i >= points.size():
		return
	var target: String = _auto["target"]
	var lo: float = points[i - 1][0] + 0.001 if i > 0 else 0.0
	var hi: float = points[i + 1][0] - 0.001 if i + 1 < points.size() else INF
	var t := time_at(at.x) if free else snap(time_at(at.x))
	points[i][0] = clampf(t, lo, maxf(hi, lo))
	points[i][1] = DawKitAutomation.clamp_value(target, DawKitEnvelope.value_of(target, lane_level(_auto["top"], at.y)))
	_auto["moved"] = true
	queue_redraw()


func _release_lane() -> void:
	var d := _auto
	_auto = {}
	queue_redraw()
	if d["moved"]:
		host.set_automation(d["id"], d["target"], d["points"])


## A right-click in an automation lane deletes the point there.
func _delete_point(lane: Dictionary, at: Vector2) -> void:
	var p := host.project()
	var t := p.track(lane["id"])
	var i := point_at(t, lane["target"], lane["top"], at) if t != null else -1
	if i < 0 or not host.can(DawKitHost.AUTOMATION):
		return
	var points := lane_points(t, lane["target"]).duplicate(true)
	points.remove_at(i)
	host.set_automation(t.id, lane["target"], points)


func _draw_clip(t: DawKitTrack, index: int, c: DawKitClip, start: float, top: float, ghost: bool) -> void:
	var x0 := x_of(start)
	var x1 := x_of(start + c.length)
	if x1 < HEADER_WIDTH or x0 > size.x:
		return
	var selected := host.is_selected(t.id, index)
	var left := maxf(x0, HEADER_WIDTH)
	var rect := Rect2(left, top + 3.0, maxf(minf(x1, size.x) - left, 1.0), lane_height - 7.0)
	var colour := c.colour if c.colour.a > 0.0 else t.colour
	var body := colour.darkened(0.42 if selected else 0.55)
	var band := colour.darkened(0.25) if not selected else colour.lightened(0.1)
	if c.muted:
		body = Color(0.22, 0.22, 0.24)
		band = Color(0.3, 0.3, 0.32)
	if ghost:
		body.a = 0.75
	draw_rect(rect, body)
	draw_rect(Rect2(rect.position, Vector2(rect.size.x, BAND)), band)
	var inside := Rect2(Vector2(x0, rect.position.y + BAND + 1.0), Vector2(x1 - x0, rect.size.y - BAND - 3.0))
	if c.is_midi():
		_draw_notes(c, start, inside, colour.lightened(0.35))
	elif not c.source.is_empty():
		_draw_wave(t, index, c, start, inside, colour.lightened(0.25))
	_draw_fades(c, x0, x1, Rect2(Vector2(x0, rect.position.y), Vector2(x1 - x0, rect.size.y)))
	var edge := DawKitLook.PLAYHEAD if ghost or selected else colour.lightened(0.15)
	draw_rect(rect, edge, false, 2.0 if selected else 1.0)
	var label := c.name if not c.name.is_empty() else (c.source.get_file().get_basename() if not c.source.is_empty() else "")
	if c.locked:
		label = "[locked] " + label
	if c.muted:
		label = "[muted] " + label
	var font := get_theme_default_font()
	var text_colour := DawKitLook.TEXT if not selected or c.muted else Color(0.08, 0.08, 0.09)
	if not label.is_empty() and rect.size.x > 24.0:
		draw_string(font, Vector2(rect.position.x + 4.0, rect.position.y + 11.0), label,
				HORIZONTAL_ALIGNMENT_LEFT, rect.size.x - 8.0, DawKitLook.SMALL_FONT_SIZE - 1, text_colour)
	# The gain's handle in the middle of a selected clip's name bar, and the gain when it is not 0 dB.
	var mid := (x0 + x1) * 0.5
	if selected and mid > HEADER_WIDTH and mid < size.x and x1 - x0 > 40.0:
		draw_rect(Rect2(mid - 4.0, rect.position.y + 2.0, 8.0, 3.0), Color(text_colour, 0.6))
	if absf(c.gain_db) >= 0.05 and rect.size.x > 90.0:
		var gain := DawKitLook.db_text(c.gain_db) + " dB"
		draw_string(font, Vector2(rect.end.x - 50.0, rect.position.y + 11.0), gain, HORIZONTAL_ALIGNMENT_RIGHT, 46,
				DawKitLook.SMALL_FONT_SIZE - 1, text_colour)


## A clip's fades: the part of it a fade takes shaded above the fade's curve, and a handle at each
## fade's inner end.
func _draw_fades(c: DawKitClip, x0: float, x1: float, rect: Rect2) -> void:
	var shade := Color(0, 0, 0, 0.4)
	var line := Color(1, 1, 1, 0.75)
	for which in 2:
		var fade := c.fade_in if which == 0 else c.fade_out
		var shape := c.fade_shape if which == 0 else c.fade_out_shape
		var width := fade * pixels_per_second
		if width >= 1.0:
			var curve := PackedVector2Array()
			var steps := clampi(int(width / 4.0), 4, 48)
			for k in steps + 1:
				var f := float(k) / steps
				var x := x0 + f * width if which == 0 else x1 - f * width
				curve.append(Vector2(clampf(x, HEADER_WIDTH, size.x), rect.end.y - DawKitClip.fade_gain(f, shape) * rect.size.y))
			var poly := curve.duplicate()
			poly.append(Vector2(clampf(x0 if which == 0 else x1, HEADER_WIDTH, size.x), rect.position.y))
			if Geometry2D.triangulate_polygon(poly).size() > 0:
				draw_colored_polygon(poly, shade)
			draw_polyline(curve, line, 1.0)
		var hx := x0 + width if which == 0 else x1 - width
		if hx >= HEADER_WIDTH and hx <= size.x and x1 - x0 > 24.0:
			draw_rect(Rect2(hx - 3.0 if which == 0 else hx - 3.0, rect.position.y, 6.0, 6.0), line)


func _say_at(at: Vector2, text: String) -> void:
	var font := get_theme_default_font()
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, DawKitLook.SMALL_FONT_SIZE).x + 10.0
	var r := Rect2(Vector2(at.x - w * 0.5, maxf(at.y - 18.0, RULER_HEIGHT)), Vector2(w, 17.0))
	draw_rect(r, DawKitLook.BACKGROUND)
	draw_rect(r, DawKitLook.ACCENT, false, 1.0)
	draw_string(font, r.position + Vector2(5.0, 13.0), text, HORIZONTAL_ALIGNMENT_LEFT, -1, DawKitLook.SMALL_FONT_SIZE, DawKitLook.TEXT)


func _draw_notes(c: DawKitClip, start: float, inside: Rect2, colour: Color) -> void:
	var low := 127
	var high := 0
	for n in c.note_count():
		var pitch := int(c.notes[n * DawKitClip.NOTE_WIDTH + 2])
		low = mini(low, pitch)
		high = maxi(high, pitch)
	var span := maxi(high - low + 1, 12)
	var mid := (low + high) / 2
	low = mid - span / 2
	var row_h := inside.size.y / float(span + 1)
	for n in c.note_count():
		var on := c.notes[n * DawKitClip.NOTE_WIDTH]
		var off := c.notes[n * DawKitClip.NOTE_WIDTH + 1]
		var pitch := int(c.notes[n * DawKitClip.NOTE_WIDTH + 2])
		var nx0 := maxf(x_of(start + on), HEADER_WIDTH)
		var nx1 := minf(x_of(start + minf(off, c.length)), size.x)
		if nx1 <= nx0:
			continue
		var y := inside.end.y - (pitch - low + 1) * row_h
		draw_rect(Rect2(nx0, y, maxf(nx1 - nx0, 1.0), maxf(row_h - 0.5, 1.0)), colour)


func _draw_wave(t: DawKitTrack, index: int, c: DawKitClip, start: float, inside: Rect2, colour: Color) -> void:
	var peaks := host.clip_peaks(t.id, index)
	if peaks.is_empty():
		return
	var rate := float(DawKitAudioFile.PEAKS_PER_SECOND)
	var mid := inside.get_center().y
	var half := inside.size.y * 0.5
	var x := maxf(inside.position.x, HEADER_WIDTH)
	var end := minf(inside.end.x, size.x)
	var points := PackedVector2Array()
	while x < end:
		var from := c.file_time(time_at(x) - start)
		var to := c.file_time(time_at(x + 1.0) - start)
		var loudest := 0
		for k in range(maxi(int(from * rate), 0), mini(int(ceil(maxf(to, from) * rate)) + 1, peaks.size())):
			loudest = maxi(loudest, peaks[k])
		var h := float(loudest) / 255.0 * half * db_to_linear(c.gain_db)
		if h >= 0.5:
			points.append(Vector2(x, mid - minf(h, half)))
			points.append(Vector2(x, mid + minf(h, half)))
		x += 1.0
	if points.size() >= 2:
		draw_multiline(points, colour, 1.0)
