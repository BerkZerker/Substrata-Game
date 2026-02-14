class_name EditingToolbar extends PanelContainer

signal brush_type_changed(brush_type: int)
signal material_changed(tile_id: int)
signal brush_size_changed(new_size: int)

const BRUSH_SQUARE = 0
const BRUSH_CIRCLE = 1

const MATERIAL_COLORS: Dictionary = {
	0: Color(0.7, 0.8, 0.9, 0.5),  # AIR
	1: Color(0.55, 0.35, 0.2),      # DIRT
	2: Color(0.3, 0.7, 0.2),        # GRASS
	3: Color(0.5, 0.5, 0.5),        # STONE
}

var _material_buttons: Dictionary = {}
var _brush_size_label: Label
var _current_material: int = 3
var _current_brush_size: int = 2


func _ready() -> void:
	var style = StyleBoxFlat.new()
	style.bg_color = Color(0, 0, 0, 0.6)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(8)
	add_theme_stylebox_override("panel", style)

	var vbox = VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 6)
	add_child(vbox)

	_build_brush_type_row(vbox)
	_build_material_row(vbox)
	_build_size_row(vbox)
	_update_material_highlight()


func _build_brush_type_row(parent: Control) -> void:
	var row = HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	parent.add_child(row)

	var label = Label.new()
	label.text = "Brush:"
	row.add_child(label)

	var btn_square = Button.new()
	btn_square.text = "Square"
	btn_square.pressed.connect(func(): brush_type_changed.emit(BRUSH_SQUARE))
	row.add_child(btn_square)

	var btn_circle = Button.new()
	btn_circle.text = "Circle"
	btn_circle.pressed.connect(func(): brush_type_changed.emit(BRUSH_CIRCLE))
	row.add_child(btn_circle)


func _build_material_row(parent: Control) -> void:
	var row = HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	parent.add_child(row)

	var materials = [
		{"name": "Air", "id": TileIndex.AIR, "key": "1"},
		{"name": "Dirt", "id": TileIndex.DIRT, "key": "2"},
		{"name": "Grass", "id": TileIndex.GRASS, "key": "3"},
		{"name": "Stone", "id": TileIndex.STONE, "key": "4"},
	]

	for mat in materials:
		var container = HBoxContainer.new()
		container.add_theme_constant_override("separation", 2)
		row.add_child(container)

		var swatch = ColorRect.new()
		swatch.custom_minimum_size = Vector2(12, 12)
		swatch.color = MATERIAL_COLORS[mat["id"]]
		container.add_child(swatch)

		var btn = Button.new()
		btn.text = "%s [%s]" % [mat["name"], mat["key"]]
		var tile_id: int = mat["id"]
		btn.pressed.connect(func(): material_changed.emit(tile_id))
		container.add_child(btn)

		_material_buttons[tile_id] = btn


func _build_size_row(parent: Control) -> void:
	var row = HBoxContainer.new()
	row.add_theme_constant_override("separation", 4)
	parent.add_child(row)

	var size_label = Label.new()
	size_label.text = "Size:"
	row.add_child(size_label)

	var q_label = Label.new()
	q_label.text = "Q"
	row.add_child(q_label)

	var btn_minus = Button.new()
	btn_minus.text = "-"
	btn_minus.pressed.connect(func(): brush_size_changed.emit(_current_brush_size - 1))
	row.add_child(btn_minus)

	_brush_size_label = Label.new()
	_brush_size_label.text = str(_current_brush_size)
	_brush_size_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_brush_size_label.custom_minimum_size.x = 24
	row.add_child(_brush_size_label)

	var btn_plus = Button.new()
	btn_plus.text = "+"
	btn_plus.pressed.connect(func(): brush_size_changed.emit(_current_brush_size + 1))
	row.add_child(btn_plus)

	var e_label = Label.new()
	e_label.text = "E"
	row.add_child(e_label)


func select_material(tile_id: int) -> void:
	_current_material = tile_id
	_update_material_highlight()


func set_brush_size(size: int) -> void:
	_current_brush_size = size
	_brush_size_label.text = str(size)


func _update_material_highlight() -> void:
	for id in _material_buttons:
		if id == _current_material:
			_material_buttons[id].modulate = Color(0.5, 0.8, 1.0)
		else:
			_material_buttons[id].modulate = Color(1.0, 1.0, 1.0)
