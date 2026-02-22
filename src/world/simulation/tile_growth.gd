## Tile growth simulation using a random tick model.
##
## Periodically selects random tiles from loaded chunks and applies growth
## rules based on each tile's growth_type property. Supports grass spreading
## to adjacent dirt and vines growing downward.
class_name TileGrowthSystem extends Node

## How often (in seconds) a growth tick runs.
const TICK_INTERVAL: float = 2.0

## Number of random tiles to sample per tick.
const TICKS_PER_CYCLE: int = 32

## Probability that a grass tile spreads to an adjacent dirt tile per tick.
const GRASS_SPREAD_CHANCE: float = 0.10

## Probability that a vine tile grows one tile downward per tick.
const VINE_GROW_CHANCE: float = 0.05

## Maximum vine chain length (tracked via cell_id).
const MAX_VINE_LENGTH: int = 10

## Neighbor offsets for grass spreading (horizontal + diagonal, not straight down).
const SPREAD_OFFSETS: Array[Vector2i] = [
	Vector2i(-1, 0), Vector2i(1, 0),
	Vector2i(0, -1),
	Vector2i(-1, -1), Vector2i(1, -1),
	Vector2i(-1, 1), Vector2i(1, 1),
]

var _timer: float = 0.0
var _chunk_manager: ChunkManager = null
var _rng: RandomNumberGenerator = RandomNumberGenerator.new()
var _cached_positions: Array = []
var _cache_timer: float = 0.0


func _ready() -> void:
	_rng.randomize()
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
	# Refresh cached chunk positions every few seconds
	_cache_timer += TICK_INTERVAL
	if _cache_timer >= 5.0 or _cached_positions.is_empty():
		_cached_positions = _chunk_manager.get_loaded_chunk_positions()
		_cache_timer = 0.0

	if _cached_positions.is_empty():
		return

	var chunk_size: int = GlobalSettings.CHUNK_SIZE
	var changes: Array = []

	for _i in range(TICKS_PER_CYCLE):
		var chunk_pos: Vector2i = _cached_positions[_rng.randi() % _cached_positions.size()]
		var tile_x: int = _rng.randi() % chunk_size
		var tile_y: int = _rng.randi() % chunk_size

		# Direct chunk read (avoid set_tiles_at_world_positions overhead)
		var chunk: Chunk = _chunk_manager.get_chunk_at(chunk_pos)
		if chunk == null:
			continue

		var tile_data: Array = chunk.get_tile_at(tile_x, tile_y)
		var tile_id: int = tile_data[0]
		var cell_id: int = tile_data[1]

		var growth_type: String = TileIndex.get_growth_type(tile_id)
		if growth_type == "none":
			continue

		var world_x: int = chunk_pos.x * chunk_size + tile_x
		var world_y: int = chunk_pos.y * chunk_size + tile_y

		if growth_type == "spread_surface":
			_try_spread_surface(world_x, world_y, tile_id, changes)
		elif growth_type == "grow_down":
			_try_grow_down(world_x, world_y, tile_id, cell_id, changes)

	if not changes.is_empty():
		_chunk_manager.set_tiles_at_world_positions(changes)


func _try_spread_surface(world_x: int, world_y: int, tile_id: int, changes: Array) -> void:
	if _rng.randf() > GRASS_SPREAD_CHANCE:
		return

	var offset: Vector2i = SPREAD_OFFSETS[_rng.randi() % SPREAD_OFFSETS.size()]
	var nx: int = world_x + offset.x
	var ny: int = world_y + offset.y

	var neighbor_data: Array = _chunk_manager.get_tile_at_world_pos(Vector2(nx, ny))
	if neighbor_data[0] != TileIndex.DIRT:
		return

	var above_data: Array = _chunk_manager.get_tile_at_world_pos(Vector2(nx, ny - 1))
	if above_data[0] != TileIndex.AIR:
		return

	changes.append({"pos": Vector2(nx, ny), "tile_id": tile_id, "cell_id": 0})


func _try_grow_down(world_x: int, world_y: int, tile_id: int, cell_id: int, changes: Array) -> void:
	if _rng.randf() > VINE_GROW_CHANCE:
		return

	if cell_id >= MAX_VINE_LENGTH:
		return

	var below_data: Array = _chunk_manager.get_tile_at_world_pos(Vector2(world_x, world_y + 1))
	if below_data[0] != TileIndex.AIR:
		return

	changes.append({"pos": Vector2(world_x, world_y + 1), "tile_id": tile_id, "cell_id": cell_id + 1})
