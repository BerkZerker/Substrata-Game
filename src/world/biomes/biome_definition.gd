## Defines a biome's tile palette and terrain generation parameters.
##
## Each biome specifies which tiles to use for surface, subsurface, deep, and
## cliff layers, along with overrides for terrain shape parameters (frequency,
## amplitude, etc.). Used by BiomeTerrainGenerator to vary terrain across the world.
class_name BiomeDefinition extends RefCounted

## Human-readable biome name (e.g. "Plains", "Desert").
var biome_name: String

## Tile palette: which tile IDs to use for each terrain layer.
## Keys: "surface", "subsurface", "deep", "cliff"
var tile_palette: Dictionary

## Generator parameter overrides, merged on top of SimplexTerrainGenerator defaults.
## Only include keys you want to override (e.g. {"heightmap_amplitude": 40.0}).
var generator_params: Dictionary

## Debug/minimap color for this biome.
var color: Color


func _init(p_name: String, p_palette: Dictionary, p_params: Dictionary = {}, p_color: Color = Color.WHITE) -> void:
	biome_name = p_name
	tile_palette = p_palette
	generator_params = p_params
	color = p_color
