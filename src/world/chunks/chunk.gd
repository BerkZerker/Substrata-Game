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
		
		# Update Visual Image
		if _terrain_image:
			# Calculate image Y (inverted relative to data Y in current rendering logic)
			var image_y = (chunk_size - 1) - y
			_terrain_image.set_pixel(x, image_y, Color(tile_id * inv_255, cell_id * inv_255, 0, 0))
		
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