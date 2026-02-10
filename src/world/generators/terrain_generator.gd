class_name TerrainGenerator extends RefCounted

var _world_seed: int
var _noise: FastNoiseLite


# Constructor
func _init(generation_seed: int) -> void:
	_world_seed = generation_seed
	_noise = FastNoiseLite.new()

	_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_noise.seed = _world_seed
	_noise.frequency = 0.003


# Generates terrain data for a chunk. chunk_pos is in chunk coordinates (not tiles).
# Returns PackedByteArray with 2 bytes per tile: [tile_id, cell_id]
func generate_chunk(chunk_pos: Vector2i) -> PackedByteArray:
	var chunk_size = GlobalSettings.CHUNK_SIZE
	var data = PackedByteArray()
	data.resize(chunk_size * chunk_size * 2)

	var origin_x = chunk_pos.x * chunk_size
	var origin_y = chunk_pos.y * chunk_size

	for y in range(chunk_size):
		for x in range(chunk_size):
			var world_x = float(origin_x + x)
			var world_y = float(origin_y + y)
			var value = _noise.get_noise_2d(world_x, world_y)

			var tile_id = TileIndex.AIR
			if value > 0.3:
				tile_id = TileIndex.STONE
			elif value > 0.15:
				tile_id = TileIndex.DIRT
			elif value > 0.1:
				tile_id = TileIndex.GRASS

			var index = (y * chunk_size + x) * 2
			data[index] = tile_id
			data[index + 1] = 0 # cell_id (unused for now)

	return data
