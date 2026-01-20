class_name GUIManager extends Control

# References
var _chunk_manager: ChunkManager = null
var _terrain_generator: TerrainGenerator = null

# UI Elements
var _panel: PanelContainer
var _brush_size_label: Label
var _brush_preview: Node2D

# State
var _current_brush_type: int = 0 # 0: Square, 1: Circle
var _current_brush_size: int = 2
var _current_material: int = TileIndex.STONE
var _is_breaking: bool = false # Left mouse - break/erase
var _is_placing: bool = false # Right mouse - place

# Constants
const BRUSH_SQUARE = 0
const BRUSH_CIRCLE = 1
const MAX_FLOOD_FILL_ITERATIONS = 500 # Safety limit for flood-fill


func _ready() -> void:
	_setup_ui()
	_setup_brush_preview()

func setup_chunk_manager(chunk_manager: ChunkManager) -> void:
	_chunk_manager = chunk_manager
	_terrain_generator = chunk_manager.get_terrain_generator()


func _process(_delta: float) -> void:
	_update_brush_preview()
	
	# Handle continuous editing while mouse is held
	if _is_breaking:
		_apply_break()
	elif _is_placing:
		_apply_place()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_is_breaking = event.pressed
			if _is_breaking:
				get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_is_placing = event.pressed
			if _is_placing:
				get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_Q:
			_change_brush_size(-1)
		elif event.keycode == KEY_E:
			_change_brush_size(1)


func _setup_ui() -> void:
	_panel = PanelContainer.new()
	add_child(_panel)
	_panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_panel.offset_top = -60
	_panel.offset_bottom = -10
	_panel.offset_left = 20
	_panel.offset_right = -20
	
	var hbox = HBoxContainer.new()
	_panel.add_child(hbox)
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	hbox.add_theme_constant_override("separation", 20)
	
	# Brush Type
	var type_label = Label.new()
	type_label.text = "Brush:"
	hbox.add_child(type_label)
	
	var btn_square = Button.new()
	btn_square.text = "Square"
	btn_square.pressed.connect(func(): _current_brush_type = BRUSH_SQUARE)
	hbox.add_child(btn_square)
	
	var btn_circle = Button.new()
	btn_circle.text = "Circle"
	btn_circle.pressed.connect(func(): _current_brush_type = BRUSH_CIRCLE)
	hbox.add_child(btn_circle)
	
	# Separator
	hbox.add_child(VSeparator.new())
	
	# Material
	var mat_label = Label.new()
	mat_label.text = "Material:"
	hbox.add_child(mat_label)
	
	var materials = {
		"Air (Eraser)": TileIndex.AIR,
		"Dirt": TileIndex.DIRT,
		"Grass": TileIndex.GRASS,
		"Stone": TileIndex.STONE
	}
	
	for mat in materials:
		var btn = Button.new()
		btn.text = mat
		btn.pressed.connect(func(): _current_material = materials[mat])
		hbox.add_child(btn)
		
	# Separator
	hbox.add_child(VSeparator.new())
	
	# Size
	_brush_size_label = Label.new()
	_brush_size_label.text = "Size: " + str(_current_brush_size)
	hbox.add_child(_brush_size_label)


func _change_brush_size(delta: int) -> void:
	_current_brush_size = clampi(_current_brush_size + delta, 1, 64)
	_brush_size_label.text = "Size: " + str(_current_brush_size)
	if _brush_preview:
		_brush_preview.queue_redraw()


func _setup_brush_preview() -> void:
	# Create a Node2D in the world (not UI) to follow mouse
	_brush_preview = Node2D.new()
	_brush_preview.z_index = 100 # On top of terrain
	# Add to GameInstance, not UI
	get_parent().get_parent().add_child.call_deferred(_brush_preview)
	
	# Add a custom draw script
	_brush_preview.set_script(load("res://src/gui/brush_preview.gd"))
	_brush_preview.set_meta("gui_manager", self) # Pass reference back


func _update_brush_preview() -> void:
	if not _brush_preview: return
	
	var mouse_pos = get_viewport().get_camera_2d().get_global_mouse_position()
	# Snap to grid
	var snapped_pos = mouse_pos.snapped(Vector2(1, 1))
	_brush_preview.global_position = snapped_pos
	_brush_preview.queue_redraw()


# Breaking logic (left-click) - removes terrain
func _apply_break() -> void:
	if not _chunk_manager:
		return
		
	var mouse_pos = get_viewport().get_camera_2d().get_global_mouse_position()
	var center_tile = mouse_pos.floor()
	
	# Get the tile at click position
	var tile_data = _chunk_manager.get_tile_at_world_pos(center_tile)
	var target_tile_id = tile_data[0]
	var target_cell_id = tile_data[1]
	
	# Can't break air
	if target_tile_id == TileIndex.AIR:
		return
	
	var changes = []
	
	if TileIndex.CELLULAR_MATERIALS.has(target_tile_id):
		# Cellular material (stone): flood-fill to find entire cell
		var positions = _flood_fill_cell(center_tile, target_tile_id, target_cell_id)
		for pos in positions:
			changes.append({
				"pos": pos,
				"tile_id": TileIndex.AIR,
				"cell_id": 0
			})
	else:
		# Amorphous material (dirt, grass): circle brush
		changes = _get_circle_brush_changes(center_tile, TileIndex.AIR, 0)
	
	if not changes.is_empty():
		_chunk_manager.set_tiles_at_world_positions(changes)


# Placing logic (right-click) - adds terrain
func _apply_place() -> void:
	if not _chunk_manager or not _terrain_generator:
		return
	
	# Can't place air
	if _current_material == TileIndex.AIR:
		return
		
	var mouse_pos = get_viewport().get_camera_2d().get_global_mouse_position()
	var center_tile = mouse_pos.floor()
	
	var changes = []
	
	if TileIndex.CELLULAR_MATERIALS.has(_current_material):
		# Cellular material: flood-fill to find procedural cell shape, only place in air
		# Use randomized cell_id so each placement has a different shape
		var target_cell_id = _terrain_generator.get_random_cell_id_at(center_tile)
		var positions = _flood_fill_procedural_cell_randomized(center_tile, target_cell_id)
		for pos in positions:
			changes.append({
				"pos": pos,
				"tile_id": _current_material,
				"cell_id": target_cell_id
			})
	else:
		# Amorphous material: circle brush, only place in air
		changes = _get_circle_brush_changes_air_only(center_tile, _current_material, 0)
	
	if not changes.is_empty():
		_chunk_manager.set_tiles_at_world_positions(changes)


# Flood-fill to find all connected tiles with same tile_id AND cell_id (for breaking)
func _flood_fill_cell(start_pos: Vector2, target_tile_id: int, target_cell_id: int) -> Array[Vector2]:
	var result: Array[Vector2] = []
	var visited: Dictionary = {}
	var queue: Array[Vector2] = [start_pos]
	
	while not queue.is_empty() and result.size() < MAX_FLOOD_FILL_ITERATIONS:
		var pos = queue.pop_front()
		
		# Skip if already visited
		if visited.has(pos):
			continue
		visited[pos] = true
		
		# Check tile data
		var tile_data = _chunk_manager.get_tile_at_world_pos(pos)
		if tile_data[0] != target_tile_id or tile_data[1] != target_cell_id:
			continue
		
		# Add to result
		result.append(pos)
		
		# Add neighbors to queue
		queue.append(pos + Vector2(-1, 0))
		queue.append(pos + Vector2(1, 0))
		queue.append(pos + Vector2(0, -1))
		queue.append(pos + Vector2(0, 1))
	
	return result


# Flood-fill to find procedural cell shape (for placing) - only expands into air
func _flood_fill_procedural_cell(start_pos: Vector2, target_cell_id: int) -> Array[Vector2]:
	var result: Array[Vector2] = []
	var visited: Dictionary = {}
	var queue: Array[Vector2] = [start_pos]
	
	while not queue.is_empty() and result.size() < MAX_FLOOD_FILL_ITERATIONS:
		var pos = queue.pop_front()
		
		# Skip if already visited
		if visited.has(pos):
			continue
		visited[pos] = true
		
		# Check if this position is air
		var tile_data = _chunk_manager.get_tile_at_world_pos(pos)
		if tile_data[0] != TileIndex.AIR:
			continue # Skip non-air (occupied) tiles
		
		# Check if procedural cell_id matches
		var procedural_cell_id = _terrain_generator.get_cell_id_at(pos)
		if procedural_cell_id != target_cell_id:
			continue
		
		# Add to result
		result.append(pos)
		
		# Add neighbors to queue
		queue.append(pos + Vector2(-1, 0))
		queue.append(pos + Vector2(1, 0))
		queue.append(pos + Vector2(0, -1))
		queue.append(pos + Vector2(0, 1))
	return result


# Flood-fill for placing with randomized offset - creates varied cell shapes
# Uses a random offset applied to the entire query, so same cell_id but different location
func _flood_fill_procedural_cell_randomized(start_pos: Vector2, target_cell_id: int) -> Array[Vector2]:
	var result: Array[Vector2] = []
	var visited: Dictionary = {}
	var queue: Array[Vector2] = [start_pos]
	
	# Generate a random offset for this placement - this shifts which part of the voronoi we sample
	var random_offset = Vector2(randf_range(-50.0, 50.0), randf_range(-50.0, 50.0))
	
	while not queue.is_empty() and result.size() < MAX_FLOOD_FILL_ITERATIONS:
		var pos = queue.pop_front()
		
		# Skip if already visited
		if visited.has(pos):
			continue
		visited[pos] = true
		
		# Check if this position is air
		var tile_data = _chunk_manager.get_tile_at_world_pos(pos)
		if tile_data[0] != TileIndex.AIR:
			continue # Skip non-air (occupied) tiles
		
		# Check cell_id at offset position (samples different part of voronoi)
		var offset_pos = pos + random_offset
		var procedural_cell_id = _terrain_generator.get_cell_id_at(offset_pos)
		if procedural_cell_id != target_cell_id:
			continue
		
		# Add to result
		result.append(pos)
		
		# Add neighbors to queue
		queue.append(pos + Vector2(-1, 0))
		queue.append(pos + Vector2(1, 0))
		queue.append(pos + Vector2(0, -1))
		queue.append(pos + Vector2(0, 1))
	return result


# Circle brush for amorphous materials (breaking)
func _get_circle_brush_changes(center: Vector2, tile_id: int, cell_id: int) -> Array:
	var changes = []
	var r = _current_brush_size
	
	for x in range(-r, r + 1):
		for y in range(-r, r + 1):
			var offset = Vector2(x, y)
			if offset.length_squared() <= r * r:
				changes.append({
					"pos": center + offset,
					"tile_id": tile_id,
					"cell_id": cell_id
				})
	
	return changes


# Circle brush for amorphous materials (placing) - only in air
func _get_circle_brush_changes_air_only(center: Vector2, tile_id: int, cell_id: int) -> Array:
	var changes = []
	var r = _current_brush_size
	
	for x in range(-r, r + 1):
		for y in range(-r, r + 1):
			var offset = Vector2(x, y)
			if offset.length_squared() <= r * r:
				var pos = center + offset
				var existing = _chunk_manager.get_tile_at_world_pos(pos)
				if existing[0] == TileIndex.AIR: # Only place in air
					changes.append({
						"pos": pos,
						"tile_id": tile_id,
						"cell_id": cell_id
					})
	
	return changes


func _apply_edit() -> void:
	var mouse_pos = get_viewport().get_camera_2d().get_global_mouse_position()
	var center_tile = mouse_pos.floor()
	
	var changes = []
	var r = _current_brush_size
	
	# Iterate over the bounding box of the brush
	for x in range(-r, r + 1):
		for y in range(-r, r + 1):
			var offset = Vector2(x, y)
			
			if _current_brush_type == BRUSH_CIRCLE:
				if offset.length_squared() > r * r:
					continue
			
			changes.append({
				"pos": center_tile + offset,
				"tile_id": _current_material,
				"cell_id": 0 # Default cell ID for now
			})

	if _chunk_manager:
		_chunk_manager.set_tiles_at_world_positions(changes)


func _exit_tree() -> void:
	if _brush_preview:
		_brush_preview.queue_free()
