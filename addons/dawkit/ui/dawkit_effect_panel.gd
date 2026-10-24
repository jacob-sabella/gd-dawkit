class_name DawKitEffectPanel
extends PanelContainer

## One effect's controls, beside the arrangement: which track and effect it is, on or bypassed,
## how wet, and a slider for every control it has, with the value as the effect says it (or a
## percentage). Opened from an effect's name on a mixer strip; closed with its X.

const WIDTH := 300

var host: DawKitHost
## The effect shown: its track and its place in the chain. "" when none.
var id := ""
var index := -1

var title: Label
var power: Button
var wet: HSlider
var wet_label: Label
var controls: VBoxContainer
var _names := []


func _init(with_host: DawKitHost) -> void:
	host = with_host
	name = "EffectPanel"
	custom_minimum_size = Vector2(WIDTH, 0)
	add_theme_stylebox_override("panel", DawKitLook.box(DawKitLook.PANEL, 0))
	visible = false
	var column := VBoxContainer.new()
	column.add_theme_constant_override("separation", 6)
	add_child(column)
	var top := HBoxContainer.new()
	column.add_child(top)
	title = Label.new()
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.clip_text = true
	title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title.add_theme_color_override("font_color", DawKitLook.ACCENT)
	top.add_child(title)
	var close := Button.new()
	close.name = "Close"
	close.text = "X"
	close.focus_mode = Control.FOCUS_NONE
	close.tooltip_text = "Close"
	close.pressed.connect(func(): show_effect("", -1))
	top.add_child(close)
	var row := HBoxContainer.new()
	column.add_child(row)
	power = Button.new()
	power.name = "On"
	power.text = "ON"
	power.toggle_mode = true
	power.focus_mode = Control.FOCUS_NONE
	power.tooltip_text = "On, or bypassed"
	power.add_theme_stylebox_override("pressed", DawKitLook.box(DawKitLook.PLAY, 3))
	power.add_theme_stylebox_override("hover_pressed", DawKitLook.box(DawKitLook.PLAY.lightened(0.1), 3))
	power.add_theme_color_override("font_pressed_color", Color(0.08, 0.08, 0.09))
	power.add_theme_color_override("font_hover_pressed_color", Color(0.08, 0.08, 0.09))
	power.toggled.connect(func(on: bool): host.set_effect_enabled(id, index, on))
	row.add_child(power)
	var wet_name := Label.new()
	wet_name.text = "  WET"
	wet_name.add_theme_color_override("font_color", DawKitLook.TEXT_DIM)
	row.add_child(wet_name)
	wet = HSlider.new()
	wet.name = "Wet"
	wet.min_value = 0.0
	wet.max_value = 1.0
	wet.step = 0.0
	wet.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wet.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	wet.value_changed.connect(func(v: float): host.set_effect_wet(id, index, v))
	row.add_child(wet)
	wet_label = Label.new()
	wet_label.custom_minimum_size = Vector2(44, 0)
	wet_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	row.add_child(wet_label)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	column.add_child(scroll)
	controls = VBoxContainer.new()
	controls.name = "Controls"
	controls.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	controls.add_theme_constant_override("separation", 2)
	scroll.add_child(controls)


## Shows effect `at` of track `track_id`, or closes for "".
func show_effect(track_id: String, at: int) -> void:
	id = track_id
	index = at
	_names = []
	for child in controls.get_children():
		child.queue_free()
		controls.remove_child(child)
	visible = not id.is_empty()
	if visible:
		host.watch_effect(id, index)
		refresh()


## Shows the effect as the host says it is now. Closes when it is not there any more.
func refresh() -> void:
	if id.is_empty():
		return
	var p := host.project()
	var t := p.track(id) if p != null else null
	if t == null or index < 0 or index >= t.effects.size():
		show_effect("", -1)
		return
	var e := t.effects[index]
	title.text = "%s  >  %s" % [t.name if not t.name.is_empty() else t.id, e.name if not e.name.is_empty() else e.kind]
	title.tooltip_text = title.text
	var editable := host.can(DawKitHost.EFFECTS)
	power.disabled = not editable
	power.set_pressed_no_signal(e.enabled)
	wet.editable = editable
	wet.set_value_no_signal(e.wet)
	wet_label.text = "%d%%" % roundi(e.wet * 100.0)
	var names := []
	for n in e.values.size():
		names.append(e.names[n] if n < e.names.size() and not e.names[n].is_empty() else "Control %d" % (n + 1))
	if names != _names:
		_names = names
		for child in controls.get_children():
			child.queue_free()
			controls.remove_child(child)
		for n in names.size():
			controls.add_child(_control_row(n, names[n], editable))
		if names.is_empty():
			var none := Label.new()
			none.text = "No controls to show."
			none.add_theme_color_override("font_color", DawKitLook.TEXT_DIM)
			controls.add_child(none)
	for n in e.values.size():
		var row := controls.get_child(n)
		(row.get_node("Slider") as HSlider).set_value_no_signal(e.values[n])
		var said := host.effect_value_text(id, index, n)
		(row.get_node("Top/Value") as Label).text = said if not said.is_empty() else "%d%%" % roundi(e.values[n] * 100.0)


func _control_row(param: int, label: String, editable: bool) -> Control:
	var row := VBoxContainer.new()
	row.name = "Control%d" % param
	row.add_theme_constant_override("separation", 0)
	var top := HBoxContainer.new()
	top.name = "Top"
	row.add_child(top)
	var named := Label.new()
	named.text = label
	named.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	named.clip_text = true
	named.add_theme_font_size_override("font_size", DawKitLook.SMALL_FONT_SIZE)
	top.add_child(named)
	var value := Label.new()
	value.name = "Value"
	value.add_theme_font_size_override("font_size", DawKitLook.SMALL_FONT_SIZE)
	value.add_theme_color_override("font_color", DawKitLook.ACCENT)
	top.add_child(value)
	var slider := HSlider.new()
	slider.name = "Slider"
	slider.min_value = 0.0
	slider.max_value = 1.0
	slider.step = 0.0
	slider.editable = editable
	slider.value_changed.connect(func(v: float): host.set_effect_value(id, index, param, v))
	row.add_child(slider)
	return row
