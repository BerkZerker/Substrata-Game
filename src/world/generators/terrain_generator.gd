class_name TerrainGenerator extends RefCounted

var _world_seed: int
var _noise: FastNoiseLite
var _cell_noise: FastNoiseLite # Cellular noise for stone cell boundaries


# Constructor
func _init(generation_seed: int) -> void:
	_world_seed = generation_seed
	_noise = FastNoiseLite.new()

	# Configure the noise generator - I may move this later
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_noise.seed = _world_seed
	_noise.frequency = 0.003
	
	# Configure cellular noise for stone cells
	_cell_noise = FastNoiseLite.new()
	_cell_noise.noise_type = FastNoiseLite.TYPE_CELLULAR
	_cell_noise.seed = _world_seed + 1 # Different seed for variety
	_cell_noise.frequency = 0.007 # Controls average cell size
	_cell_noise.cellular_return_type = FastNoiseLite.RETURN_CELL_VALUE
	_cell_noise.cellular_jitter = 0.45 # Less jitter = more regular hexagonal cells
	_cell_noise.cellular_distance_function = FastNoiseLite.DISTANCE_EUCLIDEAN


# Generates a chunk of terrain data based on the chunk position in chunk coordinates (not tile coordinates)
func generate_chunk(chunk_pos: Vector2i) -> PackedByteArray:
	var chunk_size = GlobalSettings.CHUNK_SIZE
	var data = PackedByteArray()
	data.resize(chunk_size * chunk_size * 2) # 2 bytes per tile: [id, cell_number]

	for i in range(chunk_size): # y
		for j in range(chunk_size): # x
			# Get the noise value for this position (i & j are reversed, don't ask why, nobody knows)
			var value = _noise.get_noise_2d(float(chunk_pos.x * chunk_size + j), float(chunk_pos.y * chunk_size + i))

			var tile_id = 0
			var cell_id = 0
			
			# Santize the value to be an int - solid is 1 air is 0
			if value > 0.3:
				tile_id = TileIndex.STONE
				# Generate cell_id for stone using cellular noise
				cell_id = _get_cell_id_at_world(chunk_pos.x * chunk_size + j, chunk_pos.y * chunk_size + i)
			elif value > 0.15:
				tile_id = TileIndex.DIRT
			elif value > 0.1:
				tile_id = TileIndex.GRASS
			else:
				tile_id = 0 # Air
			
			# Store interleaved: [id, cell_number]
			# i is row (y), j is col (x)
			var index = (i * chunk_size + j) * 2
			data[index] = tile_id
			data[index + 1] = cell_id

	return data


# Gets the cell_id at a world position using cellular noise
# This can be called externally for placing new cells
func get_cell_id_at(world_pos: Vector2) -> int:
	return _get_cell_id_at_world(int(floor(world_pos.x)), int(floor(world_pos.y)))


# Gets a randomized cell_id for placing - adds offset so each placement uses different cell shape
func get_random_cell_id_at(world_pos: Vector2) -> int:
	# Add random offset to sample different part of voronoi diagram each time
	var random_offset = Vector2(randf_range(-50.0, 50.0), randf_range(-50.0, 50.0))
	var offset_pos = world_pos + random_offset
	return _get_cell_id_at_world(int(floor(offset_pos.x)), int(floor(offset_pos.y)))


# Internal helper to get cell_id from world coordinates
func _get_cell_id_at_world(world_x: int, world_y: int) -> int:
	# Sample cellular noise and map to 0-255
	var cell_value = _cell_noise.get_noise_2d(float(world_x), float(world_y))
	# Noise returns -1 to 1, map to 0-255
	return int((cell_value + 1.0) * 0.5 * 255.0) % 256
