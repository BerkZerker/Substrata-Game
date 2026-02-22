## Generates biome-aware terrain using a BiomeMap for per-column variation.
##
## Each world column is assigned a biome which determines the tile palette
## (surface/subsurface/deep/cliff tiles) and terrain shape parameters.
## At biome boundaries, heightmaps are blended for smooth transitions.
## Runs entirely in the worker thread — no Godot scene API calls.
class_name BiomeTerrainGenerator extends BaseTerrainGenerator

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

## Blend radius in tiles for biome transitions.
const BLEND_RADIUS: int = 16

var _world_seed: int
var _biome_map: BiomeMap

# Shared noise instances (shape is the same across biomes, params modulate it)
var _heightmap_noise: FastNoiseLite
var _detail_noise: FastNoiseLite
var _layer_noise: FastNoiseLite


func _init(world_seed: int, biome_map: BiomeMap) -> void:
	_world_seed = world_seed
	_biome_map = biome_map

	_heightmap_noise = FastNoiseLite.new()
	_heightmap_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_heightmap_noise.seed = _world_seed
	_heightmap_noise.frequency = DEFAULT_CONFIG["heightmap_frequency"]

	_detail_noise = FastNoiseLite.new()
	_detail_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_detail_noise.seed = _world_seed + 1
	_detail_noise.frequency = DEFAULT_CONFIG["detail_frequency"]

	_layer_noise = FastNoiseLite.new()
	_layer_noise.noise_type = FastNoiseLite.TYPE_SIMPLEX
	_layer_noise.seed = _world_seed + 2
	_layer_noise.frequency = DEFAULT_CONFIG["layer_frequency"]


func get_generator_name() -> String:
	return "biome"


func generate_chunk(chunk_pos: Vector2i) -> PackedByteArray:
	var chunk_size: int = GlobalSettings.CHUNK_SIZE
	var data := PackedByteArray()
	data.resize(chunk_size * chunk_size * 2)

	var origin_x: int = chunk_pos.x * chunk_size
	var origin_y: int = chunk_pos.y * chunk_size

	for x in range(chunk_size):
		var world_x: int = origin_x + x

		# Get biome blend info for this column
		var blend_info: Array = _biome_map.get_biome_blend_at(world_x, BLEND_RADIUS)
		var biome_a: BiomeDefinition = blend_info[0]
		var biome_b: BiomeDefinition = blend_info[1]
		var blend_factor: float = blend_info[2]

		# Resolve params for primary biome
		var params_a: Dictionary = _resolve_params(biome_a)
		var surface_y_a: float = _get_surface_y(float(world_x), params_a)

		# Compute blended surface height
		var surface_y: float
		if blend_factor > 0.001:
			var params_b: Dictionary = _resolve_params(biome_b)
			var surface_y_b: float = _get_surface_y(float(world_x), params_b)
			surface_y = lerpf(surface_y_a, surface_y_b, blend_factor)
		else:
			surface_y = surface_y_a

		# Slope for cliff detection
		var slope: float = absf(_get_blended_surface_y(world_x + 1, blend_info) - _get_blended_surface_y(world_x - 1, blend_info)) / 2.0

		# Tile palette from primary biome
		var palette: Dictionary = biome_a.tile_palette

		for y in range(chunk_size):
			var world_y: float = float(origin_y + y)
			var tile_id: int = _get_tile_at(world_x, world_y, surface_y, slope, palette, params_a)

			var index: int = (y * chunk_size + x) * 2
			data[index] = tile_id
			data[index + 1] = 0

	return data


# Merges biome generator_params on top of DEFAULT_CONFIG.
func _resolve_params(biome: BiomeDefinition) -> Dictionary:
	var params: Dictionary = DEFAULT_CONFIG.duplicate()
	if biome and not biome.generator_params.is_empty():
		params.merge(biome.generator_params, true)
	return params


# Surface height using per-biome amplitude/surface_level.
func _get_surface_y(world_x: float, params: Dictionary) -> float:
	return params["surface_level"] \
		+ _heightmap_noise.get_noise_1d(world_x) * params["heightmap_amplitude"] \
		+ _detail_noise.get_noise_1d(world_x) * params["detail_amplitude"]


# Blended surface height for slope calculations at arbitrary X.
func _get_blended_surface_y(world_x: int, blend_info: Array) -> float:
	var biome_a: BiomeDefinition = blend_info[0]
	var biome_b: BiomeDefinition = blend_info[1]
	var blend_factor: float = blend_info[2]

	var params_a: Dictionary = _resolve_params(biome_a)
	var y_a: float = _get_surface_y(float(world_x), params_a)

	if blend_factor > 0.001:
		var params_b: Dictionary = _resolve_params(biome_b)
		var y_b: float = _get_surface_y(float(world_x), params_b)
		return lerpf(y_a, y_b, blend_factor)

	return y_a


# Determines tile at a position given biome palette and params.
func _get_tile_at(world_x: int, world_y: float, surface_y: float, slope: float, palette: Dictionary, params: Dictionary) -> int:
	var depth: float = world_y - surface_y

	if depth < 0:
		return TileIndex.AIR

	var variation: float = _layer_noise.get_noise_2d(float(world_x), world_y) * params["layer_variation"]

	var surface_tile: int = palette.get("surface", TileIndex.GRASS)
	var subsurface_tile: int = palette.get("subsurface", TileIndex.DIRT)
	var deep_tile: int = palette.get("deep", TileIndex.STONE)
	var cliff_tile: int = palette.get("cliff", subsurface_tile)

	var grass_depth: float = params["grass_depth"]
	var dirt_depth: float = params["dirt_depth"]

	# Cliff faces
	if slope > params["cliff_threshold"]:
		if depth < dirt_depth + variation:
			return cliff_tile
		else:
			return deep_tile

	# Normal layered terrain
	if depth < maxf(1.0, grass_depth + variation):
		return surface_tile
	elif depth < dirt_depth + variation:
		return subsurface_tile
	else:
		return deep_tile
