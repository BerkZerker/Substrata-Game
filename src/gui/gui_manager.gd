class_name GUIManager extends Control

# Components
var _toolbar: EditingToolbar
var _debug_hud: DebugHUD
var _cursor_info: CursorInfo
var _controls_overlay: ControlsOverlay
var _frame_graph: FrameGraph
var _brush_preview: Node2D
var _tool_label: Label

# State
var _current_brush_type: int = 0
var _current_brush_size: int = 2
var _current_material: int = TileIndex.STONE
var _is_editing: bool = false

# Mining state
var _is_mining: bool = false
var _mining_system: MiningSystem = MiningSystem.new()
var _tools: Array[ToolDefinition] = []
var _current_tool_index: int = 0

# Constants
const BRUSH_SQUARE = 0
const BRUSH_CIRCLE = 1


func _ready() -> void:
	_setup_tools()
	_setup_components()
	_setup_brush_preview()


func _setup_tools() -> void:
	_tools.append(ToolDefinition.create_hand())
	_tools.append(ToolDefinition.create_wood_pickaxe())
	_tools.append(ToolDefinition.create_stone_pickaxe())
	_tools.append(ToolDefinition.create_iron_pickaxe())


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

	# Tool info label
	_tool_label = Label.new()
	_tool_label.add_theme_font_size_override("font_size", 13)
	_tool_label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.6))
	left_panel.add_child(_tool_label)
	_update_tool_label()

	# Debug HUD (starts hidden, F3 toggles)
	_debug_hud = DebugHUD.new()
	left_panel.add_child(_debug_hud)

	# Cursor info (starts visible, F2 toggles)
	_cursor_info = CursorInfo.new()
	add_child(_cursor_info)

	# Controls overlay (starts hidden, F1 toggles)
	_controls_overlay = ControlsOverlay.new()
	add_child(_controls_overlay)

	# Frame time graph (starts hidden, F7 toggles) — anchored top-right
	_frame_graph = FrameGraph.new()
	_frame_graph.set_anchors_preset(Control.PRESET_TOP_RIGHT)
	_frame_graph.offset_right = -10
	_frame_graph.offset_left = -10 - _frame_graph.custom_minimum_size.x
	_frame_graph.offset_top = 10
	_frame_graph.offset_bottom = 10 + _frame_graph.custom_minimum_size.y
	add_child(_frame_graph)


func _process(delta: float) -> void:
	_update_brush_preview()

	if _is_editing:
		_apply_edit()

	if _is_mining:
		_apply_mining(delta)
	else:
		_mining_system.reset()


func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		if event.button_index == MOUSE_BUTTON_LEFT:
			_is_editing = event.pressed
			if _is_editing:
				get_viewport().set_input_as_handled()
		elif event.button_index == MOUSE_BUTTON_RIGHT:
			_is_mining = event.pressed
			if not _is_mining:
				_mining_system.reset()
			if _is_mining:
				get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if not event is InputEventKey or not event.pressed:
		return

	# Brush size
	if event.keycode == KEY_Q:
		_change_brush_size(-1)
	elif event.keycode == KEY_E:
		_change_brush_size(1)

	# Tool switching with Shift+1-4
	if event.shift_pressed:
		if event.keycode == KEY_1:
			_select_tool(0)
			return
		elif event.keycode == KEY_2:
			_select_tool(1)
			return
		elif event.keycode == KEY_3:
			_select_tool(2)
			return
		elif event.keycode == KEY_4:
			_select_tool(3)
			return

	# Material selection: number keys 1-9 map to tile IDs in registry order
	var number_keys = [KEY_1, KEY_2, KEY_3, KEY_4, KEY_5, KEY_6, KEY_7, KEY_8, KEY_9]
	var tile_ids = TileIndex.get_tile_ids()
	for i in range(mini(number_keys.size(), tile_ids.size())):
		if event.keycode == number_keys[i]:
			_set_material(tile_ids[i])

	# Debug toggles
	if event.is_action_pressed("toggle_controls_help"):
		_controls_overlay.visible = not _controls_overlay.visible
	elif event.is_action_pressed("toggle_cursor_info"):
		_cursor_info.visible = not _cursor_info.visible
	elif event.is_action_pressed("toggle_debug_hud"):
		_debug_hud.visible = not _debug_hud.visible
	elif event.is_action_pressed("toggle_frame_graph"):
		_frame_graph.visible = not _frame_graph.visible


func _select_tool(index: int) -> void:
	if index < 0 or index >= _tools.size():
		return
	# If current tool is broken, skip it (except hand)
	if _tools[index].is_broken() and index != 0:
		return
	_current_tool_index = index
	_update_tool_label()


func _get_current_tool() -> ToolDefinition:
	var tool = _tools[_current_tool_index]
	if tool.is_broken() and _current_tool_index != 0:
		_current_tool_index = 0
		_update_tool_label()
		return _tools[0]
	return tool


func _update_tool_label() -> void:
	if not _tool_label:
		return
	var tool = _tools[_current_tool_index]
	var durability_text = ""
	if tool.max_durability > 0:
		durability_text = " [%d/%d]" % [tool.current_durability, tool.max_durability]
	_tool_label.text = "Tool (Shift+1-4): %s%s" % [tool.tool_name, durability_text]


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


func _apply_mining(delta: float) -> void:
	var camera = get_viewport().get_camera_2d()
	if not camera:
		return
	var mouse_pos = camera.get_global_mouse_position()
	var tile_pos = Vector2i(mouse_pos.floor())

	var tool = _get_current_tool()
	var mined = _mining_system.update(tile_pos, tool, delta)

	if mined:
		# Spawn mining particles before replacing tile
		var tile_data = GameServices.chunk_manager.get_tile_at_world_pos(Vector2(tile_pos)) if GameServices.chunk_manager else [0, 0]
		_spawn_mining_particles(Vector2(tile_pos) + Vector2(0.5, 0.5), tile_data[0])

		# Replace mined tile with AIR
		var changes = [{
			"pos": Vector2(tile_pos),
			"tile_id": TileIndex.AIR,
			"cell_id": 0
		}]
		if GameServices.chunk_manager:
			GameServices.chunk_manager.set_tiles_at_world_positions(changes)
		_update_tool_label()


func _spawn_mining_particles(world_pos: Vector2, tile_id: int) -> void:
	var particles = CPUParticles2D.new()
	particles.emitting = true
	particles.one_shot = true
	particles.explosiveness = 0.9
	particles.amount = 12
	particles.lifetime = 0.5

	# Use the tile's UI color for particle tint
	var tile_color = TileIndex.get_tile_color(tile_id)
	particles.color = tile_color

	# Particle motion
	particles.direction = Vector2(0, -1)
	particles.spread = 180.0
	particles.initial_velocity_min = 30.0
	particles.initial_velocity_max = 80.0
	particles.gravity = Vector2(0, 200)

	# Small square particles
	particles.scale_amount_min = 0.5
	particles.scale_amount_max = 1.5

	# Position at the tile center in world space
	particles.global_position = world_pos
	particles.z_index = 50

	# Auto-free after particles finish
	get_tree().current_scene.add_child(particles)
	get_tree().create_timer(particles.lifetime + 0.1).timeout.connect(particles.queue_free)


func _exit_tree() -> void:
	if _brush_preview:
		_brush_preview.queue_free()
