## Top-left perf/world debug readout (FPS, player position, chunk manager
## queue sizes). Hidden by default; F3 toggles it.
class_name DebugHUD extends PanelContainer

@onready var _label: Label = %Label

var _player: Node = null # Resolved lazily since Player may not exist yet on first _process


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_debug_hud"):
		visible = not visible


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

	if _player.has_method("get_movement_velocity"):
		var vel = _player.get_movement_velocity()
		lines.append("Vel: (%.1f, %.1f)  Floor: %s" % [vel.x, vel.y, str(_player.get_on_floor())])

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
