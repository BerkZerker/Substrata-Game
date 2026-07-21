## Top-center material hotbar. Slots are built at runtime from TileIndex so
## the number of materials (and future item types) isn't hard-coded here.
class_name Hotbar extends PanelContainer

const SLOT_SCENE: PackedScene = preload("res://src/gui/hotbar/hotbar_slot.tscn")
const MAX_SLOTS: int = 9

@onready var _slots_row: HBoxContainer = %SlotsRow
@onready var _value_label: Label = %ValueLabel

var _button_group: ButtonGroup = ButtonGroup.new()
var _slot_buttons: Dictionary = {} # tile_id -> Button


func _ready() -> void:
	_build_slots()
	_value_label.text = _format_value(GlobalSettings.DEFAULT_BRUSH_VALUE)
	_select_slot(TileIndex.STONE)

	SignalBus.material_selected.connect(_select_slot)
	SignalBus.brush_value_changed.connect(_on_brush_value_changed)


func _build_slots() -> void:
	var tile_ids = TileIndex.get_tile_ids()

	for i in range(mini(MAX_SLOTS, tile_ids.size())):
		var tile_id: int = tile_ids[i]
		var slot: Button = SLOT_SCENE.instantiate()
		slot.button_group = _button_group
		slot.tooltip_text = TileIndex.get_tile_name(tile_id)
		slot.get_node("%KeyLabel").text = str(i + 1)
		slot.get_node("%Icon").texture = _get_slot_icon(tile_id)
		slot.pressed.connect(func(): GameServices.terrain_edit_controller.set_material(tile_id))

		_slots_row.add_child(slot)
		_slot_buttons[tile_id] = slot


func _get_slot_icon(tile_id: int) -> Texture2D:
	var texture_path: String = TileIndex.get_tile_def(tile_id).get("texture_path", "")
	if not texture_path.is_empty():
		return load(texture_path)

	# Materials without art (e.g. Air) fall back to a flat color swatch.
	var image := Image.create(1, 1, false, Image.FORMAT_RGBA8)
	image.set_pixel(0, 0, TileIndex.get_tile_color(tile_id))
	return ImageTexture.create_from_image(image)


func _select_slot(tile_id: int) -> void:
	if _slot_buttons.has(tile_id):
		_slot_buttons[tile_id].button_pressed = true


func _on_brush_value_changed(value: float) -> void:
	_value_label.text = _format_value(value)


func _format_value(value: float) -> String:
	return "Brush: %d" % roundi(value)
