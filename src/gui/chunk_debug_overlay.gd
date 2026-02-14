class_name ChunkDebugOverlay extends Node2D

# Colors
const COLOR_LOADED_REGION: Color = Color(0.2, 0.8, 0.2, 0.15)
const COLOR_CHUNK_OUTLINE: Color = Color(1.0, 1.0, 1.0, 1.0)
const COLOR_GENERATION_QUEUE: Color = Color(1.0, 1.0, 0.0, 0.4)
const COLOR_REMOVAL_QUEUE: Color = Color(1.0, 0.0, 1.0, 0.4)
const COLOR_IN_PROGRESS: Color = Color(0.0, 1.0, 1.0, 0.4)

var _debug_info: Dictionary = {}


func _ready() -> void:
	z_index = 100
	visible = false


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_debug_world_overlay"):
		visible = not visible


func _process(_delta: float) -> void:
	if not visible:
		return
	if not GameServices.chunk_manager:
		return

	_debug_info = GameServices.chunk_manager.get_debug_info()
	queue_redraw()


func _draw() -> void:
	if _debug_info.is_empty():
		return

	_draw_loaded_regions()
	_draw_generation_queue()
	_draw_removal_queue()
	_draw_chunk_outlines()


func _draw_loaded_regions() -> void:
	var chunk_size = GlobalSettings.CHUNK_SIZE
	var region_size_pixels = GlobalSettings.REGION_SIZE * chunk_size

	var loaded_regions: Dictionary = {}
	for chunk_pos in _debug_info["loaded_chunks"]:
		var region_pos = Vector2i(
			floori(float(chunk_pos.x) / GlobalSettings.REGION_SIZE),
			floori(float(chunk_pos.y) / GlobalSettings.REGION_SIZE)
		)
		loaded_regions[region_pos] = true

	for region_pos in loaded_regions.keys():
		var world_pos = Vector2(region_pos.x * region_size_pixels, region_pos.y * region_size_pixels)
		draw_rect(Rect2(world_pos, Vector2(region_size_pixels, region_size_pixels)), COLOR_LOADED_REGION, true)


func _draw_chunk_outlines() -> void:
	var chunk_size = GlobalSettings.CHUNK_SIZE

	for chunk_pos in _debug_info["loaded_chunks"]:
		var pos = Vector2(chunk_pos.x * chunk_size, chunk_pos.y * chunk_size)
		draw_rect(Rect2(pos, Vector2(chunk_size, chunk_size)), COLOR_CHUNK_OUTLINE, false, 1.0)


func _draw_generation_queue() -> void:
	var chunk_size = GlobalSettings.CHUNK_SIZE

	for chunk_pos in _debug_info["generation_queue"]:
		var pos = Vector2(chunk_pos.x * chunk_size, chunk_pos.y * chunk_size)
		draw_rect(Rect2(pos, Vector2(chunk_size, chunk_size)), COLOR_GENERATION_QUEUE, true)

	for chunk_pos in _debug_info["in_progress"]:
		var pos = Vector2(chunk_pos.x * chunk_size, chunk_pos.y * chunk_size)
		draw_rect(Rect2(pos, Vector2(chunk_size, chunk_size)), COLOR_IN_PROGRESS, true)


func _draw_removal_queue() -> void:
	var chunk_size = GlobalSettings.CHUNK_SIZE

	for chunk_pos in _debug_info["removal_positions"]:
		var pos = Vector2(chunk_pos.x * chunk_size, chunk_pos.y * chunk_size)
		draw_rect(Rect2(pos, Vector2(chunk_size, chunk_size)), COLOR_REMOVAL_QUEUE, true)
