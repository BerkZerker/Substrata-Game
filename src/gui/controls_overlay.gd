class_name ControlsOverlay extends PanelContainer


func _ready() -> void:
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.8)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(20)
	add_theme_stylebox_override("panel", style)

	set_anchors_preset(Control.PRESET_CENTER)

	var label = Label.new()
	label.add_theme_font_size_override("font_size", 14)
	label.text = "=== Controls ===\n\nMovement\n  A / D ........... Move Left / Right\n  Space ........... Jump\n  Scroll .......... Zoom\n\nEditing\n  LMB Hold ........ Paint Terrain\n  1 / 2 / 3 / 4 .. Air / Dirt / Grass / Stone\n  Q / E ........... Brush Size\n\nDebug & UI\n  F1 .............. This Help\n  F2 .............. Cursor Info\n  F3 .............. Debug HUD\n  F4 .............. World Overlay"
	add_child(label)

	visible = false
