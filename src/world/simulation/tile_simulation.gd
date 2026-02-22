## Simulates physics-based tile behavior such as falling sand and gravel.
##
## Uses a dirty-chunk tracking approach: only scans chunks that were recently
## edited or had falling tiles. Edits chunk data directly via edit_tiles()
## to avoid the heavy set_tiles_at_world_positions() path (which triggers
## full light recalculation and signal emission).
class_name TileSimulation extends Node

## How many physics frames to wait between simulation ticks.
const TICK_INTERVAL: int = 6
## Maximum number of tile moves per tick to avoid frame stutter.
const MAX_MOVES_PER_TICK: int = 48
## Max chunks to scan per tick.
const MAX_CHUNKS_PER_TICK: int = 4

var _chunk_manager: ChunkManager
var _frame_counter: int = 0
## Chunks that need gravity simulation (recently edited or had active falls).
var _dirty_chunks: Dictionary = {}  # { Vector2i: true }


func setup(chunk_manager: ChunkManager) -> void:
	_chunk_manager = chunk_manager
	SignalBus.tile_changed.connect(_on_tile_changed)


func _on_tile_changed(pos: Vector2, _old_id: int, new_id: int) -> void:
	if TileIndex.get_gravity_affected(new_id):
		var cx: int = int(floor(pos.x)) >> 5  # / 32 via bit shift
		var cy: int = int(floor(pos.y)) >> 5
		_dirty_chunks[Vector2i(cx, cy)] = true


func _physics_process(_delta: float) -> void:
	if _chunk_manager == null or _dirty_chunks.is_empty():
		return

	_frame_counter += 1
	if _frame_counter < TICK_INTERVAL:
		return
	_frame_counter = 0

	_simulate_gravity()


func _simulate_gravity() -> void:
	var chunk_size: int = GlobalSettings.CHUNK_SIZE
	var moves_remaining: int = MAX_MOVES_PER_TICK

	# Snapshot dirty chunks and clear
	var to_process: Array[Vector2i] = []
	for pos in _dirty_chunks:
		to_process.append(pos)
	_dirty_chunks.clear()

	# Sort Y descending (lower chunks first)
	to_process.sort_custom(func(a: Vector2i, b: Vector2i) -> bool: return a.y > b.y)

	# Limit chunks per tick, re-queue excess
	if to_process.size() > MAX_CHUNKS_PER_TICK:
		for i in range(MAX_CHUNKS_PER_TICK, to_process.size()):
			_dirty_chunks[to_process[i]] = true
		to_process.resize(MAX_CHUNKS_PER_TICK)

	for chunk_pos in to_process:
		if moves_remaining <= 0:
			break

		var chunk: Chunk = _chunk_manager.get_chunk_at(chunk_pos)
		if chunk == null:
			continue

		var terrain_data: PackedByteArray = chunk.get_terrain_data()
		if terrain_data.is_empty():
			continue

		# Collect changes for this chunk as edit_tiles format
		var changes: Array = []
		var cross_chunk_changes: Array = []  # For tiles falling across chunk boundary

		# Scan bottom-to-top
		for y in range(chunk_size - 1, -1, -1):
			if moves_remaining <= 0:
				break
			for x in range(chunk_size):
				if moves_remaining <= 0:
					break

				var index: int = (y * chunk_size + x) * 2
				var tile_id: int = terrain_data[index]

				if tile_id == TileIndex.AIR or not TileIndex.get_gravity_affected(tile_id):
					continue

				var cell_id: int = terrain_data[index + 1]
				var below_y: int = y + 1

				if below_y < chunk_size:
					# Within same chunk
					var below_index: int = (below_y * chunk_size + x) * 2
					var below_id: int = terrain_data[below_index]
					if not TileIndex.is_solid(below_id) and below_id != tile_id:
						var below_cell: int = terrain_data[below_index + 1]
						# Swap in local data copy (prevents double-process)
						terrain_data[index] = below_id
						terrain_data[index + 1] = below_cell
						terrain_data[below_index] = tile_id
						terrain_data[below_index + 1] = cell_id
						# Record both changes
						changes.append({"x": x, "y": y, "tile_id": below_id, "cell_id": below_cell})
						changes.append({"x": x, "y": below_y, "tile_id": tile_id, "cell_id": cell_id})
						moves_remaining -= 1
				else:
					# Cross-chunk boundary
					var below_chunk_pos := Vector2i(chunk_pos.x, chunk_pos.y + 1)
					var below_chunk: Chunk = _chunk_manager.get_chunk_at(below_chunk_pos)
					if below_chunk == null:
						continue
					var below_tile: Array = below_chunk.get_tile_at(x, 0)
					var below_id: int = below_tile[0]
					if not TileIndex.is_solid(below_id) and below_id != tile_id:
						# Clear this tile
						terrain_data[index] = below_id
						terrain_data[index + 1] = below_tile[1]
						changes.append({"x": x, "y": y, "tile_id": below_id, "cell_id": below_tile[1]})
						# Place in chunk below
						cross_chunk_changes.append({
							"chunk_pos": below_chunk_pos,
							"changes": [{"x": x, "y": 0, "tile_id": tile_id, "cell_id": cell_id}]
						})
						_dirty_chunks[below_chunk_pos] = true
						moves_remaining -= 1

		# Apply changes directly to chunk (no light recalc)
		if not changes.is_empty():
			chunk.edit_tiles(changes, false)
			_dirty_chunks[chunk_pos] = true  # Re-queue for continued falling

		# Apply cross-chunk changes
		for cc in cross_chunk_changes:
			var below_chunk: Chunk = _chunk_manager.get_chunk_at(cc["chunk_pos"])
			if below_chunk:
				below_chunk.edit_tiles(cc["changes"], false)
