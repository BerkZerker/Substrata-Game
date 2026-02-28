## Individual terrain chunk with mutex-protected data and shader-based rendering.
##
## Stores terrain as a PackedByteArray (2 bytes per tile: [tile_id, cell_id]).
## Uses a shared QuadMesh and fragment shader for rendering. Supports pooling
## via reset().
class_name Chunk extends Node2D

# Variables
@onready var _visual_mesh: MeshInstance2D = $MeshInstance2D

static var _shared_quad_mesh: QuadMesh

var _terrain_data: PackedByteArray = PackedByteArray()
var _terrain_image: Image
var _data_texture: ImageTexture
var _sky_light_data: PackedByteArray = PackedByteArray()
var _block_light_data: PackedByteArray = PackedByteArray()
var _mutex: Mutex = Mutex.new()


## Initializes the shared quad mesh on first instance.
func _ready() -> void:
	# Initialize the shared mesh once if it doesn't exist
	if not _shared_quad_mesh:
		_shared_quad_mesh = QuadMesh.new()
		_shared_quad_mesh.size = Vector2(GlobalSettings.CHUNK_SIZE, GlobalSettings.CHUNK_SIZE)


## Sets the chunk's terrain data and world position from chunk coordinates.
func generate(chunk_data: PackedByteArray, chunk_pos: Vector2i) -> void:
	_mutex.lock()
	_terrain_data = chunk_data # Just a reference, not a copy (COW optimization works well here)
	_mutex.unlock()
	position = Vector2(chunk_pos.x * GlobalSettings.CHUNK_SIZE, chunk_pos.y * GlobalSettings.CHUNK_SIZE)


## Creates the visual texture from a pre-generated image and makes the chunk visible.
func build(visual_image: Image) -> void:
	_mutex.lock()
	_terrain_image = visual_image
	_mutex.unlock()
	
	_setup_visual_mesh(visual_image)
	visible = true


## Resets the chunk for return to the pool. Clears terrain data and texture.
func reset() -> void:
	visible = false
	_mutex.lock()
	_terrain_data.clear()
	_terrain_image = null
	_data_texture = null
	_sky_light_data.clear()
	_block_light_data.clear()
	_mutex.unlock()

	if _visual_mesh.material:
		_visual_mesh.material.set_shader_parameter("chunk_data_texture", null)


# Sets up the mesh and shader data to draw the chunk using a pre-calculated image
func _setup_visual_mesh(image: Image):
	_visual_mesh.mesh = _shared_quad_mesh
	_visual_mesh.position = _visual_mesh.mesh.size / 2.0

	_data_texture = ImageTexture.create_from_image(image)
	_visual_mesh.material.set_shader_parameter("chunk_data_texture", _data_texture)
	var tile_textures = TileIndex.get_texture_array()
	if tile_textures:
		_visual_mesh.material.set_shader_parameter("tile_textures", tile_textures)


## Applies a batch of tile changes to terrain data and visuals.
## changes: Array of { "x": int, "y": int, "tile_id": int, "cell_id": int }
func edit_tiles(changes: Array) -> void:
	if changes.is_empty():
		return

	_mutex.lock()
	
	var changed_something = false
	var inv_255 = 1.0 / 255.0
	var chunk_size = GlobalSettings.CHUNK_SIZE
	
	for change in changes:
		var x = change["x"]
		var y = change["y"]
		
		# Bounds check
		if x < 0 or x >= chunk_size or y < 0 or y >= chunk_size:
			continue
			
		var index = (y * chunk_size + x) * 2
		if index >= _terrain_data.size():
			continue
			
		var tile_id = change["tile_id"]
		var cell_id = change["cell_id"]
		
		# Update Data
		_terrain_data[index] = tile_id
		_terrain_data[index + 1] = cell_id
		
		# Update Visual Image (preserve A=sky light, B=block light channels)
		if _terrain_image:
			# Calculate image Y (inverted relative to data Y in current rendering logic)
			var image_y = (chunk_size - 1) - y
			var existing_pixel = _terrain_image.get_pixel(x, image_y)
			_terrain_image.set_pixel(x, image_y, Color(tile_id * inv_255, cell_id * inv_255, existing_pixel.b, existing_pixel.a))
		
		changed_something = true
	
	_mutex.unlock()
	
	if changed_something:
		_update_visuals()


# Updates the existing GPU texture in-place (avoids allocating a new texture per edit)
func _update_visuals() -> void:
	if _terrain_image and _data_texture:
		_data_texture.update(_terrain_image)


## Returns tile data for multiple positions within the chunk.
func get_tiles(positions: Array[Vector2i]) -> Array:
	var results: Array = []
	
	_mutex.lock()
	for pos in positions:
		var tile_x = pos.x
		var tile_y = pos.y
		
		if tile_y < 0 or tile_y >= GlobalSettings.CHUNK_SIZE:
			results.append([0, 0]) # Return air if out of bounds
			continue
		if tile_x < 0 or tile_x >= GlobalSettings.CHUNK_SIZE:
			results.append([0, 0]) # Return air if out of bounds
			continue
		
		var index = (tile_y * GlobalSettings.CHUNK_SIZE + tile_x) * 2
		if index >= _terrain_data.size():
			results.append([0, 0])
			continue
			
		results.append([_terrain_data[index], _terrain_data[index + 1]])
	
	_mutex.unlock()
	return results


## Returns [tile_id, cell_id] at a specific tile position within the chunk.
func get_tile_at(tile_x: int, tile_y: int) -> Array:
	if tile_y < 0 or tile_y >= GlobalSettings.CHUNK_SIZE:
		return [0, 0] # Return air if out of bounds
	if tile_x < 0 or tile_x >= GlobalSettings.CHUNK_SIZE:
		return [0, 0] # Return air if out of bounds
	
	_mutex.lock()
	var index = (tile_y * GlobalSettings.CHUNK_SIZE + tile_x) * 2
	if index >= _terrain_data.size():
		_mutex.unlock()
		return [0, 0]
		
	var result = [_terrain_data[index], _terrain_data[index + 1]]
	_mutex.unlock()
	return result


## Returns a copy of the terrain data. Thread-safe.
func get_terrain_data() -> PackedByteArray:
	_mutex.lock()
	var data = _terrain_data.duplicate()
	_mutex.unlock()
	return data


## Updates the A (sky) and B (block) light channels from baked light data.
## light_result: Dictionary with "sky" and "block" PackedByteArrays (0-15 values).
func update_light_data(light_result: Dictionary) -> void:
	_mutex.lock()
	if _terrain_image == null:
		_mutex.unlock()
		return

	var sky_data: PackedByteArray = light_result["sky"]
	var block_data: PackedByteArray = light_result["block"]
	_sky_light_data = sky_data
	_block_light_data = block_data
	var chunk_size = GlobalSettings.CHUNK_SIZE
	var inv_max = 1.0 / float(LightBaker.MAX_LIGHT)

	for y in range(chunk_size):
		# Y-inversion: data row y maps to image row (SIZE-1 - y)
		var image_y = (chunk_size - 1) - y
		for x in range(chunk_size):
			var idx = y * chunk_size + x
			var sky_level = float(sky_data[idx]) * inv_max
			var block_level = float(block_data[idx]) * inv_max

			var pixel = _terrain_image.get_pixel(x, image_y)
			pixel.a = sky_level
			pixel.b = block_level
			_terrain_image.set_pixel(x, image_y, pixel)

	_mutex.unlock()
	_update_visuals()


## Returns a copy of the baked sky light data. Used by LightBaker for cross-chunk border seeding.
func get_sky_light_data() -> PackedByteArray:
	_mutex.lock()
	var data = _sky_light_data.duplicate()
	_mutex.unlock()
	return data


## Returns a copy of the baked block light data. Used by LightBaker for cross-chunk border seeding.
func get_block_light_data() -> PackedByteArray:
	_mutex.lock()
	var data = _block_light_data.duplicate()
	_mutex.unlock()
	return data


## Forwards a shader parameter to the visual mesh material.
func set_shader_parameter(param_name: StringName, value: Variant) -> void:
	if _visual_mesh and _visual_mesh.material:
		_visual_mesh.material.set_shader_parameter(param_name, value)


## Returns just the tile ID at a specific position. Optimized for collision checks.
func get_tile_id_at(tile_x: int, tile_y: int) -> int:
	if tile_y < 0 or tile_y >= GlobalSettings.CHUNK_SIZE:
		return 0 # Return air if out of bounds
	if tile_x < 0 or tile_x >= GlobalSettings.CHUNK_SIZE:
		return 0 # Return air if out of bounds
	
	_mutex.lock()
	var index = (tile_y * GlobalSettings.CHUNK_SIZE + tile_x) * 2
	if index >= _terrain_data.size():
		_mutex.unlock()
		return 0
		
	var result = _terrain_data[index]
	_mutex.unlock()
	return result