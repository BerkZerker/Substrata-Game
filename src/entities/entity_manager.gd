## Manages entity lifecycle: spawning, despawning, and per-frame updates.
##
## Assigns monotonically increasing IDs to entities and drives their
## entity_process() each physics frame.
class_name EntityManager extends Node

## All active entities keyed by entity_id.
var _entities: Dictionary = {} # { int: BaseEntity }

## Next entity ID to assign.
var _next_id: int = 1

## Entities grouped by chunk position for spatial queries.
var _entities_by_chunk: Dictionary = {} # { Vector2i: Dictionary { int: true } }

## Serialized entity data for entities in unloaded chunks, keyed by chunk position.
var _deferred_entities: Dictionary = {} # { Vector2i: Array[Dictionary] }


func _ready() -> void:
	SignalBus.chunk_unloaded.connect(_on_chunk_unloaded)
	SignalBus.chunk_loaded.connect(_on_chunk_loaded)


func _physics_process(delta: float) -> void:
	for entity in _entities.values():
		if is_instance_valid(entity):
			var old_chunk = entity.current_chunk
			entity.entity_process(delta)
			var new_chunk = entity.current_chunk
			if old_chunk != new_chunk:
				_update_entity_chunk(entity.entity_id, old_chunk, new_chunk)


## Spawns an entity, assigns an ID, adds it as a child, and emits the signal.
## Returns the assigned entity ID.
func spawn(entity: BaseEntity) -> int:
	var id = _next_id
	_next_id += 1
	entity.entity_id = id
	_entities[id] = entity
	add_child(entity)

	# Track entity in chunk map
	var chunk_size = GlobalSettings.CHUNK_SIZE
	var chunk_pos = Vector2i(
		int(floor(entity.global_position.x / chunk_size)),
		int(floor(entity.global_position.y / chunk_size))
	)
	entity.current_chunk = chunk_pos
	_add_entity_to_chunk(id, chunk_pos)

	SignalBus.entity_spawned.emit(entity)
	return id


## Despawns an entity by ID, removes it from the tree, and emits the signal.
func despawn(id: int) -> void:
	var entity = _entities.get(id)
	if entity == null:
		return
	_remove_entity_from_chunk(id, entity.current_chunk)
	_entities.erase(id)
	SignalBus.entity_despawned.emit(entity)
	if is_instance_valid(entity):
		entity.queue_free()


## Returns the entity with the given ID, or null if not found.
func get_entity(id: int) -> BaseEntity:
	return _entities.get(id)


## Returns the number of active entities.
func get_entity_count() -> int:
	return _entities.size()


## Returns debug info about the entity system.
func get_debug_info() -> Dictionary:
	return {
		"entity_count": _entities.size(),
		"next_id": _next_id,
		"deferred_chunks": _deferred_entities.size(),
	}


## Returns entity IDs in a given chunk position.
func get_entities_in_chunk(chunk_pos: Vector2i) -> Array:
	var chunk_set = _entities_by_chunk.get(chunk_pos)
	if chunk_set == null:
		return []
	return chunk_set.keys()


# ─── Chunk tracking helpers ──────────────────────────────────────────


func _add_entity_to_chunk(entity_id: int, chunk_pos: Vector2i) -> void:
	if not _entities_by_chunk.has(chunk_pos):
		_entities_by_chunk[chunk_pos] = {}
	_entities_by_chunk[chunk_pos][entity_id] = true


func _remove_entity_from_chunk(entity_id: int, chunk_pos: Vector2i) -> void:
	var chunk_set = _entities_by_chunk.get(chunk_pos)
	if chunk_set:
		chunk_set.erase(entity_id)
		if chunk_set.is_empty():
			_entities_by_chunk.erase(chunk_pos)


func _update_entity_chunk(entity_id: int, old_chunk: Vector2i, new_chunk: Vector2i) -> void:
	_remove_entity_from_chunk(entity_id, old_chunk)
	_add_entity_to_chunk(entity_id, new_chunk)


# ─── Chunk load/unload handlers ─────────────────────────────────────


func _on_chunk_unloaded(chunk_pos: Vector2i) -> void:
	var chunk_set = _entities_by_chunk.get(chunk_pos)
	if chunk_set == null or chunk_set.is_empty():
		return

	var serialized: Array = []
	for entity_id in chunk_set.keys():
		var entity = _entities.get(entity_id)
		if entity == null or not is_instance_valid(entity):
			continue
		serialized.append(_serialize_entity(entity))
		_entities.erase(entity_id)
		SignalBus.entity_despawned.emit(entity)
		entity.queue_free()

	_entities_by_chunk.erase(chunk_pos)

	if not serialized.is_empty():
		_deferred_entities[chunk_pos] = serialized


func _on_chunk_loaded(chunk_pos: Vector2i) -> void:
	var deferred = _deferred_entities.get(chunk_pos)
	if deferred == null:
		return
	_deferred_entities.erase(chunk_pos)

	for data in deferred:
		_deserialize_and_spawn(data)


func _serialize_entity(entity: BaseEntity) -> Dictionary:
	return {
		"scene_path": entity.scene_file_path,
		"position": entity.global_position,
		"velocity": entity.velocity,
	}


func _deserialize_and_spawn(data: Dictionary) -> void:
	var scene_path: String = data.get("scene_path", "")
	if scene_path.is_empty():
		return

	var scene = load(scene_path) as PackedScene
	if scene == null:
		return

	var entity = scene.instantiate() as BaseEntity
	if entity == null:
		return

	entity.global_position = data.get("position", Vector2.ZERO)
	entity.velocity = data.get("velocity", Vector2.ZERO)
	spawn(entity)
