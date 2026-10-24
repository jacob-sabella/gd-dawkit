class_name DawKitLook
extends RefCounted

## How dawkit's 2D interface looks and counts: its colours, its theme, its fader law, and how it
## writes a time. One place, so every part of the interface agrees, and a host can restyle the
## lot by replacing `theme()` on the DawKitStudio it makes.

const BACKGROUND := Color(0.11, 0.115, 0.13)
const PANEL := Color(0.15, 0.155, 0.175)
const PANEL_LIGHT := Color(0.2, 0.205, 0.23)
const LINE := Color(0.25, 0.26, 0.29)
const TEXT := Color(0.86, 0.87, 0.9)
const TEXT_DIM := Color(0.56, 0.58, 0.63)
const ACCENT := Color(0.98, 0.66, 0.24)
const PLAYHEAD := Color(0.98, 0.98, 1.0)
const LOOP := Color(0.4, 0.66, 0.95)
## The colours that mean something -- mute, solo, record, playing, a meter's safe, loud and over --
## kept apart from decoration because a host may need them told apart by eyes that see colour
## differently: `use_signals` replaces them, before a DawKitStudio is made.
static var MUTE := Color(0.93, 0.62, 0.22)
static var SOLO := Color(0.95, 0.85, 0.3)
static var ARM := Color(0.9, 0.28, 0.28)
static var PLAY := Color(0.4, 0.82, 0.45)
static var METER_LOW := Color(0.36, 0.8, 0.42)
static var METER_HIGH := Color(0.95, 0.8, 0.3)
static var METER_CLIP := Color(0.95, 0.3, 0.26)
const SIGNALS_AS_MADE := {"mute": Color(0.93, 0.62, 0.22), "solo": Color(0.95, 0.85, 0.3), "record": Color(0.9, 0.28, 0.28),
		"ok": Color(0.36, 0.8, 0.42), "warn": Color(0.95, 0.8, 0.3), "over": Color(0.95, 0.3, 0.26)}

## Text sizes, at `text_scale` (set_text_scale), before a DawKitStudio is made.
const BASE_FONT_SIZE := 13
const BASE_SMALL_FONT_SIZE := 11
static var text_scale := 1.0
static var FONT_SIZE := BASE_FONT_SIZE
static var SMALL_FONT_SIZE := BASE_SMALL_FONT_SIZE

## The loudest a fader goes, and the quietest it says a number for (below it is -inf).
const FADER_MAX_DB := 12.0
const FADER_FLOOR_DB := -96.0
## What a fader at the very bottom stands for: silence, said as a number a project can keep.
const SILENT_DB := -150.0


## A fader's travel 0..1 for a level in decibels: the fourth root of the gain, so the top of the
## travel is fine (a millimetre is a fraction of a dB around 0) and the bottom is coarse, as on a
## desk. 0 dB is a little under three-quarters of the way up.
static func fader_of(db: float) -> float:
	if db <= FADER_FLOOR_DB:
		return 0.0
	return clampf(pow(db_to_linear(db) / db_to_linear(FADER_MAX_DB), 0.25), 0.0, 1.0)


## `fader_of`'s inverse.
static func db_of(travel: float) -> float:
	if travel <= 0.0:
		return SILENT_DB
	var db := linear_to_db(pow(clampf(travel, 0.0, 1.0), 4.0) * db_to_linear(FADER_MAX_DB))
	return SILENT_DB if db <= FADER_FLOOR_DB else db


## A level as a desk writes it: "-4.2", "+1.5", "-inf".
static func db_text(db: float) -> String:
	if db <= FADER_FLOOR_DB:
		return "-inf"
	return ("+%.1f" if db > 0.05 else "%.1f") % db


## A pan as a desk writes it: "C", "L40", "R100".
static func pan_text(pan: float) -> String:
	var p := roundi(pan * 100.0)
	return "C" if p == 0 else ("L%d" % -p if p < 0 else "R%d" % p)


## A moment of the song as bars and beats ("12.3.50") with the project's own meter and tempo.
static func bars_text(p: DawKitProject, seconds: float) -> String:
	var beat := p.tempo_map().beat_at(maxf(seconds, 0.0))
	var at: Array = p.meter().position(beat)
	return "%d.%d.%02d" % [at[0], at[1], mini(floori(float(at[2]) * 100.0), 99)]


## A moment as minutes, seconds and milliseconds: "1:04.250".
static func clock_text(seconds: float) -> String:
	seconds = maxf(seconds, 0.0)
	var whole := floori(seconds)
	return "%d:%02d.%03d" % [whole / 60, whole % 60, floori((seconds - whole) * 1000.0)]


## The signal colours, by role: "mute", "solo", "record", "ok" (playing, a meter's safe range),
## "warn" (a meter's loud range), "over". A role left out keeps its colour; an empty one puts
## them all back as dawkit has them.
static func use_signals(colours: Dictionary) -> void:
	var c := SIGNALS_AS_MADE.duplicate()
	c.merge(colours, true)
	MUTE = c["mute"]
	SOLO = c["solo"]
	ARM = c["record"]
	PLAY = c["ok"]
	METER_LOW = c["ok"]
	METER_HIGH = c["warn"]
	METER_CLIP = c["over"]


## Every size of text times `scale` (0.75 to 2), for a reader who needs it bigger.
static func set_text_scale(scale: float) -> void:
	text_scale = clampf(scale, 0.75, 2.0)
	FONT_SIZE = roundi(BASE_FONT_SIZE * text_scale)
	SMALL_FONT_SIZE = roundi(BASE_SMALL_FONT_SIZE * text_scale)


## The interface's theme: dark panels, flat buttons that light in a colour when on.
static func theme() -> Theme:
	var t := Theme.new()
	t.default_font_size = FONT_SIZE
	t.set_color("font_color", "Label", TEXT)
	t.set_stylebox("panel", "PanelContainer", box(PANEL))
	t.set_stylebox("panel", "Panel", box(PANEL))
	for kind in ["Button", "OptionButton"]:
		t.set_stylebox("normal", kind, box(PANEL_LIGHT, 3, LINE))
		t.set_stylebox("hover", kind, box(PANEL_LIGHT.lightened(0.08), 3, LINE.lightened(0.2)))
		t.set_stylebox("pressed", kind, box(PANEL_LIGHT.darkened(0.2), 3, ACCENT))
		t.set_stylebox("hover_pressed", kind, box(PANEL_LIGHT.darkened(0.1), 3, ACCENT))
		t.set_stylebox("disabled", kind, box(PANEL.darkened(0.1), 3, LINE.darkened(0.2)))
		t.set_stylebox("focus", kind, StyleBoxEmpty.new())
		t.set_color("font_color", kind, TEXT)
		t.set_color("font_hover_color", kind, TEXT)
		t.set_color("font_pressed_color", kind, ACCENT)
		t.set_color("font_hover_pressed_color", kind, ACCENT)
		t.set_color("font_disabled_color", kind, TEXT_DIM.darkened(0.3))
	t.set_stylebox("normal", "LineEdit", box(BACKGROUND, 3, LINE))
	t.set_stylebox("focus", "LineEdit", box(BACKGROUND, 3, ACCENT))
	t.set_color("font_color", "LineEdit", TEXT)
	t.set_stylebox("slider", "VSlider", box(BACKGROUND, 2, LINE))
	t.set_stylebox("slider", "HSlider", box(BACKGROUND, 2, LINE))
	t.set_stylebox("grabber_area", "VSlider", box(BACKGROUND, 2, LINE))
	t.set_stylebox("grabber_area", "HSlider", box(BACKGROUND, 2, LINE))
	t.set_stylebox("grabber_area_highlight", "VSlider", box(BACKGROUND, 2, LINE))
	t.set_stylebox("grabber_area_highlight", "HSlider", box(BACKGROUND, 2, LINE))
	t.set_icon("grabber", "VSlider", _cap(Vector2i(26, 12)))
	t.set_icon("grabber_highlight", "VSlider", _cap(Vector2i(26, 12), true))
	t.set_icon("grabber", "HSlider", _cap(Vector2i(10, 14)))
	t.set_icon("grabber_highlight", "HSlider", _cap(Vector2i(10, 14), true))
	t.set_stylebox("panel", "TabContainer", box(PANEL))
	t.set_stylebox("tab_selected", "TabContainer", box(PANEL_LIGHT, 0, ACCENT))
	t.set_stylebox("tab_unselected", "TabContainer", box(PANEL, 0))
	t.set_stylebox("tab_hovered", "TabContainer", box(PANEL_LIGHT, 0))
	t.set_color("font_selected_color", "TabContainer", ACCENT)
	t.set_color("font_unselected_color", "TabContainer", TEXT_DIM)
	t.set_color("font_hovered_color", "TabContainer", TEXT)
	t.set_stylebox("split_bar_background", "VSplitContainer", box(LINE, 0))
	return t


static func box(fill: Color, radius := 0, border := Color(0, 0, 0, 0)) -> StyleBoxFlat:
	var b := StyleBoxFlat.new()
	b.bg_color = fill
	b.set_corner_radius_all(radius)
	if border.a > 0.0:
		b.set_border_width_all(1)
		b.border_color = border
	b.content_margin_left = 6
	b.content_margin_right = 6
	b.content_margin_top = 3
	b.content_margin_bottom = 3
	return b


## A fader cap: a light bar with a line across its middle where the level is read.
static func _cap(size: Vector2i, lit := false) -> ImageTexture:
	var img := Image.create(size.x, size.y, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.78, 0.79, 0.82) if not lit else Color(0.9, 0.91, 0.94))
	for x in size.x:
		img.set_pixel(x, 0, Color(0.4, 0.41, 0.44))
		img.set_pixel(x, size.y - 1, Color(0.3, 0.31, 0.34))
		img.set_pixel(x, size.y / 2, Color(0.15, 0.15, 0.17))
	return ImageTexture.create_from_image(img)
