## Generates terrain data for chunks using layered simplex noise.
##
## Uses dual heightmaps (broad hills + surface detail) and high-variation
## layer boundaries for organic-looking material distribution. Steep slopes
## are detected as cliff faces where grass doesn't grow.
##
## All parameters are configurable via the config dictionary passed to _init().
class_name SimplexTerrainGenerator extends BaseTerrainGenerator

## Default configuration for terrain generation. Pass a partial dictionary
## to _init() to override specific values.
const DEFAULT_CONFIG: Dictionary = {
	"heightmap_frequency": 0.002,
	"detail_frequency": 0.008,
	"layer_frequency": 0.006,
	"surface_level": 0.0,
	"heightmap_amplitude": 96.0,
	"detail_amplitude": 20.0,
	"grass_depth": 4,
	"dirt_depth": 20,
	"layer_variation": 12.0,
	"cliff_threshold": 1.5,
}

var _world_seed: int
var _heightmap_noise: FastNoiseLite
var _detail_noise: FastNoiseLite
var _layer_noise: FastNoiseLite

# Terrain shape parameters (from config)
var _surface_level: float
var _heightmap_amplitude: float
var _detail_amplitude: float
var _grass_depth: int
var _dirt_depth: int
var _layer_variation: float
var _cliff_threshold: float


func _init(generation_seed: int, config: Dictionary = {}) -> void:
	_world_seed = generation_seed

	var cfg = DEFAULT_CONFIG.duplicate()
	cfg.merge(config, true)

	_surface_level = cfg["surface_level"]
	_heightmap_amplitude = cfg["heightmap_amplitude"]
	_detail_amplitude = cfg["detail_amplitude"]
	_grass_depth = cfg["grass_depth"]
	_dirt_depth = cfg["dirt_depth"]
	_layer_variation = cfg["layer_variation"]
	_cliff_threshold = cfg["cliff_threshold"]

	# Broad hills and valleys
	_heightmap_noise = FastNoiseLite.new()
	_heightmap_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_heightmap_noise.seed = _world_seed
	_heightmap_noise.frequency = cfg["heightmap_frequency"]

	# Small-scale surface roughness (bumps, ledges)
	_detail_noise = FastNoiseLite.new()
	_detail_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_detail_noise.seed = _world_seed + 1
	_detail_noise.frequency = cfg["detail_frequency"]

	# Layer boundary variation (dirt/stone boundaries)
	_layer_noise = FastNoiseLite.new()
	_layer_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_layer_noise.seed = _world_seed + 2
	_layer_noise.frequency = cfg["layer_frequency"]


## Returns the name of this generator type.
func get_generator_name() -> String:
	return "simplex"


## Generates terrain data for a chunk at the given chunk position.
## Returns a PackedByteArray with 2 bytes per tile: [tile_id, cell_id].
func generate_chunk(chunk_pos: Vector2i) -> PackedByteArray:
	var chunk_size = GlobalSettings.CHUNK_SIZE
	var data = PackedByteArray()
	data.resize(chunk_size * chunk_size * 2)

	var origin_x = chunk_pos.x * chunk_size
	var origin_y = chunk_pos.y * chunk_size

	for x in range(chunk_size):
		var world_x = float(origin_x + x)
		var surface_y = _get_surface_y(world_x)

		# Central difference slope for cliff detection
		var slope = absf(_get_surface_y(world_x + 1.0) - _get_surface_y(world_x - 1.0)) / 2.0

		for y in range(chunk_size):
			var world_y = float(origin_y + y)
			var tile_id = _get_tile_at(world_x, world_y, surface_y, slope)

			var index = (y * chunk_size + x) * 2
			data[index] = tile_id
			data[index + 1] = 0 # cell_id (unused for now)

	return data


# Computes the surface height at a given world X coordinate.
func _get_surface_y(world_x: float) -> float:
	return _surface_level \
		+ _heightmap_noise.get_noise_1d(world_x) * _heightmap_amplitude \
		+ _detail_noise.get_noise_1d(world_x) * _detail_amplitude


# Determines the tile type at a world position given the surface height and slope.
func _get_tile_at(world_x: float, world_y: float, surface_y: float, slope: float) -> int:
	var depth = world_y - surface_y # Y-down: positive = underground

	# Above surface = air
	if depth < 0:
		return TileIndex.AIR

	var variation = _layer_noise.get_noise_2d(world_x, world_y) * _layer_variation

	# Cliff faces: steep slopes don't grow grass
	if slope > _cliff_threshold:
		if depth < _dirt_depth + variation:
			return TileIndex.DIRT
		else:
			return TileIndex.STONE

	# Normal terrain: always at least 1 grass tile on surface
	if depth < maxf(1.0, _grass_depth + variation):
		return TileIndex.GRASS
	elif depth < _dirt_depth + variation:
		return TileIndex.DIRT
	else:
		return TileIndex.STONE
