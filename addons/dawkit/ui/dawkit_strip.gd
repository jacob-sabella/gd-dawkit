class_name DawKitStrip
extends PanelContainer

## One channel of the mixer: the track's name in its colour, a pan, a fader with its level beside
## it, the level in decibels, and mute, solo and arm. It shows what the host says the track is,
## and asks the host for every change.

const WIDTH := 92
## Rows of effects and of sends shown before they scroll.
const EFFECT_ROWS := 4
const SEND_ROWS := 2
const ROW_HEIGHT := 20

## An effect's name was clicked: show its controls.
signal effect_opened(id: String, index: int)

var host: DawKitHost
var id := ""

var name_label: Label
var pan: HSlider
var pan_label: Label
var fader: VSlider
var db_label: Label
var mute: Button
var solo: Button
var arm: Button
var level: DawKitLevel
var _swatch: ColorRect
var effects_box: VBoxContainer
var sends_box: VBoxContainer
var add_effect_button: Button
var add_send_button: Button
var _effects_shown := []
var _sends_shown := []
var _menu: PopupMenu


func _init(with_host: DawKitHost, track_id: String) -> void:
	host = with_host
	id = track_id
	name = "Strip_" + track_id
	custom_minimum_size = Vector2(WIDTH, 0)
	size_flags_vertical = Control.SIZE_EXPAND_FILL

	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 4)
	add_child(column)

	_swatch = ColorRect.new()
	_swatch.custom_minimum_size = Vector2(0, 4)
	column.add_child(_swatch)
	name_label = Label.new()
	name_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	name_label.clip_text = true
	name_label.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	column.add_child(name_label)

	if id != DawKitProject.MASTER_ID:
		effects_box = _section(column, "FX", EFFECT_ROWS)
		add_effect_button = _add_button(column, "+ FX", "Add an effect", DawKitHost.EFFECTS)
		add_effect_button.pressed.connect(_open_effect_choices)
		sends_box = _section(column, "SENDS", SEND_ROWS)
		add_send_button = _add_button(column, "+ SEND", "Send this track to another", DawKitHost.SENDS)
		add_send_button.pressed.connect(_open_send_targets)
		# A chain takes an effect dropped on it, at its end.
		effects_box.get_parent().set_drag_forwarding(Callable(), _can_drop_effect.bind(-1), _drop_effect.bind(-1))

	pan = HSlider.new()
	pan.min_value = -1.0
	pan.max_value = 1.0
	pan.step = 0.01
	pan.tooltip_text = "Pan (double-click: centre)"
	pan.editable = host.can(DawKitHost.PAN)
	pan.value_changed.connect(func(v: float): host.set_pan(id, v))
	pan.gui_input.connect(_on_pan_input)
	column.add_child(pan)
	pan_label = _small()
	column.add_child(pan_label)

	var middle := HBoxContainer.new()
	middle.size_flags_vertical = Control.SIZE_EXPAND_FILL
	middle.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_child(middle)
	fader = VSlider.new()
	fader.min_value = 0.0
	fader.max_value = 1.0
	fader.step = 0.0
	fader.size_flags_vertical = Control.SIZE_EXPAND_FILL
	fader.custom_minimum_size = Vector2(28, 90)
	fader.tooltip_text = "Level (double-click: 0 dB)"
	fader.editable = host.can(DawKitHost.VOLUME)
	fader.value_changed.connect(func(v: float): host.set_volume(id, DawKitLook.db_of(v)))
	fader.gui_input.connect(_on_fader_input)
	middle.add_child(fader)
	level = DawKitLevel.new()
	level.custom_minimum_size = Vector2(10, 90)
	level.size_flags_vertical = Control.SIZE_EXPAND_FILL
	middle.add_child(level)

	db_label = _small()
	column.add_child(db_label)

	var buttons := HBoxContainer.new()
	buttons.add_theme_constant_override("separation", 2)
	buttons.alignment = BoxContainer.ALIGNMENT_CENTER
	column.add_child(buttons)
	mute = _toggle("M", "Mute", DawKitLook.MUTE, DawKitHost.MUTE, func(on: bool): host.set_mute(id, on))
	solo = _toggle("S", "Solo", DawKitLook.SOLO, DawKitHost.SOLO, func(on: bool): host.set_solo(id, on))
	arm = _toggle("R", "Arm to record", DawKitLook.ARM, DawKitHost.ARM, func(on: bool): host.set_armed(id, on))
	for b in [mute, solo, arm]:
		buttons.add_child(b)
	if id == DawKitProject.MASTER_ID:
		solo.visible = false
		arm.visible = false
		mute.disabled = not host.can(DawKitHost.MASTER_MUTE)


## Shows the track as the host's project has it.
func show_track(t: DawKitTrack) -> void:
	name_label.text = t.name if not t.name.is_empty() else t.id
	name_label.tooltip_text = name_label.text
	_swatch.color = t.colour
	pan.set_value_no_signal(t.pan)
	pan_label.text = DawKitLook.pan_text(t.pan)
	fader.set_value_no_signal(DawKitLook.fader_of(t.volume_db))
	db_label.text = DawKitLook.db_text(t.volume_db)
	fader.tooltip_text = "Level %s dB (double-click: 0 dB)" % DawKitLook.db_text(t.volume_db)
	pan.tooltip_text = "Pan %s (double-click: centre)" % DawKitLook.pan_text(t.pan)
	mute.set_pressed_no_signal(t.mute)
	solo.set_pressed_no_signal(t.solo)
	arm.set_pressed_no_signal(t.armed)
	if effects_box != null:
		_show_effects(t)
		_show_sends(t)


func show_level(peaks: Vector2) -> void:
	level.set_peaks(peaks)


func _on_fader_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.double_click and fader.editable:
		host.set_volume(id, 0.0)
		accept_event()


func _on_pan_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.double_click and pan.editable:
		host.set_pan(id, 0.0)
		accept_event()


func _small() -> Label:
	var l := Label.new()
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_size_override("font_size", DawKitLook.SMALL_FONT_SIZE)
	l.add_theme_color_override("font_color", DawKitLook.TEXT_DIM)
	return l


func _toggle(text: String, tip: String, lit: Color, edit: StringName, asked: Callable) -> Button:
	return DawKitStrip.toggle(host, text, tip, lit, edit, asked)


## A small square button that lights in `lit` while on, disabled when the host cannot do `edit`.
static func toggle(on_host: DawKitHost, text: String, tip: String, lit: Color, edit: StringName, asked: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = true
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	b.custom_minimum_size = Vector2(24, 22)
	b.add_theme_color_override("font_pressed_color", Color(0.08, 0.08, 0.09))
	b.add_theme_color_override("font_hover_pressed_color", Color(0.08, 0.08, 0.09))
	b.add_theme_stylebox_override("pressed", DawKitLook.box(lit, 3))
	b.add_theme_stylebox_override("hover_pressed", DawKitLook.box(lit.lightened(0.1), 3))
	b.disabled = not on_host.can(edit)
	b.toggled.connect(asked)
	return b



func _section(column: VBoxContainer, title: String, rows: int) -> VBoxContainer:
	var label := _small()
	label.text = title
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	column.add_child(label)
	var scroll := ScrollContainer.new()
	scroll.name = title.capitalize() + "Scroll"
	scroll.custom_minimum_size = Vector2(0, rows * ROW_HEIGHT)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", DawKitLook.box(DawKitLook.BACKGROUND, 2))
	panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var box := VBoxContainer.new()
	box.name = title.capitalize()
	box.add_theme_constant_override("separation", 1)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	panel.add_child(box)
	scroll.add_child(panel)
	column.add_child(scroll)
	return box


func _add_button(column: VBoxContainer, text: String, tip: String, edit: StringName) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_NONE
	b.add_theme_font_size_override("font_size", DawKitLook.SMALL_FONT_SIZE)
	b.add_theme_constant_override("h_separation", 0)
	b.custom_minimum_size = Vector2(0, 18)
	b.disabled = not host.can(edit)
	column.add_child(b)
	return b


## The chain, a row per effect: its on/off, and its name to open it. Rows are made again only
## when the chain changed, not every time a control on it moves.
func _show_effects(t: DawKitTrack) -> void:
	var shown := t.effects.map(func(e: DawKitEffect): return [e.name, e.enabled])
	if shown == _effects_shown:
		return
	_effects_shown = shown
	for child in effects_box.get_children():
		child.queue_free()
		effects_box.remove_child(child)
	for i in t.effects.size():
		var e := t.effects[i]
		var row := HBoxContainer.new()
		row.name = "Effect%d" % i
		row.add_theme_constant_override("separation", 1)
		var power := Button.new()
		power.name = "On"
		power.toggle_mode = true
		power.button_pressed = e.enabled
		power.text = ""
		power.focus_mode = Control.FOCUS_NONE
		power.custom_minimum_size = Vector2(12, ROW_HEIGHT - 2)
		power.tooltip_text = "On or bypassed"
		power.add_theme_stylebox_override("normal", DawKitLook.box(DawKitLook.PANEL_LIGHT.darkened(0.3), 2))
		power.add_theme_stylebox_override("pressed", DawKitLook.box(DawKitLook.PLAY, 2))
		power.add_theme_stylebox_override("hover_pressed", DawKitLook.box(DawKitLook.PLAY.lightened(0.1), 2))
		power.disabled = not host.can(DawKitHost.EFFECTS)
		var index := i
		power.toggled.connect(func(on: bool): host.set_effect_enabled(id, index, on))
		row.add_child(power)
		var open := Button.new()
		open.name = "Name"
		open.text = e.name if not e.name.is_empty() else e.kind
		open.tooltip_text = open.text + "  (click: its controls, right-click: more, drag: move it)"
		open.flat = true
		open.clip_text = true
		open.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		open.alignment = HORIZONTAL_ALIGNMENT_LEFT
		open.focus_mode = Control.FOCUS_NONE
		open.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		open.custom_minimum_size = Vector2(0, ROW_HEIGHT - 2)
		open.add_theme_font_size_override("font_size", DawKitLook.SMALL_FONT_SIZE)
		if not e.enabled:
			open.add_theme_color_override("font_color", DawKitLook.TEXT_DIM.darkened(0.2))
		open.pressed.connect(func(): effect_opened.emit(id, index))
		open.gui_input.connect(func(ev: InputEvent):
			if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_RIGHT:
				open_effect_menu(index, ev.global_position))
		open.set_drag_forwarding(_drag_effect.bind(index), _can_drop_effect.bind(index), _drop_effect.bind(index))
		row.add_child(open)
		effects_box.add_child(row)


## The sends, a row per send: where it goes, and its level. Rows are made again only when the
## sends themselves changed.
func _show_sends(t: DawKitTrack) -> void:
	var p := host.project()
	var shown := t.sends.map(func(sd: DawKitSend): return [sd.target, sd.pre_fader])
	if shown != _sends_shown:
		_sends_shown = shown
		for child in sends_box.get_children():
			child.queue_free()
			sends_box.remove_child(child)
		for i in t.sends.size():
			var row := HBoxContainer.new()
			row.name = "Send%d" % i
			row.add_theme_constant_override("separation", 2)
			var to := Label.new()
			to.name = "To"
			to.custom_minimum_size = Vector2(34, 0)
			to.clip_text = true
			to.mouse_filter = Control.MOUSE_FILTER_STOP
			to.add_theme_font_size_override("font_size", DawKitLook.SMALL_FONT_SIZE - 1)
			var index := i
			to.gui_input.connect(func(ev: InputEvent):
				if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_RIGHT:
					open_send_menu(index, ev.global_position))
			row.add_child(to)
			var level := HSlider.new()
			level.name = "Level"
			level.min_value = 0.0
			level.max_value = 1.0
			level.step = 0.0
			level.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			level.editable = host.can(DawKitHost.SENDS)
			level.value_changed.connect(func(v: float): host.set_send_level(id, index, DawKitLook.db_of(v)))
			row.add_child(level)
			sends_box.add_child(row)
	for i in t.sends.size():
		var sd := t.sends[i]
		var row := sends_box.get_child(i)
		var target := p.track(sd.target) if p != null else null
		var to := row.get_node("To") as Label
		to.text = (target.name if target != null and not target.name.is_empty() else sd.target) + ("" if not sd.pre_fader else "*")
		(row.get_node("Level") as HSlider).set_value_no_signal(DawKitLook.fader_of(sd.volume_db))
		var words := "to %s, %s dB, %s" % [to.text.trim_suffix("*"), DawKitLook.db_text(sd.volume_db), "before the fader" if sd.pre_fader else "after the fader"]
		to.tooltip_text = words + "  (right-click: more)"
		(row.get_node("Level") as HSlider).tooltip_text = words


func _menu_ready() -> PopupMenu:
	if _menu == null:
		_menu = PopupMenu.new()
		_menu.name = "StripMenu"
		add_child(_menu)
		_menu.id_pressed.connect(func(item: int): (_menu.get_meta(&"do") as Callable).call(item))
	_menu.clear()
	return _menu


func _pop(menu: PopupMenu, at: Vector2, done: Callable) -> void:
	menu.set_meta(&"do", done)
	menu.position = Vector2i(at)
	menu.reset_size()
	menu.popup()


## The effects to add, the host's own first, then one list per plugin format ("VST3: Name" goes
## under VST3), so hundreds of plugins are not one menu.
func _open_effect_choices() -> void:
	var menu := _menu_ready()
	for child in menu.get_children():
		if child is PopupMenu:
			child.queue_free()
	var choices := host.effect_choices()
	var groups := {}
	for i in choices.size():
		var label := str(choices[i][1])
		var colon := label.find(": ")
		if colon > 0 and colon <= 6:
			var format := label.substr(0, colon)
			if not groups.has(format):
				var sub := PopupMenu.new()
				sub.name = "Format_" + format.validate_node_name()
				sub.id_pressed.connect(func(item: int): menu.id_pressed.emit(item))
				menu.add_child(sub)
				groups[format] = sub
			(groups[format] as PopupMenu).add_item(label.substr(colon + 2), i)
		else:
			menu.add_item(label, i)
	if not groups.is_empty():
		menu.add_separator()
		var formats: Array = groups.keys()
		formats.sort()
		for format in formats:
			menu.add_submenu_node_item(format, groups[format])
	_pop(menu, add_effect_button.get_screen_position() + Vector2(0, add_effect_button.size.y),
			func(item: int): host.add_effect(id, str(choices[item][0])))


func _open_send_targets() -> void:
	var menu := _menu_ready()
	var p := host.project()
	var targets: Array = p.tracks.filter(func(t: DawKitTrack): return t.id != id) if p != null else []
	for i in targets.size():
		menu.add_item(targets[i].name if not targets[i].name.is_empty() else targets[i].id, i)
	_pop(menu, add_send_button.get_screen_position() + Vector2(0, add_send_button.size.y),
			func(item: int): host.add_send(id, targets[item].id))


func open_effect_menu(index: int, at: Vector2) -> void:
	var t := host.project().track(id)
	if t == null or index >= t.effects.size():
		return
	var menu := _menu_ready()
	var effects := host.can(DawKitHost.EFFECTS)
	var order := host.can(DawKitHost.EFFECT_ORDER)
	menu.add_item("Controls", 0)
	menu.add_item("Bypass" if t.effects[index].enabled else "Turn on", 1)
	menu.add_item("Earlier in the chain", 2)
	menu.add_item("Later in the chain", 3)
	menu.add_separator()
	menu.add_item("Remove", 4)
	menu.set_item_disabled(1, not effects)
	menu.set_item_disabled(2, not order or index == 0)
	menu.set_item_disabled(3, not order or index == t.effects.size() - 1)
	menu.set_item_disabled(5, not effects)
	_pop(menu, at, _on_effect_menu.bind(index, t.effects[index].enabled))


func _on_effect_menu(item: int, index: int, enabled: bool) -> void:
	match item:
		0:
			effect_opened.emit(id, index)
		1:
			host.set_effect_enabled(id, index, not enabled)
		2:
			host.move_effect(id, index, "", index - 1)
		3:
			host.move_effect(id, index, "", index + 1)
		4:
			host.remove_effect(id, index)


func open_send_menu(index: int, at: Vector2) -> void:
	var t := host.project().track(id)
	if t == null or index >= t.sends.size():
		return
	var menu := _menu_ready()
	var pre := t.sends[index].pre_fader
	menu.add_check_item("Before the fader", 0)
	menu.set_item_checked(0, pre)
	menu.add_item("Level back to 0 dB", 1)
	menu.add_separator()
	menu.add_item("Remove", 2)
	for i in menu.item_count:
		if not menu.is_item_separator(i):
			menu.set_item_disabled(i, not host.can(DawKitHost.SENDS))
	_pop(menu, at, _on_send_menu.bind(index, pre))


func _on_send_menu(item: int, index: int, pre: bool) -> void:
	match item:
		0:
			host.set_send_pre_fader(id, index, not pre)
		1:
			host.set_send_level(id, index, 0.0)
		2:
			host.remove_send(id, index)


func _drag_effect(_at: Vector2, index: int) -> Variant:
	if not host.can(DawKitHost.EFFECT_ORDER):
		return null
	var t := host.project().track(id)
	var preview := Label.new()
	preview.text = t.effects[index].name
	preview.add_theme_color_override("font_color", DawKitLook.ACCENT)
	set_drag_preview(preview)
	return {"dawkit_effect": [id, index]}


func _can_drop_effect(_at: Vector2, data: Variant, _index: int) -> bool:
	return data is Dictionary and data.has("dawkit_effect") and host.can(DawKitHost.EFFECT_ORDER)


## An effect dropped on a row lands in that row's place; dropped on the chain, at its end.
func _drop_effect(_at: Vector2, data: Variant, index: int) -> void:
	var from: Array = data["dawkit_effect"]
	var t := host.project().track(id)
	var to := index if index >= 0 else t.effects.size() - (1 if from[0] == id else 0)
	host.move_effect(from[0], from[1], id, to)
