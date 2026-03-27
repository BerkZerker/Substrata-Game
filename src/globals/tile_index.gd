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
	"damage_stages": 2, # Number of damage stages before destruction (0 = intact, stages 1..N, then destroyed = AIR)
	"break_noise": 0.0, # Force variation per propagation step (0.0 = smooth circle, 0.5 = jagged edges)
}

## Tile definitions: { tile_id: { "name": String, "solid": bool, "texture_path": String, "color": Color, "properties": Dictionary } }
var _tiles: Dictionary = {}

## Texture2DArray built from registered tile textures, indexed by tile_id.
var _texture_array: Texture2DArray

## Dimensions of each tile texture layer (all must match).
var _texture_size: int = 0


func _ready() -> void:
	# Register the default tile set
	register_tile(AIR, "Air", false, "", Color(0.7, 0.8, 0.9, 0.5), {"transparency": 0.0, "hardness": 0, "damage_stages": 0})
	register_tile(DIRT, "Dirt", true, "res://assets/textures/dirt.png", Color(0.55, 0.35, 0.2), {"hardness": 3})
	register_tile(GRASS, "Grass", true, "res://assets/textures/grass.png", Color(0.3, 0.7, 0.2), {"hardness": 2})
	register_tile(STONE, "Stone", true, "res://assets/textures/stone.png", Color(0.5, 0.5, 0.5), {"hardness": 8, "damage_stages": 2, "break_noise": 0.5})
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

	# Generate directional edge hardness from texture brightness
	_generate_edge_hardness()


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


## Returns the number of damage stages for a tile (default 2).
func get_damage_stages(tile_id: int) -> int:
	return get_tile_property(tile_id, "damage_stages")


## Returns the effective hardness of a tile at a given damage stage.
## Damaged tiles are easier to break: hardness scales linearly from full to 0.
func get_effective_hardness(tile_id: int, damage_stage: int) -> float:
	var base_hardness: float = float(get_hardness(tile_id))
	var max_stages: int = get_damage_stages(tile_id)
	if max_stages <= 0:
		return base_hardness
	var scale: float = 1.0 - (float(damage_stage) / float(max_stages))
	return base_hardness * scale


## Returns directional edge hardness for a tile based on entry direction.
## Diagonals average the two relevant edges.
func get_directional_hardness(tile_id: int, entry_dir: Vector2) -> float:
	var tile = _tiles.get(tile_id)
	if not tile or not tile.has("edge_hardness"):
		return float(get_hardness(tile_id))
	var edges = tile["edge_hardness"]
	var h = 0.0
	var count = 0
	if entry_dir.y < -0.5: # Entering from above → north edge
		h += edges["n"]; count += 1
	if entry_dir.y > 0.5: # Entering from below → south edge
		h += edges["s"]; count += 1
	if entry_dir.x < -0.5: # Entering from left → west edge
		h += edges["w"]; count += 1
	if entry_dir.x > 0.5: # Entering from right → east edge
		h += edges["e"]; count += 1
	if count == 0:
		return float(get_hardness(tile_id))
	return h / float(count)


## Returns effective directional hardness accounting for damage stage.
func get_effective_directional_hardness(tile_id: int, damage_stage: int, entry_dir: Vector2) -> float:
	var base = get_directional_hardness(tile_id, entry_dir)
	var max_stages: int = get_damage_stages(tile_id)
	if max_stages <= 0:
		return base
	var scale: float = 1.0 - (float(damage_stage) / float(max_stages))
	return base * scale


# Generates directional edge hardness for all registered tiles from their textures.
func _generate_edge_hardness() -> void:
	for id in _tiles:
		var tile = _tiles[id]
		var tex_path: String = tile["texture_path"]
		var base_hardness: float = float(tile["properties"]["hardness"])

		if tex_path == "" or base_hardness <= 0.0:
			tile["edge_hardness"] = {"n": 0.0, "s": 0.0, "e": 0.0, "w": 0.0}
			continue

		var tex = load(tex_path) as Texture2D
		if not tex:
			tile["edge_hardness"] = {"n": base_hardness, "s": base_hardness, "e": base_hardness, "w": base_hardness}
			continue

		var img = tex.get_image()
		if img.get_format() != Image.FORMAT_RGBA8:
			img.convert(Image.FORMAT_RGBA8)

		var size = img.get_width()

		# Compute overall average luminance
		var total_lum = 0.0
		for y in range(size):
			for x in range(size):
				total_lum += _pixel_luminance(img.get_pixel(x, y))
		var avg_lum = total_lum / float(size * size)

		if avg_lum < 0.001:
			tile["edge_hardness"] = {"n": base_hardness, "s": base_hardness, "e": base_hardness, "w": base_hardness}
			continue

		# Compute edge average luminances
		var north_lum = 0.0
		var south_lum = 0.0
		var west_lum = 0.0
		var east_lum = 0.0
		for i in range(size):
			north_lum += _pixel_luminance(img.get_pixel(i, 0))
			south_lum += _pixel_luminance(img.get_pixel(i, size - 1))
			west_lum += _pixel_luminance(img.get_pixel(0, i))
			east_lum += _pixel_luminance(img.get_pixel(size - 1, i))
		north_lum /= float(size)
		south_lum /= float(size)
		west_lum /= float(size)
		east_lum /= float(size)

		# Scale base hardness by INVERSE edge brightness relative to average
		# Dark edges (mortar) = high hardness, bright edges (stone face) = low hardness
		tile["edge_hardness"] = {
			"n": base_hardness * (avg_lum / maxf(north_lum, 0.001)),
			"s": base_hardness * (avg_lum / maxf(south_lum, 0.001)),
			"e": base_hardness * (avg_lum / maxf(east_lum, 0.001)),
			"w": base_hardness * (avg_lum / maxf(west_lum, 0.001)),
		}

		print("TileIndex: %s edge hardness N=%.2f S=%.2f E=%.2f W=%.2f (base=%d)" % [
			tile["name"],
			tile["edge_hardness"]["n"], tile["edge_hardness"]["s"],
			tile["edge_hardness"]["e"], tile["edge_hardness"]["w"],
			int(base_hardness)
		])


# Computes perceptual luminance from a color.
func _pixel_luminance(c: Color) -> float:
	return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b


# Creates a transparent placeholder image for tiles without textures.
func _create_placeholder() -> Image:
	var img = Image.create(_texture_size, _texture_size, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	return img
