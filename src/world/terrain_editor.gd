## Handles force-based terrain editing with Dijkstra flood fill.
##
## Given a click origin and force value, propagates destruction outward using
## a max-path Dijkstra algorithm. Force drains by each tile's effective hardness.
## Tiles that can't be fully destroyed take partial damage (damage_stage).
## After the flood fill, small orphaned clusters of solid tiles are cleaned up.
class_name TerrainEditor extends RefCounted

## Directions for 4-connected flood fill (N, S, E, W)
const NEIGHBORS: Array[Vector2] = [
	Vector2(0, -1), Vector2(0, 1), Vector2(-1, 0), Vector2(1, 0)
]


## Performs a force-based terrain edit at the given world position.
## Returns the array of changes applied (for debugging/visualization).
func edit_at(origin: Vector2, force: float, chunk_manager: ChunkManager) -> Array:
	if force <= 0.0:
		return []

	var origin_tile = origin.floor()

	# Phase 1: Dijkstra flood fill
	var changes = _flood_fill(origin_tile, force, chunk_manager)

	if changes.is_empty():
		return []

	# Phase 2: Orphaned cluster cleanup
	var orphan_changes = _cleanup_orphans(changes, chunk_manager)
	changes.append_array(orphan_changes)

	# Apply all changes
	if not changes.is_empty():
		chunk_manager.set_tiles_at_world_positions(changes)

	return changes


## Dijkstra flood fill: propagates force outward from origin.
## Returns an array of change dictionaries ready for set_tiles_at_world_positions().
func _flood_fill(origin: Vector2, force: float, chunk_manager: ChunkManager) -> Array:
	var max_radius_sq = GlobalSettings.MAX_FLOOD_FILL_RADIUS * GlobalSettings.MAX_FLOOD_FILL_RADIUS
	var changes: Array = []

	# Priority queue: [remaining_force, world_pos]
	# We use an array sorted by remaining force (highest first).
	# For the scale we're working at (capped at 64 radius), a simple sorted
	# insert is fast enough.
	var open: Array = [] # Array of [float, Vector2]
	var visited: Dictionary = {} # { Vector2: true }

	# Check origin tile — force only propagates through solid tiles, not air
	var origin_data = chunk_manager.get_tile_at_world_pos(origin)
	var origin_tile_id: int = origin_data[0]

	if origin_tile_id == TileIndex.AIR:
		# Clicked on air — nothing to destroy
		return []

	# Start from the clicked solid tile
	_pq_insert(open, [force, origin])

	while not open.is_empty():
		var entry = open.pop_front() # Highest force first
		var remaining_force: float = entry[0]
		var pos: Vector2 = entry[1]

		if visited.has(pos):
			continue
		visited[pos] = true

		# Radius check
		if (pos - origin).length_squared() > max_radius_sq:
			continue

		# Get current tile state
		var tile_data = chunk_manager.get_tile_at_world_pos(pos)
		var tile_id: int = tile_data[0]
		var damage_stage: int = tile_data[1]

		# Air tiles block propagation — force only spreads through solid material
		if tile_id == TileIndex.AIR:
			continue

		# Calculate effective hardness (damaged tiles are weaker)
		var effective_hardness: float = TileIndex.get_effective_hardness(tile_id, damage_stage)

		if remaining_force >= effective_hardness:
			# Full break — destroy tile
			var force_after = remaining_force - effective_hardness
			changes.append({
				"pos": pos,
				"tile_id": TileIndex.AIR,
				"damage_stage": 0,
			})

			# Propagate remaining force to solid neighbors only
			if force_after > 0.0:
				for dir in NEIGHBORS:
					var neighbor_pos = pos + dir
					if not visited.has(neighbor_pos):
						_pq_insert(open, [force_after, neighbor_pos])
		else:
			# Partial damage — step up damage stage
			var max_stages: int = TileIndex.get_damage_stages(tile_id)
			if max_stages > 0 and damage_stage < max_stages:
				changes.append({
					"pos": pos,
					"tile_id": tile_id,
					"damage_stage": damage_stage + 1,
				})
			# Partial damage doesn't propagate — flood fill stops here

	return changes


## Cleans up small orphaned clusters of solid tiles adjacent to destroyed tiles.
## Returns additional changes to apply.
func _cleanup_orphans(destruction_changes: Array, chunk_manager: ChunkManager) -> Array:
	var threshold = GlobalSettings.ORPHAN_CLUSTER_THRESHOLD
	var orphan_changes: Array = []

	# Build set of positions that were destroyed (turned to air)
	var destroyed_set: Dictionary = {} # { Vector2: true }
	for change in destruction_changes:
		if change["tile_id"] == TileIndex.AIR:
			destroyed_set[change["pos"]] = true

	if destroyed_set.is_empty():
		return []

	# Collect border tiles: solid tiles adjacent to any destroyed tile
	var border_set: Dictionary = {} # { Vector2: true }
	for destroyed_pos in destroyed_set:
		for dir in NEIGHBORS:
			var neighbor_pos = destroyed_pos + dir
			if destroyed_set.has(neighbor_pos):
				continue
			# Check if this neighbor is solid (and not already in our changes as destroyed)
			var tile_data = chunk_manager.get_tile_at_world_pos(neighbor_pos)
			if tile_data[0] != TileIndex.AIR:
				border_set[neighbor_pos] = true

	# Also check changes that are damage-only (still solid) as potential border tiles
	for change in destruction_changes:
		if change["tile_id"] != TileIndex.AIR:
			border_set[change["pos"]] = true

	# BFS from each unprocessed border tile to find small clusters
	var processed: Dictionary = {} # { Vector2: true }
	var already_orphaned: Dictionary = {} # { Vector2: true } — tiles already marked for destruction

	for start_pos in border_set:
		if processed.has(start_pos) or already_orphaned.has(start_pos):
			continue

		# BFS to find connected component size
		var cluster: Array[Vector2] = []
		var bfs_queue: Array[Vector2] = [start_pos]
		var bfs_visited: Dictionary = {start_pos: true}
		var is_small = true

		while not bfs_queue.is_empty() and is_small:
			var pos = bfs_queue.pop_front()
			cluster.append(pos)

			if cluster.size() > threshold:
				is_small = false
				break

			for dir in NEIGHBORS:
				var neighbor_pos = pos + dir
				if bfs_visited.has(neighbor_pos):
					continue
				if destroyed_set.has(neighbor_pos) or already_orphaned.has(neighbor_pos):
					continue

				var tile_data = chunk_manager.get_tile_at_world_pos(neighbor_pos)
				if tile_data[0] != TileIndex.AIR:
					bfs_visited[neighbor_pos] = true
					bfs_queue.append(neighbor_pos)

		# Mark all visited tiles as processed
		for pos in bfs_visited:
			processed[pos] = true

		# If cluster is small enough, destroy it
		if is_small:
			for pos in cluster:
				already_orphaned[pos] = true
				orphan_changes.append({
					"pos": pos,
					"tile_id": TileIndex.AIR,
					"damage_stage": 0,
				})

	return orphan_changes


## Inserts an entry into the priority queue (sorted by force, highest first).
func _pq_insert(queue: Array, entry: Array) -> void:
	var force = entry[0]
	# Binary search for insertion point
	var lo: int = 0
	var hi: int = queue.size()
	while lo < hi:
		@warning_ignore("integer_division")
		var mid: int = (lo + hi) / 2
		if queue[mid][0] > force:
			lo = mid + 1
		else:
			hi = mid
	queue.insert(lo, entry)
