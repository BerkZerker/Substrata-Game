class_name DebugHUD extends PanelContainer

var _label: Label
var _player: Node = null


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


func _process(_delta: float) -> void:
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

	if GameServices.chunk_manager:
		var info = GameServices.chunk_manager.get_debug_info()
		lines.append("Chunk: %s  Region: %s" % [str(info["player_chunk"]), str(info["player_region"])])
		lines.append("--- Chunks ---")
		lines.append("Loaded: %d  Gen Queue: %d" % [info["loaded_count"], info["generation_queue_size"]])
		lines.append("In Progress: %d  Build: %d" % [info["in_progress_size"], info["build_queue_size"]])
		lines.append("Active Tasks: %d  Removal: %d" % [info.get("active_tasks", 0), info["removal_queue_size"]])

	_label.text = "\n".join(lines)
