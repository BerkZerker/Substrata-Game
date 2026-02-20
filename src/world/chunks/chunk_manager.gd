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

# Main thread state
var _removal_queue: Array[Chunk] = []
var _player_region: Vector2i
var _player_chunk: Vector2i
var _last_sorted_player_chunk: Vector2i # Track last position queues were sorted for
var _chunks: Dictionary[Vector2i, Chunk] = {}
var _chunk_pool: Array[Chunk] = [] # Pool of reusable chunk instances


# Initialization
func _ready() -> void:
	# Initialize the terrain generator and threaded loader
	var terrain_generator = SimplexTerrainGenerator.new(world_seed)
	_chunk_loader = ChunkLoader.new(terrain_generator)

	# Pre-populate chunk pool to prevent runtime instantiation lag
	for i in range(GlobalSettings.MAX_CHUNK_POOL_SIZE):
		var chunk = _chunk_scene.instantiate()
		chunk.visible = false
		_chunk_pool.append(chunk)
	
	# Connect to player movement signals from central SignalBus
	SignalBus.connect("player_chunk_changed", _on_player_chunk_changed)


# The main process loop, handles processing the queues each frame
func _process(_delta: float) -> void:
	# Process chunks from build queue (main thread work)
	_process_build_queue()
	
	# Process chunk removals
	_process_removal_queue()


# Processes chunk builds from the build queue
func _process_build_queue() -> void:
	# Get batch from loader
	var build_batch = _chunk_loader.get_built_chunks(GlobalSettings.MAX_CHUNK_BUILDS_PER_FRAME)
	
	var chunks_to_mark_done: Array[Vector2i] = []
	
	for build_data in build_batch:
		var chunk_pos: Vector2i = build_data["pos"]
		var terrain_data: PackedByteArray = build_data["terrain_data"]
		var visual_image: Image = build_data["visual_image"]
		
		# Skip if chunk already exists (might have been built while in queue)
		if _chunks.has(chunk_pos):
			chunks_to_mark_done.append(chunk_pos)
			continue
		
		# Skip if chunk is out of valid range (player moved away)
		if not _is_chunk_in_valid_range(chunk_pos):
			chunks_to_mark_done.append(chunk_pos)
			continue
		
		# Instantiate and build the chunk (using pool)
		var chunk: Chunk = _get_chunk()
		if chunk.get_parent() == null:
			add_child(chunk)
		
		chunk.generate(terrain_data, chunk_pos)
		chunk.build(visual_image)
		_chunks[chunk_pos] = chunk
		chunks_to_mark_done.append(chunk_pos)
	
	# Notify loader that these chunks are finished (so it can clean up tracking)
	if not chunks_to_mark_done.is_empty():
		_chunk_loader.mark_chunks_as_processed(chunks_to_mark_done)


# Processes chunk removals from the removal queue
func _process_removal_queue() -> void:
	var removals_this_frame = 0
	
	while removals_this_frame < GlobalSettings.MAX_CHUNK_REMOVALS_PER_FRAME:
		if _removal_queue.is_empty():
			break
		var chunk = _removal_queue.pop_back()
		if is_instance_valid(chunk):
			_recycle_chunk(chunk)
		removals_this_frame += 1


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
	for chunk_pos in chunks_to_remove:
		var chunk = _chunks.get(chunk_pos)
		if chunk != null:
			_chunks.erase(chunk_pos)
			if not _removal_queue.has(chunk):
				_removal_queue.append(chunk)


# Queues new chunks for generation based on player region and generation radius
func _queue_chunks_for_generation(center_region: Vector2i, gen_radius: int) -> void:
	# Collect all chunk positions that need to be generated
	var chunks_to_queue: Array[Vector2i] = []
	
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
					
					chunks_to_queue.append(chunk_pos)
	
	# Send to loader
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
	return chunk.get_tile_id_at(tile_pos.x, tile_pos.y) > 0 # Air is 0, anything else is solid


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
	var batched_changes = {} # { chunk_pos: [ { "x": int, "y": int, "tile_id": int, "cell_id": int } ] }
	
	# Group changes by chunk
	for change in changes:
		var world_pos = change["pos"]
		var chunk_pos = world_to_chunk_pos(world_pos)
		
		if not batched_changes.has(chunk_pos):
			batched_changes[chunk_pos] = []
			
		var tile_pos = world_to_tile_pos(world_pos)
		
		batched_changes[chunk_pos].append({
			"x": tile_pos.x,
			"y": tile_pos.y,
			"tile_id": change["tile_id"],
			"cell_id": change["cell_id"]
		})
	
	# Dispatch batches to chunks
	for chunk_pos in batched_changes.keys():
		var chunk = get_chunk_at(chunk_pos)
		if chunk != null:
			chunk.edit_tiles(batched_changes[chunk_pos])


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


# Cleanup on exit
func _exit_tree() -> void:
	if _chunk_loader:
		_chunk_loader.stop()
