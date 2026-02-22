## Manages lighting state and cross-chunk light propagation.
##
## Provides an API for querying light levels at world positions and handles
## border light fixup when chunks are loaded adjacent to existing chunks.
## Light data uses 2 bytes per tile: [sunlight, blocklight], values 0-MAX_LIGHT.
##
## Uses a worklist-based cascading algorithm to propagate light changes across
## chunk boundaries, handling both light increases (BFS continuation) and
## decreases (full recalculation with neighbor imports).
class_name LightManager extends RefCounted

const _MAX_CASCADE_DEPTH: int = 3  # ceil(MAX_LIGHT / CHUNK_SIZE)

var ambient_light: float = 0.05  # Day/night cycle value (0.0-1.0)
var _chunk_manager  # Set during init
var _light_propagator: LightPropagator


func _init() -> void:
	_light_propagator = LightPropagator.new()


func setup(chunk_manager) -> void:
	_chunk_manager = chunk_manager


# ─── Border Snapshot Helpers ──────────────────────────────────────────────


## Snapshots border light values for all 4 edges.
## Returns { Vector2i offset: PackedByteArray } where each array has
## chunk_size * 2 bytes (sun, block per border tile).
func _snapshot_borders(light_data: PackedByteArray) -> Dictionary:
	var cs: int = GlobalSettings.CHUNK_SIZE
	var snap: Dictionary = {}

	# Left border (x=0) — faces neighbor at (-1, 0)
	var left: PackedByteArray = PackedByteArray()
	left.resize(cs * 2)
	for y in range(cs):
		var idx: int = y * cs
		left[y * 2] = light_data[idx * 2]
		left[y * 2 + 1] = light_data[idx * 2 + 1]
	snap[Vector2i(-1, 0)] = left

	# Right border (x=cs-1) — faces neighbor at (1, 0)
	var right: PackedByteArray = PackedByteArray()
	right.resize(cs * 2)
	for y in range(cs):
		var idx: int = y * cs + (cs - 1)
		right[y * 2] = light_data[idx * 2]
		right[y * 2 + 1] = light_data[idx * 2 + 1]
	snap[Vector2i(1, 0)] = right

	# Top border (y=0) — faces neighbor at (0, -1)
	var top: PackedByteArray = PackedByteArray()
	top.resize(cs * 2)
	for x in range(cs):
		top[x * 2] = light_data[x * 2]
		top[x * 2 + 1] = light_data[x * 2 + 1]
	snap[Vector2i(0, -1)] = top

	# Bottom border (y=cs-1) — faces neighbor at (0, 1)
	var bottom: PackedByteArray = PackedByteArray()
	bottom.resize(cs * 2)
	for x in range(cs):
		var idx: int = (cs - 1) * cs + x
		bottom[x * 2] = light_data[idx * 2]
		bottom[x * 2 + 1] = light_data[idx * 2 + 1]
	snap[Vector2i(0, 1)] = bottom

	return snap


## Returns neighbor offsets where this chunk's border light decreased.
## Each offset indicates the neighbor in that direction may have stale
## bright values and needs full recalculation.
func _decreased_border_offsets(old_snap: Dictionary, new_snap: Dictionary) -> Array[Vector2i]:
	var result: Array[Vector2i] = []
	for offset in old_snap:
		if not new_snap.has(offset):
			continue
		var old_border: PackedByteArray = old_snap[offset]
		var new_border: PackedByteArray = new_snap[offset]
		for i in range(old_border.size()):
			if new_border[i] < old_border[i]:
				result.append(offset)
				break
	return result


## Returns true if any border light value changed between snapshots.
func _border_changed(old_snap: Dictionary, new_snap: Dictionary) -> bool:
	for offset in old_snap:
		if not new_snap.has(offset):
			continue
		var old_border: PackedByteArray = old_snap[offset]
		var new_border: PackedByteArray = new_snap[offset]
		for i in range(old_border.size()):
			if new_border[i] != old_border[i]:
				return true
	return false


# ─── Core Light Engine ────────────────────────────────────────────────────


## Full recalculate from scratch + import border light from all loaded neighbors.
## Sets light data, rebuilds visual image, emits light_level_changed.
func _full_recalc_with_imports(chunk_pos: Vector2i, chunk) -> void:
	var terrain_data: PackedByteArray = chunk.get_terrain_data()
	var light_data: PackedByteArray = _light_propagator.calculate_light(terrain_data)

	if _chunk_manager:
		var cs: int = GlobalSettings.CHUNK_SIZE
		var sun_seeds: Array[int] = []
		var block_seeds: Array[int] = []

		for offset in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
			var neighbor = _chunk_manager.get_chunk_at(chunk_pos + offset)
			if neighbor:
				var neighbor_light: PackedByteArray = neighbor.get_light_data()
				if not neighbor_light.is_empty():
					_collect_border_seeds(light_data, neighbor_light, terrain_data, offset, cs, sun_seeds, block_seeds)

		if not sun_seeds.is_empty() or not block_seeds.is_empty():
			light_data = _light_propagator.continue_light(light_data, terrain_data, sun_seeds, block_seeds)

	chunk.set_light_data(light_data)
	_rebuild_chunk_light_image(chunk, light_data)
	SignalBus.light_level_changed.emit(chunk_pos)


## Two-phase worklist engine for cascading light changes across chunks.
##
## Phase 1 (darkness): Full-recalculates chunks whose incoming light decreased.
## If a recalculated chunk's borders also decrease, cascades to its neighbors.
##
## Phase 2 (brightness): BFS pushes higher light from dirty chunks to neighbors.
## If a neighbor's borders change, cascades outward.
##
## Both phases are bounded by _MAX_CASCADE_DEPTH to prevent runaway propagation.
func _propagate_light_changes(dirty_chunks: Array[Vector2i], chunks_needing_full_recalc: Array[Vector2i]) -> void:
	if _chunk_manager == null:
		return

	var cs: int = GlobalSettings.CHUNK_SIZE

	# ── Phase 1: Darkness cascade ──────────────────────────────────────
	var recalc_queue: Array[Vector2i] = chunks_needing_full_recalc.duplicate()
	var recalc_visited: Dictionary = {}
	var recalc_depth: Dictionary = {}

	for pos in recalc_queue:
		recalc_depth[pos] = 0

	var recalc_head: int = 0
	while recalc_head < recalc_queue.size():
		var pos: Vector2i = recalc_queue[recalc_head]
		recalc_head += 1

		if recalc_visited.has(pos):
			continue
		recalc_visited[pos] = true

		var chunk = _chunk_manager.get_chunk_at(pos)
		if chunk == null:
			continue

		var old_light: PackedByteArray = chunk.get_light_data()
		if old_light.is_empty():
			continue

		var old_snap: Dictionary = _snapshot_borders(old_light)
		_full_recalc_with_imports(pos, chunk)
		var new_light: PackedByteArray = chunk.get_light_data()
		var new_snap: Dictionary = _snapshot_borders(new_light)

		# If borders decreased further, cascade to affected neighbors
		var depth: int = recalc_depth.get(pos, 0)
		if depth < _MAX_CASCADE_DEPTH:
			var decreased: Array[Vector2i] = _decreased_border_offsets(old_snap, new_snap)
			for offset in decreased:
				var neighbor_pos: Vector2i = pos + offset
				if not recalc_visited.has(neighbor_pos):
					recalc_queue.append(neighbor_pos)
					if not recalc_depth.has(neighbor_pos) or recalc_depth[neighbor_pos] > depth + 1:
						recalc_depth[neighbor_pos] = depth + 1

		# Add recalculated chunk to dirty set for Phase 2
		if not dirty_chunks.has(pos):
			dirty_chunks.append(pos)

	# ── Phase 2: Light-increase cascade ────────────────────────────────
	var light_queue: Array[Vector2i] = dirty_chunks.duplicate()
	var light_visited: Dictionary = {}
	var light_depth: Dictionary = {}

	for pos in light_queue:
		light_depth[pos] = 0

	var light_head: int = 0
	while light_head < light_queue.size():
		var pos: Vector2i = light_queue[light_head]
		light_head += 1

		if light_visited.has(pos):
			continue
		light_visited[pos] = true

		var chunk = _chunk_manager.get_chunk_at(pos)
		if chunk == null:
			continue

		var light_data: PackedByteArray = chunk.get_light_data()
		if light_data.is_empty():
			continue

		# Try to push light to each unvisited neighbor
		for offset in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
			var neighbor_pos: Vector2i = pos + offset
			if light_visited.has(neighbor_pos):
				continue

			var neighbor = _chunk_manager.get_chunk_at(neighbor_pos)
			if neighbor == null:
				continue

			var neighbor_light: PackedByteArray = neighbor.get_light_data()
			if neighbor_light.is_empty():
				continue

			var neighbor_terrain: PackedByteArray = neighbor.get_terrain_data()
			var n_sun_seeds: Array[int] = []
			var n_block_seeds: Array[int] = []

			var reverse_offset: Vector2i = -offset
			_collect_border_seeds(neighbor_light, light_data, neighbor_terrain, reverse_offset, cs, n_sun_seeds, n_block_seeds)

			if not n_sun_seeds.is_empty() or not n_block_seeds.is_empty():
				var old_snap: Dictionary = _snapshot_borders(neighbor_light)
				neighbor_light = _light_propagator.continue_light(neighbor_light, neighbor_terrain, n_sun_seeds, n_block_seeds)
				neighbor.set_light_data(neighbor_light)
				_rebuild_chunk_light_image(neighbor, neighbor_light)
				SignalBus.light_level_changed.emit(neighbor_pos)

				# If neighbor's borders changed, light may cascade further
				var depth: int = light_depth.get(pos, 0)
				if depth < _MAX_CASCADE_DEPTH:
					var new_snap: Dictionary = _snapshot_borders(neighbor_light)
					if _border_changed(old_snap, new_snap):
						light_queue.append(neighbor_pos)
						if not light_depth.has(neighbor_pos) or light_depth[neighbor_pos] > depth + 1:
							light_depth[neighbor_pos] = depth + 1


# ─── Public API ───────────────────────────────────────────────────────────


## Called by ChunkManager after building a chunk to fix light at borders.
## neighbors is { Vector2i offset: Chunk } for loaded neighbor chunks.
func propagate_border_light(chunk_pos: Vector2i, chunk, neighbors: Dictionary) -> void:
	var cs: int = GlobalSettings.CHUNK_SIZE
	var light_data: PackedByteArray = chunk.get_light_data()
	if light_data.is_empty():
		return

	var terrain_data: PackedByteArray = chunk.get_terrain_data()
	var sun_seeds: Array[int] = []
	var block_seeds: Array[int] = []

	# Import border light from neighbors into this chunk
	for offset in neighbors:
		var neighbor = neighbors[offset]
		var neighbor_light: PackedByteArray = neighbor.get_light_data()
		if neighbor_light.is_empty():
			continue
		_collect_border_seeds(light_data, neighbor_light, terrain_data, offset, cs, sun_seeds, block_seeds)

	if not sun_seeds.is_empty() or not block_seeds.is_empty():
		light_data = _light_propagator.continue_light(light_data, terrain_data, sun_seeds, block_seeds)
		chunk.set_light_data(light_data)
		_rebuild_chunk_light_image(chunk, light_data)
		SignalBus.light_level_changed.emit(chunk_pos)

	# Propagate outward — newly loaded chunk, so neighbors can only get brighter
	var dirty: Array[Vector2i] = [chunk_pos]
	var empty_recalc: Array[Vector2i] = []
	_propagate_light_changes(dirty, empty_recalc)


## Recalculates light for a single chunk after tile edits.
func recalculate_chunk_light(chunk_pos: Vector2i, chunk) -> void:
	var old_light: PackedByteArray = chunk.get_light_data()
	var old_snap: Dictionary = {}
	if not old_light.is_empty():
		old_snap = _snapshot_borders(old_light)

	_full_recalc_with_imports(chunk_pos, chunk)

	# Determine which neighbors might have stale bright values
	var decreased_neighbors: Array[Vector2i] = []
	if not old_snap.is_empty():
		var new_light: PackedByteArray = chunk.get_light_data()
		var new_snap: Dictionary = _snapshot_borders(new_light)
		var decreased_offsets: Array[Vector2i] = _decreased_border_offsets(old_snap, new_snap)
		for offset in decreased_offsets:
			var neighbor_pos: Vector2i = chunk_pos + offset
			if _chunk_manager.get_chunk_at(neighbor_pos) != null:
				decreased_neighbors.append(neighbor_pos)

	var dirty: Array[Vector2i] = [chunk_pos]
	_propagate_light_changes(dirty, decreased_neighbors)


## Batch recalculates light for multiple chunks after tile edits.
## More efficient than per-chunk recalculate because edited chunks see each
## other's fresh data before outward propagation.
func recalculate_chunks_light(chunk_positions: Array[Vector2i]) -> void:
	if _chunk_manager == null:
		return

	var cs: int = GlobalSettings.CHUNK_SIZE
	var all_old_snaps: Dictionary = {}  # { Vector2i: Dictionary }
	var all_chunks: Dictionary = {}     # { Vector2i: Chunk }

	# Pass 1: Snapshot old borders, calculate fresh light (no imports yet)
	for pos in chunk_positions:
		var chunk = _chunk_manager.get_chunk_at(pos)
		if chunk == null:
			continue
		all_chunks[pos] = chunk

		var old_light: PackedByteArray = chunk.get_light_data()
		if not old_light.is_empty():
			all_old_snaps[pos] = _snapshot_borders(old_light)

		var terrain_data: PackedByteArray = chunk.get_terrain_data()
		var light_data: PackedByteArray = _light_propagator.calculate_light(terrain_data)
		chunk.set_light_data(light_data)

	# Pass 2: Import borders from all neighbors (edited siblings + non-edited)
	for pos in all_chunks:
		var chunk = all_chunks[pos]
		var terrain_data: PackedByteArray = chunk.get_terrain_data()
		var light_data: PackedByteArray = chunk.get_light_data()
		var sun_seeds: Array[int] = []
		var block_seeds: Array[int] = []

		for offset in [Vector2i(-1, 0), Vector2i(1, 0), Vector2i(0, -1), Vector2i(0, 1)]:
			var neighbor_pos: Vector2i = pos + offset
			var neighbor = _chunk_manager.get_chunk_at(neighbor_pos)
			if neighbor == null:
				continue
			var neighbor_light: PackedByteArray = neighbor.get_light_data()
			if neighbor_light.is_empty():
				continue
			_collect_border_seeds(light_data, neighbor_light, terrain_data, offset, cs, sun_seeds, block_seeds)

		if not sun_seeds.is_empty() or not block_seeds.is_empty():
			light_data = _light_propagator.continue_light(light_data, terrain_data, sun_seeds, block_seeds)
			chunk.set_light_data(light_data)

	# Pass 3: Rebuild images for all edited chunks
	for pos in all_chunks:
		var chunk = all_chunks[pos]
		_rebuild_chunk_light_image(chunk, chunk.get_light_data())
		SignalBus.light_level_changed.emit(pos)

	# Pass 4: Collect decreased-border neighbors and propagate
	var all_decreased: Array[Vector2i] = []
	for pos in all_chunks:
		var new_light: PackedByteArray = all_chunks[pos].get_light_data()
		var new_snap: Dictionary = _snapshot_borders(new_light)

		if all_old_snaps.has(pos):
			var decreased_offsets: Array[Vector2i] = _decreased_border_offsets(all_old_snaps[pos], new_snap)
			for offset in decreased_offsets:
				var neighbor_pos: Vector2i = pos + offset
				# Only add non-edited loaded neighbors
				if not all_chunks.has(neighbor_pos) and _chunk_manager.get_chunk_at(neighbor_pos) != null:
					if not all_decreased.has(neighbor_pos):
						all_decreased.append(neighbor_pos)

	var edited_array: Array[Vector2i] = []
	for pos in all_chunks:
		edited_array.append(pos)

	_propagate_light_changes(edited_array, all_decreased)


# ─── Internal Helpers ─────────────────────────────────────────────────────


## Collects border seed indices where neighbor light would improve chunk light.
## Seeds are added to sun_seeds and block_seeds arrays (flat indices into chunk).
func _collect_border_seeds(chunk_light: PackedByteArray, neighbor_light: PackedByteArray, chunk_terrain: PackedByteArray, offset: Vector2i, chunk_size: int, sun_seeds: Array[int], block_seeds: Array[int]) -> void:
	var pairs: Array = _get_border_pairs(offset, chunk_size)

	for pair in pairs:
		var c_idx: int = pair[0]  # Index in this chunk (border tile)
		var n_idx: int = pair[1]  # Index in neighbor (border tile)

		var n_sun: int = neighbor_light[n_idx * 2]
		var n_block: int = neighbor_light[n_idx * 2 + 1]
		var c_sun: int = chunk_light[c_idx * 2]
		var c_block: int = chunk_light[c_idx * 2 + 1]

		var tile_id: int = chunk_terrain[c_idx * 2]
		var light_filter: int = TileIndex.get_light_filter(tile_id)

		var new_sun: int = maxi(n_sun - 1 - light_filter, 0)
		var new_block: int = maxi(n_block - 1 - light_filter, 0)

		if new_sun > c_sun:
			chunk_light[c_idx * 2] = new_sun
			sun_seeds.append(c_idx)
		if new_block > c_block:
			chunk_light[c_idx * 2 + 1] = new_block
			block_seeds.append(c_idx)


## Returns an array of [chunk_idx, neighbor_idx] pairs for the border between
## a chunk and its neighbor at the given offset.
func _get_border_pairs(offset: Vector2i, chunk_size: int) -> Array:
	var pairs: Array = []
	if offset == Vector2i(-1, 0):  # Neighbor is to the left
		for y in range(chunk_size):
			pairs.append([y * chunk_size + 0, y * chunk_size + (chunk_size - 1)])
	elif offset == Vector2i(1, 0):  # Neighbor is to the right
		for y in range(chunk_size):
			pairs.append([y * chunk_size + (chunk_size - 1), y * chunk_size + 0])
	elif offset == Vector2i(0, -1):  # Neighbor is above
		for x in range(chunk_size):
			pairs.append([0 * chunk_size + x, (chunk_size - 1) * chunk_size + x])
	elif offset == Vector2i(0, 1):  # Neighbor is below
		for x in range(chunk_size):
			pairs.append([(chunk_size - 1) * chunk_size + x, 0 * chunk_size + x])
	return pairs


## Rebuilds the B channel of a chunk's visual image from light data.
func _rebuild_chunk_light_image(chunk, light_data: PackedByteArray) -> void:
	var chunk_size: int = GlobalSettings.CHUNK_SIZE
	var terrain_data: PackedByteArray = chunk.get_terrain_data()
	var max_light_f: float = float(GlobalSettings.MAX_LIGHT)

	var inv_255: float = 1.0 / 255.0
	var image: Image = Image.create(chunk_size, chunk_size, false, Image.FORMAT_RGBA8)

	for x in range(chunk_size):
		for y in range(chunk_size):
			var effective_y: int = (chunk_size - 1) - y
			var data_index: int = (effective_y * chunk_size + x) * 2
			var tile_id: float = float(terrain_data[data_index])
			var cell_id: float = float(terrain_data[data_index + 1])

			var light_index: int = effective_y * chunk_size + x
			var sun: int = light_data[light_index * 2]
			var block: int = light_data[light_index * 2 + 1]
			var light_value: float = float(maxi(sun, block)) / max_light_f

			image.set_pixel(x, y, Color(tile_id * inv_255, cell_id * inv_255, light_value, 0))

	chunk.rebuild_image(image)


## Returns the light level at a world position (0-MAX_LIGHT).
func get_light_at_world_pos(world_pos: Vector2) -> int:
	if _chunk_manager == null:
		return GlobalSettings.MAX_LIGHT
	var chunk_pos = _chunk_manager.world_to_chunk_pos(world_pos)
	var chunk = _chunk_manager.get_chunk_at(chunk_pos)
	if chunk == null:
		return GlobalSettings.MAX_LIGHT
	var tile_pos = _chunk_manager.world_to_tile_pos(world_pos)
	return chunk.get_light_at(tile_pos.x, tile_pos.y)
