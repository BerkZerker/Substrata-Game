## Data-driven tile registry with Texture2DArray support.
##
## Manages tile type definitions and builds a Texture2DArray for the terrain
## shader. Tiles are registered with an ID, name, solidity, texture path, and
## UI color. The texture array is indexed by tile_id — the shader samples
## layer N for tile_id N.
##
## Default tiles (AIR, DIRT, GRASS, STONE) are registered in _ready().
## Additional tiles can be registered before the game scene loads by calling
## register_tile() followed by rebuild_texture_array().
extends Node

# Built-in tile ID constants (backward compatibility)
const AIR: int = 0
const DIRT: int = 1
const GRASS: int = 2
const STONE: int = 3

## Default values for tile properties. New properties can be added here.
const DEFAULT_PROPERTIES: Dictionary = {
	"friction": 1.0,
	"damage": 0.0,
	"transparency": 1.0,
	"hardness": 1,
}

## Tile definitions: { tile_id: { "name": String, "solid": bool, "texture_path": String, "color": Color, "properties": Dictionary } }
var _tiles: Dictionary = {}

## Texture2DArray built from registered tile textures, indexed by tile_id.
var _texture_array: Texture2DArray

## Dimensions of each tile texture layer (all must match).
var _texture_size: int = 0


func _ready() -> void:
	# Register the default tile set
	register_tile(AIR, "Air", false, "", Color(0.7, 0.8, 0.9, 0.5), {"transparency": 0.0, "hardness": 0})
	register_tile(DIRT, "Dirt", true, "res://assets/textures/dirt.png", Color(0.55, 0.35, 0.2))
	register_tile(GRASS, "Grass", true, "res://assets/textures/grass.png", Color(0.3, 0.7, 0.2))
	register_tile(STONE, "Stone", true, "res://assets/textures/stone.png", Color(0.5, 0.5, 0.5), {"hardness": 3})
	rebuild_texture_array()


## Registers a tile type. Call rebuild_texture_array() after all registrations.
## texture_path: Path to the tile texture, or "" for tiles with no texture (e.g. AIR).
## color: UI swatch color for the editing toolbar.
## properties: Optional dictionary of tile properties, merged with DEFAULT_PROPERTIES.
func register_tile(id: int, tile_name: String, solid: bool, texture_path: String, color: Color = Color.WHITE, properties: Dictionary = {}) -> void:
	var merged_props = DEFAULT_PROPERTIES.duplicate()
	merged_props.merge(properties, true)
	_tiles[id] = {
		"name": tile_name,
		"solid": solid,
		"texture_path": texture_path,
		"color": color,
		"properties": merged_props,
	}


## Builds the Texture2DArray from all registered tiles.
## Must be called after all register_tile() calls complete.
func rebuild_texture_array() -> void:
	if _tiles.is_empty():
		return

	# Find the maximum tile ID to determine array layer count
	var max_id: int = 0
	for id in _tiles:
		max_id = maxi(max_id, id)

	# Determine texture dimensions from the first tile that has a texture
	_texture_size = 0
	for id in _tiles:
		var tex_path: String = _tiles[id]["texture_path"]
		if tex_path != "":
			var tex = load(tex_path) as Texture2D
			if tex:
				_texture_size = tex.get_width()
				break

	# Fallback if no textures found
	if _texture_size == 0:
		_texture_size = 32

	# Build image array: one image per tile_id slot (0 through max_id)
	var images: Array[Image] = []
	for i in range(max_id + 1):
		if _tiles.has(i) and _tiles[i]["texture_path"] != "":
			var tex = load(_tiles[i]["texture_path"]) as Texture2D
			if tex:
				var img = tex.get_image()
				if img.get_format() != Image.FORMAT_RGBA8:
					img.convert(Image.FORMAT_RGBA8)
				# Ensure dimensions match
				if img.get_width() != _texture_size or img.get_height() != _texture_size:
					img.resize(_texture_size, _texture_size)
				images.append(img)
			else:
				images.append(_create_placeholder())
		else:
			images.append(_create_placeholder())

	_texture_array = Texture2DArray.new()
	_texture_array.create_from_images(images)


## Returns the Texture2DArray for the terrain shader.
func get_texture_array() -> Texture2DArray:
	return _texture_array


## Returns true if the given tile ID represents a solid tile.
func is_solid(tile_id: int) -> bool:
	var tile = _tiles.get(tile_id)
	if tile:
		return tile["solid"]
	return false


## Returns the display name for a tile ID, or "Unknown" if not found.
func get_tile_name(tile_id: int) -> String:
	var tile = _tiles.get(tile_id)
	if tile:
		return tile["name"]
	return "Unknown"


## Returns the UI color for a tile ID, or white if not found.
func get_tile_color(tile_id: int) -> Color:
	var tile = _tiles.get(tile_id)
	if tile:
		return tile["color"]
	return Color.WHITE


## Returns all registered tile IDs sorted in ascending order.
func get_tile_ids() -> Array:
	var ids = _tiles.keys()
	ids.sort()
	return ids


## Returns the number of registered tiles.
func get_tile_count() -> int:
	return _tiles.size()


## Returns the full tile definition dictionary for a tile ID, or null.
func get_tile_def(tile_id: int):
	return _tiles.get(tile_id)


## Returns a tile property value, or the default if tile/property not found.
func get_tile_property(tile_id: int, property_name: String):
	var tile = _tiles.get(tile_id)
	if tile and tile["properties"].has(property_name):
		return tile["properties"][property_name]
	return DEFAULT_PROPERTIES.get(property_name)


## Returns the friction value for a tile (default 1.0).
func get_friction(tile_id: int) -> float:
	return get_tile_property(tile_id, "friction")


## Returns the damage value for a tile (default 0.0).
func get_damage(tile_id: int) -> float:
	return get_tile_property(tile_id, "damage")


## Returns the transparency value for a tile (default 1.0).
func get_transparency(tile_id: int) -> float:
	return get_tile_property(tile_id, "transparency")


## Returns the hardness value for a tile (default 1).
func get_hardness(tile_id: int) -> int:
	return get_tile_property(tile_id, "hardness")


# Creates a transparent placeholder image for tiles without textures.
func _create_placeholder() -> Image:
	var img = Image.create(_texture_size, _texture_size, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	return img
