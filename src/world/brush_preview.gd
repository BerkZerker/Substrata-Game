## World-space outline showing where/how large the next terrain edit will be.
## Tracks the mouse in world coordinates; reads brush size from GameServices
## directly (same lazy-lookup pattern as DebugHUD/CursorInfo use for chunk_manager).
class_name BrushPreview extends Node2D


func _ready() -> void:
	# Value can change (Q/E) without the mouse moving, so redraw on that too.
	SignalBus.brush_value_changed.connect(func(_value: float): queue_redraw())


func _process(_delta: float) -> void:
	var camera = get_viewport().get_camera_2d()
	if not camera:
		return

	# Snap to whole tiles to match where an edit would actually land, and only
	# redraw when the tile actually changes rather than every frame.
	var snapped_pos = camera.get_global_mouse_position().snapped(Vector2(1, 1))
	if snapped_pos != global_position:
		global_position = snapped_pos
		queue_redraw()


func _draw() -> void:
	if not GameServices.terrain_edit_controller:
		return

	var r = roundi(GameServices.terrain_edit_controller.get_current_brush_value())
	draw_circle(Vector2.ZERO, r, Color(1, 1, 1, 0.5), false, 1.0)
