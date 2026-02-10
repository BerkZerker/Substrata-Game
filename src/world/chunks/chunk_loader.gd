class_name ChunkLoader extends RefCounted

# Thread-safe state (protected by _mutex)
var _generation_queue: Array[Vector2i] = [] # Chunk positions waiting to be generated (sorted by priority)
var _generation_queue_set: Dictionary = {} # O(1) lookup for duplicate checking in generation queue
var _build_queue: Array[Dictionary] = [] # [{pos: Vector2i, terrain_data: Array}] ready to build
var _chunks_in_progress: Dictionary = {} # Chunk positions currently being generated (prevents duplicates)
var _player_chunk_for_priority: Vector2i # Cached player chunk for priority sorting in worker thread
var _thread_alive: bool = true
var _generation_paused: bool = false # Backpressure flag when build queue is full

# Thread and synchronization primitives
var _terrain_generator: TerrainGenerator
var _thread: Thread
var _mutex: Mutex
var _semaphore: Semaphore


# Initialization
func _init(world_seed: int) -> void:
	_terrain_generator = TerrainGenerator.new(world_seed)
	
	_mutex = Mutex.new()
	_semaphore = Semaphore.new()
	_thread = Thread.new()
	_thread.start(_worker_thread_loop)


# Adds multiple chunks to the generation queue and resorts if necessary
func add_chunks_to_generation(new_chunks: Array[Vector2i], player_chunk: Vector2i) -> void:
	if new_chunks.is_empty():
		return
		
	_mutex.lock()
	
	# Use O(1) set lookup instead of iterating the array
	var unique_chunks: Array[Vector2i] = []
	for pos in new_chunks:
		if not _generation_queue_set.has(pos) and not _chunks_in_progress.has(pos):
			unique_chunks.append(pos)
			_generation_queue_set[pos] = true
	
	# Merge new chunks with existing queue
	if not unique_chunks.is_empty():
		_generation_queue = unique_chunks + _generation_queue
		_player_chunk_for_priority = player_chunk
		
		# Sort entire queue by distance
		_generation_queue.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
			var dist_a = (a - _player_chunk_for_priority).length_squared()
			var dist_b = (b - _player_chunk_for_priority).length_squared()
			return dist_a < dist_b
		)
	
	var has_work = not _generation_queue.is_empty() and not _generation_paused
	_mutex.unlock()
	
	# Wake worker thread if there's work
	if has_work:
		_semaphore.post()


# Retrieves a batch of built chunks from the queue
func get_built_chunks(limit: int) -> Array[Dictionary]:
	_mutex.lock()
	var batch_size = mini(_build_queue.size(), limit)
	var build_batch: Array[Dictionary] = []
	for i in range(batch_size):
		build_batch.append(_build_queue.pop_front())
	
	# Check if we should resume generation (backpressure relief)
	var should_resume = _generation_paused and _build_queue.size() < GlobalSettings.MAX_BUILD_QUEUE_SIZE / 2.0
	if should_resume:
		_generation_paused = false
	_mutex.unlock()
	
	# Wake worker thread if backpressure was relieved
	if should_resume:
		_semaphore.post()
		
	return build_batch


# Removes chunks from the "in progress" tracking
func mark_chunks_as_processed(chunk_positions: Array[Vector2i]) -> void:
	if chunk_positions.is_empty():
		return
		
	_mutex.lock()
	for pos in chunk_positions:
		_chunks_in_progress.erase(pos)
	_mutex.unlock()


# Resorts both generation and build queues based on new player position
func resort_queues(player_chunk: Vector2i) -> void:
	_mutex.lock()
	_player_chunk_for_priority = player_chunk
	
	if _generation_queue.size() >= 2:
		_generation_queue.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
			var dist_a = (a - player_chunk).length_squared()
			var dist_b = (b - player_chunk).length_squared()
			return dist_a < dist_b
		)
		
	if _build_queue.size() >= 2:
		# Sort build queue by distance to current player position
		_build_queue.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			var dist_a = (a["pos"] - player_chunk).length_squared()
			var dist_b = (b["pos"] - player_chunk).length_squared()
			return dist_a < dist_b
		)
	_mutex.unlock()


# Returns a thread-safe snapshot of queue state for debug visualization
func get_debug_info() -> Dictionary:
	_mutex.lock()
	var info = {
		"generation_queue": _generation_queue.duplicate(),
		"generation_queue_size": _generation_queue.size(),
		"build_queue_size": _build_queue.size(),
		"in_progress": _chunks_in_progress.keys(),
		"in_progress_size": _chunks_in_progress.size(),
	}
	_mutex.unlock()
	return info


# Worker thread loop for chunk generation
func _worker_thread_loop() -> void:
	while true:
		# Wait for work signal
		_semaphore.wait()
		
		# Check if we should exit or pause
		_mutex.lock()
		if not _thread_alive:
			_mutex.unlock()
			break
		
		# Skip processing if backpressure is active
		if _generation_paused:
			_mutex.unlock()
			continue
		_mutex.unlock()
		
		# Process one chunk at a time for responsiveness
		_process_one_chunk()


# Processes a single chunk from the generation queue
func _process_one_chunk() -> void:
	_mutex.lock()
	
	# Check for empty queue
	if _generation_queue.is_empty():
		_mutex.unlock()
		return
	
	# Find the first chunk that isn't already in progress
	var chunk_pos: Vector2i = Vector2i.ZERO
	var found_valid_chunk = false
	
	while not _generation_queue.is_empty():
		chunk_pos = _generation_queue.pop_front()
		_generation_queue_set.erase(chunk_pos) # Keep set in sync
		
		if not _chunks_in_progress.has(chunk_pos):
			found_valid_chunk = true
			break
	
	if not found_valid_chunk:
		_mutex.unlock()
		return
	
	# Mark as in progress
	_chunks_in_progress[chunk_pos] = true
	var has_more_work = not _generation_queue.is_empty()
	
	_mutex.unlock()
	
	# Generate terrain data (thread-safe operation, done outside lock)
	var terrain_data = _terrain_generator.generate_chunk(chunk_pos)
	
	# Generate visual image data in the thread to save main thread time
	var visual_image = _generate_visual_image(terrain_data)
	
	# Add to build queue and check backpressure
	_mutex.lock()
	_build_queue.append({
		"pos": chunk_pos,
		"terrain_data": terrain_data,
		"visual_image": visual_image
	})
	
	# Apply backpressure if build queue is too large
	if _build_queue.size() >= GlobalSettings.MAX_BUILD_QUEUE_SIZE:
		_generation_paused = true
		has_more_work = false # Don't signal for more work
	
	_mutex.unlock()
	
	# Signal for more work only if there's actually more to do
	if has_more_work:
		_semaphore.post()


# Helper to generate the chunk image in the worker thread
func _generate_visual_image(terrain_data: PackedByteArray) -> Image:
	var chunk_size = GlobalSettings.CHUNK_SIZE
	var image = Image.create(chunk_size, chunk_size, false, Image.FORMAT_RGBA8)
	
	# Pre-calculate factors to avoid division in loop
	var inv_255 = 1.0 / 255.0
	
	for x in range(chunk_size):
		for y in range(chunk_size):
			# Original logic: _terrain_data[-y - 1][x]
			# -y - 1 means we start from the last row.
			# If y=0, row is -1 (index SIZE-1).
			# If y=SIZE-1, row is -SIZE (index 0).
			var effective_y = (chunk_size - 1) - y
			var index = (effective_y * chunk_size + x) * 2
			
			var tile_id = float(terrain_data[index])
			var cell_id = float(terrain_data[index + 1])
			
			# Set pixel (x, y)
			image.set_pixel(x, y, Color(tile_id * inv_255, cell_id * inv_255, 0, 0))
			
	return image


# Stops the thread and cleans up
func stop() -> void:
	_mutex.lock()
	_thread_alive = false
	_generation_paused = false
	_generation_queue.clear()
	_generation_queue_set.clear()
	_build_queue.clear()
	_chunks_in_progress.clear()
	_mutex.unlock()
	
	# Wake thread so it can exit
	_semaphore.post()
	_thread.wait_to_finish()
