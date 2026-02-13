## Registry of tile types and their properties.
##
## Provides tile ID constants for use throughout the codebase, plus runtime
## query methods for tile properties like solidity and display names.
extends Node

# Tile IDs
const AIR: int = 0
const DIRT: int = 1
const GRASS: int = 2
const STONE: int = 3

## Tile property lookup table. Maps tile ID to {name, solid}.
const TILES: Dictionary = {
	AIR: {"name": "Air", "solid": false},
	DIRT: {"name": "Dirt", "solid": true},
	GRASS: {"name": "Grass", "solid": true},
	STONE: {"name": "Stone", "solid": true},
}


## Returns true if the given tile ID represents a solid tile.
func is_solid(tile_id: int) -> bool:
	var tile = TILES.get(tile_id)
	if tile:
		return tile["solid"]
	return false


## Returns the display name for a tile ID, or "Unknown" if not found.
func get_tile_name(tile_id: int) -> String:
	var tile = TILES.get(tile_id)
	if tile:
		return tile["name"]
	return "Unknown"
