## Manages entity lifecycle: spawning, despawning, and per-frame updates.
##
## Assigns monotonically increasing IDs to entities and drives their
## entity_process() each physics frame.
class_name EntityManager extends Node

## All active entities keyed by entity_id.
var _entities: Dictionary = {} # { int: BaseEntity }

## Next entity ID to assign.
var _next_id: int = 1


func _physics_process(delta: float) -> void:
	for entity in _entities.values():
		if is_instance_valid(entity):
			entity.entity_process(delta)


## Spawns an entity, assigns an ID, adds it as a child, and emits the signal.
## Returns the assigned entity ID.
func spawn(entity: BaseEntity) -> int:
	var id = _next_id
	_next_id += 1
	entity.entity_id = id
	_entities[id] = entity
	add_child(entity)
	SignalBus.entity_spawned.emit(entity)
	return id


## Despawns an entity by ID, removes it from the tree, and emits the signal.
func despawn(id: int) -> void:
	var entity = _entities.get(id)
	if entity == null:
		return
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
