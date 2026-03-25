## Background chunk generation scheduler using Godot's WorkerThreadPool.
##
## Manages a queue of chunk positions waiting to be generated, submits them as
## parallel tasks to the WorkerThreadPool, and collects results in a build queue
## for the main thread to process. Implements backpressure to prevent the build
## queue from growing unbounded.
class_name ChunkLoader extends RefCounted

# Thread-safe state (protected by _mutex)
var _generation_queue: Array[Vector2i] = [] # Chunk positions waiting to be generated (sorted by priority)
var _generation_queue_set: Dictionary = {} # O(1) lookup for duplicate checking in generation queue
var _build_queue: Array[Dictionary] = [] # [{pos, terrain_data, visual_image}] ready to build
var _chunks_in_progress: Dictionary = {} # Chunk positions currently being generated (prevents duplicates)
var _player_chunk_for_priority: Vector2i # Cached player chunk for priority sorting
var _shutdown_requested: bool = false
var _generation_paused: bool = false # Backpressure flag when build queue is full
var _active_task_count: int = 0 # Number of tasks currently running in WorkerThreadPool

# Synchronization and generation
var _terrain_generator: BaseTerrainGenerator
var _mutex: Mutex


## Initializes the chunk loader with a terrain generator instance.
func _init(terrain_generator: BaseTerrainGenerator) -> void:
	_terrain_generator = terrain_generator
	_mutex = Mutex.new()


## Adds multiple chunks to the generation queue and submits tasks for processing.
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

		# Sort entire queue by distance to player
		_generation_queue.sort_custom(func(a: Vector2i, b: Vector2i) -> bool:
			var dist_a = (a - _player_chunk_for_priority).length_squared()
			var dist_b = (b - _player_chunk_for_priority).length_squared()
			return dist_a < dist_b
		)

	_mutex.unlock()

	# Submit tasks for any available work
	_submit_tasks()


## Retrieves a batch of built chunks from the queue.
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

	# Submit tasks if backpressure was relieved
	if should_resume:
		_submit_tasks()

	return build_batch


## Removes chunks from the "in progress" tracking.
func mark_chunks_as_processed(chunk_positions: Array[Vector2i]) -> void:
	if chunk_positions.is_empty():
		return

	_mutex.lock()
	for pos in chunk_positions:
		_chunks_in_progress.erase(pos)
	_mutex.unlock()


## Resorts both generation and build queues based on new player position.
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
		_build_queue.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
			var dist_a = (a["pos"] - player_chunk).length_squared()
			var dist_b = (b["pos"] - player_chunk).length_squared()
			return dist_a < dist_b
		)
	_mutex.unlock()


## Returns a thread-safe snapshot of queue state for debug visualization.
func get_debug_info() -> Dictionary:
	_mutex.lock()
	var info = {
		"generation_queue": _generation_queue.duplicate(),
		"generation_queue_size": _generation_queue.size(),
		"build_queue_size": _build_queue.size(),
		"in_progress": _chunks_in_progress.keys(),
		"in_progress_size": _chunks_in_progress.size(),
		"active_tasks": _active_task_count,
	}
	_mutex.unlock()
	return info


# Submits chunk generation tasks to the WorkerThreadPool up to the concurrency limit.
# Collects work items under mutex, then submits tasks outside the lock.
func _submit_tasks() -> void:
	_mutex.lock()

	if _shutdown_requested or _generation_paused:
		_mutex.unlock()
		return

	var max_tasks = GlobalSettings.MAX_CONCURRENT_GENERATION_TASKS
	var tasks_to_submit: Array[Vector2i] = []

	while _active_task_count + tasks_to_submit.size() < max_tasks and not _generation_queue.is_empty():
		var chunk_pos: Vector2i = Vector2i.ZERO
		var found = false

		while not _generation_queue.is_empty():
			chunk_pos = _generation_queue.pop_front()
			_generation_queue_set.erase(chunk_pos)

			if not _chunks_in_progress.has(chunk_pos):
				found = true
				break

		if not found:
			break

		_chunks_in_progress[chunk_pos] = true
		tasks_to_submit.append(chunk_pos)

	_active_task_count += tasks_to_submit.size()
	_mutex.unlock()

	# Submit tasks outside the lock
	for pos in tasks_to_submit:
		WorkerThreadPool.add_task(_generate_chunk_task.bind(pos))


# Generates terrain and visual data for a single chunk. Runs in a WorkerThreadPool thread.
func _generate_chunk_task(chunk_pos: Vector2i) -> void:
	# Check shutdown under mutex
	_mutex.lock()
	if _shutdown_requested:
		_active_task_count -= 1
		_chunks_in_progress.erase(chunk_pos)
		_mutex.unlock()
		return
	_mutex.unlock()

	# Generate terrain data and visual image (thread-safe, no mutex needed)
	var terrain_data = _terrain_generator.generate_chunk(chunk_pos)
	var visual_image = _generate_visual_image(terrain_data)

	# Push result to build queue
	_mutex.lock()
	_active_task_count -= 1

	if not _shutdown_requested:
		_build_queue.append({
			"pos": chunk_pos,
			"terrain_data": terrain_data,
			"visual_image": visual_image
		})

		# Apply backpressure if build queue is too large
		if _build_queue.size() >= GlobalSettings.MAX_BUILD_QUEUE_SIZE:
			_generation_paused = true

	var should_chain = not _shutdown_requested and not _generation_paused and not _generation_queue.is_empty()
	_mutex.unlock()

	# Chain more work if available
	if should_chain:
		_submit_tasks()


# Generates the chunk image from terrain data in the worker thread.
func _generate_visual_image(terrain_data: PackedByteArray) -> Image:
	var chunk_size = GlobalSettings.CHUNK_SIZE
	var image = Image.create(chunk_size, chunk_size, false, Image.FORMAT_RGBA8)

	var inv_255 = 1.0 / 255.0

	for x in range(chunk_size):
		for y in range(chunk_size):
			# Y-inversion: data row 0 maps to image row (SIZE-1)
			var effective_y = (chunk_size - 1) - y
			var index = (effective_y * chunk_size + x) * 2

			var tile_id = float(terrain_data[index])
			var cell_id = float(terrain_data[index + 1])

			image.set_pixel(x, y, Color(tile_id * inv_255, cell_id * inv_255, 0, 0))

	return image


## Generates a visual image from terrain data. Can be called from any thread.
func generate_visual_image(terrain_data: PackedByteArray) -> Image:
	return _generate_visual_image(terrain_data)


## Stops all generation and cleans up. Blocks until all active tasks finish.
func stop() -> void:
	_mutex.lock()
	_shutdown_requested = true
	_generation_paused = false
	_generation_queue.clear()
	_generation_queue_set.clear()
	_build_queue.clear()
	_mutex.unlock()

	# Wait for all active tasks to finish (with timeout)
	var timeout_ms := 2000
	var elapsed_ms := 0
	while true:
		_mutex.lock()
		var remaining = _active_task_count
		_mutex.unlock()
		if remaining == 0:
			break
		if elapsed_ms >= timeout_ms:
			push_warning("ChunkLoader: Timed out waiting for %d active tasks to finish" % remaining)
			break
		OS.delay_msec(1)
		elapsed_ms += 1

	_mutex.lock()
	_chunks_in_progress.clear()
	_mutex.unlock()
