class_name GUIManager extends Control

# Components
var _toolbar: EditingToolbar
var _debug_hud: DebugHUD
var _cursor_info: CursorInfo
var _controls_overlay: ControlsOverlay
var _brush_preview: Node2D

# State
var _current_brush_type: int = 0
var _current_brush_size: int = 2
var _current_material: int = TileIndex.STONE
var _is_editing: bool = false

# Constants
const BRUSH_SQUARE = 0
const BRUSH_CIRCLE = 1


func _ready() -> void:
	_setup_components()
	_setup_brush_preview()


func _setup_components() -> void:
	# Left panel for toolbar + debug HUD (stacks vertically)
	var left_panel = VBoxContainer.new()
	left_panel.set_anchors_preset(Control.PRESET_TOP_LEFT)
	left_panel.offset_left = 10
	left_panel.offset_top = 10
	left_panel.add_theme_constant_override("separation", 6)
	left_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(left_panel)

	# Editing toolbar
	_toolbar = EditingToolbar.new()
	left_panel.add_child(_toolbar)
	_toolbar.brush_type_changed.connect(_on_brush_type_changed)
	_toolbar.material_changed.connect(_on_material_changed)
	_toolbar.brush_size_changed.connect(_on_brush_size_changed)

	# Debug HUD (starts hidden, F3 toggles)
	_debug_hud = DebugHUD.new()
	left_panel.add_child(_debug_hud)

	# Cursor info (starts visible, F2 toggles)
	_cursor_info = CursorInfo.new()
	add_child(_cursor_info)

	# Controls overlay (starts hidden, F1 toggles)
	_controls_overlay = ControlsOverlay.new()
	add_child(_controls_overlay)


func _process(_delta: float) -> void:
	_update_brush_preview()

	if _is_editing:
		_apply_edit()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_is_editing = event.pressed
			if _is_editing:
				get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed:
		return

	# Material selection
	if event.keycode == KEY_Q:
		_change_brush_size(-1)
	elif event.keycode == KEY_E:
		_change_brush_size(1)
	elif event.keycode == KEY_1:
		_set_material(TileIndex.AIR)
	elif event.keycode == KEY_2:
		_set_material(TileIndex.DIRT)
	elif event.keycode == KEY_3:
		_set_material(TileIndex.GRASS)
	elif event.keycode == KEY_4:
		_set_material(TileIndex.STONE)

	# Debug toggles
	if event.is_action_pressed("toggle_controls_help"):
		_controls_overlay.visible = not _controls_overlay.visible
	elif event.is_action_pressed("toggle_cursor_info"):
		_cursor_info.visible = not _cursor_info.visible
	elif event.is_action_pressed("toggle_debug_hud"):
		_debug_hud.visible = not _debug_hud.visible


func _set_material(tile_id: int) -> void:
	_current_material = tile_id
	_toolbar.select_material(tile_id)


func _change_brush_size(delta: int) -> void:
	_current_brush_size = clampi(_current_brush_size + delta, 1, 64)
	_toolbar.set_brush_size(_current_brush_size)
	if _brush_preview:
		_brush_preview.queue_redraw()


func _on_brush_type_changed(brush_type: int) -> void:
	_current_brush_type = brush_type


func _on_material_changed(tile_id: int) -> void:
	_current_material = tile_id
	_toolbar.select_material(tile_id)


func _on_brush_size_changed(new_size: int) -> void:
	new_size = clampi(new_size, 1, 64)
	_current_brush_size = new_size
	_toolbar.set_brush_size(new_size)
	if _brush_preview:
		_brush_preview.queue_redraw()


func _setup_brush_preview() -> void:
	_brush_preview = Node2D.new()
	_brush_preview.z_index = 100
	_brush_preview.set_script(load("res://src/gui/brush_preview.gd"))
	_brush_preview.set_meta("gui_manager", self)
	get_tree().current_scene.add_child.call_deferred(_brush_preview)


func _update_brush_preview() -> void:
	if not _brush_preview: return

	var mouse_pos = get_viewport().get_camera_2d().get_global_mouse_position()
	var snapped_pos = mouse_pos.snapped(Vector2(1, 1))
	_brush_preview.global_position = snapped_pos
	_brush_preview.queue_redraw()


func _apply_edit() -> void:
	var mouse_pos = get_viewport().get_camera_2d().get_global_mouse_position()
	var center_tile = mouse_pos.floor()

	var changes = []
	var r = _current_brush_size

	for x in range(-r, r + 1):
		for y in range(-r, r + 1):
			var offset = Vector2(x, y)

			if _current_brush_type == BRUSH_CIRCLE:
				if offset.length_squared() > r * r:
					continue

			changes.append({
				"pos": center_tile + offset,
				"tile_id": _current_material,
				"cell_id": 0
			})

	if GameServices.chunk_manager:
		GameServices.chunk_manager.set_tiles_at_world_positions(changes)


func _exit_tree() -> void:
	if _brush_preview:
		_brush_preview.queue_free()
