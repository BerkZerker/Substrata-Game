class_name ToolDefinition extends RefCounted

var tool_name: String
var mining_speed: float
var max_durability: int
var current_durability: int
var tool_level: int


func _init(p_name: String, p_speed: float, p_durability: int, p_level: int) -> void:
	tool_name = p_name
	mining_speed = p_speed
	max_durability = p_durability
	current_durability = p_durability
	tool_level = p_level


func use() -> void:
	if max_durability > 0:
		current_durability -= 1


func is_broken() -> bool:
	return max_durability > 0 and current_durability <= 0


func can_mine(tile_hardness: int) -> bool:
	if tile_hardness <= 0:
		return true
	if tile_hardness <= 1:
		return true
	if tile_hardness <= 2:
		return tool_level >= 0
	if tile_hardness <= 3:
		return tool_level >= 1
	if tile_hardness <= 4:
		return tool_level >= 2
	return tool_level >= 3


func get_durability_fraction() -> float:
	if max_durability <= 0:
		return 1.0
	return float(current_durability) / float(max_durability)


static func create_hand() -> ToolDefinition:
	return ToolDefinition.new("Hand", 1.0, 0, 0)


static func create_wood_pickaxe() -> ToolDefinition:
	return ToolDefinition.new("Wood Pickaxe", 2.0, 100, 1)


static func create_stone_pickaxe() -> ToolDefinition:
	return ToolDefinition.new("Stone Pickaxe", 3.0, 200, 2)


static func create_iron_pickaxe() -> ToolDefinition:
	return ToolDefinition.new("Iron Pickaxe", 5.0, 500, 3)
