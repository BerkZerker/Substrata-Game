## Mouse/keyboard-driven terrain editing: digging, placing, material + brush value selection.
##
## Lives outside src/gui/ on purpose: this is gameplay input, not UI. It uses
## _unhandled_input rather than a full-screen Control, so real GUI widgets
## (e.g. the hotbar) naturally consume clicks before they ever reach here.
class_name TerrainEditController extends Node

var _terrain_editor: TerrainEditor = TerrainEditor.new()

var _current_material: int = TileIndex.STONE
# Single value driving both LMB dig force and RMB place radius (brush is circle-only).
var _current_brush_value: float = float(GlobalSettings.DEFAULT_BRUSH_VALUE)
var _is_editing: bool = false
var _is_destroying: bool = false
var _last_edit_tile_pos: Vector2 = Vector2(INF, INF)


func _process(_delta: float) -> void:
	if _is_destroying:
		_apply_destroy()
	elif _is_editing:
		_apply_edit()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		# Only reaches here if no Control (e.g. a hotbar slot) already consumed the click.
		if event.button_index == MOUSE_BUTTON_LEFT:
			_is_destroying = event.pressed
			if _is_destroying:
				_last_edit_tile_pos = Vector2(INF, INF)
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_is_editing = event.pressed
			if _is_editing:
				_last_edit_tile_pos = Vector2(INF, INF)
		return

	if not event is InputEventKey or not event.pressed:
		return

	if event.is_action_pressed("brush_value_decrease"):
		_change_brush_value(-1)
	elif event.is_action_pressed("brush_value_increase"):
		_change_brush_value(1)
	elif event.keycode == KEY_T:
		# Toggle debug terrain visualization
		if GameServices.chunk_manager:
			Chunk.debug_terrain = not Chunk.debug_terrain
			GameServices.chunk_manager.set_debug_terrain(Chunk.debug_terrain)

	# Material selection: number keys 1-9 map to tile IDs in registry order.
	# Kept as a raw keycode loop (rather than 9 fixed InputMap actions) since the
	# material list is data-driven from TileIndex, not a fixed set.
	var number_keys = [KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7, KEY_8, KEY_9]
	var tile_ids = TileIndex.get_tile_ids()
	for i in range(mini(number_keys.size(), tile_ids.size())):
		if event.keycode == number_keys[i]:
			set_material(tile_ids[i])


## Called both from the number-key handler above and externally by the hotbar on click.
func set_material(tile_id: int) -> void:
	_current_material = tile_id
	SignalBus.material_selected.emit(tile_id)


func _change_brush_value(delta: int) -> void:
	_current_brush_value = clampf(_current_brush_value + delta, 1.0, float(GlobalSettings.MAX_BRUSH_VALUE))
	SignalBus.brush_value_changed.emit(_current_brush_value)


## Returns the current material tile ID.
func get_current_material() -> int:
	return _current_material


## Returns the current brush value (dig force / place radius).
func get_current_brush_value() -> float:
	return _current_brush_value


## Left-click: force-based terrain destruction via Dijkstra flood fill.
func _apply_destroy() -> void:
	var mouse_pos = get_viewport().get_camera_2d().get_global_mouse_position()
	var center_tile = mouse_pos.floor()

	# Skip if mouse hasn't moved to a new tile position
	if center_tile == _last_edit_tile_pos:
		return
	_last_edit_tile_pos = center_tile

	if GameServices.chunk_manager:
		_terrain_editor.edit_at(center_tile, _current_brush_value, GameServices.chunk_manager)


## Right-click: place tiles in a circle sized by the current brush value.
func _apply_edit() -> void:
	var mouse_pos = get_viewport().get_camera_2d().get_global_mouse_position()
	var center_tile = mouse_pos.floor()

	# Skip if mouse hasn't moved to a new tile position
	if center_tile == _last_edit_tile_pos:
		return
	_last_edit_tile_pos = center_tile

	var changes = []
	var r = roundi(_current_brush_value)

	# Circle-only brush: square shape was removed, so this is just a radius test
	# over the bounding box rather than a shape-type branch.
	for x in range(-r, r + 1):
		for y in range(-r, r + 1):
			var offset = Vector2(x, y)
			if offset.length_squared() > r * r:
				continue

			changes.append({
				"pos": center_tile + offset,
				"tile_id": _current_material,
				"damage_stage": 0
			})

	if not changes.is_empty() and GameServices.chunk_manager:
		GameServices.chunk_manager.set_tiles_at_world_positions(changes)
