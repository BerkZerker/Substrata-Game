class_name CursorInfo extends Control

const UPDATE_INTERVAL: float = 0.05

var _label: Label
var _time_since_update: float = 0.0


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE

	_label = Label.new()
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_label.add_theme_font_size_override("font_size", 13)
	_label.add_theme_color_override("font_color", Color(1.0, 1.0, 1.0, 0.9))
	_label.add_theme_color_override("font_shadow_color", Color(0, 0, 0, 0.8))
	_label.add_theme_constant_override("shadow_offset_x", 1)
	_label.add_theme_constant_override("shadow_offset_y", 1)
	add_child(_label)


func _process(delta: float) -> void:
	if not visible:
		return

	# Position near mouse cursor
	position = get_viewport().get_mouse_position() + Vector2(16, 16)

	# Throttle tile lookups
	_time_since_update += delta
	if _time_since_update < UPDATE_INTERVAL:
		return
	_time_since_update = 0.0

	if not GameServices.chunk_manager:
		return

	var camera = get_viewport().get_camera_2d()
	if not camera:
		return

	var world_pos = camera.get_global_mouse_position()
	var tile_pos = world_pos.floor()
	var tile_data = GameServices.chunk_manager.get_tile_at_world_pos(world_pos)
	var tile_name = TileIndex.get_tile_name(tile_data[0])

	_label.text = "(%d, %d) %s" % [int(tile_pos.x), int(tile_pos.y), tile_name]
