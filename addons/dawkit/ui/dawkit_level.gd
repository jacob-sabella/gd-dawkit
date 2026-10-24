class_name DawKitLevel
extends Control

## A two-channel level meter: each channel's peak as a bar from the bottom, green to yellow to
## red, falling back at a steady rate so a peak can be seen, and a line where 0 dB is.

## How fast a bar falls, in travel per second.
const FALL := 1.6

var _shown := Vector2.ZERO


## The peaks now, 0..1 of full scale. A bar jumps up to a peak and falls back from it.
func set_peaks(peaks: Vector2) -> void:
	var fall := FALL * get_process_delta_time() if is_inside_tree() else 1.0
	var next := Vector2(maxf(_level(peaks.x), _shown.x - fall), maxf(_level(peaks.y), _shown.y - fall))
	if not next.is_equal_approx(_shown):
		_shown = next
		queue_redraw()


func shown() -> Vector2:
	return _shown


## A peak's height on the meter, on the same law as the fader beside it.
static func _level(peak: float) -> float:
	return DawKitLook.fader_of(linear_to_db(peak)) if peak > 0.0 else 0.0


func _draw() -> void:
	var w := floorf((size.x - 1.0) * 0.5)
	for ch in 2:
		var x := ch * (w + 1.0)
		draw_rect(Rect2(x, 0, w, size.y), DawKitLook.BACKGROUND)
		var h := _shown[ch] * size.y
		var top := size.y - h
		var yellow := size.y * (1.0 - DawKitLook.fader_of(-6.0))
		var red := size.y * (1.0 - DawKitLook.fader_of(0.0))
		if h > 0.0:
			draw_rect(Rect2(x, maxf(top, yellow), w, size.y - maxf(top, yellow)), DawKitLook.METER_LOW)
		if top < yellow:
			draw_rect(Rect2(x, maxf(top, red), w, yellow - maxf(top, red)), DawKitLook.METER_HIGH)
		if top < red:
			draw_rect(Rect2(x, top, w, red - top), DawKitLook.METER_CLIP)
	var zero := size.y * (1.0 - DawKitLook.fader_of(0.0))
	draw_line(Vector2(0, zero), Vector2(size.x, zero), DawKitLook.TEXT_DIM, 1.0)
