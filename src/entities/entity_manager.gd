## Manages entity lifecycle: spawning, despawning, and per-frame updates.
##
## Assigns monotonically increasing IDs to entities and drives their
## entity_process() each physics frame.
class_name EntityManager extends Node

## All active entities keyed by entity_id.
var _entities: Dictionary = {} # { int: BaseEntity }

## Next entity ID to assign.
var _next_id: int = 1

## Entities grouped by chunk position: { Vector2i: Array[int] }
var _chunk_entities: Dictionary = {}


func _ready() -> void:
	SignalBus.chunk_unloaded.connect(_on_chunk_unloaded)


func _physics_process(delta: float) -> void:
	for entity in _entities.values():
		if is_instance_valid(entity):
			entity.entity_process(delta)
			_update_entity_chunk(entity)


## Spawns an entity, assigns an ID, adds it as a child, and emits the signal.
## Returns the assigned entity ID.
func spawn(entity: BaseEntity) -> int:
	var id = _next_id
	_next_id += 1
	entity.entity_id = id
	_entities[id] = entity
	add_child(entity)
	# Initialize chunk tracking
	if GameServices.chunk_manager:
		entity.chunk_pos = GameServices.chunk_manager.world_to_chunk_pos(entity.global_position)
		if not _chunk_entities.has(entity.chunk_pos):
			_chunk_entities[entity.chunk_pos] = []
		_chunk_entities[entity.chunk_pos].append(id)
	SignalBus.entity_spawned.emit(entity)
	return id


## Despawns an entity by ID, removes it from the tree, and emits the signal.
func despawn(id: int) -> void:
	var entity = _entities.get(id)
	if entity == null:
		return
	# Remove from chunk tracking
	if _chunk_entities.has(entity.chunk_pos):
		var arr: Array = _chunk_entities[entity.chunk_pos]
		arr.erase(id)
		if arr.is_empty():
			_chunk_entities.erase(entity.chunk_pos)
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
	}


## Updates the chunk tracking for an entity based on its current position.
func _update_entity_chunk(entity: BaseEntity) -> void:
	if not GameServices.chunk_manager:
		return
	var new_chunk = GameServices.chunk_manager.world_to_chunk_pos(entity.global_position)
	if new_chunk != entity.chunk_pos:
		var old_chunk = entity.chunk_pos
		# Remove from old chunk tracking
		if _chunk_entities.has(old_chunk):
			var arr: Array = _chunk_entities[old_chunk]
			arr.erase(entity.entity_id)
			if arr.is_empty():
				_chunk_entities.erase(old_chunk)
		# Add to new chunk tracking
		if not _chunk_entities.has(new_chunk):
			_chunk_entities[new_chunk] = []
		_chunk_entities[new_chunk].append(entity.entity_id)
		entity.chunk_pos = new_chunk
		SignalBus.entity_chunk_changed.emit(entity, old_chunk, new_chunk)


## Despawns all entities in an unloaded chunk.
func _on_chunk_unloaded(chunk_pos: Vector2i) -> void:
	if not _chunk_entities.has(chunk_pos):
		return
	# Copy the array since despawn modifies _chunk_entities
	var entity_ids = _chunk_entities[chunk_pos].duplicate()
	for id in entity_ids:
		despawn(id)


## Returns all entities in the given chunk.
func get_entities_in_chunk(chunk_pos: Vector2i) -> Array:
	if not _chunk_entities.has(chunk_pos):
		return []
	var result: Array = []
	for id in _chunk_entities[chunk_pos]:
		var entity = _entities.get(id)
		if entity and is_instance_valid(entity):
			result.append(entity)
	return result


## Returns all entities within the given world-space rectangle.
func get_entities_in_area(rect: Rect2) -> Array:
	var result: Array = []
	if not GameServices.chunk_manager:
		return result
	# Determine which chunks overlap the rect
	var min_chunk = GameServices.chunk_manager.world_to_chunk_pos(rect.position)
	var max_chunk = GameServices.chunk_manager.world_to_chunk_pos(rect.position + rect.size)
	for cx in range(min_chunk.x, max_chunk.x + 1):
		for cy in range(min_chunk.y, max_chunk.y + 1):
			var chunk_pos = Vector2i(cx, cy)
			if not _chunk_entities.has(chunk_pos):
				continue
			for id in _chunk_entities[chunk_pos]:
				var entity = _entities.get(id)
				if entity and is_instance_valid(entity) and rect.has_point(entity.global_position):
					result.append(entity)
	return result
