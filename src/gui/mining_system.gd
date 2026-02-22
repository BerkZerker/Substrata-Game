class_name MiningSystem extends RefCounted

var _mining_pos: Vector2i = Vector2i(0x7FFFFFFF, 0x7FFFFFFF)
var _mining_progress: float = 0.0
var _mining_time: float = 0.0


func get_progress() -> float:
	if _mining_time <= 0.0:
		return 0.0
	return clampf(_mining_progress / _mining_time, 0.0, 1.0)


func get_mining_pos() -> Vector2i:
	return _mining_pos


func is_mining() -> bool:
	return _mining_time > 0.0 and _mining_progress < _mining_time


## Updates mining progress. Returns true when a tile is fully mined.
func update(tile_world_pos: Vector2i, tool: ToolDefinition, delta: float) -> bool:
	if tile_world_pos != _mining_pos:
		_mining_pos = tile_world_pos
		_mining_progress = 0.0
		_mining_time = _calculate_mining_time(tile_world_pos, tool)

	if _mining_time <= 0.0:
		return false

	var tile_id = _get_tile_id_at(tile_world_pos)
	if not tool.can_mine(TileIndex.get_hardness(tile_id)):
		return false

	_mining_progress += delta

	if _mining_progress >= _mining_time:
		_mining_progress = 0.0
		_mining_time = 0.0
		tool.use()
		return true

	return false


func reset() -> void:
	_mining_pos = Vector2i(0x7FFFFFFF, 0x7FFFFFFF)
	_mining_progress = 0.0
	_mining_time = 0.0


func _calculate_mining_time(tile_world_pos: Vector2i, tool: ToolDefinition) -> float:
	var tile_id = _get_tile_id_at(tile_world_pos)
	if tile_id == TileIndex.AIR:
		return 0.0
	var hardness = TileIndex.get_hardness(tile_id)
	if hardness <= 0:
		return 0.0
	return float(hardness) / tool.mining_speed


func _get_tile_id_at(tile_world_pos: Vector2i) -> int:
	if not GameServices.chunk_manager:
		return TileIndex.AIR
	var data = GameServices.chunk_manager.get_tile_at_world_pos(Vector2(tile_world_pos))
	return data[0]
