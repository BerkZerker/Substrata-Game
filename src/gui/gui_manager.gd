class_name GUIManager extends Control

# UI Elements
var _panel: PanelContainer
var _brush_size_label: Label
var _brush_preview: Node2D

# State
var _current_brush_type: int = 0 # 0: Square, 1: Circle
var _current_brush_size: int = 2
var _current_material: int = TileIndex.STONE
var _is_editing: bool = false

# Constants
const BRUSH_SQUARE = 0
const BRUSH_CIRCLE = 1


func _ready() -> void:
	_setup_ui()
	_setup_brush_preview()

func _process(_delta: float) -> void:
	_update_brush_preview()
	
	# Handle continuous editing while mouse is held
	if _is_editing:
		_apply_edit()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_is_editing = event.pressed
			if _is_editing:
				get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed:
		if event.keycode == KEY_Q:
			_change_brush_size(-1)
		elif event.keycode == KEY_E:
			_change_brush_size(1)


func _setup_ui() -> void:
	_panel = PanelContainer.new()
	add_child(_panel)
	_panel.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
	_panel.offset_top = -60
	_panel.offset_bottom = -10
	_panel.offset_left = 20
	_panel.offset_right = -20
	
	var hbox = HBoxContainer.new()
	_panel.add_child(hbox)
	hbox.alignment = BoxContainer.ALIGNMENT_CENTER
	hbox.add_theme_constant_override("separation", 20)
	
	# Brush Type
	var type_label = Label.new()
	type_label.text = "Brush:"
	hbox.add_child(type_label)
	
	var btn_square = Button.new()
	btn_square.text = "Square"
	btn_square.pressed.connect(func(): _current_brush_type = BRUSH_SQUARE)
	hbox.add_child(btn_square)
	
	var btn_circle = Button.new()
	btn_circle.text = "Circle"
	btn_circle.pressed.connect(func(): _current_brush_type = BRUSH_CIRCLE)
	hbox.add_child(btn_circle)
	
	# Separator
	hbox.add_child(VSeparator.new())
	
	# Material
	var mat_label = Label.new()
	mat_label.text = "Material:"
	hbox.add_child(mat_label)
	
	var materials = {
		"Air (Eraser)": TileIndex.AIR,
		"Dirt": TileIndex.DIRT,
		"Grass": TileIndex.GRASS,
		"Stone": TileIndex.STONE
	}
	
	for mat in materials:
		var btn = Button.new()
		btn.text = mat
		btn.pressed.connect(func(): _current_material = materials[mat])
		hbox.add_child(btn)
		
	# Separator
	hbox.add_child(VSeparator.new())
	
	# Size
	_brush_size_label = Label.new()
	_brush_size_label.text = "Size: " + str(_current_brush_size)
	hbox.add_child(_brush_size_label)


func _change_brush_size(delta: int) -> void:
	_current_brush_size = clampi(_current_brush_size + delta, 1, 64)
	_brush_size_label.text = "Size: " + str(_current_brush_size)
	if _brush_preview:
		_brush_preview.queue_redraw()


func _setup_brush_preview() -> void:
	_brush_preview = Node2D.new()
	_brush_preview.z_index = 100
	_brush_preview.set_script(load("res://src/gui/brush_preview.gd"))
	_brush_preview.set_meta("gui_manager", self)
	# Add to scene root so it renders in world space (not UI space)
	get_tree().current_scene.add_child.call_deferred(_brush_preview)


func _update_brush_preview() -> void:
	if not _brush_preview: return
	
	var mouse_pos = get_viewport().get_camera_2d().get_global_mouse_position()
	# Snap to grid
	var snapped_pos = mouse_pos.snapped(Vector2(1, 1))
	_brush_preview.global_position = snapped_pos
	_brush_preview.queue_redraw()


func _apply_edit() -> void:
	var mouse_pos = get_viewport().get_camera_2d().get_global_mouse_position()
	var center_tile = mouse_pos.floor()
	
	var changes = []
	var r = _current_brush_size
	
	# Iterate over the bounding box of the brush
	for x in range(-r, r + 1):
		for y in range(-r, r + 1):
			var offset = Vector2(x, y)
			
			if _current_brush_type == BRUSH_CIRCLE:
				if offset.length_squared() > r * r:
					continue
			
			changes.append({
				"pos": center_tile + offset,
				"tile_id": _current_material,
				"cell_id": 0 # Default cell ID for now
			})

	if GameServices.chunk_manager:
		GameServices.chunk_manager.set_tiles_at_world_positions(changes)


func _exit_tree() -> void:
	if _brush_preview:
		_brush_preview.queue_free()
