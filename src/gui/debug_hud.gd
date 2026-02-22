class_name DebugHUD extends PanelContainer

var _label: Label
var _player: Node = null
var _delta: float = 0.0


func _ready() -> void:
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.6)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(8)
	add_theme_stylebox_override("panel", style)

	_label = Label.new()
	_label.add_theme_font_size_override("font_size", 13)
	add_child(_label)

	visible = false


func _process(delta: float) -> void:
	_delta = delta
	if not visible:
		return

	if not _player:
		_player = get_tree().current_scene.get_node_or_null("Player")
		if not _player:
			return

	var lines: PackedStringArray = []

	lines.append("FPS: %d" % Engine.get_frames_per_second())

	var pos = _player.global_position
	lines.append("Pos: (%.1f, %.1f)" % [pos.x, pos.y])

	if _player._movement:
		var vel = _player._movement.velocity
		lines.append("Vel: (%.1f, %.1f)  Floor: %s" % [vel.x, vel.y, str(_player._movement.is_on_floor)])

	var camera = get_viewport().get_camera_2d()
	if camera:
		lines.append("Zoom: %.1fx" % camera.zoom.x)

	var frame_time_ms = _delta * 1000.0
	lines.append("Frame: %.1f ms" % frame_time_ms)

	if GameServices.chunk_manager:
		var info = GameServices.chunk_manager.get_debug_info()
		lines.append("Chunk: %s  Region: %s" % [str(info["player_chunk"]), str(info["player_region"])])
		lines.append("--- Chunks ---")
		lines.append("Loaded: %d  Gen Queue: %d" % [info["loaded_count"], info["generation_queue_size"]])
		lines.append("In Progress: %d  Build: %d" % [info["in_progress_size"], info["build_queue_size"]])
		lines.append("Active Tasks: %d  Removal: %d" % [info.get("active_tasks", 0), info["removal_queue_size"]])
		lines.append("--- Generation ---")
		lines.append("Gen/s: %.1f  Avg: %.2f ms" % [info.get("chunks_per_second", 0.0), info.get("avg_generation_time_ms", 0.0)])
		lines.append("Total Generated: %d" % info.get("total_chunks_generated", 0))
		lines.append("--- Memory ---")
		lines.append("Pool: %d / %d" % [info.get("pool_size", 0), info.get("pool_max", 0)])
		lines.append("Tex Mem: %.0f KB" % info.get("est_texture_memory_kb", 0.0))

	_label.text = "\n".join(lines)
