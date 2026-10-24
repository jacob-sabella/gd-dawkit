class_name DawKitMixer
extends HBoxContainer

## The mixer: a strip per track in project order, scrolling sideways when they do not fit, and
## the master's strip held at the right edge.

signal effect_opened(id: String, index: int)

var host: DawKitHost
var strips: Dictionary = {}  # id -> DawKitStrip
var _row: HBoxContainer
var _scroll: ScrollContainer
var _master: DawKitStrip


func _init(with_host: DawKitHost) -> void:
	host = with_host
	name = "Mixer"
	add_theme_constant_override("separation", 6)
	_scroll = ScrollContainer.new()
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.vertical_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	add_child(_scroll)
	_row = HBoxContainer.new()
	_row.add_theme_constant_override("separation", 2)
	_row.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.add_child(_row)
	_master = DawKitStrip.new(host, DawKitProject.MASTER_ID)
	add_child(_master)


## Lays out a strip per track again, for a project whose tracks changed.
func rebuild() -> void:
	for child in _row.get_children():
		child.queue_free()
		_row.remove_child(child)
	strips.clear()
	var p := host.project()
	_master.visible = p != null
	if p == null:
		return
	strips[DawKitProject.MASTER_ID] = _master
	for t in p.tracks:
		var strip := DawKitStrip.new(host, t.id)
		strip.effect_opened.connect(func(i: String, n: int): effect_opened.emit(i, n))
		_row.add_child(strip)
		strips[t.id] = strip
		strip.show_track(t)
	_master.show_track(p.master)


func show_track(id: String) -> void:
	var p := host.project()
	var strip: DawKitStrip = strips.get(id)
	var t := p.track(id) if p != null else null
	if strip != null and t != null:
		strip.show_track(t)


func show_levels() -> void:
	for id in strips:
		strips[id].show_level(host.meter(id))
