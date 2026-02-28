## Static light baker using sunlight propagation and flood-fill BFS.
##
## Bakes per-chunk light levels (0-15) from sunlight and emissive tiles.
## Runs on the main thread to safely read neighbor chunk data.
class_name LightBaker extends RefCounted

const MAX_LIGHT: int = 32

var _chunk_manager: ChunkManager


func _init(chunk_manager: ChunkManager) -> void:
	_chunk_manager = chunk_manager


## Bakes light for a single chunk. Returns Dictionary with "sky" PackedByteArray and "block" Dictionary {"r","g","b"}.
func bake_chunk_light(chunk_pos: Vector2i) -> Dictionary:
	var size: int = GlobalSettings.CHUNK_SIZE
	var total: int = size * size
	var sky := PackedByteArray()
	sky.resize(total)
	sky.fill(0)
	var block_r := PackedByteArray()
	block_r.resize(total)
	block_r.fill(0)
	var block_g := PackedByteArray()
	block_g.resize(total)
	block_g.fill(0)
	var block_b := PackedByteArray()
	block_b.resize(total)
	block_b.fill(0)

	var empty_block := { "r": block_r, "g": block_g, "b": block_b }

	var chunk = _chunk_manager.get_chunk_at(chunk_pos)
	if chunk == null:
		sky.fill(MAX_LIGHT)
		return { "sky": sky, "block": empty_block }

	var terrain_data = chunk.get_terrain_data()
	if terrain_data.is_empty():
		sky.fill(MAX_LIGHT)
		return { "sky": sky, "block": empty_block }

	# --- Sky light pass (sunlight propagation) ---
	var sky_queue: Array = []

	var above_chunk_pos = chunk_pos + Vector2i(0, -1)
	var above_chunk = _chunk_manager.get_chunk_at(above_chunk_pos)

	for x in range(size):
		# Check if tile above (bottom row of neighbor chunk) is air
		var above_is_air = true
		if above_chunk != null:
			var above_tile_id = above_chunk.get_tile_id_at(x, size - 1)
			above_is_air = not TileIndex.is_solid(above_tile_id)

		if not above_is_air:
			continue

		# Walk down from top of this chunk
		for y in range(size):
			var idx = y * size + x
			var data_idx = idx * 2
			var tile_id = terrain_data[data_idx]

			if TileIndex.is_solid(tile_id):
				# Surface solid tile receives full sunlight and seeds downward propagation
				sky[idx] = MAX_LIGHT
				sky_queue.append([idx, MAX_LIGHT])
				break

			sky[idx] = MAX_LIGHT
			sky_queue.append([idx, MAX_LIGHT])

	# Cross-chunk border seeding for sky light
	_seed_border_from_neighbor(chunk_pos, sky, sky_queue, size, terrain_data)

	# BFS flood fill for sky light
	_flood_fill(sky, sky_queue, size, terrain_data)

	# --- Block light pass (3-channel RGB from emissive tiles) ---
	var queue_r: Array = []
	var queue_g: Array = []
	var queue_b: Array = []

	for y in range(size):
		for x in range(size):
			var idx = y * size + x
			var data_idx = idx * 2
			var tile_id = terrain_data[data_idx]
			var emission = TileIndex.get_light_emission(tile_id)
			if emission > 0:
				var color: Color = TileIndex.get_emission_color(tile_id)
				var er = int(emission * color.r)
				var eg = int(emission * color.g)
				var eb = int(emission * color.b)
				if er > 0:
					block_r[idx] = er
					queue_r.append([idx, er])
				if eg > 0:
					block_g[idx] = eg
					queue_g.append([idx, eg])
				if eb > 0:
					block_b[idx] = eb
					queue_b.append([idx, eb])

	# BFS flood fill for each channel
	_flood_fill(block_r, queue_r, size, terrain_data)
	_flood_fill(block_g, queue_g, size, terrain_data)
	_flood_fill(block_b, queue_b, size, terrain_data)

	return { "sky": sky, "block": { "r": block_r, "g": block_g, "b": block_b } }


## Seeds the BFS queue with actual baked light values from adjacent chunk borders.
func _seed_border_from_neighbor(chunk_pos: Vector2i, light: PackedByteArray, queue: Array, size: int, _terrain_data: PackedByteArray) -> void:
	# Each entry: [offset, neighbor_edge_index_func, local_edge_index_func]
	# neighbor edge = the row/col of the neighbor touching our border
	# local edge = our row/col on that border
	var directions = [
		Vector2i(-1, 0),  # neighbor to the left
		Vector2i(1, 0),   # neighbor to the right
		Vector2i(0, -1),  # neighbor above
		Vector2i(0, 1),   # neighbor below
	]

	for dir in directions:
		var neighbor_chunk = _chunk_manager.get_chunk_at(chunk_pos + dir)
		if neighbor_chunk == null:
			continue

		var neighbor_sky = neighbor_chunk.get_sky_light_data()
		if neighbor_sky.is_empty():
			continue

		for i in range(size):
			# Read actual baked light from neighbor's border tile
			var neighbor_light: int = 0
			var local_idx: int = 0

			if dir == Vector2i(-1, 0):
				# Left neighbor: their rightmost column → our leftmost column
				neighbor_light = neighbor_sky[i * size + (size - 1)]
				local_idx = i * size + 0
			elif dir == Vector2i(1, 0):
				# Right neighbor: their leftmost column → our rightmost column
				neighbor_light = neighbor_sky[i * size + 0]
				local_idx = i * size + (size - 1)
			elif dir == Vector2i(0, -1):
				# Above neighbor: their bottom row → our top row
				neighbor_light = neighbor_sky[(size - 1) * size + i]
				local_idx = 0 * size + i
			elif dir == Vector2i(0, 1):
				# Below neighbor: their top row → our bottom row
				neighbor_light = neighbor_sky[0 * size + i]
				local_idx = (size - 1) * size + i

			if neighbor_light <= 1:
				continue

			var propagated = neighbor_light - 1
			if propagated > light[local_idx]:
				light[local_idx] = propagated
				queue.append([local_idx, propagated])


## Pure-computation bake from snapshot data. No chunk/scene access — safe for background threads.
## above_terrain_data: terrain data from the chunk above (for sunlight entry check), or empty.
## neighbor_sky_data: { Vector2i offset: PackedByteArray } — sky light from 4 neighbors.
## neighbor_block_data: { Vector2i offset: PackedByteArray } — block light from 4 neighbors.
func bake_from_data(
	terrain_data: PackedByteArray,
	above_terrain_data: PackedByteArray,
	neighbor_sky_data: Dictionary,
	neighbor_block_data: Dictionary
) -> Dictionary:
	var size: int = GlobalSettings.CHUNK_SIZE

	var total: int = size * size
	var sky := PackedByteArray()
	sky.resize(total)
	sky.fill(0)
	var block_r := PackedByteArray()
	block_r.resize(total)
	block_r.fill(0)
	var block_g := PackedByteArray()
	block_g.resize(total)
	block_g.fill(0)
	var block_b := PackedByteArray()
	block_b.resize(total)
	block_b.fill(0)

	if terrain_data.is_empty():
		sky.fill(MAX_LIGHT)
		return { "sky": sky, "block": { "r": block_r, "g": block_g, "b": block_b } }

	# --- Sky light pass (sunlight propagation) ---
	var sky_queue: Array = []

	for x in range(size):
		# Check if tile above (bottom row of above chunk) is air
		var above_is_air = true
		if not above_terrain_data.is_empty():
			var above_idx = ((size - 1) * size + x) * 2
			if above_idx < above_terrain_data.size():
				var above_tile_id = above_terrain_data[above_idx]
				above_is_air = not TileIndex.is_solid(above_tile_id)

		if not above_is_air:
			continue

		# Walk down from top of this chunk
		for y in range(size):
			var idx = y * size + x
			var data_idx = idx * 2
			var tile_id = terrain_data[data_idx]

			if TileIndex.is_solid(tile_id):
				sky[idx] = MAX_LIGHT
				sky_queue.append([idx, MAX_LIGHT])
				break

			sky[idx] = MAX_LIGHT
			sky_queue.append([idx, MAX_LIGHT])

	# Cross-chunk border seeding for sky light
	_seed_border_from_data(neighbor_sky_data, sky, sky_queue, size)

	# BFS flood fill for sky light
	_flood_fill(sky, sky_queue, size, terrain_data)

	# --- Block light pass (3-channel RGB from emissive tiles) ---
	var queue_r: Array = []
	var queue_g: Array = []
	var queue_b: Array = []

	for y in range(size):
		for x in range(size):
			var idx = y * size + x
			var data_idx = idx * 2
			var tile_id = terrain_data[data_idx]
			var emission = TileIndex.get_light_emission(tile_id)
			if emission > 0:
				var color: Color = TileIndex.get_emission_color(tile_id)
				var er = int(emission * color.r)
				var eg = int(emission * color.g)
				var eb = int(emission * color.b)
				if er > 0:
					block_r[idx] = er
					queue_r.append([idx, er])
				if eg > 0:
					block_g[idx] = eg
					queue_g.append([idx, eg])
				if eb > 0:
					block_b[idx] = eb
					queue_b.append([idx, eb])

	# Cross-chunk border seeding for block light (per channel)
	var channels = ["r", "g", "b"]
	var block_arrays = [block_r, block_g, block_b]
	var block_queues = [queue_r, queue_g, queue_b]
	for ci in range(3):
		var ch = channels[ci]
		var ch_neighbor_data: Dictionary = {}
		for offset in neighbor_block_data:
			var n_block_dict: Dictionary = neighbor_block_data[offset]
			ch_neighbor_data[offset] = n_block_dict[ch]
		_seed_border_from_data(ch_neighbor_data, block_arrays[ci], block_queues[ci], size)

	# BFS flood fill for each channel
	_flood_fill(block_r, queue_r, size, terrain_data)
	_flood_fill(block_g, queue_g, size, terrain_data)
	_flood_fill(block_b, queue_b, size, terrain_data)

	return { "sky": sky, "block": { "r": block_r, "g": block_g, "b": block_b } }


## Seeds the BFS queue from snapshot neighbor data (either sky or block).
func _seed_border_from_data(neighbor_data: Dictionary, light: PackedByteArray, queue: Array, size: int) -> void:
	var directions = [
		Vector2i(-1, 0),
		Vector2i(1, 0),
		Vector2i(0, -1),
		Vector2i(0, 1),
	]

	for dir in directions:
		var n_light: PackedByteArray = neighbor_data.get(dir, PackedByteArray())
		if n_light.is_empty():
			continue

		for i in range(size):
			var neighbor_light: int = 0
			var local_idx: int = 0

			if dir == Vector2i(-1, 0):
				neighbor_light = n_light[i * size + (size - 1)]
				local_idx = i * size + 0
			elif dir == Vector2i(1, 0):
				neighbor_light = n_light[i * size + 0]
				local_idx = i * size + (size - 1)
			elif dir == Vector2i(0, -1):
				neighbor_light = n_light[(size - 1) * size + i]
				local_idx = 0 * size + i
			elif dir == Vector2i(0, 1):
				neighbor_light = n_light[0 * size + i]
				local_idx = (size - 1) * size + i

			if neighbor_light <= 1:
				continue

			var propagated = neighbor_light - 1
			if propagated > light[local_idx]:
				light[local_idx] = propagated
				queue.append([local_idx, propagated])


## BFS flood fill: propagate light to 4-neighbors with uniform cost of 1 per tile.
func _flood_fill(light: PackedByteArray, queue: Array, size: int, terrain_data: PackedByteArray) -> void:
	var head: int = 0

	while head < queue.size():
		var entry = queue[head]
		head += 1

		var idx: int = entry[0]
		var level: int = entry[1]

		if level <= 1:
			continue

		var x: int = idx % size
		var y: int = idx / size

		var new_level = level - 1

		# 4-neighbors
		var nx_arr = [x - 1, x + 1, x, x]
		var ny_arr = [y, y, y - 1, y + 1]

		for i in range(4):
			var nx = nx_arr[i]
			var ny = ny_arr[i]

			if nx < 0 or nx >= size or ny < 0 or ny >= size:
				continue

			var n_idx = ny * size + nx

			if new_level > light[n_idx]:
				light[n_idx] = new_level
				queue.append([n_idx, new_level])
