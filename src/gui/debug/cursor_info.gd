## Small tooltip-style readout that follows the mouse and shows the tile
## under the cursor. Visible by default; F2 toggles it off.
class_name CursorInfo extends Control

const UPDATE_INTERVAL: float = 0.05 # Tile lookups are throttled to this interval, not every frame

@onready var _label: Label = %Label

var _time_since_update: float = 0.0


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_cursor_info"):
		visible = not visible


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
	var tile_id: int = tile_data[0]
	var damage_stage: int = tile_data[1]
	var tile_name = TileIndex.get_tile_name(tile_id)
	var hardness = TileIndex.get_hardness(tile_id)
	var eff_hardness = TileIndex.get_effective_hardness(tile_id, damage_stage)

	if tile_id == TileIndex.AIR:
		_label.text = "(%d, %d) %s" % [int(tile_pos.x), int(tile_pos.y), tile_name]
	else:
		_label.text = "(%d, %d) %s  H:%d  Eff:%.1f  Dmg:%d/%d" % [
			int(tile_pos.x), int(tile_pos.y), tile_name,
			hardness, eff_hardness, damage_stage, TileIndex.get_damage_stages(tile_id)
		]
