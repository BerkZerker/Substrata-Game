class_name ChunkDebugOverlay extends Node2D

# Debug settings
@export var show_loaded_regions: bool = true
@export var show_chunk_outlines: bool = true
@export var show_generation_queue: bool = true
@export var show_removal_queue: bool = true
@export var show_queue_info: bool = true

# Colors
const COLOR_LOADED_REGION: Color = Color(0.2, 0.8, 0.2, 0.15)
const COLOR_CHUNK_OUTLINE: Color = Color(1.0, 1.0, 1.0, 1.0)
const COLOR_GENERATION_QUEUE: Color = Color(1.0, 1.0, 0.0, 0.4)
const COLOR_REMOVAL_QUEUE: Color = Color(1.0, 0.0, 1.0, 0.4)
const COLOR_IN_PROGRESS: Color = Color(0.0, 1.0, 1.0, 0.4)

var _info_label: Label = null
var _debug_info: Dictionary = {}


func _ready() -> void:
	_info_label = Label.new()
	_info_label.add_theme_font_size_override("font_size", 12)
	add_child(_info_label)
	z_index = 100


func _unhandled_input(event: InputEvent) -> void:
	if not event.is_pressed():
		return

	if event.is_action("debug_toggle_all"):
		toggle_all()
	elif event.is_action("debug_toggle_chunk_borders"):
		toggle_chunk_outlines()
	elif event.is_action("debug_toggle_region_borders"):
		toggle_loaded_regions()
	elif event.is_action("debug_toggle_generation_queue"):
		toggle_generation_queue()
	elif event.is_action("debug_toggle_removal_queue"):
		toggle_removal_queue()
	elif event.is_action("debug_toggle_queue_info"):
		toggle_queue_info()


func _process(_delta: float) -> void:
	if not GameServices.chunk_manager:
		return

	_debug_info = GameServices.chunk_manager.get_debug_info()
	queue_redraw()
	_update_info_label()


func _draw() -> void:
	if _debug_info.is_empty():
		return

	if show_loaded_regions:
		_draw_loaded_regions()

	if show_generation_queue:
		_draw_generation_queue()

	if show_removal_queue:
		_draw_removal_queue()

	if show_chunk_outlines:
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


func _update_info_label() -> void:
	if not show_queue_info:
		_info_label.visible = false
		return

	_info_label.visible = true

	# Keep label in top-left of viewport
	var camera = get_viewport().get_camera_2d()
	if camera:
		var viewport_size = get_viewport_rect().size
		var top_left = camera.global_position - viewport_size / camera.zoom / 2.0
		_info_label.global_position = top_left + Vector2(10, 10) / camera.zoom
		_info_label.scale = Vector2.ONE / camera.zoom

	var info_text = "=== CHUNK DEBUG ===\n"
	info_text += "Loaded Chunks: %d\n" % _debug_info["loaded_count"]
	info_text += "Generation Queue: %d\n" % _debug_info["generation_queue_size"]
	info_text += "In Progress: %d\n" % _debug_info["in_progress_size"]
	info_text += "Active Tasks: %d\n" % _debug_info.get("active_tasks", 0)
	info_text += "Build Queue: %d\n" % _debug_info["build_queue_size"]
	info_text += "Removal Queue: %d\n" % _debug_info["removal_queue_size"]
	info_text += "\nPlayer Chunk: %s\n" % str(_debug_info["player_chunk"])
	info_text += "Player Region: %s" % str(_debug_info["player_region"])

	_info_label.text = info_text


func toggle_loaded_regions() -> void:
	show_loaded_regions = not show_loaded_regions


func toggle_chunk_outlines() -> void:
	show_chunk_outlines = not show_chunk_outlines


func toggle_generation_queue() -> void:
	show_generation_queue = not show_generation_queue


func toggle_removal_queue() -> void:
	show_removal_queue = not show_removal_queue


func toggle_queue_info() -> void:
	show_queue_info = not show_queue_info


func toggle_all() -> void:
	var new_state = not (show_loaded_regions and show_chunk_outlines and show_generation_queue and show_removal_queue and show_queue_info)
	show_loaded_regions = new_state
	show_chunk_outlines = new_state
	show_generation_queue = new_state
	show_removal_queue = new_state
	show_queue_info = new_state
