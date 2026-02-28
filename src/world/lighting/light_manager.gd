## Manages dynamic point lights and day/night cycle ambient lighting.
##
## Up to 16 dynamic point lights. Each frame, packages light data and pushes
## shader uniforms to all loaded chunks. Also drives TimeOfDay for ambient.
class_name LightManager extends Node

const MAX_LIGHTS: int = 16

## Day/night cycle controller.
var time_of_day: TimeOfDay = TimeOfDay.new()

var _lights: Dictionary = {} # { int: Dictionary }
var _next_light_id: int = 1
var _chunk_manager: ChunkManager = null


func setup(chunk_manager: ChunkManager) -> void:
	_chunk_manager = chunk_manager


func _process(delta: float) -> void:
	if _chunk_manager == null:
		return

	# Advance day/night cycle
	time_of_day.advance(delta)
	var ambient = time_of_day.get_ambient_level()

	# Package dynamic light data into Packed arrays (required by Godot shader uniforms)
	var positions := PackedVector2Array()
	var radii := PackedFloat32Array()
	var colors := PackedColorArray()
	var count: int = 0

	for light in _lights.values():
		if count >= MAX_LIGHTS:
			break
		positions.append(light["position"])
		radii.append(light["radius"])
		colors.append(light["color"])
		count += 1

	# Pad arrays to MAX_LIGHTS
	while positions.size() < MAX_LIGHTS:
		positions.append(Vector2.ZERO)
		radii.append(0.0)
		colors.append(Color(0, 0, 0, 0))

	# Push uniforms to all loaded chunks
	var chunk_positions = _chunk_manager.get_loaded_chunk_positions()
	for chunk_pos in chunk_positions:
		var chunk = _chunk_manager.get_chunk_at(chunk_pos)
		if chunk != null:
			chunk.set_shader_parameter("ambient_light", ambient)
			chunk.set_shader_parameter("num_dynamic_lights", count)
			chunk.set_shader_parameter("dynamic_light_positions", positions)
			chunk.set_shader_parameter("dynamic_light_radii", radii)
			chunk.set_shader_parameter("dynamic_light_colors", colors)


## Adds a dynamic point light. Returns light ID for later updates.
## color.a is used as intensity.
func add_light(light_position: Vector2, radius: float, color: Color = Color(1, 1, 1, 1), intensity: float = 1.0) -> int:
	var id = _next_light_id
	_next_light_id += 1
	_lights[id] = {
		"position": light_position,
		"radius": radius,
		"color": Color(color.r, color.g, color.b, intensity),
	}
	return id


## Removes a dynamic light by ID.
func remove_light(id: int) -> void:
	_lights.erase(id)


## Updates the position of an existing dynamic light.
func update_light_position(id: int, new_position: Vector2) -> void:
	var light = _lights.get(id)
	if light != null:
		light["position"] = new_position


## Updates the radius of an existing dynamic light.
func update_light_radius(id: int, new_radius: float) -> void:
	var light = _lights.get(id)
	if light != null:
		light["radius"] = new_radius


## Returns the number of active dynamic lights.
func get_light_count() -> int:
	return _lights.size()
