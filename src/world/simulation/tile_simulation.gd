## Simulates physics-based tile behavior such as falling sand and gravel.
##
## Scans loaded chunks near the player for gravity-affected tiles and moves
## them downward when the tile below is non-solid. Processes bottom-to-top
## within each chunk to avoid double-processing. Uses ChunkManager's batch
## tile editing API for cross-chunk safety.
class_name TileSimulation extends Node

## How many physics frames to wait between simulation ticks.
const TICK_INTERVAL: int = 3
## Maximum number of tile moves per tick to avoid frame stutter.
const MAX_MOVES_PER_TICK: int = 256

var _chunk_manager: ChunkManager
var _frame_counter: int = 0


func setup(chunk_manager: ChunkManager) -> void:
	_chunk_manager = chunk_manager


func _physics_process(_delta: float) -> void:
	if _chunk_manager == null:
		return

	_frame_counter += 1
	if _frame_counter < TICK_INTERVAL:
		return
	_frame_counter = 0

	_simulate_gravity()


func _simulate_gravity() -> void:
	var chunk_size: int = GlobalSettings.CHUNK_SIZE
	var moves_remaining: int = MAX_MOVES_PER_TICK

	# Collect changes as batch: Array of { "pos": Vector2, "tile_id": int, "cell_id": int }
	var changes: Array = []

	# Get loaded chunks near the player
	var player_chunk: Vector2i = _chunk_manager._player_chunk
	var radius: int = GlobalSettings.LOD_RADIUS * GlobalSettings.REGION_SIZE

	# Iterate chunks sorted by Y descending so lower chunks process first
	var chunk_positions: Array = []
	for cx in range(player_chunk.x - radius, player_chunk.x + radius + 1):
		for cy in range(player_chunk.y - radius, player_chunk.y + radius + 1):
			var cpos := Vector2i(cx, cy)
			if _chunk_manager.get_chunk_at(cpos) != null:
				chunk_positions.append(cpos)

	# Sort by Y descending (process lower chunks first for correct falling)
	chunk_positions.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.y > b.y)

	for chunk_pos in chunk_positions:
		if moves_remaining <= 0:
			break

		var chunk: Chunk = _chunk_manager.get_chunk_at(chunk_pos)
		if chunk == null:
			continue

		var terrain_data: PackedByteArray = chunk.get_terrain_data()
		if terrain_data.is_empty():
			continue

		# Scan bottom-to-top within the chunk to avoid double-processing
		for y in range(chunk_size - 1, -1, -1):
			for x in range(chunk_size):
				if moves_remaining <= 0:
					break

				var index: int = (y * chunk_size + x) * 2
				var tile_id: int = terrain_data[index]

				if tile_id == TileIndex.AIR:
					continue
				if not TileIndex.get_gravity_affected(tile_id):
					continue

				var cell_id: int = terrain_data[index + 1]

				# World position of this tile
				var world_x: float = chunk_pos.x * chunk_size + x
				var world_y: float = chunk_pos.y * chunk_size + y

				# Check tile below (world_y + 1 because Y-down)
				var below_pos := Vector2(world_x, world_y + 1)
				var below_tile: Array = _chunk_manager.get_tile_at_world_pos(below_pos)
				var below_id: int = below_tile[0]

				# Fall if tile below is non-solid
				if not TileIndex.is_solid(below_id) and below_id != tile_id:
					# Set current position to whatever was below (swap)
					changes.append({"pos": Vector2(world_x, world_y), "tile_id": below_id, "cell_id": below_tile[1]})
					# Set below position to the falling tile
					changes.append({"pos": below_pos, "tile_id": tile_id, "cell_id": cell_id})
					moves_remaining -= 1

			if moves_remaining <= 0:
				break

	# Apply all changes in one batch
	if not changes.is_empty():
		_chunk_manager.set_tiles_at_world_positions(changes)
