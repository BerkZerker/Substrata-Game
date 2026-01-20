extends Node

# Tile IDs
const AIR: int = 0
const DIRT: int = 1
const GRASS: int = 2
const STONE: int = 3

# Materials that use cell-based editing (flood-fill) vs brush-based
const CELLULAR_MATERIALS: Dictionary = {
	STONE: true
}


# Returns true if the material uses cell-based editing (flood-fill)
static func is_cellular(tile_id: int) -> bool:
	return CELLULAR_MATERIALS.has(tile_id)