extends Node2D

func _draw() -> void:
	var manager = get_meta("gui_manager")
	if not manager:
		return

	var r = manager._current_brush_size
	var color = Color(1, 1, 1, 0.5)

	if manager._current_brush_type == manager.BRUSH_SQUARE:
		var size = r * 2 + 1
		draw_rect(Rect2(Vector2(-r, -r), Vector2(size, size)), color, false, 1.0)
	elif manager._current_brush_type == manager.BRUSH_CIRCLE:
		draw_circle(Vector2.ZERO, r, color, false, 1.0)
