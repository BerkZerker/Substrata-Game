## Data-driven tile registry with Texture2DArray support.
##
## Manages tile type definitions and builds a Texture2DArray for the terrain
## shader. Tiles are registered with an ID, name, solidity, texture path, and
## UI color. The texture array is indexed by tile_id — the shader samples
## layer N for tile_id N.
##
## Tile definitions are loaded from JSON files in assets/tiles/ at startup.
## If no JSON files are found, falls back to hardcoded registration in _ready().
## Additional tiles can be registered before the game scene loads by calling
## register_tile() followed by rebuild_texture_array().
extends Node

# Built-in tile ID constants
const AIR: int = 0
const DIRT: int = 1
const GRASS: int = 2
const STONE: int = 3
const SAND: int = 4
const GRAVEL: int = 5
const CLAY: int = 6
const SNOW: int = 7
const ICE: int = 8
const COAL_ORE: int = 9
const IRON_ORE: int = 10
const GOLD_ORE: int = 11
const WATER: int = 12
const LAVA: int = 13
const FLOWERS: int = 14
const MUSHROOM: int = 15
const VINES: int = 16

## Default values for tile properties. New properties can be added here.
const DEFAULT_PROPERTIES: Dictionary = {
	"friction": 1.0,
	"damage": 0.0,
	"transparency": 1.0,
	"hardness": 1,
	"emission": 0,
	"light_filter": 0,
	"speed_modifier": 1.0,
	"gravity_affected": false,
	"growth_type": "none",
}

## Path to the tile definitions JSON directory.
const TILES_JSON_DIR: String = "res://assets/tiles/"

## Tile definitions: { tile_id: { "name": String, "solid": bool, "texture_path": String, "color": Color, "properties": Dictionary } }
var _tiles: Dictionary = {}

## Texture2DArray built from registered tile textures, indexed by tile_id.
var _texture_array: Texture2DArray

## Dimensions of each tile texture layer (all must match).
var _texture_size: int = 0


func _ready() -> void:
	if not _load_tiles_from_json():
		_register_default_tiles()

	rebuild_texture_array()


## Loads tile definitions from JSON files in TILES_JSON_DIR.
## Returns true if at least one tile was loaded successfully.
func _load_tiles_from_json() -> bool:
	var dir = DirAccess.open(TILES_JSON_DIR)
	if dir == null:
		return false

	var json_files: Array[String] = []
	dir.list_dir_begin()
	var file_name = dir.get_next()
	while file_name != "":
		if not dir.current_is_dir() and file_name.ends_with(".json"):
			json_files.append(TILES_JSON_DIR.path_join(file_name))
		file_name = dir.get_next()
	dir.list_dir_end()

	if json_files.is_empty():
		return false

	var loaded_any := false
	for json_path in json_files:
		var file = FileAccess.open(json_path, FileAccess.READ)
		if file == null:
			push_warning("TileIndex: Failed to open %s" % json_path)
			continue

		var json = JSON.new()
		var err = json.parse(file.get_as_text())
		file.close()
		if err != OK:
			push_warning("TileIndex: JSON parse error in %s: %s" % [json_path, json.get_error_message()])
			continue

		var data = json.get_data()
		if data is Dictionary and data.has("tiles") and data["tiles"] is Array:
			for tile_def in data["tiles"]:
				if _register_tile_from_dict(tile_def):
					loaded_any = true
		elif data is Array:
			for tile_def in data:
				if _register_tile_from_dict(tile_def):
					loaded_any = true
		else:
			push_warning("TileIndex: Unexpected JSON structure in %s" % json_path)

	return loaded_any


## Parses a single tile definition dictionary from JSON and registers it.
## Returns true on success.
func _register_tile_from_dict(d: Variant) -> bool:
	if not d is Dictionary:
		return false
	if not d.has("id") or not d.has("name"):
		push_warning("TileIndex: Tile definition missing 'id' or 'name'")
		return false

	var id: int = int(d["id"])
	var tile_name: String = str(d["name"])
	var solid: bool = d.get("solid", false)
	var texture_path: String = d.get("texture", "")

	# Parse color from [r, g, b] or [r, g, b, a] array
	var color := Color.WHITE
	if d.has("color") and d["color"] is Array:
		var c: Array = d["color"]
		if c.size() >= 3:
			var a: float = c[3] if c.size() >= 4 else 1.0
			color = Color(c[0], c[1], c[2], a)

	var properties: Dictionary = {}
	if d.has("properties") and d["properties"] is Dictionary:
		properties = d["properties"]

	register_tile(id, tile_name, solid, texture_path, color, properties)
	return true


## Registers the hardcoded default tile set (fallback when no JSON found).
func _register_default_tiles() -> void:
	register_tile(AIR, "Air", false, "", Color(0.7, 0.8, 0.9, 0.5), {"transparency": 0.0, "hardness": 0, "light_filter": 0})
	register_tile(DIRT, "Dirt", true, "res://assets/textures/dirt.png", Color(0.55, 0.35, 0.2))
	register_tile(GRASS, "Grass", true, "res://assets/textures/grass.png", Color(0.3, 0.7, 0.2), {"growth_type": "spread_surface"})
	register_tile(STONE, "Stone", true, "res://assets/textures/stone.png", Color(0.5, 0.5, 0.5), {"hardness": 3, "light_filter": 1})
	register_tile(SAND, "Sand", true, "res://assets/textures/sand.png", Color(0.83, 0.66, 0.28), {"friction": 0.6, "gravity_affected": true})
	register_tile(GRAVEL, "Gravel", true, "res://assets/textures/gravel.png", Color(0.55, 0.49, 0.42), {"friction": 0.9, "gravity_affected": true})
	register_tile(CLAY, "Clay", true, "res://assets/textures/clay.png", Color(0.63, 0.32, 0.18), {"friction": 1.2, "hardness": 2})
	register_tile(SNOW, "Snow", true, "res://assets/textures/snow.png", Color(0.94, 0.94, 0.94), {"friction": 0.4})
	register_tile(ICE, "Ice", true, "res://assets/textures/ice.png", Color(0.66, 0.85, 0.92), {"friction": 0.1, "hardness": 2})
	register_tile(COAL_ORE, "Coal Ore", true, "res://assets/textures/coal_ore.png", Color(0.29, 0.29, 0.29), {"hardness": 3, "light_filter": 1})
	register_tile(IRON_ORE, "Iron Ore", true, "res://assets/textures/iron_ore.png", Color(0.48, 0.48, 0.48), {"hardness": 4, "light_filter": 1})
	register_tile(GOLD_ORE, "Gold Ore", true, "res://assets/textures/gold_ore.png", Color(0.48, 0.48, 0.48), {"hardness": 5, "light_filter": 1})
	register_tile(WATER, "Water", false, "res://assets/textures/water.png", Color(0.2, 0.6, 0.86), {"transparency": 1.0, "speed_modifier": 0.5})
	register_tile(LAVA, "Lava", false, "res://assets/textures/lava.png", Color(1.0, 0.27, 0.0), {"damage": 10.0, "emission": 60, "light_filter": 0})
	register_tile(FLOWERS, "Flowers", false, "res://assets/textures/flowers.png", Color(0.9, 0.4, 0.5), {"transparency": 1.0})
	register_tile(MUSHROOM, "Mushroom", false, "res://assets/textures/mushroom.png", Color(0.63, 0.32, 0.18), {"transparency": 1.0})
	register_tile(VINES, "Vines", false, "res://assets/textures/vines.png", Color(0.18, 0.35, 0.15), {"transparency": 0.8, "growth_type": "grow_down"})


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


## Returns the light emission value for a tile (default 0).
func get_emission(tile_id: int) -> int:
	return get_tile_property(tile_id, "emission")


## Returns the light filter value for a tile (default 15, meaning full block).
func get_light_filter(tile_id: int) -> int:
	return get_tile_property(tile_id, "light_filter")


## Returns the speed modifier for a tile (default 1.0).
func get_speed_modifier(tile_id: int) -> float:
	return get_tile_property(tile_id, "speed_modifier")


## Returns true if the tile is affected by gravity (default false).
func get_gravity_affected(tile_id: int) -> bool:
	return get_tile_property(tile_id, "gravity_affected")


## Returns the growth type for a tile (default "none").
func get_growth_type(tile_id: int) -> String:
	return get_tile_property(tile_id, "growth_type")


# Creates a transparent placeholder image for tiles without textures.
func _create_placeholder() -> Image:
	var img = Image.create(_texture_size, _texture_size, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	return img
