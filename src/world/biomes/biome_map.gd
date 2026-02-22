## Maps world X coordinates to biome definitions using cellular noise.
##
## Uses FastNoiseLite with cellular (Voronoi) noise to create distinct biome
## regions. Thread-safe: no Godot scene API calls, only reads noise values
## and returns BiomeDefinition references.
class_name BiomeMap extends RefCounted

## Scale of biome regions. Larger values = bigger biome areas.
const BIOME_SCALE: float = 0.003

var _biome_noise: FastNoiseLite
var _biomes: Array[BiomeDefinition] = []


func _init(world_seed: int, biomes: Array[BiomeDefinition]) -> void:
	_biomes = biomes

	_biome_noise = FastNoiseLite.new()
	_biome_noise.noise_type = FastNoiseLite.TYPE_CELLULAR
	_biome_noise.seed = world_seed + 100
	_biome_noise.frequency = BIOME_SCALE
	_biome_noise.cellular_distance_function = FastNoiseLite.DISTANCE_EUCLIDEAN
	_biome_noise.cellular_return_type = FastNoiseLite.RETURN_CELL_VALUE


## Returns the biome at the given world X coordinate.
## The noise value [-1, 1] is mapped to a biome index.
func get_biome_at(world_x: int) -> BiomeDefinition:
	if _biomes.is_empty():
		return null
	var noise_val: float = _biome_noise.get_noise_1d(float(world_x))
	# Map [-1, 1] to [0, biome_count)
	var normalized: float = (noise_val + 1.0) * 0.5 # [0, 1]
	var index: int = clampi(int(normalized * _biomes.size()), 0, _biomes.size() - 1)
	return _biomes[index]


## Returns the biome and a blend weight for transition zones.
## Returns [BiomeDefinition, BiomeDefinition, float] where float is the
## blend factor (0.0 = fully first biome, 1.0 = fully second biome).
## Samples neighboring columns to detect biome boundaries.
func get_biome_blend_at(world_x: int, blend_radius: int = 16) -> Array:
	var center_biome := get_biome_at(world_x)
	var left_biome := get_biome_at(world_x - blend_radius)
	var right_biome := get_biome_at(world_x + blend_radius)

	# No transition — same biome on both sides
	if left_biome == center_biome and right_biome == center_biome:
		return [center_biome, center_biome, 0.0]

	# Find the nearest boundary by scanning outward
	var other_biome: BiomeDefinition = null
	var boundary_dist: int = blend_radius

	for offset in range(1, blend_radius + 1):
		var left_check := get_biome_at(world_x - offset)
		if left_check != center_biome:
			other_biome = left_check
			boundary_dist = offset
			break
		var right_check := get_biome_at(world_x + offset)
		if right_check != center_biome:
			other_biome = right_check
			boundary_dist = offset
			break

	if other_biome == null:
		return [center_biome, center_biome, 0.0]

	# Blend factor: 1.0 at boundary, 0.0 at blend_radius distance
	var blend: float = 1.0 - clampf(float(boundary_dist) / float(blend_radius), 0.0, 1.0)
	return [center_biome, other_biome, blend]
