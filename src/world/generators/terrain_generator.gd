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

	for i in range(chunk_size): # y
		for j in range(chunk_size): # x
			# Get the noise value for this position (i & j are reversed, don't ask why, nobody knows)
			var height_value = _noise.get_noise_1d(float(chunk_pos.x * chunk_size + i))
			var cave_value = _noise.get_noise_2d(float(chunk_pos.x * chunk_size + j), float(chunk_pos.y * chunk_size + i) * 5.0)

			var surface_height = int((height_value + 1.0) * 0.5 * chunk_size) # Scale to [0, chunk_size]
			var tile_id = 0

			if i < surface_height:
				tile_id = TileIndex.STONE
			elif i == surface_height:
				tile_id = TileIndex.GRASS
			elif i < surface_height + 3:
				tile_id = TileIndex.DIRT
			else:
				tile_id = TileIndex.AIR

			# Introduce caves
			if tile_id != TileIndex.AIR and cave_value > 0.4:
				tile_id = TileIndex.AIR

			# Store interleaved: [id, cell_number]
			var index = (i * chunk_size + j) * 2
			data[index] = tile_id
			data[index + 1] = 0 # Default cell number

	return data