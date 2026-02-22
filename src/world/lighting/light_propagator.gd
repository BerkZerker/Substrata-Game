## Thread-safe BFS flood-fill light propagation algorithm.
##
## Calculates a light map from terrain data using sunlight column propagation
## and block-light emission, then spreads light via BFS with per-tile filtering.
## Returns a PackedByteArray with 2 bytes per tile: [sunlight, blocklight].
## Light values range from 0 to MAX_LIGHT (80). Attenuation is 1 + light_filter
## per tile: air/dirt/grass (filter 0) lose 1 per tile (~79 tile range),
## stone (filter 1) loses 2 per tile (~39 tile range).
class_name LightPropagator extends RefCounted


## Calculates light map from terrain data.
## Returns a PackedByteArray of CHUNK_SIZE*CHUNK_SIZE*2 bytes.
## Each tile: 2 bytes [sunlight, blocklight], values 0 to MAX_LIGHT.
func calculate_light(terrain_data: PackedByteArray) -> PackedByteArray:
	var chunk_size: int = GlobalSettings.CHUNK_SIZE
	var total_tiles: int = chunk_size * chunk_size
	var max_light: int = GlobalSettings.MAX_LIGHT

	# Separate arrays for sunlight and blocklight (easier to work with during BFS)
	var sunlight: PackedByteArray = PackedByteArray()
	sunlight.resize(total_tiles)
	sunlight.fill(0)

	var blocklight: PackedByteArray = PackedByteArray()
	blocklight.resize(total_tiles)
	blocklight.fill(0)

	# --- Sunlight column pass ---
	# For each column, propagate full sunlight straight down until hitting a solid tile.
	# Only the surface tile (first solid with air above) gets sunlight — columns that
	# start solid at y=0 get nothing (border propagation handles underground light).
	var sun_sources: Array[int] = []

	for x in range(chunk_size):
		var hit_air: bool = false
		for y in range(chunk_size):
			var index: int = y * chunk_size + x
			var data_index: int = index * 2
			var tile_id: int = terrain_data[data_index]

			if TileIndex.is_solid(tile_id):
				if hit_air:
					# Surface tile: first solid tile below air
					sunlight[index] = max_light
					sun_sources.append(index)
				break

			hit_air = true
			sunlight[index] = max_light
			sun_sources.append(index)

	# --- Sunlight BFS spread ---
	_bfs_spread(sunlight, terrain_data, sun_sources, chunk_size)

	# --- Blocklight emission pass ---
	var block_sources: Array[int] = []

	for y in range(chunk_size):
		for x in range(chunk_size):
			var index: int = y * chunk_size + x
			var data_index: int = index * 2
			var tile_id: int = terrain_data[data_index]
			var emission: int = TileIndex.get_emission(tile_id)
			if emission > 0:
				blocklight[index] = emission
				block_sources.append(index)

	# --- Blocklight BFS spread ---
	_bfs_spread(blocklight, terrain_data, block_sources, chunk_size)

	# --- Pack into output (2 bytes per tile) ---
	var result: PackedByteArray = PackedByteArray()
	result.resize(total_tiles * 2)

	for i in range(total_tiles):
		result[i * 2] = sunlight[i]
		result[i * 2 + 1] = blocklight[i]

	return result


## Continues light propagation from border seeds into existing light data.
## Used for cross-chunk border fixup: seeds are border tiles that received
## higher light from a neighbor. BFS spreads inward from those seeds.
func continue_light(packed_light_data: PackedByteArray, terrain_data: PackedByteArray, sun_seeds: Array[int], block_seeds: Array[int]) -> PackedByteArray:
	var chunk_size: int = GlobalSettings.CHUNK_SIZE
	var total_tiles: int = chunk_size * chunk_size

	# Unpack into separate arrays
	var sunlight: PackedByteArray = PackedByteArray()
	sunlight.resize(total_tiles)
	var blocklight: PackedByteArray = PackedByteArray()
	blocklight.resize(total_tiles)

	for i in range(total_tiles):
		sunlight[i] = packed_light_data[i * 2]
		blocklight[i] = packed_light_data[i * 2 + 1]

	# BFS spread from seeds (only updates if higher, so existing values are preserved)
	if not sun_seeds.is_empty():
		_bfs_spread(sunlight, terrain_data, sun_seeds, chunk_size)
	if not block_seeds.is_empty():
		_bfs_spread(blocklight, terrain_data, block_seeds, chunk_size)

	# Repack
	var result: PackedByteArray = PackedByteArray()
	result.resize(total_tiles * 2)
	for i in range(total_tiles):
		result[i * 2] = sunlight[i]
		result[i * 2 + 1] = blocklight[i]

	return result


## BFS flood-fill spread for a light channel.
## Light attenuates by 1 + light_filter per tile. Air/dirt/grass (filter 0)
## lose 1 per tile (~79 tiles range at MAX_LIGHT=80). Stone (filter 1) loses
## 2 per tile (~39 tiles range).
func _bfs_spread(light: PackedByteArray, terrain_data: PackedByteArray, sources: Array[int], chunk_size: int) -> void:
	# Queue stores flat indices
	var queue: Array[int] = sources.duplicate()
	var head: int = 0

	# Direction offsets: right, left, down, up
	var dx: Array[int] = [1, -1, 0, 0]
	var dy: Array[int] = [0, 0, 1, -1]

	while head < queue.size():
		var idx: int = queue[head]
		head += 1

		var current_light: int = light[idx]
		if current_light <= 1:
			continue

		var cx: int = idx % chunk_size
		var cy: int = idx / chunk_size

		for dir in range(4):
			var nx: int = cx + dx[dir]
			var ny: int = cy + dy[dir]

			if nx < 0 or nx >= chunk_size or ny < 0 or ny >= chunk_size:
				continue

			var neighbor_idx: int = ny * chunk_size + nx
			var neighbor_data_idx: int = neighbor_idx * 2
			var neighbor_tile_id: int = terrain_data[neighbor_data_idx]
			var neighbor_filter: int = TileIndex.get_light_filter(neighbor_tile_id)

			var new_light: int = current_light - 1 - neighbor_filter
			if new_light > 0 and new_light > light[neighbor_idx]:
				light[neighbor_idx] = new_light
				queue.append(neighbor_idx)
