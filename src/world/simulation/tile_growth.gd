## Tile growth simulation using a random tick model.
##
## Periodically selects random tiles from loaded chunks and applies growth
## rules based on each tile's growth_type property. Supports grass spreading
## to adjacent dirt and vines growing downward.
class_name TileGrowthSystem extends Node

## How often (in seconds) a growth tick runs.
const TICK_INTERVAL: float = 0.8

## Number of random tiles to sample per tick.
const TICKS_PER_CYCLE: int = 64

## Probability that a grass tile spreads to an adjacent dirt tile per tick.
const GRASS_SPREAD_CHANCE: float = 0.10

## Probability that a vine tile grows one tile downward per tick.
const VINE_GROW_CHANCE: float = 0.05

## Maximum vine chain length (tracked via cell_id).
const MAX_VINE_LENGTH: int = 10

## Neighbor offsets for grass spreading (horizontal + diagonal, not straight down).
const SPREAD_OFFSETS: Array[Vector2i] = [
	Vector2i(-1, 0), Vector2i(1, 0),   # left, right
	Vector2i(0, -1),                     # up
	Vector2i(-1, -1), Vector2i(1, -1),  # upper diagonals
	Vector2i(-1, 1), Vector2i(1, 1),    # lower diagonals
]

var _timer: float = 0.0
var _chunk_manager: ChunkManager = null
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()


func _ready() -> void:
	_rng.randomize()
	# Defer setup so GameServices are populated
	SignalBus.world_ready.connect(_on_world_ready)


func _on_world_ready() -> void:
	_chunk_manager = GameServices.chunk_manager


func _process(delta: float) -> void:
	if _chunk_manager == null:
		return

	_timer += delta
	if _timer < TICK_INTERVAL:
		return
	_timer -= TICK_INTERVAL

	_run_growth_tick()


func _run_growth_tick() -> void:
	var loaded_positions: Array = _chunk_manager.get_loaded_chunk_positions()
	if loaded_positions.is_empty():
		return

	var chunk_size: int = GlobalSettings.CHUNK_SIZE
	var pending_changes: Array = []

	for _i in range(TICKS_PER_CYCLE):
		# Pick a random loaded chunk
		var chunk_pos: Vector2i = loaded_positions[_rng.randi() % loaded_positions.size()]
		# Pick a random tile within the chunk
		var tile_x: int = _rng.randi() % chunk_size
		var tile_y: int = _rng.randi() % chunk_size

		var world_x: float = chunk_pos.x * chunk_size + tile_x
		var world_y: float = chunk_pos.y * chunk_size + tile_y
		var world_pos := Vector2(world_x, world_y)

		var tile_data: Array = _chunk_manager.get_tile_at_world_pos(world_pos)
		var tile_id: int = tile_data[0]
		var cell_id: int = tile_data[1]

		var growth_type: String = TileIndex.get_growth_type(tile_id)
		if growth_type == "none":
			continue

		if growth_type == "spread_surface":
			_try_spread_surface(world_pos, tile_id, pending_changes)
		elif growth_type == "grow_down":
			_try_grow_down(world_pos, tile_id, cell_id, pending_changes)

	if not pending_changes.is_empty():
		_chunk_manager.set_tiles_at_world_positions(pending_changes)


## Grass spreading: convert an adjacent dirt tile to grass if the dirt has air above it.
func _try_spread_surface(world_pos: Vector2, tile_id: int, changes: Array) -> void:
	if _rng.randf() > GRASS_SPREAD_CHANCE:
		return

	# Shuffle-pick a random neighbor from SPREAD_OFFSETS
	var offset: Vector2i = SPREAD_OFFSETS[_rng.randi() % SPREAD_OFFSETS.size()]
	var neighbor_pos := Vector2(world_pos.x + offset.x, world_pos.y + offset.y)

	var neighbor_data: Array = _chunk_manager.get_tile_at_world_pos(neighbor_pos)
	if neighbor_data[0] != TileIndex.DIRT:
		return

	# Check if the dirt tile has air above it (exposed to sky / open space)
	var above_pos := Vector2(neighbor_pos.x, neighbor_pos.y - 1)
	var above_data: Array = _chunk_manager.get_tile_at_world_pos(above_pos)
	if above_data[0] != TileIndex.AIR:
		return

	changes.append({"pos": neighbor_pos, "tile_id": tile_id, "cell_id": 0})


## Vine growth: extend vine one tile downward if space is available and length limit not reached.
func _try_grow_down(world_pos: Vector2, tile_id: int, cell_id: int, changes: Array) -> void:
	if _rng.randf() > VINE_GROW_CHANCE:
		return

	if cell_id >= MAX_VINE_LENGTH:
		return

	var below_pos := Vector2(world_pos.x, world_pos.y + 1)
	var below_data: Array = _chunk_manager.get_tile_at_world_pos(below_pos)
	if below_data[0] != TileIndex.AIR:
		return

	# New vine segment: cell_id = parent cell_id + 1 (tracks chain length)
	changes.append({"pos": below_pos, "tile_id": tile_id, "cell_id": cell_id + 1})
