## Manages chunk lifecycle: loading, building, removal, and pooling.
##
## Monitors player position via SignalBus, queues chunk generation through
## ChunkLoader, processes built chunks each frame, and handles chunk removal
## and recycling.
class_name ChunkManager extends Node2D

# Variables
@export var world_seed: int = randi() % 1000000

@onready var _chunk_scene: PackedScene = preload("uid://dbbq2vtjx0w0y")

# Chunk Loading & Generation
var _chunk_loader: ChunkLoader
var _terrain_generator: RefCounted
var _light_baker: LightBaker

# Persistence
var _save_manager: WorldSaveManager
var _world_name: String = ""
var _dirty_chunks: Dictionary = {} # { Vector2i: true } — chunks modified since last save

# Main thread state
var _removal_queue: Array[Chunk] = []
var _player_region: Vector2i
var _player_chunk: Vector2i
var _last_sorted_player_chunk: Vector2i # Track last position queues were sorted for
var _chunks: Dictionary[Vector2i, Chunk] = {}
var _chunk_pool: Array[Chunk] = [] # Pool of reusable chunk instances
var _initial_load_complete: bool = false
var _initial_expected_count: int = -1 # Total chunks expected for initial load (-1 = not set)
var _removal_queue_set: Dictionary = {} # O(1) dedup for removal queue

# Background light baking state
var _light_bake_queue: Dictionary = {} # { Vector2i: bool } — positions waiting to be baked (value = should propagate to neighbors)
var _light_bake_results: Array[Dictionary] = [] # [{ pos, sky, block }] — completed bake results
var _light_bakes_in_progress: Dictionary = {} # { Vector2i: true } — currently baking
var _light_bake_mutex: Mutex = Mutex.new()
var _light_bake_active_tasks: int = 0
var _light_bake_shutdown: bool = false
var _light_bake_paused: bool = false


# Initialization
func _ready() -> void:
	# Initialize the terrain generator, threaded loader, and light baker
	_terrain_generator = SimplexTerrainGenerator.new(world_seed)
	_chunk_loader = ChunkLoader.new(_terrain_generator)
	_light_baker = LightBaker.new(self)

	# Pre-populate chunk pool to prevent runtime instantiation lag
	for i in range(GlobalSettings.MAX_CHUNK_POOL_SIZE):
		var chunk = _chunk_scene.instantiate()
		chunk.visible = false
		_chunk_pool.append(chunk)
	
	# Connect to player movement signals from central SignalBus
	SignalBus.connect("player_chunk_changed", _on_player_chunk_changed)


# The main process loop, handles processing the queues each frame
func _process(_delta: float) -> void:
	_process_build_queue()
	_process_removal_queue()
	_submit_light_bake_tasks()
	_process_light_bake_results()


# Processes chunk builds from the build queue
func _process_build_queue() -> void:
	var build_batch = _chunk_loader.get_built_chunks(GlobalSettings.MAX_CHUNK_BUILDS_PER_FRAME)

	var chunks_to_mark_done: Array[Vector2i] = []

	for build_data in build_batch:
		var chunk_pos: Vector2i = build_data["pos"]
		var terrain_data: PackedByteArray = build_data["terrain_data"]
		var visual_image: Image = build_data["visual_image"]

		if _chunks.has(chunk_pos):
			chunks_to_mark_done.append(chunk_pos)
			continue

		if not _is_chunk_in_valid_range(chunk_pos):
			chunks_to_mark_done.append(chunk_pos)
			continue

		var chunk: Chunk = _get_chunk()
		if chunk.get_parent() == null:
			add_child(chunk)

		chunk.generate(terrain_data, chunk_pos)
		chunk.build(visual_image)
		_chunks[chunk_pos] = chunk
		_queue_light_bake(chunk_pos, true)
		chunks_to_mark_done.append(chunk_pos)
		SignalBus.chunk_loaded.emit(chunk_pos)

	if not chunks_to_mark_done.is_empty():
		_chunk_loader.mark_chunks_as_processed(chunks_to_mark_done)

	if not _initial_load_complete and _initial_expected_count > 0 and _chunks.size() >= _initial_expected_count:
		_initial_load_complete = true
		SignalBus.world_ready.emit()


# Processes chunk removals from the removal queue
func _process_removal_queue() -> void:
	var removals_this_frame = 0
	
	while removals_this_frame < GlobalSettings.MAX_CHUNK_REMOVALS_PER_FRAME:
		if _removal_queue.is_empty():
			break
		var chunk = _removal_queue.pop_back()
		_removal_queue_set.erase(chunk)
		if is_instance_valid(chunk):
			_recycle_chunk(chunk)
		removals_this_frame += 1


# Adds a chunk position to the light bake queue.
# propagate=true means neighbors will be queued after this chunk's bake result is applied.
func _queue_light_bake(pos: Vector2i, propagate: bool = false) -> void:
	_light_bake_mutex.lock()
	if _light_bake_queue.has(pos):
		# Merge: propagate=true wins over false
		_light_bake_queue[pos] = _light_bake_queue[pos] or propagate
	else:
		_light_bake_queue[pos] = propagate
	_light_bake_mutex.unlock()


# Gathers all data needed for a light bake into a self-contained snapshot.
# Must be called on the main thread (accesses _chunks dict).
func _gather_bake_snapshot(pos: Vector2i) -> Dictionary:
	var chunk = _chunks.get(pos)
	if chunk == null:
		return {}

	var terrain_data = chunk.get_terrain_data()
	if terrain_data.is_empty():
		return {}

	# Above chunk terrain data (for sunlight entry)
	var above_terrain_data := PackedByteArray()
	var above_chunk = _chunks.get(pos + Vector2i(0, -1))
	if above_chunk != null:
		above_terrain_data = above_chunk.get_terrain_data()

	# Neighbor sky and block light data
	var neighbor_sky_data: Dictionary = {}
	var neighbor_block_data: Dictionary = {}
	for offset in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
		var neighbor = _chunks.get(pos + offset)
		if neighbor != null:
			var sky = neighbor.get_sky_light_data()
			if not sky.is_empty():
				neighbor_sky_data[offset] = sky
			var blk = neighbor.get_block_light_data()
			if not blk.is_empty():
				neighbor_block_data[offset] = blk

	return {
		"pos": pos,
		"terrain_data": terrain_data,
		"above_terrain_data": above_terrain_data,
		"neighbor_sky_data": neighbor_sky_data,
		"neighbor_block_data": neighbor_block_data,
	}


# Pops positions from the bake queue, gathers snapshots, and submits to WorkerThreadPool.
func _submit_light_bake_tasks() -> void:
	_light_bake_mutex.lock()

	if _light_bake_shutdown or _light_bake_paused or _light_bake_queue.is_empty():
		_light_bake_mutex.unlock()
		return

	# Collect positions to submit (skip those already in progress)
	var to_submit: Array = [] # [{ pos: Vector2i, propagate: bool }]
	var max_tasks = GlobalSettings.MAX_CONCURRENT_LIGHT_BAKE_TASKS

	for pos in _light_bake_queue:
		if _light_bake_active_tasks + to_submit.size() >= max_tasks:
			break
		if not _light_bakes_in_progress.has(pos):
			to_submit.append({ "pos": pos, "propagate": _light_bake_queue[pos] })

	# Remove submitted positions from queue and mark in-progress
	for entry in to_submit:
		_light_bake_queue.erase(entry["pos"])
		_light_bakes_in_progress[entry["pos"]] = true

	_light_bake_active_tasks += to_submit.size()
	_light_bake_mutex.unlock()

	# Gather snapshots on main thread, submit tasks
	for entry in to_submit:
		var snapshot = _gather_bake_snapshot(entry["pos"])
		if snapshot.is_empty():
			_light_bake_mutex.lock()
			_light_bakes_in_progress.erase(entry["pos"])
			_light_bake_active_tasks -= 1
			_light_bake_mutex.unlock()
			continue
		snapshot["propagate"] = entry["propagate"]
		WorkerThreadPool.add_task(_light_bake_task.bind(snapshot))


# Runs in WorkerThreadPool. Performs light bake and pushes result.
func _light_bake_task(snapshot: Dictionary) -> void:
	_light_bake_mutex.lock()
	if _light_bake_shutdown:
		_light_bakes_in_progress.erase(snapshot["pos"])
		_light_bake_active_tasks -= 1
		_light_bake_mutex.unlock()
		return
	_light_bake_mutex.unlock()

	var result = _light_baker.bake_from_data(
		snapshot["terrain_data"],
		snapshot["above_terrain_data"],
		snapshot["neighbor_sky_data"],
		snapshot["neighbor_block_data"]
	)

	_light_bake_mutex.lock()
	_light_bakes_in_progress.erase(snapshot["pos"])
	_light_bake_active_tasks -= 1

	if not _light_bake_shutdown:
		_light_bake_results.append({
			"pos": snapshot["pos"],
			"sky": result["sky"],
			"block": result["block"],
			"propagate": snapshot["propagate"],
		})

		# Apply backpressure if results are piling up
		if _light_bake_results.size() >= GlobalSettings.MAX_LIGHT_BAKE_QUEUE_SIZE:
			_light_bake_paused = true

	_light_bake_mutex.unlock()


# Applies completed bake results to chunks, budget-limited per frame.
func _process_light_bake_results() -> void:
	_light_bake_mutex.lock()
	if _light_bake_results.is_empty():
		_light_bake_mutex.unlock()
		return

	var batch_size = mini(_light_bake_results.size(), GlobalSettings.MAX_LIGHT_BAKE_RESULTS_PER_FRAME)
	var batch: Array[Dictionary] = []
	for i in range(batch_size):
		batch.append(_light_bake_results.pop_front())

	# Relieve backpressure
	if _light_bake_paused and _light_bake_results.size() < GlobalSettings.MAX_LIGHT_BAKE_QUEUE_SIZE / 2:
		_light_bake_paused = false

	_light_bake_mutex.unlock()

	for entry in batch:
		var chunk = _chunks.get(entry["pos"])
		if chunk != null:
			chunk.update_light_data({ "sky": entry["sky"], "block": entry["block"] })
			# After applying, queue neighbors for re-bake with updated border data
			if entry["propagate"]:
				for offset in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
					var neighbor_pos = entry["pos"] + offset
					if _chunks.has(neighbor_pos):
						_queue_light_bake(neighbor_pos, false)


## Converts a chunk position to its containing region position
func _get_chunk_region(chunk_pos: Vector2i) -> Vector2i:
	return Vector2i(
		floori(float(chunk_pos.x) / GlobalSettings.REGION_SIZE),
		floori(float(chunk_pos.y) / GlobalSettings.REGION_SIZE)
	)


# Checks if a chunk is within the valid range for loading based on player position
func _is_chunk_in_valid_range(chunk_pos: Vector2i) -> bool:
	# Calculate the chunk's region
	var chunk_region = _get_chunk_region(chunk_pos)
	
	# Calculate removal bounds in REGION coordinates
	var removal_radius = GlobalSettings.LOD_RADIUS + GlobalSettings.REMOVAL_BUFFER
	var min_region = _player_region - Vector2i(removal_radius, removal_radius)
	var max_region = _player_region + Vector2i(removal_radius, removal_radius)
	
	# Check if chunk's region is within bounds
	return chunk_region.x >= min_region.x and chunk_region.x <= max_region.x and chunk_region.y >= min_region.y and chunk_region.y <= max_region.y


# Marks chunks for removal based on player region and removal radius
func _mark_chunks_for_removal(center_region: Vector2i, removal_radius: int) -> void:
	# Check all loaded chunks using abs-based bounds check
	var chunks_to_remove: Array[Vector2i] = []
	
	for chunk_pos in _chunks.keys():
		var chunk_region = _get_chunk_region(chunk_pos)
		
		# If chunk's region is outside removal bounds, mark for removal
		if absi(chunk_region.x - center_region.x) > removal_radius or absi(chunk_region.y - center_region.y) > removal_radius:
			chunks_to_remove.append(chunk_pos)
	
	# Remove marked chunks (separate loop to avoid modifying dict while iterating)
	if not chunks_to_remove.is_empty():
		_light_bake_mutex.lock()
		for chunk_pos in chunks_to_remove:
			_light_bake_queue.erase(chunk_pos)
		_light_bake_mutex.unlock()

	for chunk_pos in chunks_to_remove:
		var chunk = _chunks.get(chunk_pos)
		if chunk != null:
			# Auto-save dirty chunk before removal
			if _save_manager and _dirty_chunks.has(chunk_pos):
				_save_dirty_chunk(chunk_pos, chunk)
			_chunks.erase(chunk_pos)
			if not _removal_queue_set.has(chunk):
				_removal_queue.append(chunk)
				_removal_queue_set[chunk] = true
			SignalBus.chunk_unloaded.emit(chunk_pos)


# Queues new chunks for generation based on player region and generation radius
func _queue_chunks_for_generation(center_region: Vector2i, gen_radius: int) -> void:
	var chunks_to_queue: Array[Vector2i] = []

	# Record initial expected count on first call
	if not _initial_load_complete and _initial_expected_count < 0:
		var gen_diameter = 2 * gen_radius + 1
		var region_chunks = GlobalSettings.REGION_SIZE * GlobalSettings.REGION_SIZE
		_initial_expected_count = gen_diameter * gen_diameter * region_chunks

	# Iterate over all regions in generation radius
	for region_x in range(center_region.x - gen_radius, center_region.x + gen_radius + 1):
		for region_y in range(center_region.y - gen_radius, center_region.y + gen_radius + 1):
			# Calculate chunk bounds for this region
			var chunk_start_x = region_x * GlobalSettings.REGION_SIZE
			var chunk_start_y = region_y * GlobalSettings.REGION_SIZE

			# Iterate over all chunks in this region
			for cx in range(chunk_start_x, chunk_start_x + GlobalSettings.REGION_SIZE):
				for cy in range(chunk_start_y, chunk_start_y + GlobalSettings.REGION_SIZE):
					var chunk_pos = Vector2i(cx, cy)

					# Skip if already loaded
					if _chunks.has(chunk_pos):
						continue

					# Load from saved data if available (bypass worker thread)
					if has_saved_chunk(chunk_pos):
						var saved_data = load_chunk_data(chunk_pos)
						if not saved_data.is_empty():
							var visual_image = _chunk_loader.generate_visual_image(saved_data)
							var chunk: Chunk = _get_chunk()
							if chunk.get_parent() == null:
								add_child(chunk)
							chunk.generate(saved_data, chunk_pos)
							chunk.build(visual_image)
							_chunks[chunk_pos] = chunk
							_queue_light_bake(chunk_pos, true)
							SignalBus.chunk_loaded.emit(chunk_pos)
							continue

					chunks_to_queue.append(chunk_pos)

	# Send remaining chunks to loader for generation
	_chunk_loader.add_chunks_to_generation(chunks_to_queue, _player_chunk)

	# Update tracking for smart resorting
	_last_sorted_player_chunk = _player_chunk


# Resorts the generation queue based on current player position
func _resort_queues() -> void:
	# Skip if player hasn't moved significantly since last sort
	var player_chunk = _player_chunk
	var distance_moved = (player_chunk - _last_sorted_player_chunk).length_squared()
	if distance_moved < 4: # Only resort if moved more than ~2 chunks
		return
	
	_chunk_loader.resort_queues(player_chunk)
	_last_sorted_player_chunk = player_chunk


# Handler: update internal state when player chunk changes (driven by SignalBus)
func _on_player_chunk_changed(new_player_chunk: Vector2i) -> void:
	if new_player_chunk == _player_chunk:
		return

	# Update player chunk and flag update
	_player_chunk = new_player_chunk

	# Determine region and trigger appropriate updates
	var new_player_region = _get_chunk_region(_player_chunk)
	if new_player_region != _player_region:
		_player_region = new_player_region
		_on_player_region_changed(_player_region)
	else:
		# Even if region didn't change, re-sort queues for better priority
		_resort_queues()


# Handler: update chunk loading when player region changes
func _on_player_region_changed(new_player_region: Vector2i) -> void:
	# Calculate bounds in REGION coordinates
	var gen_radius = GlobalSettings.LOD_RADIUS
	var removal_radius = GlobalSettings.LOD_RADIUS + GlobalSettings.REMOVAL_BUFFER
	
	# --- STEP 1: Mark chunks for removal ---
	_mark_chunks_for_removal(new_player_region, removal_radius)
	
	# --- STEP 2: Queue new chunks for generation ---
	_queue_chunks_for_generation(new_player_region, gen_radius)


# Retrieves a chunk from the pool or creates a new one if pool is empty
func _get_chunk() -> Chunk:
	if _chunk_pool.is_empty():
		return _chunk_scene.instantiate()
	else:
		var chunk = _chunk_pool.pop_back()
		return chunk


# Recycles a chunk back into the pool or frees it if pool is full
func _recycle_chunk(chunk: Chunk) -> void:
	if is_instance_valid(chunk):
		chunk.reset()
		if _chunk_pool.size() < GlobalSettings.MAX_CHUNK_POOL_SIZE:
			_chunk_pool.append(chunk)
		else:
			chunk.queue_free() # Free excess chunks


## Returns the chunk at the given chunk position, or null if not loaded.
func get_chunk_at(chunk_pos: Vector2i) -> Chunk:
	return _chunks.get(chunk_pos, null)


## Returns the terrain generator used by this ChunkManager.
func get_terrain_generator() -> RefCounted:
	return _terrain_generator


## Converts a world position to chunk coordinates.
func world_to_chunk_pos(world_pos: Vector2) -> Vector2i:
	return Vector2i(int(floor(world_pos.x / GlobalSettings.CHUNK_SIZE)), int(floor(world_pos.y / GlobalSettings.CHUNK_SIZE)))


# Helper function for positive modulo (handles negative coordinates)
func _positive_fmod(value: float, divisor: float) -> float:
	var result = fmod(value, divisor)
	if result < 0:
		result += divisor
	return result


## Converts a world position to tile coordinates within a chunk (0-31).
func world_to_tile_pos(world_pos: Vector2) -> Vector2i:
	var fx = _positive_fmod(world_pos.x, GlobalSettings.CHUNK_SIZE)
	var fy = _positive_fmod(world_pos.y, GlobalSettings.CHUNK_SIZE)
	return Vector2i(int(floor(fx)), int(floor(fy)))


## Returns true if the tile at the given world position is solid.
func is_solid_at_world_pos(world_pos: Vector2) -> bool:
	var chunk_pos = world_to_chunk_pos(world_pos)
	var chunk = get_chunk_at(chunk_pos)
	if chunk == null:
		return false # Treat unloaded chunks as non-solid
	var tile_pos = world_to_tile_pos(world_pos)
	return TileIndex.is_solid(chunk.get_tile_id_at(tile_pos.x, tile_pos.y))


## Returns just the tile_id at the given world position (0 if unloaded).
func get_tile_id_at_world_pos(world_pos: Vector2) -> int:
	var chunk_pos = world_to_chunk_pos(world_pos)
	var chunk = get_chunk_at(chunk_pos)
	if chunk == null:
		return 0
	var tile_pos = world_to_tile_pos(world_pos)
	return chunk.get_tile_id_at(tile_pos.x, tile_pos.y)


## Returns [tile_id, cell_id] at the given world position.
func get_tile_at_world_pos(world_pos: Vector2) -> Array:
	var chunk_pos = world_to_chunk_pos(world_pos)
	var chunk = get_chunk_at(chunk_pos)
	if chunk == null:
		return [0, 0] # Return air if chunk not loaded
	var tile_pos = world_to_tile_pos(world_pos)
	return chunk.get_tile_at(tile_pos.x, tile_pos.y)


## Returns tile data for multiple world positions, batched by chunk.
## Result dictionary: { Vector2(world_pos): [tile_id, cell_id] }
func get_tiles_at_world_positions(world_positions: Array) -> Dictionary:
	var result = {}
	var batched_requests = {} # { chunk_pos: [ { "world_pos": Vector2, "tile_pos": Vector2i } ] }
	
	# Group requests by chunk
	for world_pos in world_positions:
		var chunk_pos = world_to_chunk_pos(world_pos)
		if not batched_requests.has(chunk_pos):
			batched_requests[chunk_pos] = []
		
		var tile_pos = world_to_tile_pos(world_pos)
		batched_requests[chunk_pos].append({
			"world_pos": world_pos,
			"tile_pos": tile_pos
		})
	
	# Process batches
	for chunk_pos in batched_requests.keys():
		var chunk = get_chunk_at(chunk_pos)
		var requests = batched_requests[chunk_pos]
		
		if chunk == null:
			# If chunk isn't loaded, return 0 (air) for all positions
			for req in requests:
				result[req["world_pos"]] = [0, 0]
			continue
			
		var tile_positions: Array[Vector2i] = []
		for req in requests:
			tile_positions.append(req["tile_pos"])
		var tiles = chunk.get_tiles(tile_positions)
		for i in range(requests.size()):
			result[requests[i]["world_pos"]] = tiles[i]
			
	return result


## Applies tile changes at multiple world positions, batched by chunk.
## changes: Array of Dictionary { "pos": Vector2, "tile_id": int, "cell_id": int }
func set_tiles_at_world_positions(changes: Array) -> void:
	var batched_changes = {} # { chunk_pos: [ { "x", "y", "tile_id", "cell_id", "idx" } ] }

	# Group changes by chunk (single pass)
	for i in range(changes.size()):
		var change = changes[i]
		var world_pos = change["pos"]
		var chunk_pos = world_to_chunk_pos(world_pos)

		if not batched_changes.has(chunk_pos):
			batched_changes[chunk_pos] = []

		var tile_pos = world_to_tile_pos(world_pos)

		batched_changes[chunk_pos].append({
			"x": tile_pos.x,
			"y": tile_pos.y,
			"tile_id": change["tile_id"],
			"cell_id": change["cell_id"],
			"idx": i
		})

	# Read old tile IDs and apply edits per chunk (2 mutex acquires per chunk)
	var old_tile_ids: Array = []
	old_tile_ids.resize(changes.size())

	for chunk_pos in batched_changes.keys():
		var chunk = get_chunk_at(chunk_pos)
		var chunk_changes = batched_changes[chunk_pos]

		if chunk != null:
			# Batch-read old tile IDs (single mutex acquire)
			var tile_positions: Array[Vector2i] = []
			for cc in chunk_changes:
				tile_positions.append(Vector2i(cc["x"], cc["y"]))
			var old_tiles = chunk.get_tiles(tile_positions)
			for j in range(chunk_changes.size()):
				old_tile_ids[chunk_changes[j]["idx"]] = old_tiles[j][0]

			# Apply edits (single mutex acquire)
			chunk.edit_tiles(chunk_changes)
			_dirty_chunks[chunk_pos] = true
		else:
			for cc in chunk_changes:
				old_tile_ids[cc["idx"]] = 0

	# Rebake lighting for edited chunks and their neighbors
	_rebake_lighting_for_chunks(batched_changes.keys())

	# Emit tile_changed for each change (after data is committed)
	for i in range(changes.size()):
		var change = changes[i]
		SignalBus.tile_changed.emit(change["pos"], old_tile_ids[i], change["tile_id"])


## Returns all loaded chunk positions.
func get_loaded_chunk_positions() -> Array:
	return _chunks.keys()


## Queues lighting rebake for the given chunk positions (neighbors queued after results applied).
func _rebake_lighting_for_chunks(chunk_positions) -> void:
	for chunk_pos in chunk_positions:
		_queue_light_bake(chunk_pos, true)


## Returns a snapshot of debug info for the overlay.
func get_debug_info() -> Dictionary:
	var loader_info = _chunk_loader.get_debug_info()
	var removal_positions: Array[Vector2i] = []
	for chunk in _removal_queue:
		if is_instance_valid(chunk):
			var chunk_size = GlobalSettings.CHUNK_SIZE
			removal_positions.append(Vector2i(
				int(chunk.position.x / chunk_size),
				int(chunk.position.y / chunk_size)
			))

	return {
		"loaded_chunks": _chunks.keys(),
		"loaded_count": _chunks.size(),
		"removal_positions": removal_positions,
		"removal_queue_size": _removal_queue.size(),
		"player_chunk": _player_chunk,
		"player_region": _player_region,
		"generation_queue": loader_info["generation_queue"],
		"generation_queue_size": loader_info["generation_queue_size"],
		"build_queue_size": loader_info["build_queue_size"],
		"in_progress": loader_info["in_progress"],
		"in_progress_size": loader_info["in_progress_size"],
		"active_tasks": loader_info.get("active_tasks", 0),
	}


# ─── Persistence ─────────────────────────────────────────────────────


## Configures the save manager and world name for persistence.
func setup_persistence(save_manager: WorldSaveManager, world_name: String) -> void:
	_save_manager = save_manager
	_world_name = world_name


## Saves all dirty chunks and world metadata.
func save_world() -> void:
	if not _save_manager or _world_name.is_empty():
		return

	SignalBus.world_saving.emit()

	for chunk_pos in _dirty_chunks.keys():
		var chunk = _chunks.get(chunk_pos)
		if chunk:
			_save_dirty_chunk(chunk_pos, chunk)
	_dirty_chunks.clear()

	_save_manager.save_world_meta(_world_name, world_seed, "simplex", {})

	SignalBus.world_saved.emit()


## Tries to load saved terrain data for a chunk position.
## Returns the saved PackedByteArray, or an empty one if no save exists.
func load_chunk_data(chunk_pos: Vector2i) -> PackedByteArray:
	if not _save_manager or _world_name.is_empty():
		return PackedByteArray()
	return _save_manager.load_chunk(_world_name, chunk_pos)


## Returns true if a saved chunk exists at the given position.
func has_saved_chunk(chunk_pos: Vector2i) -> bool:
	if not _save_manager or _world_name.is_empty():
		return false
	return _save_manager.has_saved_chunk(_world_name, chunk_pos)


# Saves a single dirty chunk to disk.
func _save_dirty_chunk(chunk_pos: Vector2i, chunk: Chunk) -> void:
	var tile_data = chunk.get_terrain_data()
	if not tile_data.is_empty():
		_save_manager.save_chunk(_world_name, chunk_pos, tile_data)
	_dirty_chunks.erase(chunk_pos)


# Cleanup on exit
func _exit_tree() -> void:
	# Save dirty chunks before shutdown
	save_world()

	# Shut down light bake tasks
	_light_bake_mutex.lock()
	_light_bake_shutdown = true
	_light_bake_queue.clear()
	_light_bake_results.clear()
	_light_bake_mutex.unlock()

	# Wait for active light bake tasks to finish
	var timeout_ms := 2000
	var elapsed_ms := 0
	while true:
		_light_bake_mutex.lock()
		var remaining = _light_bake_active_tasks
		_light_bake_mutex.unlock()
		if remaining == 0:
			break
		if elapsed_ms >= timeout_ms:
			push_warning("ChunkManager: Timed out waiting for %d light bake tasks to finish" % remaining)
			break
		OS.delay_msec(1)
		elapsed_ms += 1

	if _chunk_loader:
		_chunk_loader.stop()
