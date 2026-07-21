class_name ControlsOverlay extends PanelContainer


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_controls_help"):
		visible = not visible
