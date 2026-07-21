## Static F1 help panel. Text is authored directly on the Label in
## controls_overlay.tscn; this script only handles the show/hide toggle.
class_name ControlsOverlay extends PanelContainer


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("toggle_controls_help"):
		visible = not visible
