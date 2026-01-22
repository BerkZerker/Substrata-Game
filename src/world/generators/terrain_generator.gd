class_name TerrainGenerator extends RefCounted

var _world_seed: int
var _noise: FastNoiseLite


# Constructor
func _init(generation_seed: int) -> void:
	_world_seed = generation_seed
	_noise = FastNoiseLite.new()

	# Configure the noise generator - I may move this later
	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_noise.seed = _world_seed
	_noise.frequency = 0.003


# Generates a chunk of terrain data based on the chunk position in chunk coordinates (not tile coordinates)
func generate_chunk(chunk_pos: Vector2i) -> PackedByteArray:
	return generate_terrain_chunk(chunk_pos)
	# var chunk_size = GlobalSettings.CHUNK_SIZE
	# var data = PackedByteArray()
	# data.resize(chunk_size * chunk_size * 2) # 2 bytes per tile: [id, cell_number]
	
	# var cell_number = 0 # I will need to track this for each material type and track it globally in the generator

	# for i in range(chunk_size): # y
	# 	for j in range(chunk_size): # x
	# 		# Get the noise value for this position (i & j are reversed, don't ask why, nobody knows)
	# 		var value = _noise.get_noise_2d(float(chunk_pos.x * chunk_size + j), float(chunk_pos.y * chunk_size + i))

	# 		var tile_id = 0
	# 		# Santize the value to be an int - solid is 1 air is 0
	# 		if value > 0.3:
	# 			tile_id = TileIndex.STONE
	# 		elif value > 0.15:
	# 			tile_id = TileIndex.DIRT
	# 		elif value > 0.1:
	# 			tile_id = TileIndex.GRASS
	# 		else:
	# 			tile_id = 0 # Air
			
	# 		# Store interleaved: [id, cell_number]
	# 		# i is row (y), j is col (x)
	# 		var index = (i * chunk_size + j) * 2
	# 		data[index] = tile_id
	# 		data[index + 1] = cell_number

	# return data

# Generates a chunk of "realistic" terrain data, with a surface, caves, etc.
func generate_terrain_chunk(chunk_pos: Vector2i) -> PackedByteArray:
	var chunk_size = GlobalSettings.CHUNK_SIZE
	var data = PackedByteArray()
	data.resize(chunk_size * chunk_size * 2) # 2 bytes per tile: [id, cell_number]

	# Compute global coords, clamp surface height, fix layer ordering, enable caves
	var cave_frequency = 0.05
	var dirt_depth = 55

	# Define a vertical span (in chunks) for the surface to vary across multiple
	# chunks so surface is continuous between chunk boundaries.
	var vertical_span_chunks = 8
	var world_height = chunk_size * vertical_span_chunks

	for y in range(chunk_size): # y
		for x in range(chunk_size): # x
			var global_x = chunk_pos.x * chunk_size + x
			var global_y = chunk_pos.y * chunk_size + y

			# Horizontal terrain variation (sample noise by global x)
			var height_value = _noise.get_noise_2d(float(global_x), 0.0)
			# Cave noise (2D, higher frequency)
			var cave_value = _noise.get_noise_2d(float(global_x) * cave_frequency, float(global_y) * cave_frequency)
			# Dirt amount
			var dirt_value = abs(_noise.get_noise_1d(float(global_x))) * float(dirt_depth)

			# Map noise [-1,1] -> [0, world_height-1] and clamp to world range
			var surface_world_y = int((height_value * 0.5 + 0.5) * float(world_height - 1))
			surface_world_y = clamp(surface_world_y, 0, world_height - 1)

			var tile_id = TileIndex.AIR

			# Compare the global tile Y against the world surface Y so adjacent
			# chunks align on the same surface height.
			if global_y < surface_world_y:
				tile_id = TileIndex.AIR
			elif global_y == surface_world_y:
				tile_id = TileIndex.GRASS
			elif global_y <= surface_world_y + dirt_value:
				tile_id = TileIndex.DIRT
			else:
				tile_id = TileIndex.STONE

			# Introduce caves (carve into non-air tiles)
			if tile_id != TileIndex.AIR and cave_value > 0.45:
				tile_id = TileIndex.AIR

			# Store interleaved: [id, cell_number]
			var index = (y * chunk_size + x) * 2
			data[index] = tile_id
			data[index + 1] = 0 # Default cell number

	return data