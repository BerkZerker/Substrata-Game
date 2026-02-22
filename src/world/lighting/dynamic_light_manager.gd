## Manages GPU-side dynamic lights that overlay on top of static chunk lighting.
##
## Packs light data into a 1D data texture each frame and sets global shader
## uniforms so all chunk shaders can sample it. Supports persistent lights
## (e.g. player torch) and transient fire-and-forget lights with TTL.
class_name DynamicLightManager extends Node

const MAX_LIGHTS: int = 64
## Each light uses 2 pixels in the data texture: (x, y, radius, intensity), (r, g, b, _)
const PIXELS_PER_LIGHT: int = 2

var _lights: Dictionary = {}  # { int id: Dictionary light_data }
var _next_id: int = 1
var _data_image: Image
var _data_texture: ImageTexture
var _dirty: bool = true


func _ready() -> void:
	# Register global shader uniforms
	RenderingServer.global_shader_parameter_add(
		"dynamic_light_count", RenderingServer.GLOBAL_VAR_TYPE_INT, 0
	)

	# Create the data texture (MAX_LIGHTS * PIXELS_PER_LIGHT wide, 1 pixel tall)
	var width: int = MAX_LIGHTS * PIXELS_PER_LIGHT
	_data_image = Image.create(width, 1, false, Image.FORMAT_RGBAF)
	_data_texture = ImageTexture.create_from_image(_data_image)

	RenderingServer.global_shader_parameter_add(
		"dynamic_light_data", RenderingServer.GLOBAL_VAR_TYPE_SAMPLER2D, _data_texture
	)


func _process(delta: float) -> void:
	_update_transient_lights(delta)
	if _dirty:
		_pack_and_upload()
		_dirty = false


## Adds a persistent dynamic light. Returns a light ID for later updates.
func add_light(pos: Vector2, radius: float, intensity: float, color: Color = Color.WHITE) -> int:
	var id: int = _next_id
	_next_id += 1
	_lights[id] = {
		"position": pos,
		"radius": radius,
		"intensity": intensity,
		"color": color,
		"ttl": -1.0,  # Persistent (no expiry)
		"max_ttl": -1.0,
	}
	_dirty = true
	return id


## Removes a dynamic light by ID.
func remove_light(id: int) -> void:
	if _lights.erase(id):
		_dirty = true


## Updates the position of an existing dynamic light.
func update_light_position(id: int, pos: Vector2) -> void:
	if _lights.has(id):
		_lights[id]["position"] = pos
		_dirty = true


## Updates properties of an existing dynamic light.
func update_light(id: int, pos: Vector2, radius: float = -1.0, intensity: float = -1.0) -> void:
	if _lights.has(id):
		_lights[id]["position"] = pos
		if radius >= 0.0:
			_lights[id]["radius"] = radius
		if intensity >= 0.0:
			_lights[id]["intensity"] = intensity
		_dirty = true


## Adds a transient (fire-and-forget) light with a time-to-live.
## Intensity fades linearly over the TTL duration.
func add_transient_light(pos: Vector2, radius: float, intensity: float, ttl: float, color: Color = Color.WHITE) -> int:
	var id: int = _next_id
	_next_id += 1
	_lights[id] = {
		"position": pos,
		"radius": radius,
		"intensity": intensity,
		"color": color,
		"ttl": ttl,
		"max_ttl": ttl,
	}
	_dirty = true
	return id


## Updates transient lights: ticks down TTL and removes expired lights.
func _update_transient_lights(delta: float) -> void:
	var expired: Array[int] = []
	for id in _lights:
		var light: Dictionary = _lights[id]
		if light["ttl"] < 0.0:
			continue  # Persistent light
		light["ttl"] -= delta
		if light["ttl"] <= 0.0:
			expired.append(id)
		else:
			_dirty = true  # Intensity changes each frame due to fade
	for id in expired:
		_lights.erase(id)
		_dirty = true


## Packs all active lights into the data texture and uploads to GPU.
func _pack_and_upload() -> void:
	var count: int = mini(_lights.size(), MAX_LIGHTS)
	var width: int = MAX_LIGHTS * PIXELS_PER_LIGHT

	# Clear image
	_data_image.fill(Color(0, 0, 0, 0))

	var idx: int = 0
	for id in _lights:
		if idx >= MAX_LIGHTS:
			break
		var light: Dictionary = _lights[id]
		var pos: Vector2 = light["position"]
		var radius: float = light["radius"]
		var intensity: float = light["intensity"]
		var color: Color = light["color"]

		# Apply fade for transient lights
		if light["ttl"] >= 0.0 and light["max_ttl"] > 0.0:
			intensity *= light["ttl"] / light["max_ttl"]

		# Pixel 0: position (R=x, G=y), radius (B), intensity (A)
		var px0: int = idx * PIXELS_PER_LIGHT
		_data_image.set_pixel(px0, 0, Color(pos.x, pos.y, radius, intensity))

		# Pixel 1: color (R, G, B), unused (A)
		_data_image.set_pixel(px0 + 1, 0, Color(color.r, color.g, color.b, 0.0))

		idx += 1

	_data_texture.update(_data_image)
	RenderingServer.global_shader_parameter_set("dynamic_light_count", count)


func _exit_tree() -> void:
	RenderingServer.global_shader_parameter_remove("dynamic_light_count")
	RenderingServer.global_shader_parameter_remove("dynamic_light_data")
