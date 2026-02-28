class_name BrushPreview extends Node2D

var _gui_manager: GUIManager


func setup(manager: GUIManager) -> void:
	_gui_manager = manager


func _draw() -> void:
	if not _gui_manager:
		return

	var r = _gui_manager.get_brush_size()
	var color = Color(1, 1, 1, 0.5)

	if _gui_manager.get_brush_type() == GUIManager.BRUSH_SQUARE:
		var size = r * 2 + 1
		draw_rect(Rect2(Vector2(-r, -r), Vector2(size, size)), color, false, 1.0)
	elif _gui_manager.get_brush_type() == GUIManager.BRUSH_CIRCLE:
		draw_circle(Vector2.ZERO, r, color, false, 1.0)
